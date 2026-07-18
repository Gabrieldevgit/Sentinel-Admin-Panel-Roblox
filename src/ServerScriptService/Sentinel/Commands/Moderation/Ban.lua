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
local DurationParser = require(Core:WaitForChild("Parser"):WaitForChild("DurationParser"))

local BanStore = DataStoreService:GetDataStore("Sentinel_Bans_v1")

export type BanRecord = {
	BannedBy: number,
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

local function setBan(userId: number, record: BanRecord)
	local ok, err = pcall(function()
		BanStore:SetAsync(tostring(userId), record)
	end)
	if not ok then
		warn(("[Sentinel.Ban] failed to persist ban for %d: %s"):format(userId, tostring(err)))
	end
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

		local reason = if #ctx.Arguments > 0 then table.concat(ctx.Arguments, " ") else "Banned by staff."
		local issuedAt = os.time()
		local expiresAt = if duration.IsPermanent then math.huge else issuedAt + duration.Seconds

		local previousRecords: { [number]: BanCommand.BanRecord? } = {}

		for _, target in ipairs(ctx.Targets) do
			previousRecords[target.UserId] = BanCommand.GetActiveBan(target.UserId)

			local record: BanCommand.BanRecord = {
				BannedBy = ctx.Executor.UserId,
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
			UndoData = previousRecords,
		}
	end,
})

return BanCommand
