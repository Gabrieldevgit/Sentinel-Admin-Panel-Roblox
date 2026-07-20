--!strict
--[[
	UIBridge.lua

	Purpose:
		The ONLY place Sentinel's future GUI (Phase 7) talks to the server.
		Exposes exactly three remotes, all deliberately narrow in scope:
		- GetCommandListRemote (RemoteFunction): read-only command metadata
		  for the command palette's autocomplete/docs (no secrets exposed —
		  just Name/Aliases/Description/Usage/Permission/Category).
		- ExecuteCommandRemote (RemoteEvent, client -> server): the SAME
		  CommandProcessor.Process path the chat hook uses. The player is
		  taken from the RemoteEvent's built-in server-side parameter, never
		  trusted from client-sent data, so this carries no more risk than
		  typing the command in chat — permission checks, cooldowns, and
		  logging in CommandRegistry.Dispatch all still apply unchanged.
		- CommandResultRemote (RemoteEvent, server -> client): sends the
		  result of an executed command back to the client that ran it.
		- GetServerStatsRemote (RemoteFunction): thin wrapper around
		  DeveloperService.GetServerStats() for the UI's status bar.

	Responsibilities:
		- Create these remotes once under ReplicatedStorage.Shared.Sentinel
		- Wire ExecuteCommandRemote through CommandProcessor exactly like
		  the chat hook does

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua, Parser/CommandProcessor.lua (Core)
		DeveloperService.lua (Systems)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sentinel = script.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local CommandProcessor = require(Sentinel:WaitForChild("Core"):WaitForChild("Parser"):WaitForChild("CommandProcessor"))
local DeveloperService = require(Sentinel:WaitForChild("Systems"):WaitForChild("DeveloperService"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local function getOrCreate(name: string, className: string): Instance
	local existing = SentinelShared:FindFirstChild(name)
	if existing then
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = SentinelShared
	return instance
end

local getCommandListRemote = getOrCreate("GetCommandListRemote", "RemoteFunction") :: RemoteFunction
local executeCommandRemote = getOrCreate("ExecuteCommandRemote", "RemoteEvent") :: RemoteEvent
local commandResultRemote = getOrCreate("CommandResultRemote", "RemoteEvent") :: RemoteEvent
local getServerStatsRemote = getOrCreate("GetServerStatsRemote", "RemoteFunction") :: RemoteFunction

function getCommandListRemote.OnServerInvoke(_player: Player)
	local list = {}
	for _, def in ipairs(CommandRegistry.All()) do
		table.insert(list, {
			Name = def.Name,
			Aliases = def.Aliases,
			Description = def.Description,
			Usage = def.Usage,
			Permission = def.Permission,
			Category = def.Category,
		})
	end
	return list
end

function getServerStatsRemote.OnServerInvoke(_player: Player)
	return DeveloperService.GetServerStats()
end

executeCommandRemote.OnServerEvent:Connect(function(player: Player, rawText: string)
	if type(rawText) ~= "string" or #rawText == 0 or #rawText > 500 then
		return
	end
	local results = CommandProcessor.Process(player, rawText)
	commandResultRemote:FireClient(player, results)
end)

return true
