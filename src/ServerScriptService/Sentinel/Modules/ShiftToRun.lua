--!strict
--[[
	ShiftToRun.lua - Sentinel module "Shift To Run" (W-FINAL.2, first module)

	Sprint with the keyboard (Shift by default), a gamepad (left stick
	click) or an on-screen Run button on touch devices. Server-authoritative:
	the client only says "I want to sprint" / "stop"; the server checks the
	character, the optional stamina, sets Humanoid.WalkSpeed and restores it.
	No animations: Roblox's default Animate script already plays its run
	cycle faster at higher WalkSpeed (R6 and R15 alike).

	Player attributes (read by the client component):
		SentinelSprinting (bool), SentinelStamina, SentinelStaminaMax (when
		stamina is on), SentinelExhausted (bool, waiting for MinStamina).

	Speed rules: sprint only raises speed (a player already faster, e.g. via
	;speed 50, is left alone); stopping restores the speed from before the
	sprint unless something else changed WalkSpeed meanwhile (then that new
	value is kept and the sprint ends). Frozen (WalkSpeed 0) or dead
	characters can't sprint.

	Client component: StarterPlayerScripts.Sentinel.Modules.ShiftToRun.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local ShiftToRun = {}

ShiftToRun.Id = "shifttorun"
ShiftToRun.Name = "Shift To Run"
ShiftToRun.Category = "Gameplay & Movement"
ShiftToRun.Version = "1.0.0"
ShiftToRun.Icon = "Speed"
ShiftToRun.Description = "Sprint with Shift, a gamepad stick click or an on-screen Run button. Configurable speed, keys and optional stamina."
ShiftToRun.Docs = table.concat({
	"Players hold (or toggle) the sprint key to run at Sprint speed.",
	"On phones and tablets a Run button appears next to the jump button.",
	"With Stamina on, sprinting drains stamina while moving; it refills after Regen delay. At 0 the player walks until stamina reaches Min stamina.",
	"Sprint never lowers speed: a player made faster by ;speed keeps that speed. Commands that change WalkSpeed during a sprint win.",
	"If Shift Lock is enabled in StarterPlayer and the sprint key is Shift, sprinting takes the key (Shift Lock stops toggling) - pick another key or turn Shift Lock off.",
}, "\n")
ShiftToRun.Features = {
	"Keyboard, gamepad and touch controls",
	"Hold or toggle mode (touch has its own mode)",
	"Configurable sprint speed and keys",
	"Optional stamina with drain, regeneration, delay and bar",
	"Camera FOV boost while running (no animations needed)",
	"Server-checked speed changes; restores speed on stop, death and deactivation",
}
ShiftToRun.Rigs = { "R6", "R15", "Any Humanoid rig" }
ShiftToRun.Platforms = { "Keyboard", "Gamepad", "Touch" }
ShiftToRun.Services = { "ContextActionService", "Humanoid.WalkSpeed" }
ShiftToRun.Dependencies = {}
ShiftToRun.Conflicts = {}
ShiftToRun.Integrations = {
	{ Id = "stamina", Description = "Stamina System module (planned). Until it exists, Shift To Run's built-in stamina is used." },
}
ShiftToRun.Changelog = {
	{ Version = "1.0.0", Date = "2026-11-24", Notes = "First release: keyboard / gamepad / touch sprint, hold / toggle, stamina, FOV boost." },
}
ShiftToRun.Client = "ShiftToRun"

ShiftToRun.Config = {
	{ Key = "SprintSpeed", Type = "number", Default = 26, Min = 8, Max = 100, Label = "Sprint speed", Description = "WalkSpeed while sprinting (Roblox walk = 16)." },
	{ Key = "Key", Type = "key", Default = "LeftShift", Label = "Sprint key", Description = "Keyboard key (e.g. LeftShift, LeftControl, Q)." },
	{ Key = "AltKey", Type = "key", Default = "RightShift", Label = "Second key", Description = "Another keyboard key, or None." },
	{ Key = "Mode", Type = "choice", Choices = { "Hold", "Toggle" }, Default = "Hold", Label = "Keyboard mode", Description = "Hold the key, or press once to start / stop." },
	{ Key = "Gamepad", Type = "boolean", Default = true, Label = "Gamepad (L3)", Description = "Click the left stick to toggle sprint." },
	{ Key = "MobileButton", Type = "boolean", Default = true, Label = "Touch Run button", Description = "Show a Run button on touch devices." },
	{ Key = "MobileMode", Type = "choice", Choices = { "Toggle", "Hold" }, Default = "Toggle", Label = "Touch mode" },
	{ Key = "FovBoost", Type = "number", Default = 6, Min = 0, Max = 20, Label = "FOV boost", Description = "Extra camera field of view while running (0 = off)." },
	{ Key = "Stamina", Type = "boolean", Default = false, Label = "Stamina", Description = "Sprinting drains stamina." },
	{ Key = "MaxStamina", Type = "number", Default = 100, Min = 10, Max = 1000, Label = "Max stamina" },
	{ Key = "Drain", Type = "number", Default = 20, Min = 1, Max = 500, Label = "Drain / s", Description = "Stamina used per second while sprinting and moving." },
	{ Key = "Regen", Type = "number", Default = 15, Min = 0, Max = 500, Label = "Regen / s" },
	{ Key = "RegenDelay", Type = "number", Default = 1, Min = 0, Max = 10, Label = "Regen delay (s)" },
	{ Key = "MinStamina", Type = "number", Default = 20, Min = 0, Max = 1000, Label = "Min stamina", Description = "Stamina needed to start again after running out." },
	{ Key = "ShowBar", Type = "boolean", Default = true, Label = "Stamina bar" },
}

function ShiftToRun.Compatibility(config: any): { string }
	local warnings = {}
	local shiftKeys = { LeftShift = true, RightShift = true }
	if StarterPlayer.EnableMouseLockOption and (shiftKeys[config.Key] or shiftKeys[config.AltKey]) then
		table.insert(warnings, "Shift Lock is enabled (StarterPlayer.EnableMouseLockOption) and also uses Shift - while sprinting is bound, Shift Lock won't toggle.")
	end
	if StarterPlayer.CharacterWalkSpeed >= (tonumber(config.SprintSpeed) or 0) then
		table.insert(warnings, ("Sprint speed (%s) is not above the default walk speed (%s)."):format(tostring(config.SprintSpeed), tostring(StarterPlayer.CharacterWalkSpeed)))
	end
	if config.Stamina and (tonumber(config.MinStamina) or 0) > (tonumber(config.MaxStamina) or 0) then
		table.insert(warnings, "Min stamina is above Max stamina - players could never sprint again after running out.")
	end
	return warnings
end

-- Pure stamina step (Modules.spec). Returns stamina, exhausted, lastDrain.
function ShiftToRun.Step(s: { Stamina: number, Exhausted: boolean, LastDrain: number }, cfg: any, dt: number, now: number, draining: boolean): (number, boolean, number)
	local stamina, exhausted, lastDrain = s.Stamina, s.Exhausted, s.LastDrain
	if draining then
		stamina = math.max(0, stamina - cfg.Drain * dt)
		lastDrain = now
		if stamina <= 0 then
			exhausted = true
		end
	elseif now - lastDrain >= cfg.RegenDelay then
		stamina = math.min(cfg.MaxStamina, stamina + cfg.Regen * dt)
	end
	if exhausted and stamina >= math.min(cfg.MinStamina, cfg.MaxStamina) then
		exhausted = false
	end
	return stamina, exhausted, lastDrain
end

type PlayerState = {
	Want: boolean,
	Sprinting: boolean,
	Base: number?,
	SetSpeed: number?,
	Stamina: number,
	Exhausted: boolean,
	LastDrain: number,
	Humanoid: Humanoid?,
	Conns: { RBXScriptConnection },
}

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	if h and h.Health > 0 then
		return h
	end
	return nil
end

function ShiftToRun.Activate(ctx: any)
	local states: { [Player]: PlayerState } = {}
	ctx.State.Players = states

	local function setAttrs(player: Player, st: PlayerState)
		player:SetAttribute("SentinelSprinting", st.Sprinting)
		if ctx.Config.Stamina then
			player:SetAttribute("SentinelStaminaMax", ctx.Config.MaxStamina)
			player:SetAttribute("SentinelStamina", math.floor(st.Stamina * 10 + 0.5) / 10)
			player:SetAttribute("SentinelExhausted", st.Exhausted)
		else
			player:SetAttribute("SentinelStamina", nil)
			player:SetAttribute("SentinelStaminaMax", nil)
			player:SetAttribute("SentinelExhausted", nil)
		end
	end

	local function stopSprint(player: Player, st: PlayerState)
		if not st.Sprinting then
			return
		end
		st.Sprinting = false
		local h = st.Humanoid
		if h and h.Parent and st.SetSpeed and h.WalkSpeed == st.SetSpeed and st.Base then
			h.WalkSpeed = st.Base
		end
		st.Base, st.SetSpeed = nil, nil
		setAttrs(player, st)
	end

	local function startSprint(player: Player, st: PlayerState): boolean
		if st.Sprinting then
			return true
		end
		local h = humanoidOf(player)
		if not h then
			return false
		end
		local speed = tonumber(ctx.Config.SprintSpeed) or 26
		if h.WalkSpeed <= 0 or h.WalkSpeed >= speed then
			return false -- frozen, or already as fast (;speed)
		end
		if ctx.Config.Stamina and (st.Exhausted or st.Stamina <= 0) then
			return false
		end
		st.Humanoid = h
		st.Base = h.WalkSpeed
		st.SetSpeed = speed
		st.Sprinting = true
		h.WalkSpeed = speed
		setAttrs(player, st)
		return true
	end

	local function newState(player: Player): PlayerState
		local st: PlayerState = {
			Want = false,
			Sprinting = false,
			Stamina = ctx.Config.MaxStamina,
			Exhausted = false,
			LastDrain = 0,
			Conns = {},
		}
		states[player] = st
		return st
	end

	local function watchCharacter(player: Player, st: PlayerState)
		for _, c in ipairs(st.Conns) do
			c:Disconnect()
		end
		st.Conns = {}
		st.Want, st.Sprinting, st.Base, st.SetSpeed = false, false, nil, nil
		st.Stamina, st.Exhausted = ctx.Config.MaxStamina, false
		local h = humanoidOf(player)
		st.Humanoid = h
		setAttrs(player, st)
		if h then
			table.insert(st.Conns, h:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
				-- something else (a command, the game) changed speed mid-sprint:
				-- keep its value and end the sprint without restoring.
				if st.Sprinting and h.WalkSpeed ~= st.SetSpeed then
					st.Sprinting, st.Base, st.SetSpeed = false, nil, nil
					setAttrs(player, st)
				end
			end))
			table.insert(st.Conns, h.Died:Connect(function()
				st.Want, st.Sprinting, st.Base, st.SetSpeed = false, false, nil, nil
				setAttrs(player, st)
			end))
		end
	end

	local function addPlayer(player: Player)
		local st = newState(player)
		watchCharacter(player, st)
		ctx.Track(player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Humanoid", 5)
			if states[player] then
				watchCharacter(player, states[player])
			end
		end))
	end

	for _, p in ipairs(Players:GetPlayers()) do
		addPlayer(p)
	end
	ctx.Track(Players.PlayerAdded:Connect(addPlayer))
	ctx.Track(Players.PlayerRemoving:Connect(function(player)
		local st = states[player]
		if st then
			for _, c in ipairs(st.Conns) do
				c:Disconnect()
			end
			states[player] = nil
		end
	end))

	ctx.State.Start = startSprint
	ctx.State.Stop = stopSprint
	ctx.State.SetAttrs = setAttrs

	local acc = 0
	ctx.Track(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		local step = acc
		acc = 0
		local cfg = ctx.Config
		local now = os.clock()
		for player, st in pairs(states) do
			if cfg.Stamina then
				local h = st.Humanoid
				local moving = h ~= nil and h.Parent ~= nil and h.MoveDirection.Magnitude > 0.1
				local before, wasExhausted = st.Stamina, st.Exhausted
				st.Stamina, st.Exhausted, st.LastDrain = ShiftToRun.Step(st, cfg, step, now, st.Sprinting and moving)
				if st.Exhausted and st.Sprinting then
					stopSprint(player, st)
				elseif not st.Exhausted and wasExhausted and st.Want then
					startSprint(player, st) -- still holding the key
				end
				if math.abs(before - st.Stamina) >= 0.05 or wasExhausted ~= st.Exhausted then
					setAttrs(player, st)
				end
			end
		end
	end))
