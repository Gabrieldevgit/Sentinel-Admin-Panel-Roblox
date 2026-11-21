--!strict
--[[
	Ban.lua

	Purpose:
		Reference implementation showing duration-modifier parsing
		("/ban Player:30m Exploiting"), DataStore-backed persistence (so a
		ban survives server restarts and applies across the whole game,
		not just one server), and the Undoable contract used by Phase 9's
		one-click rollback tool.

	Responsibilities:
		- Register the "ban" command (alias "b")
		- Parse the ":modifier" as a duration (perm/forever supported)
		- Persist ban records keyed by UserId
		- Kick any currently-connected banned player immediately
		- Check the ban store on PlayerAdded (wired in Init.server.lua)

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		CommandRegistry.lua (Core)
		DurationParser.lua (Core.Parser)
--]]

local DataStoreService = game:GetService("DataStoreService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local Core = script.Parent.Parent.Parent:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local TextFilterService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("TextFilterService"))
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))

local BanStore = DataStoreService:GetDataStore("Sentinel_Bans_v1")

export type BanRecord = {
	BannedBy: number,
	BannedByName: string?,
	TargetName: string?,
	Reason: string,
	IssuedAt: number,
	ExpiresAt: number, -- math.huge for permanent
}

local BanCommand = {}

function BanCommand.GetActiveBan(userId: number): BanRecord?
	local ok, record = pcall(function()
		return BanStore:GetAsync(tostring(userId))
	end)
	if not ok or not record then
		return nil
	end
	if record.ExpiresAt ~= math.huge and record.ExpiresAt < os.time() then
		return nil -- expired
	end
	return record :: BanRecord
end

-- W13: a ban index (key "_Index", UserId -> summary) next to the per-user
-- records, so the ban list doesn't need to scan the whole store. Every
-- write goes through writeBan so the record and the index stay together.
local INDEX_KEY = "_Index"

local function summarize(userId: number, record: any): any
	return {
		UserId = userId,
		Name = record.TargetName,
		Reason = record.Reason,
		IssuedAt = record.IssuedAt,
		ExpiresAt = if record.ExpiresAt == math.huge then -1 else record.ExpiresAt,
		BannedBy = record.BannedBy,
		BannedByName = record.BannedByName,
	}
end

local function updateIndex(userId: number, record: any?)
	pcall(function()
		BanStore:UpdateAsync(INDEX_KEY, function(old)
			local index = if type(old) == "table" then old else {}
			if record then
				index[tostring(userId)] = summarize(userId, record)
			else
				index[tostring(userId)] = nil
			end
			-- drop expired temporary bans while we're here
			local now = os.time()
			for key, entry in pairs(index) do
				if type(entry) ~= "table" or (entry.ExpiresAt ~= -1 and (entry.ExpiresAt or 0) < now) then
					index[key] = nil
				end
			end
			return index
		end)
	end)
end

local function writeBan(userId: number, record: BanRecord?): boolean
	local ok, err = pcall(function()
		if record then
			BanStore:SetAsync(tostring(userId), record)
		else
			BanStore:RemoveAsync(tostring(userId))
		end
	end)
	if not ok then
		warn(("[Sentinel.Ban] failed to persist ban for %d: %s"):format(userId, tostring(err)))
		return false
	end
	task.spawn(updateIndex, userId, record)
	return true
end

local function setBan(userId: number, record: BanRecord?)
	writeBan(userId, record)
end

-- Shared with the cross-server commands (;gban / ;gunban) and warning
-- escalation so the ban store keeps exactly one owner. Returns false when
-- the DataStore write failed.
function BanCommand.SetBan(userId: number, record: BanRecord?): boolean
	return writeBan(userId, record)
end

-- Active bans from the index, newest first. `rebuild` rescans every key of
-- the store once (ListKeysAsync) for bans given before the index existed.
function BanCommand.ListBans(rebuild: boolean?): ({ any }, string?)
	if rebuild then
		local ok, err = pcall(function()
			local pages = BanStore:ListKeysAsync()
			local fresh = {}
			while true do
				for _, key in ipairs(pages:GetCurrentPage()) do
					local id = tonumber(key.KeyName)
					if id then
						local record = BanCommand.GetActiveBan(id)
						if record then
							fresh[tostring(id)] = summarize(id, record)
						end
					end
				end
				if pages.IsFinished then
					break
				end
				pages:AdvanceToNextPageAsync()
			end
			BanStore:SetAsync(INDEX_KEY, fresh)
		end)
		if not ok then
			return {}, "Rebuilding the ban list failed: " .. tostring(err)
		end
	end
	local ok, index = pcall(function()
		return BanStore:GetAsync(INDEX_KEY)
	end)
	if not ok then
		return {}, "The ban list could not be read."
	end
	local list = {}
	local now = os.time()
	for _, entry in pairs(if type(index) == "table" then index else {}) do
		if type(entry) == "table" and (entry.ExpiresAt == -1 or (entry.ExpiresAt or 0) > now) then
			table.insert(list, entry)
		end
	end
	table.sort(list, function(a, b)
		return (a.IssuedAt or 0) > (b.IssuedAt or 0)
	end)
	return list, nil
