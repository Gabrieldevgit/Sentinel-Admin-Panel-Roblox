--!strict
--[[
	PunishmentService.lua

	Purpose:
		Owns the warning/strike ledger for every player and applies
		automatic punishment escalation (e.g. 3 warnings -> auto-kick,
		5 warnings -> auto-ban) so the escalation policy lives in ONE place
		instead of being duplicated inside the /warn command.

	Responsibilities:
		- Persist warnings per player (DataStore, keyed by UserId)
		- Expose AddWarning / GetWarnings / ClearWarnings
		- Run escalation rules after every new warning and publish
		  EventBus topics other systems (or the Ban/Kick commands) react to
		- Escalation rules are data, not code — RegisterEscalationRule lets
		  Phase 9 (enterprise config) or a future admin UI change thresholds
		  without touching this module

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		Logger.lua (Core)

	Public API:
		PunishmentService.AddWarning(target, issuer, reason): {WarningRecord}
		PunishmentService.GetWarnings(userId): {WarningRecord}
		PunishmentService.ClearWarnings(userId): ()
		PunishmentService.RegisterEscalationRule(threshold, action): ()
			-- action: (target: Player, warnings: {WarningRecord}) -> ()

	Example usage:
		PunishmentService.RegisterEscalationRule(3, function(target)
			target:Kick("Automatically kicked: 3 warnings reached.")
		end)
		PunishmentService.AddWarning(target, moderator, "Spamming")
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local Logger = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Logger"))

local WarningStore = DataStoreService:GetDataStore("Sentinel_Warnings_v1")

export type WarningRecord = {
	IssuedBy: number,
	IssuedByName: string,
	Reason: string,
	Timestamp: number,
}

local PunishmentService = {}

-- Cache so we don't hit the DataStore on every read within one server's
-- lifetime; writes always go through immediately (correctness over
-- micro-optimizing the rare "warn" path).
local cache: { [number]: { WarningRecord } } = {}

local escalationRules: { { Threshold: number, Action: (Player, { WarningRecord }) -> () } } = {}

function PunishmentService.RegisterEscalationRule(threshold: number, action: (Player, { WarningRecord }) -> ())
	table.insert(escalationRules, { Threshold = threshold, Action = action })
	table.sort(escalationRules, function(a, b)
		return a.Threshold < b.Threshold
	end)
end

function PunishmentService.GetWarnings(userId: number): { WarningRecord }
	if cache[userId] then
		return cache[userId]
	end

	local ok, stored = pcall(function()
		return WarningStore:GetAsync(tostring(userId))
	end)

	local warnings: { WarningRecord } = if ok and stored then stored else {}
	cache[userId] = warnings
	return warnings
end

local function persist(userId: number, warnings: { WarningRecord })
	cache[userId] = warnings
	local ok, err = pcall(function()
		WarningStore:SetAsync(tostring(userId), warnings)
	end)
	if not ok then
		warn(("[Sentinel.PunishmentService] failed to persist warnings for %d: %s"):format(userId, tostring(err)))
	end
end

function PunishmentService.AddWarning(target: Player, issuer: Player, reason: string): { WarningRecord }
	local warnings = PunishmentService.GetWarnings(target.UserId)
	local record: WarningRecord = {
		IssuedBy = issuer.UserId,
		IssuedByName = issuer.Name,
		Reason = reason,
		Timestamp = os.time(),
	}
	table.insert(warnings, record)
	persist(target.UserId, warnings)

	EventBus.Publish("Player.Warned", target, issuer, record, warnings)

	-- Only fire the rule that exactly matches the new count, so escalation
	-- triggers exactly once per threshold crossed rather than re-firing
	-- every lower rule again on every subsequent warning.
	for _, rule in ipairs(escalationRules) do
		if #warnings == rule.Threshold then
			Logger.Write({
				Executor = "SYSTEM",
				ExecutorName = "SYSTEM",
				Command = "auto-escalation",
				Target = target.Name,
				Result = "Success",
				Severity = "Warning",
				Message = ("Escalation threshold %d reached for %s"):format(rule.Threshold, target.Name),
			})
			task.spawn(rule.Action, target, warnings)
		end
	end

	return warnings
end

function PunishmentService.ClearWarnings(userId: number)
	cache[userId] = {}
	local ok, err = pcall(function()
		WarningStore:SetAsync(tostring(userId), {})
	end)
	if not ok then
		warn(("[Sentinel.PunishmentService] failed to clear warnings for %d: %s"):format(userId, tostring(err)))
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	-- Warm the cache so /warnings and escalation checks don't pay a
	-- DataStore round trip the first time they're needed for this player.
	task.spawn(PunishmentService.GetWarnings, player.UserId)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	cache[player.UserId] = nil
end)

return PunishmentService
