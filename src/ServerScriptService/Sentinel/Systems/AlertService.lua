--!strict
--[[
	AlertService.lua (M-panel gaps: alerts feed)

	Purpose:
		A separate feed of "alert"-level events, apart from the general
		notifications / audit log, for the Moderation > Alerts page:
		  - command   a successful high / critical risk command, a mass
		              action (>= MASS_TARGETS players or "all"), or an
		              Environment change (time, weather, fog, lighting)
		  - join      a player flagged by PlayerExplorerService.Suspicion
		              (new account, many warnings, open reports)
		  - system    anything else that calls AlertService.Raise
		Memory only (this server), newest first, at most MAX_ALERTS.
		Live push to staff on AlertRemote ("alert", entry) / ("clear").

	Public API:
		AlertService.Raise({ Kind, Severity = "info"|"warning"|"critical",
		  Title, Text, Actor? }) -> entry
		AlertService.List(limit?, kind?) -> { entry }   newest first
		AlertService.Clear() -> number
		AlertService.Classify(def, ctx, risk) -> (severity?, reason?)  (pure)
		AlertService.MASS_TARGETS, MAX_ALERTS

	Entry = { Id, Kind, Severity, Title, Text, Actor, Time }
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))

local AlertService = {}

AlertService.MAX_ALERTS = 200
AlertService.MASS_TARGETS = 3
local LIVE = RunService:IsRunning() and RunService:IsServer()

local alerts: { any } = {}
local nextId = 0

local remote: RemoteEvent? = nil
if LIVE then
	local shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local existing = shared:FindFirstChild("AlertRemote")
	if existing and existing:IsA("RemoteEvent") then
		remote = existing
	else
		local r = Instance.new("RemoteEvent")
		r.Name = "AlertRemote"
		r.Parent = shared
		remote = r
	end
end

local function pushToStaff(...: any)
	if not remote then
		return
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if PermissionSystem.Has(p, "panel.open") then
			(remote :: RemoteEvent):FireClient(p, ...)
		end
	end
end

function AlertService.Raise(info: { [string]: any }): any
	nextId += 1
	local severity = tostring(info.Severity or "warning")
	if severity ~= "info" and severity ~= "warning" and severity ~= "critical" then
		severity = "warning"
	end
	local entry = {
		Id = nextId,
		Kind = tostring(info.Kind or "system"),
		Severity = severity,
		Title = tostring(info.Title or "Alert"):sub(1, 80),
		Text = tostring(info.Text or ""):sub(1, 300),
		Actor = if info.Actor then tostring(info.Actor) else nil,
		Time = os.time(),
	}
	table.insert(alerts, 1, entry)
	while #alerts > AlertService.MAX_ALERTS do
		table.remove(alerts)
	end
	pushToStaff("alert", entry)
	return entry
end

function AlertService.List(limit: number?, kind: string?): { any }
	local max = math.clamp(math.floor(tonumber(limit) or 100), 1, AlertService.MAX_ALERTS)
	local out = {}
	for _, entry in ipairs(alerts) do
		if not kind or kind == "" or kind == "all" or entry.Kind == kind or entry.Severity == kind then
			table.insert(out, table.clone(entry))
			if #out >= max then
				break
			end
		end
	end
	return out
end

function AlertService.Clear(): number
	local n = #alerts
	table.clear(alerts)
	pushToStaff("clear")
	return n
end

-- Pure: should a successful command become an alert? Returns the severity
-- and a short reason, or nil.
function AlertService.Classify(def: any, ctx: any, risk: string): (string?, string?)
	local targets = if type(ctx.Targets) == "table" then #ctx.Targets else 0
	local first = if type(ctx.RawInput) == "string" then ctx.RawInput:match("^%s*%S+%s+([^%s:]+)") else nil
	local w = if first then first:lower() else ""
	local everyone = w == "all" or w == "others" or w == "everyone"
	if risk == "critical" then
		return "critical", "critical command"
	elseif risk == "high" then
		return "warning", "high-risk command"
	elseif def.RequiresTarget and (everyone or targets >= AlertService.MASS_TARGETS) then
		return "warning", if everyone
			then ("mass action on everyone (%d player%s)"):format(targets, if targets == 1 then "" else "s")
			else ("mass action (%d players)"):format(targets)
	elseif def.Category == "Environment" then
		return "info", "environment change"
	end
	return nil, nil
end

local function onCommand(def: any, ctx: any, result: any)
	if type(result) ~= "table" or not result.Success or result.NeedsConfirmation or result.Pending then
		return
	end
	if def.Name == "clearalerts" then
		return
	end
	local severity, reason = AlertService.Classify(def, ctx, CommandPolicy.GetRisk(def))
	if not severity then
		return
	end
	local actor = if ctx.Executor then tostring(ctx.Executor.Name) else "?"
	AlertService.Raise({
		Kind = "command",
		Severity = severity,
		Title = ("%s ran %s"):format(actor, def.Name),
		Text = ("%s - %s"):format(tostring(ctx.RawInput or def.Name):sub(1, 160), tostring(reason)),
		Actor = actor,
	})
end

CommandRegistry.AddHook("After", onCommand, "AlertService")

if LIVE then
	Players.PlayerAdded:Connect(function(player)
		-- Give ranks / warnings / reports a moment to load.
		task.delay(6, function()
			if not player.Parent then
				return
			end
			local ok, reasons = pcall(function()
				local Explorer = require(script.Parent:WaitForChild("PlayerExplorerService")) :: any
				return Explorer.Suspicion(player)
			end)
			if ok and type(reasons) == "table" and #reasons > 0 then
				AlertService.Raise({
					Kind = "join",
					Severity = "warning",
					Title = ("Flagged player joined: %s"):format(player.Name),
					Text = table.concat(reasons, ", "),
				})
			end
		end)
	end)
end

return AlertService
