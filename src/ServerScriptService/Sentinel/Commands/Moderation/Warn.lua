--!strict
--[[
	Warn.lua

	Purpose:
		Registers "/warn", "/warnings", "/clearwarnings" and
		"/removewarnings" (clear all, or remove a number of warnings; both
		work for offline players and can be undone). Delegates the actual ledger and
		escalation logic to PunishmentService and registers the escalation
		actions (kick, mute, ban). The thresholds are admin config (W08).

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		PunishmentService.lua (Systems)
		Ban.lua (Commands.Moderation) — reused for the auto-ban escalation
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local TextFilterService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("TextFilterService"))
local PunishmentService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PunishmentService"))

-- ---------------------------------------------------------------------------
-- Escalation actions (W08). WHEN they run is admin config
-- ("WarningEscalation", default 3 -> kick, 5 -> 1-day ban; see
-- Systems/AdminConfig and ;config escalation). These are the actions a step
-- may name.
-- ---------------------------------------------------------------------------
local Core = Sentinel:WaitForChild("Core")
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local ChatModerationService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ChatModerationService"))
local CaseService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CaseService"))

local function latest(warnings: { PunishmentService.WarningRecord }): string
	return warnings[#warnings] and warnings[#warnings].Reason or "unspecified"
end

PunishmentService.RegisterEscalationAction("kick", function(target, warnings, step)
	CaseService.RecordSystem("kick", target, ("Automatic: %d warnings (latest: %s)"):format(step.Count, latest(warnings)))
	target:Kick(("Automatically kicked: %d warnings reached (latest: %s)."):format(step.Count, latest(warnings)))
end)

PunishmentService.RegisterEscalationAction("mute", function(target, _warnings, step)
	local duration = DurationParser.Parse(step.Duration or "1h")
	if duration then
		ChatModerationService.Mute(target, duration.Seconds, duration.IsPermanent)
		CaseService.RecordSystem("mute", target, ("Automatic: %d warnings"):format(step.Count), step.Duration or "1h")
	end
end)

PunishmentService.RegisterEscalationAction("ban", function(target, warnings, step)
	local reasonSummary = {}
	for _, w in ipairs(warnings) do
		table.insert(reasonSummary, w.Reason)
	end
	local duration = DurationParser.Parse(step.Duration or "1d")
	local permanent = duration == nil or duration.IsPermanent
	local issuedAt = os.time()
	local record: any = {
		BannedBy = 0, -- SYSTEM
		Reason = ("Automatically banned: %d warnings reached (%s)."):format(step.Count, table.concat(reasonSummary, "; ")),
		IssuedAt = issuedAt,
		ExpiresAt = if permanent then math.huge else issuedAt + (duration :: any).Seconds,
	}
	record.TargetName = target.Name
	record.BannedByName = "SYSTEM"
	-- Ban.lua owns the ban store (record + ban list index).
	local BanCommand = require(script.Parent:WaitForChild("Ban")) :: any
	if not BanCommand.SetBan(target.UserId, record) then
		warn("[Sentinel.Warn] failed to persist auto-ban")
	end
	CaseService.RecordSystem("ban", target, record.Reason, if permanent then "forever" else step.Duration or "1d")
	target:Kick(("Banned: Automatically banned, %d warnings reached."):format(step.Count))
end)

CommandRegistry.Register({
	Name = "warn",
	Aliases = { "w" },
	Description = "Issues a warning to a player. Escalates automatically at policy thresholds.",
	Usage = "/warn target reason",
	Permission = "moderation.warn",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local reason = "No reason given."
		if #ctx.Arguments > 0 then
			-- Warning reasons end up on kick screens (escalation): filter them.
			local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, table.concat(ctx.Arguments, " "))
			if not filtered then
				return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
			end
			reason = filtered
		end
		local counts = {}

		for _, target in ipairs(ctx.Targets) do
			local warnings = PunishmentService.AddWarning(target, ctx.Executor, reason)
			counts[target.Name] = #warnings
		end

		local summary = {}
		for name, count in pairs(counts) do
			table.insert(summary, ("%s (%d)"):format(name, count))
		end

		return {
			Success = true,
			Message = "Warned: " .. table.concat(summary, ", "),
		}
	end,
})

CommandRegistry.Register({
	Name = "warnings",
	TargetProtection = false, -- harmless/read-only: allowed on higher ranks
	Aliases = { "warns" },
	Description = "Lists a player's warning history.",
	Usage = "/warnings target",
	Permission = "moderation.warn",
	Category = "Moderation",
	Log = false,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "No target found." }
		end
		local warnings = PunishmentService.GetWarnings(target.UserId)
		if #warnings == 0 then
			return { Success = true, Message = ("%s has no warnings."):format(target.Name) }
		end

		local lines = {}
		for i, record in ipairs(warnings) do
			table.insert(lines, ("%d. %s (by %s)"):format(i, record.Reason, record.IssuedByName))
		end

		return { Success = true, Message = table.concat(lines, " | ") }
	end,
})

