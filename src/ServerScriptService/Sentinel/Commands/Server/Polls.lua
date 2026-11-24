--!strict
--[[
	Polls.lua (W23)

	Commands over Systems/PollService:
		;poll [options] question | a | b ...   start a poll in this server   (server.poll)
		;gpoll [options] question | a | b ...  start a poll in every server   (crossserver.poll)
		;vote [id] <option number|name>        vote (anyone)                  (Public)
		;endpoll [id]                          end now + announce results     (server.poll; global: crossserver.poll)
		;cancelpoll [id]                       cancel without results         (same)
		;polls [history]                       active polls / recent results  (panel.open)
	Options: time=<10s-1h|none> change=on|off results=live|end announce=on|off
	Without options after the question the poll is Yes | No.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local Systems = Sentinel:WaitForChild("Systems")
local PollService = require(Systems:WaitForChild("PollService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local OPTION_HELP = "Options: time=60|2m|none change=on|off results=live|end announce=on|off"
local USAGE = "question | option 1 | option 2 ..."

local function register(def: any)
	def.Category = "Server"
	def.Subcategory = "Polls"
	def.Aliases = def.Aliases or {}
	def.Undoable = false
	def.RequiresTarget = false
	CommandRegistry.Register(def)
end

local function canManage(executor: any, poll: any): (boolean, string?)
	if typeof(executor) ~= "Instance" then
		return true, nil
	end
	local node = if poll.Scope == "global" then "crossserver.poll" else "server.poll"
	if not PermissionSystem.Has(executor, node) then
		return false, ("You need %s to end this poll."):format(node)
	end
	return true, nil
end

local function start(ctx: Ctx, scope: string): Result
	local spec, err = PollService.ParseSpec(ctx.Arguments)
	if not spec then
		return { Success = false, Message = ("%s Usage: ;%s [options] %s. %s"):format(err or "", ctx.CommandName, USAGE, OPTION_HELP) }
	end
	local ok, message, poll = PollService.Create(ctx.Executor, spec, scope)
	if not ok or not poll then
		return { Success = false, Message = message }
	end
	if scope ~= "global" then
		return { Success = true, Message = message, PollId = poll.Id } :: any
	end
	local CrossServerService = require(Systems:WaitForChild("CrossServerService")) :: any
	local op, sendErr = CrossServerService.Send("polls", PollService.StartPayload(poll), {
		Actor = CrossServerService.ActorOf(ctx.Executor),
		Label = "poll",
		History = true,
	})
	if not op or op.Status == "failed" then
		-- Still runs here; the other servers just won't see it.
		return { Success = true, Message = ("%s Other servers couldn't be reached: %s"):format(message, tostring(sendErr or (op and op.Error))), PollId = poll.Id } :: any
	end
	local final = CrossServerService.WaitFor(op.Id, 2.5) or op
	return { Success = true, Message = ("Global %s - %s."):format((message:gsub("^Poll", "poll")),CrossServerService.Describe(final)), PollId = poll.Id } :: any
end

register({
	Name = "poll",
	Aliases = { "createpoll", "startpoll" },
	Description = "Starts a poll in this server. Players vote on a card on their screen (or with ;vote).",
	Usage = "/poll text...",
	ArgHints = { text = { Description = "Optional time= change= results= announce= words, then the question, then | option | option" } },
	Examples = { "poll Best map? | Desert | Forest | City", "poll time=2m results=end Another round?", "poll time=none change=off Pick a team | Red | Blue" },
	Permission = "server.poll",
	Cooldown = 3,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return start(ctx, "server")
	end,
})

register({
	Name = "gpoll",
	Aliases = { "globalpoll" },
	Description = "Starts a poll in every server. Votes from all servers are added up live.",
	Usage = "/gpoll text...",
	ArgHints = { text = { Description = "Optional time= change= results= announce= words, then the question, then | option | option" } },
	Examples = { "gpoll Next event? | Obby race | Treasure hunt | PvP" },
	Permission = "crossserver.poll",
	Cooldown = 5,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return start(ctx, "global")
	end,
})

-- "option" may be a number or (the start of) an option's text.
local function optionIndex(poll: any, value: string): number?
	local n = tonumber(value)
	if n then
		return math.floor(n)
	end
	local lower = value:lower()
	local found = nil
	for k, option in ipairs(poll.Options) do
		if option:lower() == lower then
			return k
		end
		if option:lower():sub(1, #lower) == lower then
			if found then
				return nil -- ambiguous
			end
			found = k
		end
	end
	return found
end

register({
	Name = "vote",
	Aliases = { "pollvote" },
	Description = "Votes in a poll: the option's number or name. Without an id it votes in the newest poll.",
	Usage = "/vote text...",
	ArgHints = { text = { Description = "[poll id] option number or name" } },
	Examples = { "vote 2", "vote Forest", "vote a1b2c3 1" },
	Permission = "poll.vote",
	Public = true,
	Cooldown = 1,
	Log = false,
	NoHistory = true,
	Execute = function(ctx: Ctx): Result
		local args = ctx.Arguments
		if #args == 0 then
			return { Success = false, Message = "Usage: ;vote [poll id] <option number or name>" }
		end
		local poll, pollId, rest = nil, nil, args
		if #args >= 2 and PollService.Get(args[1]) then
			pollId = args[1]
			rest = table.move(args, 2, #args, 1, {})
		end
		local found, err = PollService.Find(pollId)
		poll = found
		if not poll then
			return { Success = false, Message = err or "There is no active poll." }
		end
		local index = optionIndex(poll, table.concat(rest, " "))
		if not index then
			return { Success = false, Message = ("No single option matches \"%s\"."):format(table.concat(rest, " ")) }
		end
		local executor = ctx.Executor
		if typeof(executor) ~= "Instance" then
			return { Success = false, Message = "Only players can vote." }
		end
		local ok, message = PollService.Vote(executor :: Player, poll.Id, index)
		return { Success = ok, Message = message }
	end,
})

local function endCommand(ctx: Ctx, cancel: boolean): Result
	local poll, err = PollService.Find(ctx.Arguments[1])
	if not poll then
		return { Success = false, Message = err or "There is no active poll." }
	end
	local allowed, why = canManage(ctx.Executor, poll)
	if not allowed then
		return { Success = false, Message = why }
	end
	local ok, message = PollService.End(ctx.Executor, poll.Id, cancel)
	return { Success = ok, Message = message }
end

register({
	Name = "endpoll",
	Aliases = { "closepoll", "stoppoll" },
	Description = "Ends a poll now and announces the results (the newest poll without an id).",
	Usage = "/endpoll [id]",
	Examples = { "endpoll", "endpoll a1b2c3" },
	Permission = "server.poll",
	Cooldown = 1,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return endCommand(ctx, false)
	end,
})

register({
	Name = "cancelpoll",
	Aliases = { "deletepoll" },
	Description = "Cancels a poll without announcing results.",
	Usage = "/cancelpoll [id]",
	Permission = "server.poll",
	Cooldown = 1,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return endCommand(ctx, true)
	end,
})

register({
	Name = "polls",
	Aliases = { "pollhistory", "pollresults" },
	Description = "Lists active polls with their live results, or `history` for recent results.",
	Usage = "/polls [history]",
	ArgHints = { history = { Type = "choice", Choices = { "history" } } },
	Permission = "panel.open",
	Cooldown = 1,
	Log = false,
	NoHistory = true,
	Execute = function(ctx: Ctx): Result
		local lines = {}
		if (ctx.Arguments[1] or ""):lower() == "history" or ctx.CommandName == "pollhistory" then
			for _, r in ipairs(PollService.History(8)) do
				local parts = {}
				for k, option in ipairs(r.Options or {}) do
					table.insert(parts, ("%s %d"):format(option, (r.Counts or {})[k] or 0))
				end
				table.insert(lines, ("[%s] %s %s (%s): %s"):format(os.date("!%m-%d %H:%M", r.EndedAt or 0), r.Id, r.Question, r.Status, table.concat(parts, ", ")))
			end
			return { Success = true, Message = if #lines == 0 then "No finished polls yet." else table.concat(lines, "\n") }
		end
		for _, p in ipairs(PollService.Active()) do
			local left = if p.EndsAt > 0 then ("%ds left"):format(math.max(0, p.EndsAt - os.time())) else "no timer"
			table.insert(lines, ("%s [%s, %s] %s"):format(p.Id, p.Scope, left, PollService.ResultText(p)))
		end
		return { Success = true, Message = if #lines == 0 then "No active polls. Start one with ;poll question | a | b" else table.concat(lines, "\n") }
	end,
})

return true
