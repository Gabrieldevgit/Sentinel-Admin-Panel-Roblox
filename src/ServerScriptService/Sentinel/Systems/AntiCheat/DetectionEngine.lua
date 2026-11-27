--!strict
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

		Scheduling: one Heartbeat loop. Every (player, module) pair is a job
		with its own next-run time (the module's Interval, staggered at
		start). A frame runs at most Core.FrameBudget jobs; position sampling
		(5 per second per player) runs in the same loop. Cost is measured
		with os.clock per module (ms of server time per second); when the
		total is over Core.CostBudgetMs every interval is stretched (up to
		4x) until the cost fits again.

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
local Logger = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("Logger"))

local DetectionEngine = {}

local SAMPLE_INTERVAL = 0.2
local EVENT_KEEP_SECONDS = 30
local EVENT_MAX = 120

local modules: { any } = {}
local byName: { [string]: any } = {}
local jobs: { any } = {}
local jobIndex = 1
local tracked: { [number]: any } = {}
local scratch: { [number]: { [string]: any } } = {}
local events: { [number]: { [string]: { any } } } = {}
local hooks: { [string]: any } = {}
local connection: RBXScriptConnection? = nil
local flagSeq = 0
local costFactor = 1

-- Per-module cost accounting (rolling one-second windows, smoothed).
local cost: { [string]: { Window: number, Ms: number, Checks: number, Flags: number, Errors: number, LastError: string? } } = {}
local windowStart = os.clock()
local windowTotal = 0
local totalMsPerSecond = 0
local checksPerSecond = 0
local windowChecks = 0

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

function DetectionEngine.BuildState(player: Player, def: any, now: number): any
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local ping = 0
	pcall(function()
		ping = player:GetNetworkPing() * 1000
	end)
	local fps = EvidenceService.ServerFps()
	local grace = AntiCheatConfig.Get("Grace")
	return {
		Player = player,
		UserId = player.UserId,
		Character = character,
		Humanoid = humanoid,
		Root = root,
		Now = now,
		Config = AntiCheatConfig.GetModule(def.Name),
		Ping = ping,
		ServerFps = fps,
		Lag = DetectionEngine.LagFactor(ping, fps, grace),
		Samples = EvidenceService.RawSamples(player.UserId),
		Module = scratchFor(player.UserId, def.Name),
		Flying = player:GetAttribute("SentinelFlying") == true,
		Noclip = player:GetAttribute("SentinelNoclip") == true,
		God = player:GetAttribute("SentinelGod") == true,
		Frozen = player:GetAttribute("SentinelFrozen") == true or (root ~= nil and (root :: BasePart).Anchored),
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
local function rebuildJobs()
	table.clear(jobs)
	local now = os.clock()
	for userId, info in pairs(tracked) do
		for i, def in ipairs(modules) do
			-- Stagger: spread each module's first run over its interval.
			local offset = ((userId % 97) / 97 + i / (#modules + 1)) % 1
			table.insert(jobs, { UserId = userId, Player = info.Player, Def = def, NextAt = now + def.Interval * offset })
		end
		table.insert(jobs, { UserId = userId, Player = info.Player, Sample = true, NextAt = now })
	end
	jobIndex = 1
end

function DetectionEngine.Track(player: Player)
	if tracked[player.UserId] then
		return
	end
	tracked[player.UserId] = { Player = player }
	rebuildJobs()
end

function DetectionEngine.Untrack(player: Player)
	tracked[player.UserId] = nil
	scratch[player.UserId] = nil
	events[player.UserId] = nil
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
end

local function runCheck(job: any, now: number)
	local def = job.Def
	local player = job.Player
	local moduleCfg = AntiCheatConfig.GetModule(def.Name)
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
	local started = os.clock()
	local state = DetectionEngine.BuildState(player, def, now)
	local ok, result = pcall(function()
		if def.Gather then
			def.Gather(player, state, DetectionEngine.Context)
		end
		return def.Check(player, state)
	end)
	local elapsed = (os.clock() - started) * 1000
	local c = cost[def.Name]
	c.Window += elapsed
	c.Checks += 1
	windowTotal += elapsed
	windowChecks += 1
	if not ok then
		c.Errors += 1
		c.LastError = tostring(result):sub(1, 200)
		return
	end
	if type(result) == "table" then
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
	for _, c in pairs(cost) do
		c.Ms = c.Ms * (1 - alpha) + (c.Window / span) * alpha
		c.Window = 0
	end
	totalMsPerSecond = totalMsPerSecond * (1 - alpha) + (windowTotal / span) * alpha
	checksPerSecond = windowChecks / span
	windowTotal = 0
	windowChecks = 0
	windowStart = now
	-- Stay under the budget: stretch intervals while over it.
	local budgetMs = AntiCheatConfig.Get("Core").CostBudgetMs or 2
	if totalMsPerSecond > budgetMs then
		costFactor = math.min(4, costFactor * 1.25)
	elseif totalMsPerSecond < budgetMs * 0.6 and costFactor > 1 then
		costFactor = math.max(1, costFactor / 1.1)
	end
end

local function step()
	local now = os.clock()
	rollWindow(now)
	local core = AntiCheatConfig.Get("Core")
	if core.Enabled == false or #jobs == 0 then
		return
	end
	local budget = core.FrameBudget or 12
	local ran = 0
	local scanned = 0
	local total = #jobs
	while ran < budget and scanned < total do
		if jobIndex > #jobs then
			jobIndex = 1
		end
		local job = jobs[jobIndex]
		jobIndex += 1
		scanned += 1
		if job and job.NextAt <= now then
			if job.Sample then
				job.NextAt = now + SAMPLE_INTERVAL
				sample(job.Player, now)
			else
				job.NextAt = now + job.Def.Interval * costFactor
				ran += 1
				local interval = AntiCheatConfig.GetModule(job.Def.Name).Interval
				if type(interval) == "number" then
					job.NextAt = now + interval * costFactor
				end
				runCheck(job, now)
			end
		end
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
		Budget = AntiCheatConfig.Get("Core").CostBudgetMs,
		Running = connection ~= nil,
		Players = playerCount,
		Jobs = #jobs,
		MemoryMb = memory,
		Modules = per,
	}
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
