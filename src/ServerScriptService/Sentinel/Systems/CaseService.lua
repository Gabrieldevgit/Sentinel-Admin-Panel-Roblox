--!strict
--[[
	CaseService.lua (W12)

	Purpose:
		Moderation cases. Every punishment (ban, kick, mute, warn, jail and
		their global versions, plus automatic escalation) becomes a numbered
		case with the staff member responsible, reason, duration, expiry and
		a status. Staff can open investigation cases, add notes, assign,
		close and reopen. Lifting a punishment (unmute, unjail, gunban)
		revokes the matching active case.

	Status:
		Open     investigation / reopened case, needs attention
		Active   punishment in force (ban, mute, jail)
		Expired  temporary punishment ran out (checked lazily + every 60 s)
		Revoked  punishment lifted early
		Closed   finished (kicks, warnings, closed investigations)
		"Active cases" on the dashboard = Open + Active.

	Storage (DataStore Sentinel_Cases_v1):
		Counter          next case number (UpdateAsync, shared by every server)
		Case_<id>        full case incl. notes
		Index            newest <= 500 case summaries (no notes), merged by Id
		Player_<userId>  that player's case ids (<= 200)
		Writes are queued and flushed every 10 s and on close. Outside a
		running game (unit tests) everything stays in memory.

	Public API:
		CaseService.Record(fields) -> case
		CaseService.Get(id) -> case?
		CaseService.Search(filter, cursor?, limit?) -> { Cases, Cursor?, Total }
		CaseService.ParseQuery(text) -> (filter?, err?)
		CaseService.AddNote(id, actor, text) -> (ok, msg)
		CaseService.SetStatus(id, status, actor, note?) -> (ok, msg)
		CaseService.Assign(id, actor, staff?) -> (ok, msg)
		CaseService.Revoke(targetId, types, actor) -> number
		CaseService.Dashboard() -> summary for the Moderation page
		CaseService.Format(case) -> string
		CaseService.ExpandReasons(args) / reason templates (ReasonTemplates)
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local CaseService = {}

local LIVE = RunService:IsRunning() and RunService:IsServer()
local store = if LIVE then DataStoreService:GetDataStore("Sentinel_Cases_v1") else nil

local INDEX_MAX = 500
local PLAYER_MAX = 200
local NOTES_MAX = 50
local STATUSES = { "Open", "Active", "Expired", "Revoked", "Closed" }
CaseService.STATUSES = STATUSES
CaseService.TYPES = { "ban", "kick", "mute", "warn", "jail", "investigation" }

export type Note = { ById: number, By: string, Text: string, At: number }
export type Case = {
	Id: number,
	Type: string,
	TargetId: number,
	TargetName: string,
	ModeratorId: number,
	ModeratorName: string,
	Assignee: string?,
	Reason: string?,
	Duration: string?,
	CreatedAt: number,
	ExpiresAt: number?, -- -1 = permanent, nil = no expiry
	Status: string,
	Server: string?,
	Global: boolean?,
	Source: string?,
	Notes: { Note }?,
	NoteCount: number?,
	UpdatedAt: number,
}

-- Everything this server knows: full cases by id (local ones + fetched).
local cases: { [number]: Case } = {}
local index: { Case } = {} -- summaries from the store, newest last
local indexLoadedAt = -math.huge
local dirty: { [number]: boolean } = {}
local localCounter = 0

local function now(): number
	return os.time()
end

local function summary(c: Case): Case
	local s = table.clone(c)
	s.NoteCount = if c.Notes then #c.Notes else (c.NoteCount or 0)
	s.Notes = nil
	return s
end

local function refreshStatus(c: Case): Case
	if c.Status == "Active" and c.ExpiresAt and c.ExpiresAt > 0 and c.ExpiresAt <= now() then
		c.Status = "Expired"
		c.UpdatedAt = c.ExpiresAt
	end
	return c
end

local function markDirty(c: Case)
	c.UpdatedAt = math.max(now(), c.UpdatedAt or 0)
	cases[c.Id] = c
	dirty[c.Id] = true
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
		warn("[Sentinel.CaseService] case counter unavailable: " .. tostring(value))
	end
	-- Offline / failed: a large number unlikely to collide with the counter.
	localCounter += 1
	return if store then 1e9 + (now() % 1e6) * 100 + localCounter else localCounter
end

local function loadIndex(force: boolean?)
	if not store or (not force and os.clock() - indexLoadedAt < 15) then
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

local function mergeSummaries(list: { Case }, updates: { Case }): { Case }
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

function CaseService.Flush()
	if not store or next(dirty) == nil then
		dirty = {}
		return
	end
	local batch = dirty
	dirty = {}
	local summaries, byPlayer = {}, {}
	for id in pairs(batch) do
		local c = cases[id]
		if c then
			local ok, err = pcall(function()
				store:SetAsync("Case_" .. id, c)
			end)
			if not ok then
				warn(("[Sentinel.CaseService] saving case %d failed: %s"):format(id, tostring(err)))
				dirty[id] = true
			end
			table.insert(summaries, summary(c))
			if c.TargetId > 0 then
				byPlayer[c.TargetId] = byPlayer[c.TargetId] or {}
				table.insert(byPlayer[c.TargetId], id)
			end
		end
	end
	pcall(function()
		store:UpdateAsync("Index", function(old)
			return mergeSummaries(if type(old) == "table" then old else {}, summaries)
		end)
	end)
	index = mergeSummaries(index, summaries)
	for userId, ids in pairs(byPlayer) do
		pcall(function()
			store:UpdateAsync("Player_" .. userId, function(old)
				local list = if type(old) == "table" then old else {}
				for _, id in ipairs(ids) do
					if not table.find(list, id) then
						table.insert(list, id)
					end
				end
				while #list > PLAYER_MAX do
					table.remove(list, 1)
				end
				return list
			end)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------
local ACTIVE_TYPES = { ban = true, mute = true, jail = true }

function CaseService.Record(fields: { [string]: any }): Case
	local kind = tostring(fields.Type or "note")
	local createdAt = now()
	local expiresAt: number? = nil
	local duration = fields.Duration
	if ACTIVE_TYPES[kind] and type(duration) == "string" and duration ~= "" then
		local parsed = DurationParser.Parse(duration)
		if parsed then
			expiresAt = if parsed.IsPermanent then -1 else createdAt + parsed.Seconds
			duration = if parsed.IsPermanent then "permanent" else parsed.Raw
		end
	elseif ACTIVE_TYPES[kind] and kind ~= "jail" then
		expiresAt = -1
		duration = "permanent"
	end
	local status = fields.Status
		or (if kind == "investigation" then "Open" elseif ACTIVE_TYPES[kind] then "Active" else "Closed")
	local c: Case = {
		Id = nextId(),
		Type = kind,
		TargetId = tonumber(fields.TargetId) or 0,
		TargetName = tostring(fields.TargetName or "?"),
		ModeratorId = tonumber(fields.ModeratorId) or 0,
		ModeratorName = tostring(fields.ModeratorName or "SYSTEM"),
		Reason = if type(fields.Reason) == "string" and fields.Reason ~= "" then fields.Reason:sub(1, 300) else nil,
		Duration = duration,
		CreatedAt = createdAt,
		ExpiresAt = expiresAt,
		Status = status,
		Server = Logger.GetServerId(),
		Global = fields.Global == true or nil,
		Source = fields.Source,
		Notes = {},
		UpdatedAt = createdAt,
	}
	markDirty(c)
	Logger.Write({
		Executor = tostring(c.ModeratorId),
		ExecutorName = c.ModeratorName,
		Command = "case",
		Action = "moderation.case." .. kind,
		Target = c.TargetName,
		TargetIds = if c.TargetId ~= 0 then { c.TargetId } else nil,
		Reason = c.Reason,
		Result = "Success",
		Severity = "Info",
		Message = ("Case #%d opened (%s, %s)"):format(c.Id, kind, c.Status),
	})
	return c
end

local function fetch(id: number): Case?
	local c = cases[id]
	if c then
		return refreshStatus(c)
	end
	if store then
		local ok, value = pcall(function()
			return store:GetAsync("Case_" .. id)
		end)
		if ok and type(value) == "table" then
			cases[id] = value
			return refreshStatus(value)
		end
	end
	return nil
end

function CaseService.Get(id: number): Case?
	if type(id) ~= "number" then
		return nil
	end
	return fetch(id)
end

function CaseService.AddNote(id: number, actor: any, text: string): (boolean, string)
	local c = fetch(id)
	if not c then
		return false, ("There is no case #%s."):format(tostring(id))
	end
	text = text:sub(1, 400)
	c.Notes = c.Notes or {}
	local notes = c.Notes :: { Note }
	table.insert(notes, { ById = actor.UserId, By = actor.Name, Text = text, At = now() })
	while #notes > NOTES_MAX do
		table.remove(notes, 1)
	end
	markDirty(c)
	return true, ("Note added to case #%d."):format(id)
end

function CaseService.SetStatus(id: number, status: string, actor: any, note: string?): (boolean, string)
	local c = fetch(id)
	if not c then
		return false, ("There is no case #%s."):format(tostring(id))
	end
	if not table.find(STATUSES, status) then
		return false, "Unknown status " .. status
	end
	local before = c.Status
	if before == status then
		return false, ("Case #%d is already %s."):format(id, status)
	end
	c.Status = status
	c.Notes = c.Notes or {}
	table.insert(c.Notes :: { Note }, {
		ById = actor.UserId,
		By = actor.Name,
		Text = ("Status %s -> %s%s"):format(before, status, if note and note ~= "" then ": " .. note:sub(1, 300) else ""),
		At = now(),
	})
	markDirty(c)
	Logger.NoteChange("case #" .. id, "Status", before, status, if typeof(actor) == "Instance" then actor else nil, "moderation.case")
	return true, ("Case #%d is now %s."):format(id, status)
end

function CaseService.Assign(id: number, actor: any, staff: string?): (boolean, string)
	local c = fetch(id)
	if not c then
		return false, ("There is no case #%s."):format(tostring(id))
	end
	local before = c.Assignee
	c.Assignee = staff
	c.Notes = c.Notes or {}
	table.insert(c.Notes :: { Note }, {
		ById = actor.UserId,
		By = actor.Name,
		Text = if staff then "Assigned to " .. staff else "Unassigned",
		At = now(),
	})
	markDirty(c)
	Logger.NoteChange("case #" .. id, "Assignee", before or "none", staff or "none", if typeof(actor) == "Instance" then actor else nil, "moderation.case")
	return true, if staff then ("Case #%d assigned to %s."):format(id, staff) else ("Case #%d unassigned."):format(id)
end

local function allKnown(): { Case }
	loadIndex()
	local seen, out = {}, {}
	for _, c in pairs(cases) do
		seen[c.Id] = true
		table.insert(out, refreshStatus(c))
	end
	for _, s in ipairs(index) do
		if not seen[s.Id] then
			seen[s.Id] = true
			table.insert(out, refreshStatus(s))
		end
	end
	table.sort(out, function(a, b)
		return a.CreatedAt > b.CreatedAt or (a.CreatedAt == b.CreatedAt and a.Id > b.Id)
	end)
	return out
end

-- Lifts punishments: every Active case of these types for the player.
function CaseService.Revoke(targetId: number, types: { string }, actor: any): number
	local n = 0
	for _, c in ipairs(allKnown()) do
		if c.TargetId == targetId and c.Status == "Active" and table.find(types, c.Type) then
			local full = fetch(c.Id)
			if full and full.Status == "Active" then
				CaseService.SetStatus(full.Id, "Revoked", actor)
				n += 1
			end
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------
export type Filter = {
	Player: string?,
	Moderator: string?,
	Type: string?,
	Status: string?, -- a status, or "active" = Open + Active
	Text: string?,
	Since: number?,
	Id: number?,
}

local function contains(hay: any, needle: string): boolean
	return type(hay) == "string" and hay:lower():find(needle, 1, true) ~= nil
end

function CaseService.Matches(c: Case, f: Filter?): boolean
	if not f then
		return true
	end
	if f.Id and c.Id ~= f.Id then
		return false
	end
	if f.Player then
		local p = f.Player:lower()
		if not (contains(c.TargetName, p) or tostring(c.TargetId) == p) then
			return false
		end
	end
	if f.Moderator then
		local m = f.Moderator:lower()
		if not (contains(c.ModeratorName, m) or contains(c.Assignee, m) or tostring(c.ModeratorId) == m) then
			return false
		end
	end
	if f.Type then
		local ok = false
		for t in f.Type:lower():gmatch("[^,]+") do
			if c.Type == t then
				ok = true
			end
		end
		if not ok then
			return false
		end
	end
	if f.Status then
		local s = f.Status:lower()
		if s == "active" then
			if c.Status ~= "Open" and c.Status ~= "Active" then
				return false
			end
		elseif c.Status:lower() ~= s then
			return false
		end
	end
	if f.Since and c.CreatedAt < f.Since then
		return false
	end
	if f.Text then
		local t = f.Text:lower()
		if not (contains(c.Reason, t) or contains(c.TargetName, t) or contains(c.ModeratorName, t) or contains(c.Type, t)) then
			return false
		end
	end
	return true
end

local QUERY_KEYS = {
	player = "Player", p = "Player", target = "Player",
	mod = "Moderator", by = "Moderator", staff = "Moderator",
	type = "Type", t = "Type",
	status = "Status", s = "Status",
	since = "Since", id = "Id",
}

function CaseService.ParseQuery(text: string?): (Filter?, string?)
	local f: any = {}
	local free = {}
	for word in (text or ""):gmatch("%S+") do
		local key, value = word:match("^(%a+):(.+)$")
		local field = key and QUERY_KEYS[key:lower()]
		if field == "Since" then
			local d = DurationParser.Parse(value)
			if not d or d.IsPermanent then
				return nil, "since: takes a duration like 7d"
			end
			f.Since = now() - d.Seconds
		elseif field == "Id" then
			f.Id = tonumber((value:gsub("^#", "")))
			if not f.Id then
				return nil, "id: takes a case number"
			end
		elseif field then
			f[field] = value:sub(1, 60)
		elseif word:match("^#%d+$") then
			f.Id = tonumber(word:sub(2))
		else
			table.insert(free, word)
		end
	end
	if #free > 0 then
		f.Text = table.concat(free, " "):sub(1, 60)
	end
	if f.Status and f.Status:lower() ~= "active" then
		local found = nil
		for _, s in ipairs(STATUSES) do
			if s:lower() == f.Status:lower() then
				found = s
			end
		end
		if not found then
			return nil, "status: is one of active, " .. table.concat(STATUSES, ", "):lower()
		end
	end
	return f, nil
end

function CaseService.SanitizeFilter(raw: any): Filter
	local f: any = {}
	if type(raw) ~= "table" then
		return f
	end
	for _, key in ipairs({ "Player", "Moderator", "Type", "Status", "Text" }) do
		if type(raw[key]) == "string" and #raw[key] <= 60 and raw[key] ~= "" then
			f[key] = raw[key]
		end
	end
	for _, key in ipairs({ "Since", "Id" }) do
		if type(raw[key]) == "number" and raw[key] == raw[key] then
			f[key] = raw[key]
		end
	end
	return f
end

-- Player searches by UserId also read that player's own key, so cases that
-- fell out of the 500-entry index are still found.
local function loadPlayerCases(f: Filter?)
	if not store or not f or not f.Player then
		return
	end
	local userId = tonumber(f.Player)
	if not userId then
		local p = Players:FindFirstChild(f.Player)
		userId = if p and p:IsA("Player") then p.UserId else nil
	end
	if not userId then
		return
	end
	local ok, ids = pcall(function()
		return store:GetAsync("Player_" .. userId)
	end)
	if ok and type(ids) == "table" then
		local fetched = 0
		for i = #ids, 1, -1 do
			local id = ids[i]
			if not cases[id] and fetched < 25 then
				fetched += 1
				fetch(id)
			end
		end
	end
end

function CaseService.Search(f: Filter?, cursor: any, limit: number?): { [string]: any }
	loadPlayerCases(f)
	local offset = if type(cursor) == "number" and cursor >= 0 then math.floor(cursor) else 0
	local max = math.clamp(limit or 40, 1, 100)
	local matched = {}
	for _, c in ipairs(allKnown()) do
		if CaseService.Matches(c, f) then
			table.insert(matched, summary(c))
		end
	end
	local page = table.move(matched, offset + 1, math.min(offset + max, #matched), 1, {})
	return {
		Cases = page,
		Total = #matched,
		Cursor = if offset + max < #matched then offset + max else nil,
	}
end

-- ---------------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------------
function CaseService.Dashboard(): { [string]: any }
	local all = allKnown()
	local t = now()
	local counts = { Active = 0, ActiveBans = 0, ActiveMutes = 0, Open = 0, Today = 0 }
	local activity = table.create(24, 0)
	local byMod: { [string]: number } = {}
	local recentPunish, recentWarn, bans, mutes = {}, {}, {}, {}
	for _, c in ipairs(all) do
		if c.Status == "Open" or c.Status == "Active" then
			counts.Active += 1
		end
		if c.Status == "Open" then
			counts.Open += 1
		end
		if c.Status == "Active" and c.Type == "ban" then
			counts.ActiveBans += 1
			if #bans < 25 then
				table.insert(bans, summary(c))
			end
		elseif c.Status == "Active" and c.Type == "mute" then
			counts.ActiveMutes += 1
			if #mutes < 25 then
				table.insert(mutes, summary(c))
			end
		end
		local age = t - c.CreatedAt
		if age < 86400 then
			counts.Today += 1
			local bucket = 24 - math.floor(age / 3600)
			activity[bucket] = (activity[bucket] or 0) + 1
			byMod[c.ModeratorName] = (byMod[c.ModeratorName] or 0) + 1
		end
		if c.Type == "warn" then
			if #recentWarn < 10 then
				table.insert(recentWarn, summary(c))
			end
		elseif c.Type ~= "investigation" and #recentPunish < 10 then
			table.insert(recentPunish, summary(c))
		end
	end
	local topMods = {}
	for name, n in pairs(byMod) do
		table.insert(topMods, { Name = name, Count = n })
	end
	table.sort(topMods, function(a, b)
		return a.Count > b.Count
	end)
	local online = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if PermissionSystem.Has(p, "panel.open") then
			local roles = PermissionSystem.GetRoles(p)
			table.insert(online, { Name = p.Name, DisplayName = p.DisplayName, UserId = p.UserId, Rank = roles[1] or "" })
		end
	end
	return {
		Counts = counts,
		Activity = activity,
		TopModerators = table.move(topMods, 1, math.min(5, #topMods), 1, {}),
		RecentPunishments = recentPunish,
		RecentWarnings = recentWarn,
		ActiveBans = bans,
		ActiveMutes = mutes,
		ModeratorsOnline = online,
		Reasons = CaseService.GetReasons(),
		Known = #all,
	}
end

function CaseService.Format(c: Case): string
	local parts = {
		("#%d %s %s"):format(c.Id, c.Type, c.TargetName),
		("[%s]"):format(c.Status),
		"by " .. c.ModeratorName,
	}
	if c.Duration then
		table.insert(parts, "for " .. c.Duration)
	end
	if c.Reason then
		table.insert(parts, '"' .. c.Reason .. '"')
	end
	table.insert(parts, os.date("!%Y-%m-%d %H:%M", c.CreatedAt) :: string)
	if c.Assignee then
		table.insert(parts, "assigned " .. c.Assignee)
	end
	return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- Reason templates (admin config key ReasonTemplates). Typing #name in a
-- command's arguments expands to the template text: ;ban Bob:1d #exploit
-- ---------------------------------------------------------------------------
local DEFAULT_REASONS = {
	{ Name = "exploit", Text = "Exploiting / using cheats" },
	{ Name = "spam", Text = "Spamming chat" },
	{ Name = "toxic", Text = "Toxic or abusive behaviour" },
	{ Name = "grief", Text = "Griefing other players" },
	{ Name = "scam", Text = "Scamming or trade fraud" },
	{ Name = "inappropriate", Text = "Inappropriate content" },
	{ Name = "alt", Text = "Alternate account evading a punishment" },
}

local function validReasons(v: any): boolean
	if type(v) ~= "table" or #v > 30 then
		return false
	end
	local seen = {}
	for _, r in ipairs(v) do
		if type(r) ~= "table" or type(r.Name) ~= "string" or type(r.Text) ~= "string" then
			return false
		end
		if not r.Name:match("^[%w_]+$") or #r.Name > 20 or #r.Text == 0 or #r.Text > 120 or seen[r.Name] then
			return false
		end
		seen[r.Name] = true
	end
	return true
end

ConfigService.Define("ReasonTemplates", DEFAULT_REASONS, validReasons)

function CaseService.GetReasons(): { { Name: string, Text: string } }
	local v = ConfigService.Get("ReasonTemplates")
	return if type(v) == "table" then v else DEFAULT_REASONS
end

function CaseService.FindReason(name: string): string?
	local lower = name:lower()
	for _, r in ipairs(CaseService.GetReasons()) do
		if r.Name:lower() == lower then
			return r.Text
		end
	end
	return nil
end

function CaseService.SetReason(name: string, text: string?, actor: Player?): (boolean, string)
	if not name:match("^[%w_]+$") or #name > 20 then
		return false, "Template names are letters, digits and _ (max 20)."
	end
	local list = table.clone(CaseService.GetReasons())
	local lower = name:lower()
	for i = #list, 1, -1 do
		if list[i].Name:lower() == lower then
			table.remove(list, i)
		end
	end
	if text then
		if #text == 0 or #text > 120 then
			return false, "Template text is 1-120 characters."
		end
		table.insert(list, { Name = lower, Text = text })
	end
	if #list > 30 then
		return false, "At most 30 reason templates."
	end
	local ok, err = ConfigService.Set("ReasonTemplates", list, actor)
	if not ok then
		return false, err or "Could not save."
	end
	return true, if text then ("Reason #%s = %s"):format(lower, text) else ("Removed reason #%s."):format(lower)
end

-- Replaces "#name" tokens with the template's words. Returns the new list
-- and whether anything changed. Unknown #words are left alone.
function CaseService.ExpandReasons(args: { string }): ({ string }, boolean)
	local out, changed = {}, false
	for _, word in ipairs(args) do
		local name = word:match("^#([%w_]+)$")
		local text = name and CaseService.FindReason(name)
		if text then
			changed = true
			for w in text:gmatch("%S+") do
				table.insert(out, w)
			end
		else
			table.insert(out, word)
		end
	end
	return out, changed
end

CommandRegistry.AddHook("Before", function(def, ctx)
	if def.Name ~= "reasons" and type(ctx.Arguments) == "table" and #ctx.Arguments > 0 then
		local expanded, changed = CaseService.ExpandReasons(ctx.Arguments)
		if changed then
			ctx.Arguments = expanded
		end
	end
	return nil
end, "ReasonTemplates")

-- ---------------------------------------------------------------------------
-- Automatic case creation from moderation commands
-- ---------------------------------------------------------------------------
local LOCAL_TYPES = { ban = "ban", kick = "kick", mute = "mute", warn = "warn", jail = "jail" }
local GLOBAL_TYPES = { gban = "ban", gkick = "kick", gwarn = "warn" }
local REVOKES = {
	unmute = { "mute" },
	unjail = { "jail" },
	gunban = { "ban" },
	unban = { "ban" },
}

function CaseService.OnCommand(def: any, ctx: any, result: any)
	if type(result) ~= "table" or not result.Success or not ctx.Executor then
		return
	end
	local name = def.Name
	local executor = ctx.Executor
	local reason = CommandRegistry.AuditFields(def, executor, ctx).Reason
	local source = ctx.Source
	if LOCAL_TYPES[name] then
		for _, target in ipairs(ctx.Targets or {}) do
			CaseService.Record({
				Type = LOCAL_TYPES[name],
				TargetId = target.UserId,
				TargetName = target.Name,
				ModeratorId = executor.UserId,
				ModeratorName = executor.Name,
				Reason = reason,
				Duration = if name == "ban" or name == "mute" then (ctx.Modifier or "forever") else nil,
				Source = source,
			})
		end
	elseif GLOBAL_TYPES[name] and type(ctx.CaseTarget) == "table" then
		CaseService.Record({
			Type = GLOBAL_TYPES[name],
			TargetId = ctx.CaseTarget.UserId,
			TargetName = ctx.CaseTarget.Name,
			ModeratorId = executor.UserId,
			ModeratorName = executor.Name,
			Reason = reason,
			Duration = if name == "gban" then ctx.Arguments[2] else nil,
			Global = true,
			Source = source,
		})
	elseif REVOKES[name] then
		local ids = {}
		for _, target in ipairs(ctx.Targets or {}) do
			table.insert(ids, target.UserId)
		end
		if type(ctx.CaseTarget) == "table" then
			table.insert(ids, ctx.CaseTarget.UserId)
		end
		for _, id in ipairs(ids) do
			CaseService.Revoke(id, REVOKES[name], executor)
		end
	end
end

CommandRegistry.AddHook("After", CaseService.OnCommand, "CaseService")

-- Escalation and other automatic actions (Warn.lua) record through this.
function CaseService.RecordSystem(kind: string, target: Player, reason: string, duration: string?): Case
	return CaseService.Record({
		Type = kind,
		TargetId = target.UserId,
		TargetName = target.Name,
		ModeratorId = 0,
		ModeratorName = "SYSTEM",
		Reason = reason,
		Duration = duration,
		Source = "escalation",
	})
end

if LIVE then
	task.spawn(function()
		while true do
			task.wait(10)
			CaseService.Flush()
		end
	end)
	task.spawn(function()
		while true do
			task.wait(60)
			for _, c in pairs(cases) do
				local before = c.Status
				refreshStatus(c)
				if c.Status ~= before then
					dirty[c.Id] = true
				end
			end
		end
	end)
	game:BindToClose(function()
		CaseService.Flush()
	end)
end

return CaseService
