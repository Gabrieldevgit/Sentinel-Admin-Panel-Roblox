--!strict
--[[
	AntiCheatConfig.lua (Sentinel AntiCheat)

	Purpose:
		Every anti-cheat setting: defaults, a schema (type, min, max,
		choices) and validation. Values live in Systems/ConfigService under
		one key per section - "AntiCheat.Core", "AntiCheat.Bands", ... and
		"AntiCheat.Module.<Name>" per detection module - so a change is
		saved to Sentinel_Config_v1 and pushed to every server live, and each
		message stays under MessagingService's 1 kB limit (one big table
		would not).

		Invalid values are refused with a clear message. Every change is
		written to the audit log with the old and new value (action
		"anticheat.config").

	Sections:
		Core        Enabled, Mode, Panic, SetupDone, ExemptRank, FrameBudget, CostBudgetMs
		Bands       Thresholds + the action of each band per mode, ban rules
		Scoring     DecayPerMinute, ScoreCap, FalsePositiveFactor, MinPlayerWeight
		Grace       SpawnGrace, TeleportGrace, SeatGrace, LagTolerance, MaxPingMs
		Storage     HistoryLength, RetentionDays, FlushSeconds
		Alerts      MinSeverity, Notify (view | review | act), WatchAlerts
		CrossServer ShareAlerts, ShareBans, ShareMinSeverity, MaxPerMinute
		Module.<Name>  Enabled, Weight (0-2), Interval, Grace + the module's Defaults

	Public API:
		AntiCheatConfig.SCHEMA, SECTIONS, PRESETS
		AntiCheatConfig.Get(section) -> table (cached, do not mutate)
		AntiCheatConfig.GetModule(name) -> table
		AntiCheatConfig.RegisterModule(def)
		AntiCheatConfig.ModuleSchema(name) -> schema
		AntiCheatConfig.Validate(sectionOrModuleKey, table) -> (ok, err?, clean?)
		AntiCheatConfig.SetValue(path, value, actor?) -> (ok, message)
			path = "Scoring.DecayPerMinute" | "Module.SpeedCheck.Weight"
		AntiCheatConfig.SetSection(key, table, actor?) -> (ok, message, changes)
		AntiCheatConfig.Reset(key, actor?) / ResetAll(actor?)
		AntiCheatConfig.Export() -> string (JSON) / Import(text, actor?, dryRun?)
		AntiCheatConfig.PreviewPreset(name) -> changes / ApplyPreset(name, actor?)
		AntiCheatConfig.Changed : Signal(key)
--]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Signal = require(Shared:WaitForChild("Signal"))

local Sentinel = script.Parent.Parent.Parent
local ConfigService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ConfigService"))
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))

local AntiCheatConfig = {}
AntiCheatConfig.Changed = Signal.new()

local PREFIX = "AntiCheat."
local ACTIONS = { "log", "alert", "correct", "warn", "kick", "tempban", "review", "ban" }

type Field = { Type: string, Default: any, Min: number?, Max: number?, Choices: { string }?, Description: string? }

local function num(default: number, min: number, max: number, description: string): Field
	return { Type = "number", Default = default, Min = min, Max = max, Description = description }
end
local function int(default: number, min: number, max: number, description: string): Field
	return { Type = "integer", Default = default, Min = min, Max = max, Description = description }
end
local function bool(default: boolean, description: string): Field
	return { Type = "boolean", Default = default, Description = description }
end
local function choice(default: string, choices: { string }, description: string): Field
	return { Type = "choice", Default = default, Choices = choices, Description = description }
end
local function str(default: string, max: number, description: string): Field
	return { Type = "string", Default = default, Max = max, Description = description }
end
-- A list of 5 band actions (one per score band).
local function bandList(default: { string }, description: string): Field
	return { Type = "bands", Default = default, Choices = ACTIONS, Description = description }
end

