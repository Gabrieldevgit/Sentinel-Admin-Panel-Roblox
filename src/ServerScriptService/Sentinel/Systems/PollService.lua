--!strict
--[[
	PollService.lua (W23 - Polls)

	Purpose:
		Live polls: staff create a question with 2-8 options, players vote
		from a card on their screen (or ;vote), results update live, the poll
		ends on its timer or by hand (;endpoll) or is cancelled (;cancelpoll),
		the results are announced and kept in a history.

	Scopes:
		server   this server only                       (;poll)
		global   every server (the creating server is    (;gpoll)
		         the poll's "origin" and owns its life)

	Options (leading key=value words, ParseSpec):
		time=<10s-1h>       timer (default 60 s; time=0 / time=none = until ended by hand)
		change=on|off       players may change their vote (default on)
		results=live|end    show results while voting, or only at the end (default live)
		announce=on|off     banner with the results when it ends (default on)
	Then the question, then the options separated by "|":
		;poll time=2m Best map? | Desert | Forest | City
		;poll Should we play another round?        (no options = Yes | No)

	Cross-server protocol (CrossServerService kinds, handled here):
		polls    { i, q, o, e, ch, lv, an, d }  a global poll started (origin)
		pollc    { i, c }                       one server's vote counts (Quiet,
		                                        every 2 s while they change)
		pollz    { i }                          voting closed: send final counts
		polle    { i, s, c, by }                final result (origin), s = ended|cancelled
		pollreq  { i, a, by }                   end / cancel asked on another server
		Each server only stores its own players' votes; the shown totals are
		this server's counts plus the latest counts of every other server.
		A player who moves to another server during a global poll could vote
		once per server (votes are not shared between servers).

	History: newest first, at most 100, DataStore Sentinel_Polls_v1 key
	"History" (flushed every 10 s and on close; only the origin records).

	Client remote PollRemote (RemoteEvent):
		server -> client  ("state", view) / ("remove", id)
		client -> server  ("vote", id, index) / ("sync")
	view = { Id, Question, Options, Counts?, Total?, MyVote, EndsAt, Status,
	         Scope, Author, AllowChange, ShowLive, Winners? }
	(Counts are hidden from players while voting when results=end; staff
	always see them.)

	Public API:
		PollService.ParseSpec(words) -> (spec?, error?)
		PollService.Create(actor, spec, scope) -> (ok, message, poll?)
		PollService.Vote(player, idOrNil, index) -> (ok, message)
		PollService.End(actor, idOrNil, cancel?) -> (ok, message)
		PollService.Active() -> { poll }   / Get(id) / Latest()
		PollService.History(limit?) -> { record }
		PollService.Snapshot(viewer) -> { Active = {view}, History = {record} }
		PollService.ResultText(poll) -> string
		Pure helpers (Poll.spec): ApplyVote, Totals, Sum
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local Logger = require(Core:WaitForChild("Logger"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local PollService = {}

PollService.MIN_OPTIONS = 2
PollService.MAX_OPTIONS = 8
PollService.MAX_QUESTION = 120
PollService.MAX_OPTION = 40
PollService.DEFAULT_DURATION = 60
PollService.MIN_DURATION = 10
PollService.MAX_DURATION = 3600
PollService.MAX_ACTIVE = 3

local MAX_HISTORY = 100
local STORE_NAME = "Sentinel_Polls_v1"
local STORE_KEY = "History"
local SYNC_INTERVAL = 2
local CLOSE_WAIT = 3 -- seconds the origin waits for final counts of a global poll

local live = RunService:IsRunning() and RunService:IsServer()

export type Spec = {
	Question: string,
	Options: { string },
	Duration: number, -- 0 = no timer
	AllowChange: boolean,
	ShowLive: boolean,
	Announce: boolean,
}

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested in Tests/Poll.spec)
-- ---------------------------------------------------------------------------
local function trim(s: string): string
	return (s:gsub("%s+", " "):match("^%s*(.-)%s*$")) :: string
end

local function parseDuration(value: string): number?
	local v = value:lower()
	if v == "0" or v == "none" or v == "off" or v == "manual" then
		return 0
	end
	local n, unit = v:match("^(%d+%.?%d*)([smh]?)$")
	local num = tonumber(n)
	if not num then
		return nil
	end
	local mult = if unit == "m" then 60 elseif unit == "h" then 3600 else 1
	return math.floor(num * mult)
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

-- words = the command's arguments. Returns the spec or an error message.
function PollService.ParseSpec(words: { string }): (Spec?, string?)
	local spec: Spec = {
		Question = "",
		Options = {},
		Duration = PollService.DEFAULT_DURATION,
		AllowChange = true,
		ShowLive = true,
		Announce = true,
	}
	local i = 1
	while i <= #words do
		local key, value = words[i]:match("^(%a+)=(.+)$")
		if not key then
			break
		end
		key = key:lower()
		if key == "time" or key == "duration" or key == "timer" then
			local seconds = parseDuration(value)
			if not seconds or (seconds ~= 0 and (seconds < PollService.MIN_DURATION or seconds > PollService.MAX_DURATION)) then
				return nil, "time must be 10s-1h (e.g. time=90, time=2m) or time=none"
			end
			spec.Duration = seconds
		elseif key == "change" then
			local b = onOff(value)
			if b == nil then
				return nil, "change must be on or off"
			end
			spec.AllowChange = b
		elseif key == "results" then
			local v = value:lower()
			if v ~= "live" and v ~= "end" then
				return nil, "results must be live or end"
			end
			spec.ShowLive = v == "live"
		elseif key == "announce" then
			local b = onOff(value)
			if b == nil then
				return nil, "announce must be on or off"
			end
			spec.Announce = b
		else
			break -- not an option: the question starts here
		end
		i += 1
	end
	local rest = table.concat(words, " ", i)
	local parts = string.split(rest, "|")
	local question = trim(parts[1] or "")
	if question == "" then
		return nil, "Type a question (options after it, separated by |)."
	end
	if #question > PollService.MAX_QUESTION then
		return nil, ("The question can be at most %d characters."):format(PollService.MAX_QUESTION)
	end
	spec.Question = question
	local seen = {}
	for k = 2, #parts do
		local option = trim(parts[k])
		if option ~= "" then
			if #option > PollService.MAX_OPTION then
				return nil, ("Options can be at most %d characters (\"%s...\")."):format(PollService.MAX_OPTION, option:sub(1, 12))
			end
			if seen[option:lower()] then
				return nil, ("Option \"%s\" is listed twice."):format(option)
			end
			seen[option:lower()] = true
			table.insert(spec.Options, option)
		end
	end
	if #spec.Options == 0 then
		spec.Options = { "Yes", "No" }
	end
	if #spec.Options < PollService.MIN_OPTIONS then
		return nil, "A poll needs at least 2 options (separate them with |)."
	end
	if #spec.Options > PollService.MAX_OPTIONS then
		return nil, ("A poll can have at most %d options."):format(PollService.MAX_OPTIONS)
	end
	return spec, nil
end

-- Records a vote in `votes` / `counts` (mutated). Returns (ok, message, changed).
function PollService.ApplyVote(votes: { [number]: number }, counts: { number }, userId: number, index: number, allowChange: boolean): (boolean, string, boolean)
	if index < 1 or index > #counts or index % 1 ~= 0 then
		return false, ("Pick an option from 1 to %d."):format(#counts), false
	end
	local previous = votes[userId]
	if previous == index then
		return true, "You already voted for that option.", false
	end
	if previous and not allowChange then
		return false, "You already voted in this poll (changing your vote is off).", false
	end
	if previous then
		counts[previous] = math.max(0, counts[previous] - 1)
	end
	votes[userId] = index
	counts[index] += 1
	return true, if previous then "Vote changed." else "Vote counted.", true
end

-- Adds count lists element-wise (missing / bad entries count as 0).
function PollService.Sum(n: number, lists: { any }): { number }
	local out = table.create(n, 0)
	for _, list in ipairs(lists) do
		if type(list) == "table" then
			for k = 1, n do
				local v = tonumber(list[k])
				if v and v > 0 then
					out[k] += math.floor(v)
				end
			end
		end
	end
	return out
end

-- (total, winner indexes) - several winners on a tie, none with no votes.
function PollService.Totals(counts: { number }): (number, { number })
	local total, best, winners = 0, 0, {}
	for k, v in ipairs(counts) do
		total += v
		if v > best then
			best = v
			winners = { k }
		elseif v == best and v > 0 then
			table.insert(winners, k)
		end
	end
	return total, winners
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
type Poll = {
	Id: string,
	Question: string,
	Options: { string },
	Scope: string,
	Origin: string,
	IsOrigin: boolean,
	Author: { UserId: number, Name: string, DisplayName: string },
	StartedAt: number,
	EndsAt: number, -- 0 = no timer
	AllowChange: boolean,
	ShowLive: boolean,
	Announce: boolean,
	Votes: { [number]: number },
	Local: { number },
	Remote: { [string]: { number } },
	Status: string, -- active | closing | ended | cancelled
	Final: { number }?,
	EndedAt: number?,
	EndedBy: string?,
	Dirty: boolean,
	SyncedAt: number,
}

local polls: { [string]: Poll } = {}
local order: { string } = {} -- active poll ids, oldest first
local listeners: { (string, any) -> () } = {}

local crossServer: any = nil -- CrossServerService (live only)
local function serverId(): string
	return if crossServer then crossServer.ServerId else Logger.GetServerId()
end

function PollService.OnChanged(fn: (string, any) -> ())
	table.insert(listeners, fn)
end

local function counts(poll: Poll): { number }
	if poll.Final then
		return poll.Final
	end
	local lists: { any } = { poll.Local }
	for _, c in pairs(poll.Remote) do
		table.insert(lists, c)
	end
	return PollService.Sum(#poll.Options, lists)
end
PollService.Counts = counts

function PollService.Get(id: string): Poll?
	return polls[id:lower()]
end

function PollService.Active(): { Poll }
	local out = {}
	for _, id in ipairs(order) do
		local p = polls[id]
		if p and (p.Status == "active" or p.Status == "closing") then
			table.insert(out, p)
		end
	end
	return out
end

-- The newest active poll (what ;vote / ;endpoll use without an id).
function PollService.Latest(): Poll?
	local active = PollService.Active()
	return active[#active]
end

local function find(id: string?): (Poll?, string?)
	if id and id ~= "" then
		local p = polls[id:lower():gsub("^#", "")]
		if not p then
			return nil, ("No poll with id %s."):format(id)
		end
		return p, nil
	end
	local p = PollService.Latest()
	if not p then
		return nil, "There is no active poll."
	end
	return p, nil
end
PollService.Find = find

-- ---------------------------------------------------------------------------
-- History
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
		warn("[Sentinel.Polls] save failed: " .. tostring(err))
		for _, r in ipairs(batch) do
			table.insert(pending, r)
		end
	end
end

function PollService.History(limit: number?): { any }
	load()
	local out = {}
	for k = 1, math.min(limit or MAX_HISTORY, #history) do
		out[k] = history[k]
	end
	return out
end

local function record(poll: Poll)
	local c = counts(poll)
	local total, winners = PollService.Totals(c)
	local entry = {
		Id = poll.Id,
		Question = poll.Question,
		Options = poll.Options,
		Counts = c,
		Total = total,
		Winners = winners,
		Scope = poll.Scope,
		Status = poll.Status,
		Author = poll.Author,
		StartedAt = poll.StartedAt,
		EndedAt = poll.EndedAt or os.time(),
		EndedBy = poll.EndedBy,
		Server = poll.Origin,
	}
	history = mergeInto(history, { entry })
	if store then
		table.insert(pending, entry)
	end
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
-- Client views
-- ---------------------------------------------------------------------------
local pollRemote: RemoteEvent? = nil
if live then
	local existing = SentinelShared:FindFirstChild("PollRemote")
	if existing and existing:IsA("RemoteEvent") then
		pollRemote = existing
	else
		local r = Instance.new("RemoteEvent")
		r.Name = "PollRemote"
		r.Parent = SentinelShared
		pollRemote = r
	end
end

local function isStaff(player: Player): boolean
	return PermissionSystem.Has(player, "panel.open")
end

function PollService.View(poll: Poll, viewer: Player?): any
	local finished = poll.Status == "ended" or poll.Status == "cancelled"
	local showCounts = poll.ShowLive or finished or (viewer ~= nil and isStaff(viewer))
	local c = counts(poll)
	local total, winners = PollService.Totals(c)
	return {
		Id = poll.Id,
		Question = poll.Question,
		Options = poll.Options,
		Counts = if showCounts then c else nil,
		Total = total, -- the number of votes is always shown
		Winners = if finished and poll.Status == "ended" then winners else nil,
		MyVote = if viewer then poll.Votes[viewer.UserId] else nil,
		EndsAt = poll.EndsAt,
		StartedAt = poll.StartedAt,
		Status = poll.Status,
		Scope = poll.Scope,
		Author = poll.Author,
		AllowChange = poll.AllowChange,
		ShowLive = poll.ShowLive,
		EndedBy = poll.EndedBy,
		Origin = if crossServer then crossServer.ShortId(poll.Origin) else poll.Origin,
	}
end

local pushQueued: { [string]: boolean } = {}
local function push(poll: Poll, immediate: boolean?)
	for _, fn in ipairs(listeners) do
		task.spawn(fn, "changed", poll)
	end
	if not pollRemote then
		return
	end
	local function send()
		pushQueued[poll.Id] = nil
		for _, p in ipairs(Players:GetPlayers()) do
			(pollRemote :: RemoteEvent):FireClient(p, "state", PollService.View(poll, p))
		end
	end
	if immediate then
		send()
	elseif not pushQueued[poll.Id] then
		-- Votes come in bursts: one update per poll every 0.5 s at most.
		pushQueued[poll.Id] = true
		task.delay(0.5, send)
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function newId(): string
	local id
	repeat
		id = HttpService:GenerateGUID(false):sub(1, 6):lower()
	until not polls[id]
	return id
end

-- plain = no winner marks / vote counts (the results banner).
local function resultLines(poll: Poll, plain: boolean?): string
	local c = counts(poll)
	local total, winners = PollService.Totals(c)
	local parts = {}
	for k, option in ipairs(poll.Options) do
		local pct = if total > 0 then math.floor(c[k] / total * 100 + 0.5) else 0
		if plain then
			table.insert(parts, ("%s %d%%"):format(option, pct))
		else
			table.insert(parts, ("%s%s %d%% (%d)"):format(if table.find(winners, k) then "* " else "", option, pct, c[k]))
		end
	end
	return table.concat(parts, if plain then "  -  " else ", ")
end

function PollService.ResultText(poll: Poll): string
	local total = PollService.Totals(counts(poll))
	return ("%s - %s. %d vote%s."):format(poll.Question, resultLines(poll), total, if total == 1 then "" else "s")
end

local function finish(poll: Poll, status: string, by: string?, final: { number }?)
	if poll.Status == "ended" or poll.Status == "cancelled" then
		return
	end
	poll.Final = final or counts(poll)
	poll.Status = status
	poll.EndedAt = os.time()
	poll.EndedBy = by
	local index = table.find(order, poll.Id)
	if index then
		table.remove(order, index)
	end
	if poll.IsOrigin then
		record(poll)
		Logger.Write({
			Executor = "SYSTEM",
			ExecutorName = by or "Poll timer",
			Command = "poll." .. status,
			Result = "Success",
			Severity = "Info",
			Message = PollService.ResultText(poll):sub(1, 200),
		})
	end
	push(poll, true)
	-- Results banner (every server shows it for its own players).
	if status == "ended" and poll.Announce then
		local ok, AnnouncementService: any = pcall(require, script.Parent:WaitForChild("AnnouncementService"))
		if ok then
			local total, winners = PollService.Totals(poll.Final :: { number })
			local names = {}
			for _, w in ipairs(winners) do
				table.insert(names, poll.Options[w])
			end
			local winnerText = if #names == 0
				then "No votes."
				elseif #names == 1 then ("Winner: %s."):format(names[1])
				else ("Tie: %s."):format(table.concat(names, ", "))
			AnnouncementService.Show({
				Id = "poll-" .. poll.Id,
				Title = "Poll results",
				Text = ("%s\n%s  %s  (%d vote%s)"):format(poll.Question, winnerText, resultLines(poll, true), total, if total == 1 then "" else "s"),
				Style = "banner",
				Duration = 10,
				Scope = poll.Scope,
				Author = poll.Author,
				Color = "A78BFA",
			})
		end
	end
	-- Forget finished polls after a minute (history keeps them).
	task.delay(60, function()
		if polls[poll.Id] == poll then
			polls[poll.Id] = nil
			if pollRemote then
				pollRemote:FireAllClients("remove", poll.Id)
			end
		end
	end)
end

local function sendCounts(poll: Poll)
	if poll.Scope ~= "global" or not crossServer then
		return
	end
	poll.Dirty = false
	poll.SyncedAt = os.clock()
	crossServer.Send("pollc", { i = poll.Id, c = poll.Local }, { Quiet = true })
end

-- Origin: close voting everywhere, wait for the last counts, then publish
-- the final result.
local function originEnd(poll: Poll, status: string, by: string?)
	if poll.Status ~= "active" then
		return
	end
	if poll.Scope ~= "global" or not crossServer or status == "cancelled" then
		finish(poll, status, by)
		if poll.Scope == "global" and crossServer then
			crossServer.Send("polle", { i = poll.Id, s = status, c = poll.Final, by = by }, { NoAck = true })
		end
		return
	end
	poll.Status = "closing"
	push(poll, true)
	crossServer.Send("pollz", { i = poll.Id }, { Quiet = true })
	task.delay(CLOSE_WAIT, function()
		finish(poll, status, by)
		crossServer.Send("polle", { i = poll.Id, s = status, c = poll.Final, by = by }, { NoAck = true })
	end)
end

local function startTimer(poll: Poll)
	if poll.EndsAt <= 0 then
		return
	end
	task.delay(math.max(0, poll.EndsAt - os.time()), function()
		if poll.Status ~= "active" then
			return
		end
		if poll.IsOrigin then
			originEnd(poll, "ended", nil)
		else
			-- The origin should end it; if it went away, close it here after
			-- a grace period with the counts this server knows.
			task.delay(CLOSE_WAIT + 5, function()
				if poll.Status == "active" or poll.Status == "closing" then
					finish(poll, "ended", "timer (origin server gone)")
				end
			end)
		end
	end)
end

local function addPoll(poll: Poll)
	polls[poll.Id] = poll
	table.insert(order, poll.Id)
	startTimer(poll)
	push(poll, true)
end

function PollService.Create(actor: any, spec: Spec, scope: string): (boolean, string, Poll?)
	if #PollService.Active() >= PollService.MAX_ACTIVE then
		return false, ("There are already %d active polls - end one first (;endpoll <id>)."):format(PollService.MAX_ACTIVE), nil
	end
	local TextFilterService = require(script.Parent:WaitForChild("TextFilterService")) :: any
	local userId = tonumber(actor.UserId) or 0
	-- Filter question and options in one call (fewer requests), split back after.
	local joined = spec.Question .. "\n" .. table.concat(spec.Options, "\n")
	local filtered = TextFilterService.ForBroadcast(userId, joined)
	if not filtered then
		return false, TextFilterService.FAILED_MESSAGE, nil
	end
	local lines = string.split(filtered, "\n")
	if #lines ~= #spec.Options + 1 then
		-- Shouldn't happen; filter separately rather than show unfiltered text.
		lines = { TextFilterService.ForBroadcast(userId, spec.Question) or "" }
		for _, option in ipairs(spec.Options) do
			table.insert(lines, TextFilterService.ForBroadcast(userId, option) or "")
		end
	end
	local options = {}
	for k = 1, #spec.Options do
		options[k] = lines[k + 1]
		if options[k] == "" then
			return false, TextFilterService.FAILED_MESSAGE, nil
		end
	end
	local poll: Poll = {
		Id = newId(),
		Question = lines[1],
		Options = options,
		Scope = if scope == "global" then "global" else "server",
		Origin = serverId(),
		IsOrigin = true,
		Author = {
			UserId = userId,
			Name = tostring(actor.Name or "Sentinel"),
			DisplayName = tostring(actor.DisplayName or actor.Name or "Sentinel"),
		},
		StartedAt = os.time(),
		EndsAt = if spec.Duration > 0 then os.time() + spec.Duration else 0,
		AllowChange = spec.AllowChange,
		ShowLive = spec.ShowLive,
		Announce = spec.Announce,
		Votes = {},
		Local = table.create(#options, 0),
		Remote = {},
		Status = "active",
		Dirty = false,
		SyncedAt = 0,
	}
	addPoll(poll)
	return true, ("Poll %s started%s."):format(poll.Id, if poll.EndsAt > 0 then (" for %ds"):format(spec.Duration) else " (until ended)"), poll
end

-- The payload a global poll is announced with (fits MessagingService's 1 kB:
-- 120 + 8 x 40 characters of text).
function PollService.StartPayload(poll: Poll): any
	return {
		i = poll.Id,
		q = poll.Question,
		o = poll.Options,
		e = poll.EndsAt,
		st = poll.StartedAt,
		ch = poll.AllowChange,
		lv = poll.ShowLive,
		an = poll.Announce,
		d = poll.Author.DisplayName:sub(1, 40),
	}
end

function PollService.Vote(player: Player, id: string?, index: number): (boolean, string)
	local poll, err = find(id)
	if not poll then
		return false, err :: string
	end
	if poll.Status ~= "active" then
		return false, "Voting in this poll has closed."
	end
	local ok, message, changed = PollService.ApplyVote(poll.Votes, poll.Local, player.UserId, index, poll.AllowChange)
	if changed then
		poll.Dirty = true
		push(poll)
		if poll.Scope == "global" and os.clock() - poll.SyncedAt >= SYNC_INTERVAL then
			sendCounts(poll)
		end
	end
	if ok and changed then
		message ..= (" (%s)"):format(poll.Options[index])
	end
	return ok, message
end

-- End (or cancel) a poll. A global poll started on another server is ended
-- by its origin: this server asks it to.
function PollService.End(actor: any, id: string?, cancel: boolean?): (boolean, string)
	local poll, err = find(id)
	if not poll then
		return false, err :: string
	end
	if poll.Status ~= "active" then
		return false, ("Poll %s is already %s."):format(poll.Id, poll.Status)
	end
	local status = if cancel then "cancelled" else "ended"
	local by = tostring(actor.Name or "Staff")
	if poll.IsOrigin then
		originEnd(poll, status, by)
		return true, if cancel then ("Poll %s cancelled."):format(poll.Id) else ("Poll %s ended: %s"):format(poll.Id, resultLines(poll))
	end
	if not crossServer then
		return false, "This poll belongs to another server."
	end
	crossServer.Send("pollreq", { i = poll.Id, a = if cancel then "cancel" else "end", by = by }, { To = poll.Origin, Quiet = true })
	return true, ("Asked the server that started poll %s to %s it."):format(poll.Id, if cancel then "cancel" else "end")
end

-- Panel data: active polls (as the viewer sees them) + history.
function PollService.Snapshot(viewer: Player): any
	local active = {}
	for _, p in ipairs(PollService.Active()) do
		table.insert(active, PollService.View(p, viewer))
	end
	return { Active = active, History = PollService.History(30) }
end

-- Summaries for CrossServerService.LocalInfo (server info card).
local function summaries(): { any }
	local out = {}
	for _, p in ipairs(PollService.Active()) do
		local total = PollService.Totals(counts(p))
		table.insert(out, { Id = p.Id, Question = p.Question, Scope = p.Scope, Votes = total, EndsAt = p.EndsAt })
	end
	return out
end
PollService.Summaries = summaries

-- ---------------------------------------------------------------------------
-- Wiring (running game only)
-- ---------------------------------------------------------------------------
if live then
	local okCs, cs = pcall(require, script.Parent:WaitForChild("CrossServerService"))
	if okCs then
		crossServer = cs
		cs.SetPollProvider(summaries)

		cs.Handle("polls", function(d: any, envelope: any)
			if envelope.f == cs.ServerId then
				return true, #Players:GetPlayers(), nil -- the origin already has it
			end
			if type(d) ~= "table" or type(d.i) ~= "string" or type(d.q) ~= "string" or type(d.o) ~= "table" then
				return false, 0, "bad poll"
			end
			if polls[d.i] then
				return true, 0, nil
			end
			local options = {}
			for k = 1, math.min(#d.o, PollService.MAX_OPTIONS) do
				options[k] = tostring(d.o[k]):sub(1, PollService.MAX_OPTION)
			end
			if #options < PollService.MIN_OPTIONS then
				return false, 0, "bad poll"
			end
			local actor = if type(envelope.a) == "table" then envelope.a else {}
			addPoll({
				Id = d.i,
				Question = d.q:sub(1, PollService.MAX_QUESTION), -- filtered by the origin
				Options = options,
				Scope = "global",
				Origin = envelope.f,
				IsOrigin = false,
				Author = {
					UserId = tonumber(actor.u) or 0,
					Name = tostring(actor.n or "Staff"),
					DisplayName = if type(d.d) == "string" then d.d else tostring(actor.n or "Staff"),
				},
				StartedAt = tonumber(d.st) or os.time(),
				EndsAt = tonumber(d.e) or 0,
				AllowChange = d.ch ~= false,
				ShowLive = d.lv ~= false,
				Announce = d.an ~= false,
				Votes = {},
				Local = table.create(#options, 0),
				Remote = {},
				Status = "active",
				Dirty = false,
				SyncedAt = 0,
			})
			return true, #Players:GetPlayers(), nil
		end)

		cs.Handle("pollc", function(d: any, envelope: any)
			local poll = if type(d) == "table" and type(d.i) == "string" then polls[d.i] else nil
			if not poll or envelope.f == cs.ServerId or type(d.c) ~= "table" or poll.Final then
				return true, 0, nil
			end
			poll.Remote[envelope.f] = PollService.Sum(#poll.Options, { d.c })
			push(poll)
			return true, 0, nil
		end)

		cs.Handle("pollz", function(d: any, envelope: any)
			local poll = if type(d) == "table" and type(d.i) == "string" then polls[d.i] else nil
			if poll and envelope.f ~= cs.ServerId and poll.Status == "active" then
				poll.Status = "closing"
				push(poll, true)
				-- Final counts straight to the origin.
				cs.Send("pollc", { i = poll.Id, c = poll.Local }, { To = poll.Origin, Quiet = true })
			end
			return true, 0, nil
		end)

		cs.Handle("polle", function(d: any, envelope: any)
			local poll = if type(d) == "table" and type(d.i) == "string" then polls[d.i] else nil
			if poll and envelope.f ~= cs.ServerId and poll.Status ~= "ended" and poll.Status ~= "cancelled" then
				local final = if type(d.c) == "table" then PollService.Sum(#poll.Options, { d.c }) else nil
				finish(poll, if d.s == "cancelled" then "cancelled" else "ended", if type(d.by) == "string" then d.by else nil, final)
			end
			return true, 0, nil
		end)

		cs.Handle("pollreq", function(d: any, envelope: any)
			local poll = if type(d) == "table" and type(d.i) == "string" then polls[d.i] else nil
			if not poll or not poll.IsOrigin or poll.Status ~= "active" then
				return true, 0, nil
			end
			-- The asking server checked the staff member's permission.
			originEnd(poll, if d.a == "cancel" then "cancelled" else "ended", ("%s @%s"):format(tostring(d.by or "Staff"), cs.ShortId(envelope.f)))
			return true, 0, nil
		end)

		-- Votes that arrived since the last sync.
		task.spawn(function()
			while true do
				task.wait(SYNC_INTERVAL)
				for _, poll in pairs(polls) do
					if poll.Dirty and poll.Scope == "global" and poll.Status == "active" then
						sendCounts(poll)
					end
				end
			end
		end)
	else
		warn("[Sentinel.Polls] CrossServerService unavailable - global polls are off: " .. tostring(cs))
	end

	local limiter = RateLimiter.new("PollRemote", 6, 2)
	local remote = pollRemote :: RemoteEvent
	remote.OnServerEvent:Connect(function(player: Player, action: any, id: any, index: any)
		if not limiter:Allow(player) then
			return
		end
		if action == "vote" and type(id) == "string" and #id <= 12 and type(index) == "number" then
			local ok, message = PollService.Vote(player, id, math.floor(index))
			remote:FireClient(player, "result", id, ok, message)
		elseif action == "sync" then
			for _, p in pairs(polls) do
				remote:FireClient(player, "state", PollService.View(p, player))
			end
		end
	end)
	-- Players joining mid-poll get the active polls.
	Players.PlayerAdded:Connect(function(player: Player)
		task.wait(3)
		for _, p in ipairs(PollService.Active()) do
			if player.Parent then
				remote:FireClient(player, "state", PollService.View(p, player))
			end
		end
	end)
end

return PollService
