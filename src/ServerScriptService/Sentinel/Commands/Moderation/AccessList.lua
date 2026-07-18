--!strict
--[[
	AccessList.lua

	Purpose:
		Registers "/blacklist", "/unblacklist", "/whitelist",
		"/unwhitelist", and enforces both on PlayerAdded — blacklisted
		players are always kicked; if whitelist mode is turned on (via
		/whitelistmode on|off) only whitelisted players may join.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local BlacklistStore = DataStoreService:GetDataStore("Sentinel_Blacklist_v1")
local WhitelistStore = DataStoreService:GetDataStore("Sentinel_Whitelist_v1")
local ConfigStore = DataStoreService:GetDataStore("Sentinel_Config_v1")

local AccessList = {}

local whitelistModeEnabled = false
do
	local ok, stored = pcall(function()
		return ConfigStore:GetAsync("WhitelistModeEnabled")
	end)
	whitelistModeEnabled = if ok and stored then stored else false
end

local function isBlacklisted(userId: number): boolean
	local ok, value = pcall(function()
		return BlacklistStore:GetAsync(tostring(userId))
	end)
	return ok and value == true
end

local function isWhitelisted(userId: number): boolean
	local ok, value = pcall(function()
		return WhitelistStore:GetAsync(tostring(userId))
	end)
	return ok and value == true
end

function AccessList.SetBlacklisted(userId: number, value: boolean)
	pcall(function()
		if value then
			BlacklistStore:SetAsync(tostring(userId), true)
		else
			BlacklistStore:RemoveAsync(tostring(userId))
		end
	end)
end

function AccessList.SetWhitelisted(userId: number, value: boolean)
	pcall(function()
		if value then
			WhitelistStore:SetAsync(tostring(userId), true)
		else
			WhitelistStore:RemoveAsync(tostring(userId))
		end
	end)
end

Players.PlayerAdded:Connect(function(player: Player)
	if isBlacklisted(player.UserId) then
		player:Kick("You are blacklisted from this game.")
		return
	end
	if whitelistModeEnabled and not isWhitelisted(player.UserId) then
		player:Kick("This game is currently whitelist-only.")
	end
end)

CommandRegistry.Register({
	Name = "blacklist",
	Aliases = {},
	Description = "Blacklists a player from joining the game.",
	Usage = "/blacklist target",
	Permission = "moderation.blacklist",
	Category = "Moderation",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			AccessList.SetBlacklisted(target.UserId, true)
			target:Kick("You have been blacklisted from this game.")
		end
		return { Success = true, Message = ("Blacklisted %d player(s)."):format(#ctx.Targets), Undoable = true, UndoData = ctx.Targets }
	end,
})

CommandRegistry.Register({
	Name = "unblacklist",
	Aliases = {},
	Description = "Removes a player from the blacklist.",
	Usage = "/unblacklist target",
	Permission = "moderation.blacklist",
	Category = "Moderation",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			AccessList.SetBlacklisted(target.UserId, false)
		end
		return { Success = true, Message = ("Removed %d player(s) from the blacklist."):format(#ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "whitelist",
	Aliases = {},
	Description = "Adds a player to the whitelist.",
	Usage = "/whitelist target",
	Permission = "moderation.whitelist",
	Category = "Moderation",
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			AccessList.SetWhitelisted(target.UserId, true)
		end
		return { Success = true, Message = ("Whitelisted %d player(s)."):format(#ctx.Targets), Undoable = true, UndoData = ctx.Targets }
	end,
})

CommandRegistry.Register({
	Name = "unwhitelist",
	Aliases = {},
	Description = "Removes a player from the whitelist.",
	Usage = "/unwhitelist target",
	Permission = "moderation.whitelist",
	Category = "Moderation",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		for _, target in ipairs(ctx.Targets) do
			AccessList.SetWhitelisted(target.UserId, false)
		end
		return { Success = true, Message = ("Removed %d player(s) from the whitelist."):format(#ctx.Targets) }
	end,
})

CommandRegistry.Register({
	Name = "whitelistmode",
	Aliases = {},
	Description = "Toggles whitelist-only join mode for the whole game.",
	Usage = "/whitelistmode on|off",
	Permission = "moderation.whitelist",
	Category = "Moderation",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local setting = ctx.Arguments[1]
		if setting ~= "on" and setting ~= "off" then
			return { Success = false, Message = "Usage: /whitelistmode on|off" }
		end
		whitelistModeEnabled = setting == "on"
		pcall(function()
			ConfigStore:SetAsync("WhitelistModeEnabled", whitelistModeEnabled)
		end)
		return { Success = true, Message = ("Whitelist mode is now %s."):format(setting) }
	end,
})

return AccessList
