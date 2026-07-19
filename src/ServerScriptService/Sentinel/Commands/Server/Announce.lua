--!strict
--[[
	Announce.lua

	Purpose:
		Registers "/announce" and "/countdown". Two separate RemoteEvents
		drive two separate client UIs: a banner across the top of the
		screen for /announce, and a large countdown overlay for /countdown
		(rather than reusing the banner for both, since a countdown needs
		its own persistent, updating widget instead of a message that
		flashes and disappears).

	Responsibilities:
		- Lazily create ReplicatedStorage.Shared.Sentinel.AnnounceRemote
		  and .CountdownRemote
		- Fire AnnounceRemote with (text, color) for /announce
		- Fire CountdownRemote with (phase, label, remaining, total) for
		  /countdown, where phase is "tick" | "done"

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = SentinelShared:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = SentinelShared
	return remote
end

local announceRemote = getOrCreateRemote("AnnounceRemote")
local countdownRemote = getOrCreateRemote("CountdownRemote")

local function broadcast(text: string, color: Color3?)
	announceRemote:FireAllClients(text, color or Color3.fromRGB(255, 215, 0))
end

CommandRegistry.Register({
	Name = "announce",
	Aliases = { "bc", "broadcast" },
	Description = "Shows a banner announcement on every player's screen.",
	Usage = "/announce message",
	Permission = "server.announce",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local text = table.concat(ctx.Arguments, " ")
		if text == "" then
			return { Success = false, Message = "Usage: /announce message" }
		end
		broadcast(text)
		return { Success = true, Message = "Announcement sent." }
	end,
})

CommandRegistry.Register({
	Name = "countdown",
	Aliases = {},
	Description = "Shows a countdown overlay on every player's screen.",
	Usage = "/countdown seconds [label]",
	Permission = "server.announce",
	Category = "Server",
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local seconds = tonumber(ctx.Arguments[1])
		if not seconds or seconds <= 0 or seconds > 300 then
			return { Success = false, Message = "Usage: /countdown seconds [label] (max 300)" }
		end
		local label = if #ctx.Arguments > 1 then table.concat(ctx.Arguments, " ", 2) else "Starting"

		task.spawn(function()
			for remaining = seconds, 1, -1 do
				countdownRemote:FireAllClients("tick", label, remaining, seconds)
				task.wait(1)
			end
			countdownRemote:FireAllClients("done", label, 0, seconds)
		end)

		return { Success = true, Message = ("Countdown started (%ds)."):format(seconds) }
	end,
})

return true
