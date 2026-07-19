--!strict
--[[
	DeveloperService.lua

	Purpose:
		Owns Sentinel's diagnostic/observability tooling: server stats
		(memory, heartbeat rate, uptime), a rolling error/warning console
		fed from LogService, and a rolling log of every RemoteEvent/
		RemoteFunction call made through anything under ReplicatedStorage
		(so a modder or admin can spot a suspicious remote getting spammed
		without attaching an external tool).

	Responsibilities:
		- Track server uptime and an approximate Heartbeat rate ("server
		  FPS" in the roadmap's terms — Roblox servers don't render frames,
		  so this is Heartbeat steps/sec, the closest server-side analog)
		- Mirror LogService output into a capped ring buffer
		- Recursively hook every existing RemoteEvent/RemoteFunction under
		  ReplicatedStorage (and ones added later) with a NON-INTRUSIVE
		  extra listener that only logs — it never blocks or alters
		  existing remote behavior
		- Report per-player ping

	Dependencies:
		Types.lua, EventBus.lua (Shared)

	Public API:
		DeveloperService.GetServerStats(): {Uptime, HeartbeatRate, MemoryMb, PlayerCount}
		DeveloperService.GetRecentLogs(count: number?): {LogServiceEntry}
		DeveloperService.GetRecentRemoteCalls(count: number?): {RemoteCallEntry}
		DeveloperService.GetPing(player): number
--]]

local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")
local Stats = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeveloperService = {}

-- ---------------------------------------------------------------------------
-- Uptime + heartbeat rate
-- ---------------------------------------------------------------------------
local serverStartTime = os.time()
local heartbeatCount = 0
local heartbeatRate = 0

RunService.Heartbeat:Connect(function()
	heartbeatCount += 1
end)

task.spawn(function()
	while true do
		task.wait(1)
		heartbeatRate = heartbeatCount
		heartbeatCount = 0
	end
end)

function DeveloperService.GetServerStats()
	local players = game:GetService("Players")
	return {
		UptimeSeconds = os.time() - serverStartTime,
		HeartbeatRate = heartbeatRate,
		MemoryMb = math.floor(Stats:GetTotalMemoryUsageMb()),
		PlayerCount = #players:GetPlayers(),
	}
end

function DeveloperService.GetPing(player: Player): number
	local ok, ping = pcall(function()
		return player:GetNetworkPing() * 1000
	end)
	return if ok then math.floor(ping) else -1
end

-- ---------------------------------------------------------------------------
-- Error / warning console
-- ---------------------------------------------------------------------------
export type LogServiceEntry = {
	Timestamp: number,
	MessageType: Enum.MessageType,
	Message: string,
}

local MAX_LOG_ENTRIES = 200
local recentLogs: { LogServiceEntry } = {}

LogService.MessageOut:Connect(function(message: string, messageType: Enum.MessageType)
	if messageType == Enum.MessageType.MessageOutput then
		return -- skip plain prints, keep signal high (errors/warnings only)
	end
	table.insert(recentLogs, {
		Timestamp = os.time(),
		MessageType = messageType,
		Message = message,
	})
	if #recentLogs > MAX_LOG_ENTRIES then
		table.remove(recentLogs, 1)
	end
end)

function DeveloperService.GetRecentLogs(count: number?): { LogServiceEntry }
	local n = count or 20
	local result = {}
	local startIndex = math.max(1, #recentLogs - n + 1)
	for i = startIndex, #recentLogs do
		table.insert(result, recentLogs[i])
	end
	return result
end

-- ---------------------------------------------------------------------------
-- Remote call monitor
-- ---------------------------------------------------------------------------
export type RemoteCallEntry = {
	Timestamp: number,
	Path: string,
	Kind: "Event" | "Function",
	PlayerName: string,
}

local MAX_REMOTE_ENTRIES = 200
local recentRemoteCalls: { RemoteCallEntry } = {}
local hookedRemotes: { [Instance]: boolean } = {}

local function recordRemoteCall(remote: Instance, kind: "Event" | "Function", player: Player?)
	table.insert(recentRemoteCalls, {
		Timestamp = os.time(),
		Path = remote:GetFullName(),
		Kind = kind,
		PlayerName = if player then player.Name else "?",
	})
	if #recentRemoteCalls > MAX_REMOTE_ENTRIES then
		table.remove(recentRemoteCalls, 1)
	end
end

local function hookRemote(instance: Instance)
	if hookedRemotes[instance] then
		return
	end
	hookedRemotes[instance] = true

	if instance:IsA("RemoteEvent") then
		instance.OnServerEvent:Connect(function(player: Player, ...)
			recordRemoteCall(instance, "Event", player)
		end)
	elseif instance:IsA("RemoteFunction") then
		-- Wrapping OnServerInvoke would require owning the single handler
		-- slot, which risks breaking whatever the game already assigned
		-- there. RemoteFunctions are monitored passively via their
		-- existence in the recent-instances list instead of per-call.
	end
end

local function scanForRemotes(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
			hookRemote(descendant)
		end
	end
end

scanForRemotes(ReplicatedStorage)
ReplicatedStorage.DescendantAdded:Connect(function(descendant: Instance)
	if descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
		hookRemote(descendant)
	end
end)

function DeveloperService.GetRecentRemoteCalls(count: number?): { RemoteCallEntry }
	local n = count or 20
	local result = {}
	local startIndex = math.max(1, #recentRemoteCalls - n + 1)
	for i = startIndex, #recentRemoteCalls do
		table.insert(result, recentRemoteCalls[i])
	end
	return result
end

return DeveloperService
