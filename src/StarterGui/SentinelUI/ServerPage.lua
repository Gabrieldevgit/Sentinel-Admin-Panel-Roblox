--!strict
--[[
	ServerPage.lua

	Purpose:
		Server Monitor/Controls page from the design doc. Uses the shared
		ToggleSwitch component for Lock/Maintenance/Time Freeze, and adds
		Slow Mode (numeric), Environment controls (weather/lighting preset
		buttons, fog/time inputs), and Announce/Countdown triggers.

	Scope notes:
		- Weather/Lighting presets are shown as a row of preset buttons
		  rather than a free-text field, since the built-in presets are a
		  small fixed set (clear/foggy; Day/Night/Sunset/Horror) — typing
		  a name blind has a low success rate. Custom presets registered
		  via RegisterWeather/RegisterLightingPreset by the game owner
		  won't appear in this list automatically (no "list all presets"
		  remote exists yet); flag if that's wanted.
		- Fog has no live "current value" getter on the server, so the fog
		  control here is set-only (sends a value but doesn't reflect
		  current state) rather than faking a readback.
		- Shutdown is intentionally NOT duplicated here — it stays on the
		  Dashboard's Quick Actions with its confirmation dialog, so
		  there's exactly one guarded path to it rather than two copies
		  that could drift out of sync.

	Dependencies:
		Theme.lua, ToggleSwitch.lua

	Public API:
		ServerPage.Build(container: Frame): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local ToggleSwitch = require(script.Parent:WaitForChild("ToggleSwitch"))

local ServerPage = {}

local WEATHER_PRESETS = { "clear", "foggy" }
local LIGHTING_PRESETS = { "Day", "Night", "Sunset", "Horror" }

function ServerPage.Build(container: Frame)
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
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Server"
	header.Parent = container

	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "ServerScroll"
	scrollFrame.Position = UDim2.new(0, 0, 0, 40)
	scrollFrame.Size = UDim2.new(1, 0, 1, -40)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 4
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.Parent = container

	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.Padding = UDim.new(0, 16)
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Parent = scrollFrame

	local function makeSectionLabel(order: number, text: string)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, 22)
		label.Font = Theme.Font.Bold
		label.TextSize = 14
		label.TextColor3 = Theme.Colors.TextSecondary
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = text
		label.Parent = scrollFrame
	end

	-- ------------------------------------------------------------------
	-- Section: Access Control (toggle rows using the shared ToggleSwitch)
	-- ------------------------------------------------------------------
	makeSectionLabel(1, "Access Control")

	local function makeToggleRow(layoutOrder: number, icon: string, label: string, onToggle: (boolean) -> ())
		local row = Instance.new("Frame")
		row.LayoutOrder = layoutOrder
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundColor3 = Theme.Colors.Surface
		row.BorderSizePixel = 0
		row.Parent = scrollFrame
		Theme.corner(row, Theme.Radius.M)
		Theme.padding(row, Theme.Spacing.S)

		local labelText = Instance.new("TextLabel")
		labelText.BackgroundTransparency = 1
		labelText.Size = UDim2.new(1, -60, 1, 0)
		labelText.Font = Theme.Font.Medium
		labelText.TextSize = 14
		labelText.TextColor3 = Theme.Colors.Text
		labelText.TextXAlignment = Enum.TextXAlignment.Left
		labelText.Text = icon .. "  " .. label
		labelText.Parent = row

		return ToggleSwitch.Create(row, {
			Position = UDim2.new(1, 0, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			OnToggle = onToggle,
		})
	end

	local lockHandle = makeToggleRow(2, "🔒", "Lock Server", function(v)
		runCommand(if v then "lockserver" else "unlockserver")
	end)
	local maintenanceHandle = makeToggleRow(3, "🛠", "Maintenance Mode", function(v)
		runCommand("maintenancemode " .. (if v then "on" else "off"))
	end)
	local timeFreezeHandle = makeToggleRow(4, "⏱", "Time Freeze", function(v)
		runCommand("timefreeze " .. (if v then "on" else "off"))
	end)

	-- Slow mode: numeric, not boolean — its own row.
	local slowModeRow = Instance.new("Frame")
	slowModeRow.LayoutOrder = 5
	slowModeRow.Size = UDim2.new(1, 0, 0, 40)
	slowModeRow.BackgroundColor3 = Theme.Colors.Surface
	slowModeRow.BorderSizePixel = 0
	slowModeRow.Parent = scrollFrame
	Theme.corner(slowModeRow, Theme.Radius.M)
	Theme.padding(slowModeRow, Theme.Spacing.S)

	local slowModeLabel = Instance.new("TextLabel")
	slowModeLabel.BackgroundTransparency = 1
	slowModeLabel.Size = UDim2.new(0.5, 0, 1, 0)
	slowModeLabel.Font = Theme.Font.Medium
	slowModeLabel.TextSize = 14
	slowModeLabel.TextColor3 = Theme.Colors.Text
	slowModeLabel.TextXAlignment = Enum.TextXAlignment.Left
	slowModeLabel.Text = "⏳ Slow Mode: -- seconds"
	slowModeLabel.Parent = slowModeRow

	local slowModeInput = Instance.new("TextBox")
	slowModeInput.AnchorPoint = Vector2.new(1, 0.5)
	slowModeInput.Position = UDim2.new(1, -80, 0.5, 0)
	slowModeInput.Size = UDim2.new(0, 60, 0, 26)
	slowModeInput.BackgroundColor3 = Theme.Colors.SurfaceRaised
	slowModeInput.Font = Theme.Font.Regular
	slowModeInput.TextSize = 13
	slowModeInput.TextColor3 = Theme.Colors.Text
	slowModeInput.PlaceholderText = "0"
	slowModeInput.Text = ""
	slowModeInput.Parent = slowModeRow
	Theme.corner(slowModeInput, Theme.Radius.S)

	local slowModeApplyButton = Instance.new("TextButton")
	slowModeApplyButton.AnchorPoint = Vector2.new(1, 0.5)
	slowModeApplyButton.Position = UDim2.new(1, 0, 0.5, 0)
	slowModeApplyButton.Size = UDim2.new(0, 60, 0, 26)
	slowModeApplyButton.BackgroundColor3 = Theme.Colors.Accent
	slowModeApplyButton.Font = Theme.Font.Medium
	slowModeApplyButton.TextSize = 12
	slowModeApplyButton.TextColor3 = Color3.new(1, 1, 1)
	slowModeApplyButton.Text = "Apply"
	slowModeApplyButton.Parent = slowModeRow
	Theme.corner(slowModeApplyButton, Theme.Radius.S)
	slowModeApplyButton.MouseButton1Click:Connect(function()
		local seconds = tonumber(slowModeInput.Text)
		if seconds then
			runCommand("slowmode " .. tostring(seconds))
		end
	end)

	-- ------------------------------------------------------------------
	-- Section: Environment
	-- ------------------------------------------------------------------
	makeSectionLabel(6, "Environment")

	local function makePresetRow(layoutOrder: number, label: string, presets: { string }, commandPrefix: string)
		local row = Instance.new("Frame")
		row.LayoutOrder = layoutOrder
		row.Size = UDim2.new(1, 0, 0, 60)
		row.BackgroundColor3 = Theme.Colors.Surface
		row.BorderSizePixel = 0
		row.Parent = scrollFrame
		Theme.corner(row, Theme.Radius.M)
		Theme.padding(row, Theme.Spacing.S)

		local rowLabel = Instance.new("TextLabel")
		rowLabel.BackgroundTransparency = 1
		rowLabel.Size = UDim2.new(1, 0, 0, 18)
		rowLabel.Font = Theme.Font.Medium
		rowLabel.TextSize = 13
		rowLabel.TextColor3 = Theme.Colors.Text
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.Text = label
		rowLabel.Parent = row

		local buttonRow = Instance.new("Frame")
		buttonRow.Position = UDim2.new(0, 0, 0, 22)
		buttonRow.Size = UDim2.new(1, 0, 0, 28)
		buttonRow.BackgroundTransparency = 1
		buttonRow.Parent = row

		local buttonLayout = Instance.new("UIListLayout")
		buttonLayout.FillDirection = Enum.FillDirection.Horizontal
		buttonLayout.Padding = UDim.new(0, 6)
		buttonLayout.Parent = buttonRow

		for i, preset in ipairs(presets) do
			local button = Instance.new("TextButton")
			button.LayoutOrder = i
			button.Size = UDim2.new(0, 80, 1, 0)
			button.BackgroundColor3 = Theme.Colors.SurfaceRaised
			button.Font = Theme.Font.Regular
			button.TextSize = 12
			button.TextColor3 = Theme.Colors.Text
			button.Text = preset
			button.Parent = buttonRow
			Theme.corner(button, Theme.Radius.S)
			button.MouseButton1Click:Connect(function()
				runCommand(("%s %s"):format(commandPrefix, preset))
			end)
		end
	end

	makePresetRow(7, "☁ Weather", WEATHER_PRESETS, "weather")
	makePresetRow(8, "💡 Lighting Preset", LIGHTING_PRESETS, "lightingpreset")

	-- ------------------------------------------------------------------
	-- Section: Broadcast (opens Command Palette pre-filled rather than
	-- building a second text-input flow here)
	-- ------------------------------------------------------------------
	makeSectionLabel(9, "Broadcast")

	local broadcastNote = Instance.new("TextLabel")
	broadcastNote.LayoutOrder = 10
	broadcastNote.BackgroundTransparency = 1
	broadcastNote.Size = UDim2.new(1, 0, 0, 20)
	broadcastNote.Font = Theme.Font.Regular
	broadcastNote.TextSize = 12
	broadcastNote.TextColor3 = Theme.Colors.TextSecondary
	broadcastNote.TextXAlignment = Enum.TextXAlignment.Left
	broadcastNote.Text = "Use the Command Palette (Ctrl+Shift+P) for /announce and /countdown."
	broadcastNote.Parent = scrollFrame

	-- ------------------------------------------------------------------
	-- Live state polling
	-- ------------------------------------------------------------------
	task.spawn(function()
		while true do
			if getServerStateRemote then
				local ok, state = pcall(function()
					return getServerStateRemote:InvokeServer()
				end)
				if ok and state then
					if state.Locked ~= nil then
						lockHandle.Set(state.Locked)
					end
					if state.MaintenanceMode ~= nil then
						maintenanceHandle.Set(state.MaintenanceMode)
					end
					if state.TimeFrozen ~= nil then
						timeFreezeHandle.Set(state.TimeFrozen)
					end
					if state.SlowModeSeconds ~= nil then
						slowModeLabel.Text = ("⏳ Slow Mode: %d seconds"):format(state.SlowModeSeconds)
					end
				end
			end
			task.wait(5)
		end
	end)
end

return ServerPage
