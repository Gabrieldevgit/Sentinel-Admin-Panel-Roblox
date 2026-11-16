--!strict
--[[
	Teleport.lua

	Purpose:
		Core movement & teleportation commands inspired by HD Admin & Nexus Admin:
		- /goto (alias /to): Teleport the executor to a target player
		- /bring: Teleport target player(s) to the executor
		- /teleport (alias /tp): Teleport target player(s) to a destination player or coordinates
		- /spawn: Teleport target player(s) to the game's spawn location

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function getRootPart(player: Player): BasePart?
	local char = player.Character
	if not char then return nil end
	return (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso")) :: BasePart?
end

local function teleportCharacter(target: Player, destinationCFrame: CFrame)
	local char = target.Character
	if not char then return false end
	local root = getRootPart(target)
	if root then
		root.CFrame = destinationCFrame
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		return true
	end
	return false
end

local function findSpawnLocation(): CFrame
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("SpawnLocation") and desc.Enabled then
			return desc.CFrame + Vector3.new(0, 4, 0)
		end
	end
	return CFrame.new(0, 10, 0)
end

-- /goto [target]
CommandRegistry.Register({
	Name = "goto",
	TargetProtection = false, -- harmless/read-only: allowed on higher ranks
	Aliases = { "to" },
	Description = "Teleports you to a target player.",
	Usage = "/goto target",
	Permission = "player.goto",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "Target player not found." }
		end

		local targetRoot = getRootPart(target)
		if not targetRoot then
			return { Success = false, Message = target.DisplayName .. " has no character or root part." }
		end

		local execRoot = getRootPart(ctx.Executor)
		local prevCFrame = execRoot and execRoot.CFrame

		local destCFrame = targetRoot.CFrame * CFrame.new(0, 0, 4)
		local ok = teleportCharacter(ctx.Executor, destCFrame)
		if not ok then
			return { Success = false, Message = "Failed to teleport your character." }
		end

		EventBus.Publish("Player.Teleported", ctx.Executor, destCFrame)

		return {
			Success = true,
			Message = ("Teleported to %s."):format(target.DisplayName),
			Undoable = prevCFrame ~= nil,
			UndoData = { Player = ctx.Executor, CFrame = prevCFrame },
		}
	end,
})

-- /bring [target]
CommandRegistry.Register({
	Name = "bring",
	Aliases = {},
	Description = "Teleports target player(s) to you.",
	Usage = "/bring target",
	Permission = "player.bring",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local execRoot = getRootPart(ctx.Executor)
		if not execRoot then
			return { Success = false, Message = "You must have a character spawned to bring players." }
		end

		local brought = 0
		local undoList = {}

		for i, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				table.insert(undoList, { Player = target, CFrame = root.CFrame })
				-- Fan out targets around the executor if multiple
				local angle = (i - 1) * (math.pi * 2 / math.max(1, #ctx.Targets))
				local offset = if #ctx.Targets > 1 then Vector3.new(math.cos(angle) * 5, 0, math.sin(angle) * 5) else (execRoot.CFrame.LookVector * 4)
				local dest = CFrame.new(execRoot.Position + offset, execRoot.Position)
				if teleportCharacter(target, dest) then
					brought += 1
					EventBus.Publish("Player.Teleported", target, dest)
				end
			end
		end

		return {
			Success = brought > 0,
			Message = ("Brought %d player(s)."):format(brought),
			Undoable = #undoList > 0,
			UndoData = undoList,
		}
	end,
})

-- /teleport [target] [destination]
CommandRegistry.Register({
	Name = "teleport",
	Aliases = { "tp" },
	Description = "Teleports target player(s) to a destination player or coordinates.",
	Usage = "/teleport target [destination / x,y,z]",
	Permission = "player.teleport",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		if #ctx.Targets == 0 then
			return { Success = false, Message = "No target players specified." }
		end

		local destCFrame: CFrame? = nil
		local destName = "destination"

		-- Check if second argument is a player or coordinates
		local destArg = ctx.Arguments[1]
		if destArg then
			-- Check coordinates "x,y,z"
			local x, y, z = destArg:match("^(%-?%d+%.?%d*)[,%s]+(%-?%d+%.?%d*)[,%s]+(%-?%d+%.?%d*)$")
			if x and y and z then
				destCFrame = CFrame.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
				destName = ("(%.1f, %.1f, %.1f)"):format(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
			else
				-- Find destination player
				local destLower = destArg:lower()
				for _, p in ipairs(Players:GetPlayers()) do
					if p.Name:lower():sub(1, #destLower) == destLower or p.DisplayName:lower():sub(1, #destLower) == destLower then
						local r = getRootPart(p)
						if r then
							destCFrame = r.CFrame * CFrame.new(0, 0, 3)
							destName = p.DisplayName
							break
						end
					end
				end
			end
		end

		-- If no destination arg was passed, default to executor's position
		if not destCFrame then
			local execRoot = getRootPart(ctx.Executor)
			if execRoot then
				destCFrame = execRoot.CFrame * CFrame.new(0, 0, 4)
				destName = ctx.Executor.DisplayName
			else
				return { Success = false, Message = "No valid destination player or position specified." }
			end
		end

		local count = 0
		local undoList = {}

		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				table.insert(undoList, { Player = target, CFrame = root.CFrame })
				if teleportCharacter(target, destCFrame) then
					count += 1
					EventBus.Publish("Player.Teleported", target, destCFrame)
				end
			end
		end

		return {
			Success = count > 0,
			Message = ("Teleported %d player(s) to %s."):format(count, destName),
			Undoable = #undoList > 0,
			UndoData = undoList,
		}
	end,
})

-- /spawn [target]
CommandRegistry.Register({
	Name = "spawn",
	Aliases = {},
	Description = "Teleports target player(s) to the game spawn point.",
	Usage = "/spawn [target]",
	Permission = "player.spawn",
	Category = "Movement",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local spawnCFrame = findSpawnLocation()
		local count = 0
		local undoList = {}

		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				table.insert(undoList, { Player = target, CFrame = root.CFrame })
				if teleportCharacter(target, spawnCFrame) then
					count += 1
				end
			end
		end

		return {
			Success = count > 0,
			Message = ("Teleported %d player(s) to spawn."):format(count),
			Undoable = #undoList > 0,
			UndoData = undoList,
		}
	end,
})

return true

