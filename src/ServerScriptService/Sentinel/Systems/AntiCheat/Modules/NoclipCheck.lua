--!strict
--[[
	NoclipCheck.lua (Sentinel AntiCheat module)

	Detects moving through solid geometry: a ray is cast along each recent
	step between two server positions; a pass is counted only when the ray
	hits an anchored, collidable part AND the reverse ray (end -> start)
	hits the same part, so the player really went through it (not just
	ended up touching it). A flag needs MinPasses passes within Window
	seconds. False positives handled: characters are excluded from the
	rays; non-collidable parts (open doors, triggers) and unanchored parts
	are ignored, as are parts with the attribute SentinelPassable and thin
	parts below MinThickness; known teleports and spawns are in grace
	(steps across a teleport are skipped); seats / vehicles are skipped;
	Sentinel noclip (SentinelNoclip) is skipped.
--]]

local Workspace = game:GetService("Workspace")

local ModuleUtil = require(script.Parent.Parent:WaitForChild("ModuleUtil"))

return {
	Name = "NoclipCheck",
	Description = "Passing through anchored, collidable parts.",
	Enabled = true,
	Interval = 0.5,
	Severity = 6,
	Defaults = {
		MinPasses = 3, -- passes needed within the window
		Window = 15, -- seconds
		MinThickness = 0.6, -- thinner parts are ignored
	},
	Schema = {
		MinPasses = { Min = 1, Max = 50, Type = "integer", Description = "Passes through walls before a flag" },
		Window = { Min = 2, Max = 120, Description = "Seconds the passes are counted over" },
		MinThickness = { Min = 0, Max = 10, Description = "Ignore parts thinner than this (studs)" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		state.Seated = ModuleUtil.Seated(state.Humanoid)
		state.InVehicle = ModuleUtil.InVehicle(state.Root)
		state.LastTeleport = if ctx.LastEvent then ctx.LastEvent(player.UserId, "teleport") else nil
		local m = state.Module
		local passes = {}
		local samples = state.Samples or {}
		if state.Character and not state.Seated and not state.InVehicle then
			local params = ModuleUtil.Params(state.Character)
			local minThickness = (state.Config and state.Config.MinThickness) or 0.6
			for i = 2, #samples do
				local a, b = samples[i - 1], samples[i]
				local fresh = b.T > (m.RayT or -math.huge)
				local acrossTeleport = state.LastTeleport ~= nil and state.LastTeleport >= a.T - 0.5
				local delta = b.P - a.P
				if fresh and not acrossTeleport and delta.Magnitude > 0.5 then
					local hit = Workspace:Raycast(a.P, delta, params)
					local part = hit and hit.Instance
					if part and part:IsA("BasePart") and part.Anchored and part.CanCollide and not part:GetAttribute("SentinelPassable") then
						local size = part.Size
						if math.min(size.X, size.Y, size.Z) >= minThickness then
							local back = Workspace:Raycast(b.P, -delta, params)
							if back and back.Instance == part then
								table.insert(passes, { T = b.T, Part = part:GetFullName() })
							end
						end
					end
				end
			end
		end
		local last = samples[#samples]
		if last then
			m.RayT = last.T
		end
		state.Passes = passes
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local m = state.Module
		if state.Noclip or state.Seated or state.InVehicle then
			m.List = {}
			return nil
		end
		m.List = m.List or {}
		for _, p in ipairs(state.Passes or {}) do
			table.insert(m.List, p)
		end
		local window = cfg.Window or 15
		for i = #m.List, 1, -1 do
			if state.Now - m.List[i].T > window then
				table.remove(m.List, i)
			end
		end
		local needed = cfg.MinPasses or 3
		if #m.List < needed then
			return nil
		end
		local parts = {}
		for _, p in ipairs(m.List) do
			if not table.find(parts, p.Part) then
				table.insert(parts, p.Part)
			end
		end
		local count = #m.List
		m.List = {}
		return {
			Confidence = ModuleUtil.Confidence(count / needed * 0.6, 0.5, 0.95),
			Reason = ("Passed through solid parts %d times in %ds"):format(count, window),
			Evidence = { Passes = count, Parts = parts },
			Correct = "position",
		}
	end,
}
