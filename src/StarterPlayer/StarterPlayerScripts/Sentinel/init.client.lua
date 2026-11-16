--!strict
--[[
	init.client.lua

	Purpose:
		Client shell. Phase 7 (UI/UX) will build the full dockable command
		palette here. For now, this owns two small pieces of UI:
		- A banner across the top of the screen for /announce
		- A large countdown overlay for /countdown

	IMPORTANT: an earlier version of this file displayed announcements via
	StarterGui:SetCore("ChatMakeSystemMessage", ...). That call only works
	under Roblox's legacy chat window and is a silent no-op under
	TextChatService — which is why /announce reported success but nothing
	ever appeared on screen. Building real custom GUI here sidesteps the
	chat-system question entirely; it doesn't matter which one the place
	uses.

	Responsibilities (current):
		- Display banner announcements (AnnounceRemote)
		- Display a countdown overlay (CountdownRemote)
	Responsibilities (future):
		- Render dockable command palette
		- Client-side autocomplete against a replicated command index
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

-- ---------------------------------------------------------------------------
-- Shared ScreenGui host
-- ---------------------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SentinelOverlay"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

-- ---------------------------------------------------------------------------
-- Announcement banner
-- ---------------------------------------------------------------------------
local bannerFrame = Instance.new("Frame")
bannerFrame.Name = "AnnouncementBanner"
bannerFrame.AnchorPoint = Vector2.new(0.5, 0)
bannerFrame.Position = UDim2.new(0.5, 0, 0, -80)
bannerFrame.Size = UDim2.new(0, 600, 0, 60)
bannerFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
bannerFrame.BackgroundTransparency = 0.1
bannerFrame.BorderSizePixel = 0
bannerFrame.Parent = screenGui

local bannerCorner = Instance.new("UICorner")
bannerCorner.CornerRadius = UDim.new(0, 10)
bannerCorner.Parent = bannerFrame

local bannerStroke = Instance.new("UIStroke")
bannerStroke.Color = Color3.fromRGB(255, 215, 0)
bannerStroke.Thickness = 2
bannerStroke.Parent = bannerFrame

local bannerLabel = Instance.new("TextLabel")
bannerLabel.Name = "Text"
bannerLabel.BackgroundTransparency = 1
bannerLabel.Size = UDim2.new(1, -20, 1, 0)
bannerLabel.Position = UDim2.new(0, 10, 0, 0)
bannerLabel.Font = Enum.Font.GothamBold
bannerLabel.TextSize = 20
bannerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
bannerLabel.TextWrapped = true
bannerLabel.Text = ""
bannerLabel.Parent = bannerFrame

local BANNER_SHOWN_Y = UDim2.new(0.5, 0, 0, 20)
local BANNER_HIDDEN_Y = UDim2.new(0.5, 0, 0, -80)
local bannerQueue: { { Text: string, Color: Color3 } } = {}
local bannerBusy = false

local function playBanner(text: string, color: Color3)
	bannerLabel.Text = text
	bannerStroke.Color = color

	bannerFrame.Position = BANNER_HIDDEN_Y
	local tweenIn = TweenService:Create(bannerFrame, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = BANNER_SHOWN_Y,
	})
	tweenIn:Play()
	tweenIn.Completed:Wait()

	task.wait(3.5)

	local tweenOut = TweenService:Create(bannerFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = BANNER_HIDDEN_Y,
	})
	tweenOut:Play()
	tweenOut.Completed:Wait()
end

local function processBannerQueue()
	if bannerBusy then
		return
	end
	bannerBusy = true
	while #bannerQueue > 0 do
		local next = table.remove(bannerQueue, 1)
		if next then
			playBanner(next.Text, next.Color)
		end
	end
	bannerBusy = false
end

local announceRemote = SentinelShared:WaitForChild("AnnounceRemote", 15)
if announceRemote and announceRemote:IsA("RemoteEvent") then
	announceRemote.OnClientEvent:Connect(function(text: string, color: Color3?)
		table.insert(bannerQueue, { Text = text, Color = color or Color3.fromRGB(255, 215, 0) })
		task.spawn(processBannerQueue)
	end)
end

