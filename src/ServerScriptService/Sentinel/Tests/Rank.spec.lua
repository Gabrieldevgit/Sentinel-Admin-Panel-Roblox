-- Tests for Systems/RankService default templates. Outside a running game
-- RankService loads defaults read-only, without touching the DataStore.
return function(t)
	local Sentinel = script.Parent.Parent
	local RankService = require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))
	local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))

	t.test("default templates sorted by priority", function()
		local ranks = RankService.GetRanks()
		local names = {}
		for _, r in ipairs(ranks) do
			table.insert(names, r.Name)
		end
		t.eq(table.concat(names, ","), "Owner,Developer,SuperAdmin,Admin,Moderator,VIP")
	end)

	t.test("rank names resolve case-insensitively", function()
		t.eq(RankService.ResolveRankName("superadmin"), "SuperAdmin")
		t.eq(RankService.ResolveRankName("nope"), nil)
	end)

	t.test("default permissions and panel access", function()
		local mod = { UserId = -8001 } :: any
		local vip = { UserId = -8002 } :: any
		local dev = { UserId = -8003 } :: any
		PermissionSystem.AssignRole(mod, "Moderator")
		PermissionSystem.AssignRole(vip, "VIP")
		PermissionSystem.AssignRole(dev, "Developer")
		t.ok(PermissionSystem.Has(mod, "panel.open"), "moderator can open panel")
		t.ok(not PermissionSystem.Has(vip, "panel.open"), "vip cannot open panel")
		t.ok(PermissionSystem.Has(vip, "player.fly"), "vip can fly")
		t.ok(not PermissionSystem.Has(mod, "moderation.ban"), "moderator cannot ban")
		t.ok(PermissionSystem.Has(dev, "moderation.ban"), "developer inherits admin")
		t.ok(PermissionSystem.Has(dev, "ranks.manage"), "developer inherits superadmin")
		t.ok(not PermissionSystem.Has(dev, "developer.execute"), "only owner may execute code")
		t.eq(RankService.GetTopRank(dev), "Developer")
	end)

	t.test("creator binding is protected and present", function()
		local found = false
		for _, b in ipairs(RankService.GetBindings("Owner")) do
			if b.Kind == "Creator" and b.Protected then
				found = true
			end
		end
		t.ok(found)
	end)

	local owner = { UserId = -8004, Name = "TestOwner" } :: any
	PermissionSystem.AssignRole(owner, "Owner")

	t.test("mutations are refused when read-only", function()
		local ok = RankService.CreateRank(owner, "Tester", 5)
		t.ok(not ok)
		t.ok(RankService.IsReadOnly())
	end)

	-- Everything below runs with in-memory writes (saves are no-ops offline).
	local admin = { UserId = -8005, Name = "TestAdmin" } :: any
	PermissionSystem.AssignRole(admin, "Admin")

	t.test("hierarchy: only ranks below your own", function()
		t.ok(RankService._AllowWritesForTests(), "writes enabled offline")
		t.ok(not (RankService.CreateRank(admin, "TooHigh", 60)), "admin cannot create above 50")
		t.ok(not (RankService.CreateRank(admin, "Equal", 50)), "admin cannot create at 50")
		t.ok((RankService.CreateRank(admin, "Helper", 40, { "Moderator" })), "admin can create below")
		t.ok((RankService.EditRank(admin, "Moderator", "color", "10,20,30")), "admin can edit moderator")
		t.ok(not (RankService.EditRank(admin, "SuperAdmin", "color", "10,20,30")), "admin cannot edit superadmin")
		t.ok(not (RankService.EditRank(admin, "Helper", "priority", "55")), "admin cannot raise above self")
		t.ok(not (RankService.CreateRank(admin, "Sneaky", 5, { "Developer" })), "admin cannot inherit a higher rank")
	end)

	t.test("cannot grant a permission you don't have", function()
		t.ok(not (RankService.SetNode(admin, "Helper", "developer.execute", true)))
		t.ok((RankService.SetNode(admin, "Helper", "player.fly", true)))
		t.ok(not (RankService.SetNode(admin, "Helper", "bad", true)), "nodes need category.action")
		t.ok(not (RankService.SetNode(admin, "Helper", "a..b", true)), "no empty segments")
	end)

	t.test("rename keeps inheritance and assignments", function()
		t.ok((RankService.AddBinding(admin, "group", 4242, "Helper")))
		t.ok((RankService.CreateRank(owner, "Junior", 5, { "Helper" })))
		t.ok((RankService.RenameRank(owner, "Helper", "Mentor")))
		t.eq(RankService.GetRank("Junior").Inherits[1], "Mentor")
		t.eq(#RankService.GetBindings("Mentor"), 1)
		t.ok(PermissionSystem.IsRoleDefined("Mentor"))
		t.ok(not PermissionSystem.IsRoleDefined("Helper"))
	end)

	t.test("assignment rules and self-demotion", function()
		t.ok(not (RankService.AddBinding(admin, "group", 4243, "Admin")), "admin cannot assign admin")
		t.ok((RankService.AddBinding(owner, "userid", 156, "Admin")), "owner can assign admin")
		local selfAdmin = { UserId = 156, Name = "SelfAdmin" } :: any
		PermissionSystem.AssignRole(selfAdmin, "Admin")
		local ok, msg = RankService.RemoveUserRank(selfAdmin, 156, "Admin")
		t.ok(not ok, "cannot remove own highest rank")
		t.ok(msg:find("own") ~= nil or msg:find("below") ~= nil, msg)
		t.ok(not (RankService.RemoveBinding(owner, "creator")), "creator binding protected")
		t.ok((RankService.AddBinding(owner, "grouprole", 4242, "Moderator", 3600, 200)))
		local found
		for _, b in ipairs(RankService.GetBindings("Moderator")) do
			if b.Kind == "GroupRole" then
				found = b
			end
		end
		t.ok(found and found.MinRank == 200 and found.ExpiresAt ~= nil, "grouprole with min rank and expiry")
	end)

	t.test("deny nodes and presets", function()
		t.ok((RankService.CreateRank(owner, "Builder", 20)))
		t.ok((RankService.SetNode(admin, "Builder", "!moderation.kick", true)), "admin may add a denial")
		t.ok(not (RankService.SetNode(owner, "Builder", "!*", true)), "cannot deny everything")
		t.ok(table.find(RankService.GetRank("Builder").Nodes, "!moderation.kick") ~= nil)
		local ok, msg = RankService.ApplyPreset(admin, "Builder", "teleport")
		t.ok(ok, msg)
		t.ok(PermissionSystem.RoleHas("Builder", "player.bring"))
		t.ok(not (RankService.ApplyPreset(admin, "Builder", "teleport")), "re-applying adds nothing")
		local okDev, msgDev = RankService.ApplyPreset(admin, "Builder", "DevReadOnly")
		t.ok(okDev, msgDev) -- admin holds the read-only developer nodes
		t.ok(not (RankService.ApplyPreset(admin, "Owner", "teleport")), "owner rank is fixed")
		t.ok(not (RankService.ApplyPreset(admin, "Builder", "nope")))
	end)

	t.test("target protection by rank", function()
		local mod = { UserId = -8010, Name = "TMod" } :: any
		local mod2 = { UserId = -8011, Name = "TMod2" } :: any
		local guest = { UserId = -8012, Name = "Guest" } :: any
		PermissionSystem.AssignRole(mod, "Moderator")
		PermissionSystem.AssignRole(mod2, "Moderator")
		t.ok(RankService.CanTarget(admin, mod), "admin can target moderator")
		t.ok(not RankService.CanTarget(mod, admin), "moderator cannot target admin")
		t.ok(not RankService.CanTarget(mod, mod2), "equal ranks are protected")
		t.ok(RankService.CanTarget(mod, guest), "unranked players are not protected")
		t.ok(RankService.CanTarget(mod, mod), "yourself is fine")
		t.ok(not RankService.CanTarget(admin, owner), "nobody below can target the owner")
	end)

	t.test("delete cleans up inheritance and assignments", function()
		t.ok(not (RankService.DeleteRank(admin, "Admin")), "admin cannot delete own rank")
		t.ok((RankService.DeleteRank(owner, "Mentor")))
		t.eq(#RankService.GetRank("Junior").Inherits, 0)
		t.eq(#RankService.GetBindings("Mentor"), 0)
		t.ok(#RankService.GetHistory(50) >= 5, "changes recorded in history")
	end)
end
