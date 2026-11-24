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
		- W22: a Server Info card (from GetServerStateRemote().Info, needs
		  server.info), Join Rules (whitelist mode, message for turned-away
		  players used by Lock / Maintenance, soft player cap) and Server
		  Actions (kick non-staff, kick all, restart = ;migrateserver,
		  shutdown with countdown). Every action is a normal command, so
		  the server's risk confirmation (ConfirmDialog) guards them.
		  Paths: ServerScroll.InfoCard.Cell_<key>.Value,
		  ServerScroll.WhitelistRow, ServerScroll.MessageRow.Input,
		  ServerScroll.CapacityRow.{Input,Apply,Clear},
		  ServerScroll.ActionsRow.Action_<name>.

	Dependencies:
		Theme.lua, ToggleSwitch.lua

	Public API:
		ServerPage.Build(container: Frame): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Icons = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Icons"))
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
		labelText.Text = Icons.text(icon, "      ") .. "  " .. label -- icon is an Icons.lua slot key
		labelText.Parent = row
		Icons.attach(labelText, icon, { Size = 18, X = 0 })

		return ToggleSwitch.Create(row, {
			Position = UDim2.new(1, 0, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			OnToggle = onToggle,
		})
	end

	-- W22: text from the Join Rules message box (filled in further down).
	local joinMessage = ""
	local function withMessage(command: string): string
		local text = joinMessage:gsub("&&", "&"):match("^%s*(.-)%s*$") or ""
		return if text ~= "" then command .. " " .. text else command
	end

	local lockHandle = makeToggleRow(2, "Lock", "Lock Server", function(v)
		runCommand(if v then withMessage("lockserver") else "unlockserver")
	end)
	local maintenanceHandle = makeToggleRow(3, "Maintenance", "Maintenance Mode", function(v)
		runCommand(if v then withMessage("maintenancemode on") else "maintenancemode off")
	end)
	local timeFreezeHandle = makeToggleRow(4, "TimeFreeze", "Time Freeze", function(v)
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
	slowModeLabel.Parent = slowModeRow
	Icons.prefix(slowModeLabel, "Slowmode", "Slow Mode: -- seconds", 18)

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
	-- W22 helpers
	-- ------------------------------------------------------------------
	local function makeRow(name: string, layoutOrder: number, height: number): Frame
		local row = Instance.new("Frame")
		row.Name = name
		row.LayoutOrder = layoutOrder
		row.Size = UDim2.new(1, 0, 0, height)
		row.BackgroundColor3 = Theme.Colors.Surface
		row.BorderSizePixel = 0
		row.Parent = scrollFrame
		Theme.corner(row, Theme.Radius.M)
		Theme.padding(row, Theme.Spacing.S)
		return row
	end

	local function smallLabel(parent: Instance, text: string, size: UDim2, color: Color3?): TextLabel
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = size
		label.Font = Theme.Font.Medium
		label.TextSize = 13
		label.TextColor3 = color or Theme.Colors.Text
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Text = text
		label.Parent = parent
		return label
	end

	local function smallButton(parent: Instance, name: string, text: string, width: number, color: Color3?): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.new(0, width, 0, 28)
		button.BackgroundColor3 = color or Theme.Colors.SurfaceRaised
		button.Font = Theme.Font.Medium
		button.TextSize = 12
		button.TextColor3 = if color then Color3.new(1, 1, 1) else Theme.Colors.Text
		button.Text = text
		button.AutoButtonColor = true
		button.Parent = parent
		Theme.corner(button, Theme.Radius.S)
		return button
	end

	local function inputBox(parent: Instance, name: string, placeholder: string, size: UDim2): TextBox
		local box = Instance.new("TextBox")
		box.Name = name
		box.Size = size
		box.BackgroundColor3 = Theme.Colors.SurfaceRaised
		box.Font = Theme.Font.Regular
		box.TextSize = 13
		box.TextColor3 = Theme.Colors.Text
		box.PlaceholderText = placeholder
		box.PlaceholderColor3 = Theme.Colors.TextSecondary
		box.Text = ""
		box.ClearTextOnFocus = false
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.Parent = parent
		Theme.corner(box, Theme.Radius.S)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 8)
		pad.PaddingRight = UDim.new(0, 8)
		pad.Parent = box
		return box
	end

	-- ------------------------------------------------------------------
	-- Section: Server Info (W22)
	-- ------------------------------------------------------------------
	makeSectionLabel(-10, "Server Info")

	local infoCard = Instance.new("Frame")
	infoCard.Name = "InfoCard"
	infoCard.LayoutOrder = -9
	infoCard.Size = UDim2.new(1, 0, 0, 0)
	infoCard.AutomaticSize = Enum.AutomaticSize.Y
	infoCard.BackgroundColor3 = Theme.Colors.Surface
	infoCard.BorderSizePixel = 0
	infoCard.Parent = scrollFrame
	Theme.corner(infoCard, Theme.Radius.M)
	Theme.padding(infoCard, Theme.Spacing.S)

	local infoLayout = Instance.new("UIListLayout")
	infoLayout.FillDirection = Enum.FillDirection.Horizontal
	infoLayout.Wraps = true
	infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
	infoLayout.Padding = UDim.new(0, 8)
	infoLayout.Parent = infoCard

	local INFO_CELLS = {
		{ "Server", "Server id" },
		{ "Version", "Place version" },
		{ "Players", "Players" },
		{ "Uptime", "Uptime" },
		{ "Status", "Status" },
		{ "Health", "Health" },
		{ "Heartbeat", "Heartbeat" },
		{ "Memory", "Memory" },
		{ "Ping", "Average ping" },
		{ "Staff", "Staff online" },
		{ "Type", "Server type" },
		{ "Location", "Location" },
		{ "Events", "Active events" },
		{ "Polls", "Active polls" },
	}
	local infoValues: { [string]: TextLabel } = {}
	for i, cell in ipairs(INFO_CELLS) do
		local frame = Instance.new("Frame")
		frame.Name = "Cell_" .. cell[1]
		frame.LayoutOrder = i
		frame.Size = UDim2.new(0, 150, 0, 40)
		frame.BackgroundTransparency = 1
		frame.Parent = infoCard
		smallLabel(frame, cell[2], UDim2.new(1, 0, 0, 16), Theme.Colors.TextSecondary).TextSize = 11
		local value = smallLabel(frame, "-", UDim2.new(1, 0, 0, 20))
		value.Name = "Value"
		value.Position = UDim2.new(0, 0, 0, 18)
		value.Font = Theme.Font.Bold
		infoValues[cell[1]] = value
	end
	-- The full JobId, selectable for copying.
	local jobIdBox = inputBox(infoCard, "JobId", "", UDim2.new(1, 0, 0, 24))
	jobIdBox.LayoutOrder = 100
	jobIdBox.TextEditable = false
	jobIdBox.TextSize = 11
	jobIdBox.TextColor3 = Theme.Colors.TextSecondary

	local function formatUptime(seconds: number): string
		local h = math.floor(seconds / 3600)
		local m = math.floor(seconds % 3600 / 60)
		return if h > 0 then ("%dh %dm"):format(h, m) else ("%dm %ds"):format(m, seconds % 60)
	end

	local function renderInfo(info: any)
		if type(info) ~= "table" then
			infoValues.Server.Text = "No access"
			return
		end
		local status = {}
		if info.Locked then
			table.insert(status, "Locked")
		end
		if info.Maint then
			table.insert(status, "Maintenance")
		end
		if info.Whitelist then
			table.insert(status, "Whitelist")
		end
		if info.Cap then
			table.insert(status, "Cap " .. tostring(info.Cap))
		end
		infoValues.Server.Text = tostring(info.ShortId or "-")
		infoValues.Version.Text = "v" .. tostring(info.Ver or 0)
		infoValues.Players.Text = ("%d / %d"):format(info.N or 0, info.Max or 0)
		infoValues.Uptime.Text = formatUptime(info.Uptime or 0)
		infoValues.Status.Text = if #status > 0 then table.concat(status, ", ") else "Open"
		local health = tostring(info.Health or "-")
		infoValues.Health.Text = health:sub(1, 1):upper() .. health:sub(2)
		infoValues.Health.TextColor3 = if health == "good"
			then Theme.Colors.Success
			elseif health == "fair" then Theme.Colors.Warning
			else Theme.Colors.Error
		infoValues.Heartbeat.Text = tostring(info.Fps or 0) .. " /s"
		infoValues.Memory.Text = tostring(info.Mem or 0) .. " MB"
		infoValues.Ping.Text = tostring(info.Ping or 0) .. " ms"
		local staff = if type(info.Staff) == "table" then info.Staff else {}
		infoValues.Staff.Text = if #staff > 0 then ("%d: %s"):format(#staff, table.concat(staff, ", ")) else "None"
		infoValues.Type.Text = if info.Studio
			then "Studio"
			elseif info.Reserved then "Reserved"
			elseif info.Priv then "Private (" .. tostring(info.PrivateAccess) .. ")"
			else "Public"
		infoValues.Location.Text = if info.Location then tostring(info.Location) else "Not available"
		infoValues.Events.Text = if type(info.Events) == "table" and #info.Events > 0 then table.concat(info.Events, ", ") else "None"
		-- W23: { Id, Question, Scope, Votes, EndsAt } per active poll.
		local pollNames = {}
		for _, p in ipairs(if type(info.Polls) == "table" then info.Polls else {}) do
			if type(p) == "table" then
				table.insert(pollNames, ("%s (%d vote%s)"):format(tostring(p.Question), tonumber(p.Votes) or 0, if p.Votes == 1 then "" else "s"))
			else
				table.insert(pollNames, tostring(p))
			end
		end
		infoValues.Polls.Text = if #pollNames > 0 then table.concat(pollNames, ", ") else "None"
		jobIdBox.Text = "JobId: " .. tostring(info.Id or "-")
	end

	-- ------------------------------------------------------------------
	-- Section: Join Rules (W22)
	-- ------------------------------------------------------------------
	makeSectionLabel(50, "Join Rules")

	local whitelistHandle = makeToggleRow(51, "Lock", "Whitelist Mode (every server)", function(v)
		runCommand("whitelistmode " .. (if v then "on" else "off"))
	end)

	local messageRow = makeRow("MessageRow", 52, 62)
	smallLabel(messageRow, "Message for turned-away players (used when you turn on Lock or Maintenance)", UDim2.new(1, 0, 0, 18), Theme.Colors.TextSecondary)
	local messageInput = inputBox(messageRow, "Input", "Default message", UDim2.new(1, 0, 0, 26))
	messageInput.Position = UDim2.new(0, 0, 0, 22)
	messageInput:GetPropertyChangedSignal("Text"):Connect(function()
		joinMessage = messageInput.Text
	end)

	local capacityRow = makeRow("CapacityRow", 53, 40)
	local capacityLabel = smallLabel(capacityRow, "Soft player cap: off", UDim2.new(1, -230, 1, 0))
	local capacityInput = inputBox(capacityRow, "Input", "Players", UDim2.new(0, 70, 0, 26))
	capacityInput.AnchorPoint = Vector2.new(1, 0.5)
	capacityInput.Position = UDim2.new(1, -150, 0.5, 0)
	local capacityApply = smallButton(capacityRow, "Apply", "Apply", 64, Theme.Colors.Accent)
	capacityApply.AnchorPoint = Vector2.new(1, 0.5)
	capacityApply.Position = UDim2.new(1, -78, 0.5, 0)
	local capacityClear = smallButton(capacityRow, "Clear", "Off", 70)
	capacityClear.AnchorPoint = Vector2.new(1, 0.5)
	capacityClear.Position = UDim2.new(1, 0, 0.5, 0)
	capacityApply.MouseButton1Click:Connect(function()
		local n = tonumber(capacityInput.Text)
		if n then
			runCommand("servercap " .. tostring(math.floor(n)))
		end
	end)
	capacityClear.MouseButton1Click:Connect(function()
		runCommand("servercap off")
	end)

	-- ------------------------------------------------------------------
	-- Section: Server Actions (W22)
	-- ------------------------------------------------------------------
	makeSectionLabel(60, "Server Actions")

	local actionsRow = makeRow("ActionsRow", 61, 0)
	actionsRow.AutomaticSize = Enum.AutomaticSize.Y
	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.Wraps = true
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, 6)
	actionsLayout.Parent = actionsRow

	local ACTIONS = {
		{ "KickNonStaff", "Kick non-staff", "kicknonstaff" },
		{ "KickAll", "Kick all", "kickall" },
		{ "Restart", "Restart (30s)", "migrateserver 30" },
		{ "Shutdown", "Shutdown (30s)", "shutdown 30" },
	}
	for i, action in ipairs(ACTIONS) do
		local button = smallButton(actionsRow, "Action_" .. action[1], action[2], 120, if i >= 3 then Theme.Colors.Error else nil)
		button.LayoutOrder = i
		button.MouseButton1Click:Connect(function()
			local command = action[3]
			if command:match("^kick") then
				command = withMessage(command)
			end
			runCommand(command)
		end)
	end
	local actionsNote = smallLabel(actionsRow, "Each action asks for confirmation. Restart moves players to a fresh server; Shutdown just ends this one.", UDim2.new(1, 0, 0, 18), Theme.Colors.TextSecondary)
	actionsNote.LayoutOrder = 10
	actionsNote.TextSize = 11
	actionsNote.TextWrapped = true
	actionsNote.TextTruncate = Enum.TextTruncate.None
	actionsNote.AutomaticSize = Enum.AutomaticSize.Y

	-- ------------------------------------------------------------------
	-- Section: Environment
	-- ------------------------------------------------------------------
	makeSectionLabel(106, "Environment")

	local function makePresetRow(layoutOrder: number, iconKey: string, label: string, presets: { string }, commandPrefix: string)
		local row = Instance.new("Frame")
		row.LayoutOrder = layoutOrder
		-- W09 (known issue #1): the buttons wrap onto more lines when the
		-- panel is narrow, and the row grows to fit them.
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
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
		rowLabel.Parent = row
		Icons.prefix(rowLabel, iconKey, label, 16)

		local buttonRow = Instance.new("Frame")
		buttonRow.Position = UDim2.new(0, 0, 0, 22)
		buttonRow.Size = UDim2.new(1, 0, 0, 0)
		buttonRow.AutomaticSize = Enum.AutomaticSize.Y
		buttonRow.BackgroundTransparency = 1
		buttonRow.Parent = row

		local buttonLayout = Instance.new("UIListLayout")
		buttonLayout.FillDirection = Enum.FillDirection.Horizontal
		buttonLayout.Wraps = true
		buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
		buttonLayout.Padding = UDim.new(0, 6)
		buttonLayout.Parent = buttonRow

		for i, preset in ipairs(presets) do
			local button = Instance.new("TextButton")
			button.LayoutOrder = i
			button.Size = UDim2.new(0, 80, 0, 28)
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

	makePresetRow(107, "Weather", "Weather", WEATHER_PRESETS, "weather")
	makePresetRow(108, "Lighting", "Lighting Preset", LIGHTING_PRESETS, "lightingpreset")

	-- ------------------------------------------------------------------
	-- Section: Broadcast (opens Command Palette pre-filled rather than
	-- building a second text-input flow here)
	-- ------------------------------------------------------------------
	makeSectionLabel(109, "Broadcast")

	local broadcastNote = Instance.new("TextLabel")
	broadcastNote.LayoutOrder = 110
	broadcastNote.BackgroundTransparency = 1
	broadcastNote.Size = UDim2.new(1, 0, 0, 20)
	broadcastNote.Font = Theme.Font.Regular
	broadcastNote.TextSize = 12
	broadcastNote.TextColor3 = Theme.Colors.TextSecondary
	broadcastNote.TextXAlignment = Enum.TextXAlignment.Left
	broadcastNote.Text = "Use the Command Palette (Ctrl+K) for /announce and /countdown."
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
					local info = state.Info
					renderInfo(info)
					if type(info) == "table" then
						whitelistHandle.Set(info.Whitelist == true)
						capacityLabel.Text = if info.Cap
							then ("Soft player cap: %d of %d"):format(info.Cap, info.Max or 0)
							else ("Soft player cap: off (Roblox maximum %d)"):format(info.Max or 0)
					end
					if state.SlowModeSeconds ~= nil then
						Icons.prefix(slowModeLabel, "Slowmode", ("Slow Mode: %d seconds"):format(state.SlowModeSeconds), 18)
					end
				end
			end
			task.wait(5)
		end
	end)
end

return ServerPage
