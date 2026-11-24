--!strict
--[[
	MusicService.lua (HD Admin gap: Music / Pitch / Volume)

	One server-wide music track: a looped Sound "SentinelMusic" in
	SoundService, heard by every player. Only Roblox audio assets the
	experience is allowed to play will load (audio privacy); Play reports
	when the sound fails to load in time.

	Public API:
		MusicService.Play(id, volume?, pitch?, by?): (ok, message)
		MusicService.Stop(): boolean               -- false if nothing played
		MusicService.SetVolume(v): (ok, message)   -- 0-10 (Roblox Sound volume)
		MusicService.SetPitch(p): (ok, message)    -- 0.1-5 (PlaybackSpeed)
		MusicService.Status(): Status?
		MusicService.ParseId(raw): number?
		MusicService.Snapshot(): Status?   / MusicService.Restore(status?)  (undo)
--]]

local MarketplaceService = game:GetService("MarketplaceService")
local SoundService = game:GetService("SoundService")

local MusicService = {}

MusicService.DEFAULT_VOLUME = 0.5
MusicService.MAX_VOLUME = 10
MusicService.MIN_PITCH = 0.1
MusicService.MAX_PITCH = 5
MusicService.LOAD_TIMEOUT = 6

export type Status = {
	Id: number,
	Title: string,
	Volume: number,
	Pitch: number,
	By: string,
	At: number,
	Loaded: boolean,
}

local current: Status? = nil

function MusicService.ParseId(raw: string?): number?
	if raw == nil then
		return nil
	end
	local digits = (raw :: string):match("^rbxassetid://(%d+)$") or (raw :: string):match("^(%d+)$")
	local id = tonumber(digits)
	if not id or id <= 0 then
		return nil
	end
	return math.floor(id)
end

local function getSound(create: boolean): Sound?
	local sound = SoundService:FindFirstChild("SentinelMusic")
	if sound and sound:IsA("Sound") then
		return sound
	end
	if not create then
		return nil
	end
	local made = Instance.new("Sound")
	made.Name = "SentinelMusic"
	made.Looped = true
	made.Parent = SoundService
	return made
end

-- Asset info in one request: (isAudio: boolean?, title). isAudio is nil
-- when the lookup failed (offline / throttled), so playback is still tried.
local function assetInfo(id: number): (boolean?, string)
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
	end)
	local fallback = ("Audio %d"):format(id)
	if not ok or type(info) ~= "table" then
		return nil, fallback
	end
	local title = if type(info.Name) == "string" and info.Name ~= "" then info.Name else fallback
	if info.AssetTypeId == nil then
		return nil, title
	end
	return info.AssetTypeId == 3, title -- 3 = Enum.AssetType.Audio
end

function MusicService.Play(id: number, volume: number?, pitch: number?, by: string?): (boolean, string)
	local audio, title = assetInfo(id)
	if audio == false then
		return false, ("Asset %d is not an audio asset."):format(id)
	end
	local vol = math.clamp(volume or (if current then current.Volume else MusicService.DEFAULT_VOLUME), 0, MusicService.MAX_VOLUME)
	local pit = math.clamp(pitch or 1, MusicService.MIN_PITCH, MusicService.MAX_PITCH)
	local sound = getSound(true) :: Sound
	sound:Stop()
	sound.SoundId = ("rbxassetid://%d"):format(id)
	sound.Volume = vol
	sound.PlaybackSpeed = pit
	sound.TimePosition = 0
	sound:Play()

	local start = os.clock()
	while not sound.IsLoaded and os.clock() - start < MusicService.LOAD_TIMEOUT do
		task.wait(0.1)
	end
	local status: Status = {
		Id = id,
		Title = title,
		Volume = vol,
		Pitch = pit,
		By = by or "Server",
		At = os.time(),
		Loaded = sound.IsLoaded,
	}
	current = status
	if not sound.IsLoaded then
		return true, ("Playing %d, but it hasn't loaded after %ds - the audio may be private or not allowed in this experience."):format(
			id,
			MusicService.LOAD_TIMEOUT
		)
	end
	return true, ("Now playing '%s' (%d) - volume %s, pitch %s."):format(status.Title, id, tostring(vol), tostring(pit))
end

function MusicService.Stop(): boolean
	local sound = getSound(false)
	local had = current ~= nil
	current = nil
	if sound then
		sound:Stop()
		sound:Destroy()
	end
	return had
end

function MusicService.SetVolume(v: number): (boolean, string)
	if v < 0 or v > MusicService.MAX_VOLUME then
		return false, ("Volume is 0-%d."):format(MusicService.MAX_VOLUME)
	end
	local sound = getSound(false)
	if not sound or not current then
		return false, "No music is playing (;music <id>)."
	end
	sound.Volume = v;
	(current :: Status).Volume = v
	return true, ("Music volume set to %s."):format(tostring(v))
end

function MusicService.SetPitch(p: number): (boolean, string)
	if p < MusicService.MIN_PITCH or p > MusicService.MAX_PITCH then
		return false, ("Pitch is %s-%s."):format(tostring(MusicService.MIN_PITCH), tostring(MusicService.MAX_PITCH))
	end
	local sound = getSound(false)
	if not sound or not current then
		return false, "No music is playing (;music <id>)."
	end
	sound.PlaybackSpeed = p;
	(current :: Status).Pitch = p
	return true, ("Music pitch set to %s."):format(tostring(p))
end

function MusicService.Status(): Status?
	return current
end

function MusicService.Snapshot(): Status?
	return if current then table.clone(current :: Status) else nil
end

-- Undo helper: put back what was playing before (or silence).
function MusicService.Restore(status: Status?): (boolean, string)
	if not status then
		MusicService.Stop()
		return true, "Music stopped."
	end
	return MusicService.Play(status.Id, status.Volume, status.Pitch, status.By)
end

return MusicService
