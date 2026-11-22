--!strict
--[[
	PlayerFormsService.lua (W14)

	Purpose:
		The player-facing side of reports and appeals. Every player (not
		only staff) can open the report form and the appeal form; banned
		players get the ban screen instead of an instant kick.

	Remotes (ReplicatedStorage.Shared.Sentinel):
		PlayerFormsRemote  RemoteFunction  client -> server, (action, data):
			"reportInfo"            -> { Enabled, Players = {{UserId, Name, DisplayName}}, Categories }
			"submitReport" {TargetId, Category, Description, Evidence = {string}}
			                        -> { Ok, Message, Id? }
			"appealInfo"            -> { Enabled, Items = AppealService.Appealable(...) }
			"submitAppeal" {Key, Text} -> { Ok, Message, Id? }
			"seen" appealId         (the player read a decision notice)
		PlayerFormsEvent   RemoteEvent     server -> client, (kind, data):
			"report"  { TargetId? }          open the report form
			"appeal"  {}                     open the appeal form
			"banscreen" { Reason, By, ExpiresAt, Window, Items }
			"notice"  { Kind, Title, Message }  e.g. an appeal decision
			"release" {}                     ban lifted while on the ban screen

	Ban screen ("pre-kick screen", decided with the user for W14):
		PlayerFormsService.HoldBanned(player, banRecord) keeps a banned
		player in the server for AppealWindow seconds (config, default 120)
		with no character and no chat, shows the ban screen, then kicks them.
		They are kicked 10 s after submitting an appeal, or at once if they
		can't appeal. If the ban is lifted meanwhile (an Owner accepts the
		appeal live, ;unban), they are released and spawn normally.
		With ;config appeals off the old instant kick is used.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))
