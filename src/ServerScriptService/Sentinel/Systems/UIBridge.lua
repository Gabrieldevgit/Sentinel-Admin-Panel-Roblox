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
local CommandHistory = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandHistory"))
local CommandLibraryService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CommandLibraryService"))
local ConfigService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ConfigService"))
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
	-- A banned staff member on the ban / appeal screen gets no panel (W14).
	return PermissionSystem.Has(player, "panel.open") and not player:GetAttribute("SentinelBanHold")
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
	SearchAuditLogRemote = { 4, 0.5 },
	GetRanksSnapshotRemote = { 3, 1.5 },
	GetAutocompleteDataRemote = { 4, 1 },
	PreviewCommandRemote = { 10, 5 },
	GetPlayerListRemote = { 6, 2 },
	GetPlayerActivityRemote = { 4, 1 },
	ResolveTargetsRemote = { 8, 3 },
	GetCommandHistoryRemote = { 6, 2 },
	GetCommandLibraryRemote = { 4, 1 },
	UpdateCommandLibraryRemote = { 6, 1 },
	GetUIPrefsRemote = { 5, 1 },
	SetUIPrefsRemote = { 8, 2 },
	GetCrossServerSnapshotRemote = { 6, 1.5 },
	GetCrossServerServerRemote = { 6, 2 },
	CrossServerFindRemote = { 4, 1 }, -- may call Roblox's user lookup
	GetModerationDashboardRemote = { 4, 1 },
	SearchCasesRemote = { 5, 1 },
	GetOfflineProfileRemote = { 4, 0.5 }, -- Roblox name lookups
	GetBanListRemote = { 3, 0.5 },
	GetAnnouncementsRemote = { 4, 1 },
	GetPollsRemote = { 4, 1 },
	GetEventsRemote = { 4, 1 },
	GetModulesRemote = { 6, 2 },
	GetAnalyticsRemote = { 3, 0.5 }, -- may read up to 2 x 90 DataStore days
	GetChatLogRemote = { 4, 1 },
	GetAlertsRemote = { 4, 1 },
	SearchReportsRemote = { 5, 1 },
	GetReportRemote = { 6, 2 },
	SearchAppealsRemote = { 5, 1 },
	GetAppealRemote = { 6, 2 },
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
		-- W22: the Server page info card + whitelist / cap / message rows.
		Info = if PermissionSystem.Has(player, "server.info") then require(script.Parent:WaitForChild("CrossServerService")).LocalInfo() else nil,
	}
end)

-- Args for the palette: copies plain fields and resolves Choices given
-- as functions (e.g. the current weather list) to plain string lists.
local function serializeArg(arg: any): any
	if type(arg) ~= "table" then
		return nil
	end
	local choices = arg.Choices
	if type(choices) == "function" then
		local ok, list = pcall(choices)
		choices = if ok and type(list) == "table" then list else nil
	end
	local suggestions = arg.Suggestions
	if type(suggestions) == "function" then
		local ok, list = pcall(suggestions)
		suggestions = if ok and type(list) == "table" then list else nil
	end
	return {
		Name = arg.Name,
		Type = arg.Type,
		Optional = arg.Optional,
		Rest = arg.Rest,
		Choices = choices,
		Suggestions = suggestions,
		Description = arg.Description,
		Min = arg.Min,
		Max = arg.Max,
		Modifier = serializeArg(arg.Modifier),
	}
end

local function serializeArgs(args: any): { any }
	local out = {}
	for _, arg in ipairs(if type(args) == "table" then args else {}) do
		table.insert(out, serializeArg(arg))
	end
	return out
end

