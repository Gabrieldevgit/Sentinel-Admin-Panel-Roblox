--!strict
--[[
	DurationParser.lua

	Purpose:
		Parses human-friendly duration strings ("30m", "2d", "1w", "1mo",
		"forever") into seconds, for use as the ":modifier" on commands like
		/ban, /mute, /jail.

	Responsibilities:
		- Parse a single unit+number token into seconds
		- Recognize "forever" / "perm" / "permanent" as permanent
		- Reject malformed input clearly (returns nil, not a throw, so
		  callers can produce a friendly command-usage error)

	Dependencies:
		Types.lua (ParsedDuration)

	Public API:
		DurationParser.Parse(raw: string): ParsedDuration?

	Example usage:
		DurationParser.Parse("30m")  --> { Seconds = 1800, IsPermanent = false, Raw = "30m" }
		DurationParser.Parse("2d")   --> { Seconds = 172800, ... }
		DurationParser.Parse("perm") --> { Seconds = math.huge, IsPermanent = true, ... }
		DurationParser.Parse("xyz")  --> nil
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

type ParsedDuration = Types.ParsedDuration

local DurationParser = {}

-- Ordered longest-suffix-first so "mo" is checked before "m" would ever
-- ambiguously match (it can't here since "mo" is 2 chars, but keeping this
-- ordering convention protects future unit additions).
local UNIT_SECONDS: { [string]: number } = {
	s = 1,
	m = 60,
	h = 3600,
	d = 86400,
	w = 604800,
	mo = 2592000, -- 30-day month approximation; documented, not "exact"
	y = 31536000, -- 365-day year approximation
}

local PERMANENT_KEYWORDS: { [string]: boolean } = {
	forever = true,
	perm = true,
	permanent = true,
}

function DurationParser.Parse(raw: string): ParsedDuration?
	if not raw or #raw == 0 then
		return nil
	end

	local lowered = raw:lower()

	if PERMANENT_KEYWORDS[lowered] then
		return {
			Seconds = math.huge,
			IsPermanent = true,
			Raw = raw,
		}
	end

	-- Match a number followed by a unit: "30m", "2d", "1mo", "1.5h"
	local number, unit = lowered:match("^(%d+%.?%d*)(%a+)$")
	if not number or not unit then
		return nil
	end

	local unitSeconds = UNIT_SECONDS[unit]
	if not unitSeconds then
		return nil
	end

	local amount = tonumber(number)
	if not amount or amount <= 0 then
		return nil
	end

	return {
		Seconds = amount * unitSeconds,
		IsPermanent = false,
		Raw = raw,
	}
end

return DurationParser