end

function ShiftToRun.OnClientMessage(ctx: any, player: Player, action: any, value: any)
	if action ~= "sprint" or type(value) ~= "boolean" then
		return
	end
	local st = ctx.State.Players and ctx.State.Players[player]
	if not st then
		return
	end
	st.Want = value
	if value then
		ctx.State.Start(player, st)
	else
		ctx.State.Stop(player, st)
	end
end

function ShiftToRun.OnConfig(ctx: any, config: any)
	for player, st in pairs(ctx.State.Players or {}) do
		if st.Sprinting and st.Humanoid and st.SetSpeed and st.Humanoid.WalkSpeed == st.SetSpeed then
			if st.Base and config.SprintSpeed > st.Base then
				st.SetSpeed = config.SprintSpeed
				st.Humanoid.WalkSpeed = config.SprintSpeed
			else
				ctx.State.Stop(player, st)
			end
		end
		st.Stamina = math.min(st.Stamina, config.MaxStamina)
		ctx.State.SetAttrs(player, st)
	end
end

function ShiftToRun.Deactivate(ctx: any)
	for player, st in pairs(ctx.State.Players or {}) do
		ctx.State.Stop(player, st)
		for _, c in ipairs(st.Conns) do
			c:Disconnect()
		end
		player:SetAttribute("SentinelSprinting", nil)
		player:SetAttribute("SentinelStamina", nil)
		player:SetAttribute("SentinelStaminaMax", nil)
		player:SetAttribute("SentinelExhausted", nil)
	end
	ctx.State.Players = {}
end

function ShiftToRun.Diagnostics(ctx: any): { [string]: any }
	local sprinting, tired, tracked = 0, 0, 0
	for _, st in pairs(ctx.State.Players or {}) do
		tracked += 1
		if st.Sprinting then
			sprinting += 1
		end
		if st.Exhausted then
			tired += 1
		end
	end
	return { Players = tracked, Sprinting = sprinting, Exhausted = tired, Stamina = ctx.Config.Stamina }
end

return ShiftToRun
