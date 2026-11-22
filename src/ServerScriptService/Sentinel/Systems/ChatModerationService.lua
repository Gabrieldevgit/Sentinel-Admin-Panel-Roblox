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

-- Primary enforcement: TextSource.CanSend. ShouldDeliverCallback alone only
-- stops delivery to OTHER players; the muted sender's own chat window still
-- showed their message as sent, which read as "mute doesn't work". With
-- CanSend = false the send is rejected (InvalidTextChannelPermissions) and
-- the message never appears anywhere.
local function textChannelsFolder(): Instance?
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return nil
	end
	return TextChatService:FindFirstChild("TextChannels")
end

local function applyCanSend(userId: number, canSend: boolean)
	local folder = textChannelsFolder()
	if not folder then
		return
	end
	for _, channel in ipairs(folder:GetChildren()) do
		if channel:IsA("TextChannel") then
			for _, source in ipairs(channel:GetChildren()) do
				if source:IsA("TextSource") and source.UserId == userId then
					source.CanSend = canSend
				end
			end
		end
	end
end

local scheduledUnmuteToken: { [number]: number } = {}

-- W14: players held on the ban / appeal screen can't chat. Not a mute: not
-- saved, not shown as a punishment, gone when they leave.
local silenced: { [number]: boolean } = {}

local function blocked(userId: number): boolean
	return silenced[userId] == true or ChatModerationService.IsMuted(userId)
end

function ChatModerationService.SetSilenced(userId: number, on: boolean)
	silenced[userId] = if on then true else nil
	applyCanSend(userId, not blocked(userId))
end

-- W14 (accepted mute appeals): lifts a mute by UserId, online or not.
function ChatModerationService.UnmuteUserId(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		ChatModerationService.Unmute(player)
		return
	end
	activeMutes[userId] = nil
	pcall(function()
		MuteStore:RemoveAsync(tostring(userId))
	end)
end

function ChatModerationService.Mute(target: Player, seconds: number, permanent: boolean?)
	local expiry = if permanent then math.huge else os.time() + seconds
	activeMutes[target.UserId] = expiry
	applyCanSend(target.UserId, false)

	-- Timed mutes: re-enable sending when the mute runs out. The token makes
	-- an older timer a no-op if the player is re-muted or unmuted meanwhile.
	local token = (scheduledUnmuteToken[target.UserId] or 0) + 1
	scheduledUnmuteToken[target.UserId] = token
	if not permanent then
		-- +1s: IsMuted treats expiry == now as still muted.
		task.delay(math.max(0, seconds) + 1, function()
			if scheduledUnmuteToken[target.UserId] == token and not ChatModerationService.IsMuted(target.UserId) then
				applyCanSend(target.UserId, true)
			end
		end)
	end

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
	scheduledUnmuteToken[target.UserId] = (scheduledUnmuteToken[target.UserId] or 0) + 1
	applyCanSend(target.UserId, not blocked(target.UserId))
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
		return not blocked(speaker.UserId)
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
		-- A muted player's TextSource can be created after the mute (on
		-- join, respawn of channels, new whisper channels): apply CanSend
		-- as each source appears.
		local function watchChannel(channel: TextChannel)
			attachDeliveryGate(channel)
			channel.ChildAdded:Connect(function(source: Instance)
				if source:IsA("TextSource") and blocked(source.UserId) then
					source.CanSend = false
				end
			end)
		end
		for _, channel in ipairs(textChannelsFolder:GetChildren()) do
			if channel:IsA("TextChannel") then
				watchChannel(channel)
			end
		end
		textChannelsFolder.ChildAdded:Connect(function(child: Instance)
			if child:IsA("TextChannel") then
				watchChannel(child)
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
		-- The TextSource may already exist by the time GetAsync returns.
		applyCanSend(player.UserId, false)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	silenced[player.UserId] = nil
	if activeMutes[player.UserId] ~= math.huge then
		activeMutes[player.UserId] = nil
	end
end)

return ChatModerationService
