--!strict
--[[
	CommandParser.lua

	Purpose:
		Ties Tokenizer output into the selector grammar described in the
		design doc: target keywords, @group selectors, #tag selectors,
		property selectors (`@level >25`), comma/space-separated multi-
		targets, and trailing `where Property<op><value>` filters. Produces
		a chain of Types.ParsedCommand (linked via NextCommand for "&&").

	Responsibilities:
		- Parse one command segment into a ParsedCommand
		- Parse the selector portion of a target token into TargetSelector[]
		- Parse trailing "where ..." clauses into CommandFilter[]
		- Chain multiple segments together for "&&"

	Dependencies:
		Tokenizer.lua
		Types.lua (Shared)

	Public API:
		CommandParser.ParseLine(input: string): ParsedCommand?
		CommandParser.ParseFilters(tokens: {string}): ({CommandFilter}, {string})
			-- returns filters found + remaining tokens with the "where ..."
			   clause stripped out

	Example usage:
		CommandParser.ParseLine("/ban Player1:30m Exploiting && kick Player2")
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Tokenizer = require(script.Parent:WaitForChild("Tokenizer"))

type ParsedCommand = Types.ParsedCommand
type TargetSelector = Types.TargetSelector
type CommandFilter = Types.CommandFilter

local CommandParser = {}

local SIMPLE_KEYWORDS: { [string]: Types.TargetSelectorKind } = {
	me = "Self",
	self = "Self",
	all = "All",
	others = "Others",
	random = "Random",
	nearest = "Nearest",
	last = "Last",
}

local AT_SELECTOR_KIND: { [string]: Types.TargetSelectorKind } = {
	team = "Team",
	role = "Role",
	group = "Group",
	rank = "Rank",
	attribute = "Attribute",
	-- @vip / @staff / @friends are sugar for @role vip / @role staff / friends-of-executor
	vip = "Role",
	staff = "Role",
}

--[[
	Parses ONE target token (which may itself be a comma list) into one or
	more TargetSelector entries. Property selectors like "@level" arrive as
	two tokens ("@level" then ">25") from the tokenizer, so the caller
	(parseSelectors) handles pulling the second token in when needed; this
	function handles a single self-contained token.
--]]
local function parseSingleSelectorToken(token: string): TargetSelector?
	if token:sub(1, 1) == "@" then
		local rest = token:sub(2)
		local name, value = rest:match("^(%a+)%s*(.*)$")
		name = name or rest
		local kind = AT_SELECTOR_KIND[name:lower()]
		if not kind then
			return nil
		end
		if name:lower() == "vip" then
			return { Kind = "Role", Raw = token, Value = "VIP" }
		elseif name:lower() == "staff" then
			return { Kind = "Role", Raw = token, Value = "Staff" }
		end
		return { Kind = kind, Raw = token, Value = if value ~= "" then value else nil }
	elseif token:sub(1, 1) == "#" then
		return { Kind = "Tag", Raw = token, Value = token:sub(2) }
	elseif SIMPLE_KEYWORDS[token:lower()] then
		return { Kind = SIMPLE_KEYWORDS[token:lower()], Raw = token }
	else
		return { Kind = "Named", Raw = token, Value = token }
	end
end

--[[
	Consumes the target expression, including the lookahead needed for
	property selectors ("@level" ">25"). Comma lists ("Player1,Player2")
	are split here; space-separated multi-targets are handled by the
	caller re-invoking this per token when a command declares it accepts
	multiple bare targets.
--]]
local function parseSelectors(targetToken: string, lookaheadToken: string?): ({ TargetSelector }, boolean)
	local selectors: { TargetSelector } = {}
	local consumedLookahead = false

	for piece in targetToken:gmatch("[^,]+") do
		local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")

		if trimmed:sub(1, 1) == "@" and lookaheadToken and lookaheadToken:match("^[<>=]") then
			local name = trimmed:sub(2):match("^(%a+)$")
			if name then
				local operator, comparand = lookaheadToken:match("^([<>=]+)(.+)$")
				table.insert(selectors, {
					Kind = "Property",
					Raw = trimmed,
					Value = name,
					Operator = operator,
					Comparand = comparand,
				})
				consumedLookahead = true
				continue
			end
		end

		local selector = parseSingleSelectorToken(trimmed)
		if selector then
			table.insert(selectors, selector)
		end
	end

	return selectors, consumedLookahead
end

function CommandParser.ParseFilters(tokens: { string }): ({ CommandFilter }, { string })
	local filters: { CommandFilter } = {}
	local remaining: { string } = {}

	local i = 1
	while i <= #tokens do
		if tokens[i]:lower() == "where" and tokens[i + 1] then
			local expr = tokens[i + 1]
			local property, operator, comparand = expr:match("^(%a+)([<>=]+)(.+)$")
			if property then
				table.insert(filters, { Property = property, Operator = operator, Comparand = comparand })
			end
			i += 2
		else
			table.insert(remaining, tokens[i])
			i += 1
		end
	end

	return filters, remaining
end

local function parseSegment(segment: string): ParsedCommand?
	local rawTokens = Tokenizer.Tokenize(segment)
	if #rawTokens == 0 then
		return nil
	end

	local commandName = rawTokens[1]:gsub("^/", ""):lower()

	local filters, tokensWithoutWhere = CommandParser.ParseFilters(rawTokens)

	local targetRaw = tokensWithoutWhere[2]
	local selectors: { TargetSelector } = {}
	local modifier: string? = nil
	local argsStartIndex = 2

	if targetRaw then
		local targetOnly, mod = Tokenizer.SplitTargetModifier(targetRaw)
		modifier = mod
		local lookahead = tokensWithoutWhere[3]
		local resolvedSelectors, consumedLookahead = parseSelectors(targetOnly, lookahead)
		selectors = resolvedSelectors
		argsStartIndex = if consumedLookahead then 4 else 3
	end

	local arguments: { string } = {}
	for i = argsStartIndex, #tokensWithoutWhere do
		table.insert(arguments, tokensWithoutWhere[i])
	end

	local plainArguments: { string } = {}
	for i = 2, #tokensWithoutWhere do
		table.insert(plainArguments, tokensWithoutWhere[i])
	end

	return {
		CommandName = commandName,
		RawInput = segment,
		TargetSelectors = selectors,
		Modifier = modifier,
		Arguments = arguments,
		PlainArguments = plainArguments,
		NextCommand = nil,
	} :: ParsedCommand
end

function CommandParser.ParseLine(input: string): ParsedCommand?
	local segments = Tokenizer.SplitChain(input)
	if #segments == 0 then
		return nil
	end

	local head: ParsedCommand? = nil
	local tail: ParsedCommand? = nil

	for _, segment in ipairs(segments) do
		local parsed = parseSegment(segment)
		if parsed then
			if not head then
				head = parsed
				tail = parsed
			elseif tail then
				tail.NextCommand = parsed
				tail = parsed
			end
		end
	end

	return head
end

return CommandParser
