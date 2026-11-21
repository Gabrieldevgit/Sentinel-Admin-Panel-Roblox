-- Tests for W13 offline profiles: the join / leave merge that keeps
-- sessions, play time and usernames seen, and the age formatter.
return function(t)
	local Sentinel = script.Parent.Parent
	local PlayerProfileService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PlayerProfileService"))

	t.test("first join creates a profile", function()
		local p = PlayerProfileService.Merge(nil, { UserId = 5, Name = "Alpha", DisplayName = "A", AccountAge = 40 }, "join", 1000, nil, "srv")
		t.eq(p.Sessions, 1)
		t.eq(p.FirstSeen, 1000)
		t.eq(p.LastSeen, 1000)
		t.eq(p.AccountAge, 40)
		t.eq(p.LastServer, "srv")
		t.eq(p.Names[1], "Alpha")
		t.eq(p.PlayTime, 0)
	end)

	t.test("leave adds play time, rename is remembered", function()
		local p = PlayerProfileService.Merge(nil, { UserId = 5, Name = "Alpha" }, "join", 1000)
		p = PlayerProfileService.Merge(p, { UserId = 5, Name = "Alpha" }, "leave", 1600, 600)
		t.eq(p.PlayTime, 600)
		t.eq(p.Sessions, 1)
		p = PlayerProfileService.Merge(p, { UserId = 5, Name = "Beta" }, "join", 5000)
		t.eq(p.Sessions, 2)
		t.eq(p.FirstSeen, 1000)
		t.eq(#p.Names, 2)
		t.eq(p.Name, "Beta")
		for i = 1, 15 do
			p = PlayerProfileService.Merge(p, { UserId = 5, Name = "N" .. i }, "join", 6000 + i)
		end
		t.eq(#p.Names, 10)
		t.eq(p.Names[10], "N15")
	end)

	t.test("age format", function()
		t.eq(PlayerProfileService.FormatAge(45), "45s")
		t.eq(PlayerProfileService.FormatAge(3 * 3600 + 120), "3h 2m")
		t.eq(PlayerProfileService.FormatAge(2 * 86400 + 3600), "2d 1h")
	end)

	t.test("resolve rejects bad input without network", function()
		t.eq((PlayerProfileService.Resolve("")), nil)
		t.eq((PlayerProfileService.Resolve("-4")), nil)
		t.eq((PlayerProfileService.Resolve("has space")), nil)
	end)
end
