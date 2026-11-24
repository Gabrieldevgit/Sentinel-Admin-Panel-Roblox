-- Tests for W23 polls: Systems/PollService pure helpers + command registration.
return function(t)
	local Sentinel = script.Parent.Parent
	local PollService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PollService"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

	local function words(s: string): { string }
		return string.split(s, " ")
	end

	t.test("poll: parse question and options", function()
		local spec = PollService.ParseSpec(words("Best map? | Desert | Forest |City"))
		t.ok(spec ~= nil, "parsed")
		t.eq(spec.Question, "Best map?")
		t.eq(#spec.Options, 3)
		t.eq(spec.Options[3], "City")
		t.eq(spec.Duration, PollService.DEFAULT_DURATION)
		t.eq(spec.AllowChange, true)
		t.eq(spec.ShowLive, true)
	end)

	t.test("poll: yes / no default and options", function()
		local spec = PollService.ParseSpec(words("time=2m change=off results=end announce=off Another round?"))
		t.ok(spec ~= nil, "parsed")
		t.eq(spec.Options[1], "Yes")
		t.eq(spec.Options[2], "No")
		t.eq(spec.Duration, 120)
		t.eq(spec.AllowChange, false)
		t.eq(spec.ShowLive, false)
		t.eq(spec.Announce, false)
		local manual = PollService.ParseSpec(words("time=none Q | a | b"))
		t.eq(manual.Duration, 0)
		-- an unknown key=value word starts the question
		local q = PollService.ParseSpec(words("x=5 is fine? | y | n"))
		t.eq(q.Question, "x=5 is fine?")
	end)

	t.test("poll: parse errors", function()
		local function fails(s: string)
			local spec, err = PollService.ParseSpec(words(s))
			t.ok(spec == nil and type(err) == "string", s)
		end
		fails("")
		fails("time=5 Q | a | b") -- below 10 s
		fails("time=2h Q | a | b") -- above 1 h
		fails("change=maybe Q | a | b")
		fails("results=never Q | a | b")
		fails("Q | only one")
		fails("Q | a | A") -- duplicate
		fails("Q | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9")
		fails("Q | " .. string.rep("x", PollService.MAX_OPTION + 1) .. " | b")
	end)

	t.test("poll: votes, change, counts", function()
		local votes, counts = {}, { 0, 0, 0 }
		local ok, _, changed = PollService.ApplyVote(votes, counts, 1, 2, true)
		t.ok(ok and changed, "first vote")
		t.eq(counts[2], 1)
		ok, _, changed = PollService.ApplyVote(votes, counts, 1, 2, true)
		t.ok(ok and not changed, "same vote again")
		ok, _, changed = PollService.ApplyVote(votes, counts, 1, 3, true)
		t.ok(ok and changed, "changed")
		t.eq(counts[2], 0)
		t.eq(counts[3], 1)
		ok = PollService.ApplyVote(votes, counts, 1, 1, false)
		t.ok(not ok, "no change allowed")
		t.eq(counts[3], 1)
		ok = PollService.ApplyVote(votes, counts, 2, 4, true)
		t.ok(not ok, "out of range")
		ok = PollService.ApplyVote(votes, counts, 2, 0, true)
		t.ok(not ok, "zero")
	end)

	t.test("poll: totals, ties and cross-server sums", function()
		local total, winners = PollService.Totals({ 3, 5, 5, 0 })
		t.eq(total, 13)
		t.eq(#winners, 2)
		t.eq(winners[1], 2)
		local none, nobody = PollService.Totals({ 0, 0 })
		t.eq(none, 0)
		t.eq(#nobody, 0)
		local sum = PollService.Sum(3, { { 1, 2, 3 }, { 4, "x", -2, 9 }, "bad" })
		t.eq(sum[1], 5)
		t.eq(sum[2], 2)
		t.eq(sum[3], 3)
		t.eq(#sum, 3)
	end)

	t.test("poll: commands registered", function()
		if not CommandRegistry.Resolve("poll") then
			require(Sentinel:WaitForChild("Commands"):WaitForChild("Server"):WaitForChild("Polls"))
		end
		t.ok(CommandRegistry.Resolve("createpoll") ~= nil, "poll alias")
		t.ok(CommandRegistry.Resolve("globalpoll") ~= nil, "gpoll alias")
		local vote = CommandRegistry.Resolve("vote")
		t.ok(vote ~= nil and vote.Public == true, "vote is public")
		t.ok(CommandRegistry.Resolve("closepoll") ~= nil, "endpoll alias")
		t.ok(CommandRegistry.Resolve("cancelpoll") ~= nil, "cancelpoll")
	end)
end
