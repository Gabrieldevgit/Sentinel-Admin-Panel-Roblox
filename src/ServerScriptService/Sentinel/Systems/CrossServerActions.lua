--!strict
--[[
	CrossServerActions.lua (cross-server, W19-W21)

	Purpose:
		What THIS server does when a cross-server message arrives. Each
		handler returns (ok, affectedCount, shortMessage), which travels back
		to the origin server as the acknowledgement.

	Trust model:
		Only game servers can publish to MessagingService, and the origin
		server ran the staff member's command through CommandRegistry.Dispatch
		(permission, cooldown, confirmation, logging) before sending. What the
		origin can't know is who outranks the actor on THIS server, so every
		handler that touches a player re-checks the rank hierarchy here with
		the actor's priority from the envelope.

	Kinds:
		ping      diagnostics (;xping)
		kick      { u, tn, r }            kick the player if they are here
		ban       { u, tn, r }            kick a just-banned player (the ban
		                                  record is written by the origin)
		warn      { u, tn, r }            add a warning if they are here
		bring     { u, tn, j, pl }        teleport the player to server j
		announce  { m, i, d, s, t, c, h }  banner for everyone (text, id, display name, style, time, colour, title)
		notify    { m }                   toast for staff
		lockdown  { on, r, by, at }       lock / unlock this server
		shutdown  { m }                   kick everyone
		migrate   { s, m }                update countdown + graceful migration
		chat      { id, n, r, m, at }     staff chat line (no ack)
		cmd       { l }                   run a global-safe command line
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))
local CommandParser = require(Core:WaitForChild("Parser"):WaitForChild("CommandParser"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local CrossServerService = require(script.Parent:WaitForChild("CrossServerService"))
local PunishmentService = require(script.Parent:WaitForChild("PunishmentService"))
local RankService = require(script.Parent:WaitForChild("RankService"))
local AnnouncementService = require(script.Parent:WaitForChild("AnnouncementService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local CrossServerActions = {}

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = SentinelShared
	return remote
end

local announceRemote = getOrCreateRemote("AnnounceRemote")

-- May the remote actor act on this player? Same rule as local commands:
-- yourself and unranked players are fine, anyone ranked equal or above is
-- protected.
function CrossServerActions.CanActOn(actor: any, target: Player): boolean
	if type(actor) ~= "table" then
		return false
	end
	if actor.u == target.UserId then
		return true
	end
	local targetPriority = RankService.GetPriority(target)
	if targetPriority == -math.huge then
		return true
	end
	return targetPriority < (tonumber(actor.p) or -1)
end

local function findTarget(payload: any, envelope: any): (Player?, string?)
	local userId = tonumber(payload.u)
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	if not player then
		return nil, nil -- not in this server: nothing to do
	end
	if not CrossServerActions.CanActOn(envelope.a, player) then
		return nil, "protected by rank"
	end
	return player, nil
end

local function actorName(envelope: any): string
	return if type(envelope.a) == "table" then tostring(envelope.a.n) else "Staff"
end

CrossServerService.Handle("ping", function(_payload: any, _envelope: any)
	return true, #Players:GetPlayers(), ("%d player(s)"):format(#Players:GetPlayers())
end)

CrossServerService.Handle("kick", function(payload: any, envelope: any)
	local player, refused = findTarget(payload, envelope)
	if refused then
		return false, 0, refused
	end
	if not player then
		return true, 0, "not here"
	end
	player:Kick(if type(payload.r) == "string" and payload.r ~= "" then payload.r else "Kicked by staff.")
	return true, 1, "kicked " .. player.Name
end)

CrossServerService.Handle("ban", function(payload: any, envelope: any)
	local player, refused = findTarget(payload, envelope)
	if refused then
		return false, 0, refused -- the origin rolls the ban record back
	end
	if not player then
		return true, 0, "not here"
	end
	player:Kick(("Banned: %s"):format(if type(payload.r) == "string" and payload.r ~= "" then payload.r else "Banned by staff."))
	return true, 1, "banned and removed " .. player.Name
end)

CrossServerService.Handle("warn", function(payload: any, envelope: any)
	local player, refused = findTarget(payload, envelope)
	if refused then
		return false, 0, refused
	end
	if not player then
		return true, 0, "not here"
	end
	local actor = envelope.a
	local warnings = PunishmentService.AddWarning(
		player,
		{ UserId = tonumber(actor.u) or 0, Name = tostring(actor.n) },
		if type(payload.r) == "string" and payload.r ~= "" then payload.r else "No reason given."
	)
	return true, 1, ("warned %s (%d)"):format(player.Name, #warnings)
end)

CrossServerService.Handle("bring", function(payload: any, envelope: any)
	local player, refused = findTarget(payload, envelope)
	if refused then
		return false, 0, refused
	end
	if not player then
		return true, 0, "not here"
	end
	if type(payload.j) ~= "string" or payload.j == CrossServerService.ServerId then
		return true, 0, "already in that server"
	end
	local ok, message = CrossServerService.TeleportToServer({ player }, {
		Id = payload.j,
		Place = tonumber(payload.pl) or game.PlaceId,
	})
	if not ok then
		return false, 0, message
	end
	announceRemote:FireClient(player, ("%s is bringing you to their server..."):format(actorName(envelope)), Color3.fromRGB(64, 156, 255))
	return true, 1, "sending " .. player.Name
end)

CrossServerService.Handle("announce", function(payload: any, envelope: any)
	if type(payload.m) ~= "string" or payload.m == "" then
		return false, 0, "empty announcement"
	end
	-- The text was filtered by the sending server (AnnouncementService.Send).
	local actor = if type(envelope.a) == "table" then envelope.a else {}
	AnnouncementService.Show({
		Id = payload.i,
		Text = payload.m,
		Title = if type(payload.h) == "string" then payload.h else nil,
		Style = payload.s,
		Duration = payload.t,
		Color = payload.c,
		Scope = "global",
		Author = {
			UserId = tonumber(actor.u) or 0,
			Name = tostring(actor.n or "Staff"),
			DisplayName = if type(payload.d) == "string" then payload.d else tostring(actor.n or "Staff"),
		},
	})
	return true, #Players:GetPlayers(), nil
end)

CrossServerService.Handle("notify", function(payload: any, envelope: any)
	if type(payload.m) ~= "string" or payload.m == "" then
		return false, 0, "empty notification"
	end
	local reached = CrossServerService.PushToStaff("notify", {
		Message = payload.m,
		From = actorName(envelope),
		Server = CrossServerService.ShortId(envelope.f),
	})
	return true, reached, nil
end)

CrossServerService.Handle("lockdown", function(payload: any, envelope: any)
	local on = payload.on == true
	CrossServerService.ApplyLockdown(on, actorName(envelope), if type(payload.r) == "string" then payload.r else nil, tonumber(payload.at))
	CrossServerService.PushToStaff("notify", {
		Message = if on
			then ("Global lockdown enabled by %s. New players can't join any server."):format(actorName(envelope))
			else ("Global lockdown lifted by %s."):format(actorName(envelope)),
		From = actorName(envelope),
		Server = CrossServerService.ShortId(envelope.f),
		Level = if on then "warning" else "success",
	})
	return true, #Players:GetPlayers(), if on then "locked" else "unlocked"
end)

CrossServerService.Handle("shutdown", function(payload: any, _envelope: any)
	local message = if type(payload.m) == "string" and payload.m ~= "" then payload.m else "All servers are shutting down."
	local count = #Players:GetPlayers()
	-- Let the acknowledgement (and the staff member's own result) go out first.
	task.delay(1.5, function()
		for _, player in ipairs(Players:GetPlayers()) do
			player:Kick(message)
		end
	end)
	return true, count, "shutting down"
end)

CrossServerService.Handle("migrate", function(payload: any, _envelope: any)
	return CrossServerService.StartMigration(tonumber(payload.s) or 30, if type(payload.m) == "string" and payload.m ~= "" then payload.m else nil)
end)

CrossServerService.Handle("chat", function(payload: any, envelope: any)
	if type(payload.id) ~= "string" or type(payload.m) ~= "string" then
		return false, 0, "bad chat message"
	end
	CrossServerService.PostStaffChat({
		Id = payload.id,
		Name = tostring(payload.n),
		Rank = if type(payload.r) == "string" then payload.r else nil,
		Text = payload.m,
		Server = CrossServerService.ShortId(envelope.f),
		At = tonumber(payload.at) or os.time(),
	}, false)
	return true, 0, nil
end)

-- ;global <command line>: one global-safe, target-less command, run through
-- CommandRegistry.DispatchRemote so hooks, middleware and logging apply.
CrossServerService.Handle("cmd", function(payload: any, envelope: any)
	local actor = envelope.a
	if type(payload.l) ~= "string" or type(actor) ~= "table" then
		return false, 0, "bad command message"
	end
	local parsed = CommandParser.ParseLine(payload.l)
	if not parsed or parsed.NextCommand then
		return false, 0, "only a single command can run globally"
	end
	local def = CommandRegistry.Resolve(parsed.CommandName)
	if not def then
		return false, 0, "unknown command " .. parsed.CommandName
	end
	if not CommandPolicy.IsGlobalSafe(def) then
		return false, 0, def.Name .. " can't run globally"
	end
	-- The staff member themselves when they are in this server, otherwise
	-- their identity only.
	local executor: any = Players:GetPlayerByUserId(tonumber(actor.u) or 0)
	if executor then
		if not PermissionSystem.Has(executor, def.Permission) then
			return false, 0, "permission denied here"
		end
	else
		executor = { UserId = tonumber(actor.u) or 0, Name = tostring(actor.n), DisplayName = tostring(actor.n), IsRemoteActor = true }
	end
	local result = CommandRegistry.DispatchRemote(def, executor, {
		Executor = executor,
		Targets = {},
		Arguments = parsed.PlainArguments,
		RawInput = parsed.RawInput,
		CommandName = parsed.CommandName,
		Source = "global",
	} :: any, CrossServerService.ShortId(envelope.f))
	return result.Success == true, if result.Success then 1 else 0, result.Message
end)

return CrossServerActions
