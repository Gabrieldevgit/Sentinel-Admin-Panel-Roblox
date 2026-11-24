--!strict
--[[
	Map.lua (HD Admin gap: SaveMap / LoadMap / ClearMap)

		;savemap [name]     (smap)     snapshot the map (default "default")
		;loadmap [name]     (lmap)     restore a snapshot; "start" = as the server booted
		;clearmap           (cmap)     remove the whole map (spawns + scripted objects stay)
		;maps               (maplist)  list snapshots
		;deletemap name     (dmap)

	;loadmap and ;clearmap need ;confirm (high risk) and are undoable: they
	first save the current map as the "undo" snapshot. Node server.map
	(Admin+ via server.*). See Systems/MapService for what is captured.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local MapService = require(Sentinel:WaitForChild("Systems"):WaitForChild("MapService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function snapshotNames(): { string }
	local names = {}
	for _, info in ipairs(MapService.List()) do
		table.insert(names, info.Name)
	end
	return names
end

local function ago(at: number): string
	local s = math.max(0, os.time() - at)
	if s >= 3600 then
		return ("%dh %dm ago"):format(s // 3600, (s % 3600) // 60)
	elseif s >= 60 then
		return ("%dm ago"):format(s // 60)
	end
	return ("%ds ago"):format(s)
end

local function undoToSnapshot(): CommandResult
	if not MapService.Has(MapService.UNDO) then
		return { Success = false, Message = "The undo snapshot is gone." }
	end
	local ok, message = MapService.Load(MapService.UNDO)
	return { Success = ok, Message = message }
end

CommandRegistry.Register({
	Name = "savemap",
	Aliases = { "smap", "mapsave" },
	Description = "Saves a snapshot of the map (parts, models, terrain) in this server's memory. Restore it with ;loadmap.",
	Usage = "/savemap [name]",
	ArgHints = { name = { Type = "string", Description = "Snapshot name (default: default)", Suggestions = snapshotNames } },
	Examples = { "savemap", "savemap arena" },
	Permission = "server.map",
	Category = "Server",
	Subcategory = "Map",
	Cooldown = 3,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local name = ctx.Arguments[1]
		if MapService.CleanName(name) == MapService.UNDO then
			return { Success = false, Message = "'undo' is reserved for ;loadmap / ;clearmap undo." }
		end
		local ok, message = MapService.Save(name, ctx.Executor.Name)
		return { Success = ok, Message = message }
	end,
} :: any)

CommandRegistry.Register({
	Name = "loadmap",
	Aliases = { "lmap", "mapload", "restoremap" },
	Description = "Restores a map snapshot: the current map is replaced (objects holding scripts are only put back if missing). 'start' is the map as the server booted.",
	Usage = "/loadmap [name]",
	ArgHints = { name = { Type = "string", Description = "Snapshot name (default: default)", Suggestions = snapshotNames } },
	Examples = { "loadmap", "loadmap start" },
	Permission = "server.map",
	Category = "Server",
	Subcategory = "Map",
	Risk = "high",
	Cooldown = 5,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local name = ctx.Arguments[1]
		if not MapService.Has(name) then
			return { Success = false, Message = ("No map snapshot named '%s' (see ;maps)."):format(MapService.CleanName(name) or tostring(name)) }
		end
		MapService.Save(MapService.UNDO, ctx.Executor.Name)
		local ok, message = MapService.Load(name)
		return { Success = ok, Message = message, Undoable = ok } :: any
	end,
	Undo = function(_ctx: CommandContext, _result: any): CommandResult
		return undoToSnapshot()
	end,
} :: any)

CommandRegistry.Register({
	Name = "clearmap",
	Aliases = { "cmap", "wipemap" },
	Description = "Removes the whole map and terrain. Spawn locations, player characters and objects holding scripts stay. Undo with ;undo or ;loadmap undo.",
	Usage = "/clearmap",
	Permission = "server.map",
	Category = "Server",
	Subcategory = "Map",
	Risk = "high",
	Cooldown = 5,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		MapService.Save(MapService.UNDO, ctx.Executor.Name)
		local ok, message = MapService.Clear()
		return { Success = ok, Message = message, Undoable = ok } :: any
	end,
	Undo = function(_ctx: CommandContext, _result: any): CommandResult
		return undoToSnapshot()
	end,
} :: any)

CommandRegistry.Register({
	Name = "maps",
	Aliases = { "maplist", "snapshots" },
	Description = "Lists this server's map snapshots.",
	Usage = "/maps",
	Permission = "server.map",
	Category = "Server",
	Subcategory = "Map",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Execute = function(_ctx: CommandContext): CommandResult
		local list = MapService.List()
		if #list == 0 then
			return { Success = true, Message = "No map snapshots yet. Save one with ;savemap [name]." }
		end
		local lines = { ("%d map snapshot(s) (max %d):"):format(#list, MapService.MAX_SNAPSHOTS) }
		for _, info in ipairs(list) do
			table.insert(
				lines,
				("%s - %d objects, %d parts%s - by %s, %s"):format(
					info.Name,
					info.Objects,
					info.Parts,
					if info.Terrain then ", terrain" else "",
					info.By,
					ago(info.At)
				)
			)
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
} :: any)

CommandRegistry.Register({
	Name = "deletemap",
	Aliases = { "dmap", "removemap" },
	Description = "Deletes a map snapshot from this server's memory.",
	Usage = "/deletemap name",
	ArgHints = { name = { Type = "string", Description = "Snapshot name", Suggestions = snapshotNames } },
	Permission = "server.map",
	Category = "Server",
	Subcategory = "Map",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local name = ctx.Arguments[1]
		if not name then
			return { Success = false, Message = "Usage: /deletemap name (see ;maps)" }
		end
		if not MapService.Delete(name) then
			return { Success = false, Message = ("No map snapshot named '%s'."):format(name) }
		end
		return { Success = true, Message = ("Deleted map snapshot '%s'."):format(MapService.CleanName(name) or name) }
	end,
} :: any)

return true
