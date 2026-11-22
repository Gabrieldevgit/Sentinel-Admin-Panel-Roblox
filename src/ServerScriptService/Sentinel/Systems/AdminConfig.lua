--!strict
--[[
	AdminConfig.lua (W08)

	Purpose:
		The administration configuration from the feature blueprint (§13):
		every setting is a ConfigService key (persisted in Sentinel_Config_v1,
		pushed to every server), described here once with a text format that
		round-trips, so ;config, the Administration page and the code all
		agree.

		key            config key             text format
		prefixes       Prefixes               "; !"
		cooldownscale  CooldownScale          "1"   (0 = no cooldowns, 2 = doubled)
		cooldowns      CooldownOverrides      "fly=2 ban=5" | "none"
		defaultban     DefaultBanDuration     "forever" | "7d"
		maxduration    MaxPunishmentDuration  "none" | "30d"
		escalation     WarningEscalation      "3:kick 5:ban:1d" | "none"
		requirereason  RequiredReasons        "ban kick warn" | "none"
		logretention   LogRetentionDays       "30"
		defaultperms   DefaultPermissions     "player.fly !page.Developer" | "none"
		ownerapproval  OwnerApproval          "on" | "off"
		approvalrisk   ApprovalRisk           "critical" | "high" | "medium"
		approvaltimeout ApprovalTimeout       "60"  (seconds, 15-300)
		reports        ReportsEnabled         "on" | "off"   (W14 player reports)
		reportcooldown ReportCooldown         "60"  (seconds between reports, 10-600)
		appeals        AppealsEnabled         "on" | "off"   (W14 appeals + ban screen)
		appealwindow   AppealWindow           "120" (seconds a banned player may stay to appeal, 30-600)
		appealcooldown AppealCooldownDays     "7"   (days before a rejected case can be appealed again, 0-90)
		newaccount     SuspiciousAccountDays  "7"   (W15: accounts younger than this are flagged suspicious, 0-365)
		suspectwarnings SuspiciousWarnings    "3"   (W15: this many warnings flags a player suspicious, 0 = off)
		privateservers PrivateServerAccess    "open" | "friends" | "staff" (W22: who may join VIP servers; key defined by ServerStateService)

		Applied by this module:
			- CommandRegistry cooldown resolver (scale + overrides)
			- a Before hook: required reasons, default ban duration, maximum
			  ban / mute duration (applies to everyone, Owner included - the
			  Owner can change the limit)
			- PunishmentService escalation policy
			- PermissionSystem default nodes
			- Logger retention

	Public API:
		AdminConfig.Entries() -> { { Key, ConfigKey, Label, Group, Description, Text } }
		AdminConfig.Find(name) -> entry?
		AdminConfig.Set(name, text, actor) -> (ok, message)
		AdminConfig.Reset(name, actor) -> (ok, message)
		AdminConfig.Format(entry) -> string
		AdminConfig.ParseEscalation(text), ParseNodes(text), ... (for tests)
--]]

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))
local PunishmentService = require(script.Parent:WaitForChild("PunishmentService"))
require(script.Parent:WaitForChild("ServerStateService")) -- defines WhitelistMode / PrivateServerAccess

local AdminConfig = {}

local ESCALATION_ACTIONS = { "kick", "mute", "ban" }
-- Commands whose ":duration" modifier the default / maximum durations govern.
local DURATION_COMMANDS = { ban = true, mute = true }
-- Default permissions may never hand out these to every player.
local FORBIDDEN_DEFAULT_ROOTS = { "*", "config", "ranks", "developer", "panel", "crossserver" }

local function isDuration(value: any, allowPermanent: boolean): boolean
	if type(value) ~= "string" or #value == 0 or #value > 12 then
		return false
	end
	local parsed = DurationParser.Parse(value)
	return parsed ~= nil and (allowPermanent or not parsed.IsPermanent)
end

