--!strict
--[[
	SoundPlayer.lua (sound effects, 2026-11-22)

	Purpose:
		Plays Sentinel's sound effects for this player, following their
		Sounds preferences (UIPrefs section "Sounds": Enabled, Volume and one
		sound per event). NotificationCenter calls Play(kind) for every
		toast, so command results, warnings and info cards all sound.

	Public API:
		SoundPlayer.ApplyPrefs(soundsPrefs)
		SoundPlayer.Play(event)        -- "Success" | "Error" | "Warning" | "Info"
		                               -- (lower-case notification kinds work too)
		SoundPlayer.Preview(value, volume?) -> (ok, message)
		                               -- plays a sound value even when muted;
		                               -- checks that a custom id loads (yields)
		SoundPlayer.IsEnabled() -> boolean
		SoundPlayer.Changed            -- BindableEvent fired after ApplyPrefs
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local MarketplaceService = game:GetService("MarketplaceService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))
local SoundLibrary = require(SentinelShared:WaitForChild("SoundLibrary"))

local SoundPlayer = {}

local prefs: any = table.clone(UIPrefs.BUILTIN.Sounds)
local lastPlayed: { [string]: number } = {}
local preloaded = false

local changed = Instance.new("BindableEvent")
SoundPlayer.Changed = changed.Event

local KIND_TO_EVENT = { success = "Success", error = "Error", warning = "Warning", info = "Info" }

local function folder(): Instance
	local f = SoundService:FindFirstChild("SentinelSounds")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SentinelSounds"
		f.Parent = SoundService
	end
	return f
end

local function playId(soundId: string, volume: number)
	local sound = Instance.new("Sound")
	sound.Name = "Sfx"
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Parent = folder()
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(10, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function preload()
	if preloaded then
		return
	end
	preloaded = true
	task.spawn(function()
		local list = {}
		for _, event in ipairs(SoundLibrary.EVENTS) do
			local id = SoundLibrary.Resolve(prefs[event])
			if id then
				local s = Instance.new("Sound")
				s.SoundId = id
				table.insert(list, s)
			end
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
		for _, s in ipairs(list) do
			s:Destroy()
		end
	end)
end

function SoundPlayer.ApplyPrefs(sounds: any)
	local merged = table.clone(UIPrefs.BUILTIN.Sounds)
	if type(sounds) == "table" then
		for k, v in pairs(sounds) do
			merged[k] = v
		end
	end
	prefs = merged
	preloaded = false
	preload()
	changed:Fire(prefs)
end

function SoundPlayer.IsEnabled(): boolean
	return prefs.Enabled ~= false
end

function SoundPlayer.Get(): any
	return prefs
end

function SoundPlayer.Play(event: string)
	event = KIND_TO_EVENT[event] or event
	if prefs.Enabled == false then
		return
	end
	local id = SoundLibrary.Resolve(prefs[event])
	if not id then
		return
	end
	-- A burst of toasts (e.g. a && chain) plays one sound per event.
	local now = os.clock()
	if lastPlayed[event] and now - lastPlayed[event] < 0.12 then
		return
	end
	lastPlayed[event] = now
	local volume = if type(prefs.Volume) == "number" then math.clamp(prefs.Volume, 0, 1) else 0.5
	if volume <= 0 then
		return
	end
	playId(id, volume)
end

-- Is this custom sound playable here? (yields up to ~4 s)
-- PreloadAsync says "Success" for any asset type, so check the asset type
-- first, then that a Sound really loads it (permission / moderation).
local checked: { [string]: boolean } = {}
function SoundPlayer.Check(soundId: string): (boolean, string)
	if checked[soundId] then
		return true, "ok"
	end
	local assetId = SoundLibrary.ParseId(soundId)
	if not assetId then
		return false, "That is not a Roblox audio link or id."
	end
	local okInfo, info = pcall(function()
		return MarketplaceService:GetProductInfo(assetId, Enum.InfoType.Asset)
	end)
	if okInfo and type(info) == "table" and info.AssetTypeId ~= 3 then
		return false, ("%d is not an Audio asset (it is asset type %s)."):format(assetId, tostring(info.AssetTypeId))
	end
	local probe = Instance.new("Sound")
	probe.Name = "Probe"
	probe.Volume = 0
	probe.SoundId = soundId
	probe.Parent = folder()
	local deadline = os.clock() + 4
	while not probe.IsLoaded and os.clock() < deadline do
		task.wait(0.1)
	end
	local loaded = probe.IsLoaded and probe.TimeLength > 0
	probe:Destroy()
	if not loaded then
		return false, ("Couldn't load audio %d - it must be public or allowed for this experience."):format(assetId)
	end
	checked[soundId] = true
	return true, "ok"
end

-- Plays a sound value regardless of Enabled. Custom ids are loaded first so
-- the caller can tell the user when a link is not playable audio.
function SoundPlayer.Preview(value: any, volume: number?): (boolean, string)
	local normalized = SoundLibrary.Normalize(value)
	if not normalized then
		return false, "That is not a sound name, Roblox audio link or id."
	end
	local id = SoundLibrary.Resolve(normalized)
	if not id then
		return true, "This event is silent (Off)."
	end
	local vol = volume or (if type(prefs.Volume) == "number" then prefs.Volume else 0.5)
	if vol <= 0 then
		vol = 0.5
	end
	if SoundLibrary.IsCustom(normalized) then
		local ok, err = SoundPlayer.Check(normalized)
		if not ok then
			return false, err
		end
	end
	playId(id, vol)
	return true, "Playing " .. SoundLibrary.Label(normalized) .. "."
end

preload()

return SoundPlayer
