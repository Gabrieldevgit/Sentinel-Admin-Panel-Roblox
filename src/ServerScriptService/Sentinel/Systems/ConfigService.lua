--!strict
--[[
	ConfigService.lua (W07)

	Purpose:
		Server-wide Sentinel settings that staff change in game (not the
		static Shared/Config.lua). Persisted in the DataStore
		Sentinel_Config_v1 (key "Global") and pushed to every server through
		MessagingService so a change applies everywhere.

		W07 uses it for chat command prefixes; W08 adds the rest of the admin
		configuration (cooldowns, ban defaults, required reasons, ...).

	Public API:
		ConfigService.Get(key) -> value (a copy for tables)
		ConfigService.Set(key, value, actor?) -> (ok, err?)
		ConfigService.Changed : Signal(key, value)
		ConfigService.GetPrefixes() -> { string }
		ConfigService.MatchPrefix(text) -> (prefixLength?)  -- 1-char prefixes
		ConfigService.ALLOWED_PREFIXES
		ConfigService.Define(key, default, validator?)   -- W08: other systems
			(Systems/AdminConfig) add their own keys; a value loaded from the
			DataStore before Define is kept and applied when it passes.
		ConfigService.Reset(key, actor?) -> (ok, err?)
		ConfigService.GetDefault(key) -> value

	Outside a running game (unit tests) the DataStore and MessagingService
	are never touched.
--]]

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Signal"))
local Logger = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Logger"))

local ConfigService = {}
ConfigService.Changed = Signal.new()

local STORE_NAME = "Sentinel_Config_v1"
local KEY = "Global"
local TOPIC = "SentinelConfig"

-- Prefixes a server may use. "/" works but collides with Roblox's own chat
-- commands (/w, /e, ...) — those are handled by Roblox first.
ConfigService.ALLOWED_PREFIXES = { ";", ":", "!", ".", "/", "-", "?", ">" }

local DEFAULTS: { [string]: any } = {
	Prefixes = { ";" },
	-- Owner-chosen UI defaults (panel theme, command bar look). Validated
	-- field by field by Shared/UIPrefs.Sanitize in Systems/PrefsService.
	UIDefaults = {},
}

local values: { [string]: any } = table.clone(DEFAULTS)
local loadedRaw: { [string]: any }? = nil -- last DataStore read (for late Define)
local live = RunService:IsRunning() and RunService:IsServer()
local store = if live then DataStoreService:GetDataStore(STORE_NAME) else nil
local serverId = HttpService:GenerateGUID(false)

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = deepCopy(x)
	end
	return out
end

local function validPrefixes(list: any): boolean
	if type(list) ~= "table" or #list == 0 or #list > #ConfigService.ALLOWED_PREFIXES then
		return false
	end
	for _, p in ipairs(list) do
		if not table.find(ConfigService.ALLOWED_PREFIXES, p) then
			return false
		end
	end
	return true
end

local VALIDATORS: { [string]: (any) -> boolean } = {
	Prefixes = validPrefixes,
	UIDefaults = function(value: any): boolean
		return type(value) == "table"
	end,
}

local function apply(key: string, value: any)
	values[key] = value
	ConfigService.Changed:Fire(key, deepCopy(value))
end

if store then
	task.spawn(function()
		local ok, data = pcall(function()
			return (store :: DataStore):GetAsync(KEY)
		end)
		if ok and type(data) == "table" then
			loadedRaw = data
			for key, value in pairs(data) do
				local check = VALIDATORS[key]
				if DEFAULTS[key] ~= nil and (not check or check(value)) then
					apply(key, value)
				end
			end
		elseif not ok then
			warn("[Sentinel.ConfigService] load failed, using defaults: " .. tostring(data))
		end
	end)
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message)
				local data = message.Data
				if type(data) == "table" and data.From ~= serverId and type(data.Key) == "string" then
					local check = VALIDATORS[data.Key]
					if DEFAULTS[data.Key] ~= nil and (not check or check(data.Value)) then
						apply(data.Key, data.Value)
					end
				end
			end)
		end)
	end)
end

function ConfigService.Define(key: string, default: any, validator: ((any) -> boolean)?)
	DEFAULTS[key] = deepCopy(default)
	VALIDATORS[key] = validator :: any
	local stored = loadedRaw and (loadedRaw :: any)[key]
	if stored ~= nil and (not validator or validator(stored)) then
		apply(key, stored)
	elseif values[key] == nil then
		values[key] = deepCopy(default)
	end
end

function ConfigService.GetDefault(key: string): any
	return deepCopy(DEFAULTS[key])
end

function ConfigService.Reset(key: string, actor: Player?): (boolean, string?)
	if DEFAULTS[key] == nil then
		return false, "unknown setting " .. key
	end
	return ConfigService.Set(key, deepCopy(DEFAULTS[key]), actor)
end

function ConfigService.Get(key: string): any
	return deepCopy(values[key])
end

function ConfigService.Set(key: string, value: any, actor: Player?): (boolean, string?)
	if DEFAULTS[key] == nil then
		return false, "unknown setting " .. key
	end
	local check = VALIDATORS[key]
	if check and not check(value) then
		return false, "invalid value for " .. key
	end
	Logger.NoteChange("config", key, values[key], value, actor, "config.set")
	apply(key, deepCopy(value))
	if store then
		task.spawn(function()
			local ok, err = pcall(function()
				(store :: DataStore):UpdateAsync(KEY, function(old)
					local data = if type(old) == "table" then old else {}
					data[key] = value
					return data
				end)
			end)
			if not ok then
				warn("[Sentinel.ConfigService] save failed: " .. tostring(err))
			end
			pcall(function()
				MessagingService:PublishAsync(TOPIC, { From = serverId, Key = key, Value = value })
			end)
		end)
	end
	return true
end

function ConfigService.GetPrefixes(): { string }
	return deepCopy(values.Prefixes)
end

-- Returns 1 when `text` starts with an active prefix followed by a command
-- letter (so "...", ":)" or "!!!" in normal chat aren't treated as commands).
function ConfigService.MatchPrefix(text: string): number?
	local first = text:sub(1, 1)
	if table.find(values.Prefixes, first) and text:sub(2, 2):match("[%a%?]") then
		return 1
	end
	return nil
end

return ConfigService
