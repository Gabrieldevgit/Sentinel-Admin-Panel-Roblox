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
local getAuditLogRemote = getOrCreate("GetAuditLogRemote", "RemoteFunction") :: RemoteFunction
getOrCreate("UtilityRemote", "RemoteEvent")
getOrCreate("MovementRemote", "RemoteEvent")

-- Staff = may open the panel. A rank can exist without this (e.g. VIP perks).
local function isStaff(player: Player): boolean
	return PermissionSystem.Has(player, "panel.open")
end

-- ---------------------------------------------------------------------------
-- Security (W04): every client -> server entry point is rate limited per
-- player, and handler errors are caught so a bad request returns nil
-- instead of surfacing a server error to the client.
-- ---------------------------------------------------------------------------
local RateLimiter = require(Sentinel:WaitForChild("Core"):WaitForChild("RateLimiter"))
local CommandPolicy = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandPolicy"))

-- capacity (burst), refill per second. Heavier snapshots get tighter limits.
local LIMITS: { [string]: { number } } = {
	CanOpenPanelRemote = { 5, 1 },
	GetCommandListRemote = { 4, 1 },
	GetAuditLogRemote = { 4, 1 },
	GetRanksSnapshotRemote = { 3, 1.5 },
	GetPlayerListRemote = { 6, 2 },
}
local DEFAULT_LIMIT = { 10, 4 }

local function bindInvoke(remote: RemoteFunction, handler: (Player, ...any) -> ...any)
	local limit = LIMITS[remote.Name] or DEFAULT_LIMIT
	local limiter = RateLimiter.new(remote.Name, limit[1], limit[2])
	remote.OnServerInvoke = function(player: Player, ...)
		if not limiter:Allow(player) then
			return nil
		end
		local results = table.pack(pcall(handler, player, ...))
		if not results[1] then
			warn(("[Sentinel.UIBridge] %s failed for %s: %s"):format(remote.Name, player.Name, tostring(results[2])))
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
end

-- Input validation helpers for client-supplied values.
local function validUserId(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value % 1 == 0 and value < 2 ^ 53
end

local function clampCount(value: any, default: number, max: number): number
	if type(value) ~= "number" or value ~= value then
		return default
	end
	return math.clamp(math.floor(value), 1, max)
end

-- Only known string/number fields survive; everything else is dropped.
local function sanitizeLogFilter(filter: any): any
	if type(filter) ~= "table" then
		return nil
	end
	local clean = {}
	for _, key in ipairs({ "Player", "Command", "Moderator", "Server" }) do
		local v = filter[key]
		if type(v) == "string" and #v <= 100 then
			clean[key] = v
		end
	end
	for _, key in ipairs({ "Since", "Until" }) do
		local v = filter[key]
		if type(v) == "number" and v == v then
			clean[key] = v
		end
	end
	return if next(clean) then clean else nil
end

-- The client calls this BEFORE building any UI at all (Shell, Command
-- Palette, pages) — not just before running commands. Without this, a
-- non-staff player could still see the whole panel (player list, roles,
-- moderation log, dashboard stats) even though every command they tried
-- would be denied. This is the single source of truth for "should this
-- client even construct the UI" — the client must not decide that on its
-- own.
bindInvoke(canOpenPanelRemote, function(player: Player)
	return isStaff(player)
end)

-- Read-only snapshot of toggleable server state, for Quick Action cards
-- that need to show their current status (e.g. "Lock Server: 🟢 Unlocked")
-- rather than being blind one-shot buttons.
bindInvoke(getServerStateRemote, function(player: Player)
	if not isStaff(player) then
		return {}
	end
	return {
		Locked = ServerStateService.IsLocked(),
		MaintenanceMode = ServerStateService.IsMaintenanceMode(),
		SlowModeSeconds = ServerStateService.GetSlowMode(),
		TimeFrozen = EnvironmentService.IsTimeFrozen(),
	}
end)

bindInvoke(getCommandListRemote, function(player: Player)
	if not isStaff(player) then
		return {}
	end
	-- Permission-aware: only commands this player can actually run.
	local isOwner = table.find(PermissionSystem.GetRoles(player), "Owner") ~= nil
	local list = {}
	for _, def in ipairs(CommandRegistry.All()) do
		local public = (def :: any).Public == true
		if not public and not PermissionSystem.Has(player, def.Permission) then
			continue
		end
		if CommandPolicy.IsOwnerOnly(def) and not isOwner then
			continue
		end
		table.insert(list, {
			Risk = CommandPolicy.GetRisk(def),
			OwnerOnly = CommandPolicy.IsOwnerOnly(def),
			Name = def.Name,
			Aliases = def.Aliases,
			Description = def.Description,
			Usage = def.Usage,
			Permission = def.Permission,
			Category = def.Category,
		})
	end
	return list
end)

bindInvoke(getServerStatsRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	return DeveloperService.GetServerStats()
end)

bindInvoke(getPlayerListRemote, function(player: Player)
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
			IsGod = p:GetAttribute("SentinelGod") == true,
			IsFlying = p:GetAttribute("SentinelFlying") == true,
			IsInvisible = p:GetAttribute("SentinelInvisible") == true,
		})
	end
	return list
