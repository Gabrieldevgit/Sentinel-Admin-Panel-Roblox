--!strict
--[[
	ConfirmDialog.lua

	Purpose:
		Generic typed-confirmation modal for destructive actions, per the
		design doc's Shutdown confirmation pattern ("Type SHUTDOWN to
		confirm"). Reused by any Quick Action card marked Critical rather
		than each one building its own dialog.

	Public API:
		ConfirmDialog.Show(config: {
			Title: string,
			Message: string,
			RequiredText: string,   -- what the user must type exactly
			ConfirmLabel: string?,
			OnConfirm: () -> (),
		}): ()
--]]

local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local ConfirmDialog = {}

export type ConfirmConfig = {
	Title: string,
	Message: string,
	RequiredText: string,
	ConfirmLabel: string?,
	OnConfirm: () -> (),
}

function ConfirmDialog.Show(config: ConfirmConfig)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelConfirmDialog"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 300
	screenGui.Parent = playerGui

	local backdrop = Instance.new("TextButton")
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.4
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 420, 0, 240)
	panel.BackgroundColor3 = Theme.Colors.Surface
	panel.BorderSizePixel = 0
	panel.Parent = screenGui
	Theme.corner(panel, Theme.Radius.L)
	Theme.stroke(panel, Theme.Colors.Error, 1.5)
	Theme.padding(panel, Theme.Spacing.L)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Size = UDim2.new(1, 0, 0, 26)
	titleLabel.Font = Theme.Font.Bold
	titleLabel.TextSize = 18
	titleLabel.TextColor3 = Theme.Colors.Error
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = "⚠ " .. config.Title
	titleLabel.Parent = panel

	local messageLabel = Instance.new("TextLabel")
	messageLabel.BackgroundTransparency = 1
	messageLabel.Position = UDim2.new(0, 0, 0, 34)
	messageLabel.Size = UDim2.new(1, 0, 0, 50)
	messageLabel.Font = Theme.Font.Regular
	messageLabel.TextSize = 13
	messageLabel.TextColor3 = Theme.Colors.TextSecondary
	messageLabel.TextWrapped = true
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top
	messageLabel.Text = config.Message
	messageLabel.Parent = panel

	local promptLabel = Instance.new("TextLabel")
	promptLabel.BackgroundTransparency = 1
	promptLabel.Position = UDim2.new(0, 0, 0, 92)
	promptLabel.Size = UDim2.new(1, 0, 0, 18)
	promptLabel.Font = Theme.Font.Medium
	promptLabel.TextSize = 12
	promptLabel.TextColor3 = Theme.Colors.TextSecondary
	promptLabel.TextXAlignment = Enum.TextXAlignment.Left
	promptLabel.Text = ('Type "%s" to confirm:'):format(config.RequiredText)
	promptLabel.Parent = panel

	local inputBox = Instance.new("TextBox")
	inputBox.Position = UDim2.new(0, 0, 0, 112)
	inputBox.Size = UDim2.new(1, 0, 0, 36)
	inputBox.BackgroundColor3 = Theme.Colors.SurfaceRaised
	inputBox.Font = Theme.Font.Mono
	inputBox.TextSize = 15
	inputBox.TextColor3 = Theme.Colors.Text
	inputBox.Text = ""
	inputBox.ClearTextOnFocus = false
	inputBox.Parent = panel
	Theme.corner(inputBox, Theme.Radius.S)
	Theme.padding(inputBox, 8)

	local buttonRow = Instance.new("Frame")
	buttonRow.Position = UDim2.new(0, 0, 1, -36)
	buttonRow.Size = UDim2.new(1, 0, 0, 36)
	buttonRow.BackgroundTransparency = 1
	buttonRow.Parent = panel

	local cancelButton = Instance.new("TextButton")
	cancelButton.AnchorPoint = Vector2.new(1, 0)
	cancelButton.Position = UDim2.new(1, -96, 0, 0)
	cancelButton.Size = UDim2.new(0, 88, 1, 0)
	cancelButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	cancelButton.Font = Theme.Font.Medium
	cancelButton.TextSize = 13
	cancelButton.TextColor3 = Theme.Colors.Text
	cancelButton.Text = "Cancel"
	cancelButton.Parent = buttonRow
	Theme.corner(cancelButton, Theme.Radius.S)

	local confirmButton = Instance.new("TextButton")
	confirmButton.AnchorPoint = Vector2.new(1, 0)
	confirmButton.Position = UDim2.new(1, 0, 0, 0)
	confirmButton.Size = UDim2.new(0, 88, 1, 0)
	confirmButton.BackgroundColor3 = Theme.Colors.Error
	confirmButton.BackgroundTransparency = 0.5
	confirmButton.Font = Theme.Font.Bold
	confirmButton.TextSize = 13
	confirmButton.TextColor3 = Theme.Colors.Text
	confirmButton.Text = config.ConfirmLabel or "Confirm"
	confirmButton.Active = false
	confirmButton.Parent = buttonRow
	Theme.corner(confirmButton, Theme.Radius.S)

	local function close()
		screenGui:Destroy()
	end

	inputBox:GetPropertyChangedSignal("Text"):Connect(function()
		local matches = inputBox.Text == config.RequiredText
		confirmButton.Active = matches
		confirmButton.BackgroundTransparency = if matches then 0 else 0.5
	end)

	cancelButton.MouseButton1Click:Connect(close)
	backdrop.MouseButton1Click:Connect(close)
	confirmButton.MouseButton1Click:Connect(function()
		if inputBox.Text == config.RequiredText then
			close()
			config.OnConfirm()
		end
	end)

	inputBox:CaptureFocus()
end

return ConfirmDialog
