--!strict
--[[
	Environment.lua

	Purpose:
		Registers weather, day/night, time-freeze, fog, and lighting-preset
		commands wrapping EnvironmentService.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		EnvironmentService.lua (Systems)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local EnvironmentService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EnvironmentService"))

CommandRegistry.Register({
	Name = "weather",
	Aliases = {},
	Description = "Sets the current weather preset (built-ins: clear, foggy).",
	Usage = "/weather name",
	Permission = "environment.weather",
	Category = "Environment",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local name = ctx.Arguments[1]
		if not name then
			return { Success = false, Message = "Usage: /weather name" }
		end
		if not EnvironmentService.SetWeather(name) then
			return { Success = false, Message = ("Unknown weather preset: %s"):format(name) }
		end
		return { Success = true, Message = ("Weather set to %s."):format(name) }
	end,
})

CommandRegistry.Register({
	Name = "daynight",
	Aliases = { "time" },
	Description = "Sets the time of day (0-24).",
	Usage = "/daynight hour",
	Permission = "environment.time",
	Category = "Environment",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local hour = tonumber(ctx.Arguments[1])
		if not hour then
			return { Success = false, Message = "Usage: /daynight hour (0-24)" }
		end
		EnvironmentService.SetTimeOfDay(hour)
		return { Success = true, Message = ("Time set to %s."):format(tostring(hour)) }
	end,
})

CommandRegistry.Register({
	Name = "timefreeze",
	Aliases = {},
	Description = "Freezes or unfreezes the day/night cycle.",
	Usage = "/timefreeze on|off",
	Permission = "environment.time",
	Category = "Environment",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local setting = ctx.Arguments[1]
		if setting ~= "on" and setting ~= "off" then
			return { Success = false, Message = "Usage: /timefreeze on|off" }
		end
		EnvironmentService.SetTimeFrozen(setting == "on")
		return { Success = true, Message = ("Time freeze is now %s."):format(setting) }
	end,
})

CommandRegistry.Register({
	Name = "fog",
	Aliases = {},
	Description = "Sets fog density (0-1).",
	Usage = "/fog density",
	Permission = "environment.fog",
	Category = "Environment",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local density = tonumber(ctx.Arguments[1])
		if not density then
			return { Success = false, Message = "Usage: /fog density (0-1)" }
		end
		EnvironmentService.SetFog(density)
		return { Success = true, Message = ("Fog density set to %s."):format(tostring(density)) }
	end,
})

CommandRegistry.Register({
	Name = "lightingpreset",
	Aliases = { "preset" },
	Description = "Applies a named lighting preset (built-ins: Day, Night, Sunset, Horror).",
	Usage = "/lightingpreset name",
	Permission = "environment.lighting",
	Category = "Environment",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local name = ctx.Arguments[1]
		if not name then
			return { Success = false, Message = "Usage: /lightingpreset name" }
		end
		if not EnvironmentService.ApplyLightingPreset(name) then
			return { Success = false, Message = ("Unknown lighting preset: %s"):format(name) }
		end
		return { Success = true, Message = ("Lighting preset '%s' applied."):format(name) }
	end,
})

return true
