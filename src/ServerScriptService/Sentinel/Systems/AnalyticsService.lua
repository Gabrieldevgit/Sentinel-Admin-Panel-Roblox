--!strict
--[[
	AnalyticsService.lua (W16 - Analytics)

	Persisted metrics in hourly buckets, merged across every server.

	What is counted (per hour):
		players    PMax (peak on one server), PSum / PN (average), GMax (peak
		           across all servers, from CrossServerService totals)
		staff      SMax, SSum / SN (staff online), StaffCmd (commands run by staff)
		perf       FSum / FN / FMin (server heartbeat FPS), MSum / MN / MMax
		           (memory MB), GSum / GN (average player ping ms)
		commands   CS (success), CF (failure), CD (denied), CC (cancelled)
		moderation Mod (successful moderation.* commands)
		economy    ETx (leaderstat changes), EVol (absolute amount moved)
	Per day: Cmd = { [command] = count }, Mods = { [userId] = { N, C } },
	Econ = { [stat] = volume }, Srv = { [serverId] = lastSeen }.

	Sources: EventBus "Log.Written" (every command, denial and failure the
	Logger records), a 30 s sampler (players, staff, FPS, memory, ping) and
	leaderstat .Changed watchers (ignores the first 10 s after a join, when
	game data loads).

	Storage: DataStore `Sentinel_Analytics_v1`, key `Day_<YYYYMMDD>` (UTC).
	Each server keeps pending deltas and merges them with UpdateAsync every
	60 s and on close (counts add, peaks max, minimums min) - so the stored
	day is the cross-server total. This server's own buckets stay in memory
	(7 days) for the "This server" scope.

	Public API:
		AnalyticsService.Query(options) -> report
			options = { Range = "24h"|"7d"|"30d"|"custom", From, To
			("YYYY-MM-DD"), Scope = "all"|"server", Compare = bool }
		AnalyticsService.Live() -> current values (players, staff, uptime,
			fps, memory, ping, active punishments, recent moderation)
		AnalyticsService.Flush()
	Pure helpers (Analytics.spec): NewBucket, MergeBucket, MergeDay,
	ParseRange, Rollup, Totals, TopN, DayKey, PctChange.
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local Sentinel = script.Parent.Parent
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))

local AnalyticsService = {}

local LIVE = RunService:IsServer() and RunService:IsRunning()
local STORE_NAME = "Sentinel_Analytics_v1"
local HOUR = 3600
local DAY = 86400
local MEMORY_HOURS = 7 * 24
local MAX_RANGE_DAYS = 90
local TOP_KEEP = 60 -- per-day map entries kept (commands / moderators / stats)
local SAMPLE_EVERY = 30
local FLUSH_EVERY = 60
local JOIN_QUIET = 10

local SUM_FIELDS = { "PSum", "PN", "SSum", "SN", "StaffCmd", "FSum", "FN", "MSum", "MN", "GSum", "GN", "CS", "CF", "CD", "CC", "Mod", "ETx", "EVol" }
local MAX_FIELDS = { "PMax", "GMax", "SMax", "MMax" }
local MIN_FIELDS = { "FMin" }

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------
function AnalyticsService.NewBucket(t: number): { [string]: number }
	local b: { [string]: number } = { T = t }
	for _, k in ipairs(SUM_FIELDS) do
		b[k] = 0
	end
	for _, k in ipairs(MAX_FIELDS) do
		b[k] = 0
	end
	return b
end

-- Merges bucket `src` into `dst` (mutates and returns dst).
function AnalyticsService.MergeBucket(dst: { [string]: number }, src: { [string]: any }): { [string]: number }
	for _, k in ipairs(SUM_FIELDS) do
		dst[k] = (tonumber(dst[k]) or 0) + (tonumber(src[k]) or 0)
	end
	for _, k in ipairs(MAX_FIELDS) do
		dst[k] = math.max(tonumber(dst[k]) or 0, tonumber(src[k]) or 0)
	end
	for _, k in ipairs(MIN_FIELDS) do
		local a, b = tonumber(dst[k]), tonumber(src[k])
		if a and b then
			dst[k] = math.min(a, b)
		else
			dst[k] = a or b :: any
		end
	end
	return dst
