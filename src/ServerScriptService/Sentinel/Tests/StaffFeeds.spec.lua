-- Tests for the M-panel gaps: ShutdownService warning marks, ChatLogService
-- search, AlertService classification, broadcast templates, new commands.
return function(t)
	local Sentinel = script.Parent.Parent
	local Systems = Sentinel:WaitForChild("Systems")
	local ShutdownService = require(Systems:WaitForChild("ShutdownService"))
	local ChatLogService = require(Systems:WaitForChild("ChatLogService"))
	local AlertService = require(Systems:WaitForChild("AlertService"))
	local AnnouncementService = require(Systems:WaitForChild("AnnouncementService"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

	t.test("shutdown: warning marks below the total", function()
		local m = ShutdownService.WarningMarks(300)
		t.eq(table.concat(m, ","), "120,60,30,10")
		t.eq(table.concat(ShutdownService.WarningMarks(301), ","), "300,120,60,30,10")
		t.eq(#ShutdownService.WarningMarks(10), 0)
		t.eq(ShutdownService.Pretty(90), "1 min 30 s")
		t.eq(ShutdownService.Pretty(3600), "1 hour")
	end)

	t.test("chatlog: note, search, query, clear", function()
		ChatLogService.Clear()
		local bob = { UserId = 1, Name = "Bob", DisplayName = "Bobby" }
		local amy = { UserId = 2, Name = "Amy", DisplayName = "Amy" }
		ChatLogService.Note(bob, "hello there")
		ChatLogService.Note(amy, "free robux scam link")
		ChatLogService.Note(bob, ";kick amy")
		ChatLogService.Note(bob, "   ")
		t.eq(ChatLogService.Count(), 3)
		local all = ChatLogService.Search(nil, 10)
		t.eq(all[1].Text, ";kick amy") -- newest first
		t.eq(all[1].Command, true)
		t.eq(#ChatLogService.Search(ChatLogService.ParseQuery("player:bo"), 10), 2)
		t.eq(#ChatLogService.Search(ChatLogService.ParseQuery("scam"), 10), 1)
		t.eq(#ChatLogService.Search(ChatLogService.ParseQuery("player:amy hello"), 10), 0)
		t.eq(#ChatLogService.Search({ Commands = false }, 10), 2)
		t.eq(ChatLogService.Clear(), 3)
		t.eq(ChatLogService.Count(), 0)
	end)

	t.test("alerts: classify commands", function()
		local function c(def, raw, targets, risk)
			return AlertService.Classify(def, { RawInput = raw, Targets = targets }, risk)
		end
		t.eq(c({ Name = "shutdown" }, "shutdown", {}, "critical"), "critical")
		t.eq(c({ Name = "ban" }, "ban bob", { {} }, "high"), "warning")
		t.eq(c({ Name = "heal", RequiresTarget = true }, "heal all", { {} }, "low"), "warning")
		t.eq(c({ Name = "heal", RequiresTarget = true }, "heal a,b,c", { {}, {}, {} }, "low"), "warning")
		t.eq(c({ Name = "heal", RequiresTarget = true }, "heal bob", { {} }, "low"), nil)
		t.eq(c({ Name = "weather", Category = "Environment" }, "weather foggy", {}, "low"), "info")
		AlertService.Clear()
		AlertService.Raise({ Kind = "join", Severity = "warning", Title = "x" })
		AlertService.Raise({ Kind = "command", Severity = "critical", Title = "y" })
		t.eq(#AlertService.List(10), 2)
		t.eq(AlertService.List(10)[1].Title, "y")
		t.eq(#AlertService.List(10, "join"), 1)
		t.eq(#AlertService.List(10, "critical"), 1)
		t.eq(AlertService.Clear(), 2)
	end)

	t.test("broadcast templates: defaults and validation", function()
		t.ok(#AnnouncementService.GetTemplates() >= 1, "default templates")
		local ok = AnnouncementService.SetTemplate("bad name!", "x")
		t.eq(ok, false)
		local ok2 = AnnouncementService.SetTemplate("nosuchtemplate", nil)
		t.eq(ok2, false)
	end)

	-- ;restart / ;cancelshutdown live in ServerControl (needs CrossServerService,
	-- which only loads in a running game) - checked in Play instead.
	t.test("m-panel gap commands registered", function()
		local Commands = Sentinel:WaitForChild("Commands")
		local files = {
			chatlog = Commands.Moderation.StaffFeeds,
			btemplate = Commands.Server.Announce,
			pumpkin = Commands.Player.Seasonal,
		}
		for name, file in pairs(files) do
			if not CommandRegistry.Resolve(name) then
				require(file)
			end
		end
		t.ok(require(Systems.EventService).FindPreset("halloween") ~= nil, "spooky night preset")
		for _, name in ipairs({ "chatlog", "clearchatlog", "alerts", "clearalerts", "btemplate", "pumpkin", "ghost", "bats", "unspooky", "clearseasonal", "clearhalloween" }) do
			t.ok(CommandRegistry.Resolve(name) ~= nil, name .. " registered")
		end
	end)
end
