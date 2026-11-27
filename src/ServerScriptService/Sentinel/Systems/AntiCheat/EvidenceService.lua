--!strict
--[[
	EvidenceService.lua (Sentinel AntiCheat)

	Purpose:
		Stores a snapshot with every flag and keeps the flag history.
		  - Position samples: the last 10 seconds of server-side root
		    positions per player (fed by DetectionEngine's sampler).
		  - Snapshot(player, extra): samples, ping, server FPS, the active
		    exemptions and the module's own evidence.
		  - Flags: recent flags of this server (memory, newest first, max
		    MAX_RECENT) plus flags shared by other servers (Server column).
		    Each player's flags are also saved to Sentinel_AC_Flags_v1 (one
		    key per UserId, capped to Storage.HistoryLength and
		    Storage.RetentionDays, batched by AntiCheatStore).
		  - Counters for the Overview sparkline and Analytics charts
		    (per-minute for an hour, per-hour for 7 days, by module).

	Public API:
		EvidenceService.AddSample(userId, t, position, velocity?)
		EvidenceService.Samples(userId, seconds?) -> { {T, X, Y, Z} }
		EvidenceService.Snapshot(player, extra?, active?) -> evidence
		EvidenceService.Record(flag, storageCfg?)
		EvidenceService.RecordRemote(flag)          -- from another server
		EvidenceService.Get(id) / List(filter?, limit?) / ForPlayer(userId, limit?)
		EvidenceService.MarkReviewed(ids, by) -> count
		EvidenceService.SetFalsePositive(id, on, by) -> flag?
		EvidenceService.Unreviewed(minSeverity?) -> count
		EvidenceService.LoadHistory(userId) -> { flag } (yields)
		EvidenceService.PerMinute() -> { number }  (60 values, oldest first)
		EvidenceService.Counts(hours, modules?) -> { ByModule, ByHour, Total }
		EvidenceService.Flush() / Health() / Forget(userId) / _Clear()
--]]

local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local AntiCheatStore = require(script.Parent:WaitForChild("AntiCheatStore"))

local EvidenceService = {}

EvidenceService.MAX_RECENT = 1000
EvidenceService.MAX_REMOTE = 300
local SAMPLE_SECONDS = 10
local SAMPLE_MAX = 80

local store = AntiCheatStore.new("Sentinel_AC_Flags_v1")

local samples: { [number]: { any } } = {}
local recent: { any } = {} -- newest first
local byId: { [string]: any } = {}
local minuteBuckets: { [number]: number } = {} -- minute index -> count
local hourBuckets: { [number]: { [string]: number } } = {} -- hour index -> module -> count

