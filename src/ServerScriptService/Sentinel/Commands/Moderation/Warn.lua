--!strict
--[[
	Warn.lua

	Purpose:
		Registers "/warn" and "/warnings". Delegates the actual ledger and
		escalation logic to PunishmentService, and defines the default
		escalation policy (3 warnings -> kick, 5 warnings -> 1-day ban) as
		data passed into PunishmentService.RegisterEscalationRule — change
		the numbers here to retune the policy; nothing else needs to change.

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
local PunishmentService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PunishmentService"))

-- ---------------------------------------------------------------------------
-- Default escalation policy. Tune here.
-- ---------------------------------------------------------------------------
PunishmentService.RegisterEscalationRule(3, function(target: Player, warnings: { PunishmentService.WarningRecord })
	local lastReason = warnings[#warnings] and warnings[#warnings].Reason or "unspecified"
	target:Kick(("Automatically kicked: 3 warnings reached (latest: %s)."):format(lastReason))
end)

PunishmentService.RegisterEscalationRule(5, function(target: Player, warnings: { PunishmentService.WarningRecord })
	local reasonSummary = {}
	for _, w in ipairs(warnings) do
		table.insert(reasonSummary, w.Reason)
	end
	local record = {
		BannedBy = 0, -- SYSTEM
		Reason = ("Automatically banned: 5 warnings reached (%s)."):format(table.concat(reasonSummary, "; ")),
		IssuedAt = os.time(),
		ExpiresAt = os.time() + 86400, -- 1 day
	}
	local DataStoreService = game:GetService("DataStoreService")
	local ok, err = pcall(function()
		DataStoreService:GetDataStore("Sentinel_Bans_v1"):SetAsync(tostring(target.UserId), record)
	end)
	if not ok then
		warn(("[Sentinel.Warn] failed to persist auto-ban: %s"):format(tostring(err)))
	end
	target:Kick("Banned: Automatically banned, 5 warnings reached.")
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
		local reason = if #ctx.Arguments > 0 then table.concat(ctx.Arguments, " ") else "No reason given."
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
