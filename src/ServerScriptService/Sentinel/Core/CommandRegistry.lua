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
		CommandRegistry.Dispatch(def, executor, ctx): CommandResult

	Lifecycle (W07), in Dispatch order:
		1. permission + owner-only + cooldown checks
		2. Before hooks   fn(def, ctx) -> string?   a string cancels the
		   command (result.Cancelled = true, Message = that string)
		3. middleware     fn(def, ctx, nextFn) -> CommandResult, outermost
		   first; call nextFn() to continue, or return your own result
		4. def.Execute(ctx)
		5. After hooks    fn(def, ctx, result) (errors are caught)
		Every result gets Command and DurationMs (Execute + middleware time).

		CommandRegistry.AddHook("Before" | "After", fn, name?) -> remove()
		CommandRegistry.Use(middleware, name?) -> remove()
		CommandRegistry.ListHooks() -> { Before = {names}, After, Middleware }

	Cancellation: long-running commands call ctx.Track(label, cancelFn)
	and get back a handle with :Finish(); ;cancel calls
	CommandRegistry.CancelRunning(player), which runs every cancelFn the
	player still has open. ctx.IsCancelled() reports it inside loops.

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
local UsageSpec = require(SentinelShared:WaitForChild("UsageSpec"))
local ArgumentTypes = require(SentinelShared:WaitForChild("ArgumentTypes"))

local PermissionSystem = require(script.Parent:WaitForChild("PermissionSystem"))
local Logger = require(script.Parent:WaitForChild("Logger"))
local CommandPolicy = require(script.Parent:WaitForChild("CommandPolicy"))

type CommandDefinition = Types.CommandDefinition
type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local CommandRegistry = {}

local byName: { [string]: CommandDefinition } = {}
local byAlias: { [string]: string } = {} -- alias -> canonical name
local byCategory: { [string]: { CommandDefinition } } = {}
local cooldowns: { [string]: number } = {} -- "userId:command" -> expiry time

type Hook = { Name: string, Fn: any }
local beforeHooks: { Hook } = {}
local afterHooks: { Hook } = {}
local middlewares: { Hook } = {}

