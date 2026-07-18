--!strict
--[[
	Tokenizer.lua

	Purpose:
		First stage of the parsing pipeline. Takes the raw string a player
		typed (after the leading "/") and splits it into a flat token list,
		while also splitting on "&&" for command chaining. Does NOT resolve
		aliases, selectors, durations, or quantities — that is
		CommandParser's job, one layer up.

	Responsibilities:
		- Split chained commands on "&&"
		- Tokenize each segment on whitespace, respecting quoted strings
		  ("Exploiting with a fly hack" stays one token)
		- Split "target:modifier" on the first unescaped ":"

	Dependencies:
		None.

	Public API:
		Tokenizer.SplitChain(input: string): {string}
		Tokenizer.Tokenize(segment: string): {string}
		Tokenizer.SplitTargetModifier(token: string): (string, string?)

	Example usage:
		Tokenizer.SplitChain("/freeze all && announce all \"Event starting\"")
			--> {"/freeze all", "announce all \"Event starting\""}

		Tokenizer.Tokenize("ban Player1:30m Exploiting hard")
			--> {"ban", "Player1:30m", "Exploiting", "hard"}
--]]

local Tokenizer = {}

function Tokenizer.SplitChain(input: string): { string }
	local segments = {}
	-- Split on "&&" that isn't inside quotes. Simple approach: since reasons
	-- rarely contain literal "&&", split naively first, then reassemble any
	-- piece whose quote count is odd (meaning we split inside a string).
	for piece in (input .. "&&"):gmatch("(.-)&&") do
		table.insert(segments, piece)
	end

	local merged = {}
	local pending: string? = nil
	for _, seg in ipairs(segments) do
		local candidate = if pending then pending .. "&&" .. seg else seg
		local quoteCount = select(2, candidate:gsub('"', ""))
		if quoteCount % 2 == 1 then
			pending = candidate
		else
			table.insert(merged, (candidate:gsub("^%s+", ""):gsub("%s+$", "")))
			pending = nil
		end
	end
	if pending then
		table.insert(merged, (pending:gsub("^%s+", ""):gsub("%s+$", "")))
	end

	return merged
end

function Tokenizer.Tokenize(segment: string): { string }
	local tokens: { string } = {}
	local i = 1
	local len = #segment

	while i <= len do
		local c = segment:sub(i, i)

		if c:match("%s") then
			i += 1
		elseif c == '"' then
			local closing = segment:find('"', i + 1)
			if closing then
				table.insert(tokens, segment:sub(i + 1, closing - 1))
				i = closing + 1
			else
				-- unterminated quote: take the rest as one token
				table.insert(tokens, segment:sub(i + 1))
				i = len + 1
			end
		else
			local nextSpace = segment:find("%s", i)
			local wordEnd = (nextSpace and nextSpace - 1) or len
			table.insert(tokens, segment:sub(i, wordEnd))
			i = wordEnd + 1
		end
	end

	return tokens
end

function Tokenizer.SplitTargetModifier(token: string): (string, string?)
	local colonIndex = token:find(":")
	if not colonIndex then
		return token, nil
	end
	local target = token:sub(1, colonIndex - 1)
	local modifier = token:sub(colonIndex + 1)
	if #modifier == 0 then
		return target, nil
	end
	return target, modifier
end

return Tokenizer
