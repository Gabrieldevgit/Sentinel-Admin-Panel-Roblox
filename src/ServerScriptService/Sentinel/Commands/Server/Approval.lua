--!strict
--[[
	Approval.lua - commands for Systems/ApprovalService (owner approval).

		;approve [id]            Owner: run a waiting risky command
		                         (no id = the only / oldest request)
		;deny [id] [reason...]   Owner: refuse it (the requester is told why)
		;approvals               list the requests waiting for the Owner
		;approvals test <cmd>    Studio only: send yourself a test request to
		                         see the Owner's card (approving it runs nothing)

	Settings: ;config ownerapproval on|off, ;config approvalrisk
	critical|high|medium, ;config approvaltimeout <seconds>.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local ApprovalService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ApprovalService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function pickId(id: string?): (string?, string?)
	if id and id ~= "" then
		return (id:gsub("^#", "")), nil
	end
	local list = ApprovalService.List()
	if #list == 0 then
		return nil, "Nothing is waiting for approval."
	end
	if #list > 1 then
		return nil, ("%d requests are waiting - give an id (;approvals lists them)."):format(#list)
	end
	return list[1].Id, nil
end

CommandRegistry.Register({
	Name = "approve",
	Aliases = { "allow" },
	Description = "Owner: approves a risky command another staff member is waiting to run.",
	Usage = "/approve [id]",
	Permission = "approval.respond",
	OwnerOnly = true,
	Category = "Server",
	Subcategory = "Security",
	Cooldown = 1,
	Log = false, -- ApprovalService writes its own audit entry
	NoHistory = true,
	RequiresTarget = false,
	Execute = function(ctx: Ctx): Result
		local id, err = pickId(ctx.Arguments[1])
		if not id then
			return { Success = false, Message = err }
		end
		local ok, message = ApprovalService.Respond(ctx.Executor, id, true)
		return { Success = ok, Message = message }
	end,
})

CommandRegistry.Register({
	Name = "deny",
	Aliases = { "refuse" },
	Description = "Owner: refuses a risky command another staff member is waiting to run.",
	Usage = "/deny [id] [reason...]",
	Permission = "approval.respond",
	OwnerOnly = true,
	Category = "Server",
	Subcategory = "Security",
	Cooldown = 1,
	Log = false,
	NoHistory = true,
	RequiresTarget = false,
	Execute = function(ctx: Ctx): Result
		local first = ctx.Arguments[1]
		local id, reasonStart = first, 2
		-- ";deny Not now" (single request): the first word is part of the reason.
		if first and #ApprovalService.List() == 1 and first:gsub("^#", ""):lower() ~= ApprovalService.List()[1].Id then
			id, reasonStart = nil, 1
		end
		local picked, err = pickId(id)
		if not picked then
			return { Success = false, Message = err }
		end
		local reason = table.concat(ctx.Arguments, " ", reasonStart)
		local ok, message = ApprovalService.Respond(ctx.Executor, picked, false, reason)
		return { Success = ok, Message = message }
	end,
})

CommandRegistry.Register({
	Name = "approvals",
	Aliases = { "pendingapprovals" },
	Description = "Lists commands waiting for the Owner's approval. Studio: ;approvals test <command> previews the Owner's card.",
	Usage = "/approvals [test] [command...]",
	Permission = "panel.open",
	Category = "Server",
	Subcategory = "Security",
	Cooldown = 1,
	Log = false,
	NoHistory = true,
	RequiresTarget = false,
	Execute = function(ctx: Ctx): Result
		if (ctx.Arguments[1] or ""):lower() == "test" then
			if not RunService:IsStudio() then
				return { Success = false, Message = "Test requests only work in Studio." }
			end
			if not ApprovalService.IsOwner(ctx.Executor) then
				return { Success = false, Message = "Only an Owner can preview the approval card." }
			end
			local text = table.concat(ctx.Arguments, " ", 2)
			local def = CommandRegistry.Resolve((text:match("^(%S+)") or "shutdown"):lower())
			if not def then
				return { Success = false, Message = "Unknown command to test with." }
			end
			local r = ApprovalService.Test(ctx.Executor, def, if text ~= "" then text else def.Name)
			return { Success = true, Message = ("Test request #%s sent to you (approving it runs nothing)."):format(r.Id) }
		end
		local list = ApprovalService.List()
		if #list == 0 then
			return { Success = true, Message = "Nothing is waiting for approval." }
		end
		local lines = {}
		for _, r in ipairs(list) do
			table.insert(lines, ("#%s  %s: ;%s  (%s risk, %ds left)"):format(r.Id, r.Requester.Name, r.Text, r.Risk, math.max(0, r.Expires - os.time())))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
})

return true