end

CommandRegistry.Register({
	Name = "ban",
	Aliases = { "b" },
	Description = "Temporarily or permanently bans a player.",
	Usage = "/ban target:duration [reason]",
	Permission = "moderation.ban",
	Category = "Moderation",
	Cooldown = 2,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local duration = DurationParser.Parse(ctx.Modifier or "forever")
		if not duration then
			return { Success = false, Message = ("Invalid duration: %s"):format(ctx.Modifier or "") }
		end

		local reason = "Banned by staff."
		if #ctx.Arguments > 0 then
			-- Stored and shown to the banned player on every rejoin: filter
			-- once, store the filtered text.
			local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, table.concat(ctx.Arguments, " "))
			if not filtered then
				return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
			end
			reason = filtered
		end
		local issuedAt = os.time()
		local expiresAt = if duration.IsPermanent then math.huge else issuedAt + duration.Seconds

		local previousRecords: { [number]: BanCommand.BanRecord? } = {}
		local bannedIds: { number } = {}

		for _, target in ipairs(ctx.Targets) do
			previousRecords[target.UserId] = BanCommand.GetActiveBan(target.UserId)
			table.insert(bannedIds, target.UserId)

			local record: BanCommand.BanRecord = {
				BannedBy = ctx.Executor.UserId,
				BannedByName = ctx.Executor.Name,
				TargetName = target.Name,
				Reason = reason,
				IssuedAt = issuedAt,
				ExpiresAt = expiresAt,
			}
			setBan(target.UserId, record)

			EventBus.Publish("Player.Banned", target, ctx.Executor, record)
			target:Kick(("Banned: %s"):format(reason))
		end

		return {
			Success = true,
			Message = ("Banned %d player(s) %s."):format(
				#ctx.Targets,
				if duration.IsPermanent then "permanently" else "for " .. duration.Raw
			),
			Undoable = true,
			UndoData = { UserIds = bannedIds, Previous = previousRecords },
		}
	end,
	-- ;undo restores each player's previous ban record (or lifts the ban).
	-- The banned players were kicked, so this works without them in game.
	Undo = function(_ctx: Types.CommandContext, result: Types.CommandResult): Types.CommandResult
		local data = result.UndoData or {}
		for _, userId in ipairs(data.UserIds or {}) do
			setBan(userId, (data.Previous or {})[userId])
			EventBus.Publish("Player.Unbanned", userId)
		end
		return { Success = true, Message = ("Lifted the ban on %d player(s)."):format(#(data.UserIds or {})) }
	end,
} :: any)

-- ---------------------------------------------------------------------------
-- W13 offline management: ;unban, ;banlist, ;isbanned, ;profile
-- ---------------------------------------------------------------------------
local PlayerProfileService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("PlayerProfileService"))
PlayerProfileService.SetProviders({ GetActiveBan = BanCommand.GetActiveBan })

local function age(seconds: number): string
	return PlayerProfileService.FormatAge(seconds)
end

local function describeExpiry(expiresAt: number): string
	if expiresAt == -1 or expiresAt == math.huge then
		return "permanent"
	end
	return age(expiresAt - os.time()) .. " left"
end

CommandRegistry.Register({
	Name = "unban",
	Aliases = { "ub", "pardon" },
	Description = "Lifts a ban. Works for offline players (username or UserId).",
	Usage = "/unban player [reason...]",
	ArgHints = { player = { Type = "string", Description = "Username or UserId" } },
	Permission = "moderation.ban",
	Category = "Moderation",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "unban Player1", "unban 123456 Appeal accepted" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local user, err = PlayerProfileService.Resolve(ctx.Arguments[1], ctx.Executor)
		if not user then
			return { Success = false, Message = err }
		end
		;(ctx :: any).CaseTarget = { UserId = user.UserId, Name = user.Name }
		if not BanCommand.GetActiveBan(user.UserId) then
			return { Success = false, Message = user.Name .. " is not banned." }
		end
		if not BanCommand.SetBan(user.UserId, nil) then
			return { Success = false, Message = "The ban could not be removed (DataStore error)." }
		end
		EventBus.Publish("Player.Unbanned", user.UserId)
		return { Success = true, Message = ("Unbanned %s (%d)."):format(user.Name, user.UserId) }
	end,
} :: any)

