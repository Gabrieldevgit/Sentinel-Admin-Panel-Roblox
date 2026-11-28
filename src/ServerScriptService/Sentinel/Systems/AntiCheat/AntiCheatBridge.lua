--!strict
--[[
	AntiCheatBridge.lua (Sentinel AntiCheat)

	Purpose:
		Server side of the Anti-Cheat Control Center. UIBridge binds the
		AntiCheatRemote RemoteFunction (rate limited, errors caught) to
		AntiCheatBridge.Handle(player, action, payload). Every action checks
		its permission node HERE, so a client that bypasses the UI and calls
		the remote directly gets the same refusal. Every argument is
		validated (type, size, range) before use; invalid calls are refused
		and counted for RemoteSpamCheck. Every state-changing action writes
		an audit-log entry (AntiCheatService.LogAction).

		Nodes: anticheat.view (read), .review, .exempt, .act, .ban (bans go
		through the ;acban command so Sentinel's owner-approval flow and
		;confirm apply), .config, .master.

	Public API:
		AntiCheatBridge.Handle(player, action, payload) -> { Ok, Message?, ... }
		AntiCheatBridge.ACTIONS  -- action -> required node (tests / docs)
--]]

local Players = game:GetService("Players")

local Sentinel = script.Parent.Parent.Parent
local Systems = Sentinel:WaitForChild("Systems")
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))

local AntiCheatConfig = require(script.Parent:WaitForChild("AntiCheatConfig"))
local AntiCheatService = require(script.Parent:WaitForChild("AntiCheatService"))
local DetectionEngine = require(script.Parent:WaitForChild("DetectionEngine"))
local ScoreService = require(script.Parent:WaitForChild("ScoreService"))
local ExemptionService = require(script.Parent:WaitForChild("ExemptionService"))
local EvidenceService = require(script.Parent:WaitForChild("EvidenceService"))
local ActionService = require(script.Parent:WaitForChild("ActionService"))

local AntiCheatBridge = {}

local V, R, E, A, C, M = "anticheat.view", "anticheat.review", "anticheat.exempt", "anticheat.act", "anticheat.config", "anticheat.master"

AntiCheatBridge.ACTIONS = {
	access = "", -- answers everyone (only says what they may do)
	overview = V, flags = V, flag = V, players = V, player = V, lookup = V, queue = V,
	modules = V, exemptions = V, config = V, analytics = V, logs = V, presetPreview = V,
	audit = V, recommend = V, exportConfig = V,
	markReviewed = R, falsePositive = R, createCase = R, note = R,
	queueDismiss = R, queueAssign = R, queueEscalate = R, queueNote = R,
	exemptAdd = E, exemptRemove = E, exemptExtend = E, watchAdd = E, watchRemove = E, testing = E,
	warn = A, kick = A, correct = A, resetScore = A,
	bans = V, -- checked inside: anticheat.ban or moderation.banlist / moderation.ban
	banLift = "anticheat.ban", banEdit = "anticheat.ban",
	setValue = C, saveSection = C, resetSection = C, resetAll = C, import = C, applyPreset = C,
	moduleToggle = C, moduleWeight = C, moduleTest = C, setMode = C, setPanic = C, exemptRank = C,
	watchAlerts = C, resetModule = C,
	setEnabled = M, finishSetup = M,
	undo = V, -- checked per entry below
}

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------
local function str(v: any, max: number): string?
	if type(v) ~= "string" or #v > max then
		return nil
	end
	return v
end

local function int(v: any, min: number, max: number): number?
	if type(v) ~= "number" or v ~= v or v % 1 ~= 0 or v < min or v > max then
		return nil
	end
	return v
end

local function num(v: any, min: number, max: number): number?
	if type(v) ~= "number" or v ~= v or v < min or v > max then
		return nil
	end
	return v
end

local function userId(v: any): number?
	local id = int(v, -(2 ^ 53 - 1), 2 ^ 53 - 1)
	return if id ~= 0 then id else nil
end

local function bad(player: Player, why: string): any
	AntiCheatService.ReportBadArgs(player, "AntiCheatRemote", why)
	return { Ok = false, Message = "Invalid request: " .. why }
end

local function lazy(name: string): any
	return require(Systems:WaitForChild(name) :: ModuleScript) :: any
end

local function can(player: Player): { [string]: boolean }
	return {
		View = PermissionSystem.Has(player, V),
		Review = PermissionSystem.Has(player, R),
		Exempt = PermissionSystem.Has(player, E),
		Act = PermissionSystem.Has(player, A),
		Ban = PermissionSystem.Has(player, "anticheat.ban"),
		Config = PermissionSystem.Has(player, C),
		Master = PermissionSystem.Has(player, M),
	}
end

local function moduleName(v: any): string?
	local name = str(v, 40)
	if not name then
		return nil
	end
	local def = DetectionEngine.GetModule(name)
	return def and def.Name
end

local function nameOf(id: number): string
	local p = Players:GetPlayerByUserId(id)
	return if p then p.Name else tostring(id)
end

local function rankName(player: Player): string
	local ok, name = pcall(function()
		return lazy("RankService").GetTopRank(player)
	end)
	return if ok and name then name else "-"
end

-- ---------------------------------------------------------------------------
-- Read handlers
-- ---------------------------------------------------------------------------
local function playerStatus(id: number): string
	if ExemptionService.IsTesting(id) then
		return "Testing"
	end
	if #ExemptionService.ForPlayer(id) > 0 then
		return "Exempt"
	end
	if ExemptionService.RankExempt(id) then
		return "Exempt"
	end
	if ExemptionService.IsWatched(id) then
		return "Watched"
	end
	return "Clean"
end

local function playerRow(p: Player): any
	local today = os.time() - os.time() % 86400
	local flags = EvidenceService.ForPlayer(p.UserId, 200)
	local byModule: { [string]: number } = {}
	local countToday = 0
	for _, f in ipairs(flags) do
		if f.Time >= today then
			countToday += 1
		end
		byModule[f.Module] = (byModule[f.Module] or 0) + f.Points
	end
	local top, best = "-", 0
	for m, pts in pairs(byModule) do
		if pts > best then
			top, best = m, pts
		end
	end
	local ping = 0
	pcall(function()
		ping = math.floor(p:GetNetworkPing() * 1000 + 0.5)
	end)
	return {
		UserId = p.UserId,
		Name = p.Name,
		DisplayName = p.DisplayName,
		Score = math.floor(ScoreService.Get(p.UserId, nil, AntiCheatConfig.Get("Scoring")) * 10 + 0.5) / 10,
		TopModule = top,
		FlagsToday = countToday,
		Status = playerStatus(p.UserId),
		Ping = ping,
		Rank = rankName(p),
	}
end

