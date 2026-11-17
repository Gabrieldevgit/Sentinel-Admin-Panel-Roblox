--!strict
--[[
	AuditService.lua (W10)

	Purpose:
		Persistent, searchable audit log on top of Core/Logger. Every
		Logger.Write entry (commands, denied / failed / cancelled actions,
		rank changes, config changes, cross-server actions, rate limits) is
		stored in paged DataStore records shared by every server, and kept
		for the admin-configured retention (`;config logretention`).

	Storage:
		DataStore        Sentinel_Audit_v1       key = page key, value =
		                                         { V = 1, S = serverId, E = { LogEntry } }
		OrderedDataStore Sentinel_AuditIndex_v1  key = page key, value =
		                                         newest timestamp in the page
		A page holds up to PAGE_SIZE entries from ONE server and is written
		once (no UpdateAsync contention between servers). Search walks the
		index newest-first and reads pages; retention removes pages whose
		newest entry is older than the cutoff.

	Before / after values:
		A command middleware snapshots each target before and after the
		command runs and records what changed (leaderstats for Economy,
		humanoid stats + Sentinel attributes for Player / Movement / Effects,
		...). A command picks its own with `def.Audit`:
			Audit = false                      -- no snapshot
			Audit = { "leaderstats", "backpack" } -- presets (SNAPSHOTS below)
			Audit = function(player) return { Field = "value" } end
		Systems record data changes with AuditService.NoteChange(...); inside
		a running command the change is attached to that command's log line,
		otherwise it becomes its own "data.change" entry.

	Public API:
		AuditService.NoteChange(target, field, before, after, actor?, action?)
		AuditService.Search(filter, cursor?, limit?) -> { Entries, Cursor?, Scanned, Persistent }
		AuditService.Flush() -> boolean           (writes pending pages now)
		AuditService.Prune(now?) -> number         (pages removed)
		AuditService.GetStatus() -> { ... }
		AuditService.Snapshot(def, player) -> { [field]: string }  (exposed for tests)
		AuditService.Diff(before, after, targetName) -> { AuditChange }

	Outside a running game (unit tests) nothing touches the DataStore.
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Logger = require(Core:WaitForChild("Logger"))
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))

local AuditService = {}

local PAGE_SIZE = 100
local FLUSH_INTERVAL = 30
local MAX_PAGES_PER_SEARCH = 6
local PRUNE_INTERVAL = 30 * 60
local PRUNE_BATCH = 50
local MAX_PENDING = 5000

local live = RunService:IsRunning() and RunService:IsServer()
local store: DataStore? = nil
local index: OrderedDataStore? = nil
if live then
	local ok = pcall(function()
		store = DataStoreService:GetDataStore("Sentinel_Audit_v1")
		index = DataStoreService:GetOrderedDataStore("Sentinel_AuditIndex_v1")
	end)
	if not ok then
		warn("[Sentinel.AuditService] DataStore unavailable - audit log stays in memory")
	end
end

local pending: { any } = {}
local pageSeq = 0
local status = {
	PagesWritten = 0,
	EntriesWritten = 0,
	PagesPruned = 0,
	LastFlush = 0,
	LastPrune = 0,
	LastError = nil :: string?,
	Dropped = 0,
}

-- ---------------------------------------------------------------------------
-- Before / after snapshots
-- ---------------------------------------------------------------------------
local function fmt(v: any): string
	if type(v) == "number" then
		if v % 1 == 0 then
			return tostring(v)
		end
		return ("%.2f"):format(v)
	end
	return tostring(v)
end

