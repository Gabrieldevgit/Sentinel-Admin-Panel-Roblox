--!strict
--[[
	PrefsService.lua (UI redesign)

	Purpose:
		Per-player UI preferences (panel theme, command bar look) and the
		server-wide default the Owner chooses.

		personal   DataStore Sentinel_Prefs_v1, key = UserId. Loaded on join,
		           saved (debounced) after a change and on leave.
		default    ConfigService key "UIDefaults" (persisted + pushed to every
		           server by ConfigService).
		effective  UIPrefs.Merge(BUILTIN, default, personal) - what the client
		           actually uses.

		Every value is validated by Shared/UIPrefs.Sanitize, so a client can
		only ever store known settings with in-range values.

	Public API:
		PrefsService.GetPersonal(player) -> prefs
		PrefsService.GetDefaults() -> prefs
		PrefsService.GetEffective(player) -> prefs
		PrefsService.Snapshot(player) -> { Effective, Personal, Defaults }
		PrefsService.SetPersonal(player, partial) -> (ok, message)
		PrefsService.ResetPersonal(player, section?) -> (ok, message)
		PrefsService.SetDefaults(partial, actor) -> (ok, message)
		PrefsService.ResetDefaults(section?, actor) -> (ok, message)
		PrefsService.CanUseCommandBar(player) -> boolean

	Clients are told about changes on UIPrefsChangedRemote(snapshot).
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))

local Sentinel = script.Parent.Parent
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local ConfigService = require(script.Parent:WaitForChild("ConfigService"))

local PrefsService = {}

local STORE_NAME = "Sentinel_Prefs_v1"
local SAVE_DELAY = 5

local live = RunService:IsRunning() and RunService:IsServer()
local store = if live then DataStoreService:GetDataStore(STORE_NAME) else nil

local personal: { [number]: any } = {}
local dirty: { [number]: boolean } = {}
local saveQueued: { [number]: boolean } = {}

local changedRemote: RemoteEvent
do
	local existing = SentinelShared:FindFirstChild("UIPrefsChangedRemote")
	if existing and existing:IsA("RemoteEvent") then
		changedRemote = existing
	else
		changedRemote = Instance.new("RemoteEvent")
		changedRemote.Name = "UIPrefsChangedRemote"
		changedRemote.Parent = SentinelShared
	end
end

-- The command bar is for staff and for ranks given "commandbar.use" (VIP).
function PrefsService.CanUseCommandBar(player: Player): boolean
	return PermissionSystem.Has(player, "panel.open") or PermissionSystem.Has(player, "commandbar.use")
end

function PrefsService.GetPersonal(player: Player): any
	return UIPrefs.Sanitize(personal[player.UserId])
end

function PrefsService.GetDefaults(): any
	return UIPrefs.Sanitize(ConfigService.Get("UIDefaults"))
end

function PrefsService.GetEffective(player: Player): any
	return UIPrefs.Merge(UIPrefs.BUILTIN, PrefsService.GetDefaults(), personal[player.UserId])
end

function PrefsService.Snapshot(player: Player): any
	return {
		Effective = PrefsService.GetEffective(player),
		Personal = PrefsService.GetPersonal(player),
		Defaults = PrefsService.GetDefaults(),
	}
end

local function push(player: Player)
	if live and player.Parent == Players then
		changedRemote:FireClient(player, PrefsService.Snapshot(player))
	end
end

local function save(userId: number)
	if not store or not dirty[userId] then
		return
	end
	dirty[userId] = nil
	local data = UIPrefs.Sanitize(personal[userId])
	local ok, err = pcall(function()
		if next(data) then
			(store :: DataStore):SetAsync(tostring(userId), data)
		else
			(store :: DataStore):RemoveAsync(tostring(userId))
		end
	end)
	if not ok then
		dirty[userId] = true
		warn(("[Sentinel.PrefsService] save failed for %d: %s"):format(userId, tostring(err)))
	end
end

local function queueSave(userId: number)
	dirty[userId] = true
	if saveQueued[userId] or not store then
		return
	end
	saveQueued[userId] = true
	task.delay(SAVE_DELAY, function()
		saveQueued[userId] = nil
		save(userId)
	end)
end

local function countFields(prefs: any): number
	local n = 0
	for _, fields in pairs(prefs) do
		for _ in pairs(fields) do
			n += 1
		end
	end
	return n
end

function PrefsService.SetPersonal(player: Player, partial: any): (boolean, string)
	local clean = UIPrefs.Sanitize(partial)
	if countFields(clean) == 0 then
		return false, "Nothing valid to change."
	end
	local current = UIPrefs.Sanitize(personal[player.UserId])
	for section, fields in pairs(clean) do
		current[section] = current[section] or {}
		for field, value in pairs(fields) do
			current[section][field] = value
		end
	end
	personal[player.UserId] = current
	queueSave(player.UserId)
	push(player)
	return true, "Saved your settings."
end

-- Drops personal overrides so the server default applies again.
function PrefsService.ResetPersonal(player: Player, section: string?): (boolean, string)
	local current = UIPrefs.Sanitize(personal[player.UserId])
	if section then
		current[section] = nil
	else
		current = {}
	end
	personal[player.UserId] = current
	queueSave(player.UserId)
	push(player)
	return true, "Your settings now follow the server default."
end

local function pushAll()
	for _, player in ipairs(Players:GetPlayers()) do
		push(player)
	end
end

function PrefsService.SetDefaults(partial: any, actor: Player?): (boolean, string)
	local clean = UIPrefs.Sanitize(partial)
	if countFields(clean) == 0 then
		return false, "Nothing valid to change."
	end
	local current = PrefsService.GetDefaults()
	for section, fields in pairs(clean) do
		current[section] = current[section] or {}
		for field, value in pairs(fields) do
			current[section][field] = value
		end
	end
	local ok, err = ConfigService.Set("UIDefaults", current, actor)
	if not ok then
		return false, err or "Could not save the server default."
	end
	return true, "Server default updated for everyone who hasn't chosen their own."
end

function PrefsService.ResetDefaults(section: string?, actor: Player?): (boolean, string)
	local current = PrefsService.GetDefaults()
	if section then
		current[section] = nil
	else
		current = {}
	end
	local ok, err = ConfigService.Set("UIDefaults", current, actor)
	if not ok then
		return false, err or "Could not save the server default."
	end
	return true, "Server default reset to Sentinel's built-in look."
end

if not live then
	return PrefsService
end

ConfigService.Changed:Connect(function(key: string)
	if key == "UIDefaults" then
		pushAll()
	end
end)

local function load(player: Player)
	local userId = player.UserId
	local ok, data = pcall(function()
		return (store :: DataStore):GetAsync(tostring(userId))
	end)
	if not ok then
		warn(("[Sentinel.PrefsService] load failed for %s: %s"):format(player.Name, tostring(data)))
		return
	end
	-- Don't overwrite a change the player made while the load was in flight.
	if personal[userId] == nil and player.Parent == Players then
		personal[userId] = UIPrefs.Sanitize(data)
		if next(personal[userId]) then
			push(player)
		end
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	task.spawn(load, player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(load, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	save(userId)
	personal[userId] = nil
	dirty[userId] = nil
end)

game:BindToClose(function()
	for userId in pairs(dirty) do
		save(userId)
	end
end)

return PrefsService
