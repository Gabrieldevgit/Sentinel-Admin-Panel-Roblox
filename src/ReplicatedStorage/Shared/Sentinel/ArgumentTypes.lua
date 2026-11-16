--!strict
--[[
	ArgumentTypes.lua

	Purpose:
		Registry of command argument types (W05). Each type knows how to
		validate a typed value and how to suggest completions for a partial
		value. Shared, so the command palette (client) validates and
		autocompletes with exactly the same rules the server registered.

	Built-in types:
		players  – a target expression: name, me/all/others/random/nearest/
		           last, @team <name>, @rank <name>, @role <name>, @staff,
		           @vip, #tag, comma lists ("a,b")
		player   – one player name
		duration – 30s, 5m, 2h, 1d, 1w, 1mo, 1y, perm
		number / integer – optional Min / Max on the argument spec
		boolean  – on/off/true/false/yes/no
		choice   – one of the argument's Choices
		rank, team – existing rank / team names
		string   – one word;  text – free text (usually the rest of the line)

	Custom types (API):
		ArgumentTypes.Register("color", {
			Description = "A colour name or R,G,B",
			Validate = function(value, env, arg) return true end,       -- or false, "message"
			Suggest = function(partial, env, arg) return { { Text = "red" } } end,
		})
		Register from a module both server and client can reach (e.g. under
		ReplicatedStorage) so the palette knows the type too. Unknown types
		fall back to "string" plus the argument's Choices/Suggestions.

	env (supplied by the caller):
		{ Players = {Player}, Teams = {Team}, Ranks = {{Name, Color?}} }
--]]

export type Suggestion = {
	Text: string, -- inserted into the input
	Label: string?, -- shown in the list (defaults to Text)
	Detail: string?, -- secondary text
	Image: string?, -- e.g. avatar headshot
	Color: Color3?,
}

export type ArgSpec = {
	Name: string,
	Type: string,
	Optional: boolean?,
	Rest: boolean?,
	Choices: { string }?,
	Suggestions: { string }?,
	Description: string?,
	Min: number?,
	Max: number?,
	Modifier: ArgSpec?, -- "target:duration" style suffix
}

export type TypeDef = {
	Description: string,
	Validate: ((value: string, env: any, arg: ArgSpec) -> (boolean, string?))?,
	Suggest: ((partial: string, env: any, arg: ArgSpec) -> { Suggestion })?,
}

local ArgumentTypes = {}

local registry: { [string]: TypeDef } = {}

local MAX_SUGGESTIONS = 8

