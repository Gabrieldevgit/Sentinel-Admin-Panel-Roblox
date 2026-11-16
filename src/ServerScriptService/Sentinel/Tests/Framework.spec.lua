-- Tests for the W07 command framework: hooks, middleware, cancellation,
-- timing, undo/redo, templates and prefixes. Uses target-less test
-- commands (no real players exist in Edit mode).
return function(t)
	local Sentinel = script.Parent.Parent
	local Core = Sentinel:WaitForChild("Core")
	require(Sentinel:WaitForChild("Systems"):WaitForChild("RankService"))
	local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
	local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))
	local CommandHistory = require(Core:WaitForChild("CommandHistory"))
	local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
	local ConfigService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ConfigService"))
	local Library = require(Sentinel:WaitForChild("Systems"):WaitForChild("CommandLibraryService"))

	local owner = { UserId = -7001, Name = "FrameworkOwner" } :: any
	PermissionSystem.AssignRole(owner, "Owner")

	local state = "off"
	local function reg(name: string, extra: any)
		local def: any = {
			Name = name,
			Aliases = {},
			Description = "test",
			Usage = "/" .. name .. " [text...]",
			Permission = "test." .. name,
			Category = "Test",
			Log = false,
			Undoable = false,
			Execute = function(ctx)
				return { Success = true, Message = name .. ":" .. table.concat(ctx.Arguments, " ") }
			end,
		}
		for k, v in pairs(extra or {}) do
			def[k] = v
		end
		CommandRegistry.Register(def)
	end
	reg("w07echo")
	reg("w07on", {
		Inverse = "w07off",
		Execute = function()
			state = "on"
			return { Success = true, Message = "on" }
		end,
	})
	reg("w07off", {
		Execute = function()
			state = "off"
			return { Success = true, Message = "off" }
		end,
	})
	local cancelled = false
	reg("w07long", {
		Cancellable = true,
		Execute = function(ctx)
			ctx.Track("long op", function()
				cancelled = true
			end)
			return { Success = true, Message = "started" }
		end,
	})

	t.test("before hook cancels a command", function()
		local remove = CommandRegistry.AddHook("Before", function(def, ctx)
			if def.Name == "w07echo" and ctx.Arguments[1] == "block" then
				return "blocked by test"
			end
			return nil
		end, "testBefore")
		local r = CommandProcessor.Process(owner, "w07echo block")[1]
		t.eq(r.Success, false)
		t.eq(r.Cancelled, true)
		t.eq(r.Message, "blocked by test")
		t.eq(CommandProcessor.Process(owner, "w07echo fine")[1].Success, true)
		remove()
		t.eq(CommandProcessor.Process(owner, "w07echo block")[1].Success, true, "hook removed")
	end)

	t.test("middleware wraps execute in order and results carry timing", function()
		local order = {}
		local r1 = CommandRegistry.Use(function(def, ctx, nextFn)
			table.insert(order, "outer")
			local r = nextFn()
			r.Message ..= "|outer"
			return r
		end, "outer")
		local r2 = CommandRegistry.Use(function(def, ctx, nextFn)
			table.insert(order, "inner")
			local r = nextFn()
			r.Message ..= "|inner"
			return r
		end, "inner")
		local seen
		local r3 = CommandRegistry.AddHook("After", function(def, ctx, result)
			seen = result.Message
		end, "after")
		local r = CommandProcessor.Process(owner, "w07echo x")[1]
		r1()
		r2()
		r3()
		t.eq(table.concat(order, ","), "outer,inner")
		t.eq(r.Message, "w07echo:x|inner|outer")
		t.eq(seen, r.Message, "after hook sees final result")
		t.eq(r.Command, "w07echo")
		t.ok(type(r.DurationMs) == "number", "DurationMs set")
	end)

	t.test("undo runs the inverse, redo replays", function()
		state = "off"
		CommandProcessor.Process(owner, "w07on")
		t.eq(state, "on")
		local undo = CommandHistory.Counts(owner)
		t.ok(undo >= 1, "something to undo")
		local r = CommandProcessor.Undo(owner)
		t.ok(r.Success, r.Message)
		t.eq(state, "off")
		local _, redo = CommandHistory.Counts(owner)
		t.eq(redo, 1)
		r = CommandProcessor.Redo(owner)
		t.ok(r.Success, r.Message)
		t.eq(state, "on")
		local entries = CommandHistory.Get(owner, { Search = "w07on" })
		t.ok(#entries >= 2, "history has the command and its redo")
		t.eq(CommandHistory.Get(owner, { Search = "w07off" })[1].Source, "undo")
	end)

	t.test("non-undoable commands aren't stacked", function()
		CommandProcessor.Process(owner, "w07echo nothing")
		local top = CommandHistory.PeekUndo(owner)
		t.ok(top == nil or top.Command ~= "w07echo")
	end)

	t.test("cancel stops tracked operations", function()
		cancelled = false
		CommandProcessor.Process(owner, "w07long")
		t.eq(#CommandRegistry.ListRunning(owner), 1)
		t.eq(CommandRegistry.CancelRunning(owner), 1)
		t.ok(cancelled, "cancel function ran")
		t.eq(#CommandRegistry.ListRunning(owner), 0)
	end)

	t.test("templates: placeholders and filling", function()
		local holders = Library.Placeholders("mute {player}:{duration} && warn {player} {reason?} {n:number}")
		t.eq(#holders, 4)
		t.eq(holders[1].Name, "player")
		t.eq(holders[3].Optional, true)
		t.eq(holders[4].Type, "number")
		local line = Library.FillTemplate("ban {player}:{duration} {reason?}", { player = "Bob", duration = "1h" })
		t.eq(line, "ban Bob:1h")
		local none, missing = Library.FillTemplate("kick {player}", {})
		t.eq(none, nil)
		t.eq(missing, "player")
		t.eq(Library.FillTemplate("announce {m}", { m = "a && b" }), "announce a & b", "&& can't be injected")
	end)

	t.test("prefixes", function()
		t.eq(ConfigService.MatchPrefix(";kick bob"), 1)
		t.eq(ConfigService.MatchPrefix(";)"), nil)
		t.eq(ConfigService.MatchPrefix("!kick"), nil)
		t.ok(not ConfigService.Set("Prefixes", { "#" }), "disallowed prefix")
		t.ok(not ConfigService.Set("Prefixes", {}), "empty list")
		t.ok(ConfigService.Set("Prefixes", { ";", "!" }))
		t.eq(ConfigService.MatchPrefix("!kick"), 1)
		ConfigService.Set("Prefixes", { ";" })
	end)
end
