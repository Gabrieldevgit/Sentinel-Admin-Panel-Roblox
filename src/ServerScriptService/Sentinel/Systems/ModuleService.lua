--!strict
--[[
	ModuleService.lua (W-FINAL.1 - Module Manager foundation)

	Central registry for optional gameplay modules. Every module is a
	ModuleScript in ServerScriptService.Sentinel.Modules returning a manifest:

		{
			Id, Name, Description, Category, Version, Icon?, Docs?,
			Changelog = { { Version, Date, Notes } },
			Features = { string }, Rigs = { "R6", "R15" }, Platforms = { ... },
			Services = { "ContextActionService", ... },
			Dependencies = { moduleId }, Conflicts = { moduleId },
			Integrations = { { Id, Description } },  -- optional modules it uses
			Config = { { Key, Type = number|integer|boolean|choice|key|string,
			             Default, Min?, Max?, Choices?, Label, Description } },
			Client = "<name of StarterPlayerScripts.Sentinel.Modules child>"?,
			Compatibility = function(config) -> { warnings }?,
			Activate = function(ctx) -> ()?    -- ctx below; error = activation failed
			Deactivate = function(ctx) -> ()?  -- must clean up everything
			OnConfig = function(ctx, config) -> ()?  -- live config change
			OnClientMessage = function(ctx, player, ...) -> ()?
			Diagnostics = function(ctx) -> { [string]: any }?
		}

	ctx = { Id, Config (current, sanitized), Send(player|nil, ...) (to the
	module's client component; nil = everyone), Track(conn|instance|fn)
	(cleaned up on deactivate), Warn(text), State = {} (module-owned) }.

	State: ConfigService key `Modules` = { [id] = { Enabled, Config, Version } }
	(DataStore + MessagingService: every server reconciles on change).
	ConfigService key `ModuleActivity` = newest-first admin actions (50).
	Status per module: Disabled | Needs Setup | Enabled | Error |
	Incompatible (missing dependency / conflict) | Restart Required.

	Remote `ModuleRemote` (RemoteEvent):
		server -> client ("state", { { Id, Client, Enabled, Config } })
		                 ("msg", id, ...)  module-specific
		client -> server ("sync") | ("msg", id, ...) -> OnClientMessage
		(rate limited 20 / 10 per s per player; only enabled modules).

	Public API:
		ModuleService.List() -> { summary }        (for UI / ;modules)
		ModuleService.Get(id) -> detail
		ModuleService.SetEnabled(id, on, actor) -> (ok, message)
		ModuleService.SetValue(id, key, raw, actor) -> (ok, message)
		ModuleService.ResetConfig(id, actor) -> (ok, message)
		ModuleService.Find(text) -> id?
		ModuleService.SanitizeConfig(schema, config) -> (clean, errors)  (pure)
		ModuleService.ParseValue(field, raw) -> (value?, err?)        (pure)
		ModuleService.Register(manifest)  (tests / modules outside the folder)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Sentinel = script.Parent.Parent
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))
local RateLimiter = require(Sentinel:WaitForChild("Core"):WaitForChild("RateLimiter"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local ModuleService = {}

local LIVE = RunService:IsServer() and RunService:IsRunning()
local ACTIVITY_MAX = 50
local RUNTIME_LOG_MAX = 40

type Field = { Key: string, Type: string, Default: any, Min: number?, Max: number?, Choices: { string }?, Label: string?, Description: string?, MaxLength: number? }

local manifests: { [string]: any } = {}
local orderList: { string } = {}
local runtime: { [string]: any } = {} -- id -> { Active, Ctx, Cleanup, Error, Log, Since, Warnings }

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------
local KEY_NAMES: { [string]: boolean } = {}
for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
	KEY_NAMES[item.Name] = true
end

local function canonicalKey(raw: string): string?
	local lower = raw:lower():gsub("%s", "")
	local aliases = { shift = "LeftShift", lshift = "LeftShift", rshift = "RightShift", ctrl = "LeftControl", control = "LeftControl", lctrl = "LeftControl", alt = "LeftAlt" }
	if aliases[lower] then
		return aliases[lower]
	end
	for name in pairs(KEY_NAMES) do
		if name:lower() == lower then
			return name
		end
	end
	return nil
end

function ModuleService.ParseValue(field: Field, raw: any): (any, string?)
	local t = field.Type
	if t == "boolean" then
		if type(raw) == "boolean" then
			return raw
		end
		local s = tostring(raw):lower()
		if s == "on" or s == "true" or s == "yes" or s == "1" then
			return true
		elseif s == "off" or s == "false" or s == "no" or s == "0" then
			return false
		end
		return nil, ("%s must be on or off"):format(field.Key)
	elseif t == "number" or t == "integer" then
		local n = tonumber(raw)
		if not n or n ~= n then
			return nil, ("%s must be a number"):format(field.Key)
		end
		if t == "integer" and n % 1 ~= 0 then
			return nil, ("%s must be a whole number"):format(field.Key)
		end
		if (field.Min and n < field.Min) or (field.Max and n > field.Max) then
			return nil, ("%s must be between %s and %s"):format(field.Key, tostring(field.Min or "-inf"), tostring(field.Max or "inf"))
		end
		return n
	elseif t == "choice" then
		local s = tostring(raw):lower()
		for _, c in ipairs(field.Choices or {}) do
			if c:lower() == s then
				return c
			end
		end
		return nil, ("%s must be one of: %s"):format(field.Key, table.concat(field.Choices or {}, ", "))
	elseif t == "key" then
		if type(raw) ~= "string" then
			return nil, ("%s must be a key name"):format(field.Key)
		end
		if raw:lower() == "none" then
			return "None"
		end
		local name = canonicalKey(raw)
		if not name or name == "Unknown" then
			return nil, ("%s: unknown key '%s'"):format(field.Key, raw)
		end
		return name
	elseif t == "string" then
		if type(raw) ~= "string" then
			return nil, ("%s must be text"):format(field.Key)
		end
		if #raw > (field.MaxLength or 60) then
			return nil, ("%s is too long"):format(field.Key)
		end
		return raw
	end
	return nil, "unknown setting type " .. tostring(t)
end

-- Returns a clean config (every schema key present, invalid values -> default).
function ModuleService.SanitizeConfig(schema: { Field }, config: any): ({ [string]: any }, { string })
	local clean: { [string]: any } = {}
	local errors = {}
	local given = if type(config) == "table" then config else {}
	for _, field in ipairs(schema) do
		local raw = given[field.Key]
		if raw == nil then
			clean[field.Key] = field.Default
		else
			local value, err = ModuleService.ParseValue(field, raw)
			if value == nil then
				clean[field.Key] = field.Default
				table.insert(errors, err or field.Key)
			else
				clean[field.Key] = value
			end
		end
	end
	return clean, errors
end

-- Public view of a manifest's schema (no functions).
local function schemaView(schema: { Field }): { any }
	local out = {}
	for i, f in ipairs(schema) do
		out[i] = { Key = f.Key, Type = f.Type, Default = f.Default, Min = f.Min, Max = f.Max, Choices = f.Choices, Label = f.Label or f.Key, Description = f.Description }
	end
	return out
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local function validState(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for id, s in pairs(v) do
		if type(id) ~= "string" or type(s) ~= "table" then
			return false
		end
	end
	return true
end
ConfigService.Define("Modules", {}, validState)
ConfigService.Define("ModuleActivity", {}, function(v)
	return type(v) == "table"
end)

local function stored(id: string): any
	local all = ConfigService.Get("Modules") or {}
	return all[id] or {}
end

local function configOf(id: string): { [string]: any }
	local m = manifests[id]
	local clean = ModuleService.SanitizeConfig(m.Config or {}, stored(id).Config)
	return clean
end

local function rt(id: string): any
	local r = runtime[id]
	if not r then
		r = { Active = false, Log = {}, Warnings = {} }
		runtime[id] = r
	end
	return r
end

local function runtimeLog(id: string, kind: string, text: string)
	local r = rt(id)
	table.insert(r.Log, 1, { At = os.time(), Kind = kind, Text = text })
	while #r.Log > RUNTIME_LOG_MAX do
		table.remove(r.Log)
	end
end

local function recordActivity(id: string, kind: string, text: string, actor: Player?)
	local list = ConfigService.Get("ModuleActivity") or {}
	table.insert(list, 1, { At = os.time(), Id = id, Kind = kind, Text = text, By = if actor then actor.Name else "SYSTEM" })
	while #list > ACTIVITY_MAX do
		table.remove(list)
	end
	ConfigService.Set("ModuleActivity", list, actor)
	Logger.Write({
		Executor = if actor then tostring(actor.UserId) else "SYSTEM",
		ExecutorName = if actor then actor.Name else "SYSTEM",
		Command = "module." .. kind,
		Action = "modules." .. kind,
		Target = id,
		Arguments = { text },
		Result = "Success",
		Severity = "Info",
		Message = text,
		Source = "modules",
	})
end

-- Missing dependencies / enabled conflicts (only enabled modules count).
local function compatibility(id: string, wantEnabled: { [string]: boolean }?): { string }
	local m = manifests[id]
	local problems = {}
	local enabledSet = wantEnabled or {}
	if not wantEnabled then
		for other in pairs(manifests) do
			enabledSet[other] = stored(other).Enabled == true
		end
	end
	for _, dep in ipairs(m.Dependencies or {}) do
		if not manifests[dep] then
			table.insert(problems, ("needs module '%s' (not installed)"):format(dep))
		elseif not enabledSet[dep] then
			table.insert(problems, ("needs module '%s' enabled"):format(manifests[dep].Name))
		end
	end
	for _, other in ipairs(m.Conflicts or {}) do
		if enabledSet[other] then
			table.insert(problems, ("conflicts with '%s'"):format(if manifests[other] then manifests[other].Name else other))
		end
	end
	return problems
end

local function warningsOf(id: string, config: { [string]: any }): { string }
	local m = manifests[id]
	if type(m.Compatibility) ~= "function" then
		return {}
	end
	local ok, list = pcall(m.Compatibility, config)
	if ok and type(list) == "table" then
		return list
	end
	return { "compatibility check failed: " .. tostring(list) }
end

-- ---------------------------------------------------------------------------
-- Client channel
-- ---------------------------------------------------------------------------
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local remote: RemoteEvent? = nil
if LIVE then
	local r = SentinelShared:FindFirstChild("ModuleRemote")
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = "ModuleRemote"
		r.Parent = SentinelShared
	end
	remote = r :: RemoteEvent
end

local function clientState(): { any }
	local list = {}
	for _, id in ipairs(orderList) do
		local m = manifests[id]
		if m.Client then
			local r = rt(id)
			table.insert(list, { Id = id, Client = m.Client, Enabled = r.Active == true, Config = configOf(id) })
		end
	end
	return list
end

local function pushState(player: Player?)
	if not remote then
		return
	end
	local list = clientState()
	if player then
		remote:FireClient(player, "state", list)
	else
		remote:FireAllClients("state", list)
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function cleanup(r: any)
	for i = #(r.Cleanup or {}), 1, -1 do
		local item = r.Cleanup[i]
		pcall(function()
			if typeof(item) == "RBXScriptConnection" then
				item:Disconnect()
			elseif typeof(item) == "Instance" then
				item:Destroy()
			elseif type(item) == "function" then
				item()
			end
		end)
	end
	r.Cleanup = {}
end

local function activate(id: string): (boolean, string?)
	local m = manifests[id]
	local r = rt(id)
	if r.Active then
		return true -- duplicate initialization guard
	end
	local problems = compatibility(id)
	if #problems > 0 then
		r.Error = "Incompatible: " .. table.concat(problems, "; ")
		runtimeLog(id, "error", r.Error)
		return false, r.Error
	end
	local config = configOf(id)
	r.Cleanup = {}
	local ctx = {
		Id = id,
		Config = config,
		State = {},
		Send = function(player: Player?, ...)
			if not remote then
				return
			end
			if player then
				remote:FireClient(player, "msg", id, ...)
			else
				remote:FireAllClients("msg", id, ...)
			end
		end,
		Track = function(item: any)
			table.insert(r.Cleanup, item)
			return item
		end,
		Warn = function(text: string)
			runtimeLog(id, "warning", text)
		end,
	}
	r.Ctx = ctx
	local ok, err = true, nil
	if type(m.Activate) == "function" then
		ok, err = pcall(m.Activate, ctx)
	end
	if not ok then
		cleanup(r)
		r.Active = false
		r.Ctx = nil
		r.Error = "Activation failed: " .. tostring(err)
		runtimeLog(id, "error", r.Error)
		warn(("[Sentinel.Modules] %s: %s"):format(id, r.Error))
		return false, r.Error
	end
	r.Active = true
	r.Error = nil
	r.Since = os.time()
	runtimeLog(id, "info", "Activated (v" .. tostring(m.Version) .. ")")
	return true
end

local function deactivate(id: string)
	local m = manifests[id]
	local r = rt(id)
	if not r.Active then
		return
	end
	if type(m.Deactivate) == "function" and r.Ctx then
		local ok, err = pcall(m.Deactivate, r.Ctx)
		if not ok then
			runtimeLog(id, "error", "Deactivate errored: " .. tostring(err))
		end
	end
	cleanup(r)
	r.Active = false
	r.Ctx = nil
	r.Since = nil
	runtimeLog(id, "info", "Deactivated")
end

-- Brings every module in line with the stored state (boot / config change).
local function reconcile()
	for _, id in ipairs(orderList) do
		local want = stored(id).Enabled == true
		local r = rt(id)
		if want and not r.Active then
			activate(id)
		elseif not want and r.Active then
			deactivate(id)
		elseif want and r.Active and r.Ctx then
			local config = configOf(id)
			local changed = false
			for k, v in pairs(config) do
				if r.Ctx.Config[k] ~= v then
					changed = true
				end
			end
			if changed then
				r.Ctx.Config = config
				local m = manifests[id]
				if type(m.OnConfig) == "function" then
					local ok, err = pcall(m.OnConfig, r.Ctx, config)
					if not ok then
						runtimeLog(id, "error", "Config update errored: " .. tostring(err))
					end
				end
				runtimeLog(id, "info", "Configuration applied")
			end
		end
		if not want then
			r.Error = nil
		end
	end
	pushState(nil)
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------
function ModuleService.Register(manifest: any)
	assert(type(manifest) == "table" and type(manifest.Id) == "string", "module manifest needs an Id")
	assert(not manifests[manifest.Id], "duplicate module id " .. manifest.Id)
	manifests[manifest.Id] = manifest
	table.insert(orderList, manifest.Id)
end

function ModuleService._UnregisterForTests(id: string)
	if runtime[id] then
		deactivate(id)
	end
	manifests[id] = nil
	runtime[id] = nil
	local i = table.find(orderList, id)
	if i then
		table.remove(orderList, i)
	end
end

function ModuleService.Find(text: any): string?
	if type(text) ~= "string" then
		return nil
	end
	local q = text:lower():gsub("[%s%-_]", "")
	for _, id in ipairs(orderList) do
		local m = manifests[id]
		if id:lower() == q or tostring(m.Name):lower():gsub("[%s%-_]", "") == q then
			return id
		end
	end
	return nil
end

local function statusOf(id: string): string
	local r = rt(id)
	local enabled = stored(id).Enabled == true
	if enabled and r.Error then
		return if r.Error:sub(1, 12) == "Incompatible" then "Incompatible" else "Error"
	end
	if enabled and r.Active then
		return "Enabled"
	end
	if enabled and not r.Active then
		return "Restart Required"
	end
	local _, errors = ModuleService.SanitizeConfig(manifests[id].Config or {}, stored(id).Config)
	if #errors > 0 then
		return "Needs Setup"
	end
	if #compatibility(id, nil) > 0 then
		return "Incompatible"
	end
	return "Disabled"
end

function ModuleService.List(): { any }
	local out = {}
	for _, id in ipairs(orderList) do
		local m = manifests[id]
		local config = configOf(id)
		table.insert(out, {
			Id = id,
			Name = m.Name,
			Description = m.Description,
			Category = m.Category,
			Version = m.Version,
			Icon = m.Icon,
			Status = statusOf(id),
			Enabled = stored(id).Enabled == true,
			Active = rt(id).Active == true,
			Dependencies = m.Dependencies or {},
			Conflicts = m.Conflicts or {},
			Warnings = warningsOf(id, config),
			Problems = compatibility(id),
			LastUpdate = (m.Changelog and m.Changelog[1] and m.Changelog[1].Date) or nil,
		})
	end
	return out
end

function ModuleService.Get(id: string): any
	local m = manifests[id]
	if not m then
		return nil
	end
	local r = rt(id)
	local config = configOf(id)
	local diag = nil
	if r.Active and type(m.Diagnostics) == "function" and r.Ctx then
		local ok, d = pcall(m.Diagnostics, r.Ctx)
		diag = if ok then d else { Error = tostring(d) }
	end
	local activity = {}
	for _, a in ipairs(ConfigService.Get("ModuleActivity") or {}) do
		if a.Id == id then
			table.insert(activity, a)
		end
	end
	local summary
	for _, s in ipairs(ModuleService.List()) do
		if s.Id == id then
			summary = s
		end
	end
	summary.Docs = m.Docs
	summary.Features = m.Features or {}
	summary.Rigs = m.Rigs or {}
	summary.Platforms = m.Platforms or {}
	summary.Services = m.Services or {}
	summary.Integrations = m.Integrations or {}
	summary.Changelog = m.Changelog or {}
	summary.Schema = schemaView(m.Config or {})
	summary.Config = config
	summary.Defaults = ModuleService.SanitizeConfig(m.Config or {}, nil)
	summary.Runtime = r.Log
	summary.Error = r.Error
	summary.Since = r.Since
	summary.Activity = activity
	summary.Diagnostics = diag
	summary.Permissions = {
		View = "modules.view",
		Configure = "modules.configure",
		Activate = "modules.activate",
		Disable = "modules.disable",
		Diagnostics = "modules.diagnostics",
		Operate = m.OperateNode,
	}
	return summary
end

local function saveState(id: string, change: (any) -> ())
	local all = ConfigService.Get("Modules") or {}
	local entry = all[id] or {}
	change(entry)
	entry.Version = manifests[id].Version
	all[id] = entry
	return ConfigService.Set("Modules", all)
end

function ModuleService.SetEnabled(id: string, on: boolean, actor: Player?): (boolean, string)
	local m = manifests[id]
	if not m then
		return false, "Unknown module."
	end
	if (stored(id).Enabled == true) == on and rt(id).Active == on then
		return false, ("%s is already %s."):format(m.Name, if on then "enabled" else "disabled")
	end
	if on then
		local problems = compatibility(id)
		if #problems > 0 then
			return false, ("%s can't be enabled: %s."):format(m.Name, table.concat(problems, "; "))
		end
		local _, errors = ModuleService.SanitizeConfig(m.Config or {}, stored(id).Config)
		if #errors > 0 then
			return false, ("%s needs setup first: %s."):format(m.Name, table.concat(errors, "; "))
		end
		-- something enabled depends on? (only matters for disable)
		local ok, err = activate(id)
		if not ok then
			return false, err or "Activation failed."
		end
	else
		for _, other in ipairs(orderList) do
			if other ~= id and rt(other).Active and table.find(manifests[other].Dependencies or {}, id) then
				return false, ("%s is needed by %s - disable that first."):format(m.Name, manifests[other].Name)
			end
		end
		deactivate(id)
	end
	saveState(id, function(e)
		e.Enabled = on
	end)
	recordActivity(id, if on then "enable" else "disable", ("%s %s"):format(m.Name, if on then "enabled" else "disabled"), actor)
	pushState(nil)
	local warnings = warningsOf(id, configOf(id))
	local suffix = if on and #warnings > 0 then " Warning: " .. table.concat(warnings, " ") else ""
	return true, ("%s %s.%s"):format(m.Name, if on then "enabled" else "disabled", suffix)
end

function ModuleService.SetValue(id: string, key: string, raw: any, actor: Player?): (boolean, string)
	local m = manifests[id]
	if not m then
		return false, "Unknown module."
	end
	local field
	for _, f in ipairs(m.Config or {}) do
		if f.Key:lower() == tostring(key):lower() then
			field = f
		end
	end
	if not field then
		local keys = {}
		for _, f in ipairs(m.Config or {}) do
			table.insert(keys, f.Key)
		end
		return false, ("%s has no setting '%s'. Settings: %s"):format(m.Name, tostring(key), table.concat(keys, ", "))
	end
	local value, err = ModuleService.ParseValue(field, raw)
	if value == nil then
		return false, err or "Invalid value."
	end
	local before = configOf(id)[field.Key]
	saveState(id, function(e)
		e.Config = if type(e.Config) == "table" then e.Config else {}
		e.Config[field.Key] = value
	end)
	recordActivity(id, "configure", ("%s.%s: %s -> %s"):format(id, field.Key, tostring(before), tostring(value)), actor)
	reconcile()
	return true, ("%s: %s = %s"):format(m.Name, field.Label or field.Key, tostring(value))
end

function ModuleService.ResetConfig(id: string, actor: Player?): (boolean, string)
	local m = manifests[id]
	if not m then
		return false, "Unknown module."
	end
	saveState(id, function(e)
		e.Config = {}
	end)
	recordActivity(id, "reset", m.Name .. " configuration reset to defaults", actor)
	reconcile()
	return true, m.Name .. " configuration reset to defaults."
end

function ModuleService.IsActive(id: string): boolean
	return rt(id).Active == true
end

-- ---------------------------------------------------------------------------
-- Discovery + wiring
-- ---------------------------------------------------------------------------
local folder = Sentinel:FindFirstChild("Modules")
if folder then
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ModuleScript") then
			local ok, manifest = pcall(require, child)
			if ok and type(manifest) == "table" and type(manifest.Id) == "string" then
				local okReg, err = pcall(ModuleService.Register, manifest)
				if not okReg then
					warn("[Sentinel.Modules] " .. tostring(err))
				end
			else
				warn(("[Sentinel.Modules] could not load %s: %s"):format(child.Name, tostring(manifest)))
			end
		end
	end
	table.sort(orderList, function(a, b)
		return tostring(manifests[a].Name) < tostring(manifests[b].Name)
	end)
end

if LIVE then
	ConfigService.Changed:Connect(function(key)
		if key == "Modules" then
			task.defer(reconcile)
		end
	end)
	task.defer(reconcile)

	local limiter = RateLimiter.new("ModuleRemote", 20, 10)
	;(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, action: any, id: any, ...)
		if not limiter:Allow(player) then
			return
		end
		if action == "sync" then
			pushState(player)
		elseif action == "msg" and type(id) == "string" then
			local m = manifests[id]
			local r = runtime[id]
			if m and r and r.Active and r.Ctx and type(m.OnClientMessage) == "function" then
				local ok, err = pcall(m.OnClientMessage, r.Ctx, player, ...)
				if not ok then
					runtimeLog(id, "error", "Client message errored: " .. tostring(err))
				end
			end
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.delay(1, function()
			if player.Parent then
				pushState(player)
			end
		end)
	end)
end

return ModuleService
