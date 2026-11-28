--!strict
--!native
--[[
	AimbotCheck.lua (Sentinel AntiCheat module)

	Detects aim assistance from what the server sees at each hit and shot.
	Inputs (noted by AntiCheatService): hits from ValidateHit or classic
	"creator" tags carry the attacker's facing angle off the victim and how
	far the attacker's root turned in the ~0.2-0.6 s before the hit; shots
	the game reports with AntiCheatService.ReportShot carry hit / headshot.
	Signals: (1) snap hits - a large turn just before a hit that lands dead
	on a target at range, MinSnaps times in 20 s; (2) accuracy - hit rate
	over MinShots ranged shots, or headshot rate over MinHits hits, above
	what players reach. False positives handled: melee range hits are
	ignored (MinDistance); the facing comes from 5 Hz server samples, so a
	snap must be big (SnapDegrees) and the final aim tight (AimDegrees);
	accuracy needs many shots (no game reports = signal 2 stays silent);
	each hit is counted once. Good players flick too, so severity is
	moderate and several snaps are needed.
--]]

return {
	Name = "AimbotCheck",
	Description = "Snap-to-target hits and inhuman hit / headshot rates.",
	Enabled = true,
	Interval = 2,
	Severity = 5,
	Defaults = {
		MinDistance = 20, -- studs: closer hits are melee, not aim
		SnapDegrees = 70, -- turn in the moment before the hit
		AimDegrees = 6, -- final aim this close to the target
		MinSnaps = 4, -- snap hits in 20 s before a flag
		MinShots = 25, -- reported shots before the accuracy test
		MaxHitRate = 0.92, -- hit share over MinShots
		MinHits = 12, -- hits before the headshot test
		MaxHeadshotRate = 0.8, -- headshot share of hits
	},
	Schema = {
		MinDistance = { Min = 0, Max = 1000, Description = "Ignore hits closer than this (studs)" },
		SnapDegrees = { Min = 10, Max = 180, Description = "Turn before a hit that counts as a snap" },
		AimDegrees = { Min = 1, Max = 45, Description = "Final aim within this many degrees" },
		MinSnaps = { Min = 1, Max = 50, Type = "integer", Description = "Snap hits in 20 s before a flag" },
		MinShots = { Min = 5, Max = 500, Type = "integer", Description = "Shots before the accuracy test" },
		MaxHitRate = { Min = 0.3, Max = 1, Description = "Highest normal hit share" },
		MinHits = { Min = 3, Max = 500, Type = "integer", Description = "Hits before the headshot test" },
		MaxHeadshotRate = { Min = 0.2, Max = 1, Description = "Highest normal headshot share" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Hits = if ctx.Events then ctx.Events(player.UserId, "hit", 20) else {}
		state.Shots = if ctx.Events then ctx.Events(player.UserId, "shot", 30) else {}
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local minDistance = cfg.MinDistance or 20
		-- (1) Snap hits.
		m.Snaps = m.Snaps or {}
		for _, e in ipairs(state.Hits or {}) do
			local h = e.D or {}
			if e.T > (m.SeenHit or -math.huge) and type(h.Distance) == "number" and h.Distance >= minDistance
				and type(h.Turn) == "number" and type(h.Angle) == "number"
				and h.Turn >= (cfg.SnapDegrees or 70) and h.Angle <= (cfg.AimDegrees or 6) then
				table.insert(m.Snaps, { T = e.T, Turn = h.Turn, Angle = h.Angle, Distance = h.Distance })
			end
		end
		local hits = state.Hits or {}
		if #hits > 0 then
			m.SeenHit = hits[#hits].T
		end
		for i = #m.Snaps, 1, -1 do
			if state.Now - m.Snaps[i].T > 20 then
				table.remove(m.Snaps, i)
			end
		end
		if #m.Snaps >= (cfg.MinSnaps or 4) then
			local n = #m.Snaps
			local first = m.Snaps[1]
			m.Snaps = {}
			return {
				Confidence = math.clamp(n / (cfg.MinSnaps or 4) * 0.55, 0.5, 0.9),
				Reason = ("%d snap hits in 20 s (turned %.0f deg, landed %.1f deg off at %.0f studs)"):format(n, first.Turn, first.Angle, first.Distance),
				Evidence = { Snaps = n, Turn = first.Turn, Angle = first.Angle, Distance = first.Distance },
			}
		end
		-- (2) Accuracy from the game's shot reports (new shots only once flagged).
		local shots = {}
		for _, e in ipairs(state.Shots or {}) do
			if e.T > (m.AccFlaggedT or -math.huge) then
				table.insert(shots, e)
			end
		end
		local hitCount, headshots, ranged = 0, 0, 0
		for _, e in ipairs(shots) do
			local d = e.D or {}
			if d.Hit then
				hitCount += 1
				if d.Headshot then
					headshots += 1
				end
			end
			if type(d.Distance) ~= "number" or d.Distance >= minDistance then
				ranged += 1
			end
		end
		if ranged >= (cfg.MinShots or 25) and hitCount / #shots > (cfg.MaxHitRate or 0.92) then
			m.AccFlaggedT = shots[#shots].T
			return {
				Confidence = 0.6,
				Reason = ("Hit %d of %d shots (%.0f%%, max %.0f%%)"):format(hitCount, #shots, hitCount / #shots * 100, (cfg.MaxHitRate or 0.92) * 100),
				Evidence = { Shots = #shots, Hits = hitCount },
			}
		end
		if hitCount >= (cfg.MinHits or 12) and headshots / hitCount > (cfg.MaxHeadshotRate or 0.8) then
			m.AccFlaggedT = shots[#shots].T
			return {
				Confidence = 0.6,
				Reason = ("%d headshots in %d hits (%.0f%%, max %.0f%%)"):format(headshots, hitCount, headshots / hitCount * 100, (cfg.MaxHeadshotRate or 0.8) * 100),
				Evidence = { Hits = hitCount, Headshots = headshots },
			}
		end
		return nil
	end,
}
