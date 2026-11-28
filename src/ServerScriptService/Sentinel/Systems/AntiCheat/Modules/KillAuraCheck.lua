--!strict
--!native
--[[
	KillAuraCheck.lua (Sentinel AntiCheat module)

	Detects kill aura / hit-all scripts: hitting many different targets at
	once, or hitting targets behind the player. Input: hits noted by
	AntiCheatService (ValidateHit from the game, or classic "creator" tags)
	with the victim and the attacker's facing angle off the victim at the
	time of the hit. False positives handled: area weapons can hit a crowd,
	so MaxTargets distinct victims within one second must be EXCEEDED, and
	Strikes such seconds are needed; the facing is the server's root
	rotation (sampled), so "behind" means more than BehindDegrees off and
	at close range only (a sword sweeping past a target beside the player
	is ~90 deg); MinBehind behind-hits in 5 s are needed; each hit counts
	once.
--]]

return {
	Name = "KillAuraCheck",
	Description = "Hitting many targets at once, or targets behind the player.",
	Enabled = true,
	Interval = 1,
	Severity = 5,
	Defaults = {
		MaxTargets = 3, -- distinct victims within one second
		Strikes = 2, -- such seconds within 10 s
		BehindDegrees = 120, -- facing this far off the victim = behind
		BehindRange = 20, -- studs: only close hits count as behind-hits
		MinBehind = 4, -- behind-hits in 5 s before a flag
	},
	Schema = {
		MaxTargets = { Min = 1, Max = 50, Type = "integer", Description = "Distinct targets hit within one second" },
		Strikes = { Min = 1, Max = 20, Type = "integer", Description = "Seconds over MaxTargets within 10 s" },
		BehindDegrees = { Min = 60, Max = 180, Description = "Facing this far off counts as behind" },
		BehindRange = { Min = 1, Max = 200, Description = "Only hits closer than this count as behind" },
		MinBehind = { Min = 1, Max = 50, Type = "integer", Description = "Behind-hits in 5 s before a flag" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Hits = if ctx.Events then ctx.Events(player.UserId, "hit", 10) else {}
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local hits = state.Hits or {}
		local now = state.Now
		-- Distinct victims in the last second.
		local victims, count = {}, 0
		for i = #hits, 1, -1 do
			local e = hits[i]
			if now - e.T > 1 then
				break
			end
			local v = e.D and e.D.Victim
			if v ~= nil and not victims[v] then
				victims[v] = true
				count += 1
			end
		end
		m.Crowd = m.Crowd or {}
		if count > (cfg.MaxTargets or 3) and (m.LastCrowdT == nil or now - m.LastCrowdT >= 1) then
			m.LastCrowdT = now
			table.insert(m.Crowd, now)
		end
		for i = #m.Crowd, 1, -1 do
			if now - m.Crowd[i] > 10 then
				table.remove(m.Crowd, i)
			end
		end
		if #m.Crowd >= (cfg.Strikes or 2) then
			m.Crowd = {}
			return {
				Confidence = math.clamp(count / (cfg.MaxTargets or 3) * 0.5, 0.5, 0.9),
				Reason = ("Hit %d different targets within one second (max %d), repeatedly"):format(count, cfg.MaxTargets or 3),
				Evidence = { Targets = count },
			}
		end
		-- Behind-hits.
		m.Behind = m.Behind or {}
		for _, e in ipairs(hits) do
			local h = e.D or {}
			if e.T > (m.Seen or -math.huge) and type(h.Angle) == "number" and h.Angle >= (cfg.BehindDegrees or 120)
				and (type(h.Distance) ~= "number" or h.Distance <= (cfg.BehindRange or 20)) then
				table.insert(m.Behind, { T = e.T, Angle = h.Angle })
			end
		end
		if #hits > 0 then
			m.Seen = hits[#hits].T
		end
		for i = #m.Behind, 1, -1 do
			if now - m.Behind[i].T > 5 then
				table.remove(m.Behind, i)
			end
		end
		if #m.Behind >= (cfg.MinBehind or 4) then
			local n = #m.Behind
			m.Behind = {}
			return {
				Confidence = math.clamp(n / (cfg.MinBehind or 4) * 0.55, 0.5, 0.9),
				Reason = ("%d hits on targets behind the player in 5 s"):format(n),
				Evidence = { BehindHits = n },
			}
		end
		return nil
	end,
}
