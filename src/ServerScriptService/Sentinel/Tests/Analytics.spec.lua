-- W16 analytics: bucket merging (cross-server), ranges, rollups, totals.
return function(t)
	local Sentinel = script.Parent.Parent
	local A = require(Sentinel:WaitForChild("Systems"):WaitForChild("AnalyticsService"))

	t.test("analytics: bucket merge adds counts, keeps peaks and minimums", function()
		local a = A.NewBucket(0)
		a.CS, a.PMax, a.FMin, a.PSum, a.PN = 3, 5, 55, 10, 2
		local b = A.NewBucket(0)
		b.CS, b.PMax, b.FMin, b.CD = 2, 9, 40, 1
		A.MergeBucket(a, b)
		t.eq(a.CS, 5)
		t.eq(a.CD, 1)
		t.eq(a.PMax, 9)
		t.eq(a.FMin, 40)
		t.eq(a.PSum, 10)
	end)

	t.test("analytics: day merge from two servers", function()
		local s1 = { H = { ["3"] = { T = 10800, CS = 4, PMax = 2 } }, Cmd = { kick = 2 }, Mods = { ["1"] = { N = "Mod", C = 2 } }, Srv = { a = 5 } }
		local s2 = { H = { ["3"] = { T = 10800, CS = 1, PMax = 6 }, ["4"] = { T = 14400, CF = 2 } }, Cmd = { kick = 1, ban = 1 }, Mods = { ["1"] = { N = "Mod", C = 1 } }, Srv = { b = 7 } }
		local day = A.MergeDay(A.MergeDay(nil, s1), s2)
		t.eq(day.H["3"].CS, 5)
		t.eq(day.H["3"].PMax, 6)
		t.eq(day.H["4"].CF, 2)
		t.eq(day.Cmd.kick, 3)
		t.eq(day.Cmd.ban, 1)
		t.eq(day.Mods["1"].C, 3)
		t.ok(day.Srv.a and day.Srv.b, "both servers seen")
	end)

	t.test("analytics: ranges", function()
		local now = 1764000000 + 1234 -- some UTC time
		local r = A.ParseRange("24h", nil, nil, now)
		t.eq(r.To - r.From, 86400)
		t.eq(r.Step, 3600)
		t.eq(r.To % 3600, 0)
		t.eq(A.ParseRange("7d", nil, nil, now).Step, 6 * 3600)
		t.eq(A.ParseRange("30d", nil, nil, now).Step, 86400)
		local c = A.ParseRange("custom", "2025-11-20", "2025-11-22", now)
		t.eq(os.date("!%Y-%m-%d", c.From), "2025-11-20")
		t.eq(c.To - c.From, 3 * 86400)
		local swapped = A.ParseRange("custom", "2025-11-22", "2025-11-20", now)
		t.eq(swapped.From, c.From)
		t.eq(A.ParseRange("custom", "nope", nil, now), nil)
		t.eq(A.ParseRange("500d", nil, nil, now), nil)
		t.eq(A.ParseRange("10m", nil, nil, now), nil)
		t.eq(A.DayKey(c.From), "Day_20251120")
	end)

	t.test("analytics: rollup + totals + compare helpers", function()
		local range = { From = 0, To = 4 * 3600, Step = 2 * 3600 }
		local hours = {
			[0] = { T = 0, CS = 2, CF = 1, PMax = 3, PSum = 6, PN = 2, FSum = 120, FN = 2 },
			[3600] = { T = 3600, CS = 1, CD = 1, PMax = 5, Mod = 2 },
			[7200] = { T = 7200, ETx = 4, EVol = 100 },
		}
		local series = A.Rollup(hours, range)
		t.eq(#series, 2)
		t.eq(series[1].Success, 3)
		t.eq(series[1].Commands, 5)
		t.eq(series[1].Players, 5)
		t.eq(series[1].Fps, 60)
		t.eq(series[1].Moderation, 2)
		t.eq(series[2].Economy, 4)
		t.eq(series[2].Fps, nil)
		local totals = A.Totals(series)
		t.eq(totals.Commands, 5)
		t.eq(totals.SuccessRate, 60)
		t.eq(totals.Peak, 5)
		t.eq(totals.EconomyVolume, 100)
		t.eq(A.PctChange(10, 15), 50)
		t.eq(A.PctChange(0, 15), nil)
		local top = A.TopN({ a = 1, b = 5, c = 3 }, 2)
		t.eq(top[1].Key, "b")
		t.eq(#top, 2)
	end)
end
