--!strict
--[[
	QuantityParser.lua

	Purpose:
		Parses the numeric ":modifier" used by economy/inventory commands,
		e.g. "/give item Player:5 Sword" where "5" is a quantity rather than
		a duration. Kept separate from DurationParser so command definitions
		declare intent explicitly (a command asks for a quantity OR a
		duration modifier, never both ambiguously).

	Responsibilities:
		- Parse a plain (optionally decimal, optionally negative) number

	Dependencies:
		Types.lua (ParsedQuantity)

	Public API:
		QuantityParser.Parse(raw: string): ParsedQuantity?

	Example usage:
		QuantityParser.Parse("5")    --> { Amount = 5, Raw = "5" }
		QuantityParser.Parse("2.5")  --> { Amount = 2.5, Raw = "2.5" }
		QuantityParser.Parse("Sword")--> nil
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

type ParsedQuantity = Types.ParsedQuantity

local QuantityParser = {}

function QuantityParser.Parse(raw: string): ParsedQuantity?
	if not raw or #raw == 0 then
		return nil
	end

	if not raw:match("^%-?%d+%.?%d*$") then
		return nil
	end

	local amount = tonumber(raw)
	if not amount then
		return nil
	end

	return {
		Amount = amount,
		Raw = raw,
	}
end

return QuantityParser
