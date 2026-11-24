--!strict
--[[
	ChatTags.lua (client)

	Shows the tag ServerScriptService.Sentinel.Systems.ChatTagService puts on
	each player (attributes SentinelChatTag / SentinelChatTagColor) before
	their name in TextChatService chat:  [Admin] Player1: hello

	TextChatService.OnIncomingMessage holds one callback and Roblox does not
	let a script read it, so setting it replaces any earlier one. Another
	script that sets it later wins; ;chattags off leaves the callback in
	place but it then returns nothing.
--]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatTags = {}

local function hex(c: Color3): string
	return ("#%02x%02x%02x"):format(
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

function ChatTags.Format(tag: string, color: Color3?): string
	return ('<font color="%s">[%s]</font> '):format(hex(color or Color3.new(1, 1, 1)), tag)
end

function ChatTags.Init()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties?
		local source = message.TextSource
		if not source then
			return nil
		end
		local player = Players:GetPlayerByUserId(source.UserId)
		local tag = player and player:GetAttribute("SentinelChatTag")
		if type(tag) ~= "string" or tag == "" then
			return nil
		end
		local color = (player :: Player):GetAttribute("SentinelChatTagColor")
		local props = Instance.new("TextChatMessageProperties")
		props.PrefixText = ChatTags.Format(tag, if typeof(color) == "Color3" then color else nil) .. message.PrefixText
		return props
	end
end

return ChatTags
