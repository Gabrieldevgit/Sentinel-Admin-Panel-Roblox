--!strict
--[[
	ApprovalService.lua (owner approval, before W14)

	Purpose:
		Security for risky commands. While an Owner is in the server, a
		risky command typed by anyone who is not an Owner does not run: it
		becomes a request the Owner approves or denies. No answer within the
		timeout = denied. With no Owner online, commands run as before.

	Settings (AdminConfig, Administration page > Security):
		ownerapproval   on | off             (ConfigService OwnerApproval, default on)
		approvalrisk    critical|high|medium (ApprovalRisk, default critical)
		approvaltimeout 15-300 seconds       (ApprovalTimeout, default 60)

	How it hooks in:
		A CommandRegistry Before hook (runs after the executor already
		passed the ;confirm step) returns { Message, Pending = true,
		ApprovalId } to hold the command. On approval the same command text
		is replayed with CommandProcessor.Process(executor, text,
		{ Confirmed = true, Source = "approval", ApprovalToken }) - so
		permissions, rank protection, logging and hooks all run again. The
		executor gets the results on CommandResultRemote.

		Commands from another server (;global -> DispatchRemote, executor is
		a plain table) are not held.

	Remote ApprovalRemote (RemoteEvent):
		server -> Owner     ("request", { Id, Command, Text, Risk, Requester
		                    = { UserId, Name, DisplayName, Rank }, Expires, Timeout })
		                    ("closed", id, status)   -- answered / expired elsewhere
		Owner -> server     ("approve" | "deny", id)

	Public API:
		ApprovalService.NeedsApproval(def, ctx) -> boolean
		ApprovalService.Request(executor, def, ctx) -> request
		ApprovalService.Respond(owner, id, approve, reason?) -> (ok, message)
		ApprovalService.List() -> { request }
		ApprovalService.IsOwner(player) -> boolean
		ApprovalService.SetOwnerResolver(fn)  -- tests
		ApprovalService.CheckCommand(def, ctx) -- the Before hook (tests)
--]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local Logger = require(Core:WaitForChild("Logger"))
local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local ApprovalService = {}

local RISK_ORDER = { low = 1, medium = 2, high = 3, critical = 4 }
local MAX_PENDING_PER_PLAYER = 3

local function getRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	-- Unit tests run in Edit: don't leave remotes in the saved place.
	if game:GetService("RunService"):IsRunning() then
		remote.Parent = SentinelShared
	end
	return remote
end
local approvalRemote = getRemote("ApprovalRemote")
local resultRemote = getRemote("CommandResultRemote")

-- ---------------------------------------------------------------------------
-- Who is an Owner / who is online (replaceable for tests)
-- ---------------------------------------------------------------------------
local ownerResolver: (any) -> boolean = function(player: any): boolean
	return typeof(player) == "Instance" and table.find(PermissionSystem.GetRoles(player), "Owner") ~= nil
end
local onlineResolver: () -> { any } = function()
	return Players:GetPlayers()
end

function ApprovalService.SetOwnerResolver(isOwner: ((any) -> boolean)?, online: (() -> { any })?)
	if isOwner then
		ownerResolver = isOwner
	end
	if online then
		onlineResolver = online
	end
end

function ApprovalService.IsOwner(player: any): boolean
	return ownerResolver(player)
end

local function ownersOnline(except: any?): { any }
	local out = {}
	for _, p in ipairs(onlineResolver()) do
		if p ~= except and ownerResolver(p) then
			table.insert(out, p)
		end
	end
	return out
end
ApprovalService.OwnersOnline = ownersOnline

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------
export type Request = {
	Id: string,
	Executor: any,
	ExecutorId: number,
	Command: string,
	Text: string,
	Risk: string,
	CreatedAt: number,
	Expires: number,
	Timeout: number,
	Status: string, -- pending | approved | denied | expired
	Test: boolean?,
}

local requests: { [string]: Request } = {}
local approvedTokens: { [string]: { Command: string, UserId: number } } = {}

local function setting(key: string, default: any): any
	local v = ConfigService.Get(key)
	if v == nil then
		return default
	end
	return v
end

function ApprovalService.NeedsApproval(def: any, ctx: any): boolean
	if setting("OwnerApproval", true) ~= true then
		return false
	end
	local executor = ctx.Executor
	if typeof(executor) ~= "Instance" and not (type(executor) == "table" and executor.FakePlayer) then
		return false -- another server's command (;global) or system call
	end
	local risk = CommandPolicy.GetRisk(def)
	local threshold = setting("ApprovalRisk", "critical")
	if (RISK_ORDER[risk] or 1) < (RISK_ORDER[threshold] or 4) then
		return false
	end
	if ownerResolver(executor) then
		return false
	end
	return #ownersOnline(executor) > 0
end

local function requesterInfo(executor: any)
	local RankService = require(script.Parent:WaitForChild("RankService")) :: any
	local rank = nil
	if typeof(executor) == "Instance" then
		local ok, r = pcall(RankService.GetTopRank, executor)
		rank = if ok then r else nil
	end
	return {
		UserId = executor.UserId,
		Name = executor.Name,
		DisplayName = executor.DisplayName or executor.Name,
		Rank = rank,
	}
end

local function payloadOf(r: Request)
	return {
		Id = r.Id,
		Command = r.Command,
		Text = r.Text,
		Risk = r.Risk,
		Requester = requesterInfo(r.Executor),
		Expires = r.Expires,
		Timeout = r.Timeout,
		Test = r.Test,
	}
end

local function tell(player: any, success: boolean, message: string, extra: { [string]: any }?)
	if typeof(player) ~= "Instance" then
		return
	end
	local result: { [string]: any } = { Success = success, Message = message }
	for k, v in pairs(extra or {}) do
		result[k] = v
	end
	resultRemote:FireClient(player, { result })
end

local function audit(actor: any, command: string, r: Request, result: string, message: string)
	Logger.Write({
		Executor = tostring(actor.UserId),
		ExecutorName = actor.Name,
		Command = command,
		Action = "security." .. command,
		RawInput = r.Text,
		Arguments = { r.Id, r.Text },
		Target = r.Executor.Name,
		TargetIds = { r.ExecutorId },
		Result = result :: any,
		Severity = "Warning",
		Message = message,
		Source = "approval",
	})
end

local function close(r: Request, status: string)
	r.Status = status
	requests[r.Id] = nil
	for _, owner in ipairs(ownersOnline()) do
		if typeof(owner) == "Instance" then
			approvalRemote:FireClient(owner, "closed", r.Id, status)
		end
	end
end

function ApprovalService.Request(executor: any, def: any, ctx: any, test: boolean?): Request
	local timeout = setting("ApprovalTimeout", 60)
	local now = os.time()
	local r: Request = {
		Id = HttpService:GenerateGUID(false):sub(1, 6):lower(),
		Executor = executor,
		ExecutorId = executor.UserId,
		Command = def.Name,
		Text = tostring(ctx.RawInput or def.Name):sub(1, 300),
		Risk = CommandPolicy.GetRisk(def),
		CreatedAt = now,
		Expires = now + timeout,
		Timeout = timeout,
		Status = "pending",
		Test = test,
	}
	requests[r.Id] = r
	local payload = payloadOf(r)
	local targets = if test then { executor } else ownersOnline(executor)
	for _, owner in ipairs(targets) do
		if typeof(owner) == "Instance" then
			approvalRemote:FireClient(owner, "request", payload)
		end
	end
	task.delay(timeout, function()
		if requests[r.Id] == r and r.Status == "pending" then
			close(r, "expired")
			tell(r.Executor, false, ("No answer from the Owner: ;%s was not run."):format(r.Command))
		end
	end)
	return r
end

local function pendingCount(userId: number): number
	local n = 0
	for _, r in pairs(requests) do
		if r.ExecutorId == userId then
			n += 1
		end
	end
	return n
end

-- The Before hook.
function ApprovalService.CheckCommand(def: any, ctx: any): any
	local token = ctx.ApprovalToken
	if type(token) == "string" then
		local grant = approvedTokens[token]
		if grant and grant.Command == def.Name and grant.UserId == ctx.Executor.UserId then
			approvedTokens[token] = nil
			return nil
		end
	end
	if not ApprovalService.NeedsApproval(def, ctx) then
		return nil
	end
	if pendingCount(ctx.Executor.UserId) >= MAX_PENDING_PER_PLAYER then
		return ("You already have %d commands waiting for the Owner."):format(MAX_PENDING_PER_PLAYER)
	end
	local r = ApprovalService.Request(ctx.Executor, def, ctx)
	return {
		Message = ("Sent to the Owner for approval (#%s): ;%s runs once they approve it (%ds)."):format(r.Id, def.Name, r.Timeout),
		Pending = true,
		ApprovalId = r.Id,
	}
end

-- Runs the approved command for its requester. Separate so tests can stub it.
local replay: (Request, string) -> { any } = function(r: Request, token: string)
	local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor")) :: any
	return CommandProcessor.Process(r.Executor, r.Text, { Confirmed = true, Source = "approval", ApprovalToken = token })
end
function ApprovalService.SetReplay(fn: (Request, string) -> { any })
	replay = fn
end

function ApprovalService.Respond(owner: any, id: any, approve: boolean, reason: string?): (boolean, string)
	if type(id) ~= "string" then
		return false, "Give a request id."
	end
	local r = requests[id:lower()]
	if not r then
		return false, ("No pending request #%s (answered or expired)."):format(tostring(id))
	end
	if not ownerResolver(owner) then
		return false, "Only an Owner can answer approval requests."
	end
	if owner == r.Executor and not r.Test then
		return false, "You can't approve your own request."
	end
	if r.Executor == nil or (typeof(r.Executor) == "Instance" and r.Executor.Parent == nil) then
		close(r, "expired")
		return false, "The requester left the server."
	end
	local ownerName = owner.DisplayName or owner.Name
	if not approve and r.Test then
		close(r, "denied")
		return true, ("Test request #%s denied."):format(r.Id)
	end
	if not approve then
		close(r, "denied")
		audit(owner, "deny", r, "Denied", ("Denied ;%s from %s%s"):format(r.Command, r.Executor.Name, if reason and reason ~= "" then ": " .. reason else ""))
		tell(r.Executor, false, ("%s denied ;%s%s"):format(ownerName, r.Command, if reason and reason ~= "" then ": " .. reason else "."))
		return true, ("Denied #%s (;%s from %s)."):format(r.Id, r.Command, r.Executor.Name)
	end
	close(r, "approved")
	if r.Test then
		-- A preview request never runs anything.
		return true, ("Test request #%s approved - nothing was run."):format(r.Id)
	end
	audit(owner, "approve", r, "Success", ("Approved ;%s from %s"):format(r.Command, r.Executor.Name))
	local token = HttpService:GenerateGUID(false)
	approvedTokens[token] = { Command = r.Command, UserId = r.ExecutorId }
	tell(r.Executor, true, ("%s approved ;%s."):format(ownerName, r.Command))
	local results = replay(r, token)
	approvedTokens[token] = nil
	if typeof(r.Executor) == "Instance" and type(results) == "table" then
		resultRemote:FireClient(r.Executor, results)
	end
	local first = if type(results) == "table" then results[1] else nil
	local outcome = if first and first.Message then (" Result: " .. tostring(first.Message)) else ""
	return true, ("Approved #%s (;%s from %s).%s"):format(r.Id, r.Command, r.Executor.Name, outcome)
end

function ApprovalService.List(): { any }
	local out = {}
	for _, r in pairs(requests) do
		table.insert(out, payloadOf(r))
	end
	table.sort(out, function(a, b)
		return a.Expires < b.Expires
	end)
	return out
end

-- Studio preview: route a request to yourself to see the Owner's card.
function ApprovalService.Test(owner: any, def: any, text: string): Request
	return ApprovalService.Request(owner, def, { RawInput = text, Executor = owner }, true)
end

function ApprovalService._Reset()
	table.clear(requests)
	table.clear(approvedTokens)
end

CommandRegistry.AddHook("Before", ApprovalService.CheckCommand, "OwnerApproval")

-- Owner answers from the request card.
local limiter = RateLimiter.new("ApprovalRemote", 6, 2)
approvalRemote.OnServerEvent:Connect(function(player: Player, action: any, id: any)
	if not limiter:Allow(player) then
		return
	end
	if action ~= "approve" and action ~= "deny" then
		return
	end
	local ok, message = ApprovalService.Respond(player, id, action == "approve")
	tell(player, ok, message)
end)

-- When an Owner joins, show them what is waiting; when the last Owner
-- leaves, pending requests can't be answered any more.
Players.PlayerAdded:Connect(function(player: Player)
	task.delay(3, function()
		if player.Parent and ownerResolver(player) then
			for _, r in pairs(requests) do
				approvalRemote:FireClient(player, "request", payloadOf(r))
			end
		end
	end)
end)
Players.PlayerRemoving:Connect(function(player: Player)
	task.defer(function()
		for _, r in pairs(requests) do
			if r.Executor == player then
				close(r, "expired")
			elseif #ownersOnline() == 0 and not r.Test then
				close(r, "expired")
				tell(r.Executor, false, ("The Owner left before answering: run ;%s again."):format(r.Command))
			end
		end
	end)
end)

return ApprovalService
