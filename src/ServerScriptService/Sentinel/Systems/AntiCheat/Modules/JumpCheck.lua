--!strict
--!native
--[[
	JumpCheck.lua (Sentinel AntiCheat module)

	Detects impossible jump height or jump rate. Height: when the player
	leaves the ground the take-off height is stored; on landing the peak
	above it is compared with the height JumpPower (JumpPower^2 / 2g) or
	JumpHeight allows, times the lag factor, plus a margin. Rate: take-offs
	in the last 10 seconds. False positives handled: the allowed height uses
	the server's JumpPower / JumpHeight, so staff-granted jump (;jump) is
	allowed; stairs / ramps climb with the ground under the player (no
	take-off); force sources the server sees (jump pads, launchers),
	seats, vehicles and Sentinel fly are skipped; spawns and teleports are
	in grace; landing on a higher platform is measured from the take-off,
	which is still the real jump.
--]]

local Workspace = game:GetService("Workspace")

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "JumpCheck",
	Description = "Jumps higher or more often than the Humanoid allows.",
	Enabled = true,
	Interval = 0.5, -- exploit jumps last > 1 s; the peak is still sampled
	Severity = 3,
	SkipWhenSeated = true, -- seated, in a vehicle or anchored: nothing to measure
	SkipWhenStill = true, -- moved < 0.5 studs in 1.2 s: no step, jump or pass to check
	-- Called by the engine instead of Check when it skips this check (see
	-- SkipWhenSeated / SkipWhenStill): does what Check would have done then.
	OnSkip = function(m: any, why: string)
		if why == "seated" then
			m.Airborne = false -- a ride up a hill is not a jump
		end
	end,
	Defaults = {
		Margin = 3, -- studs on top of the allowed height
		MaxJumpsPer10s = 18,
		GroundHeight = 4.5, -- root height above a surface that counts as grounded
	},
	Schema = {
		Margin = { Min = 0, Max = 100, Description = "Extra studs of height allowed" },
		MaxJumpsPer10s = { Min = 2, Max = 100, Type = "integer", Description = "Take-offs allowed per 10 seconds" },
		GroundHeight = { Min = 2, Max = 20, Description = "Root height above ground that counts as standing" },
	},

	Gather = function(_player: Player, state: any, _ctx: any)
		local humanoid = state.Humanoid :: Humanoid?
		local root = state.Root :: BasePart?
		state.Seated = ModuleUtil.Seated(humanoid)
		state.InVehicle = ModuleUtil.InVehicle(root)
		state.HasMover = ModuleUtil.HasMover(state.Character)
		if humanoid then
			local gravity = Workspace.Gravity
			state.AllowedHeight = if humanoid.UseJumpPower
				then (humanoid.JumpPower ^ 2) / (2 * math.max(gravity, 1))
				else humanoid.JumpHeight
			state.HipHeight = humanoid.HipHeight
		end
		if root and state.Character then
			local extra = (state.HipHeight or 2) + root.Size.Y / 2
			state.GroundDistance = ModuleUtil.Ground(state.Character, root, extra + 6)
			state.GroundLimit = extra + 1.5
			state.Height = root.Position.Y
		end
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		-- Allowance history: the server may lower JumpPower / JumpHeight
		-- mid-jump (;resetjump), or between the take-off and the check that
		-- sees it. A landing is measured against the highest allowance seen
		-- from 1 s before take-off. Only the server sets these values.
		local allowances = m.Allowances or {}
		m.Allowances = allowances
		table.insert(allowances, { T = state.Now, V = state.AllowedHeight or 7.2 })
		for i = #allowances, 1, -1 do
			if state.Now - allowances[i].T > 15 then
				table.remove(allowances, i)
			end
		end
		if state.Seated or state.InVehicle or state.Flying or state.HasMover or state.Height == nil then
			m.Airborne = false
			return nil
		end
		local limit = state.GroundLimit or cfg.GroundHeight or 4.5
		local grounded = state.GroundDistance ~= nil and state.GroundDistance <= limit
		m.TakeOffs = m.TakeOffs or {}
		local result: any = nil
		if not grounded and not m.Airborne then
			m.Airborne = true
			m.TakeOff = state.Height
			m.TakeOffT = state.Now
			m.Peak = state.Height
			table.insert(m.TakeOffs, state.Now)
		elseif not grounded and m.Airborne then
			m.Peak = math.max(m.Peak or state.Height, state.Height)
		elseif grounded and m.Airborne then
			m.Airborne = false
			local rise = (m.Peak or state.Height) - (m.TakeOff or state.Height)
			local allowedHeight = state.AllowedHeight or 7.2
			local since = (m.TakeOffT or state.Now) - 1
			for _, e in ipairs(allowances) do
				if e.T >= since and e.V > allowedHeight then
					allowedHeight = e.V
				end
			end
			local allowed = allowedHeight * (state.Lag or 1) + (cfg.Margin or 3)
			if rise > allowed then
				result = {
					Confidence = ModuleUtil.Confidence(rise / allowed - 0.6, 0.4, 0.9),
					Reason = ("Jumped %.1f studs, allowed %.1f"):format(rise, allowed),
					Evidence = { Rise = rise, Allowed = allowed },
				}
			end
		end
		for i = #m.TakeOffs, 1, -1 do
			if state.Now - m.TakeOffs[i] > 10 then
				table.remove(m.TakeOffs, i)
			end
		end
		local maxJumps = cfg.MaxJumpsPer10s or 18
		if not result and #m.TakeOffs > maxJumps then
			result = {
				Confidence = ModuleUtil.Confidence(#m.TakeOffs / maxJumps - 0.6, 0.4, 0.8),
				Reason = ("%d jumps in 10 s (allowed %d)"):format(#m.TakeOffs, maxJumps),
				Evidence = { Jumps = #m.TakeOffs },
			}
			m.TakeOffs = {}
		end
		return result
	end,
}
