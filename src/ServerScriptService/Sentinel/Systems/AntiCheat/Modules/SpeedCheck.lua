--!strict
--!native
--[[
	SpeedCheck.lua (Sentinel AntiCheat module)

	Detects moving faster than allowed: the real horizontal distance the
	server saw the root move over the last second, compared with WalkSpeed
	x time x the lag factor plus a margin. False positives handled: the
	WalkSpeed used is the one the server sees, so staff-granted speed
	(;speed, sprint modules) is already allowed; seats, vehicles (root welded
	to a bigger assembly) and PlatformStand are skipped; fast falling and
	Sentinel fly are skipped; ping and server frame time widen the limit
	(state.Lag); knockback / explosions are a single fast burst, so a flag
	needs Strikes consecutive violations; spawns and known teleports are in
	grace (ExemptionService).
--]]

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "SpeedCheck",
	Description = "Moving faster than WalkSpeed allows (server-measured distance).",
	Enabled = true,
	Interval = 0.5,
	Severity = 4,
	SkipWhenSeated = true, -- seated, in a vehicle or anchored: nothing to measure
	SkipWhenStill = true, -- moved < 0.5 studs in 1.2 s: no step, jump or pass to check
	-- Called by the engine instead of Check when it skips this check (see
	-- SkipWhenSeated / SkipWhenStill): does what Check would have done then.
	OnSkip = function(m: any, why: string)
		m.Strikes = if why == "seated" then 0 else math.max(0, (m.Strikes or 0) - 1)
	end,
	Defaults = {
		Margin = 4, -- studs per second on top of WalkSpeed x lag
		Strikes = 3, -- consecutive fast checks before a flag
		Window = 1, -- seconds of samples measured
		FallSpeed = 40, -- vertical speed (studs/s) above which a check is skipped
	},
	Schema = {
		Margin = { Min = 0, Max = 100, Description = "Extra studs per second allowed" },
		Strikes = { Min = 1, Max = 20, Type = "integer", Description = "Fast checks in a row before a flag" },
		Window = { Min = 0.4, Max = 5, Description = "Seconds of movement measured" },
		FallSpeed = { Min = 5, Max = 500, Description = "Skip while falling faster than this" },
	},

	Gather = function(_player: Player, state: any, _ctx: any)
		local humanoid = state.Humanoid :: Humanoid?
		state.WalkSpeed = if humanoid then humanoid.WalkSpeed else 16
		state.Seated = ModuleUtil.Seated(humanoid)
		state.InVehicle = ModuleUtil.InVehicle(state.Root)
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if state.Seated or state.InVehicle or state.Flying or state.Frozen then
			m.Strikes = 0
			return nil
		end
		local window = ModuleUtil.Window(state.Samples or {}, cfg.Window or 1, state.Now)
		if #window < 3 then
			return nil
		end
		local first, last = window[1], window[#window]
		local dt = last.T - first.T
		if dt < 0.4 then
			return nil
		end
		if math.abs(last.P.Y - first.P.Y) / dt > (cfg.FallSpeed or 40) then
			return nil -- falling / launched: not a walking measurement
		end
		local speed = ModuleUtil.Horizontal(first.P, last.P) / dt
		local allowed = (state.WalkSpeed or 16) * (state.Lag or 1) + (cfg.Margin or 4)
		if speed <= allowed then
			m.Strikes = math.max(0, (m.Strikes or 0) - 1)
			return nil
		end
		m.Strikes = (m.Strikes or 0) + 1
		if m.Strikes < (cfg.Strikes or 3) then
			return nil
		end
		m.Strikes = 0
		return {
			Confidence = ModuleUtil.Confidence((speed / allowed - 1) * 2, 0.35, 1),
			Reason = ("Moved %.1f studs/s, allowed %.1f (WalkSpeed %d)"):format(speed, allowed, state.WalkSpeed or 16),
			Evidence = { Speed = speed, Allowed = allowed, WalkSpeed = state.WalkSpeed, Lag = state.Lag },
			Correct = "position",
		}
	end,
}
