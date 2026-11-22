-- Tests for W14 reports & appeals: ReportService (submit rules, evidence,
-- status / assignment, queue search + query parsing) and AppealService
-- (what can be appealed, submit rules, accept lifts + revokes the case,
-- reject cooldown). Edit mode has no DataStore, so everything is in memory.
return function(t)
	local Sentinel = script.Parent.Parent
	local Systems = Sentinel:WaitForChild("Systems")
	require(Systems:WaitForChild("RankService"))
	local ReportService = require(Systems:WaitForChild("ReportService"))
	local AppealService = require(Systems:WaitForChild("AppealService"))
	local CaseService = require(Systems:WaitForChild("CaseService"))

	ReportService._Reset()
	AppealService._Reset()

	local staff = { UserId = -9001, Name = "RepStaff" } :: any
	local bob = { UserId = -9101, Name = "RepBob" } :: any
	local amy = { UserId = -9102, Name = "RepAmy" } :: any
	local cat = { UserId = -9103, Name = "RepCat" } :: any
	local dan = { UserId = -9104, Name = "RepDan" } :: any

	t.test("report submit rules", function()
		local r, err = ReportService.Submit(amy, amy, "spam", "reporting myself here")
		t.eq(r, nil)
		t.ok(err and err:find("yourself"), "no self reports")
		r, err = ReportService.Submit(amy, bob, "spam", "hi")
		t.eq(r, nil)
		t.ok(err and err:find("Describe"), "needs a description")
		r = ReportService.Submit(amy, bob, "exp", "flying through walls at spawn", { "youtu.be/clip" })
		t.ok(r ~= nil, "report created")
		t.eq(r.Category, "Exploiting") -- prefix match
		t.eq(r.Status, "Open")
		local hasReporterEvidence = false
		for _, e in ipairs(r.Evidence) do
			if e.Kind == "reporter" and e.Text == "youtu.be/clip" then
				hasReporterEvidence = true
			end
		end
		t.ok(hasReporterEvidence, "reporter evidence attached")
		local again
		again, err = ReportService.Submit(amy, cat, "spam", "spamming the chat a lot")
		t.eq(again, nil)
		t.ok(err and err:find("wait"), "reporter cooldown")
	end)

	t.test("duplicate pending report is refused", function()
		local first = ReportService.Submit(cat, dan, "Harassment", "calling people names")
		t.ok(first ~= nil, "first")
		ReportService._ForgetCooldown(cat.UserId)
		local second, err = ReportService.Submit(cat, dan, "Harassment", "still calling names")
		t.eq(second, nil)
		t.ok(err and err:find("already reported"), "duplicate refused")
	end)

	t.test("chat evidence is captured", function()
		ReportService.NoteChat({ UserId = dan.UserId, Name = dan.Name } :: any, "give me your items or else")
		ReportService.NoteChat({ UserId = dan.UserId, Name = dan.Name } :: any, ";fly me")
		task.wait()
		local chat = ReportService.RecentChat(dan.UserId)
		t.eq(#chat, 2)
		t.eq(chat[1].Text, "give me your items or else")
		t.eq(chat[2].Text, "(command)")
	end)

	t.test("status, assignment and queue search", function()
		local found = ReportService.Search(ReportService.ParseQuery("", staff.Name), nil, 50)
		t.eq(found.Total, 2) -- both pending
		local id = found.Reports[#found.Reports].Id -- the oldest (Bob)
		local ok = ReportService.Assign(id, staff, staff.Name)
		t.ok(ok, "assigned")
		t.eq(ReportService.Get(id).Status, "InProgress")
		t.eq(ReportService.Search(ReportService.ParseQuery("mine", staff.Name), nil, 50).Total, 1)
		t.eq(ReportService.Search(ReportService.ParseQuery("assignee:none", staff.Name), nil, 50).Total, 1)
		local case = CaseService.Record({ Type = "warn", TargetId = bob.UserId, TargetName = bob.Name, ModeratorId = staff.UserId, ModeratorName = staff.Name, Reason = "flying" })
		ok = ReportService.SetStatus(id, "resolved", staff, "warned", case.Id)
		t.ok(ok, "resolved")
		local r = ReportService.Get(id)
		t.eq(r.Status, "Resolved")
		t.eq(r.CaseId, case.Id)
		t.eq(r.Resolution, "warned")
		t.eq(ReportService.PendingCount(), 1)
		t.eq(ReportService.Search(ReportService.ParseQuery("all player:RepBob", staff.Name), nil, 50).Total, 1)
		t.eq(ReportService.Search(ReportService.ParseQuery("category:harass status:all"), nil, 50).Total, 1)
		local bad = ReportService.SetStatus(id, "weird", staff)
		t.eq(bad, false)
		ReportService.AddNote(id, staff, "checked the clip")
		ReportService.AddNote(id, staff, "second clip", true)
		r = ReportService.Get(id)
		t.ok(#r.Notes >= 3, "notes kept")
		t.eq(r.Evidence[#r.Evidence].Kind, "staff")
	end)

	t.test("appealable punishments", function()
		CaseService.Record({ Type = "mute", TargetId = cat.UserId, TargetName = cat.Name, ModeratorId = staff.UserId, ModeratorName = staff.Name, Reason = "spam", Duration = "1h" })
		CaseService.Record({ Type = "kick", TargetId = cat.UserId, TargetName = cat.Name, ModeratorId = staff.UserId, ModeratorName = staff.Name })
		local items = AppealService.Appealable(cat.UserId)
		t.eq(#items, 1) -- kicks can't be appealed
		t.eq(items[1].Type, "mute")
		t.eq(#AppealService.Appealable(bob.UserId), 1) -- the warning
	end)

	t.test("appeal submit, accept lifts and revokes", function()
		local lifted = {}
		AppealService.SetLifters({
			mute = function(userId)
				table.insert(lifted, userId)
				return true, "unmuted"
			end,
		})
		local key = AppealService.Appealable(cat.UserId)[1].Key
		local a, err = AppealService.Submit(cat, key, "too short")
		t.eq(a, nil)
		t.ok(err and err:find("20"), "needs a real explanation")
		a = AppealService.Submit(cat, key, "I was only sharing a link my friend asked for, sorry")
		t.ok(a ~= nil, "appeal created")
		t.eq(a.Status, "Pending")
		local dup
		dup, err = AppealService.Submit(cat, key, "I was only sharing a link my friend asked for, again")
		t.eq(dup, nil)
		t.ok(err and err:find("waiting"), "one pending appeal per case")
		t.eq(AppealService.PendingCount(), 1)
		local ok, msg = AppealService.Decide(a.Id, staff, true, "fair enough")
		t.ok(ok, msg)
		t.eq(lifted[1], cat.UserId)
		t.eq(AppealService.Get(a.Id).Status, "Accepted")
		t.eq(CaseService.Get(a.CaseId).Status, "Revoked")
		local again = AppealService.Decide(a.Id, staff, false)
		t.eq(again, false)
	end)

	t.test("rejected appeal waits for the cooldown", function()
		local key = AppealService.Appealable(bob.UserId)[1].Key
		local a = AppealService.Submit(bob, key, "the warning was for something another player did")
		t.ok(a ~= nil, "appeal created")
		local ok = AppealService.Decide(a.Id, staff, false, "clip shows you")
		t.ok(ok, "rejected")
		local item = AppealService.Appealable(bob.UserId)[1]
		t.ok(item.Blocked and item.Blocked:find("rejected"), "blocked by cooldown")
		local b, err = AppealService.Submit(bob, key, "please look at this again, it really was not me")
		t.eq(b, nil)
		t.ok(err ~= nil, "cooldown error")
		t.eq(AppealService.Search(AppealService.ParseQuery("rejected"), nil, 10).Total, 1)
		t.eq(AppealService.Search(AppealService.ParseQuery("all type:mute"), nil, 10).Total, 1)
	end)

	ReportService._Reset()
	AppealService._Reset()
end
