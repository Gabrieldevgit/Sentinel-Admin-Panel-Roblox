--!strict
--[[
	AntiCheat.lua (Sentinel AntiCheat) - chat and command-bar commands.

		;anticheat [page|flagId]    (ac)        open the Control Center          anticheat.view
		;acstatus                                mode, modules, flags, cost       anticheat.view
		;acmode observe|balanced|strict          global mode (strict confirms)    anticheat.config
		;acmodule <name> on|off                  one detection module             anticheat.config
		;acscore <player>                        score + recent flags             anticheat.view
		;acreset <player>                        reset the score (audit-logged)   anticheat.act
		;acexempt <player> [module] <duration> <reason>                           anticheat.exempt
		;acunexempt <player> [module]                                             anticheat.exempt
		;acwatch <player> [why]                  live watch list (again = off)    anticheat.exempt
		;acreview <flagId>                       a flag's evidence                anticheat.review
		;actest <player>                         Testing mode on / off            anticheat.exempt
		;acexport [n]                            recent flags as CSV text         anticheat.view
		;acpanic [off]                           all automatic actions off        anticheat.config
		;acban <player|userId> [reason]          anti-cheat ban (critical: owner
		                                         approval / ;confirm)             anticheat.ban
		;acset <setting> <value>                 any setting, e.g. Scoring.DecayPerMinute 2
		                                                                          anticheat.config

	Also hands the ban stores to ActionService (Systems can't require
	Commands): Ban.lua's SetBan and ServerBan.Add.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local DurationParser = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("DurationParser"))
local Systems = Sentinel:WaitForChild("Systems")
local AC = Systems:WaitForChild("AntiCheat")
local AntiCheatService = require(AC:WaitForChild("AntiCheatService"))
local AntiCheatConfig = require(AC:WaitForChild("AntiCheatConfig"))
local DetectionEngine = require(AC:WaitForChild("DetectionEngine"))
local ScoreService = require(AC:WaitForChild("ScoreService"))
local ExemptionService = require(AC:WaitForChild("ExemptionService"))
local EvidenceService = require(AC:WaitForChild("EvidenceService"))
local ActionService = require(AC:WaitForChild("ActionService"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))

local BanCommand = require(script.Parent.Parent:WaitForChild("Moderation"):WaitForChild("Ban"))
local ServerBan = require(script.Parent.Parent:WaitForChild("Moderation"):WaitForChild("ServerBan"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

ActionService.SetProviders({
	Ban = BanCommand.SetBan,
	ServerBan = ServerBan.Add,
})

local panelRemote = SentinelShared:FindFirstChild("PanelRemote") :: RemoteEvent?
if not panelRemote then
	local created = Instance.new("RemoteEvent")
	created.Name = "PanelRemote"
	created.Parent = SentinelShared
	panelRemote = created
end

local CATEGORY = "AntiCheat"

local function moduleNames(): { string }
	local list = {}
	for _, def in ipairs(DetectionEngine.Modules()) do
		table.insert(list, def.Name)
	end
	return list
end

local function findModule(text: string?): string?
	if not text then
		return nil
	end
	local def = DetectionEngine.GetModule(text)
	if def then
		return def.Name
	end
	local lower = text:lower()
	for _, name in ipairs(moduleNames()) do
		if name:lower():sub(1, #lower) == lower then
			return name
		end
	end
	return nil
end

local function register(def: any)
	def.Category = CATEGORY
	def.Cooldown = def.Cooldown or 1
	if def.Log == nil then
		def.Log = true
	end
	def.TargetProtection = def.TargetProtection or false
	CommandRegistry.Register(def)
end

local function fmtTime(t: number): string
	return os.date("!%H:%M:%S", t) :: string
end

register({
	Name = "anticheat",
	Aliases = { "ac", "anti", "anticheatcenter" },
	Description = "Opens the Anti-Cheat Control Center (F7 / the AC button). Optional page or flag id.",
	Usage = "/anticheat [page]",
	ArgHints = { page = { Type = "string", Description = "Overview, Flags, Players, Review, Modules, Exemptions, Settings, Analytics, Logs, or a flag id" } },
	Examples = { "anticheat", "ac flags", "ac review" },
	Permission = "anticheat.view",
	RequiresTarget = false,
	Log = false,
	Execute = function(ctx: CommandContext): CommandResult
		local page = ctx.Arguments[1]
		;(panelRemote :: RemoteEvent):FireClient(ctx.Executor, "anticheat", if type(page) == "string" then page:sub(1, 40) else nil)
		return { Success = true, Message = "" }
	end,
})

register({
	Name = "acstatus",
	Aliases = { "anticheatstatus" },
	Description = "Shows the anti-cheat mode, enabled modules, active flags and server cost.",
	Usage = "/acstatus",
	Permission = "anticheat.view",
	RequiresTarget = false,
	Log = false,
	Execute = function(_ctx: CommandContext): CommandResult
		local s = AntiCheatService.Status()
		local lines = {
			("AntiCheat %s | mode %s%s | %s"):format(if s.Enabled then "ON" else "OFF", s.Mode, if s.Panic then " | PANIC (actions off)" else "", s.Health),
			("Modules: %d of %d enabled | cost %.2f ms/s (budget %.1f)"):format(s.EnabledModules, s.Modules, s.MsPerSec, s.Budget),
			("Flags awaiting review: %d (%d high severity) | review queue: %d"):format(s.Unreviewed, s.UnreviewedHigh, s.OpenReviews),
		}
		for _, w in ipairs(s.Warnings) do
			table.insert(lines, "Warning: " .. w)
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "acmode",
	Aliases = { "anticheatmode" },
	Description = "Sets the global anti-cheat mode. Observe never punishes; Strict asks to confirm.",
	Usage = "/acmode observe|balanced|strict",
	Examples = { "acmode observe", "acmode balanced" },
	Permission = "anticheat.config",
	RequiresTarget = false,
	Risk = "high",
	ConfirmWhen = function(arguments: { string }): boolean
		return (arguments[1] or ""):lower() == "strict"
	end,
	Execute = function(ctx: CommandContext): CommandResult
		local mode = (ctx.Arguments[1] or ""):lower()
		if mode == "" then
			return { Success = true, Message = "Mode: " .. AntiCheatConfig.Get("Core").Mode }
		end
		local ok, message = AntiCheatService.SetMode(mode, ctx.Executor)
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "acmodule",
	Aliases = { "anticheatmodule" },
	Description = "Enables or disables one anti-cheat detection module on every server.",
	Usage = "/acmodule name on|off",
	ArgHints = { name = { Type = "string", Description = "Module name", Suggestions = moduleNames } },
	Examples = { "acmodule SpeedCheck off", "acmodule FlyCheck on" },
	Permission = "anticheat.config",
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local name = findModule(ctx.Arguments[1])
		if not name then
			return { Success = false, Message = "Unknown module. Modules: " .. table.concat(moduleNames(), ", ") }
		end
		local state = (ctx.Arguments[2] or ""):lower()
		if state ~= "on" and state ~= "off" then
			return { Success = true, Message = ("%s is %s."):format(name, if AntiCheatConfig.GetModule(name).Enabled then "on" else "off") }
		end
		local on = state == "on"
		local ok, message = AntiCheatConfig.SetValue(("Module.%s.Enabled"):format(name), on, ctx.Executor)
		if ok then
			AntiCheatService.LogAction(ctx.Executor, "module.toggle", name, ("%s turned %s"):format(name, state), function()
				return AntiCheatConfig.SetValue(("Module.%s.Enabled"):format(name), not on, ctx.Executor)
			end, { Old = not on, New = on })
		end
		return { Success = ok, Message = if ok then ("%s is %s on every server."):format(name, state) else message }
	end,
})

register({
	Name = "acscore",
	Aliases = { "anticheatscore" },
	Description = "Shows a player's suspicion score and recent flags.",
	Usage = "/acscore target",
	Permission = "anticheat.view",
	RequiresTarget = true,
	Log = false,
	Execute = function(ctx: CommandContext): CommandResult
		local lines = {}
		for _, target in ipairs(ctx.Targets) do
			local score = ScoreService.Get(target.UserId, nil, AntiCheatConfig.Get("Scoring"))
			table.insert(lines, ("%s: score %.1f%s"):format(target.Name, score, if ExemptionService.IsTesting(target.UserId) then " (testing)" else ""))
			for _, f in ipairs(EvidenceService.ForPlayer(target.UserId, 5)) do
				table.insert(lines, ("  %s %s sev %d +%.1f - %s [%s]"):format(fmtTime(f.Time), f.Module, f.Severity, f.Points, f.Reason, f.Id))
			end
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "acreset",
	Aliases = { "anticheatreset", "acclear" },
	Description = "Resets a player's suspicion score to 0 (audit-logged, undoable from Logs).",
	Usage = "/acreset target",
	Permission = "anticheat.act",
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local out = {}
		for _, target in ipairs(ctx.Targets) do
			local _, message = AntiCheatService.ResetScore(target.UserId, target.Name, ctx.Executor)
			table.insert(out, message)
		end
		return { Success = true, Message = table.concat(out, "\n") }
	end,
})

register({
	Name = "acexempt",
	Aliases = { "anticheatexempt" },
	Description = "Exempts a player from one module (or all) for a time, with a reason.",
	Usage = "/acexempt target [module] duration reason...",
	ArgHints = {
		module = { Type = "string", Description = "Module name or all", Suggestions = function()
			local list = moduleNames()
			table.insert(list, 1, "all")
			return list
		end },
		duration = { Type = "string", Description = "30m, 2h, 7d or perm" },
	},
	Examples = { "acexempt bob all 30m testing a vehicle", "acexempt bob SpeedCheck 1d speed pad map" },
	Permission = "anticheat.exempt",
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local args = table.clone(ctx.Arguments)
		local module = "all"
		local first = args[1]
		if first and (first:lower() == "all" or findModule(first)) and not DurationParser.Parse(first) then
			module = if first:lower() == "all" then "all" else findModule(first) :: string
			table.remove(args, 1)
		end
		local duration = args[1] and DurationParser.Parse(args[1])
		if not duration then
			return { Success = false, Message = "Usage: ;acexempt <player> [module] <duration> <reason>  (duration like 30m, 2h, perm)" }
		end
		table.remove(args, 1)
		local reason = table.concat(args, " ")
		if reason:gsub("%s", "") == "" then
			return { Success = false, Message = "A reason is required." }
		end
		local seconds = if duration.IsPermanent then nil else duration.Seconds
		local out = {}
		for _, target in ipairs(ctx.Targets) do
			local e, err = ExemptionService.Add(target.UserId, target.Name, module, seconds, reason, ctx.Executor.Name)
			if e then
				AntiCheatService.LogAction(ctx.Executor, "exempt.add", target.Name, ("Exempted %s from %s (%s): %s"):format(target.Name, module, duration.Raw, reason), function()
					ExemptionService.RemoveById(e.Id)
					return true, "exemption removed"
				end)
				table.insert(out, ("%s exempt from %s %s."):format(target.Name, module, if seconds then "for " .. duration.Raw else "permanently"))
			else
				table.insert(out, ("%s: %s"):format(target.Name, tostring(err)))
			end
		end
		return { Success = true, Message = table.concat(out, "\n") }
	end,
})

register({
	Name = "acunexempt",
	Aliases = { "anticheatunexempt" },
	Description = "Removes a player's anti-cheat exemptions (one module or all).",
	Usage = "/acunexempt target [module]",
	Permission = "anticheat.exempt",
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local module = ctx.Arguments[1]
		local name = if module and module:lower() ~= "all" then findModule(module) else nil
		if module and module:lower() ~= "all" and not name then
			return { Success = false, Message = "Unknown module." }
		end
		local out = {}
		for _, target in ipairs(ctx.Targets) do
			local removed = ExemptionService.Remove(target.UserId, name)
			if #removed > 0 then
				AntiCheatService.LogAction(ctx.Executor, "exempt.remove", target.Name, ("Removed %d exemption(s) of %s"):format(#removed, target.Name), function()
					for _, e in ipairs(removed) do
						ExemptionService.Restore(e)
					end
					return true, "exemption(s) restored"
				end)
			end
			table.insert(out, ("%s: removed %d exemption(s)."):format(target.Name, #removed))
		end
		return { Success = true, Message = table.concat(out, "\n") }
	end,
})

register({
	Name = "acwatch",
	Aliases = { "anticheatwatch" },
	Description = "Adds a player to the live watch list (run again to remove).",
	Usage = "/acwatch target [why...]",
	Permission = "anticheat.exempt",
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local why = table.concat(ctx.Arguments, " ")
		local out = {}
		for _, target in ipairs(ctx.Targets) do
			if ExemptionService.IsWatched(target.UserId) then
				local old = ExemptionService.Unwatch(target.UserId)
				AntiCheatService.LogAction(ctx.Executor, "watch.remove", target.Name, "Stopped watching " .. target.Name, function()
					ExemptionService.Watch(old.UserId, old.Name, old.Why, old.By)
					return true, "watched again"
				end)
				table.insert(out, target.Name .. " removed from the watch list.")
			else
				ExemptionService.Watch(target.UserId, target.Name, if why ~= "" then why else "watched by " .. ctx.Executor.Name, ctx.Executor.Name)
				AntiCheatService.LogAction(ctx.Executor, "watch.add", target.Name, "Watching " .. target.Name, function()
					ExemptionService.Unwatch(target.UserId)
					return true, "unwatched"
				end)
				table.insert(out, target.Name .. " is on the watch list.")
			end
		end
		return { Success = true, Message = table.concat(out, "\n") }
	end,
})

register({
	Name = "acreview",
	Aliases = { "anticheatreview", "acflag" },
	Description = "Shows a flag's evidence and opens it in the Control Center.",
	Usage = "/acreview flagId",
	Permission = "anticheat.review",
	RequiresTarget = false,
	Log = false,
	Execute = function(ctx: CommandContext): CommandResult
		local id = ctx.Arguments[1]
		local flag = id and EvidenceService.Get(id)
		if not flag then
			return { Success = false, Message = "Unknown flag id (see ;acscore <player> or the Live Flags page)." }
		end
		local e = flag.Evidence or {}
		;(panelRemote :: RemoteEvent):FireClient(ctx.Executor, "anticheat", "flag:" .. flag.Id)
		return {
			Success = true,
			Message = ("%s | %s | %s sev %d conf %.2f | +%.1f -> %.1f\n%s\nping %s ms, server FPS %s, %d position samples, exemptions: %s"):format(
				flag.Id,
				flag.Name,
				flag.Module,
				flag.Severity,
				flag.Confidence,
				flag.Points,
				flag.ScoreAfter,
				flag.Reason,
				tostring(e.Ping),
				tostring(e.ServerFps),
				if e.Samples then #e.Samples else 0,
				if e.Exemptions and #e.Exemptions > 0 then table.concat(e.Exemptions, "; ") else "none"
			),
		}
	end,
})

register({
	Name = "actest",
	Aliases = { "anticheattest", "actesting" },
	Description = "Puts a player in Testing mode: every check on them only logs. Run again to end it.",
	Usage = "/actest target",
	Permission = "anticheat.exempt",
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local out = {}
		for _, target in ipairs(ctx.Targets) do
			local on = not ExemptionService.IsTesting(target.UserId)
			local _, message = AntiCheatService.SetTesting(target.UserId, target.Name, on, ctx.Executor)
			table.insert(out, message)
		end
		return { Success = true, Message = table.concat(out, "\n") }
	end,
})

register({
	Name = "acexport",
	Aliases = { "anticheatexport" },
	Description = "Exports recent flags as CSV text for staff.",
	Usage = "/acexport [count]",
	Permission = "anticheat.view",
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local n = math.clamp(tonumber(ctx.Arguments[1]) or 25, 1, 200)
		local lines = { "time,player,module,severity,confidence,score_after,reason,server,id" }
		for _, f in ipairs(EvidenceService.List(nil, n)) do
			table.insert(lines, ('%s,%s,%s,%d,%.2f,%.1f,"%s",%s,%s'):format(
				os.date("!%Y-%m-%d %H:%M:%S", f.Time) :: string,
				f.Name,
				f.Module,
				f.Severity,
				f.Confidence,
				f.ScoreAfter or 0,
				(tostring(f.Reason):gsub('"', "'")),
				tostring(f.Server),
				f.Id
			))
		end
		AntiCheatService.LogAction(ctx.Executor, "export", nil, ("Exported %d flag(s)"):format(#lines - 1))
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "acpanic",
	Aliases = { "anticheatpanic" },
	Description = "Emergency: switches every automatic anti-cheat action off; detections keep logging. ;acpanic off restores.",
	Usage = "/acpanic [on|off]",
	Permission = "anticheat.config",
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local on = (ctx.Arguments[1] or "on"):lower() ~= "off"
		local ok, message = AntiCheatService.SetPanic(on, ctx.Executor)
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "acset",
	Aliases = { "anticheatset" },
	Description = "Changes one anti-cheat setting (validated against its range), e.g. Scoring.DecayPerMinute 2.",
	Usage = "/acset setting value...",
	Examples = { "acset Scoring.DecayPerMinute 2", "acset Module.SpeedCheck.Margin 6", "acset Bands.Balanced log,alert,warn,kick,review" },
	Permission = "anticheat.config",
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local path = ctx.Arguments[1]
		local value = table.concat(ctx.Arguments, " ", 2)
		if not path or value == "" then
			return { Success = false, Message = "Usage: ;acset <Section.Setting> <value>" }
		end
		if path:lower():match("^core%.enabled") and not PermissionSystem.Has(ctx.Executor, "anticheat.master") then
			return { Success = false, Message = "Turning the system on or off needs anticheat.master." }
		end
		local key, field = AntiCheatConfig.SplitPath(path)
		local before = if key and field then AntiCheatConfig.Get(key)[field] else nil
		local ok, message = AntiCheatConfig.SetValue(path, value, ctx.Executor)
		if ok and message:find("Changed") then
			AntiCheatService.LogAction(ctx.Executor, "config", path, message, function()
				return AntiCheatConfig.SetValue(path, before, ctx.Executor)
			end, { Old = before, New = value })
		end
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "acban",
	Aliases = { "anticheatban" },
	Description = "Bans a player for cheating (game-wide, Bands.BanDays) with the anti-cheat evidence. Critical: needs owner approval or ;confirm.",
	Usage = "/acban user [reason...]",
	ArgHints = { user = { Type = "string", Description = "Username or UserId (online or offline)" } },
	Examples = { "acban bob speed + fly pattern" },
	Permission = "anticheat.ban",
	RequiresTarget = false,
	Risk = "critical",
	Execute = function(ctx: CommandContext): CommandResult
		local PlayerProfileService = require(Systems:WaitForChild("PlayerProfileService")) :: any
		local info, err = PlayerProfileService.Resolve(ctx.Arguments[1], ctx.Executor)
		if not info then
			return { Success = false, Message = err or "Unknown player." }
		end
		if info.UserId == ctx.Executor.UserId then
			return { Success = false, Message = "You can't ban yourself." }
		end
		local online = Players:GetPlayerByUserId(info.UserId)
		if online then
			local RankService = require(Systems:WaitForChild("RankService")) :: any
			if not RankService.CanTarget(ctx.Executor, online) then
				return { Success = false, Message = ("%s is protected by rank."):format(info.Name) }
			end
		end
		local typed = table.concat(ctx.Arguments, " ", 2)
		local reason = "[AntiCheat] cheating"
		if typed ~= "" then
			local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, typed)
			if not filtered then
				return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
			end
			reason = "[AntiCheat] " .. filtered
		end
		local flags = EvidenceService.ForPlayer(info.UserId, 10)
		if #flags > 0 then
			local modules = {}
			for _, f in ipairs(flags) do
				if not table.find(modules, f.Module) then
					table.insert(modules, f.Module)
				end
			end
			reason = ("%s (flags: %s)"):format(reason, table.concat(modules, ", ")):sub(1, 280)
		end
		local days = AntiCheatConfig.Get("Bands").BanDays or 30
		local ok, message = ActionService.Ban({ UserId = info.UserId, Name = info.Name }, reason, days, ctx.Executor.Name)
		if ok then
			local closed = ActionService.Approve(info.UserId, ctx.Executor.Name)
			ActionService.Record("ban", { UserId = info.UserId, Name = info.Name }, flags[1], message, { By = ctx.Executor.Name, ById = ctx.Executor.UserId })
			AntiCheatService.LogAction(ctx.Executor, "ban", info.Name, message .. (if closed > 0 then (" (closed %d review item(s))"):format(closed) else ""))
		end
		return { Success = ok, Message = message }
	end,
})

return {}
