--!strict
--[[
	RemoteSpamCheck.lua (Sentinel AntiCheat module)

	Detects remote flooding and abuse. Inputs (noted by AntiCheatService):
	every call on the game's RemoteEvents (one counter per remote and
	second), drops reported by Sentinel's shared Core/RateLimiter (each
	Sentinel remote is already rate limited there), and calls whose
	arguments failed validation (wrong type, oversized table, nil). False
	positives handled: limits are per remote and per second with a burst
	allowance, so normal UI clicking and tools never come close; a short
	lag spike that bunches up queued calls is absorbed by the Strikes
	counter (two bad seconds in a row before a flood flag); rate-limit
	drops need DropThreshold drops in 5 s; argument errors need
	BadArgThreshold errors in 10 s.
--]]

return {
	Name = "RemoteSpamCheck",
	Description = "Remote flooding (calls per second), rate-limit drops and bad arguments.",
	Enabled = true,
	Interval = 1,
	Severity = 5,
	Defaults = {
		MaxPerRemote = 40, -- calls per second on one remote
		MaxTotal = 90, -- calls per second on all remotes
		Strikes = 2, -- seconds over the limit in a row
		DropThreshold = 8, -- rate-limit drops in 5 s
		BadArgThreshold = 3, -- invalid argument calls in 10 s
	},
	Schema = {
		MaxPerRemote = { Min = 5, Max = 1000, Type = "integer", Description = "Calls per second on one remote" },
		MaxTotal = { Min = 10, Max = 5000, Type = "integer", Description = "Calls per second on all remotes" },
		Strikes = { Min = 1, Max = 10, Type = "integer", Description = "Seconds over the limit in a row" },
		DropThreshold = { Min = 1, Max = 200, Type = "integer", Description = "Rate-limit drops in 5 s" },
		BadArgThreshold = { Min = 1, Max = 100, Type = "integer", Description = "Invalid argument calls in 10 s" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		if not ctx.Events then
			return
		end
		state.Calls = ctx.Events(player.UserId, "remote", 1)
		state.Drops = ctx.Events(player.UserId, "remoteDrop", 5)
		state.BadArgs = ctx.Events(player.UserId, "badArgs", 10)
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local perRemote: { [string]: number } = {}
		local total = 0
		for _, e in ipairs(state.Calls or {}) do
			local name = (e.D and e.D.Name) or "?"
			perRemote[name] = (perRemote[name] or 0) + 1
			total += 1
		end
		local worstName, worst = nil, 0
		for name, n in pairs(perRemote) do
			if n > worst then
				worstName, worst = name, n
			end
		end
		local over = worst > (cfg.MaxPerRemote or 40) or total > (cfg.MaxTotal or 90)
		m.Strikes = if over then (m.Strikes or 0) + 1 else 0
		if m.Strikes >= (cfg.Strikes or 2) then
			m.Strikes = 0
			return {
				Confidence = math.clamp(worst / (cfg.MaxPerRemote or 40) - 0.5, 0.5, 1),
				Reason = ("Remote flood: %d calls/s on %s (%d total)"):format(worst, tostring(worstName), total),
				Evidence = { PerRemote = perRemote, Total = total },
			}
		end
		local drops = state.Drops or {}
		if #drops >= (cfg.DropThreshold or 8) and (m.LastDropFlag or -math.huge) < state.Now - 5 then
			m.LastDropFlag = state.Now
			local names = {}
			for _, e in ipairs(drops) do
				local n = (e.D and e.D.Name) or "?"
				if not table.find(names, n) then
					table.insert(names, n)
				end
			end
			return {
				Severity = 4,
				Confidence = 0.6,
				Reason = ("%d requests dropped by rate limits in 5 s (%s)"):format(#drops, table.concat(names, ", ")),
				Evidence = { Drops = #drops, Remotes = names },
			}
		end
		local bad = state.BadArgs or {}
		if #bad >= (cfg.BadArgThreshold or 3) and (m.LastBadFlag or -math.huge) < state.Now - 10 then
			m.LastBadFlag = state.Now
			local detail = bad[#bad].D or {}
			return {
				Confidence = 0.7,
				Reason = ("%d calls with invalid arguments in 10 s (last: %s - %s)"):format(#bad, tostring(detail.Name), tostring(detail.Why)),
				Evidence = { Count = #bad, Last = detail },
			}
		end
		return nil
	end,
}
