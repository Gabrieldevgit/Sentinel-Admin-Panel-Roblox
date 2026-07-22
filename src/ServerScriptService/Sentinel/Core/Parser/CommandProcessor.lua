--!strict
--[[
	CommandProcessor.lua

	Purpose:
		The single function the chat hook (or future GUI command palette)
		calls with raw player input. Wires together CommandParser,
		CommandRegistry (alias resolution + dispatch), and TargetResolver,
		walking the "&&" chain and stopping early if a link fails.

	Responsibilities:
		- Parse raw input into a ParsedCommand chain
		- Resolve each link's command name (with alias support)
		- Resolve targets via TargetResolver
		- Attach ParsedDuration / ParsedQuantity when the command declares
		  it needs one (commands opt in via RequiresTarget + Modifier use;
		  the command's own Execute decides which parser to apply since
		  only it knows whether ":modifier" means a duration or a quantity)
		- Dispatch through CommandRegistry.Dispatch for permission/cooldown/
		  logging enforcement
		- Return a flat list of CommandResult, one per link, in order

	Dependencies:
		CommandParser.lua, TargetResolver.lua (Parser)
		CommandRegistry.lua (Core)
		Types.lua (Shared)

	Public API:
		CommandProcessor.Process(executor: Player, rawInput: string): {CommandResult}

	Example usage:
		-- rawInput does NOT include the leading "/"
		local results = CommandProcessor.Process(admin, "ban Player1:30m Exploiting")
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandParser = require(script.Parent:WaitForChild("CommandParser"))
local TargetResolver = require(script.Parent:WaitForChild("TargetResolver"))
local CommandRegistry = require(script.Parent.Parent:WaitForChild("CommandRegistry"))

type CommandResult = Types.CommandResult
type ParsedCommand = Types.ParsedCommand

local CommandProcessor = {}

function CommandProcessor.Process(executor: Player, rawInput: string): { CommandResult }
	local results: { CommandResult } = {}

	local chain = CommandParser.ParseLine(rawInput)
	if not chain then
		return { { Success = false, Message = "Could not parse that command." } }
	end

	local current: ParsedCommand? = chain
	while current do
		local def = CommandRegistry.Resolve(current.CommandName)
		if not def then
			table.insert(results, {
				Success = false,
				Message = ("Unknown command: %s"):format(current.CommandName),
			})
			break
		end

		-- IMPORTANT: only run target resolution when the command actually
		-- declares it wants a target. Otherwise a target-less command's
		-- first word (e.g. "on" in "maintenancemode on") gets swallowed by
		-- the parser's target-guessing logic and silently vanishes from
		-- Arguments — this was a real bug (maintenance/weather/slowmode/
		-- etc. all executed with empty Arguments).
		local targets: { Player } = {}
		local ctxArguments: { string } = current.PlainArguments
		local ctxModifier: string? = nil

		if def.RequiresTarget then
			targets = TargetResolver.Resolve(executor, current.TargetSelectors)
			ctxArguments = current.Arguments
			ctxModifier = current.Modifier
		end

		if def.RequiresTarget and #targets == 0 then
			table.insert(results, {
				Success = false,
				Message = ("%s requires a valid target."):format(def.Name),
			})
			break
		end

		local ctx: Types.CommandContext = {
			Executor = executor,
			Targets = targets,
			Modifier = ctxModifier,
			Arguments = ctxArguments,
			RawInput = current.RawInput,
		}

		local result = CommandRegistry.Dispatch(def, executor, ctx)
		table.insert(results, result)

		if not result.Success then
			break -- stop the chain on first failure, mirroring left-to-right execution semantics
		end

		current = current.NextCommand
	end

	return results
end

return CommandProcessor
