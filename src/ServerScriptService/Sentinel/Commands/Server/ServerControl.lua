--!strict
--[[
	ServerControl.lua

	Purpose:
		Whole-server control commands wrapping ServerStateService.

		;shutdown [seconds] [message...]   kick everyone (optional countdown)
		;lockserver [message...]           custom message for turned-away joiners
		;unlockserver
		;maintenancemode on|off [message...]
		;slowmode seconds
		;kickall [message...]              W22: everyone below your rank but you
		;kicknonstaff [message...]         W22: everyone without panel.open
		;servercap <players>|off           W22: soft player cap (staff bypass)
		;serverinfo                        W22: JobId, version, players, health...

	Dependencies:
		Types.lua (Shared), CommandRegistry (Core), ServerStateService,
		CrossServerService, RankService, PermissionSystem, TextFilterService.
--]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local ServerStateService = require(Systems:WaitForChild("ServerStateService"))
local CrossServerService = require(Systems:WaitForChild("CrossServerService"))
local RankService = require(Systems:WaitForChild("RankService"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))

-- Staff-written text shown to other players goes through the filter; on a
-- filter failure the command refuses instead of showing the original.
local function filtered(ctx: Types.CommandContext, words: { string }, from: number): (boolean, string?)
	local text = table.concat(words, " ", from)
	if text:match("^%s*$") then
		return true, nil
	end
	local clean = TextFilterService.ForBroadcast(ctx.Executor.UserId, text:sub(1, 200))
	if not clean then
		return false, nil
	end
	return true, clean
end

local FILTER_FAILED = { Success = false, Message = "The message couldn't be filtered right now - try again or leave it out." }

local shuttingDown = false

CommandRegistry.Register({
	Name = "shutdown",
	Aliases = {},
	Description = "Kicks every player and ends this server, optionally after an on-screen countdown (5-300 s). To move players to a fresh server instead, use ;migrateserver.",
	Usage = "/shutdown [seconds] [message...]",
	Permission = "server.shutdown",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "shutdown", "shutdown 30 Updating the map" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		if shuttingDown then
			return { Success = false, Message = "A shutdown is already counting down." }
		end
		local seconds = tonumber(ctx.Arguments[1])
		local from = if seconds then 2 else 1
		local ok, message = filtered(ctx, ctx.Arguments, from)
		if not ok then
			return FILTER_FAILED
		end
		local text = message or "The server is shutting down."
		local function kickEveryone()
			ServerStateService.SetLocked(true, text)
			for _, player in ipairs(Players:GetPlayers()) do
				player:Kick(text)
			end
		end
		if not seconds or seconds <= 0 then
			kickEveryone()
			return { Success = true, Message = "Server shutdown initiated." }
		end
		local total = math.clamp(math.floor(seconds), 5, 300)
		shuttingDown = true
		local countdown = SentinelShared:FindFirstChild("CountdownRemote") :: RemoteEvent?
		task.spawn(function()
			for remaining = total, 1, -1 do
				if countdown then
					countdown:FireAllClients("tick", "Server shutting down", remaining, total)
				end
				task.wait(1)
			end
			if countdown then
				countdown:FireAllClients("done", "Server shutting down", 0, total)
			end
			kickEveryone()
			shuttingDown = false
		end)
		return { Success = true, Message = ("Server shuts down in %d seconds."):format(total) }
	end,
})

CommandRegistry.Register({
	Name = "lockserver",
	Aliases = { "lock" },
	Description = "Prevents new players from joining this server (staff with server.bypass still can). The optional message is what turned-away players see.",
	Usage = "/lockserver [message...]",
	Permission = "server.lock",
	Category = "Server",
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local ok, message = filtered(ctx, ctx.Arguments, 1)
		if not ok then
			return FILTER_FAILED
		end
		ServerStateService.SetLocked(true, message)
		return { Success = true, Message = if message then "Server locked with a custom message." else "Server locked.", Undoable = true }
	end,
})

CommandRegistry.Register({
	Name = "unlockserver",
	Aliases = { "unlock" },
	Description = "Allows new players to join this server again.",
	Usage = "/unlockserver",
	Permission = "server.lock",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		ServerStateService.SetLocked(false)
		return { Success = true, Message = "Server unlocked." }
	end,
})

CommandRegistry.Register({
	Name = "maintenancemode",
	Aliases = { "maintenance" },
	Description = "Toggles maintenance mode (turns away new non-staff joiners). The optional message replaces the default maintenance text.",
	Usage = "/maintenancemode on|off [message...]",
	Permission = "server.maintenance",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local setting = (ctx.Arguments[1] or ""):lower()
		if setting ~= "on" and setting ~= "off" then
			return { Success = false, Message = "Usage: /maintenancemode on|off [message...]" }
		end
		local ok, message = filtered(ctx, ctx.Arguments, 2)
		if not ok then
			return FILTER_FAILED
		end
		ServerStateService.SetMaintenanceMode(setting == "on", message)
		return { Success = true, Message = ("Maintenance mode is now %s."):format(setting) }
	end,
})

CommandRegistry.Register({
	Name = "slowmode",
	Aliases = {},
	Description = "Sets a minimum number of seconds between chat messages per player.",
	Usage = "/slowmode seconds",
	Permission = "server.slowmode",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local seconds = tonumber(ctx.Arguments[1])
		if not seconds then
			return { Success = false, Message = "Usage: /slowmode seconds (0 to disable)" }
		end
		ServerStateService.SetSlowMode(seconds)
		return { Success = true, Message = ("Slow mode set to %d second(s)."):format(seconds) }
	end,
})

-- ---------------------------------------------------------------------------
-- W22: bulk kicks, soft capacity, server information
-- ---------------------------------------------------------------------------
local function bulkKick(ctx: Types.CommandContext, staffToo: boolean): Types.CommandResult
	local ok, message = filtered(ctx, ctx.Arguments, 1)
	if not ok then
		return FILTER_FAILED
	end
	local text = message
		or (if staffToo then "You were removed from the server by staff." else "This server is being cleared for staff.")
	local kicked, protected = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= ctx.Executor and (staffToo or not PermissionSystem.Has(player, "panel.open")) then
			if RankService.CanTarget(ctx.Executor, player) then
				player:Kick(text)
				kicked += 1
			else
				protected += 1
			end
		end
	end
	local summary = ("Kicked %d player(s)."):format(kicked)
	if protected > 0 then
		summary ..= (" %d protected by rank."):format(protected)
	end
	return { Success = true, Message = summary }
end

CommandRegistry.Register({
	Name = "kickall",
	Aliases = { "kickeveryone" },
	Description = "Kicks every player in this server except you and anyone ranked equal to or above you.",
	Usage = "/kickall [message...]",
	Permission = "server.kickall",
	Category = "Server",
	Risk = "critical",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		return bulkKick(ctx, true)
	end,
})

CommandRegistry.Register({
	Name = "kicknonstaff",
	Aliases = { "kickplayers" },
	Description = "Kicks every player who isn't staff (no panel access), e.g. before a staff meeting or a maintenance window.",
	Usage = "/kicknonstaff [message...]",
	Permission = "server.kickall",
	Category = "Server",
	Risk = "critical",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		return bulkKick(ctx, false)
	end,
})

CommandRegistry.Register({
	Name = "servercap",
	Aliases = { "playercap" },
	Description = "Soft player cap for this server: non-staff joiners beyond it are turned away (Roblox doesn't allow changing the real maximum while a server runs). off removes it; no argument shows it.",
	Usage = "/servercap [players]",
	ArgHints = { players = { Type = "string", Description = "1 to the server maximum, or off" } },
	Permission = "server.capacity",
	Category = "Server",
	Risk = "medium",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "servercap 10", "servercap off" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local arg = (ctx.Arguments[1] or ""):lower()
		if arg == "" then
			local cap = ServerStateService.GetCapacity()
			return {
				Success = true,
				Message = if cap
					then ("Soft cap: %d of %d."):format(cap, Players.MaxPlayers)
					else ("No soft cap (Roblox maximum %d)."):format(Players.MaxPlayers),
			}
		end
		if arg == "off" or arg == "none" or arg == "0" then
			ServerStateService.SetCapacity(nil)
			return { Success = true, Message = "Soft player cap removed." }
		end
		local n = tonumber(arg)
		if not n or n % 1 ~= 0 or n < 1 or n > Players.MaxPlayers then
			return { Success = false, Message = ("Give a whole number from 1 to %d, or off."):format(Players.MaxPlayers) }
		end
		ServerStateService.SetCapacity(n)
		return {
			Success = true,
			Message = ("Soft player cap set to %d (currently %d in the server)."):format(n, #Players:GetPlayers()),
		}
	end,
})

local function formatUptime(seconds: number): string
	local h = math.floor(seconds / 3600)
	local m = math.floor(seconds % 3600 / 60)
	return if h > 0 then ("%dh %dm"):format(h, m) else ("%dm %ds"):format(m, seconds % 60)
end

CommandRegistry.Register({
	Name = "serverinfo",
	Aliases = { "sinfo", "serverstatus" },
	Description = "Shows this server's id, version, players, uptime, health, heartbeat, memory, ping, staff and join restrictions.",
	Usage = "/serverinfo",
	Permission = "server.info",
	Category = "Server",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: Types.CommandContext): Types.CommandResult
		local info = CrossServerService.LocalInfo()
		local flags = {}
		if info.Locked then
			table.insert(flags, "locked")
		end
		if info.Maint then
			table.insert(flags, "maintenance")
		end
		if info.Whitelist then
			table.insert(flags, "whitelist")
		end
		if info.Cap then
			table.insert(flags, ("cap %d"):format(info.Cap))
		end
		if info.Priv then
			table.insert(flags, "private (" .. tostring(info.PrivateAccess) .. ")")
		end
		return {
			Success = true,
			Message = ("Server %s | v%d | %d/%d players | up %s | %s | %d hb/s | %d MB | ping %d ms | staff: %s | %s"):format(
				info.ShortId,
				info.Ver or 0,
				info.N or 0,
				info.Max or 0,
				formatUptime(info.Uptime or 0),
				tostring(info.Health),
				info.Fps or 0,
				info.Mem or 0,
				info.Ping or 0,
				if #info.Staff > 0 then table.concat(info.Staff, ", ") else "none",
				if #flags > 0 then table.concat(flags, ", ") else "open"
			),
		}
	end,
})

return true
