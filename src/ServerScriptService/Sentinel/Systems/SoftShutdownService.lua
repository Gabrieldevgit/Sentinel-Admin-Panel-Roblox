--!strict
--[[
	SoftShutdownService.lua - Soft Shutdown

	Moves everyone out of a closing server without disconnecting them:
		1. this server locks (ServerStateService) and every client shows the
		   "Servers are restarting" screen (also set as the teleport GUI, so
		   it stays up during the loading screen);
		2. everyone is teleported together into a freshly reserved
		   "waiting room" server (TeleportData { SentinelSoftShutdown = 1 });
		3. the waiting room holds the group WAIT_IN_ROOM seconds (so old
		   servers finish closing) and sends them back together to a public
		   server - one started on the current place version.
	Failed teleports are retried per player (TeleportInitFailed, 3 tries);
	a player who still can't move is kicked with a "please rejoin" message.

	Triggers:
		- AUTOMATIC: when Roblox closes a public server that still has players
		  (Creator Hub "Shut down all servers" / "Restart servers for
		  updates", or the server closing for any other reason), BindToClose
		  evacuates it. ConfigService key `SoftShutdown` (default on;
		  ;softshutdown auto on|off). Never in Studio, private or reserved
		  servers.
		- Commands (Commands/Server/SoftShutdown.lua): ;softshutdown now |
		  [time] | all [time] | cancel | status | auto on|off.
		- CrossServerService.MigrateNow (;restart, ;migrateserver, ;gupdate)
		  now uses Evacuate too.

	Studio can't teleport: Evacuate shows the screen for a few seconds and
	reports a dry run.

	Remote SoftShutdownRemote (server -> client):
		("leaving", label)   show the restart screen + SetTeleportGui
		("waiting", seconds) waiting-room text (the client also detects it
		                     from its own teleport data)
		("cancel")           hide (dry run / failure)

	Public API:
		SoftShutdownService.Evacuate(label?) -> (ok, message)
		SoftShutdownService.Status() -> { Auto, Evacuating, WaitingRoom, ... }
		SoftShutdownService.SetAuto(on, actor?) -> (ok, message)
		SoftShutdownService.IsMigrationData(data) -> boolean   (pure)
		SoftShutdownService.WAIT_IN_ROOM
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local Sentinel = script.Parent.Parent
local Logger = require(Sentinel:WaitForChild("Core"):WaitForChild("Logger"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))
local ServerStateService = require(script.Parent:WaitForChild("ServerStateService"))

local SoftShutdownService = {}

SoftShutdownService.WAIT_IN_ROOM = 8
SoftShutdownService.DEFAULT_LABEL = "Servers are restarting for an update"
local MAX_RETRIES = 3
local CLOSE_WAIT = 25 -- BindToClose gives ~30 s

local LIVE = RunService:IsServer() and RunService:IsRunning()
local STUDIO = RunService:IsStudio()

ConfigService.Define("SoftShutdown", true, function(v)
	return type(v) == "boolean"
end)

local state = {
	Evacuating = false,
	StartedAt = 0,
	Label = nil :: string?,
	Sent = 0,
	Retried = 0,
	Kicked = 0,
	Code = nil :: string?,
	LastResult = nil :: string?,
	WaitingRoom = false,
	Returned = 0,
}
local retries: { [number]: number } = {}

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------
-- Old ;migrateserver teleports used SentinelMigration = true; both mean
-- "send me back to a public server".
function SoftShutdownService.IsMigrationData(data: any): boolean
	return type(data) == "table" and (data.SentinelSoftShutdown == 1 or data.SentinelMigration == true)
end

local function isReservedServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function isPublicServer(): boolean
	return game.PrivateServerId == ""
end

local remote: RemoteEvent? = nil
if LIVE then
	local r = SentinelShared:FindFirstChild("SoftShutdownRemote")
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = "SoftShutdownRemote"
		r.Parent = SentinelShared
	end
	remote = r :: RemoteEvent
end

local function canTeleport(): boolean
	if STUDIO or not LIVE then
		return false
	end
	local ok, result = pcall(function()
		local CrossServer = require(script.Parent:WaitForChild("CrossServerService")) :: any
		return CrossServer.CanTeleport()
	end)
	return not ok or result ~= false
end

local function log(text: string, severity: string?)
	Logger.Write({
		Executor = "SYSTEM",
		ExecutorName = "SYSTEM",
		Command = "softshutdown",
		Action = "server.softshutdown",
		Result = "Success",
		Severity = (severity or "Warning") :: any,
		Message = text,
		Source = "system",
	})
end

-- ---------------------------------------------------------------------------
-- Teleporting
-- ---------------------------------------------------------------------------
local function options(code: string?): TeleportOptions
	local o = Instance.new("TeleportOptions")
	if code then
		o.ReservedServerAccessCode = code
	end
	o:SetTeleportData({ SentinelSoftShutdown = 1, Label = state.Label })
	return o
end

local function sendBack(players: { Player })
	local list = {}
	for _, p in ipairs(players) do
		if p.Parent == Players then
			table.insert(list, p)
		end
	end
	if #list == 0 then
		return
	end
	local ok, err = pcall(function()
		-- no TeleportData: the public server must not bounce them again
		TeleportService:TeleportAsync(game.PlaceId, list)
	end)
	if ok then
		state.Returned += #list
	else
		warn("[Sentinel.SoftShutdown] return teleport failed, retrying one by one: " .. tostring(err))
		for _, p in ipairs(list) do
			pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { p })
			end)
		end
	end
end

local function sendOut(players: { Player }): (boolean, string?)
	if #players == 0 then
		return true, nil
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, players, options(state.Code))
	end)
	if ok then
		state.Sent += #players
		return true, nil
	end
	-- group teleport refused: try each player alone
	local anyOk = false
	for _, p in ipairs(players) do
		local one = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, { p }, options(state.Code))
		end)
		if one then
			state.Sent += 1
			anyOk = true
		end
	end
	return anyOk, tostring(err)
