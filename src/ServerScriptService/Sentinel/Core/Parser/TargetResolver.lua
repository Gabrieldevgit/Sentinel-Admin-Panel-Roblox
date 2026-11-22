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

	W15 (Player Explorer selection):
		- @team / @role / @rank match names case-insensitively; @rank
		  matches the player's Sentinel ranks (then any group provider).
		- @attribute Name           players whose attribute is truthy
		  @attribute Name=value     ... equal to value (numbers compared as
		                            numbers, true/false as booleans)
		  @attribute Name!=value    ... not equal
		- @<property> <op><n> and `where <property><op><n>`: built-in
		  Health, MaxHealth, Ping, WalkSpeed, JumpPower, AccountAge (days),
		  Session (minutes in this server); otherwise any leaderstat
		  (Coins, Level, ...) or numeric player attribute of that name.
		  Property names are case-insensitive.
		TargetResolver.GetProperty(player, name) -> number?

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
local ArgumentTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("ArgumentTypes"))

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
local function humanoidOf(p: Player): Humanoid?
	local character = p.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end
propertyProviders["MaxHealth"] = function(p: Player): number
	local h = humanoidOf(p)
	return if h then h.MaxHealth else 0
end
propertyProviders["WalkSpeed"] = function(p: Player): number
	local h = humanoidOf(p)
	return if h then h.WalkSpeed else 0
end
propertyProviders["JumpPower"] = function(p: Player): number
	local h = humanoidOf(p)
	return if h then (if h.UseJumpPower then h.JumpPower else h.JumpHeight) else 0
end
propertyProviders["AccountAge"] = function(p: Player): number
	return p.AccountAge
end
-- Minutes since the player joined this server.
local joinedAt: { [Player]: number } = {}
propertyProviders["Session"] = function(p: Player): number
	return (os.clock() - (joinedAt[p] or os.clock())) / 60
end
for _, p in ipairs(Players:GetPlayers()) do
	joinedAt[p] = os.clock()
end
Players.PlayerAdded:Connect(function(p)
	joinedAt[p] = os.clock()
end)

-- Provider by name (case-insensitive), else a leaderstat or a numeric
-- player attribute with that name.
function TargetResolver.GetProperty(p: Player, name: string): number?
	local provider = propertyProviders[name]
	if not provider then
		local lower = name:lower()
		for key, fn in pairs(propertyProviders) do
			if key:lower() == lower then
				provider = fn
				break
			end
		end
	end
	if provider then
		return provider(p)
	end
	local stats = p:FindFirstChild("leaderstats")
	if stats then
		for _, v in ipairs(stats:GetChildren()) do
			if v.Name:lower() == name:lower() and (v:IsA("IntValue") or v:IsA("NumberValue")) then
				return (v :: any).Value
			end
		end
	end
	for attrName, value in pairs(p:GetAttributes()) do
		if attrName:lower() == name:lower() and type(value) == "number" then
			return value
		end
	end
	return nil
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
		-- Exact name, then case-insensitive Name/DisplayName, then a unique
		-- prefix — the same rules the palette's ArgumentTypes.FindPlayer uses.
		local name = selector.Value or selector.Raw
		local exact = Players:FindFirstChild(name)
		if exact and exact:IsA("Player") then
			return { exact :: Player }
		end
		local found = ArgumentTypes.FindPlayer(name, allPlayers())
		return if found then { found } else {}
	elseif kind == "Team" then
		local list = {}
		local wanted = (selector.Value or ""):lower()
		for _, p in ipairs(allPlayers()) do
			if p.Team and p.Team.Name:lower() == wanted then
				table.insert(list, p)
			end
		end
		return list
	elseif kind == "Role" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			local roles = PermissionSystem.GetRoles(p)
			-- @staff means "anyone who can open the panel"
			if selector.Value == "Staff" and PermissionSystem.Has(p, "panel.open") then
				table.insert(list, p)
				continue
			end
			for _, roleName in ipairs(roles) do
				if roleName:lower() == (selector.Value or ""):lower() then
					table.insert(list, p)
					break
				end
			end
		end
		return list
	elseif kind == "Group" or kind == "Rank" then
		local list = {}
		local wanted = (selector.Value or ""):lower()
		for _, p in ipairs(allPlayers()) do
			-- @rank: Sentinel ranks are the player's PermissionSystem roles.
			if kind == "Rank" then
				local matched = false
				for _, roleName in ipairs(PermissionSystem.GetRoles(p)) do
					if roleName:lower() == wanted then
						matched = true
						break
					end
				end
				if matched then
					table.insert(list, p)
					continue
				end
			end
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
		local raw = selector.Value or ""
		local name, op, wanted = raw:match("^([%w_]+)%s*([!~]?=)%s*(.+)$")
		name = name or raw
		local attrName = attributeAliases[name] or name
		local list = {}
		for _, p in ipairs(allPlayers()) do
			local value = p:GetAttribute(attrName)
			if value == nil then
				-- also look on the character (some games keep state there)
				local character = p.Character
				value = character and character:GetAttribute(attrName)
			end
			local hit
			if op then
				hit = TargetResolver._equals(value, wanted :: string)
				if op ~= "=" then
					hit = not hit
				end
			else
				hit = value ~= nil and value ~= false and value ~= 0 and value ~= ""
			end
			if hit then
				table.insert(list, p)
			end
		end
		return list
	elseif kind == "Property" then
		local list = {}
		for _, p in ipairs(allPlayers()) do
			local value = TargetResolver.GetProperty(p, selector.Value or "")
			if value and TargetResolver._compare(value, selector.Operator, selector.Comparand) then
				table.insert(list, p)
			end
		end
		return list
	end

	return {}
end

-- Attribute value vs typed text: numbers as numbers, true/false as booleans,
-- otherwise case-insensitive text.
function TargetResolver._equals(value: any, text: string): boolean
	if value == nil then
		return false
	end
	local lower = text:lower()
	if type(value) == "boolean" then
		return (lower == "true") == value and (lower == "true" or lower == "false")
	elseif type(value) == "number" then
		return tonumber(text) == value
	end
	return tostring(value):lower() == lower
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
	elseif operator == "!=" or operator == "~=" then
		return value ~= comparand
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
			local value = TargetResolver.GetProperty(p, filter.Property)
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

-- dryRun = true (palette previews): don't remember the result as the
-- executor's "last" targets.
function TargetResolver.Resolve(
	executor: Player,
	selectors: { TargetSelector },
	filters: { CommandFilter }?,
	dryRun: boolean?
): { Player }
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
	if not dryRun then
		TargetResolver.SetLast(executor, result)
	end
	return result
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastTargets[player.UserId] = nil
	joinedAt[player] = nil
end)

return TargetResolver