bindInvoke(getCommandListRemote, function(player: Player)
	-- Staff, and ranks that may use the command bar (e.g. VIP). The list is
	-- permission-aware either way: only commands this player can run.
	if not isStaff(player) and not PermissionSystem.Has(player, "commandbar.use") then
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
		if (def :: any).Hidden then
			continue
		end
		local anyDef = def :: any
		table.insert(list, {
			Subcategory = anyDef.Subcategory,
			Tags = anyDef.Tags,
			Cancellable = anyDef.Cancellable == true,
			CanUndo = type(anyDef.Undo) == "function" or (CommandHistory.InverseFor(def)) ~= nil,
			Risk = CommandPolicy.GetRisk(def),
			OwnerOnly = CommandPolicy.IsOwnerOnly(def),
			Name = def.Name,
			Aliases = def.Aliases,
			Description = def.Description,
			Usage = def.Usage,
			Permission = def.Permission,
			Category = def.Category,
			RequiresTarget = def.RequiresTarget == true,
			Cooldown = def.Cooldown,
			Args = serializeArgs(def.Args),
			Examples = def.Examples,
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

-- W15: rows come from PlayerExplorerService (status, rank, suspicion,
-- join time, movement stats... on top of the original fields).
local PlayerExplorerService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PlayerExplorerService"))
bindInvoke(getPlayerListRemote, function(player: Player)
	if not isStaff(player) then
		return {}
	end
	return PlayerExplorerService.Rows()
end)

-- W15: recently joined / left players in this server.
local getPlayerActivityRemote = getOrCreate("GetPlayerActivityRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getPlayerActivityRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	return PlayerExplorerService.Recent()
end)

-- W15 "select by team / rank / attribute / property": resolves a target
-- expression with the command grammar (e.g. "@team Red", "@rank VIP",
-- "@attribute SentinelFlying", "@walkspeed >30", "all where Health<50")
-- without running anything. Returns the matching UserIds.
local ResolveCommandParser = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("CommandParser"))
local ResolveTargetResolver = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("TargetResolver"))
local resolveTargetsRemote = getOrCreate("ResolveTargetsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(resolveTargetsRemote, function(player: Player, text: any)
	if not isStaff(player) or type(text) ~= "string" or #text == 0 or #text > 200 or text:find("&&", 1, true) then
		return nil
	end
	local parsed = ResolveCommandParser.ParseLine("select " .. text)
	if not parsed or #parsed.TargetSelectors == 0 then
		return { UserIds = {}, Error = "Not a target expression." }
	end
	-- ParseLine strips "where ..." clauses; read them separately.
	local tokens = {}
	for token in text:gmatch("%S+") do
		table.insert(tokens, token)
	end
	local filters = ResolveCommandParser.ParseFilters(tokens)
	local targets = ResolveTargetResolver.Resolve(player, parsed.TargetSelectors, filters, true)
	local ids = {}
	for _, p in ipairs(targets) do
		table.insert(ids, p.UserId)
	end
	return { UserIds = ids }
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

	-- W10: read the persistent audit log (every server, every session).
	local AuditService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AuditService"))
	local n = clampCount(count, 30, 100)
	local found = AuditService.Search({ Player = targetName }, nil, n)
	local matches = {}
	for i = 1, math.min(n, #found.Entries) do
		matches[i] = found.Entries[i]
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
	-- W15: usernames seen before (W13 offline profile), cached after the
	-- first read.
	local previousNames = {}
	local okProfile, PlayerProfileService = pcall(require, Sentinel:WaitForChild("Systems"):WaitForChild("PlayerProfileService"))
	if okProfile then
		local stored = PlayerProfileService.GetStored(target.UserId)
		if stored and type(stored.Names) == "table" then
			for _, name in ipairs(stored.Names) do
				if name ~= target.Name then
					table.insert(previousNames, name)
				end
			end
		end
	end
	local row = PlayerExplorerService.Row(target)
	return {
		UserId = target.UserId,
		AccountAgeDays = target.AccountAge,
		JoinedAt = sessionStartedAt[target.UserId],
		Ping = DeveloperService.GetPing(target),
		PreviousNames = previousNames,
		Status = row.Status,
		IdleSeconds = row.IdleSeconds,
		Position = row.Position,
		WalkSpeed = row.WalkSpeed,
		JumpPower = row.JumpPower,
		Warnings = row.Warnings,
		Suspicious = row.Suspicious,
		MembershipType = target.MembershipType.Name,
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
local getAutocompleteDataRemote = getOrCreate("GetAutocompleteDataRemote", "RemoteFunction") :: RemoteFunction

-- Palette autocomplete (W05): rank names/colours. Staff only.
bindInvoke(getAutocompleteDataRemote, function(player: Player)
	if not isStaff(player) and not PermissionSystem.Has(player, "commandbar.use") then
		return nil
	end
	local ranks = {}
	for _, rank in ipairs(RankService.GetRanks()) do
		local c = (rank :: any).Color
		table.insert(ranks, {
			Name = rank.Name,
			Priority = rank.Priority,
			Color = if type(c) == "table" and #c == 3 then Color3.fromRGB(c[1], c[2], c[3]) else nil,
		})
	end
	return { Ranks = ranks }
end)

-- Palette dry run (W06): who a command would affect, whether rank
-- protection skips anyone, and whether it will ask for confirmation.
-- Nothing executes.
local previewCommandRemote = getOrCreate("PreviewCommandRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(previewCommandRemote, function(player: Player, rawText: any)
	if not isStaff(player) or type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 then
		return nil
	end
	return CommandProcessor.Preview(player, (rawText:gsub("^%s*;", "")))
end)


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
	if type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 or player:GetAttribute("SentinelBanHold") then
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
	-- The panel may send a typed prefix; strip one leading prefix char.
	rawText = rawText:gsub("^%s+", "")
	if ConfigService.MatchPrefix(rawText) then
		rawText = rawText:sub(2)
	end
	local source = if type(options) == "table" and options.Source == "keybind" then "keybind" else "panel"
	local results = CommandProcessor.Process(player, rawText, { Confirmed = confirmed, Source = source })
	if isStaff(player) and results[1] and not (results[1].Message or ""):find("^Unknown command") then
		CommandLibraryService.NoteRecent(player, rawText)
	end
	commandResultRemote:FireClient(player, results)
end)

-- ---------------------------------------------------------------------------
-- Command framework (W07): result history, undo/redo counts, running
-- operations, and the personal command library (favorites, presets,
-- templates, recent). Library writes are validated by the service.
-- ---------------------------------------------------------------------------
local getCommandHistoryRemote = getOrCreate("GetCommandHistoryRemote", "RemoteFunction") :: RemoteFunction
local getCommandLibraryRemote = getOrCreate("GetCommandLibraryRemote", "RemoteFunction") :: RemoteFunction
local updateCommandLibraryRemote = getOrCreate("UpdateCommandLibraryRemote", "RemoteFunction") :: RemoteFunction

bindInvoke(getCommandHistoryRemote, function(player: Player, options: any)
	if not isStaff(player) then
		return nil
	end
	local clean: any = {}
	if type(options) == "table" then
		if type(options.Search) == "string" and #options.Search <= 60 then
			clean.Search = options.Search
		end
		clean.Limit = clampCount(options.Limit, 50, 200)
		clean.FailedOnly = options.FailedOnly == true
	end
	local undo, redo = CommandHistory.Counts(player)
	local top = CommandHistory.PeekUndo(player)
	local nextRedo = CommandHistory.PeekRedo(player)
	return {
		Entries = CommandHistory.Get(player, clean),
		UndoCount = undo,
		RedoCount = redo,
		NextUndo = top and top.Input,
		NextRedo = nextRedo and nextRedo.Input,
		Running = CommandRegistry.ListRunning(player),
	}
end)

bindInvoke(getCommandLibraryRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	local lib = CommandLibraryService.Get(player)
	lib.Prefixes = ConfigService.GetPrefixes()
	return lib
end)

bindInvoke(updateCommandLibraryRemote, function(player: Player, action: any, payload: any)
	if not isStaff(player) or type(action) ~= "string" or #action > 20 then
		return { Success = false, Message = "Not allowed." }
	end
	local ok, message = CommandLibraryService.Apply(player, action, payload)
	return { Success = ok, Message = message }
end)

-- ---------------------------------------------------------------------------
-- Cross-Server page (W18). Read-only: every action the page takes is a
-- normal command through ExecuteCommandRemote. Live updates (operations,
-- staff chat, notifications) are pushed on CrossServerEventRemote by
-- CrossServerService.
-- ---------------------------------------------------------------------------
local CrossServerService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CrossServerService"))
local BanCommand = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Ban"))
local getCrossServerSnapshotRemote = getOrCreate("GetCrossServerSnapshotRemote", "RemoteFunction") :: RemoteFunction
local getCrossServerServerRemote = getOrCreate("GetCrossServerServerRemote", "RemoteFunction") :: RemoteFunction
local crossServerFindRemote = getOrCreate("CrossServerFindRemote", "RemoteFunction") :: RemoteFunction

local function canViewCrossServer(player: Player): boolean
	return isStaff(player) and PermissionSystem.Has(player, "crossserver.view")
end

local CROSS_SERVER_NODES = { "join", "bring", "kick", "warn", "ban", "announce", "lockdown", "shutdown", "migrate", "staffchat", "execute" }

-- A registry record without its player list (that is fetched per server).
local function publicServer(record: any): any
	return {
		Id = record.Id,
		Short = CrossServerService.ShortId(record.Id),
		IsThis = record.Id == CrossServerService.ServerId,
		Place = record.Place,
		Version = record.Ver,
		Players = record.N,
		MaxPlayers = record.Max,
		StartedAt = record.Start,
		Heartbeat = record.HB,
		Fps = record.Fps,
		Ping = record.Ping,
		MemoryMb = record.Mem,
		Staff = record.Staff,
		Locked = record.Locked == true,
		Maintenance = record.Maint == true,
		Private = record.Priv == true,
		Studio = record.Studio == true,
		Health = record.Health,
	}
end

bindInvoke(getCrossServerSnapshotRemote, function(player: Player, options: any)
	if not canViewCrossServer(player) then
		return nil
	end
	local want = if type(options) == "table" then options else {}
	local servers, totals = CrossServerService.ListServers(want.Refresh == true)
	local list = {}
	for i, record in ipairs(servers) do
		if i > 200 then
			break
		end
		table.insert(list, publicServer(record))
	end
	local can = {}
	for _, node in ipairs(CROSS_SERVER_NODES) do
		can[node] = PermissionSystem.Has(player, "crossserver." .. node)
	end
	local snapshot: any = {
		ServerId = CrossServerService.ServerId,
		Now = os.time(),
		Servers = list,
		Totals = totals,
		Stats = CrossServerService.GetStats(),
		GlobalState = CrossServerService.GetGlobalState(),
		Can = can,
		Operations = CrossServerService.GetOperations(40),
	}
	if want.Chat == true and can.staffchat then
		snapshot.Chat = CrossServerService.GetStaffChat()
	end
	if want.History == true then
		snapshot.History = CrossServerService.GetHistory(want.Refresh == true)
	end
	return snapshot
end)

bindInvoke(getCrossServerServerRemote, function(player: Player, serverId: any)
	if not canViewCrossServer(player) or type(serverId) ~= "string" or #serverId > 64 then
		return nil
	end
	local record = CrossServerService.GetServer(serverId)
	if not record then
		return nil
	end
	local info = publicServer(record)
	info.PlayerList = {}
	for i, entry in ipairs(if type(record.P) == "table" then record.P else {}) do
		if i > 150 then
			break
		end
		table.insert(info.PlayerList, { UserId = entry[1], Name = entry[2] })
	end
	return info
end)

-- Find a player in any server; an exact username / UserId that is nowhere
-- online is looked up through Roblox and reported with its ban status.
bindInvoke(crossServerFindRemote, function(player: Player, query: any)
	if not canViewCrossServer(player) or type(query) ~= "string" then
		return nil
	end
	query = query:gsub("^%s+", ""):gsub("%s+$", "")
	if #query < 2 or #query > 40 then
		return { Online = {}, Message = "Type at least 2 characters." }
	end
	local online = {}
	for _, match in ipairs(CrossServerService.FindPlayers(query, 25)) do
		table.insert(online, {
			UserId = match.UserId,
			Name = match.Name,
			ServerId = match.ServerId,
			Short = CrossServerService.ShortId(match.ServerId),
			IsThis = match.ServerId == CrossServerService.ServerId,
			Private = match.Priv,
		})
	end
	local result: any = { Online = online }
	local exact = false
	for _, match in ipairs(online) do
		if match.Name:lower() == query:lower() or tostring(match.UserId) == query then
			exact = true
		end
	end
	if not exact then
		local userId = tonumber(query)
		local name: string? = nil
		if userId and validUserId(userId) then
			local ok, found = pcall(Players.GetNameFromUserIdAsync, Players, userId)
			name = if ok and type(found) == "string" then found else nil
		elseif not userId and query:match("^[%w_]+$") and #query <= 20 then
			local ok, found = pcall(Players.GetUserIdFromNameAsync, Players, query)
			userId = if ok and type(found) == "number" then found else nil
			name = query
		else
			userId = nil
		end
		if userId and name then
			local ban = BanCommand.GetActiveBan(userId)
			result.Offline = {
				UserId = userId,
				Name = name,
				Banned = ban ~= nil,
				BanReason = if ban then ban.Reason else nil,
				BanPermanent = if ban then ban.ExpiresAt == math.huge else nil,
				BanExpiresAt = if ban and ban.ExpiresAt ~= math.huge then ban.ExpiresAt else nil,
			}
		end
	end
	return result
end)

-- ---------------------------------------------------------------------------
-- UI preferences (redesign): panel theme and command bar look. Personal
-- settings for anyone who may use the panel or the command bar; the server
-- default needs the "config.ui" node (Owner). Values are validated by
-- PrefsService (Shared/UIPrefs.Sanitize).
-- ---------------------------------------------------------------------------
local PrefsService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PrefsService"))
local getUIPrefsRemote = getOrCreate("GetUIPrefsRemote", "RemoteFunction") :: RemoteFunction
local setUIPrefsRemote = getOrCreate("SetUIPrefsRemote", "RemoteFunction") :: RemoteFunction

bindInvoke(getUIPrefsRemote, function(player: Player)
	local canBar = PrefsService.CanUseCommandBar(player)
	if not canBar then
		return { CanCommandBar = false, CanPanel = false }
	end
	local snapshot = PrefsService.Snapshot(player)
	snapshot.CanCommandBar = true
	snapshot.CanPanel = isStaff(player)
	snapshot.CanSetDefaults = PermissionSystem.Has(player, "config.ui")
	snapshot.Prefixes = ConfigService.GetPrefixes()
	return snapshot
end)

bindInvoke(setUIPrefsRemote, function(player: Player, scope: any, prefs: any)
	if not PrefsService.CanUseCommandBar(player) or type(scope) ~= "string" then
		return { Success = false, Message = "Not allowed." }
	end
	local ok, message
	if scope == "personal" then
		ok, message = PrefsService.SetPersonal(player, prefs)
	elseif scope == "reset" then
		-- prefs may name one section ("Keys") to reset only that one.
		local section = if type(prefs) == "string" and table.find({ "Panel", "CommandBar", "Keys", "Notifications", "Layout" }, prefs) then prefs else nil
		ok, message = PrefsService.ResetPersonal(player, section)
	elseif scope == "default" or scope == "resetdefault" then
		if not PermissionSystem.Has(player, "config.ui") then
			return { Success = false, Message = "Only ranks with config.ui (Owner) can change the server default." }
		end
		if scope == "default" then
			ok, message = PrefsService.SetDefaults(prefs, player)
		else
			ok, message = PrefsService.ResetDefaults(nil, player)
		end
		Logger.Write({
			Executor = tostring(player.UserId),
			ExecutorName = player.Name,
			Command = "config.ui",
			Result = if ok then "Success" else "Failure",
			Severity = "Info",
			Message = message,
		})
	else
		return { Success = false, Message = "Unknown request." }
	end
	return { Success = ok, Message = message }
end)

-- ---------------------------------------------------------------------------
-- Administration configuration (W08). Read here; every change is a normal
-- ;config command sent through ExecuteCommandRemote (config.edit, logged).
-- ---------------------------------------------------------------------------
local AdminConfig = require(Sentinel:WaitForChild("Systems"):WaitForChild("AdminConfig"))
local getAdminConfigRemote = getOrCreate("GetAdminConfigRemote", "RemoteFunction") :: RemoteFunction

bindInvoke(getAdminConfigRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	return {
		Entries = AdminConfig.Entries(),
		CanEdit = PermissionSystem.Has(player, "config.edit"),
		CanSetUIDefaults = PermissionSystem.Has(player, "config.ui"),
	}
end)

-- ---------------------------------------------------------------------------
-- Persistent audit log (W10 / W11). `query` is either the ;logs query text
-- ("mod:Alice cmd:ban since:7d") or a filter table; `cursor` comes from the
-- previous answer to load older entries.
-- ---------------------------------------------------------------------------
local AuditService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AuditService"))
local searchAuditLogRemote = getOrCreate("SearchAuditLogRemote", "RemoteFunction") :: RemoteFunction

bindInvoke(searchAuditLogRemote, function(player: Player, query: any, cursor: any, limit: any)
	if not isStaff(player) or PermissionSystem.Evaluate(player, "logs.view") == "deny" then
		return { Entries = {}, Error = "You can't view the audit log." }
	end
	local filter
	if type(query) == "string" then
		local err
		filter, err = AuditService.ParseQuery(query:sub(1, 300))
		if not filter then
			return { Entries = {}, Error = err }
		end
	else
		filter = AuditService.SanitizeFilter(query)
	end
	local found = AuditService.Search(filter, cursor, clampCount(limit, 50, 100))
	found.Status = AuditService.GetStatus()
	found.Filter = filter
	return found
end)

-- ---------------------------------------------------------------------------
-- Moderation center (W12). Reads only; every change (case notes, status,
-- assignment, punishments, reason templates) is a normal command.
-- ---------------------------------------------------------------------------
local CaseService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CaseService"))
local ReportService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ReportService"))
local AppealService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AppealService"))
local getModerationDashboardRemote = getOrCreate("GetModerationDashboardRemote", "RemoteFunction") :: RemoteFunction
local searchCasesRemote = getOrCreate("SearchCasesRemote", "RemoteFunction") :: RemoteFunction
local getCaseRemote = getOrCreate("GetCaseRemote", "RemoteFunction") :: RemoteFunction

local function canViewCases(player: Player): boolean
	return isStaff(player) and PermissionSystem.Has(player, "moderation.cases")
end

bindInvoke(getModerationDashboardRemote, function(player: Player)
	if not canViewCases(player) then
		return { Error = "You need moderation.cases to see the moderation center." }
	end
	local data = CaseService.Dashboard()
	data.CanEditReasons = PermissionSystem.Has(player, "config.edit")
	-- W14: queue sizes for the dashboard cards.
	data.PendingReports = if PermissionSystem.Has(player, "moderation.reports") then ReportService.PendingCount() else nil
	data.PendingAppeals = if PermissionSystem.Has(player, "moderation.appeals") then AppealService.PendingCount() else nil
	return data
end)

bindInvoke(searchCasesRemote, function(player: Player, query: any, cursor: any, limit: any)
	if not canViewCases(player) then
		return { Cases = {}, Total = 0, Error = "You need moderation.cases." }
	end
	local filter
	if type(query) == "string" then
		local err
		filter, err = CaseService.ParseQuery(query:sub(1, 200))
		if not filter then
			return { Cases = {}, Total = 0, Error = err }
		end
	else
		filter = CaseService.SanitizeFilter(query)
	end
	local found = CaseService.Search(filter, if type(cursor) == "number" then cursor else nil, clampCount(limit, 40, 100))
	found.Filter = filter
	return found
end)

bindInvoke(getCaseRemote, function(player: Player, id: any)
	if not canViewCases(player) or type(id) ~= "number" then
		return nil
	end
	return CaseService.Get(id)
end)

-- ---------------------------------------------------------------------------
-- Reports & appeals (W14). Reads only; every change is a normal command
-- (;reportclaim, ;reportresolve, ;appealaccept, ...). ModerationQueueEvent
-- pushes (kind "report" | "appeal", what, summary) to staff who may see it.
-- ---------------------------------------------------------------------------
local searchReportsRemote = getOrCreate("SearchReportsRemote", "RemoteFunction") :: RemoteFunction
local getReportRemote = getOrCreate("GetReportRemote", "RemoteFunction") :: RemoteFunction
local searchAppealsRemote = getOrCreate("SearchAppealsRemote", "RemoteFunction") :: RemoteFunction
local getAppealRemote = getOrCreate("GetAppealRemote", "RemoteFunction") :: RemoteFunction
local moderationQueueEvent = getOrCreate("ModerationQueueEvent", "RemoteEvent") :: RemoteEvent

local function canReports(player: Player): boolean
	return isStaff(player) and PermissionSystem.Has(player, "moderation.reports")
end
local function canAppeals(player: Player): boolean
	return isStaff(player) and PermissionSystem.Has(player, "moderation.appeals")
end

bindInvoke(searchReportsRemote, function(player: Player, query: any, cursor: any, limit: any)
	if not canReports(player) then
		return { Reports = {}, Total = 0, Error = "You need moderation.reports." }
	end
	local filter = if type(query) == "string"
		then ReportService.ParseQuery(query:sub(1, 200), player.Name)
		else ReportService.SanitizeFilter(query)
	local found = ReportService.Search(filter, if type(cursor) == "number" then cursor else nil, clampCount(limit, 40, 100))
	found.Filter = filter
	return found
end)

bindInvoke(getReportRemote, function(player: Player, id: any)
	if not canReports(player) or type(id) ~= "number" then
		return nil
	end
	local r = ReportService.Get(id)
	if not r then
		return nil
	end
	local out = table.clone(r)
	out.TargetOnline = Players:GetPlayerByUserId(r.TargetId) ~= nil
	out.Case = if r.CaseId then CaseService.Get(r.CaseId) else nil
	-- Earlier reports about the same player, for context.
	local others = ReportService.Search({ Status = "all", Target = tostring(r.TargetId) }, nil, 10)
	out.OtherReports = {}
	for _, o in ipairs(others.Reports) do
		if o.Id ~= r.Id then
			table.insert(out.OtherReports, o)
		end
	end
	return out
end)

bindInvoke(searchAppealsRemote, function(player: Player, query: any, cursor: any, limit: any)
	if not canAppeals(player) then
		return { Appeals = {}, Total = 0, Error = "You need moderation.appeals." }
	end
	local filter = if type(query) == "string"
		then AppealService.ParseQuery(query:sub(1, 200), player.Name)
		else AppealService.SanitizeFilter(query)
	local found = AppealService.Search(filter, if type(cursor) == "number" then cursor else nil, clampCount(limit, 40, 100))
	found.Filter = filter
	return found
end)

bindInvoke(getAppealRemote, function(player: Player, id: any)
	if not canAppeals(player) or type(id) ~= "number" then
		return nil
	end
	local a = AppealService.Get(id)
	if not a then
		return nil
	end
	local out = table.clone(a)
	out.Case = if a.CaseId then CaseService.Get(a.CaseId) else nil
	local canDecide, why = AppealService.CanDecide(player, a)
	out.CanDecide = canDecide
	out.CannotDecideWhy = why
	-- The player's other cases, for context.
	local cases = CaseService.Search({ Player = tostring(a.UserId) } :: any, nil, 10)
	out.PlayerCases = cases.Cases
	return out
end)

local function pushQueue(kind: string, what: string, item: any)
	local node = if kind == "report" then "moderation.reports" else "moderation.appeals"
	for _, p in ipairs(Players:GetPlayers()) do
		if isStaff(p) and PermissionSystem.Has(p, node) then
			moderationQueueEvent:FireClient(p, kind, what, item)
		end
	end
end
ReportService.OnChanged(function(r, what)
	pushQueue("report", what, r)
end)
AppealService.OnChanged(function(a, what)
	pushQueue("appeal", what, a)
end)

-- ---------------------------------------------------------------------------
-- Join welcome (Roblox-style redesign): every player who can run at least
-- one command gets an "Info" notification with their ranks. The client asks
-- once it has loaded (a pushed event could arrive before it listens).
-- Returns nil for players without any command permission.
-- ---------------------------------------------------------------------------
local getWelcomeRemote = getOrCreate("GetWelcomeRemote", "RemoteFunction") :: RemoteFunction
LIMITS.GetWelcomeRemote = { 3, 0.5 }

local function commandCount(player: Player): number
	local count = 0
	for _, def in ipairs(CommandRegistry.All()) do
		local d = def :: any
		if not d.Public and not d.Hidden and PermissionSystem.Has(player, def.Permission) then
			count += 1
		end
	end
	return count
end

bindInvoke(getWelcomeRemote, function(player: Player)
	local count = commandCount(player)
	if count == 0 then
		return nil
	end
	local roles = {}
	for _, roleName in ipairs(PermissionSystem.GetRoles(player)) do
		local rank = RankService.GetRank(roleName)
		if rank then
			local c = rank.Color or { 200, 200, 200 }
			table.insert(roles, {
				Name = rank.Name,
				Priority = rank.Priority,
				Color = Color3.fromRGB(c[1] or 200, c[2] or 200, c[3] or 200),
			})
		end
	end
	table.sort(roles, function(a, b)
		return a.Priority > b.Priority
	end)
	-- Permissions that come from the default nodes only (no rank).
	if #roles == 0 then
		table.insert(roles, { Name = "Player", Priority = 0, Color = Color3.fromRGB(150, 150, 160) })
	end
	return {
		Roles = roles,
		Commands = count,
		CanPanel = isStaff(player),
		CanCommandBar = PrefsService.CanUseCommandBar(player),
		Prefixes = ConfigService.GetPrefixes(),
	}
end)

-- ---------------------------------------------------------------------------
-- Offline management (W13): profiles of any Roblox user + the ban list.
-- ---------------------------------------------------------------------------
local PlayerProfileService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PlayerProfileService"))
local getOfflineProfileRemote = getOrCreate("GetOfflineProfileRemote", "RemoteFunction") :: RemoteFunction
local getBanListRemote = getOrCreate("GetBanListRemote", "RemoteFunction") :: RemoteFunction

bindInvoke(getOfflineProfileRemote, function(player: Player, query: any)
	if not isStaff(player) then
		return nil
	end
	if type(query) ~= "string" and type(query) ~= "number" then
		return { Error = "Give a username or UserId." }
	end
	local profile, err = PlayerProfileService.Profile(tostring(query):sub(1, 40), player)
	if not profile then
		return { Error = err }
	end
	profile.CanBan = PermissionSystem.Has(player, "moderation.ban")
	return profile
end)

bindInvoke(getBanListRemote, function(player: Player)
	if not isStaff(player) or not PermissionSystem.Has(player, "moderation.ban") then
		return { Bans = {}, Error = "You need moderation.ban to see the ban list." }
	end
	local BanCommand = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("Ban")) :: any
	local list, err = BanCommand.ListBans(false)
	return { Bans = list, Error = err }
end)

-- ---------------------------------------------------------------------------
-- Announcements section: history + who can be targeted + what you may send.
-- ---------------------------------------------------------------------------
-- W23: active polls (as this staff member sees them) + recent results.
local getPollsRemote = getOrCreate("GetPollsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getPollsRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	local PollService = require(script.Parent:WaitForChild("PollService")) :: any
	local snapshot = PollService.Snapshot(player)
	snapshot.CanServer = PermissionSystem.Has(player, "server.poll")
	snapshot.CanGlobal = PermissionSystem.Has(player, "crossserver.poll")
	return snapshot
end)

-- W24: running / scheduled events, presets, multipliers, history.
local getEventsRemote = getOrCreate("GetEventsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getEventsRemote, function(player: Player)
	if not isStaff(player) then
		return nil
	end
	local EventService = require(script.Parent:WaitForChild("EventService")) :: any
	local snapshot = EventService.Snapshot()
	snapshot.CanServer = PermissionSystem.Has(player, "server.event")
	snapshot.CanGlobal = PermissionSystem.Has(player, "crossserver.event")
	return snapshot
end)

-- W16: analytics report (persisted metrics + graphs). Options are
-- whitelisted here; AnalyticsService validates the range itself.
local getAnalyticsRemote = getOrCreate("GetAnalyticsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getAnalyticsRemote, function(player: Player, options: any)
	if not isStaff(player) or not PermissionSystem.Has(player, "analytics.view") then
		return { Error = "You need analytics.view to see analytics." }
	end
	options = if type(options) == "table" then options else {}
	local function str(v: any, max: number): string?
		return if type(v) == "string" and #v <= max then v else nil
	end
	local AnalyticsService = require(script.Parent:WaitForChild("AnalyticsService")) :: any
	local report, err = AnalyticsService.Query({
		Range = str(options.Range, 12) or "24h",
		From = str(options.From, 10),
		To = str(options.To, 10),
		Scope = if options.Scope == "server" then "server" else "all",
		Compare = options.Compare == true,
	})
	if not report then
		return { Error = err }
	end
	report.Live = AnalyticsService.Live()
	return report
end)

-- W-FINAL.1: Module Manager. (nil) -> { Modules = summaries, Activity,
-- Can = {...} }; (id) -> one module's detail (schema, config, runtime log,
-- diagnostics when the caller has modules.diagnostics).
local getModulesRemote = getOrCreate("GetModulesRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getModulesRemote, function(player: Player, id: any)
	if not isStaff(player) or not PermissionSystem.Has(player, "modules.view") then
		return nil
	end
	local ModuleService = require(script.Parent:WaitForChild("ModuleService")) :: any
	local ConfigService = require(script.Parent:WaitForChild("ConfigService")) :: any
	local can = {
		Activate = PermissionSystem.Has(player, "modules.activate"),
		Disable = PermissionSystem.Has(player, "modules.disable"),
		Configure = PermissionSystem.Has(player, "modules.configure"),
		Diagnostics = PermissionSystem.Has(player, "modules.diagnostics"),
	}
	if type(id) == "string" and #id <= 40 then
		local detail = ModuleService.Get(id)
		if detail and not can.Diagnostics then
			detail.Diagnostics = nil
		end
		return { Module = detail, Can = can }
	end
	return { Modules = ModuleService.List(), Activity = ConfigService.Get("ModuleActivity") or {}, Can = can }
end)

local getAnnouncementsRemote = getOrCreate("GetAnnouncementsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getAnnouncementsRemote, function(player: Player, limit: any)
	if not isStaff(player) then
		return nil
	end
	local AnnouncementService = require(script.Parent:WaitForChild("AnnouncementService")) :: any
	local players = {}
	for _, p in ipairs(Players:GetPlayers()) do
		table.insert(players, { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName, Staff = isStaff(p) })
	end
	table.sort(players, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return {
		History = AnnouncementService.History(clampCount(limit, 50, 100)),
		Players = players,
		CanServer = PermissionSystem.Has(player, "server.announce"),
		CanGlobal = PermissionSystem.Has(player, "crossserver.announce"),
		Colors = AnnouncementService.COLORS,
		Server = Logger.GetServerId(),
		Templates = AnnouncementService.GetTemplates(),
		CanEditTemplates = PermissionSystem.Has(player, "server.announce"),
	}
end)

-- M-panel gaps: server chat log (query = ";chatlog" syntax) and alerts feed.
local getChatLogRemote = getOrCreate("GetChatLogRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getChatLogRemote, function(player: Player, query: any, limit: any)
	if not isStaff(player) then
		return nil
	end
	local ChatLogService = require(script.Parent:WaitForChild("ChatLogService")) :: any
	local filter = ChatLogService.ParseQuery(if type(query) == "string" then query:sub(1, 100) else "")
	return {
		Lines = ChatLogService.Search(filter, clampCount(limit, 150, 300)),
		Total = ChatLogService.Count(),
		CanClear = PermissionSystem.Has(player, "moderation.chatlog"),
	}
end)

local getAlertsRemote = getOrCreate("GetAlertsRemote", "RemoteFunction") :: RemoteFunction
bindInvoke(getAlertsRemote, function(player: Player, limit: any)
	if not isStaff(player) then
		return nil
	end
	local AlertService = require(script.Parent:WaitForChild("AlertService")) :: any
	return {
		Alerts = AlertService.List(clampCount(limit, 100, 200)),
		CanClear = PermissionSystem.Has(player, "moderation.alerts"),
	}
end)

return true
