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

-- One before/after value recorded for an audited change (W10).
export type AuditChange = {
	Target: string?, -- player name / setting owner, nil for global data
	Field: string,
	Before: string?, -- values are stored as short display strings
	After: string?,
}

export type LogEntry = {
	Id: string?, -- "<server short id>-<sequence>", unique across servers (W10)
	Timestamp: number,
	Executor: string, -- UserId as string, or "SYSTEM"
	ExecutorName: string,
	Command: string, -- command / action name (e.g. "ban", "rank.create")
	Action: string?, -- "<category>.<command>" (e.g. "moderation.ban")
	RawInput: string?, -- the command line that ran
	Arguments: { string },
	Target: string?, -- comma-joined target names
	TargetIds: { number }?,
	Reason: string?,
	Result: "Success" | "Failure" | "Denied" | "Cancelled",
	Server: string, -- JobId (Studio: "studio-<hex>")
	ExecutionTimeMs: number,
	Severity: LogSeverity,
	Message: string?,
	Changes: { AuditChange }?, -- before/after values when relevant
	Source: string?, -- chat | panel | keybind | remote | system ...
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
	CommandName: string?, -- name or alias the executor typed (lowercased)
	-- W07, set by CommandRegistry.Dispatch:
	Track: ((label: string, cancel: () -> ()) -> any)?, -- register a cancellable operation
	IsCancelled: (() -> boolean)?,
	Source: string?, -- "chat" | "panel" | "undo" | "redo" | "preset" | ...
}

export type CommandResult = {
	Success: boolean,
	Message: string?,
	Undoable: boolean?,
	UndoData: any?,
	-- Risky command waiting for ;confirm (see Core/CommandPolicy)
	NeedsConfirmation: boolean?,
	ConfirmId: string?,
	Risk: string?,
	-- W07, filled in by Dispatch / CommandProcessor
	Command: string?,
	DurationMs: number?,
	Cancelled: boolean?,
	HistoryId: number?,
	-- W10 audit: commands may name the reason and before/after values
	-- themselves; the audit middleware adds target snapshots.
	Reason: string?,
	Changes: { AuditChange }?,
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
	-- false = may target players ranked equal/above the executor (read-only
	-- or harmless commands). Default: protected.
	TargetProtection: boolean?,
	-- Overrides for Core/CommandPolicy: "low" | "medium" | "high" | "critical"
	Risk: string?,
	OwnerOnly: boolean?,
	-- Typed arguments (W05, see Shared/UsageSpec + ArgumentTypes). Args is
	-- filled at Register time from Usage unless given; ArgHints refines the
	-- parsed list; Examples are shown in the palette.
	Args: { any }?,
	ArgHints: { [any]: any }?,
	Examples: { string }?,
	-- W07 framework metadata
	Subcategory: string?,
	Tags: { string }?,
	Hidden: boolean?, -- registered but not listed in the palette / Commands page
	Cancellable: boolean?, -- uses ctx.Track; ;cancel stops it
	DefaultSelf: boolean?, -- RequiresTarget command with no target typed = the executor
	-- Undo: either the name of the command that reverses this one (run with
	-- the same targets, modifier and arguments), or a function that undoes
	-- it from the result's UndoData.
	Inverse: string?,
	Undo: ((ctx: CommandContext, result: CommandResult) -> CommandResult)?,
	-- W10 audit: before/after snapshot of each target (Systems/AuditService).
	-- false = none, a list of presets ("leaderstats", "humanoid",
	-- "attributes", "backpack") or fn(player) -> { field = value }. Default
	-- comes from the category.
	Audit: any?,
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
