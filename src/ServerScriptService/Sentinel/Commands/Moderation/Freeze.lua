--!strict
--[[
	Freeze.lua

	Purpose:
		Registers "/freeze" and "/unfreeze". Locks a player's character in
		place by zeroing WalkSpeed/JumpPower and anchoring the
		HumanoidRootPart, and marks the character with an attribute so the
		state survives being re-applied if the character respawns while
		still flagged frozen (handled via CharacterAdded below).

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local FROZEN_ATTRIBUTE = "SentinelFrozen"

local function applyFreezeState(character: Model, frozen: boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	if humanoid then
		humanoid.WalkSpeed = if frozen then 0 else 16
		humanoid.JumpPower = if frozen then 0 else 50
	end
	if rootPart then
		rootPart.Anchored = frozen
	end
end

local function setFrozen(player: Player, frozen: boolean)
	player:SetAttribute(FROZEN_ATTRIBUTE, frozen)
	local character = player.Character
	if character then
		applyFreezeState(character, frozen)
	end
end

game:GetService("Players").PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		if player:GetAttribute(FROZEN_ATTRIBUTE) then
			-- Wait for the humanoid to exist before locking it down.
			character:WaitForChild("Humanoid", 5)
			applyFreezeState(character, true)
		end
	end)
end)

CommandRegistry.Register({
	Name = "freeze",
	Aliases = { "fr" },
	Description = "Freezes a player in place.",
	Usage = "/freeze target",
	Permission = "player.freeze",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			setFrozen(target, true)
		end
		return {
			Success = true,
			Message = ("Froze %d player(s)."):format(#ctx.Targets),
			Undoable = true,
			UndoData = ctx.Targets,
		}
	end,
})

CommandRegistry.Register({
	Name = "unfreeze",
	Aliases = { "ufr" },
	Description = "Unfreezes a previously frozen player.",
	Usage = "/unfreeze target",
	Permission = "player.freeze",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			setFrozen(target, false)
		end
		return { Success = true, Message = ("Unfroze %d player(s)."):format(#ctx.Targets) }
	end,
})

return true
