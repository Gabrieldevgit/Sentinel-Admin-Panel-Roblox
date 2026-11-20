--!strict
--[[
	RankService.lua

	Purpose:
		Server-authoritative rank management. Owns rank definitions and rank
		assignments ("bindings"), persists them in the Sentinel_Ranks_v1
		DataStore, and keeps PermissionSystem in sync. This replaces the
		hard-coded roles that used to live in init.server.lua.

	Responsibilities:
		- Rank CRUD: create, edit, delete, duplicate, rename; description,
		  icon, color, priority, inheritance, permission nodes
		- Default rank templates (Owner, Developer, SuperAdmin, Admin,
		  Moderator, VIP) and reset-to-defaults
		- Bindings (how a player gets a rank): UserId, Username (resolved to
		  a UserId), Group, GroupRole, GamePass, Asset, Creator,
		  PrivateServerOwner; optional expiry for temporary assignments
		- Hierarchy rules: an actor may only touch ranks below their own
		  priority (the root/Owner may touch everything except the protected
		  Owner rank and creator binding); no self-demotion
		- Change history (persisted, last HISTORY_LIMIT entries) + Logger
		- Cross-server refresh via MessagingService
		- If the saved data cannot be loaded, run on defaults in read-only
		  mode so a DataStore outage can never overwrite real rank data

	Public API (actor = the Player making the change; every mutator returns
	(ok: boolean, message: string)):
		RankService.GetRanks(): {RankSnapshot}          -- sorted by priority desc
		RankService.GetRank(name): RankSnapshot?
		RankService.ResolveRankName(name): string?      -- case-insensitive
		RankService.GetBindings(rankName?): {Binding}
		RankService.GetHistory(count?): {HistoryEntry}  -- newest first
		RankService.GetPriority(player): number
		RankService.GetTopRank(player): string?
		RankService.IsReadOnly(): boolean
		RankService.CreateRank(actor, name, priority, inherits?)
		RankService.DeleteRank(actor, name)
		RankService.RenameRank(actor, oldName, newName)
		RankService.DuplicateRank(actor, sourceName, newName)
		RankService.EditRank(actor, name, field, value) -- priority|color|icon|description|inherits
		RankService.SetNode(actor, name, node, add)
		RankService.AddBinding(actor, kind, value, rankName, durationSeconds?, extra?)
		RankService.RemoveBinding(actor, bindingId)
		RankService.ResetToDefaults(actor)
		RankService.Refresh(player)
--]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")

local Core = script.Parent.Parent:WaitForChild("Core")
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))

local RankService = {}

local STORE_NAME = "Sentinel_Ranks_v1"
local STORE_KEY = "Config"
local MESSAGE_TOPIC = "Sentinel_RanksChanged"
local HISTORY_LIMIT = 200
local SCHEMA_VERSION = 1
local ROOT_RANK = "Owner"

export type RankDef = {
	Priority: number,
	Color: { number },
	Icon: string,
	Description: string,
	Nodes: { string },
	Inherits: { string },
	Protected: boolean?,
}

export type Binding = {
	Id: string,
	Kind: string, -- UserId | Group | GroupRole | GamePass | Asset | Creator | PrivateServerOwner
	Value: number?, -- UserId / GroupId / GamePassId / AssetId
	MinRank: number?, -- GroupRole: minimum group rank (1-255)
	Label: string?, -- e.g. the username a UserId binding was created from
	Rank: string,
	ExpiresAt: number?, -- unix time; nil = permanent
	AddedBy: number?,
	AddedAt: number,
	Protected: boolean?,
}

export type HistoryEntry = {
	Time: number,
	ActorId: number,
	ActorName: string,
	Action: string,
	Detail: string,
}

type State = {
	Version: number,
	Ranks: { [string]: RankDef },
	Bindings: { Binding },
	History: { HistoryEntry },
}

local BINDING_KINDS: { [string]: string } = {
	userid = "UserId",
	group = "Group",
	grouprole = "GroupRole",
	gamepass = "GamePass",
	asset = "Asset",
	creator = "Creator",
	privateserverowner = "PrivateServerOwner",
	privateserver = "PrivateServerOwner",
}

-- ---------------------------------------------------------------------------
-- Default templates
-- ---------------------------------------------------------------------------
local MODERATOR_NODES = {
	"panel.open",
	"moderation.kick",
	"moderation.mute",
	"moderation.warn",
	"moderation.notes",
	"moderation.cases",
	"player.freeze",
	"player.jail",
	"player.goto",
	"player.bring",
	"player.teleport",
	"player.heal",
	"player.sit",
	"utility.view",
	"utility.pm",
	"server.hint",
	-- Cross-server: see the server list, find players, talk to other staff.
	"crossserver.view",
	"crossserver.staffchat",
}

