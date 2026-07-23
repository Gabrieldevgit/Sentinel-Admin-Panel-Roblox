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
-- Main Sentinel UI shell (Phase 7): sidebar, top bar, status bar, command
-- palette, and per-section pages. Placed in StarterGui.SentinelUI, which
-- Roblox clones into this player's PlayerGui automatically — same as any
-- other StarterGui content.
-- ---------------------------------------------------------------------------
local UserInputService = game:GetService("UserInputService")

local sentinelUIFolder = playerGui:WaitForChild("SentinelUI", 15)
if sentinelUIFolder then
	local themeModule = sentinelUIFolder:WaitForChild("Theme", 15)
	local shellModule = sentinelUIFolder:WaitForChild("Shell", 15)
	local commandPaletteModule = sentinelUIFolder:WaitForChild("CommandPalette", 15)
	local dashboardPageModule = sentinelUIFolder:WaitForChild("DashboardPage", 15)
	local playersPageModule = sentinelUIFolder:WaitForChild("PlayersPage", 15)
	local moderationPageModule = sentinelUIFolder:WaitForChild("ModerationPage", 15)
	local serverPageModule = sentinelUIFolder:WaitForChild("ServerPage", 15)

	if not (themeModule and shellModule and commandPaletteModule and dashboardPageModule and playersPageModule and moderationPageModule and serverPageModule) then
		warn("[Sentinel] One or more SentinelUI modules failed to load within 15s — UI shell not started.")
		return
	end

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
		local ServerPage = require(serverPageModule)

		Shell.Init()
		CommandPalette.Init()

		DashboardPage.Build(Shell.RegisterPage("Dashboard", "Dashboard", "🏠"), CommandPalette)
		PlayersPage.Build(Shell.RegisterPage("Players", "Players", "👥"))
		ModerationPage.Build(Shell.RegisterPage("Moderation", "Moderation", "🛡"))
		ServerPage.Build(Shell.RegisterPage("Server", "Server", "🌎"))

		-- Placeholder pages for sections not built yet — keeps the sidebar
		-- fully navigable while each section gets its real content later.
		for _, id in ipairs({ "Commands", "Economy", "Analytics", "Developer", "Settings" }) do
			local page = Shell.RegisterPage(id, id, "")
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, 0, 0, 30)
			label.Font = Theme.Font.Bold
			label.TextSize = 20
			label.TextColor3 = Theme.Colors.Text
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = id .. " — coming soon"
			label.Parent = page
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
