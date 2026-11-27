--!strict
--!native
--[[
	DetectionEngine.lua (Sentinel AntiCheat)

	Purpose:
		Loads the detection modules, schedules their checks, and runs the
		scoring pipeline for every flag.

		Modules: every ModuleScript in Systems/AntiCheat/Modules is a module
		(adding a file adds a detection). Contract (see AntiCheatTypes):
		Name, Description, Enabled, Interval, Severity, Defaults, Schema?,
		Gather?(player, state, ctx) (live only: reads instances into state),
		Check(player, state) -> nil | { Severity?, Confidence, Reason,
		Evidence?, Correct? }. Check is pure, so unit tests call it with a
		hand-made state. A module never punishes; it only reports here.

		Scheduling: one Heartbeat loop over a min-heap of jobs ordered by
		next-run time (no per-frame scan of every job). Every (player,
		module) pair is a job (the module's Interval, staggered at start);
		position sampling (5 Hz per player) is a job too and refreshes the
		player's snapshot (character, humanoid, root, ping, Sentinel
		attributes, seated / anchored, how far they moved in 1.2 s) that
		every check of that player shares. A frame runs at most
		Core.FrameBudget checks AND stops after Core.FrameMsCap ms; due jobs
		left over wait for the next frame (deferred), so checks never pile
		into one frame. Modules may declare SkipWhenSeated (seated / in a
		vehicle / anchored) and SkipWhenStill (moved < 0.5 studs in 1.2 s);
		those checks are skipped before any work, and the module's optional
		OnSkip(scratch, "seated" | "still", now, lastSampleT) keeps its
		state as Check would have (resets, decays). Above Core.CrowdPlayers
		tracked players every interval scales by players / CrowdPlayers.
		Cost = the whole engine step (checks + sampling + scheduler) in ms of
		server time per second; when over Core.CostBudgetMs every interval is
		stretched (up to 12x, MAX_STRETCH) until it fits. The worst single
		frame (last 10 s, and since start) is tracked too.

		Pipeline (Submit): fill the flag (id, time, server), clamp severity
		1-10 and confidence 0-1, snapshot evidence (EvidenceService), add
		Severity x Confidence x ModuleWeight x PlayerWeight to the score
		(ScoreService), record it, decide the band action (ActionService,
		skipped in Testing mode / Panic) and push it to staff.

		Event hub: other code notes raw events per player (remote calls,
		hits, heals, damage, economy sources, client reports, known
		teleports) with Note(userId, kind, data); modules read them in
		Gather via ctx.Events(userId, kind, seconds).

	Public API:
		DetectionEngine.LoadModules(folder) -> count
		DetectionEngine.Modules() -> { def } / GetModule(name)
		DetectionEngine.Start() / Stop()
		DetectionEngine.Track(player) / Untrack(player)
		DetectionEngine.Submit(player, flag, opts?) -> fullFlag?
		DetectionEngine.Note(userId, kind, data?) / Events(userId, kind, seconds?)
		DetectionEngine.BuildState(player, def, now) -> state
		DetectionEngine.LagFactor(pingMs, serverFps, grace) -> number  (pure)
		DetectionEngine.TestModule(player, name) -> result
		DetectionEngine.Stats() -> cost / checks per module
		DetectionEngine.SetHooks({ OnFlag = fn(flag, decision, result) })
		DetectionEngine.Context  -- table handed to Gather (filled by AntiCheatService)
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local AntiCheatConfig = require(script.Parent:WaitForChild("AntiCheatConfig"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))
local ExemptionService = require(script.Parent:WaitForChild("ExemptionService"))
local EvidenceService = require(script.Parent:WaitForChild("EvidenceService"))
local ActionService = require(script.Parent:WaitForChild("ActionService"))
local ModuleUtil = require(script.Parent:WaitForChild("ModuleUtil"))
local Logger = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("Logger"))

local DetectionEngine = {}

local SAMPLE_INTERVAL = 0.2
local EVENT_KEEP_SECONDS = 30
local EVENT_MAX = 120

local modules: { any } = {}
local byName: { [string]: any } = {}
local jobs: { any } = {}
local tracked: { [number]: any } = {}
local scratch: { [number]: { [string]: any } } = {}
local events: { [number]: { [string]: { any } } } = {}
local hooks: { [string]: any } = {}
local connection: RBXScriptConnection? = nil
local flagSeq = 0
local costFactor = 1
-- How far intervals may stretch to stay in budget (12x: a 0.5 s check
-- runs every 6 s at worst). Raised from 4x: at 50 players the default
-- 2 ms/s budget needs roughly 6-10x.
local MAX_STRETCH = 12
local stretchLocked = false -- LockStretch: load tests measure the full cost

-- Per-module cost accounting (rolling one-second windows, smoothed).
local cost: { [string]: { Window: number, Ms: number, Checks: number, Flags: number, Errors: number, LastError: string? } } = {}
local windowStart = os.clock()
local windowTotal = 0
local totalMsPerSecond = 0
local checksPerSecond = 0
local windowChecks = 0
-- Engine-level accounting (see Stats): sampling, scheduler overhead, the
-- worst frame, deferred and skipped checks, crowd scaling.
local windowSampling = 0
local windowWorst = 0
local windowDeferred = 0
local windowSkipped = 0
local samplingMs = 0
local schedulerMs = 0
local recentWorst: { number } = {}
local peakFrameMs = 0
local deferredPerSecond = 0
local skippedPerSecond = 0
local crowdScale = 1
local trackedCount = 0
local STILL_STUDS = 0.5 -- SkipWhenStill: moved less than this ...
local STILL_WINDOW = 1.2 -- ... over this many seconds of samples

DetectionEngine.Context = {} :: { [string]: any }

-- ---------------------------------------------------------------------------
-- Modules
-- ---------------------------------------------------------------------------
local function validDef(def: any): (boolean, string?)
	if type(def) ~= "table" then
		return false, "did not return a table"
	end
	if type(def.Name) ~= "string" or def.Name == "" then
		return false, "has no Name"
	end
	if type(def.Check) ~= "function" then
		return false, "has no Check function"
	end
	if type(def.Interval) ~= "number" or def.Interval <= 0 then
		return false, "has no valid Interval"
	end
	if type(def.Defaults) ~= "table" then
		return false, "has no Defaults table"
	end
	return true, nil
end

function DetectionEngine.Register(def: any): (boolean, string?)
	local ok, err = validDef(def)
	if not ok then
		return false, err
	end
	if byName[def.Name] then
		return true, nil
	end
	def.Severity = math.clamp(tonumber(def.Severity) or 5, 1, 10)
	table.insert(modules, def)
	byName[def.Name] = def
	cost[def.Name] = { Window = 0, Ms = 0, Checks = 0, Flags = 0, Errors = 0 }
	AntiCheatConfig.RegisterModule(def)
	return true, nil
end

function DetectionEngine.LoadModules(folder: Instance): number
	local loaded = 0
	local children = folder:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	for _, child in ipairs(children) do
		if child:IsA("ModuleScript") then
			local ok, def = pcall(require, child)
			if not ok then
				warn(("[Sentinel.AntiCheat] module %s failed to load: %s"):format(child.Name, tostring(def)))
				continue
			end
			local registered, err = DetectionEngine.Register(def)
			if registered then
				loaded += 1
			else
				warn(("[Sentinel.AntiCheat] module %s %s - skipped"):format(child.Name, tostring(err)))
			end
		end
	end
	return loaded
end

function DetectionEngine.Modules(): { any }
	return modules
end

function DetectionEngine.GetModule(name: string): any
	if byName[name] then
		return byName[name]
	end
	for n, def in pairs(byName) do
		if n:lower() == tostring(name):lower() then
			return def
		end
	end
	return nil
end

function DetectionEngine.SetHooks(h: { [string]: any })
	for k, v in pairs(h) do
		hooks[k] = v
	end
end

-- ---------------------------------------------------------------------------
-- Event hub
-- ---------------------------------------------------------------------------
function DetectionEngine.Note(userId: number, kind: string, data: any?)
	local perPlayer = events[userId]
	if not perPlayer then
		perPlayer = {}
		events[userId] = perPlayer
	end
	local list = perPlayer[kind]
	if not list then
		list = {}
		perPlayer[kind] = list
	end
	local now = os.clock()
	table.insert(list, { T = now, D = data })
	while #list > EVENT_MAX or (#list > 0 and now - list[1].T > EVENT_KEEP_SECONDS) do
		table.remove(list, 1)
	end
end

function DetectionEngine.Events(userId: number, kind: string, seconds: number?): { any }
	local list = events[userId] and events[userId][kind]
	if not list then
		return {}
	end
	local now = os.clock()
	local window = seconds or EVENT_KEEP_SECONDS
	local out = {}
	for _, e in ipairs(list) do
		if now - e.T <= window then
			table.insert(out, e)
		end
	end
	return out
end

-- Last time an event of this kind was noted (os.clock), or nil.
function DetectionEngine.LastEvent(userId: number, kind: string): number?
	local list = events[userId] and events[userId][kind]
	local last = list and list[#list]
	return if last then last.T else nil
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- How much thresholds widen for this player right now (pure).
function DetectionEngine.LagFactor(pingMs: number, serverFps: number, grace: any?): number
	local tolerance = if grace and type(grace.LagTolerance) == "number" then grace.LagTolerance else 1.5
	local maxPing = if grace and type(grace.MaxPingMs) == "number" then grace.MaxPingMs else 1000
	local ping = math.clamp(tonumber(pingMs) or 0, 0, maxPing) / 1000
	local fps = math.clamp(tonumber(serverFps) or 60, 1, 60)
	local frame = 60 / fps -- 1 at 60 FPS, 2 at 30 FPS
	return tolerance * (1 + ping) * (1 + (frame - 1) * 0.5)
end

local function scratchFor(userId: number, name: string): any
	local s = scratch[userId]
	if not s then
		s = {}
		scratch[userId] = s
	end
	local m = s[name]
	if not m then
		m = {}
		s[name] = m
	end
	return m
end

-- Per-player snapshot, refreshed by the 5 Hz sampler and shared by every
-- check of that player: one read of the character, ping and attributes
-- per tick instead of one per module.
local snapshots: { [number]: any } = {}

-- Largest distance between the newest sample and any sample of the last
-- STILL_WINDOW seconds (math.huge when there are too few samples to say).
local function movedRecently(userId: number, now: number): number
	local list = EvidenceService.RawSamples(userId)
	local last = list[#list]
	if not last then
		return math.huge
	end
	local maxD, count = 0, 1
	for i = #list - 1, 1, -1 do
		local sample = list[i]
		if now - sample.T > STILL_WINDOW then
			break
		end
		count += 1
		local d = (sample.P - last.P).Magnitude
		if d > maxD then
			maxD = d
		end
	end
	return if count >= 3 then maxD else math.huge
end

local SLOW_REFRESH = 1 -- seconds between ping / FPS / lag / instance lookups

local function refreshSnapshot(player: Player, now: number): any
	local character = player.Character
	local snap = snapshots[player.UserId]
	if not snap or snap.Character ~= character or now - snap.SlowT >= SLOW_REFRESH then
		-- Slow part: instance lookups and network numbers.
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local ping = 0
		pcall(function()
			ping = player:GetNetworkPing() * 1000
		end)
		local fps = EvidenceService.ServerFps()
		snap = {
			SlowT = now,
			Character = character,
			Humanoid = humanoid,
			Root = root,
			Ping = ping,
			ServerFps = fps,
			Lag = DetectionEngine.LagFactor(ping, fps, AntiCheatConfig.Get("Grace")),
		}
		snapshots[player.UserId] = snap
	end
	-- Fast part, every sample: state that can flip any moment.
	local root = snap.Root :: BasePart?
	snap.T = now
	snap.Flying = player:GetAttribute("SentinelFlying") == true
	snap.Noclip = player:GetAttribute("SentinelNoclip") == true
	snap.God = player:GetAttribute("SentinelGod") == true
	snap.Frozen = player:GetAttribute("SentinelFrozen") == true or (root ~= nil and root.Anchored)
	snap.Seated = ModuleUtil.Seated(snap.Humanoid) or ModuleUtil.InVehicle(root)
	snap.Moved = movedRecently(player.UserId, now)
	return snap
end

local function snapshotFor(player: Player, now: number): any
	local snap = snapshots[player.UserId]
	if not snap or snap.Character ~= player.Character or now - snap.T > 0.5 then
		snap = refreshSnapshot(player, now)
	end
	return snap
end

function DetectionEngine.BuildState(player: Player, def: any, now: number, moduleCfg: any?): any
	local snap = snapshotFor(player, now)
	return {
		Player = player,
		UserId = player.UserId,
		Character = snap.Character,
		Humanoid = snap.Humanoid,
		Root = snap.Root,
		Now = now,
		Config = moduleCfg or AntiCheatConfig.GetModule(def.Name),
		Ping = snap.Ping,
		ServerFps = snap.ServerFps,
		Lag = snap.Lag,
		Samples = EvidenceService.RawSamples(player.UserId),
		Module = scratchFor(player.UserId, def.Name),
		Flying = snap.Flying,
		Noclip = snap.Noclip,
		God = snap.God,
		Frozen = snap.Frozen,
		Moved = snap.Moved,
	}
end

-- ---------------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------------
local function serverShort(): string
	local id = Logger.GetServerId()
	if id == "" then
		return "local"
	end
	return if id:sub(1, 7) == "studio-" then id else id:sub(1, 8)
end

-- opts = { Test = true } (log-only, not scored), Silent = no action
function DetectionEngine.Submit(player: any, partial: any, opts: any?): any
	if type(partial) ~= "table" or type(partial.Module) ~= "string" then
		return nil
	end
	local def = byName[partial.Module]
	local moduleCfg = AntiCheatConfig.GetModule(partial.Module)
	local scoring = AntiCheatConfig.Get("Scoring")
	local bands = AntiCheatConfig.Get("Bands")
	local core = AntiCheatConfig.Get("Core")
	local testing = ExemptionService.IsTesting(player.UserId)
	local isTest = opts ~= nil and opts.Test == true

	flagSeq += 1
	local severity = math.clamp(math.floor(tonumber(partial.Severity) or (def and def.Severity) or 5), 1, 10)
	local confidence = math.clamp(tonumber(partial.Confidence) or 0.5, 0, 1)
	local weight = if moduleCfg and type(moduleCfg.Weight) == "number" then moduleCfg.Weight else 1
	local playerWeight = ScoreService.PlayerWeight(player.UserId, partial.Module)
	local points = if isTest then 0 else ScoreService.Points(severity, confidence, weight, playerWeight)
	local scoreAfter = if isTest
		then ScoreService.Get(player.UserId, nil, scoring)
		else ScoreService.Add(player.UserId, points, partial.Module, scoring)

	local flag = {
		Id = ("%s-%d"):format(serverShort(), flagSeq),
		Module = partial.Module,
		Severity = severity,
		Confidence = math.floor(confidence * 100 + 0.5) / 100,
		Reason = tostring(partial.Reason or partial.Module):sub(1, 200),
		UserId = player.UserId,
		Name = player.Name,
		Time = os.time(),
		Points = math.floor(points * 10 + 0.5) / 10,
		ScoreAfter = math.floor(scoreAfter * 10 + 0.5) / 10,
		Server = serverShort(),
		Correct = partial.Correct,
		RestoreHealth = if type(partial.RestoreHealth) == "number" then partial.RestoreHealth else nil,
		Testing = if testing then true else nil,
		Test = if isTest then true else nil,
		Evidence = EvidenceService.Snapshot(player, partial.Evidence, ExemptionService.Active(player.UserId)),
	}
	if cost[flag.Module] then
		cost[flag.Module].Flags += 1
	end
	if isTest then
		return flag
	end
	EvidenceService.Record(flag, AntiCheatConfig.Get("Storage"))

	local band = ScoreService.Band(scoreAfter, bands)
	local lastBand = ScoreService.GetLastBand(player.UserId)
	-- Re-arm bands the score decayed below.
	if band < lastBand then
		ScoreService.SetLastBand(player.UserId, band)
		lastBand = band
	end
	local windowSeconds = (bands.PatternMinutes or 10) * 60
	local recentModules = ScoreService.RecentModules(player.UserId, windowSeconds)
	local decision = ActionService.Decide({
		Mode = core.Mode,
		Panic = core.Panic,
		Testing = testing,
		Band = band,
		LastBand = lastBand,
		Bands = bands,
		Modules = recentModules,
	})
	local result: string? = nil
	if decision and not (opts and opts.Silent) then
		ScoreService.SetLastBand(player.UserId, band)
		flag.Action = decision.Action
		local recentIds = {}
		for _, f in ipairs(EvidenceService.ForPlayer(player.UserId, 25)) do
			table.insert(recentIds, f.Id)
		end
		local ok, outcome = pcall(ActionService.Execute, player, decision, flag, {
			Bands = bands,
			Modules = recentModules,
			FlagIds = recentIds,
		})
		result = if ok then outcome else ("action failed: " .. tostring(outcome))
		flag.ActionResult = result
	end
	if hooks.OnFlag then
		pcall(hooks.OnFlag, flag, decision, result)
	end
	return flag
end

-- ---------------------------------------------------------------------------
-- Tracking + scheduling
-- ---------------------------------------------------------------------------
-- Min-heap of jobs by NextAt: a frame only touches the jobs that are due.
local heap: { any } = {}

local function heapPush(job: any)
	table.insert(heap, job)
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if heap[parent].NextAt <= heap[i].NextAt then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function heapPop(): any
	local top = heap[1]
	local last = table.remove(heap)
	local n = #heap
	if n > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, smallest = i * 2, i * 2 + 1, i
			if l <= n and heap[l].NextAt < heap[smallest].NextAt then
				smallest = l
			end
			if r <= n and heap[r].NextAt < heap[smallest].NextAt then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[smallest], heap[i] = heap[i], heap[smallest]
			i = smallest
		end
	end
	return top
end

local function rebuildJobs()
	table.clear(jobs)
	table.clear(heap)
	local now = os.clock()
	trackedCount = 0
	for userId, info in pairs(tracked) do
		trackedCount += 1
		for i, def in ipairs(modules) do
			-- Stagger: spread each module's first run over its interval.
			local offset = ((userId % 97) / 97 + i / (#modules + 1)) % 1
			table.insert(jobs, { UserId = userId, Player = info.Player, Def = def, NextAt = now + def.Interval * offset })
		end
		-- Samplers are staggered too, so 50 players don't all sample in one frame.
		table.insert(jobs, { UserId = userId, Player = info.Player, Sample = true, NextAt = now + ((userId % 89) / 89) * SAMPLE_INTERVAL })
	end
	for _, job in ipairs(jobs) do
		heapPush(job)
	end
end

-- opts.LoadTest: a load-test dummy (;acloadtest) - checks run and are
-- timed, but its flags are only counted, never scored or stored.
function DetectionEngine.Track(player: Player, opts: { LoadTest: boolean? }?)
	if tracked[player.UserId] then
		return
	end
	tracked[player.UserId] = { Player = player, LoadTest = opts ~= nil and opts.LoadTest == true }
	rebuildJobs()
end

function DetectionEngine.Untrack(player: Player)
	tracked[player.UserId] = nil
	scratch[player.UserId] = nil
	events[player.UserId] = nil
	snapshots[player.UserId] = nil
	rebuildJobs()
end

-- New character: fresh per-module scratch (baselines are per character).
function DetectionEngine.ResetScratch(userId: number)
	scratch[userId] = nil
end

local function sample(player: Player, now: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		EvidenceService.AddSample(player.UserId, now, root.Position, root.AssemblyLinearVelocity)
	end
	refreshSnapshot(player, now)
end

-- Gather then Check (a named function: no closure per check).
local function runModule(def: any, player: Player, state: any): any
	if def.Gather then
		def.Gather(player, state, DetectionEngine.Context)
	end
	return def.Check(player, state)
end

local function runCheck(job: any, now: number, moduleCfg: any)
	local def = job.Def
	local player = job.Player
	if moduleCfg.Enabled == false then
		return
	end
	local skip = ExemptionService.Check(player.UserId, def.Name, now)
	if skip then
		return
	end
	-- Module grace after spawn (on top of the global spawn grace).
	local info = tracked[player.UserId]
	if info and info.SpawnedAt and (moduleCfg.Grace or 0) > 0 and now - info.SpawnedAt < moduleCfg.Grace then
		return
	end
	-- Hot-path skips the module declared: nothing it measures can happen.
	if def.SkipWhenSeated or def.SkipWhenStill then
		local snap = snapshots[player.UserId]
		if snap and snap.Character == player.Character then
			local why = if def.SkipWhenSeated and (snap.Seated or snap.Frozen) then "seated"
				elseif def.SkipWhenStill and snap.Moved < STILL_STUDS then "still"
				else nil
			if why then
				windowSkipped += 1
				if def.OnSkip then
					local list = EvidenceService.RawSamples(player.UserId)
					local last = list[#list]
					pcall(def.OnSkip, scratchFor(player.UserId, def.Name), why, now, if last then last.T else nil)
				end
				return
			end
		end
	end
	local started = os.clock()
	local state = DetectionEngine.BuildState(player, def, now, moduleCfg)
	local ok, result = pcall(runModule, def, player, state)
	local elapsed = (os.clock() - started) * 1000
	local c = cost[def.Name]
	c.Window += elapsed
	c.Checks += 1
	windowChecks += 1
	if not ok then
		c.Errors += 1
		c.LastError = tostring(result):sub(1, 200)
		return
	end
	if type(result) == "table" then
		if info and info.LoadTest then
			c.Flags += 1
			return
		end
		result.Module = def.Name
		if result.Severity == nil then
			result.Severity = def.Severity
		end
		DetectionEngine.Submit(player, result)
	end
end

local function rollWindow(now: number)
	local span = now - windowStart
	if span < 1 then
		return
	end
	local alpha = 0.3
	local checksMs = 0
	for _, c in pairs(cost) do
		checksMs += c.Window
		c.Ms = c.Ms * (1 - alpha) + (c.Window / span) * alpha
		c.Window = 0
	end
	totalMsPerSecond = totalMsPerSecond * (1 - alpha) + (windowTotal / span) * alpha
	samplingMs = samplingMs * (1 - alpha) + (windowSampling / span) * alpha
	local overhead = math.max(0, windowTotal - checksMs - windowSampling)
	schedulerMs = schedulerMs * (1 - alpha) + (overhead / span) * alpha
	checksPerSecond = windowChecks / span
	deferredPerSecond = windowDeferred / span
	skippedPerSecond = windowSkipped / span
	table.insert(recentWorst, windowWorst)
	if #recentWorst > 10 then
		table.remove(recentWorst, 1)
	end
	windowTotal = 0
	windowChecks = 0
	windowSampling = 0
	windowWorst = 0
	windowDeferred = 0
	windowSkipped = 0
	windowStart = now
	-- Stay under the budget: stretch intervals while over it.
	local budgetMs = AntiCheatConfig.Get("Core").CostBudgetMs or 2
	if stretchLocked then
		costFactor = 1
	elseif totalMsPerSecond > budgetMs then
		costFactor = math.min(MAX_STRETCH, costFactor * 1.25)
	elseif totalMsPerSecond < budgetMs * 0.6 and costFactor > 1 then
		costFactor = math.max(1, costFactor / 1.1)
	end
end

local function step()
	local frameStart = os.clock()
	rollWindow(frameStart)
	local core = AntiCheatConfig.Get("Core")
	if core.Enabled == false or #heap == 0 then
		return
	end
	local maxChecks = core.FrameBudget or 12
	local capMs = core.FrameMsCap or 0.5
	crowdScale = math.max(1, trackedCount / math.max(1, core.CrowdPlayers or 40))
	local stretch = costFactor * crowdScale
	local ran = 0
	while heap[1] and heap[1].NextAt <= frameStart do
		if ran >= maxChecks or (os.clock() - frameStart) * 1000 >= capMs then
			-- Due jobs stay in the heap and run next frame (counted once per frame).
			windowDeferred += 1
			break
		end
		local job = heapPop()
		if tracked[job.UserId] then
			if job.Sample then
				job.NextAt = frameStart + SAMPLE_INTERVAL
				local t0 = os.clock()
				sample(job.Player, frameStart)
				windowSampling += (os.clock() - t0) * 1000
			else
				local moduleCfg = AntiCheatConfig.GetModule(job.Def.Name)
				local interval = moduleCfg.Interval
				if type(interval) ~= "number" then
					interval = job.Def.Interval
				end
				job.NextAt = frameStart + interval * stretch
				ran += 1
				runCheck(job, frameStart, moduleCfg)
			end
			heapPush(job)
		end
	end
	local frameMs = (os.clock() - frameStart) * 1000
	windowTotal += frameMs
	if frameMs > windowWorst then
		windowWorst = frameMs
	end
	if frameMs > peakFrameMs then
		peakFrameMs = frameMs
	end
end

function DetectionEngine.Start()
	if connection then
		return
	end
	connection = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(step)
		if not ok then
			warn("[Sentinel.AntiCheat] engine step failed: " .. tostring(err))
		end
	end)
end

function DetectionEngine.Stop()
	if connection then
		connection:Disconnect()
		connection = nil
	end
end

function DetectionEngine.MarkSpawn(userId: number)
	local info = tracked[userId]
	if info then
		info.SpawnedAt = os.clock()
	end
end

-- Runs one module against a player once, log-only (Modules page "Test").
function DetectionEngine.TestModule(player: Player, name: string): any
	local def = DetectionEngine.GetModule(name)
	if not def then
		return { Ok = false, Message = "Unknown module " .. tostring(name) }
	end
	local now = os.clock()
	local state = DetectionEngine.BuildState(player, def, now)
	-- Use a throwaway scratch so the test never disturbs live baselines.
	state.Module = {}
	local started = os.clock()
	local ok, result = pcall(function()
		if def.Gather then
			def.Gather(player, state, DetectionEngine.Context)
		end
		local first = def.Check(player, state)
		if first == nil then
			-- Second pass: modules that compare against a first sample.
			return def.Check(player, state)
		end
		return first
	end)
	local ms = (os.clock() - started) * 1000
	if not ok then
		return { Ok = false, Message = "Check failed: " .. tostring(result), Ms = ms }
	end
	local skip, why = ExemptionService.Check(player.UserId, def.Name, now)
	if type(result) == "table" then
		result.Module = def.Name
		local flag = DetectionEngine.Submit(player, result, { Test = true })
		return { Ok = true, Flagged = true, Message = ("Would flag: %s (sev %d)"):format(flag.Reason, flag.Severity), Flag = flag, Ms = ms, Exempt = if skip then why else nil }
	end
	return { Ok = true, Flagged = false, Message = "Clean: no flag.", Ms = ms, Exempt = if skip then why else nil }
end

function DetectionEngine.Stats(): any
	local per = {}
	for _, def in ipairs(modules) do
		local c = cost[def.Name]
		per[def.Name] = {
			MsPerSec = math.floor(c.Ms * 1000 + 0.5) / 1000,
			Checks = c.Checks,
			Flags = c.Flags,
			Errors = c.Errors,
			LastError = c.LastError,
		}
	end
	-- Engine work outside the modules, so the bars add up to the total.
	per["(sampling)"] = { MsPerSec = math.floor(samplingMs * 1000 + 0.5) / 1000, Checks = 0, Flags = 0, Errors = 0 }
	per["(scheduler)"] = { MsPerSec = math.floor(schedulerMs * 1000 + 0.5) / 1000, Checks = 0, Flags = 0, Errors = 0 }
	local worst = 0
	for _, w in ipairs(recentWorst) do
		worst = math.max(worst, w)
	end
	local memory = 0
	pcall(function()
		memory = math.floor(Stats:GetTotalMemoryUsageMb())
	end)
	local playerCount = 0
	for _ in pairs(tracked) do
		playerCount += 1
	end
	return {
		MsPerSec = math.floor(totalMsPerSecond * 1000 + 0.5) / 1000,
		ChecksPerSec = math.floor(checksPerSecond * 10 + 0.5) / 10,
		CostFactor = math.floor(costFactor * 100 + 0.5) / 100,
		CrowdScale = math.floor(crowdScale * 100 + 0.5) / 100,
		WorstFrameMs = math.floor(worst * 1000 + 0.5) / 1000, -- last 10 s
		PeakFrameMs = math.floor(peakFrameMs * 1000 + 0.5) / 1000, -- since start
		FrameMsCap = AntiCheatConfig.Get("Core").FrameMsCap,
		DeferredPerSec = math.floor(deferredPerSecond * 10 + 0.5) / 10,
		SkippedPerSec = math.floor(skippedPerSecond * 10 + 0.5) / 10,
		Budget = AntiCheatConfig.Get("Core").CostBudgetMs,
		Running = connection ~= nil,
		Players = playerCount,
		Jobs = #jobs,
		MemoryMb = memory,
		Modules = per,
	}
end

-- Holds the budget stretch at 1x (load tests); false restores normal.
function DetectionEngine.LockStretch(locked: boolean)
	stretchLocked = locked
	if locked then
		costFactor = 1
	end
end

-- Clears the worst-frame records (load tests measure from a clean slate).
function DetectionEngine.ResetPeak()
	peakFrameMs = 0
	table.clear(recentWorst)
end

function DetectionEngine.IsTracked(userId: number): boolean
	return tracked[userId] ~= nil
end

function DetectionEngine.TrackedPlayers(): { Player }
	local out = {}
	for _, info in pairs(tracked) do
		table.insert(out, info.Player)
	end
	return out
end

-- Players already in game are tracked by AntiCheatService.Start.
Players.PlayerRemoving:Connect(function(player: Player)
	if tracked[player.UserId] then
		DetectionEngine.Untrack(player)
	end
end)

return DetectionEngine
