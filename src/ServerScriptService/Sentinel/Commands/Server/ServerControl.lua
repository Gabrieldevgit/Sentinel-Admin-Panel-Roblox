--!strict
--[[
	ServerControl.lua

	Purpose:
		Registers whole-server control commands wrapping ServerStateService,
		plus /shutdown which isn't state-service-backed since it's a one-shot
		action rather than a toggle.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		ServerStateService.lua (Systems)
--]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local ServerStateService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ServerStateService"))

CommandRegistry.Register({
	Name = "shutdown",
	Aliases = {},
	Description = "Kicks every player from the server with a message. Note: this ends the server; it does not relaunch a new one (see README for the reserved-server caveat).",
	Usage = "/shutdown [message]",
	Permission = "server.shutdown",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local message = if #ctx.Arguments > 0 then table.concat(ctx.Arguments, " ") else "The server is shutting down."
		for _, player in ipairs(Players:GetPlayers()) do
			player:Kick(message)
		end
		return { Success = true, Message = "Server shutdown initiated." }
	end,
})

CommandRegistry.Register({
	Name = "lockserver",
	Aliases = { "lock" },
	Description = "Prevents new players from joining this server.",
	Usage = "/lockserver",
	Permission = "server.lock",
	Category = "Server",
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		ServerStateService.SetLocked(true)
		return { Success = true, Message = "Server locked.", Undoable = true }
	end,
})

CommandRegistry.Register({
	Name = "unlockserver",
	Aliases = { "unlock" },
	Description = "Allows new players to join this server again.",
	Usage = "/unlockserver",
	Permission = "server.lock",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		ServerStateService.SetLocked(false)
		return { Success = true, Message = "Server unlocked." }
	end,
})

CommandRegistry.Register({
	Name = "maintenancemode",
	Aliases = { "maintenance" },
	Description = "Toggles maintenance mode (kicks all new non-staff joiners).",
	Usage = "/maintenancemode on|off",
	Permission = "server.maintenance",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local setting = ctx.Arguments[1]
		if setting ~= "on" and setting ~= "off" then
			return { Success = false, Message = "Usage: /maintenancemode on|off" }
		end
		ServerStateService.SetMaintenanceMode(setting == "on")
		return { Success = true, Message = ("Maintenance mode is now %s."):format(setting) }
	end,
})

CommandRegistry.Register({
	Name = "slowmode",
	Aliases = {},
	Description = "Sets a minimum number of seconds between chat messages per player.",
	Usage = "/slowmode seconds",
	Permission = "server.slowmode",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local seconds = tonumber(ctx.Arguments[1])
		if not seconds then
			return { Success = false, Message = "Usage: /slowmode seconds (0 to disable)" }
		end
		ServerStateService.SetSlowMode(seconds)
		return { Success = true, Message = ("Slow mode set to %d second(s)."):format(seconds) }
	end,
})

return true
