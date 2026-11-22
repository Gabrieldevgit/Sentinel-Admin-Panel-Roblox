--!strict
--[[
	PlayerExplorerService.lua (W15 - Player Explorer completion)

	Purpose:
		Everything the Players page shows about the players in this server
		beyond the raw Player instance:
		- one row per player (GetPlayerListRemote): health, ping, status
		  (Active / Idle / Dead), top rank + colour, staff / VIP flags,
		  account age, join time, WalkSpeed / JumpPower, position, warning
		  count, live punishments and "suspicious" reasons;
		- recently joined / recently left players (last 50 of each, this
		  server, memory only);
		- idle detection: a player whose character hasn't moved for
		  IDLE_SECONDS is Idle (the server can't see input, so this is
		  movement-based).

	Suspicious = any of (each configurable with ;config, 0 = off):
		- account younger than `newaccount` days (SuspiciousAccountDays, 7)
		- at least `suspectwarnings` warnings (SuspiciousWarnings, 3)
		- an open / in-progress report against them (ReportService)

	Public API:
		PlayerExplorerService.Row(player) -> row table
		PlayerExplorerService.Rows() -> { row }
		PlayerExplorerService.Recent() -> { Joined = {...}, Left = {...} }
		PlayerExplorerService.Status(player) -> ("Active"|"Idle"|"Dead", idleSeconds)
		PlayerExplorerService.Suspicion(player) -> { string }  (reasons)
		PlayerExplorerService.JoinedAt(userId) -> number?
--]]

local Players = game:GetService("Players")

local Sentinel = script.Parent.Parent
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local Systems = script.Parent
local RankService = require(Systems:WaitForChild("RankService"))
local DeveloperService = require(Systems:WaitForChild("DeveloperService"))
local ChatModerationService = require(Systems:WaitForChild("ChatModerationService"))
local PunishmentService = require(Systems:WaitForChild("PunishmentService"))
local ConfigService = require(Systems:WaitForChild("ConfigService"))

local PlayerExplorerService = {}

local IDLE_SECONDS = 120
local MAX_RECENT = 50
local SUSPICION_TTL = 15

type Entry = { UserId: number, Name: string, DisplayName: string, At: number, SessionSeconds: number? }

local joined: { Entry } = {}
local left: { Entry } = {}
local joinedAt: { [number]: number } = {}
local lastMoved: { [number]: number } = {}
local lastPosition: { [number]: Vector3 } = {}
local suspicionCache: { [number]: { At: number, Reasons: { string } } } = {}

local function push(list: { Entry }, entry: Entry)
	table.insert(list, 1, entry)
	while #list > MAX_RECENT do
		table.remove(list)
	end
end

local function onJoin(p: Player)
	if joinedAt[p.UserId] then
		return
	end
	local now = os.time()
	joinedAt[p.UserId] = now
	lastMoved[p.UserId] = now
	push(joined, { UserId = p.UserId, Name = p.Name, DisplayName = p.DisplayName, At = now })
end

local function onLeave(p: Player)
	local now = os.time()
	local start = joinedAt[p.UserId]
	push(left, {
		UserId = p.UserId,
		Name = p.Name,
		DisplayName = p.DisplayName,
		At = now,
		SessionSeconds = if start then now - start else nil,
	})
	joinedAt[p.UserId] = nil
	lastMoved[p.UserId] = nil
	lastPosition[p.UserId] = nil
	suspicionCache[p.UserId] = nil
end

