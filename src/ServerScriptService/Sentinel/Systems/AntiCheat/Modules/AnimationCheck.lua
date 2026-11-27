--!strict
--[[
	AnimationCheck.lua (Sentinel AntiCheat module)

	Detects forbidden or spoofed animations: the animation tracks playing
	on the character's Animator (client-played tracks replicate to the
	server) are compared with an allowlist. The allowlist = the module's
	Allow list (ids your game uses) + every Animation found under the
	character at spawn (the Animate script's walk / run / jump / idle ...)
	+ every Animation in ReplicatedStorage, StarterPlayer and StarterPack at
	boot. False positives handled: with RequireAllowlist on (default) the
	module stays quiet until you fill the Allow list, so games with emotes
	or catalog animations are not flagged out of the box; an unknown track
	must show in Repeats checks in a row; the Deny list flags at once
	(higher confidence); severity is low (3) because it is a weak signal.
--]]

return {
	Name = "AnimationCheck",
	Description = "Animation tracks that are not on the game's allowlist.",
	Enabled = true,
	Interval = 3,
	Severity = 3,
	Defaults = {
		RequireAllowlist = true, -- stay quiet until Allow has entries
		Repeats = 2,
		Allow = {}, -- animation ids (numbers or rbxassetid://)
		Deny = {}, -- ids that always flag
	},
	Schema = {
		RequireAllowlist = { Description = "Only check once the Allow list has ids" },
		Repeats = { Min = 1, Max = 20, Type = "integer", Description = "Checks in a row an unknown track must show" },
		Allow = { Max = 300, Description = "Allowed animation ids (comma separated)" },
		Deny = { Max = 100, Description = "Animation ids that always flag (comma separated)" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local ids = {}
		local humanoid = state.Humanoid :: Humanoid?
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				local animation = track.Animation
				if animation then
					table.insert(ids, animation.AnimationId)
				end
			end
		end
		state.Playing = ids
		local known = if ctx.KnownAnimations then ctx.KnownAnimations(player) else {}
		state.Known = known
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		local function idOf(s: any): string
			return tostring(s):match("(%d+)") or tostring(s)
		end
		local allow, deny = {}, {}
		for _, id in ipairs(cfg.Allow or {}) do
			allow[idOf(id)] = true
		end
		for _, id in ipairs(cfg.Deny or {}) do
			deny[idOf(id)] = true
		end
		for id in pairs(state.Known or {}) do
			allow[idOf(id)] = true
		end
		local denied, unknown = {}, {}
		for _, raw in ipairs(state.Playing or {}) do
			local id = idOf(raw)
			if deny[id] then
				table.insert(denied, id)
			elseif not allow[id] then
				table.insert(unknown, id)
			end
		end
		if #denied > 0 then
			return {
				Confidence = 0.8,
				Reason = "Playing a denied animation: " .. table.concat(denied, ", "),
				Evidence = { Denied = denied },
			}
		end
		if cfg.RequireAllowlist ~= false and #(cfg.Allow or {}) == 0 then
			return nil
		end
		if #unknown == 0 then
			m.Streak = 0
			return nil
		end
		m.Streak = (m.Streak or 0) + 1
		if m.Streak < (cfg.Repeats or 2) then
			return nil
		end
		m.Streak = 0
		return {
			Confidence = 0.4,
			Reason = "Animation(s) not on the allowlist: " .. table.concat(unknown, ", "):sub(1, 120),
			Evidence = { Unknown = unknown },
		}
	end,
}
