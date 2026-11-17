--!strict
--[[
	Shell.lua (UI redesign)

	Purpose:
		Sentinel's main window.

		Title bar   clock, brand, minimize / close; drag the bar to move
		Nav bar     one tab per section (animated underline), then search,
		            notifications, settings and the signed-in user
		Sub menu    the pages of the active section (only when it has more
		            than one), with an accent marker on the current page
		Workspace   the page; new pages slide in
		Status bar  players, uptime, memory, ping, FPS, version

		Sections group the pages so 14 pages fit a top bar:
			Dashboard | Players | Moderation (+Ranks) | Commands (+Library)
			| Server (+Cross-Server, Economy) | Insights (Analytics,
			Developer) | System (Settings, Appearance, Notifications; opened
			from the gear and bell icons)

		Animations (open / close scale, page slide, tab underline, hover)
		go through Theme.tween, so the Animations preference switches them
		all off. Panel size follows the Scale preference (UIScale).

	Stable names for Studio MCP input: Root.NavBar.Tabs.<Section>Tab,
	Root.SubNav.<PageId>NavButton, Root.NavBar.Right.{SearchButton,
	BellButton, GearButton}, Root.TopBar.{MinimizeButton, CloseButton}.

	Public API:
		Shell.Init(): ScreenGui
		Shell.RegisterPage(id, displayName, icon): Frame
		Shell.ShowPage(id), Shell.GetPageIds(), Shell.SetPageVisible(id, visible)
		Shell.Toggle(), Shell.Open(), Shell.Close(), Shell.IsOpen()
		Shell.ApplyPrefs(panelPrefs)   -- scale; call after Theme.Apply/Retint
		Shell.searchButton, Shell.workspaceFrame, Shell.root, Shell.screenGui
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local Shell = {}

local localPlayer = Players.LocalPlayer
local pages: { [string]: Frame } = {}
local navButtons: { [string]: TextButton } = {}
local tabButtons: { [string]: TextButton } = {}
local hiddenPages: { [string]: boolean } = {}
local currentPageId: string? = nil
local baseScale = 1

local SECTIONS = {
	{ Id = "Dashboard", Label = "Dashboard", Icon = "🏠", Pages = { { Id = "Dashboard", Label = "Dashboard", Icon = "🏠" } } },
	{ Id = "Players", Label = "Players", Icon = "👥", Pages = { { Id = "Players", Label = "Players", Icon = "👥" } } },
	{
		Id = "Moderation",
		Label = "Moderation",
		Icon = "🛡",
		Pages = {
			{ Id = "Moderation", Label = "Moderation", Icon = "🛡" },
			{ Id = "Ranks", Label = "Ranks", Icon = "👑" },
		},
	},
	{
		Id = "Commands",
		Label = "Commands",
		Icon = "📜",
		Pages = {
			{ Id = "Commands", Label = "Commands", Icon = "📜" },
			{ Id = "Library", Label = "Library", Icon = "📚" },
		},
	},
	{
		Id = "Server",
		Label = "Server",
		Icon = "🌎",
		Pages = {
			{ Id = "Server", Label = "This server", Icon = "🌎" },
			{ Id = "CrossServer", Label = "Cross-Server", Icon = "🌐" },
			{ Id = "Economy", Label = "Economy", Icon = "💰" },
		},
	},
	{
		Id = "Insights",
		Label = "Insights",
		Icon = "📈",
		Pages = {
			{ Id = "Analytics", Label = "Analytics", Icon = "📈" },
			{ Id = "Developer", Label = "Developer", Icon = "🔧" },
		},
	},
	{
		Id = "System",
		Label = "System",
		Icon = "⚙",
		IconOnly = true, -- reached from the gear / bell icons
		Pages = {
			{ Id = "Settings", Label = "Settings", Icon = "⚙" },
			{ Id = "Appearance", Label = "Appearance", Icon = "🎨" },
			{ Id = "Notifications", Label = "Notifications", Icon = "🔔" },
		},
	},
}

local sectionOfPage: { [string]: any } = {}
for _, section in ipairs(SECTIONS) do
	for _, page in ipairs(section.Pages) do
		sectionOfPage[page.Id] = section
	end
end

function Shell.GetPageIds(): { string }
	local ids = {}
	for _, section in ipairs(SECTIONS) do
		for _, page in ipairs(section.Pages) do
			table.insert(ids, page.Id)
		end
	end
	return ids
end

local function visiblePages(section: any): { any }
	local list = {}
	for _, page in ipairs(section.Pages) do
		if not hiddenPages[page.Id] then
			table.insert(list, page)
		end
	end
	return list
end

-- Colours and sizes that depend on which page / section is active.
local function refreshNav()
	local activeSection = currentPageId and sectionOfPage[currentPageId]
	for _, section in ipairs(SECTIONS) do
		local tab = tabButtons[section.Id]
		if tab then
			local active = section == activeSection
			tab.Visible = #visiblePages(section) > 0
			Theme.tween(tab, Theme.Motion.Fast, { TextColor3 = if active then Theme.Colors.Text else Theme.Colors.TextSecondary })
			local underline = tab:FindFirstChild("Underline") :: Frame?
			if underline then
				underline.BackgroundColor3 = Theme.Colors.Accent
				Theme.tween(underline, Theme.Motion.Normal, { Size = UDim2.new(if active then 1 else 0, 0, 0, 2) })
			end
		end
		for _, page in ipairs(section.Pages) do
			local button = navButtons[page.Id]
			if button then
				local current = page.Id == currentPageId
				button.Visible = section == activeSection and not hiddenPages[page.Id]
				Theme.tween(button, Theme.Motion.Fast, {
					BackgroundTransparency = if current then 0 else 1,
					TextColor3 = if current then Theme.Colors.Text else Theme.Colors.TextSecondary,
				})
				button.BackgroundColor3 = Theme.Colors.SurfaceRaised
				local marker = button:FindFirstChild("Marker") :: Frame?
				if marker then
					marker.BackgroundColor3 = Theme.Colors.Accent
					Theme.tween(marker, Theme.Motion.Normal, { Size = UDim2.new(0, 3, if current then 0.6 else 0, 0) })
				end
			end
		end
	end
	-- The sub menu only shows for sections with several pages.
	local subNav = Shell.subNav
	local workspaceFrame = Shell.workspaceFrame
	if subNav and workspaceFrame then
		local wide = activeSection ~= nil and #visiblePages(activeSection) > 1
		subNav.Visible = wide
		local left = if wide then 176 else 0
		workspaceFrame.Position = UDim2.new(0, left, 0, 82)
		workspaceFrame.Size = UDim2.new(1, -left, 1, -82 - 28)
	end
end

-- Hides/shows a page's navigation entry (page visibility permissions). The
-- server is still the authority: hidden pages' remotes stay permission-
-- checked; this only keeps the navigation tidy.
function Shell.SetPageVisible(id: string, visible: boolean)
	hiddenPages[id] = if visible then nil else true
	if not visible and currentPageId == id and id ~= "Dashboard" then
		Shell.ShowPage("Dashboard")
	else
		refreshNav()
	end
end

function Shell.ShowPage(id: string)
	if currentPageId == id or not pages[id] then
		if currentPageId == id then
			refreshNav()
		end
		return
	end
	if currentPageId and pages[currentPageId] then
		pages[currentPageId].Visible = false
	end
	currentPageId = id
	local page = pages[id]
	page.Visible = true
	-- Slide the new page up into place.
	page.Position = UDim2.new(0, 0, 0, 14)
	Theme.tween(page, Theme.Motion.Normal, { Position = UDim2.new(0, 0, 0, 0) })
	refreshNav()
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

local function hover(button: GuiButton, onEnter: () -> (), onLeave: () -> ())
	button.MouseEnter:Connect(onEnter)
	button.MouseLeave:Connect(onLeave)
end

local function iconButton(parent: Instance, name: string, text: string, order: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = order
	button.Size = UDim2.new(0, 30, 0, 30)
	button.BackgroundColor3 = Theme.Colors.SurfaceRaised
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = Theme.Font.Medium
	button.TextSize = 15
	button.TextColor3 = Theme.Colors.TextSecondary
	button.Text = text
	button.Parent = parent
	Theme.corner(button, Theme.Radius.S)
	hover(button, function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 0, TextColor3 = Theme.Colors.Text })
	end, function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 1, TextColor3 = Theme.Colors.TextSecondary })
	end)
	return button
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
	root.Size = UDim2.new(0.8, 0, 0.82, 0)
	root.BackgroundColor3 = Theme.Colors.Background
	root.BorderSizePixel = 0
	root.Parent = screenGui
	Theme.corner(root, Theme.Radius.M)
	Theme.stroke(root, Theme.Colors.Border, 1)
	Shell.root = root

	local uiScale = Instance.new("UIScale")
	uiScale.Name = "Scale"
	uiScale.Scale = baseScale
	uiScale.Parent = root
	Shell.uiScale = uiScale

	-- ------------------------------------------------------------------
	-- Title bar
	-- ------------------------------------------------------------------
	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0, 40)
	topBar.BackgroundColor3 = Theme.Colors.Surface
	topBar.BorderSizePixel = 0
	topBar.Parent = root
	-- Rounded like the window, squared off at the bottom by a mask.
	Theme.corner(topBar, Theme.Radius.M)
	local topMask = Instance.new("Frame")
	topMask.Name = "BottomMask"
	topMask.Position = UDim2.new(0, 0, 1, -12)
	topMask.Size = UDim2.new(1, 0, 0, 12)
	topMask.BackgroundColor3 = Theme.Colors.Surface
	topMask.BorderSizePixel = 0
	topMask.ZIndex = 0
	topMask.Parent = topBar

	local clock = Instance.new("TextLabel")
	clock.Name = "Clock"
	clock.BackgroundTransparency = 1
	clock.Position = UDim2.new(0, 14, 0, 0)
	clock.Size = UDim2.new(0, 160, 1, 0)
	clock.Font = Theme.Font.Medium
	clock.TextSize = 13
	clock.TextColor3 = Theme.Colors.TextSecondary
	clock.TextXAlignment = Enum.TextXAlignment.Left
	clock.Text = ""
	clock.Parent = topBar

	local brand = Instance.new("TextLabel")
	brand.Name = "Title"
	brand.BackgroundTransparency = 1
	brand.AnchorPoint = Vector2.new(0.5, 0)
	brand.Position = UDim2.new(0.5, 0, 0, 0)
	brand.Size = UDim2.new(0, 200, 1, 0)
	brand.Font = Theme.Font.Black
	brand.TextSize = 15
	brand.TextColor3 = Theme.Colors.Text
	brand.Text = "🛡  SENTINEL"
	brand.Parent = topBar

	local windowButtons = Instance.new("Frame")
	windowButtons.Name = "WindowButtons"
	windowButtons.BackgroundTransparency = 1
	windowButtons.AnchorPoint = Vector2.new(1, 0.5)
	windowButtons.Position = UDim2.new(1, -8, 0.5, 0)
	windowButtons.Size = UDim2.new(0, 64, 0, 30)
	windowButtons.Parent = topBar
	local windowLayout = Instance.new("UIListLayout")
	windowLayout.FillDirection = Enum.FillDirection.Horizontal
	windowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	windowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	windowLayout.Padding = UDim.new(0, 4)
	windowLayout.Parent = windowButtons

	local minimizeButton = iconButton(windowButtons, "MinimizeButton", "-", 1)
	minimizeButton.TextSize = 20
	local closeButton = iconButton(windowButtons, "CloseButton", "X", 2)
	closeButton.Font = Theme.Font.Bold
	closeButton.TextSize = 13
	hover(closeButton, function()
		Theme.tween(closeButton, Theme.Motion.Fast, { BackgroundColor3 = Theme.Colors.Error })
	end, function()
		Theme.tween(closeButton, Theme.Motion.Fast, { BackgroundColor3 = Theme.Colors.SurfaceRaised })
	end)
	closeButton.MouseButton1Click:Connect(function()
		Shell.Close()
	end)

	-- ------------------------------------------------------------------
	-- Navigation bar: section tabs, then search / bell / gear / user
	-- ------------------------------------------------------------------
	local navBar = Instance.new("Frame")
	navBar.Name = "NavBar"
	navBar.Position = UDim2.new(0, 0, 0, 40)
	navBar.Size = UDim2.new(1, 0, 0, 42)
	navBar.BackgroundColor3 = Theme.Colors.Surface
	navBar.BorderSizePixel = 0
	navBar.Parent = root

	local navLine = Instance.new("Frame")
	navLine.Name = "Line"
	navLine.AnchorPoint = Vector2.new(0, 1)
	navLine.Position = UDim2.new(0, 0, 1, 0)
	navLine.Size = UDim2.new(1, 0, 0, 1)
	navLine.BackgroundColor3 = Theme.Colors.Border
	navLine.BorderSizePixel = 0
	navLine.Parent = navBar

	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.new(0, 8, 0, 0)
	tabs.Size = UDim2.new(1, -330, 1, 0)
	tabs.ClipsDescendants = true
	tabs.Parent = navBar
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Padding = UDim.new(0, 2)
	tabLayout.Parent = tabs

	for i, section in ipairs(SECTIONS) do
		if section.IconOnly then
			continue
		end
		local tab = Instance.new("TextButton")
		tab.Name = section.Id .. "Tab"
		tab.LayoutOrder = i
		tab.AutomaticSize = Enum.AutomaticSize.X
		tab.Size = UDim2.new(0, 0, 1, 0)
		tab.BackgroundTransparency = 1
		tab.AutoButtonColor = false
		tab.BorderSizePixel = 0
		tab.Font = Theme.Font.Medium
		tab.TextSize = 14
		tab.TextColor3 = Theme.Colors.TextSecondary
		tab.Text = ("%s  %s"):format(section.Icon, section.Label)
		tab.Parent = tabs
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 12)
		pad.PaddingRight = UDim.new(0, 12)
		pad.Parent = tab

		local underline = Instance.new("Frame")
		underline.Name = "Underline"
		underline.AnchorPoint = Vector2.new(0.5, 1)
		underline.Position = UDim2.new(0.5, 0, 1, 0)
		underline.Size = UDim2.new(0, 0, 0, 2)
		underline.BackgroundColor3 = Theme.Colors.Accent
		underline.BorderSizePixel = 0
		underline.Parent = tab

		hover(tab, function()
			if sectionOfPage[currentPageId or ""] ~= section then
				Theme.tween(tab, Theme.Motion.Fast, { TextColor3 = Theme.Colors.Text })
			end
		end, function()
			if sectionOfPage[currentPageId or ""] ~= section then
				Theme.tween(tab, Theme.Motion.Fast, { TextColor3 = Theme.Colors.TextSecondary })
			end
		end)
		tab.MouseButton1Click:Connect(function()
			if sectionOfPage[currentPageId or ""] == section then
				return
			end
			local first = visiblePages(section)[1]
			if first then
				Shell.ShowPage(first.Id)
			end
		end)
		tabButtons[section.Id] = tab
	end

	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.new(1, -10, 0.5, 0)
	right.Size = UDim2.new(0, 310, 0, 30)
	right.Parent = navBar
	local rightLayout = Instance.new("UIListLayout")
	rightLayout.FillDirection = Enum.FillDirection.Horizontal
	rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rightLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightLayout.Padding = UDim.new(0, 6)
	rightLayout.Parent = right

	local searchButton = Instance.new("TextButton")
	searchButton.Name = "SearchButton"
	searchButton.LayoutOrder = 1
	searchButton.Size = UDim2.new(0, 96, 0, 30)
	searchButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	searchButton.AutoButtonColor = false
	searchButton.BorderSizePixel = 0
	searchButton.Font = Theme.Font.Regular
	searchButton.TextSize = 13
	searchButton.TextColor3 = Theme.Colors.TextSecondary
	searchButton.Text = "🔍  Search"
	searchButton.Parent = right
	Theme.corner(searchButton, Theme.Radius.S)
	hover(searchButton, function()
		Theme.tween(searchButton, Theme.Motion.Fast, { TextColor3 = Theme.Colors.Text })
	end, function()
		Theme.tween(searchButton, Theme.Motion.Fast, { TextColor3 = Theme.Colors.TextSecondary })
	end)
	Shell.searchButton = searchButton

	local bellButton = iconButton(right, "BellButton", "🔔", 2)
	bellButton.MouseButton1Click:Connect(function()
		Shell.ShowPage("Notifications")
	end)
	local gearButton = iconButton(right, "GearButton", "⚙", 3)
	gearButton.MouseButton1Click:Connect(function()
		Shell.ShowPage("Settings")
	end)

	local userChip = Instance.new("Frame")
	userChip.Name = "User"
	userChip.LayoutOrder = 4
	userChip.BackgroundTransparency = 1
	userChip.Size = UDim2.new(0, 132, 0, 30)
	userChip.Parent = right
	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.Size = UDim2.new(0, 26, 0, 26)
	avatar.Position = UDim2.new(0, 0, 0.5, -13)
	avatar.BackgroundColor3 = Theme.Colors.SurfaceRaised
	avatar.BorderSizePixel = 0
	avatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(localPlayer.UserId)
	avatar.Parent = userChip
	Theme.corner(avatar, UDim.new(1, 0))
	Theme.stroke(avatar, Theme.Colors.Accent, 1)
	local userLabel = Instance.new("TextLabel")
	userLabel.Name = "UserLabel"
	userLabel.BackgroundTransparency = 1
	userLabel.Position = UDim2.new(0, 34, 0, 0)
	userLabel.Size = UDim2.new(1, -34, 1, 0)
	userLabel.Font = Theme.Font.Medium
	userLabel.TextSize = 13
	userLabel.TextColor3 = Theme.Colors.Text
	userLabel.TextXAlignment = Enum.TextXAlignment.Left
	userLabel.TextTruncate = Enum.TextTruncate.AtEnd
	userLabel.Text = localPlayer.DisplayName
	userLabel.Parent = userChip

	-- ------------------------------------------------------------------
	-- Sub menu (pages of the active section)
	-- ------------------------------------------------------------------
	local subNav = Instance.new("ScrollingFrame")
	subNav.Name = "SubNav"
	subNav.ScrollBarThickness = 3
	subNav.ScrollBarImageColor3 = Theme.Colors.Border
	subNav.AutomaticCanvasSize = Enum.AutomaticSize.Y
	subNav.CanvasSize = UDim2.new()
	subNav.ScrollingDirection = Enum.ScrollingDirection.Y
	subNav.Position = UDim2.new(0, 0, 0, 82)
	subNav.Size = UDim2.new(0, 176, 1, -82 - 28)
	subNav.BackgroundColor3 = Theme.Colors.Surface
	subNav.BorderSizePixel = 0
	subNav.Visible = false
	subNav.Parent = root
	Shell.subNav = subNav
	local subLayout = Instance.new("UIListLayout")
	subLayout.Padding = UDim.new(0, 2)
	subLayout.SortOrder = Enum.SortOrder.LayoutOrder
	subLayout.Parent = subNav
	Theme.padding(subNav, Theme.Spacing.S)

	local order = 0
	for _, section in ipairs(SECTIONS) do
		for _, page in ipairs(section.Pages) do
			order += 1
			local button = Instance.new("TextButton")
			button.Name = page.Id .. "NavButton"
			button.LayoutOrder = order
			button.Size = UDim2.new(1, 0, 0, 38)
			button.BackgroundColor3 = Theme.Colors.SurfaceRaised
			button.BackgroundTransparency = 1
			button.AutoButtonColor = false
			button.BorderSizePixel = 0
			button.Font = Theme.Font.Medium
			button.TextSize = 14
			button.TextColor3 = Theme.Colors.TextSecondary
			button.TextXAlignment = Enum.TextXAlignment.Left
			button.Text = ("    %s   %s"):format(page.Icon, page.Label)
			button.Visible = false
			button.Parent = subNav
			Theme.corner(button, Theme.Radius.S)

			local marker = Instance.new("Frame")
			marker.Name = "Marker"
			marker.AnchorPoint = Vector2.new(0, 0.5)
			marker.Position = UDim2.new(0, 0, 0.5, 0)
			marker.Size = UDim2.new(0, 3, 0, 0)
			marker.BackgroundColor3 = Theme.Colors.Accent
			marker.BorderSizePixel = 0
			marker.Parent = button
			Theme.corner(marker, UDim.new(1, 0))

			hover(button, function()
				if currentPageId ~= page.Id then
					Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 0.5, TextColor3 = Theme.Colors.Text })
				end
			end, function()
				if currentPageId ~= page.Id then
					Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 1, TextColor3 = Theme.Colors.TextSecondary })
				end
			end)
			button.MouseButton1Click:Connect(function()
				Shell.ShowPage(page.Id)
			end)
			navButtons[page.Id] = button
		end
	end

	-- ------------------------------------------------------------------
	-- Main workspace (page container)
	-- ------------------------------------------------------------------
	local workspaceFrame = Instance.new("Frame")
	workspaceFrame.Name = "Workspace"
	workspaceFrame.Position = UDim2.new(0, 0, 0, 82)
	workspaceFrame.Size = UDim2.new(1, 0, 1, -82 - 28)
	workspaceFrame.BackgroundTransparency = 1
	workspaceFrame.ClipsDescendants = true
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
	Theme.corner(statusBar, Theme.Radius.M)
	local statusMask = Instance.new("Frame")
	statusMask.Name = "TopMask"
	statusMask.Size = UDim2.new(1, 0, 0, 12)
	statusMask.BackgroundColor3 = Theme.Colors.Surface
	statusMask.BorderSizePixel = 0
	statusMask.ZIndex = 0
	statusMask.Parent = statusBar

	local function statusText(name: string, alignment: Enum.TextXAlignment): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Position = UDim2.new(0, 14, 0, 0)
		l.Size = UDim2.new(1, -44, 1, 0)
		l.Font = Theme.Font.Regular
		l.TextSize = 12
		l.TextColor3 = Theme.Colors.TextSecondary
		l.TextXAlignment = alignment
		l.RichText = true
		l.Text = ""
		l.Parent = statusBar
		return l
	end
	local statusLabel = statusText("StatusLabel", Enum.TextXAlignment.Left)
	local statusRight = statusText("StatusRight", Enum.TextXAlignment.Right)
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
			clock.Text = "🕒  " .. (os.date("%I:%M %p") :: string):gsub("^0", "")
		end
	end)

	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getServerStatsRemote = SentinelShared:WaitForChild("GetServerStatsRemote", 15) :: RemoteFunction?

	local function value(text: string): string
		local c = Theme.Colors.Text
		return ('<font color="rgb(%d,%d,%d)">%s</font>'):format(c.R * 255, c.G * 255, c.B * 255, text)
	end

	task.spawn(function()
		while true do
			if screenGui.Enabled then
				local ping = math.floor(localPlayer:GetNetworkPing() * 1000)
				local memory, playerCount, uptime = "--", "--", "--"
				if getServerStatsRemote then
					local ok, stats = pcall(function()
						return getServerStatsRemote:InvokeServer()
					end)
					if ok and stats then
						memory = tostring(stats.MemoryMb)
						playerCount = ("%s/%d"):format(tostring(stats.PlayerCount), Players.MaxPlayers)
						local s = tonumber(stats.UptimeSeconds) or 0
						uptime = ("%02d:%02d:%02d"):format(math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
					end
				end
				statusLabel.Text = ("Players: %s     Uptime: %s"):format(value(playerCount), value(uptime))
				statusRight.Text = ("Memory: %s     Ping: %s     FPS: %s     Version: %s"):format(
					value(memory .. " MB"),
					value(ping .. " ms"),
					value(tostring(fps)),
					value(tostring(game.PlaceVersion))
				)
			end
			task.wait(2)
		end
	end)

	-- ------------------------------------------------------------------
	-- Resize handle (bottom-right corner)
	-- ------------------------------------------------------------------
	local resizeHandle = Instance.new("ImageButton")
	resizeHandle.Name = "ResizeHandle"
	resizeHandle.AnchorPoint = Vector2.new(1, 1)
	resizeHandle.Position = UDim2.new(1, -4, 1, -4)
	resizeHandle.Size = UDim2.new(0, 14, 0, 14)
	resizeHandle.BackgroundTransparency = 1
	resizeHandle.BorderSizePixel = 0
	resizeHandle.Image = "rbxasset://textures/ui/GuiImageResize.png"
	resizeHandle.ImageColor3 = Theme.Colors.TextSecondary
	resizeHandle.ScaleType = Enum.ScaleType.Fit
	resizeHandle.ZIndex = 5
	resizeHandle.Parent = root

	-- ------------------------------------------------------------------
	-- Window management state
	-- ------------------------------------------------------------------
	local isMinimized = false
	local fullSizeBeforeMinimize = nil
	local isDragging = false
	local isResizing = false

	-- Minimize / restore: collapse to the title bar.
	minimizeButton.MouseButton1Click:Connect(function()
		isMinimized = not isMinimized
		local show = not isMinimized
		if isMinimized then
			fullSizeBeforeMinimize = root.Size
		end
		navBar.Visible = show
		workspaceFrame.Visible = show
		statusBar.Visible = show
		resizeHandle.Visible = show
		subNav.Visible = false
		if isMinimized then
			Theme.tween(root, Theme.Motion.Normal, { Size = UDim2.new(root.Size.X.Scale, root.Size.X.Offset, 0, 40) })
			minimizeButton.Text = "+"
		else
			if fullSizeBeforeMinimize then
				Theme.tween(root, Theme.Motion.Normal, { Size = fullSizeBeforeMinimize })
			end
			minimizeButton.Text = "-"
			refreshNav()
		end
	end)

	-- ------------------------------------------------------------------
	-- Drag reposition via the whole top bar
	-- ------------------------------------------------------------------
	-- The handle spans the full top bar but sits at ZIndex 0, so the search,
	-- minimize and close buttons (ZIndex 1, sibling ZIndex behaviour) stay on
	-- top and keep their clicks; every other spot on the bar starts a drag.
	-- It used to cover only the 200px title area, which at smaller window
	-- sizes sat underneath Roblox's own top-bar buttons (this ScreenGui
	-- ignores the GUI inset) and so could never be grabbed.
	local dragHandle = Instance.new("TextButton")
	dragHandle.Name = "DragHandle"
	dragHandle.Size = UDim2.new(1, 0, 1, 0)
	dragHandle.BackgroundTransparency = 1
	dragHandle.Text = ""
	dragHandle.AutoButtonColor = false
	dragHandle.ZIndex = 0
	dragHandle.Parent = topBar

	-- Keep the window's top bar on-screen and below Roblox's top bar.
	-- Coordinate spaces: AbsolutePosition and InputObject.Position are both
	-- measured from just below Roblox's top bar, while this ScreenGui ignores
	-- the inset, so its Position offsets start at the very top of the screen
	-- (screenGui.AbsolutePosition is (0, -inset)). All maths below happens in
	-- absolute space; placeAt converts back to a Position offset. root's
	-- AnchorPoint is 0.5, 0.5, so Position is the window's centre.
	local TOP_BAR_HEIGHT = 40
	local MIN_VISIBLE_X = 120
	local function clampCentre(centre: Vector2): Vector2
		local guiOrigin = screenGui.AbsolutePosition
		local viewport = screenGui.AbsoluteSize
		local size = root.AbsoluteSize
		local visibleTop = guiOrigin.Y + GuiService:GetGuiInset().Y
		local halfW, halfH = size.X / 2, size.Y / 2
		local minX = guiOrigin.X + MIN_VISIBLE_X - halfW
		local maxX = guiOrigin.X + viewport.X - MIN_VISIBLE_X + halfW
		local minY = visibleTop + halfH
		local maxY = math.max(minY, guiOrigin.Y + viewport.Y - TOP_BAR_HEIGHT + halfH)
		return Vector2.new(math.clamp(centre.X, minX, maxX), math.clamp(centre.Y, minY, maxY))
	end
	local function currentCentre(): Vector2
		return root.AbsolutePosition + root.AbsoluteSize / 2
	end
	local function toOffset(absolute: Vector2): UDim2
		local local_ = absolute - screenGui.AbsolutePosition
		return UDim2.fromOffset(math.round(local_.X), math.round(local_.Y))
	end
	local function placeAt(centre: Vector2)
		root.Position = toOffset(clampCentre(centre))
	end
	Shell.clampIntoView = function()
		placeAt(currentCentre())
	end
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(Shell.clampIntoView)
	screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screenGui.Enabled then
			task.defer(Shell.clampIntoView)
		end
	end)

	-- Known issue #2 (PHASE7-KNOWN-ISSUES.md): GetMouseDelta() was erratic
	-- for UI drag/resize. Deltas are computed from the absolute pointer
	-- position captured at drag/resize start. Both the start and the moves
	-- come from InputObject.Position, so they share one coordinate space
	-- (MouseButton1Down's x/y include the GUI inset, which made the window
	-- jump by the inset height on the first move).
	local dragStartPointer: Vector2? = nil
	local dragStartCentre: Vector2? = nil
	local resizeStartPointer: Vector2? = nil
	local resizeStartSize: Vector2? = nil
	local activeInput: InputObject? = nil

	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end
	local function pointerOf(input: InputObject): Vector2
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	dragHandle.InputBegan:Connect(function(input: InputObject)
		if not isPress(input) then
			return
		end
		isDragging = true
		activeInput = input
		dragStartPointer = pointerOf(input)
		dragStartCentre = currentCentre()
	end)

	resizeHandle.InputBegan:Connect(function(input: InputObject)
		if not isPress(input) then
			return
		end
		isResizing = true
		activeInput = input
		resizeStartPointer = pointerOf(input)
		resizeStartSize = root.AbsoluteSize
		-- Pin the top-left corner while resizing so only the bottom-right
		-- edge follows the pointer (root is centre-anchored).
		local topLeft = root.AbsolutePosition
		root.AnchorPoint = Vector2.new(0, 0)
		root.Position = toOffset(topLeft)
		-- AbsoluteSize includes the UIScale; Size offsets don't.
		root.Size = UDim2.fromOffset(resizeStartSize.X / uiScale.Scale, resizeStartSize.Y / uiScale.Scale)
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if not isPress(input) then
			return
		end
		if isResizing then
			-- Restore centre anchoring so dragging/clamping keep working.
			local centre = currentCentre()
			root.AnchorPoint = Vector2.new(0.5, 0.5)
			placeAt(centre)
		end
		isDragging = false
		isResizing = false
		activeInput = nil
		dragStartPointer = nil
		resizeStartPointer = nil
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local isMouseMove = input.UserInputType == Enum.UserInputType.MouseMovement
		local isTouchMove = input.UserInputType == Enum.UserInputType.Touch and input == activeInput
		if not (isMouseMove or isTouchMove) then
			return
		end
		local pointer = pointerOf(input)
		if isDragging and dragStartPointer and dragStartCentre then
			placeAt(dragStartCentre + (pointer - dragStartPointer))
		elseif isResizing and resizeStartPointer and resizeStartSize then
			local delta = pointer - resizeStartPointer
			root.Size = UDim2.fromOffset(
				math.max(760, resizeStartSize.X + delta.X) / uiScale.Scale,
				math.max(420, resizeStartSize.Y + delta.Y) / uiScale.Scale
			)
		end
	end)

	-- NOTE: does NOT call Shell.ShowPage("Dashboard") here. Pages are
	-- registered by the caller (init.client.lua) AFTER Init() returns; the
	-- caller shows the first page once every page exists.

	return screenGui
