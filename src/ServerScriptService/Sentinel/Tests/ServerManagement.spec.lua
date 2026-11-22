-- Tests for W22 server management: the ServerStateService join gate
-- (EvaluateJoin), soft capacity, custom messages and the privateservers
-- admin config entry.
return function(t)
	local Sentinel = script.Parent.Parent
	local Systems = Sentinel:WaitForChild("Systems")
	local ServerStateService = require(Systems:WaitForChild("ServerStateService"))
	local AdminConfig = require(Systems:WaitForChild("AdminConfig"))
	local M = ServerStateService.DEFAULT_MESSAGES

	t.test("join gate: lock, maintenance, custom messages, bypass", function()
		t.eq(ServerStateService.EvaluateJoin({}), nil)
		t.eq(ServerStateService.EvaluateJoin({ Locked = true }), M.Lock)
		t.eq(ServerStateService.EvaluateJoin({ Locked = true, LockMessage = "Event later" }), "Event later")
		t.eq(ServerStateService.EvaluateJoin({ Maintenance = true }), M.Maintenance)
		t.eq(ServerStateService.EvaluateJoin({ Maintenance = true, MaintenanceMessage = "Back at 5" }), "Back at 5")
		t.eq(ServerStateService.EvaluateJoin({ Locked = true, Maintenance = true, Bypass = true }), nil)
	end)

	t.test("join gate: whitelist mode and soft cap", function()
		t.eq(ServerStateService.EvaluateJoin({ WhitelistMode = true }), M.Whitelist)
		t.eq(ServerStateService.EvaluateJoin({ WhitelistMode = true, Whitelisted = true }), nil)
		t.eq(ServerStateService.EvaluateJoin({ WhitelistMode = true, Bypass = true }), nil)
		t.eq(ServerStateService.EvaluateJoin({ Capacity = 5, PlayerCount = 5 }), nil)
		t.eq(ServerStateService.EvaluateJoin({ Capacity = 5, PlayerCount = 6 }), M.Capacity)
		t.eq(ServerStateService.EvaluateJoin({ Capacity = 5, PlayerCount = 6, Bypass = true }), nil)
	end)

	t.test("join gate: private server access", function()
		local base = { IsPrivate = true }
		local function with(extra)
			local info = table.clone(base)
			for k, v in pairs(extra) do
				info[k] = v
			end
			return ServerStateService.EvaluateJoin(info)
		end
		t.eq(with({ PrivateAccess = "open" }), nil)
		t.eq(with({ PrivateAccess = "friends" }), M.PrivateFriends)
		t.eq(with({ PrivateAccess = "friends", IsFriend = true }), nil)
		t.eq(with({ PrivateAccess = "friends", IsStaff = true }), nil)
		t.eq(with({ PrivateAccess = "staff", IsFriend = true }), M.PrivateStaff)
		t.eq(with({ PrivateAccess = "staff", IsStaff = true }), nil)
		t.eq(with({ PrivateAccess = "staff", IsOwner = true }), nil)
		-- Public servers ignore the setting.
		t.eq(ServerStateService.EvaluateJoin({ PrivateAccess = "staff" }), nil)
	end)

	t.test("state: capacity and messages", function()
		ServerStateService.SetCapacity(8)
		t.eq(ServerStateService.GetCapacity(), 8)
		ServerStateService.SetCapacity(0)
		t.eq(ServerStateService.GetCapacity(), nil)
		ServerStateService.SetLocked(true, "  Closed for testing  ")
		t.eq(ServerStateService.GetMessages().Lock, "Closed for testing")
		ServerStateService.SetLocked(false, "ignored")
		t.eq(ServerStateService.GetMessages().Lock, nil)
		t.eq(ServerStateService.IsLocked(), false)
		ServerStateService.SetMaintenanceMode(true, "")
		t.eq(ServerStateService.GetMessages().Maintenance, nil)
		ServerStateService.SetMaintenanceMode(false)
	end)

	t.test("admin config: privateservers", function()
		local entry = AdminConfig.Find("privateservers")
		t.ok(entry ~= nil, "entry exists")
		t.eq((entry.Parse("Friends")), "friends")
		t.eq((entry.Parse("staff")), "staff")
		local bad = entry.Parse("everyone")
		t.eq(bad, nil)
	end)
end
