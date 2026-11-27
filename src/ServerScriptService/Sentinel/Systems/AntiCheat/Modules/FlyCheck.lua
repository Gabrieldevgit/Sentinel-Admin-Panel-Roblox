--!strict
--!native
--[[
	FlyCheck.lua (Sentinel AntiCheat module)

	Detects sustained flight or hovering: the root stays more than
	AirHeight studs above any surface while its height holds against
	gravity (vertical speed between -HoverSpeed and +ClimbSpeed) for longer
	than MaxAirTime. False positives handled: a normal jump only hovers for
	a moment at its peak; falling (fast downward speed) resets the timer;
	water counts as a surface (swimming); seats, vehicles and PlatformStand
	are skipped; any force / constraint the server sees in the character
	(jump pads, gliders, knockback - exploit-made ones never replicate) is a
	legitimate upward force source and pauses the check; Sentinel fly
	(SentinelFlying) is skipped; spawns and teleports are in grace.
--]]

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "FlyCheck",
	Description = "Sustained flight or hovering with no ground and no force source.",
	Enabled = true,
	Interval = 0.5,
	Severity = 6,
	SkipWhenSeated = true, -- (not SkipWhenStill: hovering in place is exactly what this catches)
	-- Called by the engine instead of Check when it skips this check (see
	-- SkipWhenSeated / SkipWhenStill): does what Check would have done then.
	OnSkip = function(m: any, _why: string, now: number)
		m.Air = 0
		m.LastNow = now
	end,
	Defaults = {
		AirHeight = 8, -- studs above the nearest surface that count as airborne
		MaxAirTime = 3, -- seconds airborne + holding height before a flag
		HoverSpeed = 4, -- downward speed still counted as "holding"
		ClimbSpeed = 60, -- upward speed counted as flying up
	},
	Schema = {
		AirHeight = { Min = 3, Max = 200, Description = "Studs above ground that count as airborne" },
		MaxAirTime = { Min = 1, Max = 60, Description = "Seconds airborne before a flag" },
		HoverSpeed = { Min = 0, Max = 50, Description = "Downward studs/s still counted as hovering" },
		ClimbSpeed = { Min = 1, Max = 500, Description = "Upward studs/s counted as flying up" },
	},

	Gather = function(_player: Player, state: any, _ctx: any)
		local root = state.Root :: BasePart?
		local character = state.Character
		state.Seated = ModuleUtil.Seated(state.Humanoid)
		state.InVehicle = ModuleUtil.InVehicle(root)
		state.HasMover = ModuleUtil.HasMover(character)
		if root and character then
			local depth = (state.Config and state.Config.AirHeight or 8) + 4
			state.GroundDistance = ModuleUtil.Ground(character, root, depth)
		end
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local now = state.Now
		local dt = if m.LastNow then math.clamp(now - m.LastNow, 0, 2) else 0
		m.LastNow = now
		if state.Seated or state.InVehicle or state.Flying or state.HasMover or state.Frozen then
			m.Air = 0
			return nil
		end
		local airborne = state.GroundDistance == nil or state.GroundDistance > (cfg.AirHeight or 8)
		local window = ModuleUtil.Window(state.Samples or {}, 0.6, now)
		local vy = 0
		if #window >= 2 then
			local a, b = window[1], window[#window]
			local span = b.T - a.T
			if span > 0 then
				vy = (b.P.Y - a.P.Y) / span
			end
		end
		local holding = vy > -(cfg.HoverSpeed or 4) and vy < (cfg.ClimbSpeed or 60)
		if airborne and holding then
			m.Air = (m.Air or 0) + dt
		else
			m.Air = 0
		end
		local limit = (cfg.MaxAirTime or 3) * math.max(1, (state.Lag or 1) / 1.5)
		if m.Air < limit then
			return nil
		end
		local seconds = m.Air
		m.Air = 0
		return {
			Confidence = ModuleUtil.Confidence(seconds / limit - 0.4, 0.5, 0.95),
			Reason = ("Airborne %.1f s holding height (vertical speed %.1f)"):format(seconds, vy),
			Evidence = { AirSeconds = seconds, VerticalSpeed = vy, Ground = state.GroundDistance },
			Correct = "position",
		}
	end,
}
