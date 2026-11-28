--!strict
--!native
--[[
	HumanoidStatsCheck.lua (Sentinel AntiCheat module)

	Detects Humanoid values above the game's limits as the SERVER sees them:
	WalkSpeed, JumpPower / JumpHeight and MaxHealth. A client-side speed
	hack never changes these on the server (SpeedCheck / JumpCheck measure
	that movement); a server-side value this high comes from a backdoor
	script, a free-model admin, or an admin command (Sentinel's or HD
	Admin's). False positives handled: every limit is a game setting (set
	them above your sprint / power-up values; 0 turns a limit off); a value
	must stay over the limit for Strikes checks in a row (a short power-up
	pulse is fine), and a lasting violation re-flags only every
	RepeatSeconds; a Sentinel command boost is skipped while
	Core.TrustSentinelCommands is on; a frozen or dead humanoid is skipped.
	HD Admin's server-side :speed / :jumppower can't be told apart from the
	game's own writes, so they are checked like anything else.
--]]

return {
	Name = "HumanoidStatsCheck",
	Description = "Server-side WalkSpeed, JumpPower or MaxHealth above the game's limits.",
	Enabled = true,
	Interval = 1,
	Severity = 4,
	Defaults = {
		MaxWalkSpeed = 50, -- studs/s (Roblox walk 16, Sentinel sprint 26)
		MaxJumpPower = 80, -- Roblox default 50
		MaxJumpHeight = 16, -- studs (Roblox default 7.2)
		MaxHealth = 0, -- 0 = off (games with health upgrades: set the real top)
		Strikes = 2, -- checks in a row over a limit
		RepeatSeconds = 15, -- while still over, flag again only this often
	},
	Schema = {
		MaxWalkSpeed = { Min = 0, Max = 10000, Description = "Highest WalkSpeed the game gives (0 = off)" },
		MaxJumpPower = { Min = 0, Max = 10000, Description = "Highest JumpPower the game gives (0 = off)" },
		MaxJumpHeight = { Min = 0, Max = 1000, Description = "Highest JumpHeight the game gives (0 = off)" },
		MaxHealth = { Min = 0, Max = 1000000, Description = "Highest MaxHealth the game gives (0 = off)" },
		Strikes = { Min = 1, Max = 20, Type = "integer", Description = "Checks in a row over a limit before a flag" },
		RepeatSeconds = { Min = 1, Max = 600, Description = "While still over a limit, flag again only this often" },
	},

	Gather = function(_player: Player, state: any, _ctx: any)
		local humanoid = state.Humanoid :: Humanoid?
		if humanoid then
			state.Stats = {
				WalkSpeed = humanoid.WalkSpeed,
				JumpPower = if humanoid.UseJumpPower then humanoid.JumpPower else nil,
				JumpHeight = if humanoid.UseJumpPower then nil else humanoid.JumpHeight,
				MaxHealth = humanoid.MaxHealth,
				Dead = humanoid.Health <= 0,
			}
		end
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local stats = state.Stats
		if not stats or stats.Dead or state.Frozen then
			m.Strikes = 0
			return nil
		end
		-- Trusted Sentinel boosts: CommandBoosts lists them, Boosts is nil
		-- while Core.TrustSentinelCommands is on.
		local trusted = if state.Boosts == nil then (state.CommandBoosts or {}) else {}
		local over, restore = {}, {}
		local function test(prop: string, limit: number?)
			local value = stats[prop]
			if type(value) ~= "number" or not limit or limit <= 0 or trusted[prop] ~= nil then
				return
			end
			if value > limit and value < math.huge then
				table.insert(over, ("%s %d (max %d)"):format(prop, math.floor(value), math.floor(limit)))
				restore[prop] = (state.Boosts and state.Boosts[prop]) or limit
			elseif value == math.huge then
				table.insert(over, ("%s inf (max %d)"):format(prop, math.floor(limit)))
				restore[prop] = limit
			end
		end
		test("WalkSpeed", cfg.MaxWalkSpeed)
		test("JumpPower", cfg.MaxJumpPower)
		test("JumpHeight", cfg.MaxJumpHeight)
		test("MaxHealth", cfg.MaxHealth)
		if #over == 0 then
			m.Strikes = 0
			m.LastFlagT = nil
			return nil
		end
		if m.LastFlagT and state.Now - m.LastFlagT < (cfg.RepeatSeconds or 15) then
			return nil -- same violation, already flagged recently
		end
		m.Strikes = (m.Strikes or 0) + 1
		if m.Strikes < (cfg.Strikes or 2) then
			return nil
		end
		m.Strikes = 0
		m.LastFlagT = state.Now
		return {
			Confidence = math.clamp(0.4 + 0.15 * #over, 0.4, 0.85),
			Reason = "Humanoid over the game's limits: " .. table.concat(over, ", "),
			Evidence = { Over = over, Stats = stats },
			Correct = "humanoid",
			Restore = restore,
		}
	end,
}