local function isNameList(value: any, max: number): boolean
	if type(value) ~= "table" or #value > max then
		return false
	end
	for _, v in ipairs(value) do
		if type(v) ~= "string" or not v:match("^[%w_]+$") or #v > 30 then
			return false
		end
	end
	return true
end

local function nodeAllowedForDefault(node: string): boolean
	local bare = node:gsub("^!", "")
	if not bare:match("^[%w_%.%*]+$") or #bare > 60 then
		return false
	end
	local root = bare:match("^([^%.]+)") or bare
	if node:sub(1, 1) == "!" then
		return root ~= "*" -- denying is always safe
	end
	return not table.find(FORBIDDEN_DEFAULT_ROOTS, root)
end

-- ---------------------------------------------------------------------------
-- Validators (stored values)
-- ---------------------------------------------------------------------------
local VALID = {
	CooldownScale = function(v: any): boolean
		return type(v) == "number" and v == v and v >= 0 and v <= 5
	end,
	CooldownOverrides = function(v: any): boolean
		if type(v) ~= "table" then
			return false
		end
		local n = 0
		for name, seconds in pairs(v) do
			n += 1
			if type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 30 then
				return false
			end
			if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds > 600 then
				return false
			end
		end
		return n <= 100
	end,
	DefaultBanDuration = function(v: any): boolean
		return isDuration(v, true)
	end,
	MaxPunishmentDuration = function(v: any): boolean
		return v == "none" or isDuration(v, false)
	end,
	WarningEscalation = function(v: any): boolean
		if type(v) ~= "table" or #v > 10 then
			return false
		end
		local seen = {}
		for _, step in ipairs(v) do
			if type(step) ~= "table" or type(step.Count) ~= "number" or step.Count % 1 ~= 0 then
				return false
			end
			if step.Count < 1 or step.Count > 50 or seen[step.Count] then
				return false
			end
			seen[step.Count] = true
			if not table.find(ESCALATION_ACTIONS, step.Action) then
				return false
			end
			if step.Duration ~= nil and not isDuration(step.Duration, true) then
				return false
			end
		end
		return true
	end,
	RequiredReasons = function(v: any): boolean
		return isNameList(v, 40)
	end,
	LogRetentionDays = function(v: any): boolean
		return type(v) == "number" and v % 1 == 0 and v >= 1 and v <= 365
	end,
	DefaultPermissions = function(v: any): boolean
		if type(v) ~= "table" or #v > 30 then
			return false
		end
		for _, node in ipairs(v) do
			if type(node) ~= "string" or not nodeAllowedForDefault(node) then
				return false
			end
		end
		return true
	end,
}

ConfigService.Define("CooldownScale", 1, VALID.CooldownScale)
ConfigService.Define("CooldownOverrides", {}, VALID.CooldownOverrides)
ConfigService.Define("DefaultBanDuration", "forever", VALID.DefaultBanDuration)
ConfigService.Define("MaxPunishmentDuration", "none", VALID.MaxPunishmentDuration)
ConfigService.Define("WarningEscalation", {
	{ Count = 3, Action = "kick" },
	{ Count = 5, Action = "ban", Duration = "1d" },
}, VALID.WarningEscalation)
ConfigService.Define("RequiredReasons", {}, VALID.RequiredReasons)
ConfigService.Define("LogRetentionDays", 30, VALID.LogRetentionDays)
ConfigService.Define("DefaultPermissions", {}, VALID.DefaultPermissions)
-- Owner approval (Systems/ApprovalService): risky commands from non-Owners
-- wait for an Owner who is in the server.
ConfigService.Define("OwnerApproval", true, function(v)
	return type(v) == "boolean"
end)
ConfigService.Define("ApprovalRisk", "critical", function(v)
	return v == "critical" or v == "high" or v == "medium"
end)
ConfigService.Define("ApprovalTimeout", 60, function(v)
	return type(v) == "number" and v % 1 == 0 and v >= 15 and v <= 300
end)
-- Reports & appeals (W14: Systems/ReportService, Systems/AppealService).
local function isBool(v)
	return type(v) == "boolean"
