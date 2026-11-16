-- ============================================
-- PLAYER CONTROLS SYSTEM
-- ============================================
-- Adapted from Admin Panel V4.3 Fly/View/Effects systems
-- Features: Fly, Noclip, God Mode, Visual Effects, Appearance

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Theme = require(script.Parent.Theme)
local Config = require(ReplicatedStorage.Shared.Sentinel.Config)

local PlayerControlsSystem = {}
PlayerControlsSystem.__index = PlayerControlsSystem

-- ============================================
-- STATE
-- ============================================
local isFlying = false
local isNoclip = false
local isGodMode = false
local flySpeed = Config.FLY.DEFAULT_SPEED
local flyConnection = nil
local flyGyro = nil
local flyVel = nil
local noclipConnection = nil
local godConnection = nil
local viewingPlayer = nil
local flyGui = nil

-- ============================================
-- INITIALIZATION
-- ============================================
function PlayerControlsSystem.new()
	local self = setmetatable({}, PlayerControlsSystem)
	self:Initialize()
	return self
end

function PlayerControlsSystem:Initialize()
	local player = Players.LocalPlayer

	-- Setup keybinds
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end

		local keybinds = Config.KEYBINDS

		if input.KeyCode == keybinds.QUICK_FLY then
			self:ToggleFly()
		elseif input.KeyCode == keybinds.QUICK_NOCLIP then
			self:ToggleNoclip()
		elseif input.KeyCode == keybinds.QUICK_GOD then
			self:ToggleGod()
		elseif input.KeyCode == Enum.KeyCode.V then
			if viewingPlayer then
				self:StopViewing()
			end
		end
	end)

	-- Cleanup on character removal
	player.CharacterRemoving:Connect(function()
		self:StopFly()
		self:StopNoclip()
		self:StopGod()
		self:StopViewing()
	end)
end

-- ============================================
-- FLY SYSTEM
-- ============================================
function PlayerControlsSystem:ToggleFly()
	if isFlying then
		self:StopFly()
	else
		self:StartFly()
	end
end

function PlayerControlsSystem:StartFly()
	if isFlying then return end

	local player = Players.LocalPlayer
	local char = player.Character
	if not char then
		return
	end

	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end

	isFlying = true

	-- Set humanoid state to flying (Anti-cheat bypass)
	hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Flying, true)
	hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Landed, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Running, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
	hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	hum:ChangeState(Enum.HumanoidStateType.Flying)

	-- Create BodyGyro
	flyGyro = Instance.new("BodyGyro")
	flyGyro.P = 9000
	flyGyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
	flyGyro.CFrame = root.CFrame
	flyGyro.Parent = root

	-- Create BodyVelocity
	flyVel = Instance.new("BodyVelocity")
	flyVel.Velocity = Vector3.new(0, 0, 0)
	flyVel.MaxForce = Vector3.new(9e9, 9e9, 9e9)
	flyVel.Parent = root

	-- Create Fly GUI
	self:CreateFlyGui()

	-- Fly loop
	flyConnection = RunService.Heartbeat:Connect(function()
		if not isFlying then return end

		local c = player.Character
		if not c then self:StopFly() return end

		local h = c:FindFirstChildOfClass("Humanoid")
		local r = c:FindFirstChild("HumanoidRootPart")
		if not h or not r then self:StopFly() return end

		if not flyGyro or not flyVel then self:StopFly() return end

		-- Keep flying state
		h:ChangeState(Enum.HumanoidStateType.Flying)

		local cam = Workspace.CurrentCamera
		if not cam then return end

		local dir = Vector3.new(0, 0, 0)

		-- Movement direction
		if UserInputService:IsKeyDown(Config.FLY.KEY_FORWARD) then
			dir = dir + cam.CFrame.LookVector
		end
		if UserInputService:IsKeyDown(Config.FLY.KEY_BACKWARD) then
			dir = dir - cam.CFrame.LookVector
		end
		if UserInputService:IsKeyDown(Config.FLY.KEY_LEFT) then
			dir = dir - cam.CFrame.RightVector
		end
		if UserInputService:IsKeyDown(Config.FLY.KEY_RIGHT) then
			dir = dir + cam.CFrame.RightVector
		end
		if UserInputService:IsKeyDown(Config.FLY.KEY_UP) then
			dir = dir + Vector3.new(0, 1, 0)
		end
		if UserInputService:IsKeyDown(Config.FLY.KEY_DOWN) then
			dir = dir + Vector3.new(0, -1, 0)
		end

		-- Speed multiplier
		local spd = flySpeed
		if UserInputService:IsKeyDown(Config.FLY.KEY_BOOST) then
			spd = spd * Config.FLY.BOOST_MULTIPLIER
		end

		-- Apply movement
		if flyVel and flyVel.Parent then
			if dir.Magnitude > 0 then
				flyVel.Velocity = dir.Unit * spd
			else
				flyVel.Velocity = Vector3.new(0, 0, 0)
			end
		end

		if flyGyro and flyGyro.Parent then
			flyGyro.CFrame = cam.CFrame
		end
	end)
