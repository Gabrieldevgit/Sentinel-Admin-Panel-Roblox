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
	SoundButton, BellButton, GearButton}, Root.TopBar.{MinimizeButton, CloseButton}.

	Public API:
		Shell.Init(): ScreenGui
		Shell.RegisterPage(id, displayName, icon): Frame
		Shell.ShowPage(id), Shell.GetPageIds(), Shell.SetPageVisible(id, visible)
		Shell.Toggle(), Shell.Open(), Shell.Close(), Shell.IsOpen()
		Shell.ApplyPrefs(panelPrefs, layoutPrefs?)   -- scale + W09 layout; after Theme.Apply/Retint
		Shell.Cycle(dir), Shell.GetCurrentPage(), Shell.buildPinned()
		Shell.searchButton, Shell.workspaceFrame, Shell.root, Shell.screenGui
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Icons = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Icons"))
local UIPrefs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("UIPrefs"))

local Shell = {}

local localPlayer = Players.LocalPlayer
local pages: { [string]: Frame } = {}
local navButtons: { [string]: TextButton } = {}
local tabButtons: { [string]: TextButton } = {}
local hiddenPages: { [string]: boolean } = {}
local currentPageId: string? = nil
local baseScale = 1

-- W09 layout preferences (UIPrefs "Layout"); replaced by Shell.ApplyPrefs.
local layout: any = {
	Mode = "Auto",
	Compact = false,
	StatusBar = true,
	Labels = "Auto",
	Tabs = { "Dashboard", "Players", "Moderation", "Commands", "Server", "Insights" },
	Pinned = {},
}

-- Bar sizes (unscaled pixels) for normal and compact mode.
local METRICS = {
	Normal = { Top = 40, Nav = 42, Status = 28, Sub = 176, SubIcons = 52, Strip = 40, Pad = 20, Tab = 14, Row = 38, Icon = 30 },
	Compact = { Top = 30, Nav = 34, Status = 22, Sub = 148, SubIcons = 46, Strip = 34, Pad = 10, Tab = 13, Row = 30, Icon = 24 },
}
local metrics = METRICS.Normal
-- Below these unscaled widths the shell folds things away (reflow).
local NARROW_WIDTH = 900 -- search becomes an icon, user name hidden
local SUBNAV_ICON_WIDTH = 760 -- sub menu shows icons only
local MIN_SIZE = Vector2.new(560, 360)
local isMobile = false
local relayout: () -> () = function() end

local SECTIONS = {
	{ Id = "Dashboard", Label = "Dashboard", Icon = "🏠", Pages = { { Id = "Dashboard", Label = "Dashboard", Icon = "🏠" } } },
	{
		Id = "Players",
		Label = "Players",
		Icon = "👥",
		Pages = {
			{ Id = "Players", Label = "Players", Icon = "👥" },
			{ Id = "Lookup", Label = "Lookup", Icon = "🔎" },
		},
	},
	{
		Id = "Moderation",
		Label = "Moderation",
		Icon = "🛡",
		Pages = {
			{ Id = "Moderation", Label = "Moderation", Icon = "🛡" },
			{ Id = "Reports", Label = "Reports", Icon = "🚩" },
			{ Id = "Appeals", Label = "Appeals", Icon = "⚖" },
			{ Id = "ChatLog", Label = "Chat Log", Icon = "💬" },
			{ Id = "Alerts", Label = "Alerts", Icon = "⚠" },
			{ Id = "Banned", Label = "Banned", Icon = "⛔" },
			{ Id = "AntiCheat", Label = "Anti-Cheat", Icon = "🛡" },
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
		Id = "Announcements",
		Label = "Announcements",
		Icon = "📢",
		Pages = {
			{ Id = "AnnounceHistory", Label = "History", Icon = "🕘" },
			{ Id = "AnnounceServer", Label = "Current server", Icon = "📢" },
			{ Id = "AnnounceGlobal", Label = "Global", Icon = "🌐" },
			{ Id = "AnnouncePlayers", Label = "Some players", Icon = "👤" },
			{ Id = "Polls", Label = "Polls", Icon = "📊" },
			{ Id = "Events", Label = "Events", Icon = "🎉" },
		},
	},
	{
		Id = "Insights",
		Label = "Insights",
		Icon = "📈",
		Pages = {
			{ Id = "Analytics", Label = "Analytics", Icon = "📈" },
			{ Id = "Logs", Label = "Audit Log", Icon = "📋" },
			{ Id = "Developer", Label = "Developer", Icon = "🔧" },
		},
	},
	{
		Id = "Modules",
		Label = "Modules",
		Icon = "🧩",
		Pages = {
			{ Id = "Modules", Label = "Modules", Icon = "🧩" },
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
			{ Id = "Keybinds", Label = "Keybinds", Icon = "⌨" },
			{ Id = "Sounds", Label = "Sounds", Icon = "🔊" },
			{ Id = "Administration", Label = "Administration", Icon = "🛠" },
			{ Id = "Notifications", Label = "Notifications", Icon = "🔔" },
		},
	},
}

-- Icons.lua decides each entry's icon: an uploaded image (the emoji slot
-- becomes blank space and an ImageLabel is attached) or the emoji fallback.
-- Section slots are "<Id>Section" (Dashboard has a single page and uses its page slot).
for _, section in ipairs(SECTIONS) do
	section.IconKey = if Icons.Slots[section.Id .. "Section"] then section.Id .. "Section" else section.Id
	if Icons.Slots[section.IconKey] then
		section.Icon = Icons.text(section.IconKey, "     ")
	end
	for _, page in ipairs(section.Pages) do
		page.IconKey = page.Id
		if Icons.Slots[page.Id] then
			page.Icon = Icons.text(page.Id)
		end
	end
