--!strict
--[[
	LoadTest.lua (Sentinel AntiCheat - cost measurement; Studio or a
	private server only)

	Measures what the detection engine costs with many players, without
	needing that many clients: spawns `count` R15 dummy rigs near the
	caller, tracks each one through the real DetectionEngine (a proxy table
	stands in for its Player), drives them for `seconds`, and reports the
	engine's own numbers: total ms/s, per-module ms/s, sampling and
	scheduler overhead, worst frame (each second and overall), checks,
	deferred and skipped checks per second. Dummy flags are counted, never
	scored or stored (DetectionEngine.Track opts.LoadTest).

	Mix of behaviour: ~60% walk between random points, ~20% stand still,
	~20% walk and jump. Dummies are server-owned NPCs, so this measures the
	checks, not network effects - a published test with real players is
	still the final word.

	Public API:
		LoadTest.Start(count, seconds, center?) -> (ok, message)  (async)
		LoadTest.Running() -> boolean
		LoadTest.LastReport() -> string?
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DetectionEngine = require(script.Parent:WaitForChild("DetectionEngine"))
local EvidenceService = require(script.Parent:WaitForChild("EvidenceService"))
local ModuleUtil = require(script.Parent:WaitForChild("ModuleUtil"))

local LoadTest = {}

local running = false
local lastReport: string? = nil
local WARMUP = 5

-- A Player stand-in: fields the engine and modules read, methods forwarded
-- to a Folder (FindFirstChild, GetAttribute, WaitForChild, ...).
local function makeProxy(userId: number, name: string, character: Model): any
	local folder = Instance.new("Folder")
	folder.Name = name
	local backpack = Instance.new("Folder")
	backpack.Name = "Backpack"
	backpack.Parent = folder
	local fields: { [string]: any } = {
		UserId = userId,
		Name = name,
		DisplayName = name,
		Character = character,
		AccountAge = 365,
		Backpack = backpack,
		Parent = Players,
		-- The hot methods as plain functions (a real Player's are native;
		-- a metatable + pcall per call would inflate the measurement).
		GetAttribute = function(_, key)
			return folder:GetAttribute(key)
		end,
		GetNetworkPing = function()
			return 0.08
		end,
		FindFirstChild = function(_, childName, recursive)
			return folder:FindFirstChild(childName, recursive)
		end,
		FindFirstChildOfClass = function(_, className)
			return folder:FindFirstChildOfClass(className)
		end,
		IsA = function(_, className)
			return className == "Player" or className == "Instance"
		end,
	}
	local proxy = setmetatable(fields, {
		__index = function(_, key)
			local ok, value = pcall(function()
				return (folder :: any)[key]
			end)
			if ok and type(value) == "function" then
				return function(_self, ...)
					return value(folder, ...)
				end
			end
			return if ok then value else nil
		end,
		__tostring = function()
			return name
		end,
	})
	return proxy, folder
end

local function report(lines: { string })
	local text = table.concat(lines, "\n")
	lastReport = text
	print("[Sentinel.AntiCheat] Load test report\n" .. text)
end

function LoadTest.Running(): boolean
	return running
end

function LoadTest.LastReport(): string?
	return lastReport
end

-- noStretch: hold the budget stretch at 1x for the run, so the report is
-- the full unthrottled cost of every check at this player count.
function LoadTest.Start(count: number, seconds: number, center: Vector3?, noStretch: boolean?): (boolean, string)
	-- Studio, or a private server (a real Roblox server nobody joins by
	-- accident - the way to measure live hardware). Never a public server.
	if not RunService:IsStudio() and game.PrivateServerId == "" then
		return false, "The load test only runs in Studio or a private server (it spawns NPCs)."
	end
	if running then
		return false, "A load test is already running."
	end
	count = math.clamp(math.floor(count), 1, 100)
	seconds = math.clamp(math.floor(seconds), 10, 600)
	running = true
	local dummies: { any } = {}
	task.spawn(function()
		local ok, err = pcall(function()
			local origin = center or Vector3.new(0, 10, 0)
			local template = Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
			local folder = Instance.new("Folder")
			folder.Name = "SentinelLoadTest"
			folder.Parent = Workspace
			local characters: { Instance } = {}
			for i = 1, count do
				local rig = template:Clone()
				rig.Name = "LoadTestDummy" .. i
				local angle = (i / count) * math.pi * 2
				local radius = 12 + (i % 5) * 6
				rig:PivotTo(CFrame.new(origin + Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)))
				rig.Parent = folder
				local userId = -100000 - i
				local proxy, holder = makeProxy(userId, rig.Name, rig)
				local kind = if i % 5 == 0 then "idle" elseif i % 5 == 1 then "jump" else "walk"
				table.insert(dummies, { Rig = rig, Proxy = proxy, Holder = holder, Kind = kind, UserId = userId })
				table.insert(characters, rig)
			end
			template:Destroy()
			ModuleUtil.SetExtraCharacters(characters)
			for _, d in ipairs(dummies) do
				DetectionEngine.Track(d.Proxy, { LoadTest = true })
			end

			-- Drive them: new destination every 2-4 s, jumpers jump each step.
			local stop = false
			task.spawn(function()
				while not stop do
					for _, d in ipairs(dummies) do
						local humanoid = d.Rig:FindFirstChildOfClass("Humanoid")
						if humanoid and d.Kind ~= "idle" and math.random() < 0.4 then
							local target = origin + Vector3.new(math.random(-60, 60), 0, math.random(-60, 60))
							humanoid:MoveTo(target)
							if d.Kind == "jump" then
								humanoid.Jump = true
							end
						end
					end
					task.wait(1)
				end
			end)

			DetectionEngine.LockStretch(noStretch == true)
			task.wait(WARMUP)
			DetectionEngine.ResetPeak()
			local perSecond = {}
			local worstFrame = 0
			for _ = 1, seconds do
				task.wait(1)
				local stats = DetectionEngine.Stats()
				table.insert(perSecond, stats)
				worstFrame = math.max(worstFrame, stats.WorstFrameMs or 0)
			end
			stop = true
			DetectionEngine.LockStretch(false)

			-- Summary: averages of the per-second readings (the engine's own
			-- values are smoothed 1 s windows).
			local n = #perSecond
			local sum = { Ms = 0, Checks = 0, Deferred = 0, Skipped = 0 }
			local maxMs = 0
			local modules: { [string]: number } = {}
			for _, st in ipairs(perSecond) do
				sum.Ms += st.MsPerSec
				sum.Checks += st.ChecksPerSec
				sum.Deferred += st.DeferredPerSec or 0
				sum.Skipped += st.SkippedPerSec or 0
				maxMs = math.max(maxMs, st.MsPerSec)
				for name, m in pairs(st.Modules) do
					modules[name] = (modules[name] or 0) + m.MsPerSec
				end
			end
			local last = perSecond[n]
			local lines = {
				("%d dummies (%s), %d s measured after %d s warm-up, %s, %s"):format(count, "60% walk / 20% idle / 20% jump", seconds, WARMUP, if RunService:IsStudio() then "Studio" else "live private server", if noStretch then "stretch locked at 1x (full cost)" else "budget stretch active"),
				("Total: %.3f ms/s average, %.3f ms/s highest second (budget %.1f)"):format(sum.Ms / n, maxMs, last.Budget or 2),
				("Per player: %.4f ms/s"):format(sum.Ms / n / count),
				("Worst frame: %.3f ms (cap %.2f ms per frame)"):format(math.max(worstFrame, last.PeakFrameMs or 0), last.FrameMsCap or 0.5),
				("Checks: %.0f/s, skipped %.0f/s, frames with deferred checks %.1f/s"):format(sum.Checks / n, sum.Skipped / n, sum.Deferred / n),
				("Interval stretch: budget x%.2f, crowd x%.2f"):format(last.CostFactor or 1, last.CrowdScale or 1),
				"Per module (ms/s, average):",
			}
			local names = {}
			for name in pairs(modules) do
				table.insert(names, name)
			end
			table.sort(names, function(a, b)
				return modules[a] > modules[b]
			end)
			for _, name in ipairs(names) do
				table.insert(lines, ("  %-26s %.3f"):format(name, modules[name] / n))
			end
			local flags, errors = 0, {}
			for name, m in pairs(last.Modules) do
				flags += m.Flags or 0
				if (m.Errors or 0) > 0 then
					table.insert(errors, ("%s %d (%s)"):format(name, m.Errors, tostring(m.LastError)))
				end
			end
			table.insert(lines, ("Flags raised on dummies (counted, not stored): %d since the server started"):format(flags))
			table.insert(lines, "Module errors: " .. (if #errors > 0 then table.concat(errors, "; ") else "none"))

			for _, d in ipairs(dummies) do
				DetectionEngine.Untrack(d.Proxy)
				EvidenceService.Forget(d.UserId)
				d.Holder:Destroy()
			end
			ModuleUtil.SetExtraCharacters({})
			folder:Destroy()
			report(lines)
		end)
		running = false
		DetectionEngine.LockStretch(false)
		if not ok then
			for _, d in ipairs(dummies) do
				pcall(DetectionEngine.Untrack, d.Proxy)
				EvidenceService.Forget(d.UserId)
			end
			ModuleUtil.SetExtraCharacters({})
			local leftover = Workspace:FindFirstChild("SentinelLoadTest")
			if leftover then
				leftover:Destroy()
			end
			warn("[Sentinel.AntiCheat] load test failed: " .. tostring(err))
			lastReport = "Load test failed: " .. tostring(err)
		end
	end)
	return true, ("Load test started: %d dummies for %d s (+%d s warm-up). Results print to the server output; ;acloadtest result shows them."):format(count, seconds, WARMUP)
end

return LoadTest
