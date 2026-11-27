--!strict
--!native
--[[
	HealthCheck.lua (Sentinel AntiCheat module)

	Detects god mode and health rewrites, as the server sees the Humanoid:
	health that rises faster than natural regeneration with no heal
	source, MaxHealth that rises with no heal source, and health that does
	not drop after damage the game confirmed (AntiCheatService.NoteDamage).
	False positives handled: Roblox's default regeneration (RegenPerSecond
	of MaxHealth, widened by the lag factor) is allowed; heals noted by
	Sentinel's ;heal / ;god / ;health commands (After hook) or by the game
	(AntiCheatService.NoteHeal) open a HealGrace window; a ForceField or
	Sentinel god mode (SentinelGod) skips the check; respawns reset the
	baseline (per-character scratch); a dead humanoid is skipped.
--]]

return {
	Name = "HealthCheck",
	Description = "Health that rises with no heal source, or never drops after damage.",
	Enabled = true,
	Interval = 1,
	Severity = 5,
	Defaults = {
		RegenPerSecond = 0.01, -- share of MaxHealth regenerated per second (Roblox default 1 %)
		Margin = 5, -- health points on top of the regen allowance
		HealGrace = 2, -- seconds after a known heal
		DamageDelay = 1, -- seconds after confirmed damage before it must show
	},
	Schema = {
		RegenPerSecond = { Min = 0, Max = 1, Description = "Share of MaxHealth regenerated per second" },
		Margin = { Min = 0, Max = 1000, Description = "Extra health points allowed per check" },
		HealGrace = { Min = 0, Max = 30, Description = "Seconds after a known heal" },
		DamageDelay = { Min = 0.2, Max = 10, Description = "Seconds before confirmed damage must show" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local humanoid = state.Humanoid :: Humanoid?
		if humanoid then
			state.Health = humanoid.Health
			state.MaxHealth = humanoid.MaxHealth
		end
		state.ForceField = state.Character ~= nil and state.Character:FindFirstChildOfClass("ForceField") ~= nil
		state.LastHeal = if ctx.LastEvent then ctx.LastEvent(player.UserId, "heal") else nil
		state.Damage = if ctx.Events then ctx.Events(player.UserId, "damage", 6) else {}
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local health, maxHealth = state.Health, state.MaxHealth
		if health == nil or maxHealth == nil then
			return nil
		end
		local now = state.Now
		local lastHealth, lastMax, lastT = m.Health, m.Max, m.T
		m.Health, m.Max, m.T = health, maxHealth, now
		if state.God or state.ForceField or health <= 0 then
			return nil
		end
		local healed = state.LastHeal ~= nil and now - state.LastHeal <= (cfg.HealGrace or 2)
		-- Confirmed damage that never showed.
		for _, e in ipairs(state.Damage or {}) do
			local d = e.D or {}
			local age = now - e.T
			if not healed and age >= (cfg.DamageDelay or 1) and type(d.Amount) == "number" and d.Amount > 0
				and type(d.Before) == "number" and health >= d.Before and e.T > (m.SeenT or -math.huge) then
				m.SeenT = e.T
				return {
					Confidence = 0.6,
					Reason = ("Took %d confirmed damage but health stayed at %d"):format(d.Amount, math.floor(health)),
					Evidence = { Damage = d.Amount, Before = d.Before, Health = health },
					Correct = "health",
				}
			end
		end
		if lastHealth == nil or lastT == nil or healed then
			return nil
		end
		local dt = math.clamp(now - lastT, 0, 5)
		if maxHealth > (lastMax or maxHealth) + 0.5 then
			return {
				Severity = 6,
				Confidence = 0.6,
				Reason = ("MaxHealth rose %d -> %d with no heal source"):format(math.floor(lastMax or 0), math.floor(maxHealth)),
				Evidence = { From = lastMax, To = maxHealth },
			}
		end
		local allowance = maxHealth * (cfg.RegenPerSecond or 0.01) * dt * (state.Lag or 1) + (cfg.Margin or 5)
		local gain = health - lastHealth
		if gain > allowance then
			return {
				Confidence = math.clamp(gain / math.max(maxHealth, 1), 0.4, 0.9),
				Reason = ("Health rose %d in %.1f s (allowed %d) with no heal source"):format(math.floor(gain), dt, math.floor(allowance)),
				Evidence = { From = lastHealth, To = health, Allowed = allowance },
				Correct = "health",
				RestoreHealth = lastHealth,
			}
		end
		return nil
	end,
}
