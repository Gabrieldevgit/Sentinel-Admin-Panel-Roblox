-- Remove / clear warnings planning + soft shutdown helpers.
return function(t)
	local Sentinel = script.Parent.Parent
	local PunishmentService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PunishmentService"))
	local SoftShutdownService = require(Sentinel:WaitForChild("Systems"):WaitForChild("SoftShutdownService"))

	local function list(n)
		local out = {}
		for i = 1, n do
			out[i] = { Reason = "r" .. i, IssuedBy = 1, IssuedByName = "Mod", Timestamp = i }
		end
		return out
	end
	local function reasons(l)
		local out = {}
		for _, w in ipairs(l) do
			table.insert(out, w.Reason)
		end
		return table.concat(out, ",")
	end

	t.test("warnings: remove newest n, #index, ranges, all", function()
		local kept, removed = PunishmentService.PlanRemoval(list(5), "2")
		t.eq(reasons(kept), "r1,r2,r3")
		t.eq(reasons(removed), "r4,r5")
		kept = PunishmentService.PlanRemoval(list(5), "#2")
		t.eq(reasons(kept), "r1,r3,r4,r5")
		kept = PunishmentService.PlanRemoval(list(5), "#4-2")
		t.eq(reasons(kept), "r1,r5")
		kept = PunishmentService.PlanRemoval(list(3), "all")
		t.eq(#kept, 0)
		kept = PunishmentService.PlanRemoval(list(3), "10") -- more than they have = all
		t.eq(#kept, 0)
	end)

	t.test("warnings: bad removal specs", function()
		local kept, err = PunishmentService.PlanRemoval(list(0), "1")
		t.eq(kept, nil)
		t.eq(err, "has no warnings")
		kept, err = PunishmentService.PlanRemoval(list(2), "#5")
		t.eq(kept, nil)
		t.ok(tostring(err):find("only has 2"), err)
		t.eq((PunishmentService.PlanRemoval(list(2), "0")), nil)
		t.eq((PunishmentService.PlanRemoval(list(2), "some")), nil)
	end)

	t.test("softshutdown: migration teleport data", function()
		t.eq(SoftShutdownService.IsMigrationData({ SentinelSoftShutdown = 1 }), true)
		t.eq(SoftShutdownService.IsMigrationData({ SentinelMigration = true }), true)
		t.eq(SoftShutdownService.IsMigrationData({ SentinelCreated = true }), false)
		t.eq(SoftShutdownService.IsMigrationData(nil), false)
		t.eq(SoftShutdownService.IsMigrationData("x"), false)
	end)
end
