--!strict
--[[
	Mute.lua

	Purpose:
		Registers "/mute" (alias "m"). Thin wrapper around
		ChatModerationService — the command layer only parses the duration
		modifier and delegates enforcement to the service.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua, DurationParser.lua (Core)
		ChatModerationService.lua (Systems)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Core = script.Parent.Parent.Parent:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))

local ChatModerationService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("ChatModerationService"))

CommandRegistry.Register({
	Name = "mute",
	Aliases = { "m" },
	Description = "Mutes a player's chat, optionally for a duration.",
	Usage = "/mute target[:duration]",
	Permission = "moderation.mute",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local duration = DurationParser.Parse(ctx.Modifier or "forever")
		if not duration then
			return { Success = false, Message = ("Invalid duration: %s"):format(ctx.Modifier or "") }
		end

		for _, target in ipairs(ctx.Targets) do
			ChatModerationService.Mute(target, duration.Seconds, duration.IsPermanent)
		end

		return {
			Success = true,
			Message = ("Muted %d player(s) %s."):format(
				#ctx.Targets,
				if duration.IsPermanent then "permanently" else "for " .. duration.Raw
			),
			Undoable = true,
			UndoData = ctx.Targets,
		}
	end,
})

CommandRegistry.Register({
	Name = "unmute",
	Aliases = { "um" },
	Description = "Removes an active mute from a player.",
	Usage = "/unmute target",
	Permission = "moderation.mute",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			ChatModerationService.Unmute(target)
		end
		return { Success = true, Message = ("Unmuted %d player(s)."):format(#ctx.Targets) }
	end,
})

return true
