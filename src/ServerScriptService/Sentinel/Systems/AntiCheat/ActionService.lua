--!strict
--[[
	ActionService.lua (Sentinel AntiCheat)

	Purpose:
		The action ladder. When a player's score enters a higher band, the
		band's action for the current mode runs (Bands.Observe / Balanced /
		Strict, editable):
		  log      nothing more (the flag is already logged)
		  alert    log + staff alert (AlertService + Control Center bell)
		  correct  silent correction: snap back to the last valid position or
		           restore health - fixes the effect without punishing
		  warn     PunishmentService.AddWarning + a case
		  kick     kick + a case
		  tempban  temporary server ban (Bands.TempBanMinutes) + a case
		  review   queue for staff review (Review Queue page)
		  ban      game ban (Bans.BanDays, 15 days; permanent only when
		           Bans.AllowPermanent is on) + a case + removal on every server

		Rules (enforced in Decide, which is pure and unit tested):
		  1. Observe never punishes: only log / alert.
		  2. An automatic game ban needs Bands.RequireApproval off AND a
		     pattern of at least Bands.PatternModules different modules within
		     Bands.PatternMinutes; otherwise it becomes a review item that
		     proposes the ban (staff approve it through ;acban, which uses
		     Sentinel's owner-approval flow).
		  3. Panic (Core.Panic) and Testing mode turn every action into an
		     alert at most; detections keep logging.
		  4. Each band acts once; the player must decay below it to re-arm.

		Every action stores evidence (the flag list, the last 10 s of
		positions, ping, server FPS, active exemptions), writes an audit-log
		entry (action "anticheat.action.<kind>") and, for warn / kick /
		tempban / ban, a CaseService case.

	Public API:
		ActionService.Decide(input) -> { Action, Band, Proposed?, Note? }   (pure)
		ActionService.Execute(player, decision, flag, ctx) -> string (what happened)
		ActionService.SetProviders({ Ban = fn(userId, record), ServerBan = fn(record),
		    Correct = fn(player, flag) -> boolean, Alert = fn(entry), Push = fn(kind, data) })
		ActionService.Ban(target {UserId, Name}, reason, days, actorName, flags?) -> (ok, msg)
		ActionService.BanLength(bansConfig, wantPermanent?) -> (days (0 = permanent), note?)  (pure)
		ActionService.IsAntiCheatBan(record) -> boolean                                    (pure)
		ActionService.Recent(limit?) / CountToday() / ByType(hours)
		Review queue: AddReview(item) / GetReview(id) / Reviews(status?) /
		  OpenReviews() / Dismiss(id, by) / Assign(id, by) / Escalate(id, by) /
		  Approve(userId, by) / AddReviewNote(id, by, text)
		ActionService._Clear()
--]]

local Players = game:GetService("Players")

local Sentinel = script.Parent.Parent.Parent
local Systems = Sentinel:WaitForChild("Systems")
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))

local ActionService = {}

local PUNISHING = { correct = true, warn = true, kick = true, tempban = true, ban = true }
ActionService.PUNISHING = PUNISHING

local providers: { [string]: any } = {}
local actions: { any } = {} -- newest first
local reviews: { any } = {}
local nextReview = 0

function ActionService.SetProviders(p: { [string]: any })
	for k, v in pairs(p) do
		providers[k] = v
	end
end

