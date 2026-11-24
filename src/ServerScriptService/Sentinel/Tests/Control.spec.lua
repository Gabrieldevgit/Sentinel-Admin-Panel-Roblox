-- Tests for ;control (Systems/ControlService.Validate) and the DefaultSelf
-- command option.
return function(t)
	local Sentinel = script.Parent.Parent
	local ControlService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ControlService"))
	local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))

	local ok = { ControllerAlive = true, TargetAlive = true }
	local function with(extra)
		local s = table.clone(ok)
		for k, v in pairs(extra) do
			s[k] = v
		end
		return ControlService.Validate(s)
	end

	t.test("control: validation", function()
		t.eq(ControlService.Validate(ok), nil)
		t.ok(with({ Same = true }) ~= nil, "self")
		t.ok(with({ ControllerAlive = false }) ~= nil, "dead controller")
		t.ok(with({ TargetAlive = false }) ~= nil, "dead target")
		t.ok(with({ ControllerIsControlled = true }) ~= nil, "controlled controller")
		t.ok(with({ TargetIsControlling = true }) ~= nil, "target controlling")
		t.ok((with({ TargetControlledBy = "Mod1" }) or ""):find("Mod1") ~= nil, "names the controller")
	end)

	t.test("control: commands registered", function()
		if not CommandRegistry.Resolve("control") then
			require(Sentinel:WaitForChild("Commands"):WaitForChild("Player"):WaitForChild("Control"))
		end
		local def = CommandRegistry.Resolve("possess")
		t.ok(def ~= nil and def.Name == "control", "alias possess")
		local un = CommandRegistry.Resolve("uncontrol")
		t.ok(un ~= nil and un.DefaultSelf == true, "uncontrol defaults to self")
	end)
end
