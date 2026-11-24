--!strict
--[[
	StaffFeeds.lua (M-panel gaps: chat log + alerts feed)

		;chatlog [player:name] [text...]   recent server chat, newest first (panel.open)
		;clearchatlog                      empty this server's chat log (moderation.chatlog)
		;alerts [n] [kind]                 recent alerts (panel.open)
		;clearalerts                       empty the alerts feed (moderation.alerts)

	Dependencies: CommandRegistry, ChatLogService, AlertService.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local Systems = Sentinel:WaitForChild("Systems")
local ChatLogService = require(Systems:WaitForChild("ChatLogService"))
local AlertService = require(Systems:WaitForChild("AlertService"))

local function clock(t: number): string
	return os.date("!%H:%M:%S", t) :: string
end

CommandRegistry.Register({
	Name = "chatlog",
	Aliases = { "chatlogs", "serverchat" },
	Description = "Shows this server's recent chat (every player, newest first). Filter with player:<name> and/or words. The Moderation > Chat Log page shows the same with search.",
	Usage = "/chatlog [query...]",
	Permission = "panel.open",
	Category = "Moderation",
	Subcategory = "Chat",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Examples = { "chatlog", "chatlog player:bob", "chatlog scam" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local found = ChatLogService.Search(ChatLogService.ParseQuery(table.concat(ctx.Arguments, " ")), 10)
		if #found == 0 then
			return { Success = true, Message = "No chat lines match." }
		end
		local parts = {}
		for _, line in ipairs(found) do
			table.insert(parts, ("[%s] %s: %s"):format(clock(line.Time), line.Name, line.Text))
		end
		return { Success = true, Message = table.concat(parts, "\n") }
	end,
})

CommandRegistry.Register({
	Name = "clearchatlog",
	Aliases = { "clearchat" },
	Description = "Empties this server's chat log (the Chat Log page). Report evidence is kept.",
	Usage = "/clearchatlog",
	Permission = "moderation.chatlog",
	Category = "Moderation",
	Subcategory = "Chat",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		return { Success = true, Message = ("Chat log cleared (%d lines)."):format(ChatLogService.Clear()) }
	end,
})

CommandRegistry.Register({
	Name = "alerts",
	Aliases = { "alertfeed" },
	Description = "Shows recent alerts: high-risk and mass commands, environment changes, flagged players joining. Optional count and kind (command, join, critical, warning).",
	Usage = "/alerts [count] [kind]",
	Permission = "panel.open",
	Category = "Moderation",
	Subcategory = "Alerts",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local n = tonumber(ctx.Arguments[1])
		local kind = if n then ctx.Arguments[2] else ctx.Arguments[1]
		local list = AlertService.List(n or 8, if kind then kind:lower() else nil)
		if #list == 0 then
			return { Success = true, Message = "No alerts." }
		end
		local parts = {}
		for _, a in ipairs(list) do
			table.insert(parts, ("[%s] %s: %s"):format(clock(a.Time), a.Severity:upper(), a.Title))
		end
		return { Success = true, Message = table.concat(parts, "\n") }
	end,
})

CommandRegistry.Register({
	Name = "clearalerts",
	Aliases = {},
	Description = "Empties the alerts feed for everyone on this server.",
	Usage = "/clearalerts",
	Permission = "moderation.alerts",
	Category = "Moderation",
	Subcategory = "Alerts",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		return { Success = true, Message = ("Alerts cleared (%d)."):format(AlertService.Clear()) }
	end,
})

return true
