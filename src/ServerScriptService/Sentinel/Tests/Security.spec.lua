-- Tests for W04 security pieces: RateLimiter and CommandPolicy.
return function(t)
	local Core = script.Parent.Parent:WaitForChild("Core")
	local RateLimiter = require(Core:WaitForChild("RateLimiter"))
	local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))

	t.test("rate limiter allows a burst then drops", function()
		local limiter = RateLimiter.new("TestBurst", 3, 0) -- no refill
		local p = { UserId = -7001, Name = "Spammer" } :: any
		t.ok(limiter:Allow(p))
		t.ok(limiter:Allow(p))
		t.ok(limiter:Allow(p))
		local allowed, firstDrop = limiter:Allow(p)
		t.ok(not allowed, "4th request dropped")
		t.ok(firstDrop, "first drop of the burst is flagged")
		local _, secondFirst = limiter:Allow(p)
		t.ok(not secondFirst, "later drops in the same burst are not")
		local other = { UserId = -7002, Name = "Other" } :: any
		t.ok(limiter:Allow(other), "buckets are per player")
		limiter:Reset(p)
		t.ok(limiter:Allow(p), "reset refills")
	end)

	t.test("rate limiter refills over time", function()
		local limiter = RateLimiter.new("TestRefill", 1, 1000) -- refills instantly
		local p = { UserId = -7003, Name = "Fast" } :: any
		t.ok(limiter:Allow(p))
		task.wait(0.01)
		t.ok(limiter:Allow(p))
	end)

	t.test("risk levels and confirmation rules", function()
		local function def(name, requiresTarget)
			return { Name = name, RequiresTarget = requiresTarget }
		end
		t.eq(CommandPolicy.GetRisk(def("ban")), "high")
		t.eq(CommandPolicy.GetRisk(def("shutdown")), "critical")
		t.eq(CommandPolicy.GetRisk(def("heal")), "low")
		t.ok((CommandPolicy.NeedsConfirmation(def("ban", true), 1)), "high always confirms")
		t.ok((CommandPolicy.NeedsConfirmation(def("shutdown", false), 0)), "critical always confirms")
		t.ok(not (CommandPolicy.NeedsConfirmation(def("kick", true), 2)), "medium below bulk threshold runs")
		t.ok((CommandPolicy.NeedsConfirmation(def("kick", true), CommandPolicy.BULK_THRESHOLD)), "medium bulk confirms")
		t.ok(not (CommandPolicy.NeedsConfirmation(def("heal", true), 50)), "low never confirms")
		t.eq(CommandPolicy.GetRisk({ Name = "heal", Risk = "high" }), "high", "definition override wins")
		t.eq(CommandPolicy.GetRisk({ Name = "heal", Risk = "bogus" }), "low", "unknown risk falls back")
	end)

	t.test("owner-only commands", function()
		t.ok(CommandPolicy.IsOwnerOnly({ Name = "execute" }))
		t.ok(CommandPolicy.IsOwnerOnly({ Name = "resetranks" }))
		t.ok(not CommandPolicy.IsOwnerOnly({ Name = "ban" }))
		t.ok(not CommandPolicy.IsOwnerOnly({ Name = "execute", OwnerOnly = false }), "override wins")
	end)
end