local ADMIN_NODES = {
	"moderation.*",
	"player.*",
	"movement.*",
	"utility.*",
	"economy.*",
	"inventory.*",
	"server.*",
	"environment.*",
	"ranks.view",
	-- Only read-only developer nodes; datastore writes and module execution
	-- stay with Owner (and Developer for datastore writes).
	"developer.stats",
	"developer.console",
	"developer.remotemonitor",
	"developer.datastore.read",
	-- Cross-server moderation. Lockdown, shutdown, migration and ;global
	-- stay with SuperAdmin and above.
	"crossserver.join",
	"crossserver.bring",
	"crossserver.kick",
	"crossserver.warn",
	"crossserver.ban",
	"crossserver.announce",
}

local function defaultState(): State
	return {
		Version = SCHEMA_VERSION,
		Ranks = {
			Owner = {
				Priority = 100,
				Color = { 255, 215, 0 },
				Icon = "👑",
				Description = "Full access to every command and setting.",
				Nodes = { "*" },
				Inherits = {},
				Protected = true,
			},
			Developer = {
				Priority = 80,
				Color = { 255, 100, 255 },
				Icon = "🛠",
				Description = "Developer tools, DataStore access and everything SuperAdmin has.",
				Nodes = { "developer.stats", "developer.console", "developer.remotemonitor", "developer.datastore.*" },
				Inherits = { "SuperAdmin" },
			},
			SuperAdmin = {
				Priority = 70,
				Color = { 255, 50, 50 },
				Icon = "⚡",
				Description = "Everything Admin has, plus managing lower ranks.",
				Nodes = { "ranks.*", "crossserver.*" },
				Inherits = { "Admin" },
			},
			Admin = {
				Priority = 50,
				Color = { 255, 165, 0 },
				Icon = "🛡",
				Description = "Full moderation, player, economy and server commands.",
				Nodes = table.clone(ADMIN_NODES),
				Inherits = { "Moderator" },
			},
			Moderator = {
				Priority = 30,
				Color = { 100, 149, 237 },
				Icon = "🔨",
				Description = "Basic moderation tools.",
				Nodes = table.clone(MODERATOR_NODES),
				Inherits = {},
			},
			VIP = {
				Priority = 10,
				Color = { 0, 255, 127 },
				Icon = "⭐",
				Description = "VIP perks (fly, noclip). Cannot open the panel.",
				Nodes = { "player.fly", "player.noclip", "commandbar.use" },
				Inherits = {},
			},
		},
		Bindings = {
			{ Id = "creator", Kind = "Creator", Rank = "Owner", AddedAt = os.time(), Protected = true },
			{ Id = "privateserver", Kind = "PrivateServerOwner", Rank = "VIP", AddedAt = os.time() },
		},
		History = {},
	}
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local store = DataStoreService:GetDataStore(STORE_NAME)
local state: State = defaultState()
local readOnly = false
local definedRoles: { [string]: boolean } = {}
local managed: { [number]: { [string]: boolean } } = {} -- ranks RankService assigned, per UserId

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value :: any) do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

local function sanitize(loaded: any): State?
	if type(loaded) ~= "table" or type(loaded.Ranks) ~= "table" or type(loaded.Bindings) ~= "table" then
		return nil
	end
	loaded.History = if type(loaded.History) == "table" then loaded.History else {}
	loaded.Version = loaded.Version or SCHEMA_VERSION
	for _, def in pairs(loaded.Ranks) do
		def.Nodes = def.Nodes or {}
		def.Inherits = def.Inherits or {}
		def.Color = def.Color or { 200, 200, 200 }
		def.Icon = def.Icon or ""
		def.Description = def.Description or ""
		def.Priority = tonumber(def.Priority) or 0
	end
	-- The root rank and creator binding must always exist.
	local defaults = defaultState()
	if not loaded.Ranks[ROOT_RANK] then
		loaded.Ranks[ROOT_RANK] = defaults.Ranks[ROOT_RANK]
	end
	loaded.Ranks[ROOT_RANK].Protected = true
	loaded.Ranks[ROOT_RANK].Nodes = { "*" }
	local hasCreator = false
	for _, b in ipairs(loaded.Bindings) do
		if b.Kind == "Creator" and b.Rank == ROOT_RANK then
			hasCreator = true
			b.Protected = true
		end
	end
	if not hasCreator then
		table.insert(loaded.Bindings, 1, defaults.Bindings[1])
	end
	return loaded :: State
end

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------
function RankService.ResolveRankName(name: string?): string?
	if type(name) ~= "string" then
		return nil
	end
	if state.Ranks[name] then
		return name
	end
	local lowered = name:lower()
	for rankName in pairs(state.Ranks) do
		if rankName:lower() == lowered then
			return rankName
		end
	end
	return nil
end

local function rankPriority(rankName: string): number
	local def = state.Ranks[rankName]
	return if def then def.Priority else -math.huge
end

function RankService.GetPriority(player: Player): number
	local best = -math.huge
	for _, roleName in ipairs(PermissionSystem.GetRoles(player)) do
		best = math.max(best, rankPriority(roleName))
	end
	return best
end

