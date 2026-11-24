--!strict
--[[
	CrossServerNode.lua (cross-server, W17)

	Purpose:
		The cross-server protocol, with no Roblox service calls in it, so the
		whole thing can be unit-tested with several nodes on a fake bus
		(Tests/CrossServer.spec). Systems/CrossServerService creates the one
		real node per server and plugs MessagingService into it.

	What a node does:
		- Sends a message to every server (broadcast) or to one server
		  (direct), as a compact JSON envelope that fits MessagingService's
		  1 kB limit.
		- Runs the handler registered for the message kind and answers with
		  an acknowledgement (ok, affected count, short message).
		- Tracks every message it sent as an Operation: which servers were
		  expected to answer, which did, and the final status
		  (complete / partial / no response / failed).
		- Drops duplicates, expired messages and malformed data.

	Transport (given to Node.new):
		Publish(topic, text) -> (ok, err?)
		Subscribe(topic, callback(text))

	Public API:
		Node.new({ Id, Transport, Now?, Delay?, Spawn?, AckTimeout?,
		           ExpectedServers? }) -> node
		node:Start()
		node:Handle(kind, fn(payload, envelope) -> (ok, count?, message?))
		node:Send(kind, payload, { To?, Actor?, Label?, NoAck?, Expect? })
			-> (operation?, err?)
		node:GetOperations(limit?) -> { operation snapshot }
		node:GetOperation(id) -> operation snapshot?
		node:OnOperationChanged(fn(snapshot)) -> disconnect()
		Node.Summarize(records, now, staleAfter) -> (servers, totals)
		Node.FindPlayers(servers, query, limit?) -> { match }
		Node.Health(record, now) -> "good" | "fair" | "poor"
--]]

local HttpService = game:GetService("HttpService")

local Node = {}
Node.__index = Node

Node.TOPIC_ALL = "SentinelXS1"
Node.MAX_BYTES = 900 -- MessagingService allows 1 kB per message
Node.MESSAGE_TTL = 60 -- seconds; older messages are ignored
Node.MAX_OPERATIONS = 60

export type Actor = { UserId: number, Name: string, Priority: number? }

export type Ack = { Server: string, Ok: boolean, Count: number, Message: string?, At: number }

export type Operation = {
	Id: string,
	Kind: string,
	Label: string,
	ActorName: string?,
	ActorId: number?,
	To: string?,
	StartedAt: number,
	Expected: { string },
	Acks: { Ack },
	Affected: number,
	Status: string, -- pending | complete | partial | no response | failed | sent
	Error: string?,
	FinishedAt: number?,
}

function Node.DirectTopic(serverId: string): string
	return Node.TOPIC_ALL .. "." .. serverId
end

local function shortId(): string
	return HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 10):lower()
end

