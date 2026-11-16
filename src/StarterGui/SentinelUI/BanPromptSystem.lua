-- ============================================
-- BAN PROMPT SYSTEM
-- ============================================
-- Adapted from Admin Panel V4.3 Ban Prompt
-- Features: Temp/Perm ban selection, Duration picker, Reason input

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent.Theme)
local Config = require(ReplicatedStorage.Shared.Sentinel.Config)

local BanPromptSystem = {}
BanPromptSystem.__index = BanPromptSystem

-- ============================================
-- SHOW BAN PROMPT
-- ============================================
function BanPromptSystem.ShowBanPrompt(targetPlayers, callback)
	local player = Players.LocalPlayer

	-- Create GUI
	local gui = Instance.new("ScreenGui", player.PlayerGui)
	gui.Name = "BanPromptGui"
	gui.ResetOnSpawn = false

	-- Overlay
	local overlay = Instance.new("Frame", gui)
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0

	-- Main frame
	local frame = Instance.new("Frame", gui)
	frame.Size = UDim2.new(0, 600, 0, 500)
	frame.Position = UDim2.new(0.5, -300, 0.5, -250)
	frame.BackgroundColor3 = Theme.Current.Surface
	frame.BorderSizePixel = 0

	local frameCorner = Instance.new("UICorner", frame)
	frameCorner.CornerRadius = UDim.new(0, 15)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Theme.Current.Error
	stroke.Thickness = 3

	-- Title
	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -20, 0, 50)
	title.Position = UDim2.new(0, 10, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "🔨 Ban Player"
	title.TextColor3 = Theme.Current.Error
	title.Font = Theme.Current.FontBold
	title.TextSize = 24

	-- Subtitle
	local subtitle = Instance.new("TextLabel", frame)
	subtitle.Size = UDim2.new(1, -20, 0, 30)
	subtitle.Position = UDim2.new(0, 10, 0, 60)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Choose ban type:"
	subtitle.TextColor3 = Theme.Current.Text
	subtitle.Font = Theme.Current.Font
	subtitle.TextSize = 16

	-- Ban type selection
	local banTypeFrame = Instance.new("Frame", frame)
	banTypeFrame.Size = UDim2.new(1, -40, 0, 70)
	banTypeFrame.Position = UDim2.new(0, 20, 0, 100)
	banTypeFrame.BackgroundTransparency = 1

	local banTypeList = Instance.new("UIListLayout", banTypeFrame)
	banTypeList.FillDirection = Enum.FillDirection.Horizontal
	banTypeList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	banTypeList.Padding = UDim.new(0, 20)

	local selectedBanType = "Temp"
	local permBtn, tempBtn

	-- Permanent Ban Button
	permBtn = Instance.new("TextButton", banTypeFrame)
	permBtn.Size = UDim2.new(0, 250, 1, 0)
	permBtn.BackgroundColor3 = Theme.Current.Background
	permBtn.Text = "⛔ Permanent Ban"
	permBtn.TextColor3 = Theme.Current.Text
	permBtn.Font = Theme.Current.FontBold
	permBtn.TextSize = 16
	permBtn.BorderSizePixel = 0

	local permCorner = Instance.new("UICorner", permBtn)
	permCorner.CornerRadius = UDim.new(0, 10)

	local permWarning = Instance.new("TextLabel", permBtn)
	permWarning.Size = UDim2.new(1, 0, 0, 20)
	permWarning.Position = UDim2.new(0, 0, 1, -25)
	permWarning.BackgroundTransparency = 1
	permWarning.Text = "Cannot be undone!"
	permWarning.TextColor3 = Theme.Current.Error
	permWarning.Font = Theme.Current.Font
	permWarning.TextSize = 11

	-- Temporary Ban Button
	tempBtn = Instance.new("TextButton", banTypeFrame)
	tempBtn.Size = UDim2.new(0, 250, 1, 0)
	tempBtn.BackgroundColor3 = Theme.Current.Primary
	tempBtn.Text = "⏱️ Temporary Ban"
	tempBtn.TextColor3 = Theme.Current.Text
	tempBtn.Font = Theme.Current.FontBold
	tempBtn.TextSize = 16
	tempBtn.BorderSizePixel = 0

	local tempCorner = Instance.new("UICorner", tempBtn)
	tempCorner.CornerRadius = UDim.new(0, 10)

	local tempInfo = Instance.new("TextLabel", tempBtn)
	tempInfo.Size = UDim2.new(1, 0, 0, 20)
	tempInfo.Position = UDim2.new(0, 0, 1, -25)
	tempInfo.BackgroundTransparency = 1
	tempInfo.Text = "Auto-expires"
	tempInfo.TextColor3 = Theme.Current.Success
	tempInfo.Font = Theme.Current.Font
	tempInfo.TextSize = 11

	-- Duration selection (for temp bans)
	local durationFrame = Instance.new("Frame", frame)
	durationFrame.Size = UDim2.new(1, -40, 0, 120)
	durationFrame.Position = UDim2.new(0, 20, 0, 180)
	durationFrame.BackgroundTransparency = 1
	durationFrame.Visible = true

	local durationTitle = Instance.new("TextLabel", durationFrame)
	durationTitle.Size = UDim2.new(1, 0, 0, 30)
	durationTitle.BackgroundTransparency = 1
	durationTitle.Text = "Select Duration:"
	durationTitle.TextColor3 = Theme.Current.Text
	durationTitle.Font = Theme.Current.FontBold
	durationTitle.TextSize = 14
	durationTitle.TextXAlignment = Enum.TextXAlignment.Left

	local durationScroll = Instance.new("ScrollingFrame", durationFrame)
	durationScroll.Size = UDim2.new(1, 0, 1, -35)
	durationScroll.Position = UDim2.new(0, 0, 0, 35)
	durationScroll.BackgroundColor3 = Theme.Current.Background
	durationScroll.BorderSizePixel = 0
	durationScroll.ScrollBarThickness = 6
	durationScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	durationScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

	local durationCorner = Instance.new("UICorner", durationScroll)
	durationCorner.CornerRadius = UDim.new(0, 8)

	local durationList = Instance.new("UIListLayout", durationScroll)
	durationList.Padding = UDim.new(0, 5)

	local durationPad = Instance.new("UIPadding", durationScroll)
	durationPad.PaddingTop = UDim.new(0, 5)

	local selectedDuration = 86400 -- Default: 1 day
	local durationButtons = {}

	for name, seconds in pairs(Config.MODERATION.BAN_DURATIONS) do
		if name ~= "Permanent" then
			local dBtn = Instance.new("TextButton", durationScroll)
			dBtn.Size = UDim2.new(1, -10, 0, 35)
			dBtn.BackgroundColor3 = Theme.Current.Surface
			dBtn.Text = name
			dBtn.TextColor3 = Theme.Current.Text
			dBtn.Font = Theme.Current.Font
			dBtn.TextSize = 13
			dBtn.BorderSizePixel = 0

			local dBtnCorner = Instance.new("UICorner", dBtn)
			dBtnCorner.CornerRadius = UDim.new(0, 6)

			durationButtons[name] = dBtn

			dBtn.MouseButton1Click:Connect(function()
				selectedDuration = seconds
				for _, btn in pairs(durationButtons) do
					btn.BackgroundColor3 = Theme.Current.Surface
				end
				dBtn.BackgroundColor3 = Theme.Current.Primary
			end)
		end
	end

	-- Default selection
	if durationButtons["1 Day"] then
		durationButtons["1 Day"].BackgroundColor3 = Theme.Current.Primary
	end

	-- Reason input
	local reasonLabel = Instance.new("TextLabel", frame)
	reasonLabel.Size = UDim2.new(1, -40, 0, 25)
	reasonLabel.Position = UDim2.new(0, 20, 0, 310)
	reasonLabel.BackgroundTransparency = 1
	reasonLabel.Text = "Ban Reason:"
	reasonLabel.TextColor3 = Theme.Current.Text
	reasonLabel.Font = Theme.Current.FontBold
	reasonLabel.TextSize = 14
	reasonLabel.TextXAlignment = Enum.TextXAlignment.Left

	local reasonInput = Instance.new("TextBox", frame)
	reasonInput.Size = UDim2.new(1, -40, 0, 60)
	reasonInput.Position = UDim2.new(0, 20, 0, 340)
	reasonInput.BackgroundColor3 = Theme.Current.Background
	reasonInput.BorderSizePixel = 0
	reasonInput.Text = ""
	reasonInput.PlaceholderText = "Enter reason for ban..."
	reasonInput.TextColor3 = Theme.Current.Text
	reasonInput.PlaceholderColor3 = Theme.Current.TextDim
	reasonInput.Font = Theme.Current.Font
	reasonInput.TextSize = 13
	reasonInput.TextWrapped = true
	reasonInput.MultiLine = true
	reasonInput.ClearTextOnFocus = false

	local reasonCorner = Instance.new("UICorner", reasonInput)
	reasonCorner.CornerRadius = UDim.new(0, 8)

	-- Buttons
	local confirmBtn = Instance.new("TextButton", frame)
	confirmBtn.Size = UDim2.new(0.48, -10, 0, 45)
	confirmBtn.Position = UDim2.new(0.02, 0, 1, -55)
	confirmBtn.BackgroundColor3 = Theme.Current.Error
	confirmBtn.Text = "✓ Confirm Ban"
	confirmBtn.TextColor3 = Theme.Current.Text
	confirmBtn.Font = Theme.Current.FontBold
	confirmBtn.TextSize = 15
	confirmBtn.BorderSizePixel = 0

	local confirmCorner = Instance.new("UICorner", confirmBtn)
	confirmCorner.CornerRadius = UDim.new(0, 8)

	local cancelBtn = Instance.new("TextButton", frame)
	cancelBtn.Size = UDim2.new(0.48, -10, 0, 45)
	cancelBtn.Position = UDim2.new(0.5, 0, 1, -55)
	cancelBtn.BackgroundColor3 = Theme.Current.Surface
	cancelBtn.Text = "✗ Cancel"
	cancelBtn.TextColor3 = Theme.Current.Text
	cancelBtn.Font = Theme.Current.FontBold
	cancelBtn.TextSize = 15
	cancelBtn.BorderSizePixel = 0

	local cancelCorner = Instance.new("UICorner", cancelBtn)
	cancelCorner.CornerRadius = UDim.new(0, 8)

	-- Button logic
	permBtn.MouseButton1Click:Connect(function()
		selectedBanType = "Perm"
		permBtn.BackgroundColor3 = Theme.Current.Primary
		tempBtn.BackgroundColor3 = Theme.Current.Background
		durationFrame.Visible = false
	end)

	tempBtn.MouseButton1Click:Connect(function()
		selectedBanType = "Temp"
		tempBtn.BackgroundColor3 = Theme.Current.Primary
		permBtn.BackgroundColor3 = Theme.Current.Background
		durationFrame.Visible = true
	end)

	confirmBtn.MouseButton1Click:Connect(function()
		local reason = reasonInput.Text ~= "" and reasonInput.Text or "No reason provided"

		if selectedBanType == "Perm" then
			-- Check permission (would call server)
			if Config.MODERATION.PERM_BAN_OWNER_ONLY then
				-- Would check if player is owner
				warn("Permanent ban requires owner permission")
			end
			callback("Perm", reason, -1)
		else
			-- Temp ban
			callback("Temp", reason, selectedDuration)
		end

		gui:Destroy()
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		gui:Destroy()
	end)
end

-- ============================================
-- SHOW KICK PROMPT
-- ============================================
function BanPromptSystem.ShowKickPrompt(targetPlayers, callback)
	local player = Players.LocalPlayer

	-- Create GUI
	local gui = Instance.new("ScreenGui", player.PlayerGui)
	gui.Name = "KickPromptGui"
	gui.ResetOnSpawn = false

	-- Overlay
	local overlay = Instance.new("Frame", gui)
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0

	-- Main frame
	local frame = Instance.new("Frame", gui)
	frame.Size = UDim2.new(0, 500, 0, 250)
	frame.Position = UDim2.new(0.5, -250, 0.5, -125)
	frame.BackgroundColor3 = Theme.Current.Surface
	frame.BorderSizePixel = 0

	local frameCorner = Instance.new("UICorner", frame)
	frameCorner.CornerRadius = UDim.new(0, 12)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Theme.Current.Primary
	stroke.Thickness = 2

	-- Title
	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.new(0, 10, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "👢 Kick Player"
	title.TextColor3 = Theme.Current.Primary
	title.Font = Theme.Current.FontBold
	title.TextSize = 22

	-- Subtitle
	local subtitle = Instance.new("TextLabel", frame)
	subtitle.Size = UDim2.new(1, -20, 0, 30)
	subtitle.Position = UDim2.new(0, 10, 0, 50)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Enter kick reason (optional):"
	subtitle.TextColor3 = Theme.Current.TextDim
	subtitle.Font = Theme.Current.Font
	subtitle.TextSize = 14

	-- Reason input
	local input = Instance.new("TextBox", frame)
	input.Size = UDim2.new(1, -40, 0, 60)
	input.Position = UDim2.new(0, 20, 0, 90)
	input.BackgroundColor3 = Theme.Current.Background
	input.BorderSizePixel = 0
	input.Text = ""
	input.PlaceholderText = "Reason for kick..."
	input.TextColor3 = Theme.Current.Text
	input.PlaceholderColor3 = Theme.Current.TextDim
	input.Font = Theme.Current.Font
	input.TextSize = 14
	input.TextWrapped = true
	input.MultiLine = true
	input.ClearTextOnFocus = false

	local inputCorner = Instance.new("UICorner", input)
	inputCorner.CornerRadius = UDim.new(0, 8)

	-- Buttons
	local confirmBtn = Instance.new("TextButton", frame)
	confirmBtn.Size = UDim2.new(0.48, -10, 0, 45)
	confirmBtn.Position = UDim2.new(0.02, 0, 1, -55)
	confirmBtn.BackgroundColor3 = Theme.Current.Primary
	confirmBtn.Text = "👢 Kick"
	confirmBtn.TextColor3 = Theme.Current.Text
	confirmBtn.Font = Theme.Current.FontBold
	confirmBtn.TextSize = 14
	confirmBtn.BorderSizePixel = 0

	local confirmCorner = Instance.new("UICorner", confirmBtn)
	confirmCorner.CornerRadius = UDim.new(0, 8)

	local cancelBtn = Instance.new("TextButton", frame)
	cancelBtn.Size = UDim2.new(0.48, -10, 0, 45)
	cancelBtn.Position = UDim2.new(0.5, 0, 1, -55)
	cancelBtn.BackgroundColor3 = Theme.Current.Surface
	cancelBtn.Text = "✗ Cancel"
	cancelBtn.TextColor3 = Theme.Current.Text
	cancelBtn.Font = Theme.Current.FontBold
	cancelBtn.TextSize = 14
	cancelBtn.BorderSizePixel = 0

	local cancelCorner = Instance.new("UICorner", cancelBtn)
	cancelCorner.CornerRadius = UDim.new(0, 8)

	-- Button logic
	confirmBtn.MouseButton1Click:Connect(function()
		local reason = input.Text ~= "" and input.Text or "No reason provided"
		callback(reason)
		gui:Destroy()
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		gui:Destroy()
	end)
end

-- ============================================
-- SHOW PM PROMPT
-- ============================================
function BanPromptSystem.ShowPMPrompt(targetPlayers, callback)
	local player = Players.LocalPlayer

	-- Create GUI
	local gui = Instance.new("ScreenGui", player.PlayerGui)
	gui.Name = "PMPromptGui"
	gui.ResetOnSpawn = false

	-- Overlay
	local overlay = Instance.new("Frame", gui)
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0

	-- Main frame
	local frame = Instance.new("Frame", gui)
	frame.Size = UDim2.new(0, 500, 0, 220)
	frame.Position = UDim2.new(0.5, -250, 0.5, -110)
	frame.BackgroundColor3 = Theme.Current.Surface
	frame.BorderSizePixel = 0

	local frameCorner = Instance.new("UICorner", frame)
	frameCorner.CornerRadius = UDim.new(0, 12)

	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Theme.Current.Accent
	stroke.Thickness = 2

	-- Title
	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.new(0, 10, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "💬 Private Message"
	title.TextColor3 = Theme.Current.Text
	title.Font = Theme.Current.FontBold
	title.TextSize = 20

	-- Subtitle
	local subtitle = Instance.new("TextLabel", frame)
	subtitle.Size = UDim2.new(1, -20, 0, 30)
	subtitle.Position = UDim2.new(0, 10, 0, 50)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Max " .. Config.PM.MAX_MESSAGE_LENGTH .. " characters"
	subtitle.TextColor3 = Theme.Current.TextDim
	subtitle.Font = Theme.Current.Font
	subtitle.TextSize = 14

	-- Message input
	local input = Instance.new("TextBox", frame)
	input.Size = UDim2.new(1, -40, 0, 50)
	input.Position = UDim2.new(0, 20, 0, 90)
	input.BackgroundColor3 = Theme.Current.Background
	input.BorderSizePixel = 0
	input.Text = ""
	input.PlaceholderText = "Type your message..."
	input.TextColor3 = Theme.Current.Text
	input.PlaceholderColor3 = Theme.Current.TextDim
	input.Font = Theme.Current.Font
	input.TextSize = 14
	input.TextWrapped = true
	input.MultiLine = true
	input.ClearTextOnFocus = false

	local inputCorner = Instance.new("UICorner", input)
	inputCorner.CornerRadius = UDim.new(0, 8)

	-- Character counter
	local charCount = Instance.new("TextLabel", frame)
	charCount.Size = UDim2.new(1, -40, 0, 20)
	charCount.Position = UDim2.new(0, 20, 0, 145)
	charCount.BackgroundTransparency = 1
	charCount.Text = "0/" .. Config.PM.MAX_MESSAGE_LENGTH
	charCount.TextColor3 = Theme.Current.TextDim
	charCount.Font = Theme.Current.Font
	charCount.TextSize = 12
	charCount.TextXAlignment = Enum.TextXAlignment.Right

	input:GetPropertyChangedSignal("Text"):Connect(function()
		local len = #input.Text
		if len > Config.PM.MAX_MESSAGE_LENGTH then
			input.Text = input.Text:sub(1, Config.PM.MAX_MESSAGE_LENGTH)
			len = Config.PM.MAX_MESSAGE_LENGTH
		end
		charCount.Text = len .. "/" .. Config.PM.MAX_MESSAGE_LENGTH
		charCount.TextColor3 = len >= Config.PM.MAX_MESSAGE_LENGTH and Theme.Current.Error or Theme.Current.TextDim
	end)

	-- Buttons
	local sendBtn = Instance.new("TextButton", frame)
	sendBtn.Size = UDim2.new(0.48, -10, 0, 40)
	sendBtn.Position = UDim2.new(0.02, 0, 1, -50)
	sendBtn.BackgroundColor3 = Theme.Current.Primary
	sendBtn.Text = "📤 Send"
	sendBtn.TextColor3 = Theme.Current.Text
	sendBtn.Font = Theme.Current.FontBold
	sendBtn.TextSize = 14
	sendBtn.BorderSizePixel = 0

	local sendCorner = Instance.new("UICorner", sendBtn)
	sendCorner.CornerRadius = UDim.new(0, 8)

	local cancelBtn = Instance.new("TextButton", frame)
	cancelBtn.Size = UDim2.new(0.48, -10, 0, 40)
	cancelBtn.Position = UDim2.new(0.5, 0, 1, -50)
	cancelBtn.BackgroundColor3 = Theme.Current.Surface
	cancelBtn.Text = "✗ Cancel"
	cancelBtn.TextColor3 = Theme.Current.Text
	cancelBtn.Font = Theme.Current.FontBold
	cancelBtn.TextSize = 14
	cancelBtn.BorderSizePixel = 0

	local cancelCorner = Instance.new("UICorner", cancelBtn)
	cancelCorner.CornerRadius = UDim.new(0, 8)

	-- Button logic
	sendBtn.MouseButton1Click:Connect(function()
		if input.Text ~= "" then
			callback(input.Text)
			gui:Destroy()
		end
	end)

	cancelBtn.MouseButton1Click:Connect(function()
		gui:Destroy()
	end)

	-- Auto-focus input
	task.wait(0.1)
	input:CaptureFocus()
end

return BanPromptSystem
