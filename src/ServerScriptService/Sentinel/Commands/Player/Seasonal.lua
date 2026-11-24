--!strict
--[[
	Seasonal.lua (M-panel gaps: seasonal effects + Spooky Night)

	Player effects (node player.effects, built from plain parts - no
	meshes, decals or animations needed):
		;pumpkin <players>     (pumpkinhead)  pumpkin over the head, glowing eyes
		;ghost <players>       (ghostform)    pale, see-through, floaty glow
		;bats <players>        (batswarm)     a swarm of bats circling the head
		;unspooky <players>    (unseasonal)   removes all three
		;clearseasonal         (clearhalloween) every player + stops Spooky Night

	Server-wide event (W24 EventService.Define): "spookynight" (aliases
	spooky, halloween) - dark night lighting + fog, restored when it ends.
	Start it like any event: ;event spookynight time=10m (or ;gevent).

	Effects live in the character (model "SentinelSeasonal_<kind>"), so a
	respawn removes them. Ghost keeps each part's original transparency /
	material in attributes and restores them.
--]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local EventService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EventService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local PREFIX = "SentinelSeasonal_"
local ORANGE = Color3.fromRGB(255, 128, 20)
local GLOW = Color3.fromRGB(255, 200, 60)

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function remove(character: Model, kind: string): boolean
	local existing = character:FindFirstChild(PREFIX .. kind)
	if existing then
		existing:Destroy()
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Pumpkin head
-- ---------------------------------------------------------------------------
local function addPumpkin(character: Model): boolean
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head or character:FindFirstChild(PREFIX .. "Pumpkin") then
		return head ~= nil
	end
	local model = Instance.new("Model")
	model.Name = PREFIX .. "Pumpkin"
	local cf = head.CFrame
	local body = part({ Name = "Body", Shape = Enum.PartType.Ball, Size = Vector3.new(2.6, 2.6, 2.6), Color = ORANGE, Material = Enum.Material.SmoothPlastic, CFrame = cf * CFrame.new(0, 0.25, 0) }, model)
	-- Ridges: two slightly squashed balls give the ribbed look.
	part({ Name = "RidgeA", Shape = Enum.PartType.Ball, Size = Vector3.new(2.75, 2.45, 2.2), Color = ORANGE:Lerp(Color3.new(0, 0, 0), 0.12), Material = Enum.Material.SmoothPlastic, CFrame = body.CFrame }, model)
	part({ Name = "RidgeB", Shape = Enum.PartType.Ball, Size = Vector3.new(2.2, 2.45, 2.75), Color = ORANGE:Lerp(Color3.new(0, 0, 0), 0.12), Material = Enum.Material.SmoothPlastic, CFrame = body.CFrame }, model)
	part({ Name = "Stem", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.6, 0.35, 0.35), Color = Color3.fromRGB(70, 120, 40), CFrame = body.CFrame * CFrame.new(0, 1.45, 0) * CFrame.Angles(0, 0, math.rad(90)) }, model)
	-- Face (front = -Z of the head).
	for _, x in ipairs({ -0.5, 0.5 }) do
		part({ Name = "Eye", Size = Vector3.new(0.45, 0.4, 0.2), Color = GLOW, Material = Enum.Material.Neon, CFrame = body.CFrame * CFrame.new(x, 0.3, -1.3) }, model)
	end
	part({ Name = "Mouth", Size = Vector3.new(1.2, 0.25, 0.2), Color = GLOW, Material = Enum.Material.Neon, CFrame = body.CFrame * CFrame.new(0, -0.45, -1.28) }, model)
	local light = Instance.new("PointLight")
	light.Color = GLOW
	light.Range = 8
	light.Brightness = 1.5
	light.Parent = body
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") then
			weld(head, p)
		end
	end
	-- Hide the real head + face + hats while the pumpkin is on.
	-- Over a ghost: take over the ghost's saved value (the real one), so
	-- the order the effects are removed in doesn't matter.
	local function hide(inst: any)
		local ghostT = inst:GetAttribute("SentinelGhostT")
		inst:SetAttribute("SentinelPumpkinT", if type(ghostT) == "number" then ghostT else inst.Transparency)
		inst:SetAttribute("SentinelGhostT", nil)
		inst.Transparency = 1
	end
	hide(head)
	for _, d in ipairs(head:GetChildren()) do
		if d:IsA("Decal") then
			hide(d)
		end
	end
	model.Parent = character
	return true
end

local function removePumpkin(character: Model): boolean
	local removed = remove(character, "Pumpkin")
	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		local t = head:GetAttribute("SentinelPumpkinT")
		if type(t) == "number" then
			head.Transparency = t
			head:SetAttribute("SentinelPumpkinT", nil)
		end
		for _, d in ipairs(head:GetChildren()) do
			local dt = d:GetAttribute("SentinelPumpkinT")
			if d:IsA("Decal") and type(dt) == "number" then
				d.Transparency = dt
				d:SetAttribute("SentinelPumpkinT", nil)
			end
		end
	end
	return removed
end

