--!strict
--[[
	MapService.lua (HD Admin gap: SaveMap / LoadMap / ClearMap)

	Named snapshots of the map (Workspace + Terrain), kept in this server's
	memory under ServerStorage.SentinelMapSnapshots. A "start" snapshot is
	taken a few seconds after the server boots, so ;loadmap works even if
	nobody saved one.

	What a snapshot covers: every top-level Workspace child except player
	characters, the Camera, Terrain (copied separately as a TerrainRegion),
	non-Archivable instances, and anything with the attribute
	`SentinelMapIgnore = true` or named "Sentinel*" (Sentinel's own runtime
	objects such as the jail spawn).

	Script safety: a top-level object that holds a Script / LocalScript is
	restored only when it is missing (destroyed). If it still exists it is
	left alone, so game systems in Workspace are never restarted.

	Public API:
		MapService.Save(name, by, root?): (ok, message)   -- root: tests only
		MapService.Load(name, root?): (ok, message)
		MapService.Clear(): (ok, message)       -- keeps SpawnLocations
		MapService.Delete(name): boolean
		MapService.List(): { SnapshotInfo }
		MapService.Has(name): boolean
		MapService.CleanName(raw): string?
		MapService.IsMapObject(inst): boolean
		MapService.MAX_SNAPSHOTS
--]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local MapService = {}

MapService.MAX_SNAPSHOTS = 6 -- the automatic "start" + "undo" count too
MapService.START = "start"
MapService.UNDO = "undo"

export type SnapshotInfo = {
	Name: string,
	By: string,
	At: number,
	Objects: number,
	Parts: number,
	Terrain: boolean,
}

local infos: { [string]: SnapshotInfo } = {}

local function storage(): Folder
	local folder = ServerStorage:FindFirstChild("SentinelMapSnapshots")
	if not folder then
		local created = Instance.new("Folder")
		created.Name = "SentinelMapSnapshots"
		created.Parent = ServerStorage
		folder = created
	end
	return folder :: Folder
end

function MapService.CleanName(raw: string?): string?
	if raw == nil or raw == "" then
		return "default"
	end
	local name = (raw :: string):lower():gsub("[^%w_%-]", "")
	if name == "" or #name > 24 then
		return nil
	end
	return name
end

local function isCharacter(inst: Instance): boolean
	return inst:IsA("Model") and Players:GetPlayerFromCharacter(inst) ~= nil
end

function MapService.IsMapObject(inst: Instance): boolean
	if inst:IsA("Terrain") or inst:IsA("Camera") or not inst.Archivable then
		return false
	end
	if isCharacter(inst) then
		return false
	end
	if inst:GetAttribute("SentinelMapIgnore") == true then
		return false
	end
	if inst.Name:sub(1, 8) == "Sentinel" then
		return false
	end
	return true
end

local function holdsScripts(inst: Instance): boolean
	if inst:IsA("BaseScript") then
		return true
	end
	return inst:FindFirstChildWhichIsA("BaseScript", true) ~= nil
end

local function countParts(inst: Instance): number
	local n = if inst:IsA("BasePart") then 1 else 0
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

-- Identity of a top-level object, used to match a scripted object in the
-- snapshot with the live one (restore only when missing).
local function key(inst: Instance): string
	return inst.ClassName .. "|" .. inst.Name
end

local function prune()
	local list = MapService.List()
	-- Oldest user snapshots go first; "start" is kept as long as possible.
	while #list > MapService.MAX_SNAPSHOTS do
		local victim: SnapshotInfo? = nil
		for i = #list, 1, -1 do
			if list[i].Name ~= MapService.START then
				victim = list[i]
				break
			end
		end
		if not victim then
			break
		end
		MapService.Delete(victim.Name)
		list = MapService.List()
	end
end

function MapService.Save(rawName: string?, by: string?, root: Instance?): (boolean, string)
	local container: Instance = root or Workspace
	local name = MapService.CleanName(rawName)
	if not name then
		return false, "Snapshot names are 1-24 letters, digits, - or _."
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	local objects, parts = 0, 0
	for _, child in ipairs(container:GetChildren()) do
		if not MapService.IsMapObject(child) then
			continue
		end
		local ok, copy = pcall(function()
			return child:Clone()
		end)
		if ok and copy then
			copy.Parent = folder
			objects += 1
			parts += countParts(copy)
		end
	end

	local hasTerrain = false
	local terrain = Workspace.Terrain
	local ok: boolean, region: any = false, nil
	if container == Workspace then
		ok, region = pcall(function()
			return terrain:CopyRegion(terrain.MaxExtents)
		end)
	end
	if ok and region then
		region.Name = "__Terrain"
		region.Parent = folder
		hasTerrain = true
	end

	local old = storage():FindFirstChild(name)
	if old then
		old:Destroy()
	end
	folder.Parent = storage()
	infos[name] = {
		Name = name,
		By = by or "Server",
		At = os.time(),
		Objects = objects,
		Parts = parts,
		Terrain = hasTerrain,
	}
	prune()
	return true, ("Saved map snapshot '%s' (%d objects, %d parts%s)."):format(
		name,
		objects,
		parts,
		if hasTerrain then ", terrain" else ""
	)
end

function MapService.Has(rawName: string?): boolean
	local name = MapService.CleanName(rawName)
	return name ~= nil and storage():FindFirstChild(name :: string) ~= nil
end

function MapService.Load(rawName: string?, root: Instance?): (boolean, string)
	local container: Instance = root or Workspace
	local name = MapService.CleanName(rawName)
	if not name then
		return false, "Snapshot names are 1-24 letters, digits, - or _."
	end
	local folder = storage():FindFirstChild(name)
	if not folder then
		return false, ("No map snapshot named '%s' (see ;maps)."):format(name)
	end

	-- Live scripted objects stay; remember them so they're not duplicated.
	local liveScripted: { [string]: boolean } = {}
	for _, child in ipairs(container:GetChildren()) do
		if MapService.IsMapObject(child) then
			if holdsScripts(child) then
				liveScripted[key(child)] = true
			else
				child:Destroy()
			end
		end
	end

	local restored, kept = 0, 0
	local terrainRegion: TerrainRegion? = nil
	for _, saved in ipairs(folder:GetChildren()) do
		if saved:IsA("TerrainRegion") then
			terrainRegion = saved
			continue
		end
		if holdsScripts(saved) and liveScripted[key(saved)] then
			kept += 1
			continue
		end
		local ok, copy = pcall(function()
			return saved:Clone()
		end)
		if ok and copy then
			copy.Parent = container
			restored += 1
		end
	end

	if terrainRegion and container == Workspace then
		local terrain = Workspace.Terrain
		pcall(function()
			terrain:Clear()
			terrain:PasteRegion(terrainRegion, terrain.MaxExtents.Min, true)
		end)
	end

	return true, ("Loaded map snapshot '%s' (%d objects restored%s%s)."):format(
		name,
		restored,
		if kept > 0 then (", %d scripted kept as-is"):format(kept) else "",
		if terrainRegion then ", terrain" else ""
	)
end

function MapService.Clear(): (boolean, string)
	local removed = 0
	for _, child in ipairs(Workspace:GetChildren()) do
		if MapService.IsMapObject(child) and not child:IsA("SpawnLocation") then
			if holdsScripts(child) then
				continue
			end
			child:Destroy()
			removed += 1
		end
	end
	pcall(function()
		Workspace.Terrain:Clear()
	end)
	return true, ("Cleared the map (%d objects removed; spawns and scripted objects kept)."):format(removed)
end

function MapService.Delete(rawName: string?): boolean
	local name = MapService.CleanName(rawName)
	if not name then
		return false
	end
	local folder = storage():FindFirstChild(name)
	infos[name] = nil
	if folder then
		folder:Destroy()
		return true
	end
	return false
end

function MapService.List(): { SnapshotInfo }
	local list = {}
	for _, folder in ipairs(storage():GetChildren()) do
		local info = infos[folder.Name]
		if info then
			table.insert(list, info)
		end
	end
	table.sort(list, function(a, b)
		if a.At == b.At then
			return a.Name < b.Name
		end
		return a.At > b.At
	end)
	return list
end

-- Boot snapshot, once the place's own scripts have built the map (never in
-- Edit mode, where it would be saved into the place file).
task.delay(5, function()
	if not game:GetService("RunService"):IsRunning() then
		return
	end
	if not MapService.Has(MapService.START) then
		MapService.Save(MapService.START, "Server start")
	end
end)

return MapService
