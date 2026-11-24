--!strict
--[[
	EventService.lua (W24 - Events)

	Purpose:
		Live events: staff start an event from a preset (Double Coins,
		Double XP, ...) or a custom one, now or scheduled, for a duration
		or until stopped, in this server or every server. While an event is
		active its multipliers apply to earned currency (EconomyService.Award)
		and every player sees it in the event bar at the top of the screen.
		Start / end are announced and every finished event goes to history.

	Presets (EventService.Define = the custom-event API, W25 adds more):
		doublecoins   Coins x2
		doublexp      XP x2
		doublegems    Gems x2
		doubleall     Coins, XP and Gems x2
		custom        name= / coins= / xp= / gems= decide what it does
	A definition: { Id, Name, Description, Color (hex), Multipliers =
	{ Coins?, XP?, Gems? }, DefaultDuration?, Aliases?, OnStart(event)?,
	OnStop(event)? }. OnStart / OnStop run on every server the event runs on.

	Options (ParseSpec, words after the preset):
		time=<1m-24h>|none   duration (default the preset's, else 15 min)
		in=<10s-24h>         start later (scheduled event)
		announce=on|off      banner when it starts / ends (default on)
		coins=<n> xp=<n> gems=<n>   override multipliers (0.1 - 10)
		name=Word_Word       custom name (custom events: or the remaining words)
	    ;event doublecoins time=30m
	    ;event custom in=5m coins=3 Weekend rush

	Status: scheduled -> active -> ended; stopped (by hand while active),
	cancelled (stopped before it started). Every server runs the timers of
	the events it knows from their absolute StartsAt / EndsAt.

	Global events (CrossServerService kinds, handled here):
		evs  { i, p, n, c, m, st, e, an, d }  an event was started/scheduled
		evx  { i, by }                        an event was stopped
	Active / scheduled global events are also kept in DataStore
	Sentinel_Events_v1 key "Global" so a server that starts later joins in.

	History: newest first, at most 100, DataStore Sentinel_Events_v1 key
	"History" (flushed every 10 s and on close; merged by Id, so every
	server may record a global event without duplicates).

	Multipliers: product over active events, capped at MAX_MULTIPLIER.
	Also published as attributes EventMultiplier_Coins / _XP / _Gems on
	ReplicatedStorage.Shared.Sentinel (any game script, client or server,
	can read them) and on EventBus "Events.Changed".

	Client remote EventRemote (RemoteEvent, server -> client):
		("state", { view }, serverTime)   every active / scheduled event
	view = { Id, Name, Description, Color, Multipliers, StartsAt, EndsAt,
	         Status, Scope }

	Public API:
		EventService.Define(def)            EventService.Presets() -> { def }
		EventService.FindPreset(text) -> def?
		EventService.ParseSpec(words) -> (spec?, error?)
		EventService.Create(actor, spec, scope) -> (ok, message, event?)
		EventService.Stop(actor, idOrPreset?) -> (ok, message, event?)
		EventService.Find(text?) -> (event?, error?)
		EventService.Active() -> { event }  (active + scheduled, soonest first)
		EventService.History(limit?) -> { record }
		EventService.Multiplier(stat) -> number   / Multipliers() -> map
		EventService.Snapshot() -> { Active, History, Presets, Multipliers }
		EventService.Describe(event) -> string
		Pure helpers (Event.spec): StatusAt, Combine, ParseDuration
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Logger = require(Core:WaitForChild("Logger"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local EventService = {}

EventService.DEFAULT_DURATION = 15 * 60
EventService.MIN_DURATION = 60
EventService.MAX_DURATION = 24 * 3600
EventService.MAX_DELAY = 24 * 3600
EventService.MIN_DELAY = 10
EventService.MAX_EVENTS = 6 -- active + scheduled per server
EventService.MAX_MULTIPLIER = 10
EventService.MAX_NAME = 40
EventService.STATS = { "Coins", "XP", "Gems" }

local MAX_HISTORY = 100
local STORE_NAME = "Sentinel_Events_v1"
local HISTORY_KEY = "History"
local GLOBAL_KEY = "Global"

local live = RunService:IsRunning() and RunService:IsServer()

export type Definition = {
	Id: string,
	Name: string,
	Description: string,
	Color: string,
	Multipliers: { [string]: number },
	DefaultDuration: number?,
	Aliases: { string }?,
	OnStart: ((any) -> ())?,
	OnStop: ((any) -> ())?,
}

export type Spec = {
	Preset: string,
	Name: string?,
	Duration: number, -- 0 = until stopped
	Delay: number,
	Announce: boolean,
	Multipliers: { [string]: number }?, -- overrides
}

-- ---------------------------------------------------------------------------
-- Presets / custom-event API
-- ---------------------------------------------------------------------------
local definitions: { [string]: Definition } = {}
local definitionOrder: { string } = {}

function EventService.Define(def: Definition)
	assert(type(def) == "table" and type(def.Id) == "string" and def.Id ~= "", "EventService.Define: Id required")
	local id = def.Id:lower()
	def.Id = id
	def.Name = tostring(def.Name or id)
	def.Description = tostring(def.Description or "")
	def.Color = tostring(def.Color or "F5B942")
	def.Multipliers = def.Multipliers or {}
	if not definitions[id] then
		table.insert(definitionOrder, id)
	end
	definitions[id] = def
end

function EventService.Presets(): { Definition }
	local out = {}
	for _, id in ipairs(definitionOrder) do
		table.insert(out, definitions[id])
	end
	return out
end

local function squash(s: string): string
	return (s:lower():gsub("[%s_%-]", ""))
end

function EventService.FindPreset(text: string?): Definition?
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local key = squash(text)
	if definitions[key] then
		return definitions[key]
	end
	for _, id in ipairs(definitionOrder) do
		local def = definitions[id]
		if squash(def.Name) == key then
			return def
		end
		for _, alias in ipairs(def.Aliases or {}) do
			if squash(alias) == key then
				return def
			end
		end
	end
	return nil
end

EventService.Define({
	Id = "doublecoins",
	Name = "Double Coins",
	Description = "Every coin earned counts twice.",
	Color = "F5B942",
	Multipliers = { Coins = 2 },
	Aliases = { "2xcoins", "coins2x", "doublemoney", "2xmoney" },
})
EventService.Define({
	Id = "doublexp",
	Name = "Double XP",
	Description = "Every point of XP earned counts twice.",
	Color = "60A5FA",
	Multipliers = { XP = 2 },
	Aliases = { "2xxp", "xp2x" },
})
EventService.Define({
	Id = "doublegems",
	Name = "Double Gems",
	Description = "Every gem earned counts twice.",
	Color = "C084FC",
	Multipliers = { Gems = 2 },
	Aliases = { "2xgems", "gems2x" },
})
EventService.Define({
	Id = "doubleall",
	Name = "Double Everything",
	Description = "Coins, XP and gems earned all count twice.",
	Color = "34D399",
	Multipliers = { Coins = 2, XP = 2, Gems = 2 },
	Aliases = { "2xall", "doubleeverything", "2xeverything" },
})
EventService.Define({
	Id = "custom",
	Name = "Custom event",
	Description = "A staff event.",
	Color = "F472B6",
	Multipliers = {},
})

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested in Tests/Event.spec)
-- ---------------------------------------------------------------------------
function EventService.ParseDuration(value: string): number?
	local v = value:lower()
	if v == "0" or v == "none" or v == "off" or v == "manual" then
		return 0
	end
	local total, rest = 0, v
	while rest ~= "" do
		local n, unit, after = rest:match("^(%d+%.?%d*)([smhd]?)(.*)$")
		local num = tonumber(n)
		if not num then
			return nil
		end
		local mult = if unit == "m" then 60 elseif unit == "h" then 3600 elseif unit == "d" then 86400 else 1
		if unit == "" and after ~= "" then
			return nil
		end
		total += num * mult
		rest = after
	end
	return math.floor(total)
end

local function onOff(value: string): boolean?
	local v = value:lower()
	if v == "on" or v == "yes" or v == "true" or v == "1" then
		return true
	elseif v == "off" or v == "no" or v == "false" or v == "0" then
		return false
	end
	return nil
end

local function cleanName(s: string): string
	local out = s:gsub("[%c|]", " "):gsub("&&", "&"):gsub("%s+", " ")
	return ((out:match("^%s*(.-)%s*$")) :: string):sub(1, EventService.MAX_NAME)
end

-- words = the command's arguments (preset first).
function EventService.ParseSpec(words: { string }): (Spec?, string?)
	local def = EventService.FindPreset(words[1])
	if not def then
		local names = {}
		for _, id in ipairs(definitionOrder) do
			table.insert(names, id)
		end
		return nil, ("Unknown event \"%s\". Presets: %s."):format(tostring(words[1] or ""), table.concat(names, ", "))
	end
	local spec: Spec = {
		Preset = def.Id,
		Duration = def.DefaultDuration or EventService.DEFAULT_DURATION,
		Delay = 0,
		Announce = true,
	}
	local nameWords = {}
	for k = 2, #words do
		local word = words[k]
		local key, value = word:match("^(%a+)=(.+)$")
		local lkey = if key then key:lower() else nil
		if lkey == "time" or lkey == "duration" or lkey == "for" then
			local d = EventService.ParseDuration(value)
			if not d then
				return nil, ("Bad time \"%s\" (use 30m, 2h, none)."):format(value)
			end
			if d ~= 0 and (d < EventService.MIN_DURATION or d > EventService.MAX_DURATION) then
				return nil, "An event lasts between 1 minute and 24 hours (or time=none)."
			end
			spec.Duration = d
		elseif lkey == "in" or lkey == "delay" or lkey == "start" then
			local d = EventService.ParseDuration(value)
			if not d or d == 0 then
				return nil, ("Bad start delay \"%s\" (use in=5m)."):format(value)
			end
			if d < EventService.MIN_DELAY or d > EventService.MAX_DELAY then
				return nil, "A scheduled event starts between 10 seconds and 24 hours from now."
			end
			spec.Delay = d
		elseif lkey == "announce" then
			local b = onOff(value)
			if b == nil then
				return nil, "announce= takes on or off."
			end
			spec.Announce = b
		elseif lkey == "coins" or lkey == "xp" or lkey == "gems" then
			local n = tonumber((value:gsub("^[xX]", ""):gsub("[xX]$", "")))
			if not n or n < 0.1 or n > EventService.MAX_MULTIPLIER then
				return nil, ("%s= takes a multiplier from 0.1 to %d."):format(lkey, EventService.MAX_MULTIPLIER)
			end
			spec.Multipliers = spec.Multipliers or {}
			local stat = if lkey == "coins" then "Coins" elseif lkey == "xp" then "XP" else "Gems"
			;(spec.Multipliers :: any)[stat] = math.floor(n * 100 + 0.5) / 100
		elseif lkey == "name" or lkey == "title" then
			spec.Name = cleanName((value:gsub("_", " ")))
		else
			table.insert(nameWords, word)
		end
	end
	if #nameWords > 0 then
		if def.Id ~= "custom" and not spec.Name then
			return nil, ("Unknown option \"%s\". Options: time= in= announce= coins= xp= gems= name="):format(nameWords[1])
		end
		spec.Name = spec.Name or cleanName(table.concat(nameWords, " "))
	end
	if spec.Name == "" then
		spec.Name = nil
	end
	return spec, nil
end

-- "scheduled" | "active" | "ended" (by time) for an event at `now`.
function EventService.StatusAt(event: any, now: number): string
	if event.Status == "stopped" or event.Status == "cancelled" or event.Status == "ended" then
		return event.Status
	end
	if now < (event.StartsAt or 0) then
		return "scheduled"
	end
	if (event.EndsAt or 0) > 0 and now >= event.EndsAt then
		return "ended"
	end
	return "active"
end

-- Product of the multipliers of every active event, per stat (capped).
function EventService.Combine(events: { any }, now: number): { [string]: number }
	local out: { [string]: number } = {}
	for _, stat in ipairs(EventService.STATS) do
		out[stat] = 1
	end
	for _, event in ipairs(events) do
		if EventService.StatusAt(event, now) == "active" then
			for stat, m in pairs(event.Multipliers or {}) do
				if out[stat] and type(m) == "number" and m > 0 then
					out[stat] *= m
				end
			end
		end
	end
	for stat, m in pairs(out) do
		out[stat] = math.clamp(math.floor(m * 100 + 0.5) / 100, 0.1, EventService.MAX_MULTIPLIER)
	end
	return out
end

local function multiplierText(m: { [string]: number }?): string
	local parts = {}
	for _, stat in ipairs(EventService.STATS) do
		local v = if m then m[stat] else nil
		if v and v ~= 1 then
			table.insert(parts, ("%s x%s"):format(stat, tostring(v)))
		end
	end
	return table.concat(parts, ", ")
end
EventService.MultiplierText = multiplierText

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%dh %02dm"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local events: { [string]: any } = {}
local crossServer: any = nil -- CrossServerService (live only)
local function serverId(): string
	return if crossServer then crossServer.ServerId else Logger.GetServerId()
end

local listeners: { (string, any) -> () } = {}
function EventService.OnChanged(fn: (string, any) -> ())
	table.insert(listeners, fn)
end
local function notify(what: string, event: any)
	for _, fn in ipairs(listeners) do
		task.spawn(fn, what, event)
	end
end

function EventService.Get(id: string): any
	return events[id]
end

function EventService.Active(): { any }
	local out = {}
	for _, e in pairs(events) do
		if e.Status == "active" or e.Status == "scheduled" then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		if a.StartsAt ~= b.StartsAt then
			return a.StartsAt < b.StartsAt
		end
		return a.Id < b.Id
	end)
	return out
end

function EventService.Multipliers(): { [string]: number }
	return EventService.Combine(EventService.Active(), os.time())
end

function EventService.Multiplier(stat: string): number
	return EventService.Multipliers()[stat] or 1
end

-- Finds an event by id, preset id / name, or (no text) the only / newest one.
function EventService.Find(text: string?): (any, string?)
	local list = EventService.Active()
	if #list == 0 then
		return nil, "There is no active or scheduled event."
	end
	if text == nil or text == "" then
		if #list == 1 then
			return list[1], nil
		end
		return nil, ("%d events are running - give an id: %s"):format(#list, (function()
			local ids = {}
			for _, e in ipairs(list) do
				table.insert(ids, ("%s (%s)"):format(e.Id, e.Name))
			end
			return table.concat(ids, ", ")
		end)())
	end
	local key = (text :: string):lower()
	if events[key] and (events[key].Status == "active" or events[key].Status == "scheduled") then
		return events[key], nil
	end
	local def = EventService.FindPreset(text)
	for _, e in ipairs(list) do
		if (def and e.Preset == def.Id) or squash(e.Name) == squash(text :: string) then
			return e, nil
		end
	end
	return nil, ("No active event matches \"%s\"."):format(tostring(text))
end

-- ---------------------------------------------------------------------------
-- Persistence (history + global events)
-- ---------------------------------------------------------------------------
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
	for _, source in ipairs({ newer, list }) do
		for _, r in ipairs(source) do
			if type(r) == "table" and r.Id and not seen[r.Id] then
				seen[r.Id] = true
				table.insert(out, r)
			end
		end
	end
	table.sort(out, function(a, b)
		return (a.EndedAt or 0) > (b.EndedAt or 0)
	end)
	while #out > MAX_HISTORY do
		table.remove(out)
	end
	return out
end

local function load()
	if loaded or not store then
		loaded = true
		return
	end
	local ok, data = pcall(function()
		return (store :: DataStore):GetAsync(HISTORY_KEY)
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
		(store :: DataStore):UpdateAsync(HISTORY_KEY, function(old)
			return mergeInto(if type(old) == "table" then old else {}, batch)
		end)
	end)
	if not ok then
		warn("[Sentinel.Events] history save failed: " .. tostring(err))
		for _, r in ipairs(batch) do
			table.insert(pending, r)
		end
	end
end

function EventService.History(limit: number?): { any }
	load()
	local out = {}
	for k = 1, math.min(limit or MAX_HISTORY, #history) do
		out[k] = history[k]
	end
	return out
end

local function record(event: any)
	local entry = {
		Id = event.Id,
		Preset = event.Preset,
		Name = event.Name,
		Color = event.Color,
		Multipliers = event.Multipliers,
		Scope = event.Scope,
		Status = event.Status,
		Author = event.Author,
		StartsAt = event.StartsAt,
		EndsAt = event.EndsAt,
		EndedAt = event.EndedAt or os.time(),
		EndedBy = event.EndedBy,
		Server = event.Origin,
	}
	history = mergeInto(history, { entry })
	if store then
		table.insert(pending, entry)
	end
end

-- Compact form shared by the cross-server message and the "Global" key.
local function payloadOf(event: any): any
	return {
		i = event.Id,
		p = event.Preset,
		n = event.Name,
		c = event.Color,
		m = event.Multipliers,
		st = event.StartsAt,
		e = event.EndsAt,
		an = event.Announce,
		d = event.Author.DisplayName:sub(1, 40),
		u = event.Author.UserId,
		un = event.Author.Name,
		o = event.Origin,
	}
end
EventService.StartPayload = payloadOf

local function updateGlobal(fn: ({ any }) -> { any })
	if not store then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			(store :: DataStore):UpdateAsync(GLOBAL_KEY, function(old)
				local list = if type(old) == "table" then old else {}
				local now = os.time()
				local kept = {}
				for _, p in ipairs(list) do
					if type(p) == "table" and type(p.i) == "string" and ((tonumber(p.e) or 0) == 0 or p.e > now) then
						table.insert(kept, p)
					end
				end
				return fn(kept)
			end)
		end)
		if not ok then
			warn("[Sentinel.Events] global list save failed: " .. tostring(err))
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Client views + multiplier publishing
-- ---------------------------------------------------------------------------
local eventRemote: RemoteEvent? = nil
if live then
	local existing = SentinelShared:FindFirstChild("EventRemote")
	if existing and existing:IsA("RemoteEvent") then
		eventRemote = existing
	else
		local r = Instance.new("RemoteEvent")
		r.Name = "EventRemote"
		r.Parent = SentinelShared
		eventRemote = r
	end
end

function EventService.View(event: any): any
	return {
		Id = event.Id,
		Preset = event.Preset,
		Name = event.Name,
		Description = event.Description,
		Color = event.Color,
		Multipliers = event.Multipliers,
		StartsAt = event.StartsAt,
		EndsAt = event.EndsAt,
		Status = event.Status,
		Scope = event.Scope,
		Origin = event.Origin,
		Author = event.Author,
		Announce = event.Announce,
	}
end

local function views(): { any }
	local out = {}
	for _, e in ipairs(EventService.Active()) do
		table.insert(out, EventService.View(e))
	end
	return out
end

local lastMultipliers = ""
local function publish()
	local m = EventService.Multipliers()
	for _, stat in ipairs(EventService.STATS) do
		SentinelShared:SetAttribute("EventMultiplier_" .. stat, m[stat])
	end
	local key = multiplierText(m)
	if key ~= lastMultipliers then
		lastMultipliers = key
		EventBus.Publish("Events.Changed", m)
	end
	if eventRemote then
		eventRemote:FireAllClients("state", views(), os.time())
	end
end

-- ---------------------------------------------------------------------------
-- Life cycle
-- ---------------------------------------------------------------------------
local AnnouncementService: any = nil
local function announce(event: any, title: string, text: string)
	if not event.Announce or not live then
		return
	end
	AnnouncementService = AnnouncementService or require(script.Parent:WaitForChild("AnnouncementService"))
	pcall(AnnouncementService.Show, {
		Id = ("event-%s-%s"):format(event.Id, title),
		Title = title,
		Text = text,
		Style = "banner",
		Duration = 8,
		Scope = event.Scope,
		Author = event.Author,
		Color = event.Color,
	})
end

local function runHook(event: any, hook: string)
	local def = definitions[event.Preset]
	local fn = def and (def :: any)[hook]
	if type(fn) == "function" then
		local ok, err = pcall(fn, event)
		if not ok then
			warn(("[Sentinel.Events] %s %s failed: %s"):format(event.Preset, hook, tostring(err)))
		end
	end
end

local function describeLength(event: any): string
	if (event.EndsAt or 0) == 0 then
		return "until stopped"
	end
	return "for " .. clock(event.EndsAt - event.StartsAt)
end

function EventService.Describe(event: any): string
	local now = os.time()
	local when
	if event.Status == "scheduled" then
		when = ("starts in %s, %s"):format(clock(event.StartsAt - now), describeLength(event))
	elseif event.Status == "active" then
		when = if (event.EndsAt or 0) > 0 then ("%s left"):format(clock(event.EndsAt - now)) else "until stopped"
	else
		when = event.Status
	end
	local m = multiplierText(event.Multipliers)
	return ("%s %s [%s, %s]%s"):format(event.Id, event.Name, event.Scope, when, if m ~= "" then " - " .. m else "")
end

local function activate(event: any)
	event.Status = "active"
	runHook(event, "OnStart")
	local m = multiplierText(event.Multipliers)
	announce(event, "Event started", ("%s is live %s!%s"):format(event.Name, describeLength(event), if m ~= "" then " " .. m .. "." else ""))
	if event.Origin == serverId() then
		Logger.Write({
			Executor = "SYSTEM",
			ExecutorName = event.Author.Name,
			Command = "event.start",
			Result = "Success",
			Severity = "Info",
			Message = ("Event %s (%s) started %s"):format(event.Name, event.Id, describeLength(event)),
		})
	end
	notify("start", event)
end

local function finish(event: any, status: string, by: string?)
	local wasActive = event.Status == "active"
	event.Status = status
	event.EndedAt = os.time()
	event.EndedBy = by
	if wasActive then
		runHook(event, "OnStop")
		announce(event, "Event ended", ("%s has ended%s."):format(event.Name, if by then " (stopped by " .. by .. ")" else ""))
	end
	record(event)
	notify("end", event)
	-- Forget it after a minute (history keeps it).
	task.delay(60, function()
		if events[event.Id] == event then
			events[event.Id] = nil
		end
	end)
end

local function tick()
	local now = os.time()
	local changed = false
	for _, event in pairs(events) do
		if event.Status == "scheduled" or event.Status == "active" then
			local status = EventService.StatusAt(event, now)
			if status ~= event.Status then
				if status == "active" then
					activate(event)
				elseif status == "ended" then
					if event.Status == "scheduled" then
						activate(event) -- started and ended while we weren't looking
					end
					finish(event, "ended", nil)
				end
				changed = true
			end
		end
	end
	if changed then
		publish()
	end
end

local function newId(): string
	for _ = 1, 20 do
		local id = HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 6):lower()
		if not events[id] then
			return id
		end
	end
	return tostring(os.clock()):gsub("%D", ""):sub(-6)
end

local function addEvent(event: any)
	events[event.Id] = event
	local now = os.time()
	if EventService.StatusAt(event, now) == "active" then
		activate(event)
	end
	publish()
end

function EventService.Create(actor: any, spec: Spec, scope: string): (boolean, string, any)
	if #EventService.Active() >= EventService.MAX_EVENTS then
		return false, ("There are already %d events running or scheduled - stop one first (;stopevent <id>)."):format(EventService.MAX_EVENTS), nil
	end
	local def = definitions[spec.Preset]
	if not def then
		return false, "Unknown event.", nil
	end
	local multipliers: { [string]: number } = table.clone(def.Multipliers)
	for stat, m in pairs(spec.Multipliers or {}) do
		multipliers[stat] = m
	end
	for stat, m in pairs(multipliers) do
		if m == 1 then
			multipliers[stat] = nil
		end
	end
	local name = def.Name
	if spec.Name then
		local TextFilterService = require(script.Parent:WaitForChild("TextFilterService")) :: any
		local filtered = TextFilterService.ForBroadcast(tonumber(actor.UserId) or 0, spec.Name)
		if not filtered or filtered == "" then
			return false, TextFilterService.FAILED_MESSAGE, nil
		end
		name = filtered
	end
	-- (A custom event without multipliers is just a timer + banner; allowed.)
	local now = os.time()
	local startsAt = now + spec.Delay
	local event = {
		Id = newId(),
		Preset = def.Id,
		Name = name,
		Description = def.Description,
		Color = def.Color,
		Multipliers = multipliers,
		Scope = if scope == "global" then "global" else "server",
		Origin = serverId(),
		Author = {
			UserId = tonumber(actor.UserId) or 0,
			Name = tostring(actor.Name or "Sentinel"),
			DisplayName = tostring(actor.DisplayName or actor.Name or "Sentinel"),
		},
		CreatedAt = now,
		StartsAt = startsAt,
		EndsAt = if spec.Duration > 0 then startsAt + spec.Duration else 0,
		Announce = spec.Announce,
		Status = "scheduled", -- activate() flips it and runs OnStart
	}
	if spec.Delay > 0 then
		events[event.Id] = event
		announce(event, "Event scheduled", ("%s starts in %s (%s)."):format(event.Name, clock(spec.Delay), describeLength(event)))
		notify("schedule", event)
		publish()
	else
		addEvent(event)
	end
	if event.Scope == "global" then
		local p = payloadOf(event)
		updateGlobal(function(list)
			table.insert(list, p)
			return list
		end)
	end
	local verb = if spec.Delay > 0 then ("scheduled in %s"):format(clock(spec.Delay)) else "started"
	return true, ("Event %s (%s) %s, %s."):format(event.Name, event.Id, verb, describeLength(event)), event
end

-- Ends locally (and tells the other servers for a global event).
local function stopLocal(event: any, by: string)
	local status = if event.Status == "scheduled" then "cancelled" else "stopped"
	finish(event, status, by)
	publish()
end

function EventService.Stop(actor: any, text: string?): (boolean, string, any)
	local event, err = EventService.Find(text)
	if not event then
		return false, err :: string, nil
	end
	local by = tostring(actor and actor.Name or "Sentinel")
	local wasScheduled = event.Status == "scheduled"
	stopLocal(event, by)
	if event.Scope == "global" then
		local id = event.Id
		updateGlobal(function(list)
			local kept = {}
			for _, p in ipairs(list) do
				if p.i ~= id then
					table.insert(kept, p)
				end
			end
			return kept
		end)
		if crossServer then
			crossServer.Send("evx", { i = id, by = by:sub(1, 40) }, {
				Actor = if typeof(actor) == "Instance" then crossServer.ActorOf(actor) else nil,
				Label = "stop event",
				History = true,
			})
		end
	end
	return true, ("Event %s (%s) %s."):format(event.Name, event.Id, if wasScheduled then "cancelled" else "stopped"), event
end

-- An event from another server / the Global key.
local function fromPayload(d: any, origin: string?): any
	if type(d) ~= "table" or type(d.i) ~= "string" or #d.i > 12 or type(d.n) ~= "string" then
		return nil
	end
	local def = definitions[tostring(d.p)] or definitions.custom
	local multipliers = {}
	if type(d.m) == "table" then
		for _, stat in ipairs(EventService.STATS) do
			local m = tonumber(d.m[stat])
			if m and m >= 0.1 and m <= EventService.MAX_MULTIPLIER then
				multipliers[stat] = m
			end
		end
	end
	return {
		Id = d.i,
		Preset = def.Id,
		Name = d.n:sub(1, EventService.MAX_NAME), -- filtered by the origin
		Description = def.Description,
		Color = if type(d.c) == "string" and #d.c == 6 then d.c else def.Color,
		Multipliers = multipliers,
		Scope = "global",
		Origin = origin or tostring(d.o or "?"),
		Author = {
			UserId = tonumber(d.u) or 0,
			Name = tostring(d.un or d.d or "Staff"),
			DisplayName = tostring(d.d or "Staff"),
		},
		CreatedAt = tonumber(d.st) or os.time(),
		StartsAt = tonumber(d.st) or os.time(),
		EndsAt = tonumber(d.e) or 0,
		Announce = d.an ~= false,
		Status = "scheduled",
	}
end

function EventService.Snapshot(): any
	local presets = {}
	for _, def in ipairs(EventService.Presets()) do
		table.insert(presets, {
			Id = def.Id,
			Name = def.Name,
			Description = def.Description,
			Color = def.Color,
			Multipliers = def.Multipliers,
			DefaultDuration = def.DefaultDuration or EventService.DEFAULT_DURATION,
		})
	end
	return {
		Active = views(),
		History = EventService.History(20),
		Presets = presets,
		Multipliers = EventService.Multipliers(),
		Now = os.time(),
	}
end

-- Names for CrossServerService.LocalInfo (server info card).
function EventService.Summaries(): { string }
	local out = {}
	for _, e in ipairs(EventService.Active()) do
		table.insert(out, if e.Status == "scheduled" then e.Name .. " (scheduled)" else e.Name)
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Wiring (running game only)
-- ---------------------------------------------------------------------------
if live then
	task.spawn(load)
	task.spawn(function()
		while true do
			task.wait(10)
			flush()
		end
	end)
	game:BindToClose(function()
		-- This server's own events die with it: record them. Global events
		-- go on in the other servers (and in the Global list).
		for _, event in pairs(events) do
			if event.Scope ~= "global" and (event.Status == "active" or event.Status == "scheduled") then
				event.Status = if event.Status == "scheduled" then "cancelled" else "stopped"
				event.EndedAt = os.time()
				event.EndedBy = "server closed"
				record(event)
			end
		end
		flush()
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			tick()
		end
	end)

	local okEco, Economy = pcall(require, script.Parent:WaitForChild("EconomyService"))
	if okEco then
		(Economy :: any).SetMultiplierProvider(EventService.Multiplier)
	end

	local okCs, cs = pcall(require, script.Parent:WaitForChild("CrossServerService"))
	if okCs then
		crossServer = cs
		if cs.SetEventProvider then
			cs.SetEventProvider(EventService.Summaries)
		end

		cs.Handle("evs", function(d: any, envelope: any)
			if envelope.f == cs.ServerId then
				return true, #Players:GetPlayers(), nil
			end
			local event = fromPayload(d, envelope.f)
			if not event then
				return false, 0, "bad event"
			end
			if not events[event.Id] then
				if EventService.StatusAt(event, os.time()) == "ended" then
					return true, 0, nil
				end
				if event.StartsAt > os.time() then
					events[event.Id] = event
					notify("schedule", event)
					publish()
				else
					addEvent(event)
				end
			end
			return true, #Players:GetPlayers(), nil
		end)

		cs.Handle("evx", function(d: any, envelope: any)
			local event = if type(d) == "table" and type(d.i) == "string" then events[d.i] else nil
			if event and envelope.f ~= cs.ServerId and (event.Status == "active" or event.Status == "scheduled") then
				stopLocal(event, ("%s @%s"):format(tostring(d.by or "Staff"), cs.ShortId(envelope.f)))
				return true, #Players:GetPlayers(), nil
			end
			return true, 0, nil
		end)
	else
		warn("[Sentinel.Events] CrossServerService unavailable - global events are off: " .. tostring(cs))
	end

	-- Join global events that started before this server.
	task.spawn(function()
		if not store then
			return
		end
		local ok, list = pcall(function()
			return (store :: DataStore):GetAsync(GLOBAL_KEY)
		end)
		if not ok or type(list) ~= "table" then
			return
		end
		for _, p in ipairs(list) do
			local event = fromPayload(p, nil)
			if event and not events[event.Id] and EventService.StatusAt(event, os.time()) ~= "ended" then
				event.Announce = false -- they're joining mid-event; the bar shows it
				addEvent(event)
				event.Announce = p.an ~= false
			end
		end
	end)

	-- Players joining get the event bar.
	Players.PlayerAdded:Connect(function(player: Player)
		task.wait(3)
		if player.Parent and eventRemote then
			eventRemote:FireClient(player, "state", views(), os.time())
		end
	end)
	publish()
end

return EventService
