--!strict
--[[
	CrossServer.lua (cross-server commands, W18-W21)

	Servers
		;servers                        running servers with health
		;findplayer <name|userId>       where a player is (any server / offline)
		;joinserver <server>            teleport yourself to a server
		;follow <player>                teleport to the server a player is in
		;xping                          ask every server to answer
		;xstatus [operation]            acknowledgements of recent operations
	Moderation (players may be in ANY server, or offline)
		;gkick <player> [reason]
		;gban <player> <duration|perm> [reason]
		;gunban <player>
		;gwarn <player> <reason>
		;gbring <player>                bring a player from another server
	Operations
		;gannounce <message>            banner on every server
		;gnotify <message>              toast for staff on every server
		;lockdown [on|off|status] [reason]
		;gshutdown [message]            kick everyone on every server
		;gupdate [seconds] [message]    update countdown + graceful migration
		;migrateserver [seconds] [message]   the same, this server only
		;global <command...>            run a global-safe command everywhere
	Staff
		;staffchat <message>            cross-server staff chat

	Every command here runs through CommandRegistry.Dispatch on the server
	where it was typed (permission, cooldown, confirmation, logging); the
	other servers act through Systems/CrossServerActions and answer with an
	acknowledgement, which is what the result line reports.

	Players are named by username or UserId, not by the target grammar:
	the usual selectors only resolve players in THIS server.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))
