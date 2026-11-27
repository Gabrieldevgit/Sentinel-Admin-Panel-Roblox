--!strict
--!native
--[[
	ToolIntegrityCheck.lua (Sentinel AntiCheat module)

	Detects tools the server did not give, and duplicated tools. The
	server's own view of the Backpack and the character is compared with
	the known tool catalog: tools found at boot in StarterPack,
	ServerStorage (including SentinelTools, which InventoryService gives),
	ReplicatedStorage and Lighting, the player's StarterGear, the module's
	Allow list, and every tool the game registers with
	AntiCheatService.RegisterTool. False positives handled: tools a game
	gives from those places are known by name, so only truly unknown ones
	flag (and FlagUnknown can be switched off for games that build tools
	at runtime); duplicates need more than MaxDuplicates copies; a tool
	being moved between Backpack and character is counted once; Sentinel's
	own ;give / ;removeitem are registered by the After hook.
--]]

return {
	Name = "ToolIntegrityCheck",
	Description = "Tools the server never gave, or duplicated tools.",
	Enabled = true,
	Interval = 3,
	Severity = 6,
	Defaults = {
		MaxDuplicates = 2, -- copies of one tool allowed
		FlagUnknown = true,
		Allow = {}, -- extra tool names (comma list)
	},
	Schema = {
		MaxDuplicates = { Min = 1, Max = 100, Type = "integer", Description = "Copies of the same tool allowed" },
		FlagUnknown = { Description = "Flag tools that are not in the known catalog" },
		Allow = { Max = 200, Description = "Extra known tool names (comma separated)" },
	},

	Gather = function(player: Player, state: any, ctx: any)
		local tools = {}
		local seen = {}
		local function scan(container: Instance?)
			if not container then
				return
			end
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("BackpackItem") and not seen[child] then
					seen[child] = true
					table.insert(tools, child.Name)
				end
			end
		end
		scan(player:FindFirstChildOfClass("Backpack"))
		scan(state.Character)
		state.Tools = tools
		local known = if ctx.KnownTools then ctx.KnownTools(player) else {}
		state.Known = known
	end,

	Check = function(_player: any, state: any): any
		local cfg = state.Config or {}
		local known = state.Known or {}
		local allow = {}
		for _, name in ipairs(cfg.Allow or {}) do
			allow[name] = true
		end
		local counts: { [string]: number } = {}
		local unknown = {}
		for _, name in ipairs(state.Tools or {}) do
			counts[name] = (counts[name] or 0) + 1
			if not known[name] and not allow[name] and not table.find(unknown, name) then
				table.insert(unknown, name)
			end
		end
		for name, n in pairs(counts) do
			if n > (cfg.MaxDuplicates or 2) then
				return {
					Confidence = math.clamp(n / (cfg.MaxDuplicates or 2) - 0.5, 0.5, 0.95),
					Reason = ("Holds %d copies of '%s' (max %d)"):format(n, name, cfg.MaxDuplicates or 2),
					Evidence = { Tool = name, Copies = n },
				}
			end
		end
		if cfg.FlagUnknown ~= false and #unknown > 0 then
			return {
				Confidence = 0.6,
				Reason = ("Holds tool(s) the server never gave: %s"):format(table.concat(unknown, ", ")),
				Evidence = { Unknown = unknown },
			}
		end
		return nil
	end,
}
