-- Tests for the W10 persistent audit: Logger entry fields + filters,
-- change scopes (data modification history), AuditService query parsing,
-- snapshot diffs, the in-memory search fallback (Edit mode has no
-- DataStore) and what CommandRegistry logs for failed / cancelled /
-- denied commands.
return function(t)
	local Sentinel = script.Parent.Parent
	local Core = Sentinel:WaitForChild("Core")
	require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))
	local Logger = require(Core:WaitForChild("Logger"))
	local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
	local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))
	local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
	local AuditService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AuditService"))

	local owner = { UserId = -7101, Name = "AuditOwner" } :: any
	PermissionSystem.AssignRole(owner, "Owner")
	local nobody = { UserId = -7102, Name = "AuditNobody" } :: any

	local function lastOf(command: string): any
		local all = Logger.Query({ Command = command })
		return all[#all]
	end

	CommandRegistry.Register({
		Name = "w10fail",
		Aliases = {},
		Description = "test",
		Usage = "/w10fail [reason...]",
		Permission = "test.w10fail",
		Category = "Test Things",
		Log = false, -- failures are logged anyway
		Undoable = false,
		Execute = function()
			return { Success = false, Message = "nope" }
		end,
	} :: any)
	CommandRegistry.Register({
		Name = "w10note",
		Aliases = {},
		Description = "test",
		Usage = "/w10note",
		Permission = "test.w10note",
		Category = "Test",
		Log = true,
		Undoable = false,
		Execute = function()
			Logger.NoteChange("config", "W10Thing", 1, 2)
			Logger.NoteChange("config", "Same", "a", "a") -- no change: skipped
			return { Success = true, Message = "ok" }
		end,
	} :: any)

	t.test("logger entries carry id, action, clipping", function()
		local e = Logger.Write({ Command = "w10.raw", Message = string.rep("x", 1000), Arguments = { "a" } })
		t.ok(type(e.Id) == "string" and e.Id:find("-", 1, true) ~= nil, "id")
		t.eq(e.Action, "w10.raw")
		t.ok(#e.Message <= 300, "message clipped")
		local e2 = Logger.Write({ Command = "w10.raw" })
		t.ok(e2.Id ~= e.Id, "ids unique")
	end)

	t.test("failed command: reason, action, result logged without Log", function()
		CommandProcessor.Process(owner, "w10fail spamming the chat")
		local e = lastOf("w10fail")
		t.ok(e ~= nil, "logged")
		t.eq(e.Result, "Failure")
		t.eq(e.Severity, "Error")
		t.eq(e.Reason, "spamming the chat")
		t.eq(e.Action, "testthings.w10fail")
		t.eq(e.RawInput, "w10fail spamming the chat")
		t.eq(e.Message, "nope")
	end)

	t.test("denied and cancelled commands are logged", function()
		CommandProcessor.Process(nobody, "w10fail x")
		local denied = lastOf("w10fail")
		t.eq(denied.Result, "Denied")
		t.eq(denied.ExecutorName, "AuditNobody")
		local remove = CommandRegistry.AddHook("Before", function(def)
			return if def.Name == "w10note" then "blocked" else nil
		end, "w10block")
		CommandProcessor.Process(owner, "w10note")
		remove()
		local cancelled = lastOf("w10note")
		t.eq(cancelled.Result, "Cancelled")
		t.ok(cancelled.Message:find("blocked", 1, true) ~= nil, "message names the hook reason")
	end)

	t.test("NoteChange inside a command attaches to its entry", function()
		CommandProcessor.Process(owner, "w10note")
		local e = lastOf("w10note")
		t.eq(e.Result, "Success")
		t.ok(e.Changes ~= nil and #e.Changes == 1, "one change")
		t.eq(e.Changes[1].Field, "W10Thing")
		t.eq(e.Changes[1].Before, "1")
		t.eq(e.Changes[1].After, "2")
		-- outside a command it is its own entry
		Logger.NoteChange("config", "W10Outside", nil, { 1, 2 })
		local own = lastOf("data.change")
		t.eq(own.Changes[1].Field, "W10Outside")
		t.eq(own.Changes[1].Before, "(none)")
		t.eq(own.Changes[1].After, "[1,2]")
	end)

	t.test("filters: player in multi-target, moderator prefix, action, severity, result, text", function()
		local e = Logger.Write({
			Executor = "55",
			ExecutorName = "ModAlice",
			Command = "kick",
			Action = "moderation.kick",
			Target = "Bob,Carl",
			TargetIds = { 11, 12 },
			Reason = "exploiting",
			Result = "Failure",
			Severity = "Warning",
		})
		local M = Logger.Matches
		t.ok(M(e, { Player = "carl" }), "any target, case-insensitive")
		t.ok(M(e, { Player = "12" }), "target by UserId")
		t.ok(not M(e, { Player = "Dan" }))
		t.ok(M(e, { Moderator = "modal" }), "moderator prefix")
		t.ok(M(e, { Moderator = "55" }), "moderator UserId")
		t.ok(M(e, { Action = "moderation" }), "category matches")
		t.ok(not M(e, { Action = "mod" }), "no partial category")
		t.ok(M(e, { Action = "kick" }), "command part matches")
		t.ok(M(e, { Action = "economy,moderation" }), "alternatives")
		t.ok(not M(e, { HasChanges = true }), "no changes")
		t.ok(M(e, { Severity = "Warning+" }))
		t.ok(not M(e, { Severity = "Error+" }))
		t.ok(M(e, { Result = "Failed" }))
		t.ok(not M(e, { Result = "Success" }))
		t.ok(M(e, { Text = "EXPLOIT" }), "text searches the reason")
		t.ok(M(e, { Since = e.Timestamp - 1, Until = e.Timestamp + 1 }))
		t.ok(not M(e, { Since = e.Timestamp + 5 }))
	end)

	t.test("ParseQuery reads key:value words and free text", function()
		local f = AuditService.ParseQuery("mod:Alice cmd:ban sev:warning+ result:failed since:2d hello world")
		t.eq(f.Moderator, "Alice")
		t.eq(f.Command, "ban")
		t.eq(f.Severity, "Warning+")
		t.eq(f.Result, "Failed")
		t.ok(math.abs(f.Since - (os.time() - 172800)) <= 2, "since 2d")
		t.eq(f.Text, "hello world")
		local day = AuditService.ParseQuery("until:2026-11-17")
		t.eq(day.Until, os.time({ year = 2026, month = 11, day = 17, hour = 0 }) + 86399)
		local bad, err = AuditService.ParseQuery("sev:loud")
		t.eq(bad, nil)
		t.ok(err ~= nil)
		t.eq(AuditService.ParseQuery("since:soon"), nil)
	end)

	t.test("SanitizeFilter keeps only valid client values", function()
		local f = AuditService.SanitizeFilter({
			Player = "Bob",
			Command = string.rep("x", 200),
			Severity = "Error+",
			Result = "Hacked",
			Since = 0 / 0,
			Until = 1000,
			Evil = true,
		})
		t.eq(f.Player, "Bob")
		t.eq(f.Command, nil)
		t.eq(f.Severity, "Error+")
		t.eq(f.Result, nil)
		t.eq(f.Since, nil)
		t.eq(f.Until, 1000)
		t.eq(f.Evil, nil)
	end)

	t.test("snapshot diff lists changed, added and removed fields", function()
		local changes = AuditService.Diff({ Coins = "10", Level = "2", Old = "x" }, { Coins = "25", Level = "2", New = "y" }, "Bob")
		t.eq(#changes, 3)
		t.eq(changes[1].Field, "Coins")
		t.eq(changes[1].Before, "10")
		t.eq(changes[1].After, "25")
		t.eq(changes[1].Target, "Bob")
		t.eq(changes[2].Field, "New")
		t.eq(changes[2].Before, "(none)")
		t.eq(changes[3].After, "(removed)")
		local custom = AuditService.Snapshot({ Audit = function()
			return { Score = 1.5 }
		end }, nobody)
		t.eq(custom.Score, "1.50")
		t.eq(next(AuditService.Snapshot({ Audit = false, Category = "Economy" }, nobody)), nil)
	end)

	t.test("in-memory search pages newest first", function()
		for i = 1, 5 do
			Logger.Write({ Command = "w10.page", Message = "n" .. i })
		end
		local first = AuditService.Search({ Command = "w10.page" }, nil, 3)
		t.eq(first.Persistent, false)
		t.eq(#first.Entries, 3)
		t.eq(first.Entries[1].Message, "n5")
		t.ok(first.Cursor ~= nil, "more left")
		local second = AuditService.Search({ Command = "w10.page" }, first.Cursor, 3)
		t.eq(#second.Entries, 2)
		t.eq(second.Entries[2].Message, "n1")
		t.eq(second.Cursor, nil)
	end)

	t.test("FormatEntry shows input, result, reason and changes", function()
		local line = AuditService.FormatEntry({
			Timestamp = 0,
			ExecutorName = "Alice",
			RawInput = "setcoins Bob 50",
			Result = "Success",
			Reason = "refund",
			Changes = { { Target = "Bob", Field = "Coins", Before = "10", After = "50" } },
		})
		t.ok(line:find(";setcoins Bob 50", 1, true) ~= nil, "input")
		t.ok(line:find("reason: refund", 1, true) ~= nil, "reason")
		t.ok(line:find("Bob.Coins 10->50", 1, true) ~= nil, "change")
	end)
end
