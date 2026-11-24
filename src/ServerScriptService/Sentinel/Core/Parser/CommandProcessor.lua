--!strict
--[[
	CommandProcessor.lua

	Purpose:
		The single function the chat hook (or future GUI command palette)
		calls with raw player input. Wires together CommandParser,
		CommandRegistry (alias resolution + dispatch), and TargetResolver,
		walking the "&&" chain and stopping early if a link fails.

	Responsibilities:
		- Parse raw input into a ParsedCommand chain
		- Resolve each link's command name (with alias support)
		- Resolve targets via TargetResolver
		- Attach ParsedDuration / ParsedQuantity when the command declares
		  it needs one (commands opt in via RequiresTarget + Modifier use;
		  the command's own Execute decides which parser to apply since
		  only it knows whether ":modifier" means a duration or a quantity)
		- Dispatch through CommandRegistry.Dispatch for permission/cooldown/
		  logging enforcement
		- Return a flat list of CommandResult, one per link, in order

	Dependencies:
		CommandParser.lua, TargetResolver.lua (Parser)
		CommandRegistry.lua (Core)
		Types.lua (Shared)

	Public API:
		CommandProcessor.Process(executor, rawInput, options?): {CommandResult}
			options.ApprovalToken = an Owner's approval (ApprovalService)
			options.Confirmed = true skips risk confirmation (used by
			;confirm and by UI dialogs that already asked the user)
		CommandProcessor.ConfirmPending(executor, id?): {CommandResult}
		CommandProcessor.SetTargetFilter(fn)
		CommandProcessor.Preview(executor, rawInput): {preview} (dry run)
		CommandProcessor.Undo(executor) / Redo(executor): CommandResult (W07)
		CommandProcessor.CancelPending(executor): boolean (W07)
		options.Source = "chat" | "panel" | "preset" | ... (shown in history)

	Risky commands (see Core/CommandPolicy) don't run straight away: the
	result has NeedsConfirmation = true and a ConfirmId, and the rest of
	the chain (from the risky link on) is kept for CONFIRM_WINDOW seconds
	until the player runs ;confirm.

	Example usage:
		-- rawInput does NOT include the leading "/"
		local results = CommandProcessor.Process(admin, "ban Player1:30m Exploiting")
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandParser = require(script.Parent:WaitForChild("CommandParser"))
local TargetResolver = require(script.Parent:WaitForChild("TargetResolver"))
local CommandRegistry = require(script.Parent.Parent:WaitForChild("CommandRegistry"))
local CommandPolicy = require(script.Parent.Parent:WaitForChild("CommandPolicy"))
local PermissionSystem = require(script.Parent.Parent:WaitForChild("PermissionSystem"))
local CommandHistory = require(script.Parent.Parent:WaitForChild("CommandHistory"))
local Logger = require(script.Parent.Parent:WaitForChild("Logger"))

-- W10 failed-action log: commands refused before Dispatch (no valid
-- target, rank protection) are audited too.
local function logRejected(def: any, executor: Player, current: any, args: { string }, result: string, message: string)
	local fields = CommandRegistry.AuditFields(def, executor, {
		Executor = executor,
		Targets = {},
		Arguments = args,
		RawInput = current.RawInput,
		CommandName = current.CommandName,
	} :: any, nil)
	fields.Result = result
	fields.Severity = "Warning"
	fields.Message = message
	Logger.Write(fields :: any)
end
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local CONFIRM_WINDOW = 30 -- seconds a pending confirmation stays valid

type CommandResult = Types.CommandResult
type ParsedCommand = Types.ParsedCommand

local CommandProcessor = {}

-- Optional policy that removes protected players from a command's targets
-- (installed by Systems/RankService: no targeting equal/higher ranks).
-- Returns the allowed targets and how many were removed.
type TargetFilter = (executor: Player, def: Types.CommandDefinition, targets: { Player }) -> ({ Player }, number)
local targetFilter: TargetFilter? = nil

function CommandProcessor.SetTargetFilter(fn: TargetFilter?)
	targetFilter = fn
end

type Pending = { Id: string, RawInput: string, Expires: number }
local pendingConfirmations: { [number]: Pending } = {}
Players.PlayerRemoving:Connect(function(player: Player)
	pendingConfirmations[player.UserId] = nil
end)

-- Rebuilds the raw text of a chain starting at `link`.
local function remainingChain(link: ParsedCommand?): string
	local parts = {}
	while link do
		table.insert(parts, link.RawInput)
		link = link.NextCommand
	end
	return table.concat(parts, " && ")
end

function CommandProcessor.Process(executor: Player, rawInput: string, options: { Confirmed: boolean?, Source: string?, ApprovalToken: string? }?): { CommandResult }
	local results: { CommandResult } = {}
	local confirmed = options ~= nil and options.Confirmed == true
	local source = (options and options.Source) or "panel"

	local chain = CommandParser.ParseLine(rawInput)
	if not chain then
		return { { Success = false, Message = "Could not parse that command." } }
	end

	local current: ParsedCommand? = chain
	while current do
		local def = CommandRegistry.Resolve(current.CommandName)
		if not def then
			table.insert(results, {
				Success = false,
				Message = ("Unknown command: %s"):format(current.CommandName),
			})
			break
		end

		-- IMPORTANT: only run target resolution when the command actually
		-- declares it wants a target. Otherwise a target-less command's
		-- first word (e.g. "on" in "maintenancemode on") gets swallowed by
		-- the parser's target-guessing logic and silently vanishes from
		-- Arguments — this was a real bug (maintenance/weather/slowmode/
		-- etc. all executed with empty Arguments).
		local targets: { Player } = {}
		local ctxArguments: { string } = current.PlainArguments
		local ctxModifier: string? = nil

		if def.RequiresTarget then
			-- def.DefaultSelf: no target typed = the executor (e.g. ;uncontrol).
			if def.DefaultSelf and #current.TargetSelectors == 0 then
				targets = { executor }
			else
				targets = TargetResolver.Resolve(executor, current.TargetSelectors)
			end
			ctxArguments = current.Arguments
			ctxModifier = current.Modifier
		end

		if def.RequiresTarget and #targets == 0 then
			local message = ("%s requires a valid target."):format(def.Name)
			logRejected(def, executor, current, ctxArguments, "Failure", message)
			table.insert(results, {
				Success = false,
				Message = message,
			})
			break
		end

		local blocked = 0
		if def.RequiresTarget and targetFilter and def.TargetProtection ~= false then
			targets, blocked = targetFilter(executor, def, targets)
			if #targets == 0 then
				local message = ("You can't use %s on players ranked equal to or above you."):format(def.Name)
				logRejected(def, executor, current, ctxArguments, "Denied", message)
				table.insert(results, {
					Success = false,
					Message = message,
				})
				break
			end
		end

		-- Risky commands wait for an explicit ;confirm (or a UI dialog).
		-- (Only ask when the command would actually be allowed; otherwise
		-- Dispatch reports the denial straight away.)
		local allowed = PermissionSystem.Has(executor, def.Permission)
			and (not CommandPolicy.IsOwnerOnly(def) or table.find(PermissionSystem.GetRoles(executor), "Owner") ~= nil)
		if not confirmed and allowed then
			local needs, why = CommandPolicy.NeedsConfirmation(def, #targets, if def.RequiresTarget then current.Arguments else current.PlainArguments)
			if needs then
				local id = HttpService:GenerateGUID(false):sub(1, 6):lower()
				pendingConfirmations[executor.UserId] = {
					Id = id,
					RawInput = remainingChain(current),
					Expires = os.time() + CONFIRM_WINDOW,
				}
				table.insert(results, {
					Success = false,
					NeedsConfirmation = true,
					ConfirmId = id,
					Risk = CommandPolicy.GetRisk(def),
					Message = ("⚠ %s Type ;confirm within %ds to run it."):format(why, CONFIRM_WINDOW),
				} :: any)
				break
			end
		end

		local ctx: Types.CommandContext = {
			Executor = executor,
			Targets = targets,
			Modifier = ctxModifier,
			Arguments = ctxArguments,
			RawInput = current.RawInput,
			CommandName = current.CommandName, -- the name or alias as typed (lowercased), e.g. "superfling"
			Source = source,
		}
		-- Set when an Owner approved this command (Systems/ApprovalService).
		if options and type(options.ApprovalToken) == "string" then
			(ctx :: any).ApprovalToken = options.ApprovalToken
		end

		local result = CommandRegistry.Dispatch(def, executor, ctx)
		if blocked > 0 and result.Message then
			result.Message ..= (" (skipped %d player(s) ranked equal to or above you)"):format(blocked)
		end
		CommandHistory.Record(executor, def, ctx, result, source)
		table.insert(results, result)

		if not result.Success then
			break -- stop the chain on first failure, mirroring left-to-right execution semantics
		end

		current = current.NextCommand
	end

	return results
end

--[[
	Preview (W06): a dry run of the chain for the command palette. Nothing
	executes and no state changes ("last" targets, cooldowns, pending
	confirmations are untouched). One entry per link:
		{ Command, Allowed, Problem?, RequiresTarget, Targets = {{Name,
		  DisplayName, UserId}}, Blocked, Risk, NeedsConfirmation, Reason? }
	"random" targets are re-rolled on every preview.
--]]
function CommandProcessor.Preview(executor: Player, rawInput: string): { any }
	local previews = {}
	local chain = CommandParser.ParseLine(rawInput)
	local current: ParsedCommand? = chain
	local isOwner = table.find(PermissionSystem.GetRoles(executor), "Owner") ~= nil
	while current and #previews < 10 do
		local def = CommandRegistry.Resolve(current.CommandName)
		if not def then
			table.insert(previews, { Command = current.CommandName, Allowed = false, Problem = "Unknown command" })
			break
		end
		local entry: any = {
			Command = def.Name,
			RequiresTarget = def.RequiresTarget == true,
			Risk = CommandPolicy.GetRisk(def),
			Targets = {},
			Blocked = 0,
		}
		entry.Allowed = ((def :: any).Public == true or PermissionSystem.Has(executor, def.Permission))
			and (not CommandPolicy.IsOwnerOnly(def) or isOwner)
		if not entry.Allowed then
			entry.Problem = "You don't have " .. def.Permission
		end

		local targets: { Player } = {}
		if def.RequiresTarget then
			if def.DefaultSelf and #current.TargetSelectors == 0 then
				targets = { executor }
			else
				targets = TargetResolver.Resolve(executor, current.TargetSelectors, nil, true)
			end
			if #targets == 0 then
				entry.Problem = entry.Problem or "No matching players"
			elseif targetFilter and def.TargetProtection ~= false then
				local kept, blocked = targetFilter(executor, def, targets)
				targets, entry.Blocked = kept, blocked
				if #kept == 0 then
					entry.Problem = entry.Problem or "Every target is ranked equal to or above you"
				end
			end
		end
		for _, p in ipairs(targets) do
			if #entry.Targets >= 50 then
				break
			end
			table.insert(entry.Targets, { Name = p.Name, DisplayName = p.DisplayName, UserId = p.UserId })
		end
		entry.TargetCount = #targets
		local needs, why = CommandPolicy.NeedsConfirmation(def, #targets, if def.RequiresTarget then current.Arguments else current.PlainArguments)
		entry.NeedsConfirmation = needs
		entry.Reason = why
		table.insert(previews, entry)
		current = current.NextCommand
	end
	return previews
end

-- Runs the player's pending risky command. `id` is optional (chat users
-- just type ;confirm); when given it must match, so an old dialog can't
-- confirm a newer request.
function CommandProcessor.ConfirmPending(executor: Player, id: string?): { CommandResult }
	local pending = pendingConfirmations[executor.UserId]
	if not pending or pending.Expires < os.time() then
		pendingConfirmations[executor.UserId] = nil
		return { { Success = false, Message = "Nothing to confirm (or it expired)." } }
	end
	if id and id ~= "" and id ~= pending.Id then
		return { { Success = false, Message = "That confirmation is no longer pending." } }
	end
	pendingConfirmations[executor.UserId] = nil
	return CommandProcessor.Process(executor, pending.RawInput, { Confirmed = true, Source = "confirm" })
end

-- Drops the player's pending confirmation (;cancel). Returns true if there was one.
function CommandProcessor.CancelPending(executor: Player): boolean
	local had = pendingConfirmations[executor.UserId] ~= nil
	pendingConfirmations[executor.UserId] = nil
	return had
end

-- ---------------------------------------------------------------------------
-- Undo / redo (W07). Both re-enter CommandRegistry.Dispatch, so the inverse
-- command is permission-checked, logged and hooked like any other.
-- ---------------------------------------------------------------------------
local function stillHere(targets: { Player }): { Player }
	local out = {}
	for _, p in ipairs(targets) do
		if p.Parent == Players then
			table.insert(out, p)
		end
	end
	return out
end

local function runResolved(executor: Player, def: any, targets: { Player }, modifier: string?, args: { string }, raw: string, source: string): CommandResult
	if def.RequiresTarget and targetFilter and def.TargetProtection ~= false then
		targets = targetFilter(executor, def, targets)
	end
	if def.RequiresTarget and #targets == 0 then
		return { Success = false, Message = ("%s: none of those players are here any more."):format(def.Name) }
	end
	local ctx: any = {
		Executor = executor,
		Targets = targets,
		Modifier = modifier,
		Arguments = args,
		RawInput = raw,
		CommandName = def.Name,
		Source = source,
	}
	local result = CommandRegistry.Dispatch(def, executor, ctx)
	CommandHistory.Record(executor, def, ctx, result, source)
	return result
end

local function targetText(targets: { Player }): string
	local names = {}
	for _, p in ipairs(targets) do
		table.insert(names, p.Name)
	end
	return table.concat(names, ",")
end

function CommandProcessor.Undo(executor: Player): CommandResult
	local record = CommandHistory.PeekUndo(executor)
	if not record then
		return { Success = false, Message = "Nothing to undo." }
	end
	local def = record.Def
	local targets = stillHere(record.Targets)
	local result: CommandResult
	if type(def.Undo) == "function" then
		-- Custom undo: wrapped in a one-off definition so Dispatch still
		-- checks the original command's permission and logs it.
		local undoDef: any = {
			Name = def.Name .. ".undo",
			Aliases = {},
			Permission = def.Permission,
			Category = def.Category,
			Log = true,
			Undoable = false,
			TargetProtection = false,
			Execute = function(ctx)
				return def.Undo(ctx, record.Result)
			end,
		}
		result = runResolved(executor, undoDef, targets, record.Modifier, record.Arguments, "undo " .. record.Input, "undo")
	else
		local inverseName, keepArgs = CommandHistory.InverseFor(def)
		local inverse = inverseName and CommandRegistry.Resolve(inverseName)
		if not inverse then
			CommandHistory.DropUndo(executor, record)
			return { Success = false, Message = ("%s can't be undone."):format(def.Name) }
		end
		local raw = ("%s %s"):format(inverse.Name, targetText(targets))
		result = runResolved(
			executor,
			inverse,
			targets,
			if keepArgs then record.Modifier else nil,
			if keepArgs then record.Arguments else {},
			raw,
			"undo"
		)
	end
	if result.Success then
		CommandHistory.MarkUndone(executor, record)
		result.Message = ("Undid '%s'. %s"):format(record.Input, result.Message or "")
	elseif result.Message and result.Message:find("none of those players", 1, true) then
		CommandHistory.DropUndo(executor, record)
	end
	return result
end

function CommandProcessor.Redo(executor: Player): CommandResult
	local record = CommandHistory.PeekRedo(executor)
	if not record then
		return { Success = false, Message = "Nothing to redo." }
	end
	local targets = stillHere(record.Targets)
	local result = runResolved(executor, record.Def, targets, record.Modifier, record.Arguments, record.Input, "redo")
	if result.Success then
		CommandHistory.MarkRedone(executor, record)
		result.Message = ("Redid '%s'. %s"):format(record.Input, result.Message or "")
	else
		CommandHistory.DropRedo(executor, record)
	end
	return result
end

return CommandProcessor