end

function SoftShutdownService.Evacuate(label: string?): (boolean, string)
	if state.Evacuating then
		return false, "A soft shutdown is already moving players."
	end
	local text = label or SoftShutdownService.DEFAULT_LABEL
	if remote then
		remote:FireAllClients("leaving", text)
	end
	if not canTeleport() then
		-- Studio dry run: show the screen briefly, then hide it again.
		task.delay(4, function()
			if remote then
				remote:FireAllClients("cancel")
			end
		end)
		state.LastResult = "dry run (teleports are disabled in Studio)"
		return false, "Soft shutdown dry run: the restart screen was shown, but Studio can't teleport."
	end
	state.Evacuating = true
	state.StartedAt = os.time()
	state.Label = text
	state.Sent, state.Retried, state.Kicked = 0, 0, 0
	ServerStateService.SetLocked(true, text)
	log(("Soft shutdown: moving %d player(s) (%s)"):format(#Players:GetPlayers(), text))
	task.wait(1) -- let clients set their teleport GUI

	local code: string? = nil
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return TeleportService:ReserveServer(game.PlaceId)
		end)
		if ok then
			code = result
			break
		end
		warn("[Sentinel.SoftShutdown] ReserveServer failed: " .. tostring(result))
		task.wait(attempt)
	end
	if not code then
		-- no waiting room: send everyone straight to another public server
		state.LastResult = "no reserved server; sent players to public servers"
		sendBack(Players:GetPlayers())
		return true, "Couldn't reserve a waiting room - players were sent straight to other servers."
	end
	state.Code = code
	local ok, err = sendOut(Players:GetPlayers())
	if not ok then
		state.Evacuating = false
		state.LastResult = "failed: " .. tostring(err)
		ServerStateService.SetLocked(false)
		if remote then
			remote:FireAllClients("cancel")
		end
		return false, "Soft shutdown failed: " .. tostring(err)
	end
	state.LastResult = ("moved %d player(s)"):format(state.Sent)
	return true, ("Soft shutdown: moving %d player(s) to a fresh server."):format(state.Sent)
end

function SoftShutdownService.Status(): any
	return {
		Auto = ConfigService.Get("SoftShutdown") ~= false,
		Evacuating = state.Evacuating,
		StartedAt = state.StartedAt,
		Sent = state.Sent,
		Retried = state.Retried,
		Kicked = state.Kicked,
		LastResult = state.LastResult,
		WaitingRoom = state.WaitingRoom,
		Returned = state.Returned,
		CanTeleport = canTeleport(),
		Public = isPublicServer(),
	}
end

function SoftShutdownService.SetAuto(on: boolean, actor: Player?): (boolean, string)
	local ok, err = ConfigService.Set("SoftShutdown", on, actor)
	if not ok then
		return false, err or "Could not save."
	end
	return true, ("Automatic soft shutdown is now %s (every server)."):format(if on then "on" else "off")
end

-- ---------------------------------------------------------------------------
-- Live wiring
-- ---------------------------------------------------------------------------
if LIVE then
	-- Retry failed teleports (both directions), then give up politely.
	TeleportService.TeleportInitFailed:Connect(function(player, result, message, placeId, teleportOptions)
		if not (state.Evacuating or state.WaitingRoom) or player.Parent ~= Players then
			return
		end
		local n = (retries[player.UserId] or 0) + 1
		retries[player.UserId] = n
		if n > MAX_RETRIES then
			state.Kicked += 1
			player:Kick(("%s. Please rejoin - the move to a new server failed (%s)."):format(state.Label or SoftShutdownService.DEFAULT_LABEL, tostring(result)))
			return
		end
		state.Retried += 1
		task.delay(n * 2, function()
			if player.Parent == Players then
				pcall(function()
					TeleportService:TeleportAsync(placeId, { player }, teleportOptions)
				end)
			end
		end)
		warn(("[Sentinel.SoftShutdown] teleport for %s failed (%s: %s), retry %d"):format(player.Name, tostring(result), tostring(message), n))
	end)

	-- Staff who bypass the lock and join mid-evacuation go along.
	Players.PlayerAdded:Connect(function(player)
		if state.Evacuating and state.Code then
			task.wait(2)
			if remote then
				remote:FireClient(player, "leaving", state.Label or SoftShutdownService.DEFAULT_LABEL)
			end
			sendOut({ player })
		end
	end)

	-- Waiting room: collect arrivals, then send them back together.
	if isReservedServer() and not STUDIO then
		local batch: { Player } = {}
		local timerRunning = false
		local function arrive(player: Player)
			local ok, joinData = pcall(player.GetJoinData, player)
			local data = if ok and type(joinData) == "table" then joinData.TeleportData else nil
			if not SoftShutdownService.IsMigrationData(data) then
				return
			end
			state.WaitingRoom = true
			if type(data.Label) == "string" then
				state.Label = data.Label:sub(1, 200)
			end
			table.insert(batch, player)
			if remote then
				remote:FireClient(player, "waiting", SoftShutdownService.WAIT_IN_ROOM)
			end
			if not timerRunning then
				timerRunning = true
				task.delay(SoftShutdownService.WAIT_IN_ROOM, function()
					local group = batch
					batch = {}
					timerRunning = false
					sendBack(group)
				end)
			end
		end
		for _, p in ipairs(Players:GetPlayers()) do
			task.spawn(arrive, p)
		end
		Players.PlayerAdded:Connect(arrive)
	end

	-- Automatic soft shutdown when Roblox closes this public server.
	game:BindToClose(function()
		if STUDIO or not isPublicServer() or #Players:GetPlayers() == 0 then
			return
		end
		if ConfigService.Get("SoftShutdown") == false then
			return
		end
		if not state.Evacuating then
			SoftShutdownService.Evacuate(SoftShutdownService.DEFAULT_LABEL)
		end
		local waited = 0
		while #Players:GetPlayers() > 0 and waited < CLOSE_WAIT do
			waited += task.wait(1)
		end
	end)
end

return SoftShutdownService
