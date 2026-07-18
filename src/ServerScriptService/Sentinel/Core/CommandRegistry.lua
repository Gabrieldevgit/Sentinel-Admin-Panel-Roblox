--!strict
--[[
	CommandRegistry.lua

	Purpose:
		The single source of truth for every command in Sentinel. Commands
		never get hardcoded into a giant switch statement — each command
		module calls CommandRegistry.Register(definition) on startup, and
		the registry builds the alias table, category index, and
		autocomplete index from that metadata automatically.

	Responsibilities:
		- Register command definitions + validate their shape
		- Resolve a name or alias to its CommandDefinition
		- Track per-player, per-command cooldowns
		- Expose category / autocomplete indexes for the UI (Phase 7)
		- Enforce permission + cooldown before executing, then log via
		  Logger and publish EventBus lifecycle events

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		PermissionSystem.lua, Logger.lua (Core)

	Public API:
		CommandRegistry.Register(def: CommandDefinition): ()
		CommandRegistry.Resolve(nameOrAlias: string): CommandDefinition?
		CommandRegistry.ListByCategory(category: string): {CommandDefinition}
		CommandRegistry.All(): {CommandDefinition}
		CommandRegistry.Dispatch(executor: Player, ctx: CommandContext): CommandResult

	Example usage:
		CommandRegistry.Register({
			Name = "kick",
			Aliases = {"k"},
			Description = "Kicks a player from the server.",
			Usage = "/kick player [reason]",
			Permission = "moderation.kick",
			Category = "Moderation",
			Cooldown = 1,
			Log = true,
			Undoable = false,
			Execute = function(ctx) ... end,
		})
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local PermissionSystem = require(script.Parent:WaitForChild("PermissionSystem"))
local Logger = require(script.Parent:WaitForChild("Logger"))

type CommandDefinition = Types.CommandDefinition
type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local CommandRegistry = {}

local byName: { [string]: CommandDefinition } = {}
local byAlias: { [string]: string } = {} -- alias -> canonical name
local byCategory: { [string]: { CommandDefinition } } = {}
local cooldowns: { [string]: number } = {} -- "userId:command" -> expiry time

local function validate(def: CommandDefinition)
	assert(type(def.Name) == "string" and #def.Name > 0, "CommandDefinition.Name is required")
	assert(type(def.Permission) == "string" and #def.Permission > 0, "CommandDefinition.Permission is required")
	assert(type(def.Execute) == "function", "CommandDefinition.Execute must be a function")
	assert(byName[def.Name] == nil, ("command '%s' already registered"):format(def.Name))
	for _, alias in ipairs(def.Aliases) do
		assert(byAlias[alias] == nil, ("alias '%s' already used by '%s'"):format(alias, byAlias[alias] or ""))
	end
end

function CommandRegistry.Register(def: CommandDefinition)
	validate(def)

	byName[def.Name] = def
	for _, alias in ipairs(def.Aliases) do
		byAlias[alias] = def.Name
	end

	local category = def.Category or "Uncategorized"
	byCategory[category] = byCategory[category] or {}
	table.insert(byCategory[category], def)

	EventBus.Publish("Command.Registered", def)
end

function CommandRegistry.Resolve(nameOrAlias: string): CommandDefinition?
	local direct = byName[nameOrAlias]
	if direct then
		return direct
	end
	local canonical = byAlias[nameOrAlias]
	if canonical then
		return byName[canonical]
	end
	return nil
end

function CommandRegistry.ListByCategory(category: string): { CommandDefinition }
	return byCategory[category] or {}
end

function CommandRegistry.All(): { CommandDefinition }
	local list = {}
	for _, def in pairs(byName) do
		table.insert(list, def)
	end
	return list
end

-- Used by the autocomplete engine (Phase 2): every registered name + alias.
function CommandRegistry.AllInvocables(): { string }
	local list = {}
	for name in pairs(byName) do
		table.insert(list, name)
	end
	for alias in pairs(byAlias) do
		table.insert(list, alias)
	end
	table.sort(list)
	return list
end

local function cooldownKey(userId: number, commandName: string): string
	return tostring(userId) .. ":" .. commandName
end

local function checkAndSetCooldown(executor: Player, def: CommandDefinition): boolean
	if not def.Cooldown or def.Cooldown <= 0 then
		return true
	end
	local key = cooldownKey(executor.UserId, def.Name)
	local expiry = cooldowns[key]
	if expiry and expiry > os.clock() then
		return false
	end
	cooldowns[key] = os.clock() + def.Cooldown
	return true
end

--[[
	Dispatch validates permission + cooldown, executes the command, logs the
	result, and publishes lifecycle events. This is the ONLY path that should
	ever call def.Execute — never call a command's Execute directly.
--]]
function CommandRegistry.Dispatch(def: CommandDefinition, executor: Player, ctx: CommandContext): CommandResult
	EventBus.Publish("Command.BeforeExecute", def, executor, ctx)

	if not PermissionSystem.Has(executor, def.Permission) then
		local result: CommandResult = { Success = false, Message = "You do not have permission to do that." }
		EventBus.Publish("Command.Denied", def, executor, ctx)
		Logger.Write({
			Executor = tostring(executor.UserId),
			ExecutorName = executor.Name,
			Command = def.Name,
			Arguments = ctx.Arguments,
			Result = "Denied",
			Severity = "Warning",
			Message = "Permission denied: " .. def.Permission,
		})
		return result
	end

	if not checkAndSetCooldown(executor, def) then
		return { Success = false, Message = "That command is on cooldown." }
	end

	local startClock = os.clock()
	local ok, resultOrErr = pcall(def.Execute, ctx)
	local elapsedMs = (os.clock() - startClock) * 1000

	local result: CommandResult
	if ok then
		result = resultOrErr :: CommandResult
	else
		result = { Success = false, Message = "Internal error executing command." }
		warn(("[Sentinel.CommandRegistry] '%s' errored: %s"):format(def.Name, tostring(resultOrErr)))
	end

	if def.Log then
		local targetNames = {}
		for _, p in ipairs(ctx.Targets) do
			table.insert(targetNames, p.Name)
		end
		Logger.Write({
			Executor = tostring(executor.UserId),
			ExecutorName = executor.Name,
			Command = def.Name,
			Arguments = ctx.Arguments,
			Target = table.concat(targetNames, ","),
			Result = if result.Success then "Success" else "Failure",
			Severity = if result.Success then "Info" else "Error",
			ExecutionTimeMs = elapsedMs,
			Message = result.Message,
		})
	end

	EventBus.Publish("Command.AfterExecute", def, executor, ctx, result)
	return result
end

return CommandRegistry
