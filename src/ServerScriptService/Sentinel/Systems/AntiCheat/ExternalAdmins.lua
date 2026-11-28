--!strict
--[[
	ExternalAdmins.lua (Sentinel AntiCheat - other admin systems in the place)

	Some admin systems move players on the CLIENT. HD Admin's Fly / Fly2 /
	NoClip / Noclip2 create a BodyPosition + BodyGyro ("HDAdminFlyForce",
	"HDAdminFlyGyro") only on the flying player's client, so the server sees
	exactly what an exploit fly looks like (measured: ~90% of HD Admin
	flights were flagged). The client can't be trusted to say "this is HD
	Admin", so this asks HD Admin's own SERVER API instead:
	ServerAPI.getTasks(commandName, userId) lists the command tasks HD Admin
	approved and is running on that player (its flight tasks last until the
	player respawns). A non-admin typing ":fly me" gets no task, and an
	exploiter can't create one.

	Only used while Core.TrustExternalAdmins is ON (default OFF: the owner
	tests detections with HD Admin's fly, so it is flagged like any cheat
	unless trusted). DetectionEngine checks the setting before asking.

	Answers are cached per player for CACHE_SECONDS and the cache is dropped
	whenever HD Admin runs any command (ServerAPI.onCommandRun), so a new
	flight is seen within one sample. If HD Admin isn't installed (or its API
	fails) everything reports "not flying" - nothing else changes.

	HD Admin's teleport commands (Teleport, Bring, GoTo, Apparate, Farland)
	move the character on the server with PivotTo, which AntiCheatService
	already treats as a known teleport; they need nothing here.

	Public API:
		ExternalAdmins.Start()                      (non-blocking)
		ExternalAdmins.Movement(userId, now) -> (flying, noclip)
		ExternalAdmins.Status() -> string
		ExternalAdmins.Forget(userId)
		ExternalAdmins._SetProvider(api?)           (tests)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ExternalAdmins = {}

local CACHE_SECONDS = 1
local FLIGHT_COMMANDS = { "Fly", "Fly2", "NoClip", "Noclip2" }
local NOCLIP_COMMANDS: { [string]: boolean } = { NoClip = true, Noclip2 = true }

local hdApi: any = nil
local status = "HD Admin: not checked yet"
local started = false
local cache: { [number]: { At: number, Flying: boolean, Noclip: boolean } } = {}

local function hasTask(name: string, userId: number): boolean
	local ok, tasks = pcall(hdApi.getTasks, name, userId)
	return ok and type(tasks) == "table" and #tasks > 0
end

function ExternalAdmins.Start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		-- HD Admin moves its shared files into ReplicatedStorage when it loads.
		local folder = ReplicatedStorage:WaitForChild("HD Admin", 60)
		if not folder then
			status = "HD Admin: not installed"
			return
		end
		local core = folder:WaitForChild("Core", 30)
		local module = core and core:WaitForChild("ServerAPI", 30)
		if not module or not module:IsA("ModuleScript") then
			status = "HD Admin: ServerAPI not found (older version?) - its flight may be flagged"
			return
		end
		-- Yields until HD Admin has loaded (its API waits for that itself).
		local ok, api = pcall(require, module)
		if not ok or type(api) ~= "table" or type(api.getTasks) ~= "function" then
			status = "HD Admin: API unavailable (" .. tostring(api):sub(1, 80) .. ") - its flight may be flagged"
			return
		end
		hdApi = api
		status = "HD Admin: connected"
		if type(api.onCommandRun) == "function" then
			pcall(api.onCommandRun, function()
				table.clear(cache)
			end)
		end
	end)
end

function ExternalAdmins.Movement(userId: number, now: number): (boolean, boolean)
	if not hdApi then
		return false, false
	end
	local hit = cache[userId]
	if hit and now - hit.At < CACHE_SECONDS then
		return hit.Flying, hit.Noclip
	end
	local flying, noclip = false, false
	for _, name in ipairs(FLIGHT_COMMANDS) do
		if hasTask(name, userId) then
			flying = true
			if NOCLIP_COMMANDS[name] then
				noclip = true
			end
		end
	end
	cache[userId] = { At = now, Flying = flying, Noclip = noclip }
	return flying, noclip
end

function ExternalAdmins.Status(): string
	return status
end

function ExternalAdmins.Forget(userId: number)
	cache[userId] = nil
end

-- Tests: a fake API ({ getTasks = fn(name, userId) -> {..} }) or nil.
function ExternalAdmins._SetProvider(api: any)
	hdApi = api
	table.clear(cache)
	status = if api then "HD Admin: test provider" else "HD Admin: not checked yet"
end

return ExternalAdmins
