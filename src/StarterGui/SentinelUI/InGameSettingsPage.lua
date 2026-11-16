-- ============================================
-- IN-GAME SETTINGS PAGE
-- ============================================
-- Adapted from Admin Panel V4.3 Settings tab
-- Features: Keybind customization, Theme import/export, Preferences

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Theme = require(script.Parent.Theme)
local Config = require(ReplicatedStorage.Shared.Sentinel.Config)

local InGameSettingsPage = {}
InGameSettingsPage.__index = InGameSettingsPage

-- ============================================
-- STATE
-- ============================================
local currentKeybinds = table.clone(Config.KEYBINDS)
local currentTheme = Config.DEFAULT_THEME
local customTheme = nil

-- ============================================
-- INITIALIZATION
-- ============================================
function InGameSettingsPage.new(parent)
	local self = setmetatable({}, InGameSettingsPage)
	self.parent = parent
	self.container = nil
	self.currentKeybindEdit = nil
	self.theme = Theme
	self:Build()
	return self
end

function InGameSettingsPage:Build()
	-- Main container
	self.container = Instance.new("ScrollingFrame")
	self.container.Name = "InGameSettingsPage"
	self.container.Size = UDim2.new(1, 0, 1, 0)
	self.container.BackgroundTransparency = 1
	self.container.ScrollBarThickness = 6
	self.container.CanvasSize = UDim2.new(0, 0, 0, 0)
	self.container.AutomaticCanvasSize = Enum.AutomaticSize.Y
	self.container.Parent = self.parent

	local layout = Instance.new("UIListLayout", self.container)
	layout.Padding = UDim.new(0, 15)

	local padding = Instance.new("UIPadding", self.container)
	padding.PaddingTop = UDim.new(0, 15)
	padding.PaddingLeft = UDim.new(0, 15)
	padding.PaddingRight = UDim.new(0, 15)

	-- Build sections
	self:BuildKeybindSection()
	self:BuildThemeSection()
	self:BuildPreferencesSection()
	self:BuildPermissionSection()
end

-- ============================================
-- KEYBIND SECTION
-- ============================================
function InGameSettingsPage:BuildKeybindSection()
	-- Section Header
	local sectionFrame = self:CreateSectionFrame("⌨️ Keybinds")
	sectionFrame.LayoutOrder = 1

	-- Info text
	local infoText = Instance.new("TextLabel", sectionFrame)
	infoText.Size = UDim2.new(1, -20, 0, 30)
	infoText.Position = UDim2.new(0, 10, 0, 50)
	infoText.BackgroundTransparency = 1
	infoText.Text = "Click a keybind to change it. Press Escape to cancel."
	infoText.TextColor3 = self.theme.Current.TextDim
	infoText.Font = self.theme.Current.Font
	infoText.TextSize = 13
	infoText.TextXAlignment = Enum.TextXAlignment.Left

	-- Keybind list
	local keybindList = Instance.new("Frame", sectionFrame)
	keybindList.Size = UDim2.new(1, -20, 0, 0)
	keybindList.Position = UDim2.new(0, 10, 0, 90)
	keybindList.BackgroundTransparency = 1
	keybindList.AutomaticSize = Enum.AutomaticSize.Y

	local listLayout = Instance.new("UIListLayout", keybindList)
	listLayout.Padding = UDim.new(0, 8)

	-- Define keybinds to show
	local keybindItems = {
		{ name = "Toggle Panel", key = "TOGGLE_PANEL", default = Config.KEYBINDS.TOGGLE_PANEL },
		{ name = "Command Palette", key = "TOGGLE_COMMAND_PALETTE", default = Config.KEYBINDS.TOGGLE_COMMAND_PALETTE },
		{ name = "Command Bar", key = "COMMAND_BAR", default = Config.KEYBINDS.COMMAND_BAR },
		{ name = "Quick Fly", key = "QUICK_FLY", default = Config.KEYBINDS.QUICK_FLY },
		{ name = "Quick Noclip", key = "QUICK_NOCLIP", default = Config.KEYBINDS.QUICK_NOCLIP },
		{ name = "Quick God", key = "QUICK_GOD", default = Config.KEYBINDS.QUICK_GOD },
	}

	for _, item in ipairs(keybindItems) do
		self:CreateKeybindRow(keybindList, item.name, item.key, item.default)
	end

	-- Reset button
	local resetBtn = Instance.new("TextButton", sectionFrame)
	resetBtn.Size = UDim2.new(0, 200, 0, 35)
	resetBtn.Position = UDim2.new(0, 10, 1, -45)
	resetBtn.BackgroundColor3 = self.theme.Current.Error
	resetBtn.Text = "↺ Reset All Keybinds"
	resetBtn.TextColor3 = self.theme.Current.Text
	resetBtn.Font = self.theme.Current.FontBold
	resetBtn.TextSize = 13
	resetBtn.BorderSizePixel = 0

	local resetCorner = Instance.new("UICorner", resetBtn)
	resetCorner.CornerRadius = UDim.new(0, 8)

	resetBtn.MouseButton1Click:Connect(function()
		currentKeybinds = table.clone(Config.KEYBINDS)
		self:Refresh()
	end)