local SNAPSHOTS: { [string]: (Player) -> { [string]: string } } = {
	leaderstats = function(player)
		local out = {}
		local folder = player:FindFirstChild("leaderstats")
		if folder then
			for _, v in ipairs(folder:GetChildren()) do
				if v:IsA("ValueBase") then
					out[v.Name] = fmt((v :: any).Value)
				end
			end
		end
		return out
	end,
	humanoid = function(player)
		local out = {}
		local character = player.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum then
			out.WalkSpeed = fmt(hum.WalkSpeed)
			out.JumpPower = fmt(hum.JumpPower)
			out.MaxHealth = fmt(hum.MaxHealth)
			out.Health = fmt(math.floor(hum.Health + 0.5))
		end
		return out
	end,
	attributes = function(player)
		local out = {}
		for name, value in pairs(player:GetAttributes()) do
			if name:sub(1, 8) == "Sentinel" then
				out[name] = fmt(value)
			end
		end
		local character = player.Character
		if character then
			for name, value in pairs(character:GetAttributes()) do
				if name:sub(1, 8) == "Sentinel" then
					out["Character." .. name] = fmt(value)
				end
			end
		end
		return out
	end,
	backpack = function(player)
		local names = {}
		local function add(container: Instance?)
			if container then
				for _, tool in ipairs(container:GetChildren()) do
					if tool:IsA("Tool") then
						table.insert(names, tool.Name)
					end
				end
			end
		end
		add(player:FindFirstChildOfClass("Backpack"))
		add(player.Character)
		table.sort(names)
		return { Tools = if #names > 0 then table.concat(names, ", ") else "(none)" }
	end,
}
AuditService.Snapshots = SNAPSHOTS

local CATEGORY_PRESETS: { [string]: { string } } = {
	Economy = { "leaderstats" },
	Inventory = { "backpack" },
	Player = { "humanoid", "attributes" },
	Movement = { "humanoid", "attributes" },
	Effects = { "attributes" },
	Moderation = { "attributes" },
}

local function presetsFor(def: any): any
	if def.Audit == false then
		return nil
	end
	if type(def.Audit) == "function" or type(def.Audit) == "table" then
		return def.Audit
	end
	return CATEGORY_PRESETS[def.Category or ""]
end

function AuditService.Snapshot(def: any, player: Player): { [string]: string }
	local presets = presetsFor(def)
	local out = {}
	if type(presets) == "function" then
		local ok, result = pcall(presets, player)
		if ok and type(result) == "table" then
			for k, v in pairs(result) do
				out[tostring(k)] = fmt(v)
			end
		end
	elseif type(presets) == "table" then
		for _, name in ipairs(presets) do
			local fn = SNAPSHOTS[name]
			if fn then
				local ok, result = pcall(fn, player)
				if ok then
					for k, v in pairs(result) do
						out[k] = v
					end
				end
			end
		end
	end
	return out
end

function AuditService.Diff(before: { [string]: string }, after: { [string]: string }, targetName: string?): { any }
	local changes = {}
	local seen = {}
	for field, old in pairs(before) do
		seen[field] = true
		local new = after[field]
		if new ~= old then
			table.insert(changes, { Target = targetName, Field = field, Before = old, After = new or "(removed)" })
		end
	end
	for field, new in pairs(after) do
		if not seen[field] then
			table.insert(changes, { Target = targetName, Field = field, Before = "(none)", After = new })
		end
	end
	table.sort(changes, function(a, b)
		return a.Field < b.Field
	end)
	return changes
end

-- NoteChange lives in Core/Logger so Systems can record data changes
-- without requiring this module.
AuditService.NoteChange = Logger.NoteChange

local MAX_SNAPSHOT_TARGETS = 25

CommandRegistry.Use(function(def: any, ctx: any, nextFn: () -> any): any
	local targets = ctx.Targets or {}
	local before: { [Player]: { [string]: string } } = {}
	if presetsFor(def) and #targets <= MAX_SNAPSHOT_TARGETS then
		for _, p in ipairs(targets) do
			before[p] = AuditService.Snapshot(def, p)
		end
	end
	local scope, restore = Logger.BeginChangeScope()
	local ok, result = pcall(nextFn)
	restore()
	if not ok then
		error(result, 0)
	end
	if type(result) == "table" then
		local changes = {}
		for p, snap in pairs(before) do
			if p.Parent then
				for _, c in ipairs(AuditService.Diff(snap, AuditService.Snapshot(def, p), p.Name)) do
					table.insert(changes, c)
				end
			end
		end
		for _, c in ipairs(scope) do
			table.insert(changes, c)
		end
		if #changes > 0 then
			local existing = result.Changes
			if type(existing) == "table" then
				for _, c in ipairs(changes) do
					table.insert(existing, c)
				end
			else
				result.Changes = changes
			end
		end
	end
	return result
end, "Audit")

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------
Logger.RegisterSink(function(entries)
	for _, e in ipairs(entries) do
		table.insert(pending, e)
	end
	while #pending > MAX_PENDING do
		table.remove(pending, 1)
		status.Dropped += 1
	end
end)

local flushing = false

function AuditService.Flush(): boolean
	Logger.Flush()
	if not (store and index) or flushing then
		return false
	end
	flushing = true
	local allOk = true
	while #pending > 0 do
		-- Take the page out first: new entries keep arriving while the
		-- write yields. On failure the page goes back to the front.
		local count = math.min(PAGE_SIZE, #pending)
		local page = table.move(pending, 1, count, 1, {})
		local rest = table.move(pending, count + 1, #pending, 1, {})
		table.clear(pending)
		table.move(rest, 1, #rest, 1, pending)
		local newest = 0
		for _, e in ipairs(page) do
			newest = math.max(newest, e.Timestamp or 0)
		end
		pageSeq += 1
		local key = ("%d_%s_%d"):format(page[1].Timestamp or os.time(), Logger.GetServerId():sub(1, 15), pageSeq)
		local ok, err = pcall(function()
			(store :: DataStore):SetAsync(key, { V = 1, S = Logger.GetServerId(), E = page })
			;(index :: OrderedDataStore):SetAsync(key, newest)
		end)
		if not ok then
			status.LastError = tostring(err)
			warn("[Sentinel.AuditService] page write failed (will retry): " .. tostring(err))
			allOk = false
			local merged = table.move(pending, 1, #pending, #page + 1, page)
			table.clear(pending)
			table.move(merged, 1, #merged, 1, pending)
			break
		end
		status.PagesWritten += 1
		status.EntriesWritten += count
	end
	status.LastFlush = os.time()
	flushing = false
	return allOk
end

function AuditService.Prune(now: number?): number
	local days = Logger.GetRetentionDays()
	if not (store and index) or not days then
		return 0
	end
	local cutoff = math.floor((now or os.time()) - days * 86400)
	local removed = 0
	local ok, err = pcall(function()
		local pages = (index :: OrderedDataStore):GetSortedAsync(true, PRUNE_BATCH, nil, cutoff)
		for _, item in ipairs(pages:GetCurrentPage()) do
			(store :: DataStore):RemoveAsync(item.key)
			;(index :: OrderedDataStore):RemoveAsync(item.key)
			removed += 1
		end
	end)
	if not ok then
		status.LastError = tostring(err)
		warn("[Sentinel.AuditService] prune failed: " .. tostring(err))
	end
	status.PagesPruned += removed
	status.LastPrune = os.time()
	return removed
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------
export type Cursor = { Max: number, Seen: { string } }

local function sanitizeCursor(c: any): Cursor?
	if type(c) ~= "table" or type(c.Max) ~= "number" or c.Max ~= c.Max then
		return nil
	end
	local seen = {}
	if type(c.Seen) == "table" then
		for i, k in ipairs(c.Seen) do
			if i > 200 then
				break
			end
			if type(k) == "string" and #k <= 60 then
				table.insert(seen, k)
			end
		end
	end
	return { Max = math.floor(c.Max), Seen = seen }
end

local function newestFirst(a: any, b: any): boolean
	if a.Timestamp ~= b.Timestamp then
		return a.Timestamp > b.Timestamp
	end
	return (a.Id or "") > (b.Id or "")
end

-- Returns matches newest first. The first call (no cursor) includes this
-- server's entries that are not persisted yet. Pass the returned Cursor to
-- get older entries; Cursor is nil when nothing older is left.
function AuditService.Search(filter: any, cursorIn: any, limit: number?): { [string]: any }
	local want = math.clamp(tonumber(limit) or 50, 1, 200)
	local cursor = sanitizeCursor(cursorIn)
	local results = {}
	local ids: { [string]: boolean } = {}

	local function consider(e: any)
		if e and Logger.Matches(e, filter) and not (e.Id and ids[e.Id]) then
			if e.Id then
				ids[e.Id] = true
			end
			table.insert(results, e)
		end
	end

	if not (store and index) then
		-- Not persistent (tests / no DataStore): search the in-memory log.
		local all = Logger.Query(nil)
		for i = #all, 1, -1 do
			consider(all[i])
		end
		table.sort(results, newestFirst)
		local total = #results
		local skip = if cursor then cursor.Max else 0
		local page = table.move(results, skip + 1, math.min(total, skip + want), 1, {})
		return {
			Entries = page,
			Cursor = if skip + want < total then { Max = skip + want, Seen = {} } else nil,
			Scanned = 0,
			Persistent = false,
		}
	end

	if not cursor then
		Logger.Flush()
		for i = #pending, 1, -1 do
			consider(pending[i])
		end
	end

	local seen: { [string]: boolean } = {}
	for _, k in ipairs(if cursor then cursor.Seen else {}) do
		seen[k] = true
	end
	local lastValue: number? = if cursor then cursor.Max else nil
	local seenAtLast: { string } = if cursor then table.clone(cursor.Seen) else {}
	local scanned = 0
	local exhausted = false

	local ok, err = pcall(function()
		local minValue = if filter and type(filter.Since) == "number" then math.floor(filter.Since) else nil
		local pages = (index :: OrderedDataStore):GetSortedAsync(false, 25, minValue, lastValue)
		while true do
			local items = pages:GetCurrentPage()
			for _, item in ipairs(items) do
				if not seen[item.key] then
					if #results >= want or scanned >= MAX_PAGES_PER_SEARCH then
						return
					end
					local data = (store :: DataStore):GetAsync(item.key)
					scanned += 1
					seen[item.key] = true
					if item.value ~= lastValue then
						lastValue = item.value
						seenAtLast = {}
					end
					table.insert(seenAtLast, item.key)
					if type(data) == "table" and type(data.E) == "table" then
						for i = #data.E, 1, -1 do
							consider(data.E[i])
						end
					end
				end
			end
			if pages.IsFinished then
				exhausted = true
				return
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	if not ok then
		status.LastError = tostring(err)
		warn("[Sentinel.AuditService] search failed: " .. tostring(err))
	end

	table.sort(results, newestFirst)
	return {
		Entries = results,
		-- No page read yet (this server's unsaved entries filled the page):
		-- the next call starts at the newest page.
		Cursor = if exhausted or not ok then nil else { Max = lastValue or (os.time() + 86400), Seen = seenAtLast },
		Scanned = scanned,
		Persistent = true,
		Error = if ok then nil else "The audit store could not be read right now.",
	}
end

-- ---------------------------------------------------------------------------
-- Query text -> filter ("mod:Alice cmd:ban since:2d sev:warning+ spam")
-- ---------------------------------------------------------------------------
local KEYS: { [string]: string } = {
	mod = "Moderator", moderator = "Moderator", by = "Moderator", staff = "Moderator",
	player = "Player", target = "Player", p = "Player",
	cmd = "Command", command = "Command",
	action = "Action", cat = "Action", category = "Action",
	sev = "Severity", severity = "Severity",
	result = "Result", status = "Result",
	server = "Server", job = "Server",
	since = "Since", after = "Since",
	["until"] = "Until", before = "Until",
}
local RESULTS = { success = "Success", failure = "Failure", failed = "Failed", denied = "Denied", cancelled = "Cancelled" }
local SEVERITIES = { info = "Info", warning = "Warning", error = "Error", critical = "Critical" }
AuditService.QueryKeys = KEYS

local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))

-- "2d" / "3h" -> now minus that; "2026-11-17" -> that day (UTC); a number
-- is a unix time.
local function parseTime(text: string, endOfDay: boolean): number?
	local n = tonumber(text)
	if n then
		return n
	end
	local y, m, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
	if y then
		local t = os.time({ year = tonumber(y) :: number, month = tonumber(m) :: number, day = tonumber(d) :: number, hour = 0 })
		return if endOfDay then t + 86399 else t
	end
	local parsed = DurationParser.Parse(text)
	if parsed and not parsed.IsPermanent then
		return os.time() - parsed.Seconds
	end
	return nil
end

function AuditService.ParseQuery(text: string?): (any, string?)
	local filter: { [string]: any } = {}
	local free = {}
	for word in (text or ""):gmatch("%S+") do
		local key, value = word:match("^(%a+):(.+)$")
		local field = key and KEYS[key:lower()]
		if key and key:lower() == "has" and value and value:lower() == "changes" then
			filter.HasChanges = true
		elseif field and value then
			if field == "Since" or field == "Until" then
				local t = parseTime(value, field == "Until")
				if not t then
					return nil, ("Can't read the time '%s' (try 2h, 3d or 2026-11-17)."):format(value)
				end
				filter[field] = t
			elseif field == "Result" then
				local r = RESULTS[value:lower()]
				if not r then
					return nil, "result: success, failed, failure, denied or cancelled."
				end
				filter.Result = r
			elseif field == "Severity" then
				local plus = value:sub(-1) == "+"
				local sev = SEVERITIES[(if plus then value:sub(1, -2) else value):lower()]
				if not sev then
					return nil, "sev: info, warning, error or critical (add + for 'and above')."
				end
				filter.Severity = sev .. (if plus then "+" else "")
			else
				filter[field] = value:sub(1, 100)
			end
		else
			table.insert(free, word)
		end
	end
	if #free > 0 then
		filter.Text = table.concat(free, " "):sub(1, 100)
	end
	return filter
end

-- Validates a filter table that came from a client.
function AuditService.SanitizeFilter(raw: any): any
	if type(raw) ~= "table" then
		return {}
	end
	local clean = {}
	for _, key in ipairs({ "Player", "Command", "Moderator", "Server", "Action", "Text" }) do
		local v = raw[key]
		if type(v) == "string" and #v > 0 and #v <= 100 then
			clean[key] = v
		end
	end
	if type(raw.Severity) == "string" then
		local base = raw.Severity:gsub("%+$", "")
		if SEVERITIES[base:lower()] then
			clean.Severity = raw.Severity
		end
	end
	if type(raw.Result) == "string" then
		for _, r in pairs(RESULTS) do
			if r == raw.Result then
				clean.Result = r
			end
		end
	end
	if raw.HasChanges == true then
		clean.HasChanges = true
	end
	for _, key in ipairs({ "Since", "Until" }) do
		local v = raw[key]
		if type(v) == "number" and v == v and v > 0 and v < 1e11 then
			clean[key] = v
		end
	end
	return clean
end

-- One-line text form of an entry (chat output, export).
function AuditService.FormatEntry(e: any): string
	local line = ("[%s] %s %s"):format(
		os.date("!%Y-%m-%d %H:%M:%S", e.Timestamp or 0),
		tostring(e.ExecutorName or "?"),
		if e.RawInput then ";" .. e.RawInput else tostring(e.Command)
	)
	if e.Target and e.Target ~= "" and not e.RawInput then
		line ..= " -> " .. e.Target
	end
	line ..= (" | %s"):format(tostring(e.Result))
	if e.Reason then
		line ..= (" | reason: %s"):format(e.Reason)
	end
	if e.Result ~= "Success" and e.Message then
		line ..= (" | %s"):format(e.Message)
	end
	if type(e.Changes) == "table" and #e.Changes > 0 then
		local parts = {}
		for i, c in ipairs(e.Changes) do
			if i > 4 then
				table.insert(parts, ("+%d more"):format(#e.Changes - 4))
				break
			end
			table.insert(parts, ("%s%s %s->%s"):format(
				if c.Target then c.Target .. "." else "", tostring(c.Field), tostring(c.Before), tostring(c.After)
			))
		end
		line ..= " | " .. table.concat(parts, ", ")
	end
	return line
end

function AuditService.GetStatus(): { [string]: any }
	return {
		Persistent = store ~= nil and index ~= nil,
		Pending = #pending,
		PagesWritten = status.PagesWritten,
		EntriesWritten = status.EntriesWritten,
		PagesPruned = status.PagesPruned,
		LastFlush = status.LastFlush,
		LastPrune = status.LastPrune,
		LastError = status.LastError,
		Dropped = status.Dropped,
		RetentionDays = Logger.GetRetentionDays(),
		ServerId = Logger.GetServerId(),
	}
end

if live and store and index then
	task.spawn(function()
		local sincePrune = PRUNE_INTERVAL - 120 -- first prune two minutes in
		while true do
			task.wait(FLUSH_INTERVAL)
			AuditService.Flush()
			sincePrune += FLUSH_INTERVAL
			if sincePrune >= PRUNE_INTERVAL then
				sincePrune = 0
				AuditService.Prune()
			end
		end
	end)
	game:BindToClose(function()
		AuditService.Flush()
	end)
	Players.PlayerRemoving:Connect(function()
		if #Players:GetPlayers() <= 1 then
			task.defer(AuditService.Flush)
		end
	end)
end

return AuditService
