--!strict
--[[
	UIBridge.lua

	Purpose:
		The ONLY place Sentinel's future GUI (Phase 7) talks to the server.
		Exposes exactly three remotes, all deliberately narrow in scope:
		- GetCommandListRemote (RemoteFunction): read-only command metadata
		  for the command palette's autocomplete/docs (no secrets exposed —
		  just Name/Aliases/Description/Usage/Permission/Category).
		- ExecuteCommandRemote (RemoteEvent, client -> server): the SAME
		  CommandProcessor.Process path the chat hook uses. The player is
		  taken from the RemoteEvent's built-in server-side parameter, never
		  trusted from client-sent data, so this carries no more risk than
		  typing the command in chat — permission checks, cooldowns, and
		  logging in CommandRegistry.Dispatch all still apply unchanged.
		- CommandResultRemote (RemoteEvent, server -> client): sends the
		  result of an executed command back to the client that ran it.
		- GetServerStatsRemote (RemoteFunction): thin wrapper around
		  DeveloperService.GetServerStats() for the UI's status bar.
		- GetPlayerListRemote (RemoteFunction): read-only snapshot of every
		  connected player (Name/DisplayName/Team/Health/Ping/Roles) for the
		  Player Explorer page.
		- CanOpenPanelRemote (RemoteFunction): the client calls this before
		  building ANY UI at all. Returns false for non-staff, so the panel
		  is never even constructed client-side for players who can't use
		  it — not just gated at the command-execution step.

	Responsibilities:
		- Create these remotes once under ReplicatedStorage.Shared.Sentinel
		- Wire ExecuteCommandRemote through CommandProcessor exactly like
		  the chat hook does

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua, Parser/CommandProcessor.lua (Core)
		DeveloperService.lua, PermissionSystem.lua (Systems/Core)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local CommandProcessor = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("CommandProcessor"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))
local DeveloperService = require(Sentinel:WaitForChild("Systems"):WaitForChild("DeveloperService"))
local ServerStateService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ServerStateService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local function getOrCreate(name: string, className: string): Instance
	local existing = SentinelShared:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = SentinelShared
	return instance
end

local getCommandListRemote = getOrCreate("GetCommandListRemote", "RemoteFunction") :: RemoteFunction
local executeCommandRemote = getOrCreate("ExecuteCommandRemote", "RemoteEvent") :: RemoteEvent
local commandResultRemote = getOrCreate("CommandResultRemote", "RemoteEvent") :: RemoteEvent
local getServerStatsRemote = getOrCreate("GetServerStatsRemote", "RemoteFunction") :: RemoteFunction
local getPlayerListRemote = getOrCreate("GetPlayerListRemote", "RemoteFunction") :: RemoteFunction
local getModerationLogRemote = getOrCreate("GetModerationLogRemote", "RemoteFunction") :: RemoteFunction
local canOpenPanelRemote = getOrCreate("CanOpenPanelRemote", "RemoteFunction") :: RemoteFunction
local getServerStateRemote = getOrCreate("GetServerStateRemote", "RemoteFunction") :: RemoteFunction

local function isStaff(player: Player): boolean
	return #PermissionSystem.GetRoles(player) > 0
end

-- The client calls this BEFORE building any UI at all (Shell, Command
-- Palette, pages) — not just before running commands. Without this, a
-- non-staff player could still see the whole panel (player list, roles,
-- moderation log, dashboard stats) even though every command they tried
-- would be denied. This is the single source of truth for "should this
-- client even construct the UI" — the client must not decide that on its
-- own.
function canOpenPanelRemote.OnServerInvoke(player: Player)
	return isStaff(player)
end

-- Read-only snapshot of toggleable server state, for Quick Action cards
-- that need to show their current status (e.g. "Lock Server: 🟢 Unlocked")
-- rather than being blind one-shot buttons.
function getServerStateRemote.OnServerInvoke(player: Player)
	if not isStaff(player) then
		return {}
	end
	return {
		Locked = ServerStateService.IsLocked(),
		MaintenanceMode = ServerStateService.IsMaintenanceMode(),
		SlowModeSeconds = ServerStateService.GetSlowMode(),
	}
end

function getCommandListRemote.OnServerInvoke(_player: Player)
	local list = {}
	for _, def in ipairs(CommandRegistry.All()) do
		table.insert(list, {
			Name = def.Name,
			Aliases = def.Aliases,
			Description = def.Description,
			Usage = def.Usage,
			Permission = def.Permission,
			Category = def.Category,
		})
	end
	return list
end

function getServerStatsRemote.OnServerInvoke(_player: Player)
	return DeveloperService.GetServerStats()
end

function getPlayerListRemote.OnServerInvoke(player: Player)
	if not isStaff(player) then
		return {}
	end
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local character = p.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		table.insert(list, {
			UserId = p.UserId,
			Name = p.Name,
			DisplayName = p.DisplayName,
			Team = if p.Team then p.Team.Name else nil,
			Health = if humanoid then math.floor(humanoid.Health) else nil,
			MaxHealth = if humanoid then math.floor(humanoid.MaxHealth) else nil,
			Ping = DeveloperService.GetPing(p),
			Roles = PermissionSystem.GetRoles(p),
		})
	end
	return list
end

function getModerationLogRemote.OnServerInvoke(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	local all = Logger.Query(nil)
	local n = count or 30
	local result = {}
	local startIndex = math.max(1, #all - n + 1)
	for i = startIndex, #all do
		table.insert(result, all[i])
	end
	return result
end

executeCommandRemote.OnServerEvent:Connect(function(player: Player, rawText: string)
	if type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 then
		return
	end
	local results = CommandProcessor.Process(player, rawText)
	commandResultRemote:FireClient(player, results)
end)

return true
