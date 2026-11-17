-- Tests for the cross-server protocol (Core/CrossServerNode): several nodes
-- on a fake in-memory bus stand in for several game servers, so broadcasts,
-- direct messages, acknowledgements, timeouts and duplicates can be checked
-- without live servers. Also covers the registry helpers and the policy for
-- ;global.
return function(t)
	local Sentinel = script.Parent.Parent
	local Core = Sentinel:WaitForChild("Core")
	local Node = require(Core:WaitForChild("CrossServerNode"))
	local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))

	-- A bus that delivers synchronously to every subscriber of a topic, and
	-- a scheduler whose timers only fire when the test says so.
	local function network()
		local net = { Topics = {}, Timers = {}, Published = 0, Clock = 1000, Down = {} }
		function net.transport(id: string)
			return {
				Publish = function(topic: string, text: string)
					if net.Down[id] then
						return false, "offline"
					end
					net.Published += 1
					for _, callback in ipairs(net.Topics[topic] or {}) do
						callback(text)
					end
					return true
				end,
				Subscribe = function(topic: string, callback)
					net.Topics[topic] = net.Topics[topic] or {}
					table.insert(net.Topics[topic], callback)
				end,
			}
		end
		function net.node(id: string, expected: { string }?)
			local node = Node.new({
				Id = id,
				Transport = net.transport(id),
				Now = function()
					return net.Clock
				end,
				Delay = function(_seconds: number, fn: () -> ())
					table.insert(net.Timers, fn)
				end,
				Spawn = function(fn: () -> ())
					fn()
				end,
				ExpectedServers = function()
					return expected or {}
				end,
			})
			node:Start()
			return node
		end
		function net.timeout()
			local timers = net.Timers
			net.Timers = {}
			for _, fn in ipairs(timers) do
				fn()
			end
		end
		return net
	end

	local ALL = { "A", "B", "C" }

	t.test("broadcast reaches every server and completes when all acknowledge", function()
		local net = network()
		local a, b, c = net.node("A", ALL), net.node("B", ALL), net.node("C", ALL)
		local seen = {}
		for _, node in ipairs({ a, b, c }) do
			node:Handle("kick", function(payload, envelope)
				table.insert(seen, node.Id .. ":" .. envelope.f .. ":" .. tostring(envelope.a.n))
				return true, if node.Id == "B" then 1 else 0, if node.Id == "B" then "kicked" else "not here"
			end)
		end
		local op = a:Send("kick", { u = 5 }, { Actor = { UserId = 1, Name = "Mod", Priority = 50 }, Label = "kick X" })
		t.eq(#seen, 3, "handlers run")
		local final = a:GetOperation(op.Id)
		t.eq(final.Status, "complete")
		t.eq(#final.Acks, 3)
		t.eq(final.Affected, 1)
		t.eq(final.Label, "kick X")
		t.eq(final.ActorName, "Mod")
	end)

	t.test("direct message only reaches the addressed server", function()
		local net = network()
		local a, b, c = net.node("A", ALL), net.node("B", ALL), net.node("C", ALL)
		local hits = {}
		for _, node in ipairs({ a, b, c }) do
			node:Handle("warn", function()
				table.insert(hits, node.Id)
				return true, 1
			end)
		end
		local op = a:Send("warn", {}, { To = "C" })
		t.eq(table.concat(hits, ","), "C")
		t.eq(a:GetOperation(op.Id).Status, "complete")
		t.eq(#a:GetOperation(op.Id).Expected, 1)
	end)

	t.test("message to this server itself needs no network", function()
		local net = network()
		local a = net.node("A", ALL)
		local ran = 0
		a:Handle("migrate", function()
			ran += 1
			return true, 4, "started"
		end)
		local op = a:Send("migrate", {}, { To = "A" })
		t.eq(ran, 1)
		t.eq(net.Published, 0, "nothing published")
		t.eq(a:GetOperation(op.Id).Status, "complete")
		t.eq(a:GetOperation(op.Id).Affected, 4)
	end)

	t.test("a silent server makes the operation partial after the timeout", function()
		local net = network()
		local a, b = net.node("A", ALL), net.node("B", ALL) -- C never started
		a:Handle("announce", function()
			return true, 2
		end)
		b:Handle("announce", function()
			return true, 3
		end)
		local op = a:Send("announce", { m = "hi" })
		t.eq(a:GetOperation(op.Id).Status, "pending")
		net.timeout()
		local final = a:GetOperation(op.Id)
		t.eq(final.Status, "partial")
		t.eq(#final.Acks, 2)
		t.eq(final.Affected, 5)
	end)

	t.test("no answer at all is reported, and a late answer still counts", function()
		local net = network()
		local a = net.node("A", { "A", "B" })
		-- A has no handler for "x": it answers "unsupported"; B is missing.
		local op = a:Send("x", {}, { To = "B" })
		net.timeout()
		t.eq(a:GetOperation(op.Id).Status, "no response")
		local b = net.node("B", { "A", "B" })
		b:Handle("y", function()
			return true, 1
		end)
		local op2 = a:Send("y", {}, { To = "B" })
		t.eq(a:GetOperation(op2.Id).Status, "complete")
	end)

	t.test("refusals travel back in the acknowledgement", function()
		local net = network()
		local a, b = net.node("A", { "A", "B" }), net.node("B", { "A", "B" })
		a:Handle("ban", function()
			return true, 0, "not here"
		end)
		b:Handle("ban", function()
			return false, 0, "protected by rank"
		end)
		local op = a:Send("ban", { u = 9 })
		local final = a:GetOperation(op.Id)
		t.eq(final.Status, "complete")
		local refused = nil
		for _, ack in ipairs(final.Acks) do
			if not ack.Ok then
				refused = ack
			end
		end
		t.ok(refused, "one refusal")
		t.eq(refused.Server, "B")
		t.eq(refused.Message, "protected by rank")
	end)

	t.test("a handler error is contained and acknowledged as a failure", function()
		local net = network()
		local a, b = net.node("A", { "A", "B" }), net.node("B", { "A", "B" })
		a:Handle("boom", function()
			return true, 1
		end)
		b:Handle("boom", function()
			error("kaboom")
		end)
		local op = a:Send("boom", {})
		local final = a:GetOperation(op.Id)
		t.eq(final.Status, "complete")
		t.eq(final.Affected, 1)
		t.eq(b.Stats.Errors, 1)
	end)

	t.test("duplicates, expired and malformed messages are dropped", function()
		local net = network()
		local a, b = net.node("A", { "A", "B" }), net.node("B", { "A", "B" })
		local runs = 0
		b:Handle("once", function()
			runs += 1
			return true, 1
		end)
		a:Handle("once", function()
			return true, 0
		end)
		local captured = nil
		net.Topics[Node.TOPIC_ALL][3] = function(text)
			captured = text
		end
		a:Send("once", {})
		t.eq(runs, 1)
		b:_receive(captured) -- delivered a second time
		t.eq(runs, 1, "duplicate ignored")
		b:_receive("not json")
		b:_receive({ v = 1, i = "x" })
		b:_receive({ v = 2, i = "x", f = "A", k = "once", s = net.Clock })
		t.eq(runs, 1, "malformed ignored")
		b:_receive({ v = 1, i = "old", f = "A", k = "once", s = net.Clock - 500 })
		t.eq(runs, 1, "expired ignored")
		b:_receive({ v = 1, i = "fresh", f = "A", k = "once", s = net.Clock, x = true })
		t.eq(runs, 2, "a new message still runs")
	end)

	t.test("oversized messages are refused before sending", function()
		local net = network()
		local a = net.node("A", ALL)
		local op, err = a:Send("announce", { m = string.rep("x", 2000) })
		t.eq(op, nil)
		t.ok(err and err:find("too large"), "size error")
		t.eq(net.Published, 0)
	end)

	t.test("a failed publish marks the operation failed", function()
		local net = network()
		local a = net.node("A", ALL)
		net.Down.A = true
		local op, err = a:Send("announce", { m = "hi" })
		t.eq(op.Status, "failed")
		t.eq(err, "offline")
	end)

	t.test("NoAck messages are delivered without acknowledgements", function()
		local net = network()
		local a, b = net.node("A", { "A", "B" }), net.node("B", { "A", "B" })
		local got = {}
		for _, node in ipairs({ a, b }) do
			node:Handle("chat", function(payload)
				table.insert(got, node.Id .. payload.m)
				return true, 0
			end)
		end
		local before = net.Published
		local op = a:Send("chat", { m = "hi" }, { NoAck = true })
		t.eq(#got, 2)
		t.eq(net.Published - before, 1, "no ack traffic")
		t.eq(op.Status, "sent")
	end)

	t.test("operation listeners see every change", function()
		local net = network()
		local a, b = net.node("A", { "A", "B" }), net.node("B", { "A", "B" })
		a:Handle("ping", function()
			return true, 1
		end)
		b:Handle("ping", function()
			return true, 1
		end)
		local statuses = {}
		a:OnOperationChanged(function(op)
			table.insert(statuses, op.Status)
		end)
		a:Send("ping", {})
		t.eq(statuses[#statuses], "complete")
		t.ok(#statuses >= 2, "pending then complete")
	end)

	t.test("registry: stale servers are dropped and totals add up", function()
		local now = 5000
		local servers, totals = Node.Summarize({
			{ Id = "s1", N = 10, Max = 20, HB = now - 5, Fps = 60, Ping = 80, Staff = { "a", "b" } },
			{ Id = "s2", N = 30, Max = 40, HB = now - 50, Fps = 30, Ping = 100, Staff = {}, Locked = true },
			{ Id = "s3", N = 99, Max = 99, HB = now - 500, Fps = 60, Ping = 10, Staff = {} }, -- stale
			{ Id = "s1", N = 1, Max = 1, HB = now, Fps = 60, Ping = 1, Staff = {} }, -- duplicate id
			"junk",
		}, now, 100)
		t.eq(#servers, 2)
		t.eq(servers[1].Id, "s2", "fullest first")
		t.eq(totals.Players, 40)
		t.eq(totals.Capacity, 60)
		t.eq(totals.Staff, 2)
		t.eq(totals.Locked, 1)
		t.eq(totals.AvgFps, 45)
		t.eq(servers[2].Health, "good")
		t.eq(servers[1].Health, "fair")
		t.eq(Node.Health({ HB = now, Fps = 10, Ping = 50 }, now), "poor")
	end)

	t.test("registry: find players by id, name, prefix and substring", function()
		local servers = {
			{ Id = "s1", P = { { 11, "Alice" }, { 12, "Bob" } } },
			{ Id = "s2", P = { { 13, "alicia" }, { 14, "Malice" } }, Priv = true },
		}
		local exact = Node.FindPlayers(servers, "alice")
		t.eq(exact[1].Name, "Alice")
		t.eq(exact[1].ServerId, "s1")
		t.eq(#exact, 2, "exact + substring (Malice)")
		t.eq(Node.FindPlayers(servers, "ali")[2].Name, "alicia")
		t.eq(Node.FindPlayers(servers, "14")[1].Name, "Malice")
		t.eq(Node.FindPlayers(servers, "14")[1].Priv, true)
		t.eq(#Node.FindPlayers(servers, "zzz"), 0)
		t.eq(#Node.FindPlayers(servers, "  "), 0)
		t.eq(#Node.FindPlayers(servers, "a", 1), 1, "limit")
	end)

	t.test("only target-less, listed commands may run globally", function()
		t.ok(CommandPolicy.IsGlobalSafe({ Name = "weather" }))
		t.ok(CommandPolicy.IsGlobalSafe({ Name = "slowmode" }))
		t.ok(not CommandPolicy.IsGlobalSafe({ Name = "kick", RequiresTarget = true }))
		t.ok(not CommandPolicy.IsGlobalSafe({ Name = "execute" }))
		t.ok(not CommandPolicy.IsGlobalSafe({ Name = "shutdown" }))
		t.ok(CommandPolicy.IsGlobalSafe({ Name = "myevent", Global = true }))
		t.ok(not CommandPolicy.IsGlobalSafe({ Name = "weather", Global = false }))
		t.ok(not CommandPolicy.IsGlobalSafe({ Name = "myevent", Global = true, RequiresTarget = true }))
		t.eq(CommandPolicy.GetRisk({ Name = "lockdown" }), "critical")
		t.eq(CommandPolicy.GetRisk({ Name = "gban" }), "high")
	end)
end
