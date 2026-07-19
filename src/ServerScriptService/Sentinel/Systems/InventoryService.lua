--!strict
--[[
	InventoryService.lua

	Purpose:
		Manages giving, removing, and persisting Tool instances. Tool
		templates are looked up by name from a `ServerStorage.SentinelTools`
		folder that the game owner populates — this keeps Sentinel decoupled
		from any specific game's item definitions.

	Responsibilities:
		- Clone a named tool template into a player's Backpack
		- Remove a named tool from a player's Backpack/Character
		- Duplicate an existing tool a player is holding
		- Save/restore a simple by-name inventory snapshot via DataStore
		  (note: this persists WHICH tools a player has, not any custom
		  per-tool state — games with stateful tools should extend this)

	Dependencies:
		Types.lua, EventBus.lua (Shared)

	Setup required from the game owner:
		Create a Folder named "SentinelTools" in ServerStorage and place
		Tool instances inside it, named exactly as you want them referenced
		in commands (e.g. "Sword", "Bow").

	Public API:
		InventoryService.GiveTool(player, toolName): boolean
		InventoryService.RemoveTool(player, toolName): boolean
		InventoryService.DuplicateTool(player, toolName): boolean
		InventoryService.SaveInventory(player): ()
		InventoryService.RestoreInventory(player): ()
--]]

local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local InventoryStore = DataStoreService:GetDataStore("Sentinel_Inventory_v1")

local InventoryService = {}

local function getToolTemplatesFolder(): Folder?
	local folder = ServerStorage:FindFirstChild("SentinelTools")
	if not folder then
		warn("[Sentinel.InventoryService] no 'SentinelTools' folder found in ServerStorage.")
		return nil
	end
	return folder :: Folder
end

local function findToolInPlayer(player: Player, toolName: string): Tool?
	local backpack = player:FindFirstChild("Backpack")
	local fromBackpack = backpack and backpack:FindFirstChild(toolName)
	if fromBackpack and fromBackpack:IsA("Tool") then
		return fromBackpack
	end
	local character = player.Character
	local fromCharacter = character and character:FindFirstChild(toolName)
	if fromCharacter and fromCharacter:IsA("Tool") then
		return fromCharacter
	end
	return nil
end

function InventoryService.GiveTool(player: Player, toolName: string): boolean
	local templates = getToolTemplatesFolder()
	if not templates then
		return false
	end
	local template = templates:FindFirstChild(toolName)
	if not template or not template:IsA("Tool") then
		return false
	end

	local clone = template:Clone()
	clone.Parent = player:FindFirstChild("Backpack") or player
	EventBus.Publish("Inventory.ToolGiven", player, toolName)
	return true
end

function InventoryService.RemoveTool(player: Player, toolName: string): boolean
	local tool = findToolInPlayer(player, toolName)
	if not tool then
		return false
	end
	tool:Destroy()
	EventBus.Publish("Inventory.ToolRemoved", player, toolName)
	return true
end

function InventoryService.DuplicateTool(player: Player, toolName: string): boolean
	local tool = findToolInPlayer(player, toolName)
	if not tool then
		return false
	end
	local clone = tool:Clone()
	clone.Parent = player:FindFirstChild("Backpack") or player
	EventBus.Publish("Inventory.ToolDuplicated", player, toolName)
	return true
end

function InventoryService.SaveInventory(player: Player)
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		return
	end
	local names = {}
	for _, tool in ipairs(backpack:GetChildren()) do
		if tool:IsA("Tool") then
			table.insert(names, tool.Name)
		end
	end
	local ok, err = pcall(function()
		InventoryStore:SetAsync(tostring(player.UserId), names)
	end)
	if not ok then
		warn(("[Sentinel.InventoryService] failed to save inventory: %s"):format(tostring(err)))
	end
end

function InventoryService.RestoreInventory(player: Player)
	local ok, names = pcall(function()
		return InventoryStore:GetAsync(tostring(player.UserId))
	end)
	if not ok or not names then
		return
	end
	for _, toolName in ipairs(names) do
		InventoryService.GiveTool(player, toolName)
	end
end

return InventoryService
