--!strict
--[[
	ReportService.lua (W14)

	Purpose:
		Player reports. Any player can report another player in the server
		(;report or the report form). A report carries a category, the
		reporter's description and evidence: the reported player's recent
		chat (captured server-side, filtered), both players' positions and
		distance, the server, and links / text the reporter or staff add.
		Staff work the queue: claim / assign, change status, discuss in
		internal notes, link the moderation case they opened.

	Status:
		Open        new, nobody working on it
		InProgress  claimed / assigned to a staff member
		Resolved    action taken (optionally linked to a case)
		Dismissed   no action needed
		"Pending" (dashboard, queue default) = Open + InProgress.

	Storage (DataStore Sentinel_Reports_v1), same pattern as CaseService:
		Counter            next report number (UpdateAsync)
		Report_<id>        full report incl. evidence + notes
		Index              newest <= 500 summaries (no evidence / notes)
		Writes are queued and flushed every 10 s and on close. Outside a
		running game everything stays in memory (tests).

	Abuse limits: one report per ReportCooldown seconds per reporter, at
	most 5 pending reports per reporter, not yourself, and the same reporter
	can't report the same player twice while that report is pending.

	Public API:
		ReportService.Submit(reporter, target, category, description, evidence?) -> (report?, err?)
		ReportService.Get(id) -> report?
		ReportService.Search(filter?, cursor?, limit?) -> { Reports, Cursor?, Total }
		ReportService.ParseQuery(text) -> filter
		ReportService.SetStatus(id, status, actor, note?, caseId?) -> (ok, msg)
		ReportService.Assign(id, actor, staff?) -> (ok, msg)
		ReportService.AddNote(id, actor, text, isEvidence?) -> (ok, msg)
		ReportService.PendingCount() -> number
		ReportService.Changed : Signal(report)  (UI push)
		ReportService.CATEGORIES, STATUSES
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Logger = require(Core:WaitForChild("Logger"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))
local TextFilterService = require(script.Parent:WaitForChild("TextFilterService"))

local ReportService = {}

local LIVE = RunService:IsRunning() and RunService:IsServer()
local store = if LIVE then DataStoreService:GetDataStore("Sentinel_Reports_v1") else nil

local INDEX_MAX = 500
local NOTES_MAX = 50
local CHAT_KEEP = 15
local PENDING_PER_REPORTER = 5

ReportService.STATUSES = { "Open", "InProgress", "Resolved", "Dismissed" }
ReportService.CATEGORIES = { "Exploiting", "Harassment", "Inappropriate", "Scamming", "Spam", "Griefing", "Other" }

export type Evidence = { Kind: string, Text: string, At: number, By: string? }
export type Note = { ById: number, By: string, Text: string, At: number, Evidence: boolean? }
export type Report = {
	Id: number,
	ReporterId: number,
	ReporterName: string,
	TargetId: number,
	TargetName: string,
	Category: string,
	Description: string,
	Evidence: { Evidence }?,
	EvidenceCount: number?,
	Status: string,
	Assignee: string?,
	CaseId: number?,
	Resolution: string?,
	Server: string?,
	CreatedAt: number,
	UpdatedAt: number,
	Notes: { Note }?,
	NoteCount: number?,
}

-- Fires with a summary whenever a report is created or changes (UIBridge
-- pushes it to staff).
local listeners: { (Report, string) -> () } = {}
function ReportService.OnChanged(fn: (Report, string) -> ())
	table.insert(listeners, fn)
end
local function emit(r: Report, what: string)
	for _, fn in ipairs(listeners) do
		task.spawn(fn, r, what)
	end
end

local reports: { [number]: Report } = {}
local index: { Report } = {}
local indexLoadedAt = -math.huge
local dirty: { [number]: boolean } = {}
local localCounter = 0
local lastReportAt: { [number]: number } = {}

local function now(): number
	return os.time()
end

local function summary(r: Report): Report
	local s = table.clone(r)
	s.NoteCount = if r.Notes then #r.Notes else (r.NoteCount or 0)
	s.EvidenceCount = if r.Evidence then #r.Evidence else (r.EvidenceCount or 0)
	s.Notes = nil
	s.Evidence = nil
	return s
end

local function markDirty(r: Report)
	r.UpdatedAt = math.max(now(), r.UpdatedAt or 0)
	reports[r.Id] = r
	dirty[r.Id] = true
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
		warn("[Sentinel.ReportService] report counter unavailable: " .. tostring(value))
	end
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

local function mergeSummaries(list: { Report }, updates: { Report }): { Report }
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

function ReportService.Flush()
	if not store or next(dirty) == nil then
		dirty = {}
		return
	end
	local batch = dirty
	dirty = {}
	local summaries = {}
	for id in pairs(batch) do
		local r = reports[id]
		if r then
			local ok, err = pcall(function()
				store:SetAsync("Report_" .. id, r)
			end)
			if not ok then
				warn(("[Sentinel.ReportService] saving report %d failed: %s"):format(id, tostring(err)))
				dirty[id] = true
			end
			table.insert(summaries, summary(r))
		end
	end
	pcall(function()
		store:UpdateAsync("Index", function(old)
			return mergeSummaries(if type(old) == "table" then old else {}, summaries)
		end)
	end)
	index = mergeSummaries(index, summaries)
end

local function fetch(id: number): Report?
	local r = reports[id]
	if r then
		return r
	end
	if store then
		local ok, value = pcall(function()
			return store:GetAsync("Report_" .. id)
		end)
		if ok and type(value) == "table" then
			reports[id] = value
			return value
		end
	end
	return nil
end

function ReportService.Get(id: number): Report?
	if type(id) ~= "number" then
		return nil
	end
	return fetch(id)
end

local function allKnown(): { Report }
	loadIndex()
	local seen, out = {}, {}
	for _, r in pairs(reports) do
		seen[r.Id] = true
		table.insert(out, r)
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

local function isPending(r: Report): boolean
	return r.Status == "Open" or r.Status == "InProgress"
end

-- W15 Player Explorer: open / in-progress reports filed against a player.
function ReportService.PendingAgainst(userId: number): number
	local n = 0
	for _, r in ipairs(allKnown()) do
		if r.TargetId == userId and isPending(r) then
			n += 1
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Chat capture (evidence): the last few messages of every player, filtered
-- for broadcast the moment they are captured (staff are other users).
-- ---------------------------------------------------------------------------
local chatLog: { [number]: { Evidence } } = {}

function ReportService.NoteChat(player: Player, message: string)
	if type(message) ~= "string" or message == "" then
		return
	end
	local list = chatLog[player.UserId]
	if not list then
		list = {}
		chatLog[player.UserId] = list
	end
	local entry: Evidence = { Kind = "chat", Text = "", At = now() }
	table.insert(list, entry)
	while #list > CHAT_KEEP do
		table.remove(list, 1)
	end
	-- Commands typed in chat are not evidence of anything.
	if message:match("^[;:!%./%-?>]%a") then
		entry.Text = "(command)"
		return
	end
	task.spawn(function()
		if LIVE then
			entry.Text = TextFilterService.ForBroadcast(player.UserId, message:sub(1, 200)) or "(could not be filtered)"
		else
			entry.Text = message:sub(1, 200)
		end
	end)
end

function ReportService.RecentChat(userId: number): { Evidence }
	local out = {}
	for _, e in ipairs(chatLog[userId] or {}) do
		table.insert(out, table.clone(e))
	end
	return out
end

if LIVE then
	local function watch(player: Player)
		player.Chatted:Connect(function(message)
			ReportService.NoteChat(player, message)
		end)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p)
		-- Keep the log a little longer: a report often comes right after
		-- the offender leaves.
		task.delay(300, function()
			if not Players:GetPlayerByUserId(p.UserId) then
				chatLog[p.UserId] = nil
				lastReportAt[p.UserId] = nil
			end
		end)
	end)