local CommandParser = require(Core:WaitForChild("Parser"):WaitForChild("CommandParser"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local CrossServerService = require(Systems:WaitForChild("CrossServerService"))
require(Systems:WaitForChild("CrossServerActions"))
local PunishmentService = require(Systems:WaitForChild("PunishmentService"))
local RankService = require(Systems:WaitForChild("RankService"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))
local BanCommand = require(script.Parent.Parent:WaitForChild("Moderation"):WaitForChild("Ban"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local CATEGORY = "Cross-Server"
local PLAYER_HINT = { Type = "string", Description = "Username or UserId - in any server, or offline" }
local SERVER_HINT = { Type = "string", Description = "Server id from ;servers (the first characters are enough)" }

local short = CrossServerService.ShortId

local function duration(seconds: number): string
	if seconds < 60 then
		return ("%ds"):format(seconds)
	elseif seconds < 3600 then
		return ("%dm"):format(math.floor(seconds / 60))
	elseif seconds < 86400 then
		return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
	end
	return ("%dd %dh"):format(math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

-- Text after the first `skip` words of the raw command (keeps quotes and
-- spacing, unlike joining the tokens).
local function restOf(ctx: Ctx, fromIndex: number): string
	return table.concat(ctx.Arguments, " ", fromIndex)
end

type User = { UserId: number, Name: string, Local: Player?, ServerId: string? }

-- Username or UserId -> who it is and where they are (this server, another
-- server, or offline). Offline lookups go through Roblox's own name service.
local function resolveUser(text: string?): (User?, string?)
	if not text or text == "" then
		return nil, "Give a username or UserId."
	end
	local asId = tonumber(text)
	if asId and (asId <= 0 or asId % 1 ~= 0 or asId >= 2 ^ 53) then
		return nil, "That is not a valid UserId."
	end
	local lower = text:lower()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == asId or player.Name:lower() == lower then
			return { UserId = player.UserId, Name = player.Name, Local = player, ServerId = CrossServerService.ServerId }, nil
		end
	end
	for _, match in ipairs(CrossServerService.FindPlayers(text, 10)) do
		if match.UserId == asId or match.Name:lower() == lower then
			return { UserId = match.UserId, Name = match.Name, ServerId = match.ServerId }, nil
		end
	end
	if asId then
		local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, asId)
		return { UserId = asId, Name = if ok and type(name) == "string" then name else tostring(asId) }, nil
	end
	if #text > 20 or not text:match("^[%w_]+$") then
		return nil, ("'%s' is not a valid username."):format(text)
	end
	local ok, userId = pcall(Players.GetUserIdFromNameAsync, Players, text)
	if not ok or type(userId) ~= "number" then
		return nil, ("No Roblox user named '%s'."):format(text)
	end
	local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	return { UserId = userId, Name = if okName and type(name) == "string" then name else text }, nil
end

-- Rank of someone who isn't in this server, from what can be known without
-- their Player object: the creator and UserId rank bindings. (Group and
-- game-pass ranks are re-checked by the server the player is actually in.)
local function knownPriority(userId: number): number
	if game.CreatorType == Enum.CreatorType.User and game.CreatorId == userId then
		return math.huge
	end
	local best = -math.huge
	for _, binding in ipairs(RankService.GetBindings()) do
		if binding.Kind == "UserId" and binding.Value == userId then
			local rank = RankService.GetRank(binding.Rank)
			if rank then
				best = math.max(best, rank.Priority)
			end
		end
	end
	return best
end

local function canActOn(executor: Player, user: User): boolean
	if user.UserId == executor.UserId then
		return true
	end
	if user.Local then
		return RankService.CanTarget(executor, user.Local)
	end
	local priority = knownPriority(user.UserId)
	return priority == -math.huge or priority < RankService.GetPriority(executor)
end

local PROTECTED = "You can't do that to a player ranked equal to or above you."

local function filtered(ctx: Ctx, text: string): (string?, Result?)
	local clean = TextFilterService.ForBroadcast(ctx.Executor.UserId, text)
	if not clean then
		return nil, { Success = false, Message = TextFilterService.FAILED_MESSAGE }
	end
	return clean, nil
end

-- Sends, waits briefly for the acknowledgements and turns them into a result.
-- needAffected: fail when no server reports having done anything.
local function sendAndReport(kind: string, payload: any, options: any, okText: string, needAffected: string?): (Result, any)
	local op, err = CrossServerService.Send(kind, payload, options)
	if not op then
		return { Success = false, Message = err or "Could not send." }, nil
	end
	if op.Status == "failed" then
		return { Success = false, Message = "Couldn't reach the other servers: " .. tostring(err) }, op
	end
	local final = CrossServerService.WaitFor(op.Id, 2.5) or op
	for _, ack in ipairs(final.Acks) do
		if not ack.Ok and ack.Message == "protected by rank" then
			return { Success = false, Message = PROTECTED }, final
		end
	end
	if needAffected and final.Affected == 0 and final.Status ~= "pending" then
		return { Success = false, Message = ("%s (%s)"):format(needAffected, CrossServerService.Describe(final)) }, final
	end
	return { Success = true, Message = ("%s - %s."):format(okText, CrossServerService.Describe(final)) }, final
end

local function register(def: any)
	def.Category = CATEGORY
	def.Aliases = def.Aliases or {}
	def.Log = def.Log ~= false
	def.Undoable = false
	def.RequiresTarget = def.RequiresTarget == true -- only ;createserver takes the target grammar
	CommandRegistry.Register(def)
end

-- ---------------------------------------------------------------------------
-- Servers
-- ---------------------------------------------------------------------------
register({
	Name = "servers",
	Aliases = { "serverlist" },
	Description = "Lists every running server: players, staff, health, uptime and version.",
	Usage = "/servers [search...]",
	ArgHints = { search = { Type = "text", Description = "Filter by server id or staff name" } },
	Permission = "crossserver.view",
	Subcategory = "Servers",
	Cooldown = 1,
	Log = false,
	Examples = { "servers" },
	Execute = function(ctx: Ctx): Result
		local servers, totals = CrossServerService.ListServers(true)
		local search = restOf(ctx, 1):lower()
		local lines = {}
		for _, s in ipairs(servers) do
			local staff = table.concat(s.Staff or {}, ", ")
			if search ~= "" and not (s.Id:lower():find(search, 1, true) or staff:lower():find(search, 1, true)) then
				continue
			end
			if #lines >= 12 then
				table.insert(lines, "... more servers: narrow it down with ;servers <search>")
				break
			end
			local flags = {}
			if s.Id == CrossServerService.ServerId then
				table.insert(flags, "this server")
			end
			if s.Locked then
				table.insert(flags, "locked")
			end
			if s.Maint then
				table.insert(flags, "maintenance")
			end
			if s.Res then
				table.insert(flags, "created")
			elseif s.Priv then
				table.insert(flags, "private")
			end
			table.insert(lines, ("%s  %d/%d players  %d staff  %s (fps %d, ping %d)  up %s  v%s%s"):format(
				short(s.Id),
				s.N or 0,
				s.Max or 0,
				#(s.Staff or {}),
				s.Health or "?",
				s.Fps or 0,
				s.Ping or 0,
				duration(os.time() - (s.Start or os.time())),
				tostring(s.Ver or "?"),
				if #flags > 0 then "  [" .. table.concat(flags, ", ") .. "]" else ""
			))
		end
		if #lines == 0 then
			return { Success = true, Message = "No servers match." }
		end
		table.insert(lines, ("%d server(s), %d player(s), %d staff online."):format(totals.Servers, totals.Players, totals.Staff))
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

register({
	Name = "findplayer",
	Aliases = { "whereis" },
	Description = "Finds a player in any server, or tells you they are offline and whether they are banned.",
	Usage = "/findplayer player",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.view",
	Subcategory = "Servers",
	Cooldown = 1,
	Log = false,
	Examples = { "findplayer Builderman" },
	Execute = function(ctx: Ctx): Result
		local query = ctx.Arguments[1]
		if not query then
			return { Success = false, Message = "Usage: ;findplayer <name or UserId>" }
		end
		local lines = {}
		for _, match in ipairs(CrossServerService.FindPlayers(query, 8)) do
			table.insert(lines, ("%s (%d) is in server %s%s"):format(
				match.Name,
				match.UserId,
				short(match.ServerId),
				if match.ServerId == CrossServerService.ServerId then " (this server)" else ""
			))
		end
		if #lines > 0 then
			return { Success = true, Message = table.concat(lines, "\n") }
		end
		local user, err = resolveUser(query)
		if not user then
			return { Success = false, Message = err }
		end
		local ban = BanCommand.GetActiveBan(user.UserId)
		return {
			Success = true,
			Message = ("%s (%d) is not in any server.%s"):format(
				user.Name,
				user.UserId,
				if ban then (" Banned: %s"):format(ban.Reason) else " Not banned."
			),
		}
	end,
})

register({
	Name = "joinserver",
	Aliases = { "js" },
	Description = "Teleports you to another running server.",
	Usage = "/joinserver server",
	ArgHints = { server = SERVER_HINT },
	Permission = "crossserver.join",
	Subcategory = "Servers",
	Cooldown = 3,
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[1] then
			return { Success = false, Message = "Usage: ;joinserver <server id>" }
		end
		local ok, message = CrossServerService.JoinServer(ctx.Executor, ctx.Arguments[1])
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "follow",
	Aliases = { "gjoin" },
	Description = "Teleports you to the server a player is in.",
	Usage = "/follow player",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.join",
	Subcategory = "Servers",
	Cooldown = 3,
	Execute = function(ctx: Ctx): Result
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		if user.Local then
			return { Success = false, Message = user.Name .. " is in this server already." }
		end
		if not user.ServerId then
			return { Success = false, Message = user.Name .. " is not in any server." }
		end
		local ok, message = CrossServerService.JoinServer(ctx.Executor, user.ServerId)
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "xping",
	Description = "Asks every server to answer and shows how many did (tests the cross-server link).",
	Usage = "/xping",
	Permission = "crossserver.view",
	Subcategory = "Servers",
	Cooldown = 3,
	Log = false,
	Execute = function(ctx: Ctx): Result
		local started = os.clock()
		local op, err = CrossServerService.Send("ping", {}, { Actor = CrossServerService.ActorOf(ctx.Executor), Label = "ping" })
		if not op or op.Status == "failed" then
			return { Success = false, Message = "Ping failed: " .. tostring(err) }
		end
		local final = CrossServerService.WaitFor(op.Id, 3) or op
		return {
			Success = #final.Acks > 0,
			Message = ("%d/%d server(s) answered in %d ms, %d player(s) in total."):format(
				#final.Acks,
				#final.Expected,
				math.floor((os.clock() - started) * 1000),
				final.Affected
			),
		}
	end,
})

register({
	Name = "xstatus",
	Aliases = { "ops" },
	Description = "Shows recent cross-server operations from this server and which servers acknowledged them.",
	Usage = "/xstatus [id]",
	ArgHints = { id = { Type = "string", Description = "Operation id (first characters are enough)" } },
	Permission = "crossserver.view",
	Subcategory = "Servers",
	Cooldown = 1,
	Log = false,
	Execute = function(ctx: Ctx): Result
		local id = ctx.Arguments[1]
		if id then
			local op = CrossServerService.GetOperation(id:lower())
			if not op then
				return { Success = false, Message = "No operation with that id (or it matches several)." }
			end
			local lines = { ("%s  %s  [%s]  %s"):format(op.Id, op.Label, op.Status, CrossServerService.Describe(op)) }
			for _, ack in ipairs(op.Acks) do
				table.insert(lines, ("  %s  %s  %d affected%s"):format(
					short(ack.Server),
					if ack.Ok then "ok" else "refused",
					ack.Count,
					if ack.Message then "  " .. ack.Message else ""
				))
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		end
		local ops = CrossServerService.GetOperations(6)
		if #ops == 0 then
			return { Success = true, Message = "No cross-server operations from this server yet." }
		end
		local lines = {}
		for _, op in ipairs(ops) do
			table.insert(lines, ("%s  %s  [%s]  %d/%d answered, %d affected"):format(op.Id:sub(1, 6), op.Label, op.Status, #op.Acks, #op.Expected, op.Affected))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

-- ---------------------------------------------------------------------------
-- Moderation
-- ---------------------------------------------------------------------------
register({
	Name = "gkick",
	Aliases = { "globalkick" },
	Description = "Kicks a player from whichever server they are in.",
	Usage = "/gkick player [reason...]",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.kick",
	Subcategory = "Moderation",
	Cooldown = 1,
	Examples = { "gkick Player1 Spamming" },
	Execute = function(ctx: Ctx): Result
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		(ctx :: any).CaseTarget = { UserId = user.UserId, Name = user.Name } -- W12 cases
		if not canActOn(ctx.Executor, user) then
			return { Success = false, Message = PROTECTED }
		end
		local reason = "Kicked by staff."
		if #ctx.Arguments > 1 then
			local clean, failed = filtered(ctx, restOf(ctx, 2))
			if failed then
				return failed
			end
			reason = clean :: string
		end
		local result = sendAndReport("kick", { u = user.UserId, tn = user.Name, r = reason:sub(1, 300) }, {
			To = user.ServerId, -- nil = ask every server (the registry can lag a few seconds)
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "kick " .. user.Name,
			History = true,
			Target = user.Name,
		}, "Global kick of " .. user.Name, user.Name .. " wasn't found in any server")
		return result
	end,
})

register({
	Name = "gban",
	Aliases = { "globalban" },
	Description = "Bans a player from the whole experience, online in any server or offline, and removes them wherever they are.",
	Usage = "/gban player duration [reason...]",
	ArgHints = { player = PLAYER_HINT, duration = { Type = "duration", Description = "e.g. 30m, 7d, or perm" } },
	Permission = "crossserver.ban",
	Subcategory = "Moderation",
	Cooldown = 2,
	Examples = { "gban Player1 7d Exploiting", "gban Player1:7d Exploiting", "gban 123456 perm Alt account" },
	Execute = function(ctx: Ctx): Result
		-- Live test 2026-11-22: accept the local ;ban form "name:duration" too.
		local first = ctx.Arguments[1]
		local namePart, durationPart = (first or ""):match("^([^:]+):(.+)$")
		if namePart and DurationParser.Parse(durationPart) then
			table.remove(ctx.Arguments, 1)
			table.insert(ctx.Arguments, 1, durationPart)
			table.insert(ctx.Arguments, 1, namePart)
		end
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		(ctx :: any).CaseTarget = { UserId = user.UserId, Name = user.Name } -- W12 cases
		local parsed = DurationParser.Parse(ctx.Arguments[2] or "")
		if not parsed then
			return { Success = false, Message = "Usage: ;gban <player> <duration|perm> [reason]  (e.g. 30m, 7d, perm)" }
		end
		if not canActOn(ctx.Executor, user) then
			return { Success = false, Message = PROTECTED }
		end
		local reason = "Banned by staff."
		if #ctx.Arguments > 2 then
			local clean, failed = filtered(ctx, restOf(ctx, 3))
			if failed then
				return failed
			end
			reason = (clean :: string):sub(1, 300)
		end
		local previous = BanCommand.GetActiveBan(user.UserId)
		local issuedAt = os.time()
		local record = {
			BannedBy = ctx.Executor.UserId,
			BannedByName = ctx.Executor.Name,
			TargetName = user.Name,
			Reason = reason,
			IssuedAt = issuedAt,
			ExpiresAt = if parsed.IsPermanent then math.huge else issuedAt + parsed.Seconds,
		}
		-- Record first (so a rejoin is refused), then remove the player
		-- wherever they are. A server that finds them protected by rank
		-- refuses, and the record is rolled back.
		if not BanCommand.SetBan(user.UserId, record) then
			return { Success = false, Message = "The ban could not be saved; nothing was changed." }
		end
		local result, op = sendAndReport("ban", { u = user.UserId, tn = user.Name, r = reason }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = ("ban %s (%s)"):format(user.Name, if parsed.IsPermanent then "permanent" else parsed.Raw),
			History = true,
			Target = user.Name,
		}, ("Banned %s %s"):format(user.Name, if parsed.IsPermanent then "permanently" else "for " .. parsed.Raw))
		if not result.Success and result.Message == PROTECTED then
			BanCommand.SetBan(user.UserId, previous)
			return result
		end
		if not op or op.Status == "failed" then
			-- The record stands even if the other servers couldn't be told.
			return { Success = true, Message = ("Banned %s (saved). Other servers could not be reached, so they stay until they rejoin."):format(user.Name) }
		end
		EventBus.Publish("Player.Banned", user.Local or user.UserId, ctx.Executor, record)
		return result
	end,
})

register({
	Name = "gunban",
	Aliases = { "globalunban" },
	Description = "Lifts a player's ban for the whole experience (works for offline players).",
	Usage = "/gunban player",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.ban",
	Subcategory = "Moderation",
	Cooldown = 1,
	Execute = function(ctx: Ctx): Result
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		(ctx :: any).CaseTarget = { UserId = user.UserId, Name = user.Name } -- W12 cases
		if not BanCommand.GetActiveBan(user.UserId) then
			return { Success = false, Message = user.Name .. " is not banned." }
		end
		if not BanCommand.SetBan(user.UserId, nil) then
			return { Success = false, Message = "The ban could not be removed (DataStore error)." }
		end
		EventBus.Publish("Player.Unbanned", user.UserId)
		CrossServerService.RecordHistory({
			Actor = ctx.Executor.Name,
			ActorId = ctx.Executor.UserId,
			Kind = "unban",
			Label = "unban " .. user.Name,
			Target = user.Name,
			Servers = 0,
			Acked = 0,
			Affected = 1,
			Status = "complete",
		})
		return { Success = true, Message = ("Unbanned %s on every server."):format(user.Name) }
	end,
})

register({
	Name = "gwarn",
	Aliases = { "globalwarn" },
	Description = "Warns a player in any server (or offline). Escalation runs on the server they are in.",
	Usage = "/gwarn player reason...",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.warn",
	Subcategory = "Moderation",
	Cooldown = 1,
	Examples = { "gwarn Player1 Spamming in chat" },
	Execute = function(ctx: Ctx): Result
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		(ctx :: any).CaseTarget = { UserId = user.UserId, Name = user.Name } -- W12 cases
		if #ctx.Arguments < 2 then
			return { Success = false, Message = "Usage: ;gwarn <player> <reason>" }
		end
		if not canActOn(ctx.Executor, user) then
			return { Success = false, Message = PROTECTED }
		end
		local reason, failed = filtered(ctx, restOf(ctx, 2))
		if failed then
			return failed
		end
		reason = (reason :: string):sub(1, 300)
		if user.ServerId then
			local result, op = sendAndReport("warn", { u = user.UserId, tn = user.Name, r = reason }, {
				To = user.ServerId,
				Actor = CrossServerService.ActorOf(ctx.Executor),
				Label = "warn " .. user.Name,
				History = true,
				Target = user.Name,
			}, "Warned " .. user.Name)
			if not result.Success or (op and op.Affected > 0) or (op and op.Status == "pending") then
				return result
			end
			-- they left that server in the meantime: fall through to offline
		end
		local count = PunishmentService.AddWarningOffline(user.UserId, { UserId = ctx.Executor.UserId, Name = ctx.Executor.Name }, reason)
		if not count then
			return { Success = false, Message = "The warning could not be saved." }
		end
		CrossServerService.RecordHistory({
			Actor = ctx.Executor.Name,
			ActorId = ctx.Executor.UserId,
			Kind = "warn",
			Label = "warn " .. user.Name .. " (offline)",
			Target = user.Name,
			Servers = 0,
			Acked = 0,
			Affected = 1,
			Status = "complete",
		})
		return { Success = true, Message = ("Warned %s while offline (%d warning(s) on record)."):format(user.Name, count) }
	end,
})

register({
	Name = "createserver",
	Aliases = { "newserver", "reserveserver" },
	Description = "Reserves a brand-new server and teleports the players there (default: you). Staff can join it later with ;joinserver or ;follow.",
	Usage = "/createserver [players]",
	ArgHints = { players = { Type = "players", Description = "Who goes to the new server (default: you)" } },
	Permission = "crossserver.create",
	Subcategory = "Servers",
	Risk = "medium",
	Cooldown = 10,
	RequiresTarget = true,
	DefaultSelf = true,
	Examples = { "createserver", "createserver me,Player1", "createserver @staff" },
	Execute = function(ctx: Ctx): Result
		local ok, message = CrossServerService.CreateServer(ctx.Targets, ctx.Executor)
		return { Success = ok, Message = message }
	end,
})

register({
	Name = "gbring",
	Aliases = { "globalbring" },
	Description = "Brings a player from another server into this one.",
	Usage = "/gbring player",
	ArgHints = { player = PLAYER_HINT },
	Permission = "crossserver.bring",
	Subcategory = "Moderation",
	Cooldown = 3,
	Execute = function(ctx: Ctx): Result
		local user, err = resolveUser(ctx.Arguments[1])
		if not user then
			return { Success = false, Message = err }
		end
		if user.Local then
			return { Success = false, Message = user.Name .. " is in this server already (use ;bring)." }
		end
		if not user.ServerId then
			return { Success = false, Message = user.Name .. " is not in any server." }
		end
		if not canActOn(ctx.Executor, user) then
			return { Success = false, Message = PROTECTED }
		end
		local can, why = CrossServerService.CanTeleport()
		if not can then
			return { Success = false, Message = why }
		end
		if game.PrivateServerId ~= "" then
			return { Success = false, Message = "Players can't be brought into a private or reserved server." }
		end
		-- Live test 2026-11-22: a full server made the teleport fail silently
		-- on the other side (Roblox reports it later), yet "1 affected" came
		-- back. Refuse up front when there is no free slot.
		if #Players:GetPlayers() >= Players.MaxPlayers then
			return { Success = false, Message = ("This server is full (%d/%d) - %s can't be brought here."):format(#Players:GetPlayers(), Players.MaxPlayers, user.Name) }
		end
		local result = sendAndReport("bring", { u = user.UserId, tn = user.Name, j = CrossServerService.ServerId, pl = game.PlaceId }, {
			To = user.ServerId,
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "bring " .. user.Name,
			History = true,
			Target = user.Name,
		}, "Bringing " .. user.Name, user.Name .. " could not be brought")
		return result
	end,
})

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------
register({
	Name = "gannounce",
	Aliases = { "globalannounce", "ga" },
	Description = "Shows a banner announcement on every server.",
	Usage = "/gannounce message...",
	ArgHints = { message = { Description = "Optional style=, time=, color=, title= words, then the text" } },
	Permission = "crossserver.announce",
	Subcategory = "Operations",
	Cooldown = 3,
	Examples = { "gannounce Double XP starts in 10 minutes!" },
	Execute = function(ctx: Ctx): Result
		if #ctx.Arguments == 0 then
			return { Success = false, Message = "Usage: ;gannounce <message>" }
		end
		-- Options (style= time= color= title=) and history: AnnouncementService.
		local AnnouncementService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AnnouncementService"))
		local options, rest, err = AnnouncementService.ParseOptions(ctx.Arguments)
		if err then
			return { Success = false, Message = err }
		end
		local ok, why, record = AnnouncementService.Send(ctx.Executor, table.concat(rest, " "), "global", options)
		if not ok or not record then
			return { Success = false, Message = why }
		end
		local result = sendAndReport("announce", {
			m = (record.Text :: string):sub(1, 400),
			i = record.Id,
			d = ctx.Executor.DisplayName:sub(1, 40),
			s = record.Style,
			t = record.Duration,
			c = record.Color,
			h = record.Title,
		}, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "announcement",
			History = true,
		}, "Global announcement sent")
		return result
	end,
})

register({
	Name = "gnotify",
	Aliases = { "globalnotify" },
	Description = "Sends a notification to the staff of every server (shown as a toast and in the Cross-Server page).",
	Usage = "/gnotify message...",
	Permission = "crossserver.announce",
	Subcategory = "Operations",
	Cooldown = 2,
	Execute = function(ctx: Ctx): Result
		if #ctx.Arguments == 0 then
			return { Success = false, Message = "Usage: ;gnotify <message>" }
		end
		local text, failed = filtered(ctx, restOf(ctx, 1))
		if failed then
			return failed
		end
		local result = sendAndReport("notify", { m = (text :: string):sub(1, 300) }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "staff notification",
		}, "Staff notified")
		return result
	end,
})

register({
	Name = "lockdown",
	Aliases = { "globallock" },
	Description = "Locks every server (and servers that start later) to new players, or lifts the lockdown.",
	Usage = "/lockdown [on|off|status] [reason...]",
	Permission = "crossserver.lockdown",
	Subcategory = "Operations",
	Cooldown = 3,
	Examples = { "lockdown on Exploit wave", "lockdown off", "lockdown status" },
	-- Only enabling it is risky; status and lifting it run straight away.
	ConfirmWhen = function(arguments: { string }): boolean
		return (arguments[1] or ""):lower() == "on"
	end,
	Execute = function(ctx: Ctx): Result
		local action = (ctx.Arguments[1] or "status"):lower()
		local state = CrossServerService.GetGlobalState().Lockdown
		if action == "status" then
			return {
				Success = true,
				Message = if state.On
					then ("Global lockdown is ON (by %s%s)."):format(tostring(state.By), if state.Reason then ": " .. state.Reason else "")
					else "Global lockdown is off.",
			}
		end
		if action ~= "on" and action ~= "off" then
			return { Success = false, Message = "Usage: ;lockdown on|off|status [reason]" }
		end
		local on = action == "on"
		local reason: string? = nil
		if on and #ctx.Arguments > 1 then
			local clean, failed = filtered(ctx, restOf(ctx, 2))
			if failed then
				return failed
			end
			reason = (clean :: string):sub(1, 200)
		end
		local saved, err = CrossServerService.SetLockdown(on, ctx.Executor, reason)
		if not saved then
			return { Success = false, Message = err }
		end
		local result = sendAndReport("lockdown", { on = on, r = reason, at = os.time() }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = if on then "lockdown on" else "lockdown off",
			History = true,
		}, if on then "Global lockdown enabled" else "Global lockdown lifted")
		return result
	end,
})

register({
	Name = "gshutdown",
	Aliases = { "globalshutdown" },
	Description = "Kicks every player from every server with a message.",
	Usage = "/gshutdown [message...]",
	Permission = "crossserver.shutdown",
	Subcategory = "Operations",
	Cooldown = 10,
	Execute = function(ctx: Ctx): Result
		local message = "All servers are shutting down."
		if #ctx.Arguments > 0 then
			local clean, failed = filtered(ctx, restOf(ctx, 1))
			if failed then
				return failed
			end
			message = (clean :: string):sub(1, 300)
		end
		local result = sendAndReport("shutdown", { m = message }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "global shutdown",
			History = true,
		}, "Global shutdown started")
		return result
	end,
})

local function migrate(ctx: Ctx, everywhere: boolean): Result
	local seconds = 30
	local textFrom = 1
	if tonumber(ctx.Arguments[1]) then
		seconds = math.clamp(math.floor(tonumber(ctx.Arguments[1]) :: number), 5, 300)
		textFrom = 2
	end
	local message: string? = nil
	if #ctx.Arguments >= textFrom then
		local clean, failed = filtered(ctx, restOf(ctx, textFrom))
		if failed then
			return failed
		end
		message = (clean :: string):sub(1, 200)
	end
	local result = sendAndReport("migrate", { s = seconds, m = message }, {
		To = if everywhere then nil else CrossServerService.ServerId,
		Actor = CrossServerService.ActorOf(ctx.Executor),
		Label = if everywhere then ("update in %ds (all servers)"):format(seconds) else ("migrate this server in %ds"):format(seconds),
		History = true,
	}, if everywhere then ("Update countdown (%ds) started everywhere"):format(seconds) else ("Migration countdown (%ds) started"):format(seconds))
	return result
end

register({
	Name = "gupdate",
	Aliases = { "globalupdate", "migrateall" },
	Description = "Update countdown on every server, then moves all players to fresh servers (graceful migration).",
	Usage = "/gupdate [seconds] [message...]",
	Permission = "crossserver.migrate",
	Subcategory = "Operations",
	Cooldown = 10,
	Examples = { "gupdate 60 New update" },
	Execute = function(ctx: Ctx): Result
		return migrate(ctx, true)
	end,
})

register({
	Name = "migrateserver",
	Aliases = { "restartserver" },
	Description = "Countdown, then moves this server's players to a fresh server so this one can close.",
	Usage = "/migrateserver [seconds] [message...]",
	Permission = "crossserver.migrate",
	Subcategory = "Operations",
	Cooldown = 10,
	Execute = function(ctx: Ctx): Result
		return migrate(ctx, false)
	end,
})

register({
	Name = "global",
	Aliases = { "everywhere" },
	Description = "Runs one command on every server (weather, time, fog, lighting, slowmode, announce, countdown, hint, message, lock, maintenance).",
	Usage = "/global command...",
	ArgHints = { command = { Type = "text", Description = "A command line without players, e.g. weather foggy" } },
	Permission = "crossserver.execute",
	Subcategory = "Operations",
	Cooldown = 3,
	Examples = { "global weather foggy", "global slowmode 5", "global countdown 10 Event" },
	-- Only ask for confirmation when the inner command exists; an unknown one
	-- fails straight away instead of after ;confirm (live test 2026-11-22).
	ConfirmWhen = function(arguments: { string }): boolean
		local name = ((arguments[1] or ""):gsub("^[;:!%./]", "")):lower()
		return name ~= "" and CommandRegistry.Resolve(name) ~= nil
	end,
	Execute = function(ctx: Ctx): Result
		local line = (ctx.RawInput:match("^%s*%S+%s+(.+)$") or ""):gsub("^[;:!%./]", "")
		if line == "" then
			return { Success = false, Message = "Usage: ;global <command...>  e.g. ;global weather foggy" }
		end
		local parsed = CommandParser.ParseLine(line)
		local def = parsed and CommandRegistry.Resolve(parsed.CommandName)
		if not parsed or not def then
			return { Success = false, Message = "Unknown command: " .. (if parsed then parsed.CommandName else line) }
		end
		if not CommandPolicy.IsGlobalSafe(def) then
			return { Success = false, Message = ("%s can't run globally (only commands without player targets that are marked global-safe)."):format(def.Name) }
		end
		if not PermissionSystem.Has(ctx.Executor, def.Permission) then
			return { Success = false, Message = ("You don't have permission for %s (%s)."):format(def.Name, def.Permission) }
		end
		if CommandPolicy.IsOwnerOnly(def) and not table.find(PermissionSystem.GetRoles(ctx.Executor), "Owner") then
			return { Success = false, Message = def.Name .. " is restricted to the Owner." }
		end
		local result = sendAndReport("cmd", { l = line:sub(1, 400) }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "global: " .. line:sub(1, 60),
			History = true,
		}, ("Ran '%s' globally"):format(line), "No server ran the command")
		return result
	end,
})

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
register({
	Name = "staffchat",
	Aliases = { "sc" },
	Description = "Sends a message to the staff of every server (Cross-Server page > Staff Chat).",
	Usage = "/staffchat message...",
	Permission = "crossserver.staffchat",
	Subcategory = "Staff",
	Cooldown = 0.5,
	Log = false,
	Examples = { "staffchat Anyone free to check server 3f2a?" },
	Execute = function(ctx: Ctx): Result
		if #ctx.Arguments == 0 then
			return { Success = false, Message = "Usage: ;staffchat <message>" }
		end
		local text, failed = filtered(ctx, restOf(ctx, 1))
		if failed then
			return failed
		end
		local entry = {
			Id = CrossServerService.NewChatId(),
			Name = ctx.Executor.Name,
			Rank = RankService.GetTopRank(ctx.Executor),
			Text = (text :: string):sub(1, 300),
			Server = short(CrossServerService.ServerId),
			At = os.time(),
		}
		CrossServerService.PostStaffChat(entry, true)
		local op, err = CrossServerService.Send("chat", { id = entry.Id, n = entry.Name, r = entry.Rank, m = entry.Text, at = entry.At }, {
			Actor = CrossServerService.ActorOf(ctx.Executor),
			Label = "staff chat",
			NoAck = true,
		})
		if not op or op.Status == "failed" then
			return { Success = false, Message = "Shown here, but other servers couldn't be reached: " .. tostring(err) }
		end
		return { Success = true, Message = "Sent to staff chat." }
	end,
})

return true
