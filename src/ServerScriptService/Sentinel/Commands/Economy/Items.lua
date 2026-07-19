--!strict
--[[
	Items.lua

	Purpose:
		Registers inventory commands wrapping InventoryService.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
		InventoryService.lua (Systems)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local InventoryService = require(Sentinel:WaitForChild("Systems"):WaitForChild("InventoryService"))

CommandRegistry.Register({
	Name = "giveitem",
	Aliases = { "give" },
	Description = "Gives a named tool to a player.",
	Usage = "/giveitem target itemName",
	Permission = "inventory.give",
	Category = "Inventory",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local itemName = ctx.Arguments[1]
		if not itemName then
			return { Success = false, Message = "Usage: /giveitem target itemName" }
		end
		local given = 0
		for _, target in ipairs(ctx.Targets) do
			if InventoryService.GiveTool(target, itemName) then
				given += 1
			end
		end
		if given == 0 then
			return { Success = false, Message = ("No tool named '%s' found in ServerStorage.SentinelTools."):format(itemName) }
		end
		return { Success = true, Message = ("Gave '%s' to %d player(s)."):format(itemName, given) }
	end,
})

CommandRegistry.Register({
	Name = "removeitem",
	Aliases = {},
	Description = "Removes a named tool from a player.",
	Usage = "/removeitem target itemName",
	Permission = "inventory.remove",
	Category = "Inventory",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local itemName = ctx.Arguments[1]
		if not itemName then
			return { Success = false, Message = "Usage: /removeitem target itemName" }
		end
		local removed = 0
		for _, target in ipairs(ctx.Targets) do
			if InventoryService.RemoveTool(target, itemName) then
				removed += 1
			end
		end
		return { Success = true, Message = ("Removed '%s' from %d player(s)."):format(itemName, removed) }
	end,
})

CommandRegistry.Register({
	Name = "duplicatetool",
	Aliases = { "dupe" },
	Description = "Duplicates a tool a player currently has.",
	Usage = "/duplicatetool target itemName",
	Permission = "inventory.give",
	Category = "Inventory",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local itemName = ctx.Arguments[1]
		if not itemName then
			return { Success = false, Message = "Usage: /duplicatetool target itemName" }
		end
		local duplicated = 0
		for _, target in ipairs(ctx.Targets) do
			if InventoryService.DuplicateTool(target, itemName) then
				duplicated += 1
			end
		end
		return { Success = true, Message = ("Duplicated '%s' for %d player(s)."):format(itemName, duplicated) }
	end,
})

CommandRegistry.Register({
	Name = "saveinventory",
	Aliases = {},
	Description = "Saves a player's current tool inventory.",
	Usage = "/saveinventory target",
	Permission = "inventory.manage",
	Category = "Inventory",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			InventoryService.SaveInventory(target)
		end
		return { Success = true, Message = ("Saved inventory for %d player(s)."):format(#ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "restoreinventory",
	Aliases = {},
	Description = "Restores a player's previously saved tool inventory.",
	Usage = "/restoreinventory target",
	Permission = "inventory.manage",
	Category = "Inventory",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			InventoryService.RestoreInventory(target)
		end
		return { Success = true, Message = ("Restored inventory for %d player(s)."):format(#ctx.Targets) }
	end,
})

return true
