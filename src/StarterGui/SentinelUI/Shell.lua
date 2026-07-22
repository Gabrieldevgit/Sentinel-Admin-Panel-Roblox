--!strict
--[[
	Shell.lua

	Purpose:
		Builds Sentinel's main "Mission Control" frame: top bar (title +
		search/palette trigger), left sidebar navigation, a page container
		that swaps content per section, and a bottom status bar with live
		FPS/ping/memory/player-count. This is the dockable-window host that
		later pages (Dashboard, Players, Developer Tools, etc.) attach into.

	Responsibilities:
		- Create the ScreenGui + layout frames
		- Sidebar navigation with page switching
		- Status bar polling (client FPS via RenderStepped, ping via
		  GetNetworkPing, server memory/player count via GetServerStatsRemote)
		- Expose RegisterPage so each page module can plug in independently

	Dependencies:
		Theme.lua

	Public API:
		Shell.Init(): ScreenGui
		Shell.RegisterPage(id: string, displayName: string, icon: string): Frame
		Shell.ShowPage(id: string): ()
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local Shell = {}

local localPlayer = Players.LocalPlayer
local pages: { [string]: Frame } = {}
local navButtons: { [string]: TextButton } = {}
local currentPageId: string? = nil

local NAV_ITEMS = {
	{ Id = "Dashboard", Label = "Dashboard", Icon = "🏠" },
	{ Id = "Players", Label = "Players", Icon = "👥" },
	{ Id = "Moderation", Label = "Moderation", Icon = "🛡" },
	{ Id = "Commands", Label = "Commands", Icon = "📜" },
	{ Id = "Economy", Label = "Economy", Icon = "💰" },
	{ Id = "Server", Label = "Server", Icon = "🌎" },
	{ Id = "Analytics", Label = "Analytics", Icon = "📈" },
	{ Id = "Developer", Label = "Developer", Icon = "🔧" },
	{ Id = "Settings", Label = "Settings", Icon = "⚙" },
}

function Shell.ShowPage(id: string)
	if currentPageId == id then
		return
	end
	if currentPageId and pages[currentPageId] then
		pages[currentPageId].Visible = false
	end
	if currentPageId and navButtons[currentPageId] then
		navButtons[currentPageId].BackgroundTransparency = 1
		navButtons[currentPageId].TextColor3 = Theme.Colors.TextSecondary
	end

	currentPageId = id
	if pages[id] then
		pages[id].Visible = true
	end
	if navButtons[id] then
		navButtons[id].BackgroundTransparency = 0.85
		navButtons[id].TextColor3 = Theme.Colors.Text
	end
end

function Shell.RegisterPage(id: string, _displayName: string, _icon: string): Frame
	local page = Instance.new("Frame")
	page.Name = id .. "Page"
	page.Size = UDim2.new(1, 0, 1, 0)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = Shell.workspaceFrame
	pages[id] = page
	return page
end

function Shell.Init(): ScreenGui
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelShell"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Enabled = false -- toggled open via keybind/command, see init.client.lua
	screenGui.DisplayOrder = 50
	screenGui.Parent = playerGui
	Shell.screenGui = screenGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.new(0.5, 0, 0.5, 0)
	root.Size = UDim2.new(0.82, 0, 0.82, 0)
	root.BackgroundColor3 = Theme.Colors.Background
	root.BorderSizePixel = 0
	root.Parent = screenGui
	Theme.corner(root, Theme.Radius.L)
	Theme.stroke(root, Theme.Colors.Border, 1)
	Shell.root = root

	-- ------------------------------------------------------------------
	-- Top bar
	-- ------------------------------------------------------------------
	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0, 48)
	topBar.BackgroundColor3 = Theme.Colors.Surface
	topBar.BorderSizePixel = 0
	topBar.Parent = root
	Theme.corner(topBar, Theme.Radius.L)

	-- Square off the bottom corners of the top bar so it reads as a
	-- header rather than a floating pill.
	local topBarMask = Instance.new("Frame")
	topBarMask.Name = "BottomMask"
	topBarMask.Size = UDim2.new(1, 0, 0, 14)
	topBarMask.Position = UDim2.new(0, 0, 1, -14)
	topBarMask.BackgroundColor3 = Theme.Colors.Surface
	topBarMask.BorderSizePixel = 0
	topBarMask.ZIndex = 0
	topBarMask.Parent = topBar

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 16, 0, 0)
	title.Size = UDim2.new(0, 200, 1, 0)
	title.Font = Theme.Font.Bold
	title.TextSize = 18
	title.TextColor3 = Theme.Colors.Text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "🛡 Sentinel"
	title.Parent = topBar

	local searchButton = Instance.new("TextButton")
	searchButton.Name = "SearchButton"
	searchButton.AnchorPoint = Vector2.new(0.5, 0.5)
	searchButton.Position = UDim2.new(0.5, 0, 0.5, 0)
	searchButton.Size = UDim2.new(0, 320, 0, 32)
	searchButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	searchButton.AutoButtonColor = false
	searchButton.Font = Theme.Font.Regular
	searchButton.TextSize = 14
	searchButton.TextColor3 = Theme.Colors.TextSecondary
	searchButton.TextXAlignment = Enum.TextXAlignment.Left
	searchButton.Text = "  🔍  Search commands...   (Ctrl+Shift+P)"
	searchButton.Parent = topBar
	Theme.corner(searchButton, Theme.Radius.S)
	Shell.searchButton = searchButton

	local userLabel = Instance.new("TextLabel")
	userLabel.Name = "UserLabel"
	userLabel.BackgroundTransparency = 1
	userLabel.AnchorPoint = Vector2.new(1, 0.5)
	userLabel.Position = UDim2.new(1, -16, 0.5, 0)
	userLabel.Size = UDim2.new(0, 200, 1, 0)
	userLabel.Font = Theme.Font.Medium
	userLabel.TextSize = 14
	userLabel.TextColor3 = Theme.Colors.TextSecondary
	userLabel.TextXAlignment = Enum.TextXAlignment.Right
	userLabel.Text = localPlayer.Name .. "  ▾"
	userLabel.Parent = topBar

	-- ------------------------------------------------------------------
	-- Sidebar
	-- ------------------------------------------------------------------
	local sidebar = Instance.new("Frame")
	sidebar.Name = "Sidebar"
	sidebar.Position = UDim2.new(0, 0, 0, 48)
	sidebar.Size = UDim2.new(0, 190, 1, -48 - 28)
	sidebar.BackgroundColor3 = Theme.Colors.Surface
	sidebar.BorderSizePixel = 0
	sidebar.Parent = root

	local sidebarLayout = Instance.new("UIListLayout")
	sidebarLayout.Padding = UDim.new(0, 2)
	sidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	sidebarLayout.Parent = sidebar
	Theme.padding(sidebar, Theme.Spacing.S)

	for i, item in ipairs(NAV_ITEMS) do
		local button = Instance.new("TextButton")
		button.Name = item.Id .. "NavButton"
		button.LayoutOrder = i
		button.Size = UDim2.new(1, 0, 0, 36)
		button.BackgroundColor3 = Theme.Colors.Accent
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Font = Theme.Font.Medium
		button.TextSize = 14
		button.TextColor3 = Theme.Colors.TextSecondary
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.Text = ("   %s  %s"):format(item.Icon, item.Label)
		button.Parent = sidebar
		Theme.corner(button, Theme.Radius.S)

		button.MouseButton1Click:Connect(function()
			Shell.ShowPage(item.Id)
		end)
		navButtons[item.Id] = button
	end

	-- ------------------------------------------------------------------
	-- Main workspace (page container)
	-- ------------------------------------------------------------------
	local workspaceFrame = Instance.new("Frame")
	workspaceFrame.Name = "Workspace"
	workspaceFrame.Position = UDim2.new(0, 190, 0, 48)
	workspaceFrame.Size = UDim2.new(1, -190, 1, -48 - 28)
	workspaceFrame.BackgroundTransparency = 1
	workspaceFrame.Parent = root
	Theme.padding(workspaceFrame, Theme.Spacing.L)
	Shell.workspaceFrame = workspaceFrame

	-- ------------------------------------------------------------------
	-- Status bar
	-- ------------------------------------------------------------------
	local statusBar = Instance.new("Frame")
	statusBar.Name = "StatusBar"
	statusBar.Position = UDim2.new(0, 0, 1, -28)
	statusBar.Size = UDim2.new(1, 0, 0, 28)
	statusBar.BackgroundColor3 = Theme.Colors.Surface
	statusBar.BorderSizePixel = 0
	statusBar.Parent = root
	Theme.corner(statusBar, Theme.Radius.L)

	local statusMask = Instance.new("Frame")
	statusMask.Size = UDim2.new(1, 0, 0, 14)
	statusMask.BackgroundColor3 = Theme.Colors.Surface
	statusMask.BorderSizePixel = 0
	statusMask.ZIndex = 0
	statusMask.Parent = statusBar

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.BackgroundTransparency = 1
	statusLabel.Position = UDim2.new(0, 16, 0, 0)
	statusLabel.Size = UDim2.new(1, -32, 1, 0)
	statusLabel.Font = Theme.Font.Regular
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = Theme.Colors.TextSecondary
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Text = "FPS: -- | Ping: -- | Memory: -- MB | Players: --"
	statusLabel.Parent = statusBar
	Shell.statusLabel = statusLabel

	-- FPS (client-side, via RenderStepped delta)
	local frameCount = 0
	local fps = 0
	RunService.RenderStepped:Connect(function()
		frameCount += 1
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			fps = frameCount
			frameCount = 0
		end
	end)

	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getServerStatsRemote = SentinelShared:WaitForChild("GetServerStatsRemote", 15) :: RemoteFunction?

	task.spawn(function()
		while true do
			local ping = math.floor(localPlayer:GetNetworkPing() * 1000)
			local memory, playerCount = "--", "--"
			if getServerStatsRemote then
				local ok, stats = pcall(function()
					return getServerStatsRemote:InvokeServer()
				end)
				if ok and stats then
					memory = tostring(stats.MemoryMb)
					playerCount = tostring(stats.PlayerCount)
				end
			end
			statusLabel.Text = ("FPS: %d | Ping: %dms | Memory: %s MB | Players: %s"):format(fps, ping, memory, playerCount)
			task.wait(2)
		end
	end)

	-- NOTE: does NOT call Shell.ShowPage("Dashboard") here. Pages are
	-- registered by the caller (init.client.lua) AFTER Init() returns, so
	-- calling ShowPage this early would set currentPageId to "Dashboard"
	-- before any page frame exists — the real Dashboard page registered
	-- later would then silently stay hidden (ShowPage's no-op guard for
	-- "already the current page") until the user switched tabs and back.
	-- The caller is responsible for calling ShowPage once all pages (and
	-- placeholders) are registered.

	return screenGui
end

function Shell.Toggle()
	if Shell.screenGui then
		Shell.screenGui.Enabled = not Shell.screenGui.Enabled
	end
end

return Shell
