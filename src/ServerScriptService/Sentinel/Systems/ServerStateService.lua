--!strict
--[[
	ServerStateService.lua

	Purpose:
		Owns whole-server state that affects who can join and how fast
		players can chat: locked, maintenance mode, slow mode, and (W22) a
		soft player cap, custom lock / maintenance messages, whitelist-only
		mode and private-server restrictions - all checked by one join gate.

	Responsibilities:
		- Locked / MaintenanceMode / SlowModeSeconds / Capacity / messages
		  are in memory (per-server live-ops toggles).
		- Whitelist mode is the ConfigService key `WhitelistMode` (persisted,
		  pushed to every server). The whitelist itself stays in
		  Commands/Moderation/AccessList (it hands over its lookup with
		  SetWhitelistProvider - Systems can't require Commands).
		- Private-server access is the ConfigService key
		  `PrivateServerAccess`: open | friends (owner + owner's friends) |
		  staff (owner + Sentinel staff). Only VIP servers (owner id ~= 0);
		  reserved servers are left alone (migration uses them).
		- Join gate: waits for RankService to finish resolving the player's
		  ranks (group bindings yield), then staff with "server.bypass" go
		  through; everyone else is checked by EvaluateJoin (pure, tested).
		- Slow mode: last-chat-time per player.

	Public API:
		SetLocked(on, message?) / IsLocked()
		SetMaintenanceMode(on, message?) / IsMaintenanceMode()
		SetSlowMode(seconds) / GetSlowMode() / IsOnSlowModeCooldown(player)
		SetCapacity(n?) / GetCapacity()            -- nil = no soft cap
		GetMessages() -> { Lock, Maintenance }     -- custom texts or nil
		IsWhitelistMode() / SetWhitelistProvider(fn(userId) -> boolean)
		GetPrivateServerAccess() -> "open"|"friends"|"staff"
		EvaluateJoin(info) -> kick message?        -- pure
		DEFAULT_MESSAGES
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local PermissionSystem = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local ServerStateService = {}

ServerStateService.DEFAULT_MESSAGES = {
	Lock = "This server is currently locked to new joiners.",
	Maintenance = "This game is undergoing maintenance. Please check back shortly.",
	Whitelist = "This game is currently whitelist-only.",
	Capacity = "This server is full right now. Please join another server.",
	PrivateFriends = "This private server only admits the owner's friends.",
	PrivateStaff = "This private server is restricted to its owner and staff.",
}

ConfigService.Define("WhitelistMode", false, function(v)
	return type(v) == "boolean"
end)
ConfigService.Define("PrivateServerAccess", "open", function(v)
	return v == "open" or v == "friends" or v == "staff"
end)

local locked = false
local maintenanceMode = false
local slowModeSeconds = 0
local capacity: number? = nil
local lockMessage: string? = nil
local maintenanceMessage: string? = nil
local lastChatTime: { [number]: number } = {}
local whitelistProvider: ((number) -> boolean)? = nil

local function cleanMessage(message: string?): string?
	if type(message) ~= "string" then
		return nil
	end
	local text = message:match("^%s*(.-)%s*$") :: string
	if text == "" then
		return nil
	end
	return text:sub(1, 200)
end

function ServerStateService.SetLocked(value: boolean, message: string?)
	locked = value
	lockMessage = if value then cleanMessage(message) else nil
	EventBus.Publish("Server.LockedChanged", value)
end

function ServerStateService.IsLocked(): boolean
	return locked
end

function ServerStateService.SetMaintenanceMode(value: boolean, message: string?)
	maintenanceMode = value
	maintenanceMessage = if value then cleanMessage(message) else nil
	EventBus.Publish("Server.MaintenanceModeChanged", value)
end

function ServerStateService.IsMaintenanceMode(): boolean
	return maintenanceMode
end

function ServerStateService.GetMessages(): { Lock: string?, Maintenance: string? }
	return { Lock = lockMessage, Maintenance = maintenanceMessage }
end

function ServerStateService.SetSlowMode(seconds: number)
	slowModeSeconds = math.max(0, seconds)
	EventBus.Publish("Server.SlowModeChanged", slowModeSeconds)
end

function ServerStateService.GetSlowMode(): number
	return slowModeSeconds
end

-- Soft cap: Players.MaxPlayers can't change at runtime, so non-staff joiners
-- beyond `n` players are turned away instead. nil / 0 = off.
function ServerStateService.SetCapacity(n: number?)
	if n and n > 0 then
		capacity = math.floor(n)
	else
		capacity = nil
	end
	EventBus.Publish("Server.CapacityChanged", capacity)
end

function ServerStateService.GetCapacity(): number?
	return capacity
end

function ServerStateService.IsWhitelistMode(): boolean
	return ConfigService.Get("WhitelistMode") == true
end

function ServerStateService.SetWhitelistProvider(fn: (number) -> boolean)
	whitelistProvider = fn
end

function ServerStateService.GetPrivateServerAccess(): string
	local v = ConfigService.Get("PrivateServerAccess")
	return if type(v) == "string" then v else "open"
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

--[[
	Pure join decision (unit-tested). info fields:
		Bypass        staff with server.bypass
		Locked, LockMessage, Maintenance, MaintenanceMessage
		WhitelistMode, Whitelisted
		Capacity (number?), PlayerCount (including the joiner)
		PrivateAccess ("open"|"friends"|"staff"), IsPrivate (VIP server),
		IsOwner, IsFriend (of the owner), IsStaff
	Returns the kick message, or nil to let the player in.
--]]
function ServerStateService.EvaluateJoin(info: any): string?
	local M = ServerStateService.DEFAULT_MESSAGES
	if info.Bypass then
		return nil
	end
	if info.Locked then
		return info.LockMessage or M.Lock
	end
	if info.Maintenance then
		return info.MaintenanceMessage or M.Maintenance
	end
	if info.IsPrivate and not info.IsOwner then
		if info.PrivateAccess == "staff" and not info.IsStaff then
			return M.PrivateStaff
		elseif info.PrivateAccess == "friends" and not info.IsFriend and not info.IsStaff then
			return M.PrivateFriends
		end
	end
	if info.WhitelistMode and not info.Whitelisted then
		return M.Whitelist
	end
	if info.Capacity and (info.PlayerCount or 0) > info.Capacity then
		return M.Capacity
	end
	return nil
end

-- RankService resolves ranks asynchronously (group lookups yield). Wait a
-- little for it so a group-ranked staff member isn't turned away.
local rankResolved: ((Player) -> boolean)? = nil
function ServerStateService.SetRankResolvedCheck(fn: (Player) -> boolean)
	rankResolved = fn
end

local function checkJoin(player: Player)
	local check = rankResolved
	if check then
		local deadline = os.clock() + 10
		while player.Parent == Players and not check(player) and os.clock() < deadline do
			task.wait(0.1)
		end
	end
	if player.Parent ~= Players then
		return
	end
	local ownerId = game.PrivateServerOwnerId
	local isPrivate = game.PrivateServerId ~= "" and ownerId ~= 0
	local access = ServerStateService.GetPrivateServerAccess()
	local isStaff = PermissionSystem.Has(player, "panel.open")
	local isFriend = false
	if isPrivate and access == "friends" and player.UserId ~= ownerId then
		local ok, friends = pcall(player.IsFriendsWith, player, ownerId)
		isFriend = ok and friends == true
	end
	local whitelistMode = ServerStateService.IsWhitelistMode()
	local whitelisted = false
	if whitelistMode and whitelistProvider then
		local ok, value = pcall(whitelistProvider, player.UserId)
		whitelisted = ok and value == true
	end
	local message = ServerStateService.EvaluateJoin({
		Bypass = PermissionSystem.Has(player, "server.bypass"),
		Locked = locked,
		LockMessage = lockMessage,
		Maintenance = maintenanceMode,
		MaintenanceMessage = maintenanceMessage,
		WhitelistMode = whitelistMode,
		Whitelisted = whitelisted,
		Capacity = capacity,
		PlayerCount = #Players:GetPlayers(),
		PrivateAccess = access,
		IsPrivate = isPrivate,
		IsOwner = player.UserId == ownerId,
		IsFriend = isFriend,
		IsStaff = isStaff,
	})
	if message then
		player:Kick(message)
	end
end

if RunService:IsRunning() then
	Players.PlayerAdded:Connect(checkJoin)
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastChatTime[player.UserId] = nil
end)

return ServerStateService