local ReportService = require(script.Parent:WaitForChild("ReportService"))
local AppealService = require(script.Parent:WaitForChild("AppealService"))
local ChatModerationService = require(script.Parent:WaitForChild("ChatModerationService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local PlayerFormsService = {}

local function getOrCreate(name: string, className: string): Instance
	local existing = SentinelShared:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = SentinelShared
	return inst
end

local formsRemote = getOrCreate("PlayerFormsRemote", "RemoteFunction") :: RemoteFunction
local formsEvent = getOrCreate("PlayerFormsEvent", "RemoteEvent") :: RemoteEvent
local limiter = RateLimiter.new("PlayerFormsRemote", 8, 0.5)

-- userId -> { Ban, Deadline, Token }
local held: { [number]: { Ban: any, Deadline: number, Token: number } } = {}
PlayerFormsService.Held = held

function PlayerFormsService.IsHeld(player: Player): boolean
	return held[player.UserId] ~= nil
end

function PlayerFormsService.Open(player: Player, kind: string, data: any?)
	formsEvent:FireClient(player, kind, data or {})
end

function PlayerFormsService.Notice(player: Player, kind: string, title: string, message: string)
	formsEvent:FireClient(player, "notice", { Kind = kind, Title = title, Message = message })
end

local function kickHeld(player: Player, token: number, message: string)
	local h = held[player.UserId]
	if h and h.Token == token and player.Parent then
		player:Kick(message)
	end
end

local function banText(ban: any): string
	local expiry = if ban.ExpiresAt == math.huge or ban.ExpiresAt == -1
		then "permanently"
		else ("until %s"):format(os.date("!%Y-%m-%d %H:%M UTC", ban.ExpiresAt))
	return ("You are banned %s. Reason: %s"):format(expiry, tostring(ban.Reason))
end
PlayerFormsService.BanText = banText

local function removeCharacter(player: Player)
	local character = player.Character
	if character then
		character:Destroy()
	end
end

function PlayerFormsService.HoldBanned(player: Player, ban: any)
	if ConfigService.Get("AppealsEnabled") == false then
		player:Kick(banText(ban))
		return
	end
	local window = ConfigService.Get("AppealWindow") or 120
	local token = (held[player.UserId] and held[player.UserId].Token or 0) + 1
	held[player.UserId] = { Ban = ban, Deadline = os.time() + window, Token = token }
	player:SetAttribute("SentinelBanHold", true)
	ChatModerationService.SetSilenced(player.UserId, true)
	removeCharacter(player)
	player.CharacterAdded:Connect(function()
		if held[player.UserId] then
			task.defer(removeCharacter, player)
		end
	end)

	local items = AppealService.Appealable(player.UserId, player.Name)
	local canAppeal = false
	for _, item in ipairs(items) do
		if item.Type == "ban" and not item.Blocked then
			canAppeal = true
		end
	end
	formsEvent:FireClient(player, "banscreen", {
		Reason = ban.Reason,
		By = ban.BannedByName,
		ExpiresAt = if ban.ExpiresAt == math.huge then -1 else ban.ExpiresAt,
		Window = window,
		Items = items,
		CanAppeal = canAppeal,
	})
	-- Nothing to appeal (already pending / rejected recently): a short
	-- read of the status, then out.
	local stay = if canAppeal then window else math.min(window, 30)
	task.delay(stay, kickHeld, player, token, banText(ban))
end

local function release(userId: number)
	local h = held[userId]
	if not h then
		return
	end
	held[userId] = nil
	local player = Players:GetPlayerByUserId(userId)
	if player then
		player:SetAttribute("SentinelBanHold", nil)
		ChatModerationService.SetSilenced(userId, false)
		formsEvent:FireClient(player, "release", {})
		task.defer(function()
			if player.Parent and not player.Character then
				player:LoadCharacter()
			end
		end)
	end
end
PlayerFormsService.Release = release

EventBus.Subscribe("Player.Unbanned", function(userId: any)
	if type(userId) == "number" then
		release(userId)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	held[player.UserId] = nil
end)

-- ---------------------------------------------------------------------------
-- Decision notices: right away when online, else on the next join.
-- ---------------------------------------------------------------------------
local function decisionText(a: any): (string, string, string)
	local what = if a.CaseId then ("%s (case #%d)"):format(a.Type, a.CaseId) else a.Type
	if a.Status == "Accepted" then
		local extra = if a.Type == "ban" then " You can join the game again." else " The punishment has been lifted."
		return "success", ("Appeal #%d accepted"):format(a.Id), ("Your appeal of your %s was accepted.%s%s"):format(
			what,
			extra,
			if a.Decision then "\nNote from staff: " .. a.Decision else ""
		)
	end
	return "warning", ("Appeal #%d rejected"):format(a.Id), ("Your appeal of your %s was rejected.%s"):format(
		what,
		if a.Decision then "\nNote from staff: " .. a.Decision else ""
	)
end

AppealService.OnChanged(function(a: any, what: string)
	if what ~= "decided" then
		return
	end
	local player = Players:GetPlayerByUserId(a.UserId)
	if player and not held[a.UserId] then
		local kind, title, msg = decisionText(a)
		PlayerFormsService.Notice(player, kind, title, msg)
		AppealService.MarkSeen(a.UserId, a.Id)
	end
end)

Players.PlayerAdded:Connect(function(player: Player)
	task.delay(8, function()
		if not player.Parent or held[player.UserId] then
			return
		end
		for _, e in ipairs(AppealService.ForUser(player.UserId)) do
			if e.Status ~= "Pending" and not e.Seen then
				local a = AppealService.Get(e.Id)
				if a then
					local kind, title, msg = decisionText(a)
					PlayerFormsService.Notice(player, kind, title, msg)
				end
				AppealService.MarkSeen(player.UserId, e.Id)
			end
		end
	end)
end)

-- ---------------------------------------------------------------------------
-- Remote
-- ---------------------------------------------------------------------------
local function str(v: any, max: number): string?
	return if type(v) == "string" then v:sub(1, max) else nil
end

local handlers: { [string]: (Player, any) -> any } = {}

handlers.reportInfo = function(player: Player)
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and not held[p.UserId] then
			table.insert(list, { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName })
		end
	end
	table.sort(list, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return {
		Enabled = ConfigService.Get("ReportsEnabled") ~= false,
		Players = list,
		Categories = ReportService.CATEGORIES,
	}
end

handlers.submitReport = function(player: Player, data: any)
	if held[player.UserId] or type(data) ~= "table" or type(data.TargetId) ~= "number" then
		return { Ok = false, Message = "Pick a player to report." }
	end
	local target = Players:GetPlayerByUserId(data.TargetId)
	if not target then
		return { Ok = false, Message = "That player is no longer in this server." }
	end
	local evidence = {}
	if type(data.Evidence) == "table" then
		for i = 1, 5 do
			local e = str(data.Evidence[i], 200)
			if e and e:match("%S") then
				table.insert(evidence, e)
			end
		end
	end
	local report, err = ReportService.Submit(player, target, str(data.Category, 30), str(data.Description, 500), evidence)
	if not report then
		return { Ok = false, Message = err }
	end
	return { Ok = true, Id = report.Id, Message = ("Thanks! Report #%d was sent to the staff team."):format(report.Id) }
end

handlers.appealInfo = function(player: Player)
	return {
		Enabled = ConfigService.Get("AppealsEnabled") ~= false,
		Items = AppealService.Appealable(player.UserId, player.Name),
	}
end

handlers.submitAppeal = function(player: Player, data: any)
	if type(data) ~= "table" then
		return { Ok = false, Message = "Pick the punishment you want to appeal." }
	end
	local h = held[player.UserId]
	local appeal, err = AppealService.Submit(player, str(data.Key, 40) or "", str(data.Text, 1000) or "", if h then "banscreen" else "form")
	if not appeal then
		return { Ok = false, Message = err }
	end
	if h then
		local token = h.Token
		task.delay(12, kickHeld, player, token, banText(h.Ban) .. (" Your appeal #%d was received."):format(appeal.Id))
	end
	return { Ok = true, Id = appeal.Id, Message = ("Appeal #%d was sent. Staff will review it; you'll be told the decision."):format(appeal.Id) }
end

handlers.seen = function(player: Player, id: any)
	if type(id) == "number" then
		AppealService.MarkSeen(player.UserId, id)
	end
	return true
end

formsRemote.OnServerInvoke = function(player: Player, action: any, data: any)
	if not limiter:Allow(player) then
		return { Ok = false, Message = "Slow down a little." }
	end
	local handler = if type(action) == "string" then handlers[action] else nil
	if not handler then
		return nil
	end
	local ok, result = pcall(handler, player, data)
	if not ok then
		warn("[Sentinel.PlayerForms] " .. tostring(action) .. " failed: " .. tostring(result))
		return { Ok = false, Message = "Something went wrong. Try again." }
	end
	return result
end

return PlayerFormsService
