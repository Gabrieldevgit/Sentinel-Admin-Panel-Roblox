--!strict
--[[
	Control.lua

	Purpose:
		;control <player>   (aliases possess) - move another player's
		                    character as your own (Systems/ControlService)
		;uncontrol [player] - stop (no argument: stop your own session; with a
		                      player: free that player from whoever controls them)

	Node player.control (Admin gets it through player.*). High risk, so it
	asks for confirmation; rank protection applies (you can't control
	someone ranked equal to or above you).
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local ControlService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ControlService"))

CommandRegistry.Register({
	Name = "control",
	Aliases = { "possess" },
	Description = "Lets you move and jump as another player's character; your own character waits where it stands. Ends on ;uncontrol, death, respawn or leaving.",
	Usage = "/control player",
	Permission = "player.control",
	Category = "Player",
	Risk = "high",
	Inverse = "uncontrol",
	Log = true,
	Cooldown = 2,
	RequiresTarget = true,
	Examples = { "control Player1" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		if #ctx.Targets ~= 1 then
			return { Success = false, Message = "Control one player at a time." }
		end
		local ok, message = ControlService.Start(ctx.Executor, ctx.Targets[1])
		return { Success = ok, Message = message }
	end,
})

CommandRegistry.Register({
	Name = "uncontrol",
	Aliases = { "unpossess" },
	Description = "Stops controlling a player. With a player: frees them from whoever controls them.",
	Usage = "/uncontrol [player]",
	Permission = "player.control",
	Category = "Player",
	TargetProtection = false,
	Log = true,
	DefaultSelf = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local target = ctx.Targets[1]
		if target == ctx.Executor then
			local controlled = ControlService.TargetOf(ctx.Executor)
			if not controlled then
				return { Success = false, Message = "You aren't controlling anyone." }
			end
		end
		local ok, message = ControlService.Stop(target)
		return { Success = ok, Message = message }
	end,
})

return true
