-- W-FINAL.1 Module Manager + Shift To Run: config validation, lifecycle
-- (enable / disable cycles, cleanup, failures, dependencies), stamina.
return function(t)
	local Sentinel = script.Parent.Parent
	local ModuleService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ModuleService"))
	local ShiftToRun = require(Sentinel:WaitForChild("Modules"):WaitForChild("ShiftToRun"))

	local schema = {
		{ Key = "Speed", Type = "number", Default = 26, Min = 8, Max = 100 },
		{ Key = "Key", Type = "key", Default = "LeftShift" },
		{ Key = "Mode", Type = "choice", Choices = { "Hold", "Toggle" }, Default = "Hold" },
		{ Key = "On", Type = "boolean", Default = false },
	}

	t.test("modules: parse values", function()
		t.eq(ModuleService.ParseValue(schema[1], "30"), 30)
		t.eq(ModuleService.ParseValue(schema[1], "200"), nil)
		t.eq(ModuleService.ParseValue(schema[1], "fast"), nil)
		t.eq(ModuleService.ParseValue(schema[2], "shift"), "LeftShift")
		t.eq(ModuleService.ParseValue(schema[2], "q"), "Q")
		t.eq(ModuleService.ParseValue(schema[2], "none"), "None")
		t.eq(ModuleService.ParseValue(schema[2], "notakey"), nil)
		t.eq(ModuleService.ParseValue(schema[3], "toggle"), "Toggle")
		t.eq(ModuleService.ParseValue(schema[3], "spin"), nil)
		t.eq(ModuleService.ParseValue(schema[4], "on"), true)
		t.eq(ModuleService.ParseValue(schema[4], "off"), false)
	end)

	t.test("modules: sanitize keeps valid values and reports bad ones", function()
		local clean, errors = ModuleService.SanitizeConfig(schema, { Speed = 40, Mode = "nope", Extra = 1 })
		t.eq(clean.Speed, 40)
		t.eq(clean.Mode, "Hold")
		t.eq(clean.Key, "LeftShift")
		t.eq(clean.Extra, nil)
		t.eq(#errors, 1)
		local defaults = ModuleService.SanitizeConfig(ShiftToRun.Config, nil)
		t.eq(defaults.SprintSpeed, 26)
		t.eq(defaults.Stamina, false)
	end)

	t.test("modules: lifecycle, cleanup, repeated cycles", function()
		local log = {}
		local folder = Instance.new("Folder")
		ModuleService.Register({
			Id = "spec_a",
			Name = "Spec A",
			Version = "1",
			Config = schema,
			Activate = function(ctx)
				table.insert(log, "on")
				ctx.Track(Instance.new("Part", folder))
				ctx.Track(function()
					table.insert(log, "cleanup")
				end)
			end,
			Deactivate = function()
				table.insert(log, "off")
			end,
		})
		for _ = 1, 3 do
			local ok = ModuleService.SetEnabled("spec_a", true, nil)
			t.ok(ok, "enable")
			t.eq(#folder:GetChildren(), 1)
			t.eq(ModuleService.IsActive("spec_a"), true)
			t.eq((ModuleService.SetEnabled("spec_a", true, nil)), false) -- already on
			t.ok((ModuleService.SetEnabled("spec_a", false, nil)), "disable")
			t.eq(#folder:GetChildren(), 0)
		end
		t.eq(table.concat(log, ","), "on,off,cleanup,on,off,cleanup,on,off,cleanup")
		local ok, msg = ModuleService.SetValue("spec_a", "speed", "500", nil)
		t.eq(ok, false)
		t.ok(msg:find("between"), msg)
		t.ok((ModuleService.SetValue("spec_a", "Speed", "50", nil)), "set")
		t.eq(ModuleService.Get("spec_a").Config.Speed, 50)
		t.ok((ModuleService.ResetConfig("spec_a", nil)), "reset")
		t.eq(ModuleService.Get("spec_a").Config.Speed, 26)
		ModuleService._UnregisterForTests("spec_a")
		folder:Destroy()
	end)

	t.test("modules: failed activation is isolated, dependencies block", function()
		ModuleService.Register({
			Id = "spec_bad",
			Name = "Spec Bad",
			Version = "1",
			Activate = function(ctx)
				ctx.Track(function() end)
				error("boom")
			end,
		})
		ModuleService.Register({ Id = "spec_dep", Name = "Spec Dep", Version = "1", Dependencies = { "spec_bad" } })
		local ok, msg = ModuleService.SetEnabled("spec_bad", true, nil)
		t.eq(ok, false)
		t.ok(msg:find("boom"), msg)
		t.eq(ModuleService.IsActive("spec_bad"), false)
		local ok2, msg2 = ModuleService.SetEnabled("spec_dep", true, nil)
		t.eq(ok2, false)
		t.ok(msg2:find("needs"), msg2)
		t.eq(ModuleService.Find("Spec Dep"), "spec_dep")
		ModuleService._UnregisterForTests("spec_bad")
		ModuleService._UnregisterForTests("spec_dep")
	end)

	t.test("shifttorun: stamina drains, regenerates after the delay, exhaustion", function()
		local cfg = { Drain = 20, Regen = 10, RegenDelay = 1, MaxStamina = 100, MinStamina = 20 }
		local s = { Stamina = 100, Exhausted = false, LastDrain = 0 }
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 1, 10, true)
		t.eq(s.Stamina, 80)
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 1, 10.5, false)
		t.eq(s.Stamina, 80) -- still in the regen delay
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 1, 11.5, false)
		t.eq(s.Stamina, 90)
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 5, 12, true)
		t.eq(s.Stamina, 0)
		t.eq(s.Exhausted, true)
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 1, 14, false)
		t.eq(s.Exhausted, true) -- 10 < MinStamina
		s.Stamina, s.Exhausted, s.LastDrain = ShiftToRun.Step(s, cfg, 1, 15, false)
		t.eq(s.Stamina, 20)
		t.eq(s.Exhausted, false)
		local warnings = ShiftToRun.Compatibility({ Key = "Q", AltKey = "None", SprintSpeed = 10, Stamina = true, MinStamina = 200, MaxStamina = 100 })
		t.ok(#warnings >= 2, "slow sprint + min > max")
	end)
end
