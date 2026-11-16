--!strict
--[[
	UsageSpec.lua

	Purpose:
		Turns a command's Usage string ("/ban target:duration [reason]")
		into typed argument specs (W05), and analyses what the user has typed
		so far so the command palette knows which argument the cursor is on,
		what to suggest, and which values are invalid. Shared by the server
		(CommandRegistry builds every command's Args at Register time) and
		the client palette.

	Usage grammar:
		name            required argument, type guessed from the name
		[name]          optional argument;  [a b] = two optional arguments
		a|b|c           choice;  on|off = boolean
		name...         free text, rest of the line
		target:mod      target with a required ":modifier" (target[:mod] = optional)

	Commands can refine the guess without rewriting the Usage:
		ArgHints = { name = { Type = "choice", Choices = {...}, Description = "..." } }
		  (keys are argument names, or 1-based positions)
		Args = { ...full ArgSpec list... }   -- replaces the parsed list
		Examples = { "ban Player1:7d Exploiting" }

	Public API:
		UsageSpec.Parse(usage): { ArgSpec }
		UsageSpec.Build(def): { ArgSpec }
		UsageSpec.Tokenize(text): { Token }
		UsageSpec.Analyze(text, resolve, env): Analysis
		UsageSpec.Signature(args): string
--]]

local ArgumentTypes = require(script.Parent:WaitForChild("ArgumentTypes"))

type ArgSpec = ArgumentTypes.ArgSpec

export type Token = { Text: string, Start: number, End: number, Quoted: boolean }

local UsageSpec = {}

-- Name -> type and hints. Keys are lowercase.
local NAME_HINTS: { [string]: { [string]: any } } = {
	target = { Type = "players" },
	duration = { Type = "duration" },
	reason = { Type = "text", Description = "Why — logged and shown to the player" },
	text = { Type = "text" },
	message = { Type = "text" },
	label = { Type = "text", Description = "Text shown with the countdown" },
	description = { Type = "text" },
	amount = { Type = "number", Suggestions = { "10", "100", "1000" } },
	level = { Type = "integer", Min = 1, Suggestions = { "1", "10", "50" } },
	count = { Type = "integer", Min = 1, Suggestions = { "10", "25", "50" } },
	seconds = { Type = "integer", Min = 0, Suggestions = { "10", "30", "60" } },
	hour = { Type = "number", Min = 0, Max = 24, Suggestions = { "0", "6", "12", "18" }, Description = "Time of day, 0–24" },
	speed = { Type = "number", Min = 0, Suggestions = { "16", "50", "100" } },
	density = { Type = "number", Min = 0, Max = 1, Suggestions = { "0", "0.25", "0.5", "1" } },
	priority = { Type = "integer", Suggestions = { "10", "50", "100" }, Description = "Higher priority ranks outrank lower ones" },
	mingrouprank = { Type = "integer", Min = 0, Max = 255, Description = "Lowest group role rank (0–255) that gets the rank" },
	badgeid = { Type = "integer", Min = 1 },
	rank = { Type = "rank" },
	newname = { Type = "string", Description = "The new name" },
	node = { Type = "string", Description = "Permission node: +node allows, -node removes, +!node denies" },
	id = { Type = "string" },
}

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function makeArg(rawName: string, optional: boolean): ArgSpec
	local rest = false
	local name = rawName
	if name:sub(-3) == "..." then
		rest = true
		name = name:sub(1, -4)
	end

	local modifier: ArgSpec? = nil
	local base, modOpt = name:match("^([^%[:]+)%[:([^%]]+)%]$")
	if base then
		name = base
		modifier = makeArg(modOpt, true)
	else
		local b2, mod = name:match("^([^:]+):(.+)$")
		if b2 then
			name = b2
			modifier = makeArg(mod, false)
		end
	end

	local arg: ArgSpec
	if name:find("|", 1, true) then
		local choices = {}
		local plain = true
		for part in name:gmatch("[^|]+") do
			table.insert(choices, part)
			if not part:match("^%a+$") then
				plain = false
			end
		end
		if plain and #choices == 2 and choices[1]:lower() == "on" and choices[2]:lower() == "off" then
			arg = { Name = "state", Type = "boolean" }
		elseif plain then
			arg = { Name = "option", Type = "choice", Choices = choices }
		else
			-- "+node|-node": not literal choices; name it after the first word
			arg = { Name = (choices[1]:match("%a+") or "value"), Type = "string" }
		end
	else
		arg = { Name = name, Type = "string" }
	end

	local hint = NAME_HINTS[arg.Name:lower()]
	if hint then
		for k, v in pairs(hint) do
			(arg :: any)[k] = v
		end
	end
	if rest then
		arg.Type = if arg.Type == "string" then "text" else arg.Type
		arg.Rest = true
	end
	arg.Optional = optional or nil
	arg.Modifier = modifier
	return arg
end

-- Parses the argument part of a Usage string into ArgSpecs.
function UsageSpec.Parse(usage: string?): { ArgSpec }
	local args: { ArgSpec } = {}
	if type(usage) ~= "string" then
		return args
	end
	-- Drop example text: "...  e.g. priority 25" / anything after two spaces.
	local text = usage:gsub("%s%s+.*$", ""):gsub("%s+e%.g%..*$", "")
	-- Drop the command word itself.
	text = text:gsub("^%s*[/;]?%S+%s*", "", 1)

	local i = 1
	while i <= #text do
		local c = text:sub(i, i)
		if c:match("%s") then
			i += 1
		elseif c == "[" and not text:sub(1, i - 1):match("%S$") then
			local close = text:find("]", i, true) or #text
			local inner = trim(text:sub(i + 1, close - 1))
			i = close + 1
			if inner:find("...", 1, true) then
				-- "[field value ...]" → one optional rest-of-line argument
				local name = trim((inner:gsub("%.%.%.", ""))):gsub("%s+", " ")
				table.insert(args, { Name = name, Type = "text", Rest = true, Optional = true })
			elseif inner:find(" / ", 1, true) then
				-- "[destination / x,y,z]" → one optional argument
				local name = trim(inner:match("^(.-)%s/") or inner)
				local arg = makeArg(name, true)
				arg.Description = arg.Description or ("A " .. name .. " or " .. trim(inner:match("/%s*(.*)$") or ""))
				table.insert(args, arg)
			else
				for word in inner:gmatch("%S+") do
					table.insert(args, makeArg(word, true))
				end
			end
		else
			local wordEnd = (text:find("%s", i) or (#text + 1)) - 1
			-- keep "target[:duration]" together
			table.insert(args, makeArg(text:sub(i, wordEnd), false))
			i = wordEnd + 1
		end
	end

	-- The last free-text argument takes the rest of the line.
	local last = args[#args]
	if last and last.Type == "text" then
		last.Rest = true
	end
	return args
end

-- Builds the final Args for a command definition: explicit Args win,
-- otherwise the parsed Usage refined by ArgHints.
function UsageSpec.Build(def: any): { ArgSpec }
	if type(def.Args) == "table" and #def.Args > 0 and type(def.Args[1]) == "table" and def.Args[1].Name then
		return def.Args
	end
	local args = UsageSpec.Parse(def.Usage)
	if type(def.ArgHints) == "table" then
		for key, hint in pairs(def.ArgHints) do
			for index, arg in ipairs(args) do
				if key == index or (type(key) == "string" and arg.Name:lower() == key:lower()) then
					for k, v in pairs(hint) do
						(arg :: any)[k] = v
					end
				end
			end
		end
	end
	return args
end

-- "ban <target>:<duration> [reason]"
function UsageSpec.Signature(args: { ArgSpec }): string
	local parts = {}
	for _, arg in ipairs(args) do
		local name = arg.Name .. (if arg.Rest then "…" else "")
		local s = if arg.Optional then "[" .. name .. "]" else "<" .. name .. ">"
		if arg.Modifier then
			local m = arg.Modifier
			s ..= if m.Optional then "[:" .. m.Name .. "]" else ":<" .. m.Name .. ">"
		end
		table.insert(parts, s)
	end
	return table.concat(parts, " ")
end

-- Tokenizes like Core/Parser/Tokenizer but keeps positions (1-based,
-- inclusive) so the palette can replace exactly the token being typed.
function UsageSpec.Tokenize(text: string): { Token }
	local tokens: { Token } = {}
	local i, len = 1, #text
	while i <= len do
		local c = text:sub(i, i)
		if c:match("%s") then
			i += 1
		elseif c == '"' then
			local close = text:find('"', i + 1, true)
			local stop = close or len
			table.insert(tokens, {
				Text = text:sub(i + 1, if close then close - 1 else len),
				Start = i,
				End = stop,
				Quoted = true,
			})
			i = stop + 1
		else
			local stop = (text:find("%s", i) or (len + 1)) - 1
			table.insert(tokens, { Text = text:sub(i, stop), Start = i, End = stop, Quoted = false })
			i = stop + 1
		end
	end
	return tokens
end

-- Start index of the last "&&" segment (outside quotes).
local function lastSegmentStart(text: string): number
	local start = 1
	local inQuote = false
	local i = 1
	while i <= #text do
		local c = text:sub(i, i)
		if c == '"' then
			inQuote = not inQuote
		elseif not inQuote and text:sub(i, i + 1) == "&&" then
			start = i + 2
			i += 1
		end
		i += 1
	end
	return start
end

export type Analysis = {
	Part: string, -- "command" | "arg" | "modifier" | "selectorValue" | "extra" | "unknown"
	Command: any?, -- the resolved command meta
	CommandWord: string,
	Arg: ArgSpec?, -- argument the cursor is on (for modifier: the modifier spec)
	ArgIndex: number?,
	Partial: string, -- text of the value being typed
	ReplaceStart: number, -- where the partial starts in the full text
	Trailer: string, -- what to append after accepting a suggestion
	Errors: { string },
	Missing: { ArgSpec },
}

local function isValueSelector(piece: string): string?
	local name = piece:match("^@(%a+)$")
	return if name then ArgumentTypes.ValueSelectors[name:lower()] else nil
end

-- resolve(name) -> command meta { Name, Args, RequiresTarget, ... } or nil
function UsageSpec.Analyze(text: string, resolve: (string) -> any?, env: any): Analysis
	local segStart = lastSegmentStart(text)
	local segment = text:sub(segStart)
	-- A leading chat prefix is allowed in the palette.
	local prefixLen = #(segment:match("^%s*[;/]?") or "")
	local body = segment:sub(prefixLen + 1)
	local offset = segStart + prefixLen - 1 -- body index i is text index offset + i

	local tokens = UsageSpec.Tokenize(body)
	local trailingSpace = body == "" or body:match("%s$") ~= nil
	-- An open quote keeps the token "current" even after a space.
	local lastTok = tokens[#tokens]
	if lastTok and lastTok.Quoted and body:sub(lastTok.End, lastTok.End) ~= '"' then
		trailingSpace = false
	elseif lastTok and lastTok.Quoted and lastTok.End == lastTok.Start then
		trailingSpace = false
	end

	local analysis: Analysis = {
		Part = "command",
		CommandWord = "",
		Partial = "",
		ReplaceStart = #text + 1,
		Trailer = " ",
		Errors = {},
		Missing = {},
	}

	if #tokens == 0 or (#tokens == 1 and not trailingSpace) then
		local tok = tokens[1]
		analysis.CommandWord = if tok then tok.Text else ""
		analysis.Partial = analysis.CommandWord
		analysis.ReplaceStart = if tok then offset + tok.Start else #text + 1
		return analysis
	end

	local commandWord = tokens[1].Text:lower()
	analysis.CommandWord = commandWord
	local meta = resolve(commandWord)
	if not meta then
		analysis.Part = "unknown"
		table.insert(analysis.Errors, ("Unknown command '%s'"):format(commandWord))
		return analysis
	end
	analysis.Command = meta
	local args: { ArgSpec } = meta.Args or {}

	-- Argument tokens; a trailing space opens a new, empty current token.
	local argTokens: { Token } = {}
	for i = 2, #tokens do
		table.insert(argTokens, tokens[i])
	end
	local currentIndex = if trailingSpace then #argTokens + 1 else #argTokens
	if trailingSpace then
		table.insert(argTokens, { Text = "", Start = #body + 1, End = #body, Quoted = false })
	end

	-- Map each token to an argument.
	local ti, ai = 1, 1
	local lastArgIndex = 0
	while ti <= #argTokens do
		local tok = argTokens[ti]
		local arg = args[ai]
		local isCurrent = ti == currentIndex

		if not arg then
			if isCurrent then
				analysis.Part = "extra"
				analysis.Partial = tok.Text
				analysis.ReplaceStart = offset + tok.Start
				if tok.Text ~= "" then
					table.insert(analysis.Errors, ("%s takes no more arguments"):format(meta.Name))
				end
			elseif #analysis.Errors == 0 then
				table.insert(analysis.Errors, ("Too many arguments for %s"):format(meta.Name))
			end
			ti += 1
			continue
		end
		lastArgIndex = ai

		-- Target selectors that take the next token ("@team Red").
		local selectorType: string? = nil
		if ai == 1 and meta.RequiresTarget and arg.Type == "players" then
			local lastPiece = tok.Text:match("([^,]*)$") or tok.Text
			selectorType = isValueSelector(lastPiece)
		end

		if isCurrent then
			analysis.ArgIndex = ai
			local colon = if arg.Modifier then tok.Text:find(":", 1, true) else nil
			if colon and arg.Modifier then
				analysis.Part = "modifier"
				analysis.Arg = arg.Modifier
				analysis.Partial = tok.Text:sub(colon + 1)
				analysis.ReplaceStart = offset + tok.Start + colon
				analysis.Trailer = " "
				local ok, message = ArgumentTypes.Validate(arg, tok.Text:sub(1, colon - 1), env)
				if not ok and message then
					table.insert(analysis.Errors, message)
				end
			else
				analysis.Part = "arg"
				analysis.Arg = arg
				analysis.Partial = tok.Text
				analysis.ReplaceStart = offset + tok.Start + (if tok.Quoted then 1 else 0)
				analysis.Trailer = if arg.Modifier and not arg.Modifier.Optional then ":" else " "
				if arg.Modifier and not arg.Modifier.Optional then
					table.insert(analysis.Missing, arg.Modifier)
				end
			end
		else
			-- Completed token: validate it.
			local value, mod = tok.Text, nil
			if arg.Modifier then
				local colon = tok.Text:find(":", 1, true)
				if colon then
					value, mod = tok.Text:sub(1, colon - 1), tok.Text:sub(colon + 1)
				end
			end
			if not (arg.Rest and arg.Type == "text") then
				local ok, message = ArgumentTypes.Validate(arg, value, env)
				if not ok and message then
					table.insert(analysis.Errors, message)
				end
			end
			if arg.Modifier then
				if mod and mod ~= "" then
					local ok, message = ArgumentTypes.Validate(arg.Modifier, mod, env)
					if not ok and message then
						table.insert(analysis.Errors, message)
					end
				elseif not arg.Modifier.Optional then
					table.insert(analysis.Errors, ("Add :<%s> after the %s"):format(arg.Modifier.Name, arg.Name))
				end
			end
		end

		if selectorType and argTokens[ti + 1] then
			ti += 1
			local valueTok = argTokens[ti]
			local valueArg: ArgSpec = { Name = selectorType .. " name", Type = selectorType }
			if ti == currentIndex then
				analysis.Part = "selectorValue"
				analysis.Arg = valueArg
				analysis.Partial = valueTok.Text
				analysis.ReplaceStart = offset + valueTok.Start + (if valueTok.Quoted then 1 else 0)
				analysis.Trailer = " "
				if valueTok.Text == "" then
					table.insert(analysis.Missing, valueArg)
				end
			else
				local ok, message = ArgumentTypes.Validate(valueArg, valueTok.Text, env)
				if not ok and message then
					table.insert(analysis.Errors, message)
				end
			end
		end

		if arg.Rest then
			-- Everything after belongs to this argument.
			if currentIndex > ti then
				analysis.Part = "arg"
				analysis.Arg = arg
				analysis.ArgIndex = ai
				local cur = argTokens[currentIndex]
				analysis.Partial = cur.Text
				analysis.ReplaceStart = offset + cur.Start
			end
			break
		end
		ti += 1
		ai += 1
	end

	-- Required arguments still to type (after the one being edited).
	local from = math.max(lastArgIndex, analysis.ArgIndex or 0) + 1
	if analysis.Part == "arg" and analysis.Partial == "" and analysis.ArgIndex then
		from = analysis.ArgIndex
	end
	for i = from, #args do
		if not args[i].Optional then
			table.insert(analysis.Missing, args[i])
		end
	end
	return analysis
end

-- ---------------------------------------------------------------------------
-- W06: Walk — highlight spans + parsed values for every "&&" segment
-- ---------------------------------------------------------------------------
export type Span = { Start: number, Stop: number, Kind: string }
export type Value = { Arg: ArgSpec, Text: string, Mod: string? }
export type Segment = { CommandWord: string, Command: any?, Values: { Value }, Errors: { string } }

local KIND_BY_TYPE: { [string]: string } = {
	players = "target",
	player = "target",
	duration = "duration",
	number = "number",
	integer = "number",
	boolean = "keyword",
	choice = "keyword",
	rank = "name",
	team = "name",
	command = "command",
	string = "string",
	text = "text",
}

local SELECTOR_WORDS = { me = true, self = true, all = true, others = true, random = true, nearest = true, last = true }

local function kindFor(arg: ArgSpec, value: string): string
	if arg.Type == "players" then
		local first = value:match("^[^,]*") or value
		if first:sub(1, 1) == "@" or first:sub(1, 1) == "#" or SELECTOR_WORDS[first:lower()] then
			return "selector"
		end
	end
	return KIND_BY_TYPE[arg.Type] or "string"
end

-- Returns segments as { Start, Stop } (text indices) and the "&&" spans.
local function splitSegments(text: string): ({ { number } }, { Span })
	local segments, chains = {}, {}
	local start, inQuote, i = 1, false, 1
	while i <= #text do
		local c = text:sub(i, i)
		if c == '"' then
			inQuote = not inQuote
		elseif not inQuote and text:sub(i, i + 1) == "&&" then
			table.insert(segments, { start, i - 1 })
			table.insert(chains, { Start = i, Stop = i + 1, Kind = "chain" })
			start = i + 2
			i += 1
		end
		i += 1
	end
	table.insert(segments, { start, #text })
	return segments, chains
end

--[[
	Walks the whole input. Returns:
		spans    – { Start, Stop, Kind } for syntax highlighting. Kinds:
		           prefix chain command unknown target selector modifier punct
		           duration number keyword name string text error
		segments – per "&&" segment: CommandWord, Command (meta), Values
		           (one per argument typed: Arg, Text, Mod), Errors
	The token still being typed (at the very end, no trailing space) is
	never marked as an error.
--]]
function UsageSpec.Walk(text: string, resolve: (string) -> any?, env: any): ({ Span }, { Segment })
	local segmentsPos, spans = splitSegments(text)
	local segments: { Segment } = {}
	local typingEnd = if text:match("%s$") then -1 else #text

	local function add(startPos: number, stopPos: number, kind: string)
		if stopPos >= startPos then
			table.insert(spans, { Start = startPos, Stop = stopPos, Kind = kind })
		end
	end

	for _, pos in ipairs(segmentsPos) do
		local segStart, segStop = pos[1], pos[2]
		local raw = text:sub(segStart, segStop)
		local lead = #(raw:match("^%s*") or "")
		local prefixLen = if raw:sub(lead + 1, lead + 1):match("[;/]") then 1 else 0
		if prefixLen == 1 then
			add(segStart + lead, segStart + lead, "prefix")
		end
		local off = segStart + lead + prefixLen - 1
		local tokens = UsageSpec.Tokenize(raw:sub(lead + prefixLen + 1))
		local segment: Segment = { CommandWord = "", Values = {}, Errors = {} }
		table.insert(segments, segment)
		if #tokens == 0 then
			continue
		end

		local function absStart(tok: Token): number
			return off + tok.Start
		end
		local function absStop(tok: Token): number
			return off + tok.End
		end
		local function typing(tok: Token): boolean
			return absStop(tok) == typingEnd
		end

		local cmdTok = tokens[1]
		segment.CommandWord = cmdTok.Text:lower()
		local meta = resolve(segment.CommandWord)
		segment.Command = meta
		if not meta then
			add(absStart(cmdTok), absStop(cmdTok), if typing(cmdTok) then "unknown" else "error")
			if not typing(cmdTok) then
				table.insert(segment.Errors, ("Unknown command '%s'"):format(cmdTok.Text))
			end
			continue
		end
		add(absStart(cmdTok), absStop(cmdTok), "command")

		local args: { ArgSpec } = meta.Args or {}
		local ti, ai = 2, 1
		while ti <= #tokens do
			local tok = tokens[ti]
			local arg = args[ai]
			if not arg then
				add(absStart(tok), absStop(tok), if typing(tok) then "extra" else "error")
				if not typing(tok) and #segment.Errors == 0 then
					table.insert(segment.Errors, ("Too many arguments for %s"):format(meta.Name))
				end
				ti += 1
				continue
			end

			if arg.Rest then
				local last = tokens[#tokens]
				local parts = {}
				for k = ti, #tokens do
					table.insert(parts, tokens[k].Text)
				end
				add(absStart(tok), absStop(last), "text")
				table.insert(segment.Values, { Arg = arg, Text = table.concat(parts, " ") })
				break
			end

			local value, mod = tok.Text, nil
			local colon = if arg.Modifier then tok.Text:find(":", 1, true) else nil
			if colon then
				value, mod = tok.Text:sub(1, colon - 1), tok.Text:sub(colon + 1)
			end
			local valueStop = if colon then absStart(tok) + colon - 2 else absStop(tok)
			local ok, message = true, nil
			if not typing(tok) or colon then
				ok, message = ArgumentTypes.Validate(arg, value, env)
			end
			add(absStart(tok), valueStop, if ok then kindFor(arg, value) else "error")
			if not ok and message then
				table.insert(segment.Errors, message)
			end
			if colon and arg.Modifier then
				add(valueStop + 1, valueStop + 1, "punct")
				local modOk, modMessage = true, nil
				if not typing(tok) and mod ~= "" then
					modOk, modMessage = ArgumentTypes.Validate(arg.Modifier, mod :: string, env)
				end
				add(valueStop + 2, absStop(tok), if modOk then "modifier" else "error")
				if not modOk and modMessage then
					table.insert(segment.Errors, modMessage)
				end
			end
			table.insert(segment.Values, { Arg = arg, Text = value, Mod = if mod ~= "" then mod else nil })

			-- "@team Red": the next token is the selector's value.
			if ai == 1 and meta.RequiresTarget and arg.Type == "players" then
				local selType = isValueSelector(value:match("([^,]*)$") or value)
				local nextTok = tokens[ti + 1]
				if selType and nextTok then
					ti += 1
					local selArg: ArgSpec = { Name = selType .. " name", Type = selType }
					local selOk, selMessage = true, nil
					if not typing(nextTok) then
						selOk, selMessage = ArgumentTypes.Validate(selArg, nextTok.Text, env)
					end
					add(absStart(nextTok), absStop(nextTok), if selOk then "name" else "error")
					if not selOk and selMessage then
						table.insert(segment.Errors, selMessage)
					end
					segment.Values[#segment.Values].Text ..= " " .. nextTok.Text
				end
			end
			ti += 1
			ai += 1
		end
	end

	table.sort(spans, function(a, b)
		return a.Start < b.Start
	end)
	return spans, segments
end

local UNIT_NAMES = {
	{ 31536000, "year" },
	{ 2592000, "month" },
	{ 604800, "week" },
	{ 86400, "day" },
	{ 3600, "hour" },
	{ 60, "minute" },
	{ 1, "second" },
}

function UsageSpec.PrettyDuration(raw: string): string?
	local seconds = ArgumentTypes.ParseDuration(raw)
	if not seconds then
		return nil
	end
	if seconds == math.huge then
		return "permanent"
	end
	for _, unit in ipairs(UNIT_NAMES) do
		if seconds >= unit[1] then
			local n = seconds / unit[1]
			local shown = if n == math.floor(n) then tostring(n) else ("%.1f"):format(n)
			return ("%s %s%s"):format(shown, unit[2], if n == 1 then "" else "s")
		end
	end
	return raw
end

local function prettyValue(arg: ArgSpec, text: string): string
	if arg.Type == "duration" then
		local pretty = UsageSpec.PrettyDuration(text)
		if pretty then
			return ("%s (%s)"):format(text, pretty)
		end
	elseif arg.Type == "text" then
		return '"' .. text .. '"'
	end
	return text
end

-- Live parse: "target = Player1 · duration = 3d (3 days) · reason = "x""
function UsageSpec.Breakdown(segment: Segment): string
	if not segment.Command then
		return ""
	end
	local parts = {}
	for _, v in ipairs(segment.Values) do
		if v.Text ~= "" then
			table.insert(parts, ("%s = %s"):format(v.Arg.Name, prettyValue(v.Arg, v.Text)))
		end
		if v.Mod and v.Arg.Modifier then
			table.insert(parts, ("%s = %s"):format(v.Arg.Modifier.Name, prettyValue(v.Arg.Modifier, v.Mod)))
		end
	end
	return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------------------
-- W06: usage examples (explicit Examples first, then generated ones)
-- ---------------------------------------------------------------------------
local TEXT_SAMPLES: { [string]: string } = {
	reason = '"Breaking the rules"',
	message = '"Hello everyone"',
	text = '"Hello everyone"',
	label = '"Event starts"',
	description = '"Helps new players"',
}
local STRING_SAMPLES: { [string]: string } = {
	itemname = "Sword",
	storename = "PlayerData",
	key = "Player_123",
	modulename = "MyModule",
	newname = "NewName",
	name = "Name",
	node = "+moderation.kick",
	id = "a1b2c3",
	destination = "Spawn",
	value = "10",
	jsonvalue = "{}",
	kind = "userid",
}

local function sample(arg: ArgSpec, env: any): string
	local choices = arg.Choices :: any
	if type(choices) == "function" then
		local ok, list = pcall(choices)
		choices = if ok then list else nil
	end
	if type(choices) == "table" and #choices > 0 then
		return choices[1]
	end
	local t = arg.Type
	if t == "players" then
		return "me"
	elseif t == "player" then
		return if env and env.LocalPlayer then env.LocalPlayer.Name else "Player1"
	elseif t == "duration" then
		return "30m"
	elseif t == "number" or t == "integer" then
		return (arg.Suggestions and arg.Suggestions[1]) or tostring(arg.Min or 10)
	elseif t == "boolean" then
		return "on"
	elseif t == "rank" then
		local ranks = env and env.Ranks
		return if ranks and #ranks > 0 then ranks[#ranks].Name else "Moderator"
	elseif t == "team" then
		local teams = env and env.Teams
		return if teams and #teams > 0 then teams[1].Name else "Red"
	elseif t == "command" then
		return "ban"
	elseif t == "text" then
		return TEXT_SAMPLES[arg.Name:lower()] or '"Some text"'
	end
	return STRING_SAMPLES[arg.Name:lower()] or arg.Name
end

function UsageSpec.Examples(def: any, env: any): { string }
	local out: { string } = {}
	for _, e in ipairs(def.Examples or {}) do
		table.insert(out, e)
	end
	local args: { ArgSpec } = def.Args or {}
	local function build(includeOptional: boolean): string
		local parts = { def.Name }
		for _, arg in ipairs(args) do
			if arg.Optional and not includeOptional then
				continue
			end
			local v = sample(arg, env)
			if arg.Modifier and (includeOptional or not arg.Modifier.Optional) then
				v ..= ":" .. sample(arg.Modifier, env)
			end
			table.insert(parts, v)
		end
		return table.concat(parts, " ")
	end
	for _, line in ipairs({ build(false), build(true) }) do
		if not table.find(out, line) then
			table.insert(out, line)
		end
	end
	return out
end

return UsageSpec