end

function InGameSettingsPage:CreateKeybindRow(parent, name, key, defaultKey)
	local row = Instance.new("Frame", parent)
	row.Size = UDim2.new(1, 0, 0, 45)
	row.BackgroundColor3 = self.theme.Current.Surface
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner", row)
	corner.CornerRadius = UDim.new(0, 8)

	-- Label
	local label = Instance.new("TextLabel", row)
	label.Size = UDim2.new(0.6, 0, 1, 0)
	label.Position = UDim2.new(0, 15, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = self.theme.Current.Text
	label.Font = self.theme.Current.Font
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left

	-- Key button
	local keyBtn = Instance.new("TextButton", row)
	keyBtn.Size = UDim2.new(0, 150, 0, 30)
	keyBtn.Position = UDim2.new(1, -160, 0.5, -15)
	keyBtn.BackgroundColor3 = self.theme.Current.Primary
	keyBtn.Text = self:KeyCodeToString(currentKeybinds[key] or defaultKey)
	keyBtn.TextColor3 = self.theme.Current.Text
	keyBtn.Font = self.theme.Current.FontBold
	keyBtn.TextSize = 13
	keyBtn.BorderSizePixel = 0

	local keyCorner = Instance.new("UICorner", keyBtn)
	keyCorner.CornerRadius = UDim.new(0, 6)

	-- Waiting state
	local isWaiting = false

	keyBtn.MouseButton1Click:Connect(function()
		if isWaiting then return end
		isWaiting = true
		keyBtn.Text = "Press any key..."
		keyBtn.BackgroundColor3 = self.theme.Current.Warning

		-- Listen for key press
		local connection
		connection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then return end

			if input.KeyCode == Enum.KeyCode.Escape then
				-- Cancel
				keyBtn.Text = self:KeyCodeToString(currentKeybinds[key] or defaultKey)
				keyBtn.BackgroundColor3 = self.theme.Current.Primary
			else
				-- Set new keybind
				currentKeybinds[key] = input.KeyCode
				keyBtn.Text = self:KeyCodeToString(input.KeyCode)
				keyBtn.BackgroundColor3 = self.theme.Current.Success
				task.wait(0.2)
				keyBtn.BackgroundColor3 = self.theme.Current.Primary
			end

			isWaiting = false
			connection:Disconnect()
		end)
	end)
end

function InGameSettingsPage:KeyCodeToString(keyCode)
	local name = tostring(keyCode):gsub("Enum.KeyCode.", "")
	return name
end

