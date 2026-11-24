--!strict
--[[
	CrossServerService.lua (cross-server infrastructure, W17-W21)

	Purpose:
		Everything Sentinel needs to see and reach the experience's other
		running servers:

		Registry   Each server writes a heartbeat record (players, capacity,
		           uptime, version, FPS, ping, memory, staff, flags, player
		           list) to a MemoryStore sorted map every HEARTBEAT seconds.
		           Records expire on their own, so crashed servers disappear.
		Bus        One Core/CrossServerNode on MessagingService: broadcast or
		           direct messages, acknowledgements, operation status.
		State      Experience-wide flags (global lockdown) in a DataStore, so
		           servers that start later apply them too.
		History    The last global actions of every server, in the DataStore.
		Staff chat Cross-server staff chat with a short shared backlog
		           (MemoryStore), pushed live to staff clients.
		Teleports  Join a server, graceful migration (update countdown, then a
		           bounce through a reserved server so players land in fresh
		           servers).

		Roblox services used as the blueprint asks: DataStoreService for
		persistent records, MemoryStoreService for fast-changing temporary
		data, MessagingService for live server-to-server communication.

	Actions (what a server DOES when a message arrives) live in
	Systems/CrossServerActions; the staff commands in
	Commands/CrossServer/CrossServer.lua.

	Outside a running game (unit tests) no Roblox service is touched: the
	node gets a transport that goes nowhere.

	Public API:
		CrossServerService.ServerId, .ShortId(id)
		CrossServerService.ListServers(force?) -> (servers, totals)
		CrossServerService.GetServer(idOrPrefix) -> record?, err?
		CrossServerService.FindPlayers(query, limit?) -> { match }
		CrossServerService.ActorOf(player) -> Actor
		CrossServerService.Handle(kind, fn)
		CrossServerService.Send(kind, payload, options) -> (operation?, err?)
			options: To, Actor, Label, NoAck, History = true, Target = "name"
		CrossServerService.WaitFor(opId, timeout) -> operation?
		CrossServerService.Describe(operation) -> string
		CrossServerService.GetOperations(limit?) / GetOperation(id)
		CrossServerService.GetGlobalState() / SetLockdown / ApplyLockdown
		CrossServerService.GetHistory(force?) / RecordHistory(entry)
		CrossServerService.PostStaffChat(entry, publish?) / GetStaffChat()
		CrossServerService.PushToStaff(kind, data) -> number
		CrossServerService.JoinServer(player, idOrPrefix) -> (ok, message)
		CrossServerService.StartMigration(seconds, message) -> (ok, count, message)
		CrossServerService.GetStats() -> { Peak..., Bus... }
		CrossServerService.LocalInfo() -> this server's record + W22 fields
--]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Node = require(Core:WaitForChild("CrossServerNode"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local DeveloperService = require(script.Parent:WaitForChild("DeveloperService"))
local ServerStateService = require(script.Parent:WaitForChild("ServerStateService"))
local RankService = require(script.Parent:WaitForChild("RankService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local CrossServerService = {}

local REGISTRY_MAP = "SentinelServers_v1"
local CHAT_MAP = "SentinelStaffChat_v1"
local STORE_NAME = "Sentinel_CrossServer_v1"
local KEY_STATE = "GlobalState"
local KEY_HISTORY = "History"
local KEY_STATS = "Stats"

local HEARTBEAT = 25 -- seconds between registry writes
local RECORD_EXPIRY = 90 -- MemoryStore expiry of a registry record
local STALE_AFTER = 100 -- ignore records older than this
local LIST_CACHE = 5 -- seconds a fetched server list is reused
local MAX_LISTED_PLAYERS = 150 -- player names kept per registry record
local HISTORY_LIMIT = 150
local CHAT_BACKLOG = 60
local CHAT_EXPIRY = 6 * 3600

local live = RunService:IsRunning() and RunService:IsServer()
local studio = RunService:IsStudio()
local startedAt = os.time()

-- Studio has no JobId; give the session its own id so the registry and the
-- bus still work (and Studio never collides with a live server).
local serverId = if game.JobId ~= ""
	then game.JobId
	else "studio-" .. HttpService:GenerateGUID(false):sub(1, 8):lower()
CrossServerService.ServerId = serverId

function CrossServerService.ShortId(id: string?): string
	if not id then
		return "?"
	end
	return if id:sub(1, 7) == "studio-" then id else id:sub(1, 8)
end

-- W10: audit entries carry the same server id (Studio has no JobId).
Logger.SetServerId(serverId, CrossServerService.ShortId(serverId))

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = SentinelShared
	return remote
end

local eventRemote = getOrCreateRemote("CrossServerEventRemote")

-- ---------------------------------------------------------------------------
-- Pushing to staff clients (Cross-Server page, toasts)
-- ---------------------------------------------------------------------------
local function canView(player: Player): boolean
	return PermissionSystem.Has(player, "panel.open") and PermissionSystem.Has(player, "crossserver.view")
end

function CrossServerService.PushToStaff(kind: string, data: any, node: string?): number
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if canView(player) and (node == nil or PermissionSystem.Has(player, node)) then
			eventRemote:FireClient(player, kind, data)
			count += 1
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------
local registryMap = if live then MemoryStoreService:GetSortedMap(REGISTRY_MAP) else nil
local cachedServers: { any } = {}
local cachedTotals: any = { Servers = 0, Players = 0, Staff = 0, Capacity = 0, AvgFps = 0, AvgPing = 0, Locked = 0, Poor = 0 }
local cachedAt = -math.huge
local fetching = false
local registryError: string? = nil

local function buildRecord(): any
	local stats = DeveloperService.GetServerStats()
	local staff, list = {}, {}
	local pingSum, pingCount = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		if PermissionSystem.Has(player, "panel.open") and #staff < 12 then
			table.insert(staff, player.Name)
		end
		if #list < MAX_LISTED_PLAYERS then
			table.insert(list, { player.UserId, player.Name })
		end
		local ping = DeveloperService.GetPing(player)
		if ping >= 0 then
			pingSum += ping
			pingCount += 1
		end
	end
	return {
		Id = serverId,
		Place = game.PlaceId,
		Ver = game.PlaceVersion,
		N = #Players:GetPlayers(),
		Max = Players.MaxPlayers,
		Start = startedAt,
		HB = os.time(),
		Fps = math.floor(tonumber(stats.HeartbeatRate) or 0),
		Ping = if pingCount > 0 then math.floor(pingSum / pingCount) else 0,
		Mem = stats.MemoryMb,
		Staff = staff,
		Locked = ServerStateService.IsLocked(),
		Maint = ServerStateService.IsMaintenanceMode(),
		Priv = game.PrivateServerId ~= "",
		-- A reserved server made by ;createserver can be joined by id: its
		-- PrivateServerId keys the access code in SentinelReserved_v1.
		Res = if game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then game.PrivateServerId else nil,
		Studio = studio or nil,
		P = list,
	}
end

--[[
	W22: everything the Server page / ;serverinfo show about THIS server.
	Location: Roblox has no server-region API, so it stays nil. Events and
	polls: active polls from PollService (W23); events stay empty until W24.
--]]
local pollProvider: (() -> { any })? = nil

function CrossServerService.LocalInfo(): any
	local record = buildRecord()
	record.P = nil
	record.ShortId = CrossServerService.ShortId(serverId)
	record.Uptime = os.time() - startedAt
	record.Health = Node.Health(record, os.time())
	record.SlowMode = ServerStateService.GetSlowMode()
	record.Cap = ServerStateService.GetCapacity()
	record.Whitelist = ServerStateService.IsWhitelistMode()
	record.PrivateAccess = ServerStateService.GetPrivateServerAccess()
	record.Messages = ServerStateService.GetMessages()
	record.Reserved = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
	record.Owner = if game.PrivateServerOwnerId ~= 0 then game.PrivateServerOwnerId else nil
	record.Location = nil
	record.Events = {}
	record.Polls = if pollProvider then pollProvider() else {}
	return record
end

-- W23: PollService hands over its active-poll summaries (Systems can't
-- require each other in a cycle).
function CrossServerService.SetPollProvider(fn: () -> { any })
	pollProvider = fn
end

local function writeHeartbeat()
	if not registryMap then
		return
	end
	local record = buildRecord()
	local ok, err = pcall(function()
		(registryMap :: MemoryStoreSortedMap):SetAsync(serverId, record, RECORD_EXPIRY)
	end)
	if not ok then
		registryError = tostring(err)
		warn("[Sentinel.CrossServerService] heartbeat failed: " .. tostring(err))
	else
		registryError = nil
	end
end

local function fetchRecords(): { any }
	local records = {}
	if not registryMap then
		return records
	end
	local lowerBound: any = nil
	for _ = 1, 5 do -- up to 1000 servers
		local items = (registryMap :: MemoryStoreSortedMap):GetRangeAsync(Enum.SortDirection.Ascending, 200, lowerBound)
		for _, item in ipairs(items) do
			if type(item.value) == "table" then
				table.insert(records, item.value)
			end
		end
		if #items < 200 then
			break
		end
		local last = items[#items]
		lowerBound = { key = last.key, sortKey = last.sortKey }
	end
	return records
end

local peak = { Players = 0, Servers = 0, At = 0 }
local peakDirty = false

function CrossServerService.ListServers(force: boolean?): ({ any }, any)
	if not live then
		return {}, cachedTotals
	end
	if not force and os.clock() - cachedAt < LIST_CACHE then
		return cachedServers, cachedTotals
	end
	if fetching then
		-- another caller is already asking MemoryStore: wait for its answer
		local waited = 0
		while fetching and waited < 5 do
			waited += task.wait(0.1)
		end
		return cachedServers, cachedTotals
	end
	fetching = true
	local ok, records = pcall(fetchRecords)
	if not ok then
		registryError = tostring(records)
		warn("[Sentinel.CrossServerService] server list failed: " .. tostring(records))
		records = {}
	end
	-- This server is always listed, with fresh numbers, even when MemoryStore
	-- is unavailable.
	local mine = buildRecord()
	local merged = { mine }
	for _, record in ipairs(records :: { any }) do
		if type(record) == "table" and record.Id ~= serverId then
			table.insert(merged, record)
		end
	end
	cachedServers, cachedTotals = Node.Summarize(merged, os.time(), STALE_AFTER)
	cachedAt = os.clock()
	fetching = false
	if cachedTotals.Players > peak.Players then
		peak = { Players = cachedTotals.Players, Servers = cachedTotals.Servers, At = os.time() }
		peakDirty = true
	end
	return cachedServers, cachedTotals
end

function CrossServerService.GetRegistryError(): string?
	return registryError
end

-- Full id, or a unique prefix of at least 4 characters ("this" = here).
function CrossServerService.GetServer(idOrPrefix: string): (any, string?)
	local wanted = idOrPrefix:lower()
	if wanted == "this" or wanted == "here" then
		wanted = serverId:lower()
	end
	local servers = CrossServerService.ListServers()
	local matches = {}
	for _, record in ipairs(servers) do
		local id = record.Id:lower()
		if id == wanted then
			return record, nil
		end
		if #wanted >= 4 and id:sub(1, #wanted) == wanted then
			table.insert(matches, record)
		end
	end
	if #matches == 1 then
		return matches[1], nil
	elseif #matches > 1 then
		return nil, ("'%s' matches %d servers - type more of the id."):format(idOrPrefix, #matches)
	end
	return nil, ("No running server matches '%s'."):format(idOrPrefix)
end

function CrossServerService.FindPlayers(query: string, limit: number?): { any }
	local servers = CrossServerService.ListServers()
	return Node.FindPlayers(servers, query, limit)
end

-- ---------------------------------------------------------------------------
-- Bus
-- ---------------------------------------------------------------------------
local transport
if live then
	transport = {
		Publish = function(topic: string, text: string): (boolean, string?)
			local lastErr: any = nil
			for attempt = 1, 2 do -- one retry: publishes fail transiently
				local ok, err = pcall(MessagingService.PublishAsync, MessagingService, topic, text)
				if ok then
					return true, nil
				end
				lastErr = err
				if attempt == 1 then
					task.wait(0.4)
				end
			end
			return false, tostring(lastErr)
		end,
		Subscribe = function(topic: string, callback: (any) -> ())
			task.spawn(function()
				for attempt = 1, 4 do
					local ok, err = pcall(function()
						MessagingService:SubscribeAsync(topic, function(message)
							callback(message.Data)
						end)
					end)
					if ok then
						return
					end
					warn(("[Sentinel.CrossServerService] subscribe to %s failed (try %d): %s"):format(topic, attempt, tostring(err)))
					task.wait(attempt * 2)
				end
			end)
		end,
	}
else
	transport = {
		Publish = function(): (boolean, string?)
			return false, "cross-server messaging is only available in a running game"
		end,
		Subscribe = function() end,
	}
end

local node = Node.new({
	Id = serverId,
	Transport = transport,
	AckTimeout = 8,
	ExpectedServers = function(): { string }
		local ids = {}
		for _, record in ipairs(cachedServers) do
			table.insert(ids, record.Id)
		end
		return ids
	end,
})
CrossServerService.Node = node

function CrossServerService.ActorOf(player: Player): Node.Actor
	local priority = RankService.GetPriority(player)
	return {
		UserId = player.UserId,
		Name = player.Name,
		Priority = if priority == -math.huge then -1 else priority,
	}
end

-- Handlers get (payload, envelope); envelope.a = { u, n, p } is the staff
-- member who started it, envelope.f the origin server. Every handled action
-- that came from ANOTHER server is written to this server's log.
local QUIET_KINDS = { chat = true, ping = true, notify = true, pollc = true, pollreq = true }

function CrossServerService.Handle(kind: string, fn: (any, any) -> (boolean, number?, string?))
	node:Handle(kind, function(payload: any, envelope: any)
		local ok, count, message = fn(payload, envelope)
		if envelope.f ~= serverId and not QUIET_KINDS[kind] then
			local actor = envelope.a
			Logger.Write({
				Executor = if type(actor) == "table" then tostring(actor.u) else "SYSTEM",
				ExecutorName = ("%s @%s"):format(
					if type(actor) == "table" then tostring(actor.n) else "SYSTEM",
					CrossServerService.ShortId(envelope.f)
				),
				Command = "xs." .. kind,
				Target = if type(payload) == "table" and payload.tn then tostring(payload.tn) else nil,
				Result = if ok then "Success" else "Failure",
				Severity = if ok then "Info" else "Warning",
				Message = message or ("%d affected"):format(tonumber(count) or 0),
			})
		end
		return ok, count, message
	end)
end

-- ---------------------------------------------------------------------------
-- Operations + history
-- ---------------------------------------------------------------------------
local store = if live then DataStoreService:GetDataStore(STORE_NAME) else nil
local opMeta: { [string]: { History: boolean?, Target: string?, Recorded: boolean? } } = {}
local history: { any } = {}
local historyLoadedAt = -math.huge

local function mergeHistory(stored: any): { any }
	local list = if type(stored) == "table" then stored else {}
	return list
end

function CrossServerService.RecordHistory(entry: any)
	entry.At = entry.At or os.time()
	entry.Origin = CrossServerService.ShortId(serverId)
	table.insert(history, 1, entry)
	while #history > HISTORY_LIMIT do
		table.remove(history)
	end
	CrossServerService.PushToStaff("history", entry)
	if not store then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(KEY_HISTORY, function(old)
				local list = mergeHistory(old)
				table.insert(list, 1, entry)
				while #list > HISTORY_LIMIT do
					table.remove(list)
				end
				return list
			end)
		end)
		if not ok then
			warn("[Sentinel.CrossServerService] history save failed: " .. tostring(err))
		end
	end)
end

-- Newest first. Re-read from the DataStore at most every 20 s so actions
-- taken on other servers show up.
function CrossServerService.GetHistory(force: boolean?): { any }
	if store and (force or os.clock() - historyLoadedAt > 20) then
		historyLoadedAt = os.clock()
		local ok, stored = pcall(function()
			return (store :: DataStore):GetAsync(KEY_HISTORY)
		end)
		if ok and type(stored) == "table" then
			history = stored
		elseif not ok then
			warn("[Sentinel.CrossServerService] history load failed: " .. tostring(stored))
		end
	end
	return history
end

node:OnOperationChanged(function(op: any)
	CrossServerService.PushToStaff("op", op)
	local meta = opMeta[op.Id]
	if meta and meta.History and not meta.Recorded and op.Status ~= "pending" and op.Status ~= "sent" then
		meta.Recorded = true
		CrossServerService.RecordHistory({
			Actor = op.ActorName or "SYSTEM",
			ActorId = op.ActorId,
			Kind = op.Kind,
			Label = op.Label,
			Target = meta.Target,
			Servers = #op.Expected,
			Acked = #op.Acks,
			Affected = op.Affected,
			Status = op.Status,
		})
	end
end)

function CrossServerService.Send(kind: string, payload: any, options: { [string]: any }?): (any, string?)
	local opts: { [string]: any } = options or {}
	if not live then
		return nil, "Cross-server messaging is only available in a running game."
	end
	if not opts.To and not opts.Quiet then
		-- make sure the expectation list is reasonably fresh for broadcasts
		CrossServerService.ListServers()
	end
	local op, err = node:Send(kind, payload, opts)
	if op and opts.History then
		opMeta[op.Id] = { History = true, Target = opts.Target }
		if op.Status == "failed" then
			opMeta[op.Id].Recorded = true
			CrossServerService.RecordHistory({
				Actor = op.ActorName or "SYSTEM",
				ActorId = op.ActorId,
				Kind = kind,
				Label = op.Label,
				Target = opts.Target,
				Servers = #op.Expected,
				Acked = 0,
				Affected = 0,
				Status = "failed",
			})
		end
	end
	return op, err
end

-- Waits until every expected server answered (usually well under a
-- second) or `timeout` seconds passed; returns the operation either way.
function CrossServerService.WaitFor(opId: string, timeout: number?): any
	local deadline = os.clock() + (timeout or 2.5)
	local op = node:GetOperation(opId)
	while op and op.Status == "pending" and os.clock() < deadline do
		task.wait(0.1)
		op = node:GetOperation(opId)
	end
	return op
end

function CrossServerService.Describe(op: any): string
	if not op then
		return "operation not found"
	end
	if op.Status == "failed" then
		return "could not be sent: " .. tostring(op.Error)
	end
	local text = ("%d/%d server(s) answered, %d affected"):format(#op.Acks, #op.Expected, op.Affected)
	if op.Status == "pending" then
		text ..= " so far (still waiting - see ;xstatus " .. op.Id .. ")"
	end
	local refused = {}
	for _, ack in ipairs(op.Acks) do
		if not ack.Ok and ack.Message then
			table.insert(refused, ("%s: %s"):format(CrossServerService.ShortId(ack.Server), ack.Message))
		end
	end
	if #refused > 0 then
		text ..= " - " .. table.concat(refused, "; ")
	end
	return text
end

function CrossServerService.GetOperations(limit: number?): { any }
	return node:GetOperations(limit)
end

function CrossServerService.GetOperation(id: string): any
	local op = node:GetOperation(id)
	if op then
		return op
	end
	-- allow a unique prefix
	local found = nil
	for _, candidate in ipairs(node:GetOperations()) do
		if candidate.Id:sub(1, #id) == id then
			if found then
				return nil
			end
			found = candidate
		end
	end
	return found
end

-- ---------------------------------------------------------------------------
-- Global state (lockdown). The DataStore copy is what servers started
-- later read; running servers are told through the bus.
-- ---------------------------------------------------------------------------
local globalState: any = { Lockdown = { On = false } }

function CrossServerService.GetGlobalState(): any
	local lockdown = globalState.Lockdown or {}
	return {
		Lockdown = {
			On = lockdown.On == true,
			By = lockdown.By,
			At = lockdown.At,
			Reason = lockdown.Reason,
		},
	}
end

-- Applies a lockdown change to THIS server (bus handler, boot).
function CrossServerService.ApplyLockdown(on: boolean, by: string?, reason: string?, at: number?)
	globalState.Lockdown = { On = on, By = by, At = at or os.time(), Reason = reason }
	ServerStateService.SetLocked(on)
	CrossServerService.PushToStaff("state", CrossServerService.GetGlobalState())
end

-- Persists the flag for servers that start later. Does not message anyone;
-- the ;lockdown command broadcasts after this succeeds.
function CrossServerService.SetLockdown(on: boolean, actor: Player, reason: string?): (boolean, string?)
	local record = { On = on, By = actor.Name, ById = actor.UserId, At = os.time(), Reason = reason }
	if store then
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(KEY_STATE, function(old)
				local data = if type(old) == "table" then old else {}
				data.Lockdown = record
				return data
			end)
		end)
		if not ok then
			return false, "Could not save the lockdown state: " .. tostring(err)
		end
	end
	return true, nil
end

-- ---------------------------------------------------------------------------
-- Staff chat
-- ---------------------------------------------------------------------------
local chatMap = if live then MemoryStoreService:GetSortedMap(CHAT_MAP) else nil
local chatLog: { any } = {} -- oldest first
local chatIds: { [string]: boolean } = {}
local chatBacklogLoaded = false
local chatCounter = 0

local function addChat(entry: any): boolean
	if type(entry) ~= "table" or type(entry.Id) ~= "string" or chatIds[entry.Id] then
		return false
	end
	chatIds[entry.Id] = true
	table.insert(chatLog, entry)
	table.sort(chatLog, function(a, b)
		return a.Id < b.Id
	end)
	while #chatLog > CHAT_BACKLOG do
		local old = table.remove(chatLog, 1)
		if old then
			chatIds[old.Id] = nil
		end
	end
	return true
end

function CrossServerService.NewChatId(): string
	chatCounter += 1
	-- time-ordered, unique across servers
	return ("%012d%03d%s"):format(os.time(), chatCounter % 1000, serverId:sub(-4))
end

-- entry = { Id, Name, Rank, Text, Server, At }. `publish` = this server is
-- where it was typed: also keep it in the shared backlog.
function CrossServerService.PostStaffChat(entry: any, publish: boolean?)
	if not addChat(entry) then
		return
	end
	CrossServerService.PushToStaff("chat", entry, "crossserver.staffchat")
	if publish and chatMap then
		task.spawn(function()
			local ok, err = pcall(function()
				(chatMap :: MemoryStoreSortedMap):SetAsync(entry.Id, entry, CHAT_EXPIRY)
			end)
			if not ok then
				warn("[Sentinel.CrossServerService] staff chat backlog write failed: " .. tostring(err))
			end
		end)
	end
end

function CrossServerService.GetStaffChat(): { any }
	if chatMap and not chatBacklogLoaded then
		chatBacklogLoaded = true
		local ok, items = pcall(function()
			return (chatMap :: MemoryStoreSortedMap):GetRangeAsync(Enum.SortDirection.Descending, CHAT_BACKLOG)
		end)
		if ok then
			for _, item in ipairs(items) do
				addChat(item.value)
			end
		else
			chatBacklogLoaded = false
			warn("[Sentinel.CrossServerService] staff chat backlog read failed: " .. tostring(items))
		end
	end
	return chatLog
end

-- ---------------------------------------------------------------------------
-- Teleports: join a server, graceful migration
-- ---------------------------------------------------------------------------
function CrossServerService.CanTeleport(): (boolean, string?)
	if studio then
		return false, "Teleporting between servers isn't available in Studio."
	end
	return true, nil
end

-- ---------------------------------------------------------------------------
-- ;createserver: reserved servers staff create and can join later by id.
-- Access codes live in the MemoryStore sorted map SentinelReserved_v1
-- (key = PrivateServerId, 24 h), never sent to clients.
-- ---------------------------------------------------------------------------
local RESERVED_MAP = "SentinelReserved_v1"
local RESERVED_EXPIRY = 24 * 3600
local reservedMap = if live then MemoryStoreService:GetSortedMap(RESERVED_MAP) else nil

local function reservedCode(privateServerId: string): string?
	if not reservedMap then
		return nil
	end
	local ok, value = pcall(function()
		return (reservedMap :: MemoryStoreSortedMap):GetAsync(privateServerId)
	end)
	return if ok and type(value) == "table" and type(value.Code) == "string" then value.Code else nil
end

function CrossServerService.CreateServer(players: { Player }, actor: Player): (boolean, string, string?)
	local can, why = CrossServerService.CanTeleport()
	if not can then
		return false, why :: string, nil
	end
	if #players == 0 then
		return false, "Nobody to send.", nil
	end
	local okReserve, code, privateServerId = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not okReserve or type(code) ~= "string" then
		return false, "Could not reserve a server: " .. tostring(code), nil
	end
	if reservedMap then
		pcall(function()
			(reservedMap :: MemoryStoreSortedMap):SetAsync(privateServerId, {
				Code = code,
				By = actor.Name,
				ById = actor.UserId,
				At = os.time(),
			}, RESERVED_EXPIRY)
		end)
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData({ SentinelCreated = true })
	local okTeleport, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, players, options)
	end)
	if not okTeleport then
		return false, "Teleport failed: " .. tostring(err), privateServerId
	end
	return true, ("Created a new server; teleporting %d player(s). Staff can join it with ;joinserver once it shows in ;servers."):format(#players), privateServerId
end

function CrossServerService.TeleportToServer(players: { Player }, record: any): (boolean, string)
	local can, why = CrossServerService.CanTeleport()
	if not can then
		return false, why :: string
	end
	if record.Studio then
		return false, "That entry is a Studio session, not a live server."
	end
	local options = Instance.new("TeleportOptions")
	if record.Priv then
		local code = if type(record.Res) == "string" then reservedCode(record.Res) else nil
		if not code then
			return false, "Private and reserved servers can't be joined by id (only servers made with ;createserver)."
		end
		options.ReservedServerAccessCode = code
	else
		options.ServerInstanceId = record.Id
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(record.Place or game.PlaceId, players, options)
	end)
	if not ok then
		return false, "Teleport failed: " .. tostring(err)
	end
	return true, ("Teleporting to server %s..."):format(CrossServerService.ShortId(record.Id))
end

function CrossServerService.JoinServer(player: Player, idOrPrefix: string): (boolean, string)
	local record, err = CrossServerService.GetServer(idOrPrefix)
	if not record then
		return false, err :: string
	end
	if record.Id == serverId then
		return false, "You are already in that server."
	end
	if (tonumber(record.N) or 0) >= (tonumber(record.Max) or math.huge) then
		return false, ("Server %s is full (%d/%d)."):format(CrossServerService.ShortId(record.Id), record.N, record.Max)
	end
	return CrossServerService.TeleportToServer({ player }, record)
end

local migrating = false

local function getRemote(name: string): RemoteEvent?
	local remote = SentinelShared:FindFirstChild(name)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

--[[
	Graceful migration ("soft shutdown"): countdown on every screen, lock
	this server, then send everyone through a freshly reserved server that
	immediately sends them back to the public place. They land in servers
	started on the current place version, and this one closes when empty.
	In Studio the teleport is skipped (reported as a dry run).
--]]
function CrossServerService.StartMigration(seconds: number, message: string?): (boolean, number, string)
	if migrating then
		return false, 0, "a migration is already running"
	end
	migrating = true
	local delaySeconds = math.clamp(math.floor(seconds), 5, 300)
	local playerCount = #Players:GetPlayers()
	local label = message or "Server restarting for an update"
	task.spawn(function()
		local announce = getRemote("AnnounceRemote")
		local countdown = getRemote("CountdownRemote")
		if announce then
			announce:FireAllClients(("%s in %d seconds. You will be moved to a new server automatically."):format(label, delaySeconds), Color3.fromRGB(240, 180, 60))
		end
		for remaining = delaySeconds, 1, -1 do
			if countdown then
				countdown:FireAllClients("tick", label, remaining, delaySeconds)
			end
			task.wait(1)
		end
		if countdown then
			countdown:FireAllClients("done", label, 0, delaySeconds)
		end
		local can = CrossServerService.CanTeleport()
		if not can then
			if announce then
				announce:FireAllClients("Migration dry run finished (teleports are disabled in Studio).", Color3.fromRGB(240, 180, 60))
			end
			migrating = false
			return
		end
		ServerStateService.SetLocked(true)
		local ok, err = pcall(function()
			local code = TeleportService:ReserveServer(game.PlaceId)
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = code
			options:SetTeleportData({ SentinelMigration = true })
			TeleportService:TeleportAsync(game.PlaceId, Players:GetPlayers(), options)
		end)
		if not ok then
			warn("[Sentinel.CrossServerService] migration teleport failed: " .. tostring(err))
			ServerStateService.SetLocked(false)
			if announce then
				announce:FireAllClients("The move to a new server failed - you can keep playing here.", Color3.fromRGB(235, 87, 87))
			end
		end
		migrating = false
	end)
	return true, playerCount, ("migration starts in %ds for %d player(s)"):format(delaySeconds, playerCount)
end

-- The reserved "waiting room" server: send migrating players straight back
-- to a public server. TeleportData comes from the client, so the only thing
-- it can trigger is a teleport to this same place.
local function isReservedServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function bounceBack(player: Player)
	if studio or not isReservedServer() then
		return
	end
	local ok, joinData = pcall(player.GetJoinData, player)
	local data = if ok and type(joinData) == "table" then joinData.TeleportData else nil
	if type(data) ~= "table" or data.SentinelMigration ~= true then
		return
	end
	task.delay(6, function()
		for attempt = 1, 3 do
			if player.Parent ~= Players then
				return
			end
			local sent = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { player })
			end)
			if sent then
				return
			end
			task.wait(attempt * 3)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------------
function CrossServerService.GetStats(): any
	return {
		PeakPlayers = peak.Players,
		PeakServers = peak.Servers,
		PeakAt = peak.At,
		Bus = table.clone(node.Stats),
		RegistryError = registryError,
		Live = live,
		Studio = studio,
	}
end

-- ---------------------------------------------------------------------------
-- Startup (running game only)
-- ---------------------------------------------------------------------------
if not live then
	return CrossServerService
end

node:Start()

-- Global state + peak: read once at boot.
task.spawn(function()
	local ok, state = pcall(function()
		return (store :: DataStore):GetAsync(KEY_STATE)
	end)
	if ok and type(state) == "table" and type(state.Lockdown) == "table" and state.Lockdown.On == true then
		local lockdown = state.Lockdown
		CrossServerService.ApplyLockdown(true, lockdown.By, lockdown.Reason, lockdown.At)
		print(("[Sentinel] Global lockdown is active (set by %s) - this server is locked."):format(tostring(lockdown.By)))
	elseif not ok then
		warn("[Sentinel.CrossServerService] global state load failed: " .. tostring(state))
	end
	local okStats, stats = pcall(function()
		return (store :: DataStore):GetAsync(KEY_STATS)
	end)
	if okStats and type(stats) == "table" and (tonumber(stats.Players) or 0) > peak.Players then
		peak = { Players = tonumber(stats.Players) or 0, Servers = tonumber(stats.Servers) or 0, At = tonumber(stats.At) or 0 }
	end
end)

-- Heartbeat: on a timer, and shortly after anyone joins or leaves so
-- "find player" stays accurate.
local heartbeatQueued = false
local function heartbeatSoon()
	if heartbeatQueued then
		return
	end
	heartbeatQueued = true
	task.delay(3, function()
		heartbeatQueued = false
		writeHeartbeat()
		cachedAt = -math.huge
	end)
end

task.spawn(function()
	while true do
		writeHeartbeat()
		if peakDirty then
			peakDirty = false
			local snapshot = table.clone(peak)
			pcall(function()
				(store :: DataStore):UpdateAsync(KEY_STATS, function(old)
					if type(old) == "table" and (tonumber(old.Players) or 0) >= snapshot.Players then
						return nil -- another server already recorded a higher peak
					end
					return snapshot
				end)
			end)
		end
		task.wait(HEARTBEAT)
	end
end)

Players.PlayerAdded:Connect(function(player: Player)
	heartbeatSoon()
	bounceBack(player)
end)
Players.PlayerRemoving:Connect(heartbeatSoon)
for _, player in ipairs(Players:GetPlayers()) do
	bounceBack(player)
end

-- Leave the registry right away instead of waiting for the record to expire.
game:BindToClose(function()
	pcall(function()
		(registryMap :: MemoryStoreSortedMap):RemoveAsync(serverId)
	end)
end)

return CrossServerService