end
local function intRange(lo: number, hi: number)
	return function(v)
		return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
	end
end
ConfigService.Define("ReportsEnabled", true, isBool)
ConfigService.Define("ReportCooldown", 60, intRange(10, 600))
ConfigService.Define("AppealsEnabled", true, isBool)
ConfigService.Define("AppealWindow", 120, intRange(30, 600))
ConfigService.Define("AppealCooldownDays", 7, intRange(0, 90))
ConfigService.Define("SuspiciousAccountDays", 7, intRange(0, 365))
ConfigService.Define("SuspiciousWarnings", 3, intRange(0, 50))

-- ---------------------------------------------------------------------------
-- Text <-> value
-- ---------------------------------------------------------------------------
local function words(text: string): { string }
	local out = {}
	for w in text:gmatch("%S+") do
		table.insert(out, w)
	end
	return out
end

local function isNone(text: string): boolean
	local t = text:lower():match("^%s*(.-)%s*$")
	return t == "none" or t == "off" or t == ""
end

function AdminConfig.ParseEscalation(text: string): (any, string?)
	if isNone(text) then
		return {}, nil
	end
	local steps = {}
	for _, part in ipairs(words(text)) do
		local count, action, duration = part:lower():match("^(%d+):(%a+):?(.*)$")
		if not count then
			return nil, ("'%s' should look like 3:kick or 5:ban:1d"):format(part)
		end
		if not table.find(ESCALATION_ACTIONS, action) then
			return nil, ("'%s' is not an action (kick, mute, ban)"):format(action)
		end
		if duration ~= "" and not isDuration(duration, true) then
			return nil, ("'%s' is not a duration"):format(duration)
		end
		table.insert(steps, { Count = tonumber(count), Action = action, Duration = if duration ~= "" then duration else nil })
	end
	table.sort(steps, function(a, b)
		return a.Count < b.Count
	end)
	if not VALID.WarningEscalation(steps) then
		return nil, "counts must be 1-50, each used once, at most 10 steps"
	end
	return steps, nil
end

function AdminConfig.ParseNodes(text: string): (any, string?)
	if isNone(text) then
		return {}, nil
	end
	local nodes = words(text)
	for _, node in ipairs(nodes) do
		if not nodeAllowedForDefault(node) then
			return nil, ("'%s' can't be a default permission (no *, config, ranks, developer, panel or crossserver nodes)"):format(node)
		end
	end
	if #nodes > 30 then
		return nil, "at most 30 nodes"
	end
	return nodes, nil
end

function AdminConfig.ParseOverrides(text: string): (any, string?)
	if isNone(text) then
		return {}, nil
	end
	local out = {}
	for _, part in ipairs(words(text)) do
		local name, seconds = part:lower():match("^([%w_]+)=([%d%.]+)$")
		local n = tonumber(seconds)
		if not name or not n then
			return nil, ("'%s' should look like fly=2"):format(part)
		end
		local def = CommandRegistry.Resolve(name)
		if not def then
			return nil, ("there is no command '%s'"):format(name)
		end
		out[def.Name] = math.clamp(n, 0, 600)
	end
	return out, nil
end

function AdminConfig.ParseCommandList(text: string): (any, string?)
	if isNone(text) then
		return {}, nil
	end
	local out = {}
	for _, name in ipairs(words(text)) do
		local def = CommandRegistry.Resolve((name:lower():gsub("^%p", "")))
		if not def then
			return nil, ("there is no command '%s'"):format(name)
		end
		if not table.find(out, def.Name) then
			table.insert(out, def.Name)
		end
	end
	return out, nil
end

local function formatOverrides(v: any): string
	local parts = {}
	for name, seconds in pairs(v) do
		table.insert(parts, ("%s=%s"):format(name, tostring(seconds)))
	end
	table.sort(parts)
	return if #parts == 0 then "none" else table.concat(parts, " ")