AntiCheatConfig.SCHEMA = {
	Core = {
		Enabled = bool(true, "Master switch: run detections at all"),
		Mode = choice("observe", { "observe", "balanced", "strict" }, "Global mode (Observe never punishes)"),
		Panic = bool(false, "Panic: every automatic action off, detections keep logging"),
		SetupDone = bool(false, "The setup wizard was finished"),
		ExemptRank = str("Admin", 30, "Staff at or above this rank are exempt (None = nobody)"),
		FrameBudget = int(12, 1, 200, "Most checks run in one frame"),
		CostBudgetMs = num(2, 0.5, 50, "Budget: ms of server time per second for all checks"),
	},
	Bands = {
		Band1 = int(20, 1, 999, "Score where band 2 starts (below = band 1)"),
		Band2 = int(40, 1, 999, "Score where band 3 starts"),
		Band3 = int(60, 1, 999, "Score where band 4 starts"),
		Band4 = int(80, 1, 999, "Score where band 5 starts"),
		Observe = bandList({ "log", "alert", "alert", "alert", "alert" }, "Observe mode actions (never punishes)"),
		Balanced = bandList({ "log", "alert", "warn", "kick", "review" }, "Balanced mode actions"),
		Strict = bandList({ "log", "correct", "kick", "tempban", "ban" }, "Strict mode actions"),
		RequireApproval = bool(true, "Automatic game bans need staff / owner approval"),
		PatternModules = int(3, 3, 14, "Different modules needed for a pattern ban"),
		PatternMinutes = int(10, 1, 120, "Window for the multi-module pattern (minutes)"),
		TempBanMinutes = int(60, 1, 10080, "Length of a temporary server ban"),
		BanDays = int(30, 0, 3650, "Length of an anti-cheat game ban in days (0 = permanent)"),
		DismissReduce = int(50, 0, 100, "Percent of the score removed when staff dismiss a review item"),
	},
	Scoring = {
		DecayPerMinute = num(1, 0, 50, "Points the score loses every minute"),
		ScoreCap = int(100, 20, 1000, "Highest possible score"),
		FalsePositiveFactor = num(0.5, 0.1, 1, "A false-positive mark multiplies the module's weight for that player by this"),
		MinPlayerWeight = num(0.1, 0, 1, "Lowest per-player module weight after false-positive marks"),
	},
	Grace = {
		SpawnGrace = num(3, 0, 30, "Seconds without checks after spawn / character load"),
		TeleportGrace = num(3, 0, 30, "Seconds without movement checks after a known teleport"),
		SeatGrace = num(3, 0, 30, "Seconds without movement checks after leaving a seat"),
		LagTolerance = num(1.5, 1, 5, "Lag multiplier: thresholds widen by ping and server frame time"),
		MaxPingMs = int(1000, 100, 5000, "Ping above this counts as this (caps the widening)"),
	},
	Storage = {
		HistoryLength = int(200, 10, 1000, "Flags kept per player"),
		RetentionDays = int(30, 1, 365, "Days a stored flag is kept"),
		FlushSeconds = int(30, 10, 600, "Seconds between batched DataStore writes"),
	},
	Alerts = {
		MinSeverity = int(5, 1, 10, "Lowest flag severity that alerts staff"),
		Notify = choice("view", { "view", "review", "act" }, "Who gets alerts: anticheat.view, .review or .act holders"),
		WatchAlerts = bool(true, "Alert staff when a watched player joins any server"),
	},
	CrossServer = {
		ShareAlerts = bool(true, "Send high-severity flags to every server"),
		ShareBans = bool(true, "Remove an anti-cheat banned player from every server"),
		ShareMinSeverity = int(7, 1, 10, "Lowest severity shared with other servers"),
		MaxPerMinute = int(20, 1, 120, "Most cross-server anti-cheat messages per minute"),
	},
}

AntiCheatConfig.SECTIONS = { "Core", "Bands", "Scoring", "Grace", "Storage", "Alerts", "CrossServer" }

-- Fields every module has, on top of its own Defaults.
local MODULE_COMMON: { [string]: Field } = {
	Enabled = bool(true, "Module on / off"),
	Weight = num(1, 0, 2, "How much this module adds to scores"),
	Interval = num(1, 0.1, 60, "Seconds between checks of one player"),
	Grace = num(0, 0, 30, "Extra grace seconds after spawn for this module"),
}

local moduleSchemas: { [string]: { [string]: Field } } = {}
local moduleOrder: { string } = {}

