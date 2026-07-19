--!strict
--[[
	Jail.lua

	Purpose:
		Registers "/jail" and "/unjail". Jailing now also freezes the
		target in place (like /freeze) and remembers exactly where they
		were standing before teleporting them; unjailing restores movement
		and teleports them back to that saved spot.

	Responsibilities:
		- Save the target's CFrame before teleporting to jail
		- Teleport target to a designated jail location and freeze them
		  (WalkSpeed/JumpPower zeroed, HumanoidRootPart anchored)
		- Watchdog loop that returns jailed players who move too far away
		- Re-apply on respawn via CharacterAdded (still frozen, still in
		  jail, since they were never actually released)
		- On unjail: unfreeze and teleport back to the saved CFrame

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)

	Setup required from the game owner:
		Place a Part named "SentinelJailSpawn" anywhere in Workspace. If it
		is missing, /jail falls back to teleporting 500 studs into the sky,
		with a warning in the server log, so the command still degrades
		gracefully instead of erroring.

	Known limitation:
		Saved return positions live in memory only (not a DataStore) — if
		the server restarts while someone is jailed, their return position
		is lost and /unjail will just release them where they stand. This
		matches how other session-scoped Sentinel state (e.g. slow mode)
		behaves; flag if you'd rather have this persist across restarts.
--]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local JAILED_ATTRIBUTE = "SentinelJailed"
local WATCHDOG_INTERVAL = 3
local LEASH_DISTANCE = 40 -- studs the jailed player may wander before being pulled back

-- Return position saved at the moment /jail is issued, keyed by UserId.
local savedReturnCFrame: { [number]: CFrame } = {}

local function getJailPosition(): Vector3
	local marker = Workspace:FindFirstChild("SentinelJailSpawn")
	if marker and marker:IsA("BasePart") then
		return marker.Position + Vector3.new(0, 3, 0)
	end
	warn("[Sentinel.Jail] no 'SentinelJailSpawn' part found in Workspace; falling back to a sky cell.")
	return Vector3.new(0, 500, 0)
end

local function applyFrozenState(character: Model, frozen: boolean)
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

local function teleportToJail(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart then
		-- Anchored parts still respect CFrame assignment, so this works
		-- whether or not the freeze has already been applied.
		rootPart.CFrame = CFrame.new(getJailPosition())
	end
end

local function setJailed(player: Player, jailed: boolean)
	if jailed then
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart then
			savedReturnCFrame[player.UserId] = rootPart.CFrame
		end

		player:SetAttribute(JAILED_ATTRIBUTE, true)
		if character then
			teleportToJail(character)
			applyFrozenState(character, true)
		end
	else
		player:SetAttribute(JAILED_ATTRIBUTE, false)

		local character = player.Character
		if character then
			applyFrozenState(character, false)
			local returnCFrame = savedReturnCFrame[player.UserId]
			local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if returnCFrame and rootPart then
				rootPart.CFrame = returnCFrame
			end
		end

		savedReturnCFrame[player.UserId] = nil
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		if player:GetAttribute(JAILED_ATTRIBUTE) then
			character:WaitForChild("HumanoidRootPart", 5)
			teleportToJail(character)
			applyFrozenState(character, true)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	savedReturnCFrame[player.UserId] = nil
end)

-- Watchdog: pulls jailed players back if they leave the jail radius (e.g.
-- via an exploit that ignores Anchored, or before the freeze re-applies
-- right after a respawn).
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
	Description = "Confines a player to the jail area and freezes them there.",
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
	Description = "Releases a player from jail, unfreezes them, and returns them to where they were.",
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