end

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
			-- Sidebar customisation: order and visibility come from Layout.Tabs.
			local position = table.find(layout.Tabs, section.Id)
			tab.Visible = position ~= nil and #visiblePages(section) > 0
			tab.LayoutOrder = position or 99
			-- Roblox-style: the active section is a filled pill.
			tab.BackgroundColor3 = Theme.Colors.SurfaceRaised
			Theme.tween(tab, Theme.Motion.Fast, {
				TextColor3 = if active then Theme.Colors.Text else Theme.Colors.TextSecondary,
				BackgroundTransparency = if active then 0 else 1,
			})
		end
		for _, page in ipairs(section.Pages) do
			local button = navButtons[page.Id]
			if button then
				local current = page.Id == currentPageId
				-- Pinned pages already show in the Pinned group at the top.
				button.Visible = section == activeSection
					and not hiddenPages[page.Id]
					and not table.find(layout.Pinned, page.Id)
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
	-- Pinned (favorite) pages: highlight the current one.
	for id, button in pairs(Shell.pinButtons or {}) do
		local current = id == currentPageId
		button.BackgroundColor3 = Theme.Colors.SurfaceRaised
		Theme.tween(button, Theme.Motion.Fast, {
			BackgroundTransparency = if current then 0 else 1,
			TextColor3 = if current then Theme.Colors.Text else Theme.Colors.TextSecondary,
		})
	end
	local pinButton = Shell.pinButton
	if pinButton then
		local pinned = currentPageId ~= nil and table.find(layout.Pinned, currentPageId) ~= nil
		-- RichText colour, so the hover tween (TextColor3) can't grey it out.
		pinButton.Text = if pinned
			then ('<font color="#%s">★</font>'):format(Theme.Colors.Warning:ToHex())
			else "☆"
	end
	relayout()
end

-- Hides/shows a page's navigation entry (page visibility permissions). The
-- server is still the authority: hidden pages' remotes stay permission-
-- checked; this only keeps the navigation tidy.
function Shell.SetPageVisible(id: string, visible: boolean)
	hiddenPages[id] = if visible then nil else true
	Shell.buildPinned()
	if not visible and currentPageId == id and id ~= "Dashboard" then
		Shell.ShowPage("Dashboard")
	else
		refreshNav()
	end
end

local transitionToken = 0
local navOrder: () -> { string }

function Shell.ShowPage(id: string)
	if currentPageId == id or not pages[id] then
		if currentPageId == id then
			refreshNav()
		end
		return
	end
	local previousId = currentPageId
	local previous = previousId and pages[previousId]
	currentPageId = id
	local page = pages[id]
	-- Direction follows the navigation order: a page further along slides
	-- in from the right (the old one leaves to the left), and back again.
	local order = navOrder()
	local from = previousId and table.find(order, previousId) or 0
	local to = table.find(order, id) or 0
	local dir = if to >= from then 1 else -1
	transitionToken += 1
	local token = transitionToken
	if previous then
		if Theme.Animations and not Theme.ReducedMotion then
			previous.ZIndex = 1
			local exitInfo = TweenInfo.new(0.16 / Theme.AnimationSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			Theme.tween(previous, exitInfo, { Position = UDim2.new(-0.12 * dir, 0, 0, 0) })
			task.delay(exitInfo.Time, function()
				-- Came straight back to it: the new enter tween owns it now.
				if currentPageId ~= previousId then
					previous.Visible = false
					previous.Position = UDim2.new(0, 0, 0, 0)
				end
			end)
		else
			previous.Visible = false
		end
	end
	page.Visible = true
	page.ZIndex = 2
	if Theme.Animations and not Theme.ReducedMotion and previous then
		-- Enter from the side with a little overshoot-free ease (Quint),
		-- starting slightly lower so it settles diagonally into place.
		page.Position = UDim2.new(0.18 * dir, 0, 0, 10)
		task.delay(0.05 / Theme.AnimationSpeed, function()
			if token == transitionToken then
				Theme.tween(page, Theme.Motion.Page, { Position = UDim2.new(0, 0, 0, 0) })
			end
		end)
	else
		page.Position = UDim2.new(0, 0, 0, 14)
		Theme.tween(page, Theme.Motion.Normal, { Position = UDim2.new(0, 0, 0, 0) })
	end
	refreshNav()
end

-- Next / previous page (keyboard shortcuts), in navigation order: pinned
-- pages, then the section tabs in the player's order, then System. Skips
-- hidden and unregistered pages. Wraps around.
navOrder = function(): { string }
	local ids = {}
	local function add(id: string)
		if pages[id] and not hiddenPages[id] and not table.find(ids, id) then
			table.insert(ids, id)
		end
	end
	for _, id in ipairs(layout.Pinned) do
		add(id)
	end
	for _, sectionId in ipairs(layout.Tabs) do
		for _, section in ipairs(SECTIONS) do
			if section.Id == sectionId then
				for _, page in ipairs(section.Pages) do
					add(page.Id)
				end
			end
		end
	end
	for _, page in ipairs(SECTIONS[#SECTIONS].Pages) do
		add(page.Id)
	end
	return ids
end

function Shell.Cycle(direction: number)
	local ids = navOrder()
	if #ids == 0 then
		return
	end
	local index = (currentPageId and table.find(ids, currentPageId)) or 0
	local nextIndex = ((index - 1 + direction) % #ids) + 1
	Shell.ShowPage(ids[nextIndex])
end

function Shell.GetCurrentPage(): string?
	return currentPageId
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
	Theme.corner(button, Theme.Radius.Pill)
	Shell.iconButtons = Shell.iconButtons or {}
	table.insert(Shell.iconButtons, button)
	hover(button, function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 0, TextColor3 = Theme.Colors.Text })
	end, function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 1, TextColor3 = Theme.Colors.TextSecondary })
	end)
	return button
