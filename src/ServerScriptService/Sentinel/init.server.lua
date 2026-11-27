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
		- Load RankService (roles + assignments) before everything else
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

local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))

-- ---------------------------------------------------------------------------
-- Ranks and permissions are owned by Systems/RankService (persisted in the
-- Sentinel_Ranks_v1 DataStore, default templates Owner/Developer/SuperAdmin/
-- Admin/Moderator/VIP). It is required first so roles exist before anything
-- else loads; the game creator always gets Owner.
-- ---------------------------------------------------------------------------
local RankServiceModule = require(Systems:WaitForChild("RankService"))
-- W22: the join gate (lock / maintenance / whitelist / cap / private server)
-- waits until a joiner's ranks are resolved so group-ranked staff get in.
require(Systems:WaitForChild("ServerStateService")).SetRankResolvedCheck(RankServiceModule.IsResolved)

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

-- Sentinel AntiCheat (Systems/AntiCheat is a folder, so the loop above
-- skips it). Started in a pcall: an anti-cheat failure never stops Sentinel.
do
	local okStart, err = pcall(function()
		require(Systems:WaitForChild("AntiCheat"):WaitForChild("AntiCheatService")).Start()
	end)
	if not okStart then
		warn("[Sentinel] AntiCheat failed to start: " .. tostring(err))
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

-- W14: banned players get the ban / appeal screen first (Systems/
-- PlayerFormsService.HoldBanned), then are kicked. ;config appeals off
-- restores the instant kick.
local PlayerFormsService = require(Systems:WaitForChild("PlayerFormsService"))

local function enforceBan(player: Player)
	local activeBan = BanCommand.GetActiveBan(player.UserId)
	if activeBan then
		PlayerFormsService.HoldBanned(player, activeBan)
	end
end
Players.PlayerAdded:Connect(enforceBan)
-- Players who joined while the modules above were loading (always the
-- first player in Studio; possible on a live server too) were missed by
-- PlayerAdded: check them now.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(enforceBan, player)
end

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
-- Prefixes are configurable in game (;prefix, W07) via Systems/ConfigService.
local ConfigService = require(Systems:WaitForChild("ConfigService"))
local CommandLibraryService = require(Systems:WaitForChild("CommandLibraryService"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))

-- Both chat-issued and UI-issued commands now surface through the exact
-- same remote, so Phase 7D's Notification Center (toasts + persistent
-- log) shows feedback regardless of how the command was actually typed.
local commandResultRemote = ReplicatedStorage:WaitForChild("Shared")
	:WaitForChild("Sentinel")
	:WaitForChild("CommandResultRemote") :: RemoteEvent

local RateLimiter = require(Core:WaitForChild("RateLimiter"))
local chatCommandLimiter = RateLimiter.new("ChatCommands", 6, 2)

local function handleCommandText(player: Player, text: string)
	if #text > 500 or not ConfigService.MatchPrefix(text) or player:GetAttribute("SentinelBanHold") then
		return
	end
	local allowed, firstDrop = chatCommandLimiter:Allow(player)
	if not allowed then
		if firstDrop then
			commandResultRemote:FireClient(player, { { Success = false, Message = "Slow down — too many commands." } })
		end
		return
	end
	local results = CommandProcessor.Process(player, text:sub(2), { Source = "chat" })
	if PermissionSystem.Has(player, "panel.open") and results[1] and not (results[1].Message or ""):find("^Unknown command") then
		CommandLibraryService.NoteRecent(player, text:sub(2))
	end
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