local function fpRates(): { [string]: any }
	local out = {}
	for _, f in ipairs(EvidenceService.List(nil, 2000)) do
		if not f.Remote then
			local r = out[f.Module] or { Reviewed = 0, False = 0, Total = 0 }
			out[f.Module] = r
			r.Total += 1
			if f.Reviewed then
				r.Reviewed += 1
			end
			if f.FalsePositive then
				r.False += 1
			end
		end
	end
	for _, r in pairs(out) do
		r.Rate = if r.Reviewed > 0 then math.floor(r.False / r.Reviewed * 1000 + 0.5) / 10 else 0
	end
	return out
end

local function overview(): any
	local hourAgo = os.time() - 3600
	local flagsHour = #EvidenceService.List({ Since = hourAgo }, 5000)
	local rates = fpRates()
	local reviewed, falses = 0, 0
	for _, r in pairs(rates) do
		reviewed += r.Reviewed
		falses += r.False
	end
	local feed = {}
	for _, f in ipairs(EvidenceService.List(nil, 20)) do
		table.insert(feed, AntiCheatService.Compact(f))
	end
	local stats = DetectionEngine.Stats()
	return {
		Ok = true,
		Cards = {
			FlagsHour = flagsHour,
			Above40 = ScoreService.Above(40, AntiCheatConfig.Get("Scoring")),
			ActionsToday = ActionService.CountToday(),
			AwaitingReview = EvidenceService.Unreviewed() + ActionService.OpenReviews(),
			OpenReviews = ActionService.OpenReviews(),
			CostMs = stats.MsPerSec,
			FalsePositiveRate = if reviewed > 0 then math.floor(falses / reviewed * 1000 + 0.5) / 10 else 0,
		},
		Feed = feed,
		Sparkline = EvidenceService.PerMinute(),
		Status = AntiCheatService.Status(),
	}
end

local function filterFrom(payload: any): any
	local p = if type(payload) == "table" then payload else {}
	local filter = {
		Module = moduleName(p.Module),
		MinSeverity = int(p.MinSeverity, 1, 10),
		MaxSeverity = int(p.MaxSeverity, 1, 10),
		Player = str(p.Player, 40),
		Since = num(p.Since, 0, 2 ^ 40),
		Server = str(p.Server, 40),
		Unreviewed = p.Unreviewed == true,
		UserId = userId(p.UserId),
	}
	if type(p.Modules) == "table" then
		local set = {}
		local n = 0
		for k, v in pairs(p.Modules) do
			n += 1
			if n > 20 then
				break
			end
			local name = moduleName(k)
			if name and v == true then
				set[name] = true
			end
		end
		filter.Modules = set
	end
	return filter
end

local function moduleList(): { any }
	local stats = DetectionEngine.Stats()
	local rates = fpRates()
	local dayAgo = os.time() - 86400
	local counts: { [string]: number } = {}
	for _, f in ipairs(EvidenceService.List({ Since = dayAgo }, 5000)) do
		counts[f.Module] = (counts[f.Module] or 0) + 1
	end
	local out = {}
	for _, def in ipairs(DetectionEngine.Modules()) do
		local cfg = AntiCheatConfig.GetModule(def.Name)
		local schema = {}
		for field, s in pairs(AntiCheatConfig.ModuleSchema(def.Name) or {}) do
			table.insert(schema, { Key = field, Type = s.Type, Min = s.Min, Max = s.Max, Default = s.Default, Description = s.Description })
		end
		table.sort(schema, function(a, b)
			return a.Key < b.Key
		end)
		local perf = stats.Modules[def.Name] or {}
		table.insert(out, {
			Name = def.Name,
			Description = def.Description,
			Severity = def.Severity,
			Enabled = cfg.Enabled ~= false,
			Weight = cfg.Weight,
			Interval = cfg.Interval,
			Config = cfg,
			Schema = schema,
			Flags24h = counts[def.Name] or 0,
			FalsePositiveRate = (rates[def.Name] or {}).Rate or 0,
			MsPerSec = perf.MsPerSec or 0,
			Errors = perf.Errors or 0,
			LastError = perf.LastError,
		})
	end
	return out
end

local function configSnapshot(): any
	local sections = {}
	for _, key in ipairs(AntiCheatConfig.SECTIONS) do
		local fields = {}
		for field, s in pairs(AntiCheatConfig.SCHEMA[key]) do
			table.insert(fields, { Key = field, Type = s.Type, Min = s.Min, Max = s.Max, Choices = s.Choices, Default = s.Default, Description = s.Description })
		end
		table.sort(fields, function(a, b)
			return a.Key < b.Key
		end)
		table.insert(sections, { Key = key, Fields = fields, Values = AntiCheatConfig.Get(key) })
	end
	local ranks = {}
	pcall(function()
		for _, r in ipairs(lazy("RankService").GetRanks()) do
			table.insert(ranks, { Name = r.Name, Priority = r.Priority })
		end
	end)
	table.sort(ranks, function(a, b)
		return a.Priority > b.Priority
	end)
	return { Ok = true, Sections = sections, Ranks = ranks, Presets = { "Observe", "Balanced", "Strict" } }
end

local function analytics(payload: any): any
	local p = if type(payload) == "table" then payload else {}
	local hours = if p.Range == "1h" then 1 elseif p.Range == "7d" then 168 else 24
	local filter = filterFrom({ Modules = p.Modules })
	local counts = EvidenceService.Counts(hours, filter.Modules)
	local since = os.time() - hours * 3600
	local byPlayer: { [number]: any } = {}
	for _, f in ipairs(EvidenceService.List({ Since = since, Modules = filter.Modules }, 5000)) do
		local e = byPlayer[f.UserId] or { UserId = f.UserId, Name = f.Name, Flags = 0, Points = 0 }
		byPlayer[f.UserId] = e
		e.Flags += 1
		e.Points += f.Points or 0
	end
	local top = {}
	for _, e in pairs(byPlayer) do
		table.insert(top, e)
	end
	table.sort(top, function(a, b)
		return a.Flags > b.Flags
	end)
	while #top > 10 do
		table.remove(top)
	end
	local status = AntiCheatService.Status()
	local stats = DetectionEngine.Stats()
	return {
		Ok = true,
		Range = if hours == 1 then "1h" elseif hours == 168 then "7d" else "24h",
		ByModule = counts.ByModule,
		ByHour = counts.ByHour,
		Total = counts.Total,
		TopPlayers = top,
		Actions = ActionService.ByType(hours),
		Accuracy = fpRates(),
		Performance = stats,
		RemoteCalls = AntiCheatService.RemoteCallsPerSecond(),
		Health = { Stores = status.Stores, CrossServer = status.CrossServer, Warnings = status.Warnings, Integrations = status.Integrations },
	}
end