end

-- One entry of the sub menu (a section page or a pinned page).
local function makeNavButton(parent: Instance, name: string, page: any, order: number, withMarker: boolean): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, metrics.Row)
	button.BackgroundColor3 = Theme.Colors.SurfaceRaised
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Font = Theme.Font.Medium
	button.TextSize = 14
	button.TextColor3 = Theme.Colors.TextSecondary
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Text = ("    %s   %s"):format(page.Icon, page.Label)
	button:SetAttribute("FullText", button.Text)
	button:SetAttribute("IconText", page.Icon)
	button:SetAttribute("StripText", ("  %s  %s  "):format(page.Icon, page.Label))
	button.Parent = parent
	if Icons.attach(button, page.IconKey or page.Id, { Size = 18, X = 14 }) then
		button:SetAttribute("IconText", "")
	end
	Theme.corner(button, Theme.Radius.S)

	if withMarker then
		local marker = Instance.new("Frame")
		marker.Name = "Marker"
		marker.AnchorPoint = Vector2.new(0, 0.5)
		marker.Position = UDim2.new(0, 0, 0.5, 0)
		marker.Size = UDim2.new(0, 3, 0, 0)
		marker.BackgroundColor3 = Theme.Colors.Accent
		marker.BorderSizePixel = 0
		marker.Parent = button
		Theme.corner(marker, UDim.new(1, 0))
	end

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
	return button
end

local pageInfo: { [string]: any } = {}
for _, section in ipairs(SECTIONS) do
	for _, page in ipairs(section.Pages) do
		pageInfo[page.Id] = page
	end
end

