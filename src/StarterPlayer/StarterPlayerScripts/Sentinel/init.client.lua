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
		- Load SentinelUI/AnnouncementBanner (announcements, PMs, approvals)
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

-- W14: report / appeal forms and the ban screen, for every player. Loaded
-- first: a banned player never spawns, so nothing from StarterGui arrives.
local PlayerForms = require(script:WaitForChild("PlayerForms"))
PlayerForms.Init()

-- HD Admin gap: rank / custom chat tags ([Admin] Player1: hi), every player.
require(script:WaitForChild("ChatTags")).Init()

-- W-FINAL.1: client components of enabled Sentinel modules (every player).
require(script:WaitForChild("ModuleHost")).Init()

-- Soft Shutdown: "Servers are restarting" screen (every player, also in the
-- waiting-room server).
require(script:WaitForChild("SoftShutdown")).Init()

-- Sentinel AntiCheat: tiny client reporter (untrusted hints, every player).
require(script:WaitForChild("AntiCheatReporter")).Init()

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
-- Announcements, private messages and Owner approval cards live in
-- SentinelUI/AnnouncementBanner (built for every player, staff or not).
-- ---------------------------------------------------------------------------
-- StarterGui content is copied into PlayerGui when the character first
-- spawns, which can take well over 15 s on a slow join (seen live: 30+ s).
-- A timeout here used to skip the whole Sentinel UI silently (no panel, no
-- top bar buttons, no F6), so wait for as long as it takes.
local function waitForSentinelUI(): Instance
	local folder = playerGui:FindFirstChild("SentinelUI")
	if folder then
		return folder
	end
	local warned = false
	local started = os.clock()
	while not folder do
		folder = playerGui:WaitForChild("SentinelUI", 5)
		if not folder and not warned and os.clock() - started > 15 then
			warned = true
			warn("[Sentinel] PlayerGui.SentinelUI hasn't arrived after 15 s (slow join) - still waiting.")
		end
	end
	return folder :: Instance
end

local AnnouncementBanner: any = nil
do
	local folder = waitForSentinelUI()
	local module = folder:WaitForChild("AnnouncementBanner", 15)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then
			AnnouncementBanner = result
			AnnouncementBanner.Init()
		else
			warn("[Sentinel] AnnouncementBanner failed to load: " .. tostring(result))
		end
	end
	-- W24: running / scheduled events bar (every player).
	local eventBar = folder:WaitForChild("EventBar", 15)
	if eventBar and eventBar:IsA("ModuleScript") then
		task.spawn(function()
			local ok, result = pcall(function()
				require(eventBar).Init()
			end)
			if not ok then
				warn("[Sentinel] EventBar failed to load: " .. tostring(result))
			end
		end)
	end
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
		if phase == "cancel" then
			-- ;cancelshutdown / ;cancelrestart (M-panel gaps)
			countdownFrame.Visible = false
			return
		end
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
			if AnnouncementBanner then
				AnnouncementBanner.ShowHint(tostring(text))
			end
		elseif action == "View" then
			local subject = args[1]
			if subject and workspace.CurrentCamera then
				workspace.CurrentCamera.CameraSubject = subject
			end
		elseif action == "Unview" then
			if workspace.CurrentCamera and localPlayer.Character then
				workspace.CurrentCamera.CameraSubject = localPlayer.Character:FindFirstChildOfClass("Humanoid")
			end
		-- Private messages arrive on PrivateMessageRemote (AnnouncementBanner).
		end
	end)
end

