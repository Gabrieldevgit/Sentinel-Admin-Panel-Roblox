--!strict
--[[
	TargetResolver.lua

	Purpose:
		Turns the parsed TargetSelector list (from CommandParser) into an
		actual list of in-game Players. This is the "powerful part of the
		framework" — supporting simple keywords (me/all/others/random/
		nearest/last), group selectors (@team/@role/@group/@rank/@vip/
		@staff/@friends), property selectors (@level >25), attribute
		selectors (@attribute Flying), tag selectors (#Raiders), and
		explicit filters (`where Health<50`).

	Responsibilities:
		- Resolve each selector kind to a Player set
		- Union multiple selectors / named targets together, de-duplicated
		- Apply trailing `where <Property><op><value>` filters
		- Track "last" target per executor for the $last / "last" selector

	Dependencies:
		Types.lua (Shared)
		A small set of injectable lookups (RoleProvider, GroupProvider,
		TagProvider, PropertyProvider) so this module never hardcodes
		game-specific concepts like "level" or "vip" — those are wired up
		by whichever game-specific service owns that data (Phase 4).

	Public API:
		TargetResolver.Resolve(executor: Player, selectors: {TargetSelector}, filters: {CommandFilter}?): {Player}
		TargetResolver.SetLast(executor: Player, players: {Player}): ()
		TargetResolver.RegisterPropertyProvider(name: string, fn: (Player) -> number): ()
		TargetResolver.RegisterGroupProvider(fn: (Player, groupName: string) -> boolean): ()
		TargetResolver.RegisterTagProvider(fn: (Player, tag: string) -> boolean): ()
		TargetResolver.RegisterAttributeAlias(alias: string, attributeName: string): ()

	Example usage:
		-- /heal @team Red where Health<50
		TargetResolver.Resolve(executor, {
			{ Kind = "Team", Raw = "@team", Value = "Red" },
		}, {
			{ Property = "Health", Operator = "<", Comparand = "50" },
		})
--]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local PermissionSystem = require(script.Parent.Parent:WaitForChild("PermissionSystem"))

type TargetSelector = Types.TargetSelector
type CommandFilter = Types.CommandFilter

local TargetResolver = {}

local lastTargets: { [number]: { Player } } = {}
local propertyProviders: { [string]: (Player) -> number } = {}
local groupProviders: { (Player, string) -> boolean } = {}
local tagProviders: { (Player, string) -> boolean } = {}
local attributeAliases: { [string]: string } = {}

-- Built-in property providers that make sense with no game-specific hookup.
propertyProviders["Health"] = function(p: Player): number
	local character = p.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid then humanoid.Health else 0
end
propertyProviders["Ping"] = function(p: Player): number
	local ok, stats = pcall(function()
		return p:GetNetworkPing() * 1000
	end)
	return if ok then stats else 0
end

function TargetResolver.RegisterPropertyProvider(name: string, fn: (Player) -> number)
	propertyProviders[name] = fn
end

function TargetResolver.RegisterGroupProvider(fn: (Player, string) -> boolean)
	table.insert(groupProviders, fn)
end

function TargetResolver.RegisterTagProvider(fn: (Player, string) -> boolean)
	table.insert(tagProviders, fn)
end

function TargetResolver.RegisterAttributeAlias(alias: string, attributeName: string)
	attributeAliases[alias] = attributeName
end

function TargetResolver.SetLast(executor: Player, players: { Player })
	lastTargets[executor.UserId] = players
end

local function allPlayers(): { Player }
	return Players:GetPlayers()
end

local function distance(a: Player, b: Player): number
	local ca, cb = a.Character, b.Character
	if not ca or not cb then
		return math.huge
	end
	local ra, rb = ca.PrimaryPart, cb.PrimaryPart
	if not ra or not rb then
		return math.huge
	end
	return (ra.Position - rb.Position).Magnitude
end

local function resolveOne(executor: Player, selector: TargetSelector): { Player }
	local kind = selector.Kind

	if kind == "Self" then
		return { executor }
	elseif kind == "All" then
		return allPlayers()
	elseif kind == "Others" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			if p ~= executor then
				table.insert(list, p)
			end
		end
		return list
	elseif kind == "Random" then
		local pool = allPlayers()
		if #pool == 0 then
			return {}
		end
		return { pool[math.random(1, #pool)] }
	elseif kind == "Nearest" then
		local nearest: Player? = nil
		local nearestDist = math.huge
		for _, p in ipairs(allPlayers()) do
			if p ~= executor then
				local d = distance(executor, p)
				if d < nearestDist then
					nearestDist = d
					nearest = p
				end
			end
		end
		return if nearest then { nearest } else {}
	elseif kind == "Last" then
		return lastTargets[executor.UserId] or {}
	elseif kind == "Named" then
		local player = Players:FindFirstChild(selector.Value or selector.Raw)
		return if player and player:IsA("Player") then { player :: Player } else {}
	elseif kind == "Team" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			if p.Team and p.Team.Name == selector.Value then
				table.insert(list, p)
			end
		end
		return list
	elseif kind == "Role" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			for _, roleName in ipairs(PermissionSystem.GetRoles(p)) do
				if roleName == selector.Value then
					table.insert(list, p)
					break
				end
			end
		end
		return list
	elseif kind == "Group" or kind == "Rank" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			for _, provider in ipairs(groupProviders) do
				if provider(p, selector.Value or "") then
					table.insert(list, p)
					break
				end
			end
		end
		return list
	elseif kind == "Tag" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			for _, provider in ipairs(tagProviders) do
				if provider(p, selector.Value or "") then
					table.insert(list, p)
					break
				end
			end
		end
		return list
	elseif kind == "Attribute" then
		local attrName = attributeAliases[selector.Value or ""] or (selector.Value or "")
		local list = {}
		for _, p in ipairs(allPlayers()) do
			if p:GetAttribute(attrName) then
				table.insert(list, p)
			end
		end
		return list
	elseif kind == "Property" then
		local provider = propertyProviders[selector.Value or ""]
		if not provider then
			return {}
		end
		local list = {}
		for _, p in ipairs(allPlayers()) do
			local value = provider(p)
			if TargetResolver._compare(value, selector.Operator, selector.Comparand) then
				table.insert(list, p)
			end
		end
		return list
	end

	return {}
end

function TargetResolver._compare(value: number, operator: string?, comparandStr: string?): boolean
	local comparand = tonumber(comparandStr or "")
	if not comparand then
		return false
	end
	if operator == ">" then
		return value > comparand
	elseif operator == "<" then
		return value < comparand
	elseif operator == ">=" then
		return value >= comparand
	elseif operator == "<=" then
		return value <= comparand
	elseif operator == "=" or operator == "==" then
		return value == comparand
	end
	return false
end

local function applyFilters(players: { Player }, filters: { CommandFilter }?): { Player }
	if not filters or #filters == 0 then
		return players
	end
	local filtered = {}
	for _, p in ipairs(players) do
		local passesAll = true
		for _, filter in ipairs(filters) do
			local provider = propertyProviders[filter.Property]
			local value = if provider then provider(p) else nil
			if not value or not TargetResolver._compare(value, filter.Operator, filter.Comparand) then
				passesAll = false
				break
			end
		end
		if passesAll then
			table.insert(filtered, p)
		end
	end
	return filtered
end

function TargetResolver.Resolve(executor: Player, selectors: { TargetSelector }, filters: { CommandFilter }?): { Player }
	local seen: { [Player]: boolean } = {}
	local result: { Player } = {}

	for _, selector in ipairs(selectors) do
		for _, p in ipairs(resolveOne(executor, selector)) do
			if not seen[p] then
				seen[p] = true
				table.insert(result, p)
			end
		end
	end

	result = applyFilters(result, filters)
	TargetResolver.SetLast(executor, result)
	return result
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastTargets[player.UserId] = nil
end)

return TargetResolver
