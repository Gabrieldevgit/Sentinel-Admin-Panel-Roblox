--!strict
--[[
	Selection.lua

	Purpose:
		The player(s) picked on the Players page, shared with the rest of the
		panel so other pages (the Commands directory's Run / Fill buttons)
		act on them instead of always on "me".

		Two parts:
		- the focused player (the one whose details are open), Set / Get;
		- W15: the checked players (bulk selection), SetMany / GetMany.
		  When any are checked they are the command target.

		Client-side only: it just decides which names go into the command
		text. The server still resolves the names and checks permissions and
		rank protection like for any typed command.

	Public API:
		Selection.Set(userId: number?, name: string?)   -- nil clears both parts
		Selection.Get(): { UserId: number, Name: string }?
		Selection.SetMany(list: { { UserId: number, Name: string } })
		Selection.GetMany(): { { UserId: number, Name: string } }
		Selection.TargetText(): string   -- checked names (a,b,c), else the
		                                 -- focused name, else "me"
		Selection.Changed: BindableEvent.Event  -- fires (focused?)
--]]

local Players = game:GetService("Players")

local Selection = {}

type Pick = { UserId: number, Name: string }

local current: Pick? = nil
local many: { Pick } = {}
local changed = Instance.new("BindableEvent")
Selection.Changed = changed.Event

function Selection.Set(userId: number?, name: string?)
	if type(userId) == "number" and type(name) == "string" then
		if current and current.UserId == userId then
			return
		end
		current = { UserId = userId, Name = name }
	else
		if current == nil and #many == 0 then
			return
		end
		current = nil
		many = {}
	end
	changed:Fire(current)
end

function Selection.Get(): Pick?
	-- A player who left is no longer a valid target.
	if current and not Players:GetPlayerByUserId(current.UserId) then
		current = nil
		changed:Fire(nil)
	end
	return current
end

function Selection.SetMany(list: { Pick })
	local clean: { Pick } = {}
	local seen: { [number]: boolean } = {}
	for _, pick in ipairs(list) do
		if type(pick) == "table" and type(pick.UserId) == "number" and type(pick.Name) == "string" and not seen[pick.UserId] then
			seen[pick.UserId] = true
			table.insert(clean, { UserId = pick.UserId, Name = pick.Name })
		end
	end
	many = clean
	changed:Fire(current)
end

function Selection.GetMany(): { Pick }
	local alive: { Pick } = {}
	for _, pick in ipairs(many) do
		if Players:GetPlayerByUserId(pick.UserId) then
			table.insert(alive, pick)
		end
	end
	many = alive
	return table.clone(many)
end

function Selection.TargetText(): string
	local checked = Selection.GetMany()
	if #checked > 0 then
		local names = {}
		for _, pick in ipairs(checked) do
			table.insert(names, pick.Name)
		end
		return table.concat(names, ",")
	end
	local selected = Selection.Get()
	return if selected then selected.Name else "me"
end

Players.PlayerRemoving:Connect(function(player)
	local fire = false
	if current and current.UserId == player.UserId then
		current = nil
		fire = true
	end
	for i, pick in ipairs(many) do
		if pick.UserId == player.UserId then
			table.remove(many, i)
			fire = true
			break
		end
	end
	if fire then
		changed:Fire(current)
	end
end)

return Selection
