--!strict
--[[
	Init.server.lua

	Purpose:
		Sentinel's server entry point. Loads Core systems, defines the
		starter role hierarchy, requires every command module (which
		self-register via CommandRegistry.Register), checks bans on join,
		and hooks Players.PlayerChatted so "/command" text works with no
		client-side dependency (the future command-palette UI in Phase 7
		will call CommandProcessor.Process directly instead of going
		through chat).

	Responsibilities:
		- Require Core modules in dependency order
		- Define default roles (Owner / Admin / Moderator)
		- Require every Commands/** module so they register themselves
		- Enforce bans on PlayerAdded
		- Route chat messages starting with "/" into CommandProcessor

	Dependencies:
		Everything under Core and Commands.
--]]

local Players = game:GetService("Players")

-- IMPORTANT: this script's own Instance *is* the Sentinel container (it sits
-- inside ServerScriptService.Sentinel as that folder's entry point), so we
-- reference `script` here, not `script.Parent` (which is ServerScriptService).
local Sentinel = script
local Core = Sentinel:WaitForChild("Core")
local Commands = Sentinel:WaitForChild("Commands")

local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))

-- ---------------------------------------------------------------------------
-- Starter role hierarchy. Replace/extend via your own onboarding tooling;
-- this is intentionally minimal so the framework is usable out of the box.
-- ---------------------------------------------------------------------------
PermissionSystem.DefineRole("Moderator", {
	"moderation.kick",
	"moderation.mute",
	"moderation.warn",
})

PermissionSystem.DefineRole("Admin", {
	"moderation.*",
	"player.*",
}, { "Moderator" })

PermissionSystem.DefineRole("Owner", {
	"*",
}, { "Admin" })

-- ---------------------------------------------------------------------------
-- Load every command module so it registers itself. New commands only need
-- to be dropped into Commands/<Category>/ — nothing here needs to change.
-- ---------------------------------------------------------------------------
local function loadCommandsRecursive(root: Instance)
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("ModuleScript") then
			require(child)
		elseif child:IsA("Folder") then
			loadCommandsRecursive(child)
		end
	end
end

loadCommandsRecursive(Commands)

-- ---------------------------------------------------------------------------
-- Ban enforcement on join. Uses Ban.lua's exported GetActiveBan so the ban
-- store has exactly one owner.
-- ---------------------------------------------------------------------------
local BanCommand = require(Commands:WaitForChild("Moderation"):WaitForChild("Ban"))

Players.PlayerAdded:Connect(function(player: Player)
	local activeBan = BanCommand.GetActiveBan(player.UserId)
	if activeBan then
		local expiryText = if activeBan.ExpiresAt == math.huge
			then "permanently"
			else ("until %s"):format(os.date("!%Y-%m-%d %H:%M UTC", activeBan.ExpiresAt))
		player:Kick(("You are banned %s. Reason: %s"):format(expiryText, activeBan.Reason))
	end
end)

-- ---------------------------------------------------------------------------
-- Chat-based invocation. This is a bridge for launch day; Phase 7 replaces
-- the primary UX with a dockable command palette that calls
-- CommandProcessor.Process directly (no chat round-trip needed).
-- ---------------------------------------------------------------------------
Players.PlayerAdded:Connect(function(player: Player)
	player.Chatted:Connect(function(message: string)
		if message:sub(1, 1) ~= "/" then
			return
		end
		local results = CommandProcessor.Process(player, message:sub(2))
		for _, result in ipairs(results) do
			if result.Message then
				-- Placeholder feedback channel; Phase 7 UI replaces this
				-- with a proper notification system.
				print(("[Sentinel -> %s] %s"):format(player.Name, result.Message))
			end
		end
	end)
end)

print("[Sentinel] Core Engine + Command Framework loaded.")
