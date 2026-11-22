--!strict
--[[
	SoundLibrary.lua (sound effects, 2026-11-22)

	Purpose:
		The sound effects Sentinel ships with, and the parser for custom
		sounds. Shared by UIPrefs (validation), the settings page and the
		client SoundPlayer.

	A sound value (UIPrefs Sounds.<Event>) is one of:
		"Off"                      no sound for that event
		"Success1" .. "Fail4"      a built-in sound (BUILTIN below)
		"rbxassetid://<id>"        a custom sound (any Roblox audio asset)

	Custom sounds can be given as a Roblox asset link
	(https://create.roblox.com/store/asset/<id>/..., https://www.roblox.com/
	library/<id>/...), rbxassetid://<id>, or the plain id. The asset must be
	an Audio asset the experience is allowed to play.

	Public API:
		SoundLibrary.BUILTIN    name -> { Id, Label }
		SoundLibrary.ORDER      built-in names in display order
		SoundLibrary.EVENTS     the events that play a sound, in order
		SoundLibrary.ParseId(text) -> number?   asset id from a link / id
		SoundLibrary.Normalize(value) -> string?  canonical sound value
		SoundLibrary.Resolve(value) -> string?    "rbxassetid://..." to play
		SoundLibrary.Label(value) -> string       short name for the UI
--]]

local SoundLibrary = {}

-- The user's uploads (Creator Hub, "Sentinel-Admin-Panel-Sucess" and
-- "Sentinel_Fail_sound_effect" 1-4).
SoundLibrary.BUILTIN = {
	Success1 = { Id = 71846104869252, Label = "Success 1" },
	Success2 = { Id = 88231927602066, Label = "Success 2" },
	Success3 = { Id = 106102480232369, Label = "Success 3" },
	Success4 = { Id = 86646291995792, Label = "Success 4" },
	Fail1 = { Id = 93029035669113, Label = "Fail 1" },
	Fail2 = { Id = 101675667324598, Label = "Fail 2" },
	Fail3 = { Id = 91946171121220, Label = "Fail 3" },
	Fail4 = { Id = 134933923910446, Label = "Fail 4" },
}
SoundLibrary.ORDER = { "Success1", "Success2", "Success3", "Success4", "Fail1", "Fail2", "Fail3", "Fail4" }

-- Events, in settings order. Description is shown in the settings page.
SoundLibrary.EVENTS = { "Success", "Error", "Warning", "Info" }
SoundLibrary.EVENT_INFO = {
	Success = "A command worked, or a success notification",
	Error = "A command failed or was denied",
	Warning = "Warnings: confirmations, held commands, rate limits",
	Info = "Information: new reports / appeals, messages, welcome",
}

local MAX_ID = 1e17

-- Asset id from a link, "rbxassetid://id" or a plain number. nil if none.
function SoundLibrary.ParseId(text: any): number?
	if type(text) == "number" then
		if text >= 1 and text < MAX_ID and text == math.floor(text) then
			return text
		end
		return nil
	end
	if type(text) ~= "string" or #text > 300 then
		return nil
	end
	local s = text:gsub("%s", "")
	local digits = s:match("^(%d+)$")
		or s:match("^rbxassetid://(%d+)$")
		or s:match("[%?&]id=(%d+)")
		or s:match("roblox%.com/.-/(%d+)")
	local id = tonumber(digits)
	if id and id >= 1 and id < MAX_ID then
		return id
	end
	return nil
end

-- Canonical value ("Off", a built-in name, or "rbxassetid://<id>") or nil.
function SoundLibrary.Normalize(value: any): string?
	if type(value) == "string" then
		local lower = value:lower():gsub("[%s_%-]", "")
		if lower == "off" or lower == "none" or lower == "mute" then
			return "Off"
		end
		for _, name in ipairs(SoundLibrary.ORDER) do
			if name:lower() == lower then
				return name
			end
		end
	end
	local id = SoundLibrary.ParseId(value)
	if id then
		return ("rbxassetid://%d"):format(id)
	end
	return nil
end

-- What to put in Sound.SoundId, or nil for Off / invalid.
function SoundLibrary.Resolve(value: any): string?
	local v = SoundLibrary.Normalize(value)
	if not v or v == "Off" then
		return nil
	end
	local builtin = SoundLibrary.BUILTIN[v]
	if builtin then
		return ("rbxassetid://%d"):format(builtin.Id)
	end
	return v
end

function SoundLibrary.IsCustom(value: any): boolean
	return type(value) == "string" and value:sub(1, 13) == "rbxassetid://"
end

function SoundLibrary.Label(value: any): string
	local v = SoundLibrary.Normalize(value)
	if not v then
		return "?"
	elseif v == "Off" then
		return "Off"
	elseif SoundLibrary.BUILTIN[v] then
		return SoundLibrary.BUILTIN[v].Label
	end
	return "Custom (" .. v:sub(14) .. ")"
end

return SoundLibrary