local function round(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

function EvidenceService.AddSample(userId: number, t: number, position: Vector3, velocity: Vector3?)
	local list = samples[userId]
	if not list then
		list = {}
		samples[userId] = list
	end
	table.insert(list, { T = t, P = position, V = velocity })
	while #list > SAMPLE_MAX or (#list > 1 and t - list[1].T > SAMPLE_SECONDS) do
		table.remove(list, 1)
	end
end

-- Raw samples (oldest first) for module checks.
function EvidenceService.RawSamples(userId: number): { any }
	return samples[userId] or {}
end

function EvidenceService.Samples(userId: number, seconds: number?): { any }
	local list = samples[userId] or {}
	local out = {}
	local last = list[#list]
	if not last then
		return out
	end
	local window = seconds or SAMPLE_SECONDS
	for _, s in ipairs(list) do
		if last.T - s.T <= window then
			table.insert(out, { T = round(s.T - last.T), X = round(s.P.X), Y = round(s.P.Y), Z = round(s.P.Z) })
		end
	end
	return out
end

local function serverFps(): number
	local ok, fps = pcall(function()
		return Workspace:GetRealPhysicsFPS()
	end)
	return if ok and type(fps) == "number" then math.floor(fps + 0.5) else 60
end
EvidenceService.ServerFps = serverFps

function EvidenceService.Snapshot(player: any, extra: any?, active: { string }?): any
	local ping = 0
	pcall(function()
		ping = math.floor(player:GetNetworkPing() * 1000 + 0.5)
	end)
	local memory = 0
	pcall(function()
		memory = math.floor(Stats:GetTotalMemoryUsageMb())
	end)
	return {
		Samples = EvidenceService.Samples(player.UserId),
		Ping = ping,
		ServerFps = serverFps(),
		MemoryMb = memory,
		Exemptions = active or {},
		Details = extra,
	}
end

-- ---------------------------------------------------------------------------
-- Flags
-- ---------------------------------------------------------------------------
local function count(flag: any)
	local minute = flag.Time // 60
	minuteBuckets[minute] = (minuteBuckets[minute] or 0) + 1
	local hour = flag.Time // 3600
	local bucket = hourBuckets[hour]
	if not bucket then
		bucket = {}
		hourBuckets[hour] = bucket
	end
	bucket[flag.Module] = (bucket[flag.Module] or 0) + 1
	-- Drop counters older than 7 days / 1 hour.
	for h in pairs(hourBuckets) do
		if h < hour - 24 * 7 then
			hourBuckets[h] = nil
		end
	end
	for m in pairs(minuteBuckets) do
		if m < minute - 60 then
			minuteBuckets[m] = nil
		end
	end
end

local function insertRecent(flag: any)
	table.insert(recent, 1, flag)
	byId[flag.Id] = flag
	while #recent > EvidenceService.MAX_RECENT + EvidenceService.MAX_REMOTE do
		local old = table.remove(recent)
		if old then
			byId[old.Id] = nil
		end
	end
end

-- A compact copy for the DataStore (evidence samples trimmed).
local function storable(flag: any): any
	local copy = table.clone(flag)
	copy.Remote = nil
	if type(copy.Evidence) == "table" then
		local e = table.clone(copy.Evidence)
		if type(e.Samples) == "table" and #e.Samples > 30 then
			local trimmed = {}
			for i = #e.Samples - 29, #e.Samples do
				table.insert(trimmed, e.Samples[i])
			end
			e.Samples = trimmed
		end
		copy.Evidence = e
	end
	return copy
end

function EvidenceService.Record(flag: any, storageCfg: any?)
	insertRecent(flag)
	count(flag)
	local history = if storageCfg then storageCfg.HistoryLength else 200
	local retention = (if storageCfg then storageCfg.RetentionDays else 30) * 86400
	local saved = storable(flag)
	store:Queue(tostring(flag.UserId), function(old: any)
		local data = if type(old) == "table" then old else {}
		local list = if type(data.Flags) == "table" then data.Flags else {}
		table.insert(list, 1, saved)
		local cutoff = os.time() - retention
		for i = #list, 1, -1 do
			if i > history or (tonumber(list[i].Time) or 0) < cutoff then
				table.remove(list, i)
			end
		end
		data.Flags = list
		data.Name = flag.Name
		return data
	end)
end

-- Flags other servers share (cross-server): shown, not stored again.
function EvidenceService.RecordRemote(flag: any)
	if type(flag) ~= "table" or type(flag.Id) ~= "string" or byId[flag.Id] then
		return
	end
	flag.Remote = true
	insertRecent(flag)
end

-- Persist the reviewed / false-positive state of a stored flag.
local function persistMark(flag: any)
	if flag.Remote then
		return
	end
	local id, reviewed, fp = flag.Id, flag.Reviewed, flag.FalsePositive
	store:Queue(tostring(flag.UserId), function(old: any)
		if type(old) == "table" and type(old.Flags) == "table" then
			for _, f in ipairs(old.Flags) do
				if f.Id == id then
					f.Reviewed = reviewed
					f.FalsePositive = fp
				end
			end
		end
		return old
	end)
end

function EvidenceService.Get(id: string): any
	return byId[id]
end

-- filter = { Module?, MinSeverity?, MaxSeverity?, UserId?, Player? (name
-- part), Since? (os.time), Server?, Unreviewed? }
function EvidenceService.Matches(flag: any, filter: any?): boolean
	if not filter then
		return true
	end
	if filter.Module and filter.Module ~= "" and flag.Module ~= filter.Module then
		return false
	end
	if filter.Modules and type(filter.Modules) == "table" and next(filter.Modules) and not filter.Modules[flag.Module] then
		return false
	end
	if filter.MinSeverity and flag.Severity < filter.MinSeverity then
		return false
	end
	if filter.MaxSeverity and flag.Severity > filter.MaxSeverity then
		return false
	end
	if filter.UserId and flag.UserId ~= filter.UserId then
		return false
	end
	if filter.Player and filter.Player ~= "" and not tostring(flag.Name):lower():find(filter.Player:lower(), 1, true) then
		return false
	end
	if filter.Since and flag.Time < filter.Since then
		return false
	end
	if filter.Server and filter.Server ~= "" and not tostring(flag.Server):find(filter.Server, 1, true) then
		return false
	end
	if filter.Unreviewed and flag.Reviewed then
		return false
	end
	return true
end

function EvidenceService.List(filter: any?, limit: number?): { any }
	local out = {}
	local max = limit or 500
	for _, flag in ipairs(recent) do
		if EvidenceService.Matches(flag, filter) then
			table.insert(out, flag)
			if #out >= max then
				break
			end
		end
	end
	return out
end

function EvidenceService.ForPlayer(userId: number, limit: number?): { any }
	return EvidenceService.List({ UserId = userId }, limit or 100)
end

function EvidenceService.MarkReviewed(ids: { string }, by: string): number
	local n = 0
	for _, id in ipairs(ids) do
		local flag = byId[id]
		if flag and not flag.Reviewed then
			flag.Reviewed = true
			flag.ReviewedBy = by
			n += 1
			persistMark(flag)
		end
	end
	return n
end

function EvidenceService.SetFalsePositive(id: string, on: boolean, by: string): any
	local flag = byId[id]
	if not flag then
		return nil
	end
	flag.FalsePositive = if on then true else nil
	flag.Reviewed = true
	flag.ReviewedBy = by
	persistMark(flag)
	return flag
end

function EvidenceService.Unreviewed(minSeverity: number?): number
	local n = 0
	for _, flag in ipairs(recent) do
		if not flag.Reviewed and not flag.Remote and flag.Severity >= (minSeverity or 0) then
			n += 1
		end
	end
	return n
end

function EvidenceService.LoadHistory(userId: number): { any }
	local data = store:Read(tostring(userId))
	if type(data) == "table" and type(data.Flags) == "table" then
		return data.Flags
	end
	return {}
end

-- Flags per minute over the last hour (60 values, oldest first).
function EvidenceService.PerMinute(): { number }
	local now = os.time() // 60
	local out = {}
	for m = now - 59, now do
		table.insert(out, minuteBuckets[m] or 0)
	end
	return out
end

-- Local flag counts over the last `hours` (this server).
function EvidenceService.Counts(hours: number, modules: { [string]: boolean }?): any
	local nowHour = os.time() // 3600
	local byModule: { [string]: number } = {}
	local byHour = {}
	local total = 0
	for h = nowHour - hours + 1, nowHour do
		local n = 0
		for module, c in pairs(hourBuckets[h] or {}) do
			if not modules or not next(modules) or modules[module] then
				byModule[module] = (byModule[module] or 0) + c
				n += c
			end
		end
		table.insert(byHour, { Hour = h * 3600, Count = n })
		total += n
	end
	return { ByModule = byModule, ByHour = byHour, Total = total }
end

function EvidenceService.Forget(userId: number)
	samples[userId] = nil
end

function EvidenceService.Flush(): number
	return store:Flush(15)
end

function EvidenceService.Health(): any
	return store:Health()
end

function EvidenceService._Clear()
	table.clear(samples)
	table.clear(recent)
	table.clear(byId)
	table.clear(minuteBuckets)
	table.clear(hourBuckets)
end

return EvidenceService
