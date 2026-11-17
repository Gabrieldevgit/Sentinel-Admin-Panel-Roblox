-- Tests for W08 settings: Shared/UIPrefs (keys, themes, custom binds,
-- palette resolution) and Systems/AdminConfig (text formats, the Before hook
-- rules) plus PermissionSystem default nodes.
return function(t)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):Clone()
	local UIPrefs = require(Shared:WaitForChild("UIPrefs"))

	local Sentinel = script.Parent.Parent
	local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
	local ConfigService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ConfigService"))
	local AdminConfig = require(Sentinel:WaitForChild("Systems"):WaitForChild("AdminConfig"))

	t.test("keys: parse and normalise", function()
		t.eq(UIPrefs.ParseKey("ctrl+shift+k"), "Ctrl+Shift+K")
		t.eq(UIPrefs.ParseKey("Shift + Ctrl + k"), "Ctrl+Shift+K")
		t.eq(UIPrefs.ParseKey("ctrl+shift+p"), nil) -- Shift+P = Roblox Freecam
		t.eq(UIPrefs.ParseKey("ctrl+p"), "Ctrl+P")
		t.eq(UIPrefs.ParseKey("f6"), "F6")
		t.eq(UIPrefs.ParseKey("ctrl+1"), "Ctrl+One")
		t.eq(UIPrefs.ParseKey("none"), "None")
		t.eq(UIPrefs.ParseKey("escape"), nil)
		t.eq(UIPrefs.ParseKey("ctrl+"), nil)
		t.eq(UIPrefs.ParseKey("hyper+k"), nil)
	end)

	t.test("keys: match needs the exact modifiers", function()
		t.ok(UIPrefs.MatchKey("Ctrl+Shift+K", "K", true, true, false))
		t.ok(not UIPrefs.MatchKey("Ctrl+Shift+K", "K", true, false, false))
		t.ok(not UIPrefs.MatchKey("P", "P", true, false, false))
		t.ok(UIPrefs.MatchKey("F6", "F6", false, false, false))
		t.ok(not UIPrefs.MatchKey("None", "F6", false, false, false))
	end)

	t.test("sanitize: keys, custom binds, palette, notifications", function()
		local clean = UIPrefs.Sanitize({
			Keys = {
				QuickFly = "ctrl+f",
				Panel = "escape", -- not allowed: dropped
				Custom = {
					{ Key = "ctrl+h", Command = "  heal me  " },
					{ Key = "none", Command = "x" }, -- no key: dropped
					{ Key = "k", Command = "" }, -- no command: dropped
				},
			},
			Panel = { Custom = { Background = "#000000", Surface = "111111" } }, -- incomplete: dropped
			Notifications = { Duration = 99, Position = "topleft", Sound = "yes" },
		})
		t.eq(clean.Keys.QuickFly, "Ctrl+F")
		t.eq(clean.Keys.Panel, nil)
		t.eq(#clean.Keys.Custom, 1)
		t.eq(clean.Keys.Custom[1].Key, "Ctrl+H")
		t.eq(clean.Keys.Custom[1].Command, "heal me")
		t.eq(clean.Panel, nil)
		t.eq(clean.Notifications.Duration, 15)
		t.eq(clean.Notifications.Position, "TopLeft")
		t.eq(clean.Notifications.Sound, nil)
	end)

	t.test("theme codes round-trip and reject junk", function()
		local palette = UIPrefs.ResolvePalette({ Theme = "Ocean", Accent = "Cyan" })
		local code = UIPrefs.EncodeTheme(palette)
		t.ok(code:match("^SNTL1%-"), "prefix")
		local custom = UIPrefs.DecodeTheme(code)
		t.ok(custom ~= nil, "decoded")
		local again = UIPrefs.ResolvePalette({ Theme = "Custom", Custom = custom })
		for _, key in ipairs(UIPrefs.PALETTE_KEYS) do
			t.eq(UIPrefs.ColorToHex(again[key]), UIPrefs.ColorToHex(palette[key]), key)
		end
		t.eq((UIPrefs.DecodeTheme("SNTL1-000000-111111")), nil)
		t.eq((UIPrefs.DecodeTheme("hello")), nil)
		t.eq((UIPrefs.DecodeTheme("SNTL1-GGGGGG-111111-222222-333333-444444-555555-666666")), nil)
	end)

	t.test("palette: light theme and high contrast", function()
		t.ok(UIPrefs.IsLight(UIPrefs.ResolvePalette({ Theme = "Light" })))
		t.ok(not UIPrefs.IsLight(UIPrefs.ResolvePalette({ Theme = "Nebula" })))
		local hc = UIPrefs.ResolvePalette({ Theme = "Nebula", HighContrast = true })
		t.eq(UIPrefs.ColorToHex(hc.Text), "FFFFFF")
		local hcLight = UIPrefs.ResolvePalette({ Theme = "Light", HighContrast = true })
		t.eq(UIPrefs.ColorToHex(hcLight.Text), "000000")
	end)

	t.test("find: keys and notification settings", function()
		local s, f = UIPrefs.Find("keys.quickfly")
		t.eq(s, "Keys")
		t.eq(f, "QuickFly")
		s, f = UIPrefs.Find("duration", "Notifications")
		t.eq(f, "Duration")
		t.eq((UIPrefs.Parse("Keys", "Palette", "ctrl+k")), "Ctrl+K")
	end)

	t.test("admin config: escalation format", function()
		local steps = AdminConfig.ParseEscalation("5:ban:1d 3:kick")
		t.eq(#steps, 2)
		t.eq(steps[1].Count, 3)
		t.eq(steps[1].Action, "kick")
		t.eq(steps[2].Duration, "1d")
		t.eq(#AdminConfig.ParseEscalation("none"), 0)
		t.eq((AdminConfig.ParseEscalation("3:explode")), nil)
		t.eq((AdminConfig.ParseEscalation("3:kick 3:ban")), nil)
		t.eq((AdminConfig.ParseEscalation("3:ban:soon")), nil)
	end)

	t.test("admin config: default permission nodes are limited", function()
		t.eq(#AdminConfig.ParseNodes("player.fly !page.Developer"), 2)
		t.eq((AdminConfig.ParseNodes("*")), nil)
		t.eq((AdminConfig.ParseNodes("config.edit")), nil)
		t.eq((AdminConfig.ParseNodes("panel.open")), nil)
		t.eq((AdminConfig.ParseNodes("ranks.*")), nil)
		t.eq(#AdminConfig.ParseNodes("!ranks.manage"), 1) -- denying is fine
	end)

	t.test("admin config: required reasons and max duration", function()
		local oldReasons = ConfigService.Get("RequiredReasons")
		local oldMax = ConfigService.Get("MaxPunishmentDuration")
		local oldBan = ConfigService.Get("DefaultBanDuration")
		ConfigService.Set("RequiredReasons", { "kick" })
		ConfigService.Set("MaxPunishmentDuration", "7d")
		ConfigService.Set("DefaultBanDuration", "3d")
		local ok, err = pcall(function()
			t.ok(AdminConfig.CheckCommand({ Name = "kick" }, { Arguments = {} }) ~= nil, "kick without reason refused")
			t.eq(AdminConfig.CheckCommand({ Name = "kick" }, { Arguments = { "spam" } }), nil)
			local ctx = { Arguments = {} } :: any
			t.eq(AdminConfig.CheckCommand({ Name = "ban" }, ctx), nil)
			t.eq(ctx.Modifier, "3d", "default ban duration filled in")
			t.ok(AdminConfig.CheckCommand({ Name = "ban" }, { Arguments = {}, Modifier = "30d" }) ~= nil, "too long")
			t.ok(AdminConfig.CheckCommand({ Name = "mute" }, { Arguments = {} }) ~= nil, "permanent mute over the limit")
			t.eq(AdminConfig.CheckCommand({ Name = "mute" }, { Arguments = {}, Modifier = "1h" }), nil)
		end)
		ConfigService.Set("RequiredReasons", oldReasons)
		ConfigService.Set("MaxPunishmentDuration", oldMax)
		ConfigService.Set("DefaultBanDuration", oldBan)
		if not ok then
			error(err, 0)
		end
	end)

	t.test("default permission nodes apply to players without a rank", function()
		local nobody = { UserId = -9301 } :: any
		local previous = PermissionSystem.GetDefaultNodes()
		PermissionSystem.SetDefaultNodes({ "test.default", "!test.default.no" })
		local ok, err = pcall(function()
			t.ok(PermissionSystem.Has(nobody, "test.default"))
			t.ok(not PermissionSystem.Has(nobody, "test.other"))
			t.eq(PermissionSystem.Evaluate(nobody, "test.default.no"), "deny")
		end)
		PermissionSystem.SetDefaultNodes(previous)
		if not ok then
			error(err, 0)
		end
	end)

	-- W09 layout prefs
	t.test("layout: sanitize mode, tabs and pinned pages", function()
		local clean = UIPrefs.Sanitize({
			Layout = {
				Mode = "mobile",
				Compact = true,
				StatusBar = "yes", -- not a boolean: dropped
				Tabs = { "server", "Players", "server", "Nope" },
				Pinned = { "ranks", "cross-server", "Ranks", "Missing" },
			},
		})
		t.eq(clean.Layout.Mode, "Mobile")
		t.eq(clean.Layout.Compact, true)
		t.eq(clean.Layout.StatusBar, nil)
		t.eq(table.concat(clean.Layout.Tabs, ","), "Server,Players")
		t.eq(table.concat(clean.Layout.Pinned, ","), "Ranks,CrossServer")
		-- no section tabs at all is refused (the panel needs navigation)
		t.eq(UIPrefs.Sanitize({ Layout = { Tabs = {} } }).Layout, nil)
		-- pinned pages are capped
		local many = {}
		for _, id in ipairs(UIPrefs.PAGE_IDS) do
			table.insert(many, id)
		end
		t.eq(#UIPrefs.Sanitize({ Layout = { Pinned = many } }).Layout.Pinned, UIPrefs.MAX_PINNED)
	end)

	t.test("layout: lookups and parsing", function()
		t.eq(UIPrefs.FindPage("crossserver"), "CrossServer")
		t.eq(UIPrefs.FindSection("INSIGHTS"), "Insights")
		t.eq(UIPrefs.FindSection("Ranks"), nil) -- a page, not a section tab
		local s, f = UIPrefs.Find("compact")
		t.eq(s, "Layout")
		t.eq(f, "Compact")
		t.eq((UIPrefs.Parse("Layout", "Mode", "desktop")), "Desktop")
		t.eq((UIPrefs.Parse("Layout", "Tabs", "x")), nil) -- own editor
		local merged = UIPrefs.Merge(UIPrefs.BUILTIN, { Layout = { Compact = true } })
		t.eq(merged.Layout.Compact, true)
		t.eq(#merged.Layout.Tabs, #UIPrefs.NAV_SECTIONS)
	end)
end