end

local function trimMap(map: { [string]: any }, score: (any) -> number, keep: number)
	local list = {}
	for k, v in pairs(map) do
		table.insert(list, { k, score(v) })
	end
	if #list <= keep then
		return
	end
	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)
	for i = keep + 1, #list do
		map[list[i][1]] = nil
	end
end

-- Merges a day record (delta) into another (stored). Both may be nil.
function AnalyticsService.MergeDay(stored: any, delta: any): any
	local out = if type(stored) == "table" then stored else { V = 1 }
	out.V = 1
	out.H = if type(out.H) == "table" then out.H else {}
	out.Cmd = if type(out.Cmd) == "table" then out.Cmd else {}
	out.Mods = if type(out.Mods) == "table" then out.Mods else {}
	out.Econ = if type(out.Econ) == "table" then out.Econ else {}
	out.Srv = if type(out.Srv) == "table" then out.Srv else {}
	if type(delta) ~= "table" then
		return out
	end
	for h, b in pairs(delta.H or {}) do
		local key = tostring(h)
		local dst = out.H[key]
		if type(dst) ~= "table" then
			dst = AnalyticsService.NewBucket(tonumber(b.T) or 0)
			out.H[key] = dst
		end
		AnalyticsService.MergeBucket(dst, b)
	end
	for name, n in pairs(delta.Cmd or {}) do
		out.Cmd[name] = (tonumber(out.Cmd[name]) or 0) + (tonumber(n) or 0)
	end
	for uid, m in pairs(delta.Mods or {}) do
		local cur = out.Mods[uid]
		if type(cur) ~= "table" then
			cur = { N = m.N, C = 0 }
			out.Mods[uid] = cur
		end
		cur.N = m.N or cur.N
		cur.C = (tonumber(cur.C) or 0) + (tonumber(m.C) or 0)
	end
	for stat, v in pairs(delta.Econ or {}) do
		out.Econ[stat] = (tonumber(out.Econ[stat]) or 0) + (tonumber(v) or 0)
	end
	for id, at in pairs(delta.Srv or {}) do
		out.Srv[id] = math.max(tonumber(out.Srv[id]) or 0, tonumber(at) or 0)
	end
	trimMap(out.Cmd, function(v)
		return tonumber(v) or 0
	end, TOP_KEEP)
	trimMap(out.Mods, function(v)
		return tonumber(v.C) or 0
	end, TOP_KEEP)
	trimMap(out.Econ, function(v)
		return tonumber(v) or 0
	end, 20)
	trimMap(out.Srv, function(v)
		return tonumber(v) or 0
	end, 200)
	return out
end

function AnalyticsService.DayKey(t: number): string
	return "Day_" .. os.date("!%Y%m%d", t)
end

local function dayStart(t: number): number
	return t - t % DAY
end

