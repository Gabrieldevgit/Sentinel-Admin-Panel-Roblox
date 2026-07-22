--!strict
--[[
	Types.lua

	Purpose:
		Central type-definition module for Sentinel. Every core system imports
		its public types from here so that Core, Commands, Services, and
		Plugins all share one contract instead of redefining shapes locally.

	Responsibilities:
		- Define command metadata shape
		- Define parsed-command / target / duration / quantity shapes
		- Define permission node shape
		- Define log entry shape
		- Define plugin contract shape

	Dependencies:
		None. This module is pure data (types + a couple of enums).

	Public API:
		See exported types below. Import with:
			local Types = require(game.ReplicatedStorage.Shared.Sentinel.Types)
--]]

export type PermissionNode = string -- e.g. "moderation.ban"

export type LogSeverity = "Info" | "Warning" | "Error" | "Critical"

export type LogEntry = {
	Timestamp: number,
	Executor: string, -- UserId as string, or "SYSTEM"
	ExecutorName: string,
	Command: string,
	Arguments: { string },
	Target: string?,
	Result: "Success" | "Failure" | "Denied",
	Server: string, -- JobId
	ExecutionTimeMs: number,
	Severity: LogSeverity,
	Message: string?,
}

-- A single resolved target after selector expansion (@team, @role, filters, etc.)
export type ResolvedTarget = {
	Player: Player,
	UserId: number,
}

export type TargetSelectorKind = "Self" | "All" | "Others" | "Random" | "Nearest" | "Last"
	| "Named" | "Team" | "Role" | "Group" | "Rank" | "Tag" | "Attribute" | "Property"

export type TargetSelector = {
	Kind: TargetSelectorKind,
	Raw: string, -- original selector text, e.g. "@team"
	Value: string?, -- e.g. "Red" for @team Red
	Operator: string?, -- for property selectors: ">", "<", ">=", "<=", "="
	Comparand: string?, -- for property selectors: "25" in @level >25
}

export type ParsedDuration = {
	Seconds: number, -- 0 for instantaneous, math.huge for permanent
	IsPermanent: boolean,
	Raw: string,
}

export type ParsedQuantity = {
	Amount: number,
	Raw: string,
}

-- The fully tokenized and parsed representation of one command line,
-- BEFORE target resolution turns selectors into real Players.
export type ParsedCommand = {
	CommandName: string, -- resolved through alias table already
	RawInput: string,
	TargetSelectors: { TargetSelector },
	Modifier: string?, -- text after ":" on the target, e.g. "30m" or "5"
	Arguments: { string }, -- remaining free-text arguments, ASSUMING a target was present
	PlainArguments: { string }, -- every token after the command name, untouched by target-guessing —
		-- used for commands where RequiresTarget is false, since those
		-- commands have no target concept and the first token is a real
		-- argument (e.g. "maintenancemode on" — "on" must not be
		-- swallowed as an attempted target selector).
	NextCommand: ParsedCommand?, -- set when "&&" chains commands
}

export type CommandFilter = {
	Property: string, -- "Health", "Ping", etc.
	Operator: string, -- "<", ">", "<=", ">=", "="
	Comparand: string,
}

export type CommandContext = {
	Executor: Player,
	Targets: { Player },
	Modifier: string?,
	ParsedDuration: ParsedDuration?,
	ParsedQuantity: ParsedQuantity?,
	Arguments: { string },
	RawInput: string,
}

export type CommandResult = {
	Success: boolean,
	Message: string?,
	Undoable: boolean?,
	UndoData: any?,
}

export type CommandDefinition = {
	Name: string,
	Aliases: { string },
	Description: string,
	Usage: string,
	Permission: PermissionNode,
	Category: string,
	Cooldown: number?, -- seconds
	Log: boolean,
	Undoable: boolean,
	RequiresTarget: boolean?,
	Execute: (ctx: CommandContext) -> CommandResult,
}

export type PluginManifest = {
	Name: string,
	Version: string,
	Author: string?,
	Dependencies: { string }?,
	OnLoad: (sentinelApi: any) -> (),
	OnUnload: (() -> ())?,
}

return {}
