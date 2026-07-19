--!strict
--[[
	Currency.lua

	Purpose:
		Registers economy commands wrapping EconomyService: currency
		(Coins), premium currency (Gems), XP, level, and badges.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		EconomyService.lua (Systems)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local QuantityParser = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("QuantityParser"))
local EconomyService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EconomyService"))

local function parseAmount(ctx: Types.CommandContext): number?
	local quantity = QuantityParser.Parse(ctx.Modifier or ctx.Arguments[1] or "")
	return if quantity then quantity.Amount else nil
end

CommandRegistry.Register({
	Name = "givecurrency",
	Aliases = { "givecoins" },
	Description = "Gives coins to a player.",
	Usage = "/givecurrency target:amount",
	Permission = "economy.currency.give",
	Category = "Economy",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.AddCoins(target, amount)
		end
		return { Success = true, Message = ("Gave %d coins to %d player(s)."):format(amount, #ctx.Targets), Undoable = true }
	end,
})

CommandRegistry.Register({
	Name = "removecurrency",
	Aliases = { "removecoins" },
	Description = "Removes coins from a player.",
	Usage = "/removecurrency target:amount",
	Permission = "economy.currency.give",
	Category = "Economy",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.AddCoins(target, -amount)
		end
		return { Success = true, Message = ("Removed %d coins from %d player(s)."):format(amount, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "setbalance",
	Aliases = {},
	Description = "Sets a player's coin balance exactly.",
	Usage = "/setbalance target:amount",
	Permission = "economy.currency.give",
	Category = "Economy",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.SetCoins(target, amount)
		end
		return { Success = true, Message = ("Set balance to %d for %d player(s)."):format(amount, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "givepremium",
	Aliases = { "givegems" },
	Description = "Gives premium currency (Gems) to a player.",
	Usage = "/givepremium target:amount",
	Permission = "economy.currency.give",
	Category = "Economy",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.AddGems(target, amount)
		end
		return { Success = true, Message = ("Gave %d gems to %d player(s)."):format(amount, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "addxp",
	Aliases = {},
	Description = "Adds XP to a player.",
	Usage = "/addxp target:amount",
	Permission = "economy.xp.give",
	Category = "Economy",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.AddXP(target, amount)
		end
		return { Success = true, Message = ("Gave %d XP to %d player(s)."):format(amount, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "removexp",
	Aliases = {},
	Description = "Removes XP from a player.",
	Usage = "/removexp target:amount",
	Permission = "economy.xp.give",
	Category = "Economy",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local amount = parseAmount(ctx)
		if not amount then
			return { Success = false, Message = "Invalid amount." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.AddXP(target, -amount)
		end
		return { Success = true, Message = ("Removed %d XP from %d player(s)."):format(amount, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "setlevel",
	Aliases = {},
	Description = "Sets a player's level exactly.",
	Usage = "/setlevel target:level",
	Permission = "economy.xp.give",
	Category = "Economy",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local level = parseAmount(ctx)
		if not level then
			return { Success = false, Message = "Invalid level." }
		end
		for _, target in ipairs(ctx.Targets) do
			EconomyService.SetLevel(target, level)
		end
		return { Success = true, Message = ("Set level to %d for %d player(s)."):format(level, #ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "grantbadge",
	Aliases = {},
	Description = "Grants a badge to a player by badge ID.",
	Usage = "/grantbadge target badgeId",
	Permission = "economy.badge.grant",
	Category = "Economy",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local badgeId = tonumber(ctx.Arguments[1])
		if not badgeId then
			return { Success = false, Message = "Usage: /grantbadge target badgeId" }
		end
		local granted = 0
		for _, target in ipairs(ctx.Targets) do
			if EconomyService.GrantBadge(target, badgeId) then
				granted += 1
			end
		end
		return { Success = true, Message = ("Granted badge to %d player(s)."):format(granted) }
	end,
})

return true
