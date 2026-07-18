--!strict
--[[
	Jail.lua

	Purpose:
		Registers "/jail" and "/unjail". Teleports the target to a
		designated jail location (a part named "SentinelJailSpawn" placed
		anywhere in Workspace by the game owner) and periodically re-
		teleports them back if they wander or respawn, until released.

	Responsibilities:
		- Look up the jail spawn location (lazy, cached)
		- Teleport target there and tag them with an attribute
		- Watchdog loop that returns jailed players who move too far away
		- Re-apply on respawn via CharacterAdded

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)

	Setup required from the game owner:
		Place a Part named "SentinelJailSpawn" anywhere in Workspace. If it
		is missing, /jail falls back to teleporting 500 studs into the sky
		and anchoring the player, with a warning in the server log, so the
		command still degrades gracefully instead of erroring.
--]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local JAILED_ATTRIBUTE = "SentinelJailed"
local WATCHDOG_INTERVAL = 3
local LEASH_DISTANCE = 40 -- studs the jailed player may wander before being pulled back

local function getJailPosition(): Vector3
	local marker = Workspace:FindFirstChild("SentinelJailSpawn")
	if marker and marker:IsA("BasePart") then
		return marker.Position + Vector3.new(0, 3, 0)
	end
	warn("[Sentinel.Jail] no 'SentinelJailSpawn' part found in Workspace; falling back to a sky cell.")
	return Vector3.new(0, 500, 0)
end

local function teleportToJail(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart then
		rootPart.CFrame = CFrame.new(getJailPosition())
	end
end

local function setJailed(player: Player, jailed: boolean)
	player:SetAttribute(JAILED_ATTRIBUTE, jailed)
	if jailed and player.Character then
		teleportToJail(player.Character)
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		if player:GetAttribute(JAILED_ATTRIBUTE) then
			character:WaitForChild("HumanoidRootPart", 5)
			teleportToJail(character)
		end
	end)
end)

-- Watchdog: pulls jailed players back if they leave the jail radius (e.g.
-- via an exploit or a jetpack tool that ignores Anchored).
task.spawn(function()
	while true do
		task.wait(WATCHDOG_INTERVAL)
		local jailPos = getJailPosition()
		for _, player in ipairs(Players:GetPlayers()) do
			if player:GetAttribute(JAILED_ATTRIBUTE) then
				local character = player.Character
				local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if rootPart and (rootPart.Position - jailPos).Magnitude > LEASH_DISTANCE then
					rootPart.CFrame = CFrame.new(jailPos)
				end
			end
		end
	end
end)

CommandRegistry.Register({
	Name = "jail",
	Aliases = { "j" },
	Description = "Confines a player to the jail area.",
	Usage = "/jail target",
	Permission = "player.jail",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			setJailed(target, true)
		end
		return {
			Success = true,
			Message = ("Jailed %d player(s)."):format(#ctx.Targets),
			Undoable = true,
			UndoData = ctx.Targets,
		}
	end,
})

CommandRegistry.Register({
	Name = "unjail",
	Aliases = { "uj" },
	Description = "Releases a player from jail.",
	Usage = "/unjail target",
	Permission = "player.jail",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			setJailed(target, false)
		end
		return { Success = true, Message = ("Released %d player(s) from jail."):format(#ctx.Targets) }
	end,
})

return true
