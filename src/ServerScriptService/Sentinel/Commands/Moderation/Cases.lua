--!strict
--[[
	Cases.lua (W12)

	Moderation case commands on top of Systems/CaseService:
		;cases [query...]                 search (player: mod: type: status: since: #id, free text)
		;case <id>                        show one case with its notes
		;caseopen <player> <summary...>   open an investigation case
		;casenote <id> <text...>          add a note (internal staff discussion)
		;caseclose <id> [note...]         close a case
		;casereopen <id> [note...]        reopen a case
		;caseassign <id> <staff|me|none>  set the staff member responsible
		;reasons [add|remove] [name] [text...]  reason templates (#name in any reason)

	Viewing / notes need moderation.cases; open / close / reopen / assign
	need moderation.cases too, editing reason templates needs config.edit.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local CaseService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CaseService"))
local TextFilterService = require(Sentinel:WaitForChild("Systems"):WaitForChild("TextFilterService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function caseId(text: string?): number?
	if not text then
		return nil
	end
	return tonumber((text:gsub("^#", "")))
end

local function rest(ctx: Ctx, from: number): string
	return table.concat(table.move(ctx.Arguments, from, #ctx.Arguments, 1, {}), " ")
end

local function register(def: any)
	def.Category = "Moderation"
	def.Subcategory = "Cases"
	def.Aliases = def.Aliases or {}
	def.Permission = def.Permission or "moderation.cases"
	def.Undoable = false
	def.RequiresTarget = false
	if def.Log == nil then
		def.Log = true
	end
	CommandRegistry.Register(def)
end

local function staffText(ctx: Ctx, text: string): string?
	-- Notes are only shown to staff, but they are typed by people and stored:
	-- filter like any other stored text.
	return TextFilterService.ForBroadcast(ctx.Executor.UserId, text)
end

register({
	Name = "cases",
	Aliases = { "caselist" },
	Description = "Searches moderation cases. Filters: player: mod: type: status: (active, open, closed...) since: #id, plus free text.",
	Usage = "/cases [query...]",
	Log = false,
	Examples = { "cases status:active", "cases player:Bob type:ban", "cases mod:Alice since:7d" },
	Execute = function(ctx: Ctx): Result
		local filter, err = CaseService.ParseQuery(table.concat(ctx.Arguments, " "))
		if not filter then
			return { Success = false, Message = err or "Bad query." }
		end
		local found = CaseService.Search(filter, nil, 15)
		if #found.Cases == 0 then
			return { Success = true, Message = "No cases match." }
		end
		local lines = { ("%d case(s)%s:"):format(found.Total, if found.Total > #found.Cases then (", newest %d"):format(#found.Cases) else "") }
		for _, c in ipairs(found.Cases) do
			table.insert(lines, CaseService.Format(c))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "case",
	Aliases = { "viewcase" },
	Description = "Shows one moderation case with its notes.",
	Usage = "/case id",
	Log = false,
	Examples = { "case 12" },
	Execute = function(ctx: Ctx): Result
		local id = caseId(ctx.Arguments[1])
		local c = id and CaseService.Get(id)
		if not c then
			return { Success = false, Message = "Usage: ;case <number> (see ;cases)." }
		end
		local lines = { CaseService.Format(c) }
		for _, note in ipairs(c.Notes or {}) do
			table.insert(lines, ("  %s %s: %s"):format(os.date("!%m-%d %H:%M", note.At) :: string, note.By, note.Text))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "caseopen",
	Aliases = { "newcase" },
	Description = "Opens an investigation case about a player (online name, or username / UserId).",
	Usage = "/caseopen player summary...",
	Examples = { "caseopen Bob Reported for trade scams" },
	Execute = function(ctx: Ctx): Result
		local who = ctx.Arguments[1]
		if not who or #ctx.Arguments < 2 then
			return { Success = false, Message = "Usage: ;caseopen <player> <summary>" }
		end
		local userId, name = tonumber(who), who
		local online = Players:FindFirstChild(who)
		if online and online:IsA("Player") then
			userId, name = online.UserId, online.Name
		elseif not userId then
			local ok, id = pcall(function()
				return Players:GetUserIdFromNameAsync(who)
			end)
			if not ok or not id then
				return { Success = false, Message = ("No Roblox user called %s."):format(who) }
			end
			userId = id
		else
			local ok, real = pcall(function()
				return Players:GetNameFromUserIdAsync(userId :: number)
			end)
			name = if ok and real then real else who
		end
		local summary = staffText(ctx, rest(ctx, 2))
		if not summary then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local c = CaseService.Record({
			Type = "investigation",
			TargetId = userId,
			TargetName = name,
			ModeratorId = ctx.Executor.UserId,
			ModeratorName = ctx.Executor.Name,
			Reason = summary,
			Source = (ctx :: any).Source,
		})
		return { Success = true, Message = ("Opened case #%d about %s."):format(c.Id, name) }
	end,
})

register({
	Name = "casenote",
	Aliases = { "cnote" },
	Description = "Adds a note to a case (internal staff discussion).",
	Usage = "/casenote id text...",
	Examples = { "casenote 12 Checked the trade logs, looks legit" },
	Execute = function(ctx: Ctx): Result
		local id = caseId(ctx.Arguments[1])
		if not id or #ctx.Arguments < 2 then
			return { Success = false, Message = "Usage: ;casenote <id> <text>" }
		end
		local text = staffText(ctx, rest(ctx, 2))
		if not text then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local ok, msg = CaseService.AddNote(id, ctx.Executor, text)
		return { Success = ok, Message = msg }
	end,
})

local function statusCommand(name: string, aliases: { string }, status: string, description: string)
	register({
		Name = name,
		Aliases = aliases,
		Description = description,
		Usage = ("/%s id [note...]"):format(name),
		Execute = function(ctx: Ctx): Result
			local id = caseId(ctx.Arguments[1])
			if not id then
				return { Success = false, Message = ("Usage: ;%s <id> [note]"):format(name) }
			end
			local note = nil
			if #ctx.Arguments > 1 then
				note = staffText(ctx, rest(ctx, 2))
				if not note then
					return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
				end
			end
			local ok, msg = CaseService.SetStatus(id, status, ctx.Executor, note)
			return { Success = ok, Message = msg }
		end,
	})
end

statusCommand("caseclose", { "closecase" }, "Closed", "Closes a case.")
statusCommand("casereopen", { "reopencase" }, "Open", "Reopens a case.")

register({
	Name = "caseassign",
	Aliases = { "assigncase" },
	Description = "Sets the staff member responsible for a case (me, a name, or none).",
	Usage = "/caseassign id staff",
	Examples = { "caseassign 12 me", "caseassign 12 none" },
	Execute = function(ctx: Ctx): Result
		local id = caseId(ctx.Arguments[1])
		local who = ctx.Arguments[2]
		if not id or not who then
			return { Success = false, Message = "Usage: ;caseassign <id> <staff|me|none>" }
		end
		local staff: string? = who
		if who:lower() == "me" then
			staff = ctx.Executor.Name
		elseif who:lower() == "none" then
			staff = nil
		else
			local p = Players:FindFirstChild(who)
			if p and p:IsA("Player") then
				if not PermissionSystem.Has(p, "panel.open") then
					return { Success = false, Message = p.Name .. " is not staff." }
				end
				staff = p.Name
			elseif not who:match("^[%w_]+$") or #who > 20 then
				return { Success = false, Message = "Give a username." }
			end
		end
		local ok, msg = CaseService.Assign(id, ctx.Executor, staff)
		return { Success = ok, Message = msg }
	end,
})

register({
	Name = "reasons",
	Aliases = { "reason", "reasontemplates" },
	Description = "Lists punishment reason templates; #name in any reason expands to the template. add / remove need config.edit.",
	Usage = "/reasons [action] [name] [text...]",
	ArgHints = { action = { Type = "choice", Choices = { "list", "add", "remove" }, Description = "list (default), add or remove" } },
	Permission = "moderation.cases",
	Log = true,
	Examples = { "reasons", "reasons add afk Idle in a competitive round", "reasons remove afk" },
	Execute = function(ctx: Ctx): Result
		local action = (ctx.Arguments[1] or "list"):lower()
		if action == "list" then
			local lines = {}
			for _, r in ipairs(CaseService.GetReasons()) do
				table.insert(lines, ("#%s  %s"):format(r.Name, r.Text))
			end
			return { Success = true, Message = if #lines == 0 then "No reason templates." else table.concat(lines, "\n") }
		end
		if not PermissionSystem.Has(ctx.Executor, "config.edit") then
			return { Success = false, Message = "Changing reason templates needs config.edit." }
		end
		local name = ctx.Arguments[2]
		if not name then
			return { Success = false, Message = ("Usage: ;reasons %s <name>%s"):format(action, if action == "add" then " <text>" else "") }
		end
		name = name:gsub("^#", "")
		if action == "add" or action == "set" then
			local text = staffText(ctx, rest(ctx, 3))
			if not text or text == "" then
				return { Success = false, Message = "Give the reason text." }
			end
			local ok, msg = CaseService.SetReason(name, text, ctx.Executor)
			return { Success = ok, Message = msg }
		elseif action == "remove" or action == "delete" then
			if not CaseService.FindReason(name) then
				return { Success = false, Message = ("There is no reason #%s."):format(name) }
			end
			local ok, msg = CaseService.SetReason(name, nil, ctx.Executor)
			return { Success = ok, Message = msg }
		end
		return { Success = false, Message = "Use ;reasons, ;reasons add <name> <text> or ;reasons remove <name>." }
	end,
})

return true