CommandRegistry.Register({
	Name = "isbanned",
	Aliases = { "banstatus", "checkban" },
	TargetProtection = false,
	Description = "Tells whether a player (online or offline) is banned, why, and until when.",
	Usage = "/isbanned player",
	ArgHints = { player = { Type = "string", Description = "Username or UserId" } },
	Permission = "moderation.ban",
	Category = "Moderation",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local user, err = PlayerProfileService.Resolve(ctx.Arguments[1], ctx.Executor)
		if not user then
			return { Success = false, Message = err }
		end
		local ban = BanCommand.GetActiveBan(user.UserId)
		if not ban then
			return { Success = true, Message = ("%s (%d) is not banned."):format(user.Name, user.UserId) }
		end
		return {
			Success = true,
			Message = ("%s (%d) is banned (%s) by %s: %s"):format(
				user.Name,
				user.UserId,
				describeExpiry(ban.ExpiresAt),
				ban.BannedByName or tostring(ban.BannedBy),
				ban.Reason
			),
		}
	end,
} :: any)

CommandRegistry.Register({
	Name = "banlist",
	Aliases = { "bans" },
	TargetProtection = false,
	Description = "Lists active bans (search by name or reason). ;banlist rebuild rescans the store.",
	Usage = "/banlist [search...]",
	Permission = "moderation.ban",
	Category = "Moderation",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local query = table.concat(ctx.Arguments, " "):lower()
		local rebuild = query == "rebuild"
		local list, err = BanCommand.ListBans(rebuild)
		if err then
			return { Success = false, Message = err }
		end
		local lines = {}
		for _, b in ipairs(list) do
			local text = ("%s (%d)  %s  by %s  %s"):format(
				b.Name or "?",
				b.UserId,
				describeExpiry(b.ExpiresAt),
				b.BannedByName or tostring(b.BannedBy),
				b.Reason or ""
			)
			if rebuild or query == "" or text:lower():find(query, 1, true) then
				table.insert(lines, text)
			end
		end
		if #lines == 0 then
			return { Success = true, Message = "No active bans" .. (if query ~= "" and not rebuild then " match." else ".") }
		end
		local shown = table.move(lines, 1, math.min(20, #lines), 1, {})
		return {
			Success = true,
			Message = ("%d active ban(s)%s:\n%s"):format(#lines, if #lines > 20 then ", newest 20" else "", table.concat(shown, "\n")),
		}
	end,
} :: any)

CommandRegistry.Register({
	Name = "profile",
	Aliases = { "whois", "lookup", "seen" },
	TargetProtection = false,
	Description = "Shows a player's profile, online or offline: when they were seen, play time, previous names, ban, warnings, cases, notes.",
	Usage = "/profile player",
	ArgHints = { player = { Type = "string", Description = "Username or UserId" } },
	Permission = "panel.open",
	Category = "Moderation",
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "profile Player1", "whois 123456" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local p, err = PlayerProfileService.Profile(ctx.Arguments[1], ctx.Executor)
		if not p then
			return { Success = false, Message = err }
		end
		local lines = {
			("%s (@%s, %d)%s"):format(p.DisplayName or p.Name, p.Name, p.UserId, if p.Online then "  online: " .. tostring(p.Server) else "  offline"),
		}
		if p.LastSeen then
			table.insert(lines, ("Seen %s ago, first %s ago, %d session(s), played %s%s"):format(
				age(os.time() - p.LastSeen),
				age(os.time() - p.FirstSeen),
				p.Sessions or 0,
				age(p.PlayTime or 0),
				if p.AccountAge then (", account %d days old"):format(p.AccountAge) else ""
			))
		else
			table.insert(lines, "Never seen in this experience by Sentinel.")
		end
		if p.Names and #p.Names > 1 then
			table.insert(lines, "Usernames seen: " .. table.concat(p.Names, ", "))
		end
		if p.BoundRanks and #p.BoundRanks > 0 then
			table.insert(lines, "Ranks: " .. table.concat(p.BoundRanks, ", "))
		end
		table.insert(lines, if p.Ban
			then ("BANNED (%s): %s"):format(describeExpiry(p.Ban.ExpiresAt), p.Ban.Reason)
			else "Not banned.")
		table.insert(lines, ("%d warning(s), %d case(s), %d note(s)"):format(p.WarningCount or 0, p.CaseCount or 0, #(p.Notes or {})))
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
} :: any)

return BanCommand