-- ---------------------------------------------------------------------------
-- ;clearwarnings / ;removewarnings (online or offline, undoable)
-- ---------------------------------------------------------------------------
local Logger = require(Core:WaitForChild("Logger"))
local PlayerProfileService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PlayerProfileService"))
local RankService = require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))

-- Resolves the player argument and refuses higher / equal ranks when online.
local function resolveForWarnings(ctx: Types.CommandContext): (any, string?)
	local user, err = PlayerProfileService.Resolve(ctx.Arguments[1], ctx.Executor)
	if not user then
		return nil, err
	end
	if user.Local and user.Local ~= ctx.Executor and not RankService.CanTarget(ctx.Executor, user.Local) then
		return nil, ("%s is protected by rank."):format(user.Name)
	end
	return user, nil
end

local function applyRemoval(ctx: Types.CommandContext, spec: string, reasonFrom: number): Types.CommandResult
	local user, err = resolveForWarnings(ctx)
	if not user then
		return { Success = false, Message = err or "Player not found." }
	end
	local before = table.clone(PunishmentService.GetWarnings(user.UserId))
	local kept, removed = PunishmentService.PlanRemoval(before, spec)
	if not kept then
		return { Success = false, Message = ("%s %s."):format(user.Name, tostring(removed)) }
	end
	if not PunishmentService.SetWarnings(user.UserId, kept) then
		return { Success = false, Message = "The warnings could not be saved (DataStore error) - try again." }
	end
	Logger.NoteChange(user.Name, "warnings", #before, #kept, ctx.Executor, "moderation.warnings")
	local reason = table.concat(ctx.Arguments, " ", reasonFrom)
	;(ctx :: any).Reason = if reason ~= "" then reason else nil
	local what = if #kept == 0 then "all warnings" else ("%d warning(s)"):format(#removed)
	return {
		Success = true,
		Message = ("Removed %s from %s (%d -> %d)."):format(what, user.Name, #before, #kept),
		Undoable = true,
		UndoData = { UserId = user.UserId, Name = user.Name, Previous = before },
	} :: any
end

local function restoreWarnings(_ctx: Types.CommandContext, result: any): Types.CommandResult
	local data = result.UndoData or {}
	if type(data.UserId) ~= "number" or type(data.Previous) ~= "table" then
		return { Success = false, Message = "Nothing to restore." }
	end
	if not PunishmentService.SetWarnings(data.UserId, data.Previous) then
		return { Success = false, Message = "The warnings could not be restored (DataStore error)." }
	end
	return { Success = true, Message = ("Restored %d warning(s) for %s."):format(#data.Previous, tostring(data.Name)) }
end

CommandRegistry.Register({
	Name = "clearwarnings",
	Aliases = { "clearwarns", "resetwarnings", "clearwarn" },
	Description = "Removes every warning a player has (online or offline). Undo with ;undo.",
	Usage = "/clearwarnings player [reason...]",
	ArgHints = { player = { Type = "string", Description = "Username, UserId or me" } },
	Examples = { "clearwarnings Player1", "clearwarnings 123456 Appeal accepted" },
	Permission = "moderation.clearwarnings",
	Category = "Moderation",
	Subcategory = "Warnings",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		if not ctx.Arguments[1] then
			return { Success = false, Message = "Usage: ;clearwarnings <player> [reason]" }
		end
		return applyRemoval(ctx, "all", 2)
	end,
	Undo = restoreWarnings,
} :: any)

CommandRegistry.Register({
	Name = "removewarnings",
	Aliases = { "removewarns", "unwarn", "delwarn", "removewarn" },
	Description = "Removes some of a player's warnings: the newest <count>, warning #n (as ;warnings numbers them) or #a-b. Online or offline; undo with ;undo.",
	Usage = "/removewarnings player amount [reason...]",
	ArgHints = {
		player = { Type = "string", Description = "Username, UserId or me" },
		amount = { Type = "string", Description = "Newest N (e.g. 2), #3 for warning 3, #2-4, or all", Suggestions = { "1", "2", "3", "#1", "all" } },
	},
	Examples = { "removewarnings Player1 1", "removewarnings Player1 2 Mistake", "removewarnings Player1 #3", "removewarnings 123456 #1-2" },
	Permission = "moderation.clearwarnings",
	Category = "Moderation",
	Subcategory = "Warnings",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		if not ctx.Arguments[1] then
			return { Success = false, Message = "Usage: ;removewarnings <player> <amount|#n|#a-b|all> [reason]" }
		end
		-- no amount = the newest one (;unwarn Player1)
		local spec = ctx.Arguments[2]
		local reasonFrom = 3
		if not spec or not (spec:lower() == "all" or spec:match("^#?%d+$") or spec:match("^#%d+%-%d+$")) then
			spec, reasonFrom = "1", 2
		end
		return applyRemoval(ctx, spec, reasonFrom)
	end,
	Undo = restoreWarnings,
} :: any)

return true
