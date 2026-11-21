--!strict
--[[
	Utility.lua

	Purpose:
		Server utility, building tools, broadcast, and observation commands
		from HD Admin & Nexus Admin:
		- /btools (alias /f3x): Give building tools
		- /clear (alias /cleardebris, /cleanup): Clear loose parts, hats, and debris
		- /message (alias /m): Broadcast a prominent server message
		- /hint (alias /h): Display a top-screen hint bar
		- /pm: Send a private popup message to target player
		- /view (alias /watch): Spectate target player
		- /unview (alias /unwatch): Stop spectating

	Dependencies:
		Types.lua, EventBus.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local TextFilterService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("TextFilterService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function getUtilityRemote(): RemoteEvent
	local existing = SentinelShared:FindFirstChild("UtilityRemote")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "UtilityRemote"
	remote.Parent = SentinelShared
	return remote
end

local utilityRemote = getUtilityRemote()

-- /btools [target]
CommandRegistry.Register({
	Name = "btools",
	Aliases = { "f3x" },
	Description = "Gives building tools to target player(s).",
	Usage = "/btools [target]",
	Permission = "utility.btools",
	Category = "Utility",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local targets = if #ctx.Targets > 0 then ctx.Targets else { ctx.Executor }
		local count = 0

		-- Search for existing F3X or Building Tools in ServerStorage or ReplicatedStorage
		local f3xTemplate = ServerStorage:FindFirstChild("Building Tools") or ReplicatedStorage:FindFirstChild("Building Tools")

		for _, target in ipairs(targets) do
			local backpack = target:FindFirstChildOfClass("Backpack")
			if backpack then
				if f3xTemplate and f3xTemplate:IsA("Tool") then
					f3xTemplate:Clone().Parent = backpack
				else
					-- Classic HopperBins: Move (1), Clone (3), Delete (4)
					local binTypes = {
						Enum.BinType.GameTool,
						Enum.BinType.Clone,
						Enum.BinType.Hammer,
					}
					for _, bType in ipairs(binTypes) do
						local bin = Instance.new("HopperBin")
						bin.BinType = bType
						bin.Parent = backpack
					end
				end
				count += 1
			end
		end

		return {
			Success = count > 0,
			Message = ("Gave btools to %d player(s)."):format(count),
		}
	end,
})

-- /clear
CommandRegistry.Register({
	Name = "clear",
	Aliases = { "cleardebris", "cleanup" },
	Description = "Cleans up loose unanchored parts, dropped hats, and debris in Workspace.",
	Usage = "/clear",
	Permission = "server.control",
	Category = "Server",
	Cooldown = 3,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(_ctx: CommandContext): CommandResult
		local removed = 0
		for _, child in ipairs(Workspace:GetChildren()) do
			-- Check for loose tools, hats, or standalone unanchored parts not belonging to a player
			if child:IsA("Tool") or child:IsA("Accessory") then
				child:Destroy()
				removed += 1
			elseif child:IsA("BasePart") and not child.Anchored and child.Name ~= "Terrain" then
				child:Destroy()
				removed += 1
			end
		end
		return {
			Success = true,
			Message = ("Cleaned up %d loose item(s) from Workspace."):format(removed),
		}
	end,
})

-- /message [text...]
CommandRegistry.Register({
	Name = "message",
	Aliases = { "msg" },
	Description = "Broadcasts a large prominent announcement to all players.",
	Usage = "/message text...",
	Permission = "server.announce",
	Category = "Server",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		-- Same as ";announce style=full ...": full-screen card with the
		-- sender's name and avatar, recorded in the announcement history.
		local AnnouncementService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("AnnouncementService"))
		local options, rest, err = AnnouncementService.ParseOptions(ctx.Arguments)
		if err then
			return { Success = false, Message = err }
		end
		options.Style = "full"
		local text = table.concat(rest, " ")
		if #text == 0 then
			return { Success = false, Message = "Message text is required." }
		end
		local ok, message = AnnouncementService.Send(ctx.Executor, text, "server", options)
		return { Success = ok, Message = if ok then "Broadcasted message." else message }
	end,
})

-- /hint [text...]
CommandRegistry.Register({
	Name = "hint",
	Aliases = { "h" },
	Description = "Displays a hint bar at the top of the screen for all players.",
	Usage = "/hint text...",
	Permission = "server.announce",
	Category = "Server",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local text = table.concat(ctx.Arguments, " ")
		if #text == 0 then
			return { Success = false, Message = "Hint text is required." }
		end
		text = TextFilterService.ForBroadcast(ctx.Executor.UserId, text) :: any
		if not text then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end

		utilityRemote:FireAllClients("Hint", ("[%s]: %s"):format(ctx.Executor.DisplayName, text))

		return {
			Success = true,
			Message = "Displayed hint to server.",
		}
	end,
})

-- /pm [target] [options] [message...]
-- Options (Systems/PrivateMessageService): kind= time= reply= ack= anon= style= title=
CommandRegistry.Register({
	Name = "pm",
	TargetProtection = false, -- harmless/read-only: allowed on higher ranks
	Aliases = { "privatemessage", "dm" },
	Description = "Sends a private message card to one or more players. They can reply unless reply=off.",
	Usage = "/pm target message...",
	ArgHints = {
		message = { Description = "Optional kind= time= reply= ack= anon= style= title= words, then the text" },
	},
	Examples = {
		"pm Alpha Please stop spawn killing.",
		"pm Alpha kind=warning ack=on Last warning before a kick.",
		"pm Alpha,Beta reply=off time=15 title=Event Meet at the arena!",
		"pm @team Red style=popup anon=on Your base is under attack.",
	},
	Permission = "utility.pm",
	Category = "Utility",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		if #ctx.Targets == 0 then
			return { Success = false, Message = "Target player not found." }
		end
		local PrivateMessageService = require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("PrivateMessageService"))
		local options, rest, err = PrivateMessageService.ParseOptions(ctx.Arguments)
		if err then
			return { Success = false, Message = err .. ". Options: kind=info|success|warning|error time=0|5-120 reply=on|off ack=on anon=on style=card|popup title=Word_Word" }
		end
		local text = table.concat(rest, " ")
		if #text == 0 then
			return { Success = false, Message = "Private message text is required." }
		end
		local sent, lastError = 0, nil
		for _, target in ipairs(ctx.Targets) do
			local ok, message = PrivateMessageService.Send(ctx.Executor, target, text, options)
			if ok then
				sent += 1
			else
				lastError = message
			end
		end
		if sent == 0 then
			return { Success = false, Message = lastError or "Could not send the message." }
		end
		local who = if sent == 1 and #ctx.Targets == 1 then ctx.Targets[1].DisplayName else ("%d players"):format(sent)
		local extras = {}
		if not options.Reply then
			table.insert(extras, "replies off")
		end
		if options.Ack then
			table.insert(extras, "read receipt on")
		end
		if options.Anonymous then
			table.insert(extras, "anonymous")
		end
		return {
			Success = true,
			Message = ("Sent private message to %s%s."):format(who, if #extras > 0 then " (" .. table.concat(extras, ", ") .. ")" else ""),
		}
	end,
})

-- /view [target]
CommandRegistry.Register({
	Name = "view",
	TargetProtection = false, -- harmless/read-only: allowed on higher ranks
	Aliases = { "watch", "spectate" },
	Description = "Spectates a target player's camera view.",
	Usage = "/view target",
	Permission = "utility.view",
	Category = "Utility",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	Execute = function(ctx: CommandContext): CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "Target player not found." }
		end

		local targetHum = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
		if not targetHum then
			return { Success = false, Message = target.DisplayName .. " has no spawned character." }
		end

		utilityRemote:FireClient(ctx.Executor, "View", targetHum)

		return {
			Success = true,
			Message = ("Now viewing %s. Use /unview to return."):format(target.DisplayName),
		}
	end,
})

-- /unview
CommandRegistry.Register({
	Name = "unview",
	Aliases = { "unwatch", "unspectate" },
	Description = "Restores your camera back to your own character.",
	Usage = "/unview",
	Permission = "utility.view",
	Category = "Utility",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local myHum = ctx.Executor.Character and ctx.Executor.Character:FindFirstChildOfClass("Humanoid")
		if myHum then
			utilityRemote:FireClient(ctx.Executor, "View", myHum)
		else
			utilityRemote:FireClient(ctx.Executor, "Unview")
		end

		return {
			Success = true,
			Message = "Returned camera to your character.",
		}
	end,
})

return true

