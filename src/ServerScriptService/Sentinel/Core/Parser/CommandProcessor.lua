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
			options.Confirmed = true skips risk confirmation (used by
			;confirm and by UI dialogs that already asked the user)
		CommandProcessor.ConfirmPending(executor, id?): {CommandResult}
		CommandProcessor.SetTargetFilter(fn)

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

function CommandProcessor.Process(executor: Player, rawInput: string, options: { Confirmed: boolean? }?): { CommandResult }
	local results: { CommandResult } = {}
	local confirmed = options ~= nil and options.Confirmed == true

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
			targets = TargetResolver.Resolve(executor, current.TargetSelectors)
			ctxArguments = current.Arguments
			ctxModifier = current.Modifier
		end

		if def.RequiresTarget and #targets == 0 then
			table.insert(results, {
				Success = false,
				Message = ("%s requires a valid target."):format(def.Name),
			})
			break
		end

		local blocked = 0
		if def.RequiresTarget and targetFilter and def.TargetProtection ~= false then
			targets, blocked = targetFilter(executor, def, targets)
			if #targets == 0 then
				table.insert(results, {
					Success = false,
					Message = ("You can't use %s on players ranked equal to or above you."):format(def.Name),
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
			local needs, why = CommandPolicy.NeedsConfirmation(def, #targets)
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
		}

		local result = CommandRegistry.Dispatch(def, executor, ctx)
		if blocked > 0 and result.Message then
			result.Message ..= (" (skipped %d player(s) ranked equal to or above you)"):format(blocked)
		end
		table.insert(results, result)

		if not result.Success then
			break -- stop the chain on first failure, mirroring left-to-right execution semantics
		end

		current = current.NextCommand
	end

	return results
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
	return CommandProcessor.Process(executor, pending.RawInput, { Confirmed = true })
end

return CommandProcessor
