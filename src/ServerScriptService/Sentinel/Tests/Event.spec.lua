-- Tests for W24 events: Systems/EventService pure helpers + command registration.
return function(t)
	local Sentinel = script.Parent.Parent
	local EventService = require(Sentinel:WaitForChild("Systems"):WaitForChild("EventService"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

	local function words(s: string): { string }
		return string.split(s, " ")
	end

	t.test("event: presets and aliases", function()
		t.eq(EventService.FindPreset("doublecoins").Id, "doublecoins")
		t.eq(EventService.FindPreset("2xcoins").Id, "doublecoins")
		t.eq(EventService.FindPreset("Double XP").Id, "doublexp")
		t.eq(EventService.FindPreset("double_gems").Id, "doublegems")
		t.eq(EventService.FindPreset("2xall").Id, "doubleall")
		t.eq(EventService.FindPreset("nope"), nil)
		t.ok(#EventService.Presets() >= 5, "five built-in presets")
	end)

	t.test("event: parse defaults and options", function()
		local spec = EventService.ParseSpec(words("doublecoins"))
		t.ok(spec ~= nil, "parsed")
		t.eq(spec.Preset, "doublecoins")
		t.eq(spec.Duration, EventService.DEFAULT_DURATION)
		t.eq(spec.Delay, 0)
		t.eq(spec.Announce, true)
		local s2 = EventService.ParseSpec(words("doublexp time=1h30m in=5m announce=off xp=3"))
		t.eq(s2.Duration, 5400)
		t.eq(s2.Delay, 300)
		t.eq(s2.Announce, false)
		t.eq(s2.Multipliers.XP, 3)
		local s3 = EventService.ParseSpec(words("custom coins=1.5 gems=x2 Weekend rush"))
		t.eq(s3.Name, "Weekend rush")
		t.eq(s3.Multipliers.Coins, 1.5)
		t.eq(s3.Multipliers.Gems, 2)
		local s4 = EventService.ParseSpec(words("doublecoins time=none name=Coin_Frenzy"))
		t.eq(s4.Duration, 0)
		t.eq(s4.Name, "Coin Frenzy")
	end)

	t.test("event: parse errors", function()
		local function fails(s: string)
			local spec, err = EventService.ParseSpec(words(s))
			t.eq(spec, nil, s)
			t.ok(type(err) == "string" and #err > 0, "error for " .. s)
		end
		fails("unknownpreset")
		fails("doublecoins time=10s") -- under 1 minute
		fails("doublecoins time=25h")
		fails("doublecoins in=2s")
		fails("doublecoins coins=50")
		fails("doublecoins announce=maybe")
		fails("doublecoins stray words") -- only custom events take a free name
	end)

	t.test("event: durations", function()
		t.eq(EventService.ParseDuration("90"), 90)
		t.eq(EventService.ParseDuration("2m"), 120)
		t.eq(EventService.ParseDuration("1h30m"), 5400)
		t.eq(EventService.ParseDuration("1d"), 86400)
		t.eq(EventService.ParseDuration("none"), 0)
		t.eq(EventService.ParseDuration("abc"), nil)
		t.eq(EventService.ParseDuration("5x"), nil)
	end)

	t.test("event: status over time", function()
		local e = { StartsAt = 100, EndsAt = 200, Status = "scheduled" }
		t.eq(EventService.StatusAt(e, 50), "scheduled")
		t.eq(EventService.StatusAt(e, 100), "active")
		t.eq(EventService.StatusAt(e, 199), "active")
		t.eq(EventService.StatusAt(e, 200), "ended")
		local open = { StartsAt = 0, EndsAt = 0, Status = "active" }
		t.eq(EventService.StatusAt(open, 1e9), "active")
		t.eq(EventService.StatusAt({ StartsAt = 0, EndsAt = 0, Status = "stopped" }, 5), "stopped")
	end)

	t.test("event: multipliers combine and cap", function()
		local list = {
			{ StartsAt = 0, EndsAt = 0, Status = "active", Multipliers = { Coins = 2 } },
			{ StartsAt = 0, EndsAt = 0, Status = "active", Multipliers = { Coins = 2, XP = 1.5 } },
			{ StartsAt = 500, EndsAt = 0, Status = "scheduled", Multipliers = { Gems = 3 } }, -- not started
			{ StartsAt = 0, EndsAt = 10, Status = "active", Multipliers = { Gems = 5 } }, -- over
		}
		local m = EventService.Combine(list, 100)
		t.eq(m.Coins, 4)
		t.eq(m.XP, 1.5)
		t.eq(m.Gems, 1)
		local big = {
			{ StartsAt = 0, EndsAt = 0, Status = "active", Multipliers = { Coins = 10 } },
			{ StartsAt = 0, EndsAt = 0, Status = "active", Multipliers = { Coins = 10 } },
		}
		t.eq(EventService.Combine(big, 1).Coins, EventService.MAX_MULTIPLIER)
		t.eq(EventService.MultiplierText({ Coins = 2, XP = 1 }), "Coins x2")
	end)

	t.test("event: custom-event API", function()
		EventService.Define({ Id = "SpecTestEvent", Name = "Spec Test", Multipliers = { XP = 4 } })
		local def = EventService.FindPreset("spectestevent")
		t.ok(def ~= nil, "defined")
		t.eq(def.Multipliers.XP, 4)
		t.eq(EventService.ParseSpec(words("spec_test_event")).Preset, "spectestevent")
	end)

	t.test("event: commands registered", function()
		if not CommandRegistry.Resolve("event") then
			require(Sentinel:WaitForChild("Commands"):WaitForChild("Server"):WaitForChild("Events"))
		end
		if not CommandRegistry.Resolve("reward") then
			require(Sentinel:WaitForChild("Commands"):WaitForChild("Economy"):WaitForChild("Currency"))
		end
		for _, name in ipairs({ "event", "gevent", "scheduleevent", "stopevent", "events", "reward" }) do
			t.ok(CommandRegistry.Resolve(name) ~= nil, name)
		end
		t.eq(CommandRegistry.Resolve("multipliers").Name, "events")
		t.eq(CommandRegistry.Resolve("event").Permission, "server.event")
		t.eq(CommandRegistry.Resolve("gevent").Permission, "crossserver.event")
	end)
end
