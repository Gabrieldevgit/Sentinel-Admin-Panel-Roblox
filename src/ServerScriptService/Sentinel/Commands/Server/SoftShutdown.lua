--!strict
--[[
	SoftShutdown.lua - every Soft Shutdown action is a command.

		;softshutdown [time] [message...]      this server: countdown (default
		                                       30 s; 5 s - 3 h, warnings,
		                                       cancellable), then soft shutdown
		;softshutdown now [message...]         this server, right away
		;softshutdown all [time] [message...]  every server (5 - 300 s countdown)
		;softshutdown cancel                   stop a pending countdown
		;softshutdown status                   auto setting, pending, last run
		;softshutdown auto on|off              soft shutdown when Roblox closes
		                                       a server (Creator Hub "Shut down
		                                       all servers" / updates)

	Aliases: softrestart, sshutdown. Nodes: server.shutdown (this server,
	cancel, status), crossserver.migrate (all), config.edit (auto).
	Critical risk (asks ;confirm) except status / cancel / auto.
	See Systems/SoftShutdownService.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))
local ShutdownService = require(Systems:WaitForChild("ShutdownService"))
local SoftShutdownService = require(Systems:WaitForChild("SoftShutdownService"))
local CrossServerService = require(Systems:WaitForChild("CrossServerService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local SAFE_ACTIONS = { status = true, cancel = true, auto = true, stop = true }

local function parseTime(word: string?): number?
	if not word then
		return nil
	end
	local n = tonumber(word)
	if n then
		return n
	end
	local parsed = DurationParser.Parse(word)
	if parsed and not parsed.IsPermanent then
		return parsed.Seconds
	end
	return nil
end

-- (ok, message?) - ok false = the filter failed (never show the original)
local function message(ctx: Ctx, from: number): (boolean, string?)
	local text = table.concat(ctx.Arguments, " ", from)
	if text:match("^%s*$") then
		return true, nil
	end
	local clean = TextFilterService.ForBroadcast(ctx.Executor.UserId, text:sub(1, 200))
	if not clean then
		return false, nil
	end
	return true, clean
end

local FILTER_FAILED: Result = { Success = false, Message = "The message couldn't be filtered right now - try again or leave it out." }

local function need(ctx: Ctx, node: string): Result?
	if not PermissionSystem.Has(ctx.Executor, node) then
		return { Success = false, Message = ("You need %s for that."):format(node) }
	end
	return nil
end

local function ago(t: number): string
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return d .. "s ago"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m ago"
	end
	return math.floor(d / 3600) .. "h ago"
end

CommandRegistry.Register({
	Name = "softshutdown",
	Aliases = { "softrestart", "sshutdown" },
	Description = "Soft shutdown: moves players to a fresh server instead of disconnecting them (restart screen, waiting room, back to a new server together). Also runs automatically when Roblox closes a server - see ;softshutdown auto.",
	Usage = "/softshutdown [action] [time] [message...]",
	ArgHints = {
		action = { Type = "string", Description = "now | all | cancel | status | auto, or a time (30, 5m)", Suggestions = { "now", "all", "status", "cancel", "auto", "30", "5m" } },
		time = { Type = "string", Description = "Countdown: seconds or 10m / 1h (default 30 s)" },
		message = { Type = "text", Description = "Shown to players" },
	},
	Examples = { "softshutdown", "softshutdown now", "softshutdown 5m New update", "softshutdown all 60 Update", "softshutdown status", "softshutdown auto off" },
	Permission = "server.shutdown",
	Category = "Server",
	Subcategory = "Shutdown",
	Risk = "critical",
	ConfirmWhen = function(arguments: { string }): boolean
		return not SAFE_ACTIONS[(arguments[1] or ""):lower()]
	end,
	Cooldown = 3,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Ctx): Result
		local action = (ctx.Arguments[1] or ""):lower()

		if action == "status" then
			local s = SoftShutdownService.Status()
			local lines = {
				("Automatic soft shutdown: %s%s"):format(if s.Auto then "on" else "off", if s.Public then "" else " (not used here: private / reserved server)"),
			}
			local pending = ShutdownService.Pending()
			if pending then
				table.insert(lines, ("Pending %s in %ds (by %s)."):format(pending.Kind, pending.Remaining, tostring(pending.By)))
			elseif CrossServerService.IsMigrating() then
				table.insert(lines, "A migration countdown is running.")
			end
			if s.Evacuating then
				table.insert(lines, ("Moving players since %s: %d sent, %d retried, %d kicked."):format(ago(s.StartedAt), s.Sent, s.Retried, s.Kicked))
			end
			if s.WaitingRoom then
				table.insert(lines, ("This is a waiting room: %d player(s) sent back so far."):format(s.Returned))
			end
			if s.LastResult then
				table.insert(lines, "Last run: " .. s.LastResult)
			end
			if not s.CanTeleport then
				table.insert(lines, "Teleports are unavailable here (Studio) - a soft shutdown is a dry run.")
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		elseif action == "cancel" or action == "stop" then
			local ok, text = ShutdownService.Cancel(ctx.Executor)
			return { Success = ok, Message = text }
		elseif action == "auto" then
			local denied = need(ctx, "config.edit")
			if denied then
				return denied
			end
			local value = (ctx.Arguments[2] or ""):lower()
			if value ~= "on" and value ~= "off" then
				return { Success = false, Message = ("Automatic soft shutdown is %s. Use ;softshutdown auto on|off."):format(if SoftShutdownService.Status().Auto then "on" else "off") }
			end
			local ok, text = SoftShutdownService.SetAuto(value == "on", ctx.Executor)
			return { Success = ok, Message = text }
		elseif action == "all" or action == "global" or action == "everywhere" then
			local denied = need(ctx, "crossserver.migrate")
			if denied then
				return denied
			end
			local seconds = parseTime(ctx.Arguments[2])
			local ok, text = message(ctx, if seconds then 3 else 2)
			if not ok then
				return FILTER_FAILED
			end
			seconds = math.clamp(math.floor(seconds or 30), 5, 300)
			local op, err = CrossServerService.Send("migrate", { s = seconds, m = text }, {
				Actor = CrossServerService.ActorOf(ctx.Executor),
				Label = ("soft shutdown in %ds (all servers)"):format(seconds),
				History = true,
			})
			if not op then
				return { Success = false, Message = err or "Could not reach the other servers." }
			end
			if op.Status == "failed" then
				return { Success = false, Message = "Couldn't reach the other servers: " .. tostring(err) }
			end
			local final = CrossServerService.WaitFor(op.Id, 2.5) or op
			return { Success = true, Message = ("Soft shutdown in %ds started on every server - %s."):format(seconds, CrossServerService.Describe(final)) }
		elseif action == "now" then
			local ok, text = message(ctx, 2)
			if not ok then
				return FILTER_FAILED
			end
			local done, result = SoftShutdownService.Evacuate(text)
			return { Success = done, Message = result }
		end

		-- this server with a countdown: ;softshutdown [time] [message]
		local seconds = parseTime(ctx.Arguments[1])
		local ok, text = message(ctx, if seconds then 2 else 1)
		if not ok then
			return FILTER_FAILED
		end
		if seconds and seconds <= 0 then
			local done, result = SoftShutdownService.Evacuate(text)
			return { Success = done, Message = result }
		end
		local done, result = ShutdownService.Schedule("restart", seconds or 30, text or "Soft shutdown: you'll be moved to a fresh server.", ctx.Executor)
		return { Success = done, Message = if done then "Soft shutdown: " .. result else result }
	end,
} :: any)

return {}