-- ============================================
-- THEME SECTION
-- ============================================
function InGameSettingsPage:BuildThemeSection()
	local sectionFrame = self:CreateSectionFrame("🎨 Theme Settings")
	sectionFrame.LayoutOrder = 2

	-- Current theme selector
	local themeLabel = Instance.new("TextLabel", sectionFrame)
	themeLabel.Size = UDim2.new(0.5, 0, 0, 30)
	themeLabel.Position = UDim2.new(0, 10, 0, 50)
	themeLabel.BackgroundTransparency = 1
	themeLabel.Text = "Select Theme:"
	themeLabel.TextColor3 = self.theme.Current.Text
	themeLabel.Font = self.theme.Current.Font
	themeLabel.TextSize = 14
	themeLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Theme buttons
	local themeButtons = Instance.new("Frame", sectionFrame)
	themeButtons.Size = UDim2.new(1, -20, 0, 40)
	themeButtons.Position = UDim2.new(0, 10, 0, 85)
	themeButtons.BackgroundTransparency = 1

	local buttonsLayout = Instance.new("UIListLayout", themeButtons)
	buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonsLayout.Padding = UDim.new(0, 10)

	for themeName, themeData in pairs(Config.THEMES) do
		local btn = Instance.new("TextButton", themeButtons)
		btn.Size = UDim2.new(0, 120, 1, 0)
		btn.BackgroundColor3 = themeData.Primary
		btn.Text = themeName
		btn.TextColor3 = themeData.Text
		btn.Font = self.theme.Current.FontBold
		btn.TextSize = 13
		btn.BorderSizePixel = currentTheme == themeName and 3 or 0
		btn.BorderColor3 = self.theme.Current.Text

		local btnCorner = Instance.new("UICorner", btn)
		btnCorner.CornerRadius = UDim.new(0, 8)

		btn.MouseButton1Click:Connect(function()
			currentTheme = themeName
			self.theme.SetTheme(themeName)
			self:Refresh()
		end)
	end

	-- Theme export/import
	local exportImportFrame = Instance.new("Frame", sectionFrame)
	exportImportFrame.Size = UDim2.new(1, -20, 0, 140)
	exportImportFrame.Position = UDim2.new(0, 10, 0, 140)
	exportImportFrame.BackgroundColor3 = self.theme.Current.Surface
	exportImportFrame.BorderSizePixel = 0

	local eiCorner = Instance.new("UICorner", exportImportFrame)
	eiCorner.CornerRadius = UDim.new(0, 8)

	-- Export button
	local exportBtn = Instance.new("TextButton", exportImportFrame)
	exportBtn.Size = UDim2.new(0.48, -5, 0, 40)
	exportBtn.Position = UDim2.new(0, 10, 0, 10)
	exportBtn.BackgroundColor3 = self.theme.Current.Success
	exportBtn.Text = "📤 Export Theme"
	exportBtn.TextColor3 = self.theme.Current.Text
	exportBtn.Font = self.theme.Current.FontBold
	exportBtn.TextSize = 13
	exportBtn.BorderSizePixel = 0

	local expCorner = Instance.new("UICorner", exportBtn)
	expCorner.CornerRadius = UDim.new(0, 8)

	exportBtn.MouseButton1Click:Connect(function()
		self:ExportTheme()
	end)

	-- Import button
	local importBtn = Instance.new("TextButton", exportImportFrame)
	importBtn.Size = UDim2.new(0.48, -5, 0, 40)
	importBtn.Position = UDim2.new(0.52, 5, 0, 10)
	importBtn.BackgroundColor3 = self.theme.Current.Primary
	importBtn.Text = "📥 Import Theme"
	importBtn.TextColor3 = self.theme.Current.Text
	importBtn.Font = self.theme.Current.FontBold
	importBtn.TextSize = 13
	importBtn.BorderSizePixel = 0

	local impCorner = Instance.new("UICorner", importBtn)
	impCorner.CornerRadius = UDim.new(0, 8)

	importBtn.MouseButton1Click:Connect(function()
		self:ShowImportDialog()
	end)

	-- Theme code input
	local inputLabel = Instance.new("TextLabel", exportImportFrame)
	inputLabel.Size = UDim2.new(1, -20, 0, 20)
	inputLabel.Position = UDim2.new(0, 10, 0, 60)
	inputLabel.BackgroundTransparency = 1
	inputLabel.Text = "Paste theme code below:"
	inputLabel.TextColor3 = self.theme.Current.TextDim
	inputLabel.Font = self.theme.Current.Font
	inputLabel.TextSize = 12
	inputLabel.TextXAlignment = Enum.TextXAlignment.Left

	local themeInput = Instance.new("TextBox", exportImportFrame)
	themeInput.Size = UDim2.new(1, -20, 0, 50)
	themeInput.Position = UDim2.new(0, 10, 0, 85)
	themeInput.BackgroundColor3 = self.theme.Current.Background
	themeInput.PlaceholderText = '{"Name":"Custom","Background":[30,30,35],...}'
	themeInput.Text = ""
	themeInput.TextColor3 = self.theme.Current.Text
	themeInput.PlaceholderColor3 = self.theme.Current.TextDim
	themeInput.Font = self.theme.Current.Font
	themeInput.TextSize = 12
	themeInput.TextWrapped = true
	themeInput.ClearTextOnFocus = false

	local inputCorner = Instance.new("UICorner", themeInput)
	inputCorner.CornerRadius = UDim.new(0, 6)

	self.themeInput = themeInput
