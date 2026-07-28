--!strict
--[[
	PermissionSystem.lua

	Purpose:
		Resolves whether a player may execute a given permission node
		(e.g. "moderation.ban", "player.fly"). Roles are collections of
		nodes (with wildcard support: "moderation.*"). No admin level is
		ever hardcoded into a command — commands only ever ask
		PermissionSystem:Has(player, node).

	Responsibilities:
		- Store Role -> { nodes } assignments
		- Store Player -> Role assignments (supports multiple roles/player)
		- Resolve wildcard nodes ("moderation.*" grants "moderation.ban")
		- Support temporary permission grants (Phase 9 staff management hook)

	Dependencies:
		EventBus.lua (publishes "Permission.Changed")

	Public API:
		PermissionSystem.DefineRole(roleName, nodes: {string}, inherits: {string}?)
		PermissionSystem.AssignRole(player, roleName)
		PermissionSystem.RevokeRole(player, roleName)
		PermissionSystem.Has(player, node): boolean
		PermissionSystem.GrantTemporary(player, node, seconds)

	Example usage:
		PermissionSystem.DefineRole("Moderator", {"moderation.kick", "moderation.mute"})
		PermissionSystem.DefineRole("Admin", {"moderation.*", "player.*"}, {"Moderator"})
		PermissionSystem.AssignRole(somePlayer, "Admin")
		PermissionSystem.Has(somePlayer, "moderation.ban") --> true
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local PermissionSystem = {}

type RoleDefinition = {
	Nodes: { string },
	Inherits: { string },
}

local roles: { [string]: RoleDefinition } = {}
local playerRoles: { [number]: { [string]: boolean } } = {}
local temporaryGrants: { [number]: { [string]: number } } = {} -- node -> expiry unix time

function PermissionSystem.DefineRole(roleName: string, nodes: { string }, inherits: { string }?)
	roles[roleName] = {
		Nodes = nodes,
		Inherits = inherits or {},
	}
end

function PermissionSystem.AssignRole(player: Player, roleName: string)
	assert(roles[roleName], ("[Sentinel.PermissionSystem] unknown role '%s'"):format(roleName))
	local set = playerRoles[player.UserId]
	if not set then
		set = {}
		playerRoles[player.UserId] = set
	end
	set[roleName] = true
	EventBus.Publish("Permission.Changed", player, roleName, "Assigned")
end

function PermissionSystem.RevokeRole(player: Player, roleName: string)
	local set = playerRoles[player.UserId]
	if set then
		set[roleName] = nil
	end
	EventBus.Publish("Permission.Changed", player, roleName, "Revoked")
end

function PermissionSystem.GrantTemporary(player: Player, node: string, seconds: number)
	local set = temporaryGrants[player.UserId]
	if not set then
		set = {}
		temporaryGrants[player.UserId] = set
	end
	set[node] = os.time() + seconds
end

local function nodeMatches(granted: string, requested: string): boolean
	if granted == requested then
		return true
	end
	-- wildcard: "moderation.*" matches "moderation.ban", "moderation.ban.temp", etc.
	if granted:sub(-2) == ".*" then
		local prefix = granted:sub(1, -3)
		return requested == prefix or requested:sub(1, #prefix + 1) == prefix .. "."
	end
	if granted == "*" then
		return true
	end
	return false
end

local function roleHasNode(roleName: string, requested: string, visited: { [string]: boolean }): boolean
	if visited[roleName] then
		return false -- guard against inheritance cycles
	end
	visited[roleName] = true

	local def = roles[roleName]
	if not def then
		return false
	end

	for _, granted in ipairs(def.Nodes) do
		if nodeMatches(granted, requested) then
			return true
		end
	end

	for _, parentRole in ipairs(def.Inherits) do
		if roleHasNode(parentRole, requested, visited) then
			return true
		end
	end

	return false
end

function PermissionSystem.Has(player: Player, node: string): boolean
	-- Temporary grants first (cheap check, self-expiring).
	local temp = temporaryGrants[player.UserId]
	if temp and temp[node] then
		if temp[node] > os.time() then
			return true
		end
		temp[node] = nil
	end

	local assigned = playerRoles[player.UserId]
	if not assigned then
		return false
	end

	for roleName in pairs(assigned) do
		if roleHasNode(roleName, node, {}) then
			return true
		end
	end

	return false
end

function PermissionSystem.GetRoles(player: Player): { string }
	local assigned = playerRoles[player.UserId]
	if not assigned then
		return {}
	end
	local list = {}
	for roleName in pairs(assigned) do
		table.insert(list, roleName)
	end
	return list
end

-- Read-only snapshot of every DEFINED role (not a specific player's
-- roles) — for the Settings page's Permissions viewer (Phase 7E). Returns
-- copies, not the live internal tables, so a UI holding onto this can't
-- accidentally mutate role definitions.
function PermissionSystem.GetAllRoleDefinitions(): { [string]: { Nodes: { string }, Inherits: { string } } }
	local snapshot = {}
	for roleName, def in pairs(roles) do
		snapshot[roleName] = {
			Nodes = table.clone(def.Nodes),
			Inherits = table.clone(def.Inherits),
		}
	end
	return snapshot
end

game:GetService("Players").PlayerRemoving:Connect(function(player: Player)
	playerRoles[player.UserId] = nil
	temporaryGrants[player.UserId] = nil
end)

return PermissionSystem
