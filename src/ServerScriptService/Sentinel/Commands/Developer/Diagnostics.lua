--!strict
--[[
	Diagnostics.lua

	Purpose:
		Registers the Developer Suite commands: /serverstats, /pingview,
		/errorconsole, /remotelog, /datastoreget, /datastoreset,
		/datastorelist, /execute.

	IMPORTANT — permission model for this file:
		/datastoreset and /execute can corrupt persisted data or run
		arbitrary game code respectively. They use permission nodes
		("developer.datastore.write", "developer.execute") that are
		deliberately NOT included in the Admin role's wildcard grants in
		init.server.lua — only Owner (which grants "*") has them by
		default. Read-only tools (/serverstats, /pingview, /errorconsole,
		/remotelog, /datastoreget, /datastorelist) ARE included for Admins.
		If you want a specific Admin to have the dangerous ones, grant the
		node directly with PermissionSystem.GrantTemporary or a custom role
		rather than changing the Admin wildcard.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		DeveloperService.lua (Systems)
--]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local DeveloperService = require(Sentinel:WaitForChild("Systems"):WaitForChild("DeveloperService"))

CommandRegistry.Register({
	Name = "serverstats",
	Aliases = { "stats" },
	Description = "Shows server uptime, heartbeat rate, memory, and player count.",
	Usage = "/serverstats",
	Permission = "developer.stats",
	Category = "Developer",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		local stats = DeveloperService.GetServerStats()
		return {
			Success = true,
			Message = ("Uptime: %ds | Heartbeat: %d/s | Memory: %dMB | Players: %d"):format(
				stats.UptimeSeconds, stats.HeartbeatRate, stats.MemoryMb, stats.PlayerCount
			),
		}
	end,
})

CommandRegistry.Register({
	Name = "pingview",
	Aliases = { "ping" },
	Description = "Shows a player's ping in milliseconds.",
	Usage = "/pingview target",
	Permission = "developer.stats",
	Category = "Developer",
	Log = false,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local lines = {}
		for _, target in ipairs(ctx.Targets) do
			table.insert(lines, ("%s: %dms"):format(target.Name, DeveloperService.GetPing(target)))
		end
		return { Success = true, Message = table.concat(lines, " | ") }
	end,
})

CommandRegistry.Register({
	Name = "errorconsole",
	Aliases = { "errors" },
	Description = "Shows the most recent server errors/warnings.",
	Usage = "/errorconsole [count]",
	Permission = "developer.console",
	Category = "Developer",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local count = tonumber(ctx.Arguments[1]) or 10
		local logs = DeveloperService.GetRecentLogs(count)
		if #logs == 0 then
			return { Success = true, Message = "No recent errors or warnings." }
		end
		local lines = {}
		for _, entry in ipairs(logs) do
			table.insert(lines, ("[%s] %s"):format(entry.MessageType.Name, entry.Message))
		end
		return { Success = true, Message = table.concat(lines, " | ") }
	end,
})

CommandRegistry.Register({
	Name = "remotelog",
	Aliases = {},
	Description = "Shows the most recent RemoteEvent calls made to the server.",
	Usage = "/remotelog [count]",
	Permission = "developer.remotemonitor",
	Category = "Developer",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local count = tonumber(ctx.Arguments[1]) or 10
		local calls = DeveloperService.GetRecentRemoteCalls(count)
		if #calls == 0 then
			return { Success = true, Message = "No recent remote calls recorded." }
		end
		local lines = {}
		for _, entry in ipairs(calls) do
			table.insert(lines, ("%s (%s) by %s"):format(entry.Path, entry.Kind, entry.PlayerName))
		end
		return { Success = true, Message = table.concat(lines, " | ") }
	end,
})

CommandRegistry.Register({
	Name = "datastoreget",
	Aliases = {},
	Description = "Reads a key's raw value from a DataStore.",
	Usage = "/datastoreget storeName key",
	Permission = "developer.datastore.read",
	Category = "Developer",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local storeName, key = ctx.Arguments[1], ctx.Arguments[2]
		if not storeName or not key then
			return { Success = false, Message = "Usage: /datastoreget storeName key" }
		end
		local ok, value = pcall(function()
			return DataStoreService:GetDataStore(storeName):GetAsync(key)
		end)
		if not ok then
			return { Success = false, Message = ("DataStore error: %s"):format(tostring(value)) }
		end
		if value == nil then
			return { Success = true, Message = "(no value for that key)" }
		end
		local encodeOk, json = pcall(function()
			return HttpService:JSONEncode(value)
		end)
		return { Success = true, Message = if encodeOk then json else tostring(value) }
	end,
})

CommandRegistry.Register({
	Name = "datastoreset",
	Aliases = {},
	Description = "Writes a JSON value to a DataStore key. DANGEROUS — can overwrite live player data.",
	Usage = "/datastoreset storeName key jsonValue",
	Permission = "developer.datastore.write",
	Category = "Developer",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local storeName, key = ctx.Arguments[1], ctx.Arguments[2]
		if not storeName or not key or #ctx.Arguments < 3 then
			return { Success = false, Message = "Usage: /datastoreset storeName key jsonValue" }
		end
		local jsonText = table.concat(ctx.Arguments, " ", 3)
		local decodeOk, value = pcall(function()
			return HttpService:JSONDecode(jsonText)
		end)
		if not decodeOk then
			return { Success = false, Message = "Value must be valid JSON, e.g. 100 or \"text\" or {\"a\":1}." }
		end
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(storeName):SetAsync(key, value)
		end)
		if not ok then
			return { Success = false, Message = ("DataStore error: %s"):format(tostring(err)) }
		end
		return { Success = true, Message = ("Wrote key '%s' in store '%s'."):format(key, storeName) }
	end,
})