-- Presets: a full set of values per mode (previewed before applying).
AntiCheatConfig.PRESETS = {
	Observe = {
		["Core.Mode"] = "observe",
		["Core.Panic"] = false,
		["Grace.LagTolerance"] = 1.5,
		["Scoring.DecayPerMinute"] = 1,
	},
	Balanced = {
		["Core.Mode"] = "balanced",
		["Core.Panic"] = false,
		["Grace.LagTolerance"] = 1.5,
		["Scoring.DecayPerMinute"] = 1,
		["Bands.RequireApproval"] = true,
	},
	Strict = {
		["Core.Mode"] = "strict",
		["Core.Panic"] = false,
		["Grace.LagTolerance"] = 1.25,
		["Scoring.DecayPerMinute"] = 0.5,
		["Bands.RequireApproval"] = true,
	},
}

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------
local function schemaFor(key: string): { [string]: Field }?
	local moduleName = key:match("^Module%.(.+)$")
	if moduleName then
		return moduleSchemas[moduleName]
	end
	return (AntiCheatConfig.SCHEMA :: any)[key]
end

local function defaultsOf(schema: { [string]: Field }): { [string]: any }
	local out = {}
	for name, field in pairs(schema) do
		out[name] = if type(field.Default) == "table" then table.clone(field.Default) else field.Default
	end
	return out
end

-- Coerces and checks one value. Strings from commands ("on", "2.5") are
-- converted. Returns (ok, valueOrError).
local function checkField(name: string, field: Field, value: any): (boolean, any)
	if field.Type == "number" or field.Type == "integer" then
		local n = if type(value) == "string" then tonumber(value) else value
		if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
			return false, ("%s must be a number"):format(name)
		end
		if field.Type == "integer" and n % 1 ~= 0 then
			return false, ("%s must be a whole number"):format(name)
		end
		if (field.Min and n < field.Min) or (field.Max and n > field.Max) then
			return false, ("%s must be between %s and %s"):format(name, tostring(field.Min), tostring(field.Max))
		end
		return true, n
	elseif field.Type == "boolean" then
		if type(value) == "string" then
			local v = value:lower()
			if v == "on" or v == "true" or v == "yes" or v == "1" then
				return true, true
			elseif v == "off" or v == "false" or v == "no" or v == "0" then
				return true, false
			end
		end
		if type(value) ~= "boolean" then
			return false, ("%s must be on or off"):format(name)
		end
		return true, value
	elseif field.Type == "choice" then
		local v = if type(value) == "string" then value:lower() else nil
		if not v or not table.find(field.Choices :: { string }, v) then
			return false, ("%s must be one of: %s"):format(name, table.concat(field.Choices :: { string }, ", "))
		end
		return true, v
	elseif field.Type == "string" then
		if type(value) ~= "string" or #value > (field.Max or 100) or value:find("[%c]") then
			return false, ("%s must be text of at most %d characters"):format(name, field.Max or 100)
		end
		return true, value
	elseif field.Type == "bands" then
		local list = value
		if type(value) == "string" then
			local compact = value:lower():gsub("%s", "")
			list = string.split(compact, ",")
		end
		if type(list) ~= "table" or #list ~= 5 then
			return false, ("%s needs 5 actions (one per band)"):format(name)
		end
		local clean = {}
		for i = 1, 5 do
			if type(list[i]) ~= "string" or not table.find(ACTIONS, list[i]) then
				return false, ("%s: '%s' is not an action (%s)"):format(name, tostring(list[i]), table.concat(ACTIONS, ", "))
			end
			clean[i] = list[i]
		end
		return true, clean
	elseif field.Type == "list" then
		if type(value) == "string" then
			value = if value == "" then {} else string.split(value, ",")
		end
		if type(value) ~= "table" or #value > (field.Max or 100) then
			return false, ("%s must be a list of at most %d items"):format(name, field.Max or 100)
		end
		local clean = {}
		for _, item in ipairs(value) do
			local s = (tostring(item):gsub("^%s+", ""):gsub("%s+$", ""))
			if #s > 0 and #s <= 60 then
				table.insert(clean, s)
			end
		end
		return true, clean
	end
	return false, ("%s has an unknown type"):format(name)
end
AntiCheatConfig.CheckField = checkField