function RankService.GetTopRank(player: Player): string?
	local top, best = nil, -math.huge
	for _, roleName in ipairs(PermissionSystem.GetRoles(player)) do
		local p = rankPriority(roleName)
		if p > best then
			top, best = roleName, p
		end
	end
	return top
end

local function isRoot(actor: Player): boolean
	for _, roleName in ipairs(PermissionSystem.GetRoles(actor)) do
		if roleName == ROOT_RANK then
			return true
		end
	end
	return false
end

-- Root may manage any rank; everyone else only ranks strictly below them.
local function canManage(actor: Player, rankName: string): boolean
	return isRoot(actor) or rankPriority(rankName) < RankService.GetPriority(actor)
end

function RankService.IsReadOnly(): boolean
	return readOnly
end

-- Tests only: enables in-memory writes when not in a running game. Saves
-- are no-ops offline, so this can never touch the real DataStore.
function RankService._AllowWritesForTests(): boolean
	if game:GetService("RunService"):IsRunning() then
		return false
	end
	readOnly = false
	return true
end

type RankSnapshot = RankDef & { Name: string }

function RankService.GetRank(name: string): RankSnapshot?
	local canonical = RankService.ResolveRankName(name)
	if not canonical then
		return nil
	end
	local snap = deepCopy(state.Ranks[canonical]) :: any
	snap.Name = canonical
	return snap
end

function RankService.GetRanks(): { RankSnapshot }
	local list = {}
	for name in pairs(state.Ranks) do
		table.insert(list, (RankService.GetRank(name) :: any))
	end
	table.sort(list, function(a, b)
		if a.Priority == b.Priority then
			return a.Name < b.Name
		end
		return a.Priority > b.Priority
	end)
	return list
end

function RankService.GetBindings(rankName: string?): { Binding }
	local filter = if rankName then RankService.ResolveRankName(rankName) else nil
	local list = {}
	if rankName and not filter then
		return list -- unknown rank: nothing, not everything
	end
	for _, b in ipairs(state.Bindings) do
		if not filter or b.Rank == filter then
			table.insert(list, deepCopy(b))
		end
	end
	return list
end

function RankService.GetHistory(count: number?): { HistoryEntry }
	local n = count or 20
	local list = {}
	for i = #state.History, math.max(1, #state.History - n + 1), -1 do
		table.insert(list, deepCopy(state.History[i]))
	end
	return list
end

-- ---------------------------------------------------------------------------
-- Binding evaluation
-- ---------------------------------------------------------------------------
local function bindingMatches(player: Player, b: Binding): boolean
	if b.ExpiresAt and b.ExpiresAt <= os.time() then
		return false
	end
	local kind = b.Kind
	if kind == "UserId" then
		return player.UserId == b.Value
	elseif kind == "Creator" then
		if game.CreatorType == Enum.CreatorType.User then
			return player.UserId == game.CreatorId
		end
		local ok, groupRank = pcall(player.GetRankInGroup, player, game.CreatorId)
		return ok and groupRank == 255
	elseif kind == "PrivateServerOwner" then
		return game.PrivateServerOwnerId ~= 0 and player.UserId == game.PrivateServerOwnerId
	elseif kind == "Group" and b.Value then
		local ok, inGroup = pcall(player.IsInGroup, player, b.Value)
		return ok and inGroup == true
	elseif kind == "GroupRole" and b.Value then
		local ok, groupRank = pcall(player.GetRankInGroup, player, b.Value)
		return ok and groupRank >= (b.MinRank or 1)
	elseif kind == "GamePass" and b.Value then
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, b.Value)
		return ok and owns == true
	elseif kind == "Asset" and b.Value then
		local ok, owns = pcall(MarketplaceService.PlayerOwnsAsset, MarketplaceService, player, b.Value)
		return ok and owns == true
	end
	return false
end

function RankService.Refresh(player: Player)
	if not player.Parent then
		return
	end
	local desired: { [string]: boolean } = {}
	for _, b in ipairs(state.Bindings) do
		if state.Ranks[b.Rank] and bindingMatches(player, b) then
			desired[b.Rank] = true
		end
	end

	local current = managed[player.UserId] or {}
	for rankName in pairs(current) do
		if not desired[rankName] then
			PermissionSystem.RevokeRole(player, rankName)
		end
	end
	for rankName in pairs(desired) do
		if not current[rankName] then
			PermissionSystem.AssignRole(player, rankName)
		end
	end
	managed[player.UserId] = desired
end

local function refreshAll()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(RankService.Refresh, player)
	end
end

-- Pushes the rank definitions into PermissionSystem.
local function syncRoles()
	for roleName in pairs(definedRoles) do
		if not state.Ranks[roleName] then
			PermissionSystem.UndefineRole(roleName)
			definedRoles[roleName] = nil
		end
	end
	for name, def in pairs(state.Ranks) do
		PermissionSystem.DefineRole(name, table.clone(def.Nodes), table.clone(def.Inherits))
		definedRoles[name] = true
	end
	-- Drop assignments of ranks that no longer exist.
	for userId, set in pairs(managed) do
		for rankName in pairs(set) do
			if not state.Ranks[rankName] then
				set[rankName] = nil
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
local offline = not game:GetService("RunService"):IsRunning()

