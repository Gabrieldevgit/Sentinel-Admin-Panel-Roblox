-- Tests for the HD Admin gaps: server bans (this server only) and chat tags.
return function(t)
	local Sentinel = script.Parent.Parent
	local ChatTagService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ChatTagService"))
	local ServerBan = require(Sentinel:WaitForChild("Commands"):WaitForChild("Moderation"):WaitForChild("ServerBan"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
	require(Sentinel.Commands.Player.ChatTags)

	t.test("chattag: colours", function()
		t.eq(ChatTagService.ParseColor("red"), Color3.fromRGB(255, 70, 70))
		t.eq(ChatTagService.ParseColor("#FF8800"), Color3.fromRGB(255, 136, 0))
		t.eq(ChatTagService.ParseColor("00ff00"), Color3.fromRGB(0, 255, 0))
		t.eq(ChatTagService.ParseColor("10,20,30"), Color3.fromRGB(10, 20, 30))
		t.eq(ChatTagService.ParseColor("300,0,0"), nil)
		t.eq(ChatTagService.ParseColor("rainbow"), nil)
		t.eq(ChatTagService.ParseColor(""), nil)
	end)

	t.test("chattag: clean strips rich text and caps length", function()
		t.eq(ChatTagService.Clean("  <b>VIP</b>  "), "bVIP/b")
		t.eq(ChatTagService.Clean("[Admin]"), "Admin")
		t.eq(ChatTagService.Clean('a&b"c'), "abc")
		t.eq(#ChatTagService.Clean(string.rep("x", 40)), ChatTagService.MAX_LENGTH)
	end)

	t.test("serverban: add, list, expiry, remove", function()
		ServerBan._ClearForTests()
		local now = os.time()
		ServerBan.Add({ UserId = -101, Name = "Alpha", Reason = "r", By = "Mod", At = now })
		ServerBan.Add({ UserId = -102, Name = "Beta", Reason = "r", By = "Mod", At = now + 1, ExpiresAt = now + 60 })
		ServerBan.Add({ UserId = -103, Name = "Gone", Reason = "r", By = "Mod", At = now, ExpiresAt = now - 1 })
		local list = ServerBan.List()
		t.eq(#list, 2)
		t.eq(list[1].Name, "Beta") -- newest first
		t.eq(ServerBan.Get(-103), nil) -- expired
		t.eq(ServerBan.Remove(-101), true)
		t.eq(ServerBan.Remove(-101), false)
		t.eq(#ServerBan.List(), 1)
		ServerBan._ClearForTests()
	end)

	t.test("hd gaps: commands registered", function()
		for _, name in ipairs({ "serverban", "unserverban", "serverbans", "chattag", "unchattag", "chattags" }) do
			t.eq(CommandRegistry.Resolve(name) ~= nil, true)
		end
		t.eq(CommandRegistry.Resolve("sban") ~= nil, true)
		t.eq(CommandRegistry.Resolve("tag") ~= nil, true)
	end)
end
