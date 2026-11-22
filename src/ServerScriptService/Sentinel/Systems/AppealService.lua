--!strict
--[[
	AppealService.lua (W14)

	Purpose:
		Punishment appeals. A punished player appeals one of their cases:
		  - ban: from the ban screen they see on join (the server keeps them
		    for AppealWindow seconds with no character, then disconnects them)
		  - mute / jail (active) and warnings (last 30 days): from the in-game
		    appeal form (;appeal)
		Staff review the queue, discuss in internal notes, and accept (the
		punishment is lifted and the case revoked) or reject (the player can
		appeal that case again after AppealCooldownDays).
		The player is told the decision right away when online, otherwise
		the next time they join.

	Status: Pending, Accepted, Rejected.

	Storage (DataStore Sentinel_Appeals_v1):
		Counter          next appeal number (UpdateAsync)
		Appeal_<id>      full appeal incl. notes
		Index            newest <= 500 summaries
		User_<userId>    that player's appeals { Id, Key, Status, DecidedAt, Seen }
		Queued, flushed every 10 s and on close; memory-only outside a game.

	Lifting the punishment lives in the command modules (Systems can't
	require Commands): Commands/Moderation/Appeals.lua installs them with
	AppealService.SetLifters({ ban = fn, mute = fn, warn = fn, jail = fn }).

	Public API:
		AppealService.Appealable(userId, name?) -> { { Key, Type, CaseId?, Reason, Duration, CreatedAt, ExpiresAt, Blocked? } }
		AppealService.Submit(player|{UserId,Name}, key, text) -> (appeal?, err?)
		AppealService.Get(id) / Search(filter, cursor, limit) / ParseQuery(text, actorName)
		AppealService.Decide(id, actor, accept, note?) -> (ok, msg)
		AppealService.AddNote(id, actor, text) / Assign(id, actor, staff?)
		AppealService.PendingCount() -> number
		AppealService.ForUser(userId) -> list (User_ record)
		AppealService.OnChanged(fn(appeal, what))   -- UI push / player notice
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Logger = require(Core:WaitForChild("Logger"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))
local CaseService = require(script.Parent:WaitForChild("CaseService"))
local TextFilterService = require(script.Parent:WaitForChild("TextFilterService"))

local AppealService = {}

local LIVE = RunService:IsRunning() and RunService:IsServer()
local store = if LIVE then DataStoreService:GetDataStore("Sentinel_Appeals_v1") else nil

local INDEX_MAX = 500
local NOTES_MAX = 50
local USER_MAX = 50
local WARN_DAYS = 30

AppealService.STATUSES = { "Pending", "Accepted", "Rejected" }
-- Node needed (besides moderation.appeals) to accept an appeal of that type.
AppealService.LIFT_NODES = { ban = "moderation.ban", mute = "moderation.mute", warn = "moderation.warn", jail = "player.jail" }

export type Note = { ById: number, By: string, Text: string, At: number }
export type Appeal = {
	Id: number,
	UserId: number,
	Name: string,
	Key: string, -- "case:<id>" or "ban" (a ban with no case)
	Type: string, -- ban | mute | warn | jail
	CaseId: number?,
	PunishReason: string?,
	PunishedBy: string?,
	Text: string,
	Status: string,
	Assignee: string?,
	ReviewerName: string?,
	Decision: string?,
	DecidedAt: number?,
	Source: string?, -- "banscreen" | "form" | "command"
	Server: string?,
	CreatedAt: number,
	UpdatedAt: number,
	Notes: { Note }?,
	NoteCount: number?,
}
export type UserEntry = { Id: number, Key: string, Status: string, DecidedAt: number?, Seen: boolean? }

local appeals: { [number]: Appeal } = {}
local index: { Appeal } = {}
local indexLoadedAt = -math.huge
local dirty: { [number]: boolean } = {}
local userLists: { [number]: { UserEntry } } = {}
local userDirty: { [number]: boolean } = {}
local localCounter = 0

local lifters: { [string]: (number, any, Appeal) -> (boolean, string) } = {}
function AppealService.SetLifters(map: { [string]: (number, any, Appeal) -> (boolean, string) })
	lifters = map
end

-- The active ban record lives in Ban.lua; it hands over a reader.
local banReader: ((number) -> any)? = nil
function AppealService.SetBanReader(fn: (number) -> any)
	banReader = fn
end

local listeners: { (Appeal, string) -> () } = {}
function AppealService.OnChanged(fn: (Appeal, string) -> ())
	table.insert(listeners, fn)
end
local function emit(a: Appeal, what: string)
	for _, fn in ipairs(listeners) do
		task.spawn(fn, a, what)
	end
end

local function now(): number
	return os.time()
end

local function summary(a: Appeal): Appeal
	local s = table.clone(a)
	s.NoteCount = if a.Notes then #a.Notes else (a.NoteCount or 0)
	s.Notes = nil
	return s
end

local function markDirty(a: Appeal)
	a.UpdatedAt = math.max(now(), a.UpdatedAt or 0)
	appeals[a.Id] = a
	dirty[a.Id] = true
end

local function nextId(): number
	if store then
		local ok, value = pcall(function()
			return store:UpdateAsync("Counter", function(old)
				return (if type(old) == "number" then old else 0) + 1
			end)
		end)
		if ok and type(value) == "number" then
			return value
		end
		warn("[Sentinel.AppealService] appeal counter unavailable: " .. tostring(value))
	end
	localCounter += 1
	return if store then 1e9 + (now() % 1e6) * 100 + localCounter else localCounter
end

local function mergeSummaries(list: { Appeal }, updates: { Appeal }): { Appeal }
	local byId = {}
	for i, s in ipairs(list) do
		byId[s.Id] = i
	end
	for _, s in ipairs(updates) do
		local at = byId[s.Id]
		if at then
			if (s.UpdatedAt or 0) >= (list[at].UpdatedAt or 0) then
				list[at] = s
			end
		else
			table.insert(list, s)
			byId[s.Id] = #list
		end
	end
	table.sort(list, function(a, b)
		return a.CreatedAt < b.CreatedAt or (a.CreatedAt == b.CreatedAt and a.Id < b.Id)
	end)
	while #list > INDEX_MAX do
		table.remove(list, 1)
	end
	return list
end

-- ---------------------------------------------------------------------------
-- Per-user list (lets a banned player on any server see their appeals)
-- ---------------------------------------------------------------------------
function AppealService.ForUser(userId: number): { UserEntry }
	local list = userLists[userId]
	if list then
		return list
	end
	list = {}
	if store then
		local ok, value = pcall(function()
			return store:GetAsync("User_" .. userId)
		end)
		if ok and type(value) == "table" then
			list = value
		end
	end
	userLists[userId] = list
	return list :: { UserEntry }
end

local function touchUser(a: Appeal)
	local list = AppealService.ForUser(a.UserId)
	local found = false
	for _, e in ipairs(list) do
		if e.Id == a.Id then
			e.Status, e.DecidedAt = a.Status, a.DecidedAt
			e.Seen = if a.Status == "Pending" then nil else e.Seen
			found = true
		end
	end
	if not found then
		table.insert(list, { Id = a.Id, Key = a.Key, Status = a.Status, DecidedAt = a.DecidedAt })
	end
	while #list > USER_MAX do
		table.remove(list, 1)
	end
	userDirty[a.UserId] = true
end

function AppealService.MarkSeen(userId: number, id: number)
	for _, e in ipairs(AppealService.ForUser(userId)) do
		if e.Id == id then
			e.Seen = true
			userDirty[userId] = true
		end
	end
end

function AppealService.Flush()
	if not store then
		dirty, userDirty = {}, {}
		return
	end
	local batch = dirty
	dirty = {}
	local summaries = {}
	for id in pairs(batch) do
		local a = appeals[id]
		if a then
			local ok, err = pcall(function()
				store:SetAsync("Appeal_" .. id, a)
			end)
			if not ok then
				warn(("[Sentinel.AppealService] saving appeal %d failed: %s"):format(id, tostring(err)))
				dirty[id] = true
			end
			table.insert(summaries, summary(a))
		end
	end
	if #summaries > 0 then
		pcall(function()
			store:UpdateAsync("Index", function(old)
				return mergeSummaries(if type(old) == "table" then old else {}, summaries)
			end)
		end)
		index = mergeSummaries(index, summaries)
	end
	local users = userDirty
	userDirty = {}
	for userId in pairs(users) do
		local mine = userLists[userId] or {}
		pcall(function()
			store:UpdateAsync("User_" .. userId, function(old)
				-- Merge by id: another server may have decided one meanwhile.
				local merged = if type(old) == "table" then old else {}
				local at = {}
				for i, e in ipairs(merged) do
					at[e.Id] = i
				end
				for _, e in ipairs(mine) do
					local i = at[e.Id]
					if i then
						local o = merged[i]
						if (e.DecidedAt or 0) >= (o.DecidedAt or 0) then
							merged[i] = e
						end
					else
						table.insert(merged, e)
					end
				end
				while #merged > USER_MAX do
					table.remove(merged, 1)
				end
				return merged
			end)
		end)
	end
end

local function fetch(id: number): Appeal?
	local a = appeals[id]
	if a then
		return a
	end
	if store then
		local ok, value = pcall(function()
			return store:GetAsync("Appeal_" .. id)
		end)
		if ok and type(value) == "table" then
			appeals[id] = value
			return value
		end
	end
	return nil
end

function AppealService.Get(id: number): Appeal?
	if type(id) ~= "number" then
		return nil
	end
	return fetch(id)
end

local function loadIndex()
	if not store or os.clock() - indexLoadedAt < 15 then
		return
	end
	indexLoadedAt = os.clock()
	local ok, value = pcall(function()
		return store:GetAsync("Index")
	end)
	if ok and type(value) == "table" then
		index = value
	end
end

local function allKnown(): { Appeal }
	loadIndex()
	local seen, out = {}, {}
	for _, a in pairs(appeals) do
		seen[a.Id] = true
		table.insert(out, a)
	end
	for _, s in ipairs(index) do
		if not seen[s.Id] then
			seen[s.Id] = true
			table.insert(out, s)
		end
	end
	table.sort(out, function(a, b)
		return a.CreatedAt > b.CreatedAt or (a.CreatedAt == b.CreatedAt and a.Id > b.Id)
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- What can this player appeal?
-- ---------------------------------------------------------------------------
export type Appealable = {
	Key: string,
	Type: string,
	CaseId: number?,
	Reason: string?,
	By: string?,
	Duration: string?,
	CreatedAt: number?,
	ExpiresAt: number?,
	Blocked: string?, -- why it can't be appealed right now
	AppealId: number?, -- the pending / last appeal
	AppealStatus: string?,
}

local function lastAppealFor(userId: number, key: string): UserEntry?
	local best: UserEntry? = nil
	for _, e in ipairs(AppealService.ForUser(userId)) do
		if e.Key == key and (not best or e.Id > best.Id) then
			best = e
		end
	end
	return best
end

local function blockReason(userId: number, key: string): (string?, UserEntry?)
	local last = lastAppealFor(userId, key)
	if not last then
		return nil, nil
	end
	if last.Status == "Pending" then
		return ("Your appeal #%d is waiting for review."):format(last.Id), last
	elseif last.Status == "Accepted" then
		return ("Your appeal #%d was accepted."):format(last.Id), last
	end
	local days = ConfigService.Get("AppealCooldownDays") or 7
	local readyAt = (last.DecidedAt or 0) + days * 86400
	if now() < readyAt then
		local left = readyAt - now()
		local text = if left >= 86400 then ("%d day(s)"):format(math.ceil(left / 86400)) else ("%d hour(s)"):format(math.ceil(left / 3600))
		return ("Your appeal #%d was rejected. You can appeal again in %s."):format(last.Id, text), last
	end
	return nil, last
end

function AppealService.Appealable(userId: number, name: string?): { Appealable }
	local out: { Appealable } = {}
	if ConfigService.Get("AppealsEnabled") == false then
		return out
	end
	local found = CaseService.Search({ Player = tostring(userId), Status = nil } :: any, nil, 100)
	local t = now()
	local hasBanCase = false
	for _, c in ipairs(found.Cases or {}) do
		if c.TargetId ~= userId then
			continue
		end
		local ok = (c.Status == "Active" and (c.Type == "ban" or c.Type == "mute" or c.Type == "jail"))
			or (c.Type == "warn" and c.Status == "Closed" and t - c.CreatedAt < WARN_DAYS * 86400)
		if ok then
			if c.Type == "ban" then
				hasBanCase = true
			end
			local key = "case:" .. c.Id
			local blocked, last = blockReason(userId, key)
			table.insert(out, {
				Key = key,
				Type = c.Type,
				CaseId = c.Id,
				Reason = c.Reason,
				By = c.ModeratorName,
				Duration = c.Duration,
				CreatedAt = c.CreatedAt,
				ExpiresAt = c.ExpiresAt,
				Blocked = blocked,
				AppealId = if last then last.Id else nil,
				AppealStatus = if last then last.Status else nil,
			})
		end
	end
	-- A ban from before cases existed (or whose case was lost): still appealable.
	if not hasBanCase and banReader then
		local ban = banReader(userId)
		if ban then
			local blocked, last = blockReason(userId, "ban")
			table.insert(out, {
				Key = "ban",
				Type = "ban",
				Reason = ban.Reason,
				By = ban.BannedByName,
				CreatedAt = ban.IssuedAt,
				ExpiresAt = if ban.ExpiresAt == math.huge then -1 else ban.ExpiresAt,
				Blocked = blocked,
				AppealId = if last then last.Id else nil,
				AppealStatus = if last then last.Status else nil,
			})
		end
	end
	table.sort(out, function(a, b)
		local order = { ban = 1, mute = 2, jail = 3, warn = 4 }
		if a.Type ~= b.Type then
			return (order[a.Type] or 9) < (order[b.Type] or 9)
		end
		return (a.CreatedAt or 0) > (b.CreatedAt or 0)
	end)
	return out
end

-- ---------------------------------------------------------------------------
-- Submit
-- ---------------------------------------------------------------------------
function AppealService.Submit(player: any, key: string, text: string, source: string?): (Appeal?, string?)
	if ConfigService.Get("AppealsEnabled") == false then
		return nil, "Appeals are turned off in this game."
	end
	if type(key) ~= "string" or type(text) ~= "string" then
		return nil, "Pick the punishment you want to appeal."
	end
	local body = text:gsub("^%s+", ""):gsub("%s+$", "")
	if #body < 20 then
		return nil, "Explain why the punishment should be lifted (at least 20 characters)."
	end
	local target: Appealable? = nil
	for _, a in ipairs(AppealService.Appealable(player.UserId, player.Name)) do
		if a.Key == key then
			target = a
		end
	end
	if not target then
		return nil, "That punishment can't be appealed (it may have ended already)."
	end
	if target.Blocked then
		return nil, target.Blocked
	end
	local filtered = if LIVE then TextFilterService.ForBroadcast(player.UserId, body:sub(1, 1000)) else body:sub(1, 1000)
	if not filtered then
		return nil, "Your appeal could not be checked by the text filter. Try again."
	end
	local t = now()
	local a: Appeal = {
		Id = nextId(),
		UserId = player.UserId,
		Name = tostring(player.Name),
		Key = key,
		Type = target.Type,
		CaseId = target.CaseId,
		PunishReason = target.Reason,
		PunishedBy = target.By,
		Text = filtered,
		Status = "Pending",
		Source = source,
		Server = Logger.GetServerId(),
		CreatedAt = t,
		UpdatedAt = t,
		Notes = {},
	}
	markDirty(a)
	touchUser(a)
	if a.CaseId then
		CaseService.AddNote(a.CaseId, { UserId = 0, Name = "SYSTEM" }, ("Appeal #%d submitted by %s."):format(a.Id, a.Name))
	end
	Logger.Write({
		Executor = tostring(a.UserId),
		ExecutorName = a.Name,
		Command = "appeal",
		Action = "moderation.appeal.create",
		Target = a.Name,
		TargetIds = { a.UserId },
		Result = "Success",
		Severity = "Info",
		Message = ("Appeal #%d (%s%s) from %s"):format(a.Id, a.Type, if a.CaseId then (", case #%d"):format(a.CaseId) else "", a.Name),
	})
	emit(summary(a), "created")
	return a, nil
end

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
local function addNote(a: Appeal, actor: any, text: string)
	a.Notes = a.Notes or {}
	local notes = a.Notes :: { Note }
	table.insert(notes, { ById = actor.UserId, By = actor.Name, Text = text:sub(1, 400), At = now() })
	while #notes > NOTES_MAX do
		table.remove(notes, 1)
	end
end

function AppealService.AddNote(id: number, actor: any, text: string): (boolean, string)
	local a = fetch(id)
	if not a then
		return false, ("There is no appeal #%s."):format(tostring(id))
	end
	addNote(a, actor, text)
	markDirty(a)
	emit(summary(a), "note")
	return true, ("Note added to appeal #%d."):format(id)
end

function AppealService.Assign(id: number, actor: any, staff: string?): (boolean, string)
	local a = fetch(id)
	if not a then
		return false, ("There is no appeal #%s."):format(tostring(id))
	end
	local before = a.Assignee
	a.Assignee = staff
	addNote(a, actor, if staff then "Assigned to " .. staff else "Unassigned")
	markDirty(a)
	Logger.NoteChange("appeal #" .. id, "Assignee", before or "none", staff or "none", if typeof(actor) == "Instance" then actor else nil, "moderation.appeal")
	emit(summary(a), "assign")
	return true, if staff then ("Appeal #%d assigned to %s."):format(id, staff) else ("Appeal #%d unassigned."):format(id)
end

-- Can this staff member accept / reject this appeal?
function AppealService.CanDecide(actor: any, a: Appeal): (boolean, string?)
	if typeof(actor) ~= "Instance" then
		return true, nil
	end
	local node = AppealService.LIFT_NODES[a.Type]
	if node and not PermissionSystem.Has(actor, node) then
		return false, ("Deciding a %s appeal needs %s."):format(a.Type, node)
	end
	if actor.UserId == a.UserId then
		return false, "You can't decide your own appeal."
	end
	return true, nil
end

function AppealService.Decide(id: number, actor: any, accept: boolean, note: string?): (boolean, string)
	local a = fetch(id)
	if not a then
		return false, ("There is no appeal #%s."):format(tostring(id))
	end
	if a.Status ~= "Pending" then
		return false, ("Appeal #%d was already %s."):format(id, a.Status:lower())
	end
	local allowed, why = AppealService.CanDecide(actor, a)
	if not allowed then
		return false, why :: string
	end
	local liftMsg = ""
	if accept then
		local lift = lifters[a.Type]
		if lift then
			local ok, msg = lift(a.UserId, actor, a)
			if not ok then
				return false, ("Appeal #%d not accepted: %s"):format(id, msg)
			end
			liftMsg = msg
		end
		if a.CaseId then
			local c = CaseService.Get(a.CaseId)
			if c and c.Status ~= "Revoked" then
				CaseService.SetStatus(a.CaseId, "Revoked", actor, ("Appeal #%d accepted"):format(id))
			end
		end
	end
	a.Status = if accept then "Accepted" else "Rejected"
	a.ReviewerName = actor.Name
	a.Decision = if note and note ~= "" then note:sub(1, 300) else nil
	a.DecidedAt = now()
	addNote(a, actor, ("%s%s"):format(a.Status, if a.Decision then ": " .. a.Decision else ""))
	markDirty(a)
	touchUser(a)
	if a.CaseId and not accept then
		CaseService.AddNote(a.CaseId, actor, ("Appeal #%d rejected%s"):format(id, if a.Decision then ": " .. a.Decision else ""))
	end
	Logger.NoteChange("appeal #" .. id, "Status", "Pending", a.Status, if typeof(actor) == "Instance" then actor else nil, "moderation.appeal")
	emit(summary(a), "decided")
	return true, ("Appeal #%d %s.%s"):format(id, a.Status:lower(), if liftMsg ~= "" then " " .. liftMsg else "")
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------
export type Filter = { Status: string?, Player: string?, Type: string?, Assignee: string?, Text: string?, Id: number? }

local function contains(hay: any, needle: string): boolean
	return type(hay) == "string" and hay:lower():find(needle, 1, true) ~= nil
end

function AppealService.Matches(a: Appeal, f: Filter?): boolean
	f = f or {}
	local filter = f :: Filter
	if filter.Id then
		return a.Id == filter.Id
	end
	local status = (filter.Status or "pending"):lower()
	if status ~= "all" and a.Status:lower() ~= status then
		return false
	end
	if filter.Player then
		local p = filter.Player:lower()
		if not (contains(a.Name, p) or tostring(a.UserId) == p) then
			return false
		end
	end
	if filter.Type and a.Type ~= filter.Type:lower() then
		return false
	end
	if filter.Assignee then
		local s = filter.Assignee:lower()
		if s == "none" then
			if a.Assignee then
				return false
			end
		elseif not contains(a.Assignee, s) then
			return false
		end
	end
	if filter.Text then
		local t = filter.Text:lower()
		if not (contains(a.Text, t) or contains(a.Name, t) or contains(a.PunishReason, t) or contains(a.Decision, t)) then
			return false
		end
	end
	return true
end

function AppealService.ParseQuery(text: string?, actorName: string?): Filter
	local f: Filter = {}
	local free = {}
	for word in (text or ""):gmatch("%S+") do
		local key, value = word:match("^(%a+):(.+)$")
		local id = word:match("^#(%d+)$")
		local lw = word:lower()
		if id then
			f.Id = tonumber(id)
		elseif key then
			key = key:lower()
			if key == "status" or key == "s" then
				f.Status = value
			elseif key == "player" or key == "p" then
				f.Player = value
			elseif key == "type" then
				f.Type = value
			elseif key == "assignee" or key == "a" then
				f.Assignee = if value:lower() == "me" and actorName then actorName else value
			else
				table.insert(free, word)
			end
		elseif lw == "all" or lw == "pending" or lw == "accepted" or lw == "rejected" then
			f.Status = lw
		elseif lw == "mine" and actorName then
			f.Assignee = actorName
		elseif lw == "ban" or lw == "mute" or lw == "warn" or lw == "jail" then
			f.Type = lw
		else
			table.insert(free, word)
		end
	end
	if #free > 0 then
		f.Text = table.concat(free, " ")
	end
	return f
end

function AppealService.SanitizeFilter(raw: any): Filter
	local f: Filter = {}
	if type(raw) ~= "table" then
		return f
	end
	for _, key in ipairs({ "Status", "Player", "Type", "Assignee", "Text" }) do
		local v = raw[key]
		if type(v) == "string" and #v <= 100 and v ~= "" then
			(f :: any)[key] = v
		end
	end
	if type(raw.Id) == "number" then
		f.Id = raw.Id
	end
	return f
end

function AppealService.Search(f: Filter?, cursor: any, limit: number?): { [string]: any }
	if f and f.Id and not appeals[f.Id] then
		fetch(f.Id)
	end
	local offset = if type(cursor) == "number" and cursor >= 0 then math.floor(cursor) else 0
	local max = math.clamp(limit or 40, 1, 100)
	local matched = {}
	local counts = { Pending = 0, Accepted = 0, Rejected = 0 }
	for _, a in ipairs(allKnown()) do
		counts[a.Status] = (counts[a.Status] or 0) + 1
		if AppealService.Matches(a, f) then
			table.insert(matched, summary(a))
		end
	end
	return {
		Appeals = table.move(matched, offset + 1, math.min(offset + max, #matched), 1, {}),
		Total = #matched,
		Counts = counts,
		Cursor = if offset + max < #matched then offset + max else nil,
	}
end

function AppealService.PendingCount(): number
	local n = 0
	for _, a in ipairs(allKnown()) do
		if a.Status == "Pending" then
			n += 1
		end
	end
	return n
end

function AppealService.Format(a: Appeal): string
	return ("#%d %s [%s] %s%s: %s"):format(
		a.Id,
		a.Name,
		a.Status,
		a.Type,
		if a.CaseId then (" (case #%d)"):format(a.CaseId) else "",
		a.Text:sub(1, 80)
	)
end

function AppealService._Reset()
	if store then
		return
	end
	appeals, index, dirty, userLists, userDirty = {}, {}, {}, {}, {}
	localCounter = 0
end

if LIVE then
	task.spawn(function()
		while true do
			task.wait(10)
			AppealService.Flush()
		end
	end)
	game:BindToClose(function()
		AppealService.Flush()
	end)
	Players.PlayerRemoving:Connect(function(p)
		task.delay(30, function()
			if not Players:GetPlayerByUserId(p.UserId) and not userDirty[p.UserId] then
				userLists[p.UserId] = nil
			end
		end)
	end)
end

return AppealService
