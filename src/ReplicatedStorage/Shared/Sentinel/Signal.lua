--!strict
--[[
	Signal.lua

	Purpose:
		Minimal, allocation-conscious pub/sub primitive used internally by
		EventBus. Not exposed directly to command/plugin authors — they go
		through EventBus so every subscription is centrally tracked and can
		be audited / torn down safely.

	Responsibilities:
		- Connect / Disconnect listeners
		- Fire listeners synchronously in registration order
		- Guard against a listener error breaking other listeners

	Dependencies:
		None.

	Public API:
		Signal.new(): Signal
		Signal:Connect(fn): Connection
		Signal:Fire(...: any): ()
		Signal:DisconnectAll(): ()

	Example usage:
		local sig = Signal.new()
		local conn = sig:Connect(function(msg) print(msg) end)
		sig:Fire("hello")
		conn:Disconnect()
--]]

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	local self = setmetatable({
		_listeners = {} :: { [number]: (...any) -> () },
		_nextId = 1,
	}, Signal)
	return (self :: any) :: Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local self_ = self :: any
	local id = self_._nextId
	self_._nextId += 1
	self_._listeners[id] = fn

	local connection = {
		Connected = true,
	}

	function connection:Disconnect()
		if not self.Connected then
			return
		end
		self.Connected = false
		self_._listeners[id] = nil
	end

	return (connection :: any) :: Connection
end

function Signal:Fire(...: any)
	local self_ = self :: any
	-- Snapshot to avoid mutation-during-iteration issues if a listener
	-- connects/disconnects other listeners mid-fire.
	local snapshot = {}
	for id, fn in pairs(self_._listeners) do
		snapshot[id] = fn
	end

	for _, fn in pairs(snapshot) do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn(("[Sentinel.Signal] listener error: %s"):format(tostring(err)))
		end
	end
end

function Signal:DisconnectAll()
	local self_ = self :: any
	self_._listeners = {}
end

return Signal
