--!strict
--[[
	EventBus.lua

	Purpose:
		Decouples Sentinel's internal systems. Instead of Commands requiring
		Logger, PermissionSystem, Analytics, etc. directly (which invites
		circular dependencies as the plugin count grows), systems publish
		named events and subscribe to the ones they care about.

	Responsibilities:
		- Provide a single global namespace of named Signals
		- Lazily create a Signal the first time a topic is used
		- Allow safe teardown for plugin unloads

	Dependencies:
		Signal.lua

	Public API:
		EventBus.Subscribe(topic: string, fn): Connection
		EventBus.Publish(topic: string, ...): ()
		EventBus.Clear(topic: string): ()

	Example usage:
		EventBus.Subscribe("Command.AfterExecute", function(ctx, result)
			-- react to every command execution, e.g. for analytics
		end)

		EventBus.Publish("Command.AfterExecute", ctx, result)

	Well-known topics (by convention, not enforced):
		"Command.BeforeExecute"
		"Command.AfterExecute"
		"Command.Denied"
		"Permission.Changed"
		"Player.Banned"
		"Player.Muted"
		"Plugin.Loaded"
		"Plugin.Unloaded"
--]]

local Signal = require(script.Parent.Signal)

type Connection = Signal.Connection

local EventBus = {}

local topics: { [string]: Signal.Signal } = {}

local function getOrCreate(topic: string): Signal.Signal
	local existing = topics[topic]
	if existing then
		return existing
	end
	local created = Signal.new()
	topics[topic] = created
	return created
end

function EventBus.Subscribe(topic: string, fn: (...any) -> ()): Connection
	return getOrCreate(topic):Connect(fn)
end

function EventBus.Publish(topic: string, ...: any)
	local signal = topics[topic]
	if not signal then
		return -- no listeners registered yet; not an error
	end
	signal:Fire(...)
end

function EventBus.Clear(topic: string)
	local signal = topics[topic]
	if signal then
		signal:DisconnectAll()
	end
end

return EventBus
