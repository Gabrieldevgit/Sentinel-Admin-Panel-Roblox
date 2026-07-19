--!strict
--[[
	ChatModerationService.lua

	Purpose:
		Owns the mute ledger and is the ONLY thing that decides whether a
		chat message is delivered. Uses TextChatService's
		ShouldDeliverCallback (the modern, non-legacy way to gate chat) so
		muted players' messages never leave the server, rather than a
		client-side visual trick.

	Responsibilities:
		- Persist per-player mutes (in-memory; mutes are session/duration
		  based rather than permanent-by-default, so DataStore persistence
		  is opt-in via the Duration modifier on /mute — a "perm" mute
		  still persists via a lightweight DataStore entry)
		- Register the ShouldDeliverCallback on every TextChannel, including
		  ones created after this service starts (party/whisper channels)
		- Auto-expire timed mutes

	Dependencies:
		Types.lua, EventBus.lua (Shared)

	Public API:
		ChatModerationService.Mute(target: Player, seconds: number, permanent: boolean?): ()
		ChatModerationService.Unmute(target: Player): ()
		ChatModerationService.IsMuted(userId: number): boolean

	Example usage:
		ChatModerationService.Mute(target, 900) -- 15 minute mute
--]]

local TextChatService = game:GetService("TextChatService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local MuteStore = DataStoreService:GetDataStore("Sentinel_Mutes_v1")

local ChatModerationService = {}

-- expiry: math.huge for permanent, otherwise a unix timestamp
local activeMutes: { [number]: number } = {}

function ChatModerationService.IsMuted(userId: number): boolean
	local expiry = activeMutes[userId]
	if not expiry then
		return false
	end
	if expiry ~= math.huge and expiry < os.time() then
		activeMutes[userId] = nil
		return false
	end
	return true
end

function ChatModerationService.Mute(target: Player, seconds: number, permanent: boolean?)
	local expiry = if permanent then math.huge else os.time() + seconds
	activeMutes[target.UserId] = expiry

	if permanent then
		local ok, err = pcall(function()
			MuteStore:SetAsync(tostring(target.UserId), expiry)
		end)
		if not ok then
			warn(("[Sentinel.ChatModerationService] failed to persist mute: %s"):format(tostring(err)))
		end
	end

	EventBus.Publish("Player.Muted", target, expiry)
end

function ChatModerationService.Unmute(target: Player)
	activeMutes[target.UserId] = nil
	local ok, err = pcall(function()
		MuteStore:RemoveAsync(tostring(target.UserId))
	end)
	if not ok then
		warn(("[Sentinel.ChatModerationService] failed to clear persisted mute: %s"):format(tostring(err)))
	end
	EventBus.Publish("Player.Unmuted", target)
end

local function attachDeliveryGate(channel: TextChannel)
	channel.ShouldDeliverCallback = function(message: TextChatMessage, _targetChannel: TextChannel): boolean
		local speaker = message.TextSource
		if not speaker then
			return true -- system messages etc.
		end
		return not ChatModerationService.IsMuted(speaker.UserId)
	end
end

-- IMPORTANT: TextChatService.TextChannels (and its default channels) exist
-- in the DataModel on modern Roblox regardless of which chat system is
-- actually active — their presence is NOT a valid way to detect this. The
-- authoritative flag is TextChatService.ChatVersion. Only attach the
-- delivery gate when that says TextChatService is actually in use;
-- otherwise mute enforcement genuinely isn't available (Roblox doesn't
-- expose a supported server-side delivery gate for legacy chat), so warn
-- once and move on rather than attaching to channels nothing routes
-- through.
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
	local textChannelsFolder = TextChatService:WaitForChild("TextChannels", 10)
	if textChannelsFolder then
		for _, channel in ipairs(textChannelsFolder:GetChildren()) do
			if channel:IsA("TextChannel") then
				attachDeliveryGate(channel)
			end
		end
		textChannelsFolder.ChildAdded:Connect(function(child: Instance)
			if child:IsA("TextChannel") then
				attachDeliveryGate(child)
			end
		end)
	end
else
	warn(
		"[Sentinel.ChatModerationService] This place uses legacy chat, not TextChatService — "
			.. "/mute will track mute state but cannot block chat messages server-side. "
			.. "Enable TextChatService in Game Settings > Chat to get full mute enforcement."
	)
end

Players.PlayerAdded:Connect(function(player: Player)
	local ok, expiry = pcall(function()
		return MuteStore:GetAsync(tostring(player.UserId))
	end)
	if ok and expiry and (expiry == math.huge or expiry > os.time()) then
		activeMutes[player.UserId] = expiry
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	if activeMutes[player.UserId] ~= math.huge then
		activeMutes[player.UserId] = nil
	end
end)

return ChatModerationService