end

function InGameSettingsPage:ExportTheme()
	local themeData = self.theme.Current
	local exportData = {
		Name = themeData.Name or "Custom",
		Background = { themeData.Background.R * 255, themeData.Background.G * 255, themeData.Background.B * 255 },
		Surface = { themeData.Surface.R * 255, themeData.Surface.G * 255, themeData.Surface.B * 255 },
		Primary = { themeData.Primary.R * 255, themeData.Primary.G * 255, themeData.Primary.B * 255 },
		Secondary = { themeData.Secondary.R * 255, themeData.Secondary.G * 255, themeData.Secondary.B * 255 },
		Accent = { themeData.Accent.R * 255, themeData.Accent.G * 255, themeData.Accent.B * 255 },
		Text = { themeData.Text.R * 255, themeData.Text.G * 255, themeData.Text.B * 255 },
		TextDim = { themeData.TextDim.R * 255, themeData.TextDim.G * 255, themeData.TextDim.B * 255 },
		Success = { themeData.Success.R * 255, themeData.Success.G * 255, themeData.Success.B * 255 },
		Warning = { themeData.Warning.R * 255, themeData.Warning.G * 255, themeData.Warning.B * 255 },
		Error = { themeData.Error.R * 255, themeData.Error.G * 255, themeData.Error.B * 255 },
	}

	local json = HttpService:JSONEncode(exportData)
	self.themeInput.Text = json
end

function InGameSettingsPage:ShowImportDialog()
	local text = self.themeInput.Text
	if text == "" then
		return
	end

	local success, data = pcall(function()
		return HttpService:JSONDecode(text)
	end)

	if not success then
		warn("Invalid theme JSON")
		return
	end

	-- Convert RGB arrays to Color3
	local function toColor3(arr)
		return Color3.fromRGB(arr[1], arr[2], arr[3])
	end

	customTheme = {
		Name = data.Name or "Custom",
		Background = toColor3(data.Background),
		Surface = toColor3(data.Surface),
		Primary = toColor3(data.Primary),
		Secondary = toColor3(data.Secondary),
		Accent = toColor3(data.Accent),
		Text = toColor3(data.Text),
		TextDim = toColor3(data.TextDim),
		Success = toColor3(data.Success),
		Warning = toColor3(data.Warning),
		Error = toColor3(data.Error),
	}

	-- Apply custom theme
	self.theme.SetCustomTheme(customTheme)
	self:Refresh()
end

