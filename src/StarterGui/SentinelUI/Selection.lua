--!strict
--[[
	Selection.lua

	Purpose:
		The player picked on the Players page, shared with the rest of the
		panel so other pages (the Commands directory's Run / Fill buttons)
		act on that player instead of always on "me".

		Client-side only: it just decides which name goes into the command
		text. The server still resolves the name and checks permissions and
		rank protection like for any typed command.

	Public API:
		Selection.Set(userId: number?, name: string?)   -- nil clears
		Selection.Get(): { UserId: number, Name: string }?
		Selection.TargetText(): string   -- selected name, or "me"
		Selection.Changed: BindableEvent.Event  -- fires (selection?)
--]]

local Players = game:GetService("Players")

local Selection = {}

local current: { UserId: number, Name: string }? = nil
local changed = Instance.new("BindableEvent")
Selection.Changed = changed.Event

function Selection.Set(userId: number?, name: string?)
	if type(userId) == "number" and type(name) == "string" then
		if current and current.UserId == userId then
			return
		end
		current = { UserId = userId, Name = name }
	else
		if current == nil then
			return
		end
		current = nil
	end
	changed:Fire(current)
end

function Selection.Get(): { UserId: number, Name: string }?
	-- A player who left is no longer a valid target.
	if current and not Players:GetPlayerByUserId(current.UserId) then
		current = nil
		changed:Fire(nil)
	end
	return current
end

function Selection.TargetText(): string
	local selected = Selection.Get()
	return if selected then selected.Name else "me"
end

Players.PlayerRemoving:Connect(function(player)
	if current and current.UserId == player.UserId then
		current = nil
		changed:Fire(nil)
	end
end)

return Selection
