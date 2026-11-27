--!strict
--!native
--[[
	CharacterIntegrityCheck.lua (Sentinel AntiCheat module)

	Detects tampered characters, as replicated to the server: a missing
	Humanoid or HumanoidRootPart, body parts that disappeared, body-part
	size or CanCollide changes against the baseline taken when the
	character loaded, and scripts parented to the character that were not
	there at load. False positives handled: the baseline is taken
	BaselineDelay seconds after spawn (after the game's own character setup,
	accessories and scaling); Sentinel commands that legitimately change
	the character (;size, ;scale, ;r6/;r15, morphs, ;removelimbs ...) and
	AntiCheatService.Rebaseline(player) take a new baseline; dead characters
	are skipped; accessories and tools are not body parts and are ignored;
	the size tolerance allows rounding.
--]]

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "CharacterIntegrityCheck",
	Description = "Missing Humanoid / parts, resized or non-collidable body parts, unexpected scripts.",
	Enabled = true,
	Interval = 5,
	Severity = 5,
	Defaults = {
		BaselineDelay = 3, -- seconds after spawn before the baseline is taken
		SizeTolerance = 0.05, -- 5 %
		FlagScripts = true,
	},
	Schema = {
		BaselineDelay = { Min = 0.5, Max = 30, Description = "Seconds after spawn before the baseline" },
		SizeTolerance = { Min = 0, Max = 1, Description = "Allowed body-part size change (0.05 = 5 %)" },
		FlagScripts = { Description = "Flag scripts parented to the character after load" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local character = state.Character
		state.HasCharacter = character ~= nil
		if not character then
			return
		end
		state.HasHumanoid = character:FindFirstChildOfClass("Humanoid") ~= nil
		state.HasRoot = character:FindFirstChild("HumanoidRootPart") ~= nil
		state.Dead = state.Humanoid ~= nil and (state.Humanoid :: Humanoid).Health <= 0
		local parts = {}
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("BasePart") then
				parts[child.Name] = { Size = child.Size, CanCollide = child.CanCollide }
			end
		end
		state.Parts = parts
		-- Kept current by events (ModuleUtil.Scripts): no descendant walk.
		state.Scripts = ModuleUtil.Scripts(character)
		state.SpawnedAt = if ctx.LastEvent then ctx.LastEvent(player.UserId, "spawn") else nil
		state.RebaselineAt = if ctx.LastEvent then ctx.LastEvent(player.UserId, "baseline") else nil
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if not state.HasCharacter or state.Dead then
			return nil
		end
		local since = state.SpawnedAt or m.FirstSeen
		if not since then
			m.FirstSeen = state.Now
			return nil
		end
		if state.Now - since < (cfg.BaselineDelay or 3) then
			return nil
		end
		-- Take / refresh the baseline.
		if not m.Baseline or (state.RebaselineAt and state.RebaselineAt > (m.BaselineAt or 0)) then
			m.Baseline = state.Parts or {}
			m.Scripts = {}
			for _, s in ipairs(state.Scripts or {}) do
				m.Scripts[s] = true
			end
			m.BaselineAt = state.Now
			m.HadHumanoid = state.HasHumanoid
			return nil
		end
		local problems = {}
		if m.HadHumanoid and not state.HasHumanoid then
			table.insert(problems, "Humanoid missing")
		end
		if not state.HasRoot then
			table.insert(problems, "HumanoidRootPart missing")
		end
		local tolerance = cfg.SizeTolerance or 0.05
		for name, base in pairs(m.Baseline) do
			local now = (state.Parts or {})[name]
			if not now then
				table.insert(problems, name .. " missing")
			else
				local a, b = base.Size, now.Size
				local change = math.max(
					math.abs(b.X - a.X) / math.max(a.X, 0.01),
					math.abs(b.Y - a.Y) / math.max(a.Y, 0.01),
					math.abs(b.Z - a.Z) / math.max(a.Z, 0.01)
				)
				if change > tolerance then
					table.insert(problems, ("%s resized %d%%"):format(name, math.floor(change * 100)))
				end
				if base.CanCollide ~= now.CanCollide and (name == "HumanoidRootPart" or name == "Head" or name:find("Torso")) then
					table.insert(problems, ("%s CanCollide %s -> %s"):format(name, tostring(base.CanCollide), tostring(now.CanCollide)))
				end
			end
		end
		if cfg.FlagScripts ~= false then
			for _, s in ipairs(state.Scripts or {}) do
				if not m.Scripts[s] then
					table.insert(problems, "new script " .. s)
					m.Scripts[s] = true
				end
			end
		end
		if #problems == 0 then
			return nil
		end
		-- Report once, then accept the new state as the baseline.
		m.Baseline = state.Parts or {}
		m.HadHumanoid = state.HasHumanoid
		return {
			Confidence = math.clamp(0.4 + #problems * 0.15, 0.4, 0.9),
			Reason = "Character changed: " .. table.concat(problems, ", "):sub(1, 160),
			Evidence = { Problems = problems },
		}
	end,
}