-- ---------------------------------------------------------------------------
-- Ghost form
-- ---------------------------------------------------------------------------
local function addGhost(character: Model): boolean
	if character:FindFirstChild(PREFIX .. "Ghost") then
		return true
	end
	local marker = Instance.new("Highlight")
	marker.Name = PREFIX .. "Ghost"
	marker.FillColor = Color3.fromRGB(210, 230, 255)
	marker.FillTransparency = 0.55
	marker.OutlineColor = Color3.fromRGB(235, 245, 255)
	marker.OutlineTransparency = 0.2
	marker.DepthMode = Enum.HighlightDepthMode.Occluded
	marker.Parent = character
	for _, d in ipairs(character:GetDescendants()) do
		if d:GetAttribute("SentinelPumpkinT") ~= nil then
			continue -- hidden under a pumpkin; the pumpkin restores it
		elseif d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and not d:FindFirstAncestor(PREFIX .. "Pumpkin") and not d:FindFirstAncestor(PREFIX .. "Bats") then
			d:SetAttribute("SentinelGhostT", d.Transparency)
			d.Transparency = math.max(d.Transparency, 0.6)
		elseif d:IsA("Decal") then
			d:SetAttribute("SentinelGhostT", d.Transparency)
			d.Transparency = math.max(d.Transparency, 0.6)
		end
	end
	return true
end

local function removeGhost(character: Model): boolean
	local removed = remove(character, "Ghost")
	for _, d in ipairs(character:GetDescendants()) do
		local t = d:GetAttribute("SentinelGhostT")
		if type(t) == "number" and (d:IsA("BasePart") or d:IsA("Decal")) then
			(d :: any).Transparency = t
			d:SetAttribute("SentinelGhostT", nil)
		end
	end
	return removed
end

-- ---------------------------------------------------------------------------
-- Bat swarm: anchored parts moved by one server loop.
-- ---------------------------------------------------------------------------
local swarms: { [Model]: { Head: BasePart, Bats: { { Part: BasePart, Radius: number, Speed: number, Phase: number, Height: number } } } } = {}
local swarmConn: RBXScriptConnection? = nil

local function stepSwarms()
	local t = os.clock()
	for model, swarm in pairs(swarms) do
		if not model.Parent or not swarm.Head.Parent then
			swarms[model] = nil
		else
			local center = swarm.Head.Position
			for _, bat in ipairs(swarm.Bats) do
				local a = t * bat.Speed + bat.Phase
				local pos = center + Vector3.new(math.cos(a) * bat.Radius, bat.Height + math.sin(t * 3 + bat.Phase) * 0.4, math.sin(a) * bat.Radius)
				local ahead = center + Vector3.new(math.cos(a + 0.2) * bat.Radius, bat.Height, math.sin(a + 0.2) * bat.Radius)
				local flap = math.sin(t * 18 + bat.Phase) * 0.6
				bat.Part.CFrame = CFrame.lookAt(pos, ahead) * CFrame.Angles(0, 0, flap)
			end
		end
	end
	if next(swarms) == nil and swarmConn then
		swarmConn:Disconnect()
		swarmConn = nil
	end
end

local function addBats(character: Model): boolean
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return false
	end
	if character:FindFirstChild(PREFIX .. "Bats") then
		return true
	end
	local model = Instance.new("Model")
	model.Name = PREFIX .. "Bats"
	local list = {}
	local rng = Random.new()
	for i = 1, 7 do
		local bat = part({ Name = "Bat", Anchored = true, Size = Vector3.new(1.1, 0.12, 0.45), Color = Color3.fromRGB(20, 16, 24), CFrame = head.CFrame }, model)
		part({ Name = "Eyes", Anchored = true, Size = Vector3.new(0.3, 0.1, 0.1), Color = Color3.fromRGB(255, 50, 50), Material = Enum.Material.Neon, CFrame = bat.CFrame }, bat)
		table.insert(list, { Part = bat, Radius = rng:NextNumber(2.2, 4), Speed = rng:NextNumber(1.6, 3) * (if i % 2 == 0 then 1 else -1), Phase = rng:NextNumber(0, math.pi * 2), Height = rng:NextNumber(0.5, 2.5) })
	end
	model.Parent = character
	-- Keep the eyes on their bat.
	for _, entry in ipairs(list) do
		local eyes = entry.Part:FindFirstChild("Eyes") :: BasePart?
		if eyes then
			eyes.Anchored = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = entry.Part
			w.Part1 = eyes
			w.Parent = eyes
			eyes.CFrame = entry.Part.CFrame * CFrame.new(0, 0.08, -0.2)
		end
	end
	swarms[model] = { Head = head, Bats = list }
	if not swarmConn then
		swarmConn = RunService.Heartbeat:Connect(stepSwarms)
	end
	return true
end

local function removeBats(character: Model): boolean
	local model = character:FindFirstChild(PREFIX .. "Bats")
	if model and model:IsA("Model") then
		swarms[model] = nil
	end
	return remove(character, "Bats")
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
local function apply(ctx: CommandContext, fn: (Model) -> boolean, verb: string): CommandResult
	local count = 0
	for _, target in ipairs(ctx.Targets) do
		local character = target.Character
		if character and fn(character) then
			count += 1
		end
	end
	return { Success = count > 0, Message = (if count > 0 then "%s %d player(s)." else "No character to change (%s 0)."):format(verb, count) }
