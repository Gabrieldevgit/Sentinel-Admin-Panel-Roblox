--!strict
--[[
	EnvironmentService.lua

	Purpose:
		Centralizes every Lighting/atmosphere-related control so commands
		stay thin wrappers. Owns the "is time frozen" loop so freezing time
		and setting time don't fight each other.

	Responsibilities:
		- Apply named weather presets (toggles a workspace Atmosphere/rain
		  effect the game owner sets up, identified by name)
		- Set time of day, with an optional freeze that stops Lighting's
		  own day/night progression
		- Set fog density/color
		- Apply named Lighting presets (property bags defined here, or
		  extended via RegisterLightingPreset)

	Dependencies:
		Types.lua, EventBus.lua (Shared)

	Public API:
		EnvironmentService.SetWeather(name: string): boolean
		EnvironmentService.SetTimeOfDay(hour: number): ()
		EnvironmentService.SetTimeFrozen(frozen: boolean): ()
		EnvironmentService.SetFog(density: number, color: Color3?): ()
		EnvironmentService.ApplyLightingPreset(name: string): boolean
		EnvironmentService.RegisterLightingPreset(name, properties): ()
		EnvironmentService.RegisterWeather(name, applyFn): ()
--]]

local Lighting = game:GetService("Lighting")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local EnvironmentService = {}

-- ---------------------------------------------------------------------------
-- Time of day / freeze
-- ---------------------------------------------------------------------------
local timeFrozen = false
local originalClockTime = Lighting.ClockTime

function EnvironmentService.SetTimeOfDay(hour: number)
	Lighting.ClockTime = hour % 24
	EventBus.Publish("Environment.TimeChanged", hour)
end

function EnvironmentService.SetTimeFrozen(frozen: boolean)
	timeFrozen = frozen
	if frozen then
		originalClockTime = Lighting.ClockTime
	end
	EventBus.Publish("Environment.TimeFrozenChanged", frozen)
end

function EnvironmentService.IsTimeFrozen(): boolean
	return timeFrozen
end

-- Roblox doesn't natively pause day/night progression, so if a game's
-- Lighting is configured to auto-cycle (e.g. via a separate day/night
-- script), this loop re-pins ClockTime every frame while frozen. Games
-- with no auto-cycling script running don't need this at all, but it's
-- a harmless no-op in that case (ClockTime just gets rewritten to itself).
task.spawn(function()
	while true do
		task.wait()
		if timeFrozen then
			Lighting.ClockTime = originalClockTime
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Fog
-- ---------------------------------------------------------------------------
function EnvironmentService.SetFog(density: number, color: Color3?)
	-- density is 0-1 conceptually; map to FogEnd (lower FogEnd = thicker fog)
	local clamped = math.clamp(density, 0, 1)
	Lighting.FogEnd = 1000 * (1 - clamped) + 10
	Lighting.FogStart = 0
	if color then
		Lighting.FogColor = color
	end
	EventBus.Publish("Environment.FogChanged", density, color)
end

-- ---------------------------------------------------------------------------
-- Lighting presets
-- ---------------------------------------------------------------------------
local lightingPresets: { [string]: { [string]: any } } = {
	Day = { ClockTime = 14, Brightness = 2, Ambient = Color3.fromRGB(150, 150, 150), FogEnd = 100000 },
	Night = { ClockTime = 0, Brightness = 1, Ambient = Color3.fromRGB(40, 40, 60), FogEnd = 100000 },
	Sunset = { ClockTime = 18, Brightness = 1.5, Ambient = Color3.fromRGB(180, 120, 90), FogEnd = 100000 },
	Horror = { ClockTime = 0, Brightness = 0.3, Ambient = Color3.fromRGB(20, 20, 20), FogEnd = 60, FogColor = Color3.new(0, 0, 0) },
}

function EnvironmentService.RegisterLightingPreset(name: string, properties: { [string]: any })
	lightingPresets[name] = properties
end

function EnvironmentService.ApplyLightingPreset(name: string): boolean
	local preset = lightingPresets[name]
	if not preset then
		return false
	end
	for property, value in pairs(preset) do
		(Lighting :: any)[property] = value
	end
	EventBus.Publish("Environment.LightingPresetApplied", name)
	return true
end

-- ---------------------------------------------------------------------------
-- Weather
-- ---------------------------------------------------------------------------
local weatherHandlers: { [string]: () -> () } = {}
local currentWeather: string? = nil

function EnvironmentService.RegisterWeather(name: string, applyFn: () -> ())
	weatherHandlers[name] = applyFn
end

function EnvironmentService.SetWeather(name: string): boolean
	local handler = weatherHandlers[name]
	if not handler then
		return false
	end
	handler()
	currentWeather = name
	EventBus.Publish("Environment.WeatherChanged", name)
	return true
end

function EnvironmentService.GetWeather(): string?
	return currentWeather
end

-- Built-in "clear" weather always available so /weather clear works even if
-- the game hasn't registered any custom weather effects yet.
EnvironmentService.RegisterWeather("clear", function()
	EnvironmentService.SetFog(0)
end)
EnvironmentService.RegisterWeather("foggy", function()
	EnvironmentService.SetFog(0.7, Color3.fromRGB(200, 200, 200))
end)

return EnvironmentService
