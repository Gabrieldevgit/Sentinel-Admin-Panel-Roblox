--!strict
--[[
	AnnouncementService.lua (Announcements section, before W14)

	Purpose:
		One place that sends announcements and remembers them. Every
		announcement carries its author (UserId, name, display name) so the
		banner can show who sent it with their avatar.

	Scopes:
		server   everyone in this server            (;announce)
		global   everyone in every server           (;gannounce, via CrossServerActions)
		players  chosen players in this server      (;tannounce <players>)
		staff    staff online in this server        (;sannounce)

	Options (leading key=value words of the command, parsed by ParseOptions):
		style=banner|full     banner at the top (default) or a full-screen card
		time=<3-60>           seconds on screen (default 8)
		color=<name|#hex>     accent: accent gold red green blue purple orange pink
		title=<Word_Word>     heading (underscores become spaces, filtered)

	Payload sent on AnnounceRemote (client: SentinelUI/AnnouncementBanner):
		{ Kind = "announcement", Id, Text, Title, Style, Color, Duration,
		  Scope, Author = { UserId, Name, DisplayName }, Time }
	Older callers still fire (text, color); the client accepts both.

	History: newest first, at most 100, DataStore Sentinel_Announcements_v1
	key "History" (UpdateAsync merge, flushed every 10 s and on close; memory
	only outside a running game). Only the server that sent an announcement
	records it, so a global one appears once.

	Public API:
		AnnouncementService.ParseOptions(words) -> (options, rest, error?)
		AnnouncementService.Send(actor, text, scope, options, recipients?) -> (ok, message, record?)
		AnnouncementService.Show(payload, recipients?)   -- fire to clients only
		AnnouncementService.Record(record)
		AnnouncementService.History(limit?) -> { record }
		AnnouncementService.ColorHex(name) -> string?
		AnnouncementService.COLORS, STYLES
		AnnouncementService.GetTemplates() -> { {Name, Text} }   (M-panel gaps)
		AnnouncementService.SetTemplate(name, text?, actor?) -> (ok, message)

	Broadcast templates: ConfigService key BroadcastTemplates (server-wide,
	at most 20, name = letters/digits/_ <= 20, text <= 200). The
	Announcements page shows them as chips that fill the message box;
	;btemplate add|remove edits them.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local TextFilterService = require(script.Parent:WaitForChild("TextFilterService"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local AnnouncementService = {}

AnnouncementService.STYLES = { "banner", "full" }
AnnouncementService.COLORS = {
	accent = "",
	gold = "FFC94D",
	red = "EB5757",
	green = "57D682",
	blue = "409CFF",
	purple = "A78BFA",
	orange = "FF8A3D",
	pink = "F472B6",
}
AnnouncementService.DEFAULT_DURATION = 8
AnnouncementService.MAX_TEXT = 400

local MAX_HISTORY = 100
local STORE_NAME = "Sentinel_Announcements_v1"
local STORE_KEY = "History"

local function getRemote(): RemoteEvent
	local existing = SentinelShared:FindFirstChild("AnnounceRemote")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "AnnounceRemote"
	-- Unit tests run in Edit: don't leave remotes in the saved place.
	if game:GetService("RunService"):IsRunning() then
		remote.Parent = SentinelShared
	end
	return remote
end
local announceRemote = getRemote()

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------
function AnnouncementService.ColorHex(value: string): string?
	local lower = value:lower()
	local named = AnnouncementService.COLORS[lower]
	if named then
		return named
	end
	local hex = lower:match("^#?(%x%x%x%x%x%x)$")
	return if hex then hex:upper() else nil
end

export type Options = { Style: string, Duration: number, Color: string, Title: string? }

-- Reads leading key=value words. Stops at the first word that isn't an
-- option, so "time=5 Server restart at 5" keeps "at 5" in the message.
function AnnouncementService.ParseOptions(words: { string }): (Options, { string }, string?)
	local options: Options = { Style = "banner", Duration = AnnouncementService.DEFAULT_DURATION, Color = "" }
	local i = 1
	while i <= #words do
		local key, value = words[i]:match("^(%a+)=(.+)$")
		if not key then
			break
		end
		key = key:lower()
		if key == "style" then
			local style = value:lower()
			if style == "fullscreen" or style == "alert" then
				style = "full"
			end
			if not table.find(AnnouncementService.STYLES, style) then
				return options, {}, "style must be banner or full"
			end
			options.Style = style
		elseif key == "time" or key == "duration" then
			local n = tonumber((value:gsub("s$", "")))
			if not n or n < 3 or n > 60 then
				return options, {}, "time must be 3-60 seconds"
			end
			options.Duration = math.floor(n)
		elseif key == "color" or key == "colour" then
			local hex = AnnouncementService.ColorHex(value)
			if not hex then
				return options, {}, "unknown color (try gold, red, green, blue, purple, orange, pink or #RRGGBB)"
			end
			options.Color = hex
		elseif key == "title" then
			options.Title = value:gsub("_", " "):sub(1, 40)
		else
			break -- not one of ours: part of the message (e.g. "x=5")
		end
		i += 1
	end
	return options, table.move(words, i, #words, 1, {}), nil
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------
local live = RunService:IsRunning() and RunService:IsServer()
local store: DataStore? = nil
if live then
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, STORE_NAME)
	if ok then
		store = result
	end
end

local history: { any } = {}
local pending: { any } = {}
local loaded = false

local function mergeInto(list: { any }, newer: { any }): { any }
	local seen, out = {}, {}
	for _, r in ipairs(newer) do
		if type(r) == "table" and r.Id and not seen[r.Id] then
			seen[r.Id] = true
			table.insert(out, r)
		end
	end
	for _, r in ipairs(list) do
		if type(r) == "table" and r.Id and not seen[r.Id] then
			seen[r.Id] = true
			table.insert(out, r)
		end
	end
	table.sort(out, function(a, b)
		return (a.Time or 0) > (b.Time or 0)
	end)
	while #out > MAX_HISTORY do
		table.remove(out)
	end
	return out
end
AnnouncementService._Merge = mergeInto

local function load()
	if loaded or not store then
		loaded = true
		return
	end
	local ok, data = pcall(function()
		return (store :: DataStore):GetAsync(STORE_KEY)
	end)
	if ok then
		loaded = true
		history = mergeInto(if type(data) == "table" then data else {}, history)
	end
end

local function flush()
	if #pending == 0 or not store then
		return
	end
	local batch = pending
	pending = {}
	local ok, err = pcall(function()
		(store :: DataStore):UpdateAsync(STORE_KEY, function(old)
			return mergeInto(if type(old) == "table" then old else {}, batch)
		end)
	end)
	if not ok then
		warn("[Sentinel.Announcements] save failed: " .. tostring(err))
		for _, r in ipairs(batch) do
			table.insert(pending, r)
		end
	end
end

function AnnouncementService.Record(record: any)
	history = mergeInto(history, { record })
	if store then
		table.insert(pending, record)
	end
end

function AnnouncementService.History(limit: number?): { any }
	load()
	local out = {}
	for i = 1, math.min(limit or MAX_HISTORY, #history) do
		out[i] = history[i]
	end
	return out
end

if live then
	task.spawn(load)
	task.spawn(function()
		while true do
			task.wait(10)
			flush()
		end
	end)
	game:BindToClose(flush)
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
local function toColor(hex: string?): Color3?
	if type(hex) ~= "string" or #hex ~= 6 then
		return nil
	end
	local ok, c = pcall(Color3.fromHex, hex)
	return if ok then c else nil
end

-- Fires the banner. `recipients` nil = everyone in this server.
function AnnouncementService.Show(payload: any, recipients: { Player }?)
	local message = {
		Kind = "announcement",
		Id = payload.Id,
		Text = tostring(payload.Text or ""):sub(1, AnnouncementService.MAX_TEXT),
		Title = payload.Title,
		Style = if payload.Style == "full" then "full" else "banner",
		Color = toColor(payload.Color),
		Duration = math.clamp(tonumber(payload.Duration) or AnnouncementService.DEFAULT_DURATION, 3, 60),
		Scope = payload.Scope or "server",
		Author = payload.Author,
		Time = payload.Time or os.time(),
	}
	if recipients then
		for _, p in ipairs(recipients) do
			announceRemote:FireClient(p, message)
		end
	else
		announceRemote:FireAllClients(message)
	end
end

local function authorOf(actor: any): { UserId: number, Name: string, DisplayName: string }
	return {
		UserId = tonumber(actor.UserId) or 0,
		Name = tostring(actor.Name or "Sentinel"),
		DisplayName = tostring(actor.DisplayName or actor.Name or "Sentinel"),
	}
end
AnnouncementService.AuthorOf = authorOf

function AnnouncementService.StaffOnline(): { Player }
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if PermissionSystem.Has(p, "panel.open") then
			table.insert(out, p)
		end
	end
	return out
end

-- Builds the record, filters the text (and title) and shows it here.
-- scope "global" only builds + records; CrossServer.lua broadcasts it.
function AnnouncementService.Send(actor: any, text: string, scope: string, options: Options?, recipients: { Player }?): (boolean, string, any?)
	text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") :: string
	if text == "" then
		return false, "Type a message.", nil
	end
	local opts = options or { Style = "banner", Duration = AnnouncementService.DEFAULT_DURATION, Color = "" }
	local filtered = TextFilterService.ForBroadcast(actor.UserId, text:sub(1, AnnouncementService.MAX_TEXT))
	if not filtered then
		return false, TextFilterService.FAILED_MESSAGE, nil
	end
	local title = nil
	if opts.Title and opts.Title ~= "" then
		title = TextFilterService.ForBroadcast(actor.UserId, opts.Title)
	end

	local names = {}
	if recipients then
		for i, p in ipairs(recipients) do
			if i > 12 then
				break
			end
			table.insert(names, p.Name)
		end
	end
	local record = {
		Id = HttpService:GenerateGUID(false):sub(1, 8):lower(),
		Text = filtered,
		Title = title,
		Style = opts.Style,
		Color = opts.Color,
		Duration = opts.Duration,
		Scope = scope,
		Recipients = if recipients then names else nil,
		RecipientCount = if recipients then #recipients else nil,
		Author = authorOf(actor),
		Time = os.time(),
		Server = Logger.GetServerId(),
	}
	if scope ~= "global" then
		AnnouncementService.Show(record, recipients)
	end
	AnnouncementService.Record(record)
	return true, "Announcement sent.", record
end

-- ---------------------------------------------------------------------------
-- Broadcast templates (M-panel gaps)
-- ---------------------------------------------------------------------------
local DEFAULT_TEMPLATES = {
	{ Name = "welcome", Text = "Welcome to the server! Have fun and follow the rules." },
	{ Name = "rules", Text = "Reminder: be respectful, no exploiting, no spamming." },
	{ Name = "restart", Text = "The server will restart soon for an update. You will be moved automatically." },
	{ Name = "event", Text = "An event is starting now - join in!" },
}
AnnouncementService.MAX_TEMPLATES = 20
AnnouncementService.MAX_TEMPLATE_TEXT = 200

local function validTemplates(v: any): boolean
	if type(v) ~= "table" or #v > AnnouncementService.MAX_TEMPLATES then
		return false
	end
	local seen = {}
	for _, t in ipairs(v) do
		if type(t) ~= "table" or type(t.Name) ~= "string" or type(t.Text) ~= "string" then
			return false
		end
		if not t.Name:match("^[%w_]+$") or #t.Name > 20 or #t.Text == 0 or #t.Text > AnnouncementService.MAX_TEMPLATE_TEXT or seen[t.Name] then
			return false
		end
		seen[t.Name] = true
	end
	return true
end

ConfigService.Define("BroadcastTemplates", DEFAULT_TEMPLATES, validTemplates)

function AnnouncementService.GetTemplates(): { { Name: string, Text: string } }
	local v = ConfigService.Get("BroadcastTemplates")
	return if type(v) == "table" then v else table.clone(DEFAULT_TEMPLATES)
end

function AnnouncementService.SetTemplate(name: string, text: string?, actor: Player?): (boolean, string)
	if type(name) ~= "string" or not name:match("^[%w_]+$") or #name > 20 then
		return false, "Template names are letters, digits and _ (max 20)."
	end
	local lower = name:lower()
	local list = table.clone(AnnouncementService.GetTemplates())
	local existed = false
	for i = #list, 1, -1 do
		if list[i].Name:lower() == lower then
			table.remove(list, i)
			existed = true
		end
	end
	if text then
		text = text:gsub("%c+", " "):gsub("&&", "&"):match("^%s*(.-)%s*$")
		if not text or #text == 0 or #text > AnnouncementService.MAX_TEMPLATE_TEXT then
			return false, ("Template text is 1-%d characters."):format(AnnouncementService.MAX_TEMPLATE_TEXT)
		end
		table.insert(list, { Name = lower, Text = text })
	elseif not existed then
		return false, ("No template named %s."):format(lower)
	end
	if #list > AnnouncementService.MAX_TEMPLATES then
		return false, ("At most %d templates."):format(AnnouncementService.MAX_TEMPLATES)
	end
	local ok, err = ConfigService.Set("BroadcastTemplates", list, actor)
	if not ok then
		return false, err or "Could not save."
	end
	return true, if text then ("Template %s saved."):format(lower) else ("Removed template %s."):format(lower)
end

return AnnouncementService
