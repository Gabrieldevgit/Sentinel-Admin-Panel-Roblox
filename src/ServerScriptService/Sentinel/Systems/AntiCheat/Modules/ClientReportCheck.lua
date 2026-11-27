--!strict
--[[
	ClientReportCheck.lua (Sentinel AntiCheat module)

	Accepts tamper hints from the tiny client reporter
	(StarterPlayerScripts/Sentinel/AntiCheatReporter). Reports are only
	accepted with the player's session token (given by the server at join),
	from a short list of known kinds, size-checked and rate limited
	(AntiCheatService). Weighted low (severity 2, low confidence) because a
	client can be spoofed: these flags can never reach an action band on
	their own in practice. False positives handled: a reporter that is
	slow to start (slow devices, long loading) has HeartbeatTimeout seconds
	after join before "silent reporter" counts; one report kind is flagged
	at most once per ReportCooldown seconds; unknown kinds are ignored.
--]]

return {
	Name = "ClientReportCheck",
	Description = "Low-weight tamper hints from the client reporter (clients can be spoofed).",
	Enabled = true,
	Interval = 5,
	Severity = 2,
	Defaults = {
		HeartbeatTimeout = 90, -- seconds without a reporter heartbeat
		ReportCooldown = 60,
	},
	Schema = {
		HeartbeatTimeout = { Min = 20, Max = 900, Description = "Seconds without a reporter heartbeat" },
		ReportCooldown = { Min = 5, Max = 3600, Description = "Seconds between flags of the same report kind" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Reports = if ctx.Events then ctx.Events(player.UserId, "clientReport", 30) else {}
		state.LastHeartbeat = if ctx.LastEvent then ctx.LastEvent(player.UserId, "clientHeartbeat") else nil
		state.JoinedAt = if ctx.JoinedAt then ctx.JoinedAt(player.UserId) else nil
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		m.Flagged = m.Flagged or {}
		local cooldown = cfg.ReportCooldown or 60
		for _, e in ipairs(state.Reports or {}) do
			local kind = tostring((e.D and e.D.Kind) or "?")
			if e.T > (m.Seen or -math.huge) and state.Now - (m.Flagged[kind] or -math.huge) >= cooldown then
				m.Seen = e.T
				m.Flagged[kind] = state.Now
				return {
					Confidence = 0.3,
					Reason = ("Client reported: %s"):format(kind),
					Evidence = { Kind = kind, Detail = e.D and e.D.Detail },
				}
			end
		end
		local timeout = cfg.HeartbeatTimeout or 90
		local since = state.LastHeartbeat or state.JoinedAt
		if since and state.Now - since > timeout and state.Now - (m.Flagged.silent or -math.huge) >= cooldown * 5 then
			m.Flagged.silent = state.Now
			return {
				Confidence = 0.2,
				Reason = ("Client reporter silent for %d s"):format(math.floor(state.Now - since)),
				Evidence = { Silent = state.Now - since },
			}
		end
		return nil
	end,
}
