-- Tests for the HD Admin gaps: server bans (this server only), chat tags,
-- map snapshots and server music.
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

	t.test("map: names and map objects", function()
		local MapService = require(Sentinel.Systems.MapService)
		t.eq(MapService.CleanName(nil), "default")
		t.eq(MapService.CleanName("Arena 1!"), "arena1")
		t.eq(MapService.CleanName("!!!"), nil)
		t.eq(MapService.CleanName(string.rep("a", 30)), nil)
		t.eq(MapService.IsMapObject(workspace.Terrain), false)
		local part = Instance.new("Part")
		t.eq(MapService.IsMapObject(part), true)
		part:SetAttribute("SentinelMapIgnore", true)
		t.eq(MapService.IsMapObject(part), false)
		part.Name = "SentinelJailSpawn"
		part:SetAttribute("SentinelMapIgnore", nil)
		t.eq(MapService.IsMapObject(part), false)
		part:Destroy()
	end)

	t.test("map: save, change, load, delete", function()
		local MapService = require(Sentinel.Systems.MapService)
		-- A detached stand-in for Workspace, so the test never touches the map.
		local root = Instance.new("Folder")
		local part = Instance.new("Part")
		part.Name = "__MapSpecPart"
		part.Parent = root
		local scripted = Instance.new("Model")
		scripted.Name = "__MapSpecScripted"
		local script_ = Instance.new("Script")
		script_.Disabled = true
		script_.Parent = scripted
		scripted.Parent = root
		t.eq((MapService.Save("__spec", "Spec", root)), true)
		part:Destroy()
		local extra = Instance.new("Part")
		extra.Name = "__Extra"
		extra.Parent = root
		t.eq((MapService.Load("__spec", root)), true)
		t.eq(root:FindFirstChild("__MapSpecPart") ~= nil, true)
		t.eq(root:FindFirstChild("__Extra"), nil) -- replaced
		t.eq(root:FindFirstChild("__MapSpecScripted"), scripted) -- live scripted object kept
		local count = 0
		for _, c in ipairs(root:GetChildren()) do
			if c.Name == "__MapSpecScripted" then
				count += 1
			end
		end
		t.eq(count, 1)
		root:Destroy()
		t.eq(MapService.Delete("__spec"), true)
		t.eq(MapService.Has("__spec"), false)
		t.eq((MapService.Load("__spec")), false)
		local folder = game:GetService("ServerStorage"):FindFirstChild("SentinelMapSnapshots")
		if folder and #folder:GetChildren() == 0 and not game:GetService("RunService"):IsRunning() then
			folder:Destroy()
		end
	end)

	t.test("music: id parsing", function()
		local MusicService = require(Sentinel.Systems.MusicService)
		t.eq(MusicService.ParseId("1837849285"), 1837849285)
		t.eq(MusicService.ParseId("rbxassetid://123"), 123)
		t.eq(MusicService.ParseId("abc"), nil)
		t.eq(MusicService.ParseId("0"), nil)
		t.eq(MusicService.ParseId(nil), nil)
		t.eq((MusicService.SetVolume(20)), false)
		t.eq((MusicService.SetPitch(0)), false)
	end)

	t.test("map + music: commands registered", function()
		require(Sentinel.Commands.Server.Map)
		require(Sentinel.Commands.Server.Music)
		for _, name in ipairs({ "savemap", "loadmap", "clearmap", "maps", "deletemap", "music", "stopmusic", "volume", "pitch", "nowplaying" }) do
			t.eq(CommandRegistry.Resolve(name) ~= nil, true)
		end
		t.eq(CommandRegistry.Resolve("np") ~= nil, true)
		t.eq(CommandRegistry.Resolve("smap") ~= nil, true)
	end)
end