end

local function formatEscalation(v: any): string
	local parts = {}
	for _, step in ipairs(v) do
		table.insert(parts, ("%d:%s%s"):format(step.Count, step.Action, if step.Duration then ":" .. step.Duration else ""))
	end
	return if #parts == 0 then "none" else table.concat(parts, " ")
end

local function formatList(v: any): string
	return if #v == 0 then "none" else table.concat(v, " ")
end

local function parseOnOff(text: string): (any, string?)
	local t = text:lower():match("^%s*(.-)%s*$")
	if t == "on" or t == "true" or t == "yes" then
		return true, nil
	elseif t == "off" or t == "false" or t == "no" then
		return false, nil
	end
	return nil, "use on or off"
end

local function formatOnOff(v: any): string
	return if v then "on" else "off"
end

local function parseSeconds(lo: number, hi: number)
	return function(text: string): (any, string?)
		local n = tonumber((text:gsub("s%s*$", "")))
		if not n or n % 1 ~= 0 or n < lo or n > hi then
			return nil, ("give a whole number of seconds from %d to %d"):format(lo, hi)
		end
		return n, nil
	end
end

type Entry = {
	Key: string,
	ConfigKey: string,
	Label: string,
	Group: string,
	Description: string,
	Example: string,
	Parse: (string) -> (any, string?),
	Format: (any) -> string,
}

