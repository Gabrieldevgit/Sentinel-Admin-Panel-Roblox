--!strict
--[[
	AltAndBanEvasion.lua (Sentinel AntiCheat module)

	Flags possible ban evasion when a new account joins: an account younger
	than MaxAccountAge days that joins within WindowMinutes of a ban on
	this or another server (bans are shared cross-server), or that is
	friends with a recently banned account. Flag only - this module can't
	prove anything, so staff decide: severity 4, low confidence, and it is
	checked once per session. False positives handled: older accounts are
	never flagged; the friend check (Player:IsFriendsWith, pcall'd) only
	looks at the last few bans; the time window keeps unrelated new
	players from matching bans from hours ago.
--]]

return {
	Name = "AltAndBanEvasion",
	Description = "New accounts joining right after a ban, or friends of banned accounts.",
	Enabled = true,
	Interval = 15,
	Severity = 4,
	Defaults = {
		MaxAccountAge = 7, -- days
		WindowMinutes = 30,
	},
	Schema = {
		MaxAccountAge = { Min = 1, Max = 365, Type = "integer", Description = "Accounts younger than this (days) are checked" },
		WindowMinutes = { Min = 1, Max = 1440, Type = "integer", Description = "Minutes after a ban that count" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.AccountAge = player.AccountAge
		local m = state.Module
		if m.Done then
			return
		end
		local windowSeconds = ((state.Config and state.Config.WindowMinutes) or 30) * 60
		local bans = if ctx.RecentBans then ctx.RecentBans(windowSeconds) else {}
		state.RecentBans = bans
		local friendOf: string? = nil
		if state.AccountAge < ((state.Config and state.Config.MaxAccountAge) or 7) then
			for i = 1, math.min(#bans, 5) do
				local ok, isFriend = pcall(function()
					return player:IsFriendsWith(bans[i].UserId)
				end)
				if ok and isFriend then
					friendOf = bans[i].Name
					break
				end
			end
		end
		state.FriendOf = friendOf
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if m.Done then
			return nil
		end
		m.Done = true
		local age = tonumber(state.AccountAge) or 9999
		if age >= (cfg.MaxAccountAge or 7) then
			return nil
		end
		if state.FriendOf then
			return {
				Confidence = 0.7,
				Reason = ("New account (%d days) is friends with recently banned %s"):format(age, state.FriendOf),
				Evidence = { AccountAge = age, FriendOf = state.FriendOf },
			}
		end
		local bans = state.RecentBans or {}
		if #bans > 0 then
			return {
				Confidence = 0.35,
				Reason = ("New account (%d days) joined %d min after %s was banned"):format(
					age,
					math.floor((os.time() - (bans[1].Time or os.time())) / 60),
					tostring(bans[1].Name)
				),
				Evidence = { AccountAge = age, RecentBans = #bans },
			}
		end
		return nil
	end,
}