local function save(): boolean
	if offline then
		return true -- Edit-mode tests: never touch the real DataStore
	end
	local ok, err = pcall(function()
		store:UpdateAsync(STORE_KEY, function()
			return state
		end)
	end)
	if not ok then
		warn("[Sentinel.RankService] save failed: " .. tostring(err))
		return false
	end
	pcall(function()
		MessagingService:PublishAsync(MESSAGE_TOPIC, game.JobId)
	end)
	return true
end

local function load(): boolean
	for attempt = 1, 3 do
		local ok, result = pcall(store.GetAsync, store, STORE_KEY)
		if ok then
			if result == nil then
				state = defaultState()
			else
				local clean = sanitize(result)
				if not clean then
					warn("[Sentinel.RankService] saved rank data is malformed; using defaults (read-only).")
					state = defaultState()
					return false
				end
				state = clean
			end
			return true
		end
		warn(("[Sentinel.RankService] load attempt %d failed: %s"):format(attempt, tostring(result)))
		task.wait(attempt)
	end
	state = defaultState()
	return false
end

-- Records a change, re-syncs roles, saves and refreshes everyone.
local function commit(actor: Player?, action: string, detail: string): (boolean, string)
	table.insert(state.History, {
		Time = os.time(),
		ActorId = if actor then actor.UserId else 0,
		ActorName = if actor then actor.Name else "System",
		Action = action,
		Detail = detail,
	})
	while #state.History > HISTORY_LIMIT do
		table.remove(state.History, 1)
	end
	syncRoles()
	refreshAll()
	Logger.Write({
		Executor = if actor then tostring(actor.UserId) else "0",
		ExecutorName = if actor then actor.Name else "System",
		Command = "rank." .. action,
		Result = "Success",
		Severity = "Info",
		Message = detail,
	})
	if not save() then
		return true, detail .. " (warning: could not be saved — it will be lost when this server closes)"
	end
	return true, detail
end

local function guardWritable(): (boolean, string)
	if readOnly then
		return false, "Rank data failed to load, so changes are disabled to avoid overwriting saved ranks."
	end
	return true, ""
end

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------
local function validRankName(name: any): boolean
	return type(name) == "string" and #name >= 1 and #name <= 24 and name:match("^[%w_]+$") ~= nil
end

-- "*" or category.action[.more] where any segment may be "*". A leading
-- "!" makes it an explicit denial ("!developer.execute").
local function validNode(node: any): boolean
	if type(node) ~= "string" or #node < 1 or #node > 64 then
		return false
	end
	if node:sub(1, 1) == "!" then
		node = node:sub(2)
		if node == "*" then
			return false -- denying everything is never what you want
		end
	end
	if node == "*" then
		return true
	end
	for segment in (node .. "."):gmatch("(.-)%.") do
		if segment ~= "*" and not segment:match("^[%w_]+$") then
			return false
		end
	end
	return node:find("%.") ~= nil
end

local function parseColor(raw: string): { number }?
	local hex = raw:match("^#?(%x%x%x%x%x%x)$")
	if hex then
		return {
			tonumber(hex:sub(1, 2), 16) :: number,
			tonumber(hex:sub(3, 4), 16) :: number,
			tonumber(hex:sub(5, 6), 16) :: number,
		}
	end
	local r, g, b = raw:match("^(%d+),(%d+),(%d+)$")
	if r then
		local rgb = { tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number }
		for _, c in ipairs(rgb) do
			if c > 255 then
				return nil
			end
		end
		return rgb
	end
	return nil
end

local function checkPriority(actor: Player, priority: any): (boolean, string)
	if type(priority) ~= "number" or priority ~= math.floor(priority) or priority < 0 or priority > 1000 then
		return false, "Priority must be a whole number from 0 to 1000."
	end
	if not isRoot(actor) and priority >= RankService.GetPriority(actor) then
		return false, "You can only use priorities below your own rank."
	end
	return true, ""
end

local function resolveInherits(actor: Player, selfName: string, list: { string }): ({ string }?, string?)
	local out = {}
	for _, raw in ipairs(list) do
		local canonical = RankService.ResolveRankName(raw)
		if not canonical then
			return nil, ("Unknown rank '%s'."):format(raw)
		end
		if canonical == selfName then
			return nil, "A rank cannot inherit from itself."
		end
		if not canManage(actor, canonical) then
			return nil, ("You cannot inherit from '%s' (it is not below your rank)."):format(canonical)
		end
		table.insert(out, canonical)
	end
	return out, nil
end