end

function PlayerControlsSystem:StopFly()
	if not isFlying then return end
	isFlying = false

	if flyConnection then
		flyConnection:Disconnect()
		flyConnection = nil
	end

	if flyGyro and flyGyro.Parent then
		flyGyro:Destroy()
	end
	flyGyro = nil

	if flyVel and flyVel.Parent then
		flyVel:Destroy()
	end
	flyVel = nil

	-- Destroy Fly GUI
	if flyGui then
		flyGui:Destroy()
		flyGui = nil
	end

	-- Re-enable humanoid states
	local player = Players.LocalPlayer
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum:SetStateEnabled(Enum.HumanoidStateType.Climbing, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Running, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Seated, true)
			hum:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
			hum:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end

	-- Reset noclip
	self:StopNoclip()
end

function PlayerControlsSystem:CreateFlyGui()
	if not Config.FLY.SHOW_FLY_GUI then return end

	local player = Players.LocalPlayer
	flyGui = Instance.new("ScreenGui")
	flyGui.Name = "FlyGui"
	flyGui.ResetOnSpawn = false
	flyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	flyGui.Parent = player.PlayerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 280, 0, 160)
	frame.Position = UDim2.new(1, -300, 1, -180)
	frame.BackgroundColor3 = Theme.Current.Surface
	frame.BorderSizePixel = 0
	frame.Parent = flyGui

	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Theme.Current.Primary
	stroke.Thickness = 2

	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 10, 0, 5)
	title.BackgroundTransparency = 1
	title.Text = "🦅 Fly Controls"
	title.TextColor3 = Theme.Current.Primary
	title.Font = Theme.Current.FontBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left

	-- Speed Label
	local flySpeedLabel = Instance.new("TextLabel", frame)
	flySpeedLabel.Name = "SpeedLabel"
	flySpeedLabel.Size = UDim2.new(1, -20, 0, 25)
	flySpeedLabel.Position = UDim2.new(0, 10, 0, 40)
	flySpeedLabel.BackgroundTransparency = 1
	flySpeedLabel.Text = "Speed: " .. flySpeed
	flySpeedLabel.TextColor3 = Theme.Current.Text
	flySpeedLabel.Font = Theme.Current.Font
	flySpeedLabel.TextSize = 14
	flySpeedLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Speed Slider
	local sliderBg = Instance.new("Frame", frame)
	sliderBg.Size = UDim2.new(1, -40, 0, 6)
	sliderBg.Position = UDim2.new(0, 20, 0, 70)
	sliderBg.BackgroundColor3 = Theme.Current.Background
	sliderBg.BorderSizePixel = 0

	Instance.new("UICorner", sliderBg).CornerRadius = UDim.new(1, 0)

	local sliderFill = Instance.new("Frame", sliderBg)
	sliderFill.Name = "SliderFill"
	sliderFill.Size = UDim2.new(flySpeed / Config.FLY.MAX_SPEED, 0, 1, 0)
	sliderFill.BackgroundColor3 = Theme.Current.Primary
	sliderFill.BorderSizePixel = 0

	Instance.new("UICorner", sliderFill).CornerRadius = UDim.new(1, 0)

	local sliderButton = Instance.new("TextButton", sliderBg)
	sliderButton.Size = UDim2.new(0, 20, 0, 20)
	sliderButton.Position = UDim2.new(flySpeed / Config.FLY.MAX_SPEED, -10, 0.5, -10)
	sliderButton.BackgroundColor3 = Theme.Current.Primary
	sliderButton.Text = ""
	sliderButton.BorderSizePixel = 0

	Instance.new("UICorner", sliderButton).CornerRadius = UDim.new(1, 0)

	local dragging = false

	sliderButton.MouseButton1Down:Connect(function()
		dragging = true
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not flyGui then return end

		if dragging then
			local mouse = player:GetMouse()
			local relativePos = math.clamp((mouse.X - sliderBg.AbsolutePosition.X) / sliderBg.AbsoluteSize.X, 0, 1)
			flySpeed = math.floor(relativePos * Config.FLY.MAX_SPEED)

			sliderButton.Position = UDim2.new(relativePos, -10, 0.5, -10)
			sliderFill.Size = UDim2.new(relativePos, 0, 1, 0)
			flySpeedLabel.Text = "Speed: " .. flySpeed
		end
	end)

	-- Noclip Toggle Button
	if Config.FLY.NOCLIP_ENABLED then
		local flyNoclipBtn = Instance.new("TextButton", frame)
		flyNoclipBtn.Name = "NoclipBtn"
		flyNoclipBtn.Size = UDim2.new(1, -40, 0, 35)
		flyNoclipBtn.Position = UDim2.new(0, 20, 0, 85)
		flyNoclipBtn.BackgroundColor3 = Theme.Current.Background
		flyNoclipBtn.Text = "🚫 Noclip: OFF"
		flyNoclipBtn.TextColor3 = Theme.Current.Text
		flyNoclipBtn.Font = Theme.Current.FontBold
		flyNoclipBtn.TextSize = 13
		flyNoclipBtn.BorderSizePixel = 0

		Instance.new("UICorner", flyNoclipBtn).CornerRadius = UDim.new(0, 8)

		flyNoclipBtn.MouseButton1Click:Connect(function()
			self:ToggleNoclip()
			flyNoclipBtn.Text = isNoclip and "🚫 Noclip: ON" or "🚫 Noclip: OFF"
			flyNoclipBtn.BackgroundColor3 = isNoclip and Theme.Current.Primary or Theme.Current.Background
		end)
	end

	-- Stop Fly Button
	local stopBtn = Instance.new("TextButton", frame)
	stopBtn.Size = UDim2.new(1, -40, 0, 35)
	stopBtn.Position = UDim2.new(0, 20, 0, 125)
	stopBtn.BackgroundColor3 = Theme.Current.Error
	stopBtn.Text = "✋ Stop Flying"
	stopBtn.TextColor3 = Theme.Current.Text
	stopBtn.Font = Theme.Current.FontBold
	stopBtn.TextSize = 13
	stopBtn.BorderSizePixel = 0

	Instance.new("UICorner", stopBtn).CornerRadius = UDim.new(0, 8)

	stopBtn.MouseButton1Click:Connect(function()
		self:StopFly()
	end)