end

-- Panel prefs that the shell itself owns (size). Colours are handled by
-- Theme.Apply + Theme.Retint in init.client; this re-applies the active
-- states with the new palette.
function Shell.ApplyPrefs(panel: any)
	baseScale = if panel and type(panel.Scale) == "number" then panel.Scale else 1
	if Shell.uiScale then
		Shell.uiScale.Scale = baseScale
	end
	if Shell.screenGui then
		refreshNav()
		if Shell.clampIntoView and Shell.screenGui.Enabled then
			task.defer(Shell.clampIntoView)
		end
	end
end

local closing = false

function Shell.IsOpen(): boolean
	return Shell.screenGui ~= nil and Shell.screenGui.Enabled and not closing
end

function Shell.Open()
	local screenGui, uiScale = Shell.screenGui, Shell.uiScale
	if not screenGui then
		return
	end
	closing = false
	screenGui.Enabled = true
	if uiScale then
		uiScale.Scale = baseScale * 0.94
		Theme.tween(uiScale, Theme.Motion.Spring, { Scale = baseScale })
	end
	if currentPageId then
		refreshNav()
	end
end

function Shell.Close()
	local screenGui, uiScale = Shell.screenGui, Shell.uiScale
	if not screenGui or not screenGui.Enabled or closing then
		return
	end
	if not uiScale or not Theme.Animations then
		screenGui.Enabled = false
		return
	end
	closing = true
	local tween = Theme.tween(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = baseScale * 0.94 })
	task.delay(0.12, function()
		if closing then
			closing = false
			screenGui.Enabled = false
			uiScale.Scale = baseScale
		end
		if tween then
			tween:Cancel()
		end
	end)
end

function Shell.Toggle()
	if Shell.IsOpen() then
		Shell.Close()
	else
		Shell.Open()
	end
end

return Shell