-- ---------------------------------------------------------------------------
-- Countdown overlay
-- ---------------------------------------------------------------------------
local countdownFrame = Instance.new("Frame")
countdownFrame.Name = "CountdownOverlay"
countdownFrame.AnchorPoint = Vector2.new(0.5, 0.5)
countdownFrame.Position = UDim2.new(0.5, 0, 0.32, 0)
countdownFrame.Size = UDim2.new(0, 260, 0, 140)
countdownFrame.BackgroundTransparency = 1
countdownFrame.Visible = false
countdownFrame.Parent = screenGui

local countdownLabelText = Instance.new("TextLabel")
countdownLabelText.Name = "Label"
countdownLabelText.BackgroundTransparency = 1
countdownLabelText.Size = UDim2.new(1, 0, 0, 30)
countdownLabelText.Position = UDim2.new(0, 0, 0, 0)
countdownLabelText.Font = Enum.Font.GothamMedium
countdownLabelText.TextSize = 22
countdownLabelText.TextColor3 = Color3.fromRGB(255, 255, 255)
countdownLabelText.Text = ""
countdownLabelText.Parent = countdownFrame

local countdownNumber = Instance.new("TextLabel")
countdownNumber.Name = "Number"
countdownNumber.BackgroundTransparency = 1
countdownNumber.Size = UDim2.new(1, 0, 0, 100)
countdownNumber.Position = UDim2.new(0, 0, 0, 30)
countdownNumber.Font = Enum.Font.GothamBlack
countdownNumber.TextSize = 72
countdownNumber.TextColor3 = Color3.fromRGB(255, 215, 0)
countdownNumber.TextStrokeTransparency = 0.5
countdownNumber.Text = ""
countdownNumber.Parent = countdownFrame

local function pulseNumber()
	countdownNumber.TextTransparency = 0
	countdownNumber.Size = UDim2.new(1, 0, 0, 120)
	local tween = TweenService:Create(countdownNumber, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(1, 0, 0, 100),
	})
	tween:Play()
end