local ENTRIES: { Entry } = {
	{
		Key = "prefixes",
		ConfigKey = "Prefixes",
		Label = "Command prefixes",
		Group = "Commands",
		Description = "Characters that start a chat command (" .. table.concat(ConfigService.ALLOWED_PREFIXES, " ") .. ").",
		Example = "; !",
		Parse = function(text)
			local list = {}
			for _, p in ipairs(words(text)) do
				if not table.find(ConfigService.ALLOWED_PREFIXES, p) then
					return nil, ("'%s' is not an allowed prefix"):format(p)
				end
				if not table.find(list, p) then
					table.insert(list, p)
				end
			end
			if #list == 0 then
				return nil, "keep at least one prefix"
			end
			return list, nil
		end,
		Format = formatList,
	},
	{
		Key = "cooldownscale",
		ConfigKey = "CooldownScale",
		Label = "Cooldown scale",
		Group = "Commands",
		Description = "Multiplies every command cooldown (0 = none, 1 = normal, 2 = doubled).",
		Example = "1",
		Parse = function(text)
			local n = tonumber(text)
			if not n or n < 0 or n > 5 then
				return nil, "give a number from 0 to 5"
			end
			return math.floor(n * 100 + 0.5) / 100, nil
		end,
		Format = function(v)
			return tostring(v)
		end,
	},
	{
		Key = "cooldowns",
		ConfigKey = "CooldownOverrides",
		Label = "Cooldown overrides",
		Group = "Commands",
		Description = "Seconds for specific commands, ignoring the scale.",
		Example = "fly=2 announce=10",
		Parse = AdminConfig.ParseOverrides,
		Format = formatOverrides,
	},
	{
		Key = "defaultban",
		ConfigKey = "DefaultBanDuration",
		Label = "Default ban duration",
		Group = "Moderation",
		Description = "Used when ;ban has no :duration.",
		Example = "7d",
		Parse = function(text)
			local t = text:lower():match("^%s*(.-)%s*$") :: string
			if not isDuration(t, true) then
				return nil, "give a duration like 1h, 7d or forever"
			end
			return t, nil
		end,
		Format = function(v)
			return tostring(v)
		end,
	},
	{
		Key = "maxduration",
		ConfigKey = "MaxPunishmentDuration",
		Label = "Maximum punishment",
		Group = "Moderation",
		Description = "Longest ;ban / ;mute anyone may give (permanent ones are refused too). none = no limit.",
		Example = "30d",
		Parse = function(text)
			if isNone(text) then
				return "none", nil
			end
			local t = text:lower():match("^%s*(.-)%s*$") :: string
			if not isDuration(t, false) then
				return nil, "give a duration like 30d, or none"
			end
			return t, nil
		end,
		Format = function(v)
			return tostring(v)
		end,
	},
	{
		Key = "escalation",
		ConfigKey = "WarningEscalation",
		Label = "Warning escalation",
		Group = "Moderation",
		Description = "What happens at a number of warnings: count:action[:duration] (kick, mute, ban).",
		Example = "3:kick 5:ban:1d",
		Parse = AdminConfig.ParseEscalation,
		Format = formatEscalation,
	},
	{
		Key = "requirereason",
		ConfigKey = "RequiredReasons",
		Label = "Required reasons",
		Group = "Moderation",
		Description = "Commands that refuse to run without a reason.",
		Example = "ban kick warn",
		Parse = AdminConfig.ParseCommandList,
		Format = formatList,
	},
	{
		Key = "logretention",
		ConfigKey = "LogRetentionDays",
		Label = "Log retention",
		Group = "Logs",
		Description = "Days log entries are kept (1-365).",
		Example = "30",
		Parse = function(text)
			local n = tonumber(text)
			if not n or n % 1 ~= 0 or n < 1 or n > 365 then
				return nil, "give a whole number of days from 1 to 365"
			end
			return n, nil
		end,
		Format = function(v)
			return tostring(v) .. " days"
		end,
	},
	{
		Key = "ownerapproval",
		ConfigKey = "OwnerApproval",
		Label = "Owner approval",
		Group = "Security",
		Description = "When an Owner is in the server, risky commands from other ranks wait for the Owner to approve them (on / off).",
		Example = "on",
		Parse = function(text)
			local t = text:lower():match("^%s*(.-)%s*$")
			if t == "on" or t == "true" or t == "yes" then
				return true, nil
			elseif t == "off" or t == "false" or t == "no" then
				return false, nil
			end
			return nil, "use on or off"
		end,
		Format = function(v)
			return if v then "on" else "off"
		end,
	},
	{
		Key = "approvalrisk",
		ConfigKey = "ApprovalRisk",
		Label = "Approval risk level",
		Group = "Security",
		Description = "Lowest risk that needs approval: critical (server-wide: shutdown, lockdown, data), high (adds bans, economy resets, rank deletes) or medium (adds kicks, mutes, jails...).",
		Example = "critical",
		Parse = function(text)
			local t = text:lower():match("^%s*(.-)%s*$")
			if t == "critical" or t == "high" or t == "medium" then
				return t, nil
			end
			return nil, "use critical, high or medium"
		end,
		Format = function(v)
			return tostring(v)
		end,
	},
	{
		Key = "approvaltimeout",
		ConfigKey = "ApprovalTimeout",
		Label = "Approval timeout",
		Group = "Security",
		Description = "Seconds the Owner has to answer before the request is denied (15-300).",
		Example = "60",
		Parse = function(text)
			local n = tonumber((text:gsub("s%s*$", "")))
			if not n or n % 1 ~= 0 or n < 15 or n > 300 then
				return nil, "give a whole number of seconds from 15 to 300"
			end
			return n, nil
		end,
		Format = function(v)
			return tostring(v) .. "s"
		end,
	},
	{
		Key = "reports",
		ConfigKey = "ReportsEnabled",
		Label = "Player reports",
		Group = "Reports & appeals",
		Description = "Players can report other players with ;report (on / off).",
		Example = "on",
		Parse = parseOnOff,
		Format = formatOnOff,
	},
	{
		Key = "reportcooldown",
		ConfigKey = "ReportCooldown",
		Label = "Report cooldown",
		Group = "Reports & appeals",
		Description = "Seconds a player must wait between two reports (10-600).",
		Example = "60",
		Parse = parseSeconds(10, 600),
		Format = function(v)
			return tostring(v) .. "s"
		end,
	},
	{
		Key = "appeals",
		ConfigKey = "AppealsEnabled",
		Label = "Appeals",
		Group = "Reports & appeals",
		Description = "Punished players can appeal (on / off). When on, banned players see an appeal screen before they are disconnected.",
		Example = "on",
		Parse = parseOnOff,
		Format = formatOnOff,
	},
	{
		Key = "appealwindow",
		ConfigKey = "AppealWindow",
		Label = "Appeal window",
		Group = "Reports & appeals",
		Description = "Seconds a banned player may stay on the appeal screen before being disconnected (30-600).",
		Example = "120",
		Parse = parseSeconds(30, 600),
		Format = function(v)
			return tostring(v) .. "s"
		end,
	},
	{
		Key = "appealcooldown",
		ConfigKey = "AppealCooldownDays",
		Label = "Appeal cooldown",
		Group = "Reports & appeals",
		Description = "Days before a case whose appeal was rejected can be appealed again (0-90).",
		Example = "7",
		Parse = function(text)
			local n = tonumber((text:gsub("d%s*$", "")))
			if not n or n % 1 ~= 0 or n < 0 or n > 90 then
				return nil, "give a whole number of days from 0 to 90"
			end
			return n, nil
		end,
		Format = function(v)
			return tostring(v) .. " days"
		end,
	},
	{
		Key = "newaccount",
		ConfigKey = "SuspiciousAccountDays",
		Label = "New account age",
		Group = "Player explorer",
		Description = "Accounts younger than this many days are flagged suspicious on the Players page (0 = off, max 365).",
		Example = "7",
		Parse = function(text)
			local n = tonumber((text:gsub("d%s*$", "")))
			if not n or n % 1 ~= 0 or n < 0 or n > 365 then
				return nil, "give a whole number of days from 0 to 365"
			end
			return n, nil
		end,
		Format = function(v)
			return if v == 0 then "off" else tostring(v) .. " days"
		end,
	},
	{
		Key = "suspectwarnings",
		ConfigKey = "SuspiciousWarnings",
		Label = "Suspicious warnings",
		Group = "Player explorer",
		Description = "Players with at least this many warnings are flagged suspicious (0 = off, max 50).",
		Example = "3",
		Parse = function(text)
			local n = tonumber(text)
			if not n or n % 1 ~= 0 or n < 0 or n > 50 then
				return nil, "give a whole number from 0 to 50"
			end
			return n, nil
		end,
		Format = function(v)
			return if v == 0 then "off" else tostring(v)
		end,
	},
	{
		Key = "privateservers",
		ConfigKey = "PrivateServerAccess",
		Label = "Private server access",
		Group = "Server",
		Description = "Who may join private (VIP) servers: open (Roblox's own rules), friends (the owner and the owner's friends, plus staff) or staff (the owner and staff only).",
		Example = "friends",
		Parse = function(text)
			local t = text:lower():match("^%s*(.-)%s*$")
			if t == "open" or t == "friends" or t == "staff" then
				return t, nil
			end
			return nil, "use open, friends or staff"
		end,
		Format = function(v)
			return tostring(v)
		end,
	},
	{
		Key = "defaultperms",
		ConfigKey = "DefaultPermissions",
		Label = "Default permissions",
		Group = "Permissions",
		Description = "Nodes every player has, even without a rank (! denies).",
		Example = "player.fly",
		Parse = AdminConfig.ParseNodes,
		Format = formatList,
	},
}