-- Suggestions from the false-positive data (never applied automatically).
local function recommend(): any
	local out = {}
	local rates = fpRates()
	for _, def in ipairs(DetectionEngine.Modules()) do
		local r = rates[def.Name]
		local cfg = AntiCheatConfig.GetModule(def.Name)
		if r and r.Reviewed >= 3 and r.Rate >= 30 then
			table.insert(out, ("%s: %.0f%% of reviewed flags were false positives - lower its Weight (now %.2f) or widen its thresholds."):format(def.Name, r.Rate, cfg.Weight or 1))
		elseif r and r.Reviewed >= 5 and r.Rate == 0 and (cfg.Weight or 1) < 1 then
			table.insert(out, ("%s: no false positives in %d reviews - its Weight (%.2f) could go back to 1."):format(def.Name, r.Reviewed, cfg.Weight or 1))
		end
	end
	local stats = DetectionEngine.Stats()
	local budget = AntiCheatConfig.Get("Core").CostBudgetMs or 2
	if stats.MsPerSec > budget then
		table.insert(out, ("Server cost %.2f ms/s is over the %.1f ms budget - raise module Intervals or lower Core.FrameBudget."):format(stats.MsPerSec, budget))
	end
	if #out == 0 then
		table.insert(out, "No changes suggested yet: mark more flags as reviewed or false positive to build accuracy data.")
	end
	return { Ok = true, Suggestions = out }
end

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------
local UNDO_NODE = {
	["exempt.add"] = E, ["exempt.remove"] = E, ["exempt.extend"] = E, ["watch.add"] = E, ["watch.remove"] = E, testing = E,
	["score.reset"] = A, unban = "anticheat.ban", banEdit = "anticheat.ban", mode = C, panic = C, ["module.toggle"] = C, ["module.weight"] = C, config = C, master = M,
}

local function target(id: any): (Player?, string?)
	local uid = userId(id)
	if not uid then
		return nil, "invalid player"
	end
	local p = Players:GetPlayerByUserId(uid)
	if not p then
		return nil, "that player is not in this server"
	end
	return p, nil
end

local function canTarget(actor: Player, targetPlayer: Player): boolean
	local ok, allowed = pcall(function()
		return lazy("RankService").CanTarget(actor, targetPlayer)
	end)
	return not ok or allowed ~= false
end

local handlers: { [string]: (Player, any) -> any } = {}

