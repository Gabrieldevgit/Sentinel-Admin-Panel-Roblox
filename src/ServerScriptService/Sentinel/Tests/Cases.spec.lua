-- Tests for the W12 moderation center: CaseService records, statuses,
-- search / query parsing, expiry, revocation, reason templates and the
-- After hook that turns moderation commands into cases. Edit mode has no
-- DataStore, so everything runs in memory.
return function(t)
	local Sentinel = script.Parent.Parent
	require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))
	local CaseService = require(Sentinel:WaitForChild("Systems"):WaitForChild("CaseService"))

	local mod = { UserId = -8101, Name = "CaseMod" } :: any
	local function rec(fields)
		fields.ModeratorId = fields.ModeratorId or mod.UserId
		fields.ModeratorName = fields.ModeratorName or mod.Name
		return CaseService.Record(fields)
	end

	t.test("record sets status, duration and expiry", function()
		local ban = rec({ Type = "ban", TargetId = -8201, TargetName = "CaseBob", Reason = "x", Duration = "1d" })
		t.eq(ban.Status, "Active")
		t.ok(ban.ExpiresAt and ban.ExpiresAt > os.time() + 86000, "expires in a day")
		local perm = rec({ Type = "ban", TargetId = -8202, TargetName = "CasePerm", Duration = "forever" })
		t.eq(perm.ExpiresAt, -1)
		t.eq(perm.Duration, "permanent")
		local kick = rec({ Type = "kick", TargetId = -8201, TargetName = "CaseBob" })
		t.eq(kick.Status, "Closed")
		local inv = rec({ Type = "investigation", TargetId = -8203, TargetName = "CaseSus", Reason = "trade scam" })
		t.eq(inv.Status, "Open")
		t.ok(inv.Id ~= kick.Id and kick.Id ~= ban.Id, "unique ids")
	end)

	t.test("query parsing", function()
		local f = CaseService.ParseQuery("player:Bob mod:Alice type:ban status:active since:7d hello world")
		t.eq(f.Player, "Bob")
		t.eq(f.Moderator, "Alice")
		t.eq(f.Type, "ban")
		t.eq(f.Status, "active")
		t.ok(f.Since and f.Since < os.time(), "since")
		t.eq(f.Text, "hello world")
		t.eq(CaseService.ParseQuery("#12").Id, 12)
		local bad, err = CaseService.ParseQuery("status:weird")
		t.eq(bad, nil)
		t.ok(err ~= nil, "status error")
	end)

	t.test("search filters and pages", function()
		local found = CaseService.Search(CaseService.ParseQuery("player:CaseBob"), nil, 10)
		t.eq(found.Total, 2)
		t.eq(found.Cases[1].Type, "kick") -- newest first
		t.eq(CaseService.Search(CaseService.ParseQuery("player:CaseBob type:ban"), nil, 10).Total, 1)
		t.eq(CaseService.Search(CaseService.ParseQuery("player:-8201 status:active"), nil, 10).Total, 1)
		t.eq(CaseService.Search(CaseService.ParseQuery("trade"), nil, 10).Total, 1)
		local page = CaseService.Search(CaseService.ParseQuery("mod:CaseMod"), nil, 2)
		t.eq(#page.Cases, 2)
		t.eq(page.Cursor, 2)
		local nextPage = CaseService.Search(CaseService.ParseQuery("mod:CaseMod"), page.Cursor, 2)
		t.ok(nextPage.Cases[1].Id ~= page.Cases[1].Id, "second page differs")
		t.eq(page.Cases[1].Notes, nil) -- summaries carry no notes
	end)

	t.test("notes, status, assignment", function()
		local c = rec({ Type = "warn", TargetId = -8204, TargetName = "CaseNoter" })
		local ok = CaseService.AddNote(c.Id, mod, "first note")
		t.ok(ok, "note added")
		t.eq(#CaseService.Get(c.Id).Notes, 1)
		t.ok((CaseService.SetStatus(c.Id, "Open", mod)), "reopen")
		t.eq(CaseService.Get(c.Id).Status, "Open")
		t.eq((CaseService.SetStatus(c.Id, "Open", mod)), false) -- already open
		CaseService.Assign(c.Id, mod, "Alice")
		t.eq(CaseService.Get(c.Id).Assignee, "Alice")
		t.eq(CaseService.Search({ Moderator = "alice" }, nil, 50).Total >= 1, true)
		t.eq((CaseService.AddNote(999999, mod, "x")), false)
	end)

	t.test("expiry and revoke", function()
		local c = rec({ Type = "mute", TargetId = -8205, TargetName = "CaseMuted", Duration = "1h" })
		c.ExpiresAt = os.time() - 1
		t.eq(CaseService.Get(c.Id).Status, "Expired")
		local m = rec({ Type = "mute", TargetId = -8206, TargetName = "CaseMuted2", Duration = "1h" })
		t.eq(CaseService.Revoke(-8206, { "mute" }, mod), 1)
		t.eq(CaseService.Get(m.Id).Status, "Revoked")
		t.eq(CaseService.Revoke(-8206, { "mute" }, mod), 0)
	end)

	t.test("reason templates expand #name", function()
		local out, changed = CaseService.ExpandReasons({ "#exploit", "and", "#nope" })
		t.ok(changed, "changed")
		t.eq(out[1], "Exploiting")
		t.eq(out[#out], "#nope")
		t.ok(CaseService.FindReason("SPAM") ~= nil, "case-insensitive")
		local same, changed2 = CaseService.ExpandReasons({ "plain" })
		t.eq(changed2, false)
		t.eq(same[1], "plain")
	end)

	t.test("moderation commands become cases", function()
		local target = { UserId = -8207, Name = "CaseHooked" }
		CaseService.OnCommand({ Name = "ban", Category = "Moderation", Args = {
			{ Name = "target", Type = "players" },
			{ Name = "reason", Type = "text" },
		}, RequiresTarget = true }, {
			Executor = mod,
			Targets = { target },
			Modifier = "7d",
			Arguments = { "being", "rude" },
		}, { Success = true })
		local found = CaseService.Search({ Player = "CaseHooked" }, nil, 5)
		t.eq(found.Total, 1)
		t.eq(found.Cases[1].Reason, "being rude")
		t.eq(found.Cases[1].Duration, "7d")
		-- failures make no case
		CaseService.OnCommand({ Name = "kick" }, { Executor = mod, Targets = { target }, Arguments = {} }, { Success = false })
		t.eq(CaseService.Search({ Player = "CaseHooked" }, nil, 5).Total, 1)
		-- global ban through ctx.CaseTarget, then gunban revokes it
		CaseService.OnCommand({ Name = "gban" }, {
			Executor = mod,
			Arguments = { "-8208", "perm" },
			CaseTarget = { UserId = -8208, Name = "CaseGlobal" },
		}, { Success = true })
		local g = CaseService.Search({ Player = "CaseGlobal" }, nil, 5).Cases[1]
		t.eq(g.Global, true)
		t.eq(g.Status, "Active")
		CaseService.OnCommand({ Name = "gunban" }, {
			Executor = mod,
			Arguments = { "-8208" },
			CaseTarget = { UserId = -8208, Name = "CaseGlobal" },
		}, { Success = true })
		t.eq(CaseService.Get(g.Id).Status, "Revoked")
	end)

	t.test("dashboard summary", function()
		local d = CaseService.Dashboard()
		t.ok(d.Counts.Active >= 2, "active count")
		t.ok(d.Counts.ActiveBans >= 1, "bans")
		t.eq(#d.Activity, 24)
		t.ok(d.Activity[24] >= 5, "this hour")
		t.ok(#d.RecentPunishments > 0 and #d.RecentWarnings > 0, "recent lists")
		t.ok(#d.Reasons >= 5, "reasons")
	end)
end