function AdminConfig.Find(name: string): Entry?
	local lower = name:lower()
	for _, entry in ipairs(ENTRIES) do
		if entry.Key == lower or entry.ConfigKey:lower() == lower then
			return entry
		end
	end
	return nil
end

function AdminConfig.Format(entry: Entry): string
	return entry.Format(ConfigService.Get(entry.ConfigKey))
end

function AdminConfig.Entries(): { any }
	local out = {}
	for _, entry in ipairs(ENTRIES) do
		table.insert(out, {
			Key = entry.Key,
			ConfigKey = entry.ConfigKey,
			Label = entry.Label,
			Group = entry.Group,
			Description = entry.Description,
			Example = entry.Example,
			Text = AdminConfig.Format(entry),
			Default = entry.Format(ConfigService.GetDefault(entry.ConfigKey)),
		})
	end
	return out
end

function AdminConfig.Keys(): { string }
	local out = {}
	for _, entry in ipairs(ENTRIES) do
		table.insert(out, entry.Key)
	end
	return out
end

function AdminConfig.Set(name: string, text: string, actor: Player?): (boolean, string)
	local entry = AdminConfig.Find(name)
	if not entry then
		return false, ("Unknown setting '%s'. Settings: %s"):format(name, table.concat(AdminConfig.Keys(), ", "))
	end
	local value, err = entry.Parse(text)
	if value == nil then
		return false, ("%s: %s."):format(entry.Key, err or "invalid value")
	end
	local ok, why = ConfigService.Set(entry.ConfigKey, value, actor)
	if not ok then
		return false, why or "Could not save."
	end
	return true, ("%s set to %s."):format(entry.Label, entry.Format(value))
