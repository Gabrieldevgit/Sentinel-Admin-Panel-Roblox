--!strict
--[[
	ServerBan.lua (HD Admin gap: ServerBan / UnServerBan)

	A ban from THIS server only: the player is kicked and turned away if
	they try to rejoin it, but can join any other server of the game. Kept
	in server memory (no DataStore), so it ends when the server closes, or
	after the optional duration.

		;serverban <players>[:duration] [reason]   (sban, sb)
		;unserverban <name|UserId|all>             (unsban, usb)
		;serverbans                                (sbans) list

	Node moderation.serverban (default Moderator rank + Admin via
	moderation.*; saved ranks are not migrated: ;rankperm <rank>
	+moderation.serverban).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local TextFilterService = require(Sentinel:WaitForChild("Systems"):WaitForChild("TextFilterService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

export type ServerBanRecord = {
	UserId: number,
	Name: string,
	Reason: string,
	By: string,
	At: number,
	ExpiresAt: number?, -- nil = until the server closes
}

local ServerBan = {}

local bans: { [number]: ServerBanRecord } = {}

local function active(userId: number): ServerBanRecord?
	local record = bans[userId]
	if record and record.ExpiresAt and record.ExpiresAt <= os.time() then
		bans[userId] = nil
		return nil
	end
	return record
end

local function prettyLeft(record: ServerBanRecord): string
	if not record.ExpiresAt then
		return "until the server closes"
	end
	local left = math.max(0, record.ExpiresAt - os.time())
	if left >= 3600 then
		return ("%dh %dm left"):format(left // 3600, (left % 3600) // 60)
	elseif left >= 60 then
		return ("%dm left"):format(left // 60)
	end
	return ("%ds left"):format(left)
end

local function kickMessage(record: ServerBanRecord): string
	return ("You are banned from this server (%s). Reason: %s. You can join another server."):format(
		prettyLeft(record),
		record.Reason
	)
end

function ServerBan.Get(userId: number): ServerBanRecord?
	return active(userId)
end

function ServerBan.List(): { ServerBanRecord }
	local list = {}
	for userId in pairs(bans) do
		local record = active(userId)
		if record then
			table.insert(list, record)
		end
	end
	table.sort(list, function(a, b)
		return a.At > b.At
	end)
	return list
end

function ServerBan.Add(record: ServerBanRecord)
	bans[record.UserId] = record
	local player = Players:GetPlayerByUserId(record.UserId)
	if player then
		EventBus.Publish("Player.BeforeKick", player, nil, record.Reason)
		player:Kick(kickMessage(record))
	end
end

function ServerBan.Remove(userId: number): boolean
	local had = active(userId) ~= nil
	bans[userId] = nil
	return had
end

function ServerBan._ClearForTests()
	table.clear(bans)
end

Players.PlayerAdded:Connect(function(player: Player)
	local record = active(player.UserId)
	if record then
		player:Kick(kickMessage(record))
	end
end)

CommandRegistry.Register({
	Name = "serverban",
	Aliases = { "sban", "sb" },
	Description = "Bans a player from this server only: kicked now and refused if they rejoin it, until the server closes or the duration ends. Other servers still let them in.",
	Usage = "/serverban target[:duration] [reason...]",
	Permission = "moderation.serverban",
	Category = "Moderation",
	Subcategory = "Bans",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Examples = { "serverban Player1 Spamming", "serverban Player1:30m Griefing" },
	Execute = function(ctx: CommandContext): CommandResult
		local expiresAt: number? = nil
		if ctx.Modifier and ctx.Modifier ~= "" then
			local duration = DurationParser.Parse(ctx.Modifier)
			if not duration then
				return { Success = false, Message = ("Invalid duration: %s"):format(ctx.Modifier) }
			end
			if not duration.IsPermanent then
				expiresAt = os.time() + math.floor(duration.Seconds)
			end
		end
		local reason = "Banned from this server by staff"
		if #ctx.Arguments > 0 then
			local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, table.concat(ctx.Arguments, " "))
			if not filtered then
				return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
			end
			reason = filtered
		end

		local ids, names = {}, {}
		for _, target in ipairs(ctx.Targets) do
			if target == ctx.Executor then
				continue
			end
			table.insert(ids, target.UserId)
			table.insert(names, target.Name)
			ServerBan.Add({
				UserId = target.UserId,
				Name = target.Name,
				Reason = reason,
				By = ctx.Executor.Name,
				At = os.time(),
				ExpiresAt = expiresAt,
			})
		end
		if #ids == 0 then
			return { Success = false, Message = "You can't server-ban yourself." }
		end
		return {
			Success = true,
			Message = ("Server-banned %s (%s)."):format(
				table.concat(names, ", "),
				if expiresAt then ctx.Modifier :: string else "until this server closes"
			),
			Undoable = true,
			UndoData = { UserIds = ids },
		} :: any
	end,
	Undo = function(_ctx: CommandContext, result: any): CommandResult
		local count = 0
		for _, userId in ipairs((result.UndoData or {}).UserIds or {}) do
			if ServerBan.Remove(userId) then
				count += 1
			end
		end
		return { Success = true, Message = ("Lifted %d server ban(s)."):format(count) }
	end,
} :: any)

CommandRegistry.Register({
	Name = "unserverban",
	Aliases = { "unsban", "usb" },
	Description = "Lifts a server ban (this server only). Give the name or UserId shown by ;serverbans, or 'all'.",
	Usage = "/unserverban player",
	ArgHints = {
		player = {
			Type = "string",
			Description = "Name, UserId or all",
			Suggestions = { "all" },
		},
	},
	Permission = "moderation.serverban",
	Category = "Moderation",
	Subcategory = "Bans",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	TargetProtection = false,
	Examples = { "unserverban Player1", "unserverban all" },
	Execute = function(ctx: CommandContext): CommandResult
		local query = ctx.Arguments[1]
		if not query or query == "" then
			return { Success = false, Message = "Give a name or UserId (see ;serverbans), or 'all'." }
		end
		local list = ServerBan.List()
		if query:lower() == "all" then
			for _, record in ipairs(list) do
				ServerBan.Remove(record.UserId)
			end
			return { Success = true, Message = ("Lifted %d server ban(s)."):format(#list) }
		end
		local asId = tonumber(query)
		local lower = query:lower():gsub("^@", "")
		local match: ServerBanRecord? = nil
		for _, record in ipairs(list) do
			if record.UserId == asId or record.Name:lower() == lower then
				match = record
				break
			end
		end
		if not match then
			local found = {}
			for _, record in ipairs(list) do
				if record.Name:lower():sub(1, #lower) == lower then
					table.insert(found, record)
				end
			end
			if #found > 1 then
				return { Success = false, Message = ("'%s' matches %d server bans - be more specific."):format(query, #found) }
			end
			match = found[1]
		end
		if not match then
			return { Success = false, Message = ("%s is not server-banned here."):format(query) }
		end
		ServerBan.Remove(match.UserId)
		return { Success = true, Message = ("Lifted the server ban on %s."):format(match.Name) }
	end,
} :: any)

CommandRegistry.Register({
	Name = "serverbans",
	Aliases = { "sbans", "serverbanlist" },
	Description = "Lists the players banned from this server (name, reason, who, time left).",
	Usage = "/serverbans",
	Permission = "moderation.serverban",
	Category = "Moderation",
	Subcategory = "Bans",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Execute = function(_ctx: CommandContext): CommandResult
		local list = ServerBan.List()
		if #list == 0 then
			return { Success = true, Message = "No server bans on this server." }
		end
		local lines = { ("%d server ban(s):"):format(#list) }
		for _, record in ipairs(list) do
			table.insert(
				lines,
				("%s (%d) - %s - by %s, %s"):format(record.Name, record.UserId, record.Reason, record.By, prettyLeft(record))
			)
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
} :: any)

return ServerBan