end

local function register(name: string, aliases: { string }, description: string, fn: (Model) -> boolean, verb: string, inverse: string?)
	CommandRegistry.Register({
		Name = name,
		Aliases = aliases,
		Description = description,
		Usage = "/" .. name .. " target",
		Permission = "player.effects",
		Category = "Effects",
		Subcategory = "Seasonal",
		Cooldown = 1,
		Log = true,
		Undoable = inverse ~= nil,
		Inverse = inverse,
		RequiresTarget = true,
		DefaultSelf = true,
		Execute = function(ctx: CommandContext): CommandResult
			return apply(ctx, fn, verb)
		end,
	})
end

local function removeAll(character: Model): boolean
	local a = removePumpkin(character)
	local b = removeGhost(character)
	local c = removeBats(character)
	return a or b or c
end

register("pumpkin", { "pumpkinhead" }, "Seasonal: puts a glowing pumpkin over the player's head. ;unspooky removes it.", addPumpkin, "Gave a pumpkin head to", "unspooky")
register("ghost", { "ghostform" }, "Seasonal: turns the player into a pale, see-through ghost. ;unspooky removes it.", addGhost, "Turned into a ghost:", "unspooky")
register("bats", { "batswarm" }, "Seasonal: a swarm of bats circles the player's head. ;unspooky removes it.", addBats, "Bat swarm on", "unspooky")
register("unspooky", { "unseasonal" }, "Removes the pumpkin head, ghost form and bat swarm from the player.", removeAll, "Removed seasonal effects from", nil)

-- ---------------------------------------------------------------------------
-- Spooky Night (server-wide event)
-- ---------------------------------------------------------------------------
local LIGHTING_KEYS = { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "FogStart", "FogEnd", "FogColor", "ExposureCompensation" }
local saved: { [string]: any }? = nil
local savedAtmosphere: { [string]: any }? = nil
local activeCount = 0

local function startSpooky()
	activeCount += 1
	if activeCount > 1 then
		return
	end
	saved = {}
	for _, key in ipairs(LIGHTING_KEYS) do
		(saved :: any)[key] = (Lighting :: any)[key]
	end
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		savedAtmosphere = { Density = atmosphere.Density, Color = atmosphere.Color, Decay = atmosphere.Decay, Haze = atmosphere.Haze }
		atmosphere.Density = 0.45
		atmosphere.Color = Color3.fromRGB(70, 60, 90)
		atmosphere.Decay = Color3.fromRGB(40, 20, 50)
		atmosphere.Haze = 2
	end
	Lighting.ClockTime = 0
	Lighting.Brightness = 0.6
	Lighting.Ambient = Color3.fromRGB(40, 30, 55)
	Lighting.OutdoorAmbient = Color3.fromRGB(55, 40, 75)
	Lighting.FogColor = Color3.fromRGB(35, 25, 45)
	Lighting.FogStart = 0
	Lighting.FogEnd = 160
	Lighting.ExposureCompensation = -0.3
end

local function stopSpooky()
	activeCount = math.max(0, activeCount - 1)
	if activeCount > 0 or not saved then
		return
	end
	for key, value in pairs(saved :: any) do
		pcall(function()
			(Lighting :: any)[key] = value
		end)
	end
	saved = nil
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere and savedAtmosphere then
		for key, value in pairs(savedAtmosphere) do
			(atmosphere :: any)[key] = value
		end
	end
	savedAtmosphere = nil
end

EventService.Define({
	Id = "spookynight",
	Name = "Spooky Night",
	Description = "Dark night sky, purple fog. Lighting goes back to normal when it ends.",
	Color = "A78BFA",
	Multipliers = {},
	DefaultDuration = 600,
	Aliases = { "spooky", "halloween" },
	OnStart = function(_event: any)
		startSpooky()
	end,
	OnStop = function(_event: any)
		stopSpooky()
	end,
})

CommandRegistry.Register({
	Name = "clearseasonal",
	Aliases = { "clearhalloween", "clearspooky" },
	Description = "Removes every seasonal effect (pumpkin heads, ghosts, bat swarms) from all players and stops a running Spooky Night.",
	Usage = "/clearseasonal",
	Permission = "player.effects",
	Category = "Effects",
	Subcategory = "Seasonal",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character and removeAll(player.Character) then
				count += 1
			end
		end
		local stopped = 0
		for _, event in ipairs(EventService.Active()) do
			if event.Preset == "spookynight" then
				local stopOk, done = pcall(EventService.Stop, ctx.Executor, event.Id)
				if stopOk and done then
					stopped += 1
				end
			end
		end
		return {
			Success = true,
			Message = ("Cleared seasonal effects from %d player(s)%s."):format(count, if stopped > 0 then " and stopped Spooky Night" else ""),
		}
	end,
})

return true
