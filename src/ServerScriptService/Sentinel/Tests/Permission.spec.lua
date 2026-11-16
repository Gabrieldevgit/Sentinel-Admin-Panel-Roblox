-- Tests for Core/PermissionSystem. Uses fake players (only UserId is read)
-- with negative ids and test-only role names, and a fresh module copy when
-- run from Studio's command bar / execute_luau, so it never touches the
-- live server's role table.
return function(t)
	local PermissionSystem = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PermissionSystem"))

	local modA = { UserId = -9001 } :: any
	local adminB = { UserId = -9002 } :: any
	local nobody = { UserId = -9003 } :: any

	PermissionSystem.DefineRole("TestMod", { "moderation.kick", "moderation.mute" })
	PermissionSystem.DefineRole("TestAdmin", { "player.*" }, { "TestMod" })
	PermissionSystem.DefineRole("TestCycleA", { "a.node" }, { "TestCycleB" })
	PermissionSystem.DefineRole("TestCycleB", { "b.node" }, { "TestCycleA" })
	PermissionSystem.AssignRole(modA, "TestMod")
	PermissionSystem.AssignRole(adminB, "TestAdmin")

	t.test("exact node", function()
		t.ok(PermissionSystem.Has(modA, "moderation.kick"))
		t.ok(not PermissionSystem.Has(modA, "moderation.ban"))
	end)

	t.test("wildcard matches children but not siblings", function()
		t.ok(PermissionSystem.Has(adminB, "player.fly"))
		t.ok(PermissionSystem.Has(adminB, "player.fly.others"))
		t.ok(not PermissionSystem.Has(adminB, "playerx.fly"))
	end)

	t.test("inheritance", function()
		t.ok(PermissionSystem.Has(adminB, "moderation.mute"))
	end)

	t.test("no roles means no permissions and not staff", function()
		t.ok(not PermissionSystem.Has(nobody, "moderation.kick"))
		t.eq(#PermissionSystem.GetRoles(nobody), 0)
	end)

	t.test("inheritance cycles terminate", function()
		local p = { UserId = -9004 } :: any
		PermissionSystem.AssignRole(p, "TestCycleA")
		t.ok(PermissionSystem.Has(p, "b.node"))
		t.ok(not PermissionSystem.Has(p, "c.node"))
		PermissionSystem.RevokeRole(p, "TestCycleA")
		t.ok(not PermissionSystem.Has(p, "a.node"))
	end)

	t.test("temporary grant works and expires", function()
		PermissionSystem.GrantTemporary(nobody, "server.lock", 60)
		t.ok(PermissionSystem.Has(nobody, "server.lock"))
		PermissionSystem.GrantTemporary(nobody, "server.unlock", -1)
		t.ok(not PermissionSystem.Has(nobody, "server.unlock"))
	end)

	t.test("explicit deny", function()
		PermissionSystem.DefineRole("TestDev", { "developer.*", "!developer.execute" })
		PermissionSystem.DefineRole("TestDevChild", { "developer.execute" }, { "TestDev" })
		PermissionSystem.DefineRole("TestVipDeny", { "!moderation.kick" })
		local dev = { UserId = -9101 } :: any
		local child = { UserId = -9102 } :: any
		local both = { UserId = -9103 } :: any
		PermissionSystem.AssignRole(dev, "TestDev")
		PermissionSystem.AssignRole(child, "TestDevChild")
		PermissionSystem.AssignRole(both, "TestMod")
		PermissionSystem.AssignRole(both, "TestVipDeny")
		t.ok(PermissionSystem.Has(dev, "developer.stats"), "wildcard still allows the rest")
		t.ok(not PermissionSystem.Has(dev, "developer.execute"), "deny beats wildcard in the same rank")
		t.eq(PermissionSystem.Evaluate(dev, "developer.execute"), "deny")
		t.eq(PermissionSystem.Evaluate(dev, "economy.give"), nil)
		t.ok(PermissionSystem.Has(child, "developer.execute"), "child rank can re-allow")
		t.ok(not PermissionSystem.Has(child, "developer.datastore.write") == false, "child inherits parent allows")
		t.ok(PermissionSystem.Has(both, "moderation.kick"), "another rank's deny can't remove a staff allow")
		t.ok(PermissionSystem.RoleHas("TestDev", "developer.console"))
		t.ok(not PermissionSystem.RoleHas("TestDev", "developer.execute"))
	end)

	t.test("unknown role assignment errors", function()
		t.ok(not pcall(PermissionSystem.AssignRole, nobody, "DoesNotExist"))
	end)
end
