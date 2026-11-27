--!strict
--[[
	EconomyCheck.lua (Sentinel AntiCheat module)

	Detects impossible gains: every numeric leaderstat (or only the ones in
	Stats) is sampled; a rise above PerMinuteCap per minute, or a single
	jump above SuddenJump with no known source, flags. Known sources =
	Sentinel economy commands (;give / ;addcurrency / ;reward ..., After
	hook), EconomyService rewards and anything the game reports with
	AntiCheatService.NoteEconomySource(player, stat, amount); their amount
	is subtracted from the rise. False positives handled: the first
	JoinGrace seconds are skipped (saved data loading sets the values);
	losses are never flagged; the caps are generous defaults - tune them
	to your game's real earn rates (Modules page > Configure); only
	numbers are read (strings / objects ignored).
--]]

return {
	Name = "EconomyCheck",
	Description = "Currency or stat gains above a per-minute cap or with no known source.",
	Enabled = true,
	Interval = 5,
	Severity = 7,
	Defaults = {
		PerMinuteCap = 100000,
		SuddenJump = 1000000,
		JoinGrace = 20,
		Stats = {}, -- leaderstat names to watch (empty = all numeric)
	},
	Schema = {
		PerMinuteCap = { Min = 1, Max = 1e12, Description = "Highest unexplained gain per minute" },
		SuddenJump = { Min = 1, Max = 1e15, Description = "Highest unexplained gain in one check" },
		JoinGrace = { Min = 0, Max = 300, Description = "Seconds after join that are skipped" },
		Stats = { Max = 30, Description = "Leaderstats to watch (comma separated, empty = all)" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local values = {}
		local folder = player:FindFirstChild("leaderstats")
		if folder then
			for _, v in ipairs(folder:GetChildren()) do
				if v:IsA("IntValue") or v:IsA("NumberValue") then
					values[v.Name] = (v :: any).Value
				end
			end
		end
		state.Values = values
		state.Sources = if ctx.Events then ctx.Events(player.UserId, "economySource", 60) else {}
		state.JoinedAt = if ctx.JoinedAt then ctx.JoinedAt(player.UserId) else nil
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if state.JoinedAt and state.Now - state.JoinedAt < (cfg.JoinGrace or 20) then
			m.Prev = nil
			return nil
		end
		local watch = {}
		for _, name in ipairs(cfg.Stats or {}) do
			watch[name] = true
		end
		local prev, prevT = m.Prev, m.T
		m.Prev, m.T = table.clone(state.Values or {}), state.Now
		if not prev or not prevT then
			return nil
		end
		local dt = math.max(state.Now - prevT, 0.5)
		local explained: { [string]: number } = {}
		for _, e in ipairs(state.Sources or {}) do
			if e.T >= prevT - 0.5 and type(e.D) == "table" then
				local stat = tostring(e.D.Stat or "*")
				explained[stat] = (explained[stat] or 0) + math.abs(tonumber(e.D.Amount) or math.huge)
			end
		end
		for stat, value in pairs(state.Values or {}) do
			if (next(watch) == nil or watch[stat]) and type(prev[stat]) == "number" then
				local gain = value - prev[stat] - (explained[stat] or 0) - (explained["*"] or 0)
				if gain > 0 then
					local perMinute = gain / dt * 60
					if gain > (cfg.SuddenJump or 1e6) or perMinute > (cfg.PerMinuteCap or 1e5) then
						return {
							Confidence = if gain > (cfg.SuddenJump or 1e6) then 0.7 else 0.5,
							Reason = ("%s rose %d in %.0f s (%.0f/min) with no known source"):format(stat, gain, dt, perMinute),
							Evidence = { Stat = stat, From = prev[stat], To = value, PerMinute = perMinute },
						}
					end
				end
			end
		end
		return nil
	end,
}
