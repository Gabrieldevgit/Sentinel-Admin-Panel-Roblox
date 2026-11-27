--!strict
--[[
	ScoreService.lua (Sentinel AntiCheat)

	Purpose:
		Per-player, per-session suspicion scores. Each flag adds
		Severity x Confidence x ModuleWeight x PlayerWeight points; the score
		decays over time (Scoring.DecayPerMinute, applied lazily on read) so
		one odd moment fades while repeated flags stack. The score is capped
		(Scoring.ScoreCap). A short score history (for the Players drawer
		graph) and the modules that flagged recently (for the multi-module
		ban pattern) are kept per player.

		Per-player module weights start at 1 and are multiplied by
		Scoring.FalsePositiveFactor each time staff mark one of that module's
		flags on that player as a false positive (never below
		MinPlayerWeight).

		Pure bookkeeping - no Roblox calls, so it is unit tested directly.
		Times: `now` = os.clock() seconds (decay), os.time() for history.

	Public API:
		ScoreService.Points(severity, confidence, moduleWeight, playerWeight) -> number
		ScoreService.Get(userId, now?, cfg?) -> number
		ScoreService.Add(userId, points, module, cfg?, now?) -> number (score after)
		ScoreService.Set(userId, value) / Reset(userId) -> old / Reduce(userId, amount)
		ScoreService.Band(score, bands) -> 1..5
		ScoreService.RecentModules(userId, windowSeconds, now?) -> { string }
		ScoreService.PlayerWeight(userId, module) / LowerWeight(userId, module, factor, min)
		ScoreService.History(userId) -> { {T, S} }
		ScoreService.GetLastBand / SetLastBand(userId, band)
		ScoreService.Forget(userId) / Above(threshold) -> count / _Clear()
--]]

local ScoreService = {}

local HISTORY_MAX = 120

type Entry = {
	Score: number,
	At: number, -- os.clock of the last decay
	History: { { T: number, S: number } },
	Recent: { { M: string, T: number } },
	Weights: { [string]: number },
	LastBand: number,
}

local entries: { [number]: Entry } = {}

local function entry(userId: number, now: number): Entry
	local e = entries[userId]
	if not e then
		e = { Score = 0, At = now, History = {}, Recent = {}, Weights = {}, LastBand = 1 }
		entries[userId] = e
	end
	return e
end

local function decay(e: Entry, now: number, cfg: any?)
	local perMinute = if cfg and type(cfg.DecayPerMinute) == "number" then cfg.DecayPerMinute else 1
	local dt = now - e.At
	if dt > 0 then
		e.Score = math.max(0, e.Score - perMinute * dt / 60)
		e.At = now
	end
end

function ScoreService.Points(severity: number, confidence: number, moduleWeight: number, playerWeight: number?): number
	local s = math.clamp(tonumber(severity) or 0, 0, 10)
	local c = math.clamp(tonumber(confidence) or 0, 0, 1)
	local w = math.clamp(tonumber(moduleWeight) or 1, 0, 2)
	local p = math.clamp(tonumber(playerWeight) or 1, 0, 1)
	return s * c * w * p
end

function ScoreService.Get(userId: number, now: number?, cfg: any?): number
	local e = entries[userId]
	if not e then
		return 0
	end
	decay(e, now or os.clock(), cfg)
	return e.Score
end

function ScoreService.Add(userId: number, points: number, module: string?, cfg: any?, now: number?): number
	local t = now or os.clock()
	local e = entry(userId, t)
	decay(e, t, cfg)
	local cap = if cfg and type(cfg.ScoreCap) == "number" then cfg.ScoreCap else 100
	e.Score = math.clamp(e.Score + math.max(0, points), 0, cap)
	table.insert(e.History, { T = os.time(), S = math.floor(e.Score * 10 + 0.5) / 10 })
	while #e.History > HISTORY_MAX do
		table.remove(e.History, 1)
	end
	if module then
		table.insert(e.Recent, { M = module, T = t })
		while #e.Recent > 200 do
			table.remove(e.Recent, 1)
		end
	end
	return e.Score
end

function ScoreService.Set(userId: number, value: number)
	local e = entry(userId, os.clock())
	e.Score = math.max(0, tonumber(value) or 0)
	e.At = os.clock()
	table.insert(e.History, { T = os.time(), S = e.Score })
	if e.Score < 1 then
		e.LastBand = 1
	end
end

-- Returns the score before the reset.
function ScoreService.Reset(userId: number): number
	local old = ScoreService.Get(userId)
	ScoreService.Set(userId, 0)
	local e = entries[userId]
	if e then
		e.LastBand = 1
		table.clear(e.Recent)
	end
	return old
end

function ScoreService.Reduce(userId: number, amount: number): number
	local current = ScoreService.Get(userId)
	ScoreService.Set(userId, math.max(0, current - math.max(0, amount)))
	return ScoreService.Get(userId)
end

-- Band 1 = below Band1, 5 = at or above Band4.
function ScoreService.Band(score: number, bands: any): number
	local b = bands or { Band1 = 20, Band2 = 40, Band3 = 60, Band4 = 80 }
	if score >= b.Band4 then
		return 5
	elseif score >= b.Band3 then
		return 4
	elseif score >= b.Band2 then
		return 3
	elseif score >= b.Band1 then
		return 2
	end
	return 1
end

-- Distinct modules that flagged within the window.
function ScoreService.RecentModules(userId: number, windowSeconds: number, now: number?): { string }
	local e = entries[userId]
	if not e then
		return {}
	end
	local t = now or os.clock()
	local seen, out = {}, {}
	for i = #e.Recent, 1, -1 do
		local r = e.Recent[i]
		if t - r.T > windowSeconds then
			break
		end
		if not seen[r.M] then
			seen[r.M] = true
			table.insert(out, r.M)
		end
	end
	table.sort(out)
	return out
end

function ScoreService.PlayerWeight(userId: number, module: string): number
	local e = entries[userId]
	return if e and e.Weights[module] then e.Weights[module] else 1
end

function ScoreService.LowerWeight(userId: number, module: string, factor: number, min: number): number
	local e = entry(userId, os.clock())
	local w = (e.Weights[module] or 1) * math.clamp(factor, 0, 1)
	e.Weights[module] = math.max(min, w)
	return e.Weights[module]
end

function ScoreService.SetWeights(userId: number, weights: { [string]: number })
	local e = entry(userId, os.clock())
	e.Weights = table.clone(weights)
end

function ScoreService.Weights(userId: number): { [string]: number }
	local e = entries[userId]
	return if e then table.clone(e.Weights) else {}
end

function ScoreService.History(userId: number): { { T: number, S: number } }
	local e = entries[userId]
	return if e then table.clone(e.History) else {}
end

function ScoreService.GetLastBand(userId: number): number
	local e = entries[userId]
	return if e then e.LastBand else 1
end

function ScoreService.SetLastBand(userId: number, band: number)
	entry(userId, os.clock()).LastBand = band
end

-- How many tracked players are at or above the threshold right now.
function ScoreService.Above(threshold: number, cfg: any?): number
	local n = 0
	local now = os.clock()
	for _, e in pairs(entries) do
		decay(e, now, cfg)
		if e.Score >= threshold then
			n += 1
		end
	end
	return n
end

function ScoreService.Forget(userId: number)
	entries[userId] = nil
end

function ScoreService._Clear()
	table.clear(entries)
end

return ScoreService