CommandRegistry.Register({
	Name = "datastorelist",
	Aliases = {},
	Description = "Lists keys in a DataStore (up to 50).",
	Usage = "/datastorelist storeName",
	Permission = "developer.datastore.read",
	Category = "Developer",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local storeName = ctx.Arguments[1]
		if not storeName then
			return { Success = false, Message = "Usage: /datastorelist storeName" }
		end
		local ok, result = pcall(function()
			local pages = DataStoreService:GetDataStore(storeName):ListKeysAsync()
			return pages:GetCurrentPage()
		end)
		if not ok then
			return { Success = false, Message = ("DataStore error: %s"):format(tostring(result)) }
		end
		local names = {}
		for i, keyInfo in ipairs(result) do
			if i > 50 then
				break
			end
			table.insert(names, keyInfo.KeyName)
		end
		if #names == 0 then
			return { Success = true, Message = "(no keys found)" }
		end
		return { Success = true, Message = table.concat(names, ", ") }
	end,
})

CommandRegistry.Register({
	Name = "execute",
	Aliases = { "run" },
	Description = "Requires a ModuleScript by name from ServerStorage.SentinelScripts. DANGEROUS — runs arbitrary server code.",
	Usage = "/execute moduleName",
	Permission = "developer.execute",
	Category = "Developer",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local moduleName = ctx.Arguments[1]
		if not moduleName then
			return { Success = false, Message = "Usage: /execute moduleName" }
		end
		local ServerStorage = game:GetService("ServerStorage")
		local folder = ServerStorage:FindFirstChild("SentinelScripts")
		if not folder then
			return { Success = false, Message = "No 'SentinelScripts' folder found in ServerStorage." }
		end
		local moduleScript = folder:FindFirstChild(moduleName)
		if not moduleScript or not moduleScript:IsA("ModuleScript") then
			return { Success = false, Message = ("No module named '%s' found."):format(moduleName) }
		end
		local ok, result = pcall(require, moduleScript)
		if not ok then
			return { Success = false, Message = ("Execution error: %s"):format(tostring(result)) }
		end
		return { Success = true, Message = ("Executed '%s'."):format(moduleName) }
	end,
})

return true
