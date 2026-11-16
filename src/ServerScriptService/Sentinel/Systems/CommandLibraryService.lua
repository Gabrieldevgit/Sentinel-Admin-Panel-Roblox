--!strict
--[[
	CommandLibraryService.lua (W07)

	Purpose:
		Each staff member's personal command library, persisted in the
		DataStore Sentinel_CommandLibrary_v1 (key = UserId):
			Favorites  — command names pinned in the palette / Library page
			Presets    — named, exact command lines (may chain with &&)
			Templates  — named command lines with {placeholders} that the
			             command builder turns into input fields
			Recent     — the last command lines the player ran (any source)
		Plus read-only built-in templates everyone gets.

	Placeholders: {name} in a template becomes a field. When the name is an
	argument type (player, players, duration, number, integer, team, rank,
	boolean) the builder uses that type's suggestions and validation;
	anything else is free text. {name?} marks a field optional.

	Public API:
		CommandLibraryService.Get(player) -> library (copy, + BuiltinTemplates)
		CommandLibraryService.Apply(player, action, payload) -> (ok, message)
			actions: "favorite" {Command, On?}, "savePreset" {Name, Text},
			"deletePreset" {Name}, "saveTemplate" {Name, Text, Description?},
			"deleteTemplate" {Name}, "clearRecent" {}
		CommandLibraryService.FindPreset(player, name) -> preset?
		CommandLibraryService.NoteRecent(player, text)
		CommandLibraryService.FillTemplate(text, values) -> (line?, missing?)
		CommandLibraryService.Placeholders(text) -> { {Name, Optional} }
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CommandLibraryService = {}

local STORE_NAME = "Sentinel_CommandLibrary_v1"
local MAX_FAVORITES = 40
local MAX_PRESETS = 50
local MAX_TEMPLATES = 50
local MAX_RECENT = 30
local MAX_TEXT = 400
local MAX_NAME = 32
local SAVE_DELAY = 6

CommandLibraryService.BUILTIN_TEMPLATES = {
	{ Name = "Spam warning", Text = "warn {player} Please stop spamming the chat.", Description = "Formal warning for chat spam." },
	{ Name = "Temporary mute", Text = "mute {player}:{duration} && warn {player} {reason}", Description = "Mute, then log a warning with the reason." },
	{ Name = "Temporary ban", Text = "ban {player}:{duration} {reason}", Description = "Ban for a set time with a reason." },
	{ Name = "Kick with reason", Text = "kick {player} {reason}", Description = "Remove a player from this server." },
	{ Name = "Freeze & investigate", Text = "freeze {player} && note {player} {note}", Description = "Freeze a player and record a moderator note." },
	{ Name = "Reward coins", Text = "givecurrency {players}:{amount}", Description = "Give coins to one or more players." },
	{ Name = "Event countdown", Text = "countdown {seconds:number} {label}", Description = "Show a countdown to everyone." },
	{ Name = "Server announcement", Text = "announce {message}", Description = "Banner announcement to the whole server." },
}

type Library = {
	Favorites: { string },
	Presets: { { Name: string, Text: string } },
	Templates: { { Name: string, Text: string, Description: string? } },
	Recent: { string },
}

local live = RunService:IsRunning() and RunService:IsServer()
local store = if live then DataStoreService:GetDataStore(STORE_NAME) else nil

local libraries: { [number]: Library } = {}
local loading: { [number]: boolean } = {}
local dirty: { [number]: boolean } = {}

local function empty(): Library
	return { Favorites = {}, Presets = {}, Templates = {}, Recent = {} }
end

local function cleanString(v: any, max: number): string?
	if type(v) ~= "string" then
		return nil
	end
	v = v:gsub("[%c]", " "):match("^%s*(.-)%s*$")
	if v == "" or #v > max then
		return nil
	end
	return v
end

local function sanitize(data: any): Library
	local lib = empty()
	if type(data) ~= "table" then
		return lib
	end
	for _, name in ipairs(type(data.Favorites) == "table" and data.Favorites or {}) do
		local n = cleanString(name, 40)
		if n and #lib.Favorites < MAX_FAVORITES then
			table.insert(lib.Favorites, n)
		end
	end
	for _, p in ipairs(type(data.Presets) == "table" and data.Presets or {}) do
		local n, t = cleanString(type(p) == "table" and p.Name, MAX_NAME), cleanString(type(p) == "table" and p.Text, MAX_TEXT)
		if n and t and #lib.Presets < MAX_PRESETS then
			table.insert(lib.Presets, { Name = n, Text = t })
		end
	end
	for _, p in ipairs(type(data.Templates) == "table" and data.Templates or {}) do
		local n, t = cleanString(type(p) == "table" and p.Name, MAX_NAME), cleanString(type(p) == "table" and p.Text, MAX_TEXT)
		if n and t and #lib.Templates < MAX_TEMPLATES then
			table.insert(lib.Templates, { Name = n, Text = t, Description = cleanString(p.Description, 120) })
		end
	end
	for _, line in ipairs(type(data.Recent) == "table" and data.Recent or {}) do
		local t = cleanString(line, MAX_TEXT)
		if t and #lib.Recent < MAX_RECENT then
			table.insert(lib.Recent, t)
		end
	end
	return lib
end

local function save(userId: number)
	local lib = libraries[userId]
	if not store or not lib then
		return
	end
	dirty[userId] = nil
	local ok, err = pcall(function()
		(store :: DataStore):SetAsync(tostring(userId), lib)
	end)
	if not ok then
		warn(("[Sentinel.CommandLibrary] save failed for %d: %s"):format(userId, tostring(err)))
	end
end

local function markDirty(userId: number)
	if dirty[userId] then
		return
	end
	dirty[userId] = true
	task.delay(SAVE_DELAY, function()
		if dirty[userId] then
			save(userId)
		end
	end)
end

local function libraryFor(player: Player): Library
	local userId = player.UserId
	local lib = libraries[userId]
	if lib then
		return lib
	end
	if store and not loading[userId] then
		loading[userId] = true
		local ok, data = pcall(function()
			return (store :: DataStore):GetAsync(tostring(userId))
		end)
		loading[userId] = nil
		lib = sanitize(if ok then data else nil)
		if not ok then
			warn(("[Sentinel.CommandLibrary] load failed for %d: %s"):format(userId, tostring(data)))
		end
	else
		lib = empty()
	end
	-- another thread may have loaded it while this one yielded
	if libraries[userId] then
		return libraries[userId]
	end
	libraries[userId] = lib :: Library
	return lib :: Library
end

Players.PlayerRemoving:Connect(function(player: Player)
	if dirty[player.UserId] then
		save(player.UserId)
	end
	libraries[player.UserId] = nil
end)

if live then
	game:BindToClose(function()
		for userId in pairs(dirty) do
			save(userId)
		end
	end)
end

local function findByName(list: { any }, name: string): number?
	local lower = name:lower()
	for i, item in ipairs(list) do
		if item.Name:lower() == lower then
			return i
		end
	end
	return nil
end

function CommandLibraryService.Get(player: Player): any
	local lib = libraryFor(player)
	return {
		Favorites = table.clone(lib.Favorites),
		Presets = table.clone(lib.Presets),
		Templates = table.clone(lib.Templates),
		Recent = table.clone(lib.Recent),
		BuiltinTemplates = CommandLibraryService.BUILTIN_TEMPLATES,
	}
end

function CommandLibraryService.FindPreset(player: Player, name: string): any
	local lib = libraryFor(player)
	local i = findByName(lib.Presets, name)
	return i and lib.Presets[i]
end

function CommandLibraryService.FindTemplate(player: Player, name: string): any
	local lib = libraryFor(player)
	local i = findByName(lib.Templates, name)
	if i then
		return lib.Templates[i]
	end
	i = findByName(CommandLibraryService.BUILTIN_TEMPLATES, name)
	return i and CommandLibraryService.BUILTIN_TEMPLATES[i]
end

function CommandLibraryService.NoteRecent(player: Player, text: string)
	local t = cleanString(text, MAX_TEXT)
	if not t then
		return
	end
	local lib = libraryFor(player)
	local i = table.find(lib.Recent, t)
	if i then
		table.remove(lib.Recent, i)
	end
	table.insert(lib.Recent, 1, t)
	while #lib.Recent > MAX_RECENT do
		table.remove(lib.Recent)
	end
	markDirty(player.UserId)
end

function CommandLibraryService.Apply(player: Player, action: any, payload: any): (boolean, string)
	local lib = libraryFor(player)
	payload = if type(payload) == "table" then payload else {}
	if action == "favorite" then
		local name = cleanString(payload.Command, 40)
		if not name then
			return false, "Which command?"
		end
		name = name:lower()
		local i = table.find(lib.Favorites, name)
		local on = if payload.On == nil then i == nil else payload.On == true
		if on and not i then
			if #lib.Favorites >= MAX_FAVORITES then
				return false, ("You can have at most %d favorites."):format(MAX_FAVORITES)
			end
			table.insert(lib.Favorites, name)
		elseif not on and i then
			table.remove(lib.Favorites, i)
		end
		markDirty(player.UserId)
		return true, if on then ("Added %s to favorites."):format(name) else ("Removed %s from favorites."):format(name)
	elseif action == "savePreset" or action == "saveTemplate" then
		local name = cleanString(payload.Name, MAX_NAME)
		local text = cleanString(payload.Text, MAX_TEXT)
		if not name or not text then
			return false, ("A name (≤%d chars) and a command (≤%d chars) are required."):format(MAX_NAME, MAX_TEXT)
		end
		text = text:gsub("^[;:!%./%-%?>]", "")
		local isPreset = action == "savePreset"
		local list: { any } = if isPreset then lib.Presets else lib.Templates
		local entry: any = { Name = name, Text = text }
		if not isPreset then
			entry.Description = cleanString(payload.Description, 120)
			if #CommandLibraryService.Placeholders(text) == 0 then
				return false, "A template needs at least one {placeholder}."
			end
		end
		local i = findByName(list, name)
		if i then
			list[i] = entry
		else
			if #list >= (if isPreset then MAX_PRESETS else MAX_TEMPLATES) then
				return false, "Your library is full — delete something first."
			end
			table.insert(list, entry)
		end
		markDirty(player.UserId)
		return true, ("Saved %s '%s'."):format(if isPreset then "preset" else "template", name)
	elseif action == "deletePreset" or action == "deleteTemplate" then
		local name = cleanString(payload.Name, MAX_NAME)
		local list: { any } = if action == "deletePreset" then lib.Presets else lib.Templates
		local i = name and findByName(list, name)
		if not i then
			return false, "Not found."
		end
		table.remove(list, i)
		markDirty(player.UserId)
		return true, ("Deleted '%s'."):format(name :: string)
	elseif action == "clearRecent" then
		table.clear(lib.Recent)
		markDirty(player.UserId)
		return true, "Cleared recent commands."
	end
	return false, "Unknown action."
end

-- "{player}" / "{seconds:number}" / "{reason?}" -> { Name, Type?, Optional }
function CommandLibraryService.Placeholders(text: string): { any }
	local out, seen = {}, {}
	for inner in text:gmatch("{([^{}]+)}") do
		local optional = inner:sub(-1) == "?"
		if optional then
			inner = inner:sub(1, -2)
		end
		local name, typ = inner:match("^%s*([%w_]+)%s*:%s*([%w_]+)%s*$")
		name = name or inner:match("^%s*([%w_]+)%s*$")
		if name and not seen[name] then
			seen[name] = true
			table.insert(out, { Name = name, Type = typ or name, Optional = optional })
		end
	end
	return out
end

-- Fills {placeholders}; returns the command line, or nil + the first
-- missing required placeholder.
function CommandLibraryService.FillTemplate(text: string, values: { [string]: string }): (string?, string?)
	local missing: string? = nil
	local line = text:gsub("{([^{}]+)}", function(inner: string)
		local optional = inner:sub(-1) == "?"
		local name = (if optional then inner:sub(1, -2) else inner):match("^%s*([%w_]+)")
		local v = name and values[name]
		if type(v) == "string" and v:match("%S") then
			return (v:gsub("&&", "&"))
		end
		if not optional and not missing then
			missing = name
		end
		return ""
	end)
	if missing then
		return nil, missing
	end
	return (line:gsub("%s+", " "):match("^%s*(.-)%s*$")), nil
end

return CommandLibraryService
