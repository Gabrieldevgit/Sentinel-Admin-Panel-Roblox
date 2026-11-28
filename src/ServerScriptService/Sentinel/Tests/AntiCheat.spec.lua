-- Tests for Sentinel AntiCheat (Systems/AntiCheat): every detection module
-- (one clean case that must not flag, one that must), scoring, the action
-- ladder, exemptions, permissions on the Control Center remote, remote
-- argument validation and config validation. Pure: modules get hand-made
-- states; fake players are tables with negative UserIds.
return function(t)
	local Sentinel = script.Parent.Parent
	local AC = Sentinel:WaitForChild("Systems"):WaitForChild("AntiCheat")
	local Modules = AC:WaitForChild("Modules")
	local AntiCheatConfig = require(AC:WaitForChild("AntiCheatConfig"))
	local ScoreService = require(AC:WaitForChild("ScoreService"))
	local ExemptionService = require(AC:WaitForChild("ExemptionService"))
	local ActionService = require(AC:WaitForChild("ActionService"))
	local DetectionEngine = require(AC:WaitForChild("DetectionEngine"))
	local EvidenceService = require(AC:WaitForChild("EvidenceService"))
	local AntiCheatService = require(AC:WaitForChild("AntiCheatService"))
	local AntiCheatBridge = require(AC:WaitForChild("AntiCheatBridge"))
	local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

	DetectionEngine.LoadModules(Modules)

	local function mod(name: string): any
		return require(Modules:WaitForChild(name))
	end

	-- Samples every 0.2 s moving `step` (Vector3) per sample.
	local function track(n: number, step: Vector3, start: Vector3?): { any }
		local out = {}
		local p = start or Vector3.new(0, 3, 0)
		for i = 0, n - 1 do
			table.insert(out, { T = i * 0.2, P = p + step * i })
		end
		return out
	end

	local function state(def: any, fields: any): any
		local s = {
			Config = AntiCheatConfig.GetModule(def.Name),
			Module = {},
			Lag = 1.5,
			Now = 1,
			Samples = {},
		}
		for k, v in pairs(fields or {}) do
			s[k] = v
		end
		return s
	end

	local function fakePlayer(id: number, name: string): any
		return {
			UserId = id,
			Name = name,
			DisplayName = name,
			GetAttribute = function()
				return nil
			end,
		}
	end

	-- -----------------------------------------------------------------------
	-- Modules: clean + flagged
	-- -----------------------------------------------------------------------
	t.test("modules: all 18 load with the contract", function()
		local names = {}
		for _, def in ipairs(DetectionEngine.Modules()) do
			t.ok(type(def.Check) == "function", def.Name .. " Check")
			t.ok(type(def.Defaults) == "table", def.Name .. " Defaults")
			t.ok(def.Interval > 0, def.Name .. " Interval")
			table.insert(names, def.Name)
		end
		for _, expected in ipairs({ "SpeedCheck", "FlyCheck", "TeleportCheck", "NoclipCheck", "JumpCheck", "HealthCheck", "RemoteSpamCheck", "ToolIntegrityCheck", "CombatCheck", "CharacterIntegrityCheck", "AnimationCheck", "EconomyCheck", "ClientReportCheck", "AltAndBanEvasion", "HumanoidStatsCheck", "AutoClickerCheck", "AimbotCheck", "KillAuraCheck" }) do
			t.ok(table.find(names, expected) ~= nil, expected .. " loaded")
		end
	end)

	t.test("SpeedCheck: sprinting at WalkSpeed is clean", function()
		local def = mod("SpeedCheck")
		local s = state(def, { WalkSpeed = 24, Samples = track(6, Vector3.new(24 * 0.2, 0, 0)) })
		for _ = 1, 5 do
			t.eq(def.Check(nil, s), nil)
		end
	end)

	t.test("SpeedCheck: 3x WalkSpeed flags after the strikes", function()
		local def = mod("SpeedCheck")
		local s = state(def, { WalkSpeed = 16, Samples = track(6, Vector3.new(48 * 0.2, 0, 0)) })
		local flag
		for _ = 1, 3 do
			flag = def.Check(nil, s) or flag
		end
		t.ok(flag ~= nil, "flagged")
		t.eq(flag.Correct, "position")
	end)

	t.test("SpeedCheck: seats and vehicles are skipped", function()
		local def = mod("SpeedCheck")
		local s = state(def, { WalkSpeed = 16, InVehicle = true, Samples = track(6, Vector3.new(20, 0, 0)) })
		for _ = 1, 5 do
			t.eq(def.Check(nil, s), nil)
		end
	end)

	t.test("TeleportCheck: walking is clean", function()
		local def = mod("TeleportCheck")
		local samples = track(5, Vector3.new(3.2, 0, 0))
		t.eq(def.Check(nil, state(def, { WalkSpeed = 16, Samples = samples, Now = samples[#samples].T })), nil)
	end)

	t.test("TeleportCheck: a 200-stud jump flags, a known teleport does not", function()
		local def = mod("TeleportCheck")
		local samples = track(4, Vector3.new(3, 0, 0))
		table.insert(samples, { T = 0.8, P = Vector3.new(210, 3, 0) })
		local flag = def.Check(nil, state(def, { WalkSpeed = 16, Samples = samples, Now = 0.8 }))
		t.ok(flag ~= nil, "flagged")
		local known = def.Check(nil, state(def, { WalkSpeed = 16, Samples = samples, Now = 0.8, LastTeleport = 0.7 }))
		t.eq(known, nil)
	end)

	t.test("TeleportCheck: falling a long way is clean", function()
		local def = mod("TeleportCheck")
		local samples = { { T = 0, P = Vector3.new(0, 500, 0) }, { T = 0.2, P = Vector3.new(0, 300, 0) } }
		t.eq(def.Check(nil, state(def, { WalkSpeed = 16, Samples = samples, Now = 0.2 })), nil)
	end)

	t.test("FlyCheck: a normal jump is clean", function()
		local def = mod("FlyCheck")
		local s = state(def, { GroundDistance = 3 })
		for i = 1, 10 do
			s.Now = i * 0.5
			s.Samples = track(4, Vector3.new(0, 0, 0))
			t.eq(def.Check(nil, s), nil)
		end
	end)

	t.test("FlyCheck: hovering high for seconds flags", function()
		local def = mod("FlyCheck")
		local s = state(def, { GroundDistance = nil })
		local flag
		for i = 1, 12 do
			s.Now = i * 0.5
			s.Samples = { { T = s.Now - 0.4, P = Vector3.new(0, 50, 0) }, { T = s.Now, P = Vector3.new(0, 50, 0) } }
			flag = def.Check(nil, s) or flag
		end
		t.ok(flag ~= nil, "flagged")
	end)

	t.test("FlyCheck: Sentinel fly and force sources are skipped", function()
		local def = mod("FlyCheck")
		local s = state(def, { GroundDistance = nil, Flying = true })
		for i = 1, 12 do
			s.Now = i * 0.5
			s.Samples = { { T = s.Now - 0.4, P = Vector3.new(0, 50, 0) }, { T = s.Now, P = Vector3.new(0, 50, 0) } }
			t.eq(def.Check(nil, s), nil)
		end
	end)

	t.test("NoclipCheck: no passes is clean, repeated passes flag", function()
		local def = mod("NoclipCheck")
		t.eq(def.Check(nil, state(def, { Passes = {} })), nil)
		local s = state(def, { Now = 5, Passes = { { T = 4, Part = "Wall" }, { T = 4.5, Part = "Wall" }, { T = 5, Part = "Door" } } })
		local flag = def.Check(nil, s)
		t.ok(flag ~= nil, "flagged")
		t.ok(#flag.Evidence.Parts == 2, "two parts")
	end)

	t.test("JumpCheck: a normal jump is clean, a 40-stud jump flags", function()
		local def = mod("JumpCheck")
		local s = state(def, { AllowedHeight = 7.2, GroundLimit = 4.5 })
		local seq = { { 3, 0 }, { 8, 10 }, { 3, 3 } } -- ground, peak 5 studs, ground
		for i, step in ipairs(seq) do
			s.Now = i
			s.GroundDistance = step[1]
			s.Height = step[2]
			t.eq(def.Check(nil, s), nil)
		end
		local s2 = state(def, { AllowedHeight = 7.2, GroundLimit = 4.5 })
		local flag
		for i, step in ipairs({ { 3, 0 }, { 30, 20 }, { 30, 40 }, { 3, 0 } }) do
			s2.Now = i
			s2.GroundDistance = step[1]
			s2.Height = step[2]
			flag = def.Check(nil, s2) or flag
		end
		t.ok(flag ~= nil, "flagged high jump")
	end)

	t.test("HealthCheck: natural regen is clean, a full heal with no source flags", function()
		local def = mod("HealthCheck")
		local s = state(def, { Health = 50, MaxHealth = 100, Now = 0 })
		t.eq(def.Check(nil, s), nil)
		s.Now, s.Health = 1, 51.5
		t.eq(def.Check(nil, s), nil)
		s.Now, s.Health = 1.5, 100
		local flag = def.Check(nil, s)
		t.ok(flag ~= nil, "flagged")
		t.eq(flag.Correct, "health")
		local healed = state(def, { Health = 50, MaxHealth = 100, Now = 0 })
		def.Check(nil, healed)
		healed.Now, healed.Health, healed.LastHeal = 1, 100, 0.8
		t.eq(def.Check(nil, healed), nil)
	end)

	t.test("RemoteSpamCheck: normal use clean, a flood flags", function()
		local def = mod("RemoteSpamCheck")
		local calls = {}
		for _ = 1, 10 do
			table.insert(calls, { T = 0, D = { Name = "Shoot" } })
		end
		local s = state(def, { Calls = calls })
		t.eq(def.Check(nil, s), nil)
		t.eq(def.Check(nil, s), nil)
		local flood = {}
		for _ = 1, 200 do
			table.insert(flood, { T = 0, D = { Name = "Shoot" } })
		end
		local s2 = state(def, { Calls = flood })
		local flag = def.Check(nil, s2) or def.Check(nil, s2)
		t.ok(flag ~= nil, "flagged")
		local s3 = state(def, { Now = 100, BadArgs = { { T = 99, D = { Name = "X", Why = "a" } }, { T = 99, D = { Name = "X", Why = "b" } }, { T = 99, D = { Name = "X", Why = "c" } } } })
		t.ok(def.Check(nil, s3) ~= nil, "bad args flagged")
	end)

	t.test("ToolIntegrityCheck: known tools clean, unknown or duplicated flag", function()
		local def = mod("ToolIntegrityCheck")
		t.eq(def.Check(nil, state(def, { Tools = { "Sword", "Bow" }, Known = { Sword = true, Bow = true } })), nil)
		t.ok(def.Check(nil, state(def, { Tools = { "Sword", "AdminGun" }, Known = { Sword = true } })) ~= nil, "unknown")
		t.ok(def.Check(nil, state(def, { Tools = { "Sword", "Sword", "Sword", "Sword" }, Known = { Sword = true } })) ~= nil, "dupes")
	end)

	t.test("CombatCheck: in-range hits clean, long-range hits flag", function()
		local def = mod("CombatCheck")
		local good = {}
		for i = 1, 5 do
			table.insert(good, { T = i * 0.5, D = { Distance = 8, LineOfSight = true } })
		end
		t.eq(def.Check(nil, state(def, { Now = 3, Hits = good })), nil)
		local bad = {}
		for i = 1, 4 do
			table.insert(bad, { T = i * 0.5, D = { Distance = 150, LineOfSight = true } })
		end
		t.ok(def.Check(nil, state(def, { Now = 3, Hits = bad })) ~= nil, "flagged")
	end)

	t.test("CharacterIntegrityCheck: unchanged clean, resized part flags", function()
		local def = mod("CharacterIntegrityCheck")
		local parts = { HumanoidRootPart = { Size = Vector3.new(2, 2, 1), CanCollide = true }, Head = { Size = Vector3.new(1, 1, 1), CanCollide = true } }
		local s = state(def, { HasCharacter = true, HasHumanoid = true, HasRoot = true, Parts = parts, Scripts = {}, SpawnedAt = 0, Now = 5 })
		t.eq(def.Check(nil, s), nil) -- baseline
		t.eq(def.Check(nil, s), nil) -- same
		s.Parts = { HumanoidRootPart = parts.HumanoidRootPart, Head = { Size = Vector3.new(10, 10, 10), CanCollide = true } }
		local flag = def.Check(nil, s)
		t.ok(flag ~= nil, "flagged")
		local s2 = state(def, { HasCharacter = true, HasHumanoid = true, HasRoot = true, Parts = parts, Scripts = {}, SpawnedAt = 0, Now = 5 })
		def.Check(nil, s2)
		s2.HasHumanoid = false
		t.ok(def.Check(nil, s2) ~= nil, "missing humanoid flagged")
	end)

	t.test("AnimationCheck: quiet without an allowlist; denied ids flag", function()
		local def = mod("AnimationCheck")
		local cfg = table.clone(AntiCheatConfig.GetModule("AnimationCheck"))
		t.eq(def.Check(nil, state(def, { Config = cfg, Playing = { "rbxassetid://123" } })), nil)
		cfg.Allow = { "111" }
		local s = state(def, { Config = cfg, Playing = { "rbxassetid://111" } })
		t.eq(def.Check(nil, s), nil)
		s.Playing = { "rbxassetid://999" }
		t.eq(def.Check(nil, s), nil) -- first sighting
		t.ok(def.Check(nil, s) ~= nil, "unknown flagged after repeats")
		cfg.Deny = { "666" }
		t.ok(def.Check(nil, state(def, { Config = cfg, Playing = { "rbxassetid://666" } })) ~= nil, "denied")
	end)

	t.test("EconomyCheck: explained gains clean, huge unexplained gain flags", function()
		local def = mod("EconomyCheck")
		local s = state(def, { Values = { Coins = 100 }, Now = 100, JoinedAt = 0, Sources = {} })
		t.eq(def.Check(nil, s), nil)
		s.Now, s.Values = 105, { Coins = 5000000 }
		s.Sources = { { T = 104, D = { Stat = "Coins", Amount = 4999900 } } }
		t.eq(def.Check(nil, s), nil)
		s.Now, s.Values, s.Sources = 110, { Coins = 9000000 }, {}
		t.ok(def.Check(nil, s) ~= nil, "flagged")
	end)

	t.test("ClientReportCheck: heartbeat clean, tamper report flags low", function()
		local def = mod("ClientReportCheck")
		t.eq(def.Check(nil, state(def, { Now = 100, JoinedAt = 0, LastHeartbeat = 95, Reports = {} })), nil)
		local flag = def.Check(nil, state(def, { Now = 100, JoinedAt = 0, LastHeartbeat = 95, Reports = { { T = 99, D = { Kind = "core_missing" } } } }))
		t.ok(flag ~= nil, "flagged")
		t.ok(flag.Confidence <= 0.3, "low weight")
	end)

	t.test("AltAndBanEvasion: old accounts clean, new account after a ban flags", function()
		local def = mod("AltAndBanEvasion")
		t.eq(def.Check(nil, state(def, { AccountAge = 400, RecentBans = { { UserId = 1, Name = "x", Time = os.time() } } })), nil)
		t.ok(def.Check(nil, state(def, { AccountAge = 1, RecentBans = { { UserId = 1, Name = "x", Time = os.time() } } })) ~= nil, "flagged")
		t.eq(def.Check(nil, state(def, { AccountAge = 1, RecentBans = {} })), nil)
	end)

	-- -----------------------------------------------------------------------
	-- Scoring
	-- -----------------------------------------------------------------------
	t.test("scoring: adds severity x confidence x weight, decays, caps", function()
		ScoreService._Clear()
		t.eq(ScoreService.Points(6, 0.5, 1, 1), 3)
		t.eq(ScoreService.Points(6, 0.5, 2, 0.5), 3)
		local cfg = { DecayPerMinute = 1, ScoreCap = 100 }
		ScoreService.Add(-1, 10, "SpeedCheck", cfg, 0)
		t.eq(ScoreService.Get(-1, 0, cfg), 10)
		t.eq(ScoreService.Get(-1, 120, cfg), 8) -- two minutes later
		ScoreService.Add(-1, 500, "SpeedCheck", cfg, 120)
		t.eq(ScoreService.Get(-1, 120, cfg), 100)
		ScoreService._Clear()
	end)

	t.test("scoring: a single low flag never reaches an action band", function()
		local bands = AntiCheatConfig.Get("Bands")
		local max = ScoreService.Points(10, 1, 1, 1) -- strongest possible single flag
		t.eq(ScoreService.Band(max, bands), 1)
		t.eq(ScoreService.Band(ScoreService.Points(2, 0.3, 1, 1), bands), 1)
	end)

	t.test("scoring: false-positive marks lower the player's module weight", function()
		ScoreService._Clear()
		t.eq(ScoreService.PlayerWeight(-2, "FlyCheck"), 1)
		t.eq(ScoreService.LowerWeight(-2, "FlyCheck", 0.5, 0.1), 0.5)
		t.eq(ScoreService.LowerWeight(-2, "FlyCheck", 0.5, 0.1), 0.25)
		for _ = 1, 10 do
			ScoreService.LowerWeight(-2, "FlyCheck", 0.5, 0.1)
		end
		t.eq(ScoreService.PlayerWeight(-2, "FlyCheck"), 0.1)
		ScoreService._Clear()
	end)

	-- -----------------------------------------------------------------------
	-- Action ladder
	-- -----------------------------------------------------------------------
	local defaults = {
		Band1 = 20, Band2 = 40, Band3 = 60, Band4 = 80,
		Observe = { "log", "alert", "alert", "alert", "alert" },
		Balanced = { "log", "alert", "warn", "kick", "review" },
		Strict = { "log", "correct", "kick", "tempban", "ban" },
		RequireApproval = true, PatternModules = 3,
	}

	t.test("ladder: each band and mode gives the expected action", function()
		local expected = {
			observe = { "alert", "alert", "alert", "alert" },
			balanced = { "alert", "warn", "kick", "review" },
			strict = { "correct", "kick", "tempban", "review" },
		}
		for mode, list in pairs(expected) do
			for band = 2, 5 do
				local d = ActionService.Decide({ Mode = mode, Band = band, LastBand = 1, Bands = defaults })
				t.eq(d.Action, list[band - 1], mode .. " band " .. band)
			end
		end
		t.eq(ActionService.Decide({ Mode = "balanced", Band = 1, LastBand = 1, Bands = defaults }), nil)
	end)

	t.test("ladder: Observe never punishes, even with a punishing config", function()
		local evil = table.clone(defaults)
		evil.Observe = { "ban", "ban", "kick", "kick", "ban" }
		for band = 2, 5 do
			local d = ActionService.Decide({ Mode = "observe", Band = band, LastBand = 1, Bands = evil })
			t.ok(d.Action == "log" or d.Action == "alert", "observe band " .. band)
		end
		local ok = AntiCheatConfig.Validate("Bands", evil)
		t.eq(ok, false)
	end)

	t.test("ladder: automatic game bans need approval or a 3-module pattern", function()
		local d = ActionService.Decide({ Mode = "strict", Band = 5, LastBand = 1, Bands = defaults, Modules = { "A", "B", "C" } })
		t.eq(d.Action, "review")
		t.eq(d.Proposed, "ban")
		local noApproval = table.clone(defaults)
		noApproval.RequireApproval = false
		t.eq(ActionService.Decide({ Mode = "strict", Band = 5, LastBand = 1, Bands = noApproval, Modules = { "A", "B" } }).Action, "review")
		t.eq(ActionService.Decide({ Mode = "strict", Band = 5, LastBand = 1, Bands = noApproval, Modules = { "A", "B", "C" } }).Action, "ban")
	end)

	t.test("ladder: panic and testing mode skip punishment; bands act once", function()
		t.eq(ActionService.Decide({ Mode = "strict", Band = 3, LastBand = 1, Bands = defaults, Panic = true }).Action, "alert")
		t.eq(ActionService.Decide({ Mode = "balanced", Band = 4, LastBand = 1, Bands = defaults, Testing = true }).Action, "alert")
		t.eq(ActionService.Decide({ Mode = "balanced", Band = 3, LastBand = 3, Bands = defaults }), nil)
	end)

	t.test("review queue: one open item per player, dismiss / assign / escalate", function()
		ActionService._Clear()
		local a = ActionService.AddReview({ UserId = -5, Name = "x", Score = 80, Modules = { "A" }, Reason = "r", Proposed = "ban" })
		local b = ActionService.AddReview({ UserId = -5, Name = "x", Score = 90, Modules = { "B" }, Reason = "r2" })
		t.eq(a.Id, b.Id)
		t.eq(#a.Modules, 2)
		t.ok(ActionService.Assign(a.Id, "mod") ~= nil)
		t.eq(a.Status, "Assigned")
		t.ok(ActionService.Escalate(a.Id, "mod") ~= nil)
		t.eq(a.Status, "Escalated")
		t.ok(ActionService.Dismiss(a.Id, "mod") ~= nil)
		t.eq(ActionService.Dismiss(a.Id, "mod"), nil)
		t.eq(ActionService.OpenReviews(), 0)
		ActionService._Clear()
	end)

	-- -----------------------------------------------------------------------
	-- Exemptions
	-- -----------------------------------------------------------------------
	t.test("exemptions: grace after spawn and teleport", function()
		ExemptionService._Clear()
		ExemptionService.MarkGrace(-10, 3, "all", "spawn")
		t.ok(ExemptionService.InGrace(-10, "SpeedCheck", os.clock()), "spawn grace")
		t.ok(not ExemptionService.InGrace(-10, "SpeedCheck", os.clock() + 4), "expired")
		ExemptionService.MarkGrace(-11, 3, "movement", "teleport")
		t.ok(ExemptionService.InGrace(-11, "TeleportCheck", os.clock()), "movement covers teleport")
		t.ok(not ExemptionService.InGrace(-11, "HealthCheck", os.clock()), "not health")
	end)

	t.test("exemptions: staff rank, per-player, per-module, expiry", function()
		ExemptionService._Clear()
		ExemptionService.SetRankProvider(function(id)
			return id == -20, "Admin"
		end)
		t.ok(ExemptionService.Check(-20, "FlyCheck"), "staff rank")
		t.ok(not ExemptionService.Check(-21, "FlyCheck"), "normal player")
		ExemptionService.SetTesting(-20, true, "self test")
		t.ok(not ExemptionService.Check(-20, "FlyCheck"), "Testing mode: staff are checked (log-only)")
		ExemptionService.SetTesting(-20, false)
		t.ok(ExemptionService.Check(-20, "FlyCheck"), "Testing off: staff exempt again")
		local e = ExemptionService.Add(-21, "bob", "FlyCheck", 3600, "glider map", "mod")
		t.ok(e ~= nil)
		t.ok(ExemptionService.Check(-21, "FlyCheck"), "module exemption")
		t.ok(not ExemptionService.Check(-21, "SpeedCheck"), "other module")
		t.eq(ExemptionService.Add(-21, "bob", "all", nil, "   ", "mod"), nil, "reason required")
		ExemptionService.Add(-22, "amy", "all", 1, "short", "mod")
		ExemptionService.ForPlayer(-22)[1].ExpiresAt = os.time() - 1 -- copy: original untouched
		local list = ExemptionService.ForPlayer(-22)
		t.eq(#list, 1)
		local stored = ExemptionService.RemoveById(list[1].Id)
		stored.ExpiresAt = os.time() - 5
		ExemptionService.Restore(stored)
		t.eq(#ExemptionService.ForPlayer(-22), 0, "expired exemption pruned")
		t.eq(#ExemptionService.Remove(-21, "FlyCheck"), 1)
		ExemptionService._Clear()
	end)

	t.test("exemptions: testing mode logs only (no actions)", function()
		ExemptionService._Clear()
		ScoreService._Clear()
		ExemptionService.SetTesting(-30, true, "mod")
		t.ok(ExemptionService.IsTesting(-30))
		local p = fakePlayer(-30, "tester")
		local flag
		for _ = 1, 8 do
			flag = DetectionEngine.Submit(p, { Module = "TeleportCheck", Severity = 7, Confidence = 1, Reason = "test" })
		end
		t.ok(flag.ScoreAfter > 40, "score still counts")
		t.ok(flag.Action == nil or flag.Action == "alert" or flag.Action == "log", "no punishment in testing")
		ExemptionService._Clear()
		ScoreService._Clear()
	end)

	t.test("engine: lag factor widens with ping and frame time", function()
		local grace = { LagTolerance = 1.5, MaxPingMs = 1000 }
		t.eq(DetectionEngine.LagFactor(0, 60, grace), 1.5)
		t.ok(DetectionEngine.LagFactor(200, 60, grace) > 1.5, "ping")
		t.ok(DetectionEngine.LagFactor(0, 30, grace) > 1.5, "low server fps")
		t.eq(DetectionEngine.LagFactor(5000, 60, grace), DetectionEngine.LagFactor(1000, 60, grace), "capped")
	end)

	-- -----------------------------------------------------------------------
	-- Permissions: the server refuses without the node (UI bypassed)
	-- -----------------------------------------------------------------------
	PermissionSystem.DefineRole("TestACViewer", { "anticheat.view" })
	PermissionSystem.DefineRole("TestACConfig", { "anticheat.view", "anticheat.config" })
	local nobody = fakePlayer(-9201, "nobody")
	local viewer = fakePlayer(-9202, "viewer")
	local configurer = fakePlayer(-9203, "configurer")
	PermissionSystem.AssignRole(viewer, "TestACViewer")
	PermissionSystem.AssignRole(configurer, "TestACConfig")

	t.test("permissions: every action has a node", function()
		for action, node in pairs(AntiCheatBridge.ACTIONS) do
			t.ok(type(node) == "string", action)
			if action ~= "access" then
				t.ok(node:match("^anticheat%.") ~= nil, action .. " node")
			end
		end
	end)

	t.test("permissions: no node = no flags, no actions, even calling the remote", function()
		t.eq(AntiCheatBridge.Handle(nobody, "overview").Ok, false)
		t.eq(AntiCheatBridge.Handle(nobody, "flags", {}).Ok, false)
		t.eq(AntiCheatBridge.Handle(nobody, "setMode", { Mode = "strict" }).Ok, false)
		t.eq(AntiCheatBridge.Handle(nobody, "resetScore", { UserId = 1 }).Ok, false)
		local access = AntiCheatBridge.Handle(nobody, "access")
		t.eq(access.Can.View, false)
		t.eq(access.Status, nil, "no status for non-viewers")
	end)

	t.test("permissions: view can read but not configure, act, ban or master", function()
		t.eq(AntiCheatBridge.Handle(viewer, "flags", {}).Ok, true)
		t.eq(AntiCheatBridge.Handle(viewer, "setMode", { Mode = "strict" }).Denied, true)
		t.eq(AntiCheatBridge.Handle(viewer, "kick", { UserId = 1, Reason = "x" }).Denied, true)
		t.eq(AntiCheatBridge.Handle(viewer, "exemptAdd", { UserId = 1, Module = "all", Reason = "x" }).Denied, true)
		t.eq(AntiCheatBridge.Handle(viewer, "markReviewed", { Ids = { "a" } }).Denied, true)
		t.eq(AntiCheatBridge.Handle(configurer, "setEnabled", { On = false }).Denied, true, "master is separate")
		t.eq(AntiCheatBridge.Handle(configurer, "setValue", { Path = "Core.Enabled", Value = false }).Ok, false, "no master via setValue")
	end)

	t.test("acban: is critical (owner approval / confirm) and needs anticheat.ban", function()
		local ban = CommandRegistry.Resolve("acban")
		if not ban then
			require(Sentinel:WaitForChild("Commands"):WaitForChild("AntiCheat"):WaitForChild("AntiCheat"))
			ban = CommandRegistry.Resolve("acban")
		end
		t.ok(ban ~= nil, "registered")
		t.eq(ban.Permission, "anticheat.ban")
		t.eq(ban.Risk, "critical")
		for _, name in ipairs({ "anticheat", "ac", "acstatus", "acmode", "acmodule", "acscore", "acreset", "acexempt", "acunexempt", "acwatch", "acreview", "actest", "acexport", "acpanic" }) do
			local def = CommandRegistry.Resolve(name)
			t.ok(def ~= nil, name .. " registered")
			t.ok(def.Permission:match("^anticheat%.") ~= nil, name .. " node")
		end
	end)

	-- -----------------------------------------------------------------------
	-- Remotes: argument validation
	-- -----------------------------------------------------------------------
	t.test("remotes: wrong types, oversized tables, nil and unknown actions are refused", function()
		local v = AntiCheatService.ValidateArgs
		t.ok(v(table.pack("hi", 5), { "string:10", "number:0:10" }), "valid")
		t.eq(v(table.pack(5, 5), { "string:10", "number:0:10" }), false, "wrong type")
		t.eq(v(table.pack(("x"):rep(50), 5), { "string:10", "number:0:10" }), false, "too long")
		t.eq(v(table.pack("a", 0 / 0), { "string:10", "number" }), false, "nan")
		t.eq(v(table.pack("a", 99), { "string:10", "number:0:10" }), false, "range")
		local big = {}
		for i = 1, 100 do
			big[i] = i
		end
		t.eq(v(table.pack(big), { "table:20" }), false, "oversized table")
		t.eq(v(table.pack(nil), { "string" }), false, "nil")
		t.ok(v(table.pack(nil), { "string?" }), "optional nil")
		t.eq(v(table.pack(1, 2, 3), { "number" }), false, "too many")
		t.eq(AntiCheatBridge.Handle(viewer, 123).Ok, false, "non-string action")
		t.eq(AntiCheatBridge.Handle(viewer, "dropTables").Ok, false, "unknown action")
		t.eq(AntiCheatBridge.Handle(viewer, "flag", 12345).Ok, false, "bad flag id")
		t.eq(AntiCheatBridge.Handle(viewer, "flags", { Module = { nested = true } }).Ok, true, "garbage filter ignored")
	end)

	t.test("remotes: floods are rate limited (shared RateLimiter)", function()
		local RateLimiter = require(Sentinel:WaitForChild("Core"):WaitForChild("RateLimiter"))
		local limiter = RateLimiter.new("ACTestLimiter", 5, 0)
		local p = fakePlayer(-9300, "flooder")
		local allowed = 0
		for _ = 1, 50 do
			if limiter:Allow(p) then
				allowed += 1
			end
		end
		t.eq(allowed, 5)
	end)

	-- -----------------------------------------------------------------------
	-- Config
	-- -----------------------------------------------------------------------
	t.test("config: out-of-range and wrong-type values are rejected", function()
		local ok1 = AntiCheatConfig.SetValue("Scoring.DecayPerMinute", 999)
		t.eq(ok1, false)
		local ok2, msg2 = AntiCheatConfig.SetValue("Core.Mode", "chaos")
		t.eq(ok2, false)
		t.ok(msg2:find("must be one of") ~= nil, "clear message")
		t.eq((AntiCheatConfig.SetValue("Module.SpeedCheck.Weight", 3)), false)
		t.eq((AntiCheatConfig.SetValue("Nope.Field", 1)), false)
		local bands = table.clone(AntiCheatConfig.Get("Bands"))
		bands.Band2 = 10 -- below Band1
		t.eq((AntiCheatConfig.Validate("Bands", bands)), false)
	end)

	t.test("config: valid changes apply, are audit-logged, and reset", function()
		local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))
		local before = AntiCheatConfig.Get("Scoring").DecayPerMinute
		local ok, msg = AntiCheatConfig.SetValue("Scoring.DecayPerMinute", 2)
		t.ok(ok, msg)
		t.eq(AntiCheatConfig.Get("Scoring").DecayPerMinute, 2)
		local found = false
		for _, e in ipairs(Logger.Query()) do
			if e.Changes and e.Changes[1] and e.Changes[1].Field == "Scoring.DecayPerMinute" then
				found = true
			end
		end
		t.ok(found, "audit entry with old/new value")
		AntiCheatConfig.SetValue("Scoring.DecayPerMinute", before)
		AntiCheatConfig.Reset("Scoring")
		t.eq(AntiCheatConfig.Get("Scoring").DecayPerMinute, 1)
	end)

	t.test("config: starts in Observe mode; export / import round-trip; presets preview", function()
		t.eq(AntiCheatConfig.SCHEMA.Core.Mode.Default, "observe")
		local text = AntiCheatConfig.Export()
		local ok = AntiCheatConfig.Import(text, nil, true)
		t.ok(ok, "valid export")
		t.eq((AntiCheatConfig.Import('{"Config":{"Scoring":{"DecayPerMinute":-5}}}', nil, true)), false)
		local changes = AntiCheatConfig.PreviewPreset("Strict")
		t.ok(type(changes) == "table" and #changes > 0, "preview lists changes")
	end)

	t.test("evidence: flags keep a snapshot and can be reviewed", function()
		EvidenceService._Clear()
		ScoreService._Clear()
		local p = fakePlayer(-40, "evi")
		for i = 1, 5 do
			EvidenceService.AddSample(-40, i * 0.2, Vector3.new(i, 3, 0))
		end
		local flag = DetectionEngine.Submit(p, { Module = "SpeedCheck", Severity = 4, Confidence = 0.5, Reason = "fast" }, { Silent = true })
		t.ok(flag.Evidence ~= nil and #flag.Evidence.Samples == 5, "samples")
		t.ok(flag.Evidence.ServerFps ~= nil, "fps")
		t.eq(EvidenceService.Get(flag.Id), flag)
		t.eq(EvidenceService.MarkReviewed({ flag.Id }, "mod"), 1)
		t.eq(EvidenceService.Unreviewed(), 0)
		EvidenceService._Clear()
		ScoreService._Clear()
	end)

	t.test("storage: a failing DataStore keeps data in memory and reports it", function()
		local AntiCheatStore = require(AC:WaitForChild("AntiCheatStore"))
		local store = AntiCheatStore.new("Sentinel_AC_Test_v1")
		store:Queue("1", function()
			return { a = 1 }
		end)
		t.eq(store:PendingCount(), 1)
		AntiCheatStore.SetFailing(true)
		t.eq(store:Health().Ok, false)
		AntiCheatStore.SetFailing(false)
		t.eq(store:PendingCount(), 1, "still queued")
	end)
	t.test("engine: movement modules declare their hot-path skips (Fly never skips when still)", function()
		for _, name in ipairs({ "SpeedCheck", "TeleportCheck", "NoclipCheck", "JumpCheck" }) do
			t.ok(mod(name).SkipWhenSeated == true and mod(name).SkipWhenStill == true, name)
		end
		t.ok(mod("FlyCheck").SkipWhenSeated == true, "Fly skips seated")
		t.ok(mod("FlyCheck").SkipWhenStill ~= true, "hovering in place is what Fly catches")
	end)

	t.test("engine: OnSkip keeps module state as Check would", function()
		local m: any = { Strikes = 2 }
		mod("SpeedCheck").OnSkip(m, "still")
		t.eq(m.Strikes, 1, "still decays like a clean check")
		mod("SpeedCheck").OnSkip(m, "seated")
		t.eq(m.Strikes, 0)
		local f: any = { Air = 2.5, LastNow = 1 }
		mod("FlyCheck").OnSkip(f, "seated", 10)
		t.eq(f.Air, 0)
		t.eq(f.LastNow, 10)
		local n: any = { List = { { T = 1, Part = "x" } }, RayT = 1 }
		mod("NoclipCheck").OnSkip(n, "still", 5, 4.8)
		t.eq(#n.List, 1, "still keeps passes (no reset by pausing)")
		t.eq(n.RayT, 4.8)
		mod("NoclipCheck").OnSkip(n, "seated", 6, 5.8)
		t.eq(#n.List, 0)
	end)

	t.test("JumpCheck: a vehicle ride up a hill after a take-off is not a jump", function()
		local def = mod("JumpCheck")
		local s1 = state(def, { Height = 0, GroundDistance = 20, GroundLimit = 4.5, AllowedHeight = 7.2, Now = 0 })
		t.eq(def.Check(nil, s1), nil, "take-off")
		t.ok(s1.Module.Airborne == true)
		def.OnSkip(s1.Module, "seated")
		-- Out of the vehicle at the top: briefly airborne, then landing.
		local s2 = state(def, { Height = 200, GroundDistance = 20, GroundLimit = 4.5, AllowedHeight = 7.2, Now = 30 })
		s2.Module = s1.Module
		t.eq(def.Check(nil, s2), nil, "airborne after the ride")
		local s3 = state(def, { Height = 198, GroundDistance = 3, GroundLimit = 4.5, AllowedHeight = 7.2, Now = 30.5 })
		s3.Module = s1.Module
		t.eq(def.Check(nil, s3), nil, "landing is measured from the new take-off")
	end)

	t.test("engine: Stats reports sampling, scheduler, frames, skips", function()
		local st = DetectionEngine.Stats()
		t.ok(st.Modules["(sampling)"] ~= nil and st.Modules["(scheduler)"] ~= nil, "engine rows")
		t.ok(type(st.WorstFrameMs) == "number" and type(st.PeakFrameMs) == "number", "frames")
		t.ok(type(st.DeferredPerSec) == "number" and type(st.SkippedPerSec) == "number", "deferred / skipped")
		t.ok(type(st.CrowdScale) == "number", "crowd scale")
		t.ok(type(AntiCheatConfig.Get("Core").FrameMsCap) == "number" and type(AntiCheatConfig.Get("Core").CrowdPlayers) == "number", "config")
	end)
	-- -----------------------------------------------------------------------
	-- False positives from admin tools (live test 2026-11-27)
	-- -----------------------------------------------------------------------
	local function shifted(samples: { any }, by: number): { any }
		local out = {}
		for _, sample in ipairs(samples) do
			table.insert(out, { T = sample.T + by, P = sample.P })
		end
		return out
	end

	t.test("SpeedCheck: lowering WalkSpeed mid-move (;resetspeed) does not flag", function()
		local def = mod("SpeedCheck")
		local m = {}
		local walk = track(6, Vector3.new(60 * 0.2, 0, 0)) -- 60 studs/s
		local flag = nil
		for i, ws in ipairs({ 100, 16, 16, 16 }) do
			local now = 1 + (i - 1) * 0.5
			local s = state(def, { WalkSpeed = ws, Now = now, Samples = shifted(walk, now - 1) })
			s.Module = m
			flag = def.Check(nil, s) or flag
		end
		t.eq(flag, nil, "the 100 WalkSpeed of 1.5 s ago still counts")
		-- Two seconds later the old WalkSpeed is gone: running at 60 flags again.
		for i = 1, 4 do
			local now = 4 + i * 0.5
			local s = state(def, { WalkSpeed = 16, Now = now, Samples = shifted(walk, now - 1) })
			s.Module = m
			flag = def.Check(nil, s) or flag
		end
		t.ok(flag ~= nil, "a real 60 studs/s at WalkSpeed 16 still flags")
	end)

	t.test("JumpCheck: lowering JumpPower mid-jump (;resetjump) does not flag", function()
		local def = mod("JumpCheck")
		local function run(allowances: { number }): any
			local m = {}
			local heights = { { H = 0, G = 20 }, { H = 60, G = 60 }, { H = 2, G = 3 } }
			local result = nil
			for i, step in ipairs(heights) do
				local s = state(def, { Height = step.H, GroundDistance = step.G, GroundLimit = 4.5, AllowedHeight = allowances[i], Now = i * 0.5 })
				s.Module = m
				result = def.Check(nil, s) or result
			end
			return result
		end
		t.eq(run({ 100, 7.2, 7.2 }), nil, "a 60-stud jump made with JumpPower allowing 100")
		t.ok(run({ 7.2, 7.2, 7.2 }) ~= nil, "the same jump with a normal JumpPower flags")
	end)

	t.test("ExternalAdmins: approved HD Admin flight tasks count, nothing else does", function()
		local ExternalAdmins = require(AC:WaitForChild("ExternalAdmins"))
		t.eq(select(1, ExternalAdmins.Movement(-31, 1)), false, "no HD Admin: not flying")
		local tasks: { [string]: { [number]: boolean } } = { Fly = { [-31] = true }, NoClip = { [-32] = true } }
		ExternalAdmins._SetProvider({
			getTasks = function(name: string, userId: number)
				return if tasks[name] and tasks[name][userId] then { {} } else {}
			end,
		})
		local f1, n1 = ExternalAdmins.Movement(-31, 10)
		t.ok(f1 == true and n1 == false, "Fly: flying, not noclip")
		local f2, n2 = ExternalAdmins.Movement(-32, 10)
		t.ok(f2 == true and n2 == true, "NoClip: flying and noclip")
		t.eq(select(1, ExternalAdmins.Movement(-33, 10)), false, "no task: not flying")
		tasks.Fly[-31] = nil
		t.eq(select(1, ExternalAdmins.Movement(-31, 10.5)), true, "cached for a second")
		t.eq(select(1, ExternalAdmins.Movement(-31, 11.5)), false, "then re-asked")
		ExternalAdmins._SetProvider(nil)
	end)

	t.test("engine: flight ending (Sentinel attribute) starts a movement grace", function()
		local flying = true
		local p = fakePlayer(-777, "Flyer")
		p.GetAttribute = function(_, key)
			return if key == "SentinelFlying" then flying else nil
		end
		local def = mod("SpeedCheck")
		local trustBefore = AntiCheatConfig.Get("Core").TrustSentinelCommands
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", true)
		DetectionEngine.BuildState(p, def, 100)
		t.eq(ExemptionService.InGrace(-777, "SpeedCheck"), false, "flying: no grace needed yet")
		flying = false
		DetectionEngine.BuildState(p, def, 101)
		t.eq(ExemptionService.InGrace(-777, "SpeedCheck"), true, "landing grace")
		t.eq(ExemptionService.InGrace(-777, "HealthCheck"), false, "movement modules only")
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", trustBefore == true)
		ExemptionService.Forget(-777)
	end)

	t.test("engine: HD Admin flight is checked unless Core.TrustExternalAdmins is on", function()
		local ExternalAdmins = require(AC:WaitForChild("ExternalAdmins"))
		ExternalAdmins._SetProvider({
			getTasks = function(name: string, userId: number)
				return if name == "Fly" and userId == -778 then { {} } else {}
			end,
		})
		local before = AntiCheatConfig.Get("Core").TrustExternalAdmins
		local p = fakePlayer(-778, "HDFlyer")
		p.GetAttribute = function()
			return nil
		end
		local def = mod("FlyCheck")
		AntiCheatConfig.SetValue("Core.TrustExternalAdmins", false)
		t.eq(DetectionEngine.BuildState(p, def, 200).Flying, false, "trust off (default): HD Admin fly is measured")
		AntiCheatConfig.SetValue("Core.TrustExternalAdmins", true)
		t.eq(DetectionEngine.BuildState(p, def, 201).Flying, true, "trust on: approved HD Admin fly is skipped")
		AntiCheatConfig.SetValue("Core.TrustExternalAdmins", before == true)
		ExternalAdmins._SetProvider(nil)
		ExemptionService.Forget(-778)
		t.eq(AntiCheatConfig.SCHEMA.Core.TrustExternalAdmins.Default, false, "defaults to off")
	end)

	t.test("ModuleUtil.Scripts: scripts inside tools are left to ToolIntegrityCheck", function()
		local ModuleUtil = require(AC:WaitForChild("ModuleUtil"))
		local character = Instance.new("Model")
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Parent = character
		Instance.new("Script", head).Name = "Injected"
		local tool = Instance.new("Tool")
		tool.Name = "Sword"
		tool.Parent = character
		Instance.new("Script", tool).Name = "SwordScript"
		local names = ModuleUtil.Scripts(character)
		t.ok(table.find(names, "Head.Injected") ~= nil, "body script listed")
		t.eq(table.find(names, "Sword.SwordScript"), nil, "tool script ignored")
		Instance.new("LocalScript", tool).Name = "Later"
		t.eq(table.find(ModuleUtil.Scripts(character), "Sword.Later"), nil, "added later: still ignored")
		character:Destroy()
	end)

	-- -----------------------------------------------------------------------
	-- Sentinel command trust + new modules (session 7)
	-- -----------------------------------------------------------------------
	t.test("engine: Sentinel ;fly / ;god are checked unless Core.TrustSentinelCommands is on", function()
		local p = fakePlayer(-790, "Boosted")
		p.GetAttribute = function(_, key)
			return if key == "SentinelFlying" or key == "SentinelGod" then true else nil
		end
		local def = mod("FlyCheck")
		local before = AntiCheatConfig.Get("Core").TrustSentinelCommands
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", false)
		local s = DetectionEngine.BuildState(p, def, 300)
		t.eq(s.Flying, false, "trust off: Sentinel fly measured")
		t.eq(s.God, false, "trust off: Sentinel god measured")
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", true)
		s = DetectionEngine.BuildState(p, def, 301)
		t.eq(s.Flying, true, "trust on: Sentinel fly skipped")
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", before == true)
		ExemptionService.Forget(-790)
		t.eq(AntiCheatConfig.SCHEMA.Core.TrustSentinelCommands.Default, false, "defaults to off")
	end)

	t.test("engine: a ;speed boost is measured against the natural WalkSpeed (trust off)", function()
		local p = fakePlayer(-791, "Speedy")
		ExemptionService.SetBoost(-791, "WalkSpeed", 16)
		local before = AntiCheatConfig.Get("Core").TrustSentinelCommands
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", false)
		local def = mod("SpeedCheck")
		local st = DetectionEngine.BuildState(p, def, 310)
		t.eq(st.Boosts and st.Boosts.WalkSpeed, 16, "boost visible")
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", true)
		st = DetectionEngine.BuildState(p, def, 311.6)
		t.eq(st.Boosts, nil, "trust on: no boost")
		t.eq(st.CommandBoosts and st.CommandBoosts.WalkSpeed, 16, "still listed for HumanoidStats")
		AntiCheatConfig.SetValue("Core.TrustSentinelCommands", before == true)
		ExemptionService.Forget(-791)
		t.eq(ExemptionService.Boosts(-791), nil, "forgotten")
	end)

	t.test("SpeedCheck: WalkSpeed 1000 from a command flags with trust off", function()
		local def = mod("SpeedCheck")
		local fast = track(6, Vector3.new(200 * 0.2, 0, 0))
		local s = state(def, { Humanoid = { WalkSpeed = 1000 }, Samples = fast, Boosts = { WalkSpeed = 16 } })
		def.Gather(nil :: any, s, {})
		t.eq(s.WalkSpeed, 16, "natural WalkSpeed used")
		local flag
		for _ = 1, 3 do
			flag = def.Check(nil, s) or flag
		end
		t.ok(flag ~= nil, "flagged")
		local trusted = state(def, { WalkSpeed = 1000, Samples = fast })
		for _ = 1, 4 do
			t.eq(def.Check(nil, trusted), nil, "trusted boost clean")
		end
	end)

	t.test("AntiCheat: boost commands listed, middleware runs the command", function()
		t.ok(AntiCheatService.BOOST_COMMANDS.speed and AntiCheatService.BOOST_COMMANDS.jumppower and AntiCheatService.BOOST_COMMANDS.fly, "listed")
		t.eq(AntiCheatService.BOOST_COMMANDS.tp, nil, "teleports stay legitimate")
		local ran = 0
		local result = AntiCheatService._CommandMiddleware({}, { Targets = {} }, function()
			ran += 1
			return { Success = true }
		end)
		t.eq(ran, 1, "middleware runs the command")
		t.ok(result.Success, "returns its result")
	end)

	t.test("HumanoidStatsCheck: normal stats clean, WalkSpeed 1000 flags", function()
		local def = mod("HumanoidStatsCheck")
		local s = state(def, { Stats = { WalkSpeed = 16, JumpPower = 50, MaxHealth = 100 } })
		for _ = 1, 3 do
			t.eq(def.Check(nil, s), nil)
		end
		local bad = state(def, { Stats = { WalkSpeed = 1000, JumpPower = 100, MaxHealth = 100 }, Boosts = { WalkSpeed = 16 } })
		local flag
		for _ = 1, 2 do
			flag = def.Check(nil, bad) or flag
		end
		t.ok(flag ~= nil, "flagged")
		t.eq(flag.Correct, "humanoid")
		t.eq(flag.Restore.WalkSpeed, 16, "restores the natural value")
		t.eq(def.Check(nil, bad), nil, "no repeat flag right away")
		bad.Now += 16
		def.Check(nil, bad)
		t.ok(def.Check(nil, bad) ~= nil, "flags again after RepeatSeconds")
		local trusted = state(def, { Stats = { WalkSpeed = 1000 }, CommandBoosts = { WalkSpeed = 16 } })
		for _ = 1, 3 do
			t.eq(def.Check(nil, trusted), nil, "trusted command boost skipped")
		end
	end)

	local function clicks(n: number, gap: number, jitter: number?): { any }
		local out = {}
		local tt = 0
		for i = 1, n do
			tt += gap + (if jitter then (if i % 2 == 0 then jitter else -jitter) * (i % 3) else 0)
			table.insert(out, { T = tt, D = { Tool = "Sword" } })
		end
		return out
	end

	t.test("AutoClickerCheck: human clicking clean, macro and 30 CPS flag", function()
		local def = mod("AutoClickerCheck")
		local human = clicks(30, 0.12, 0.04)
		t.eq(def.Check(nil, state(def, { Clicks = human, Now = human[#human].T })), nil, "human")
		local macro = clicks(30, 0.1)
		t.ok(def.Check(nil, state(def, { Clicks = macro, Now = macro[#macro].T })) ~= nil, "regular macro")
		local burst = clicks(40, 1 / 30, 0.005)
		local bs = state(def, { Clicks = burst, Now = burst[#burst].T, Module = { FlaggedT = math.huge } })
		local flag = def.Check(nil, bs)
		flag = def.Check(nil, bs) or flag
		t.ok(flag ~= nil and flag.Reason:find("clicks in one second") ~= nil, "30 CPS")
	end)

	t.test("AimbotCheck: normal hits clean, repeated snap hits and perfect accuracy flag", function()
		local def = mod("AimbotCheck")
		local normal = {}
		for i = 1, 6 do
			table.insert(normal, { T = i, D = { Distance = 60, Angle = 12, Turn = 20 } })
		end
		t.eq(def.Check(nil, state(def, { Hits = normal, Now = 7 })), nil, "normal")
		local snaps = {}
		for i = 1, 5 do
			table.insert(snaps, { T = i, D = { Distance = 80, Angle = 2, Turn = 150 } })
		end
		t.ok(def.Check(nil, state(def, { Hits = snaps, Now = 6 })) ~= nil, "snaps")
		local shots = {}
		for i = 1, 30 do
			table.insert(shots, { T = i * 0.5, D = { Hit = true, Headshot = true, Distance = 50 } })
		end
		t.ok(def.Check(nil, state(def, { Shots = shots, Now = 16 })) ~= nil, "100% hits")
	end)

	t.test("KillAuraCheck: one target clean, crowd and behind-hits flag", function()
		local def = mod("KillAuraCheck")
		local one = {}
		for i = 1, 8 do
			table.insert(one, { T = i * 0.25, D = { Victim = 1, Angle = 10, Distance = 5 } })
		end
		t.eq(def.Check(nil, state(def, { Hits = one, Now = 2 })), nil, "single target")
		local crowd = {}
		for v = 1, 5 do
			table.insert(crowd, { T = 0.9 + v * 0.01, D = { Victim = v, Angle = 20, Distance = 6 } })
		end
		local cs = state(def, { Hits = crowd, Now = 1 })
		t.eq(def.Check(nil, cs), nil, "one crowded second is not enough")
		cs.Now = 2.1
		for v = 1, 5 do
			table.insert(crowd, { T = 2 + v * 0.005, D = { Victim = v, Angle = 20, Distance = 6 } })
		end
		t.ok(def.Check(nil, cs) ~= nil, "crowd twice")
		local behind = {}
		for i = 1, 4 do
			table.insert(behind, { T = i * 0.5, D = { Victim = 1, Angle = 170, Distance = 5 } })
		end
		t.ok(def.Check(nil, state(def, { Hits = behind, Now = 2.1 })) ~= nil, "behind-hits")
	end)

	-- -----------------------------------------------------------------------
	-- Ban settings (session 8)
	-- -----------------------------------------------------------------------
	t.test("Bans config: 15-day temporary bans, permanent disabled by default", function()
		local schema = AntiCheatConfig.SCHEMA.Bans
		t.eq(schema.BanDays.Default, 15)
		t.eq(schema.DefaultType.Default, "temporary")
		t.eq(schema.AllowPermanent.Default, false)
		t.ok(table.find(AntiCheatConfig.SECTIONS, "Bans") ~= nil, "section listed")
		t.eq(AntiCheatConfig.SCHEMA.Bands.BanDays, nil, "moved out of Bands")
	end)

	t.test("ActionService.BanLength: temporary by default, permanent only when allowed", function()
		local defaults = { BanDays = 15, DefaultType = "temporary", AllowPermanent = false }
		t.eq((ActionService.BanLength(defaults)), 15, "default 15 days")
		local days, note = ActionService.BanLength(defaults, true)
		t.eq(days, 15, "permanent refused -> 15 days")
		t.ok(note ~= nil, "says why")
		local permDefault = { BanDays = 15, DefaultType = "permanent", AllowPermanent = false }
		t.eq((ActionService.BanLength(permDefault)), 15, "permanent default still refused")
		local allowed = { BanDays = 7, DefaultType = "permanent", AllowPermanent = true }
		t.eq((ActionService.BanLength(allowed)), 0, "allowed: permanent (0)")
		t.eq((ActionService.BanLength(allowed, false)), 7, "explicit temporary")
		t.eq((ActionService.BanLength(nil)), 15, "no config: 15")
	end)

	t.test("ActionService.IsAntiCheatBan tells anti-cheat bans from staff bans", function()
		t.ok(ActionService.IsAntiCheatBan({ Reason = "[AntiCheat] SpeedCheck: fast", BannedByName = "gabriel" }))
		t.ok(ActionService.IsAntiCheatBan({ Reason = "x", BannedByName = "Sentinel AntiCheat" }))
		t.eq(ActionService.IsAntiCheatBan({ Reason = "Exploiting", BannedByName = "gabriel" }), false)
		t.eq(ActionService.IsAntiCheatBan(nil), false)
	end)

	t.test("bridge: ban actions are permission-gated", function()
		t.eq(AntiCheatBridge.ACTIONS.banLift, "anticheat.ban")
		t.eq(AntiCheatBridge.ACTIONS.banEdit, "anticheat.ban")
		t.ok(AntiCheatBridge.ACTIONS.bans ~= nil, "list action exists")
	end)
end