function Node.new(options: { [string]: any })
	assert(type(options.Id) == "string" and #options.Id > 0, "Node needs an Id")
	assert(type(options.Transport) == "table", "Node needs a Transport")
	local self = setmetatable({}, Node)
	self.Id = options.Id
	self.Transport = options.Transport
	self.Now = options.Now or os.time
	self.Delay = options.Delay or task.delay
	self.Spawn = options.Spawn or task.spawn
	self.AckTimeout = options.AckTimeout or 8
	self.ExpectedServers = options.ExpectedServers or function(): { string }
		return {}
	end
	self.Handlers = {} :: { [string]: (any, any) -> (boolean, number?, string?) }
	self.Operations = {} :: { Operation } -- newest first
	self.OpsById = {} :: { [string]: Operation }
	self.Seen = {} :: { [string]: number }
	self.Listeners = {} :: { (any) -> () }
	self.Stats = { Sent = 0, Received = 0, Handled = 0, Dropped = 0, Errors = 0 }
	self.Started = false
	return self
end

local function snapshot(op: Operation): any
	local acks = {}
	for _, ack in ipairs(op.Acks) do
		table.insert(acks, { Server = ack.Server, Ok = ack.Ok, Count = ack.Count, Message = ack.Message, At = ack.At })
	end
	return {
		Id = op.Id,
		Kind = op.Kind,
		Label = op.Label,
		ActorName = op.ActorName,
		ActorId = op.ActorId,
		To = op.To,
		StartedAt = op.StartedAt,
		FinishedAt = op.FinishedAt,
		Expected = table.clone(op.Expected),
		Acks = acks,
		Affected = op.Affected,
		Status = op.Status,
		Error = op.Error,
	}
end

function Node:_changed(op: Operation)
	local snap = snapshot(op)
	for _, listener in ipairs(self.Listeners) do
		local ok, err = pcall(listener, snap)
		if not ok then
			warn("[Sentinel.CrossServerNode] operation listener errored: " .. tostring(err))
		end
	end
end

function Node:OnOperationChanged(fn: (any) -> ()): () -> ()
	table.insert(self.Listeners, fn)
	return function()
		local i = table.find(self.Listeners, fn)
		if i then
			table.remove(self.Listeners, i)
		end
	end
end

function Node:Handle(kind: string, fn: (any, any) -> (boolean, number?, string?))
	self.Handlers[kind] = fn
end

function Node:Start()
	if self.Started then
		return
	end
	self.Started = true
	local function receive(text: any)
		self:_receive(text)
	end
	self.Transport.Subscribe(Node.TOPIC_ALL, receive)
	self.Transport.Subscribe(Node.DirectTopic(self.Id), receive)
end

-- Every expected server answered, or the timeout passed: settle the status.
function Node:_finalize(op: Operation, timedOut: boolean)
	if op.Status ~= "pending" then
		return
	end
	local answered: { [string]: boolean } = {}
	for _, ack in ipairs(op.Acks) do
		answered[ack.Server] = true
	end
	local missing = 0
	for _, id in ipairs(op.Expected) do
		if not answered[id] then
			missing += 1
		end
	end
	if missing > 0 and not timedOut then
		return -- still waiting
	end
	if #op.Acks == 0 then
		op.Status = "no response"
	elseif missing > 0 then
		op.Status = "partial"
	else
		op.Status = "complete"
	end
	op.FinishedAt = self.Now()
	self:_changed(op)
end

function Node:_recordAck(opId: string, ack: Ack)
	local op = self.OpsById[opId]
	if not op then
		return
	end
	for _, existing in ipairs(op.Acks) do
		if existing.Server == ack.Server then
			return -- one answer per server
		end
	end
	table.insert(op.Acks, ack)
	op.Affected += ack.Count
	if op.Status == "pending" then
		self:_changed(op)
		self:_finalize(op, false)
	elseif op.Status == "partial" or op.Status == "no response" then
		-- a late answer still counts
		local answered: { [string]: boolean } = {}
		for _, a in ipairs(op.Acks) do
			answered[a.Server] = true
		end
		local missing = 0
		for _, id in ipairs(op.Expected) do
			if not answered[id] then
				missing += 1
			end
		end
		op.Status = if missing == 0 then "complete" else "partial"
		self:_changed(op)
	end
end

function Node:_handle(envelope: any)
	local handler = self.Handlers[envelope.k]
	local ok, count, message = false, 0, "unsupported action"
	if handler then
		local ran, a, b, c = pcall(handler, envelope.d or {}, envelope)
		if ran then
			ok, count, message = a == true, tonumber(b) or 0, if type(c) == "string" then c else nil
		else
			self.Stats.Errors += 1
			warn(("[Sentinel.CrossServerNode] handler '%s' errored: %s"):format(tostring(envelope.k), tostring(a)))
			ok, count, message = false, 0, "handler error"
		end
		self.Stats.Handled += 1
	end
	if envelope.x then
		return
	end
	local ack: Ack = {
		Server = self.Id,
		Ok = ok,
		Count = count,
		Message = if message then message:sub(1, 120) else nil,
		At = self.Now(),
	}
	if envelope.f == self.Id then
		self:_recordAck(envelope.i, ack)
		return
	end
	local text = HttpService:JSONEncode({
		v = 1,
		i = shortId(),
		f = self.Id,
		t = envelope.f,
		k = "ack",
		s = self.Now(),
		d = { i = envelope.i, o = ok, n = count, m = ack.Message },
	})
	local sent, err = self.Transport.Publish(Node.DirectTopic(envelope.f), text)
	if not sent then
		self.Stats.Errors += 1
		warn("[Sentinel.CrossServerNode] could not send acknowledgement: " .. tostring(err))
	end
end

function Node:_receive(text: any)
	local envelope = text
	if type(text) == "string" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
		envelope = if ok then decoded else nil
	end
	if
		type(envelope) ~= "table"
		or envelope.v ~= 1
		or type(envelope.i) ~= "string"
		or type(envelope.f) ~= "string"
		or type(envelope.k) ~= "string"
		or type(envelope.s) ~= "number"
	then
		self.Stats.Dropped += 1
		return
	end
	if envelope.t ~= nil and envelope.t ~= self.Id then
		return -- addressed to another server
	end
	local now = self.Now()
	if math.abs(now - envelope.s) > Node.MESSAGE_TTL then
		self.Stats.Dropped += 1
		return
	end
	-- MessagingService may deliver a message more than once.
	local seenKey = envelope.f .. "|" .. envelope.i
	if self.Seen[seenKey] then
		self.Stats.Dropped += 1
		return
	end
	self.Seen[seenKey] = now
	for key, at in pairs(self.Seen) do
		if now - at > Node.MESSAGE_TTL * 2 then
			self.Seen[key] = nil
		end
	end
	self.Stats.Received += 1

	if envelope.k == "ack" then
		local d = envelope.d
		if type(d) == "table" and type(d.i) == "string" then
			self:_recordAck(d.i, {
				Server = envelope.f,
				Ok = d.o == true,
				Count = tonumber(d.n) or 0,
				Message = if type(d.m) == "string" then d.m else nil,
				At = now,
			})
		end
		return
	end
	self.Spawn(function()
		self:_handle(envelope)
	end)
end

function Node:Send(kind: string, payload: any, options: { [string]: any }?): (any, string?)
	local opts: { [string]: any } = options or {}
	local actor: Actor? = opts.Actor
	local id = shortId()
	local envelope = {
		v = 1,
		i = id,
		f = self.Id,
		t = opts.To,
		k = kind,
		d = payload or {},
		a = if actor then { u = actor.UserId, n = actor.Name, p = actor.Priority } else nil,
		s = self.Now(),
		x = if opts.NoAck then true else nil,
	}
	local text = HttpService:JSONEncode(envelope)
	if #text > Node.MAX_BYTES then
		return nil, ("message too large (%d of %d bytes)"):format(#text, Node.MAX_BYTES)
	end

	-- Quiet = frequent background sync (poll tallies): no acknowledgement
	-- and no operation record, so the Operations list stays readable.
	if opts.Quiet then
		envelope.x = true
		text = HttpService:JSONEncode(envelope)
		self.Stats.Sent += 1
		if opts.To == self.Id then
			self.Seen[self.Id .. "|" .. id] = self.Now()
			self.Spawn(function()
				self:_handle(envelope)
			end)
		else
			local sent, err = self.Transport.Publish(if opts.To then Node.DirectTopic(opts.To) else Node.TOPIC_ALL, text)
			if not sent then
				self.Stats.Errors += 1
				return nil, tostring(err)
			end
		end
		return { Id = id, Kind = kind, Status = "sent" }, nil
	end

	local expected: { string } = {}
	if opts.To then
		expected = { opts.To }
	else
		for _, serverId in ipairs(opts.Expect or self.ExpectedServers()) do
			if not table.find(expected, serverId) then
				table.insert(expected, serverId)
			end
		end
		if not table.find(expected, self.Id) then
			table.insert(expected, self.Id)
		end
	end

	local op: Operation = {
		Id = id,
		Kind = kind,
		Label = opts.Label or kind,
		ActorName = if actor then actor.Name else nil,
		ActorId = if actor then actor.UserId else nil,
		To = opts.To,
		StartedAt = self.Now(),
		Expected = expected,
		Acks = {},
		Affected = 0,
		Status = if opts.NoAck then "sent" else "pending",
	}
	table.insert(self.Operations, 1, op)
	self.OpsById[id] = op
	while #self.Operations > Node.MAX_OPERATIONS do
		local old = table.remove(self.Operations)
		if old then
			self.OpsById[old.Id] = nil
		end
	end
	self.Stats.Sent += 1

	if opts.To == self.Id then
		-- Addressed to this server: no network round trip.
		self.Seen[self.Id .. "|" .. id] = self.Now()
		self.Spawn(function()
			self:_handle(envelope)
		end)
	else
		local topic = if opts.To then Node.DirectTopic(opts.To) else Node.TOPIC_ALL
		local sent, err = self.Transport.Publish(topic, text)
		if not sent then
			op.Status = "failed"
			op.Error = tostring(err)
			op.FinishedAt = self.Now()
			self.Stats.Errors += 1
			self:_changed(op)
			return snapshot(op), op.Error
		end
	end

	if not opts.NoAck then
		self.Delay(self.AckTimeout, function()
			self:_finalize(op, true)
		end)
	end
	self:_changed(op)
	return snapshot(op), nil
end

function Node:GetOperation(id: string): any
	local op = self.OpsById[id]
	return if op then snapshot(op) else nil
end

function Node:GetOperations(limit: number?): { any }
	local out = {}
	for i = 1, math.min(limit or Node.MAX_OPERATIONS, #self.Operations) do
		table.insert(out, snapshot(self.Operations[i]))
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Server registry helpers (pure). A registry record is what each server
-- writes on its heartbeat:
--   { Id, Place, Ver, N, Max, Start, HB, Fps, Ping, Mem, Staff = {names},
--     Locked, Maint, Priv, P = { {userId, name}, ... } }
-- ---------------------------------------------------------------------------
function Node.Health(record: any, now: number): string
	local age = now - (tonumber(record.HB) or 0)
	local fps = tonumber(record.Fps) or 60
	local ping = tonumber(record.Ping) or 0
	if age > 75 or fps < 20 or ping > 400 then
		return "poor"
	elseif age > 45 or fps < 45 or ping > 200 then
		return "fair"
	end
	return "good"
end

-- Drops stale / malformed records, sorts by player count (fullest first)
-- and returns totals for the overview.
function Node.Summarize(records: { any }, now: number, staleAfter: number): ({ any }, any)
	local servers = {}
	local totals = { Servers = 0, Players = 0, Staff = 0, Capacity = 0, AvgFps = 0, AvgPing = 0, Locked = 0, Poor = 0 }
	local fpsSum, pingSum = 0, 0
	local seen: { [string]: boolean } = {}
	for _, record in ipairs(records) do
		if type(record) ~= "table" or type(record.Id) ~= "string" or seen[record.Id] then
			continue
		end
		if now - (tonumber(record.HB) or 0) > staleAfter then
			continue
		end
		seen[record.Id] = true
		record.Health = Node.Health(record, now)
		table.insert(servers, record)
		totals.Servers += 1
		totals.Players += tonumber(record.N) or 0
		totals.Capacity += tonumber(record.Max) or 0
		totals.Staff += if type(record.Staff) == "table" then #record.Staff else 0
		fpsSum += tonumber(record.Fps) or 0
		pingSum += tonumber(record.Ping) or 0
		if record.Locked then
			totals.Locked += 1
		end
		if record.Health == "poor" then
			totals.Poor += 1
		end
	end
	if totals.Servers > 0 then
		totals.AvgFps = math.floor(fpsSum / totals.Servers + 0.5)
		totals.AvgPing = math.floor(pingSum / totals.Servers + 0.5)
	end
	table.sort(servers, function(a, b)
		local na, nb = tonumber(a.N) or 0, tonumber(b.N) or 0
		if na ~= nb then
			return na > nb
		end
		return a.Id < b.Id
	end)
	return servers, totals
end

-- Exact UserId, exact name, then name prefix, then substring.
function Node.FindPlayers(servers: { any }, query: string, limit: number?): { any }
	local max = limit or 25
	local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if q == "" then
		return {}
	end
	local asId = tonumber(q)
	local buckets: { { any } } = { {}, {}, {} }
	for _, server in ipairs(servers) do
		for _, entry in ipairs(if type(server.P) == "table" then server.P else {}) do
			local userId, name = entry[1], tostring(entry[2] or "")
			local lower = name:lower()
			local rank: number? = nil
			if (asId and userId == asId) or lower == q then
				rank = 1
			elseif lower:sub(1, #q) == q then
				rank = 2
			elseif lower:find(q, 1, true) then
				rank = 3
			end
			if rank then
				table.insert(buckets[rank], { UserId = userId, Name = name, ServerId = server.Id, Place = server.Place, Priv = server.Priv == true })
			end
		end
	end
	local out = {}
	for _, bucket in ipairs(buckets) do
		for _, match in ipairs(bucket) do
			if #out >= max then
				return out
			end
			table.insert(out, match)
		end
	end
	return out
end

return Node
