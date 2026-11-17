--!strict
--[[
	Warn.lua

	Purpose:
		Registers "/warn" and "/warnings". Delegates the actual ledger and
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

local function latest(warnings: { PunishmentService.WarningRecord }): string
	return warnings[#warnings] and warnings[#warnings].Reason or "unspecified"
end

PunishmentService.RegisterEscalationAction("kick", function(target, warnings, step)
	target:Kick(("Automatically kicked: %d warnings reached (latest: %s)."):format(step.Count, latest(warnings)))
end)

PunishmentService.RegisterEscalationAction("mute", function(target, _warnings, step)
	local duration = DurationParser.Parse(step.Duration or "1h")
	if duration then
		ChatModerationService.Mute(target, duration.Seconds, duration.IsPermanent)
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
	local record = {
		BannedBy = 0, -- SYSTEM
		Reason = ("Automatically banned: %d warnings reached (%s)."):format(step.Count, table.concat(reasonSummary, "; ")),
		IssuedAt = issuedAt,
		ExpiresAt = if permanent then math.huge else issuedAt + (duration :: any).Seconds,
	}
	local DataStoreService = game:GetService("DataStoreService")
	local ok, err = pcall(function()
		DataStoreService:GetDataStore("Sentinel_Bans_v1"):SetAsync(tostring(target.UserId), record)
	end)
	if not ok then
		warn(("[Sentinel.Warn] failed to persist auto-ban: %s"):format(tostring(err)))
	end
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

return true