handlers.access = function(player)
	local c = can(player)
	if not c.View then
		return { Ok = true, Can = c }
	end
	local isOwner = false
	pcall(function()
		isOwner = lazy("ApprovalService").IsOwner(player)
	end)
	return { Ok = true, Can = c, Status = AntiCheatService.Status(), Owner = isOwner, Modules = #DetectionEngine.Modules() }
end

handlers.overview = function()
	return overview()
end

handlers.flags = function(_player, payload)
	local filter = filterFrom(payload)
	local list = {}
	local servers, seen = {}, {}
	for _, f in ipairs(EvidenceService.List(filter, 1000)) do
		table.insert(list, AntiCheatService.Compact(f))
		if not seen[f.Server] then
			seen[f.Server] = true
			table.insert(servers, f.Server)
		end
	end
	local names = {}
	for _, def in ipairs(DetectionEngine.Modules()) do
		table.insert(names, def.Name)
	end
	return { Ok = true, Flags = list, Modules = names, Servers = servers }
end

handlers.flag = function(player, payload)
	local id = str(type(payload) == "table" and payload.Id or payload, 40)
	if not id then
		return bad(player, "flag id")
	end
	local flag = EvidenceService.Get(id)
	if not flag then
		return { Ok = false, Message = "That flag is not in this server's memory (older flags: player history)." }
	end
	return {
		Ok = true,
		Flag = flag,
		History = ScoreService.History(flag.UserId),
		Score = ScoreService.Get(flag.UserId),
		PlayerFlags = (function()
			local out = {}
			for _, f in ipairs(EvidenceService.ForPlayer(flag.UserId, 30)) do
				table.insert(out, AntiCheatService.Compact(f))
			end
			return out
		end)(),
	}
end

handlers.players = function()
	local rows = {}
	for _, p in ipairs(Players:GetPlayers()) do
		table.insert(rows, playerRow(p))
	end
	return { Ok = true, Players = rows }
end

handlers.player = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or payload)
	if not uid then
		return bad(player, "user id")
	end
	local flags = {}
	for _, f in ipairs(EvidenceService.ForPlayer(uid, 100)) do
		table.insert(flags, AntiCheatService.Compact(f))
	end
	local notes = {}
	pcall(function()
		local Note = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Note")) :: any
		notes = Note.GetNotes(uid)
	end)
	local p = Players:GetPlayerByUserId(uid)
	-- Flight granted by an admin system: movement checks are paused for it
	-- (HD Admin's only while Core.TrustExternalAdmins is on).
	local flight = {}
	if p then
		local checked = if AntiCheatConfig.Get("Core").TrustSentinelCommands == true then "" else " (checked: trust off)"
		if p:GetAttribute("SentinelFlying") == true then
			table.insert(flight, "Sentinel fly" .. checked)
		end
		if p:GetAttribute("SentinelNoclip") == true then
			table.insert(flight, "Sentinel noclip" .. checked)
		end
		local boosts = ExemptionService.Boosts(uid)
		if boosts then
			for prop, natural in pairs(boosts) do
				table.insert(flight, ("Sentinel %s boost (normal %s)%s"):format(prop, tostring(natural), checked))
			end
		end
		local hdFly, hdNoclip = require(script.Parent:WaitForChild("ExternalAdmins")).Movement(uid, os.clock())
		if hdFly then
			local label = if hdNoclip then "HD Admin noclip" else "HD Admin fly"
			if AntiCheatConfig.Get("Core").TrustExternalAdmins ~= true then
				label ..= " (checked: trust off)"
			end
			table.insert(flight, label)
		end
	end
	return {
		Ok = true,
		UserId = uid,
		Name = nameOf(uid),
		Row = if p then playerRow(p) else nil,
		Flight = flight,
		Score = ScoreService.Get(uid),
		History = ScoreService.History(uid),
		Flags = flags,
		Exemptions = ExemptionService.ForPlayer(uid),
		Active = ExemptionService.Active(uid),
		Watch = ExemptionService.GetWatch(uid),
		Testing = ExemptionService.IsTesting(uid),
		Weights = ScoreService.Weights(uid),
		Notes = notes,
	}
end

handlers.lookup = function(player, payload)
	local query = str(type(payload) == "table" and payload.Query or payload, 40)
	if not query or query == "" then
		return bad(player, "query")
	end
	local info, err = lazy("PlayerProfileService").Resolve(query, player)
	if not info then
		return { Ok = false, Message = err or "Not found." }
	end
	local stored = EvidenceService.LoadHistory(info.UserId)
	local list = {}
	for i = 1, math.min(#stored, 100) do
		table.insert(list, AntiCheatService.Compact(stored[i]))
	end
	return { Ok = true, UserId = info.UserId, Name = info.Name, Online = info.Local ~= nil, Flags = list, Exemptions = ExemptionService.ForPlayer(info.UserId), Watch = ExemptionService.GetWatch(info.UserId) }
end

handlers.queue = function(_player, payload)
	local status = str(type(payload) == "table" and payload.Status or nil, 20)
	return { Ok = true, Items = ActionService.Reviews(status) }
end

handlers.modules = function()
	return { Ok = true, Modules = moduleList() }
end

handlers.exemptions = function()
	local watch = {}
	for _, w in ipairs(ExemptionService.WatchList()) do
		w.Score = ScoreService.Get(w.UserId)
		table.insert(watch, w)
	end
	local testing = {}
	for id, info in pairs(ExemptionService.TestingList()) do
		table.insert(testing, { UserId = id, Name = nameOf(id), By = info.By, At = info.At })
	end
	local modules = { "all" }
	for _, def in ipairs(DetectionEngine.Modules()) do
		table.insert(modules, def.Name)
	end
	local snap = configSnapshot()
	return {
		Ok = true,
		Exemptions = ExemptionService.List(),
		Watch = watch,
		Testing = testing,
		Modules = modules,
		ExemptRank = AntiCheatConfig.Get("Core").ExemptRank,
		WatchAlerts = AntiCheatConfig.Get("Alerts").WatchAlerts,
		Ranks = snap.Ranks,
	}
end

handlers.config = function()
	return configSnapshot()
end

handlers.analytics = function(_player, payload)
	return analytics(payload)
end

handlers.exportConfig = function(player)
	AntiCheatService.LogAction(player, "config.export", "AntiCheat", "Exported the anti-cheat config")
	return { Ok = true, Text = AntiCheatConfig.Export() }
end

handlers.recommend = function()
	return recommend()
end

handlers.logs = function()
	return { Ok = true, Log = AntiCheatService.ActionLog(300) }
end

handlers.presetPreview = function(player, payload)
	local name = str(type(payload) == "table" and payload.Name or payload, 20)
	if not name then
		return bad(player, "preset")
	end
	local changes, err = AntiCheatConfig.PreviewPreset(name)
	return { Ok = changes ~= nil, Changes = changes, Message = err }
end

handlers.audit = function(player, payload)
	local what = str(type(payload) == "table" and payload.What or payload, 60)
	if not what then
		return bad(player, "audit text")
	end
	AntiCheatService.LogAction(player, "ui", nil, (what:gsub("[%c]", " ")))
	return { Ok = true }
end

-- Review --------------------------------------------------------------------
handlers.markReviewed = function(player, payload)
	local ids = type(payload) == "table" and payload.Ids
	if type(ids) ~= "table" or #ids == 0 or #ids > 200 then
		return bad(player, "flag ids")
	end
	local clean = {}
	for _, id in ipairs(ids) do
		local s = str(id, 40)
		if s then
			table.insert(clean, s)
		end
	end
	local n = EvidenceService.MarkReviewed(clean, player.Name)
	AntiCheatService.LogAction(player, "review", nil, ("Marked %d flag(s) reviewed"):format(n))
	AntiCheatService.PushStatus()
	return { Ok = true, Message = ("Marked %d flag(s) reviewed."):format(n) }
end

handlers.falsePositive = function(player, payload)
	local id = str(type(payload) == "table" and payload.Id or nil, 40)
	if not id then
		return bad(player, "flag id")
	end
	local flag = EvidenceService.Get(id)
	if not flag then
		return { Ok = false, Message = "Unknown flag." }
	end
	if flag.FalsePositive then
		return { Ok = false, Message = "Already marked as a false positive." }
	end
	local scoring = AntiCheatConfig.Get("Scoring")
	local before = ScoreService.PlayerWeight(flag.UserId, flag.Module)
	EvidenceService.SetFalsePositive(id, true, player.Name)
	local after = ScoreService.LowerWeight(flag.UserId, flag.Module, scoring.FalsePositiveFactor or 0.5, scoring.MinPlayerWeight or 0.1)
	ScoreService.Reduce(flag.UserId, flag.Points or 0)
	AntiCheatService.LogAction(player, "falsepositive", flag.Name, ("Flag %s (%s) marked false positive; %s weight for %s %.2f -> %.2f"):format(id, flag.Module, flag.Module, flag.Name, before, after), function()
		EvidenceService.SetFalsePositive(id, false, player.Name)
		local weights = ScoreService.Weights(flag.UserId)
		weights[flag.Module] = before
		ScoreService.SetWeights(flag.UserId, weights)
		return true, "false-positive mark removed"
	end, { Old = before, New = after })
	AntiCheatService.PushStatus()
	return { Ok = true, Message = ("Marked as a false positive. %s now counts x%.2f for %s."):format(flag.Module, after, flag.Name) }
end

handlers.createCase = function(player, payload)
	local id = str(type(payload) == "table" and payload.Id or nil, 40)
	local flag = id and EvidenceService.Get(id)
	if not flag then
		return bad(player, "flag id")
	end
	local CaseService = lazy("CaseService")
	local evidence = flag.Evidence or {}
	local c = CaseService.Record({
		Type = "investigation",
		TargetId = flag.UserId,
		TargetName = flag.Name,
		ModeratorId = player.UserId,
		ModeratorName = player.Name,
		Reason = ("[AntiCheat %s] %s"):format(flag.Module, flag.Reason),
		Source = "anticheat",
	})
	pcall(CaseService.AddNote, c.Id, player, ("Flag %s: severity %d, confidence %.2f, score after %d, ping %s ms, server FPS %s, exemptions: %s, %d position samples."):format(
		flag.Id,
		flag.Severity,
		flag.Confidence,
		math.floor(flag.ScoreAfter or 0),
		tostring(evidence.Ping),
		tostring(evidence.ServerFps),
		if evidence.Exemptions and #evidence.Exemptions > 0 then table.concat(evidence.Exemptions, "; ") else "none",
		if evidence.Samples then #evidence.Samples else 0
	))
	EvidenceService.MarkReviewed({ flag.Id }, player.Name)
	AntiCheatService.LogAction(player, "case", flag.Name, ("Case #%d created from flag %s"):format(c.Id, flag.Id))
	return { Ok = true, Message = ("Case #%d created with the evidence attached."):format(c.Id), CaseId = c.Id }
end

handlers.note = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	local text = str(type(payload) == "table" and payload.Text or nil, 300)
	if not uid or not text or text:gsub("%s", "") == "" then
		return bad(player, "note")
	end
	local TextFilterService = lazy("TextFilterService")
	local filtered = TextFilterService.ForBroadcast(player.UserId, text)
	if not filtered then
		return { Ok = false, Message = TextFilterService.FAILED_MESSAGE }
	end
	local Note = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Note")) :: any
	Note.AddNote(uid, player.Name, "[AntiCheat] " .. filtered, "Investigation")
	AntiCheatService.LogAction(player, "note", nameOf(uid), "Added a staff note")
	return { Ok = true, Message = "Note saved." }
end

local function reviewItem(player: Player, payload: any): (any, any)
	local id = int(type(payload) == "table" and payload.Id or nil, 1, 1e9)
	if not id then
		return nil, bad(player, "review id")
	end
	return id, nil
end

handlers.queueDismiss = function(player, payload)
	local id, err = reviewItem(player, payload)
	if err then
		return err
	end
	local item, msg = ActionService.Dismiss(id, player.Name)
	if not item then
		return { Ok = false, Message = msg }
	end
	local pct = AntiCheatConfig.Get("Bands").DismissReduce or 50
	local before = ScoreService.Get(item.UserId)
	ScoreService.Reduce(item.UserId, before * pct / 100)
	ScoreService.SetLastBand(item.UserId, 1)
	AntiCheatService.LogAction(player, "review.dismiss", item.Name, ("Dismissed review #%d (score %d -> %d)"):format(id, math.floor(before), math.floor(ScoreService.Get(item.UserId))))
	return { Ok = true, Message = ("Dismissed #%d; score reduced by %d%%."):format(id, pct) }
end

handlers.queueAssign = function(player, payload)
	local id, err = reviewItem(player, payload)
	if err then
		return err
	end
	local item, msg = ActionService.Assign(id, player.Name)
	if not item then
		return { Ok = false, Message = msg }
	end
	AntiCheatService.LogAction(player, "review.assign", item.Name, ("Took review #%d"):format(id))
	return { Ok = true, Message = ("You are handling #%d."):format(id) }
end

handlers.queueEscalate = function(player, payload)
	local id, err = reviewItem(player, payload)
	if err then
		return err
	end
	local item, msg = ActionService.Escalate(id, player.Name)
	if not item then
		return { Ok = false, Message = msg }
	end
	local notified = 0
	pcall(function()
		local ApprovalService = lazy("ApprovalService")
		for _, owner in ipairs(ApprovalService.OwnersOnline()) do
			notified += 1
			AntiCheatService.PushToStaff("alert", {
				Title = "Escalated to you",
				Text = ("%s escalated review #%d (%s, score %d): %s"):format(player.Name, id, item.Name, math.floor(item.Score), item.Reason),
				Severity = "critical",
				Time = os.time(),
				ForUserId = owner.UserId,
			})
		end
	end)
	lazy("AlertService").Raise({ Kind = "anticheat", Severity = "critical", Title = "AntiCheat review escalated", Text = ("#%d %s - %s"):format(id, item.Name, item.Reason), Actor = player.Name })
	AntiCheatService.LogAction(player, "review.escalate", item.Name, ("Escalated review #%d to the Owner"):format(id))
	return { Ok = true, Message = if notified > 0 then "Escalated: the Owner was notified." else "Escalated: no Owner is online; it waits in the queue as Escalated." }
end

handlers.queueNote = function(player, payload)
	local id, err = reviewItem(player, payload)
	if err then
		return err
	end
	local text = str(payload.Text, 300)
	if not text or text:gsub("%s", "") == "" then
		return bad(player, "note text")
	end
	local item, msg = ActionService.AddReviewNote(id, player.Name, text)
	if not item then
		return { Ok = false, Message = msg }
	end
	return handlers.note(player, { UserId = item.UserId, Text = text })
end

-- Exemptions ------------------------------------------------------------------
handlers.exemptAdd = function(player, payload)
	if type(payload) ~= "table" then
		return bad(player, "payload")
	end
	local uid = userId(payload.UserId)
	local name: string? = nil
	if not uid and str(payload.Name, 40) then
		local info = lazy("PlayerProfileService").Resolve(payload.Name, player)
		if info then
			uid, name = info.UserId, info.Name
		end
	end
	if not uid then
		return { Ok = false, Message = "Pick a player (name or UserId)." }
	end
	name = name or nameOf(uid)
	local module = if payload.Module == "all" then "all" else moduleName(payload.Module)
	if not module then
		return bad(player, "module")
	end
	local seconds = if payload.Seconds == nil then nil else num(payload.Seconds, 60, 3650 * 86400)
	if payload.Seconds ~= nil and not seconds then
		return bad(player, "duration")
	end
	local reason = str(payload.Reason, 200)
	if not reason or reason:gsub("%s", "") == "" then
		return { Ok = false, Message = "A reason is required." }
	end
	local e, err = ExemptionService.Add(uid, name :: string, module, seconds, reason, player.Name)
	if not e then
		return { Ok = false, Message = err }
	end
	AntiCheatService.LogAction(player, "exempt.add", name, ("Exempted %s from %s %s: %s"):format(name :: string, module, if seconds then ("for %d min"):format(seconds // 60) else "permanently", reason), function()
		ExemptionService.RemoveById(e.Id)
		return true, "exemption removed"
	end)
	return { Ok = true, Message = ("%s is exempt from %s."):format(name :: string, module) }
end

handlers.exemptRemove = function(player, payload)
	if type(payload) ~= "table" then
		return bad(player, "payload")
	end
	local removed = {}
	local id = str(payload.Id, 20)
	if id then
		local e = ExemptionService.RemoveById(id)
		if e then
			table.insert(removed, e)
		end
	else
		local uid = userId(payload.UserId)
		if not uid then
			return bad(player, "exemption")
		end
		local module = if payload.Module == nil or payload.Module == "all" then nil else moduleName(payload.Module)
		removed = ExemptionService.Remove(uid, module)
	end
	if #removed == 0 then
		return { Ok = false, Message = "No matching exemption." }
	end
	AntiCheatService.LogAction(player, "exempt.remove", removed[1].Name, ("Removed %d exemption(s) of %s"):format(#removed, removed[1].Name), function()
		for _, e in ipairs(removed) do
			ExemptionService.Restore(e)
		end
		return true, "exemption(s) restored"
	end)
	return { Ok = true, Message = ("Removed %d exemption(s)."):format(#removed) }
end

handlers.exemptExtend = function(player, payload)
	local id = str(type(payload) == "table" and payload.Id or nil, 20)
	local seconds = num(type(payload) == "table" and payload.Seconds or nil, 60, 365 * 86400)
	if not id or not seconds then
		return bad(player, "extend")
	end
	local before
	for _, e in ipairs(ExemptionService.List()) do
		if e.Id == id then
			before = e.ExpiresAt
		end
	end
	local e, err = ExemptionService.Extend(id, seconds)
	if not e then
		return { Ok = false, Message = err }
	end
	AntiCheatService.LogAction(player, "exempt.extend", e.Name, ("Extended %s's %s exemption by %d min"):format(e.Name, e.Module, seconds // 60), function()
		local removed = ExemptionService.RemoveById(id)
		if removed then
			removed.ExpiresAt = before
			ExemptionService.Restore(removed)
		end
		return true, "expiry restored"
	end)
	return { Ok = true, Message = "Exemption extended." }
end

handlers.watchAdd = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	if not uid then
		return bad(player, "user id")
	end
	local why = str(payload.Why, 200) or "watched from the Control Center"
	local name = nameOf(uid)
	ExemptionService.Watch(uid, name, why, player.Name)
	AntiCheatService.LogAction(player, "watch.add", name, ("Watching %s: %s"):format(name, why), function()
		ExemptionService.Unwatch(uid)
		return true, "unwatched"
	end)
	return { Ok = true, Message = ("%s is on the watch list."):format(name) }
end

handlers.watchRemove = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	if not uid then
		return bad(player, "user id")
	end
	local old = ExemptionService.Unwatch(uid)
	if not old then
		return { Ok = false, Message = "Not on the watch list." }
	end
	AntiCheatService.LogAction(player, "watch.remove", old.Name, ("Stopped watching %s"):format(old.Name), function()
		ExemptionService.Watch(old.UserId, old.Name, old.Why, old.By)
		return true, "watched again"
	end)
	return { Ok = true, Message = ("Removed %s from the watch list."):format(old.Name) }
end

handlers.testing = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	if not uid or type(payload.On) ~= "boolean" then
		return bad(player, "testing")
	end
	local ok, message = AntiCheatService.SetTesting(uid, nameOf(uid), payload.On, player)
	return { Ok = ok, Message = message }
end

-- Act -------------------------------------------------------------------------
local function actReason(player: Player, payload: any): (string?, any)
	local reason = str(type(payload) == "table" and payload.Reason or nil, 200)
	if not reason or reason:gsub("%s", "") == "" then
		return nil, { Ok = false, Message = "A reason is required." }
	end
	local filtered = lazy("TextFilterService").ForBroadcast(player.UserId, reason)
	if not filtered then
		return nil, { Ok = false, Message = "The reason could not be filtered." }
	end
	return filtered, nil
end

handlers.warn = function(player, payload)
	local t, err = target(type(payload) == "table" and payload.UserId or nil)
	if not t then
		return { Ok = false, Message = err }
	end
	if not canTarget(player, t) then
		return { Ok = false, Message = ("%s is protected by rank."):format(t.Name) }
	end
	local reason, refused = actReason(player, payload)
	if not reason then
		return refused
	end
	lazy("PunishmentService").AddWarning(t, player, "[AntiCheat] " .. reason)
	lazy("CaseService").Record({ Type = "warn", TargetId = t.UserId, TargetName = t.Name, ModeratorId = player.UserId, ModeratorName = player.Name, Reason = "[AntiCheat] " .. reason, Source = "anticheat" })
	AntiCheatService.LogAction(player, "warn", t.Name, ("Warned %s: %s"):format(t.Name, reason))
	return { Ok = true, Message = ("Warned %s."):format(t.Name) }
end

handlers.kick = function(player, payload)
	local t, err = target(type(payload) == "table" and payload.UserId or nil)
	if not t then
		return { Ok = false, Message = err }
	end
	if not canTarget(player, t) then
		return { Ok = false, Message = ("%s is protected by rank."):format(t.Name) }
	end
	local reason, refused = actReason(player, payload)
	if not reason then
		return refused
	end
	lazy("CaseService").Record({ Type = "kick", TargetId = t.UserId, TargetName = t.Name, ModeratorId = player.UserId, ModeratorName = player.Name, Reason = "[AntiCheat] " .. reason, Source = "anticheat" })
	AntiCheatService.LogAction(player, "kick", t.Name, ("Kicked %s: %s"):format(t.Name, reason))
	t:Kick("Kicked: " .. reason)
	return { Ok = true, Message = ("Kicked %s."):format(t.Name) }
end

handlers.correct = function(player, payload)
	local t, err = target(type(payload) == "table" and payload.UserId or nil)
	if not t then
		return { Ok = false, Message = err }
	end
	local done = AntiCheatService.Correct(t, { Correct = "position" })
	AntiCheatService.LogAction(player, "correct", t.Name, ("Silent correction on %s (%s)"):format(t.Name, if done then "moved back" else "nothing to do"))
	return { Ok = done, Message = if done then ("Moved %s back to a recent valid position."):format(t.Name) else "No valid position to restore." }
end

-- ---------------------------------------------------------------------------
-- Banned players (anti-cheat bans: automatic + ;acban)
-- ---------------------------------------------------------------------------
local function banModule(): any
	return require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Ban")) :: any
end

local function canSeeBans(player: Player): boolean
	return PermissionSystem.Has(player, "anticheat.ban")
		or PermissionSystem.Has(player, "moderation.banlist")
		or PermissionSystem.Has(player, "moderation.ban")
end

handlers.bans = function(player, payload)
	if not canSeeBans(player) then
		return { Ok = false, Denied = true, Message = "You need anticheat.ban or moderation.banlist to see banned players." }
	end
	local all = type(payload) == "table" and payload.All == true
	local list, err = banModule().ListDetailed()
	local out = {}
	for _, b in ipairs(list) do
		if all or b.Source == "anticheat" then
			table.insert(out, b)
		end
	end
	return { Ok = true, Bans = out, Error = err, Config = AntiCheatConfig.Get("Bans"), CanAct = PermissionSystem.Has(player, "anticheat.ban") }
end

-- Lift / edit: only bans the anti-cheat wrote (staff bans belong to
-- Sentinel moderation: ;unban / ;editban with moderation.ban).
local function antiCheatBan(payload: any): (number?, any, string?)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	if not uid then
		return nil, nil, "invalid player"
	end
	local record = banModule().GetActiveBan(uid)
	if not record then
		return nil, nil, "That player is not banned."
	end
	if not ActionService.IsAntiCheatBan(record) then
		return nil, nil, "Not an anti-cheat ban - use Sentinel's Banned page (;unban / ;editban)."
	end
	return uid, record, nil
end

handlers.banLift = function(player, payload)
	local uid, record, err = antiCheatBan(payload)
	if not uid then
		return { Ok = false, Message = err }
	end
	local reason, refused = actReason(player, payload)
	if not reason then
		return refused
	end
	local Ban = banModule()
	if not Ban.SetBan(uid, nil) then
		return { Ok = false, Message = "The ban could not be removed (DataStore error)." }
	end
	local name = record.TargetName or tostring(uid)
	pcall(function()
		-- Same as ;unban: the ban's case becomes Revoked.
		lazy("CaseService").Revoke(uid, { "ban" }, player)
	end)
	pcall(function()
		lazy("CaseService").Record({ Type = "unban", TargetId = uid, TargetName = name, ModeratorId = player.UserId, ModeratorName = player.Name, Reason = "[AntiCheat] " .. reason, Source = "anticheat" })
	end)
	pcall(function()
		require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("EventBus")).Publish("Player.Unbanned", uid)
	end)
	AntiCheatService.LogAction(player, "unban", name, ("Lifted the anti-cheat ban on %s: %s"):format(name, reason), function()
		return Ban.SetBan(uid, record), "Ban restored"
	end)
	return { Ok = true, Message = ("Unbanned %s."):format(name) }
end

handlers.banEdit = function(player, payload)
	local uid, record, err = antiCheatBan(payload)
	if not uid then
		return { Ok = false, Message = err }
	end
	local permanent = payload.Permanent == true
	local days = int(payload.Days, 1, 3650)
	if not permanent and not days then
		return { Ok = false, Message = "Give a number of days (1-3650) or permanent." }
	end
	if permanent and AntiCheatConfig.Get("Bans").AllowPermanent ~= true then
		return { Ok = false, Message = "Permanent anti-cheat bans are disabled (Settings > Bans > AllowPermanent)." }
	end
	local ok, message, previous = banModule().EditBan(uid, if permanent then nil else (days :: number) * 86400, player.Name)
	if not ok then
		return { Ok = false, Message = message }
	end
	local name = record.TargetName or tostring(uid)
	local what = if permanent then "permanent" else ("%d day(s) from now"):format(days :: number)
	AntiCheatService.LogAction(player, "banEdit", name, ("Changed %s's anti-cheat ban to %s"):format(name, what), function()
		return banModule().SetBan(uid, previous), "Previous ban length restored"
	end)
	return { Ok = true, Message = ("%s's ban is now %s."):format(name, what) }
end

handlers.resetScore = function(player, payload)
	local uid = userId(type(payload) == "table" and payload.UserId or nil)
	if not uid then
		return bad(player, "user id")
	end
	local ok, message = AntiCheatService.ResetScore(uid, nameOf(uid), player)
	return { Ok = ok, Message = message }
end

-- Config ----------------------------------------------------------------------
local function cleanValue(v: any): any
	if type(v) == "table" then
		local out = {}
		for i, x in ipairs(v) do
			if i > 300 then
				break
			end
			if type(x) == "string" or type(x) == "number" then
				out[i] = x
			end
		end
		return out
	end
	if type(v) == "string" then
		return v:sub(1, 2000)
	end
	return v
end

handlers.setValue = function(player, payload)
	local path = str(type(payload) == "table" and payload.Path or nil, 80)
	if not path then
		return bad(player, "path")
	end
	if path:lower():match("^core%.enabled") and not PermissionSystem.Has(player, M) then
		return { Ok = false, Message = "Turning the system on or off needs anticheat.master." }
	end
	local key, field = AntiCheatConfig.SplitPath(path)
	local before = if key and field then AntiCheatConfig.Get(key)[field] else nil
	local ok, message = AntiCheatConfig.SetValue(path, cleanValue(payload.Value), player)
	if ok and message:find("Changed") then
		AntiCheatService.LogAction(player, "config", path, message, function()
			return AntiCheatConfig.SetValue(path, before, player)
		end, { Old = before, New = payload.Value })
	end
	return { Ok = ok, Message = message }
end

handlers.saveSection = function(player, payload)
	local key = str(type(payload) == "table" and payload.Key or nil, 60)
	local values = type(payload) == "table" and payload.Values
	if not key or type(values) ~= "table" then
		return bad(player, "section")
	end
	local count = 0
	local clean = {}
	for k, v in pairs(values) do
		count += 1
		if count > 40 or type(k) ~= "string" then
			return bad(player, "section values")
		end
		clean[k] = cleanValue(v)
	end
	if key == "Core" and clean.Enabled ~= nil and clean.Enabled ~= AntiCheatConfig.Get("Core").Enabled and not PermissionSystem.Has(player, M) then
		return { Ok = false, Message = "Turning the system on or off needs anticheat.master." }
	end
	local merged = table.clone(AntiCheatConfig.Get(key))
	for k, v in pairs(clean) do
		merged[k] = v
	end
	local before = table.clone(AntiCheatConfig.Get(key))
	local ok, message, changes = AntiCheatConfig.SetSection(key, merged, player)
	if ok and #changes > 0 then
		AntiCheatService.LogAction(player, "config", key, message, function()
			local done, msg = AntiCheatConfig.SetSection(key, before, player)
			return done, msg
		end)
	end
	return { Ok = ok, Message = message, Changes = changes }
end

handlers.resetSection = function(player, payload)
	local key = str(type(payload) == "table" and payload.Key or nil, 60)
	if not key then
		return bad(player, "section")
	end
	local before = table.clone(AntiCheatConfig.Get(key))
	if key == "Core" then
		-- Never flip the master switch through a reset.
		return handlers.saveSection(player, { Key = "Core", Values = { Mode = "observe", Panic = false, ExemptRank = "Admin", TrustExternalAdmins = false, TrustSentinelCommands = false, FrameBudget = 12, CostBudgetMs = 2, StretchMinPlayers = 10 } })
	end
	local ok, message = AntiCheatConfig.Reset(key, player)
	if ok then
		AntiCheatService.LogAction(player, "config", key, message, function()
			return AntiCheatConfig.SetSection(key, before, player)
		end)
	end
	return { Ok = ok, Message = message }
end

handlers.resetModule = function(player, payload)
	local name = moduleName(type(payload) == "table" and payload.Name or nil)
	if not name then
		return bad(player, "module")
	end
	return handlers.resetSection(player, { Key = "Module." .. name })
end

handlers.resetAll = function(player)
	local ok, message = AntiCheatConfig.ResetAll(player)
	AntiCheatService.LogAction(player, "config", "AntiCheat", message)
	return { Ok = ok, Message = message }
end

handlers.import = function(player, payload)
	local text = str(type(payload) == "table" and payload.Text or nil, 60000)
	if not text then
		return bad(player, "config text")
	end
	local ok, message = AntiCheatConfig.Import(text, player, payload.DryRun == true)
	if ok and not payload.DryRun then
		AntiCheatService.LogAction(player, "config", "AntiCheat", message)
	end
	return { Ok = ok, Message = message }
end

handlers.applyPreset = function(player, payload)
	local name = str(type(payload) == "table" and payload.Name or nil, 20)
	if not name then
		return bad(player, "preset")
	end
	local snapshot = AntiCheatConfig.Snapshot()
	local ok, message = AntiCheatConfig.ApplyPreset(name, player)
	if ok then
		AntiCheatService.LogAction(player, "config", "preset " .. name, message, function()
			for key, value in pairs(snapshot) do
				AntiCheatConfig.SetSection(key, value, player)
			end
			return true, "previous config restored"
		end)
		AntiCheatService.PushStatus()
	end
	return { Ok = ok, Message = message }
end

handlers.moduleToggle = function(player, payload)
	local name = moduleName(type(payload) == "table" and payload.Name or nil)
	if not name or type(payload.On) ~= "boolean" then
		return bad(player, "module toggle")
	end
	local ok, message = AntiCheatConfig.SetValue(("Module.%s.Enabled"):format(name), payload.On, player)
	if ok then
		AntiCheatService.LogAction(player, "module.toggle", name, ("%s turned %s"):format(name, if payload.On then "on" else "off"), function()
			return AntiCheatConfig.SetValue(("Module.%s.Enabled"):format(name), not payload.On, player)
		end, { Old = not payload.On, New = payload.On })
	end
	return { Ok = ok, Message = if ok then ("%s is %s on every server."):format(name, if payload.On then "on" else "off") else message }
end

handlers.moduleWeight = function(player, payload)
	local name = moduleName(type(payload) == "table" and payload.Name or nil)
	local weight = num(type(payload) == "table" and payload.Weight or nil, 0, 2)
	if not name or not weight then
		return bad(player, "module weight")
	end
	weight = math.floor(weight * 20 + 0.5) / 20
	local before = AntiCheatConfig.GetModule(name).Weight
	local ok, message = AntiCheatConfig.SetValue(("Module.%s.Weight"):format(name), weight, player)
	if ok and before ~= weight then
		AntiCheatService.LogAction(player, "module.weight", name, ("%s weight %.2f -> %.2f"):format(name, before or 1, weight), function()
			return AntiCheatConfig.SetValue(("Module.%s.Weight"):format(name), before, player)
		end, { Old = before, New = weight })
	end
	return { Ok = ok, Message = message }
end

handlers.moduleTest = function(player, payload)
	local name = moduleName(type(payload) == "table" and payload.Name or nil)
	if not name then
		return bad(player, "module")
	end
	local result = DetectionEngine.TestModule(player, name)
	AntiCheatService.LogAction(player, "module.test", name, ("Tested %s on %s: %s"):format(name, player.Name, tostring(result.Message)))
	return { Ok = result.Ok, Message = result.Message .. (if result.Exempt then (" (note: live checks skip you - %s)"):format(result.Exempt) else ""), Result = result }
end

handlers.setMode = function(player, payload)
	local mode = str(type(payload) == "table" and payload.Mode or nil, 12)
	if not mode then
		return bad(player, "mode")
	end
	local ok, message = AntiCheatService.SetMode(mode, player)
	return { Ok = ok, Message = message }
end

handlers.setPanic = function(player, payload)
	if type(payload) ~= "table" or type(payload.On) ~= "boolean" then
		return bad(player, "panic")
	end
	local ok, message = AntiCheatService.SetPanic(payload.On, player)
	return { Ok = ok, Message = message }
end

handlers.exemptRank = function(player, payload)
	local rank = str(type(payload) == "table" and payload.Rank or nil, 30)
	if not rank then
		return bad(player, "rank")
	end
	return handlers.setValue(player, { Path = "Core.ExemptRank", Value = rank })
end

handlers.watchAlerts = function(player, payload)
	if type(payload) ~= "table" or type(payload.On) ~= "boolean" then
		return bad(player, "watch alerts")
	end
	return handlers.setValue(player, { Path = "Alerts.WatchAlerts", Value = payload.On })
end

-- Master ----------------------------------------------------------------------
handlers.setEnabled = function(player, payload)
	if type(payload) ~= "table" or type(payload.On) ~= "boolean" then
		return bad(player, "enabled")
	end
	local ok, message = AntiCheatService.SetEnabled(payload.On, player)
	return { Ok = ok, Message = message }
end

handlers.finishSetup = function(player, payload)
	if type(payload) ~= "table" then
		return bad(player, "setup")
	end
	local mode = str(payload.Mode, 12)
	if not mode or not table.find({ "observe", "balanced", "strict" }, mode) then
		return bad(player, "mode")
	end
	local preset = mode:sub(1, 1):upper() .. mode:sub(2)
	local ok, message = AntiCheatConfig.ApplyPreset(preset, player)
	if not ok then
		return { Ok = false, Message = message }
	end
	if type(payload.Modules) == "table" then
		local n = 0
		for name, on in pairs(payload.Modules) do
			n += 1
			if n > 30 then
				break
			end
			local m = moduleName(name)
			if m and type(on) == "boolean" and AntiCheatConfig.GetModule(m).Enabled ~= on then
				AntiCheatConfig.SetValue(("Module.%s.Enabled"):format(m), on, player)
			end
		end
	end
	local rank = str(payload.ExemptRank, 30)
	local core = table.clone(AntiCheatConfig.Get("Core"))
	core.Enabled = true
	core.SetupDone = true
	if rank then
		core.ExemptRank = rank
	end
	local saved, msg = AntiCheatConfig.SetSection("Core", core, player)
	if not saved then
		return { Ok = false, Message = msg }
	end
	AntiCheatService.LogAction(player, "setup", "AntiCheat", ("Setup finished: %s mode, exempt rank %s"):format(mode, tostring(core.ExemptRank)))
	AntiCheatService.PushStatus()
	return { Ok = true, Message = ("Sentinel AntiCheat is on in %s mode."):format(preset) }
end

-- Undo: needs the node of the original action.
handlers.undo = function(player, payload)
	local id = int(type(payload) == "table" and payload.Id or nil, 1, 1e9)
	if not id then
		return bad(player, "log id")
	end
	local entry
	for _, e in ipairs(AntiCheatService.ActionLog(300)) do
		if e.Id == id then
			entry = e
		end
	end
	if not entry then
		return { Ok = false, Message = "Unknown log entry." }
	end
	local node = UNDO_NODE[entry.Action] or (if entry.Action == "falsepositive" then R else C)
	if not PermissionSystem.Has(player, node) then
		return { Ok = false, Message = ("Undoing that needs %s."):format(node) }
	end
	local ok, message = AntiCheatService.Undo(id, player)
	return { Ok = ok, Message = message }
end

function AntiCheatBridge.Handle(player: Player, action: any, payload: any): any
	if type(action) ~= "string" or #action > 30 then
		return bad(player, "action")
	end
	local node = AntiCheatBridge.ACTIONS[action]
	local handler = handlers[action]
	if node == nil or not handler then
		return bad(player, "unknown action " .. action:sub(1, 30))
	end
	if player:GetAttribute("SentinelBanHold") then
		return { Ok = false, Message = "Not available." }
	end
	if node ~= "" and not PermissionSystem.Has(player, node) then
		return { Ok = false, Denied = true, Message = ("You need %s for that."):format(node) }
	end
	if node ~= "" and node ~= V and not PermissionSystem.Has(player, V) then
		return { Ok = false, Denied = true, Message = "You need anticheat.view for the Control Center." }
	end
	if payload ~= nil and type(payload) ~= "table" and type(payload) ~= "string" and type(payload) ~= "number" then
		return bad(player, "payload type")
	end
	return handler(player, payload)
end

return AntiCheatBridge