end

local function position(p: any): Vector3?
	local character = if typeof(p) == "Instance" then (p :: Player).Character else nil
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function fmtVec(v: Vector3): string
	return ("%d, %d, %d"):format(math.round(v.X), math.round(v.Y), math.round(v.Z))
end

-- ---------------------------------------------------------------------------
-- Submit
-- ---------------------------------------------------------------------------
local function matchCategory(text: string?): string?
	local t = (text or ""):lower()
	for _, c in ipairs(ReportService.CATEGORIES) do
		if c:lower() == t or (#t >= 3 and c:lower():sub(1, #t) == t) then
			return c
		end
	end
	return nil
end
ReportService.MatchCategory = matchCategory

-- reporter: Player (or {UserId, Name} in tests). target: Player or
-- {UserId, Name}. evidence: optional list of strings (links / text).
function ReportService.Submit(reporter: any, target: any, category: string?, description: string?, evidence: { string }?): (Report?, string?)
	if ConfigService.Get("ReportsEnabled") == false then
		return nil, "Reports are turned off in this game."
	end
	if not target or not target.UserId then
		return nil, "Pick a player to report."
	end
	if target.UserId == reporter.UserId then
		return nil, "You can't report yourself."
	end
	local cat = matchCategory(category) or "Other"
	local desc = if type(description) == "string" then description:gsub("^%s+", ""):gsub("%s+$", "") else ""
	if #desc < 5 then
		return nil, "Describe what happened (at least a few words)."
	end
	local t = now()
	local cooldown = ConfigService.Get("ReportCooldown") or 60
	local last = lastReportAt[reporter.UserId]
	if last and t - last < cooldown then
		return nil, ("Please wait %ds before sending another report."):format(cooldown - (t - last))
	end
	local pending = 0
	for _, r in ipairs(allKnown()) do
		if r.ReporterId == reporter.UserId and isPending(r) then
			pending += 1
			if r.TargetId == target.UserId then
				return nil, ("You already reported %s (report #%d is still being reviewed)."):format(target.Name, r.Id)
			end
		end
	end
	if pending >= PENDING_PER_REPORTER then
		return nil, "You have too many reports waiting for review. Please wait for staff to handle them."
	end
	lastReportAt[reporter.UserId] = t

	local filteredDesc = if LIVE then TextFilterService.ForBroadcast(reporter.UserId, desc:sub(1, 500)) else desc:sub(1, 500)
	if not filteredDesc then
		lastReportAt[reporter.UserId] = nil
		return nil, "Your description could not be checked by the text filter. Try again."
	end

	local items: { Evidence } = {}
	for _, e in ipairs(ReportService.RecentChat(target.UserId)) do
		table.insert(items, e)
	end
	local rp, tp = position(reporter), position(target)
	if tp then
		table.insert(items, {
			Kind = "position",
			Text = ("%s at %s%s"):format(target.Name, fmtVec(tp), if rp then (", %d studs from %s"):format(math.round((rp - tp).Magnitude), reporter.Name) else ""),
			At = t,
		})
	end
	for i, text in ipairs(evidence or {}) do
		if i > 5 or type(text) ~= "string" or text == "" then
			continue
		end
		local clean = if LIVE then TextFilterService.ForBroadcast(reporter.UserId, text:sub(1, 200)) else text:sub(1, 200)
		if clean then
			table.insert(items, { Kind = "reporter", Text = clean, At = t, By = reporter.Name })
		end
	end

	local r: Report = {
		Id = nextId(),
		ReporterId = reporter.UserId,
		ReporterName = tostring(reporter.Name),
		TargetId = target.UserId,
		TargetName = tostring(target.Name),
		Category = cat,
		Description = filteredDesc,
		Evidence = items,
		Status = "Open",
		Server = Logger.GetServerId(),
		CreatedAt = t,
		UpdatedAt = t,
		Notes = {},
	}
	markDirty(r)
	Logger.Write({
		Executor = tostring(r.ReporterId),
		ExecutorName = r.ReporterName,
		Command = "report",
		Action = "moderation.report.create",
		Target = r.TargetName,
		TargetIds = { r.TargetId },
		Reason = cat,
		Result = "Success",
		Severity = "Info",
		Message = ("Report #%d: %s reported %s (%s)"):format(r.Id, r.ReporterName, r.TargetName, cat),
	})
	emit(summary(r), "created")
	return r, nil
end

-- ---------------------------------------------------------------------------
-- Staff actions
-- ---------------------------------------------------------------------------
local function addNote(r: Report, actor: any, text: string, evidence: boolean?)
	r.Notes = r.Notes or {}
	local notes = r.Notes :: { Note }
	table.insert(notes, { ById = actor.UserId, By = actor.Name, Text = text:sub(1, 400), At = now(), Evidence = evidence or nil })
	while #notes > NOTES_MAX do
		table.remove(notes, 1)
	end
end

function ReportService.AddNote(id: number, actor: any, text: string, isEvidence: boolean?): (boolean, string)
	local r = fetch(id)
	if not r then
		return false, ("There is no report #%s."):format(tostring(id))
	end
	if isEvidence then
		r.Evidence = r.Evidence or {}
		table.insert(r.Evidence :: { Evidence }, { Kind = "staff", Text = text:sub(1, 300), At = now(), By = actor.Name })
	else
		addNote(r, actor, text)
	end
	markDirty(r)
	emit(summary(r), "note")
	return true, if isEvidence then ("Evidence added to report #%d."):format(id) else ("Note added to report #%d."):format(id)
end

function ReportService.SetStatus(id: number, status: string, actor: any, note: string?, caseId: number?): (boolean, string)
	local r = fetch(id)
	if not r then
		return false, ("There is no report #%s."):format(tostring(id))
	end
	local wanted: string? = nil
	for _, s in ipairs(ReportService.STATUSES) do
		if s:lower() == status:lower() then
			wanted = s
		end
	end
	if not wanted then
		return false, "Status must be open, inprogress, resolved or dismissed."
	end
	local before = r.Status
	if before == wanted and not caseId then
		return false, ("Report #%d is already %s."):format(id, wanted)
	end
	r.Status = wanted :: string
	if caseId then
		r.CaseId = caseId
	end
	if wanted == "InProgress" and not r.Assignee then
		r.Assignee = actor.Name
	end
	if wanted == "Resolved" or wanted == "Dismissed" then
		r.Resolution = if note and note ~= "" then note:sub(1, 300) else nil
	end
	addNote(r, actor, ("Status %s -> %s%s%s"):format(
		before,
		wanted :: string,
		if caseId then (" (case #%d)"):format(caseId) else "",
		if note and note ~= "" then ": " .. note:sub(1, 300) else ""
	))
	markDirty(r)
	Logger.NoteChange("report #" .. id, "Status", before, wanted :: string, if typeof(actor) == "Instance" then actor else nil, "moderation.report")
	emit(summary(r), "status")
	return true, ("Report #%d is now %s."):format(id, wanted :: string)
end

function ReportService.Assign(id: number, actor: any, staff: string?): (boolean, string)
	local r = fetch(id)
	if not r then
		return false, ("There is no report #%s."):format(tostring(id))
	end
	local before = r.Assignee
	r.Assignee = staff
	if staff and r.Status == "Open" then
		r.Status = "InProgress"
	elseif not staff and r.Status == "InProgress" then
		r.Status = "Open"
	end
	addNote(r, actor, if staff then "Assigned to " .. staff else "Unassigned")
	markDirty(r)
	Logger.NoteChange("report #" .. id, "Assignee", before or "none", staff or "none", if typeof(actor) == "Instance" then actor else nil, "moderation.report")
	emit(summary(r), "assign")
	return true, if staff then ("Report #%d assigned to %s."):format(id, staff) else ("Report #%d unassigned."):format(id)
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------
export type Filter = {
	Status: string?, -- a status, "pending" (Open + InProgress) or "all"
	Player: string?, -- reporter or target (name or id)
	Target: string?,
	Reporter: string?,
	Assignee: string?, -- name, or "none"
	Category: string?,
	Text: string?,
	Id: number?,
}

local function contains(hay: any, needle: string): boolean
	return type(hay) == "string" and hay:lower():find(needle, 1, true) ~= nil
end

function ReportService.Matches(r: Report, f: Filter?): boolean
	if not f then
		return isPending(r)
	end
	if f.Id then
		return r.Id == f.Id
	end
	local status = (f.Status or "pending"):lower()
	if status == "pending" then
		if not isPending(r) then
			return false
		end
	elseif status ~= "all" and r.Status:lower() ~= status then
		return false
	end
	if f.Player then
		local p = f.Player:lower()
		if not (contains(r.TargetName, p) or contains(r.ReporterName, p) or tostring(r.TargetId) == p or tostring(r.ReporterId) == p) then
			return false
		end
	end
	if f.Target then
		local p = f.Target:lower()
		if not (contains(r.TargetName, p) or tostring(r.TargetId) == p) then
			return false
		end
	end
	if f.Reporter then
		local p = f.Reporter:lower()
		if not (contains(r.ReporterName, p) or tostring(r.ReporterId) == p) then
			return false
		end
	end
	if f.Assignee then
		local a = f.Assignee:lower()
		if a == "none" then
			if r.Assignee then
				return false
			end
		elseif not contains(r.Assignee, a) then
			return false
		end
	end
	if f.Category and r.Category:lower() ~= f.Category:lower() then
		return false
	end
	if f.Text then
		local t = f.Text:lower()
		if not (contains(r.Description, t) or contains(r.Category, t) or contains(r.TargetName, t) or contains(r.ReporterName, t) or contains(r.Resolution, t)) then
			return false
		end
	end
	return true
end

-- "status:all player:Bob assignee:me category:spam #12 free text"
-- `me` in assignee: is replaced by the caller's name (pass actorName).
function ReportService.ParseQuery(text: string?, actorName: string?): Filter
	local f: Filter = {}
	local free = {}
	for word in (text or ""):gmatch("%S+") do
		local key, value = word:match("^(%a+):(.+)$")
		local id = word:match("^#(%d+)$")
		if id then
			f.Id = tonumber(id)
		elseif key then
			key = key:lower()
			if key == "status" or key == "s" then
				f.Status = value
			elseif key == "player" or key == "p" then
				f.Player = value
			elseif key == "target" or key == "t" then
				f.Target = value
			elseif key == "reporter" or key == "by" then
				f.Reporter = value
			elseif key == "assignee" or key == "a" then
				f.Assignee = if value:lower() == "me" and actorName then actorName else value
			elseif key == "category" or key == "c" then
				f.Category = matchCategory(value) or value
			else
				table.insert(free, word)
			end
		elseif word:lower() == "all" or word:lower() == "open" or word:lower() == "resolved" or word:lower() == "dismissed" or word:lower() == "inprogress" then
			f.Status = word
		elseif word:lower() == "mine" and actorName then
			f.Assignee = actorName
		else
			table.insert(free, word)
		end
	end
	if #free > 0 then
		f.Text = table.concat(free, " ")
	end
	return f
end

function ReportService.SanitizeFilter(raw: any): Filter
	local f: Filter = {}
	if type(raw) ~= "table" then
		return f
	end
	for _, key in ipairs({ "Status", "Player", "Target", "Reporter", "Assignee", "Category", "Text" }) do
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

function ReportService.Search(f: Filter?, cursor: any, limit: number?): { [string]: any }
	if f and f.Id and not reports[f.Id] then
		fetch(f.Id)
	end
	local offset = if type(cursor) == "number" and cursor >= 0 then math.floor(cursor) else 0
	local max = math.clamp(limit or 40, 1, 100)
	local matched = {}
	local counts = { Open = 0, InProgress = 0, Resolved = 0, Dismissed = 0 }
	for _, r in ipairs(allKnown()) do
		counts[r.Status] = (counts[r.Status] or 0) + 1
		if ReportService.Matches(r, f or {}) then
			table.insert(matched, summary(r))
		end
	end
	return {
		Reports = table.move(matched, offset + 1, math.min(offset + max, #matched), 1, {}),
		Total = #matched,
		Counts = counts,
		Cursor = if offset + max < #matched then offset + max else nil,
	}
end

function ReportService.PendingCount(): number
	local n = 0
	for _, r in ipairs(allKnown()) do
		if isPending(r) then
			n += 1
		end
	end
	return n
end

function ReportService.Format(r: Report): string
	local parts = {
		("#%d %s -> %s"):format(r.Id, r.ReporterName, r.TargetName),
		("[%s]"):format(r.Status),
		r.Category,
	}
	if r.Assignee then
		table.insert(parts, "assigned " .. r.Assignee)
	end
	if r.CaseId then
		table.insert(parts, ("case #%d"):format(r.CaseId))
	end
	return table.concat(parts, " ") .. ": " .. r.Description:sub(1, 80)
end

-- Test hook: lets the same reporter send again right away.
function ReportService._ForgetCooldown(userId: number)
	lastReportAt[userId] = nil
end

-- Test hook: forget everything (memory mode only).
function ReportService._Reset()
	if store then
		return
	end
	reports, index, dirty, lastReportAt, chatLog = {}, {}, {}, {}, {}
	localCounter = 0
end

if LIVE then
	task.spawn(function()
		while true do
			task.wait(10)
			ReportService.Flush()
		end
	end)
	game:BindToClose(function()
		ReportService.Flush()
	end)
end

return ReportService
