--!strict
--[[
	Movement.lua

	Purpose:
		Player movement and physics manipulation commands from HD Admin & Nexus Admin:
		- /speed (alias /walkspeed, /ws): Set walkspeed
		- /resetspeed: Reset walkspeed to default (16)
		- /jumppower (alias /jp, /jumpheight): Set jump power
		- /resetjump: Reset jump power to default (50)
		- /sit: Make player sit
		- /jump: Make player jump
		- /trip: Knock player over
		- /fling (alias /superfling): Fling player into the air
		- /spin: Spin character continuously
		- /unspin: Stop spinning character
		- /fly: Enable flight
		- /unfly: Disable flight
		- /noclip: Enable noclip
		- /clip: Disable noclip

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

local function getMovementRemote(): RemoteEvent
	local existing = SentinelShared:FindFirstChild("MovementRemote")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "MovementRemote"
	remote.Parent = SentinelShared
	return remote
end

local movementRemote = getMovementRemote()

-- The client's fly menu reports when the player turns fly off or toggles
-- noclip themselves. This only ever touches the sender's own attributes
-- (status display for the Players page), never another player's, and
-- grants nothing: flight itself is started only by the /fly command.
local RateLimiter = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("RateLimiter"))
local movementLimiter = RateLimiter.new("MovementRemote", 10, 5)

movementRemote.OnServerEvent:Connect(function(player: Player, kind: unknown, value: unknown)
	if not movementLimiter:Allow(player) or typeof(value) ~= "boolean" then
		return
	end
	if kind == "FlyState" and value == false then
		player:SetAttribute("SentinelFlying", false)
	elseif kind == "NoclipState" then
		player:SetAttribute("SentinelNoclip", value)
	end
end)

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

-- /speed [target] [amount]
CommandRegistry.Register({
	Name = "speed",
	Aliases = { "walkspeed", "ws" },
	Description = "Sets the target player's walkspeed.",
	Usage = "/speed target [amount]",
	Permission = "player.speed",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local speedVal = tonumber(ctx.Arguments[1]) or (if ctx.ParsedQuantity then ctx.ParsedQuantity.Amount else 32)
		speedVal = math.clamp(speedVal, 0, 1000)

		local count = 0
		local undoList = {}

		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				table.insert(undoList, { Player = target, Speed = hum.WalkSpeed })
				hum.WalkSpeed = speedVal
				target:SetAttribute("SentinelWalkSpeed", speedVal)
				count += 1
			end
		end

		return {
			Success = count > 0,
			Message = ("Set WalkSpeed to %d for %d player(s)."):format(speedVal, count),
			Undoable = #undoList > 0,
			UndoData = undoList,
		}
	end,
})

-- /resetspeed [target]
CommandRegistry.Register({
	Name = "resetspeed",
	Aliases = { "rws" },
	Description = "Resets the target player's walkspeed to default (16).",
	Usage = "/resetspeed target",
	Permission = "player.speed",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.WalkSpeed = 16
				target:SetAttribute("SentinelWalkSpeed", 16)
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Reset WalkSpeed for %d player(s)."):format(count),
		}
	end,
})

-- /jumppower [target] [amount]
CommandRegistry.Register({
	Name = "jumppower",
	Aliases = { "jp", "jumpheight" },
	Description = "Sets the target player's jump power or height.",
	Usage = "/jumppower target [amount]",
	Permission = "player.jump",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local jumpVal = tonumber(ctx.Arguments[1]) or (if ctx.ParsedQuantity then ctx.ParsedQuantity.Amount else 100)
		jumpVal = math.clamp(jumpVal, 0, 1000)

		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.UseJumpPower = true
				hum.JumpPower = jumpVal
				hum.JumpHeight = jumpVal / 7
				target:SetAttribute("SentinelJumpPower", jumpVal)
				count += 1
			end
		end

		return {
			Success = count > 0,
			Message = ("Set JumpPower to %d for %d player(s)."):format(jumpVal, count),
		}
	end,
})

-- /resetjump [target]
CommandRegistry.Register({
	Name = "resetjump",
	Aliases = { "rjp" },
	Description = "Resets the target player's jump power to default (50).",
	Usage = "/resetjump target",
	Permission = "player.jump",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.UseJumpPower = true
				hum.JumpPower = 50
				hum.JumpHeight = 7.2
				target:SetAttribute("SentinelJumpPower", 50)
				count += 1
			end
		end
		return {
			Success = count > 0,
			Message = ("Reset JumpPower for %d player(s)."):format(count),
		}
	end,
})

-- /sit [target]
CommandRegistry.Register({
	Name = "sit",
	Aliases = {},
	Description = "Forces the target player(s) to sit.",
	Usage = "/sit target",
	Permission = "player.sit",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.Sit = true
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Forced %d player(s) to sit."):format(count) }
	end,
})