local countdownRemote = SentinelShared:WaitForChild("CountdownRemote", 15)
if countdownRemote and countdownRemote:IsA("RemoteEvent") then
	countdownRemote.OnClientEvent:Connect(function(phase: string, label: string, remaining: number, _total: number)
		countdownFrame.Visible = true
		countdownLabelText.Text = label

		if phase == "tick" then
			countdownNumber.Text = tostring(remaining)
			countdownNumber.TextColor3 = if remaining <= 3 then Color3.fromRGB(255, 80, 80) else Color3.fromRGB(255, 215, 0)
			pulseNumber()
		elseif phase == "done" then
			countdownNumber.Text = "GO!"
			countdownNumber.TextColor3 = Color3.fromRGB(80, 255, 120)
			pulseNumber()
			task.delay(1.5, function()
				countdownFrame.Visible = false
			end)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Movement & Physics handling (Fly, Noclip) + fly control menu
-- ---------------------------------------------------------------------------
local RunService = game:GetService("RunService")
local isFlying = false
local flySpeed = 50
local flyGyro: BodyGyro? = nil
local flyVelocity: BodyVelocity? = nil
local flyConn: RBXScriptConnection? = nil
local noclipEnabled = false
local noclipConn: RBXScriptConnection? = nil

local movementRemote = SentinelShared:WaitForChild("MovementRemote", 15) :: RemoteEvent?

-- Tell the server about changes the player made from the fly menu, so the
-- SentinelFlying / SentinelNoclip attributes (shown in the Players page)
-- stay accurate. The server only ever updates the sender's own attributes.
local function reportState(kind: string, value: boolean)
	if movementRemote then
		movementRemote:FireServer(kind, value)
	end
end

-- Fly menu (bottom-right): Deactivate fly, Noclip toggle, Close.
local FLY_COLORS = {
	Surface = Color3.fromRGB(26, 26, 32),
	Raised = Color3.fromRGB(34, 34, 42),
	Accent = Color3.fromRGB(64, 156, 255),
	Error = Color3.fromRGB(235, 87, 87),
	Text = Color3.fromRGB(240, 240, 245),
	TextSecondary = Color3.fromRGB(150, 150, 160),
}

local flyMenu = Instance.new("Frame")
flyMenu.Name = "FlyMenu"
flyMenu.AnchorPoint = Vector2.new(1, 1)
flyMenu.Position = UDim2.new(1, -16, 1, -16)
flyMenu.Size = UDim2.new(0, 230, 0, 146)
flyMenu.BackgroundColor3 = FLY_COLORS.Surface
flyMenu.BorderSizePixel = 0
flyMenu.Visible = false
flyMenu.Parent = screenGui
do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = flyMenu
	local stroke = Instance.new("UIStroke")
	stroke.Color = FLY_COLORS.Accent
	stroke.Thickness = 1.5
	stroke.Parent = flyMenu
end

local flyTitle = Instance.new("TextLabel")
flyTitle.Name = "Title"
flyTitle.BackgroundTransparency = 1
flyTitle.Position = UDim2.new(0, 14, 0, 8)
flyTitle.Size = UDim2.new(1, -56, 0, 26)
flyTitle.Font = Enum.Font.GothamBold
flyTitle.TextSize = 16
flyTitle.TextColor3 = FLY_COLORS.Text
flyTitle.TextXAlignment = Enum.TextXAlignment.Left
flyTitle.Text = "✈  Fly Controls"
flyTitle.Parent = flyMenu

local flyHint = Instance.new("TextLabel")
flyHint.Name = "Hint"
flyHint.BackgroundTransparency = 1
flyHint.Position = UDim2.new(0, 14, 0, 32)
flyHint.Size = UDim2.new(1, -28, 0, 16)
flyHint.Font = Enum.Font.Gotham
flyHint.TextSize = 12
flyHint.TextColor3 = FLY_COLORS.TextSecondary
flyHint.TextXAlignment = Enum.TextXAlignment.Left
flyHint.Text = "WASD to move · Space up · Shift down"
flyHint.Parent = flyMenu

local function makeFlyButton(name: string, text: string, color: Color3, position: UDim2, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = size
	button.BackgroundColor3 = color
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.TextColor3 = FLY_COLORS.Text
	button.Text = text
	button.Parent = flyMenu
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button
	return button
end

local flyCloseButton = makeFlyButton("CloseButton", "X", FLY_COLORS.Raised, UDim2.new(1, -38, 0, 10), UDim2.new(0, 26, 0, 26))
flyCloseButton.TextSize = 13
local noclipButton = makeFlyButton("NoclipButton", "Noclip: OFF", FLY_COLORS.Raised, UDim2.new(0, 14, 0, 56), UDim2.new(1, -28, 0, 34))
local unflyButton = makeFlyButton("DeactivateButton", "Deactivate Fly", FLY_COLORS.Error, UDim2.new(0, 14, 0, 98), UDim2.new(1, -28, 0, 34))

local function refreshNoclipButton()
	noclipButton.Text = if noclipEnabled then "Noclip: ON" else "Noclip: OFF"
	noclipButton.BackgroundColor3 = if noclipEnabled then FLY_COLORS.Accent else FLY_COLORS.Raised
end

local function setNoclip(enabled: boolean)
	noclipEnabled = enabled
	if noclipConn then
		noclipConn:Disconnect()
		noclipConn = nil
	end
	if noclipEnabled then
		noclipConn = RunService.Stepped:Connect(function()
			local char = localPlayer.Character
			if char then
				for _, part in ipairs(char:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanCollide = false
					end
				end
			end
		end)
	end
	refreshNoclipButton()
end

local function stopFlying()
	isFlying = false
	flyMenu.Visible = false
	if flyConn then
		flyConn:Disconnect()
		flyConn = nil
	end
	if flyGyro then
		flyGyro:Destroy()
		flyGyro = nil
	end
	if flyVelocity then
		flyVelocity:Destroy()
		flyVelocity = nil
	end
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

local function startFlying(speed: number?)
	stopFlying()

	local char = localPlayer.Character
	if not char then return end
	local root = (char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso")) :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not root or not hum then return end

	isFlying = true
	flySpeed = speed or 50
	hum.PlatformStand = true

	local gyro = Instance.new("BodyGyro")
	gyro.P = 9e4
	gyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
	gyro.CFrame = root.CFrame
	gyro.Parent = root
	flyGyro = gyro

	local velocity = Instance.new("BodyVelocity")
	velocity.Velocity = Vector3.zero
	velocity.MaxForce = Vector3.new(9e9, 9e9, 9e9)
	velocity.Parent = root
	flyVelocity = velocity

	refreshNoclipButton()
	flyMenu.Visible = true

	flyConn = RunService.RenderStepped:Connect(function()
		if not isFlying or not root.Parent or not hum.Parent then
			stopFlying()
			return
		end

		local camera = workspace.CurrentCamera
		if not camera then return end
		gyro.CFrame = camera.CFrame

		-- W/S fly where the camera looks (including up/down), A/D strafe,
		-- Space/Shift move straight up/down.
		local moveDir = hum.MoveDirection
		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local flatRight = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
		local direction = Vector3.zero
		if moveDir.Magnitude > 0 and flatLook.Magnitude > 0 and flatRight.Magnitude > 0 then
			flatLook = flatLook.Unit
			flatRight = flatRight.Unit
			direction = look * moveDir:Dot(flatLook) + flatRight * moveDir:Dot(flatRight)
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			direction += Vector3.yAxis
		elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			direction -= Vector3.yAxis
		end

		velocity.Velocity = if direction.Magnitude > 0 then direction.Unit * flySpeed else Vector3.zero
	end)
end

unflyButton.MouseButton1Click:Connect(function()
	stopFlying()
	reportState("FlyState", false)
end)

noclipButton.MouseButton1Click:Connect(function()
	setNoclip(not noclipEnabled)
	reportState("NoclipState", noclipEnabled)
end)

flyCloseButton.MouseButton1Click:Connect(function()
	-- Close only hides the menu; flight keeps going (use /unfly to stop).
	flyMenu.Visible = false
end)

-- A respawn destroys the old character's BodyGyro/BodyVelocity; drop the
-- fly state with it so the menu and server attributes stay accurate.
localPlayer.CharacterAdded:Connect(function()
	if isFlying then
		stopFlying()
		reportState("FlyState", false)
	end
end)

if movementRemote then
	movementRemote.OnClientEvent:Connect(function(action: string, arg: any)
		if action == "Fly" then
			startFlying(tonumber(arg))
		elseif action == "Unfly" then
			stopFlying()
		elseif action == "Noclip" then
			setNoclip(arg == true)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Utility & Broadcast listener (Hint, PM, View/Watch)
-- ---------------------------------------------------------------------------
local utilityRemote = SentinelShared:WaitForChild("UtilityRemote", 15)
if utilityRemote and utilityRemote:IsA("RemoteEvent") then
	utilityRemote.OnClientEvent:Connect(function(action: string, ...)
		local args = { ... }
		if action == "Hint" then
			local text = args[1] or ""
			playBanner(text, Color3.fromRGB(0, 170, 255))
		elseif action == "View" then
			local subject = args[1]
			if subject and workspace.CurrentCamera then
				workspace.CurrentCamera.CameraSubject = subject
			end
		elseif action == "Unview" then
			if workspace.CurrentCamera and localPlayer.Character then
				workspace.CurrentCamera.CameraSubject = localPlayer.Character:FindFirstChildOfClass("Humanoid")
			end
		elseif action == "PM" then
			local senderName = args[1] or "Staff"
			local messageText = args[2] or ""

			local pmGui = Instance.new("Frame")
			pmGui.Name = "SentinelPM"
			pmGui.AnchorPoint = Vector2.new(0.5, 0.5)
			pmGui.Position = UDim2.new(0.5, 0, 0.5, 0)
			pmGui.Size = UDim2.new(0, 360, 0, 150)
			pmGui.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
			pmGui.BorderSizePixel = 0
			pmGui.Parent = screenGui

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = pmGui

			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(64, 156, 255)
			stroke.Thickness = 2
			stroke.Parent = pmGui

			local titleLbl = Instance.new("TextLabel")
			titleLbl.BackgroundTransparency = 1
			titleLbl.Position = UDim2.new(0, 14, 0, 10)
			titleLbl.Size = UDim2.new(1, -28, 0, 24)
			titleLbl.Font = Enum.Font.GothamBold
			titleLbl.TextSize = 16
			titleLbl.TextColor3 = Color3.fromRGB(64, 156, 255)
			titleLbl.TextXAlignment = Enum.TextXAlignment.Left
			titleLbl.Text = "✉ Private Message from " .. senderName
			titleLbl.Parent = pmGui

			local bodyLbl = Instance.new("TextLabel")
			bodyLbl.BackgroundTransparency = 1
			bodyLbl.Position = UDim2.new(0, 14, 0, 38)
			bodyLbl.Size = UDim2.new(1, -28, 0, 64)
			bodyLbl.Font = Enum.Font.Gotham
			bodyLbl.TextSize = 13
			bodyLbl.TextColor3 = Color3.fromRGB(240, 240, 245)
			bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
			bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
			bodyLbl.TextWrapped = true
			bodyLbl.Text = messageText
			bodyLbl.Parent = pmGui

			local closeBtn = Instance.new("TextButton")
			closeBtn.AnchorPoint = Vector2.new(0.5, 1)
			closeBtn.Position = UDim2.new(0.5, 0, 1, -10)
			closeBtn.Size = UDim2.new(0, 100, 0, 28)
			closeBtn.BackgroundColor3 = Color3.fromRGB(64, 156, 255)
			closeBtn.Font = Enum.Font.GothamMedium
			closeBtn.TextSize = 12
			closeBtn.TextColor3 = Color3.new(1, 1, 1)
			closeBtn.Text = "Dismiss"
			closeBtn.Parent = pmGui

			local btnCorner = Instance.new("UICorner")
			btnCorner.CornerRadius = UDim.new(0, 6)
			btnCorner.Parent = closeBtn

			closeBtn.MouseButton1Click:Connect(function()
				pmGui:Destroy()
			end)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Main Sentinel UI shell (Phase 7): sidebar, top bar, status bar, command
-- palette, and per-section pages. Placed in StarterGui.SentinelUI, which
-- Roblox clones into this player's PlayerGui automatically — same as any
-- other StarterGui content.
-- ---------------------------------------------------------------------------

local sentinelUIFolder = playerGui:WaitForChild("SentinelUI", 15)
if sentinelUIFolder then
	local moduleWaitList = {
		{ Name = "Theme" },
		{ Name = "Shell" },
		{ Name = "CommandPalette" },
		{ Name = "DashboardPage" },
		{ Name = "PlayersPage" },
		{ Name = "ModerationPage" },
		{ Name = "CommandsPage" },
		{ Name = "EconomyPage" },
		{ Name = "ServerPage" },
		{ Name = "AnalyticsPage" },
		{ Name = "DeveloperPage" },
		{ Name = "NotificationCenter" },
		{ Name = "SettingsPage" },
		{ Name = "RankManagementPage" },
	}
	local loadedModules: { [string]: ModuleScript } = {}
	local missingModules: { string } = {}
	for _, entry in ipairs(moduleWaitList) do
		local instance = sentinelUIFolder:WaitForChild(entry.Name, 15)
		if instance then
			loadedModules[entry.Name] = instance :: ModuleScript
		else
			table.insert(missingModules, entry.Name)
		end
	end

	if #missingModules > 0 then
		warn(
			("[Sentinel] SentinelUI module(s) not found under StarterGui.SentinelUI within 15s: %s. "
				.. "Check they exist in StarterGui > SentinelUI in the Explorer and that Rojo is connected/synced — UI shell not started."):format(
				table.concat(missingModules, ", ")
			)
		)
		return
	end

	local themeModule = loadedModules.Theme
	local shellModule = loadedModules.Shell
	local commandPaletteModule = loadedModules.CommandPalette
	local dashboardPageModule = loadedModules.DashboardPage
	local playersPageModule = loadedModules.PlayersPage
	local moderationPageModule = loadedModules.ModerationPage
	local commandsPageModule = loadedModules.CommandsPage
	local serverPageModule = loadedModules.ServerPage
	local economyPageModule = loadedModules.EconomyPage
	local analyticsPageModule = loadedModules.AnalyticsPage
	local developerPageModule = loadedModules.DeveloperPage
	local notificationCenterModule = loadedModules.NotificationCenter
	local settingsPageModule = loadedModules.SettingsPage
	local rankPageModule = loadedModules.RankManagementPage

	local canOpenPanelRemote = SentinelShared:WaitForChild("CanOpenPanelRemote", 15) :: RemoteFunction?

	-- IMPORTANT: the UI is NOT built eagerly on join. It's built the first
	-- time the server confirms (via CanOpenPanelRemote) that this player
	-- actually has a staff role — otherwise a non-staff player could see
	-- the whole panel (player list, roles, moderation log, dashboard
	-- stats) even though every command they tried would be denied. This
	-- was a real gap in an earlier version of this file.
	local uiBuilt = false
	local Shell, CommandPalette

	local function buildUI()
		local Theme = require(themeModule)
		Shell = require(shellModule)
		CommandPalette = require(commandPaletteModule)
		local DashboardPage = require(dashboardPageModule)
		local PlayersPage = require(playersPageModule)
		local ModerationPage = require(moderationPageModule)
		local CommandsPage = require(commandsPageModule)
		local ServerPage = require(serverPageModule)
		local EconomyPage = require(economyPageModule)
		local AnalyticsPage = require(analyticsPageModule)
		local DeveloperPage = require(developerPageModule)
		local NotificationCenter = require(notificationCenterModule)
		local SettingsPage = require(settingsPageModule)
		local RankManagementPage = require(rankPageModule)

		Shell.Init()
		CommandPalette.Init()

		DashboardPage.Build(Shell.RegisterPage("Dashboard", "Dashboard", "🏠"), CommandPalette)
		PlayersPage.Build(Shell.RegisterPage("Players", "Players", "👥"))
		ModerationPage.Build(Shell.RegisterPage("Moderation", "Moderation", "🛡"))
		CommandsPage.Build(Shell.RegisterPage("Commands", "Commands", "📜"), CommandPalette)
		EconomyPage.Build(Shell.RegisterPage("Economy", "Economy", "🪙"))
		ServerPage.Build(Shell.RegisterPage("Server", "Server", "🌎"))
		AnalyticsPage.Build(Shell.RegisterPage("Analytics", "Analytics", "📈"))
		DeveloperPage.Build(Shell.RegisterPage("Developer", "Developer", "🛠"))
		NotificationCenter.Init()
		NotificationCenter.BuildPage(Shell.RegisterPage("Notifications", "Notifications", "🔔"))
		RankManagementPage.Build(Shell.RegisterPage("Ranks", "Ranks", "👑"), Shell.GetPageIds())
		SettingsPage.Build(Shell.RegisterPage("Settings", "Settings", "⚙"), CommandPalette, NotificationCenter)

		-- Page visibility permissions: hide pages the player's ranks
		-- explicitly deny ("!page.<id>"). Visible by default.
		local hiddenPagesRemote = SentinelShared:FindFirstChild("GetHiddenPagesRemote") :: RemoteFunction?
		if hiddenPagesRemote then
			local okHidden, hidden = pcall(function()
				return (hiddenPagesRemote :: RemoteFunction):InvokeServer(Shell.GetPageIds())
			end)
			if okHidden and type(hidden) == "table" then
				for _, pageId in ipairs(hidden) do
					Shell.SetPageVisible(pageId, false)
				end
			end
		end

		Shell.searchButton.MouseButton1Click:Connect(function()
			CommandPalette.Open()
		end)

		-- Show Dashboard now that every page (real and placeholder) has
		-- actually been registered. Calling this any earlier (e.g. inside
		-- Shell.Init itself) was the cause of an earlier bug where the
		-- Dashboard page stayed invisible until switching tabs and back.
		Shell.ShowPage("Dashboard")

		uiBuilt = true
		Shell.Toggle() -- open immediately on first successful build, since this call came from an explicit F6 press
		print("[Sentinel] UI shell built and opened — Ctrl+Shift+P for the command palette.")
	end

	-- Re-checks permission every time until the UI is actually built, so a
	-- player promoted mid-session (e.g. via /assignrole while testing)
	-- doesn't need to rejoin — they just press F6 again after being granted
	-- a role.
	local function tryOpenPanel()
		if uiBuilt then
			Shell.Toggle()
			return
		end
		if not canOpenPanelRemote then
			return
		end
		local ok, allowed = pcall(function()
			return canOpenPanelRemote:InvokeServer()
		end)
		if ok and allowed then
			buildUI()
		end
		-- Deliberately silent on denial — no UI flash, no error, nothing
		-- to indicate the panel exists at all to a non-staff player.
	end

	-- F6 toggles the main Sentinel panel. NOT "P" — this game's other admin
	-- panel (AdminPanelClient) already binds P for its own UI, so reusing it
	-- here would collide. Ctrl+Shift+P is reserved solely for the Command
	-- Palette (wired up inside CommandPalette.Init, which only runs after
	-- access is confirmed), so it does nothing for non-staff either.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F6 then
			tryOpenPanel()
		end
	end)
end

print("[Sentinel] Client shell loaded.")