local function parseDate(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local y, m, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
	if not y then
		return nil
	end
	local year, month, dayN = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if month < 1 or month > 12 or dayN < 1 or dayN > 31 or year < 2020 or year > 2100 then
		return nil
	end
	-- days from civil (UTC, no os.time local-time surprises)
	local yy = if month <= 2 then year - 1 else year
	local era = yy // 400
	local yoe = yy - era * 400
	local mp = (month + 9) % 12
	local doy = (153 * mp + 2) // 5 + dayN - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return (era * 146097 + doe - 719468) * DAY
end

--[[
	ParseRange(range, from, to, now) -> { From, To, Step, Label } | (nil, err)
	From inclusive, To exclusive (epoch seconds, hour aligned).
	Step: 1 h for <= 2 days, 6 h for <= 14 days, else 24 h.
--]]
function AnalyticsService.ParseRange(range: any, from: any, to: any, now: number): (any, string?)
	local hourNow = now - now % HOUR + HOUR -- end of the current hour
	local r = if type(range) == "string" then range:lower() else "24h"
	local a: number, b: number
	local label: string
	if r == "custom" or (r:match("^%d%d%d%d%-") ~= nil) then
		local f = parseDate(if r == "custom" then from else r)
		local tt = parseDate(if r == "custom" then (to or from) else (to or r))
		if not f or not tt then
			return nil, "Dates must look like 2026-11-24."
		end
		if tt < f then
			f, tt = tt, f
		end
		a, b = f, math.min(tt + DAY, hourNow)
		if b <= a then
			return nil, "That range is in the future."
		end
		label = ("%s to %s"):format(os.date("!%Y-%m-%d", f), os.date("!%Y-%m-%d", tt))
	else
		local n, unit = r:match("^(%d+)%s*([hdw])$")
		if r == "today" then
			n, unit = "0", "t"
		end
		if not n then
			return nil, "Range must be 24h, 7d, 30d, today or custom dates."
		end
		local seconds
		if unit == "t" then
			seconds = hourNow - dayStart(now)
			label = "Today"
		else
			local mult = if unit == "h" then HOUR elseif unit == "d" then DAY else 7 * DAY
			seconds = (tonumber(n) :: number) * mult
			label = "Last " .. r
		end
		if seconds < HOUR then
			return nil, "Range must be at least 1 hour."
		end
		a, b = hourNow - seconds, hourNow
	end
	if b - a > MAX_RANGE_DAYS * DAY then
		return nil, ("Range can be at most %d days."):format(MAX_RANGE_DAYS)
	end
	local span = b - a
	local step = if span <= 2 * DAY then HOUR elseif span <= 14 * DAY then 6 * HOUR else DAY
	return { From = a, To = b, Step = step, Label = label }
end

local function avg(sum: any, n: any): number?
	n = tonumber(n) or 0
	if n <= 0 then
		return nil
	end
	return (tonumber(sum) or 0) / n
end

--[[
	Rollup(hours, range) -> series
	`hours` = { [hourStart] = bucket }. One point per Step between From and
	To, each a flat table the client can graph.
--]]
function AnalyticsService.Rollup(hours: { [number]: any }, range: any): { any }
	local series = {}
	local t = range.From
	while t < range.To do
		local acc = AnalyticsService.NewBucket(t)
		local h = t
		while h < t + range.Step and h < range.To do
			local b = hours[h]
			if b then
				AnalyticsService.MergeBucket(acc, b)
			end
			h += HOUR
		end
		table.insert(series, {
			T = t,
			Players = acc.PMax,
			PlayersAvg = avg(acc.PSum, acc.PN),
			Global = acc.GMax,
			Staff = acc.SMax,
			StaffAvg = avg(acc.SSum, acc.SN),
			StaffCmd = acc.StaffCmd,
			Fps = avg(acc.FSum, acc.FN),
			FpsMin = acc.FMin,
			Memory = avg(acc.MSum, acc.MN),
			MemoryMax = acc.MMax,
			Ping = avg(acc.GSum, acc.GN),
			Success = acc.CS,
			Failed = acc.CF,
			Denied = acc.CD,
			Cancelled = acc.CC,
			Commands = acc.CS + acc.CF + acc.CD + acc.CC,
			Moderation = acc.Mod,
			Economy = acc.ETx,
			EconomyVolume = acc.EVol,
			HasData = acc.PN > 0 or acc.CS + acc.CF + acc.CD + acc.CC > 0 or acc.ETx > 0,
		})
		t += range.Step
	end
	return series
end

function AnalyticsService.Totals(series: { any }): { [string]: number }
	local out = { Commands = 0, Success = 0, Failed = 0, Denied = 0, Cancelled = 0, Moderation = 0, StaffCmd = 0, Economy = 0, EconomyVolume = 0, Peak = 0, GlobalPeak = 0, StaffPeak = 0 }
	local fpsSum, fpsN, pingSum, pingN, memSum, memN, plSum, plN = 0, 0, 0, 0, 0, 0, 0, 0
	for _, p in ipairs(series) do
		for _, k in ipairs({ "Commands", "Success", "Failed", "Denied", "Cancelled", "Moderation", "StaffCmd", "Economy", "EconomyVolume" }) do
			out[k] += p[k] or 0
		end
		out.Peak = math.max(out.Peak, p.Players or 0)
		out.GlobalPeak = math.max(out.GlobalPeak, p.Global or 0)
		out.StaffPeak = math.max(out.StaffPeak, p.Staff or 0)
		if p.Fps then
			fpsSum += p.Fps
			fpsN += 1
		end
		if p.Ping then
			pingSum += p.Ping
			pingN += 1
		end
		if p.Memory then
			memSum += p.Memory
			memN += 1
		end
		if p.PlayersAvg then
			plSum += p.PlayersAvg
			plN += 1
		end
	end
	out.SuccessRate = if out.Commands > 0 then math.floor(out.Success / out.Commands * 1000 + 0.5) / 10 else 100
	out.Fps = if fpsN > 0 then math.floor(fpsSum / fpsN * 10 + 0.5) / 10 else 0
	out.Ping = if pingN > 0 then math.floor(pingSum / pingN + 0.5) else 0
	out.Memory = if memN > 0 then math.floor(memSum / memN + 0.5) else 0
	out.PlayersAvg = if plN > 0 then math.floor(plSum / plN * 10 + 0.5) / 10 else 0
	return out
end

function AnalyticsService.TopN(map: { [string]: any }, n: number, score: ((any) -> number)?): { any }
	local list = {}
	for k, v in pairs(map) do
		table.insert(list, { Key = k, Value = v, Score = if score then score(v) else (tonumber(v) or 0) })
	end
	table.sort(list, function(a, b)
		if a.Score == b.Score then
			return tostring(a.Key) < tostring(b.Key)
		end
		return a.Score > b.Score
	end)
	local out = {}
	for i = 1, math.min(n, #list) do
		out[i] = list[i]
	end
	return out
end

-- Percent change from `before` to `after` (nil when before is 0).
function AnalyticsService.PctChange(before: number?, after: number?): number?
	if not before or not after or before == 0 then
		return nil
	end
	return math.floor((after - before) / before * 1000 + 0.5) / 10
end

-- ---------------------------------------------------------------------------
-- Live collection
-- ---------------------------------------------------------------------------
local store: DataStore? = nil
if LIVE then
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = ds
	end
end

local startedAt = os.time()
local memoryHours: { [number]: any } = {} -- this server, hourStart -> bucket
local memoryDays: { [string]: any } = {} -- this server, day key -> { Cmd, Mods, Econ }
local pending: { [string]: any } = {} -- day key -> delta day record (not yet stored)

local function hourBucket(t: number): ({ [string]: number }, { [string]: number }, any, any)
	local h = t - t % HOUR
	local key = AnalyticsService.DayKey(h)
	local mem = memoryHours[h]
	if not mem then
		mem = AnalyticsService.NewBucket(h)
		memoryHours[h] = mem
		-- prune
		for k in pairs(memoryHours) do
			if k < h - MEMORY_HOURS * HOUR then
				memoryHours[k] = nil
			end
		end
	end
	local delta = pending[key]
	if not delta then
		delta = { V = 1, H = {}, Cmd = {}, Mods = {}, Econ = {}, Srv = {} }
		pending[key] = delta
	end
	local hk = tostring(math.floor((h % DAY) / HOUR))
	local pb = delta.H[hk]
	if not pb then
		pb = AnalyticsService.NewBucket(h)
		delta.H[hk] = pb
	end
	local md = memoryDays[key]
	if not md then
		md = { Cmd = {}, Mods = {}, Econ = {} }
		memoryDays[key] = md
		local cutoff = AnalyticsService.DayKey(h - 8 * DAY)
		for k in pairs(memoryDays) do
			if k < cutoff then
				memoryDays[k] = nil
			end
		end
	end
	return mem, pb, delta, md
end

local function bump(field: string, amount: number)
	local mem, pb = hourBucket(os.time())
	mem[field] = (mem[field] or 0) + amount
	pb[field] = (pb[field] or 0) + amount
end

local function bumpMap(mapName: string, key: string, amount: number, name: string?)
	local _, _, delta, md = hourBucket(os.time())
	for _, target in ipairs({ delta, md }) do
		local map = target[mapName]
		if mapName == "Mods" then
			local cur = map[key] or { N = name, C = 0 }
			cur.N = name or cur.N
			cur.C += amount
			map[key] = cur
		else
			map[key] = (map[key] or 0) + amount
		end
	end
end

local function isStaffUserId(userId: any): boolean
	local uid = tonumber(userId)
	local player = uid and Players:GetPlayerByUserId(uid)
	return player ~= nil and PermissionSystem.Has(player, "panel.open")
end

local function onLog(entry: any)
	-- SYSTEM lines and module bookkeeping (the ;module command is logged too)
	if type(entry) ~= "table" or entry.Executor == "SYSTEM" or entry.Source == "modules" then
		return
	end
	local action = tostring(entry.Action or "")
	if entry.Command == "data.change" or action == "data.change" then
		return
	end
	local result = entry.Result
	local field = if result == "Success" then "CS" elseif result == "Denied" then "CD" elseif result == "Cancelled" then "CC" else "CF"
	bump(field, 1)
	bumpMap("Cmd", tostring(entry.Command or "?"), 1)
	if isStaffUserId(entry.Executor) then
		bump("StaffCmd", 1)
	end
	if result == "Success" and action:sub(1, 11) == "moderation." then
		bump("Mod", 1)
		bumpMap("Mods", tostring(entry.Executor), 1, entry.ExecutorName)
	end
end

local function sample()
	local now = os.time()
	local players = Players:GetPlayers()
	local staff, pingSum, pingN = 0, 0, 0
	for _, p in ipairs(players) do
		if PermissionSystem.Has(p, "panel.open") then
			staff += 1
		end
		local ok, ping = pcall(function()
			return p:GetNetworkPing() * 1000
		end)
		if ok and type(ping) == "number" and ping > 0 then
			pingSum += ping
			pingN += 1
		end
	end
	local fps, mem = 0, 0
	pcall(function()
		local Dev = require(script.Parent:WaitForChild("DeveloperService")) :: any
		local s = Dev.GetServerStats()
		fps = tonumber(s.HeartbeatRate) or 0
		mem = tonumber(s.MemoryMb) or 0
	end)
	local global = #players
	pcall(function()
		local CrossServer = require(script.Parent:WaitForChild("CrossServerService")) :: any
		local _, totals = CrossServer.ListServers(false)
		if type(totals) == "table" and tonumber(totals.Players) then
			global = math.max(global, tonumber(totals.Players) :: number)
		end
	end)
	local memB, pb, delta = hourBucket(now)
	for _, b in ipairs({ memB, pb }) do
		b.PMax = math.max(b.PMax or 0, #players)
		b.GMax = math.max(b.GMax or 0, global)
		b.SMax = math.max(b.SMax or 0, staff)
		b.PSum += #players
		b.PN += 1
		b.SSum += staff
		b.SN += 1
		if fps > 0 then
			b.FSum += fps
			b.FN += 1
			b.FMin = math.min(b.FMin or fps, fps)
		end
		if mem > 0 then
			b.MSum += mem
			b.MN += 1
			b.MMax = math.max(b.MMax or 0, mem)
		end
		if pingN > 0 then
			b.GSum += pingSum / pingN
			b.GN += 1
		end
	end
	delta.Srv[Logger.GetServerId()] = now
end

-- Economy: every numeric leaderstat change after the join settle time.
local function watchStat(player: Player, stat: Instance, joinedAt: number)
	if not (stat:IsA("IntValue") or stat:IsA("NumberValue")) then
		return
	end
	local value = stat :: any
	local last = value.Value
	value.Changed:Connect(function(new)
		local before = last
		last = new
		if os.clock() - joinedAt < JOIN_QUIET or type(new) ~= "number" or type(before) ~= "number" then
			return
		end
		local diff = math.abs(new - before)
		if diff == 0 then
			return
		end
		bump("ETx", 1)
		bump("EVol", diff)
		bumpMap("Econ", stat.Name, diff)
	end)
end

local function watchPlayer(player: Player)
	local joinedAt = os.clock()
	local function hook(folder: Instance)
		if folder.Name ~= "leaderstats" then
			return
		end
		for _, s in ipairs(folder:GetChildren()) do
			watchStat(player, s, joinedAt)
		end
		folder.ChildAdded:Connect(function(s)
			watchStat(player, s, joinedAt)
		end)
	end
	for _, c in ipairs(player:GetChildren()) do
		hook(c)
	end
	player.ChildAdded:Connect(hook)
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
local cache: { [string]: { At: number, Data: any } } = {}

function AnalyticsService.Flush()
	if not store then
		pending = {}
		return
	end
	local batch = pending
	pending = {}
	for key, delta in pairs(batch) do
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(key, function(old)
				return AnalyticsService.MergeDay(old, delta)
			end)
		end)
		if ok then
			cache[key] = nil
		else
			warn("[Sentinel.Analytics] save failed: " .. tostring(err))
			-- put it back for the next flush
			pending[key] = AnalyticsService.MergeDay(pending[key], delta)
		end
	end
end

local function readDay(key: string, isToday: boolean): any
	if not store then
		return nil
	end
	local hit = cache[key]
	local maxAge = if isToday then 60 else 600
	if hit and os.clock() - hit.At < maxAge then
		return hit.Data
	end
	local ok, data = pcall(function()
		return (store :: DataStore):GetAsync(key)
	end)
	if ok then
		cache[key] = { At = os.clock(), Data = data }
		return data
	end
	return hit and hit.Data
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------
local function collect(range: any, scope: string): ({ [number]: any }, { [string]: number }, { [string]: any }, { [string]: number }, number)
	local hours: { [number]: any } = {}
	local cmd: { [string]: number } = {}
	local mods: { [string]: any } = {}
	local econ: { [string]: number } = {}
	local servers: { [string]: boolean } = {}
	local today = AnalyticsService.DayKey(os.time())
	local d = dayStart(range.From)
	while d < range.To do
		local key = AnalyticsService.DayKey(d)
		local day
		if scope == "server" then
			day = { Cmd = (memoryDays[key] or {}).Cmd, Mods = (memoryDays[key] or {}).Mods, Econ = (memoryDays[key] or {}).Econ, H = {} }
			for h = d, d + DAY - HOUR, HOUR do
				if memoryHours[h] then
					day.H[tostring(math.floor((h % DAY) / HOUR))] = memoryHours[h]
				end
			end
		else
			-- stored total + what this server hasn't written yet
			local stored = readDay(key, key == today)
			day = AnalyticsService.MergeDay(AnalyticsService.MergeDay(nil, stored), pending[key])
		end
		-- whole-day maps only count when the day overlaps the range
		for name, n in pairs(day.Cmd or {}) do
			cmd[name] = (cmd[name] or 0) + n
		end
		for uid, m in pairs(day.Mods or {}) do
			local cur = mods[uid] or { N = m.N, C = 0 }
			cur.N = m.N or cur.N
			cur.C += m.C or 0
			mods[uid] = cur
		end
		for stat, v in pairs(day.Econ or {}) do
			econ[stat] = (econ[stat] or 0) + v
		end
		for id in pairs(day.Srv or {}) do
			servers[id] = true
		end
		for hk, b in pairs(day.H or {}) do
			local h = d + (tonumber(hk) or 0) * HOUR
			if h >= range.From and h < range.To then
				hours[h] = AnalyticsService.MergeBucket(AnalyticsService.NewBucket(h), b)
			end
		end
		d += DAY
	end
	local serverCount = 0
	for _ in pairs(servers) do
		serverCount += 1
	end
	return hours, cmd, mods, econ, serverCount
end

function AnalyticsService.Query(options: any): (any, string?)
	options = if type(options) == "table" then options else {}
	local now = os.time()
	local range, err = AnalyticsService.ParseRange(options.Range, options.From, options.To, now)
	if not range then
		return nil, err
	end
	local scope = if options.Scope == "server" then "server" else "all"
	local hours, cmd, mods, econ, serverCount = collect(range, scope)
	local series = AnalyticsService.Rollup(hours, range)
	local report: any = {
		Range = range,
		Scope = scope,
		Series = series,
		Totals = AnalyticsService.Totals(series),
		Servers = if scope == "server" then 1 else serverCount,
		TopCommands = {},
		TopModerators = {},
		Economy = {},
		Persistent = store ~= nil,
		Now = now,
	}
	for i, item in ipairs(AnalyticsService.TopN(cmd, 10)) do
		report.TopCommands[i] = { Command = item.Key, Count = item.Score }
	end
	for i, item in ipairs(AnalyticsService.TopN(mods, 10, function(v)
		return v.C or 0
	end)) do
		report.TopModerators[i] = { UserId = tonumber(item.Key), Name = item.Value.N or item.Key, Count = item.Score }
	end
	for i, item in ipairs(AnalyticsService.TopN(econ, 8)) do
		report.Economy[i] = { Stat = item.Key, Volume = item.Score }
	end
	if options.Compare then
		local length = range.To - range.From
		local prev = { From = range.From - length, To = range.From, Step = range.Step, Label = "Previous period" }
		local pHours = collect(prev, scope)
		local pSeries = AnalyticsService.Rollup(pHours, prev)
		report.Previous = { Range = prev, Series = pSeries, Totals = AnalyticsService.Totals(pSeries) }
	end
	return report
end

function AnalyticsService.Live(): any
	local players = Players:GetPlayers()
	local staff, pingSum, pingN = 0, 0, 0
	for _, p in ipairs(players) do
		if PermissionSystem.Has(p, "panel.open") then
			staff += 1
		end
		local ok, ping = pcall(function()
			return p:GetNetworkPing() * 1000
		end)
		if ok and ping > 0 then
			pingSum += ping
			pingN += 1
		end
	end
	local live: any = {
		Players = #players,
		MaxPlayers = Players.MaxPlayers,
		Staff = staff,
		Uptime = os.time() - startedAt,
		Ping = if pingN > 0 then math.floor(pingSum / pingN + 0.5) else 0,
	}
	pcall(function()
		local Dev = require(script.Parent:WaitForChild("DeveloperService")) :: any
		local s = Dev.GetServerStats()
		live.Fps = math.floor((tonumber(s.HeartbeatRate) or 0) + 0.5)
		live.Memory = tonumber(s.MemoryMb) or 0
		live.Uptime = tonumber(s.Uptime) or live.Uptime
	end)
	pcall(function()
		local CaseService = require(script.Parent:WaitForChild("CaseService")) :: any
		local dash = CaseService.Dashboard()
		live.ActiveBans = dash.Counts.ActiveBans
		live.ActiveMutes = dash.Counts.ActiveMutes
		live.ActivePunishments = dash.Counts.Active
		local recent = {}
		for i, c in ipairs(dash.RecentPunishments or {}) do
			if i > 6 then
				break
			end
			recent[i] = { Id = c.Id, Type = c.Type, Target = c.TargetName, By = c.ModeratorName, At = c.CreatedAt }
		end
		live.RecentModeration = recent
	end)
	return live
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
if LIVE then
	EventBus.Subscribe("Log.Written", function(entry)
		local ok, e = pcall(onLog, entry)
		if not ok then
			warn("[Sentinel.Analytics] " .. tostring(e))
		end
	end)
	for _, p in ipairs(Players:GetPlayers()) do
		watchPlayer(p)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	task.spawn(function()
		task.wait(3)
		while true do
			pcall(sample)
			task.wait(SAMPLE_EVERY)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(FLUSH_EVERY)
			AnalyticsService.Flush()
		end
	end)
	game:BindToClose(function()
		AnalyticsService.Flush()
	end)
end

return AnalyticsService