-- Validates a whole section table. Unknown fields are refused; missing
-- fields take their default. Extra rule: band thresholds must increase.
function AntiCheatConfig.Validate(key: string, value: any): (boolean, string?, { [string]: any }?)
	local schema = schemaFor(key)
	if not schema then
		return false, "unknown anti-cheat setting group " .. tostring(key), nil
	end
	if type(value) ~= "table" then
		return false, key .. " must be a table", nil
	end
	local clean = defaultsOf(schema)
	for name, v in pairs(value) do
		local field = schema[name]
		if not field then
			return false, ("unknown setting %s.%s"):format(key, tostring(name)), nil
		end
		local ok, result = checkField(name, field, v)
		if not ok then
			return false, result, nil
		end
		clean[name] = result
	end
	if key == "Bands" then
		if not (clean.Band1 < clean.Band2 and clean.Band2 < clean.Band3 and clean.Band3 < clean.Band4) then
			return false, "band thresholds must increase (Band1 < Band2 < Band3 < Band4)", nil
		end
		-- Observe never punishes, whatever is stored.
		for _, action in ipairs(clean.Observe) do
			if action ~= "log" and action ~= "alert" then
				return false, "Observe mode can only log or alert", nil
			end
		end
	end
	return true, nil, clean
end

-- ---------------------------------------------------------------------------
-- Storage via ConfigService (cached; the cache is dropped on change)
-- ---------------------------------------------------------------------------
local cache: { [string]: { [string]: any } } = {}

local function define(key: string)
	local schema = schemaFor(key) :: { [string]: Field }
	ConfigService.Define(PREFIX .. key, defaultsOf(schema), function(value: any): boolean
		local ok = AntiCheatConfig.Validate(key, value)
		return ok
	end)
end

for _, section in ipairs(AntiCheatConfig.SECTIONS) do
	define(section)
end

