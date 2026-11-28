--!strict
--!native
--[[
	AutoClickerCheck.lua (Sentinel AntiCheat module)

	Detects auto-clickers and click macros on tools. Input: every
	Tool.Activated the server receives for a tool the player holds (noted
	by AntiCheatService), so it needs no game integration. Two signals:
	(1) clicks per second above MaxCps for Strikes seconds in a row, and
	(2) machine-regular clicking: at least MinClicks clicks in 5 s at
	MinRegularCps or faster whose intervals barely vary (coefficient of
	variation under MaxVariation) - human clicking at that speed varies a
	lot. False positives handled: holding the mouse fires Activated once
	(automatic weapons don't count); network jitter adds variation, so the
	regularity limit is strict; lag bursts (several clicks arriving in one
	frame) are ignored as intervals under 10 ms; one fast second never
	flags (Strikes). Severity is low: clicking fast is not always cheating.
--]]

return {
	Name = "AutoClickerCheck",
	Description = "Tool clicks faster than a human, or with machine-regular timing.",
	Enabled = true,
	Interval = 1,
	Severity = 3,
	Defaults = {
		MaxCps = 20, -- clicks per second
		Strikes = 2, -- seconds in a row over MaxCps
		MinClicks = 25, -- clicks in 5 s needed for the regularity test
		MinRegularCps = 7, -- regularity is tested only at this speed or faster
		MaxVariation = 0.08, -- interval std dev / mean below this = machine
	},
	Schema = {
		MaxCps = { Min = 5, Max = 200, Type = "integer", Description = "Clicks per second allowed" },
		Strikes = { Min = 1, Max = 10, Type = "integer", Description = "Seconds in a row over the limit" },
		MinClicks = { Min = 10, Max = 120, Type = "integer", Description = "Clicks in 5 s before the regularity test" },
		MinRegularCps = { Min = 2, Max = 50, Description = "Regularity is only tested at this speed or faster" },
		MaxVariation = { Min = 0, Max = 1, Description = "Interval variation below this counts as a machine" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Clicks = if ctx.Events then ctx.Events(player.UserId, "click", 5) else {}
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local clicks = state.Clicks or {}
		local now = state.Now
		local lastSecond = 0
		for i = #clicks, 1, -1 do
			if now - clicks[i].T <= 1 then
				lastSecond += 1
			else
				break
			end
		end
		local maxCps = cfg.MaxCps or 20
		if lastSecond > maxCps then
			m.Strikes = (m.Strikes or 0) + 1
			if m.Strikes >= (cfg.Strikes or 2) then
				m.Strikes = 0
				return {
					Confidence = math.clamp(lastSecond / maxCps - 0.5, 0.5, 0.9),
					Reason = ("%d clicks in one second (max %d)"):format(lastSecond, maxCps),
					Evidence = { Cps = lastSecond, Tool = clicks[#clicks] and clicks[#clicks].D and clicks[#clicks].D.Tool },
				}
			end
		else
			m.Strikes = 0
		end
		-- Regularity over the last 5 s (new clicks only once flagged).
		if #clicks < (cfg.MinClicks or 25) or (m.FlaggedT and clicks[1].T <= m.FlaggedT) then
			return nil
		end
		local intervals = {}
		for i = 2, #clicks do
			local d = clicks[i].T - clicks[i - 1].T
			if d >= 0.01 then
				table.insert(intervals, d)
			end
		end
		if #intervals < (cfg.MinClicks or 25) - 1 then
			return nil
		end
		local sum = 0
		for _, d in ipairs(intervals) do
			sum += d
		end
		local mean = sum / #intervals
		if mean <= 0 or 1 / mean < (cfg.MinRegularCps or 7) then
			return nil
		end
		local var = 0
		for _, d in ipairs(intervals) do
			var += (d - mean) ^ 2
		end
		local cv = math.sqrt(var / #intervals) / mean
		if cv >= (cfg.MaxVariation or 0.08) then
			return nil
		end
		m.FlaggedT = clicks[#clicks].T
		return {
			Confidence = math.clamp(1 - cv / math.max(cfg.MaxVariation or 0.08, 0.001) * 0.5, 0.5, 0.9),
			Reason = ("%d clicks at %.1f/s with machine-regular timing (variation %.3f)"):format(#clicks, 1 / mean, cv),
			Evidence = { Clicks = #clicks, Cps = 1 / mean, Variation = cv },
		}
	end,
}
