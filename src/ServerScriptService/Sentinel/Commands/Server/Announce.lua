--!strict
--[[
	Announce.lua

	Purpose:
		Registers ;announce (this server), ;tannounce (some players),
		;sannounce (staff only), ;announcements (history) - all through
		Systems/AnnouncementService - and ;countdown.
		(Original note:) Registers "/announce" and "/countdown". Two separate RemoteEvents
		drive two separate client UIs: a banner across the top of the
		screen for /announce, and a large countdown overlay for /countdown
		(rather than reusing the banner for both, since a countdown needs
		its own persistent, updating widget instead of a message that
		flashes and disappears).

	Responsibilities:
		- Lazily create ReplicatedStorage.Shared.Sentinel.AnnounceRemote
		  and .CountdownRemote
		- Fire AnnounceRemote with (text, color) for /announce
		- Fire CountdownRemote with (phase, label, remaining, total) for
		  /countdown, where phase is "tick" | "done"

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local TextFilterService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("TextFilterService"))
local AnnouncementService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("AnnouncementService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = SentinelShared
	return remote
end

local countdownRemote = getOrCreateRemote("CountdownRemote")

local OPTION_HELP = "Options: style=banner|full time=3-60 color=gold|red|green|blue|purple|orange|pink|#hex title=Word_Word"

-- Splits options from the message; returns (options, text) or a failure result.
local function parse(words: { string }, usage: string): (any, string?, Types.CommandResult?)
	local options, rest, err = AnnouncementService.ParseOptions(words)
	if err then
		return nil, nil, { Success = false, Message = ("%s. %s"):format(err, OPTION_HELP) }
	end
	local text = table.concat(rest, " ")
	if text == "" then
		return nil, nil, { Success = false, Message = ("Usage: %s"):format(usage) }
	end
	return options, text, nil
end

local function send(ctx: Types.CommandContext, scope: string, usage: string, recipients: { Player }?, done: string): Types.CommandResult
	local options, text, failed = parse(ctx.Arguments, usage)
	if failed then
		return failed
	end
	local ok, message = AnnouncementService.Send(ctx.Executor, text :: string, scope, options, recipients)
	if not ok then
		return { Success = false, Message = message }
	end
	return { Success = true, Message = done }
end

local ANNOUNCE_HINTS = {
	message = { Description = "Optional style=, time=, color=, title= words, then the text" },
}

CommandRegistry.Register({
	Name = "announce",
	Aliases = { "bc", "broadcast" },
	Description = "Shows an announcement (with your name and avatar) on every player's screen in this server.",
	Usage = "/announce message...",
	ArgHints = ANNOUNCE_HINTS,
	Examples = { "announce Event starts in 5 minutes!", "announce style=full color=gold title=Double_XP Double XP is live!" },
	Permission = "server.announce",
	Category = "Server",
	Subcategory = "Announcements",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		return send(ctx, "server", "/announce [options] message", nil, "Announcement sent.")
	end,
})

CommandRegistry.Register({
	Name = "tannounce",
	Aliases = { "pannounce", "announceto" },
	Description = "Shows an announcement to some players only.",
	Usage = "/tannounce target message...",
	ArgHints = ANNOUNCE_HINTS,
	Examples = { "tannounce Alpha,Beta Please meet at spawn.", "tannounce @team Red style=full Your round starts now!" },
	Permission = "server.announce",
	TargetProtection = false, -- a message, not a punishment
	Category = "Server",
	Subcategory = "Announcements",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local n = #ctx.Targets
		return send(ctx, "players", "/tannounce players [options] message", ctx.Targets,
			("Announcement sent to %d player%s."):format(n, if n == 1 then "" else "s"))
	end,
})

CommandRegistry.Register({
	Name = "sannounce",
	Aliases = { "staffannounce" },
	Description = "Shows an announcement to the staff online in this server only.",
	Usage = "/sannounce message...",
	ArgHints = ANNOUNCE_HINTS,
	Examples = { "sannounce Staff meeting in 10 minutes." },
	Permission = "server.announce",
	Category = "Server",
	Subcategory = "Announcements",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local staff = AnnouncementService.StaffOnline()
		return send(ctx, "staff", "/sannounce [options] message", staff,
			("Announcement sent to %d staff member%s."):format(#staff, if #staff == 1 then "" else "s"))
	end,
})

local SCOPE_LABEL = { server = "server", global = "global", players = "players", staff = "staff" }

CommandRegistry.Register({
	Name = "announcements",
	Aliases = { "announcehistory", "annhistory" },
	Description = "Lists recent announcements (newest first).",
	Usage = "/announcements [count]",
	Permission = "panel.open",
	Category = "Server",
	Subcategory = "Announcements",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local count = math.clamp(tonumber(ctx.Arguments[1]) or 5, 1, 20)
		local list = AnnouncementService.History(count)
		if #list == 0 then
			return { Success = true, Message = "No announcements yet." }
		end
		local lines = {}
		for _, r in ipairs(list) do
			local author = if type(r.Author) == "table" then r.Author.Name else "?"
			table.insert(lines, ("[%s] %s (%s): %s"):format(os.date("!%m-%d %H:%M", r.Time or 0), author, SCOPE_LABEL[r.Scope] or "?", tostring(r.Text):sub(1, 80)))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

CommandRegistry.Register({
	Name = "countdown",
	Aliases = {},
	Description = "Shows a countdown overlay on every player's screen.",
	Usage = "/countdown seconds [label]",
	Permission = "server.announce",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Cancellable = true, -- ;cancel stops it (W07)
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local seconds = tonumber(ctx.Arguments[1])
		if not seconds or seconds <= 0 or seconds > 300 then
			return { Success = false, Message = "Usage: /countdown seconds [label] (max 300)" }
		end
		local label = "Starting"
		if #ctx.Arguments > 1 then
			local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, table.concat(ctx.Arguments, " ", 2))
			if not filtered then
				return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
			end
			label = filtered
		end

		local stopped = false
		local handle = if ctx.Track
			then ctx.Track(("countdown %ds"):format(seconds), function()
				stopped = true
				countdownRemote:FireAllClients("done", label, 0, seconds)
			end)
			else nil
		task.spawn(function()
			for remaining = seconds, 1, -1 do
				if stopped then
					return
				end
				countdownRemote:FireAllClients("tick", label, remaining, seconds)
				task.wait(1)
			end
			if stopped then
				return
			end
			if handle then
				handle.Finish()
			end
			countdownRemote:FireAllClients("done", label, 0, seconds)
		end)

		return { Success = true, Message = ("Countdown started (%ds)."):format(seconds) }
	end,
})

-- M-panel gaps: saved broadcast templates (Announcements page chips).
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))

CommandRegistry.Register({
	Name = "btemplate",
	Aliases = { "broadcasttemplate", "bctemplate" },
	Description = "Saved announcement templates (server-wide). list shows them; add <name> <text> saves one; remove <name> deletes it. The Announcements page shows them as chips that fill the message box.",
	Usage = "/btemplate [list|add|remove] [name] [text...]",
	ArgHints = { list = { Type = "choice", Choices = { "list", "add", "remove" } } },
	Examples = { "btemplate", "btemplate add maintenance Short maintenance in 5 minutes", "btemplate remove maintenance" },
	Permission = "panel.open",
	Category = "Server",
	Subcategory = "Announcements",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local action = (ctx.Arguments[1] or "list"):lower()
		if action == "list" then
			local parts = {}
			for _, t in ipairs(AnnouncementService.GetTemplates()) do
				table.insert(parts, ("%s: %s"):format(t.Name, t.Text))
			end
			return { Success = true, Message = if #parts > 0 then table.concat(parts, " | ") else "No templates." }
		end
		if action ~= "add" and action ~= "remove" then
			return { Success = false, Message = "Usage: ;btemplate [list | add <name> <text...> | remove <name>]" }
		end
		if not PermissionSystem.Has(ctx.Executor, "server.announce") then
			return { Success = false, Message = "Editing templates needs server.announce." }
		end
		local name = ctx.Arguments[2]
		if not name then
			return { Success = false, Message = "Give a template name." }
		end
		local text = if action == "add" then table.concat(ctx.Arguments, " ", 3) else nil
		if action == "add" and (not text or text == "") then
			return { Success = false, Message = "Give the template text." }
		end
		local ok, message = AnnouncementService.SetTemplate(name, text, ctx.Executor)
		return { Success = ok, Message = message }
	end,
})

return true
