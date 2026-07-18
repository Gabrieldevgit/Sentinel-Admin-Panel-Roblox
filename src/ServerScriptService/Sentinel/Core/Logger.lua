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

function Logger.Write(partial: {
	Executor: string?,
	ExecutorName: string?,
	Command: string,
	Arguments: { string }?,
	Target: string?,
	Result: ("Success" | "Failure" | "Denied")?,
	Severity: Types.LogSeverity?,
	Message: string?,
	ExecutionTimeMs: number?,
})
	local entry: LogEntry = {
		Timestamp = os.time(),
		Executor = partial.Executor or "SYSTEM",
		ExecutorName = partial.ExecutorName or "SYSTEM",
		Command = partial.Command,
		Arguments = partial.Arguments or {},
		Target = partial.Target,
		Result = partial.Result or "Success",
		Server = game.JobId,
		ExecutionTimeMs = partial.ExecutionTimeMs or 0,
		Severity = partial.Severity or "Info",
		Message = partial.Message,
	}

	table.insert(buffer, entry)
	pushRecent(entry)
	EventBus.Publish("Log.Written", entry)

	if #buffer >= MAX_BUFFER_BEFORE_FORCE_FLUSH then
		Logger.Flush()
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
	Player: string?,
	Command: string?,
	Moderator: string?,
	Server: string?,
	Since: number?,
	Until: number?,
}

function Logger.Query(filter: LogQueryFilter?): { LogEntry }
	if not filter then
		return recent
	end

	local results = {}
	for _, entry in ipairs(recent) do
		if filter.Player and entry.Target ~= filter.Player then
			continue
		end
		if filter.Command and entry.Command ~= filter.Command then
			continue
		end
		if filter.Moderator and entry.ExecutorName ~= filter.Moderator then
			continue
		end
		if filter.Server and entry.Server ~= filter.Server then
			continue
		end
		if filter.Since and entry.Timestamp < filter.Since then
			continue
		end
		if filter.Until and entry.Timestamp > filter.Until then
			continue
		end
		table.insert(results, entry)
	end
	return results
end

-- Periodic flush loop. Uses task.spawn once; never polls per-frame.
task.spawn(function()
	while true do
		task.wait(FLUSH_INTERVAL_SECONDS)
		Logger.Flush()
	end
end)

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