local function addTo(list: { Hook }, fn: any, name: string?): () -> ()
	assert(type(fn) == "function", "hook must be a function")
	local hook = { Name = name or ("hook" .. tostring(#list + 1)), Fn = fn }
	table.insert(list, hook)
	return function()
		local i = table.find(list, hook)
		if i then
			table.remove(list, i)
		end
	end
end

function CommandRegistry.AddHook(kind: string, fn: any, name: string?): () -> ()
	if kind == "Before" then
		return addTo(beforeHooks, fn, name)
	elseif kind == "After" then
		return addTo(afterHooks, fn, name)
	end
	error("hook kind must be 'Before' or 'After'")
end

function CommandRegistry.Use(middleware: any, name: string?): () -> ()
	return addTo(middlewares, middleware, name)
end

function CommandRegistry.ListHooks(): { [string]: { string } }
	local function names(list: { Hook })
		local out = {}
		for _, h in ipairs(list) do
			table.insert(out, h.Name)
		end
		return out
	end
	return { Before = names(beforeHooks), After = names(afterHooks), Middleware = names(middlewares) }
end

-- Running (cancellable) operations, per player.
type Operation = { Id: number, Command: string, Label: string, Started: number, Cancel: () -> (), Cancelled: boolean }
local running: { [number]: { Operation } } = {}
local nextOpId = 0

local function trackOperation(userId: number, command: string, label: string, cancel: () -> ())
	nextOpId += 1
	local op: Operation = { Id = nextOpId, Command = command, Label = label, Started = os.clock(), Cancel = cancel, Cancelled = false }
	running[userId] = running[userId] or {}
	table.insert(running[userId], op)
	local handle = {}
	function handle.Finish()
		local list = running[userId]
		local i = list and table.find(list, op)
		if i then
			table.remove(list :: any, i)
		end
	end
	function handle.IsCancelled(): boolean
		return op.Cancelled
	end
	return handle, op
end

function CommandRegistry.ListRunning(player: Player): { { Command: string, Label: string, Seconds: number } }
	local out = {}
	for _, op in ipairs(running[player.UserId] or {}) do
		table.insert(out, { Command = op.Command, Label = op.Label, Seconds = math.floor(os.clock() - op.Started) })
	end
	return out
end

-- Cancels every running operation the player started; returns how many.
function CommandRegistry.CancelRunning(player: Player): number
	local list = running[player.UserId]
	running[player.UserId] = nil
	local n = 0
	for _, op in ipairs(list or {}) do
		op.Cancelled = true
		local ok, err = pcall(op.Cancel)
		if not ok then
			warn(("[Sentinel.CommandRegistry] cancel of '%s' failed: %s"):format(op.Command, tostring(err)))
		end
		n += 1
	end
	return n
end

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

	-- Typed arguments (W05): parsed from Usage, refined by ArgHints, or
	-- given explicitly as Args. Used by the palette for autocomplete and
	-- inline validation.
	local args = UsageSpec.Build(def)
	for _, arg in ipairs(args) do
		for _, spec in ipairs({ arg, arg.Modifier }) do
			if spec and type(spec.Choices) ~= "function" and not ArgumentTypes.Has(spec.Type) then
				warn(("[Sentinel.CommandRegistry] '%s' argument '%s' has unknown type '%s'"):format(def.Name, spec.Name, spec.Type))
			end
		end
	end
	def.Args = args

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

	-- Public commands (e.g. ;confirm, which only replays the player's own
	-- pending, fully re-checked command) skip the node check.
	if not (def :: any).Public and not PermissionSystem.Has(executor, def.Permission) then
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

	-- Owner-only commands: refused for anyone without the Owner rank, no
	-- matter which permission nodes they hold.
	if CommandPolicy.IsOwnerOnly(def) and not table.find(PermissionSystem.GetRoles(executor), "Owner") then
		EventBus.Publish("Command.Denied", def, executor, ctx)
		Logger.Write({
			Executor = tostring(executor.UserId),
			ExecutorName = executor.Name,
			Command = def.Name,
			Arguments = ctx.Arguments,
			Result = "Denied",
			Severity = "Warning",
			Message = "Owner-only command",
		})
		return { Success = false, Message = ("%s is restricted to the Owner."):format(def.Name) }
	end

	if not checkAndSetCooldown(executor, def) then
		return { Success = false, Message = "That command is on cooldown." }
	end

	-- Cancellation support for long-running commands.
	local ctxAny = ctx :: any
	local cancelledFlag = false
	ctxAny.Track = function(label: string, cancelFn: () -> ())
		local handle, op = trackOperation(executor.UserId, def.Name, label, function()
			cancelledFlag = true
			cancelFn()
		end)
		return handle, op
	end
	ctxAny.IsCancelled = function(): boolean
		return cancelledFlag
	end

	-- Before hooks may cancel.
	for _, hook in ipairs(beforeHooks) do
		local ok, why = pcall(hook.Fn, def, ctx)
		if not ok then
			warn(("[Sentinel.CommandRegistry] before-hook '%s' errored: %s"):format(hook.Name, tostring(why)))
		elseif type(why) == "string" then
			local cancelled = { Success = false, Cancelled = true, Message = why, Command = def.Name, DurationMs = 0 }
			EventBus.Publish("Command.Cancelled", def, executor, ctx, why)
			return cancelled :: any
		end
	end

	-- Middleware chain around Execute (outermost = first registered).
	local function runAt(i: number): CommandResult
		local mw = middlewares[i]
		if not mw then
			return def.Execute(ctx)
		end
		return mw.Fn(def, ctx, function()
			return runAt(i + 1)
		end)
	end

	local startClock = os.clock()
	local ok, resultOrErr = pcall(runAt, 1)
	local elapsedMs = (os.clock() - startClock) * 1000

	local result: CommandResult
	if ok and type(resultOrErr) == "table" then
		result = resultOrErr :: CommandResult
	elseif ok then
		result = { Success = false, Message = "Command returned no result." }
	else
		result = { Success = false, Message = "Internal error executing command." }
		warn(("[Sentinel.CommandRegistry] '%s' errored: %s"):format(def.Name, tostring(resultOrErr)))
	end
	local resultAny = result :: any
	resultAny.Command = def.Name
	resultAny.DurationMs = math.floor(elapsedMs * 100 + 0.5) / 100

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

	for _, hook in ipairs(afterHooks) do
		local hookOk, err = pcall(hook.Fn, def, ctx, result)
		if not hookOk then
			warn(("[Sentinel.CommandRegistry] after-hook '%s' errored: %s"):format(hook.Name, tostring(err)))
		end
	end

	EventBus.Publish("Command.AfterExecute", def, executor, ctx, result)
	return result
end

return CommandRegistry