end)

bindInvoke(getModerationLogRemote, function(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	local all = Logger.Query(nil)
	local n = clampCount(count, 30, 200)
	local result = {}
	local startIndex = math.max(1, #all - n + 1)
	for i = startIndex, #all do
		table.insert(result, all[i])
	end
	return result
end)

bindInvoke(getAuditLogRemote, function(player: Player, filter: any)
	if not isStaff(player) then
		return { Entries = {}, Stats = { Total = 0, SuccessRate = 100, TopCommands = {} } }
	end

	local entries = Logger.Query(sanitizeLogFilter(filter))
	local total = #entries
	local successes = 0
	local commandCounts: { [string]: number } = {}

	for _, entry in ipairs(entries) do
		if entry.Result == "Success" then
			successes += 1
		end
		if entry.Command then
			commandCounts[entry.Command] = (commandCounts[entry.Command] or 0) + 1
		end
	end

	local topCommands = {}
	for cmd, count in pairs(commandCounts) do
		table.insert(topCommands, { Command = cmd, Count = count })
	end
	table.sort(topCommands, function(a, b) return a.Count > b.Count end)

	-- Most recent first, up to 150 entries
	local recentEntries = {}
	local limit = math.min(150, #entries)
	for i = #entries, math.max(1, #entries - limit + 1), -1 do
		table.insert(recentEntries, entries[i])
	end

	local successRate = if total > 0 then math.floor((successes / total) * 100) else 100

	local staffOnline = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if isStaff(p) then
			staffOnline += 1
		end
	end

	return {
		Entries = recentEntries,
		Stats = {
			Total = total,
			SuccessRate = successRate,
			TopCommands = topCommands,
			ActiveStaffCount = staffOnline,
		},
	}
end)

local EconomyService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EconomyService"))

bindInvoke(getEconomySnapshotRemote, function(player: Player, userId: number)
	if not isStaff(player) or not validUserId(userId) then
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
end)

bindInvoke(getRecentLogsRemote, function(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	return DeveloperService.GetRecentLogs(clampCount(count, 50, 200))
end)

bindInvoke(getRecentRemoteCallsRemote, function(player: Player, count: number?)
	if not isStaff(player) then
		return {}
	end
	return DeveloperService.GetRecentRemoteCalls(clampCount(count, 50, 200))
end)

-- Settings page Permissions viewer (Phase 7E): read-only, no assign/
-- revoke controls exist in the UI, so this only ever hands back data,
-- never accepts a role name to change anything.
bindInvoke(getPermissionsSnapshotRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	return {
		MyRoles = PermissionSystem.GetRoles(player),
		Roles = PermissionSystem.GetAllRoleDefinitions(),
	}
end)

-- Inventory tab (Phase 7F): reads Tool instances directly rather than
-- adding a new InventoryService function — this is a simple enumeration,
-- not business logic InventoryService owns (it only knows about give/
-- remove/duplicate/save/restore, not "list what's currently there").
bindInvoke(getPlayerInventoryRemote, function(player: Player, userId: number?)
	if not isStaff(player) or not validUserId(userId) then
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
end)

-- Moderation History tab (Phase 7F): Logger.Query's `Player` filter does
-- an EXACT match against `entry.Target`, which is a comma-joined string
-- for multi-target commands (e.g. "kick p1,p2" stores Target="p1,p2") —
-- an exact filter for "p1" would miss that entry entirely. Filtering here
-- by splitting on comma and checking membership is the correct behavior;
-- Logger.Query itself isn't changed, since other callers may rely on its
-- current (admittedly surprising) exact-match semantics.
bindInvoke(getPlayerModerationHistoryRemote, function(player: Player, userId: number?, count: number?)
	if not isStaff(player) or not validUserId(userId) then
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
		if #matches >= clampCount(count, 30, 100) then
			break
		end
	end
	return matches
end)

-- Session tab (Phase 7F): join time comes from the tiny tracker above;
-- everything else is read straight off the Player instance.
bindInvoke(getPlayerSessionRemote, function(player: Player, userId: number?)
	if not isStaff(player) or not validUserId(userId) then
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
end)

-- Notes tab (Phase 7F): read-only here — adding a note still goes through
-- ExecuteCommandRemote ("/note target text") so the "moderation.notes"
-- permission node is actually enforced, same reasoning as DataStores in
-- the Developer Tools page.
bindInvoke(getPlayerNotesRemote, function(player: Player, userId: number?)
	if not isStaff(player) or not validUserId(userId) then
		return {}
	end
	return NoteCommand.GetNotes(userId)
end)

-- ---------------------------------------------------------------------------
-- Rank Management page (W03). Read-only snapshot; every change the page
-- makes is sent as a normal command through ExecuteCommandRemote, so it
-- goes through the same permission/cooldown/logging pipeline as chat.
-- ---------------------------------------------------------------------------
local RankService = require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))
local getRanksSnapshotRemote = getOrCreate("GetRanksSnapshotRemote", "RemoteFunction") :: RemoteFunction
local getHiddenPagesRemote = getOrCreate("GetHiddenPagesRemote", "RemoteFunction") :: RemoteFunction


bindInvoke(getRanksSnapshotRemote, function(player: Player)
	if not isStaff(player) or not PermissionSystem.Has(player, "ranks.view") then
		return nil
	end

	local commands = {}
	for _, def in ipairs(CommandRegistry.All()) do
		table.insert(commands, { Name = def.Name, Permission = def.Permission, Category = def.Category })
	end
	table.sort(commands, function(a, b)
		return a.Name < b.Name
	end)

	local holders: { [string]: { string } } = {}
	local online = {}
	for _, p in ipairs(Players:GetPlayers()) do
		for _, roleName in ipairs(PermissionSystem.GetRoles(p)) do
			holders[roleName] = holders[roleName] or {}
			table.insert(holders[roleName], p.Name)
		end
		table.insert(online, { Name = p.Name, UserId = p.UserId, TopRank = RankService.GetTopRank(p) })
	end

	local ranks = RankService.GetRanks()
	for _, rank in ipairs(ranks :: { any }) do
		-- Permission preview: which commands this rank can run (with
		-- inheritance and denials applied).
		local allowed = {}
		for _, cmd in ipairs(commands) do
			if PermissionSystem.RoleHas(rank.Name, cmd.Permission) then
				table.insert(allowed, cmd.Name)
			end
		end
		rank.AllowedCommands = allowed
		rank.OnlineHolders = holders[rank.Name] or {}
	end

	local bindings = RankService.GetBindings()
	for _, b in ipairs(bindings :: { any }) do
		b.Description = RankService.DescribeBinding(b)
	end

	return {
		Ranks = ranks,
		Bindings = bindings,
		History = RankService.GetHistory(30),
		Presets = RankService.GetPresets(),
		Commands = commands,
		Online = online,
		ReadOnly = RankService.IsReadOnly(),
		Me = {
			Priority = (function()
				local priority = RankService.GetPriority(player)
				return if priority == -math.huge then nil else priority
			end)(),
			TopRank = RankService.GetTopRank(player),
			CanManage = PermissionSystem.Has(player, "ranks.manage"),
			CanAssign = PermissionSystem.Has(player, "ranks.assign"),
		},
	}
end)

-- Page visibility: a page is hidden only when the player's ranks
-- explicitly deny "page.<id>" (e.g. "!page.economy"); visible by default.
bindInvoke(getHiddenPagesRemote, function(player: Player, pageIds: any)
	if not isStaff(player) or type(pageIds) ~= "table" or #pageIds > 50 then
		return {}
	end
	local hidden = {}
	for _, id in ipairs(pageIds) do
		if type(id) == "string" and #id <= 32 and id:match("^%w+$") then
			if PermissionSystem.Evaluate(player, "page." .. id:lower()) == "deny" then
				table.insert(hidden, id)
			end
		end
	end
	return hidden
end)

local executeLimiter = RateLimiter.new("ExecuteCommandRemote", 8, 4)

-- options.Confirmed: the UI already showed its own confirmation dialog
-- (e.g. Quick Actions' typed SHUTDOWN). Confirmations are a safeguard
-- against mistakes, not a permission: Dispatch still checks everything.
executeCommandRemote.OnServerEvent:Connect(function(player: Player, rawText: any, options: any)
	if type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 then
		return
	end
	local allowed, firstDrop = executeLimiter:Allow(player)
	if not allowed then
		if firstDrop then
			commandResultRemote:FireClient(player, { { Success = false, Message = "Slow down — too many commands." } })
		end
		return
	end
	local confirmed = type(options) == "table" and options.Confirmed == true
	local results = CommandProcessor.Process(player, rawText, { Confirmed = confirmed })
	commandResultRemote:FireClient(player, results)
end)

return true