-- Favorite pages (W09): a "Pinned" group at the top of the sub menu,
-- rebuilt whenever the Layout prefs or page visibility change. Instance
-- names: Root.SubNav.PinnedHeader, Root.SubNav.Pin_<PageId>.
function Shell.buildPinned()
	local subNav = Shell.subNav
	if not subNav then
		return
	end
	for _, child in ipairs(subNav:GetChildren()) do
		if child:GetAttribute("Pinned") then
			child:Destroy()
		end
	end
	Shell.pinButtons = {}
	local list = {}
	for _, id in ipairs(layout.Pinned) do
		if pageInfo[id] and not hiddenPages[id] then
			table.insert(list, id)
		end
	end
	Shell.pinnedCount = #list
	if #list == 0 then
		return
	end
	local header = Instance.new("TextLabel")
	header.Name = "PinnedHeader"
	header.LayoutOrder = -200
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 20)
	header.Font = Theme.Font.Bold
	header.TextSize = 11
	header.TextColor3 = Theme.Colors.TextSecondary
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "  ★  PINNED"
	header:SetAttribute("Pinned", true)
	header:SetAttribute("FullText", header.Text)
	header:SetAttribute("IconText", "★")
	header:SetAttribute("StripText", " ★ ")
	header.Parent = subNav
	for i, id in ipairs(list) do
		local button = makeNavButton(subNav, "Pin_" .. id, pageInfo[id], -100 + i, false)
		button:SetAttribute("Pinned", true)
		Shell.pinButtons[id] = button
	end
	local divider = Instance.new("Frame")
	divider.Name = "PinnedDivider"
	divider.LayoutOrder = -1
	divider.BackgroundColor3 = Theme.Colors.Border
	divider.BorderSizePixel = 0
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider:SetAttribute("Pinned", true)
	divider.Parent = subNav
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
	Theme.corner(root, Theme.Radius.L)
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
	Theme.corner(topBar, Theme.Radius.L)
	local topMask = Instance.new("Frame")
	topMask.Name = "BottomMask"
	topMask.Position = UDim2.new(0, 0, 1, -16)
	topMask.Size = UDim2.new(1, 0, 0, 16)
	topMask.BackgroundColor3 = Theme.Colors.Surface
	topMask.BorderSizePixel = 0
	topMask.ZIndex = 0
	topMask.Parent = topBar

	local clock = Instance.new("TextLabel")
	clock.Name = "Clock"
	clock.BackgroundTransparency = 1
	clock.AnchorPoint = Vector2.new(0.5, 0)
	clock.Position = UDim2.new(0.5, 0, 0, 0)
	clock.Size = UDim2.new(0, 160, 1, 0)
	clock.Font = Theme.Font.Medium
	clock.TextSize = 13
	clock.TextColor3 = Theme.Colors.TextSecondary
	clock.TextXAlignment = Enum.TextXAlignment.Center
	clock.Text = ""
	clock.Parent = topBar

	local brand = Instance.new("TextLabel")
	brand.Name = "Title"
	brand.BackgroundTransparency = 1
	brand.Position = UDim2.new(0, 12, 0, 0)
	brand.Size = UDim2.new(0, 200, 1, 0)
	brand.Font = Theme.Font.Bold
	brand.TextSize = 17
	brand.TextColor3 = Theme.Colors.Text
	brand.TextXAlignment = Enum.TextXAlignment.Left
	brand.Text = "Sentinel"
	brand.Parent = topBar
	-- Round accent badge with the "S" monogram (same mark as the top bar button).
	local brandPad = Instance.new("UIPadding")
	brandPad.PaddingLeft = UDim.new(0, 32)
	brandPad.Parent = brand
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, -32, 0.5, 0)
	badge.Size = UDim2.fromOffset(24, 24)
	badge.BackgroundColor3 = Theme.Colors.Accent
	badge.BorderSizePixel = 0
	badge.Parent = brand
	Theme.corner(badge, Theme.Radius.Pill)
	local badgeGlyph = Instance.new("TextLabel")
	badgeGlyph.Name = "Glyph"
	badgeGlyph.BackgroundTransparency = 1
	badgeGlyph.Size = UDim2.fromScale(1, 1)
	badgeGlyph.Font = Theme.Font.Black
	badgeGlyph.TextSize = 15
	badgeGlyph.TextColor3 = Color3.new(1, 1, 1)
	badgeGlyph.Text = "S"
	badgeGlyph.Parent = badge

	-- Seasonal themes (UIPrefs.SEASONAL): an image over the badge, a thin
	-- two-colour line under the title bar, a faint corner image. Hidden
	-- unless a seasonal theme is on (and, for images, an id is set).
	local seasonImage = Instance.new("ImageLabel")
	seasonImage.Name = "SeasonImage"
	seasonImage.BackgroundTransparency = 1
	seasonImage.AnchorPoint = Vector2.new(0.5, 0.5)
	seasonImage.Position = UDim2.fromScale(0.5, 0.5)
	seasonImage.Size = UDim2.fromOffset(28, 28)
	seasonImage.ScaleType = Enum.ScaleType.Fit
	seasonImage.Visible = false
	seasonImage.ZIndex = 3
	seasonImage.Parent = badge
	local seasonLine = Instance.new("Frame")
	seasonLine.Name = "SeasonLine"
	seasonLine.AnchorPoint = Vector2.new(0, 1)
	seasonLine.Position = UDim2.new(0, 0, 1, 0)
	seasonLine.Size = UDim2.new(1, 0, 0, 2)
	seasonLine.BackgroundColor3 = Color3.new(1, 1, 1)
	seasonLine.BorderSizePixel = 0
	seasonLine.Visible = false
	seasonLine.ZIndex = 2
	seasonLine.Parent = topBar
	local seasonGradient = Instance.new("UIGradient")
	seasonGradient.Parent = seasonLine
	local seasonCorner = Instance.new("ImageLabel")
	seasonCorner.Name = "SeasonCorner"
	seasonCorner.BackgroundTransparency = 1
	seasonCorner.AnchorPoint = Vector2.new(1, 0)
	seasonCorner.Position = UDim2.new(1, -80, 0, 0)
	seasonCorner.Size = UDim2.fromOffset(160, 40)
	seasonCorner.ScaleType = Enum.ScaleType.Fit
	seasonCorner.ImageTransparency = 0.35
	seasonCorner.Visible = false
	seasonCorner.ZIndex = 1
	seasonCorner.Parent = topBar
	-- Hat sitting on the "Sentinel" word (Christmas).
	local seasonHat = Instance.new("ImageLabel")
	seasonHat.Name = "SeasonHat"
	seasonHat.BackgroundTransparency = 1
	seasonHat.AnchorPoint = Vector2.new(0.5, 1)
	seasonHat.Position = UDim2.new(0, 7, 0, 21)
	seasonHat.Size = UDim2.fromOffset(22, 22)
	seasonHat.Rotation = -18
	seasonHat.ScaleType = Enum.ScaleType.Fit
	seasonHat.Visible = false
	seasonHat.ZIndex = 4
	seasonHat.Parent = brand
	Shell.season = { Hat = seasonHat, Image = seasonImage, Glyph = badgeGlyph, Badge = badge, Line = seasonLine, Gradient = seasonGradient, Corner = seasonCorner }

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
	local closeButton = iconButton(windowButtons, "CloseButton", "", 2)
	local closeCross = Theme.crossIcon(closeButton, 11, Theme.Colors.TextSecondary, 2)
	hover(closeButton, function()
		Theme.tween(closeButton, Theme.Motion.Fast, { BackgroundColor3 = Theme.Colors.Error })
		for _, bar in ipairs(closeCross:GetChildren()) do
			(bar :: Frame).BackgroundColor3 = Theme.Colors.Text
		end
	end, function()
		Theme.tween(closeButton, Theme.Motion.Fast, { BackgroundColor3 = Theme.Colors.SurfaceRaised })
		for _, bar in ipairs(closeCross:GetChildren()) do
			(bar :: Frame).BackgroundColor3 = Theme.Colors.TextSecondary
		end
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
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Parent = tabs

	for i, section in ipairs(SECTIONS) do
		if section.IconOnly then
			continue
		end
		local tab = Instance.new("TextButton")
		tab.Name = section.Id .. "Tab"
		tab.LayoutOrder = i
		tab.AutomaticSize = Enum.AutomaticSize.X
		tab.Size = UDim2.new(0, 0, 0, 30)
		tab.BackgroundColor3 = Theme.Colors.SurfaceRaised
		tab.BackgroundTransparency = 1
		tab.AutoButtonColor = false
		tab.BorderSizePixel = 0
		tab.Font = Theme.Font.Medium
		tab.TextSize = 14
		tab.TextColor3 = Theme.Colors.TextSecondary
		tab.Text = ("%s  %s"):format(section.Icon, section.Label)
		tab:SetAttribute("FullText", tab.Text)
		tab:SetAttribute("IconText", section.Icon)
		tab.Parent = tabs
		Icons.attach(tab, section.IconKey, { Size = 18, X = 0 })
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 12)
		pad.PaddingRight = UDim.new(0, 12)
		pad.Parent = tab

		Theme.corner(tab, Theme.Radius.Pill)

		hover(tab, function()
			if sectionOfPage[currentPageId or ""] ~= section then
				Theme.tween(tab, Theme.Motion.Fast, { TextColor3 = Theme.Colors.Text, BackgroundTransparency = 0.6 })
			end
		end, function()
			if sectionOfPage[currentPageId or ""] ~= section then
				Theme.tween(tab, Theme.Motion.Fast, { TextColor3 = Theme.Colors.TextSecondary, BackgroundTransparency = 1 })
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
	right.Size = UDim2.new(0, 0, 0, 30)
	right.AutomaticSize = Enum.AutomaticSize.X
	right.Parent = navBar
	Shell.tabsFrame = tabs
	Shell.navRight = right
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
	Icons.prefix(searchButton, "Search", "Search", 14)
	searchButton.Parent = right
	Theme.corner(searchButton, Theme.Radius.Pill)
	hover(searchButton, function()
		Theme.tween(searchButton, Theme.Motion.Fast, { TextColor3 = Theme.Colors.Text })
	end, function()
		Theme.tween(searchButton, Theme.Motion.Fast, { TextColor3 = Theme.Colors.TextSecondary })
	end)
	Shell.searchButton = searchButton

	-- Favorite pages (W09): pin / unpin the current page. Sent as a normal
	-- ;pin / ;unpin command, so it is saved with the player's prefs and the
	-- server pushes the new layout back.
	local pinButton = iconButton(right, "PinButton", "☆", 0)
	pinButton.RichText = true
	pinButton.MouseButton1Click:Connect(function()
		local id = currentPageId
		if not id then
			return
		end
		local remote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):FindFirstChild("ExecuteCommandRemote") :: RemoteEvent?
		if remote then
			local pinned = table.find(layout.Pinned, id) ~= nil
			remote:FireServer((if pinned then "unpin " else "pin ") .. id, { Source = "panel" })
		end
	end)
	Shell.pinButton = pinButton

	-- Sound effects on / off (Sounds.Enabled, saved to personal prefs).
	-- The speaker icon follows SoundPlayer, so ;sounds and the Sounds page
	-- update it too.
	local SoundPlayer = require(script.Parent:WaitForChild("SoundPlayer"))
	local soundButton = iconButton(right, "SoundButton", Icons.text("SoundOn", ""), 2)
	local soundIcon = Icons.attach(soundButton, "SoundOn", { Size = 18 })
	local function showSoundState()
		local on = SoundPlayer.IsEnabled()
		local key = if on then "SoundOn" else "SoundOff"
		if soundIcon then
			soundIcon.Image = Icons.image(key) or ""
		else
			soundButton.Text = Icons.fallback(key)
		end
	end
	showSoundState()
	SoundPlayer.Changed:Connect(showSoundState)
	soundButton.MouseButton1Click:Connect(function()
		local remote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):FindFirstChild("SetUIPrefsRemote") :: RemoteFunction?
		if not remote then
			return
		end
		local enable = not SoundPlayer.IsEnabled()
		-- Show it at once; UIPrefsChangedRemote confirms.
		local current = table.clone(SoundPlayer.Get())
		current.Enabled = enable
		SoundPlayer.ApplyPrefs(current)
		if enable then
			SoundPlayer.Play("Success")
		end
		task.spawn(function()
			pcall(function()
				(remote :: RemoteFunction):InvokeServer("personal", { Sounds = { Enabled = enable } })
			end)
		end)
	end)

	local bellButton = iconButton(right, "BellButton", Icons.text("Bell", ""), 3)
	Icons.attach(bellButton, "Bell", { Size = 18 })
	bellButton.MouseButton1Click:Connect(function()
		Shell.ShowPage("Notifications")
	end)
	local gearButton = iconButton(right, "GearButton", Icons.text("Gear", ""), 4)
	Icons.attach(gearButton, "Gear", { Size = 18 })
	gearButton.MouseButton1Click:Connect(function()
		Shell.ShowPage("Settings")
	end)

	-- Mobile has no title bar: this close button takes its place.
	local mobileClose = iconButton(right, "MobileCloseButton", "", 9)
	mobileClose.Visible = false
	Theme.crossIcon(mobileClose, 11, Theme.Colors.TextSecondary, 2)
	mobileClose.MouseButton1Click:Connect(function()
		Shell.Close()
	end)

	local userChip = Instance.new("Frame")
	userChip.Name = "User"
	userChip.LayoutOrder = 5
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
	Shell.userChip = userChip

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
	Shell.subLayout = subLayout
	local subPadding = Theme.padding(subNav, Theme.Spacing.S)
	Shell.subPadding = subPadding

	local order = 0
	for _, section in ipairs(SECTIONS) do
		for _, page in ipairs(section.Pages) do
			order += 1
			local button = makeNavButton(subNav, page.Id .. "NavButton", page, order, false)
			button.Visible = false
			navButtons[page.Id] = button
		end
	end
	Shell.buildPinned()

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
	local workspacePadding = Theme.padding(workspaceFrame, Theme.Spacing.L)
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
	statusMask.Name = "TopMask"
	statusMask.Size = UDim2.new(1, 0, 0, 16)
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
			Icons.prefix(clock, "Clock", ((os.date("%I:%M %p") :: string):gsub("^0", "")), 14)
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
			if screenGui.Enabled and statusBar.Visible then
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
	local minimizeShift = 0
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
		statusBar.Visible = show and layout.StatusBar
		resizeHandle.Visible = show and not isMobile
		subNav.Visible = false
		-- The window is centre-anchored, so collapsing it would move the
		-- title bar (and the minimize button) down by half the height.
		-- Shift it up by that much so the title bar stays put (W09).
		if isMinimized then
			minimizeShift = math.round((root.AbsoluteSize.Y - metrics.Top * uiScale.Scale) / 2)
			Theme.tween(root, Theme.Motion.Normal, {
				Size = UDim2.new(root.Size.X.Scale, root.Size.X.Offset, 0, metrics.Top),
				Position = root.Position - UDim2.fromOffset(0, minimizeShift),
			})
			minimizeButton.Text = "+"
		else
			if fullSizeBeforeMinimize then
				Theme.tween(root, Theme.Motion.Normal, {
					Size = fullSizeBeforeMinimize,
					Position = root.Position + UDim2.fromOffset(0, minimizeShift),
				})
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
		local maxY = math.max(minY, guiOrigin.Y + viewport.Y - metrics.Top + halfH)
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
		if isMobile then
			relayout() -- the mobile window always fills the screen
			return
		end
		placeAt(currentCentre())
	end
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		relayout() -- may switch Auto mode between mobile and desktop
		Shell.clampIntoView()
	end)
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
		if not isPress(input) or isMobile then
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
			-- Minimum in unscaled pixels; the content reflows below ~900 wide.
			root.Size = UDim2.fromOffset(
				math.max(MIN_SIZE.X, (resizeStartSize.X + delta.X) / uiScale.Scale),
				math.max(MIN_SIZE.Y, (resizeStartSize.Y + delta.Y) / uiScale.Scale)
			)
		end
	end)

	-- ------------------------------------------------------------------
	-- Layout (W09): compact / normal bar sizes, mobile / desktop window,
	-- status bar, section tab order and labels, sub menu reflow. Runs on
	-- every prefs change, page change, window resize and screen resize.
	-- ------------------------------------------------------------------
	local desktopSize: UDim2? = nil
	local desktopPosition: UDim2? = nil

	-- Screen size used for layout. Studio can't emulate a phone through
	-- MCP, so a test can set the attribute EmulateViewport (Vector2) on the
	-- SentinelShell ScreenGui to lay the panel out as on that screen.
	local function viewportSize(): Vector2
		local emulated = screenGui:GetAttribute("EmulateViewport")
		if typeof(emulated) == "Vector2" then
			return emulated
		end
		return screenGui.AbsoluteSize
	end
	Shell.viewportSize = viewportSize
	screenGui:GetAttributeChangedSignal("EmulateViewport"):Connect(function()
		relayout()
	end)

	local function wantMobile(): boolean
		if layout.Mode == "Mobile" then
			return true
		elseif layout.Mode == "Desktop" then
			return false
		end
		local viewport = viewportSize()
		-- Phones in landscape are often wider than 760 but only ~390 tall.
		return (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
			or (viewport.X > 0 and viewport.X < 760)
			or (viewport.Y > 0 and viewport.Y < 480)
	end

	local function textWidth(text: string, size: number, font: Enum.Font): number
		return TextService:GetTextSize(text, size, font, Vector2.new(2000, 100)).X
	end

	local function styleSubEntry(entry: GuiObject, strip: boolean, iconsOnly: boolean)
		local isLabel = entry:IsA("TextLabel")
		local isButton = entry:IsA("TextButton")
		if not (isLabel or isButton) then
			if entry.Name == "PinnedDivider" then
				entry.Size = if strip then UDim2.new(0, 1, 1, -10) else UDim2.new(1, 0, 0, 1)
			end
			return
		end
		local textEntry = entry :: any
		if strip then
			textEntry.AutomaticSize = Enum.AutomaticSize.X
			textEntry.Size = UDim2.new(0, 0, 1, 0)
			textEntry.Text = entry:GetAttribute("StripText") or textEntry.Text
			textEntry.TextXAlignment = Enum.TextXAlignment.Center
			local img = entry:FindFirstChild("IconImage") :: ImageLabel?
			if img then
				Icons.place(img, 8)
			end
		else
			textEntry.AutomaticSize = Enum.AutomaticSize.None
			textEntry.Size = UDim2.new(1, 0, 0, if isLabel then 20 else metrics.Row)
			textEntry.Text = (if iconsOnly then entry:GetAttribute("IconText") else entry:GetAttribute("FullText")) or textEntry.Text
			textEntry.TextXAlignment = if iconsOnly then Enum.TextXAlignment.Center else Enum.TextXAlignment.Left
			local img = entry:FindFirstChild("IconImage") :: ImageLabel?
			if img then
				Icons.place(img, if iconsOnly then nil else 14)
			end
		end
		if isButton then
			textEntry.TextSize = if layout.Compact then 13 else 14
		end
	end

	local laying = false
	local lastStrip: boolean? = nil
	relayout = function()
		if laying then
			return
		end
		laying = true

		-- Mobile: the window fills the screen below Roblox's top bar; no
		-- drag or resize. Leaving mobile restores the desktop window.
		local mobile = wantMobile()
		if mobile ~= isMobile then
			if mobile then
				desktopSize, desktopPosition = root.Size, root.Position
			else
				root.AnchorPoint = Vector2.new(0.5, 0.5)
				root.Size = desktopSize or UDim2.new(0.8, 0, 0.82, 0)
				root.Position = desktopPosition or UDim2.new(0.5, 0, 0.5, 0)
			end
			isMobile = mobile
			Shell.isMobile = mobile
		end
		if isMobile and not isMinimized then
			local viewport = viewportSize()
			local inset = GuiService:GetGuiInset().Y
			local margin = 6
			root.AnchorPoint = Vector2.new(0.5, 0.5)
			root.Position = UDim2.fromOffset(math.round(viewport.X / 2), math.round(inset + (viewport.Y - inset) / 2))
			root.Size = UDim2.fromOffset(
				math.max(200, viewport.X - margin * 2) / baseScale,
				math.max(200, viewport.Y - inset - margin * 2) / baseScale
			)
		end
		resizeHandle.Visible = not isMobile and not isMinimized
		-- Phones: every pixel of height counts, so mobile always uses the
		-- compact bars, drops the title bar (close moves into the nav bar)
		-- and the status bar.
		metrics = if layout.Compact or isMobile then METRICS.Compact else METRICS.Normal

		-- Bars.
		local top, nav = if isMobile then 0 else metrics.Top, metrics.Nav
		local status = if layout.StatusBar and not isMobile then metrics.Status else 0
		topBar.Visible = not isMobile
		mobileClose.Visible = isMobile
		topBar.Size = UDim2.new(1, 0, 0, top)
		navBar.Position = UDim2.new(0, 0, 0, top)
		navBar.Size = UDim2.new(1, 0, 0, nav)
		statusBar.Position = UDim2.new(0, 0, 1, -metrics.Status)
		statusBar.Size = UDim2.new(1, 0, 0, metrics.Status)
		statusBar.Visible = layout.StatusBar and not isMinimized and not isMobile
		statusLabel.TextSize = if layout.Compact then 11 else 12
		statusRight.TextSize = statusLabel.TextSize
		windowButtons.Size = UDim2.new(0, metrics.Icon * 2 + 4, 0, metrics.Icon)
		for _, button in ipairs(Shell.iconButtons or {}) do
			button.Size = UDim2.new(0, metrics.Icon, 0, metrics.Icon)
		end
		brand.TextSize = if layout.Compact then 15 else 17
		clock.TextSize = if layout.Compact then 12 else 13

		-- Width-based reflow (unscaled pixels).
		local scale = if uiScale.Scale > 0 then uiScale.Scale else 1
		local width = if isMobile then viewportSize().X / scale else root.AbsoluteSize.X / scale
		local narrow = isMobile or width < NARROW_WIDTH
		clock.Visible = width >= 640
		if narrow then
			searchButton.Text = Icons.text("Search", "")
			local searchImg = searchButton:FindFirstChild("IconImage") :: ImageLabel?
			if searchImg then
				Icons.place(searchImg, nil)
			end
		else
			Icons.prefix(searchButton, "Search", "Search", 14)
		end
		local searchWidth = if narrow then metrics.Icon else 96
		searchButton.Size = UDim2.new(0, searchWidth, 0, metrics.Icon)
		local userWidth = if narrow then 26 else 132
		userChip.Size = UDim2.new(0, userWidth, 0, metrics.Icon)
		userLabel.Visible = not narrow
		right.Size = UDim2.new(0, 0, 0, metrics.Icon)
		local rightWidth = metrics.Icon * (if isMobile then 4 else 3) + searchWidth + userWidth + 6 * (if isMobile then 5 else 4)
		tabs.Size = UDim2.new(1, -(rightWidth + 26), 1, 0)

		-- Section tabs: full labels while they fit, else icons only.
		local available = width - rightWidth - 26
		local full = 0
		for _, sectionId in ipairs(layout.Tabs) do
			local tab = tabButtons[sectionId]
			if tab and tab.Visible then
				full += textWidth(tab:GetAttribute("FullText") or "", metrics.Tab, tab.Font) + 26
			end
		end
		local iconTabs = layout.Labels == "Icons" or (layout.Labels == "Auto" and full > available)
		for _, tab in pairs(tabButtons) do
			tab.Text = (if iconTabs then tab:GetAttribute("IconText") else tab:GetAttribute("FullText")) or tab.Text
			tab.TextSize = metrics.Tab + (if iconTabs then 3 else 0)
			local tabImg = tab:FindFirstChild("IconImage") :: ImageLabel?
			if tabImg then
				Icons.place(tabImg, if iconTabs then nil else 0)
			end
			tab.Size = UDim2.new(0, 0, 0, metrics.Icon)
			local pad = tab:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingLeft = UDim.new(0, if iconTabs then 10 else 12)
				pad.PaddingRight = pad.PaddingLeft
			end
		end
		Shell.iconTabs = iconTabs

		-- Sub menu: a left column on desktop (icons only when narrow), a
		-- horizontal strip under the nav bar on mobile.
		local activeSection = currentPageId and sectionOfPage[currentPageId]
		local hasSection = activeSection ~= nil and #visiblePages(activeSection) > 1
		local showSub = (hasSection or (Shell.pinnedCount or 0) > 0) and not isMinimized
		local headerTop = top + nav
		local left, workspaceTop = 0, headerTop
		local iconsOnly = not isMobile and width < SUBNAV_ICON_WIDTH
		if isMobile then
			subLayout.FillDirection = Enum.FillDirection.Horizontal
			subLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			subNav.ScrollingDirection = Enum.ScrollingDirection.X
			subNav.AutomaticCanvasSize = Enum.AutomaticSize.X
			subNav.Position = UDim2.new(0, 0, 0, headerTop)
			subNav.Size = UDim2.new(1, 0, 0, metrics.Strip)
			subPadding.PaddingTop = UDim.new(0, 4)
			subPadding.PaddingBottom = UDim.new(0, 4)
			if showSub then
				workspaceTop += metrics.Strip
			end
		else
			subLayout.FillDirection = Enum.FillDirection.Vertical
			subLayout.VerticalAlignment = Enum.VerticalAlignment.Top
			subNav.ScrollingDirection = Enum.ScrollingDirection.Y
			subNav.AutomaticCanvasSize = Enum.AutomaticSize.Y
			local subWidth = if iconsOnly then metrics.SubIcons else metrics.Sub
			subNav.Position = UDim2.new(0, 0, 0, headerTop)
			subNav.Size = UDim2.new(0, subWidth, 1, -headerTop - status)
			subPadding.PaddingTop = UDim.new(0, Theme.Spacing.S)
			subPadding.PaddingBottom = UDim.new(0, Theme.Spacing.S)
			if showSub then
				left = subWidth
			end
		end
		if lastStrip ~= isMobile then
			subNav.CanvasPosition = Vector2.zero
			lastStrip = isMobile
		end
		for _, entry in ipairs(subNav:GetChildren()) do
			if entry:IsA("GuiObject") then
				styleSubEntry(entry, isMobile, iconsOnly)
			end
		end
		subNav.Visible = showSub
		workspaceFrame.Position = UDim2.new(0, left, 0, workspaceTop)
		workspaceFrame.Size = UDim2.new(1, -left, 1, -workspaceTop - status)
		local pad = UDim.new(0, if isMobile then 8 else metrics.Pad)
		workspacePadding.PaddingTop = pad
		workspacePadding.PaddingBottom = pad
		workspacePadding.PaddingLeft = pad
		workspacePadding.PaddingRight = pad
		laying = false
	end

	-- Window resized by the handle (or Scale changed): reflow once per frame.
	local relayoutQueued = false
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if relayoutQueued or isMinimized then
			return
		end
		relayoutQueued = true
		task.defer(function()
			relayoutQueued = false
			relayout()
		end)
	end)
	relayout()

	-- NOTE: does NOT call Shell.ShowPage("Dashboard") here. Pages are
	-- registered by the caller (init.client.lua) AFTER Init() returns; the
	-- caller shows the first page once every page exists.

	return screenGui
