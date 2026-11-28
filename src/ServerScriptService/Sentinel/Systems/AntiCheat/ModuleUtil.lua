--!strict
--!native
--[[
	ModuleUtil.lua (Sentinel AntiCheat)

	Purpose:
		Small helpers shared by the detection modules (kept out of the
		Modules folder, where every file must be a detection). The pure
		helpers are used by Check; the Roblox ones only by Gather.

	Public API:
		ModuleUtil.Window(samples, seconds, now?) -> samples newer than now - seconds
		ModuleUtil.Horizontal(a: Vector3, b: Vector3) -> number
		ModuleUtil.Params(character) -> RaycastParams excluding every character
		ModuleUtil.Ground(character, root, depth) -> (distance?, material?, part?)
		ModuleUtil.Seated(humanoid) -> boolean
		ModuleUtil.InVehicle(root) -> boolean
		ModuleUtil.HasMover(character) -> boolean (server-made forces / constraints)
		ModuleUtil.Confidence(ratio, low?, high?) -> 0.3 .. 1
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ModuleUtil = {}

function ModuleUtil.Window(samples: { any }, seconds: number, now: number?): { any }
	local last = samples[#samples]
	if not last then
		return {}
	end
	local t = now or last.T
	local out = {}
	for _, s in ipairs(samples) do
		if t - s.T <= seconds then
			table.insert(out, s)
		end
	end
	return out
end

function ModuleUtil.Horizontal(a: Vector3, b: Vector3): number
	return Vector3.new(b.X - a.X, 0, b.Z - a.Z).Magnitude
end

-- One RaycastParams for every check (building it per ray was the main
-- cost). Rebuilt only when it is stale: a player joined or left, the extra
-- list changed, or a character asked for is not in it yet (a respawn).
local cachedParams: RaycastParams? = nil
local cachedList: { Instance } = {}
local dirty = true

Players.PlayerAdded:Connect(function()
	dirty = true
end)
Players.PlayerRemoving:Connect(function()
	dirty = true
end)

-- Extra characters excluded like players' (the load test's dummy rigs).
local extraCharacters: { Instance } = {}
function ModuleUtil.SetExtraCharacters(list: { Instance })
	extraCharacters = list
	dirty = true
end

function ModuleUtil.Params(character: Instance?): RaycastParams
	if cachedParams and not dirty and (not character or table.find(cachedList, character)) then
		return cachedParams
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, c in ipairs(extraCharacters) do
		table.insert(list, c)
	end
	if character and not table.find(list, character) then
		table.insert(list, character)
	end
	params.FilterDescendantsInstances = list
	params.IgnoreWater = false
	cachedParams, cachedList, dirty = params, list, false
	return params
end

-- Distance from the root down to the first surface (water counts).
-- One ray per character is reused while the root stays put (standing,
-- hovering): JumpCheck and FlyCheck both ask, several times a second, and
-- the ray was most of their cost. Rays are cast at least GROUND_DEPTH deep
-- so one cached answer serves every caller's depth.
local GROUND_DEPTH = 24
local GROUND_MOVE = 0.25 -- studs the root may move before the ray is redone
local GROUND_TTL = 1 -- seconds a cached ray stays valid
type GroundHit = { P: Vector3, T: number, Depth: number, Distance: number?, Material: Enum.Material?, Part: BasePart? }
local groundCache: { [Instance]: GroundHit } = setmetatable({}, { __mode = "k" }) :: any

function ModuleUtil.Ground(character: Instance, root: BasePart, depth: number): (number?, Enum.Material?, BasePart?)
	local pos = root.Position
	local now = os.clock()
	local hit = groundCache[character]
	if not (hit and hit.Depth >= depth and now - hit.T < GROUND_TTL and (pos - hit.P).Magnitude < GROUND_MOVE) then
		local castDepth = math.max(depth, GROUND_DEPTH)
		local result = Workspace:Raycast(pos, Vector3.new(0, -castDepth, 0), ModuleUtil.Params(character))
		hit = {
			P = pos,
			T = now,
			Depth = castDepth,
			Distance = if result then (pos - result.Position).Magnitude else nil,
			Material = if result then result.Material else nil,
			Part = if result then result.Instance :: BasePart else nil,
		}
		groundCache[character] = hit :: GroundHit
	end
	local h = hit :: GroundHit
	if h.Distance == nil or h.Distance > depth then
		return nil, nil, nil
	end
	return h.Distance, h.Material, h.Part
end

function ModuleUtil.Seated(humanoid: Humanoid?): boolean
	return humanoid ~= nil and (humanoid.SeatPart ~= nil or humanoid.Sit or humanoid.PlatformStand)
end

-- Welded to something bigger than the character (vehicle, mount, cart).
function ModuleUtil.InVehicle(root: BasePart?): boolean
	if not root then
		return false
	end
	local assemblyRoot = root.AssemblyRootPart
	return assemblyRoot ~= nil and assemblyRoot ~= root
end

-- Forces / constraints in the character. Exploit-made ones never reach
-- the server, so anything the server sees was made by the game: it is a
-- legitimate "force source" (jump pads, knockback, gliders).
local MOVERS: { [string]: boolean } = {
	BodyVelocity = true, BodyPosition = true, BodyForce = true, BodyGyro = true, BodyThrust = true,
	LinearVelocity = true, VectorForce = true, AlignPosition = true, LineForce = true,
}
-- Mover count per character, kept up to date by DescendantAdded /
-- DescendantRemoving instead of scanning every descendant on every check.
local moverCounts: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

local function watch(character: Instance)
	local n = 0
	for _, d in ipairs(character:GetDescendants()) do
		if MOVERS[d.ClassName] then
			n += 1
		end
	end
	moverCounts[character] = n
	character.DescendantAdded:Connect(function(d)
		if MOVERS[d.ClassName] then
			moverCounts[character] = (moverCounts[character] or 0) + 1
		end
	end)
	character.DescendantRemoving:Connect(function(d)
		if MOVERS[d.ClassName] then
			moverCounts[character] = math.max(0, (moverCounts[character] or 1) - 1)
		end
	end)
end

function ModuleUtil.HasMover(character: Instance?): boolean
	if not character then
		return false
	end
	if moverCounts[character] == nil then
		watch(character)
	end
	return (moverCounts[character] or 0) > 0
end

-- Scripts under a character, as paths relative to it ("Head.Script"),
-- kept current by DescendantAdded / DescendantRemoving after one scan, so
-- CharacterIntegrityCheck never walks every descendant on a check.
-- Scripts inside a tool (an equipped Tool / HopperBin) are left out: every
-- tool brings its own scripts, and ToolIntegrityCheck already judges
-- whether the server gave that tool (live: ;giveitem Sword was flagged as
-- "new script Sword.SwordScript").
local scriptSets: { [Instance]: { [Instance]: string } } = setmetatable({}, { __mode = "k" }) :: any

local function relativeName(character: Instance, d: Instance): string
	return d:GetFullName():sub(#character:GetFullName() + 2)
end

function ModuleUtil.Scripts(character: Instance): { string }
	local set = scriptSets[character]
	if not set then
		local fresh: { [Instance]: string } = {}
		set = fresh
		scriptSets[character] = fresh
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("BaseScript") and not d:FindFirstAncestorWhichIsA("BackpackItem") then
				fresh[d] = relativeName(character, d)
			end
		end
		character.DescendantAdded:Connect(function(d)
			if d:IsA("BaseScript") and not d:FindFirstAncestorWhichIsA("BackpackItem") then
				fresh[d] = relativeName(character, d)
			end
		end)
		character.DescendantRemoving:Connect(function(d)
			fresh[d] = nil
		end)
	end
	local out = {}
	for _, name in pairs(set :: any) do
		table.insert(out, name)
	end
	return out
end

function ModuleUtil.Confidence(ratio: number, low: number?, high: number?): number
	return math.clamp(ratio, low or 0.3, high or 1)
end

return ModuleUtil