local function root(p: Player): BasePart?
	local character = p.Character
	return character and (character:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

local function humanoid(p: Player): Humanoid?
	local character = p.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function PlayerExplorerService.JoinedAt(userId: number): number?
	return joinedAt[userId]
end

function PlayerExplorerService.Status(p: Player): (string, number)
	local h = humanoid(p)
	if not h or h.Health <= 0 then
		return "Dead", 0
	end
	local idleFor = os.time() - (lastMoved[p.UserId] or os.time())
	if idleFor >= IDLE_SECONDS then
		return "Idle", idleFor
	end
	return "Active", idleFor
end

function PlayerExplorerService.Suspicion(p: Player): { string }
	local cached = suspicionCache[p.UserId]
	if cached and os.clock() - cached.At < SUSPICION_TTL then
		return cached.Reasons
	end
	local reasons = {}
	local ageDays = ConfigService.Get("SuspiciousAccountDays") or 7
	if ageDays > 0 and p.AccountAge < ageDays then
		table.insert(reasons, ("New account (%d day%s old)"):format(p.AccountAge, if p.AccountAge == 1 then "" else "s"))
	end
	local warnLimit = ConfigService.Get("SuspiciousWarnings") or 3
	if warnLimit > 0 then
		local ok, warnings = pcall(PunishmentService.GetWarnings, p.UserId)
		if ok and type(warnings) == "table" and #warnings >= warnLimit then
			table.insert(reasons, ("%d warnings"):format(#warnings))
		end
	end
	local okReports, ReportService = pcall(require, Systems:WaitForChild("ReportService"))
	if okReports and ReportService.PendingAgainst then
		local okCount, n = pcall(ReportService.PendingAgainst, p.UserId)
		if okCount and n > 0 then
			table.insert(reasons, ("%d open report%s"):format(n, if n == 1 then "" else "s"))
		end
	end
	suspicionCache[p.UserId] = { At = os.clock(), Reasons = reasons }
	return reasons
end

local function rankInfo(p: Player): (string?, { number }?)
	local top = RankService.GetTopRank(p)
	if not top then
		return nil, nil
	end
	local def = RankService.GetRank(top)
	local c = def and (def :: any).Color
	return top, if type(c) == "table" and #c == 3 then c else nil
end

local function hasRole(p: Player, name: string): boolean
	for _, roleName in ipairs(PermissionSystem.GetRoles(p)) do
		if roleName:lower() == name then
			return true
		end
	end
	return false
end

function PlayerExplorerService.Row(p: Player): { [string]: any }
	local h = humanoid(p)
	local status, idleFor = PlayerExplorerService.Status(p)
	local rank, rankColor = rankInfo(p)
	local rp = root(p)
	local okWarn, warnings = pcall(PunishmentService.GetWarnings, p.UserId)
	return {
		UserId = p.UserId,
		Name = p.Name,
		DisplayName = p.DisplayName,
		Team = if p.Team then p.Team.Name else nil,
		TeamColor = if p.Team then p.Team.TeamColor.Color else nil,
		Health = if h then math.floor(h.Health) else nil,
		MaxHealth = if h then math.floor(h.MaxHealth) else nil,
		WalkSpeed = if h then math.floor(h.WalkSpeed * 10 + 0.5) / 10 else nil,
		JumpPower = if h then math.floor((if h.UseJumpPower then h.JumpPower else h.JumpHeight) * 10 + 0.5) / 10 else nil,
		Position = if rp then { math.floor(rp.Position.X), math.floor(rp.Position.Y), math.floor(rp.Position.Z) } else nil,
		Ping = DeveloperService.GetPing(p),
		Roles = PermissionSystem.GetRoles(p),
		Rank = rank,
		RankColor = rankColor,
		IsStaff = PermissionSystem.Has(p, "panel.open"),
		IsVIP = hasRole(p, "vip"),
		AccountAge = p.AccountAge,
		JoinedAt = joinedAt[p.UserId],
		Status = status,
		IdleSeconds = idleFor,
		Suspicious = PlayerExplorerService.Suspicion(p),
		Warnings = if okWarn and type(warnings) == "table" then #warnings else 0,
		-- Live punishments / states: the attributes the commands set are the
		-- source of truth.
		IsFrozen = p:GetAttribute("SentinelFrozen") == true,
		IsJailed = p:GetAttribute("SentinelJailed") == true,
		IsMuted = ChatModerationService.IsMuted(p.UserId),
		IsGod = p:GetAttribute("SentinelGod") == true,
		IsFlying = p:GetAttribute("SentinelFlying") == true,
		IsInvisible = p:GetAttribute("SentinelInvisible") == true,
	}
end

function PlayerExplorerService.Rows(): { { [string]: any } }
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local ok, row = pcall(PlayerExplorerService.Row, p)
		if ok then
			table.insert(list, row)
		end
	end
	return list
end

function PlayerExplorerService.Recent(): { [string]: any }
	return { Joined = table.clone(joined), Left = table.clone(left), Now = os.time() }
end

for _, p in ipairs(Players:GetPlayers()) do
	onJoin(p)
end
Players.PlayerAdded:Connect(onJoin)
Players.PlayerRemoving:Connect(onLeave)

-- Movement sampling for idle detection (cheap: one position per player
-- every 3 s).
if game:GetService("RunService"):IsRunning() then
	task.spawn(function()
		while true do
			task.wait(3)
			for _, p in ipairs(Players:GetPlayers()) do
				local rp = root(p)
				if rp then
					local previous = lastPosition[p.UserId]
					if not previous or (rp.Position - previous).Magnitude > 1 then
						lastMoved[p.UserId] = os.time()
					end
					lastPosition[p.UserId] = rp.Position
				end
			end
		end
	end)
end

return PlayerExplorerService
