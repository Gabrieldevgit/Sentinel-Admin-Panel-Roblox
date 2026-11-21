--!strict
--[[
	PrivateMessageService.lua (PM options, before W14)

	Purpose:
		Delivers ;pm messages as message cards (SentinelUI/AnnouncementBanner)
		and handles what the recipient does with them: reply, "Got it"
		(read receipt). Each staff -> player message opens a thread; both
		sides may answer inside it.

	Options (leading key=value words of ;pm, see ParseOptions):
		kind=info|success|warning|error   card colour / icon (default info)
		time=0|5-120                      seconds on screen; 0 = until closed (default 0)
		reply=on|off                      the player may answer (default on)
		ack=on                            tell me when they read it
		anon=on                           show "Staff" instead of my name
		                                  (needs node utility.pm.anonymous; still logged)
		style=card|popup                  corner card (default) or centred pop-up
		title=Word_Word                   heading (underscores become spaces)

	Remote PrivateMessageRemote (RemoteEvent):
		server -> client  (payload)  { Kind = "pm", Thread, MessageId, From?,
		                   Anonymous, Text, Title, Level, Duration, CanReply,
		                   NeedsAck, Style, IsReply }
		client -> server  ("reply", thread, text) | ("ack", thread, messageId)

	Reply rules: the recipient may reply while the thread allows it, up to
	MAX_REPLIES times, within REPLY_WINDOW seconds of the last staff
	message. Replies are filtered (ForUser) and logged (utility.pmreply).

	Public API:
		PrivateMessageService.ParseOptions(words) -> (options, rest, error?)
		PrivateMessageService.Send(from, to, text, options) -> (ok, message)
		PrivateMessageService.HandleReply(player, threadId, text) -> (ok, message)
		PrivateMessageService.HandleAck(player, threadId, messageId) -> boolean
--]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local TextFilterService = require(script.Parent:WaitForChild("TextFilterService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local PrivateMessageService = {}

PrivateMessageService.KINDS = { "info", "success", "warning", "error" }
PrivateMessageService.MAX_REPLIES = 5
PrivateMessageService.REPLY_WINDOW = 600
PrivateMessageService.MAX_TEXT = 300
PrivateMessageService.ANON_NODE = "utility.pm.anonymous"

local function getRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	-- Unit tests run in Edit: don't leave remotes in the saved place.
	if game:GetService("RunService"):IsRunning() then
		remote.Parent = SentinelShared
	end
	return remote
end
local pmRemote = getRemote("PrivateMessageRemote")
local resultRemote = getRemote("CommandResultRemote")

export type Options = {
	Kind: string,
	Duration: number,
	Reply: boolean,
	Ack: boolean,
	Anonymous: boolean,
	Style: string,
	Title: string?,
}

local function truthy(value: string): boolean?
	local v = value:lower()
	if v == "on" or v == "yes" or v == "true" or v == "1" then
		return true
	elseif v == "off" or v == "no" or v == "false" or v == "0" then
		return false
	end
	return nil
end

function PrivateMessageService.ParseOptions(words: { string }): (Options, { string }, string?)
	local options: Options = { Kind = "info", Duration = 0, Reply = true, Ack = false, Anonymous = false, Style = "card" }
	local i = 1
	while i <= #words do
		local key, value = words[i]:match("^(%a+)=(.+)$")
		if not key then
			break
		end
		key = key:lower()
		if key == "kind" or key == "type" then
			local kind = value:lower()
			if kind == "ok" then
				kind = "success"
			elseif kind == "warn" then
				kind = "warning"
			end
			if not table.find(PrivateMessageService.KINDS, kind) then
				return options, {}, "kind must be info, success, warning or error"
			end
			options.Kind = kind
		elseif key == "time" or key == "duration" then
			local n = tonumber((value:gsub("s$", "")))
			if not n or (n ~= 0 and (n < 5 or n > 120)) then
				return options, {}, "time must be 0 (until closed) or 5-120 seconds"
			end
			options.Duration = math.floor(n)
		elseif key == "reply" or key == "ack" or key == "anon" or key == "anonymous" then
			local flag = truthy(value)
			if flag == nil then
				return options, {}, key .. " must be on or off"
			end
			if key == "reply" then
				options.Reply = flag
			elseif key == "ack" then
				options.Ack = flag
			else
				options.Anonymous = flag
			end
		elseif key == "style" then
			local style = value:lower()
			if style ~= "card" and style ~= "popup" then
				return options, {}, "style must be card or popup"
			end
			options.Style = style
		elseif key == "title" then
			options.Title = value:gsub("_", " "):sub(1, 40)
		else
			break
		end
		i += 1
	end
	return options, table.move(words, i, #words, 1, {}), nil
end

-- ---------------------------------------------------------------------------
-- Threads
-- ---------------------------------------------------------------------------
type Thread = {
	Id: string,
	Staff: number, -- the staff member who opened it
	Player: number, -- the recipient
	Reply: boolean,
	Anonymous: boolean,
	Replies: number,
	LastStaffAt: number,
	Acks: { [string]: boolean }, -- messageId -> needs ack (true) / done (nil)
}

local threads: { [string]: Thread } = {}

local function newId(): string
	return HttpService:GenerateGUID(false):sub(1, 8):lower()
end

local function senderInfo(p: Player)
	return { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName }
end

local function deliver(to: Player, thread: Thread, from: Player, text: string, options: Options, isReply: boolean): string
	local messageId = newId()
	local fromStaff = from.UserId == thread.Staff
	local needsAck = fromStaff and options.Ack
	if needsAck then
		thread.Acks[messageId] = true
	end
	local hide = fromStaff and thread.Anonymous
	pmRemote:FireClient(to, {
		Kind = "pm",
		Thread = thread.Id,
		MessageId = messageId,
		From = if hide then nil else senderInfo(from),
		Anonymous = hide,
		Text = text,
		Title = options.Title,
		Level = options.Kind,
		Duration = options.Duration,
		-- staff can always answer a reply; players only if the thread allows it
		CanReply = if fromStaff then thread.Reply else true,
		NeedsAck = needsAck,
		Style = options.Style,
		IsReply = isReply,
	})
	return messageId
end

function PrivateMessageService.Send(from: Player, to: Player, text: string, options: Options): (boolean, string)
	text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") :: string
	if text == "" then
		return false, "Private message text is required."
	end
	if options.Anonymous and not PermissionSystem.Has(from, PrivateMessageService.ANON_NODE) then
		return false, ("Anonymous messages need the %s permission."):format(PrivateMessageService.ANON_NODE)
	end
	local filtered = TextFilterService.ForUser(from.UserId, text:sub(1, PrivateMessageService.MAX_TEXT), to.UserId)
	if not filtered then
		return false, TextFilterService.FAILED_MESSAGE
	end
	if options.Title then
		options = table.clone(options)
		options.Title = TextFilterService.ForUser(from.UserId, options.Title, to.UserId)
	end
	local thread: Thread = {
		Id = newId(),
		Staff = from.UserId,
		Player = to.UserId,
		Reply = options.Reply,
		Anonymous = options.Anonymous,
		Replies = 0,
		LastStaffAt = os.time(),
		Acks = {},
	}
	threads[thread.Id] = thread
	deliver(to, thread, from, filtered, options, false)
	return true, filtered
end

local function writeLog(player: Player, command: string, text: string, target: Player?, message: string)
	Logger.Write({
		Executor = tostring(player.UserId),
		ExecutorName = player.Name,
		Command = command,
		Action = "utility." .. command,
		Arguments = { text },
		Target = if target then target.Name else nil,
		TargetIds = if target then { target.UserId } else nil,
		Result = "Success",
		Severity = "Info",
		Message = message,
		Source = "message card",
	})
end

function PrivateMessageService.HandleReply(player: Player, threadId: any, text: any): (boolean, string)
	if type(threadId) ~= "string" or type(text) ~= "string" then
		return false, "Bad reply."
	end
	local thread = threads[threadId]
	if not thread or (player.UserId ~= thread.Staff and player.UserId ~= thread.Player) then
		return false, "This conversation has ended."
	end
	local isStaff = player.UserId == thread.Staff
	if not isStaff then
		if not thread.Reply then
			return false, "Replies are turned off for this message."
		end
		if thread.Replies >= PrivateMessageService.MAX_REPLIES then
			return false, "You've reached the reply limit for this message."
		end
		if os.time() - thread.LastStaffAt > PrivateMessageService.REPLY_WINDOW then
			return false, "This conversation has ended."
		end
	end
	local otherId = if isStaff then thread.Player else thread.Staff
	local other = Players:GetPlayerByUserId(otherId)
	if not other then
		return false, "They are no longer in this server."
	end
	text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") :: string
	if text == "" then
		return false, "Type a reply."
	end
	local filtered = TextFilterService.ForUser(player.UserId, text:sub(1, PrivateMessageService.MAX_TEXT), other.UserId)
	if not filtered then
		return false, TextFilterService.FAILED_MESSAGE
	end
	if isStaff then
		thread.LastStaffAt = os.time()
		thread.Replies = 0 -- a new staff message opens a fresh round of replies
	else
		thread.Replies += 1
		-- a reply also counts as having read every message so far
		for id in pairs(thread.Acks) do
			thread.Acks[id] = nil
		end
	end
	deliver(other, thread, player, filtered, {
		Kind = "info",
		Duration = 0,
		Reply = thread.Reply,
		Ack = false,
		Anonymous = false,
		Style = "card",
		Title = nil,
	}, true)
	writeLog(player, "pmreply", filtered, other, ("Reply to %s"):format(other.Name))
	return true, "Reply sent."
end

function PrivateMessageService.HandleAck(player: Player, threadId: any, messageId: any): boolean
	if type(threadId) ~= "string" or type(messageId) ~= "string" then
		return false
	end
	local thread = threads[threadId]
	if not thread or thread.Player ~= player.UserId or not thread.Acks[messageId] then
		return false
	end
	thread.Acks[messageId] = nil
	local staff = Players:GetPlayerByUserId(thread.Staff)
	if staff then
		resultRemote:FireClient(staff, { { Success = true, Message = ("%s read your private message."):format(player.DisplayName) } })
	end
	return true
end

-- Clean up threads of players who left.
Players.PlayerRemoving:Connect(function(player: Player)
	for id, thread in pairs(threads) do
		if thread.Staff == player.UserId or thread.Player == player.UserId then
			threads[id] = nil
		end
	end
end)

local limiter = RateLimiter.new("PrivateMessageRemote", 4, 0.5)
pmRemote.OnServerEvent:Connect(function(player: Player, action: any, threadId: any, value: any)
	if not limiter:Allow(player) then
		return
	end
	if action == "reply" then
		local ok, message = PrivateMessageService.HandleReply(player, threadId, value)
		pmRemote:FireClient(player, { Kind = "replyResult", Thread = threadId, Success = ok, Message = message })
	elseif action == "ack" then
		PrivateMessageService.HandleAck(player, threadId, value)
	end
end)

return PrivateMessageService
