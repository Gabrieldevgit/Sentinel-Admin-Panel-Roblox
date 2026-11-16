--!strict
--[[
	Character.lua

	Purpose:
		Player character status, health, and combat commands from HD Admin & Nexus Admin:
		- /god: Grant invulnerability
		- /ungod: Remove invulnerability
		- /heal: Restore health to maximum
		- /damage: Apply damage to player
		- /kill: Instantly kill player
		- /maxhealth: Change player max health
		- /respawn (alias /reset): Reload player character
		- /refresh (alias /re): Respawn player while keeping their exact position
		- /ragdoll: Ragdoll player character
		- /unragdoll: Unragdoll player character
		- /stun: Stun player (platform stand)
		- /unstun: Unstun player
		- /removelimbs: Strip player's character limbs

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function getHumanoid(player: Player): Humanoid?
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChildOfClass("Humanoid")
end

local function getRootPart(player: Player): BasePart?
	local char = player.Character
	if not char then return nil end
	return (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")) :: BasePart?
end

-- Monitor god mode on characters
local godConnections: { [number]: RBXScriptConnection } = {}

local function applyGod(player: Player)
	player:SetAttribute("SentinelGod", true)
	local hum = getHumanoid(player)
	if hum then
		hum.MaxHealth = math.huge
		hum.Health = math.huge

		if godConnections[player.UserId] then
			godConnections[player.UserId]:Disconnect()
		end

		godConnections[player.UserId] = hum.HealthChanged:Connect(function(newHealth)
			if player:GetAttribute("SentinelGod") == true and newHealth < hum.MaxHealth then
				hum.Health = hum.MaxHealth
			end
		end)
	end
end

local function removeGod(player: Player)
	player:SetAttribute("SentinelGod", false)
	if godConnections[player.UserId] then
		godConnections[player.UserId]:Disconnect()
		godConnections[player.UserId] = nil
	end
	local hum = getHumanoid(player)
	if hum then
		hum.MaxHealth = 100
		hum.Health = 100
	end
end

-- /god [target]
CommandRegistry.Register({
	Name = "god",
	Aliases = {},
	Description = "Grants invulnerability (infinite health) to target player(s).",
	Usage = "/god target",
	Permission = "player.god",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			applyGod(target)
			count += 1
		end
		return {
			Success = count > 0,
			Message = ("Applied God mode to %d player(s)."):format(count),
			Undoable = true,
			UndoData = ctx.Targets,
		}
	end,
})

-- /ungod [target]
CommandRegistry.Register({
	Name = "ungod",
	Aliases = {},
	Description = "Removes invulnerability from target player(s).",
	Usage = "/ungod target",
	Permission = "player.god",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			removeGod(target)
			count += 1
		end
		return {
			Success = count > 0,
			Message = ("Removed God mode from %d player(s)."):format(count),
		}
	end,
})

-- /heal [target]
CommandRegistry.Register({
	Name = "heal",
	Aliases = {},
	Description = "Restores target player(s) health to maximum.",
	Usage = "/heal target",
	Permission = "player.heal",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.Health = hum.MaxHealth
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Healed %d player(s)."):format(count),
		}
	end,
})

-- /damage [target] [amount]
CommandRegistry.Register({
	Name = "damage",
	Aliases = { "dmg" },
	Description = "Applies damage to target player(s).",
	Usage = "/damage target [amount]",
	Permission = "player.damage",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local amount = tonumber(ctx.Arguments[1]) or (if ctx.ParsedQuantity then ctx.ParsedQuantity.Amount else 25)
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum:TakeDamage(amount)
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Damaged %d player(s) by %d."):format(count, amount),
		}
	end,
})

-- /kill [target]
CommandRegistry.Register({
	Name = "kill",
	Aliases = {},
	Description = "Instantly kills target player(s).",
	Usage = "/kill target",
	Permission = "player.kill",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.Health = 0
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Killed %d player(s)."):format(count),
		}
	end,
})

-- /maxhealth [target] [amount]
CommandRegistry.Register({
	Name = "maxhealth",
	Aliases = { "mhp" },
	Description = "Sets target player(s) max health.",
	Usage = "/maxhealth target [amount]",
	Permission = "player.health",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local maxHp = tonumber(ctx.Arguments[1]) or (if ctx.ParsedQuantity then ctx.ParsedQuantity.Amount else 100)
		maxHp = math.clamp(maxHp, 1, 1000000)
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.MaxHealth = maxHp
				hum.Health = math.min(hum.Health, maxHp)
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Set MaxHealth to %d for %d player(s)."):format(maxHp, count),
		}
	end,
})

