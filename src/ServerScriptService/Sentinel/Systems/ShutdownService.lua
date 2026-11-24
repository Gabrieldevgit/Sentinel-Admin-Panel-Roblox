--!strict
--[[
	ShutdownService.lua (M-panel gaps: cancellable shutdown / scheduled restart)

	Purpose:
		One pending "end of this server" at a time: a shutdown (lock + kick
		everyone) or a restart (graceful migration to a fresh server via
		CrossServerService.MigrateNow). It can be cancelled until it fires.

		Warnings: a banner when it is scheduled, then at 30m / 15m / 10m / 5m /
		2m / 1m / 30s / 10s before the end (only the marks below the total);
		the big on-screen countdown (CountdownRemote) runs for the last 10 s.
		A cancel fires CountdownRemote "cancel" (the client hides the overlay)
		and an all-clear banner.

	Public API:
		ShutdownService.Schedule(kind, seconds, message?, actor?) -> (ok, text)
		ShutdownService.Cancel(actor?) -> (ok, text)
		ShutdownService.Pending() -> { Kind, EndsAt, Total, By, Message }?
		ShutdownService.WarningMarks(total) -> { number }   (pure, for tests)
		ShutdownService.MIN_SECONDS / MAX_SECONDS

	Dependencies: CrossServerService (MigrateNow, provider), ServerStateService,
	AnnouncementService (banners).
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local ServerStateService = require(script.Parent:WaitForChild("ServerStateService"))
-- Required lazily: CrossServerService only loads inside a running game, and
-- the pure helpers here are unit-tested in Edit mode.
local crossServer: any = nil
local function CrossServer(): any
	if not crossServer then
		crossServer = require(script.Parent:WaitForChild("CrossServerService")) :: any
	end
	return crossServer
end
local AnnouncementService = require(script.Parent:WaitForChild("AnnouncementService"))

local ShutdownService = {}

ShutdownService.MIN_SECONDS = 5
ShutdownService.MAX_SECONDS = 3 * 3600
ShutdownService.MARKS = { 1800, 900, 600, 300, 120, 60, 30, 10 }
local OVERLAY_SECONDS = 10

type Pending = {
	Id: number,
	Kind: string,
	EndsAt: number,
	Total: number,
	By: string,
	Message: string?,
}

local pending: Pending? = nil
local nextId = 0

local function countdownRemote(): RemoteEvent?
	local remote = SentinelShared:FindFirstChild("CountdownRemote")
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

function ShutdownService.WarningMarks(total: number): { number }
	local out = {}
	for _, mark in ipairs(ShutdownService.MARKS) do
		if mark < total then
			table.insert(out, mark)
		end
	end
	return out
end

local function pretty(seconds: number): string
	seconds = math.max(0, math.floor(seconds + 0.5))
	if seconds >= 3600 then
		local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
		return if m > 0 then ("%d h %d min"):format(h, m) else ("%d hour%s"):format(h, if h == 1 then "" else "s")
	elseif seconds >= 60 then
		local m, s = math.floor(seconds / 60), seconds % 60
		return if s > 0 then ("%d min %d s"):format(m, s) else ("%d minute%s"):format(m, if m == 1 then "" else "s")
	end
	return ("%d second%s"):format(seconds, if seconds == 1 then "" else "s")
end
ShutdownService.Pretty = pretty

local function label(kind: string): string
	return if kind == "restart" then "Server restart" else "Server shutdown"
end

local function banner(kind: string, text: string, color: string, author: any?)
	AnnouncementService.Show({
		Text = text,
		Title = label(kind),
		Color = AnnouncementService.COLORS[color],
		Duration = 8,
		Author = author,
	})
end

local function warnText(p: Pending, remaining: number): string
	local what = if p.Kind == "restart"
		then "This server restarts in %s. You will be moved to a new server automatically."
		else "This server shuts down in %s."
	local text = what:format(pretty(remaining))
	if p.Message then
		text ..= " " .. p.Message
	end
	return text
end

local function finish(p: Pending)
	if p.Kind == "restart" then
		CrossServer().MigrateNow(p.Message)
	else
		local text = p.Message or "The server is shutting down."
		ServerStateService.SetLocked(true, text)
		for _, player in ipairs(Players:GetPlayers()) do
			player:Kick(text)
		end
	end
end

local function run(p: Pending, author: any?)
	local marks = ShutdownService.WarningMarks(p.Total)
	local markIndex = 1
	local overlay = countdownRemote()
	local title = label(p.Kind)
	while pending == p do
		local remaining = p.EndsAt - os.clock()
		if remaining <= 0 then
			break
		end
		while markIndex <= #marks and remaining <= marks[markIndex] + 0.05 do
			-- Skip a mark we're already well past (the server hitched).
			if remaining > marks[markIndex] - 2 then
				banner(p.Kind, warnText(p, marks[markIndex]), "orange", author)
			end
			markIndex += 1
		end
		if remaining <= OVERLAY_SECONDS and overlay then
			overlay:FireAllClients("tick", title, math.ceil(remaining), math.min(p.Total, OVERLAY_SECONDS))
		end
		task.wait(if remaining <= OVERLAY_SECONDS + 1 then 1 else 0.5)
	end
	if pending ~= p then
		return -- cancelled
	end
	pending = nil
	if overlay then
		overlay:FireAllClients("done", title, 0, OVERLAY_SECONDS)
	end
	finish(p)
end

function ShutdownService.Pending(): any
	local p = pending
	if not p then
		return nil
	end
	return {
		Kind = p.Kind,
		EndsAt = os.time() + math.max(0, math.floor(p.EndsAt - os.clock())),
		Remaining = math.max(0, math.floor(p.EndsAt - os.clock())),
		Total = p.Total,
		By = p.By,
		Message = p.Message,
	}
end

function ShutdownService.Schedule(kind: string, seconds: number, message: string?, actor: any?): (boolean, string)
	if kind ~= "shutdown" and kind ~= "restart" then
		return false, "kind must be shutdown or restart"
	end
	if pending then
		local p = pending :: Pending
		return false, ("A %s is already pending (%s left) - cancel it first with ;cancelshutdown."):format(
			p.Kind,
			pretty(p.EndsAt - os.clock())
		)
	end
	if CrossServer().IsMigrating() then
		return false, "A migration countdown is already running - cancel it first with ;cancelshutdown."
	end
	local total = math.clamp(math.floor(seconds), ShutdownService.MIN_SECONDS, ShutdownService.MAX_SECONDS)
	nextId += 1
	local p: Pending = {
		Id = nextId,
		Kind = kind,
		EndsAt = os.clock() + total,
		Total = total,
		By = if actor then tostring(actor.Name) else "Sentinel",
		Message = message,
	}
	pending = p
	local author = if actor then AnnouncementService.AuthorOf(actor) else nil
	banner(kind, warnText(p, total), "orange", author)
	task.spawn(run, p, author)
	return true, ("%s in %s."):format(label(kind), pretty(total))
end

function ShutdownService.Cancel(actor: any?): (boolean, string)
	local p = pending
	if not p then
		if CrossServer().CancelMigration() then
			local overlay = countdownRemote()
			if overlay then
				overlay:FireAllClients("cancel", "Server restart", 0, 0)
			end
			return true, "Migration countdown cancelled."
		end
		return false, "No shutdown or restart is pending."
	end
	pending = nil
	local overlay = countdownRemote()
	if overlay then
		overlay:FireAllClients("cancel", label(p.Kind), 0, 0)
	end
	banner(
		p.Kind,
		("The %s was cancelled. You can keep playing."):format(if p.Kind == "restart" then "restart" else "shutdown"),
		"green",
		if actor then AnnouncementService.AuthorOf(actor) else nil
	)
	return true, ("%s cancelled (%s were left)."):format(label(p.Kind), pretty(p.EndsAt - os.clock()))
end

if game:GetService("RunService"):IsRunning() then
	CrossServer().SetShutdownProvider(ShutdownService.Pending)
end

return ShutdownService