-- ============================================
-- PREFERENCES SECTION
-- ============================================
function InGameSettingsPage:BuildPreferencesSection()
	local sectionFrame = self:CreateSectionFrame("⚙️ Preferences")
	sectionFrame.LayoutOrder = 3

	local prefsList = Instance.new("Frame", sectionFrame)
	prefsList.Size = UDim2.new(1, -20, 0, 0)
	prefsList.Position = UDim2.new(0, 10, 0, 50)
	prefsList.BackgroundTransparency = 1
	prefsList.AutomaticSize = Enum.AutomaticSize.Y

	local listLayout = Instance.new("UIListLayout", prefsList)
	listLayout.Padding = UDim.new(0, 8)

	-- Preference toggles
	local preferences = {
		{ name = "Show Notification Toasts", key = "SHOW_TOASTS", default = true },
		{ name = "Reduce Motion Effects", key = "REDUCE_MOTION", default = false },
		{ name = "Show Fly GUI", key = "SHOW_FLY_GUI", default = true },
		{ name = "Enable Noclip", key = "NOCLIP_ENABLED", default = true },
		{ name = "Auto-close Panel after Command", key = "AUTO_CLOSE", default = false },
	}

	for _, pref in ipairs(preferences) do
		self:CreatePreferenceRow(prefsList, pref.name, pref.key, pref.default)
	end
end