-- /respawn [target]
CommandRegistry.Register({
	Name = "respawn",
	Aliases = { "reset", "load" },
	Description = "Reloads target player(s) character.",
	Usage = "/respawn target",
	Permission = "player.respawn",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			target:LoadCharacter()
			count += 1
		end
		return {
			Success = count > 0,
			Message = ("Respawned %d player(s)."):format(count),
		}
	end,
})

-- /refresh [target]
CommandRegistry.Register({
	Name = "refresh",
	Aliases = { "re" },
	Description = "Respawns target player(s) in place, preserving their exact CFrame position.",
	Usage = "/refresh target",
	Permission = "player.respawn",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			local pos = root and root.CFrame
			target:LoadCharacter()
			if pos then
				task.spawn(function()
					local char = target.CharacterAdded:Wait()
					local newRoot = (char:WaitForChild("HumanoidRootPart", 5) or char:WaitForChild("Torso", 5)) :: BasePart?
					if newRoot then
						newRoot.CFrame = pos
					end
				end)
			end
			count += 1
		end
		return {
			Success = count > 0,
			Message = ("Refreshed %d player(s) in place."):format(count),
		}
	end,
})

-- /stun [target]
CommandRegistry.Register({
	Name = "stun",
	Aliases = { "tripstand" },
	Description = "Stuns target player(s), dropping them to the ground.",
	Usage = "/stun target",
	Permission = "player.stun",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.PlatformStand = true
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Stunned %d player(s)."):format(count),
		}
	end,
})

-- /unstun [target]
CommandRegistry.Register({
	Name = "unstun",
	Aliases = {},
	Description = "Removes stun from target player(s).",
	Usage = "/unstun target",
	Permission = "player.stun",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.PlatformStand = false
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Unstunned %d player(s)."):format(count),
		}
	end,
})

-- /ragdoll [target]
CommandRegistry.Register({
	Name = "ragdoll",
	Aliases = {},
	Description = "Ragdolls the target player(s).",
	Usage = "/ragdoll target",
	Permission = "player.ragdoll",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			local hum = getHumanoid(target)
			if char and hum then
				hum.PlatformStand = true
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("Motor6D") and desc.Name ~= "RootJoint" then
						local a0 = Instance.new("Attachment")
						a0.CFrame = desc.C0
						a0.Parent = desc.Part0

						local a1 = Instance.new("Attachment")
						a1.CFrame = desc.C1
						a1.Parent = desc.Part1

						local bsc = Instance.new("BallSocketConstraint")
						bsc.Name = "RagdollConstraint"
						bsc.Attachment0 = a0
						bsc.Attachment1 = a1
						bsc.LimitsEnabled = true
						bsc.TwistLimitsEnabled = true
						bsc.Parent = desc.Parent

						desc.Enabled = false
					end
				end
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Ragdolled %d player(s)."):format(count),
		}
	end,
})

-- /unragdoll [target]
CommandRegistry.Register({
	Name = "unragdoll",
	Aliases = {},
	Description = "Unragdolls target player(s) and restores joints.",
	Usage = "/unragdoll target",
	Permission = "player.ragdoll",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			local hum = getHumanoid(target)
			if char and hum then
				hum.PlatformStand = false
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("BallSocketConstraint") and desc.Name == "RagdollConstraint" then
						desc:Destroy()
					elseif desc:IsA("Motor6D") then
						desc.Enabled = true
					end
				end
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Unragdolled %d player(s)."):format(count),
		}
	end,
})

-- /removelimbs [target]
CommandRegistry.Register({
	Name = "removelimbs",
	Aliases = { "armless", "legless" },
	Description = "Removes target player's arms and legs.",
	Usage = "/removelimbs target",
	Permission = "player.modify",
	Category = "Player",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		local limbNames = {
			"Left Arm", "Right Arm", "Left Leg", "Right Leg",
			"LeftUpperArm", "LeftLowerArm", "LeftHand",
			"RightUpperArm", "RightLowerArm", "RightHand",
			"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
			"RightUpperLeg", "RightLowerLeg", "RightFoot",
		}
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, name in ipairs(limbNames) do
					local part = char:FindFirstChild(name)
					if part and part:IsA("BasePart") then
						part:Destroy()
					end
				end
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Removed limbs for %d player(s)."):format(count),
		}
	end,
})

return true

