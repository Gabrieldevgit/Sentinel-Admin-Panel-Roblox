-- Tests for the Announcements section, PM options and Owner approval:
-- option parsing, history merge, and the approval hold / approve / deny
-- flow with fake players.
return function(t)
	local Sentinel = script.Parent.Parent
	local Systems = Sentinel:WaitForChild("Systems")
	local AnnouncementService = require(Systems:WaitForChild("AnnouncementService"))
	local PrivateMessageService = require(Systems:WaitForChild("PrivateMessageService"))
	local ApprovalService = require(Systems:WaitForChild("ApprovalService"))

	-- ------------------------------------------------------------------
	-- Announcements
	-- ------------------------------------------------------------------
	t.test("announce options are read from the front", function()
		local o, rest, err = AnnouncementService.ParseOptions({ "style=full", "time=15", "color=gold", "title=Big_News", "Hello", "world" })
		t.eq(err, nil)
		t.eq(o.Style, "full")
		t.eq(o.Duration, 15)
		t.eq(o.Color, "FFC94D")
		t.eq(o.Title, "Big News")
		t.eq(#rest, 2)
		t.eq(rest[1], "Hello")
	end)

	t.test("announce: unknown keys stay in the message, bad values fail", function()
		local o, rest = AnnouncementService.ParseOptions({ "x=5", "is", "fine" })
		t.eq(o.Style, "banner")
		t.eq(o.Duration, AnnouncementService.DEFAULT_DURATION)
		t.eq(#rest, 3)
		local _, _, err = AnnouncementService.ParseOptions({ "time=500", "hi" })
		t.ok(err ~= nil)
		local _, _, err2 = AnnouncementService.ParseOptions({ "color=nope", "hi" })
		t.ok(err2 ~= nil)
		local o3 = AnnouncementService.ParseOptions({ "color=#a1b2c3", "hi" })
		t.eq(o3.Color, "A1B2C3")
	end)

	t.test("history merge: newest first, no duplicates, capped", function()
		local list = {}
		for i = 1, 120 do
			table.insert(list, { Id = "a" .. i, Time = i })
		end
		local merged = AnnouncementService._Merge(list, { { Id = "a120", Time = 120 }, { Id = "new", Time = 500 } })
		t.eq(#merged, 100)
		t.eq(merged[1].Id, "new")
		t.eq(merged[2].Id, "a120")
	end)

	-- ------------------------------------------------------------------
	-- Private messages
	-- ------------------------------------------------------------------
	t.test("pm options", function()
		local o, rest, err = PrivateMessageService.ParseOptions({ "kind=warn", "reply=off", "ack=on", "time=30", "Stop", "that" })
		t.eq(err, nil)
		t.eq(o.Kind, "warning")
		t.eq(o.Reply, false)
		t.eq(o.Ack, true)
		t.eq(o.Duration, 30)
		t.eq(#rest, 2)
		local d = PrivateMessageService.ParseOptions({ "hello" })
		t.eq(d.Reply, true)
		t.eq(d.Duration, 0)
		t.eq(d.Style, "card")
		local _, _, bad = PrivateMessageService.ParseOptions({ "time=3", "x" })
		t.ok(bad ~= nil)
		local _, _, bad2 = PrivateMessageService.ParseOptions({ "anon=maybe", "x" })
		t.ok(bad2 ~= nil)
	end)

	-- ------------------------------------------------------------------
	-- Owner approval
	-- ------------------------------------------------------------------
	local owner = { UserId = 1, Name = "Owner1", DisplayName = "Owner", FakePlayer = true }
	local admin = { UserId = 2, Name = "Admin2", DisplayName = "Admin", FakePlayer = true }
	local online = { owner, admin }
	ApprovalService.SetOwnerResolver(function(p)
		return p == owner
	end, function()
		return online
	end)
	local critical = { Name = "shutdown", Risk = "critical" }
	local high = { Name = "ban", Risk = "high" }

	t.test("risky command from a non-owner is held while an owner is online", function()
		ApprovalService._Reset()
		local held = ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = "shutdown" })
		t.ok(type(held) == "table" and held.Pending == true)
		t.eq(#ApprovalService.List(), 1)
	end)

	t.test("owner, low risk or no owner online: runs directly", function()
		ApprovalService._Reset()
		t.eq(ApprovalService.CheckCommand(critical, { Executor = owner, RawInput = "shutdown" }), nil)
		t.eq(ApprovalService.CheckCommand(high, { Executor = admin, RawInput = "ban x" }), nil) -- default threshold = critical
		online = { admin }
		t.eq(ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = "shutdown" }), nil)
		online = { owner, admin }
	end)

	t.test("approve replays the command once with a token; deny doesn't", function()
		ApprovalService._Reset()
		local replays, innerResult = 0, "unset"
		ApprovalService.SetReplay(function(r, token)
			replays += 1
			-- The replayed command must pass the hook thanks to the token.
			innerResult = ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = r.Text, ApprovalToken = token })
			return { { Success = true, Message = "ran" } }
		end)
		local held = ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = "shutdown" })
		local ok = ApprovalService.Respond(admin, held.ApprovalId, true)
		t.eq(ok, false) -- only an owner may answer
		ok = ApprovalService.Respond(owner, held.ApprovalId, true)
		t.eq(ok, true)
		t.eq(replays, 1)
		t.eq(innerResult, nil)
		t.eq(#ApprovalService.List(), 0)
		-- a used token can't be reused
		local again = ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = "shutdown", ApprovalToken = "x" })
		t.ok(type(again) == "table" and again.Pending == true)

		ApprovalService._Reset()
		local held2 = ApprovalService.CheckCommand(critical, { Executor = admin, RawInput = "shutdown" })
		t.eq(ApprovalService.Respond(owner, held2.ApprovalId, false, "not now"), true)
		t.eq(replays, 1)
		ApprovalService._Reset()
	end)
end
