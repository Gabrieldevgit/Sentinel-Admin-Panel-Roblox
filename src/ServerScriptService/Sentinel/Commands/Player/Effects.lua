--!strict
--[[
	Effects.lua

	Purpose:
		Visual effects, appearance, and fun character modification commands
		from HD Admin & Nexus Admin:
		- /forcefield (alias /ff), /unforcefield (alias /unff)
		- /invisible (alias /invis), /visible (alias /vis)
		- /explode (alias /bigexplosion)
		- /fire, /unfire
		- /smoke, /unsmoke
		- /sparkles, /unsparkles
		- /glow, /unglow
		- /bighead, /smallhead, /normalhead
		- /skin [material/preset] (gold, silver, diamond, neon, glass, metal, normal)
		- /clone: Spawn an NPC clone of the target
		- /blind, /unblind

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

-- /forcefield [target]
CommandRegistry.Register({
	Name = "forcefield",
	Aliases = { "ff" },
	Description = "Gives target player(s) a protective forcefield.",
	Usage = "/forcefield target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				local existing = char:FindFirstChildOfClass("ForceField")
				if not existing then
					local ff = Instance.new("ForceField")
					ff.Name = "SentinelForceField"
					ff.Parent = char
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Gave forcefield to %d player(s)."):format(count) }
	end,
})

-- /unforcefield [target]
CommandRegistry.Register({
	Name = "unforcefield",
	Aliases = { "unff" },
	Description = "Removes forcefield from target player(s).",
	Usage = "/unforcefield target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("ForceField") then
						desc:Destroy()
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Removed forcefield from %d player(s)."):format(count) }
	end,
})

-- /invisible [target]
CommandRegistry.Register({
	Name = "invisible",
	Aliases = { "invis" },
	Description = "Makes target player(s) completely invisible.",
	Usage = "/invisible target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				target:SetAttribute("SentinelInvisible", true)
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
						desc.Transparency = 1
					elseif desc:IsA("Decal") then
						desc.Transparency = 1
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Made %d player(s) invisible."):format(count) }
	end,
})

-- /visible [target]
CommandRegistry.Register({
	Name = "visible",
	Aliases = { "vis" },
	Description = "Makes target player(s) visible again.",
	Usage = "/visible target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				target:SetAttribute("SentinelInvisible", false)
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
						desc.Transparency = 0
					elseif desc:IsA("Decal") then
						desc.Transparency = 0
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Made %d player(s) visible."):format(count) }
	end,
})

-- /explode [target]
CommandRegistry.Register({
	Name = "explode",
	Aliases = { "bigexplosion" },
	Description = "Triggers an explosion at target player(s).",
	Usage = "/explode target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		local isBig = ctx.CommandName == "bigexplosion"
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local exp = Instance.new("Explosion")
				exp.Position = root.Position
				exp.BlastRadius = if isBig then 30 else 12
				exp.BlastPressure = if isBig then 800000 else 400000
				exp.Parent = Workspace
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Exploded %d player(s)."):format(count) }
	end,
})

-- /fire [target]
CommandRegistry.Register({
	Name = "fire",
	Aliases = {},
	Description = "Sets target player(s) on fire.",
	Usage = "/fire target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local existing = root:FindFirstChild("SentinelFire")
				if not existing then
					local fire = Instance.new("Fire")
					fire.Name = "SentinelFire"
					fire.Size = 6
					fire.Parent = root
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Set %d player(s) on fire."):format(count) }
	end,
})

-- /unfire [target]
CommandRegistry.Register({
	Name = "unfire",
	Aliases = {},
	Description = "Extinguishes fire on target player(s).",
	Usage = "/unfire target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("Fire") then
						desc:Destroy()
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Extinguished fire on %d player(s)."):format(count) }
	end,
})

-- /smoke [target]
CommandRegistry.Register({
	Name = "smoke",
	Aliases = {},
	Description = "Creates a smoke plume on target player(s).",
	Usage = "/smoke target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local existing = root:FindFirstChild("SentinelSmoke")
				if not existing then
					local s = Instance.new("Smoke")
					s.Name = "SentinelSmoke"
					s.Size = 4
					s.Parent = root
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Added smoke to %d player(s)."):format(count) }
	end,
})

-- /unsmoke [target]
CommandRegistry.Register({
	Name = "unsmoke",
	Aliases = {},
	Description = "Removes smoke from target player(s).",
	Usage = "/unsmoke target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("Smoke") then
						desc:Destroy()
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Removed smoke from %d player(s)."):format(count) }
	end,
})

-- /sparkles [target]
CommandRegistry.Register({
	Name = "sparkles",
	Aliases = {},
	Description = "Adds sparkles to target player(s).",
	Usage = "/sparkles target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local root = getRootPart(target)
			if root then
				local existing = root:FindFirstChild("SentinelSparkles")
				if not existing then
					local sp = Instance.new("Sparkles")
					sp.Name = "SentinelSparkles"
					sp.SparkleColor = Color3.fromRGB(255, 215, 0)
					sp.Parent = root
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Added sparkles to %d player(s)."):format(count) }
	end,
})

-- /unsparkles [target]
CommandRegistry.Register({
	Name = "unsparkles",
	Aliases = {},
	Description = "Removes sparkles from target player(s).",
	Usage = "/unsparkles target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("Sparkles") then
						desc:Destroy()
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Removed sparkles from %d player(s)."):format(count) }
	end,
})

-- /glow [target]
CommandRegistry.Register({
	Name = "glow",
	Aliases = { "highlight" },
	Description = "Adds an outline glow/highlight effect to target player(s).",
	Usage = "/glow target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				local existing = char:FindFirstChild("SentinelHighlight")
				if not existing then
					local hl = Instance.new("Highlight")
					hl.Name = "SentinelHighlight"
					hl.FillColor = Color3.fromRGB(0, 170, 255)
					hl.OutlineColor = Color3.fromRGB(255, 255, 255)
					hl.FillTransparency = 0.5
					hl.Parent = char
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Applied glow to %d player(s)."):format(count) }
	end,
})

-- /unglow [target]
CommandRegistry.Register({
	Name = "unglow",
	Aliases = { "unhighlight" },
	Description = "Removes glow/highlight effect from target player(s).",
	Usage = "/unglow target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				local hl = char:FindFirstChild("SentinelHighlight")
				if hl then
					hl:Destroy()
					count += 1
				end
			end
		end
		return { Success = count > 0, Message = ("Removed glow from %d player(s)."):format(count) }
	end,
})

-- Scales a character's head by `factor` relative to normal (1 = normal).
-- R15: the Humanoid's HeadScale value (rescales the MeshPart + accessories).
-- R6: the head's SpecialMesh (default scale 1.25).
-- Otherwise: Head.Size, remembering the original in an attribute.
local function setHeadScale(char: Model, factor: number): boolean
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then
		return false
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local headScale = humanoid and humanoid:FindFirstChild("HeadScale")
	if headScale and headScale:IsA("NumberValue") then
		headScale.Value = factor
		return true
	end
	local mesh = head:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		mesh.Scale = Vector3.new(1.25, 1.25, 1.25) * factor
		return true
	end
	local original = head:GetAttribute("SentinelHeadOriginalSize")
	if typeof(original) ~= "Vector3" then
		original = head.Size
		head:SetAttribute("SentinelHeadOriginalSize", original)
	end
	head.Size = (original :: Vector3) * factor
	return true
end

-- /bighead [target]
CommandRegistry.Register({
	Name = "bighead",
	Aliases = {},
	Description = "Enlarges the target player's head.",
	Usage = "/bighead target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char and setHeadScale(char, 3) then
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Enlarged head for %d player(s)."):format(count) }
	end,
})

-- /smallhead [target]
CommandRegistry.Register({
	Name = "smallhead",
	Aliases = {},
	Description = "Shrinks the target player's head.",
	Usage = "/smallhead target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char and setHeadScale(char, 0.5) then
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Shrunk head for %d player(s)."):format(count) }
	end,
})

-- /normalhead [target]
CommandRegistry.Register({
	Name = "normalhead",
	Aliases = {},
	Description = "Restores normal head scale for target player(s).",
	Usage = "/normalhead target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char and setHeadScale(char, 1) then
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Normalized head for %d player(s)."):format(count) }
	end,
})

-- /skin [target] [preset]
local PRESETS: { [string]: { Material: Enum.Material, Color: Color3? } } = {
	gold = { Material = Enum.Material.Metal, Color = Color3.fromRGB(255, 215, 0) },
	silver = { Material = Enum.Material.Metal, Color = Color3.fromRGB(200, 200, 200) },
	diamond = { Material = Enum.Material.DiamondPlate, Color = Color3.fromRGB(180, 230, 255) },
	neon = { Material = Enum.Material.Neon, Color = Color3.fromRGB(0, 255, 200) },
	glass = { Material = Enum.Material.Glass, Color = Color3.fromRGB(220, 240, 255) },
	metal = { Material = Enum.Material.Metal, Color = Color3.fromRGB(150, 150, 150) },
	plastic = { Material = Enum.Material.Plastic, Color = nil },
	normal = { Material = Enum.Material.SmoothPlastic, Color = nil },
}

CommandRegistry.Register({
	Name = "skin",
	Aliases = { "charactermaterial" },
	Description = "Applies a material/skin preset to target player's character (gold, silver, diamond, neon, glass, metal, normal).",
	Usage = "/skin target [preset]",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local presetName = (ctx.Arguments[1] or "gold"):lower()
		local preset = PRESETS[presetName] or PRESETS.gold
		local count = 0

		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				for _, desc in ipairs(char:GetDescendants()) do
					if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
						desc.Material = preset.Material
						if preset.Color then
							desc.Color = preset.Color
						end
					end
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Applied skin '%s' to %d player(s)."):format(presetName, count) }
	end,
})

-- /clone [target]
CommandRegistry.Register({
	Name = "clone",
	Aliases = {},
	Description = "Spawns an NPC clone of the target player's character.",
	Usage = "/clone target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local char = target.Character
			if char then
				char.Archivable = true
				local clone = char:Clone()
				char.Archivable = false

				clone.Name = target.DisplayName .. " (Clone)"
				local root = clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChild("Torso")
				if root and root:IsA("BasePart") then
					root.CFrame = root.CFrame * CFrame.new(4, 0, 0)
				end
				clone.Parent = Workspace
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Created clone for %d player(s)."):format(count) }
	end,
})

-- /blind [target]
CommandRegistry.Register({
	Name = "blind",
	Aliases = {},
	Description = "Blinds target player(s) with a pitch-black screen.",
	Usage = "/blind target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local pg = target:FindFirstChildOfClass("PlayerGui")
			if pg then
				local existing = pg:FindFirstChild("SentinelBlindGui")
				if not existing then
					local sg = Instance.new("ScreenGui")
					sg.Name = "SentinelBlindGui"
					sg.IgnoreGuiInset = true
					sg.DisplayOrder = 999999

					local f = Instance.new("Frame")
					f.Size = UDim2.new(1, 0, 1, 0)
					f.BackgroundColor3 = Color3.new(0, 0, 0)
					f.BorderSizePixel = 0
					f.Parent = sg
					sg.Parent = pg
				end
				count += 1
			end
		end
		return { Success = count > 0, Message = ("Blinded %d player(s)."):format(count) }
	end,
})

-- /unblind [target]
CommandRegistry.Register({
	Name = "unblind",
	Aliases = {},
	Description = "Removes blind effect from target player(s).",
	Usage = "/unblind target",
	Permission = "player.effects",
	Category = "Effects",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local pg = target:FindFirstChildOfClass("PlayerGui")
			if pg then
				local bg = pg:FindFirstChild("SentinelBlindGui")
				if bg then
					bg:Destroy()
					count += 1
				end
			end
		end
		return { Success = count > 0, Message = ("Unblinded %d player(s)."):format(count) }
	end,
})

return true

