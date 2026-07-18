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
-- IMPORTANT: Roblox places can run on either the legacy Chat system or the
-- newer TextChatService, and there is no reliable way to know which one a
-- given place uses without checking at runtime — assuming wrong means chat
-- commands silently never fire. So: detect TextChatService.TextChannels
-- with FindFirstChild (non-yielding). If it exists, use the modern,
-- reliable TextChannel.MessageReceived. If it doesn't, fall back to
-- Players.PlayerChatted, which — despite being an unreliable bridge under
-- TextChatService — is the correct, direct, first-party event under
-- legacy chat and works fine there.
--
-- The trigger is ";" rather than "/", since Roblox's default TextChatService
-- reserves several "/"-prefixed commands for itself (notably "/w" for
-- whisper).
-- ---------------------------------------------------------------------------
local COMMAND_PREFIX = ";"
local TextChatService = game:GetService("TextChatService")

local function handleCommandText(player: Player, text: string)
	if text:sub(1, 1) ~= COMMAND_PREFIX then
		return
	end
	local results = CommandProcessor.Process(player, text:sub(2))
	for _, result in ipairs(results) do
		if result.Message then
			-- Placeholder feedback channel; Phase 7 UI replaces this
			-- with a proper notification system.
			print(("[Sentinel -> %s] %s"):format(player.Name, result.Message))
		end
	end
end

-- IMPORTANT: TextChatService creates its default channels asynchronously,
-- a moment after server start — not synchronously at t=0. An instant check
-- can wrongly conclude "legacy chat" on a place that's genuinely using
-- TextChatService, simply because it checked too early. WaitForChild with
-- a bounded timeout gives it a real chance to appear, while a truly
-- legacy-chat place still falls back cleanly after the timeout instead of
-- hanging forever.
local textChannelsFolder = TextChatService:WaitForChild("TextChannels", 10)

if textChannelsFolder then
	print("[Sentinel] TextChatService detected — routing commands via TextChannel.MessageReceived.")

	local function attachCommandListener(channel: TextChannel)
		channel.MessageReceived:Connect(function(message: TextChatMessage)
			local speaker = message.TextSource
			if not speaker then
				return
			end
			local player = Players:GetPlayerByUserId(speaker.UserId)
			if player then
				handleCommandText(player, message.Text)
			end
		end)
	end

	for _, channel in ipairs(textChannelsFolder:GetChildren()) do
		if channel:IsA("TextChannel") then
			attachCommandListener(channel)
		end
	end
	textChannelsFolder.ChildAdded:Connect(function(child: Instance)
		if child:IsA("TextChannel") then
			attachCommandListener(child)
		end
	end)
else
	print("[Sentinel] Legacy chat detected — routing commands via Players.PlayerChatted.")

	Players.PlayerAdded:Connect(function(player: Player)
		player.Chatted:Connect(function(message: string)
			handleCommandText(player, message)
		end)
	end)
end

print("[Sentinel] Core Engine + Command Framework + Moderator Toolkit loaded.")
