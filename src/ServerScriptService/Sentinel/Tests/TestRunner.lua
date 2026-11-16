--[[
	TestRunner.lua

	Purpose:
		Tiny dependency-free test runner for Sentinel's pure core modules
		(parser, permission engine). Not loaded by the bootstrap — run it
		from Studio (command bar or Studio MCP execute_luau, Edit mode):

			local copy = game.ServerScriptService.Sentinel:Clone()
			require(copy.Tests.TestRunner).Run()
			copy:Destroy()

		Run it on a fresh Clone: Studio caches require() results per
		ModuleScript in Edit mode, so requiring the originals again after
		an edit silently runs the old code.

	Each sibling ModuleScript whose name ends in ".spec" returns
	function(t) ... end, where t.test(name, fn) registers a case and
	t.eq / t.ok / t.near are assertions.
--]]

local TestRunner = {}

local function fmt(v: any): string
	if type(v) == "string" then
		return ("%q"):format(v)
	end
	return tostring(v)
end

function TestRunner.Run(): (number, number)
	local passed, failed = 0, 0
	local failures = {}

	for _, spec in ipairs(script.Parent:GetChildren()) do
		if spec:IsA("ModuleScript") and spec.Name:match("%.spec$") then
			local cases = {}
			local t = {}
			function t.test(name: string, fn: () -> ())
				table.insert(cases, { Name = name, Fn = fn })
			end
			function t.eq(actual: any, expected: any, label: string?)
				if actual ~= expected then
					error(("%sexpected %s, got %s"):format(if label then label .. ": " else "", fmt(expected), fmt(actual)), 2)
				end
			end
			function t.ok(value: any, label: string?)
				if not value then
					error((label or "expected truthy value") .. ", got " .. fmt(value), 2)
				end
			end

			local okLoad, err = pcall(function()
				require(spec)(t)
			end)
			if not okLoad then
				failed += 1
				table.insert(failures, ("%s (load): %s"):format(spec.Name, tostring(err)))
				continue
			end

			for _, case in ipairs(cases) do
				local ok, caseErr = pcall(case.Fn)
				if ok then
					passed += 1
				else
					failed += 1
					table.insert(failures, ("%s > %s: %s"):format(spec.Name, case.Name, tostring(caseErr)))
				end
			end
		end
	end

	for _, line in ipairs(failures) do
		warn("[Sentinel.Tests] FAIL " .. line)
	end
	print(("[Sentinel.Tests] %d passed, %d failed"):format(passed, failed))
	return passed, failed
end

return TestRunner
