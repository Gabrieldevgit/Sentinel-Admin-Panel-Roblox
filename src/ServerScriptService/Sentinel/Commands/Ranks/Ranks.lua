--!strict
--[[
	Ranks.lua

	Purpose:
		Chat/palette front-end for Systems/RankService. Every rule (hierarchy,
		protected Owner, validation, persistence) lives in RankService; these
		commands only parse arguments and report the result.

	Commands:
		;ranks                                   list ranks
		;rankinfo Rank                           details of one rank
		;myrank                                  your ranks and priority
		;createrank Name priority [Parent,...]   create a rank
		;deleterank Rank
		;renamerank Rank NewName
		;duplicaterank Rank NewName
		;editrank Rank priority|color|icon|description|inherits value...
		;rankperm Rank +node | -node             grant / remove a permission node
		;assignrank target[:duration] Rank       give online player(s) a rank (temporary with :7d)
		;unassignrank target Rank
		;bindrank kind value Rank [duration] [minGroupRank]
		      kinds: username userid group grouprole gamepass asset creator privateserver
		;unbindrank id
		;rankbindings [Rank]                     list assignments with their ids
		;rankhistory [count]
		;resetranks confirm                      restore default templates (Owner only)

	Permission nodes: ranks.view (read), ranks.manage (edit ranks),
	ranks.assign (assignments). SuperAdmin has ranks.*; Owner has *.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local DurationParser = require(Sentinel.Core:WaitForChild("Parser"):WaitForChild("DurationParser"))
local RankService = require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function result(ok: boolean, message: string): Result
	return { Success = ok, Message = message }
end

local function rest(args: { string }, from: number): string
	local parts = {}
	for i = from, #args do
		table.insert(parts, args[i])
	end
	return table.concat(parts, " ")
end

local function readOnlyNote(): string
	return if RankService.IsReadOnly() then " (read-only: saved rank data could not be loaded)" else ""
end

local function register(def: any)
	def.Category = "Ranks"
	def.Log = if def.Log == nil then true else def.Log
	def.Undoable = false
	def.Cooldown = def.Cooldown or 1
	CommandRegistry.Register(def)
end

register({
	Name = "ranks",
	Aliases = { "listranks" },
	Description = "Lists every rank by priority.",
	Usage = "/ranks",
	Permission = "ranks.view",
	Log = false,
	Execute = function(_ctx: Ctx): Result
		local parts = {}
		for _, rank in ipairs(RankService.GetRanks()) do
			table.insert(parts, ("%s %s (%d)"):format(rank.Icon, rank.Name, rank.Priority))
		end
		return result(true, table.concat(parts, " | ") .. readOnlyNote())
	end,
})

register({
	Name = "rankinfo",
	Aliases = {},
	Description = "Shows a rank's priority, inheritance, permissions and assignments.",
	Usage = "/rankinfo Rank",
	Permission = "ranks.view",
	Log = false,
	Execute = function(ctx: Ctx): Result
		local rank = RankService.GetRank(ctx.Arguments[1] or "")
		if not rank then
			return result(false, "Usage: /rankinfo Rank")
		end
		local inherits = if #rank.Inherits > 0 then table.concat(rank.Inherits, ",") else "none"
		local nodes = if #rank.Nodes > 0 then table.concat(rank.Nodes, ", ") else "none"
		return result(true, ("%s %s — priority %d, color %d,%d,%d, inherits %s%s. %s Nodes: %s. Assignments: %d."):format(
			rank.Icon,
			rank.Name,
			rank.Priority,
			rank.Color[1],
			rank.Color[2],
			rank.Color[3],
			inherits,
			if rank.Protected then ", protected" else "",
			rank.Description,
			nodes,
			#RankService.GetBindings(rank.Name)
		))
	end,
})

register({
	Name = "myrank",
	Aliases = { "whoami" },
	Description = "Shows your ranks and priority.",
	Usage = "/myrank",
	Permission = "ranks.view",
	Log = false,
	Execute = function(ctx: Ctx): Result
		local top = RankService.GetTopRank(ctx.Executor)
		if not top then
			return result(true, "You have no rank.")
		end
		return result(true, ("Top rank: %s (priority %d)."):format(top, RankService.GetPriority(ctx.Executor)))
	end,
})

register({
	Name = "createrank",
	Aliases = { "addrank" },
	Description = "Creates a rank below your own.",
	Usage = "/createrank Name priority [Parent1,Parent2]",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		local name, priority = ctx.Arguments[1], tonumber(ctx.Arguments[2] or "")
		if not name or not priority then
			return result(false, "Usage: /createrank Name priority [Parent1,Parent2]")
		end
		local parents = {}
		for piece in (ctx.Arguments[3] or ""):gmatch("[^,]+") do
			table.insert(parents, piece)
		end
		return result(RankService.CreateRank(ctx.Executor, name, priority, parents))
	end,
})

register({
	Name = "deleterank",
	Aliases = { "removerank" },
	Description = "Deletes a rank (and its assignments).",
	Usage = "/deleterank Rank",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[1] then
			return result(false, "Usage: /deleterank Rank")
		end
		return result(RankService.DeleteRank(ctx.Executor, ctx.Arguments[1]))
	end,
})

register({
	Name = "renamerank",
	Aliases = {},
	Description = "Renames a rank, keeping its assignments.",
	Usage = "/renamerank Rank NewName",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[2] then
			return result(false, "Usage: /renamerank Rank NewName")
		end
		return result(RankService.RenameRank(ctx.Executor, ctx.Arguments[1], ctx.Arguments[2]))
	end,
})

register({
	Name = "duplicaterank",
	Aliases = { "copyrank" },
	Description = "Copies a rank's settings and permissions to a new rank.",
	Usage = "/duplicaterank Rank NewName",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[2] then
			return result(false, "Usage: /duplicaterank Rank NewName")
		end
		return result(RankService.DuplicateRank(ctx.Executor, ctx.Arguments[1], ctx.Arguments[2]))
	end,
})

register({
	Name = "editrank",
	Aliases = {},
	Description = "Edits a rank's priority, color, icon, description or inheritance.",
	Usage = "/editrank Rank priority|color|icon|description|inherits value",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[2] then
			return result(false, "Usage: /editrank Rank priority|color|icon|description|inherits value")
		end
		return result(RankService.EditRank(ctx.Executor, ctx.Arguments[1], ctx.Arguments[2], rest(ctx.Arguments, 3)))
	end,
})

register({
	Name = "rankperm",
	Aliases = { "rankpermission" },
	Description = "Grants (+node) or removes (-node) a permission node on a rank.",
	Usage = "/rankperm Rank +node|-node",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		local name, change = ctx.Arguments[1], ctx.Arguments[2]
		if not name or not change or #ctx.Arguments > 2 then
			return result(false, "Usage: /rankperm Rank +node|-node (one node, no spaces)")
		end
		local sign, node = change:sub(1, 1), change:sub(2)
		if sign ~= "+" and sign ~= "-" then
			sign, node = "+", change
		end
		return result(RankService.SetNode(ctx.Executor, name, node, sign == "+"))
	end,
})

register({
	Name = "assignrank",
	Aliases = { "promote" },
	Description = "Gives online player(s) a rank. Add :duration for a temporary rank.",
	Usage = "/assignrank target[:duration] Rank",
	Permission = "ranks.assign",
	RequiresTarget = true,
	Execute = function(ctx: Ctx): Result
		local rankName = ctx.Arguments[1]
		if not rankName then
			return result(false, "Usage: /assignrank target[:duration] Rank")
		end
		local seconds: number? = nil
		if ctx.Modifier then
			local parsed = DurationParser.Parse(ctx.Modifier)
			if not parsed then
				return result(false, ("Invalid duration '%s' (use e.g. 30m, 2h, 7d)."):format(ctx.Modifier))
			end
			seconds = if parsed.IsPermanent then nil else parsed.Seconds
		end
		local messages, allOk = {}, true
		for _, target in ipairs(ctx.Targets) do
			local ok, msg = RankService.AddBinding(ctx.Executor, "userid", target.UserId, rankName, seconds)
			allOk = allOk and ok
			table.insert(messages, msg)
		end
		return result(allOk, table.concat(messages, " "))
	end,
})

register({
	Name = "unassignrank",
	Aliases = { "demote" },
	Description = "Removes a directly-assigned rank from online player(s).",
	Usage = "/unassignrank target Rank",
	Permission = "ranks.assign",
	RequiresTarget = true,
	Execute = function(ctx: Ctx): Result
		local rankName = ctx.Arguments[1]
		if not rankName then
			return result(false, "Usage: /unassignrank target Rank")
		end
		local messages, allOk = {}, true
		for _, target in ipairs(ctx.Targets) do
			local ok, msg = RankService.RemoveUserRank(ctx.Executor, target.UserId, rankName)
			allOk = allOk and ok
			table.insert(messages, msg)
		end
		return result(allOk, table.concat(messages, " "))
	end,
})

register({
	Name = "bindrank",
	Aliases = { "rankbind" },
	Description = "Assigns a rank by username, UserId, group, group role, GamePass, asset, creator or private-server owner.",
	Usage = "/bindrank kind value Rank [duration] [minGroupRank]",
	Permission = "ranks.assign",
	Execute = function(ctx: Ctx): Result
		local args = ctx.Arguments
		local kind = (args[1] or ""):lower()
		local value, rankName, extraIndex
		-- creator / privateserver take no value
		if kind == "creator" or kind == "privateserver" or kind == "privateserverowner" then
			value, rankName, extraIndex = nil, args[2], 3
		else
			value, rankName, extraIndex = args[2], args[3], 4
		end
		if kind == "" or not rankName then
			return result(false, "Usage: /bindrank kind value Rank [duration] [minGroupRank]")
		end
		local seconds: number? = nil
		local minRank: number? = nil
		for i = extraIndex, #args do
			local parsed = DurationParser.Parse(args[i])
			if parsed then
				seconds = if parsed.IsPermanent then nil else parsed.Seconds
			elseif tonumber(args[i]) then
				minRank = tonumber(args[i])
			else
				return result(false, ("Didn't understand '%s' (expected a duration like 7d or a group rank number)."):format(args[i]))
			end
		end
		return result(RankService.AddBinding(ctx.Executor, kind, value, rankName, seconds, minRank))
	end,
})

register({
	Name = "unbindrank",
	Aliases = { "removebinding" },
	Description = "Removes a rank assignment by its id (see /rankbindings).",
	Usage = "/unbindrank id",
	Permission = "ranks.assign",
	Execute = function(ctx: Ctx): Result
		if not ctx.Arguments[1] then
			return result(false, "Usage: /unbindrank id")
		end
		return result(RankService.RemoveBinding(ctx.Executor, ctx.Arguments[1]))
	end,
})

register({
	Name = "rankbindings",
	Aliases = { "rankassignments" },
	Description = "Lists rank assignments and their ids.",
	Usage = "/rankbindings [Rank]",
	Permission = "ranks.view",
	Log = false,
	Execute = function(ctx: Ctx): Result
		local bindings = RankService.GetBindings(ctx.Arguments[1])
		if #bindings == 0 then
			return result(true, "No assignments.")
		end
		local parts = {}
		for _, b in ipairs(bindings) do
			table.insert(parts, ("[%s] %s"):format(b.Id, RankService.DescribeBinding(b)))
		end
		return result(true, table.concat(parts, " | "))
	end,
})

register({
	Name = "rankhistory",
	Aliases = {},
	Description = "Shows recent rank and permission changes.",
	Usage = "/rankhistory [count]",
	Permission = "ranks.view",
	Log = false,
	Execute = function(ctx: Ctx): Result
		local count = math.clamp(tonumber(ctx.Arguments[1] or "") or 10, 1, 50)
		local history = RankService.GetHistory(count)
		if #history == 0 then
			return result(true, "No rank changes yet.")
		end
		local parts = {}
		for _, h in ipairs(history) do
			table.insert(parts, ("%s %s: %s"):format(os.date("!%m-%d %H:%M", h.Time), h.ActorName, h.Detail))
		end
		return result(true, table.concat(parts, " | "))
	end,
})

register({
	Name = "resetranks",
	Aliases = {},
	Description = "Restores the default rank templates and assignments (Owner only).",
	Usage = "/resetranks confirm",
	Permission = "ranks.manage",
	Execute = function(ctx: Ctx): Result
		if (ctx.Arguments[1] or ""):lower() ~= "confirm" then
			return result(false, "This deletes every custom rank and assignment. Type /resetranks confirm to proceed.")
		end
		return result(RankService.ResetToDefaults(ctx.Executor))
	end,
})

return true
