--!strict
--[[
	Init.server.lua

	Purpose:
		Sentinel's server entry point. Loads Core systems, defines the
		starter role hierarchy, requires every command module (which
		self-register via CommandRegistry.Register), checks bans on join,
		and hooks Players.PlayerChatted so ";command" text works with no
		client-side dependency (the future command-palette UI in Phase 7
		will call CommandProcessor.Process directly instead of going
		through chat).

	Responsibilities:
		- Require Core modules in dependency order
		- Define default roles (Owner / Admin / Moderator)
		- Require every Commands/** module so they register themselves
		- Enforce bans on PlayerAdded
		- Route chat messages starting with ";" into CommandProcessor

	Dependencies:
		Everything under Core and Commands.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- IMPORTANT: this script's own Instance *is* the Sentinel container (it sits
-- inside ServerScriptService.Sentinel as that folder's entry point), so we
-- reference `script` here, not `script.Parent` (which is ServerScriptService).
local Sentinel = script
local Core = Sentinel:WaitForChild("Core")
local Commands = Sentinel:WaitForChild("Commands")
local Systems = Sentinel:WaitForChild("Systems")

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
	"moderation.notes",
	"player.freeze",
	"player.jail",
})

PermissionSystem.DefineRole("Admin", {
	"moderation.*",
	"player.*",
	"economy.*",
	"inventory.*",
	"server.*",
	"environment.*",
	-- Developer Suite: only the READ-ONLY diagnostic nodes are granted to
	-- Admin by default. "developer.datastore.write" and "developer.execute"
	-- are deliberately excluded — they can corrupt persisted data or run
	-- arbitrary server code, so only Owner ("*") has them out of the box.
	"developer.stats",
	"developer.console",
	"developer.remotemonitor",
	"developer.datastore.read",
}, { "Moderator" })

PermissionSystem.DefineRole("Owner", {
	"*",
}, { "Admin" })

-- ---------------------------------------------------------------------------
-- Load every Systems/** module first (PunishmentService, ChatModerationService,
-- etc.) so their startup hooks (PlayerAdded connections, TextChannel gating)
-- are in place before any command that depends on them can run.
-- ---------------------------------------------------------------------------
for _, child in ipairs(Systems:GetChildren()) do
	if child:IsA("ModuleScript") then
		require(child)
	end
end

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
--
-- IMPORTANT: TextChannel.MessageReceived is a CLIENT-ONLY event (confirmed
-- by Roblox's own documentation: "This event is only fired on the
-- client.") — connecting to it from a server Script silently never fires.
-- An earlier version of this file tried exactly that. Players.PlayerChatted
-- is the correct server-side entry point instead: it fires on the server
-- under both the legacy Chat system and TextChatService (TextChatService
-- bridges to it internally for backward compatibility), so it works
-- reliably regardless of which chat system the place uses — no runtime
-- detection needed.
--
-- The trigger is ";" rather than "/", since Roblox's default TextChatService
-- reserves several "/"-prefixed commands for itself (notably "/w" for
-- whisper).
-- ---------------------------------------------------------------------------
local COMMAND_PREFIX = ";"

-- Both chat-issued and UI-issued commands now surface through the exact
-- same remote, so Phase 7D's Notification Center (toasts + persistent
-- log) shows feedback regardless of how the command was actually typed.
local commandResultRemote = ReplicatedStorage:WaitForChild("Shared")
	:WaitForChild("Sentinel")
	:WaitForChild("CommandResultRemote") :: RemoteEvent

local function handleCommandText(player: Player, text: string)
	if text:sub(1, 1) ~= COMMAND_PREFIX then
		return
	end
	local results = CommandProcessor.Process(player, text:sub(2))
	commandResultRemote:FireClient(player, results)
	for _, result in ipairs(results) do
		if result.Message then
			print(("[Sentinel -> %s] %s"):format(player.Name, result.Message))
		end
	end
end

local function onPlayerAddedForChat(player: Player)
	player.Chatted:Connect(function(message: string)
		handleCommandText(player, message)
	end)
end

Players.PlayerAdded:Connect(onPlayerAddedForChat)

-- Handle players already in the game when this script starts (e.g. if
-- Sentinel is ever hot-reloaded, or a future architecture defers its load).
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAddedForChat(player)
end

print("[Sentinel] Core Engine + Command Framework + Moderator Toolkit loaded.")
