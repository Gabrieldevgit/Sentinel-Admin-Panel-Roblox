--!strict
--[[
	UIBridge.lua

	Purpose:
		The ONLY place Sentinel's future GUI (Phase 7) talks to the server.
		Has grown alongside each Phase 7 page — every remote stays either
		deliberately open (harmless metadata) or gated behind isStaff():
		- GetCommandListRemote (RemoteFunction): read-only command metadata
		  for the command palette's autocomplete/docs (no secrets exposed —
		  just Name/Aliases/Description/Usage/Permission/Category). Open.
		- ExecuteCommandRemote (RemoteEvent, client -> server): the SAME
		  CommandProcessor.Process path the chat hook uses. The player is
		  taken from the RemoteEvent's built-in server-side parameter, never
		  trusted from client-sent data, so this carries no more risk than
		  typing the command in chat — permission checks, cooldowns, and
		  logging in CommandRegistry.Dispatch all still apply unchanged.
		- CommandResultRemote (RemoteEvent, server -> client): sends the
		  result of an executed command back to the client that ran it —
		  both from ExecuteCommandRemote AND from the chat hook now, so
		  the Notification Center (Phase 7D) gets feedback for either path.
		- GetServerStatsRemote (RemoteFunction): thin wrapper around
		  DeveloperService.GetServerStats() for the UI's status bar. Open.
		- GetPlayerListRemote (RemoteFunction): read-only snapshot of every
		  connected player (Name/DisplayName/Team/Health/Ping/Roles/
		  IsFrozen/IsJailed/IsMuted) for the Player Explorer page's table
		  and its Freeze/Jail/Mute toggle switches. Staff-gated.
		- GetModerationLogRemote (RemoteFunction): staff-gated recent
		  moderation actions for the Moderation Queue.
		- CanOpenPanelRemote (RemoteFunction): the client calls this before
		  building ANY UI at all. Returns false for non-staff, so the panel
		  is never even constructed client-side for players who can't use
		  it — not just gated at the command-execution step.
		- GetServerStateRemote (RemoteFunction): staff-gated server lock/
		  maintenance/slowmode state for the Server page.
		- GetEconomySnapshotRemote (RemoteFunction): staff-gated Coins/
		  Gems/XP/Level for one online player, keyed by UserId, for the
		  Economy page (Phase 7B).
		- GetRecentLogsRemote / GetRecentRemoteCallsRemote (RemoteFunction):
		  staff-gated wrappers around DeveloperService's LogService/remote-
		  call history, for the Developer Tools page's Console/Remotes
		  tabs (Phase 7C).
		- GetPermissionsSnapshotRemote (RemoteFunction): staff-gated, for
		  the Settings page's Permissions viewer (Phase 7E). Returns the
		  calling player's own assigned roles plus a read-only catalog of
		  every DEFINED role and its nodes — deliberately read-only; the
		  Settings page has no assign/revoke controls, since role
		  assignment isn't exposed anywhere in Sentinel's UI yet (it's
		  done via `PermissionSystem.AssignRole` calls in bootstrap code).
		- GetPlayerInventoryRemote / GetPlayerModerationHistoryRemote /
		  GetPlayerSessionRemote / GetPlayerNotesRemote (RemoteFunction):
		  staff-gated, one per remaining Player Explorer tab (Phase 7F).
		  Statistics and Permissions tabs deliberately reuse
		  GetEconomySnapshotRemote and GetPlayerListRemote's Roles field
		  (plus GetPermissionsSnapshotRemote's role catalog) instead of
		  getting their own remotes — that data already exists, so a
		  duplicate read path would just be two places to keep in sync.

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
local ChatModerationService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ChatModerationService"))
local EnvironmentService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EnvironmentService"))
local NoteCommand = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Note"))

-- Session tab (Phase 7F) needs a join time, and nothing in Sentinel
-- tracked that anywhere else. Kept as a tiny local table here rather than
-- a whole new SessionService module — this is the only consumer. Seeds
-- already-connected players at load time too, since a live Rojo sync can
-- re-run this script while players are already in a running server.
local sessionStartedAt: { [number]: number } = {}
for _, p in ipairs(Players:GetPlayers()) do
	sessionStartedAt[p.UserId] = os.time()
end
Players.PlayerAdded:Connect(function(p: Player)
	sessionStartedAt[p.UserId] = os.time()
end)
Players.PlayerRemoving:Connect(function(p: Player)
	sessionStartedAt[p.UserId] = nil
end)

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
local getEconomySnapshotRemote = getOrCreate("GetEconomySnapshotRemote", "RemoteFunction") :: RemoteFunction
local getRecentLogsRemote = getOrCreate("GetRecentLogsRemote", "RemoteFunction") :: RemoteFunction
local getRecentRemoteCallsRemote = getOrCreate("GetRecentRemoteCallsRemote", "RemoteFunction") :: RemoteFunction
local getPermissionsSnapshotRemote = getOrCreate("GetPermissionsSnapshotRemote", "RemoteFunction") :: RemoteFunction
local getPlayerInventoryRemote = getOrCreate("GetPlayerInventoryRemote", "RemoteFunction") :: RemoteFunction
local getPlayerModerationHistoryRemote = getOrCreate("GetPlayerModerationHistoryRemote", "RemoteFunction") :: RemoteFunction
local getPlayerSessionRemote = getOrCreate("GetPlayerSessionRemote", "RemoteFunction") :: RemoteFunction
local getPlayerNotesRemote = getOrCreate("GetPlayerNotesRemote", "RemoteFunction") :: RemoteFunction

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
		TimeFrozen = EnvironmentService.IsTimeFrozen(),
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
			-- Read directly via attributes rather than importing Freeze/Jail
			-- modules — those attributes ("SentinelFrozen"/"SentinelJailed")
			-- are the actual, single source of truth those commands already
			-- use, so this stays in sync automatically with no extra coupling.
			IsFrozen = p:GetAttribute("SentinelFrozen") == true,
			IsJailed = p:GetAttribute("SentinelJailed") == true,
			IsMuted = ChatModerationService.IsMuted(p.UserId),
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

local EconomyService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EconomyService"))

function getEconomySnapshotRemote.OnServerInvoke(player: Player, userId: number)
	if not isStaff(player) or type(userId) ~= "number" then
		return nil
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		return nil
	end
	return {
		Coins = EconomyService.GetBalance(target, "Coins"),
		Gems = EconomyService.GetBalance(target, "Gems"),
		XP = EconomyService.GetBalance(target, "XP"),
		Level = EconomyService.GetBalance(target, "Level"),
	}
end

function getRecentLogsRemote.OnServerInvoke(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	return DeveloperService.GetRecentLogs(count)
end

function getRecentRemoteCallsRemote.OnServerInvoke(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	return DeveloperService.GetRecentRemoteCalls(count)
end

-- Settings page Permissions viewer (Phase 7E): read-only, no assign/
-- revoke controls exist in the UI, so this only ever hands back data,
-- never accepts a role name to change anything.
function getPermissionsSnapshotRemote.OnServerInvoke(player: Player)
	if not isStaff(player) then
		return nil
	end
	return {
		MyRoles = PermissionSystem.GetRoles(player),
		Roles = PermissionSystem.GetAllRoleDefinitions(),
	}
end

-- Inventory tab (Phase 7F): reads Tool instances directly rather than
-- adding a new InventoryService function — this is a simple enumeration,
-- not business logic InventoryService owns (it only knows about give/
-- remove/duplicate/save/restore, not "list what's currently there").
function getPlayerInventoryRemote.OnServerInvoke(player: Player, userId: number?)
	if not isStaff(player) or type(userId) ~= "number" then
		return nil
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		return nil
	end
	local backpack = target:FindFirstChild("Backpack")
	local items = {}
	if backpack then
		for _, tool in ipairs(backpack:GetChildren()) do
			if tool:IsA("Tool") then
				table.insert(items, { Name = tool.Name, Equipped = false })
			end
		end
	end
	local character = target.Character
	local equippedTool = character and character:FindFirstChildOfClass("Tool")
	if equippedTool then
		table.insert(items, { Name = equippedTool.Name, Equipped = true })
	end
	return items
end

-- Moderation History tab (Phase 7F): Logger.Query's `Player` filter does
-- an EXACT match against `entry.Target`, which is a comma-joined string
-- for multi-target commands (e.g. "kick p1,p2" stores Target="p1,p2") —
-- an exact filter for "p1" would miss that entry entirely. Filtering here
-- by splitting on comma and checking membership is the correct behavior;
-- Logger.Query itself isn't changed, since other callers may rely on its
-- current (admittedly surprising) exact-match semantics.
function getPlayerModerationHistoryRemote.OnServerInvoke(player: Player, userId: number?, count: number?)
	if not isStaff(player) or type(userId) ~= "number" then
		return {}
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		return {}
	end
	local targetName = target.Name

	local all = Logger.Query(nil)
	local matches = {}
	for i = #all, 1, -1 do
		local entry = all[i]
		if entry.Target then
			for name in entry.Target:gmatch("[^,]+") do
				if name == targetName then
					table.insert(matches, entry)
					break
				end
			end
		end
		if #matches >= (count or 30) then
			break
		end
	end
	return matches
end

-- Session tab (Phase 7F): join time comes from the tiny tracker above;
-- everything else is read straight off the Player instance.
function getPlayerSessionRemote.OnServerInvoke(player: Player, userId: number?)
	if not isStaff(player) or type(userId) ~= "number" then
		return nil
	end
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		return nil
	end
	return {
		UserId = target.UserId,
		AccountAgeDays = target.AccountAge,
		JoinedAt = sessionStartedAt[target.UserId],
		Ping = DeveloperService.GetPing(target),
	}
end

-- Notes tab (Phase 7F): read-only here — adding a note still goes through
-- ExecuteCommandRemote ("/note target text") so the "moderation.notes"
-- permission node is actually enforced, same reasoning as DataStores in
-- the Developer Tools page.
function getPlayerNotesRemote.OnServerInvoke(player: Player, userId: number?)
	if not isStaff(player) or type(userId) ~= "number" then
		return {}
	end
	return NoteCommand.GetNotes(userId)
end

executeCommandRemote.OnServerEvent:Connect(function(player: Player, rawText: string)
	if type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 then
		return
	end
	local results = CommandProcessor.Process(player, rawText)
	commandResultRemote:FireClient(player, results)
end)

return true