-- ---------------------------------------------------------------------------
-- Decision (pure)
-- input = { Mode, Panic, Testing, Band, LastBand, Bands (config), Modules (recent distinct) }
-- ---------------------------------------------------------------------------
function ActionService.Decide(input: any): any
	local band = input.Band or 1
	if band <= (input.LastBand or 1) then
		return nil
	end
	local bands = input.Bands or {}
	local mode = tostring(input.Mode or "observe"):lower()
	local key = if mode == "strict" then "Strict" elseif mode == "balanced" then "Balanced" else "Observe"
	local list = bands[key] or { "log", "alert", "alert", "alert", "alert" }
	local action = list[band] or "log"
	local note: string? = nil
	local proposed: string? = nil

	if key == "Observe" and action ~= "log" then
		action = "alert" -- rule 1
	end
	if action == "ban" then
		local needed = bands.PatternModules or 3
		local modules = input.Modules or {}
		if bands.RequireApproval ~= false then
			action, proposed, note = "review", "ban", "game bans need staff approval"
		elseif #modules < needed then
			action, proposed, note = "review", "ban", ("pattern needs %d modules, saw %d"):format(needed, #modules)
		end
	end
	if (input.Panic or input.Testing) and PUNISHING[action] then
		note = if input.Panic then "panic mode: " .. action .. " skipped" else "testing mode: " .. action .. " skipped"
		action = "alert"
	elseif (input.Panic or input.Testing) and action == "review" then
		note = if input.Panic then "panic mode: review only" else "testing mode: review skipped"
		if input.Testing then
			action = "alert"
		end
	end
	return { Action = action, Band = band, Proposed = proposed, Note = note }
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------
local function record(kind: string, player: any, flag: any, note: string?, extra: any?)
	local entry = {
		Kind = kind,
		UserId = player.UserId,
		Name = player.Name,
		Time = os.time(),
		FlagId = if flag then flag.Id else nil,
		Module = if flag then flag.Module else nil,
		Score = if flag then flag.ScoreAfter else nil,
		Note = note,
		By = if extra and extra.By then extra.By else "SYSTEM",
	}
	table.insert(actions, 1, entry)
	while #actions > 500 do
		table.remove(actions)
	end
	Logger.Write({
		Executor = if extra and extra.ById then tostring(extra.ById) else "SYSTEM",
		ExecutorName = entry.By,
		Command = "anticheat." .. kind,
		Action = "anticheat.action." .. kind,
		Arguments = {},
		Target = player.Name,
		TargetIds = { player.UserId },
		Reason = if flag then flag.Reason else note,
		Result = "Success",
		Severity = if PUNISHING[kind] then "Warning" else "Info",
		Message = ("AntiCheat %s on %s%s%s"):format(
			kind,
			player.Name,
			if flag then (" (%s, score %d)"):format(flag.Module, math.floor(flag.ScoreAfter or 0)) else "",
			if note then " - " .. note else ""
		),
		Source = "anticheat",
	} :: any)
	if providers.Push then
		pcall(providers.Push, "action", entry)
	end
	return entry
end
ActionService.Record = record

local function lazy(name: string): any
	local ok, mod = pcall(function()
		return require(Systems:WaitForChild(name, 2) :: ModuleScript)
	end)
	return if ok then mod else nil
end

local function openCase(kind: string, player: any, reason: string, duration: string?)
	local CaseService = lazy("CaseService")
	if not CaseService then
		return nil
	end
	local ok, c = pcall(function()
		return CaseService.Record({
			Type = kind,
			TargetId = player.UserId,
			TargetName = player.Name,
			ModeratorId = 0,
			ModeratorName = "Sentinel AntiCheat",
			Reason = reason,
			Duration = duration,
			Source = "anticheat",
		})
	end)
	return if ok then c else nil
end

local function reasonOf(flag: any): string
	return ("[AntiCheat] %s: %s"):format(tostring(flag.Module), tostring(flag.Reason)):sub(1, 280)
end

-- How long an anti-cheat ban lasts. wantPermanent nil = the configured
-- DefaultType. Permanent bans are refused unless Bans.AllowPermanent is on
-- (risky); then the ban is a BanDays one and the note says why.
function ActionService.BanLength(bans: any, wantPermanent: boolean?): (number, string?)
	local cfg = if type(bans) == "table" then bans else {}
	local days = math.max(1, math.floor(tonumber(cfg.BanDays) or 15))
	local permanent = if wantPermanent == nil then cfg.DefaultType == "permanent" else wantPermanent
	if permanent then
		if cfg.AllowPermanent == true then
			return 0, nil
		end
		return days, ("permanent bans are disabled (Bans.AllowPermanent) - banned for %d day(s)"):format(days)
	end
	return days, nil
end

-- A ban record / ban-list entry written by the anti-cheat (automatic or ;acban).
function ActionService.IsAntiCheatBan(record: any): boolean
	if type(record) ~= "table" then
		return false
	end
	local reason = tostring(record.Reason or "")
	return reason:sub(1, 11) == "[AntiCheat]" or record.BannedByName == "Sentinel AntiCheat"
end

function ActionService.Ban(target: any, reason: string, days: number, actorName: string, flags: { any }?): (boolean, string)
	if not providers.Ban then
		return false, "the ban store is not available"
	end
	local now = os.time()
	local expiresAt = if days and days > 0 then now + days * 86400 else math.huge
	local ok = providers.Ban(target.UserId, {
		BannedBy = 0,
		BannedByName = actorName,
		TargetName = target.Name,
		Reason = reason,
		IssuedAt = now,
		ExpiresAt = expiresAt,
	})
	if not ok then
		return false, "the ban could not be saved"
	end
	openCase("ban", target, reason, if days and days > 0 then ("%dd"):format(days) else "permanent")
	local player = Players:GetPlayerByUserId(target.UserId)
	if player then
		player:Kick("Banned: " .. reason)
	end
	if providers.ShareBan then
		pcall(providers.ShareBan, target, reason)
	end
	return true, ("Banned %s %s."):format(target.Name, if days and days > 0 then ("for %d day(s)"):format(days) else "permanently")
end

-- Runs a decision. ctx = { Config = { Bands }, Flags = recent flags of the player }
function ActionService.Execute(player: any, decision: any, flag: any, ctx: any?): string
	local action = decision.Action
	local bands = (ctx and ctx.Bands) or {}
	if action == "log" then
		return "logged"
	elseif action == "alert" then
		if providers.Alert then
			pcall(providers.Alert, {
				Severity = if flag.Severity >= 7 then "critical" else "warning",
				Title = ("AntiCheat: %s"):format(player.Name),
				Text = ("%s (sev %d, score %d)%s"):format(
					flag.Reason,
					flag.Severity,
					math.floor(flag.ScoreAfter or 0),
					if decision.Note then " - " .. decision.Note else ""
				),
			})
		end
		record("alert", player, flag, decision.Note)
		return "staff alerted"
	elseif action == "correct" then
		local done = false
		if providers.Correct then
			local ok, result = pcall(providers.Correct, player, flag)
			done = ok and result == true
		end
		record("correct", player, flag, if done then "corrected" else "nothing to correct")
		return if done then "silently corrected" else "logged (nothing to correct)"
	elseif action == "warn" then
		local PunishmentService = lazy("PunishmentService")
		if PunishmentService then
			pcall(PunishmentService.AddWarning, player, { UserId = 0, Name = "Sentinel AntiCheat" }, reasonOf(flag))
		end
		openCase("warn", player, reasonOf(flag))
		record("warn", player, flag, decision.Note)
		return "warned"
	elseif action == "kick" then
		openCase("kick", player, reasonOf(flag))
		record("kick", player, flag, decision.Note)
		if typeof(player) == "Instance" then
			player:Kick("You were removed by Sentinel AntiCheat. If this was a mistake, please rejoin.")
		end
		return "kicked"
	elseif action == "tempban" then
		local minutes = bands.TempBanMinutes or 60
		if providers.ServerBan then
			pcall(providers.ServerBan, {
				UserId = player.UserId,
				Name = player.Name,
				Reason = reasonOf(flag),
				By = "Sentinel AntiCheat",
				At = os.time(),
				ExpiresAt = os.time() + minutes * 60,
			})
		end
		openCase("ban", player, "[Server ban] " .. reasonOf(flag), ("%dm"):format(minutes))
		record("tempban", player, flag, ("%d min server ban"):format(minutes))
		return "server-banned"
	elseif action == "review" then
		local item = ActionService.AddReview({
			UserId = player.UserId,
			Name = player.Name,
			Score = flag.ScoreAfter or 0,
			Modules = (ctx and ctx.Modules) or { flag.Module },
			Reason = flag.Reason,
			Proposed = decision.Proposed or "review",
			Flags = (ctx and ctx.FlagIds) or { flag.Id },
		})
		record("review", player, flag, decision.Note)
		return ("queued for review (#%d)"):format(item.Id)
	elseif action == "ban" then
		local days, note = ActionService.BanLength(ctx and ctx.Bans)
		local ok, message = ActionService.Ban(player, reasonOf(flag), days, "Sentinel AntiCheat")
		record("ban", player, flag, message .. (if note then " (" .. note .. ")" else ""))
		return if ok then "banned" else message
	end
	return "logged"
end

function ActionService.Recent(limit: number?): { any }
	local out = {}
	for i = 1, math.min(#actions, limit or 100) do
		table.insert(out, table.clone(actions[i]))
	end
	return out
end

function ActionService.CountToday(): number
	local dayStart = os.time() - os.time() % 86400
	local n = 0
	for _, a in ipairs(actions) do
		if a.Time < dayStart then
			break
		end
		if a.Kind ~= "log" then
			n += 1
		end
	end
	return n
end

function ActionService.ByType(hours: number): { [string]: number }
	local since = os.time() - hours * 3600
	local out = {}
	for _, a in ipairs(actions) do
		if a.Time < since then
			break
		end
		out[a.Kind] = (out[a.Kind] or 0) + 1
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Review queue (this server, memory; every change is audit-logged by the caller)
-- ---------------------------------------------------------------------------
function ActionService.AddReview(fields: any): any
	-- One open item per player: update it instead of stacking.
	for _, item in ipairs(reviews) do
		if item.UserId == fields.UserId and (item.Status == "Open" or item.Status == "Assigned" or item.Status == "Escalated") then
			item.Score = math.max(item.Score, fields.Score or 0)
			for _, m in ipairs(fields.Modules or {}) do
				if not table.find(item.Modules, m) then
					table.insert(item.Modules, m)
				end
			end
			for _, id in ipairs(fields.Flags or {}) do
				if not table.find(item.Flags, id) then
					table.insert(item.Flags, id)
				end
			end
			if fields.Proposed == "ban" then
				item.Proposed = "ban"
			end
			item.Reason = fields.Reason or item.Reason
			item.UpdatedAt = os.time()
			return item
		end
	end
	nextReview += 1
	local item = {
		Id = nextReview,
		UserId = fields.UserId,
		Name = fields.Name,
		Score = fields.Score or 0,
		Modules = table.clone(fields.Modules or {}),
		Reason = fields.Reason or "",
		Proposed = fields.Proposed or "review",
		Status = "Open",
		AssignedTo = nil,
		CreatedAt = os.time(),
		UpdatedAt = os.time(),
		Notes = {},
		Flags = table.clone(fields.Flags or {}),
	}
	table.insert(reviews, 1, item)
	while #reviews > 200 do
		table.remove(reviews)
	end
	if providers.Push then
		pcall(providers.Push, "review", item)
	end
	return item
end

function ActionService.GetReview(id: number): any
	for _, item in ipairs(reviews) do
		if item.Id == id then
			return item
		end
	end
	return nil
end

function ActionService.Reviews(status: string?): { any }
	local out = {}
	for _, item in ipairs(reviews) do
		if not status or status == "" or status == "all" or item.Status == status then
			table.insert(out, item)
		end
	end
	return out
end

function ActionService.OpenReviews(): number
	local n = 0
	for _, item in ipairs(reviews) do
		if item.Status == "Open" or item.Status == "Assigned" or item.Status == "Escalated" then
			n += 1
		end
	end
	return n
end

local function closed(item: any): boolean
	return item.Status == "Approved" or item.Status == "Dismissed"
end

function ActionService.Dismiss(id: number, by: string): (any, string?)
	local item = ActionService.GetReview(id)
	if not item then
		return nil, "no review item #" .. tostring(id)
	end
	if closed(item) then
		return nil, ("#%d is already %s"):format(id, item.Status:lower())
	end
	item.Status = "Dismissed"
	item.ClosedBy = by
	item.UpdatedAt = os.time()
	return item, nil
end

function ActionService.Assign(id: number, by: string): (any, string?)
	local item = ActionService.GetReview(id)
	if not item then
		return nil, "no review item #" .. tostring(id)
	end
	if closed(item) then
		return nil, ("#%d is already %s"):format(id, item.Status:lower())
	end
	item.AssignedTo = by
	if item.Status == "Open" then
		item.Status = "Assigned"
	end
	item.UpdatedAt = os.time()
	return item, nil
end

function ActionService.Escalate(id: number, by: string): (any, string?)
	local item = ActionService.GetReview(id)
	if not item then
		return nil, "no review item #" .. tostring(id)
	end
	if closed(item) then
		return nil, ("#%d is already %s"):format(id, item.Status:lower())
	end
	item.Status = "Escalated"
	item.EscalatedBy = by
	item.UpdatedAt = os.time()
	return item, nil
end

-- A ban went through for this player: close their open items.
function ActionService.Approve(userId: number, by: string): number
	local n = 0
	for _, item in ipairs(reviews) do
		if item.UserId == userId and not closed(item) then
			item.Status = "Approved"
			item.ClosedBy = by
			item.UpdatedAt = os.time()
			n += 1
		end
	end
	return n
end

function ActionService.AddReviewNote(id: number, by: string, text: string): (any, string?)
	local item = ActionService.GetReview(id)
	if not item then
		return nil, "no review item #" .. tostring(id)
	end
	table.insert(item.Notes, { By = by, Text = text:sub(1, 300), At = os.time() })
	item.UpdatedAt = os.time()
	return item, nil
end

function ActionService._Clear()
	table.clear(actions)
	table.clear(reviews)
	nextReview = 0
end

return ActionService