-- ---------------------------------------------------------------------------
-- ;control (Systems/ControlService). The controller's client owns the
-- target's physics, follows it with the camera and feeds its own movement
-- input into the target's Humanoid; the target's controls are disabled.
-- ---------------------------------------------------------------------------
do
	local RunService = game:GetService("RunService")
	local controlRemote = SentinelShared:WaitForChild("ControlRemote", 15)
	local controls: any = nil
	local function getControls(): any
		if controls == nil then
			local ok, result = pcall(function()
				local module = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
				return module and require(module :: ModuleScript):GetControls()
			end)
			controls = if ok and result then result else false
		end
		return controls or nil
	end
	local connections: { RBXScriptConnection } = {}
	local function stopDriving()
		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		table.clear(connections)
		local camera = workspace.CurrentCamera
		local char = localPlayer.Character
		if camera and char then
			camera.CameraSubject = char:FindFirstChildOfClass("Humanoid")
		end
	end
	if controlRemote and controlRemote:IsA("RemoteEvent") then
		controlRemote.OnClientEvent:Connect(function(action: string, a: any, b: any)
			if action == "start" then
				stopDriving()
				local targetChar = a :: Model?
				local hum = targetChar and targetChar:FindFirstChildOfClass("Humanoid")
				if not hum then
					controlRemote:FireServer("stop")
					return
				end
				local camera = workspace.CurrentCamera
				if camera then
					camera.CameraSubject = hum
				end
				local ctl = getControls()
				table.insert(connections, RunService.RenderStepped:Connect(function()
					if not hum.Parent or hum.Health <= 0 then
						stopDriving()
						controlRemote:FireServer("stop")
						return
					end
					local move = if ctl then ctl:GetMoveVector() else Vector3.zero
					hum:Move(move, true)
				end))
				table.insert(connections, UserInputService.JumpRequest:Connect(function()
					if hum.Parent then
						hum.Jump = true
					end
				end))
				if AnnouncementBanner then
					AnnouncementBanner.ShowHint(("Controlling %s - type ;uncontrol to stop"):format(tostring(b)))
				end
			elseif action == "stop" then
				stopDriving()
				if AnnouncementBanner then
					AnnouncementBanner.ShowHint(("Stopped controlling %s%s"):format(tostring(a), if b then " (" .. tostring(b) .. ")" else ""))
				end
			elseif action == "controlled" then
				local ctl = getControls()
				if ctl then
					ctl:Disable()
				end
				if AnnouncementBanner then
					AnnouncementBanner.ShowHint(("%s is controlling your character"):format(tostring(a)))
				end
			elseif action == "released" then
				local ctl = getControls()
				if ctl then
					ctl:Enable()
				end
				if AnnouncementBanner then
					AnnouncementBanner.ShowHint("You have your character back")
				end
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Main Sentinel UI shell (Phase 7): sidebar, top bar, status bar, command
-- palette, and per-section pages. Placed in StarterGui.SentinelUI, which
-- Roblox clones into this player's PlayerGui automatically — same as any
-- other StarterGui content.
-- ---------------------------------------------------------------------------

local sentinelUIFolder = waitForSentinelUI()
if sentinelUIFolder then
	local moduleWaitList = {
		{ Name = "Theme" },
		{ Name = "Shell" },
		{ Name = "CommandPalette" },
		{ Name = "DashboardPage" },
		{ Name = "PlayersPage" },
		{ Name = "ModerationPage" },
		{ Name = "ReportsPage" },
		{ Name = "CommandsPage" },
		{ Name = "EconomyPage" },
		{ Name = "ServerPage" },
		{ Name = "AnalyticsPage" },
		{ Name = "AuditLogPage" },
		{ Name = "LookupPage" },
		{ Name = "AnnouncementsPage" },
		{ Name = "DeveloperPage" },
		{ Name = "NotificationCenter" },
		{ Name = "SettingsPage" },
		{ Name = "RankManagementPage" },
		{ Name = "ConfirmDialog" },
		{ Name = "LibraryPage" },
		{ Name = "CommandBuilder" },
		{ Name = "CrossServerPage" },
		{ Name = "CommandBar" },
		{ Name = "AppearancePage" },
		{ Name = "KeybindsPage" },
		{ Name = "InGameSettingsPage" },
		{ Name = "TopbarIcons" },
		{ Name = "PollsPage" },
		{ Name = "EventsPage" },
		{ Name = "StaffFeedsPage" },
		{ Name = "BannedPage" },
		{ Name = "ModulesPage" },
		{ Name = "ToggleSwitch" },
		{ Name = "AntiCheatCenter" },
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
	local confirmDialogModule = loadedModules.ConfirmDialog
	local libraryPageModule = loadedModules.LibraryPage
	local commandBuilderModule = loadedModules.CommandBuilder
	local crossServerPageModule = loadedModules.CrossServerPage

	local canOpenPanelRemote = SentinelShared:WaitForChild("CanOpenPanelRemote", 15) :: RemoteFunction?

	-- IMPORTANT: the UI is NOT built eagerly on join. It's built the first
	-- time the server confirms (via CanOpenPanelRemote) that this player
	-- actually has a staff role — otherwise a non-staff player could see
	-- the whole panel (player list, roles, moderation log, dashboard
	-- stats) even though every command they tried would be denied. This
	-- was a real gap in an earlier version of this file.
	local uiBuilt = false
	-- True while buildUI runs (the background pre-build or an F6 press), so
	-- the panel is never built twice.
	local uiBuilding = false
	local Shell, CommandPalette

	-- -----------------------------------------------------------------------
	-- UI preferences (redesign): panel theme + command bar look. Effective =
	-- built-in < server default (Owner) < personal. Applied before anything
	-- is built, and live whenever the server reports a change.
	-- -----------------------------------------------------------------------
	local Theme = require(themeModule)
	local CommandBar: any = nil
	local NotificationCenterRef: any = nil
	local effectivePrefs: any = nil
	local uiPrefsRemote = SentinelShared:WaitForChild("GetUIPrefsRemote", 15) :: RemoteFunction?
	local prefsChangedRemote = SentinelShared:WaitForChild("UIPrefsChangedRemote", 15) :: RemoteEvent?

	local function applyPrefs(newPrefs: any)
		if type(newPrefs) ~= "table" or type(newPrefs.Panel) ~= "table" then
			return
		end
		effectivePrefs = newPrefs
		local previous, previousFonts = Theme.Apply(newPrefs.Panel)
		-- Recolour / refont what already exists (the command bar rebuilds itself).
		for _, gui in ipairs(playerGui:GetChildren()) do
			if gui:IsA("ScreenGui") and gui.Name:sub(1, 8) == "Sentinel" and gui.Name ~= "SentinelCommandBar" and gui.Name ~= "SentinelOverlay" then
				Theme.Retint(gui, previous, previousFonts)
			end
		end
		if uiBuilt and Shell then
			Shell.ApplyPrefs(newPrefs.Panel, newPrefs.Layout)
		end
		-- Seasonal themes: the top-bar "S" button image (Icons slot).
		local topbarModule = sentinelUIFolder and sentinelUIFolder:FindFirstChild("TopbarIcons")
		if topbarModule and topbarModule:IsA("ModuleScript") then
			pcall(function()
				local UIPrefsModule = require(SentinelShared:WaitForChild("UIPrefs")) :: any
				local IconsModule = require(SentinelShared:WaitForChild("Icons")) :: any
				local season = UIPrefsModule.Season(newPrefs.Panel)
				require(topbarModule).SetImage("Sentinel", if season then IconsModule.image(season.Topbar) else nil)
			end)
		end
		if NotificationCenterRef and type(newPrefs.Notifications) == "table" then
			NotificationCenterRef.ApplyPrefs(newPrefs.Notifications)
		end
		-- Sound effects (SentinelUI/SoundPlayer) follow the Sounds section.
		local soundModule = sentinelUIFolder and sentinelUIFolder:FindFirstChild("SoundPlayer")
		if soundModule then
			require(soundModule :: ModuleScript).ApplyPrefs(newPrefs.Sounds)
		end
		if CommandBar then
			CommandBar.ApplyPrefs(newPrefs)
		end
	end

	-- Asks the server what this player may use. The command bar is built
	-- for staff and for ranks with "commandbar.use" (VIP); asked again on
	-- F2 until it exists, so a rank granted mid-session works without a
	-- rejoin.
	local function ensureCommandBar(): boolean
		if CommandBar then
			return true
		end
		if not uiPrefsRemote then
			return false
		end
		local ok, snapshot = pcall(function()
			return (uiPrefsRemote :: RemoteFunction):InvokeServer()
		end)
		if not ok or type(snapshot) ~= "table" or not snapshot.CanCommandBar then
			return false
		end
		applyPrefs(snapshot.Effective)
		CommandBar = require(loadedModules.CommandBar)
		CommandBar.Init(effectivePrefs)
		return true
	end
	task.spawn(ensureCommandBar)

	-- -----------------------------------------------------------------------
	-- Sentinel AntiCheat: the Anti-Cheat Control Center (own window). Built
	-- only when the server says this player has anticheat.view; opened by F7,
	-- the AC top-bar button, Moderation > Anti-Cheat, Ctrl+K > anti and
	-- ;anticheat / ;ac.
	-- -----------------------------------------------------------------------
	local AntiCheatCenter: any = nil
	local antiCheatChecked = false
	local antiCheatBusy = false
	local function ensureAntiCheat(): boolean
		if AntiCheatCenter and AntiCheatCenter.IsBuilt() then
			return true
		end
		while antiCheatBusy do
			task.wait()
		end
		if AntiCheatCenter and AntiCheatCenter.IsBuilt() then
			return true
		end
		antiCheatBusy = true
		local ok, result = pcall(function()
			local folder = loadedModules.AntiCheatCenter
			local Center = require(folder:WaitForChild("Center") :: ModuleScript) :: any
			local NotificationCenter = require(notificationCenterModule) :: any
			NotificationCenter.Init()
			local built = Center.Init({
				NotificationCenter = NotificationCenter,
				ConfirmDialog = require(confirmDialogModule),
				ToggleSwitch = require(loadedModules.ToggleSwitch),
			})
			if built then
				Center.Badge = function(on: boolean)
					pcall(function()
						require(loadedModules.TopbarIcons).SetBadge("AntiCheat", on)
					end)
				end
				AntiCheatCenter = Center
			end
			return built
		end)
		antiCheatBusy = false
		antiCheatChecked = true
		if not ok then
			warn("[Sentinel] Anti-Cheat Control Center failed: " .. tostring(result))
			return false
		end
		return result == true
	end
	local function toggleAntiCheat(page: string?, forceOpen: boolean?)
		task.spawn(function()
			if ensureAntiCheat() then
				if forceOpen then
					AntiCheatCenter.Open(page)
				else
					AntiCheatCenter.Toggle(page)
				end
			end
		end)
	end
	local _ = antiCheatChecked

	if prefsChangedRemote then
		prefsChangedRemote.OnClientEvent:Connect(function(update: any)
			if type(update) == "table" then
				applyPrefs(update.Effective)
			end
		end)
	end

	-- openAfter: open the panel once built (an explicit F6 / button press).
	-- Staff get it pre-built in the background after join (openAfter =
	-- false), so the first F6 opens instantly instead of waiting for every
	-- page to build.
	local function buildUI(openAfter: boolean)
		if uiBuilt or uiBuilding then
			return
		end
		uiBuilding = true
		ensureCommandBar() -- also loads + applies the theme before pages are required
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
		if effectivePrefs then
			Shell.ApplyPrefs(effectivePrefs.Panel, effectivePrefs.Layout)
		end
		CommandPalette.Init()
		local CommandBuilder = require(commandBuilderModule)
		local LibraryPage = require(libraryPageModule)
		CommandBuilder.Init(CommandPalette)

		DashboardPage.Build(Shell.RegisterPage("Dashboard", "Dashboard", "🏠"), CommandPalette)
		PlayersPage.Build(Shell.RegisterPage("Players", "Players", "👥"), {
			OpenCommands = function()
				Shell.ShowPage("Commands")
			end,
		})
		ModerationPage.Build(Shell.RegisterPage("Moderation", "Moderation", "🛡"))
		-- W14: Reports + Appeals queues (Moderation section).
		local ReportsPage = require(loadedModules.ReportsPage)
		ReportsPage.Build({
			Reports = Shell.RegisterPage("Reports", "Reports", "🚩"),
			Appeals = Shell.RegisterPage("Appeals", "Appeals", "⚖"),
		}, function(caseId: number)
			Shell.ShowPage("Moderation")
			ModerationPage.OpenCase(caseId)
		end)
		-- M-panel gaps: server chat log + alerts feed (Moderation section).
		local StaffFeedsPage = require(loadedModules.StaffFeedsPage)
		StaffFeedsPage.BuildChatLog(Shell.RegisterPage("ChatLog", "Chat Log", "💬"))
		StaffFeedsPage.BuildAlerts(Shell.RegisterPage("Alerts", "Alerts", "⚠"))
		local LookupPage = require(loadedModules.LookupPage)
		LookupPage.Build(Shell.RegisterPage("Lookup", "Lookup", "🔎"), function(caseId: number)
			Shell.ShowPage("Moderation")
			ModerationPage.OpenCase(caseId)
		end)
		-- Moderation > Banned: every active ban (hidden without moderation.banlist / .ban).
		local bannedContainer = Shell.RegisterPage("Banned", "Banned", "⛔")
		Shell.SetPageVisible("Banned", false)
		task.spawn(function()
			local visible = require(loadedModules.BannedPage).Build(bannedContainer, function(userId: number)
				Shell.ShowPage("Lookup")
				LookupPage.Show(tostring(userId))
			end)
			Shell.SetPageVisible("Banned", visible)
		end)
		CommandsPage.Build(Shell.RegisterPage("Commands", "Commands", "📜"), CommandPalette, CommandBuilder)
		LibraryPage.Build(Shell.RegisterPage("Library", "Library", "📚"), CommandPalette, CommandBuilder)
		EconomyPage.Build(Shell.RegisterPage("Economy", "Economy", "🪙"))
		ServerPage.Build(Shell.RegisterPage("Server", "Server", "🌎"))
		local crossServerContainer = Shell.RegisterPage("CrossServer", "Cross-Server", "🌐")
		require(loadedModules.AnnouncementsPage).Build({
			History = Shell.RegisterPage("AnnounceHistory", "History", "🕘"),
			Server = Shell.RegisterPage("AnnounceServer", "Current server", "📢"),
			Global = Shell.RegisterPage("AnnounceGlobal", "Global", "🌐"),
			Players = Shell.RegisterPage("AnnouncePlayers", "Some players", "👤"),
		}, AnnouncementBanner, function(pageId: string)
			Shell.ShowPage(pageId)
		end)
		-- W23: polls (Announcements section).
		require(loadedModules.PollsPage).Build(Shell.RegisterPage("Polls", "Polls", "📊"))
		-- W24: events (Announcements section).
		require(loadedModules.EventsPage).Build(Shell.RegisterPage("Events", "Events", "🎉"))
		AnalyticsPage.Build(Shell.RegisterPage("Analytics", "Analytics", "📈"))
		require(loadedModules.AuditLogPage).Build(Shell.RegisterPage("Logs", "Audit Log", "📋"))
		DeveloperPage.Build(Shell.RegisterPage("Developer", "Developer", "🛠"))
		-- W-FINAL.1: Module Manager (own nav section).
		require(loadedModules.ModulesPage).Build(Shell.RegisterPage("Modules", "Modules", "🧩"))
		-- Sentinel AntiCheat: Moderation > Anti-Cheat (hidden without anticheat.view).
		local antiCheatPage = Shell.RegisterPage("AntiCheat", "Anti-Cheat", "🛡")
		Shell.SetPageVisible("AntiCheat", false)
		task.spawn(function()
			if ensureAntiCheat() then
				Shell.SetPageVisible("AntiCheat", true)
				require(loadedModules.AntiCheatCenter:WaitForChild("PanelPage") :: ModuleScript).Build(antiCheatPage, AntiCheatCenter, function()
					toggleAntiCheat(nil, true)
				end)
			end
		end)
		NotificationCenter.Init()
		NotificationCenterRef = NotificationCenter
		if effectivePrefs and type(effectivePrefs.Notifications) == "table" then
			NotificationCenter.ApplyPrefs(effectivePrefs.Notifications)
		end
		NotificationCenter.BuildPage(Shell.RegisterPage("Notifications", "Notifications", "🔔"))
		-- W14: a toast when a new report / appeal arrives (staff who can see it).
		local queueEvent = SentinelShared:FindFirstChild("ModerationQueueEvent") :: RemoteEvent?
		if queueEvent then
			queueEvent.OnClientEvent:Connect(function(kind: any, what: any, item: any)
				if what ~= "created" or type(item) ~= "table" then
					return
				end
				local isReport = kind == "report"
				NotificationCenter.Notify({
					Kind = "warning",
					Title = if isReport then ("New report #%d"):format(item.Id) else ("New appeal #%d"):format(item.Id),
					Message = if isReport
						then ("%s reported %s (%s)."):format(tostring(item.ReporterName), tostring(item.TargetName), tostring(item.Category))
						else ("%s appealed their %s."):format(tostring(item.Name), tostring(item.Type)),
					Action = {
						Text = "Review",
						Callback = function()
							Shell.Open()
							Shell.ShowPage(if isReport then "Reports" else "Appeals")
							ReportsPage.Open(if isReport then "report" else "appeal", item.Id)
						end,
					},
				})
			end)
		end
		-- Built after the Notification Center so staff chat and global
		-- notifications can raise toasts.
		require(crossServerPageModule).Build(crossServerContainer, NotificationCenter)
		RankManagementPage.Build(Shell.RegisterPage("Ranks", "Ranks", "👑"), Shell.GetPageIds())
		SettingsPage.Build(Shell.RegisterPage("Settings", "Settings", "⚙"), CommandPalette, NotificationCenter)
		require(loadedModules.AppearancePage).Build(Shell.RegisterPage("Appearance", "Appearance", "🎨"), CommandBar)
		require(loadedModules.KeybindsPage).Build(Shell.RegisterPage("Keybinds", "Keybinds", "⌨"))
		-- Sound effects page = the Appearance page generator limited to the Sounds section.
		require(loadedModules.AppearancePage).Build(Shell.RegisterPage("Sounds", "Sounds", "🔊"), nil, { Sections = { "Sounds" }, Title = "Sounds" })
		require(loadedModules.InGameSettingsPage).Build(Shell.RegisterPage("Administration", "Administration", "🛠"))

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

		-- Risky / bulk commands come back with NeedsConfirmation (see the
		-- server's Core/CommandPolicy). Ask here; the server re-checks
		-- everything when ;confirm arrives.
		local ConfirmDialog = require(confirmDialogModule)
		local resultRemote = SentinelShared:WaitForChild("CommandResultRemote") :: RemoteEvent
		local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote") :: RemoteEvent
		resultRemote.OnClientEvent:Connect(function(results: any)
			if type(results) ~= "table" then
				return
			end
			for _, result in ipairs(results) do
				if type(result) == "table" and result.NeedsConfirmation and type(result.ConfirmId) == "string" then
					ConfirmDialog.Show({
						Title = if result.Risk == "critical" then "Critical action" else "Confirm action",
						Message = (tostring(result.Message):gsub("^⚠%s*", ""):gsub(" Type ;confirm within %d+s to run it%.", "")),
						RequiredText = "CONFIRM",
						ConfirmLabel = "Run it",
						OnConfirm = function()
							executeRemote:FireServer("confirm " .. result.ConfirmId)
						end,
					})
					break
				end
			end
		end)

		uiBuilt = true
		uiBuilding = false
		if openAfter then
			Shell.Toggle()
		end
		print("[Sentinel] UI shell built — F6 opens it, Ctrl+K for the command palette.")
	end

	-- Re-checks permission every time until the UI is actually built, so a
	-- player promoted mid-session (e.g. via /assignrole while testing)
	-- doesn't need to rejoin — they just press F6 again after being granted
	-- a role.
	local openRequested = false
	local function tryOpenPanel()
		if uiBuilt then
			Shell.Toggle()
			return
		end
		if uiBuilding then
			-- The background pre-build is running: open when it finishes.
			if not openRequested then
				openRequested = true
				task.spawn(function()
					while uiBuilding do
						task.wait()
					end
					openRequested = false
					if uiBuilt and not Shell.IsOpen() then
						Shell.Open()
					end
				end)
			end
			return
		end
		if not canOpenPanelRemote then
			return
		end
		local ok, allowed = pcall(function()
			return canOpenPanelRemote:InvokeServer()
		end)
		if ok and allowed then
			local okBuild, err = pcall(buildUI, true)
			if not okBuild then
				uiBuilding = false
				warn("[Sentinel] UI build failed: " .. tostring(err))
			end
		end
		-- Deliberately silent on denial — no UI flash, no error, nothing
		-- to indicate the panel exists at all to a non-staff player.
	end

	-- F6 toggles the main Sentinel panel. NOT "P" — this game's other admin
	-- panel (AdminPanelClient) already binds P for its own UI, so reusing it
	-- here would collide. The palette is Ctrl+K: Ctrl+Shift+P also toggled
	-- Roblox's developer Freecam (Shift+P), which hides every ScreenGui.
	--
	-- W08: every shortcut is a preference (Shared/UIPrefs "Keys"): panel,
	-- close panel, palette, quick fly / noclip / god, next / previous page and
	-- custom key -> command binds. Quick actions and custom binds are normal
	-- commands, so the server still checks every permission.
	local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))
	local keyExecuteRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?

	local function runCommand(text: string)
		if keyExecuteRemote then
			keyExecuteRemote:FireServer(text, { Source = "keybind" })
		end
	end

	local function quickToggle(attribute: string, onCommand: string, offCommand: string)
		if localPlayer:GetAttribute(attribute) == true then
			runCommand(offCommand .. " me")
		else
			runCommand(onCommand .. " me")
		end
	end

	local function isDown(a: Enum.KeyCode, b: Enum.KeyCode): boolean
		return UserInputService:IsKeyDown(a) or UserInputService:IsKeyDown(b)
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		-- The Keybinds page is recording a new key: that press is not a shortcut.
		if uiBuilt and require(loadedModules.KeybindsPage).IsCapturing() then
			return
		end
		local ctrl = isDown(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl)
		local shift = isDown(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
		local alt = isDown(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt)
		-- While typing (a text box has focus) only Ctrl / Alt chords count,
		-- so plain letter shortcuts never fire mid-sentence.
		-- F-keys are the exception: other scripts (or Studio) often mark them
		-- processed via ContextActionService, yet they never type text, so
		-- they still count unless a text box actually has focus.
		if gameProcessed and not (ctrl or alt) then
			local isFKey = input.KeyCode.Name:match("^F%d+$") ~= nil
			if not isFKey or UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
		end
		local keys = (effectivePrefs and effectivePrefs.Keys) or UIPrefs.BUILTIN.Keys
		local name = input.KeyCode.Name
		local function is(field: string): boolean
			return UIPrefs.MatchKey(keys[field] or UIPrefs.BUILTIN.Keys[field], name, ctrl, shift, alt)
		end

		if is("Panel") then
			tryOpenPanel()
		elseif is("ClosePanel") then
			if uiBuilt and Shell.IsOpen() then
				Shell.Close()
			end
		elseif is("AntiCheat") then
			toggleAntiCheat()
		elseif is("Palette") then
			if uiBuilt and CommandPalette then
				-- Inside the Control Center: anti-cheat commands first.
				if AntiCheatCenter and AntiCheatCenter.IsOpen() and not CommandPalette.IsOpen() then
					CommandPalette.Open("ac")
				else
					CommandPalette.Toggle()
				end
			end
		elseif is("NextPage") or is("PrevPage") then
			if uiBuilt and Shell.IsOpen() then
				Shell.Cycle(if is("NextPage") then 1 else -1)
			end
		elseif is("QuickFly") then
			quickToggle("SentinelFlying", "fly", "unfly")
		elseif is("QuickNoclip") then
			quickToggle("SentinelNoclip", "noclip", "clip")
		elseif is("QuickGod") then
			quickToggle("SentinelGod", "god", "ungod")
		else
			local custom = keys.Custom
			if type(custom) == "table" then
				for _, bind in ipairs(custom) do
					if type(bind) == "table" and UIPrefs.MatchKey(bind.Key, name, ctrl, shift, alt) and type(bind.Command) == "string" then
						runCommand(bind.Command)
						break
					end
				end
			end
		end

		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F2 and not CommandBar then
			-- Not built yet (no access at join): ask again, then open.
			task.spawn(function()
				if ensureCommandBar() and CommandBar and effectivePrefs.CommandBar.Key == "F2" then
					CommandBar.Open()
				end
			end)
		end
	end)

	-- -----------------------------------------------------------------------
	-- Join welcome + top bar buttons (Roblox-style redesign). Everyone who
	-- can run at least one command gets an "Info" card with their ranks;
	-- staff / command bar users also get Sentinel buttons in Roblox's top
	-- bar. The server decides who qualifies (GetWelcomeRemote).
	-- -----------------------------------------------------------------------
	local welcomeRemote = SentinelShared:WaitForChild("GetWelcomeRemote", 15) :: RemoteFunction?

	local function keyLabel(field: string, fallback: string): string
		local keys = (effectivePrefs and effectivePrefs.Keys) or UIPrefs.BUILTIN.Keys
		local key = keys[field]
		return if type(key) == "string" and key ~= "None" then key else fallback
	end

	local function toggleCommandBar()
		task.spawn(function()
			if ensureCommandBar() and CommandBar then
				CommandBar.Toggle()
			end
		end)
	end

	local function showHowTo(NotificationCenter: any, info: any)
		local lines = {}
		if info.CanPanel then
			table.insert(lines, ("<b>%s</b> or the <b>S</b> button in the top bar opens the Sentinel panel."):format(keyLabel("Panel", "F6")))
			table.insert(lines, ("<b>%s</b> opens the command palette."):format(keyLabel("Palette", "Ctrl+K")))
		end
		if info.CanCommandBar then
			local barKey = (effectivePrefs and effectivePrefs.CommandBar and effectivePrefs.CommandBar.Key) or "F2"
			table.insert(lines, ("<b>%s</b> or the <b>&gt;_</b> button opens the command bar."):format(tostring(barKey)))
		end
		local prefixes = if type(info.Prefixes) == "table" and #info.Prefixes > 0 then info.Prefixes else { ";" }
		table.insert(lines, ("In chat, start a command with <b>%s</b> (try <b>%shelp</b>)."):format(
			table.concat(prefixes, " "),
			tostring(prefixes[1])
		))
		table.insert(lines, ("You can use <b>%d</b> commands."):format(tonumber(info.Commands) or 0))
		NotificationCenter.Notify({
			Kind = "info",
			Title = "Getting started",
			RichText = true,
			Message = table.concat(lines, "\n"),
			Duration = 20,
			Record = false,
			Action = if info.CanPanel then { Text = "Open Sentinel", Callback = tryOpenPanel } else nil,
		})
	end

	task.spawn(function()
		if not welcomeRemote then
			return
		end
		-- Ranks are applied as the player joins (group lookups can take a
		-- moment), so ask again a couple of times before giving up.
		local info: any = nil
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return (welcomeRemote :: RemoteFunction):InvokeServer()
			end)
			if ok and type(result) == "table" then
				info = result
				break
			end
			task.wait(4)
		end
		if not info then
			return
		end

		local NotificationCenter = require(notificationCenterModule)
		NotificationCenter.Init()
		NotificationCenterRef = NotificationCenter
		if effectivePrefs and type(effectivePrefs.Notifications) == "table" then
			NotificationCenter.ApplyPrefs(effectivePrefs.Notifications)
		end

		-- Top bar buttons first, so the "S" button the card mentions exists.
		local icons = {}
		if info.CanPanel then
			table.insert(icons, {
				Id = "Sentinel",
				Glyph = "S",
				GlyphSize = 23,
				Tooltip = ("Sentinel (%s)"):format(keyLabel("Panel", "F6")),
				OnClick = tryOpenPanel,
				IsActive = function()
					return uiBuilt and Shell ~= nil and Shell.IsOpen()
				end,
			})
		end
		if info.CanCommandBar then
			table.insert(icons, {
				Id = "CommandBar",
				Glyph = ">_",
				Font = Enum.Font.RobotoMono,
				GlyphSize = 19,
				Tooltip = "Command bar",
				OnClick = toggleCommandBar,
				IsActive = function()
					return CommandBar ~= nil and CommandBar.IsOpen()
				end,
			})
		end
		if info.CanAntiCheat then
			table.insert(icons, {
				Id = "AntiCheat",
				Glyph = "AC",
				GlyphSize = 15,
				Tooltip = ("Anti-Cheat (%s)"):format(keyLabel("AntiCheat", "F7")),
				OnClick = function()
					toggleAntiCheat()
				end,
				IsActive = function()
					return AntiCheatCenter ~= nil and AntiCheatCenter.IsOpen()
				end,
			})
			-- Build it in the background so the red dot (unreviewed
			-- high-severity flags) shows before the first open.
			task.spawn(ensureAntiCheat)
		end
		if #icons > 0 then
			require(loadedModules.TopbarIcons).Init(icons)
		end

		-- Pre-build the panel hidden so the first F6 opens without a delay.
		if info.CanPanel and not uiBuilt and not uiBuilding then
			task.spawn(function()
				local okBuild, err = pcall(buildUI, false)
				if not okBuild then
					uiBuilding = false
					warn("[Sentinel] UI pre-build failed: " .. tostring(err))
				end
			end)
		end

		local chips = {}
		for _, role in ipairs(info.Roles or {}) do
			if type(role) == "table" and type(role.Name) == "string" then
				table.insert(chips, { Text = role.Name, Color = if typeof(role.Color) == "Color3" then role.Color else nil })
			end
		end
		NotificationCenter.Notify({
			Kind = "info",
			Title = "Info",
			RichText = true,
			Message = ("Welcome <b>@%s</b>! Your roles are:"):format(localPlayer.Name),
			Chips = chips,
			Duration = 12,
			Action = {
				Text = "Learn More",
				Callback = function()
					showHowTo(NotificationCenter, info)
				end,
			},
		})
	end)

	-- ;sentinel / ;opensentinel (chat or command bar): the server says
	-- "toggle", or "open" with a page id. tryOpenPanel still asks the server
	-- for access before building anything.
	local panelRemote = SentinelShared:WaitForChild("PanelRemote", 15) :: RemoteEvent?
	if panelRemote then
		panelRemote.OnClientEvent:Connect(function(action: any, page: any)
			if action == "anticheat" then
				toggleAntiCheat(if type(page) == "string" then page else nil, true)
			elseif action == "toggle" then
				tryOpenPanel()
			elseif action == "open" then
				if not (uiBuilt and Shell.IsOpen()) then
					tryOpenPanel()
				end
				if uiBuilt and type(page) == "string" then
					Shell.ShowPage(page)
				end
			end
		end)
	end
end

print("[Sentinel] Client shell loaded.")