function InGameSettingsPage:CreatePreferenceRow(parent, name, key, defaultValue)
	local row = Instance.new("Frame", parent)
	row.Size = UDim2.new(1, 0, 0, 45)
	row.BackgroundColor3 = self.theme.Current.Surface
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner", row)
	corner.CornerRadius = UDim.new(0, 8)

	-- Label
	local label = Instance.new("TextLabel", row)
	label.Size = UDim2.new(0.7, 0, 1, 0)
	label.Position = UDim2.new(0, 15, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = self.theme.Current.Text
	label.Font = self.theme.Current.Font
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left

	-- Toggle switch (simplified for now)
	local toggle = Instance.new("TextButton", row)
	toggle.Size = UDim2.new(0, 60, 0, 30)
	toggle.Position = UDim2.new(1, -70, 0.5, -15)
	toggle.BackgroundColor3 = self.theme.Current.Primary
	toggle.Text = "ON"
	toggle.TextColor3 = self.theme.Current.Text
	toggle.Font = self.theme.Current.FontBold
	toggle.TextSize = 12
	toggle.BorderSizePixel = 0

	local toggleCorner = Instance.new("UICorner", toggle)
	toggleCorner.CornerRadius = UDim.new(0, 15)

	toggle.MouseButton1Click:Connect(function()
		local isOn = toggle.Text == "ON"
		toggle.Text = isOn and "OFF" or "ON"
		toggle.BackgroundColor3 = isOn and self.theme.Current.Secondary or self.theme.Current.Primary
	end)
end

-- ============================================
-- PERMISSION SECTION (Studio Configuration Display)
-- ============================================
function InGameSettingsPage:BuildPermissionSection()
	local sectionFrame = self:CreateSectionFrame("🛡️ Permission Configuration")
	sectionFrame.LayoutOrder = 4

	-- Info text
	local infoText = Instance.new("TextLabel", sectionFrame)
	infoText.Size = UDim2.new(1, -20, 0, 60)
	infoText.Position = UDim2.new(0, 10, 0, 50)
	infoText.BackgroundTransparency = 1
	infoText.Text = "Permission ranks are configured in Studio via the AdminPanelConfig module.\nThis panel shows the current rank hierarchy for reference."
	infoText.TextColor3 = self.theme.Current.TextDim
	infoText.Font = self.theme.Current.Font
	infoText.TextSize = 13
	infoText.TextXAlignment = Enum.TextXAlignment.Left
	infoText.TextWrapped = true

	-- Rank list
	local rankList = Instance.new("Frame", sectionFrame)
	rankList.Size = UDim2.new(1, -20, 0, 0)
	rankList.Position = UDim2.new(0, 10, 0, 120)
	rankList.BackgroundTransparency = 1
	rankList.AutomaticSize = Enum.AutomaticSize.Y

	local listLayout = Instance.new("UIListLayout", rankList)
	listLayout.Padding = UDim.new(0, 8)

	for _, rank in ipairs(Config.RANKS) do
		self:CreateRankRow(rankList, rank)
	end
end

function InGameSettingsPage:CreateRankRow(parent, rank)
	local row = Instance.new("Frame", parent)
	row.Size = UDim2.new(1, 0, 0, 60)
	row.BackgroundColor3 = self.theme.Current.Surface
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner", row)
	corner.CornerRadius = UDim.new(0, 8)

	-- Rank color indicator
	local colorIndicator = Instance.new("Frame", row)
	colorIndicator.Size = UDim2.new(0, 8, 1, -10)
	colorIndicator.Position = UDim2.new(0, 5, 0, 5)
	colorIndicator.BackgroundColor3 = rank.color
	colorIndicator.BorderSizePixel = 0

	local indicatorCorner = Instance.new("UICorner", colorIndicator)
	indicatorCorner.CornerRadius = UDim.new(0, 4)

	-- Rank name
	local nameLabel = Instance.new("TextLabel", row)
	nameLabel.Size = UDim2.new(0.3, 0, 0, 25)
	nameLabel.Position = UDim2.new(0, 20, 0, 5)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = rank.name
	nameLabel.TextColor3 = rank.color
	nameLabel.Font = self.theme.Current.FontBold
	nameLabel.TextSize = 15
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Level badge
	local levelLabel = Instance.new("TextLabel", row)
	levelLabel.Size = UDim2.new(0, 80, 0, 20)
	levelLabel.Position = UDim2.new(0.35, 0, 0, 8)
	levelLabel.BackgroundColor3 = self.theme.Current.Background
	levelLabel.Text = "Lvl " .. rank.level
	levelLabel.TextColor3 = self.theme.Current.TextDim
	levelLabel.Font = self.theme.Current.Font
	levelLabel.TextSize = 11

	local levelCorner = Instance.new("UICorner", levelLabel)
	levelCorner.CornerRadius = UDim.new(0, 10)

	-- Description
	local descLabel = Instance.new("TextLabel", row)
	descLabel.Size = UDim2.new(1, -20, 0, 20)
	descLabel.Position = UDim2.new(0, 20, 1, -25)
	descLabel.BackgroundTransparency = 1
	descLabel.Text = rank.description
	descLabel.TextColor3 = self.theme.Current.TextDim
	descLabel.Font = self.theme.Current.Font
	descLabel.TextSize = 11
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
end

-- ============================================
-- HELPERS
-- ============================================
function InGameSettingsPage:CreateSectionFrame(title)
	local frame = Instance.new("Frame", self.container)
	frame.Size = UDim2.new(1, 0, 0, 200)
	frame.BackgroundColor3 = self.theme.Current.Background
	frame.BorderSizePixel = 0
	frame.AutomaticSize = Enum.AutomaticSize.Y

	local corner = Instance.new("UICorner", frame)
	corner.CornerRadius = UDim.new(0, 12)

	-- Section header
	local header = Instance.new("TextLabel", frame)
	header.Size = UDim2.new(1, -20, 0, 35)
	header.Position = UDim2.new(0, 10, 0, 10)
	header.BackgroundTransparency = 1
	header.Text = title
	header.TextColor3 = self.theme.Current.Primary
	header.Font = self.theme.Current.FontBold
	header.TextSize = 18
	header.TextXAlignment = Enum.TextXAlignment.Left

	return frame
end

function InGameSettingsPage:Refresh()
	-- Rebuild the page
	if self.container then
		self.container:Destroy()
	end
	self:Build()
end

-- ============================================
-- PUBLIC API
-- ============================================
function InGameSettingsPage.GetCurrentKeybinds()
	return currentKeybinds
end

function InGameSettingsPage.GetCurrentTheme()
	return currentTheme
end

function InGameSettingsPage.SetKeybind(key, keyCode)
	currentKeybinds[key] = keyCode
end

return InGameSettingsPage
