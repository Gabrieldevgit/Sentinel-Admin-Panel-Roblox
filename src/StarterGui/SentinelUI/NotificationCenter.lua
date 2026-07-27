--!strict
--[[
	NotificationCenter.lua

	Purpose:
		Phase 7D from the roadmap: toast popups + a persistent log panel.
		Replaces the placeholder feedback channel noted in
		`init.server.lua`'s chat hook ("Placeholder feedback channel;
		Phase 7 UI replaces this with a proper notification system.") —
		that hook now fires the same `CommandResultRemote` the UI already
		used, so this single module covers feedback for BOTH chat-typed
		and UI-issued commands.

	Design notes:
		- Reuses the shape of the old Admin Panel V4.3's toast system
		  (`reference/OldAdminPanel/extracted_source_fragments.txt`,
		  `showNotification`) as a starting point — slide-in-from-the-
		  right, dismiss button, theme-colored border — but stacks
		  multiple toasts at once instead of a strict one-at-a-time
		  queue, and pulls colors/fonts from `Theme.lua` instead of the
		  old panel's own `Config.THEMES` table.
		- The toast overlay is its own top-level ScreenGui, independent of
		  Shell's — so a toast still shows even if the player has closed
		  the main panel (F6) after firing a command, matching how the
		  old panel's notifications worked.
		- Only `CommandResultRemote` feeds this — there's no separate
		  server-side alert/event stream for things like "another admin
		  changed server state," so the persistent log is honestly scoped
		  to "results of commands that ran because of something this
		  client did" (via chat OR the UI), not a general activity feed.
		  That's a real, current backend limitation, not a UI oversight.
		- History is an in-memory ring buffer (last 100), since nothing
		  server-side persists it either — it resets on rejoin, same as
		  the old panel's in-session-only toasts.

	Dependencies:
		Theme.lua

	Public API:
		NotificationCenter.Init(): () -- mounts the toast overlay + starts
			listening to CommandResultRemote. Call once.
		NotificationCenter.BuildPage(container: Frame): () -- builds the
			persistent log page. Call once, after Init().
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local NotificationCenter = {}

type HistoryEntry = {
	Timestamp: number,
	Success: boolean,
	Message: string,
}

local MAX_HISTORY = 100
local TOAST_WIDTH = 320
local SUCCESS_DURATION = 4
local ERROR_DURATION = 6

local history: { HistoryEntry } = {}
local historyChanged: (() -> ())? = nil
local initialized = false

local function pushHistory(entry: HistoryEntry)
	table.insert(history, entry)
	if #history > MAX_HISTORY then
		table.remove(history, 1)
	end
	if historyChanged then
		historyChanged()
	end
end

-- ---------------------------------------------------------------------------
-- Toast overlay
-- ---------------------------------------------------------------------------
function NotificationCenter.Init()
	if initialized then
		return
	end
	initialized = true

	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelNotifications"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 60 -- above Shell (50), so toasts show even while the panel is closed
	screenGui.Parent = playerGui

	local stack = Instance.new("Frame")
	stack.Name = "ToastStack"
	stack.AnchorPoint = Vector2.new(1, 1)
	stack.Position = UDim2.new(1, -16, 1, -16)
	stack.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.BackgroundTransparency = 1
	stack.Parent = screenGui

	local stackLayout = Instance.new("UIListLayout")
	stackLayout.Padding = UDim.new(0, 8)
	stackLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stackLayout.Parent = stack

	local toastOrder = 0

	local function showToast(success: boolean, message: string)
		toastOrder += 1
		local order = toastOrder

		local frame = Instance.new("Frame")
		frame.LayoutOrder = order
		frame.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
		frame.AutomaticSize = Enum.AutomaticSize.Y
		frame.BackgroundColor3 = Theme.Colors.Surface
		frame.BorderSizePixel = 0
		frame.Parent = stack
		Theme.corner(frame, Theme.Radius.M)
		Theme.stroke(frame, if success then Theme.Colors.Success else Theme.Colors.Error, 1)
		Theme.padding(frame, Theme.Spacing.S)

		local innerLayout = Instance.new("UIListLayout")
		innerLayout.Padding = UDim.new(0, 2)
		innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
		innerLayout.Parent = frame

		local titleRow = Instance.new("Frame")
		titleRow.LayoutOrder = 1
		titleRow.Size = UDim2.new(1, 0, 0, 20)
		titleRow.BackgroundTransparency = 1
		titleRow.Parent = frame

		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Size = UDim2.new(1, -24, 1, 0)
		titleLabel.Font = Theme.Font.Bold
		titleLabel.TextSize = 14
		titleLabel.TextColor3 = if success then Theme.Colors.Success else Theme.Colors.Error
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Text = if success then "✅ Success" else "❌ Failed"
		titleLabel.Parent = titleRow

		local dismissButton = Instance.new("TextButton")
		dismissButton.AnchorPoint = Vector2.new(1, 0)
		dismissButton.Position = UDim2.new(1, 0, 0, 0)
		dismissButton.Size = UDim2.new(0, 20, 0, 20)
		dismissButton.BackgroundTransparency = 1
		dismissButton.Font = Theme.Font.Medium
		dismissButton.TextSize = 14
		dismissButton.TextColor3 = Theme.Colors.TextSecondary
		dismissButton.Text = "✕"
		dismissButton.Parent = titleRow

		local messageLabel = Instance.new("TextLabel")
		messageLabel.LayoutOrder = 2
		messageLabel.BackgroundTransparency = 1
		messageLabel.Size = UDim2.new(1, 0, 0, 0)
		messageLabel.AutomaticSize = Enum.AutomaticSize.Y
		messageLabel.Font = Theme.Font.Regular
		messageLabel.TextSize = 13
		messageLabel.TextColor3 = Theme.Colors.Text
		messageLabel.TextWrapped = true
		messageLabel.TextXAlignment = Enum.TextXAlignment.Left
		messageLabel.Text = message
		messageLabel.Parent = frame

		local dismissed = false
		local function dismiss()
			if dismissed then
				return
			end
			dismissed = true
			local tweenOut = TweenService:Create(frame, Theme.Motion.Fast, { BackgroundTransparency = 1 })
			tweenOut:Play()
			for _, descendant in ipairs(frame:GetDescendants()) do
				if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
					TweenService:Create(descendant, Theme.Motion.Fast, { TextTransparency = 1 }):Play()
				elseif descendant:IsA("UIStroke") then
					TweenService:Create(descendant, Theme.Motion.Fast, { Transparency = 1 }):Play()
				end
			end
			task.wait(Theme.Motion.Fast.Time)
			frame:Destroy()
		end

		dismissButton.MouseButton1Click:Connect(dismiss)

		-- Fade/slide in.
		frame.BackgroundTransparency = 1
		for _, descendant in ipairs(frame:GetDescendants()) do
			if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
				descendant.TextTransparency = 1
			end
		end
		local tweenIn = TweenService:Create(frame, Theme.Motion.Normal, { BackgroundTransparency = 0 })
		tweenIn:Play()
		for _, descendant in ipairs(frame:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				TweenService:Create(descendant, Theme.Motion.Normal, { TextTransparency = 0 }):Play()
			elseif descendant:IsA("TextButton") then
				TweenService:Create(descendant, Theme.Motion.Normal, { TextTransparency = 0 }):Play()
			end
		end

		task.delay(if success then SUCCESS_DURATION else ERROR_DURATION, dismiss)
	end

	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local commandResultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	if commandResultRemote then
		commandResultRemote.OnClientEvent:Connect(function(results: { any })
			for _, result in ipairs(results) do
				if result.Message then
					showToast(result.Success == true, result.Message)
					pushHistory({
						Timestamp = os.time(),
						Success = result.Success == true,
						Message = result.Message,
					})
				end
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Persistent log page
-- ---------------------------------------------------------------------------
function NotificationCenter.BuildPage(container: Frame)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Notifications"
	header.Parent = container

	local subHeader = Instance.new("TextLabel")
	subHeader.BackgroundTransparency = 1
	subHeader.Position = UDim2.new(0, 0, 0, 30)
	subHeader.Size = UDim2.new(1, -90, 0, 20)
	subHeader.Font = Theme.Font.Regular
	subHeader.TextSize = 12
	subHeader.TextColor3 = Theme.Colors.TextSecondary
	subHeader.TextXAlignment = Enum.TextXAlignment.Left
	subHeader.Text = "Results of commands run this session, via chat or this panel. Resets on rejoin."
	subHeader.Parent = container

	local clearButton = Instance.new("TextButton")
	clearButton.AnchorPoint = Vector2.new(1, 0)
	clearButton.Position = UDim2.new(1, 0, 0, 4)
	clearButton.Size = UDim2.new(0, 80, 0, 24)
	clearButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	clearButton.Font = Theme.Font.Medium
	clearButton.TextSize = 12
	clearButton.TextColor3 = Theme.Colors.TextSecondary
	clearButton.Text = "Clear"
	clearButton.Parent = container
	Theme.corner(clearButton, Theme.Radius.S)

	local listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Position = UDim2.new(0, 0, 0, 58)
	listFrame.Size = UDim2.new(1, 0, 1, -58)
	listFrame.BackgroundColor3 = Theme.Colors.Surface
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = container
	Theme.corner(listFrame, Theme.Radius.M)
	Theme.padding(listFrame, Theme.Spacing.S)

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.Name = "EmptyState"
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Size = UDim2.new(1, 0, 0, 40)
	emptyLabel.Font = Theme.Font.Regular
	emptyLabel.TextSize = 13
	emptyLabel.TextColor3 = Theme.Colors.TextSecondary
	emptyLabel.Text = "No notifications yet this session."
	emptyLabel.Visible = false
	emptyLabel.Parent = listFrame

	local function render()
		for _, child in ipairs(listFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		if #history == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- Most recent first.
		for i = #history, 1, -1 do
			local entry = history[i]
			local row = Instance.new("Frame")
			row.LayoutOrder = #history - i
			row.Size = UDim2.new(1, 0, 0, 36)
			row.BackgroundColor3 = Theme.Colors.SurfaceRaised
			row.BorderSizePixel = 0
			row.Parent = listFrame
			Theme.corner(row, Theme.Radius.S)

			local sideBar = Instance.new("Frame")
			sideBar.BorderSizePixel = 0
			sideBar.Size = UDim2.new(0, 3, 1, 0)
			sideBar.BackgroundColor3 = if entry.Success then Theme.Colors.Success else Theme.Colors.Error
			sideBar.Parent = row
			Theme.corner(sideBar, UDim.new(0, 2))

			local timeText = os.date("%H:%M:%S", entry.Timestamp)
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Position = UDim2.new(0, 12, 0, 2)
			label.Size = UDim2.new(1, -24, 1, -4)
			label.Font = Theme.Font.Regular
			label.TextSize = 13
			label.TextColor3 = Theme.Colors.Text
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextWrapped = true
			label.Text = ("[%s] %s"):format(tostring(timeText), entry.Message)
			label.Parent = row
		end
	end

	historyChanged = render
	clearButton.MouseButton1Click:Connect(function()
		table.clear(history)
		render()
	end)

	render()
end

return NotificationCenter