local function startsWith(text: string, prefix: string): boolean
	return text:lower():sub(1, #prefix) == prefix:lower()
end

local function fromList(list: { string }, partial: string, detail: string?): { Suggestion }
	local out: { Suggestion } = {}
	for _, item in ipairs(list) do
		if startsWith(item, partial) then
			table.insert(out, { Text = item, Detail = detail })
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Durations (same grammar as Core/Parser/DurationParser on the server)
-- ---------------------------------------------------------------------------
local UNIT_SECONDS: { [string]: number } = { s = 1, m = 60, h = 3600, d = 86400, w = 604800, mo = 2592000, y = 31536000 }
local UNIT_ORDER = { "s", "m", "h", "d", "w", "mo", "y" }
local UNIT_WORD = { s = "seconds", m = "minutes", h = "hours", d = "days", w = "weeks", mo = "months", y = "years" }
local PERMANENT = { perm = true, permanent = true, forever = true }

function ArgumentTypes.ParseDuration(raw: string): number?
	local lowered = raw:lower()
	if PERMANENT[lowered] then
		return math.huge
	end
	local number, unit = lowered:match("^(%d+%.?%d*)(%a+)$")
	if not number or not unit or not UNIT_SECONDS[unit] then
		return nil
	end
	local amount = tonumber(number)
	if not amount or amount <= 0 then
		return nil
	end
	return amount * UNIT_SECONDS[unit]
end

local COMMON_DURATIONS = { "30s", "5m", "15m", "30m", "1h", "6h", "1d", "3d", "7d", "30d", "perm" }

-- ---------------------------------------------------------------------------
-- Players / target expressions
-- ---------------------------------------------------------------------------
local KEYWORDS = {
	{ "me", "Yourself" },
	{ "all", "Everyone in the server" },
	{ "others", "Everyone except you" },
	{ "random", "One random player" },
	{ "nearest", "Closest player to you" },
	{ "last", "Your previous targets" },
}
local KEYWORD_SET: { [string]: boolean } = {}
for _, k in ipairs(KEYWORDS) do
	KEYWORD_SET[k[1]] = true
end
local AT_SELECTORS = {
	{ "@team", "Players on a team (then a team name)" },
	{ "@rank", "Players with a rank (then a rank name)" },
	{ "@role", "Players with a role (then a role name)" },
	{ "@staff", "Everyone who can open the panel" },
	{ "@vip", "Players with the VIP role" },
	{ "@group", "Players in a group (then a group id)" },
	{ "@attribute", "Players with an attribute (then its name)" },
}
-- Selectors that take the NEXT token as their value ("@team Red").
ArgumentTypes.ValueSelectors = { team = "team", rank = "rank", role = "rank", group = "string", attribute = "string" }

local function playerList(env: any): { Player }
	return (env and env.Players) or {}
end

-- Mirrors the server's TargetResolver name lookup: exact name, then a
-- case-insensitive exact Name/DisplayName, then a unique prefix.
function ArgumentTypes.FindPlayer(name: string, players: { Player }): Player?
	local lowered = name:lower()
	for _, p in ipairs(players) do
		if p.Name == name then
			return p
		end
	end
	for _, p in ipairs(players) do
		if p.Name:lower() == lowered or p.DisplayName:lower() == lowered then
			return p
		end
	end
	local match: Player? = nil
	for _, p in ipairs(players) do
		if startsWith(p.Name, lowered) or startsWith(p.DisplayName, lowered) then
			if match and match ~= p then
				return nil -- ambiguous
			end
			match = p
		end
	end
	return match
end

local function headshot(userId: number): string
	return ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(userId)
end

local function suggestPlayers(partial: string, env: any, includeSelectors: boolean): { Suggestion }
	-- Comma lists: complete only the last piece, keep the rest.
	local head, piece = partial:match("^(.*,)([^,]*)$")
	head = head or ""
	piece = piece or partial

	local out: { Suggestion } = {}
	for _, p in ipairs(playerList(env)) do
		if piece == "" or startsWith(p.Name, piece) or startsWith(p.DisplayName, piece) then
			table.insert(out, {
				Text = head .. p.Name,
				Label = if p.DisplayName ~= p.Name then ("%s  @%s"):format(p.DisplayName, p.Name) else p.Name,
				Detail = if p.Team then "Team " .. p.Team.Name else nil,
				Image = headshot(p.UserId),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.Text:lower() < b.Text:lower()
	end)
	if includeSelectors then
		for _, k in ipairs(KEYWORDS) do
			if startsWith(k[1], piece) and (piece ~= "" or head == "") then
				table.insert(out, { Text = head .. k[1], Detail = k[2] })
			end
		end
		if piece:sub(1, 1) == "@" or piece == "" then
			for _, s in ipairs(AT_SELECTORS) do
				if startsWith(s[1], piece) then
					table.insert(out, { Text = head .. s[1], Detail = s[2] })
				end
			end
		end
	end
	return out
end

local function validateTargetPiece(piece: string, env: any): (boolean, string?)
	if piece == "" then
		return false, "Empty target in list"
	end
	local lowered = piece:lower()
	if KEYWORD_SET[lowered] or piece:sub(1, 1) == "#" then
		return true
	end
	if piece:sub(1, 1) == "@" then
		-- Known selectors, or property selectors such as "@level >25".
		if lowered:sub(2):match("^%a+$") then
			return true
		end
		return false, ("'%s' is not a selector"):format(piece)
	end
	if ArgumentTypes.FindPlayer(piece, playerList(env)) then
		return true
	end
	return false, ("No player in this server matches '%s'"):format(piece)
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------
function ArgumentTypes.Register(name: string, def: TypeDef)
	assert(type(name) == "string" and #name > 0, "type name required")
	assert(type(def) == "table" and type(def.Description) == "string", "type needs a Description")
	registry[name:lower()] = def
end

function ArgumentTypes.Get(name: string): TypeDef?
	return registry[(name or ""):lower()]
end

function ArgumentTypes.Has(name: string): boolean
	return registry[(name or ""):lower()] ~= nil
end

function ArgumentTypes.Names(): { string }
	local list = {}
	for name in pairs(registry) do
		table.insert(list, name)
	end
	table.sort(list)
	return list
end

-- Validates one value for an argument. Choices on the argument apply to
-- every type. Returns (ok, message?).
function ArgumentTypes.Validate(arg: ArgSpec, value: string, env: any): (boolean, string?)
	if arg.Choices and #arg.Choices > 0 and (arg.Type == "choice" or not ArgumentTypes.Has(arg.Type)) then
		for _, c in ipairs(arg.Choices) do
			if c:lower() == value:lower() then
				return true
			end
		end
		return false, ("%s must be one of: %s"):format(arg.Name, table.concat(arg.Choices, ", "))
	end
	local def = ArgumentTypes.Get(arg.Type) or registry.string
	if def and def.Validate then
		local ok, result, message = pcall(def.Validate, value, env, arg)
		if not ok then
			return true -- a broken custom validator never blocks typing
		end
		return result, message
	end
	return true
end

function ArgumentTypes.Suggest(arg: ArgSpec, partial: string, env: any): { Suggestion }
	local out: { Suggestion }
	if arg.Choices and #arg.Choices > 0 then
		out = fromList(arg.Choices, partial)
	else
		local def = ArgumentTypes.Get(arg.Type)
		out = {}
		if def and def.Suggest then
			local ok, result = pcall(def.Suggest, partial, env, arg)
			if ok and type(result) == "table" then
				out = result
			end
		end
		if arg.Suggestions then
			for _, s in ipairs(fromList(arg.Suggestions, partial)) do
				table.insert(out, s)
			end
		end
	end
	while #out > MAX_SUGGESTIONS do
		table.remove(out)
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Built-in types
-- ---------------------------------------------------------------------------
ArgumentTypes.Register("players", {
	Description = "Player name, me, all, others, random, nearest, @team <name>, @rank <name>, @staff, or a comma list",
	Validate = function(value, env)
		for piece in (value .. ","):gmatch("([^,]*),") do
			local ok, message = validateTargetPiece(piece, env)
			if not ok then
				return false, message
			end
		end
		return true
	end,
	Suggest = function(partial, env)
		return suggestPlayers(partial, env, true)
	end,
})

ArgumentTypes.Register("player", {
	Description = "One player in this server",
	Validate = function(value, env)
		if ArgumentTypes.FindPlayer(value, playerList(env)) then
			return true
		end
		return false, ("No player in this server matches '%s'"):format(value)
	end,
	Suggest = function(partial, env)
		return suggestPlayers(partial, env, false)
	end,
})

ArgumentTypes.Register("duration", {
	Description = "How long: 30s, 5m, 2h, 1d, 1w, 1mo, 1y or perm",
	Validate = function(value)
		if ArgumentTypes.ParseDuration(value) then
			return true
		end
		return false, ("'%s' is not a duration (try 30m, 2h, 7d or perm)"):format(value)
	end,
	Suggest = function(partial)
		local number = partial:match("^(%d+%.?%d*)%a*$")
		if number then
			local out: { Suggestion } = {}
			for _, unit in ipairs(UNIT_ORDER) do
				local text = number .. unit
				if startsWith(text, partial) then
					table.insert(out, { Text = text, Detail = ("%s %s"):format(number, UNIT_WORD[unit]) })
				end
			end
			return out
		end
		local out = fromList(COMMON_DURATIONS, partial)
		for _, s in ipairs(out) do
			if s.Text == "perm" then
				s.Detail = "Permanent"
			end
		end
		return out
	end,
})

local function numberValidator(integer: boolean)
	return function(value: string, _env: any, arg: ArgSpec): (boolean, string?)
		local n = tonumber(value)
		if not n then
			return false, ("%s must be a number"):format(arg.Name)
		end
		if integer and n ~= math.floor(n) then
			return false, ("%s must be a whole number"):format(arg.Name)
		end
		if arg.Min and n < arg.Min then
			return false, ("%s must be at least %s"):format(arg.Name, tostring(arg.Min))
		end
		if arg.Max and n > arg.Max then
			return false, ("%s must be at most %s"):format(arg.Name, tostring(arg.Max))
		end
		return true
	end
end

ArgumentTypes.Register("number", { Description = "A number", Validate = numberValidator(false) })
ArgumentTypes.Register("integer", { Description = "A whole number", Validate = numberValidator(true) })

local BOOLEANS = { "on", "off", "true", "false", "yes", "no" }
ArgumentTypes.Register("boolean", {
	Description = "on or off",
	Validate = function(value, _env, arg)
		if table.find(BOOLEANS, value:lower()) then
			return true
		end
		return false, ("%s must be on or off"):format(arg.Name)
	end,
	Suggest = function(partial)
		return fromList({ "on", "off" }, partial)
	end,
})

ArgumentTypes.Register("choice", { Description = "One of a fixed set of values" })

ArgumentTypes.Register("rank", {
	Description = "A rank name",
	Validate = function(value, env)
		local ranks = env and env.Ranks
		if not ranks or #ranks == 0 then
			return true -- rank list not loaded yet; the server checks anyway
		end
		for _, r in ipairs(ranks) do
			if r.Name:lower() == value:lower() then
				return true
			end
		end
		return false, ("No rank named '%s'"):format(value)
	end,
	Suggest = function(partial, env)
		local out: { Suggestion } = {}
		for _, r in ipairs((env and env.Ranks) or {}) do
			if startsWith(r.Name, partial) then
				table.insert(out, {
					Text = r.Name,
					Detail = if r.Priority then "Priority " .. tostring(r.Priority) else nil,
					Color = r.Color,
				})
			end
		end
		return out
	end,
})

ArgumentTypes.Register("team", {
	Description = "A team name",
	Validate = function(value, env)
		local teams = (env and env.Teams) or {}
		for _, team in ipairs(teams) do
			if team.Name == value then
				return true
			end
		end
		if #teams == 0 then
			return false, "This game has no teams"
		end
		return false, ("No team named '%s' (team names are case-sensitive)"):format(value)
	end,
	Suggest = function(partial, env)
		local out: { Suggestion } = {}
		for _, team in ipairs((env and env.Teams) or {}) do
			if startsWith(team.Name, partial) then
				local count = #team:GetPlayers()
				table.insert(out, {
					Text = if team.Name:find("%s") then '"' .. team.Name .. '"' else team.Name,
					Label = team.Name,
					Detail = ("%d player%s"):format(count, if count == 1 then "" else "s"),
					Color = team.TeamColor.Color,
				})
			end
		end
		return out
	end,
})

-- env.Commands: the palette's command metas ({ Name, Aliases, Description }).
ArgumentTypes.Register("command", {
	Description = "A command name or alias",
	Validate = function(value, env)
		local commands = env and env.Commands
		if not commands or #commands == 0 then
			return true
		end
		local lowered = value:lower()
		for _, meta in ipairs(commands) do
			if meta.Name:lower() == lowered or table.find(meta.Aliases or {}, lowered) then
				return true
			end
		end
		return false, ("No command named '%s'"):format(value)
	end,
	Suggest = function(partial, env)
		local out: { Suggestion } = {}
		for _, meta in ipairs((env and env.Commands) or {}) do
			if startsWith(meta.Name, partial) then
				table.insert(out, { Text = meta.Name, Detail = meta.Description })
			end
		end
		return out
	end,
})

ArgumentTypes.Register("string", { Description = "A word" })
ArgumentTypes.Register("text", { Description = "Free text" })

return ArgumentTypes