end

-- Panel prefs that the shell itself owns (size). Colours are handled by
-- Theme.Apply + Theme.Retint in init.client; this re-applies the active
-- states with the new palette.
-- Seasonal theme decoration (see the title bar build). Images come from
-- Icons slots; with no id set only the line and colours change.
function Shell.ApplySeason(panel: any)
	local parts = Shell.season
	if not parts then
		return
	end
	local season = UIPrefs.Season(panel)
	local badgeImage = if season then Icons.image(season.Badge) else nil
	local cornerImage = if season then Icons.image(season.Corner) else nil
	parts.Image.Image = badgeImage or ""
	parts.Image.Visible = badgeImage ~= nil
	parts.Glyph.Visible = badgeImage == nil
	parts.Badge.BackgroundTransparency = if badgeImage then 1 else 0
	parts.Corner.Image = cornerImage or ""
	parts.Corner.Visible = cornerImage ~= nil
	local hatImage = if season and season.Hat then Icons.image(season.Hat) else nil
	parts.Hat.Image = hatImage or ""
	parts.Hat.Visible = hatImage ~= nil
	parts.Line.Visible = season ~= nil
	if season then
		parts.Gradient.Color = ColorSequence.new(season.Line[1], season.Line[2])
	end
end

function Shell.ApplyPrefs(panel: any, layoutPrefs: any?)
	Shell.ApplySeason(panel)
	baseScale = if panel and type(panel.Scale) == "number" then panel.Scale else 1
	if Shell.uiScale then
		Shell.uiScale.Scale = baseScale
	end
	if type(layoutPrefs) == "table" then
		local merged = table.clone(layout)
		for field, value in pairs(layoutPrefs) do
			merged[field] = value
		end
		if type(merged.Tabs) ~= "table" or #merged.Tabs == 0 then
			merged.Tabs = { "Dashboard", "Players", "Moderation", "Commands", "Server", "Insights" }
		end
		if type(merged.Pinned) ~= "table" then
			merged.Pinned = {}
		end
		layout = merged
		Shell.layout = layout
		Shell.buildPinned()
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