-- ---------------------------------------------------------------------------
-- Rank CRUD
-- ---------------------------------------------------------------------------
function RankService.CreateRank(actor: Player, name: string, priority: number, inherits: { string }?): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	if not validRankName(name) then
		return false, "Rank names are 1-24 letters, digits or underscores."
	end
	local existing = RankService.ResolveRankName(name)
	if existing then
		return false, ("A rank named '%s' already exists."):format(existing)
	end
	local okP, msgP = checkPriority(actor, priority)
	if not okP then
		return false, msgP
	end
	local parents, err = resolveInherits(actor, name, inherits or {})
	if not parents then
		return false, err :: string
	end
	state.Ranks[name] = {
		Priority = priority,
		Color = { 200, 200, 200 },
		Icon = "",
		Description = "",
		Nodes = {},
		Inherits = parents,
	}
	return commit(actor, "create", ("Created rank %s (priority %d)."):format(name, priority))
end

function RankService.DeleteRank(actor: Player, name: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(name)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(name)
	end
	if state.Ranks[canonical].Protected then
		return false, ("%s is protected and cannot be deleted."):format(canonical)
	end
	if not canManage(actor, canonical) then
		return false, "You can only delete ranks below your own."
	end
	state.Ranks[canonical] = nil
	for _, def in pairs(state.Ranks) do
		local idx = table.find(def.Inherits, canonical)
		if idx then
			table.remove(def.Inherits, idx)
		end
	end
	local removed = 0
	for i = #state.Bindings, 1, -1 do
		if state.Bindings[i].Rank == canonical then
			table.remove(state.Bindings, i)
			removed += 1
		end
	end
	return commit(actor, "delete", ("Deleted rank %s and %d assignment(s)."):format(canonical, removed))
end

function RankService.RenameRank(actor: Player, oldName: string, newName: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(oldName)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(oldName)
	end
	if state.Ranks[canonical].Protected then
		return false, ("%s is protected and cannot be renamed."):format(canonical)
	end
	if not canManage(actor, canonical) then
		return false, "You can only rename ranks below your own."
	end
	if not validRankName(newName) then
		return false, "Rank names are 1-24 letters, digits or underscores."
	end
	local clash = RankService.ResolveRankName(newName)
	if clash and clash ~= canonical then
		return false, ("A rank named '%s' already exists."):format(clash)
	end
	state.Ranks[newName] = state.Ranks[canonical]
	if newName ~= canonical then
		state.Ranks[canonical] = nil
	end
	for _, def in pairs(state.Ranks) do
		for i, parent in ipairs(def.Inherits) do
			if parent == canonical then
				def.Inherits[i] = newName
			end
		end
	end
	for _, b in ipairs(state.Bindings) do
		if b.Rank == canonical then
			b.Rank = newName
		end
	end
	for _, set in pairs(managed) do
		if set[canonical] then
			set[canonical] = nil
		end
	end
	return commit(actor, "rename", ("Renamed rank %s to %s."):format(canonical, newName))
end

function RankService.DuplicateRank(actor: Player, sourceName: string, newName: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(sourceName)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(sourceName)
	end
	if not canManage(actor, canonical) then
		return false, "You can only duplicate ranks below your own."
	end
	if not validRankName(newName) then
		return false, "Rank names are 1-24 letters, digits or underscores."
	end
	if RankService.ResolveRankName(newName) then
		return false, ("A rank named '%s' already exists."):format(newName)
	end
	local copy = deepCopy(state.Ranks[canonical])
	copy.Protected = nil
	state.Ranks[newName] = copy
	return commit(actor, "duplicate", ("Duplicated rank %s as %s."):format(canonical, newName))
end

function RankService.EditRank(actor: Player, name: string, field: string, value: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(name)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(name)
	end
	if not canManage(actor, canonical) then
		return false, "You can only edit ranks below your own."
	end
	local def = state.Ranks[canonical]
	field = (field or ""):lower()

	if field == "priority" then
		if def.Protected then
			return false, ("%s's priority is fixed."):format(canonical)
		end
		local priority = tonumber(value)
		local okP, msgP = checkPriority(actor, priority)
		if not okP then
			return false, msgP
		end
		def.Priority = priority :: number
	elseif field == "color" or field == "colour" then
		local rgb = parseColor(value or "")
		if not rgb then
			return false, "Color must be #RRGGBB or R,G,B."
		end
		def.Color = rgb
	elseif field == "icon" then
		if utf8.len(value or "") == nil or #(value or "") > 16 then
			return false, "Icon must be a short piece of text or an emoji."
		end
		def.Icon = value
	elseif field == "description" then
		if #(value or "") > 200 then
			return false, "Description is limited to 200 characters."
		end
		def.Description = value or ""
	elseif field == "inherits" then
		local list = {}
		if value and value ~= "" and value:lower() ~= "none" then
			for piece in value:gmatch("[^,%s]+") do
				table.insert(list, piece)
			end
		end
		local parents, err = resolveInherits(actor, canonical, list)
		if not parents then
			return false, err :: string
		end
		if def.Protected then
			return false, ("%s's inheritance is fixed."):format(canonical)
		end
		def.Inherits = parents
	else
		return false, "Field must be one of: priority, color, icon, description, inherits."
	end
	return commit(actor, "edit", ("Set %s of %s to %s."):format(field, canonical, tostring(value)))
end

function RankService.SetNode(actor: Player, name: string, node: string, add: boolean): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(name)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(name)
	end
	if state.Ranks[canonical].Protected then
		return false, ("%s always has every permission."):format(canonical)
	end
	if not canManage(actor, canonical) then
		return false, "You can only edit ranks below your own."
	end
	if not validNode(node) then
		return false, "Permission nodes look like category.action, e.g. moderation.kick or player.*"
	end
	-- You cannot hand out a permission you don't have yourself.
	if add and node:sub(1, 1) ~= "!" and not isRoot(actor) and not PermissionSystem.Has(actor, node) then
		return false, ("You cannot grant %s because you don't have it."):format(node)
	end
	local nodes = state.Ranks[canonical].Nodes
	local idx = table.find(nodes, node)
	if add then
		if idx then
			return false, ("%s already has %s."):format(canonical, node)
		end
		-- Allow and deny of the same node are mutually exclusive: switching
		-- one to the other is a single change.
		local opposite = if node:sub(1, 1) == "!" then node:sub(2) else "!" .. node
		local oppositeIdx = table.find(nodes, opposite)
		if oppositeIdx then
			table.remove(nodes, oppositeIdx)
		end
		table.insert(nodes, node)
		if node:sub(1, 1) == "!" then
			return commit(actor, "deny", ("Denied %s on %s."):format(node:sub(2), canonical))
		end
		return commit(actor, "grant", ("Granted %s to %s."):format(node, canonical))
	end
	if not idx then
		return false, ("%s does not have %s directly."):format(canonical, node)
	end
	table.remove(nodes, idx)
	return commit(actor, "revoke", ("Removed %s from %s."):format(node, canonical))
end

function RankService.ResetToDefaults(actor: Player): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	if not isRoot(actor) then
		return false, ("Only %s can reset ranks to the defaults."):format(ROOT_RANK)
	end
	local history = state.History
	state = defaultState()
	state.History = history
	managed = {}
	for _, player in ipairs(Players:GetPlayers()) do
		for _, roleName in ipairs(PermissionSystem.GetRoles(player)) do
			PermissionSystem.RevokeRole(player, roleName)
		end
	end
	return commit(actor, "reset", "Reset all ranks and assignments to the default templates.")
end

-- ---------------------------------------------------------------------------
-- Bindings
-- ---------------------------------------------------------------------------
local function describeBinding(b: Binding): string
	local what
	if b.Kind == "UserId" then
		what = ("user %s"):format(if b.Label then ("%s (%d)"):format(b.Label, b.Value or 0) else tostring(b.Value))
	elseif b.Kind == "GroupRole" then
		what = ("group %s rank >= %d"):format(tostring(b.Value), b.MinRank or 1)
	elseif b.Kind == "Creator" then
		what = "game creator"
	elseif b.Kind == "PrivateServerOwner" then
		what = "private server owner"
	else
		what = ("%s %s"):format(b.Kind:lower(), tostring(b.Value))
	end
	local expiry = if b.ExpiresAt then (" until %s"):format(os.date("!%Y-%m-%d %H:%M UTC", b.ExpiresAt)) else ""
	return ("%s -> %s%s"):format(what, b.Rank, expiry)
end
RankService.DescribeBinding = describeBinding

-- kind: userid | username | group | grouprole | gamepass | asset | creator | privateserver
-- value: the id (or username for kind "username"); extra = min group rank for grouprole.
function RankService.AddBinding(
	actor: Player,
	kind: string,
	value: any,
	rankName: string,
	durationSeconds: number?,
	extra: number?
): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(rankName)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(tostring(rankName))
	end
	if not canManage(actor, canonical) then
		return false, "You can only assign ranks below your own."
	end

	local lowered = (kind or ""):lower()
	local label: string? = nil
	local numericValue: number? = nil

	if lowered == "username" then
		local ok, userId = pcall(Players.GetUserIdFromNameAsync, Players, tostring(value))
		if not ok or not userId then
			return false, ("No Roblox user named '%s'."):format(tostring(value))
		end
		local okName, exactName = pcall(Players.GetNameFromUserIdAsync, Players, userId)
		label = if okName then exactName else tostring(value)
		numericValue = userId
		lowered = "userid"
	end

	local bindingKind = BINDING_KINDS[lowered]
	if not bindingKind then
		return false, "Kind must be userid, username, group, grouprole, gamepass, asset, creator or privateserver."
	end

	if bindingKind ~= "Creator" and bindingKind ~= "PrivateServerOwner" then
		numericValue = numericValue or tonumber(value)
		if not numericValue or numericValue <= 0 or numericValue ~= math.floor(numericValue) then
			return false, "That needs a positive numeric id."
		end
	end
	if bindingKind == "GroupRole" then
		local minRank = extra or 1
		if minRank < 1 or minRank > 255 or minRank ~= math.floor(minRank) then
			return false, "Group rank must be 1-255."
		end
		extra = minRank
	end
	if bindingKind == "UserId" and not label then
		local okName, exactName = pcall(Players.GetNameFromUserIdAsync, Players, numericValue)
		label = if okName then exactName else nil
	end
	if durationSeconds and (durationSeconds <= 0 or durationSeconds == math.huge) then
		durationSeconds = nil
	end

	-- Replace an existing identical binding instead of stacking duplicates
	-- (e.g. re-assigning the same user extends/clears the expiry).
	for i = #state.Bindings, 1, -1 do
		local b = state.Bindings[i]
		if b.Kind == bindingKind and b.Value == numericValue and b.Rank == canonical and b.MinRank == (if bindingKind == "GroupRole" then extra else nil) then
			if b.Protected then
				return false, "That assignment already exists and is protected."
			end
			table.remove(state.Bindings, i)
		end
	end

	local binding: Binding = {
		Id = HttpService:GenerateGUID(false):sub(1, 8):lower(),
		Kind = bindingKind,
		Value = numericValue,
		MinRank = if bindingKind == "GroupRole" then extra else nil,
		Label = label,
		Rank = canonical,
		ExpiresAt = if durationSeconds then os.time() + math.floor(durationSeconds) else nil,
		AddedBy = actor.UserId,
		AddedAt = os.time(),
	}
	table.insert(state.Bindings, binding)
	return commit(actor, "assign", ("Assigned %s [%s]."):format(describeBinding(binding), binding.Id))
end

function RankService.RemoveBinding(actor: Player, bindingId: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	for i, b in ipairs(state.Bindings) do
		if b.Id == bindingId then
			if b.Protected then
				return false, "That assignment is protected and cannot be removed."
			end
			if not canManage(actor, b.Rank) then
				return false, "You can only remove assignments of ranks below your own."
			end
			-- No self-demotion: you cannot remove the assignment that gives
			-- you your own highest rank.
			if b.Kind == "UserId" and b.Value == actor.UserId and rankPriority(b.Rank) >= RankService.GetPriority(actor) then
				return false, "You cannot remove your own highest rank."
			end
			table.remove(state.Bindings, i)
			return commit(actor, "unassign", ("Removed %s."):format(describeBinding(b)))
		end
	end
	return false, ("No assignment with id '%s'."):format(tostring(bindingId))
end

-- Removes every UserId binding of `rankName` for `userId`.
function RankService.RemoveUserRank(actor: Player, userId: number, rankName: string): (boolean, string)
	local canonical = RankService.ResolveRankName(rankName)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(tostring(rankName))
	end
	for _, b in ipairs(state.Bindings) do
		if b.Kind == "UserId" and b.Value == userId and b.Rank == canonical then
			return RankService.RemoveBinding(actor, b.Id)
		end
	end
	return false, ("That player doesn't have %s through a direct assignment."):format(canonical)
end

-- ---------------------------------------------------------------------------
-- Permission presets: named bundles of nodes that can be added to a rank.
-- ---------------------------------------------------------------------------
local PRESETS: { [string]: { Description: string, Nodes: { string } } } = {
	PanelAccess = { Description = "Open the panel and view ranks", Nodes = { "panel.open", "ranks.view" } },
	Moderation = {
		Description = "Kick, mute, warn, notes, freeze, jail",
		Nodes = { "moderation.kick", "moderation.mute", "moderation.warn", "moderation.notes", "moderation.cases", "player.freeze", "player.jail" },
	},
	FullModeration = { Description = "All moderation incl. bans and access lists", Nodes = { "moderation.*", "player.freeze", "player.jail" } },
	Teleport = { Description = "Goto, bring, teleport, spawn", Nodes = { "player.goto", "player.bring", "player.teleport", "player.spawn" } },
	PlayerFun = {
		Description = "Fly, noclip, speed, jump, spin, effects",
		Nodes = { "player.fly", "player.noclip", "player.speed", "player.jump", "player.spin", "player.effects" },
	},
	Economy = { Description = "Currency, XP, badges and items", Nodes = { "economy.*", "inventory.*" } },
	Server = { Description = "Announcements, lock, maintenance, environment", Nodes = { "server.*", "environment.*" } },
	CrossServerStaff = {
		Description = "Server list, find players, cross-server staff chat",
		Nodes = { "crossserver.view", "crossserver.staffchat", "crossserver.join" },
	},
	CrossServerModeration = {
		Description = "Global kick, warn, ban, bring and announcements",
		Nodes = {
			"crossserver.view",
			"crossserver.staffchat",
			"crossserver.join",
			"crossserver.bring",
			"crossserver.kick",
			"crossserver.warn",
			"crossserver.ban",
			"crossserver.announce",
		},
	},
	CrossServerOperations = { Description = "Everything cross-server incl. lockdown, shutdown, migration", Nodes = { "crossserver.*" } },
	DevReadOnly = {
		Description = "Read-only developer tools",
		Nodes = { "developer.stats", "developer.console", "developer.remotemonitor", "developer.datastore.read" },
	},
}

function RankService.GetPresets(): { { Name: string, Description: string, Nodes: { string } } }
	local list = {}
	for name, preset in pairs(PRESETS) do
		table.insert(list, { Name = name, Description = preset.Description, Nodes = table.clone(preset.Nodes) })
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

-- Adds every node of a preset the rank doesn't already have (one history
-- entry). Same rules as SetNode: only for ranks below you, and only nodes
-- you hold yourself.
function RankService.ApplyPreset(actor: Player, rankName: string, presetName: string): (boolean, string)
	local writable, why = guardWritable()
	if not writable then
		return false, why
	end
	local canonical = RankService.ResolveRankName(rankName)
	if not canonical then
		return false, ("Unknown rank '%s'."):format(tostring(rankName))
	end
	local presetKey = nil
	for name in pairs(PRESETS) do
		if name:lower() == (presetName or ""):lower() then
			presetKey = name
		end
	end
	if not presetKey then
		local names = {}
		for _, p in ipairs(RankService.GetPresets()) do
			table.insert(names, p.Name)
		end
		return false, "Unknown preset. Presets: " .. table.concat(names, ", ")
	end
	if state.Ranks[canonical].Protected then
		return false, ("%s always has every permission."):format(canonical)
	end
	if not canManage(actor, canonical) then
		return false, "You can only edit ranks below your own."
	end
	local nodes = state.Ranks[canonical].Nodes
	local added, skipped = {}, {}
	for _, node in ipairs(PRESETS[presetKey].Nodes) do
		if table.find(nodes, node) then
			continue
		end
		if not isRoot(actor) and not PermissionSystem.Has(actor, node) then
			table.insert(skipped, node)
			continue
		end
		table.insert(nodes, node)
		table.insert(added, node)
	end
	if #added == 0 then
		return false, if #skipped > 0
			then ("Nothing added; you don't hold: %s."):format(table.concat(skipped, ", "))
			else ("%s already has everything in %s."):format(canonical, presetKey)
	end
	local ok, msg = commit(actor, "preset", ("Applied preset %s to %s: %s."):format(presetKey, canonical, table.concat(added, ", ")))
	if #skipped > 0 then
		msg ..= (" Skipped (you don't hold them): %s."):format(table.concat(skipped, ", "))
	end
	return ok, msg
end

-- ---------------------------------------------------------------------------
-- Target protection: staff can't target players ranked equal to or above
-- them (immunity by rank). Yourself is always allowed.
-- ---------------------------------------------------------------------------
function RankService.CanTarget(executor: Player, target: Player): boolean
	if executor == target then
		return true
	end
	local targetPriority = RankService.GetPriority(target)
	if targetPriority == -math.huge then
		return true -- unranked players are never protected
	end
	return targetPriority < RankService.GetPriority(executor)
end

local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))
CommandProcessor.SetTargetFilter(function(executor: Player, _def: any, targets: { Player })
	local allowed, blocked = {}, 0
	for _, target in ipairs(targets) do
		if RankService.CanTarget(executor, target) then
			table.insert(allowed, target)
		else
			blocked += 1
		end
	end
	return allowed, blocked
end)

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------
-- Required outside a running game (Studio command bar, tests): defaults only,
-- read-only, no DataStore access and no background loops.
if not game:GetService("RunService"):IsRunning() then
	readOnly = true
	syncRoles()
	return RankService
end

readOnly = not load()
syncRoles()

Players.PlayerAdded:Connect(function(player)
	RankService.Refresh(player)
end)
Players.PlayerRemoving:Connect(function(player)
	managed[player.UserId] = nil
end)
refreshAll()

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _passId, purchased)
	if purchased then
		RankService.Refresh(player)
	end
end)

-- Other servers changed the ranks: reload and re-apply.
task.spawn(function()
	pcall(function()
		MessagingService:SubscribeAsync(MESSAGE_TOPIC, function(message)
			if message.Data == game.JobId then
				return
			end
			if load() then
				readOnly = false
				syncRoles()
				refreshAll()
			end
		end)
	end)
end)

-- Expire temporary assignments.
task.spawn(function()
	while true do
		task.wait(15)
		if readOnly then
			continue
		end
		local now = os.time()
		local expired = {}
		for i = #state.Bindings, 1, -1 do
			local b = state.Bindings[i]
			if b.ExpiresAt and b.ExpiresAt <= now then
				table.insert(expired, describeBinding(b))
				table.remove(state.Bindings, i)
			end
		end
		if #expired > 0 then
			commit(nil, "expire", "Expired: " .. table.concat(expired, "; "))
		end
	end
end)

if readOnly then
	warn("[Sentinel.RankService] running on default ranks in read-only mode (saved data unavailable).")
end

return RankService
