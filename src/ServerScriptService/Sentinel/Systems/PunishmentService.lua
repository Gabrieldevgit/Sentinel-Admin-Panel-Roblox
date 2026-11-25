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
		PunishmentService.AddWarningOffline(userId, issuer, reason): number?
		PunishmentService.GetWarnings(userId): {WarningRecord}
		PunishmentService.ClearWarnings(userId): boolean
		PunishmentService.SetWarnings(userId, list): boolean
		PunishmentService.PlanRemoval(list, "all"|"<n>"|"#i"|"#i-j") -> (kept, removed)
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

-- W08: data-driven escalation (admin config "WarningEscalation"). The
-- provider returns { { Count, Action, Duration? } }; actions are looked up
-- by name (registered by Commands/Moderation/Warn.lua: kick, ban, mute).
export type EscalationStep = { Count: number, Action: string, Duration: string? }
local policyProvider: (() -> { EscalationStep })? = nil
local escalationActions: { [string]: (Player, { WarningRecord }, EscalationStep) -> () } = {}

function PunishmentService.SetPolicyProvider(fn: (() -> { EscalationStep })?)
	policyProvider = fn
end

function PunishmentService.RegisterEscalationAction(name: string, fn: (Player, { WarningRecord }, EscalationStep) -> ())
	escalationActions[name] = fn
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

-- `issuer` only needs UserId and Name: a Player, or the identity of a staff
-- member on another server (cross-server ;gwarn).
function PunishmentService.AddWarning(target: Player, issuer: any, reason: string): { WarningRecord }
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

	if policyProvider then
		local ok, steps = pcall(policyProvider)
		if ok and type(steps) == "table" then
			for _, step in ipairs(steps) do
				local action = escalationActions[step.Action]
				if step.Count == #warnings and action then
					Logger.Write({
						Executor = "SYSTEM",
						ExecutorName = "SYSTEM",
						Command = "auto-escalation",
						Target = target.Name,
						Result = "Success",
						Severity = "Warning",
						Message = ("Escalation %s at %d warnings for %s"):format(step.Action, step.Count, target.Name),
					})
					task.spawn(action, target, warnings, step)
				end
			end
		end
	end

	return warnings
end

-- Warning for a player who is not in ANY server (cross-server ;gwarn). The
-- record is appended atomically; escalation rules need a Player object, so
-- they run on the next warning the player receives while online. Returns
-- the new warning count, or nil when the DataStore write failed.
function PunishmentService.AddWarningOffline(userId: number, issuer: any, reason: string): number?
	local count: number? = nil
	local ok, err = pcall(function()
		WarningStore:UpdateAsync(tostring(userId), function(old)
			local warnings = if type(old) == "table" then old else {}
			table.insert(warnings, {
				IssuedBy = issuer.UserId,
				IssuedByName = issuer.Name,
				Reason = reason,
				Timestamp = os.time(),
			})
			count = #warnings
			return warnings
		end)
	end)
	if not ok then
		warn(("[Sentinel.PunishmentService] offline warning for %d failed: %s"):format(userId, tostring(err)))
		return nil
	end
	cache[userId] = nil
	return count
end

function PunishmentService.ClearWarnings(userId: number): boolean
	return PunishmentService.SetWarnings(userId, {})
end

-- Replaces a player's whole warning list (clear / remove / undo). Returns
-- whether the DataStore write worked (the cache is updated either way).
function PunishmentService.SetWarnings(userId: number, warnings: { WarningRecord }): boolean
	cache[userId] = warnings
	local ok, err = pcall(function()
		WarningStore:SetAsync(tostring(userId), warnings)
	end)
	if not ok then
		warn(("[Sentinel.PunishmentService] failed to save warnings for %d: %s"):format(userId, tostring(err)))
		return false
	end
	EventBus.Publish("Player.WarningsChanged", userId, #warnings)
	return true
end

--[[
	Pure (Warnings.spec): which warnings to drop.
		spec "all"            every warning
		spec "<n>"            the newest n (n >= 1)
		spec "#<i>"           warning number i as ;warnings lists it (1 = oldest)
		spec "#<i>-<j>"       numbers i..j
	Returns (kept, removed) or (nil, error).
--]]
function PunishmentService.PlanRemoval(warnings: { WarningRecord }, spec: string): ({ WarningRecord }?, any)
	local total = #warnings
	if total == 0 then
		return nil, "has no warnings"
	end
	spec = tostring(spec):lower()
	local from, to
	if spec == "all" then
		from, to = 1, total
	elseif spec:match("^#%d+%-%d+$") then
		local a, b = spec:match("^#(%d+)%-(%d+)$")
		from, to = math.min(tonumber(a) :: number, tonumber(b) :: number), math.max(tonumber(a) :: number, tonumber(b) :: number)
	elseif spec:match("^#%d+$") then
		from = tonumber(spec:sub(2)) :: number
		to = from
	elseif spec:match("^%d+$") then
		local n = tonumber(spec) :: number
		if n < 1 then
			return nil, "the number must be at least 1"
		end
		n = math.min(n, total)
		from, to = total - n + 1, total
	else
		return nil, "give a number (newest n), #index, #from-to or all"
	end
	if from < 1 or to > total then
		return nil, ("only has %d warning(s)"):format(total)
	end
	local kept, removed = {}, {}
	for i, w in ipairs(warnings) do
		if i >= from and i <= to then
			table.insert(removed, w)
		else
			table.insert(kept, w)
		end
	end
	return kept, removed
end

-- W14 (accepted warn appeals): removes the one warning issued closest to
-- `at` (a case's CreatedAt), within 2 minutes. Returns whether one was removed.
function PunishmentService.RemoveWarningNear(userId: number, at: number): boolean
	local warnings = table.clone(PunishmentService.GetWarnings(userId))
	local best, bestGap = nil, 121
	for i, w in ipairs(warnings) do
		local gap = math.abs((w.Timestamp or 0) - at)
		if gap < bestGap then
			best, bestGap = i, gap
		end
	end
	if not best then
		return false
	end
	table.remove(warnings, best)
	persist(userId, warnings)
	return true
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
