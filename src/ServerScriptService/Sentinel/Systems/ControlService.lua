--!strict
--[[
	ControlService.lua

	Purpose:
		;control - a staff member moves another player's character as if it
		were their own (idea from HD Admin's Control; own implementation).

	How it works:
		- The server gives the controller network ownership of the target's
		  character (HumanoidRootPart assembly), so the controller's client
		  simulates it.
		- The controller's own character is anchored where it stands; their
		  camera follows the target and their client feeds its movement input
		  into the target's Humanoid (Move / Jump) - see init.client
		  "ControlRemote".
		- The target's client disables its own movement controls and shows
		  who is controlling it.
		- It ends on ;uncontrol, either player leaving, either character dying
		  or respawning. Ownership goes back to the target.

	Attributes: target `SentinelControlledBy` = controller name, controller
	`SentinelControlling` = target name.

	Public API:
		ControlService.Start(controller, target) -> (ok, message)
		ControlService.Stop(player) -> (ok, message)   -- either side
		ControlService.ControllerOf(target) -> Player?
		ControlService.TargetOf(controller) -> Player?
		ControlService.Validate(controller, target, state) -> string?  (pure, tested)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local ControlService = {}

local function getRemote(): RemoteEvent
	local existing = SentinelShared:FindFirstChild("ControlRemote")
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = "ControlRemote"
	remote.Parent = SentinelShared
	return remote
end
local controlRemote = getRemote()

type Session = {
	Controller: Player,
	Target: Player,
	ControllerRoot: BasePart?,
	WasAnchored: boolean,
	Connections: { RBXScriptConnection },
}

local byTarget: { [Player]: Session } = {}
local byController: { [Player]: Session } = {}

local function rootOf(player: Player): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function alive(player: Player): boolean
	local hum = humanoidOf(player)
	return hum ~= nil and hum.Health > 0 and rootOf(player) ~= nil
end

--[[
	Pure checks (unit-tested). state = {
		Same, ControllerAlive, TargetAlive, TargetControlledBy (name?),
		ControllerIsControlled (bool), TargetIsControlling (bool) }
--]]
function ControlService.Validate(state: any): string?
	if state.Same then
		return "You can't control yourself."
	end
	if not state.ControllerAlive then
		return "You need a living character to control someone."
	end
	if not state.TargetAlive then
		return "That player has no living character."
	end
	if state.ControllerIsControlled then
		return "You are being controlled right now."
	end
	if state.TargetIsControlling then
		return "That player is controlling someone else."
	end
	if state.TargetControlledBy then
		return ("That player is already controlled by %s."):format(tostring(state.TargetControlledBy))
	end
	return nil
end

local function setOwner(part: BasePart?, owner: Player?)
	if part and part.Parent and not part.Anchored then
		pcall(function()
			part:SetNetworkOwner(owner)
		end)
	end
end

local function finish(session: Session, reason: string?)
	if byTarget[session.Target] ~= session then
		return
	end
	byTarget[session.Target] = nil
	byController[session.Controller] = nil
	for _, c in ipairs(session.Connections) do
		c:Disconnect()
	end
	local target, controller = session.Target, session.Controller
	if target.Parent == Players then
		setOwner(rootOf(target), target)
		target:SetAttribute("SentinelControlledBy", nil)
		controlRemote:FireClient(target, "released", controller.Name)
	end
	if controller.Parent == Players then
		if session.ControllerRoot and session.ControllerRoot.Parent then
			session.ControllerRoot.Anchored = session.WasAnchored
		end
		controller:SetAttribute("SentinelControlling", nil)
		controlRemote:FireClient(controller, "stop", target.Name, reason)
	end
end

function ControlService.ControllerOf(target: Player): Player?
	local s = byTarget[target]
	return s and s.Controller
end

function ControlService.TargetOf(controller: Player): Player?
	local s = byController[controller]
	return s and s.Target
end

function ControlService.Start(controller: Player, target: Player): (boolean, string)
	local current = byTarget[target]
	local problem = ControlService.Validate({
		Same = controller == target,
		ControllerAlive = alive(controller),
		TargetAlive = alive(target),
		ControllerIsControlled = byTarget[controller] ~= nil,
		TargetIsControlling = byController[target] ~= nil,
		TargetControlledBy = current and current.Controller.Name,
	})
	if problem then
		return false, problem
	end
	-- One target at a time: switching ends the previous session.
	local previous = byController[controller]
	if previous then
		finish(previous, "switched")
	end

	local controllerRoot = rootOf(controller)
	local session: Session = {
		Controller = controller,
		Target = target,
		ControllerRoot = controllerRoot,
		WasAnchored = controllerRoot ~= nil and controllerRoot.Anchored,
		Connections = {},
	}
	byTarget[target] = session
	byController[controller] = session

	local function endOn(signal: RBXScriptSignal, reason: string)
		table.insert(session.Connections, signal:Connect(function()
			finish(session, reason)
		end))
	end
	local targetHum = humanoidOf(target) :: Humanoid
	local controllerHum = humanoidOf(controller) :: Humanoid
	endOn(targetHum.Died, "target died")
	endOn(controllerHum.Died, "you died")
	endOn(target.CharacterAdded, "target respawned")
	endOn(controller.CharacterAdded, "you respawned")

	if controllerRoot then
		controllerRoot.Anchored = true
	end
	setOwner(rootOf(target), controller)
	target:SetAttribute("SentinelControlledBy", controller.Name)
	controller:SetAttribute("SentinelControlling", target.Name)
	controlRemote:FireClient(target, "controlled", controller.Name)
	controlRemote:FireClient(controller, "start", target.Character, target.Name)
	return true, ("You are controlling %s. Use ;uncontrol to stop."):format(target.Name)
end

function ControlService.Stop(player: Player): (boolean, string)
	local session = byController[player] or byTarget[player]
	if not session then
		return false, ("%s is not controlling or controlled."):format(player.Name)
	end
	local name = session.Target.Name
	finish(session, "stopped")
	return true, ("Stopped controlling %s."):format(name)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local session = byController[player] or byTarget[player]
	if session then
		finish(session, if session.Target == player then "target left" else "controller left")
	end
end)

-- The controller's client says when it has lost track (e.g. camera reset).
if game:GetService("RunService"):IsRunning() then
	controlRemote.OnServerEvent:Connect(function(player: Player, action: any)
		-- Only the controller may end it this way; a controlled player can't
		-- free themselves by firing the remote.
		if action == "stop" and byController[player] then
			ControlService.Stop(player)
		end
	end)
end

return ControlService
