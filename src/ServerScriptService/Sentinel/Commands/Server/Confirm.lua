--!strict
--[[
	Confirm.lua

	Purpose:
		;confirm runs the player's pending risky command (see
		Core/CommandPolicy and CommandProcessor.ConfirmPending). It is Public
		because it can only replay that player's OWN pending command, which
		goes through Dispatch again with full permission checks.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Core = script.Parent.Parent.Parent:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))

CommandRegistry.Register({
	Name = "confirm",
	Aliases = { "yes" },
	Description = "Runs your pending high-risk or bulk command.",
	Usage = "/confirm [id]",
	Permission = "commands.confirm",
	Public = true,
	Category = "Utility",
	Cooldown = 1,
	Log = false, -- the confirmed command logs itself
	Undoable = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local results = CommandProcessor.ConfirmPending(ctx.Executor, ctx.Arguments[1])
		-- Merge the replayed chain's results into one message.
		local ok, messages = true, {}
		for _, r in ipairs(results) do
			ok = ok and r.Success
			if r.Message then
				table.insert(messages, r.Message)
			end
		end
		return { Success = ok, Message = table.concat(messages, " | ") }
	end,
} :: any)

return true
