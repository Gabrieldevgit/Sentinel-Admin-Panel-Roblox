--!strict
--[[
	ShiftToRun (client component) - see ServerScriptService.Sentinel.Modules.
	ShiftToRun for the server half (speed + stamina live there).

	- ContextActionService action "SentinelSprint" at a priority above
	  Roblox's Shift Lock, on Config.Key / AltKey / ButtonL3, with a touch
	  "Run" button when Config.MobileButton.
	- Hold or toggle (keyboard: Config.Mode, touch: Config.MobileMode,
	  gamepad: always toggle). Sends ("sprint", bool) to the server.
	- While SentinelSprinting is set and the character moves, the camera FOV
	  eases up by Config.FovBoost (restored on stop).
	- Stamina bar (ScreenGui SentinelSprint.Bar.Fill) when Config.Stamina and
	  Config.ShowBar: shown while sprinting or below max, red while
	  exhausted.
--]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ACTION = "SentinelSprint"
local PRIORITY = Enum.ContextActionPriority.High.Value + 10

local ShiftToRun = {}

function ShiftToRun.Start(config: any, api: any)
	local player = Players.LocalPlayer
	local want = false
	local conns: { RBXScriptConnection } = {}
	local gui: ScreenGui? = nil
	local fill: Frame? = nil
	local baseFov: number? = nil
	local boosted = false

	local function send(on: boolean)
		if want == on then
			return
		end
		want = on
		api.Send("sprint", on)
	end

	local function keyList(): { Enum.KeyCode }
		local keys = {}
		for _, name in ipairs({ config.Key, config.AltKey }) do
			if type(name) == "string" and name ~= "None" then
				local ok, code = pcall(function()
					return (Enum.KeyCode :: any)[name]
				end)
				if ok and code then
					table.insert(keys, code)
				end
			end
		end
		if config.Gamepad then
			table.insert(keys, Enum.KeyCode.ButtonL3)
		end
		return keys
	end

	local function handler(_name: string, inputState: Enum.UserInputState, input: InputObject)
		local isTouch = input.UserInputType == Enum.UserInputType.Touch
		local isPad = input.KeyCode == Enum.KeyCode.ButtonL3
		local mode = if isTouch then config.MobileMode elseif isPad then "Toggle" else config.Mode
		if mode == "Toggle" then
			if inputState == Enum.UserInputState.Begin then
				send(not want)
			end
		else
			if inputState == Enum.UserInputState.Begin then
				send(true)
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				send(false)
			end
		end
		return Enum.ContextActionResult.Sink
	end

	local function bind()
		ContextActionService:UnbindAction(ACTION)
		local keys = keyList()
		local touch = config.MobileButton == true and UserInputService.TouchEnabled
		if #keys == 0 and not touch then
			return
		end
		ContextActionService:BindActionAtPriority(ACTION, handler, touch, PRIORITY, table.unpack(keys))
		if touch then
			ContextActionService:SetTitle(ACTION, "Run")
			ContextActionService:SetPosition(ACTION, UDim2.new(1, -170, 1, -80))
		end
	end

	local function buildBar()
		if gui then
			gui:Destroy()
			gui, fill = nil, nil
		end
		if not (config.Stamina and config.ShowBar) then
			return
		end
		local g = Instance.new("ScreenGui")
		g.Name = "SentinelSprint"
		g.ResetOnSpawn = false
		g.IgnoreGuiInset = true
		g.DisplayOrder = 5
		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.AnchorPoint = Vector2.new(0.5, 1)
		bar.Position = UDim2.new(0.5, 0, 1, -96)
		bar.Size = UDim2.fromOffset(220, 8)
		bar.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
		bar.BackgroundTransparency = 0.3
		bar.BorderSizePixel = 0
		bar.Visible = false
		bar.Parent = g
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = bar
		local f = Instance.new("Frame")
		f.Name = "Fill"
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = Color3.fromRGB(87, 214, 130)
		f.BorderSizePixel = 0
		f.Parent = bar
		corner:Clone().Parent = f
		g.Parent = player:WaitForChild("PlayerGui")
		gui, fill = g, f
	end

	local function paintBar()
		if not gui or not fill then
			return
		end
		local max = tonumber(player:GetAttribute("SentinelStaminaMax")) or 0
		local value = tonumber(player:GetAttribute("SentinelStamina")) or max
		local bar = fill.Parent :: Frame
		if max <= 0 then
			bar.Visible = false
			return
		end
		local exhausted = player:GetAttribute("SentinelExhausted") == true
		bar.Visible = value < max - 0.05 or player:GetAttribute("SentinelSprinting") == true
		fill.Size = UDim2.fromScale(math.clamp(value / max, 0, 1), 1)
		fill.BackgroundColor3 = if exhausted then Color3.fromRGB(235, 87, 87) else Color3.fromRGB(87, 214, 130)
	end

	local function setFov(on: boolean)
		local camera = workspace.CurrentCamera
		local boost = tonumber(config.FovBoost) or 0
		if not camera or boost <= 0 then
			on = false
		end
		if on == boosted or not camera then
			return
		end
		boosted = on
		if on then
			baseFov = camera.FieldOfView
			TweenService:Create(camera, TweenInfo.new(0.25, Enum.EasingStyle.Quad), { FieldOfView = (baseFov :: number) + boost }):Play()
		elseif baseFov then
			TweenService:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quad), { FieldOfView = baseFov :: number }):Play()
		end
	end

	bind()
	buildBar()
	paintBar()
	for _, attr in ipairs({ "SentinelStamina", "SentinelStaminaMax", "SentinelExhausted", "SentinelSprinting" }) do
		table.insert(conns, player:GetAttributeChangedSignal(attr):Connect(paintBar))
	end
	-- the server ends a sprint on death / exhaustion / speed change; in toggle
	-- mode forget the toggle so the next press starts again.
	table.insert(conns, player:GetAttributeChangedSignal("SentinelSprinting"):Connect(function()
		if player:GetAttribute("SentinelSprinting") ~= true and want and player:GetAttribute("SentinelExhausted") ~= true then
			want = false
		end
	end))
	table.insert(conns, player.CharacterAdded:Connect(function()
		want = false
		setFov(false)
	end))
	table.insert(conns, RunService.RenderStepped:Connect(function()
		local character = player.Character
		local h = character and character:FindFirstChildOfClass("Humanoid")
		local moving = h ~= nil and h.MoveDirection.Magnitude > 0.1
		setFov(player:GetAttribute("SentinelSprinting") == true and moving)
	end))

	local handle = {}
	function handle.Update(newConfig: any)
		config = newConfig
		bind()
		buildBar()
		paintBar()
		if boosted then
			setFov(false)
		end
	end
	function handle.Stop()
		ContextActionService:UnbindAction(ACTION)
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		conns = {}
		setFov(false)
		if gui then
			gui:Destroy()
		end
		if want then
			want = false
			pcall(api.Send, "sprint", false)
		end
	end
	return handle
end

return ShiftToRun
