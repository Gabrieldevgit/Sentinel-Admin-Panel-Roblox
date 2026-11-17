--!strict
--[[
	Logger.lua

	Purpose:
		Single entry point for every administrative log line in Sentinel
		(chat, commands, bans, joins/leaves, purchases, economy, exploit
		detections, errors, staff actions). Buffers writes and flushes them
		in batches so DataStore/analytics sinks are never hit synchronously
		on the command execution path.

	Responsibilities:
		- Accept structured LogEntry records
		- Buffer + batch-flush to registered sinks (DataStore, webhook, etc.)
		- Provide in-memory recent-log queries for the admin UI before a
		  full DataStore-backed search system (Phase 6) exists

	Dependencies:
		Types.lua (ReplicatedStorage.Shared.Sentinel)
		EventBus.lua (publishes "Log.Written" for anything that wants to
		  react live, e.g. a Discord webhook plugin)

	Public API:
		Logger.Write(entry: Partial<LogEntry>): ()
		Logger.RegisterSink(fn: (entries: {LogEntry}) -> ()): ()
		Logger.Query(filter): {LogEntry}
		Logger.Flush(): ()

	Example usage:
		Logger.Write({
			Executor = tostring(admin.UserId),
			ExecutorName = admin.Name,
			Command = "ban",
			Arguments = {"Player1", "30m", "Exploiting"},
			Target = "Player1",
			Result = "Success",
			Severity = "Warning",
		})
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

type LogEntry = Types.LogEntry

local Logger = {}

local FLUSH_INTERVAL_SECONDS = 5
local MAX_BUFFER_BEFORE_FORCE_FLUSH = 200
local MAX_RECENT_IN_MEMORY = 2000

local buffer: { LogEntry } = {}
local recent: { LogEntry } = {} -- ring buffer for fast in-memory search
local sinks: { (entries: { LogEntry }) -> () } = {}

local function pushRecent(entry: LogEntry)
	table.insert(recent, entry)
	if #recent > MAX_RECENT_IN_MEMORY then
		table.remove(recent, 1)
	end
end

-- W10: every entry gets a unique id ("<server short id>-<sequence>") and
-- the server id CrossServerService assigns (Studio has no JobId).
local serverId = game.JobId
local serverShort = if game.JobId ~= "" then game.JobId:sub(1, 8) else "local"
local sequence = 0

function Logger.SetServerId(id: string, short: string?)
	serverId = id
	serverShort = short or id:sub(1, 8)
end

function Logger.GetServerId(): string
	return serverId
end

local MAX_TEXT = 300

local function clip(v: any, max: number?): string?
	if v == nil then
		return nil
	end
	local text = tostring(v)
	local limit = max or MAX_TEXT
	if #text > limit then
		text = text:sub(1, limit - 3) .. "..."
	end
	return text
end
Logger.Clip = clip

function Logger.Write(partial: {
	Executor: string?,
	ExecutorName: string?,
	Command: string,
	Action: string?,
	RawInput: string?,
	Arguments: { string }?,
	Target: string?,
	TargetIds: { number }?,
	Reason: string?,
	Result: ("Success" | "Failure" | "Denied" | "Cancelled")?,
	Severity: Types.LogSeverity?,
	Message: string?,
	ExecutionTimeMs: number?,
	Changes: { Types.AuditChange }?,
	Source: string?,
	Timestamp: number?,
})
	sequence += 1
	local args = {}
	for i, a in ipairs(partial.Arguments or {}) do
		if i > 20 then
			break
		end
		args[i] = clip(a, 100) :: string
	end
	local changes: { Types.AuditChange }? = nil
	if partial.Changes and #partial.Changes > 0 then
		local list = {}
		for i, c in ipairs(partial.Changes) do
			if i > 25 then
				break
			end
			list[i] = {
				Target = clip(c.Target, 60),
				Field = clip(c.Field, 60) or "?",
				Before = clip(c.Before, 120),
				After = clip(c.After, 120),
			}
		end
		changes = list
	end
	local entry: LogEntry = {
		Id = ("%s-%d"):format(serverShort, sequence),
		Timestamp = partial.Timestamp or os.time(),
		Executor = partial.Executor or "SYSTEM",
		ExecutorName = partial.ExecutorName or "SYSTEM",
		Command = partial.Command,
		Action = partial.Action or partial.Command,
		RawInput = clip(partial.RawInput),
		Arguments = args,
		Target = clip(partial.Target, 400),
		TargetIds = partial.TargetIds,
		Reason = clip(partial.Reason, 200),
		Result = partial.Result or "Success",
		Server = serverId,
		ExecutionTimeMs = math.floor((partial.ExecutionTimeMs or 0) * 100 + 0.5) / 100,
		Severity = partial.Severity or "Info",
		Message = clip(partial.Message),
		Changes = changes,
		Source = partial.Source,
	}

	table.insert(buffer, entry)
	pushRecent(entry)
	EventBus.Publish("Log.Written", entry)

	if #buffer >= MAX_BUFFER_BEFORE_FORCE_FLUSH then
		Logger.Flush()
	end
	return entry
end

-- W10 data modification history. A running command opens a change scope
-- (Systems/AuditService's middleware); NoteChange inside it attaches the
-- before/after value to that command's log line. Outside a scope it
-- becomes its own "data.change" entry.
local scopes: { [thread]: { any } } = {}

function Logger.BeginChangeScope(): ({ any }, () -> ())
	local thread = coroutine.running()
	local outer = scopes[thread]
	local scope = {}
	scopes[thread] = scope
	return scope, function()
		scopes[thread] = outer
	end
end

local function display(v: any): string
	if v == nil then
		return "(none)"
	end
	if type(v) == "number" and v % 1 ~= 0 then
		return ("%.2f"):format(v)
	end
	if type(v) == "table" then
		local ok, json = pcall(function()
			return game:GetService("HttpService"):JSONEncode(v)
		end)
		return if ok then json else "(table)"
	end
	return tostring(v)
end

function Logger.NoteChange(target: string?, field: string, before: any, after: any, actor: Player?, action: string?)
	local change = { Target = target, Field = field, Before = display(before), After = display(after) }
	if change.Before == change.After then
		return
	end
	local scope = scopes[coroutine.running()]
	if scope then
		table.insert(scope, change)
		return
	end
	Logger.Write({
		Executor = if actor then tostring(actor.UserId) else "SYSTEM",
		ExecutorName = if actor then actor.Name else "SYSTEM",
		Command = action or "data.change",
		Target = target,
		Result = "Success",
		Severity = "Info",
		Message = field .. " changed",
		Changes = { change :: any },
	})
end

-- W08 admin config "LogRetentionDays": entries older than this are dropped
-- from the in-memory log. Systems/AuditService prunes the persistent store
-- with the same value.
local retentionSeconds: number? = nil

function Logger.SetRetentionDays(days: number?)
	retentionSeconds = if type(days) == "number" and days > 0 then days * 86400 else nil
end

function Logger.GetRetentionDays(): number?
	return if retentionSeconds then retentionSeconds / 86400 else nil
end

function Logger.Prune(now: number?)
	if not retentionSeconds then
		return
	end
	local cutoff = (now or os.time()) - retentionSeconds
	local first = 1
	while recent[first] and recent[first].Timestamp < cutoff do
		first += 1
	end
	if first > 1 then
		local kept = table.move(recent, first, #recent, 1, {})
		table.clear(recent)
		table.move(kept, 1, #kept, 1, recent)
	end
end

function Logger.RegisterSink(fn: (entries: { LogEntry }) -> ())
	table.insert(sinks, fn)
end

function Logger.Flush()
	if #buffer == 0 then
		return
	end
	local toFlush = buffer
	buffer = {}

	for _, sink in ipairs(sinks) do
		task.spawn(function()
			local ok, err = pcall(sink, toFlush)
			if not ok then
				warn(("[Sentinel.Logger] sink error: %s"):format(tostring(err)))
			end
		end)
	end
end

export type LogQueryFilter = {
	Player: string?, -- target name (exact, any of a multi-target entry) or UserId
	Command: string?, -- exact command name
	Moderator: string?, -- executor name (case-insensitive prefix) or UserId
	Server: string?, -- server id or prefix
	Since: number?,
	Until: number?,
	-- W10 additions
	Action: string?, -- "moderation" matches every "moderation.*" action
	Severity: string?, -- exact, or "Warning+" for Warning and above
	Result: string?, -- Success | Failure | Denied | Cancelled | "Failed" (= not Success)
	Text: string?, -- case-insensitive search in input, message, reason, targets
	HasChanges: boolean?, -- only entries with before/after values
}

local SEVERITY_RANK = { Info = 1, Warning = 2, Error = 3, Critical = 4 }
Logger.SeverityRank = SEVERITY_RANK

local function lower(v: any): string
	return if type(v) == "string" then v:lower() else ""
end

local function hasTarget(entry: LogEntry, wanted: string): boolean
	local id = tonumber(wanted)
	if id and entry.TargetIds and table.find(entry.TargetIds, id) then
		return true
	end
	local w = wanted:lower()
	if entry.Target then
		for name in entry.Target:gmatch("[^,]+") do
			if name:lower() == w then
				return true
			end
		end
	end
	if entry.Changes then
		for _, c in ipairs(entry.Changes) do
			if c.Target and c.Target:lower() == w then
				return true
			end
		end
	end
	return false
end

-- True when the entry passes every field of the filter. Shared by the
-- in-memory query and the persistent AuditService search.
function Logger.Matches(entry: LogEntry, filter: LogQueryFilter?): boolean
	if not filter then
		return true
	end
	if filter.Player and not hasTarget(entry, filter.Player) then
		return false
	end
	if filter.Command and lower(entry.Command) ~= filter.Command:lower() then
		return false
	end
	if filter.Moderator then
		local m = filter.Moderator:lower()
		if entry.Executor ~= filter.Moderator and lower(entry.ExecutorName):sub(1, #m) ~= m then
			return false
		end
	end
	if filter.Server and (entry.Server or ""):sub(1, #filter.Server) ~= filter.Server then
		return false
	end
	if filter.Since and entry.Timestamp < filter.Since then
		return false
	end
	if filter.Until and entry.Timestamp > filter.Until then
		return false
	end
	if filter.Action then
		-- Matches a whole dot-separated part ("config" matches "config.set"
		-- and "server.config"); commas give alternatives ("rank,ranks").
		local padded = "." .. lower(entry.Action or entry.Command) .. "."
		local any = false
		for want in filter.Action:lower():gmatch("[^,%s]+") do
			if padded:find("." .. want .. ".", 1, true) then
				any = true
				break
			end
		end
		if not any then
			return false
		end
	end
	if filter.Severity then
		local min = filter.Severity:match("^(%a+)%+$")
		if min then
			if (SEVERITY_RANK[entry.Severity] or 1) < (SEVERITY_RANK[min] or 1) then
				return false
			end
		elseif entry.Severity ~= filter.Severity then
			return false
		end
	end
	if filter.Result then
		if filter.Result == "Failed" then
			if entry.Result == "Success" then
				return false
			end
		elseif entry.Result ~= filter.Result then
			return false
		end
	end
	if filter.HasChanges and not (entry.Changes and #entry.Changes > 0) then
		return false
	end
	if filter.Text and filter.Text ~= "" then
		local t = filter.Text:lower()
		local hay = table.concat({
			lower(entry.RawInput), lower(entry.Message), lower(entry.Reason), lower(entry.Target),
			lower(entry.Command), lower(entry.ExecutorName),
		}, " | ")
		if not hay:find(t, 1, true) then
			return false
		end
	end
	return true
end

function Logger.Query(filter: LogQueryFilter?): { LogEntry }
	if not filter then
		return recent
	end
	local results = {}
	for _, entry in ipairs(recent) do
		if Logger.Matches(entry, filter) then
			table.insert(results, entry)
		end
	end
	return results
end

-- Periodic flush loop. Uses task.spawn once; never polls per-frame. Not
-- started outside a running game (Edit-mode tests), where it would leak.
if RunService:IsRunning() then
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL_SECONDS)
			Logger.Flush()
			Logger.Prune()
		end
	end)
end

if RunService:IsStudio() then
	Logger.RegisterSink(function(entries)
		for _, entry in ipairs(entries) do
			print(("[Sentinel] %s %s -> %s (%s)"):format(
				entry.ExecutorName, entry.Command, entry.Target or "-", entry.Result
			))
		end
	end)
end

return Logger
