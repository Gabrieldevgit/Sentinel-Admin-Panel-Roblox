--!strict
--[[
	CommandPolicy.lua

	Purpose:
		One reviewable place for command risk levels and owner-only
		commands, instead of scattering them across ~100 command files.

	Risk levels:
		low       normal commands (default)
		medium    disruptive to the target(s); needs confirmation when it
		          hits BULK_THRESHOLD or more players
		high      destructive or hard to undo; always needs confirmation
		critical  affects the whole server or its data; always needs
		          confirmation

	Owner-only commands are refused for anyone without the Owner rank, no
	matter which permission nodes they hold (enforced in
	CommandRegistry.Dispatch).

	A command definition may also set `Risk` / `OwnerOnly` itself; that
	wins over this table.

	Public API:
		CommandPolicy.GetRisk(def): "low" | "medium" | "high" | "critical"
		CommandPolicy.IsOwnerOnly(def): boolean
		CommandPolicy.NeedsConfirmation(def, targetCount, executor?): (boolean, string?)
		CommandPolicy.BULK_THRESHOLD
--]]

local CommandPolicy = {}

CommandPolicy.BULK_THRESHOLD = 3

local RISK: { [string]: string } = {
	-- critical: whole server / persistent data / arbitrary code
	shutdown = "critical",
	execute = "critical",
	datastoreset = "critical",
	resetranks = "critical",
	whitelistmode = "critical",

	-- high: destructive or hard to undo
	ban = "high",
	blacklist = "high",
	setbalance = "high",
	removecurrency = "high",
	removexp = "high",
	setlevel = "high",
	restoreinventory = "high",
	deleterank = "high",
	lockserver = "high",
	maintenancemode = "high",

	-- medium: disruptive to the targets (confirm when bulk)
	kick = "medium",
	mute = "medium",
	jail = "medium",
	freeze = "medium",
	kill = "medium",
	explode = "medium",
	fling = "medium",
	removelimbs = "medium",
	removeitem = "medium",
	damage = "medium",
	blind = "medium",
	warn = "medium",
	unassignrank = "medium",
	unbindrank = "medium",
	assignrank = "medium",
}

local OWNER_ONLY: { [string]: boolean } = {
	execute = true,
	resetranks = true,
}

local ORDER = { low = 1, medium = 2, high = 3, critical = 4 }

function CommandPolicy.GetRisk(def: any): string
	local risk = def.Risk or RISK[def.Name] or "low"
	return if ORDER[risk] then risk else "low"
end

function CommandPolicy.IsOwnerOnly(def: any): boolean
	if def.OwnerOnly ~= nil then
		return def.OwnerOnly == true
	end
	return OWNER_ONLY[def.Name] == true
end

-- Returns whether a confirmation is required and a human explanation.
function CommandPolicy.NeedsConfirmation(def: any, targetCount: number): (boolean, string?)
	local risk = CommandPolicy.GetRisk(def)
	if risk == "critical" or risk == "high" then
		local scope = if def.RequiresTarget then (" on %d player(s)"):format(targetCount) else ""
		return true, ("%s is a %s-risk command%s."):format(def.Name, risk, scope)
	end
	if risk == "medium" and targetCount >= CommandPolicy.BULK_THRESHOLD then
		return true, ("%s will affect %d players."):format(def.Name, targetCount)
	end
	return false, nil
end

return CommandPolicy
