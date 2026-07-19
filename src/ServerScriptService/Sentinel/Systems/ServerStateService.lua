--!strict
--[[
	ServerStateService.lua

	Purpose:
		Owns whole-server state that affects who can join and how fast
		players can chat: locked, maintenance mode, and slow mode.

	Responsibilities:
		- Track Locked / MaintenanceMode / SlowModeSeconds in memory
		  (server-instance scoped by design — these are per-server live-ops
		  toggles, not persistent game-wide settings)
		- Enforce Locked/MaintenanceMode on PlayerAdded (staff with
		  "server.bypass" permission are let through either state)
		- Enforce SlowMode by tracking last-chat-time per player and
		  disconnecting nothing — chat throttling is advisory here since
		  actually blocking legacy chat isn't supported (same limitation
		  documented in ChatModerationService)

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		PermissionSystem.lua (Core)

	Public API:
		ServerStateService.SetLocked(locked: boolean): ()
		ServerStateService.SetMaintenanceMode(enabled: boolean): ()
		ServerStateService.SetSlowMode(seconds: number): ()
		ServerStateService.IsOnCooldown(player): boolean -- for slow mode
--]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local PermissionSystem = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PermissionSystem"))

local ServerStateService = {}

local locked = false
local maintenanceMode = false
local slowModeSeconds = 0
local lastChatTime: { [number]: number } = {}

function ServerStateService.SetLocked(value: boolean)
	locked = value
	EventBus.Publish("Server.LockedChanged", value)
end

function ServerStateService.IsLocked(): boolean
	return locked
end

function ServerStateService.SetMaintenanceMode(value: boolean)
	maintenanceMode = value
	EventBus.Publish("Server.MaintenanceModeChanged", value)
end

function ServerStateService.IsMaintenanceMode(): boolean
	return maintenanceMode
end

function ServerStateService.SetSlowMode(seconds: number)
	slowModeSeconds = math.max(0, seconds)
	EventBus.Publish("Server.SlowModeChanged", slowModeSeconds)
end

function ServerStateService.GetSlowMode(): number
	return slowModeSeconds
end

-- Returns true (blocked) if the player must wait before their next message.
function ServerStateService.IsOnSlowModeCooldown(player: Player): boolean
	if slowModeSeconds <= 0 then
		return false
	end
	local last = lastChatTime[player.UserId]
	if last and os.clock() - last < slowModeSeconds then
		return true
	end
	lastChatTime[player.UserId] = os.clock()
	return false
end

Players.PlayerAdded:Connect(function(player: Player)
	local bypasses = PermissionSystem.Has(player, "server.bypass")
	if bypasses then
		return
	end
	if locked then
		player:Kick("This server is currently locked to new joiners.")
		return
	end
	if maintenanceMode then
		player:Kick("This game is undergoing maintenance. Please check back shortly.")
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastChatTime[player.UserId] = nil
end)

return ServerStateService
