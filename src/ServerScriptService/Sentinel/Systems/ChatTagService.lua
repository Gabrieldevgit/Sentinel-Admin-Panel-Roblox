--!strict
--[[
	ChatTagService.lua (HD Admin gap: ChatTag / ChatTagColor)

	Decides the tag shown before each player's name in chat:
		1. a custom tag set by staff (;chattag), kept for this server, else
		2. the player's top Sentinel rank, in the rank's colour, when the
		   config key RankChatTags is on (default on; ;chattags on|off).

	The result is written to two player attributes the client reads in
	TextChatService.OnIncomingMessage (StarterPlayerScripts/Sentinel/
	ChatTags.lua):
		SentinelChatTag       string ("" = no tag)
		SentinelChatTagColor  Color3

	Public API:
		ChatTagService.SetCustom(player, text?, color?)  nil text = clear
		ChatTagService.GetCustom(player) -> { Text, Color }?
		ChatTagService.Compute(player) -> (text?, Color3?)
		ChatTagService.Refresh(player) / RefreshAll()
		ChatTagService.ParseColor(text) -> Color3?
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventBus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("EventBus"))

local Systems = script.Parent
local ConfigService = require(Systems:WaitForChild("ConfigService"))
local RankService = require(Systems:WaitForChild("RankService"))

local ChatTagService = {}

local TAG_ATTR = "SentinelChatTag"
local COLOR_ATTR = "SentinelChatTagColor"
local MAX_LEN = 20
local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)

ChatTagService.MAX_LENGTH = MAX_LEN

ConfigService.Define("RankChatTags", true, function(v)
	return type(v) == "boolean"
end)

local NAMED_COLORS: { [string]: Color3 } = {
	white = Color3.fromRGB(255, 255, 255),
	red = Color3.fromRGB(255, 70, 70),
	orange = Color3.fromRGB(255, 160, 40),
	yellow = Color3.fromRGB(255, 220, 60),
	gold = Color3.fromRGB(255, 200, 0),
	green = Color3.fromRGB(80, 220, 100),
	lime = Color3.fromRGB(170, 255, 60),
	cyan = Color3.fromRGB(60, 220, 255),
	blue = Color3.fromRGB(80, 140, 255),
	purple = Color3.fromRGB(170, 100, 255),
	pink = Color3.fromRGB(255, 110, 200),
	gray = Color3.fromRGB(170, 170, 170),
	grey = Color3.fromRGB(170, 170, 170),
	black = Color3.fromRGB(40, 40, 40),
}
ChatTagService.COLOR_NAMES = {
	"white", "red", "orange", "yellow", "gold", "green", "lime", "cyan", "blue", "purple", "pink", "gray",
}

-- "red", "#ff8800", "ff8800" or "255,136,0".
function ChatTagService.ParseColor(text: string?): Color3?
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local lower = text:lower()
	if NAMED_COLORS[lower] then
		return NAMED_COLORS[lower]
	end
	local hex = lower:match("^#?(%x%x%x%x%x%x)$")
	if hex then
		return Color3.fromRGB(tonumber(hex:sub(1, 2), 16) :: number, tonumber(hex:sub(3, 4), 16) :: number, tonumber(hex:sub(5, 6), 16) :: number)
	end
	local r, g, b = lower:match("^(%d+),(%d+),(%d+)$")
	if r then
		local rn, gn, bn = tonumber(r) :: number, tonumber(g) :: number, tonumber(b) :: number
		if rn <= 255 and gn <= 255 and bn <= 255 then
			return Color3.fromRGB(rn, gn, bn)
		end
	end
	return nil
end

-- Strip characters that would break the client's RichText and cap length.
function ChatTagService.Clean(text: string): string
	local cleaned = text:gsub("[<>&\"'%[%]\n\r\t]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if utf8.len(cleaned) and (utf8.len(cleaned) :: number) > MAX_LEN then
		cleaned = cleaned:sub(1, utf8.offset(cleaned, MAX_LEN + 1) :: number - 1)
	end
	return cleaned
end

type Custom = { Text: string, Color: Color3 }
local custom: { [number]: Custom } = {}

function ChatTagService.GetCustom(player: Player): Custom?
	return custom[player.UserId]
end

function ChatTagService.Compute(player: Player): (string?, Color3?)
	local own = custom[player.UserId]
	if own then
		return own.Text, own.Color
	end
	if ConfigService.Get("RankChatTags") == false then
		return nil, nil
	end
	local rankName = RankService.GetTopRank(player)
	if not rankName then
		return nil, nil
	end
	local rank = RankService.GetRank(rankName)
	local rgb = rank and (rank :: any).Color
	local color = if type(rgb) == "table" and #rgb == 3 then Color3.fromRGB(rgb[1], rgb[2], rgb[3]) else DEFAULT_COLOR
	return rankName, color
end

function ChatTagService.Refresh(player: Player)
	if player.Parent ~= Players then
		return
	end
	local text, color = ChatTagService.Compute(player)
	if player:GetAttribute(TAG_ATTR) ~= (text or "") then
		player:SetAttribute(TAG_ATTR, text or "")
	end
	local c = color or DEFAULT_COLOR
	if player:GetAttribute(COLOR_ATTR) ~= c then
		player:SetAttribute(COLOR_ATTR, c)
	end
end

function ChatTagService.RefreshAll()
	for _, player in ipairs(Players:GetPlayers()) do
		ChatTagService.Refresh(player)
	end
end

function ChatTagService.SetCustom(player: Player, text: string?, color: Color3?)
	if text == nil or text == "" then
		custom[player.UserId] = nil
	else
		custom[player.UserId] = { Text = text, Color = color or DEFAULT_COLOR }
	end
	ChatTagService.Refresh(player)
end

EventBus.Subscribe("Permission.Changed", function(player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		task.defer(ChatTagService.Refresh, player)
	end
end)

ConfigService.Changed:Connect(function(key)
	if key == "RankChatTags" then
		ChatTagService.RefreshAll()
	end
end)

Players.PlayerAdded:Connect(function(player)
	task.defer(ChatTagService.Refresh, player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.defer(ChatTagService.Refresh, player)
end

Players.PlayerRemoving:Connect(function(player)
	custom[player.UserId] = nil
end)

-- Rank edits (colour / rename) don't fire Permission.Changed: a slow sweep
-- keeps tags in line. Only attribute changes are replicated.
if RunService:IsRunning() then
	task.spawn(function()
		while true do
			task.wait(10)
			ChatTagService.RefreshAll()
		end
	end)
end

return ChatTagService
