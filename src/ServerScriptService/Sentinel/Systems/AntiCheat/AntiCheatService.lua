--!strict
--[[
	AntiCheatService.lua (Sentinel AntiCheat)

	Purpose:
		Boot, module loader, master switch and public API of Sentinel
		AntiCheat - a server-authoritative anti-cheat. The server is the only
		authority: modules measure what the server sees; the client reporter
		only sends untrusted, low-weight hints.

		Start() (called once by init.server):
		  - loads Systems/AntiCheat/Modules (DetectionEngine.LoadModules)
		  - tracks players: spawn / respawn / character load grace, seat-exit
		    grace, and known teleports (a server script setting the root's
		    CFrame or PivotTo - the CFrame change signal never fires for
		    physics) -> teleport grace
		  - an After hook gives grace / notes heals, economy sources and
		    character rebaselines for Sentinel's own staff commands
		  - counts calls on every RemoteEvent in ReplicatedStorage and the
		    shared RateLimiter's drops (RemoteSpamCheck)
		  - records hits from classic "creator" tags (CombatCheck)
		  - the client reporter remote (session token, kind allowlist,
		    rate limit)
		  - cross-server: shares high-severity flags, anti-cheat bans and
		    watched-player joins through CrossServerService (rate capped)
		  - batched DataStore flushes + flush on close

	Game integration API (all optional, all server-side):
		AntiCheatService.RegisterTeleport(player, reason?)   -- before moving a player
		AntiCheatService.NoteHeal(player)                    -- the game healed them
		AntiCheatService.NoteDamage(player, amount)          -- before applying damage
		AntiCheatService.ValidateHit(attacker, victim, { Range?, Cooldown?, Weapon? }) -> (ok, why?)
		AntiCheatService.NoteEconomySource(player, stat, amount)
		AntiCheatService.RegisterTool(player, toolName)
		AntiCheatService.Rebaseline(player)                  -- character changed on purpose
		AntiCheatService.ReportBadArgs(player, remoteName, why)
		AntiCheatService.GuardRemote(remote, spec, handler)  -- validated OnServerEvent
		AntiCheatService.ValidateArgs(args, spec) -> (ok, why?)  (pure)

	Control API (permission checks are done by the callers: AntiCheatBridge
	and Commands/AntiCheat):
		Status(), SetEnabled(on, actor), SetMode(mode, actor), SetPanic(on, actor),
		SetTesting(userId, on, actor), ResetScore(userId, actor), Correct(player, flag),
		LogAction(actor, action, target, message, undo?), Undo(id, actor), ActionLog(limit)
		PushToStaff(kind, data), UnreviewedHigh()
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPack = game:GetService("StarterPack")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(Shared:WaitForChild("EventBus"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local Logger = require(Core:WaitForChild("Logger"))
local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))

local AntiCheatConfig = require(script.Parent:WaitForChild("AntiCheatConfig"))
local DetectionEngine = require(script.Parent:WaitForChild("DetectionEngine"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))
local ExemptionService = require(script.Parent:WaitForChild("ExemptionService"))
local EvidenceService = require(script.Parent:WaitForChild("EvidenceService"))
local ActionService = require(script.Parent:WaitForChild("ActionService"))

local AntiCheatService = {}
AntiCheatService.Started = false

local LIVE = RunService:IsRunning() and RunService:IsServer()

local joinedAt: { [number]: number } = {}
local tokens: { [number]: string } = {}
local playerTools: { [number]: { [string]: boolean } } = {}
local playerAnimations: { [number]: { [string]: boolean } } = {}
local knownTools: { [string]: boolean } = {}
local knownAnimations: { [string]: boolean } = {}
local recentBans: { any } = {}
local lastHit: { [number]: { [string]: number } } = {}
local actionLog: { any } = {}
local undoFns: { [number]: () -> (boolean, string) } = {}
local logSeq = 0
local eventRemote: RemoteEvent? = nil
local crossServer: any = nil
local crossServerError: string? = nil
local crossBucket = { Tokens = 20, At = os.clock() }

-- ---------------------------------------------------------------------------
-- Staff push (Control Center live updates)
-- ---------------------------------------------------------------------------
local function canView(player: Player): boolean
	return PermissionSystem.Has(player, "anticheat.view") and not player:GetAttribute("SentinelBanHold")
end
AntiCheatService.CanView = canView

function AntiCheatService.PushToStaff(kind: string, data: any, node: string?)
	if not eventRemote then
		return
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if canView(p) and (node == nil or PermissionSystem.Has(p, node)) then
			(eventRemote :: RemoteEvent):FireClient(p, kind, data)
		end
	end
end

function AntiCheatService.UnreviewedHigh(): number
	return EvidenceService.Unreviewed(7)
end

local function compact(flag: any): any
	return {
		Id = flag.Id,
		Module = flag.Module,
		Severity = flag.Severity,
		Confidence = flag.Confidence,
		Reason = flag.Reason,
		UserId = flag.UserId,
		Name = flag.Name,
		Time = flag.Time,
		Points = flag.Points,
		ScoreAfter = flag.ScoreAfter,
		Server = flag.Server,
		Action = flag.Action,
		ActionResult = flag.ActionResult,
		Reviewed = flag.Reviewed,
		FalsePositive = flag.FalsePositive,
		Remote = flag.Remote,
		Testing = flag.Testing,
	}
end
AntiCheatService.Compact = compact

-- ---------------------------------------------------------------------------
-- Action log (Logs page, with undo) - every entry is also an audit-log line
-- ---------------------------------------------------------------------------
function AntiCheatService.LogAction(actor: any, action: string, target: string?, message: string, undo: (() -> (boolean, string))?, extra: any?): any
	logSeq += 1
	local entry = {
		Id = logSeq,
		Time = os.time(),
		Actor = if actor then tostring(actor.Name) else "SYSTEM",
		ActorId = if actor then actor.UserId else 0,
		Action = action,
		Target = target,
		Message = message,
		Old = extra and extra.Old,
		New = extra and extra.New,
		CanUndo = undo ~= nil,
	}
	table.insert(actionLog, 1, entry)
	while #actionLog > 300 do
		local old = table.remove(actionLog)
		if old then
			undoFns[old.Id] = nil
		end
	end
	if undo then
		undoFns[logSeq] = undo
	end
	Logger.Write({
		Executor = if actor then tostring(actor.UserId) else "SYSTEM",
		ExecutorName = entry.Actor,
		Command = "anticheat." .. action,
		Action = "anticheat." .. action,
		Arguments = {},
		Target = target,
		Result = "Success",
		Severity = "Info",
		Message = message,
		Changes = if extra and (extra.Old ~= nil or extra.New ~= nil)
			then { { Target = target or "AntiCheat", Field = action, Before = tostring(extra.Old), After = tostring(extra.New) } }
			else nil,
		Source = "anticheat",
	} :: any)
	AntiCheatService.PushToStaff("log", entry)
	return entry
end

function AntiCheatService.ActionLog(limit: number?): { any }
	local out = {}
	for i = 1, math.min(#actionLog, limit or 300) do
		local e = table.clone(actionLog[i])
		e.CanUndo = undoFns[e.Id] ~= nil
		table.insert(out, e)
	end
	return out
end

function AntiCheatService.Undo(id: number, actor: any): (boolean, string)
	local fn = undoFns[id]
	if not fn then
		return false, "That action can't be undone (or was undone already)."
	end
	undoFns[id] = nil
	local ok, done, message = pcall(fn)
	if not ok then
		return false, "Undo failed: " .. tostring(done)
	end
	local original
	for _, e in ipairs(actionLog) do
		if e.Id == id then
			original = e
			e.CanUndo = false
			e.Undone = true
		end
	end
	AntiCheatService.LogAction(actor, "undo", original and original.Target, ("Undid #%d (%s): %s"):format(id, original and original.Action or "?", tostring(message)))
	return done ~= false, tostring(message)
end

-- ---------------------------------------------------------------------------
-- Status + master controls
-- ---------------------------------------------------------------------------
function AntiCheatService.Status(): any
	local core = AntiCheatConfig.Get("Core")
	local stats = DetectionEngine.Stats()
	local stores = { EvidenceService.Health(), ExemptionService.Health() }
	local warnings = {}
	for _, h in ipairs(stores) do
		if not h.Ok then
			table.insert(warnings, ("%s failing (%s) - data kept in memory"):format(h.Name, tostring(h.LastError)))
		end
	end
	if crossServerError then
		table.insert(warnings, "Cross-server messaging unavailable: " .. crossServerError)
	end
	if stats.MsPerSec > (core.CostBudgetMs or 2) then
		table.insert(warnings, ("Checks cost %.2f ms/s, over the %.1f ms budget (intervals stretched x%.2f)"):format(stats.MsPerSec, core.CostBudgetMs, stats.CostFactor))
	end
	local health = if not core.Enabled then "Off" elseif #warnings > 0 then "Degraded" else "Healthy"
	local enabledModules = 0
	for _, def in ipairs(DetectionEngine.Modules()) do
		if AntiCheatConfig.GetModule(def.Name).Enabled ~= false then
			enabledModules += 1
		end
	end
	return {
		Enabled = core.Enabled,
		Mode = core.Mode,
		Panic = core.Panic,
		SetupDone = core.SetupDone,
		Health = health,
		Warnings = warnings,
		Modules = #DetectionEngine.Modules(),
		EnabledModules = enabledModules,
		MsPerSec = stats.MsPerSec,
		Budget = core.CostBudgetMs,
		Unreviewed = EvidenceService.Unreviewed(),
		UnreviewedHigh = AntiCheatService.UnreviewedHigh(),
		OpenReviews = ActionService.OpenReviews(),
		Stores = stores,
		CrossServer = { Ok = crossServer ~= nil and crossServerError == nil, Error = crossServerError },
	}
end

local function pushStatus()
	AntiCheatService.PushToStaff("status", AntiCheatService.Status())
end
AntiCheatService.PushStatus = pushStatus

local function setCore(field: string, value: any, actor: any, action: string): (boolean, string)
	local before = AntiCheatConfig.Get("Core")[field]
	local ok, message = AntiCheatConfig.SetValue("Core." .. field, value, actor)
	if ok and tostring(before) ~= tostring(AntiCheatConfig.Get("Core")[field]) then
		AntiCheatService.LogAction(actor, action, "AntiCheat", message, function()
			return AntiCheatConfig.SetValue("Core." .. field, before, actor)
		end, { Old = before, New = value })
		pushStatus()
	end
	return ok, message
end

function AntiCheatService.SetEnabled(on: boolean, actor: any): (boolean, string)
	local ok, message = setCore("Enabled", on == true, actor, "master")
	return ok, if ok then ("Anti-cheat turned %s."):format(if on then "on" else "off") else message
end

function AntiCheatService.SetMode(mode: string, actor: any): (boolean, string)
	local ok, message = setCore("Mode", tostring(mode):lower(), actor, "mode")
	return ok, if ok then ("Mode set to %s."):format(tostring(mode):lower()) else message
end

function AntiCheatService.SetPanic(on: boolean, actor: any): (boolean, string)
	local ok, message = setCore("Panic", on == true, actor, "panic")
	if ok and on then
		local AlertService = require(Systems:WaitForChild("AlertService")) :: any
		pcall(AlertService.Raise, {
			Kind = "anticheat",
			Severity = "critical",
			Title = "AntiCheat panic",
			Text = "All automatic anti-cheat actions are off. Detections keep logging.",
			Actor = if actor then actor.Name else nil,
		})
	end
	return ok, if ok then (if on then "PANIC: all automatic actions are off; detections keep logging." else "Panic off: automatic actions are back.") else message
end

function AntiCheatService.SetTesting(userId: number, name: string, on: boolean, actor: any): (boolean, string)
	local was = ExemptionService.IsTesting(userId)
	ExemptionService.SetTesting(userId, on, if actor then actor.Name else "SYSTEM")
	AntiCheatService.LogAction(actor, "testing", name, ("Testing mode %s for %s"):format(if on then "on" else "off", name), function()
		ExemptionService.SetTesting(userId, was, "undo")
		return true, ("testing mode %s again"):format(if was then "on" else "off")
	end, { Old = was, New = on })
	return true, ("Testing mode %s for %s: all checks log only."):format(if on then "on" else "off", name)
end

function AntiCheatService.ResetScore(userId: number, name: string, actor: any): (boolean, string)
	local old = ScoreService.Reset(userId)
	AntiCheatService.LogAction(actor, "score.reset", name, ("Reset %s's score (was %d)"):format(name, math.floor(old)), function()
		ScoreService.Set(userId, old)
		return true, ("score restored to %d"):format(math.floor(old))
	end, { Old = math.floor(old), New = 0 })
	return true, ("Reset %s's score (was %d)."):format(name, math.floor(old))
end

-- ---------------------------------------------------------------------------
-- Silent correction
-- ---------------------------------------------------------------------------
function AntiCheatService.Correct(player: Player, flag: any): boolean
	local character = player.Character
	if not character then
		return false
	end
	if flag.Correct == "position" then
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local samples = EvidenceService.RawSamples(player.UserId)
		if not root or #samples == 0 then
			return false
		end
		local target = samples[1]
		local cutoff = os.clock() - 1.5
		for i = #samples, 1, -1 do
			if samples[i].T <= cutoff then
				target = samples[i]
				break
			end
		end
		ExemptionService.MarkGrace(player.UserId, 2, "movement", "correction")
		DetectionEngine.Note(player.UserId, "teleport", { Reason = "correction" })
		character:PivotTo(CFrame.new(target.P + Vector3.new(0, 0.5, 0)) * root.CFrame.Rotation)
		return true
	elseif flag.Correct == "health" and type(flag.RestoreHealth) == "number" then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > flag.RestoreHealth then
			humanoid.Health = flag.RestoreHealth
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Game integration API
-- ---------------------------------------------------------------------------
function AntiCheatService.RegisterTeleport(player: Player, reason: string?)
	local grace = AntiCheatConfig.Get("Grace")
	ExemptionService.MarkGrace(player.UserId, grace.TeleportGrace or 3, "movement", reason or "teleport")
	DetectionEngine.Note(player.UserId, "teleport", { Reason = reason })
end

function AntiCheatService.NoteHeal(player: Player)
	DetectionEngine.Note(player.UserId, "heal")
end

function AntiCheatService.NoteDamage(player: Player, amount: number)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and type(amount) == "number" and amount > 0 then
		DetectionEngine.Note(player.UserId, "damage", { Amount = amount, Before = humanoid.Health })
	end
end

function AntiCheatService.NoteEconomySource(player: Player, stat: string?, amount: number?)
	DetectionEngine.Note(player.UserId, "economySource", { Stat = stat or "*", Amount = amount })
end

function AntiCheatService.RegisterTool(player: Player, toolName: string)
	local set = playerTools[player.UserId]
	if not set then
		set = {}
		playerTools[player.UserId] = set
	end
	set[toolName] = true
end

function AntiCheatService.Rebaseline(player: Player)
	DetectionEngine.Note(player.UserId, "baseline")
end

function AntiCheatService.ReportBadArgs(player: Player, remoteName: string, why: string)
	DetectionEngine.Note(player.UserId, "badArgs", { Name = tostring(remoteName):sub(1, 60), Why = tostring(why):sub(1, 80) })
end

local function rootOf(target: any): BasePart?
	local model = target
	if typeof(target) == "Instance" and target:IsA("Player") then
		model = target.Character
	elseif typeof(target) == "Instance" and target:IsA("Humanoid") then
		model = target.Parent
	end
	if typeof(model) ~= "Instance" then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return if model:IsA("Model") then model.PrimaryPart else nil
end

-- For the game's own damage code. Records the hit for CombatCheck and
-- says whether it looks valid (the game may refuse invalid hits).
function AntiCheatService.ValidateHit(attacker: Player, victim: any, info: any?): (boolean, string?)
	local opts = if type(info) == "table" then info else {}
	local a, v = rootOf(attacker), rootOf(victim)
	if not a or not v then
		return false, "missing character"
	end
	local distance = (a.Position - v.Position).Magnitude
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { a.Parent :: Instance, v.Parent :: Instance }
	local blocker = Workspace:Raycast(a.Position, v.Position - a.Position, params)
	local los = not (blocker and blocker.Instance.CanCollide and blocker.Instance.Transparency < 0.9)
	local weapon = tostring(opts.Weapon or "default")
	local perWeapon = lastHit[attacker.UserId]
	if not perWeapon then
		perWeapon = {}
		lastHit[attacker.UserId] = perWeapon
	end
	local now = os.clock()
	local since = if perWeapon[weapon] then now - perWeapon[weapon] else nil
	perWeapon[weapon] = now
	DetectionEngine.Note(attacker.UserId, "hit", {
		Distance = distance,
		Range = tonumber(opts.Range),
		LineOfSight = los,
		Cooldown = tonumber(opts.Cooldown),
		Since = since,
		Weapon = weapon,
	})
	local range = (tonumber(opts.Range) or AntiCheatConfig.GetModule("CombatCheck").MaxRange or 20) * 1.5 + 4
	if distance > range then
		return false, "out of range"
	elseif not los then
		return false, "no line of sight"
	elseif opts.Cooldown and since and since < opts.Cooldown * 0.7 then
		return false, "too fast"
	end
	return true, nil
end

-- Pure argument validation. spec = list of "type[:max]" / "type?" (optional)
-- e.g. { "string:50", "number:0:100", "table:20", "boolean?" }.
function AntiCheatService.ValidateArgs(args: { any }, spec: { string }): (boolean, string?)
	local n = if type(args) == "table" then (args.n or #args) else 0
	if n > #spec then
		return false, ("too many arguments (%d > %d)"):format(n, #spec)
	end
	for i, rule in ipairs(spec) do
		local optional = rule:sub(-1) == "?"
		local parts = string.split(if optional then rule:sub(1, -2) else rule, ":")
		local kind = parts[1]
		local value = args[i]
		if value == nil then
			if not optional then
				return false, ("argument %d is missing (nil)"):format(i)
			end
		elseif kind ~= "any" and typeof(value) ~= kind then
			return false, ("argument %d should be %s, got %s"):format(i, kind, typeof(value))
		elseif kind == "string" and parts[2] and #value > tonumber(parts[2]) :: number then
			return false, ("argument %d is too long (%d)"):format(i, #value)
		elseif kind == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return false, ("argument %d is not a finite number"):format(i)
			end
			local min, max = tonumber(parts[2]), tonumber(parts[3])
			if (min and value < min) or (max and value > max) then
				return false, ("argument %d out of range"):format(i)
			end
		elseif kind == "table" then
			local count = 0
			for _ in pairs(value) do
				count += 1
				if count > (tonumber(parts[2]) or 50) then
					return false, ("argument %d table is too big"):format(i)
				end
			end
		end
	end
	return true, nil
end

function AntiCheatService.GuardRemote(remote: RemoteEvent, spec: { string }, handler: (Player, ...any) -> ())
	local limiter = RateLimiter.new("Guard:" .. remote.Name, 20, 10)
	remote.OnServerEvent:Connect(function(player: Player, ...)
		if not limiter:Allow(player) then
			return
		end
		local args = table.pack(...)
		local ok, why = AntiCheatService.ValidateArgs(args, spec)
		if not ok then
			AntiCheatService.ReportBadArgs(player, remote.Name, why or "invalid")
			return
		end
		handler(player, ...)
	end)
end

-- ---------------------------------------------------------------------------
-- Context for module Gather functions
-- ---------------------------------------------------------------------------
local function scanCatalog()
	table.clear(knownTools)
	table.clear(knownAnimations)
	for _, root in ipairs({ StarterPack, ServerStorage, ReplicatedStorage, Lighting, StarterPlayer }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BackpackItem") then
				knownTools[d.Name] = true
			elseif d:IsA("Animation") then
				knownAnimations[d.AnimationId] = true
			end
		end
	end
end

local ctx = DetectionEngine.Context
ctx.Events = DetectionEngine.Events
ctx.LastEvent = DetectionEngine.LastEvent
ctx.JoinedAt = function(userId: number): number?
	return joinedAt[userId]
end
ctx.KnownTools = function(player: Player): { [string]: boolean }
	local out = table.clone(knownTools)
	for name in pairs(playerTools[player.UserId] or {}) do
		out[name] = true
	end
	local gear = player:FindFirstChild("StarterGear")
	if gear then
		for _, t in ipairs(gear:GetChildren()) do
			out[t.Name] = true
		end
	end
	return out
end
ctx.KnownAnimations = function(player: Player): { [string]: boolean }
	local out = table.clone(knownAnimations)
	for id in pairs(playerAnimations[player.UserId] or {}) do
		out[id] = true
	end
	return out
end
ctx.RecentBans = function(windowSeconds: number): { any }
	local out = {}
	local cutoff = os.time() - windowSeconds
	for _, b in ipairs(recentBans) do
		if b.Time >= cutoff then
			table.insert(out, b)
		end
	end
	return out
end

local function noteBan(userId: number, name: string)
	table.insert(recentBans, 1, { UserId = userId, Name = name, Time = os.time() })
	while #recentBans > 30 do
		table.remove(recentBans)
	end
end
AntiCheatService.NoteBan = noteBan

-- ---------------------------------------------------------------------------
-- Cross-server
-- ---------------------------------------------------------------------------
local function crossAllowed(): boolean
	local cfg = AntiCheatConfig.Get("CrossServer")
	local perMinute = cfg.MaxPerMinute or 20
	local now = os.clock()
	crossBucket.Tokens = math.min(perMinute, crossBucket.Tokens + (now - crossBucket.At) * perMinute / 60)
	crossBucket.At = now
	if crossBucket.Tokens < 1 then
		return false
	end
	crossBucket.Tokens -= 1
	return true
end

local function crossSend(kind: string, payload: any)
	if not crossServer or not crossAllowed() then
		return
	end
	task.spawn(function()
		local ok, err = pcall(crossServer.Send, kind, payload, { Quiet = true })
		if not ok then
			crossServerError = tostring(err):sub(1, 120)
		end
	end)
end

local function setupCrossServer()
	local ok, service = pcall(function()
		return require(Systems:WaitForChild("CrossServerService", 5) :: ModuleScript)
	end)
	if not ok or type(service) ~= "table" then
		crossServerError = "CrossServerService did not load"
		return
	end
	crossServer = service
	pcall(service.Handle, "acflag", function(payload: any)
		if type(payload) ~= "table" or type(payload.Id) ~= "string" then
			return false, 0, "bad payload"
		end
		local flag = {
			Id = payload.Id:sub(1, 40),
			Module = tostring(payload.Module):sub(1, 40),
			Severity = math.clamp(tonumber(payload.Severity) or 1, 1, 10),
			Confidence = math.clamp(tonumber(payload.Confidence) or 0, 0, 1),
			Reason = tostring(payload.Reason):sub(1, 200),
			UserId = tonumber(payload.UserId) or 0,
			Name = tostring(payload.Name):sub(1, 40),
			Time = tonumber(payload.Time) or os.time(),
			ScoreAfter = tonumber(payload.ScoreAfter) or 0,
			Server = tostring(payload.Server):sub(1, 40),
		}
		EvidenceService.RecordRemote(flag)
		AntiCheatService.PushToStaff("flag", compact(flag))
		return true, 0, nil
	end)
	pcall(service.Handle, "acban", function(payload: any)
		if type(payload) ~= "table" or type(payload.UserId) ~= "number" then
			return false, 0, "bad payload"
		end
		noteBan(payload.UserId, tostring(payload.Name))
		local player = Players:GetPlayerByUserId(payload.UserId)
		if player then
			player:Kick("Banned: " .. tostring(payload.Reason or "Sentinel AntiCheat"))
			return true, 1, "removed " .. player.Name
		end
		return true, 0, "not here"
	end)
	pcall(service.Handle, "acwatch", function(payload: any)
		if type(payload) ~= "table" then
			return false, 0, "bad payload"
		end
		AntiCheatService.PushToStaff("alert", {
			Title = "Watched player joined",
			Text = ("%s joined server %s (watched: %s)"):format(tostring(payload.Name), tostring(payload.Server), tostring(payload.Why)),
			Severity = "warning",
			Time = os.time(),
		})
		return true, 0, nil
	end)
end

-- ---------------------------------------------------------------------------
-- Flag hook: alerts, cross-server sharing, staff push
-- ---------------------------------------------------------------------------
local function onFlag(flag: any, decision: any, _result: string?)
	AntiCheatService.PushToStaff("flag", compact(flag))
	local alerts = AntiCheatConfig.Get("Alerts")
	local alreadyAlerted = decision ~= nil and decision.Action == "alert"
	if flag.Severity >= (alerts.MinSeverity or 5) and not alreadyAlerted then
		AntiCheatService.PushToStaff("alert", {
			Title = ("AntiCheat: %s"):format(flag.Name),
			Text = ("%s - %s (sev %d)"):format(flag.Module, flag.Reason, flag.Severity),
			Severity = if flag.Severity >= 7 then "critical" else "warning",
			FlagId = flag.Id,
			Time = flag.Time,
		}, "anticheat." .. (alerts.Notify or "view"))
	end
	local cross = AntiCheatConfig.Get("CrossServer")
	if cross.ShareAlerts and flag.Severity >= (cross.ShareMinSeverity or 7) then
		crossSend("acflag", compact(flag))
	end
	pushStatus()
end

-- ---------------------------------------------------------------------------
-- Player lifecycle
-- ---------------------------------------------------------------------------
local function onCharacter(player: Player, character: Model)
	local grace = AntiCheatConfig.Get("Grace")
	ExemptionService.MarkGrace(player.UserId, grace.SpawnGrace or 3, "all", "spawn")
	DetectionEngine.ResetScratch(player.UserId)
	DetectionEngine.MarkSpawn(player.UserId)
	DetectionEngine.Note(player.UserId, "spawn")
	DetectionEngine.Note(player.UserId, "teleport", { Reason = "spawn" })

	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not root or not humanoid or character.Parent == nil then
		return
	end
	-- Fired only for script writes (CFrame / PivotTo), never for physics:
	-- every server-side move of the character is a known teleport.
	local lastMark = 0
	root:GetPropertyChangedSignal("CFrame"):Connect(function()
		if os.clock() - lastMark > 0.1 then
			lastMark = os.clock()
			AntiCheatService.RegisterTeleport(player, "server move")
		end
	end)
	humanoid.Seated:Connect(function(active: boolean)
		if not active then
			ExemptionService.MarkGrace(player.UserId, AntiCheatConfig.Get("Grace").SeatGrace or 3, "movement", "seat exit")
		end
	end)
	-- Hits from classic "creator" tags (CombatCheck input) - every humanoid,
	-- tagged by the attacker's tool.
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth then
			local tag = humanoid:FindFirstChild("creator")
			local attacker = tag and tag:IsA("ObjectValue") and tag.Value
			if attacker and attacker:IsA("Player") and attacker ~= player then
				local a = rootOf(attacker)
				if a then
					DetectionEngine.Note(attacker.UserId, "hit", { Distance = (a.Position - root.Position).Magnitude, Weapon = "creator" })
				end
			end
		end
		lastHealth = health
	end)
	-- Animations the character ships with (Animate script) are allowed.
	task.delay(1, function()
		local set = playerAnimations[player.UserId] or {}
		playerAnimations[player.UserId] = set
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("Animation") then
				set[d.AnimationId] = true
			end
		end
	end)
end

local function onPlayerAdded(player: Player)
	joinedAt[player.UserId] = os.clock()
	tokens[player.UserId] = HttpService:GenerateGUID(false)
	DetectionEngine.Track(player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
	task.spawn(function()
		local watched = ExemptionService.Load(player.UserId, player.Name)
		if watched and AntiCheatConfig.Get("Alerts").WatchAlerts then
			local server = Logger.GetServerId()
			local short = if server:sub(1, 7) == "studio-" then server else server:sub(1, 8)
			local alert = {
				Title = "Watched player joined",
				Text = ("%s joined this server (watched: %s)"):format(player.Name, tostring(watched.Why)),
				Severity = "warning",
				Time = os.time(),
			}
			AntiCheatService.PushToStaff("alert", alert)
			local AlertService = require(Systems:WaitForChild("AlertService")) :: any
			pcall(AlertService.Raise, { Kind = "anticheat", Severity = "warning", Title = alert.Title, Text = alert.Text })
			crossSend("acwatch", { Name = player.Name, UserId = player.UserId, Server = short, Why = watched.Why })
		end
	end)
end

local function onPlayerRemoving(player: Player)
	joinedAt[player.UserId] = nil
	tokens[player.UserId] = nil
	playerTools[player.UserId] = nil
	playerAnimations[player.UserId] = nil
	lastHit[player.UserId] = nil
	ExemptionService.Forget(player.UserId)
	EvidenceService.Forget(player.UserId)
	-- The score is per session; keep it a minute in case they rejoin this server.
	task.delay(60, function()
		if not Players:GetPlayerByUserId(player.UserId) then
			ScoreService.Forget(player.UserId)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Sentinel staff commands are legitimate game mechanics
-- ---------------------------------------------------------------------------
local MOVE_COMMANDS = {
	tp = true, teleport = true, bring = true, goto = true, to = true, spawn = true, respawn = true,
	refresh = true, re = true, jail = true, unjail = true, fling = true, trip = true, sit = true,
	jump = true, speed = true, resetspeed = true, freeze = true, unfreeze = true, control = true, uncontrol = true,
	fly = true, unfly = true, noclip = true, clip = true, size = true, scale = true, ragdoll = true,
}
local HEAL_COMMANDS = { heal = true, god = true, ungod = true, health = true, sethealth = true, maxhealth = true, respawn = true, refresh = true }
local CHARACTER_COMMANDS = {
	size = true, scale = true, r6 = true, r15 = true, char = true, morph = true, removelimbs = true, unchar = true,
	pumpkin = true, ghost = true, unspooky = true, clearseasonal = true, invisible = true, visible = true, head = true,
}

local function afterCommand(def: any, cmdCtx: any, result: any)
	if type(result) ~= "table" or not result.Success then
		return
	end
	local name = tostring(def.Name):lower()
	local category = tostring(def.Category or "")
	local targets = {}
	for _, t in ipairs(cmdCtx.Targets or {}) do
		if typeof(t) == "Instance" and t:IsA("Player") then
			table.insert(targets, t)
		end
	end
	if name == "goto" or name == "to" then
		table.insert(targets, cmdCtx.Executor)
	end
	local grace = AntiCheatConfig.Get("Grace")
	for _, p in ipairs(targets) do
		if typeof(p) == "Instance" and p:IsA("Player") then
			if MOVE_COMMANDS[name] or category == "Movement" then
				AntiCheatService.RegisterTeleport(p, "staff command ;" .. name)
			elseif category == "Player" then
				ExemptionService.MarkGrace(p.UserId, grace.TeleportGrace or 3, "all", "staff command ;" .. name)
			end
			if HEAL_COMMANDS[name] then
				AntiCheatService.NoteHeal(p)
			end
			if CHARACTER_COMMANDS[name] or category == "Player" then
				AntiCheatService.Rebaseline(p)
			end
			if category == "Economy" or category == "Inventory" then
				AntiCheatService.NoteEconomySource(p, "*", math.huge)
				ExemptionService.MarkGrace(p.UserId, 5, "ToolIntegrityCheck", "staff command ;" .. name)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Remote watching (RemoteSpamCheck)
-- ---------------------------------------------------------------------------
local watchedRemotes: { [Instance]: boolean } = {}
local remoteCalls = { Window = 0, Since = os.clock(), Rate = 0 }

-- Calls per second on the game's RemoteEvents (Analytics > Performance).
function AntiCheatService.RemoteCallsPerSecond(): number
	local span = os.clock() - remoteCalls.Since
	if span >= 2 then
		remoteCalls.Rate = remoteCalls.Window / span
		remoteCalls.Window = 0
		remoteCalls.Since = os.clock()
	end
	return math.floor(remoteCalls.Rate * 10 + 0.5) / 10
end

local function watchRemote(remote: Instance)
	if watchedRemotes[remote] or not remote:IsA("RemoteEvent") then
		return
	end
	watchedRemotes[remote] = true
	local name = remote.Name
	remote.OnServerEvent:Connect(function(player: Player)
		remoteCalls.Window += 1
		DetectionEngine.Note(player.UserId, "remote", { Name = name })
	end)
end

-- ---------------------------------------------------------------------------
-- Client reporter (untrusted hints)
-- ---------------------------------------------------------------------------
local REPORT_KINDS = { core_missing = true, reporter_restarted = true, gui_injected = true, humanoid_state = true }

local function setupReporter(shared: Instance)
	local remote = shared:FindFirstChild("AntiCheatReportRemote")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "AntiCheatReportRemote"
		remote.Parent = shared
	end
	local limiter = RateLimiter.new("AntiCheatReportRemote", 6, 0.5)
	local r = remote :: RemoteEvent
	r.OnServerEvent:Connect(function(player: Player, kind: any, token: any, reportKind: any, detail: any)
		if not limiter:Allow(player) then
			return
		end
		if kind == "hello" then
			r:FireClient(player, "token", tokens[player.UserId])
			return
		end
		if type(token) ~= "string" or token ~= tokens[player.UserId] then
			AntiCheatService.ReportBadArgs(player, "AntiCheatReportRemote", "bad session token")
			return
		end
		if kind == "hb" then
			DetectionEngine.Note(player.UserId, "clientHeartbeat")
		elseif kind == "report" and type(reportKind) == "string" and REPORT_KINDS[reportKind] then
			DetectionEngine.Note(player.UserId, "clientReport", {
				Kind = reportKind,
				Detail = if type(detail) == "string" then detail:sub(1, 100) else nil,
			})
		else
			AntiCheatService.ReportBadArgs(player, "AntiCheatReportRemote", "unknown report")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------
function AntiCheatService.Start()
	if AntiCheatService.Started then
		return
	end
	AntiCheatService.Started = true
	local count = DetectionEngine.LoadModules(script.Parent:WaitForChild("Modules"))

	ExemptionService.SetRankProvider(function(userId: number): (boolean, string?)
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			return false, nil
		end
		local rankName = AntiCheatConfig.Get("Core").ExemptRank
		if type(rankName) ~= "string" or rankName == "" or rankName:lower() == "none" then
			return false, nil
		end
		local RankService = require(Systems:WaitForChild("RankService")) :: any
		local rank = RankService.GetRank(rankName)
		if not rank then
			return false, nil
		end
		local priority = RankService.GetPriority(player)
		if priority >= rank.Priority then
			return true, RankService.GetTopRank(player)
		end
		return false, nil
	end)

	ActionService.SetProviders({
		Correct = AntiCheatService.Correct,
		Alert = function(entry: any)
			local AlertService = require(Systems:WaitForChild("AlertService")) :: any
			AlertService.Raise({ Kind = "anticheat", Severity = entry.Severity, Title = entry.Title, Text = entry.Text })
			entry.Time = os.time()
			AntiCheatService.PushToStaff("alert", entry, "anticheat." .. (AntiCheatConfig.Get("Alerts").Notify or "view"))
		end,
		Push = function(kind: string, data: any)
			AntiCheatService.PushToStaff(kind, data)
		end,
		ShareBan = function(target: any, reason: string)
			noteBan(target.UserId, target.Name)
			if AntiCheatConfig.Get("CrossServer").ShareBans then
				crossSend("acban", { UserId = target.UserId, Name = target.Name, Reason = reason })
			end
		end,
	})
	DetectionEngine.SetHooks({ OnFlag = onFlag })
	CommandRegistry.AddHook("After", afterCommand, "AntiCheat")

	EventBus.Subscribe("Player.Banned", function(target: any)
		if typeof(target) == "Instance" and target:IsA("Player") then
			noteBan(target.UserId, target.Name)
		end
	end)

	if not LIVE then
		return
	end

	eventRemote = Shared:FindFirstChild("AntiCheatEvent") :: RemoteEvent?
	if not eventRemote then
		local r = Instance.new("RemoteEvent")
		r.Name = "AntiCheatEvent"
		r.Parent = Shared
		eventRemote = r
	end
	setupReporter(Shared)

	RateLimiter.SetDropListener(function(player: Player, limiterName: string)
		DetectionEngine.Note(player.UserId, "remoteDrop", { Name = limiterName })
	end)
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		watchRemote(d)
	end
	ReplicatedStorage.DescendantAdded:Connect(watchRemote)

	scanCatalog()
	task.spawn(function()
		while true do
			task.wait(60)
			scanCatalog()
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, p)
	end

	task.spawn(setupCrossServer)
	DetectionEngine.Start()

	-- Batched DataStore writes.
	task.spawn(function()
		while true do
			task.wait(AntiCheatConfig.Get("Storage").FlushSeconds or 30)
			pcall(EvidenceService.Flush)
			pcall(ExemptionService.Flush)
		end
	end)
	game:BindToClose(function()
		pcall(EvidenceService.Flush)
		pcall(ExemptionService.Flush)
	end)

	-- Config changes on any server reach staff UIs here.
	AntiCheatConfig.Changed:Connect(function(key: string)
		if key == "Core" then
			pushStatus()
		end
		AntiCheatService.PushToStaff("config", key)
	end)

	print(("[Sentinel] AntiCheat started: %d modules, mode %s."):format(count, tostring(AntiCheatConfig.Get("Core").Mode)))
end

return AntiCheatService
