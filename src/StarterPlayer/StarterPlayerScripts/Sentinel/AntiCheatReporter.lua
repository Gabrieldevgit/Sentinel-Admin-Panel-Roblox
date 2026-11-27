--!strict
--[[
	AntiCheatReporter.lua (Sentinel AntiCheat - tiny client reporter)

	Runs for every player. Sends the server raw, untrusted observations
	only - never a verdict:
	  - a heartbeat every 20 s (a reporter that goes silent is itself a weak
	    hint: something removed it)
	  - "core_missing" when Sentinel's own client scripts disappear
	The server gives this script a session token at join and ignores
	reports without it, limits the rate, accepts only known kinds and
	weights them low (ClientReportCheck, severity 2). A client can be
	spoofed, so nothing here can punish anyone on its own.

	Public API: AntiCheatReporter.Init()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AntiCheatReporter = {}

function AntiCheatReporter.Init()
	task.spawn(function()
		local shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
		local remote = shared:WaitForChild("AntiCheatReportRemote", 60) :: RemoteEvent?
		if not remote then
			return
		end
		local token: string? = nil
		remote.OnClientEvent:Connect(function(kind: any, value: any)
			if kind == "token" and type(value) == "string" then
				token = value
			end
		end)
		for _ = 1, 5 do
			remote:FireServer("hello")
			task.wait(3)
			if token then
				break
			end
		end
		if not token then
			return
		end
		local container = script.Parent
		local watched = {}
		for _, name in ipairs({ "PlayerForms", "ModuleHost", "SoftShutdown" }) do
			if container:FindFirstChild(name) then
				table.insert(watched, name)
			end
		end
		local reported: { [string]: boolean } = {}
		while true do
			remote:FireServer("hb", token)
			for _, name in ipairs(watched) do
				if not container:FindFirstChild(name) and not reported[name] then
					reported[name] = true
					remote:FireServer("report", token, "core_missing", name)
				end
			end
			task.wait(20)
		end
	end)
end

return AntiCheatReporter
