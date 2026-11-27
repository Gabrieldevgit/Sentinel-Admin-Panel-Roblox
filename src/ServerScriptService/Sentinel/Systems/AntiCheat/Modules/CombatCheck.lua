--!strict
--[[
	CombatCheck.lua (Sentinel AntiCheat module)

	Detects impossible hit rates or ranges. Hits are validated on the
	server: either the game calls AntiCheatService.ValidateHit(attacker,
	victim, { Range, Cooldown, Weapon }) from its own damage code (distance
	from the attacker's root, a line-of-sight raycast, the time since the
	previous hit with the same weapon), or, with no game integration,
	AntiCheatService watches Humanoid damage tagged with the classic
	"creator" ObjectValue and records the distance. False positives
	handled: the range allowance grows with the lag factor (moving targets
	and ping put both players apart on the server); a cooldown is only
	broken below CooldownTolerance of the stated cooldown; one odd hit never
	flags - MinBadHits invalid hits within 5 s are needed; area damage
	(explosions) is not a hit unless the game reports it as one.
--]]

return {
	Name = "CombatCheck",
	Description = "Hits from too far, through walls, or faster than the weapon allows.",
	Enabled = true,
	Interval = 1,
	Severity = 6,
	Defaults = {
		MaxRange = 20, -- studs when the game gives no range
		RangeMargin = 4,
		CooldownTolerance = 0.7, -- a hit sooner than 70 % of the cooldown is too fast
		MaxHitsPerSecond = 12,
		MinBadHits = 3, -- invalid hits within 5 s before a flag
	},
	Schema = {
		MaxRange = { Min = 1, Max = 2000, Description = "Default weapon range in studs" },
		RangeMargin = { Min = 0, Max = 200, Description = "Extra studs allowed" },
		CooldownTolerance = { Min = 0.1, Max = 1, Description = "Share of the cooldown that must pass" },
		MaxHitsPerSecond = { Min = 1, Max = 100, Type = "integer", Description = "Hits per second allowed" },
		MinBadHits = { Min = 1, Max = 50, Type = "integer", Description = "Invalid hits in 5 s before a flag" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Hits = if ctx.Events then ctx.Events(player.UserId, "hit", 5) else {}
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local bad = {}
		local lastSecond = 0
		for _, e in ipairs(state.Hits or {}) do
			local h = e.D or {}
			if state.Now - e.T <= 1 then
				lastSecond += 1
			end
			if e.T > (m.Seen or -math.huge) then
				local range = (tonumber(h.Range) or cfg.MaxRange or 20) * (state.Lag or 1) + (cfg.RangeMargin or 4)
				if type(h.Distance) == "number" and h.Distance > range then
					table.insert(bad, ("range %.0f > %.0f"):format(h.Distance, range))
				elseif h.LineOfSight == false then
					table.insert(bad, "no line of sight")
				elseif type(h.Cooldown) == "number" and type(h.Since) == "number" and h.Since < h.Cooldown * (cfg.CooldownTolerance or 0.7) then
					table.insert(bad, ("%.2fs between hits (cooldown %.2fs)"):format(h.Since, h.Cooldown))
				end
			end
		end
		local hits = state.Hits or {}
		if #hits > 0 then
			m.Seen = hits[#hits].T
		end
		m.Bad = m.Bad or {}
		for _, b in ipairs(bad) do
			table.insert(m.Bad, { T = state.Now, Why = b })
		end
		for i = #m.Bad, 1, -1 do
			if state.Now - m.Bad[i].T > 5 then
				table.remove(m.Bad, i)
			end
		end
		if lastSecond > (cfg.MaxHitsPerSecond or 12) then
			return {
				Confidence = 0.7,
				Reason = ("%d hits in one second (max %d)"):format(lastSecond, cfg.MaxHitsPerSecond or 12),
				Evidence = { HitsPerSecond = lastSecond },
			}
		end
		if #m.Bad >= (cfg.MinBadHits or 3) then
			local reasons = {}
			for _, b in ipairs(m.Bad) do
				table.insert(reasons, b.Why)
			end
			local n = #m.Bad
			m.Bad = {}
			return {
				Confidence = math.clamp(n / (cfg.MinBadHits or 3) * 0.6, 0.5, 0.95),
				Reason = ("%d invalid hits in 5 s: %s"):format(n, table.concat(reasons, "; "):sub(1, 140)),
				Evidence = { Invalid = reasons },
			}
		end
		return nil
	end,
}
