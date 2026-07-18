--!strict
--[[
	Kick.lua

	Purpose:
		Reference implementation of a Moderator Toolkit (Phase 3) command,
		showing the full pattern every future command should follow:
		self-registration, typed Execute, EventBus notification for other
		systems (e.g. a future Discord webhook plugin) to react to.

	Responsibilities:
		- Register the "kick" command (alias "k") with CommandRegistry
		- Kick every resolved target with an optional reason

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

CommandRegistry.Register({
	Name = "kick",
	Aliases = { "k" },
	Description = "Kicks a player from the server.",
	Usage = "/kick target [reason]",
	Permission = "moderation.kick",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local reason = if #ctx.Arguments > 0 then table.concat(ctx.Arguments, " ") else "Kicked by staff."

		for _, target in ipairs(ctx.Targets) do
			EventBus.Publish("Player.BeforeKick", target, ctx.Executor, reason)
			target:Kick(reason)
		end

		return {
			Success = true,
			Message = ("Kicked %d player(s)."):format(#ctx.Targets),
			Undoable = false,
		}
	end,
})

return true
