--!strict
--[[
	AntiCheatTypes.lua (Sentinel AntiCheat)

	Purpose:
		Shared types and constants for Sentinel AntiCheat, used by the
		server (ServerScriptService.Sentinel.Systems.AntiCheat) and the
		Anti-Cheat Control Center (StarterGui.SentinelUI.AntiCheatCenter).
		Types only plus a few display constants - no logic, no secrets.

	Contents:
		Flag, ModuleDef, ModuleState, Exemption, WatchEntry, ReviewItem
		AntiCheatTypes.MODES          observe | balanced | strict
		AntiCheatTypes.ACTIONS        what an action band can do
		AntiCheatTypes.NODES          permission nodes (RankService)
		AntiCheatTypes.STATUSES       player status labels
		AntiCheatTypes.PAGES          Control Center sidebar order (keys 1-9, 0)
		AntiCheatTypes.SeverityColor(n) -> Color3 (1 green .. 10 red)
--]]

export type Flag = {
	Id: string, -- "<server short>-<seq>"
	Module: string,
	Severity: number, -- 1-10
	Confidence: number, -- 0-1
	Reason: string,
	Evidence: { [string]: any }?,
	UserId: number,
	Name: string,
	Time: number,
	Points: number, -- what this flag added
	ScoreAfter: number,
	Server: string,
	Reviewed: boolean?,
	FalsePositive: boolean?,
	Action: string?, -- the action band result, if any
	Correct: string?, -- "position" | "health" | nil (silent correction hint)
}

-- A detection module (Systems/AntiCheat/Modules/*). Check is pure: it only
-- reads `state` (built by DetectionEngine, or by a unit test) and returns
-- nil or a partial flag. A module never punishes.
export type ModuleDef = {
	Name: string,
	Description: string,
	Enabled: boolean,
	Interval: number,
	Severity: number,
	Defaults: { [string]: any },
	Schema: { [string]: { Min: number?, Max: number?, Type: string?, Description: string? } }?,
	Gather: ((player: Player, state: any, ctx: any) -> ())?,
	Check: (player: any, state: any) -> any,
}

export type Exemption = {
	Id: string,
	UserId: number,
	Name: string,
	Module: string, -- module name or "all"
	Reason: string,
	By: string,
	At: number,
	ExpiresAt: number?, -- nil = permanent
}

export type WatchEntry = {
	UserId: number,
	Name: string,
	Since: number,
	Why: string,
	By: string,
}

export type ReviewItem = {
	Id: number,
	UserId: number,
	Name: string,
	Score: number,
	Modules: { string },
	Reason: string,
	Proposed: string, -- "ban" | "review"
	Status: string, -- Open | Assigned | Escalated | Approved | Dismissed
	AssignedTo: string?,
	CreatedAt: number,
	Notes: { any },
	Flags: { string }, -- flag ids
}

local AntiCheatTypes = {}

AntiCheatTypes.MODES = { "observe", "balanced", "strict" }

AntiCheatTypes.ACTIONS = { "log", "alert", "correct", "warn", "kick", "tempban", "review", "ban" }

AntiCheatTypes.ACTION_LABELS = {
	log = "Log only",
	alert = "Log + staff alert",
	correct = "Silent correction",
	warn = "Warn player",
	kick = "Kick",
	tempban = "Temporary ban (server)",
	review = "Queue for staff review",
	ban = "Ban (game)",
}

AntiCheatTypes.NODES = {
	View = "anticheat.view",
	Review = "anticheat.review",
	Exempt = "anticheat.exempt",
	Act = "anticheat.act",
	Ban = "anticheat.ban",
	Config = "anticheat.config",
	Master = "anticheat.master",
}

AntiCheatTypes.STATUSES = { "Clean", "Watched", "Exempt", "Testing" }

AntiCheatTypes.PAGES = {
	{ Id = "Overview", Label = "Overview" },
	{ Id = "Flags", Label = "Live Flags" },
	{ Id = "Players", Label = "Players" },
	{ Id = "Review", Label = "Review Queue" },
	{ Id = "Bans", Label = "Banned" },
	{ Id = "Modules", Label = "Modules" },
	{ Id = "Exemptions", Label = "Exemptions" },
	{ Id = "Settings", Label = "Settings" },
	{ Id = "Analytics", Label = "Analytics" },
	{ Id = "Logs", Label = "Logs & Help" },
}

-- 1 = green, 5 = amber, 10 = red.
function AntiCheatTypes.SeverityColor(severity: number): Color3
	local t = math.clamp(((tonumber(severity) or 1) - 1) / 9, 0, 1)
	if t < 0.5 then
		return Color3.fromRGB(87, 214, 130):Lerp(Color3.fromRGB(240, 180, 60), t * 2)
	end
	return Color3.fromRGB(240, 180, 60):Lerp(Color3.fromRGB(235, 87, 87), (t - 0.5) * 2)
end

return AntiCheatTypes