-- /jump [target]
CommandRegistry.Register({
	Name = "jump",
	Aliases = {},
	Description = "Forces the target player(s) to jump.",
	Usage = "/jump target",
	Permission = "player.jump",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum.Jump = true
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Made %d player(s) jump."):format(count) }
	end,
})

-- /trip [target]
CommandRegistry.Register({
	Name = "trip",
	Aliases = {},
	Description = "Trips the target player(s) onto the ground.",
	Usage = "/trip target",
	Permission = "player.trip",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local hum = getHumanoid(target)
			if hum then
				hum:ChangeState(Enum.HumanoidStateType.FallingDown)
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Tripped %d player(s)."):format(count) }
	end,
})

-- /fling [target]
CommandRegistry.Register({
	Name = "fling",
	Aliases = { "superfling" },
	Description = "Flings the target player(s) high into the sky.",
	Usage = "/fling target",
	Permission = "player.fling",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		local power = if ctx.CommandName == "superfling" then 350 else 180

		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			local hum = getHumanoid(target)
			if root and hum then
				hum.Sit = true
				local dir = Vector3.new(math.random(-10, 10), 15, math.random(-10, 10)).Unit
				root.AssemblyLinearVelocity = dir * power
				root.AssemblyAngularVelocity = Vector3.new(math.random(-100, 100), math.random(-100, 100), math.random(-100, 100))
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Flung %d player(s)."):format(count) }
	end,
})

-- /spin [target] [speed]
CommandRegistry.Register({
	Name = "spin",
	Aliases = {},
	Description = "Spins the target player's character continuously.",
	Usage = "/spin target [speed]",
	Permission = "player.spin",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local speed = tonumber(ctx.Arguments[1]) or 20
		local count = 0

		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local existing = root:FindFirstChild("SentinelSpin")
				if existing then existing:Destroy() end

				local bva = Instance.new("BodyAngularVelocity")
				bva.Name = "SentinelSpin"
				bva.MaxTorque = Vector3.new(0, math.huge, 0)
				bva.AngularVelocity = Vector3.new(0, speed, 0)
				bva.Parent = root
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Spinning %d player(s)."):format(count) }
	end,
})

-- /unspin [target]
CommandRegistry.Register({
	Name = "unspin",
	Aliases = {},
	Description = "Stops spinning the target player's character.",
	Usage = "/unspin target",
	Permission = "player.spin",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local spin = root:FindFirstChild("SentinelSpin")
				if spin then
					spin:Destroy()
					count += 1
				end
			end
		end
		return { Success = count > 0, Message = ("Stopped spin for %d player(s)."):format(count) }
	end,
})

-- /fly [target] [speed]
CommandRegistry.Register({
	Name = "fly",
	Aliases = {},
	Description = "Enables flight for the target player(s).",
	Usage = "/fly target [speed]",
	Permission = "player.fly",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local speed = tonumber(ctx.Arguments[1]) or 50
		local count = 0

		for _, target in ipairs(ctx.Targets) do
			target:SetAttribute("SentinelFlying", true)
			target:SetAttribute("SentinelFlySpeed", speed)
			movementRemote:FireClient(target, "Fly", speed)
			count += 1
		end
		return { Success = count > 0, Message = ("Enabled fly for %d player(s)."):format(count) }
	end,
})

-- /unfly [target]
CommandRegistry.Register({
	Name = "unfly",
	Aliases = {},
	Description = "Disables flight for the target player(s).",
	Usage = "/unfly target",
	Permission = "player.fly",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			target:SetAttribute("SentinelFlying", false)
			movementRemote:FireClient(target, "Unfly")
			count += 1
		end
		return { Success = count > 0, Message = ("Disabled fly for %d player(s)."):format(count) }
	end,
})

-- /noclip [target]
CommandRegistry.Register({
	Name = "noclip",
	Aliases = {},
	Description = "Enables noclip collision bypass for the target player(s).",
	Usage = "/noclip target",
	Permission = "player.noclip",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			target:SetAttribute("SentinelNoclip", true)
			movementRemote:FireClient(target, "Noclip", true)
			count += 1
		end
		return { Success = count > 0, Message = ("Enabled noclip for %d player(s)."):format(count) }
	end,
})

-- /clip [target]
CommandRegistry.Register({
	Name = "clip",
	Aliases = { "unnoclip" },
	Description = "Disables noclip collision bypass for the target player(s).",
	Usage = "/clip target",
	Permission = "player.noclip",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			target:SetAttribute("SentinelNoclip", false)
			movementRemote:FireClient(target, "Noclip", false)
			count += 1
		end
		return { Success = count > 0, Message = ("Disabled noclip for %d player(s)."):format(count) }
	end,
})

return true

