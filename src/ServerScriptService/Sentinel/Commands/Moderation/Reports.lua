--!strict
--[[
	Reports.lua (W14)

	Reports & appeals commands on top of Systems/ReportService,
	Systems/AppealService and Systems/PlayerFormsService.

	Everyone (Public):
		;report [player] [category] [what happened...]
		    no arguments / only a player: opens the report form
		    everything: files the report directly
		;appeal                             opens the appeal form

	Staff - reports (node moderation.reports):
		;reports [query...]                 queue (default pending). Filters:
		                                    status: player: target: reporter:
		                                    assignee: (me/none) category: #id, mine, all
		;reportview <id>                    one report with evidence + notes
		;reportclaim <id>                   assign to yourself (In progress)
		;reportassign <id> <staff|me|none>
		;reportstatus <id> <open|inprogress|resolved|dismissed> [#case] [note...]
		;reportresolve <id> [#case] [note...]
		;reportdismiss <id> [note...]
		;reportnote <id> <text...>          internal staff discussion
		;reportevidence <id> <text...>      add evidence (link, observation)

	Staff - appeals (node moderation.appeals; accepting also needs the
	punishment's node: moderation.ban / moderation.mute / moderation.warn /
	player.jail):
		;appeals [query...]                 queue (default pending). Filters:
		                                    status: player: type: assignee: #id, mine, all
		;appealview <id>
		;appealaccept <id> [note...]        lifts the punishment, revokes the case
		;appealreject <id> [note...]
		;appealnote <id> <text...>
		;appealassign <id> <staff|me|none>
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))
local EventBus = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("EventBus"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local ReportService = require(Systems:WaitForChild("ReportService"))
local AppealService = require(Systems:WaitForChild("AppealService"))
local PlayerFormsService = require(Systems:WaitForChild("PlayerFormsService"))
local CaseService = require(Systems:WaitForChild("CaseService"))
local ChatModerationService = require(Systems:WaitForChild("ChatModerationService"))
local PunishmentService = require(Systems:WaitForChild("PunishmentService"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))
local BanCommand = require(script.Parent:WaitForChild("Ban"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function num(text: string?): number?
	if not text then
		return nil
	end
	return tonumber((text:gsub("^#", "")))
end

local function rest(ctx: Ctx, from: number): string
	return table.concat(table.move(ctx.Arguments, from, #ctx.Arguments, 1, {}), " ")
end

local function staffText(ctx: Ctx, text: string): string?
	if text == "" then
		return ""
	end
	return TextFilterService.ForBroadcast(ctx.Executor.UserId, text)
end

local function register(def: any, sub: string)
	def.Category = "Moderation"
	def.Subcategory = sub
	def.Aliases = def.Aliases or {}
	def.Undoable = false
	def.RequiresTarget = false
	if def.Log == nil then
		def.Log = true
	end
	CommandRegistry.Register(def)
end

local function fmtTime(t: number): string
	return os.date("!%m-%d %H:%M", t) :: string
end

-- "me" / "none" / a staff name -> assignee (nil = none)
local function assignee(ctx: Ctx, who: string?): (boolean, string?)
	if not who then
		return false, nil
	end
	local w = who:lower()
	if w == "none" or w == "nobody" then
		return true, nil
	elseif w == "me" then
		return true, ctx.Executor.Name
	end
	local p = Players:FindFirstChild(who)
	return true, if p and p:IsA("Player") then p.Name else who
end

-- ---------------------------------------------------------------------------
-- Lifting punishments when an appeal is accepted
-- ---------------------------------------------------------------------------
AppealService.SetBanReader(function(userId: number)
	return BanCommand.GetActiveBan(userId)
end)

AppealService.SetLifters({
	ban = function(userId: number, _actor: any, a: any): (boolean, string)
		if not BanCommand.GetActiveBan(userId) then
			return true, "The ban had already ended."
		end
		if not BanCommand.SetBan(userId, nil) then
			return false, "the ban could not be removed (DataStore error)"
		end
		EventBus.Publish("Player.Unbanned", userId)
		return true, ("%s is unbanned."):format(a.Name)
	end,
	mute = function(userId: number, _actor: any, a: any): (boolean, string)
		ChatModerationService.UnmuteUserId(userId)
		return true, ("%s is unmuted."):format(a.Name)
	end,
	jail = function(userId: number, actor: any, a: any): (boolean, string)
		local player = Players:GetPlayerByUserId(userId)
		if player and player:GetAttribute("SentinelJailed") and typeof(actor) == "Instance" then
			local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))
			CommandProcessor.Process(actor, "unjail " .. player.Name, { Confirmed = true, Source = "appeal" })
			return true, ("%s is released."):format(a.Name)
		end
		return true, "They are not jailed in this server."
	end,
	warn = function(userId: number, _actor: any, a: any): (boolean, string)
		local c = if a.CaseId then CaseService.Get(a.CaseId) else nil
		if c and PunishmentService.RemoveWarningNear(userId, c.CreatedAt) then
			return true, "The warning was removed."
		end
		return true, "No matching warning was found (it may have been cleared)."
	end,
})

-- ---------------------------------------------------------------------------
-- Player commands
-- ---------------------------------------------------------------------------
local function findOnline(name: string): Player?
	local lower = name:lower()
	local match: Player? = nil
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower() == lower or p.DisplayName:lower() == lower then
			return p
		end
		if p.Name:lower():sub(1, #lower) == lower then
			match = if match then nil else p
		end
	end
	return match
end

register({
	Name = "report",
	Aliases = { "reportplayer" },
	Description = "Reports a player to the staff team. With no arguments it opens the report form.",
	Usage = "/report [player] [category] [description...]",
	ArgHints = {
		player = { Type = "string", Description = "Who you are reporting (in this server)" },
		category = { Type = "choice", Choices = ReportService.CATEGORIES, Description = "What kind of problem" },
	},
	Permission = "player.report",
	Public = true,
	Cooldown = 2,
	Log = false,
	Examples = { "report", "report Bob", "report Bob scamming He took my items and left" },
	Execute = function(ctx: Ctx): Result
		local player = ctx.Executor :: Player
		local who = ctx.Arguments[1]
		local target = if who then findOnline(who) else nil
		if who and not target then
			return { Success = false, Message = ("No player called %s in this server."):format(who) }
		end
		if #ctx.Arguments < 3 then
			PlayerFormsService.Open(player, "report", { TargetId = if target then target.UserId else nil })
			return { Success = true, Message = "" }
		end
		local category = ReportService.MatchCategory(ctx.Arguments[2])
		local description = rest(ctx, if category then 3 else 2)
		local report, err = ReportService.Submit(player, target, category, description)
		if not report then
			PlayerFormsService.Notice(player, "error", "Report not sent", err or "")
			return { Success = false, Message = err or "Report not sent." }
		end
		local msg = ("Thanks! Report #%d about %s was sent to the staff team."):format(report.Id, report.TargetName)
		PlayerFormsService.Notice(player, "success", "Report sent", msg)
		return { Success = true, Message = msg }
	end,
}, "Reports")

register({
	Name = "appeal",
	Aliases = { "appealform" },
	Description = "Opens the appeal form to appeal one of your punishments (mute, jail, warning).",
	Usage = "/appeal",
	Permission = "player.appeal",
	Public = true,
	Cooldown = 2,
	Log = false,
	Examples = { "appeal" },
	Execute = function(ctx: Ctx): Result
		PlayerFormsService.Open(ctx.Executor :: Player, "appeal", {})
		return { Success = true, Message = "" }
	end,
}, "Appeals")

-- ---------------------------------------------------------------------------
-- Staff: reports
-- ---------------------------------------------------------------------------
local function reportOrFail(ctx: Ctx): (any, string?)
	local id = num(ctx.Arguments[1])
	local r = id and ReportService.Get(id)
	if not r then
		return nil, "Give a report number (see ;reports)."
	end
	return r, nil
end

register({
	Name = "reports",
	Aliases = { "reportqueue" },
	Permission = "moderation.reports",
	Description = "The report queue (pending by default). Filters: status: player: target: reporter: assignee: category: #id, mine, all.",
	Usage = "/reports [query...]",
	Log = false,
	Examples = { "reports", "reports mine", "reports all player:Bob", "reports category:exploiting" },
	Execute = function(ctx: Ctx): Result
		local found = ReportService.Search(ReportService.ParseQuery(table.concat(ctx.Arguments, " "), ctx.Executor.Name), nil, 15)
		if #found.Reports == 0 then
			return { Success = true, Message = "No reports match." }
		end
		local lines = { ("%d report(s)%s:"):format(found.Total, if found.Total > #found.Reports then (", newest %d"):format(#found.Reports) else "") }
		for _, r in ipairs(found.Reports) do
			table.insert(lines, ReportService.Format(r))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
}, "Reports")

register({
	Name = "reportview",
	Aliases = { "viewreport" },
	Permission = "moderation.reports",
	Description = "Shows one report with its evidence and staff notes.",
	Usage = "/reportview id",
	Log = false,
	Examples = { "reportview 4" },
	Execute = function(ctx: Ctx): Result
		local r, err = reportOrFail(ctx)
		if not r then
			return { Success = false, Message = err }
		end
		local lines = { ReportService.Format(r), "Description: " .. r.Description }
		for _, e in ipairs(r.Evidence or {}) do
			table.insert(lines, ("  [%s] %s%s"):format(e.Kind, e.Text, if e.By then " (" .. e.By .. ")" else ""))
		end
		for _, n in ipairs(r.Notes or {}) do
			table.insert(lines, ("  %s %s: %s"):format(fmtTime(n.At), n.By, n.Text))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
}, "Reports")

register({
	Name = "reportclaim",
	Aliases = { "claimreport" },
	Permission = "moderation.reports",
	Description = "Assigns a report to yourself and marks it in progress.",
	Usage = "/reportclaim id",
	Examples = { "reportclaim 4" },
	Execute = function(ctx: Ctx): Result
		local r, err = reportOrFail(ctx)
		if not r then
			return { Success = false, Message = err }
		end
		local ok, msg = ReportService.Assign(r.Id, ctx.Executor, ctx.Executor.Name)
		return { Success = ok, Message = msg }
	end,
}, "Reports")

register({
	Name = "reportassign",
	Permission = "moderation.reports",
	Description = "Sets the staff member handling a report (me, a name, or none).",
	Usage = "/reportassign id staff",
	Examples = { "reportassign 4 me", "reportassign 4 Alice", "reportassign 4 none" },
	Execute = function(ctx: Ctx): Result
		local r, err = reportOrFail(ctx)
		if not r then
			return { Success = false, Message = err }
		end
		local given, who = assignee(ctx, ctx.Arguments[2])
		if not given then
			return { Success = false, Message = "Usage: ;reportassign <id> <me|name|none>" }
		end
		local ok, msg = ReportService.Assign(r.Id, ctx.Executor, who)
		return { Success = ok, Message = msg }
	end,
}, "Reports")

-- Pulls an optional "#<case>" / "case:<id>" out of the words after the id.
local function statusWithCase(ctx: Ctx, status: string, from: number): Result
	local r, err = reportOrFail(ctx)
	if not r then
		return { Success = false, Message = err }
	end
	local words = table.move(ctx.Arguments, from, #ctx.Arguments, 1, {})
	local linked: number? = nil
	if words[1] then
		local c = words[1]:match("^#(%d+)$") or words[1]:match("^[Cc]ase:?#?(%d+)$")
		if c then
			linked = tonumber(c)
			table.remove(words, 1)
			if not CaseService.Get(linked :: number) then
				return { Success = false, Message = ("There is no case #%d."):format(linked :: number) }
			end
		end
	end
	local note = staffText(ctx, table.concat(words, " "))
	if not note then
		return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
	end
	local ok, msg = ReportService.SetStatus(r.Id, status, ctx.Executor, note, linked)
	if ok and linked then
		CaseService.AddNote(linked, ctx.Executor, ("Linked from report #%d (%s reported %s: %s)"):format(r.Id, r.ReporterName, r.TargetName, r.Category))
	end
	return { Success = ok, Message = msg }
end

register({
	Name = "reportstatus",
	Permission = "moderation.reports",
	Description = "Changes a report's status (open, inprogress, resolved, dismissed); optionally link a case with #<case>.",
	Usage = "/reportstatus id open|inprogress|resolved|dismissed [note...]",
	Examples = { "reportstatus 4 resolved #12 Banned for exploiting", "reportstatus 4 open" },
	Execute = function(ctx: Ctx): Result
		local status = ctx.Arguments[2]
		if not status then
			return { Success = false, Message = "Usage: ;reportstatus <id> <open|inprogress|resolved|dismissed> [#case] [note]" }
		end
		return statusWithCase(ctx, status, 3)
	end,
}, "Reports")

register({
	Name = "reportresolve",
	Aliases = { "resolvereport" },
	Permission = "moderation.reports",
	Description = "Marks a report resolved; link the case you opened with #<case>.",
	Usage = "/reportresolve id [note...]",
	Examples = { "reportresolve 4 #12 Banned 1d", "reportresolve 4 Warned in chat" },
	Execute = function(ctx: Ctx): Result
		return statusWithCase(ctx, "Resolved", 2)
	end,
}, "Reports")

register({
	Name = "reportdismiss",
	Aliases = { "dismissreport" },
	Permission = "moderation.reports",
	Description = "Dismisses a report (no action needed).",
	Usage = "/reportdismiss id [note...]",
	Examples = { "reportdismiss 4 No evidence of exploiting" },
	Execute = function(ctx: Ctx): Result
		return statusWithCase(ctx, "Dismissed", 2)
	end,
}, "Reports")

register({
	Name = "reportnote",
	Permission = "moderation.reports",
	Description = "Adds an internal staff note to a report.",
	Usage = "/reportnote id text...",
	Examples = { "reportnote 4 Watching him from spectate now" },
	Execute = function(ctx: Ctx): Result
		local r, err = reportOrFail(ctx)
		if not r or #ctx.Arguments < 2 then
			return { Success = false, Message = err or "Usage: ;reportnote <id> <text>" }
		end
		local text = staffText(ctx, rest(ctx, 2))
		if not text then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local ok, msg = ReportService.AddNote(r.Id, ctx.Executor, text)
		return { Success = ok, Message = msg }
	end,
}, "Reports")

register({
	Name = "reportevidence",
	Permission = "moderation.reports",
	Description = "Attaches evidence to a report (a clip link, an observation).",
	Usage = "/reportevidence id text...",
	Examples = { "reportevidence 4 Saw him fly through the wall at spawn" },
	Execute = function(ctx: Ctx): Result
		local r, err = reportOrFail(ctx)
		if not r or #ctx.Arguments < 2 then
			return { Success = false, Message = err or "Usage: ;reportevidence <id> <text>" }
		end
		local text = staffText(ctx, rest(ctx, 2))
		if not text then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local ok, msg = ReportService.AddNote(r.Id, ctx.Executor, text, true)
		return { Success = ok, Message = msg }
	end,
}, "Reports")

-- ---------------------------------------------------------------------------
-- Staff: appeals
-- ---------------------------------------------------------------------------
local function appealOrFail(ctx: Ctx): (any, string?)
	local id = num(ctx.Arguments[1])
	local a = id and AppealService.Get(id)
	if not a then
		return nil, "Give an appeal number (see ;appeals)."
	end
	return a, nil
end

register({
	Name = "appeals",
	Aliases = { "appealqueue" },
	Permission = "moderation.appeals",
	Description = "The appeal queue (pending by default). Filters: status: player: type: assignee: #id, mine, all.",
	Usage = "/appeals [query...]",
	Log = false,
	Examples = { "appeals", "appeals all", "appeals type:ban", "appeals player:Bob" },
	Execute = function(ctx: Ctx): Result
		local found = AppealService.Search(AppealService.ParseQuery(table.concat(ctx.Arguments, " "), ctx.Executor.Name), nil, 15)
		if #found.Appeals == 0 then
			return { Success = true, Message = "No appeals match." }
		end
		local lines = { ("%d appeal(s):"):format(found.Total) }
		for _, a in ipairs(found.Appeals) do
			table.insert(lines, AppealService.Format(a))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
}, "Appeals")

register({
	Name = "appealview",
	Aliases = { "viewappeal" },
	Permission = "moderation.appeals",
	Description = "Shows one appeal with the punishment and staff notes.",
	Usage = "/appealview id",
	Log = false,
	Examples = { "appealview 3" },
	Execute = function(ctx: Ctx): Result
		local a, err = appealOrFail(ctx)
		if not a then
			return { Success = false, Message = err }
		end
		local lines = {
			AppealService.Format(a),
			("Punishment: %s by %s, reason: %s"):format(a.Type, a.PunishedBy or "?", a.PunishReason or "none"),
			"Appeal: " .. a.Text,
		}
		for _, n in ipairs(a.Notes or {}) do
			table.insert(lines, ("  %s %s: %s"):format(fmtTime(n.At), n.By, n.Text))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
}, "Appeals")

local function decide(ctx: Ctx, accept: boolean): Result
	local a, err = appealOrFail(ctx)
	if not a then
		return { Success = false, Message = err }
	end
	local note = staffText(ctx, rest(ctx, 2))
	if not note then
		return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
	end
	;(ctx :: any).CaseTarget = { UserId = a.UserId, Name = a.Name }
	local ok, msg = AppealService.Decide(a.Id, ctx.Executor, accept, note)
	return { Success = ok, Message = msg }
end

register({
	Name = "appealaccept",
	Aliases = { "acceptappeal" },
	Permission = "moderation.appeals",
	Description = "Accepts an appeal: lifts the punishment (unban / unmute / release / remove the warning) and revokes the case.",
	Usage = "/appealaccept id [note...]",
	Examples = { "appealaccept 3 Fair point, first offence" },
	Execute = function(ctx: Ctx): Result
		return decide(ctx, true)
	end,
}, "Appeals")

register({
	Name = "appealreject",
	Aliases = { "rejectappeal" },
	Permission = "moderation.appeals",
	Description = "Rejects an appeal. The player can appeal that case again after the appeal cooldown.",
	Usage = "/appealreject id [note...]",
	Examples = { "appealreject 3 Clear evidence in the report" },
	Execute = function(ctx: Ctx): Result
		return decide(ctx, false)
	end,
}, "Appeals")

register({
	Name = "appealnote",
	Permission = "moderation.appeals",
	Description = "Adds an internal staff note to an appeal.",
	Usage = "/appealnote id text...",
	Examples = { "appealnote 3 Check the clip in report #4 first" },
	Execute = function(ctx: Ctx): Result
		local a, err = appealOrFail(ctx)
		if not a or #ctx.Arguments < 2 then
			return { Success = false, Message = err or "Usage: ;appealnote <id> <text>" }
		end
		local text = staffText(ctx, rest(ctx, 2))
		if not text then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local ok, msg = AppealService.AddNote(a.Id, ctx.Executor, text)
		return { Success = ok, Message = msg }
	end,
}, "Appeals")

register({
	Name = "appealassign",
	Permission = "moderation.appeals",
	Description = "Sets the staff member reviewing an appeal (me, a name, or none).",
	Usage = "/appealassign id staff",
	Examples = { "appealassign 3 me" },
	Execute = function(ctx: Ctx): Result
		local a, err = appealOrFail(ctx)
		if not a then
			return { Success = false, Message = err }
		end
		local given, who = assignee(ctx, ctx.Arguments[2])
		if not given then
			return { Success = false, Message = "Usage: ;appealassign <id> <me|name|none>" }
		end
		local ok, msg = AppealService.Assign(a.Id, ctx.Executor, who)
		return { Success = ok, Message = msg }
	end,
}, "Appeals")

return true