end

function AdminConfig.Reset(name: string, actor: Player?): (boolean, string)
	local entry = AdminConfig.Find(name)
	if not entry then
		return false, ("Unknown setting '%s'."):format(name)
	end
	local ok, why = ConfigService.Reset(entry.ConfigKey, actor)
	if not ok then
		return false, why or "Could not save."
	end
	return true, ("%s reset to %s."):format(entry.Label, AdminConfig.Format(entry))
end

-- ---------------------------------------------------------------------------
-- Applying the settings
-- ---------------------------------------------------------------------------
CommandRegistry.SetCooldownResolver(function(def): number?
	local overrides = ConfigService.Get("CooldownOverrides")
	if type(overrides) == "table" and type(overrides[def.Name]) == "number" then
		return overrides[def.Name]
	end
	local scale = ConfigService.Get("CooldownScale")
	return (def.Cooldown or 0) * (if type(scale) == "number" then scale else 1)
end)

-- Returns a message to cancel the command, or nil. Exposed for tests.
function AdminConfig.CheckCommand(def: any, ctx: any): string?
	local name = def.Name
	local required = ConfigService.Get("RequiredReasons")
	if type(required) == "table" and table.find(required, name) and #(ctx.Arguments or {}) == 0 then
		return ("A reason is required for ;%s (server setting)."):format(name)
	end
	if DURATION_COMMANDS[name] then
		if name == "ban" and (ctx.Modifier == nil or ctx.Modifier == "") then
			ctx.Modifier = ConfigService.Get("DefaultBanDuration")
		end
		local max = ConfigService.Get("MaxPunishmentDuration")
		if type(max) == "string" and max ~= "none" then
			local limit = DurationParser.Parse(max)
			local wanted = DurationParser.Parse(ctx.Modifier or "forever")
			if limit and wanted and (wanted.IsPermanent or wanted.Seconds > limit.Seconds) then
				return ("The longest ;%s allowed is %s (server setting)."):format(name, max)
			end
		end
	end
	return nil
end

CommandRegistry.AddHook("Before", AdminConfig.CheckCommand, "AdminConfig")

PunishmentService.SetPolicyProvider(function()
	return ConfigService.Get("WarningEscalation")
end)

local function applyKey(key: string)
	if key == "DefaultPermissions" then
		PermissionSystem.SetDefaultNodes(ConfigService.Get("DefaultPermissions"))
	elseif key == "LogRetentionDays" then
		Logger.SetRetentionDays(ConfigService.Get("LogRetentionDays"))
	end
end
applyKey("DefaultPermissions")
applyKey("LogRetentionDays")
ConfigService.Changed:Connect(applyKey)

return AdminConfig