ConfigService.Changed:Connect(function(fullKey: string)
	if type(fullKey) == "string" and fullKey:sub(1, #PREFIX) == PREFIX then
		local key = fullKey:sub(#PREFIX + 1)
		cache[key] = nil
		AntiCheatConfig.Changed:Fire(key)
	end
end)

local function read(key: string): { [string]: any }
	local hit = cache[key]
	if hit then
		return hit
	end
	local schema = schemaFor(key)
	if not schema then
		return {}
	end
	local stored = ConfigService.Get(PREFIX .. key)
	local ok, _, clean = AntiCheatConfig.Validate(key, if type(stored) == "table" then stored else {})
	local value = if ok and clean then clean else defaultsOf(schema)
	cache[key] = value
	return value
end

function AntiCheatConfig.Get(section: string): { [string]: any }
	return read(section)
end

function AntiCheatConfig.GetModule(name: string): { [string]: any }
	return read("Module." .. name)
end

function AntiCheatConfig.Modules(): { string }
	return table.clone(moduleOrder)
end

-- Called by DetectionEngine for every module file it loads.
function AntiCheatConfig.RegisterModule(def: any)
	local schema: { [string]: Field } = {}
	for name, field in pairs(MODULE_COMMON) do
		schema[name] = table.clone(field)
	end
	schema.Enabled.Default = def.Enabled ~= false
	schema.Interval.Default = tonumber(def.Interval) or 1
	for name, default in pairs(def.Defaults or {}) do
		local hint = (def.Schema or {})[name] or {}
		local field: Field
		if type(default) == "boolean" then
			field = bool(default, hint.Description or name)
		elseif type(default) == "number" then
			local integer = hint.Type == "integer"
			field = {
				Type = if integer then "integer" else "number",
				Default = default,
				Min = hint.Min or 0,
				Max = hint.Max or math.max(default * 10, 10),
				Description = hint.Description or name,
			}
		elseif type(default) == "table" then
			field = { Type = "list", Default = table.clone(default), Max = hint.Max or 200, Description = hint.Description or name }
		else
			field = str(tostring(default), hint.Max or 60, hint.Description or name)
		end
		schema[name] = field
	end
	moduleSchemas[def.Name] = schema
	if not table.find(moduleOrder, def.Name) then
		table.insert(moduleOrder, def.Name)
	end
	cache["Module." .. def.Name] = nil
	define("Module." .. def.Name)
end

function AntiCheatConfig.ModuleSchema(name: string): { [string]: Field }?
	return moduleSchemas[name]
end

function AntiCheatConfig.SchemaFor(key: string): { [string]: Field }?
	return schemaFor(key)
end

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------
local function fmt(v: any): string
	if type(v) == "table" then
		local parts = {}
		for _, x in ipairs(v) do
			table.insert(parts, tostring(x))
		end
		return table.concat(parts, ",")
	end
	return tostring(v)
end

local function audit(actor: any, changes: { any }, message: string)
	if #changes == 0 then
		return
	end
	Logger.Write({
		Executor = if actor then tostring(actor.UserId) else "SYSTEM",
		ExecutorName = if actor then tostring(actor.Name) else "SYSTEM",
		Command = "anticheat.config",
		Action = "anticheat.config",
		Arguments = {},
		Result = "Success",
		Severity = "Warning",
		Message = message,
		Changes = changes,
		Source = "anticheat",
	} :: any)
end

-- Stores a validated section and returns the list of changed fields.
function AntiCheatConfig.SetSection(key: string, value: any, actor: any?): (boolean, string, { any })
	local ok, err, clean = AntiCheatConfig.Validate(key, value)
	if not ok or not clean then
		return false, err or "invalid", {}
	end
	local before = read(key)
	local changes = {}
	for name, v in pairs(clean) do
		if fmt(before[name]) ~= fmt(v) then
			table.insert(changes, { Target = "AntiCheat", Field = key .. "." .. name, Before = fmt(before[name]), After = fmt(v) })
		end
	end
	table.sort(changes, function(a, b)
		return a.Field < b.Field
	end)
	if #changes == 0 then
		return true, "Nothing changed.", changes
	end
	local saved, saveErr = ConfigService.Set(PREFIX .. key, clean, actor)
	if not saved then
		return false, saveErr or "could not save", {}
	end
	cache[key] = nil
	AntiCheatConfig.Changed:Fire(key)
	local names = {}
	for _, c in ipairs(changes) do
		table.insert(names, ("%s %s -> %s"):format(c.Field, c.Before, c.After))
	end
	local message = "Changed " .. table.concat(names, "; ")
	audit(actor, changes, message)
	return true, message, changes
end

-- path = "<Section>.<Field>" or "Module.<Name>.<Field>"
function AntiCheatConfig.SplitPath(path: string): (string?, string?)
	if type(path) ~= "string" or #path > 80 then
		return nil, nil
	end
	local moduleName, moduleField = path:match("^[Mm]odule%.([%w_]+)%.([%w_]+)$")
	if moduleName then
		for _, n in ipairs(moduleOrder) do
			if n:lower() == moduleName:lower() then
				moduleName = n
			end
		end
		local schema = moduleSchemas[moduleName]
		if schema then
			for f in pairs(schema) do
				if f:lower() == (moduleField :: string):lower() then
					return "Module." .. moduleName, f
				end
			end
		end
		return nil, nil
	end
	local section, field = path:match("^([%w_]+)%.([%w_]+)$")
	if not section then
		return nil, nil
	end
	for _, s in ipairs(AntiCheatConfig.SECTIONS) do
		if s:lower() == (section :: string):lower() then
			for f in pairs((AntiCheatConfig.SCHEMA :: any)[s]) do
				if f:lower() == (field :: string):lower() then
					return s, f
				end
			end
		end
	end
	return nil, nil
end

function AntiCheatConfig.SetValue(path: string, value: any, actor: any?): (boolean, string)
	local key, field = AntiCheatConfig.SplitPath(path)
	if not key or not field then
		return false, ("Unknown anti-cheat setting '%s'."):format(tostring(path))
	end
	local updated = table.clone(read(key))
	updated[field] = value
	local ok, message = AntiCheatConfig.SetSection(key, updated, actor)
	return ok, message
end

function AntiCheatConfig.Reset(key: string, actor: any?): (boolean, string)
	local schema = schemaFor(key)
	if not schema then
		return false, "unknown setting group " .. tostring(key)
	end
	local ok, message = AntiCheatConfig.SetSection(key, defaultsOf(schema), actor)
	return ok, if ok then key .. " reset to defaults. " .. message else message
end

function AntiCheatConfig.AllKeys(): { string }
	local keys = table.clone(AntiCheatConfig.SECTIONS)
	for _, name in ipairs(moduleOrder) do
		table.insert(keys, "Module." .. name)
	end
	return keys
end

function AntiCheatConfig.ResetAll(actor: any?): (boolean, string)
	local count = 0
	for _, key in ipairs(AntiCheatConfig.AllKeys()) do
		if key ~= "Core" then
			local ok, msg = AntiCheatConfig.Reset(key, actor)
			if ok and msg:find("Changed") then
				count += 1
			end
		end
	end
	-- Keep the master switch and setup state; reset the rest of Core.
	local core = table.clone(read("Core"))
	local defaults = defaultsOf(AntiCheatConfig.SCHEMA.Core)
	defaults.Enabled = core.Enabled
	defaults.SetupDone = core.SetupDone
	AntiCheatConfig.SetSection("Core", defaults, actor)
	return true, ("Reset %d setting group(s) to defaults."):format(count)
end

function AntiCheatConfig.Snapshot(): { [string]: any }
	local out = {}
	for _, key in ipairs(AntiCheatConfig.AllKeys()) do
		out[key] = table.clone(read(key))
	end
	return out
end

function AntiCheatConfig.Export(): string
	return HttpService:JSONEncode({ SentinelAntiCheat = 1, Config = AntiCheatConfig.Snapshot() })
end

-- Validates everything first; applies only when every group passes.
function AntiCheatConfig.Import(text: string, actor: any?, dryRun: boolean?): (boolean, string, number)
	if type(text) ~= "string" or #text > 60000 then
		return false, "The config text is missing or too long.", 0
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if not ok or type(data) ~= "table" or type(data.Config) ~= "table" then
		return false, "That is not an exported Sentinel AntiCheat config.", 0
	end
	local cleaned = {}
	for key, value in pairs(data.Config) do
		local valid, err, clean = AntiCheatConfig.Validate(tostring(key), value)
		if not valid then
			return false, ("Import refused: %s"):format(err or key), 0
		end
		cleaned[key] = clean
	end
	if dryRun then
		return true, "The config is valid.", 0
	end
	local changed = 0
	for key, clean in pairs(cleaned) do
		local done, _, changes = AntiCheatConfig.SetSection(key, clean, actor)
		if done then
			changed += #changes
		end
	end
	return true, ("Imported: %d value(s) changed."):format(changed), changed
end

function AntiCheatConfig.PreviewPreset(name: string): ({ any }?, string?)
	local preset
	for presetName, values in pairs(AntiCheatConfig.PRESETS) do
		if presetName:lower() == tostring(name):lower() then
			preset = values
		end
	end
	if not preset then
		return nil, "Preset must be Observe, Balanced or Strict."
	end
	local changes = {}
	for path, value in pairs(preset) do
		local key, field = AntiCheatConfig.SplitPath(path)
		if key and field then
			local before = read(key)[field]
			if fmt(before) ~= fmt(value) then
				table.insert(changes, { Field = path, Before = fmt(before), After = fmt(value) })
			end
		end
	end
	table.sort(changes, function(a, b)
		return a.Field < b.Field
	end)
	return changes, nil
end

function AntiCheatConfig.ApplyPreset(name: string, actor: any?): (boolean, string)
	local changes, err = AntiCheatConfig.PreviewPreset(name)
	if not changes then
		return false, err or "unknown preset"
	end
	local byKey: { [string]: { [string]: any } } = {}
	for _, c in ipairs(changes) do
		local key, field = AntiCheatConfig.SplitPath(c.Field)
		if key and field then
			byKey[key] = byKey[key] or table.clone(read(key))
			local presetValue
			for presetName, values in pairs(AntiCheatConfig.PRESETS) do
				if presetName:lower() == name:lower() then
					presetValue = values[c.Field]
				end
			end
			byKey[key][field] = presetValue
		end
	end
	for key, value in pairs(byKey) do
		local ok, message = AntiCheatConfig.SetSection(key, value, actor)
		if not ok then
			return false, message
		end
	end
	return true, ("Preset %s applied (%d value(s) changed)."):format(name, #changes)
end

-- Clears the read cache (tests).
function AntiCheatConfig._ClearCache()
	table.clear(cache)
end

return AntiCheatConfig
