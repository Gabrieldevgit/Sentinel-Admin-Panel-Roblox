--!strict
--[[
	QuickActionsPanel.lua

	Purpose:
		The Quick Actions section from the design doc: card-based controls
		color-coded by risk (Safe/Server/Critical), with real toggle
		switches for persistent server state (Lock Server, Maintenance
		Mode) instead of one-shot buttons that only ever turn something on.

	IMPORTANT — toggle switch visuals: the user is designing the actual
	switch look themselves. This module implements the FUNCTIONAL toggle
	(state read from the server, click flips it, color reflects on/off)
	with a plain default appearance (green pill / red pill) that's meant
	to be swapped out, not the final visual design.

	Cards included, and why others from the design doc aren't:
		- Announce (Safe): opens the Command Palette pre-filled with
		  "announce " — reuses the palette rather than building a second
		  text-input flow.
		- Freeze All (Safe): real command (`freeze all`), momentary.
		- Lock Server (Server, toggle): real command (lockserver/
		  unlockserver), reflects ServerStateService.IsLocked().
		- Maintenance Mode (Server, toggle): real command
		  (maintenancemode on/off), reflects IsMaintenanceMode().
		- Shutdown (Critical): real command, gated behind ConfirmDialog
		  requiring the exact text "SHUTDOWN" per the design doc.
		- NOT included: Heal All, Teleport Players, Restart Server (true
		  restart), Cleanup Map, Auto Moderation toggle — none of these
		  have a backing Sentinel command yet. Adding cards for
		  nonexistent commands would just produce "Unknown command"
		  errors, so they're left out until Player Controls / a real
		  restart mechanism / a map-cleanup command exist.

	Dependencies:
		Theme.lua, ConfirmDialog.lua

	Public API:
		QuickActionsPanel.Build(container: Frame, commandPalette: any): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local ConfirmDialog = require(script.Parent:WaitForChild("ConfirmDialog"))

local QuickActionsPanel = {}

local CATEGORY_COLOR_KEY = {
	Safe = "Success",
	Server = "Warning",
	Critical = "Error",
}

function QuickActionsPanel.Build(container: Frame, commandPalette: any)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local getServerStateRemote = SentinelShared:WaitForChild("GetServerStateRemote", 15) :: RemoteFunction?

	local function runCommand(text: string)
		if executeCommandRemote then
			executeCommandRemote:FireServer(text)
		end
	end

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 24)
	header.Font = Theme.Font.Bold
	header.TextSize = 16
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "⚡ Quick Actions"
	header.Parent = container

	local cardRow = Instance.new("Frame")
	cardRow.Name = "QuickActionCards"
	cardRow.Position = UDim2.new(0, 0, 0, 30)
	cardRow.Size = UDim2.new(1, 0, 0, 110)
	cardRow.BackgroundTransparency = 1
	cardRow.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = cardRow

	-- ------------------------------------------------------------------
	-- Card shell shared by both action and toggle cards
	-- ------------------------------------------------------------------
	local function makeCardShell(layoutOrder: number, icon: string, title: string, description: string, category: string): (Frame, TextLabel)
		local colorKey = CATEGORY_COLOR_KEY[category] or "TextSecondary"
		local categoryColor = (Theme.Colors :: any)[colorKey]

		local card = Instance.new("Frame")
		card.Name = title .. "Card"
		card.LayoutOrder = layoutOrder
		card.Size = UDim2.new(0, 170, 1, 0)
		card.BackgroundColor3 = Theme.Colors.Surface
		card.BorderSizePixel = 0
		card.Parent = cardRow
		Theme.corner(card, Theme.Radius.M)
		local stroke = Theme.stroke(card, categoryColor, 1)
		stroke.Transparency = 0.4
		Theme.padding(card, Theme.Spacing.S)

		local iconLabel = Instance.new("TextLabel")
		iconLabel.BackgroundTransparency = 1
		iconLabel.Size = UDim2.new(1, 0, 0, 26)
		iconLabel.Font = Theme.Font.Regular
		iconLabel.TextSize = 20
		iconLabel.TextXAlignment = Enum.TextXAlignment.Left
		iconLabel.Text = icon
		iconLabel.Parent = card

		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Position = UDim2.new(0, 0, 0, 28)
		titleLabel.Size = UDim2.new(1, 0, 0, 18)
		titleLabel.Font = Theme.Font.Bold
		titleLabel.TextSize = 13
		titleLabel.TextColor3 = Theme.Colors.Text
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Text = title
		titleLabel.Parent = card

		local descLabel = Instance.new("TextLabel")
		descLabel.BackgroundTransparency = 1
		descLabel.Position = UDim2.new(0, 0, 0, 46)
		descLabel.Size = UDim2.new(1, 0, 0, 16)
		descLabel.Font = Theme.Font.Regular
		descLabel.TextSize = 11
		descLabel.TextColor3 = Theme.Colors.TextSecondary
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.TextWrapped = true
		descLabel.Text = description
		descLabel.Parent = card

		local statusLabel = Instance.new("TextLabel")
		statusLabel.Name = "Status"
		statusLabel.BackgroundTransparency = 1
		statusLabel.Position = UDim2.new(0, 0, 1, -20)
		statusLabel.Size = UDim2.new(1, 0, 0, 18)
		statusLabel.Font = Theme.Font.Medium
		statusLabel.TextSize = 11
		statusLabel.TextColor3 = categoryColor
		statusLabel.TextXAlignment = Enum.TextXAlignment.Left
		statusLabel.Text = category
		statusLabel.Parent = card

		return card, statusLabel
	end

	-- A momentary action card: whole card is clickable, runs `onClick`.
	local function makeActionCard(layoutOrder: number, icon: string, title: string, description: string, category: string, onClick: () -> ())
		local card, statusLabel = makeCardShell(layoutOrder, icon, title, description, category)
		statusLabel.Text = if category == "Critical" then "Requires confirmation" else "Instant"

		local clickButton = Instance.new("TextButton")
		clickButton.BackgroundTransparency = 1
		clickButton.Size = UDim2.new(1, 0, 1, 0)
		clickButton.Text = ""
		clickButton.Parent = card
		clickButton.MouseButton1Click:Connect(onClick)

		-- Simple hover feedback (card "raises" per the design doc's hover spec).
		clickButton.MouseEnter:Connect(function()
			card.BackgroundColor3 = Theme.Colors.SurfaceRaised
		end)
		clickButton.MouseLeave:Connect(function()
			card.BackgroundColor3 = Theme.Colors.Surface
		end)

		return card
	end

	-- A toggle card: reflects live on/off state and flips it on click.
	-- Returns an `applyState(value)` function the caller uses to push
	-- fresh state from the server without the card needing to know how
	-- that state is fetched.
	local function makeToggleCard(
		layoutOrder: number,
		icon: string,
		title: string,
		description: string,
		onToggle: (boolean) -> ()
	): (boolean) -> ()
		local card, statusLabel = makeCardShell(layoutOrder, icon, title, description, "Server")

		-- Functional toggle switch — plain pill shape, swap the visuals
		-- here once the custom design is ready. Green = on, red = off.
		local switchTrack = Instance.new("Frame")
		switchTrack.Name = "SwitchTrack"
		switchTrack.AnchorPoint = Vector2.new(1, 1)
		switchTrack.Position = UDim2.new(1, 0, 1, -20)
		switchTrack.Size = UDim2.new(0, 40, 0, 18)
		switchTrack.BackgroundColor3 = Theme.Colors.Error
		switchTrack.BorderSizePixel = 0
		switchTrack.Parent = card
		Theme.corner(switchTrack, UDim.new(1, 0))

		local switchKnob = Instance.new("Frame")
		switchKnob.Name = "SwitchKnob"
		switchKnob.Size = UDim2.new(0, 14, 0, 14)
		switchKnob.Position = UDim2.new(0, 2, 0.5, -7)
		switchKnob.BackgroundColor3 = Color3.new(1, 1, 1)
		switchKnob.BorderSizePixel = 0
		switchKnob.Parent = switchTrack
		Theme.corner(switchKnob, UDim.new(1, 0))

		local isOn = false
		local function render()
			switchTrack.BackgroundColor3 = if isOn then Theme.Colors.Success else Theme.Colors.Error
			switchKnob.Position = if isOn then UDim2.new(1, -16, 0.5, -7) else UDim2.new(0, 2, 0.5, -7)
			statusLabel.Text = if isOn then "🟢 Enabled" else "🔴 Disabled"
			statusLabel.TextColor3 = if isOn then Theme.Colors.Success else Theme.Colors.Error
		end

		local clickButton = Instance.new("TextButton")
		clickButton.BackgroundTransparency = 1
		clickButton.Size = UDim2.new(1, 0, 1, 0)
		clickButton.Text = ""
		clickButton.Parent = card
		clickButton.MouseButton1Click:Connect(function()
			isOn = not isOn
			render() -- optimistic UI update; corrected by the next poll if the command failed
			onToggle(isOn)
		end)

		render()

		return function(value: boolean)
			isOn = value
			render()
		end
	end

	-- ------------------------------------------------------------------
	-- Cards
	-- ------------------------------------------------------------------
	makeActionCard(1, "📢", "Announce", "Broadcast a message", "Safe", function()
		if commandPalette then
			commandPalette.Open()
			task.wait()
			if commandPalette.inputBox then
				commandPalette.inputBox.Text = "announce "
				commandPalette.inputBox.CursorPosition = -1
			end
		end
	end)

	makeActionCard(2, "❄", "Freeze All", "Freeze every player", "Safe", function()
		runCommand("freeze all")
	end)

	local applyLockState = makeToggleCard(3, "🔒", "Lock Server", "Prevent new joins", function(newValue: boolean)
		runCommand(if newValue then "lockserver" else "unlockserver")
	end)

	local applyMaintenanceState = makeToggleCard(4, "🛠", "Maintenance", "Enable maintenance mode", function(newValue: boolean)
		runCommand("maintenancemode " .. (if newValue then "on" else "off"))
	end)

	makeActionCard(5, "⛔", "Shutdown", "Close this server", "Critical", function()
		ConfirmDialog.Show({
			Title = "Shutdown Server",
			Message = "This will disconnect every player currently in this server. This cannot be undone.",
			RequiredText = "SHUTDOWN",
			ConfirmLabel = "Shutdown",
			OnConfirm = function()
				runCommand("shutdown")
			end,
		})
	end)

	-- Poll live server state so the two toggle cards reflect reality
	-- (including changes made from chat/Command Palette, not just from
	-- clicking these cards).
	task.spawn(function()
		while true do
			if getServerStateRemote then
				local ok, state = pcall(function()
					return getServerStateRemote:InvokeServer()
				end)
				if ok and state then
					if state.Locked ~= nil then
						applyLockState(state.Locked)
					end
					if state.MaintenanceMode ~= nil then
						applyMaintenanceState(state.MaintenanceMode)
					end
				end
			end
			task.wait(5)
		end
	end)
end

return QuickActionsPanel
