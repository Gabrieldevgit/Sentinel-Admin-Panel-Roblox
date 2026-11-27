--!strict
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

-- One RaycastParams for every check, refreshed when the character list
-- changes (at most every 0.5 s) - building it per ray was the main cost.
local cachedParams: RaycastParams? = nil
local cachedAt = -math.huge
local cachedCount = -1
local cachedList: { Instance } = {}

function ModuleUtil.Params(character: Instance?): RaycastParams
	local now = os.clock()
	local players = Players:GetPlayers()
	if cachedParams and now - cachedAt < 0.5 and #players == cachedCount then
		if not character or table.find(cachedList, character) then
			return cachedParams
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = {}
	for _, p in ipairs(players) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	if character and not table.find(list, character) then
		table.insert(list, character)
	end
	params.FilterDescendantsInstances = list
	params.IgnoreWater = false
	cachedParams, cachedAt, cachedCount, cachedList = params, now, #players, list
	return params
end

-- Distance from the root down to the first surface (water counts).
function ModuleUtil.Ground(character: Instance, root: BasePart, depth: number): (number?, Enum.Material?, BasePart?)
	local result = Workspace:Raycast(root.Position, Vector3.new(0, -depth, 0), ModuleUtil.Params(character))
	if not result then
		return nil, nil, nil
	end
	return (root.Position - result.Position).Magnitude, result.Material, result.Instance :: BasePart
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

function ModuleUtil.Confidence(ratio: number, low: number?, high: number?): number
	return math.clamp(ratio, low or 0.3, high or 1)
end

return ModuleUtil