end

-- ============================================
-- NOCLIP SYSTEM
-- ============================================
function PlayerControlsSystem:ToggleNoclip()
	if isNoclip then
		self:StopNoclip()
	else
		self:StartNoclip()
	end
end

function PlayerControlsSystem:StartNoclip()
	if isNoclip then return end

	local player = Players.LocalPlayer
	local char = player.Character
	if not char then return end

	isNoclip = true

	noclipConnection = RunService.Stepped:Connect(function()
		if not isNoclip then return end

		local c = player.Character
		if not c then return end

		for _, part in ipairs(c:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	end)
end

function PlayerControlsSystem:StopNoclip()
	if not isNoclip then return end
	isNoclip = false

	if noclipConnection then
		noclipConnection:Disconnect()
		noclipConnection = nil
	end

	local player = Players.LocalPlayer
	local char = player.Character
	if char then
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = true
			end
		end
	end
end

-- ============================================
-- GOD MODE SYSTEM
-- ============================================
function PlayerControlsSystem:ToggleGod()
	if isGodMode then
		self:StopGod()
	else
		self:StartGod()
	end
end

function PlayerControlsSystem:StartGod()
	if isGodMode then return end

	local player = Players.LocalPlayer
	local char = player.Character
	if not char then return end

	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	isGodMode = true

	-- Set god mode
	hum.MaxHealth = math.huge
	hum.Health = math.huge

	-- Keep god mode
	godConnection = hum.HealthChanged:Connect(function(health)
		if isGodMode and health < math.huge then
			hum.Health = math.huge
		end
	end)
end

function PlayerControlsSystem:StopGod()
	if not isGodMode then return end
	isGodMode = false

	if godConnection then
		godConnection:Disconnect()
		godConnection = nil
	end

	local player = Players.LocalPlayer
	local char = player.Character
	if char then
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.MaxHealth = 100
			hum.Health = 100
		end
	end
end

-- ============================================
-- VIEW SYSTEM
-- ============================================
function PlayerControlsSystem:StartViewing(targetPlayer)
	if viewingPlayer == targetPlayer then
		self:StopViewing()
		return
	end

	viewingPlayer = targetPlayer

	local cam = Workspace.CurrentCamera
	if targetPlayer.Character then
		cam.CameraSubject = targetPlayer.Character:FindFirstChild("Humanoid")
	end
end

function PlayerControlsSystem:StopViewing()
	if not viewingPlayer then return end

	local player = Players.LocalPlayer
	local cam = Workspace.CurrentCamera
	if player.Character then
		cam.CameraSubject = player.Character:FindFirstChild("Humanoid")
	end

	viewingPlayer = nil
end

-- ============================================
-- VISUAL EFFECTS SYSTEM
-- ============================================
function PlayerControlsSystem:ApplyEffect(targetPlayer, effectName)
	local char = targetPlayer.Character
	if not char then return end

	local effects = {
		-- Fire effect
		Fire = function()
			local fire = Instance.new("Fire", char:FindFirstChild("HumanoidRootPart"))
			fire.Heat = 25
			fire.Size = 10
		end,

		-- Smoke effect
		Smoke = function()
			local smoke = Instance.new("Smoke", char:FindFirstChild("HumanoidRootPart"))
			smoke.Size = 5
			smoke.Opacity = 0.5
		end,

		-- Sparkles effect
		Sparkles = function()
			local sparkles = Instance.new("Sparkles", char:FindFirstChild("HumanoidRootPart"))
			sparkles.SparkleColor = Color3.new(1, 1, 1)
		end,

		-- ForceField effect
		ForceField = function()
			local ff = Instance.new("ForceField", char)
			ff.Visible = true
		end,

		-- PointLight effect
		PointLight = function()
			local light = Instance.new("PointLight", char:FindFirstChild("HumanoidRootPart"))
			light.Color = Color3.fromRGB(255, 255, 255)
			light.Brightness = 2
			light.Range = 20
		end,
	}

	if effects[effectName] then
		effects[effectName]()
	end
end

function PlayerControlsSystem:RemoveEffect(targetPlayer, effectName)
	local char = targetPlayer.Character
	if not char then return end

	local removals = {
		Fire = function()
			local fire = char:FindFirstChild("HumanoidRootPart"):FindFirstChild("Fire")
			if fire then fire:Destroy() end
		end,

		Smoke = function()
			local smoke = char:FindFirstChild("HumanoidRootPart"):FindFirstChild("Smoke")
			if smoke then smoke:Destroy() end
		end,

		Sparkles = function()
			local sparkles = char:FindFirstChild("HumanoidRootPart"):FindFirstChild("Sparkles")
			if sparkles then sparkles:Destroy() end
		end,

		ForceField = function()
			local ff = char:FindFirstChild("ForceField")
			if ff then ff:Destroy() end
		end,

		PointLight = function()
			local light = char:FindFirstChild("HumanoidRootPart"):FindFirstChild("PointLight")
			if light then light:Destroy() end
		end,
	}

	if removals[effectName] then
		removals[effectName]()
	end
end

-- ============================================
-- APPEARANCE SYSTEM
-- ============================================
function PlayerControlsSystem:SetAppearance(targetPlayer, appearanceName)
	local char = targetPlayer.Character
	if not char then return end

	local appearances = {
		-- Invisible
		Invisible = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Transparency = 1
				elseif part:IsA("Decal") then
					part.Transparency = 1
				end
			end
		end,

		-- Visible (reset)
		Visible = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Transparency = 0
				elseif part:IsA("Decal") then
					part.Transparency = 0
				end
			end
		end,

		-- Neon material
		Neon = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Material = Enum.Material.Neon
				end
			end
		end,

		-- Glass material
		Glass = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Material = Enum.Material.Glass
				end
			end
		end,

		-- Gold material
		Gold = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Material = Enum.Material.Metal
					part.Color = Color3.fromRGB(255, 215, 0)
				end
			end
		end,

		-- Silver material
		Silver = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Material = Enum.Material.Metal
					part.Color = Color3.fromRGB(192, 192, 192)
				end
			end
		end,

		-- Normal material
		Normal = function()
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Material = Enum.Material.Plastic
				end
			end
		end,
	}

	if appearances[appearanceName] then
		appearances[appearanceName]()
	end
end

-- ============================================
-- GETTERS
-- ============================================
function PlayerControlsSystem:IsFlying()
	return isFlying
end

function PlayerControlsSystem:IsNoclipping()
	return isNoclip
end

function PlayerControlsSystem:IsGod()
	return isGodMode
end

function PlayerControlsSystem:GetViewingPlayer()
	return viewingPlayer
end

function PlayerControlsSystem:GetFlySpeed()
	return flySpeed
end

function PlayerControlsSystem:SetFlySpeed(speed)
	flySpeed = math.clamp(speed, Config.FLY.MIN_SPEED, Config.FLY.MAX_SPEED)
end

return PlayerControlsSystem
