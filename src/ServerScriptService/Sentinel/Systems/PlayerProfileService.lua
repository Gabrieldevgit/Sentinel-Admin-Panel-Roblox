--!strict
--[[
	PlayerProfileService.lua (W13)

	Purpose:
		Offline player management. Remembers every player who joins
		(DataStore Sentinel_Profiles_v1, key UserId): first / last seen,
		sessions, play time, last server, display name and every username
		seen (previous usernames, as far as Sentinel saw them), and builds a
		full profile for any Roblox user, online or offline: identity, the
		stored profile, where they are now, active ban, warnings, moderation
		cases, staff notes and rank bindings.

	Public API:
		PlayerProfileService.Resolve(text) -> (user?, err?)
			username / UserId / online name -> { UserId, Name, DisplayName?, Local? }
		PlayerProfileService.GetStored(userId) -> stored profile?
		PlayerProfileService.Profile(text, executor?) -> (profile?, err?)  ("me" = executor)
		PlayerProfileService.SetProviders({ GetActiveBan, GetNotes }) (commands
			register their stores here; Systems can't require Commands)
		PlayerProfileService.FormatAge(seconds) -> "3d 4h"
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserService = game:GetService("UserService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Logger = require(Core:WaitForChild("Logger"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))

local PlayerProfileService = {}

local LIVE = RunService:IsRunning() and RunService:IsServer()
local store = if LIVE then DataStoreService:GetDataStore("Sentinel_Profiles_v1") else nil

local MAX_NAMES = 10

export type Stored = {
	UserId: number,
	Name: string,
	DisplayName: string?,
	Names: { string }, -- usernames seen, oldest first
	FirstSeen: number,
	LastSeen: number,
	Sessions: number,
	PlayTime: number, -- seconds
	LastServer: string?,
	AccountAge: number?, -- days, at last join
}

local providers: { [string]: any } = {}

function PlayerProfileService.SetProviders(list: { [string]: any })
	for k, v in pairs(list) do
		providers[k] = v
	end
end

function PlayerProfileService.FormatAge(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m"
	elseif seconds < 86400 then
		return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
	end
	return ("%dd %dh"):format(math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

-- ---------------------------------------------------------------------------
-- Lookup (cached: Roblox's name service is rate limited)
-- ---------------------------------------------------------------------------
local nameCache: { [string]: { Id: number, At: number } } = {}
local idCache: { [number]: { Name: string, At: number } } = {}
local CACHE_SECONDS = 600

local function nameFromId(userId: number): string?
	local hit = idCache[userId]
	if hit and os.clock() - hit.At < CACHE_SECONDS then
		return hit.Name
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if ok and type(name) == "string" then
		idCache[userId] = { Name = name, At = os.clock() }
		return name
	end
	return nil
end

local function idFromName(name: string): number?
	local key = name:lower()
	local hit = nameCache[key]
	if hit and os.clock() - hit.At < CACHE_SECONDS then
		return hit.Id
	end
	local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, name)
	if ok and type(id) == "number" then
		nameCache[key] = { Id = id, At = os.clock() }
		return id
	end
	return nil
end

function PlayerProfileService.Resolve(text: string?, executor: any?): (any, string?)
	if type(text) ~= "string" or text == "" then
		return nil, "Give a username or UserId."
	end
	if executor and (text:lower() == "me" or text:lower() == "self") then
		text = tostring(executor.UserId)
	end
	text = text:gsub("^@", "")
	local asId = tonumber(text)
	if asId and (asId <= 0 or asId % 1 ~= 0 or asId >= 2 ^ 53) then
		return nil, "That is not a valid UserId."
	end
	local lower = text:lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == asId or p.Name:lower() == lower or (not asId and p.DisplayName:lower() == lower) then
			return { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName, Local = p }, nil
		end
	end
	if asId then
		local name = nameFromId(asId)
		if not name then
			return nil, ("No Roblox user with id %d."):format(asId)
		end
		return { UserId = asId, Name = name }, nil
	end
	if #text > 20 or not text:match("^[%w_]+$") then
		return nil, ("'%s' is not a valid username."):format(text)
	end
	local id = idFromName(text)
	if not id then
		return nil, ("No Roblox user named '%s'."):format(text)
	end
	return { UserId = id, Name = nameFromId(id) or text }, nil
end

-- ---------------------------------------------------------------------------
-- Stored profiles
-- ---------------------------------------------------------------------------
local live: { [number]: { Joined: number } } = {}
local storedCache: { [number]: Stored } = {}

function PlayerProfileService.GetStored(userId: number): Stored?
	if storedCache[userId] then
		return storedCache[userId]
	end
	if not store then
		return nil
	end
	local ok, value = pcall(function()
		return store:GetAsync(tostring(userId))
	end)
	if ok and type(value) == "table" then
		storedCache[userId] = value
		return value
	end
	return nil
end

-- Pure merge (tests): applies a join or leave to a stored profile.
function PlayerProfileService.Merge(old: any, player: any, event: string, now: number, sessionSeconds: number?, serverId: string?): Stored
	local p: Stored = if type(old) == "table"
		then old
		else {
			UserId = player.UserId,
			Name = player.Name,
			Names = {},
			FirstSeen = now,
			LastSeen = now,
			Sessions = 0,
			PlayTime = 0,
		}
	p.Names = p.Names or {}
	if not table.find(p.Names, player.Name) then
		table.insert(p.Names, player.Name)
		while #p.Names > MAX_NAMES do
			table.remove(p.Names, 1)
		end
	end
	p.Name = player.Name
	p.DisplayName = player.DisplayName
	p.LastSeen = now
	p.LastServer = serverId or p.LastServer
	if event == "join" then
		p.Sessions = (p.Sessions or 0) + 1
		if type(player.AccountAge) == "number" then
			p.AccountAge = player.AccountAge
		end
	elseif event == "leave" and sessionSeconds then
		p.PlayTime = (p.PlayTime or 0) + math.max(0, math.floor(sessionSeconds))
	end
	return p
end

local function update(player: Player, event: string, sessionSeconds: number?)
	if not store then
		return
	end
	local info = { UserId = player.UserId, Name = player.Name, DisplayName = player.DisplayName, AccountAge = player.AccountAge }
	local ok, value = pcall(function()
		return store:UpdateAsync(tostring(player.UserId), function(old)
			return PlayerProfileService.Merge(old, info, event, os.time(), sessionSeconds, Logger.GetServerId())
		end)
	end)
	if ok and type(value) == "table" then
		storedCache[player.UserId] = value
	else
		warn("[Sentinel.PlayerProfileService] profile update failed: " .. tostring(value))
	end
end

-- ---------------------------------------------------------------------------
-- Full profile
-- ---------------------------------------------------------------------------
function PlayerProfileService.Profile(text: string, executor: any?): (any, string?)
	local user, err = PlayerProfileService.Resolve(text, executor)
	if not user then
		return nil, err
	end
	local userId = user.UserId
	local profile: { [string]: any } = {
		UserId = userId,
		Name = user.Name,
		DisplayName = user.DisplayName,
		Online = user.Local ~= nil,
	}

	if not profile.DisplayName then
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync({ userId })
		end)
		if ok and type(infos) == "table" and infos[1] then
			profile.DisplayName = infos[1].DisplayName
			profile.Verified = infos[1].HasVerifiedBadge
		end
	end

	local stored = PlayerProfileService.GetStored(userId)
	if stored then
		profile.FirstSeen = stored.FirstSeen
		profile.LastSeen = stored.LastSeen
		profile.Sessions = stored.Sessions
		profile.PlayTime = stored.PlayTime
		profile.LastServer = stored.LastServer
		profile.Names = stored.Names
		profile.AccountAge = stored.AccountAge
	end

	if user.Local then
		local p = user.Local :: Player
		profile.AccountAge = p.AccountAge
		profile.Server = "this server"
		profile.Ranks = PermissionSystem.GetRoles(p)
		local session = live[userId]
		if session then
			profile.SessionSeconds = os.time() - session.Joined
		end
	else
		local ok, CrossServerService = pcall(require, script.Parent:FindFirstChild("CrossServerService") :: any)
		if ok and CrossServerService then
			local found = (CrossServerService :: any).FindPlayers(tostring(userId), 5)
			for _, m in ipairs(found) do
				if m.UserId == userId then
					profile.Server = m.ServerId
					profile.Online = true
				end
			end
		end
	end

	-- Rank bindings that name this UserId (group ranks need the player).
	local okRank, RankService = pcall(require, script.Parent:FindFirstChild("RankService") :: any)
	if okRank and RankService then
		local bound = {}
		for _, b in ipairs((RankService :: any).GetBindings()) do
			if b.Kind == "UserId" and b.Value == userId then
				table.insert(bound, b.Rank)
			end
		end
		if game.CreatorType == Enum.CreatorType.User and game.CreatorId == userId then
			table.insert(bound, "Owner (creator)")
		end
		profile.BoundRanks = bound
	end

	if providers.GetActiveBan then
		local ok, ban = pcall(providers.GetActiveBan, userId)
		if ok and ban then
			profile.Ban = {
				Reason = ban.Reason,
				IssuedAt = ban.IssuedAt,
				ExpiresAt = if ban.ExpiresAt == math.huge then -1 else ban.ExpiresAt,
				BannedBy = ban.BannedBy,
			}
		end
	end

	local okPun, PunishmentService = pcall(require, script.Parent:FindFirstChild("PunishmentService") :: any)
	if okPun and PunishmentService then
		local warnings = (PunishmentService :: any).GetWarnings(userId)
		profile.Warnings = table.move(warnings, math.max(1, #warnings - 19), #warnings, 1, {})
		profile.WarningCount = #warnings
	end

	if providers.GetNotes then
		local ok, notes = pcall(providers.GetNotes, userId)
		if ok and type(notes) == "table" then
			profile.Notes = table.move(notes, math.max(1, #notes - 19), #notes, 1, {})
		end
	end

	local okCase, CaseService = pcall(require, script.Parent:FindFirstChild("CaseService") :: any)
	if okCase and CaseService then
		local found = (CaseService :: any).Search({ Player = tostring(userId) }, nil, 30)
		profile.Cases = found.Cases
		profile.CaseCount = found.Total
	end

	return profile, nil
end

if LIVE then
	local function onJoin(player: Player)
		live[player.UserId] = { Joined = os.time() }
		task.spawn(update, player, "join")
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, p in ipairs(Players:GetPlayers()) do
		onJoin(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		local session = live[player.UserId]
		live[player.UserId] = nil
		update(player, "leave", if session then os.time() - session.Joined else 0)
	end)
	game:BindToClose(function()
		for _, p in ipairs(Players:GetPlayers()) do
			local session = live[p.UserId]
			if session then
				live[p.UserId] = nil
				update(p, "leave", os.time() - session.Joined)
			end
		end
	end)
end

return PlayerProfileService
