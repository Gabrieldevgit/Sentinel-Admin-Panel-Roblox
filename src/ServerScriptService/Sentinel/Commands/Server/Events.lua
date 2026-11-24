--!strict
--[[
	Events.lua (W24)

	Commands over Systems/EventService:
		;event <preset> [options] [name]       start / schedule in this server  (server.event)
		;gevent <preset> [options] [name]      same, in every server            (crossserver.event)
		;scheduleevent <delay> <preset> ...    = ;event <preset> in=<delay> ...  (server.event)
		;stopevent [id|preset]                 stop (or cancel a scheduled one)  (server.event; global: crossserver.event)
		;events [history|presets]              running events + multipliers      (panel.open)
	Options: time=30m|2h|none in=5m announce=on|off coins=2 xp=2 gems=2 name=Word_Word
	Presets: doublecoins doublexp doublegems doubleall custom (+ EventService.Define).
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local Systems = Sentinel:WaitForChild("Systems")
local EventService = require(Systems:WaitForChild("EventService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local OPTION_HELP = "Options: time=30m|2h|none in=5m announce=on|off coins=2 xp=2 gems=2 name=Word_Word"

local function presetIds(): { string }
	local out = {}
	for _, def in ipairs(EventService.Presets()) do
		table.insert(out, def.Id)
	end
	return out
end

local function register(def: any)
	def.Category = "Server"
	def.Subcategory = "Events"
	def.Aliases = def.Aliases or {}
	def.Undoable = false
	def.RequiresTarget = false
	CommandRegistry.Register(def)
end

local function start(ctx: Ctx, scope: string, words: { string }): Result
	if #words == 0 then
		return { Success = false, Message = ("Usage: ;%s <preset> [options] [name]. Presets: %s. %s"):format(ctx.CommandName, table.concat(presetIds(), ", "), OPTION_HELP) }
	end
	local spec, err = EventService.ParseSpec(words)
	if not spec then
		return { Success = false, Message = ("%s %s"):format(err or "", OPTION_HELP) }
	end
	local ok, message, event = EventService.Create(ctx.Executor, spec, scope)
	if not ok or not event then
		return { Success = false, Message = message }
	end
	if scope ~= "global" then
		return { Success = true, Message = message, EventId = event.Id } :: any
	end
	local CrossServerService = require(Systems:WaitForChild("CrossServerService")) :: any
	local op, sendErr = CrossServerService.Send("evs", EventService.StartPayload(event), {
		Actor = if typeof(ctx.Executor) == "Instance" then CrossServerService.ActorOf(ctx.Executor) else nil,
		Label = "event",
		History = true,
	})
	if not op or op.Status == "failed" then
		-- Runs here; servers that start later still join it (Global list).
		return { Success = true, Message = ("%s Other servers couldn't be reached right now: %s"):format(message, tostring(sendErr or (op and op.Error))), EventId = event.Id } :: any
	end
	local final = CrossServerService.WaitFor(op.Id, 2.5) or op
	return { Success = true, Message = ("Global %s - %s."):format((message:gsub("^Event", "event")), CrossServerService.Describe(final)), EventId = event.Id } :: any
end

local PRESET_HINT = {
	Type = "choice",
	Choices = presetIds,
	Description = "doublecoins, doublexp, doublegems, doubleall or custom",
}

register({
	Name = "event",
	Aliases = { "startevent", "createevent" },
	Description = "Starts an event in this server (now, or later with in=). Multipliers apply to earned coins / XP / gems.",
	Usage = "/event preset [text...]",
	ArgHints = {
		preset = PRESET_HINT,
		text = { Description = "time= in= announce= coins= xp= gems= name= (custom events: the rest is the name)" },
	},
	Examples = { "event doublecoins time=30m", "event doublexp in=5m time=1h", "event custom coins=3 time=20m Weekend rush" },
	Permission = "server.event",
	Cooldown = 3,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return start(ctx, "server", ctx.Arguments)
	end,
})

register({
	Name = "gevent",
	Aliases = { "globalevent" },
	Description = "Starts an event in every server (servers that start later join it too).",
	Usage = "/gevent preset [text...]",
	ArgHints = {
		preset = PRESET_HINT,
		text = { Description = "time= in= announce= coins= xp= gems= name=" },
	},
	Examples = { "gevent doublecoins time=1h", "gevent doubleall in=10m time=2h" },
	Permission = "crossserver.event",
	Cooldown = 5,
	Log = true,
	Execute = function(ctx: Ctx): Result
		return start(ctx, "global", ctx.Arguments)
	end,
})

register({
	Name = "scheduleevent",
	Aliases = { "planevent" },
	Description = "Schedules an event in this server: ;scheduleevent 10m doublecoins time=30m.",
	Usage = "/scheduleevent delay preset [text...]",
	ArgHints = {
		delay = { Type = "string", Description = "When it starts: 30s, 10m, 2h", Suggestions = { "1m", "5m", "10m", "30m", "1h" } },
		preset = PRESET_HINT,
		text = { Description = "time= announce= coins= xp= gems= name=" },
	},
	Examples = { "scheduleevent 10m doublecoins time=30m", "scheduleevent 1h doubleall" },
	Permission = "server.event",
	Cooldown = 3,
	Log = true,
	Execute = function(ctx: Ctx): Result
		local args = ctx.Arguments
		if #args < 2 then
			return { Success = false, Message = "Usage: ;scheduleevent <delay> <preset> [options] (e.g. ;scheduleevent 10m doublecoins time=30m)" }
		end
		local words = { args[2], "in=" .. args[1] }
		for k = 3, #args do
			table.insert(words, args[k])
		end
		return start(ctx, "server", words)
	end,
})

register({
	Name = "stopevent",
	Aliases = { "endevent", "cancelevent" },
	Description = "Stops an event (or cancels a scheduled one). Without an id it stops the only running event.",
	Usage = "/stopevent [event]",
	ArgHints = { event = { Type = "string", Description = "Event id or preset name" } },
	Examples = { "stopevent", "stopevent a1b2c3", "stopevent doublecoins" },
	Permission = "server.event",
	Cooldown = 1,
	Log = true,
	Execute = function(ctx: Ctx): Result
		local event, err = EventService.Find(ctx.Arguments[1])
		if not event then
			return { Success = false, Message = err or "There is no active event." }
		end
		if event.Scope == "global" and typeof(ctx.Executor) == "Instance" and not PermissionSystem.Has(ctx.Executor, "crossserver.event") then
			return { Success = false, Message = "You need crossserver.event to stop a global event." }
		end
		local ok, message = EventService.Stop(ctx.Executor, event.Id)
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "events",
	Aliases = { "eventlist", "multipliers" },
	Description = "Lists running and scheduled events with the current multipliers; `history` for past events, `presets` for presets.",
	Usage = "/events [view]",
	ArgHints = { view = { Type = "choice", Choices = { "history", "presets" } } },
	Permission = "panel.open",
	Cooldown = 1,
	Log = false,
	NoHistory = true,
	Execute = function(ctx: Ctx): Result
		local view = (ctx.Arguments[1] or ""):lower()
		local lines = {}
		if view == "history" then
			for _, r in ipairs(EventService.History(10)) do
				local m = EventService.MultiplierText(r.Multipliers)
				table.insert(lines, ("[%s] %s %s (%s, %s)%s%s"):format(
					os.date("!%m-%d %H:%M", r.EndedAt or 0),
					tostring(r.Id),
					tostring(r.Name),
					tostring(r.Scope),
					tostring(r.Status),
					if m ~= "" then " " .. m else "",
					if r.EndedBy then " by " .. tostring(r.EndedBy) else ""
				))
			end
			return { Success = true, Message = if #lines == 0 then "No finished events yet." else table.concat(lines, "\n") }
		elseif view == "presets" then
			for _, def in ipairs(EventService.Presets()) do
				local m = EventService.MultiplierText(def.Multipliers)
				table.insert(lines, ("%s - %s%s"):format(def.Id, def.Name, if m ~= "" then " (" .. m .. ")" else ""))
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		end
		for _, e in ipairs(EventService.Active()) do
			table.insert(lines, EventService.Describe(e))
		end
		local m = EventService.MultiplierText(EventService.Multipliers())
		table.insert(lines, if m ~= "" then "Multipliers now: " .. m else "Multipliers now: none (all x1)")
		if #lines == 1 then
			table.insert(lines, 1, "No event is running. Start one with ;event doublecoins time=30m")
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

return true
