--!strict
--[[
	ExemptionService.lua (Sentinel AntiCheat)

	Purpose:
		Everything that keeps honest players from being flagged:
		  - Grace windows: after spawn, respawn, teleport, seat exit and
		    character load (Grace.* config), per scope ("all", "movement" or
		    one module). Known teleports (Sentinel commands, server scripts
		    setting the character's CFrame) call MarkGrace.
		  - Staff rank exemption: players at or above Core.ExemptRank are not
		    checked at all (the rank check is a provider set by
		    AntiCheatService so this file stays pure).
		  - Per-player exemptions: one module or "all", with a reason, who
		    added it and an expiry (nil = permanent).
		  - Testing mode: every check still runs but only logs.
		  - Watch list: staff follow a player; an alert fires when a watched
		    player joins any server (Alerts.WatchAlerts).

		Exemptions and the watch entry persist per player in
		Sentinel_AC_Exemptions_v1 (one key per UserId, batched writes via
		AntiCheatStore). Testing mode and grace windows are session only.

	Public API:
		ExemptionService.MOVEMENT       -- modules covered by the "movement" scope
		ExemptionService.MarkGrace(userId, seconds, scope?, reason?)
		ExemptionService.InGrace(userId, module, now?) -> (boolean, reason?)
		ExemptionService.SetRankProvider(fn(userId) -> (boolean, rankName?))
		ExemptionService.Check(userId, module, now?) -> (skip: boolean, reason?)
		ExemptionService.Add(userId, name, module, seconds?, reason, by) -> (exemption?, err?)
		ExemptionService.Remove(userId, module?) -> { exemption }
		ExemptionService.RemoveById(id) -> exemption?
		ExemptionService.Extend(id, seconds) -> (exemption?, err?)
		ExemptionService.Restore(exemption)            -- undo of a removal
		ExemptionService.List() / ForPlayer(userId)
		ExemptionService.RankExempt(userId) -> boolean
		ExemptionService.SetTesting(userId, on, by?) / IsTesting(userId) / TestingList()
		ExemptionService.Watch(userId, name, why, by) / Unwatch(userId) / IsWatched / WatchList()
		ExemptionService.Active(userId) -> { string }   -- for evidence snapshots
		ExemptionService.Load(userId) (yields) / Flush() / Health()
		ExemptionService._Clear()
--]]

local HttpService = game:GetService("HttpService")

local AntiCheatStore = require(script.Parent:WaitForChild("AntiCheatStore"))

local ExemptionService = {}

ExemptionService.MOVEMENT = {
	SpeedCheck = true,
	FlyCheck = true,
	TeleportCheck = true,
	NoclipCheck = true,
	JumpCheck = true,
}

local store = AntiCheatStore.new("Sentinel_AC_Exemptions_v1")

local grace: { [number]: { [string]: { Until: number, Reason: string } } } = {}
local exemptions: { [number]: { any } } = {}
local testing: { [number]: { By: string, At: number } } = {}
local watch: { [number]: any } = {}
local names: { [number]: string } = {}
local rankProvider: ((number) -> (boolean, string?))? = nil

-- ---------------------------------------------------------------------------
-- Grace windows
-- ---------------------------------------------------------------------------
function ExemptionService.MarkGrace(userId: number, seconds: number, scope: string?, reason: string?)
	if seconds <= 0 then
		return
	end
	local g = grace[userId]
	if not g then
		g = {}
		grace[userId] = g
	end
	local key = scope or "all"
	local untilAt = os.clock() + seconds
	local current = g[key]
	if not current or current.Until < untilAt then
		g[key] = { Until = untilAt, Reason = reason or key }
	end
end

function ExemptionService.InGrace(userId: number, module: string, now: number?): (boolean, string?)
	local g = grace[userId]
	if not g then
		return false, nil
	end
	local t = now or os.clock()
	for _, key in ipairs({ "all", module, if ExemptionService.MOVEMENT[module] then "movement" else "" }) do
		local w = g[key]
		if w and w.Until > t then
			return true, "grace: " .. w.Reason
		end
	end
	return false, nil
end

-- ---------------------------------------------------------------------------
-- Exemptions
-- ---------------------------------------------------------------------------
local function expired(e: any, now: number): boolean
	return e.ExpiresAt ~= nil and e.ExpiresAt <= now
end

local function prune(userId: number)
	local list = exemptions[userId]
	if not list then
		return
	end
	local now = os.time()
	for i = #list, 1, -1 do
		if expired(list[i], now) then
			table.remove(list, i)
		end
	end
end

local function persist(userId: number)
	local list = exemptions[userId] or {}
	local entry = watch[userId]
	local snapshot = { Exemptions = table.clone(list), Watch = if entry then table.clone(entry) else nil, Name = names[userId] }
	store:Queue(tostring(userId), function(_old: any)
		return snapshot
	end)
end

function ExemptionService.SetRankProvider(fn: ((number) -> (boolean, string?))?)
	rankProvider = fn
end

-- Is the player exempt by staff rank (Core.ExemptRank)?
function ExemptionService.RankExempt(userId: number): boolean
	if not rankProvider then
		return false
	end
	local ok, exempt = pcall(rankProvider :: any, userId)
	return ok and exempt == true
end

-- Should this module skip this player entirely right now?
function ExemptionService.Check(userId: number, module: string, now: number?): (boolean, string?)
	if rankProvider then
		local ok, exempt, rank = pcall(rankProvider :: any, userId)
		if ok and exempt then
			return true, "staff rank " .. tostring(rank or "")
		end
	end
	local list = exemptions[userId]
	if list then
		local t = os.time()
		for _, e in ipairs(list) do
			if not expired(e, t) and (e.Module == "all" or e.Module == module) then
				return true, ("exempt (%s): %s"):format(e.Module, e.Reason)
			end
		end
	end
	return ExemptionService.InGrace(userId, module, now)
end

function ExemptionService.Add(userId: number, name: string, module: string, seconds: number?, reason: string, by: string): (any, string?)
	if type(userId) ~= "number" or userId == 0 or userId % 1 ~= 0 then
		return nil, "invalid player"
	end
	if type(reason) ~= "string" or reason:gsub("%s", "") == "" then
		return nil, "a reason is required"
	end
	if seconds ~= nil and (type(seconds) ~= "number" or seconds <= 0 or seconds ~= seconds) then
		return nil, "invalid duration"
	end
	names[userId] = name
	local list = exemptions[userId]
	if not list then
		list = {}
		exemptions[userId] = list
	end
	prune(userId)
	if #list >= 30 then
		return nil, "this player already has 30 exemptions"
	end
	local e = {
		Id = HttpService:GenerateGUID(false):sub(1, 8):lower(),
		UserId = userId,
		Name = name,
		Module = module,
		Reason = reason:sub(1, 200),
		By = by,
		At = os.time(),
		ExpiresAt = if seconds then os.time() + math.floor(seconds) else nil,
	}
	table.insert(list, e)
	persist(userId)
	return table.clone(e), nil
end

-- Removes the player's exemptions for one module (nil = all of them).
function ExemptionService.Remove(userId: number, module: string?): { any }
	local list = exemptions[userId]
	local removed = {}
	if not list then
		return removed
	end
	for i = #list, 1, -1 do
		if module == nil or list[i].Module == module then
			table.insert(removed, table.remove(list, i))
		end
	end
	if #removed > 0 then
		persist(userId)
	end
	return removed
end

local function findById(id: string): (any, number?, number?)
	for userId, list in pairs(exemptions) do
		for i, e in ipairs(list) do
			if e.Id == id then
				return e, userId, i
			end
		end
	end
	return nil, nil, nil
end

function ExemptionService.RemoveById(id: string): any
	local e, userId, index = findById(id)
	if e and userId and index then
		table.remove(exemptions[userId], index)
		persist(userId)
		return e
	end
	return nil
end

function ExemptionService.Extend(id: string, seconds: number): (any, string?)
	local e, userId = findById(id)
	if not e or not userId then
		return nil, "no exemption with that id"
	end
	if type(seconds) ~= "number" or seconds <= 0 then
		return nil, "invalid duration"
	end
	if e.ExpiresAt == nil then
		return nil, "that exemption is permanent"
	end
	e.ExpiresAt = math.max(e.ExpiresAt, os.time()) + math.floor(seconds)
	persist(userId)
	return table.clone(e), nil
end

-- Puts back an exemption (undo of Remove), keeping its id.
function ExemptionService.Restore(e: any)
	if type(e) ~= "table" or type(e.UserId) ~= "number" then
		return
	end
	local list = exemptions[e.UserId]
	if not list then
		list = {}
		exemptions[e.UserId] = list
	end
	table.insert(list, table.clone(e))
	persist(e.UserId)
end

function ExemptionService.ForPlayer(userId: number): { any }
	prune(userId)
	local out = {}
	for _, e in ipairs(exemptions[userId] or {}) do
		table.insert(out, table.clone(e))
	end
	return out
end

function ExemptionService.List(): { any }
	local out = {}
	for userId in pairs(exemptions) do
		for _, e in ipairs(ExemptionService.ForPlayer(userId)) do
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return a.At > b.At
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- Testing mode (session only)
-- ---------------------------------------------------------------------------
function ExemptionService.SetTesting(userId: number, on: boolean, by: string?)
	testing[userId] = if on then { By = by or "?", At = os.time() } else nil
end

function ExemptionService.IsTesting(userId: number): boolean
	return testing[userId] ~= nil
end

function ExemptionService.TestingList(): { [number]: any }
	return table.clone(testing)
end

-- ---------------------------------------------------------------------------
-- Watch list
-- ---------------------------------------------------------------------------
function ExemptionService.Watch(userId: number, name: string, why: string, by: string): any
	names[userId] = name
	local entry = { UserId = userId, Name = name, Since = os.time(), Why = (why or ""):sub(1, 200), By = by }
	watch[userId] = entry
	persist(userId)
	return table.clone(entry)
end

function ExemptionService.Unwatch(userId: number): any
	local old = watch[userId]
	watch[userId] = nil
	if old then
		persist(userId)
	end
	return old
end

function ExemptionService.IsWatched(userId: number): boolean
	return watch[userId] ~= nil
end

function ExemptionService.GetWatch(userId: number): any
	return if watch[userId] then table.clone(watch[userId]) else nil
end

function ExemptionService.WatchList(): { any }
	local out = {}
	for _, entry in pairs(watch) do
		table.insert(out, table.clone(entry))
	end
	table.sort(out, function(a, b)
		return a.Since > b.Since
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- Evidence + persistence
-- ---------------------------------------------------------------------------
function ExemptionService.Active(userId: number): { string }
	local out = {}
	local now = os.clock()
	for key, w in pairs(grace[userId] or {}) do
		if w.Until > now then
			table.insert(out, ("grace %s (%.1fs left)"):format(key, w.Until - now))
		end
	end
	for _, e in ipairs(ExemptionService.ForPlayer(userId)) do
		table.insert(out, ("exempt %s: %s"):format(e.Module, e.Reason))
	end
	if testing[userId] then
		table.insert(out, "testing mode")
	end
	table.sort(out)
	return out
end

-- Loads a joining player's stored exemptions + watch entry (yields).
-- Returns the watch entry when the player is watched.
function ExemptionService.Load(userId: number, name: string?): any
	if name then
		names[userId] = name
	end
	local data, ok = store:Read(tostring(userId))
	if ok and type(data) == "table" then
		if type(data.Exemptions) == "table" then
			local list = {}
			local now = os.time()
			for _, e in ipairs(data.Exemptions) do
				if type(e) == "table" and type(e.Module) == "string" and not expired(e, now) then
					table.insert(list, e)
				end
			end
			-- Merge with anything added this session before the load finished.
			for _, e in ipairs(exemptions[userId] or {}) do
				table.insert(list, e)
			end
			exemptions[userId] = list
		end
		if type(data.Watch) == "table" and watch[userId] == nil then
			watch[userId] = data.Watch
		end
	end
	return watch[userId]
end

-- Session cleanup when the player leaves (stored data stays).
function ExemptionService.Forget(userId: number)
	grace[userId] = nil
	testing[userId] = nil
end

function ExemptionService.Flush(): number
	return store:Flush(10)
end

function ExemptionService.Health(): any
	return store:Health()
end

function ExemptionService._Clear()
	table.clear(grace)
	table.clear(exemptions)
	table.clear(testing)
	table.clear(watch)
	rankProvider = nil
end

return ExemptionService
