--!strict
--!native
--[[
	TeleportCheck.lua (Sentinel AntiCheat module)

	Detects instant position jumps: one sampling step (about 0.2 s) that
	covers more than MaxStep studs beyond what walking could explain.
	False positives handled: known teleports are registered as legitimate
	- Sentinel's teleport / movement commands (After hook), and any server
	script that sets the character's CFrame or calls PivotTo (the root's
	CFrame property change is only fired for script writes, never physics)
	- and a step that starts before the last known teleport is ignored;
	spawns are in grace; falling distance (downward) is not counted, so a
	long drop or falling off the map is fine; seats and vehicles are
	skipped (vehicles legitimately move fast); ping and server frame time
	widen the walking allowance.
--]]

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "TeleportCheck",
	Description = "Instant position jumps without a known teleport.",
	Enabled = true,
	Interval = 0.5,
	Severity = 7,
	SkipWhenSeated = true, -- seated, in a vehicle or anchored: nothing to measure
	SkipWhenStill = true, -- moved < 0.5 studs in 1.2 s: no step, jump or pass to check
	Defaults = {
		MaxStep = 40, -- studs in one step beyond walking
		Recent = 1, -- only steps in the last N seconds are examined
	},
	Schema = {
		MaxStep = { Min = 10, Max = 1000, Description = "Studs one step may cover beyond walking" },
		Recent = { Min = 0.25, Max = 5, Description = "Seconds of steps examined per check" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local humanoid = state.Humanoid :: Humanoid?
		state.WalkSpeed = if humanoid then humanoid.WalkSpeed else 16
		local boosts = state.Boosts -- Sentinel ;speed boost, not trusted
		if boosts and boosts.WalkSpeed then
			state.WalkSpeed = boosts.WalkSpeed
		end
		state.Seated = ModuleUtil.Seated(humanoid)
		state.InVehicle = ModuleUtil.InVehicle(state.Root)
		state.LastTeleport = if ctx.LastEvent then ctx.LastEvent(player.UserId, "teleport") else nil
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if state.Seated or state.InVehicle or state.Flying then
			return nil
		end
		local samples = state.Samples or {}
		local worst, worstStep = 0, nil
		for i = 2, #samples do
			local a, b = samples[i - 1], samples[i]
			if b.T > (m.LastT or -math.huge) and state.Now - b.T <= (cfg.Recent or 1) then
				local skip = state.LastTeleport ~= nil and state.LastTeleport >= a.T - 0.5
				if not skip then
					local dt = math.max(b.T - a.T, 1 / 60)
					local dy = b.P.Y - a.P.Y
					local up = math.max(0, dy) -- falling distance never counts
					local distance = math.sqrt(ModuleUtil.Horizontal(a.P, b.P) ^ 2 + up * up)
					local walking = (state.WalkSpeed or 16) * dt * (state.Lag or 1) * 2
					local excess = distance - walking
					if excess > worst then
						worst = excess
						worstStep = { Distance = distance, Dt = dt, From = a.P, To = b.P }
					end
				end
			end
		end
		local last = samples[#samples]
		if last then
			m.LastT = last.T
		end
		local maxStep = cfg.MaxStep or 40
		if not worstStep or worst <= maxStep then
			return nil
		end
		return {
			Confidence = ModuleUtil.Confidence(worst / maxStep - 0.5, 0.5, 1),
			Reason = ("Jumped %.0f studs in %.2f s with no known teleport"):format(worstStep.Distance, worstStep.Dt),
			Evidence = {
				Distance = worstStep.Distance,
				From = tostring(worstStep.From),
				To = tostring(worstStep.To),
			},
			Correct = "position",
		}
	end,
}
