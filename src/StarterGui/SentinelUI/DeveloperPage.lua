--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local DeveloperPage = {}

type TabDef = {
	Id: string,
	Label: string,
}

local TABS: { TabDef } = {
	{ Id = "Performance", Label = "📊 Performance" },
	{ Id = "Console", Label = "📋 Console" },
	{ Id = "Remotes", Label = "📡 Remotes" },
	{ Id = "DataStores", Label = "💾 DataStores" },
}

function DeveloperPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local getServerStatsRemote = SentinelShared:WaitForChild("GetServerStatsRemote", 15) :: RemoteFunction?
	local getPlayerListRemote = SentinelShared:WaitForChild("GetPlayerListRemote", 15) :: RemoteFunction?
	local getRecentLogsRemote = SentinelShared:WaitForChild("GetRecentLogsRemote", 15) :: RemoteFunction?
	local getRecentRemoteCallsRemote = SentinelShared:WaitForChild("GetRecentRemoteCallsRemote", 15) :: RemoteFunction?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Developer"
	header.Parent = container

	-- Tab bar
	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.Position = UDim2.new(0, 0, 0, 38)
	tabBar.Size = UDim2.new(1, 0, 0, 32)
	tabBar.BackgroundTransparency = 1
	tabBar.Parent = container

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabBar

	local tabContent = Instance.new("Frame")
	tabContent.Name = "TabContent"
	tabContent.Position = UDim2.new(0, 0, 0, 74)
	tabContent.Size = UDim2.new(1, 0, 1, -74)
	tabContent.BackgroundTransparency = 1
	tabContent.Parent = container

	local tabFrames: { [string]: Frame } = {}
	local activeTabId = TABS[1].Id

	local function buildPerformanceTab(): Frame
		local frame = Instance.new("Frame")
		frame.Name = "PerformanceContent"
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = tabContent

		local statsGrid = Instance.new("Frame")
		statsGrid.Name = "StatsGrid"
		statsGrid.Size = UDim2.new(1, 0, 0, 80)
		statsGrid.BackgroundTransparency = 1
		statsGrid.Parent = frame

		local gridLayout = Instance.new("UIListLayout")
		gridLayout.FillDirection = Enum.FillDirection.Horizontal
		gridLayout.Padding = UDim.new(0, 8)
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
		gridLayout.Parent = statsGrid

		local function makeStatCard(layoutOrder: number, label: string): TextLabel
			local card = Instance.new("Frame")
			card.LayoutOrder = layoutOrder
			card.Size = UDim2.new(0, 0, 1, 0)
			card.BackgroundColor3 = Theme.Colors.Surface
			card.BorderSizePixel = 0
			card.Parent = statsGrid
			Theme.corner(card, Theme.Radius.M)
			Theme.padding(card, Theme.Spacing.S)

			local cardLabel = Instance.new("TextLabel")
			cardLabel.BackgroundTransparency = 1
			cardLabel.Size = UDim2.new(1, 0, 0, 16)
			cardLabel.Font = Theme.Font.Regular
			cardLabel.TextSize = 11
			cardLabel.TextColor3 = Theme.Colors.TextSecondary
			cardLabel.TextXAlignment = Enum.TextXAlignment.Left
			cardLabel.Text = label
			cardLabel.Parent = card

			local valueLabel = Instance.new("TextLabel")
			valueLabel.Name = "Value"
			valueLabel.BackgroundTransparency = 1
			valueLabel.Position = UDim2.new(0, 0, 0, 18)
			valueLabel.Size = UDim2.new(1, 0, 0, 32)
			valueLabel.Font = Theme.Font.Black
			valueLabel.TextSize = 22
			valueLabel.TextColor3 = Theme.Colors.Text
			valueLabel.TextXAlignment = Enum.TextXAlignment.Left
			valueLabel.Text = "--"
			valueLabel.Parent = card

			card.Size = UDim2.new(0, 120, 1, 0)
			return valueLabel
		end

		local uptimeValue = makeStatCard(1, "Uptime")
		local heartbeatValue = makeStatCard(2, "Heartbeat")
		local memoryValue = makeStatCard(3, "Memory")
		local playerCountValue = makeStatCard(4, "Players")

		-- Per-player ping list
		local pingSection = Instance.new("TextLabel")
		pingSection.BackgroundTransparency = 1
		pingSection.Position = UDim2.new(0, 0, 0, 88)
		pingSection.Size = UDim2.new(1, 0, 0, 20)
		pingSection.Font = Theme.Font.Bold
		pingSection.TextSize = 13
		pingSection.TextColor3 = Theme.Colors.TextSecondary
		pingSection.TextXAlignment = Enum.TextXAlignment.Left
		pingSection.Text = "Player Ping"
		pingSection.Parent = frame

		local pingList = Instance.new("ScrollingFrame")
		pingList.Name = "PingList"
		pingList.Position = UDim2.new(0, 0, 0, 112)
		pingList.Size = UDim2.new(1, 0, 1, -112)
		pingList.BackgroundColor3 = Theme.Colors.Surface
		pingList.BorderSizePixel = 0
		pingList.ScrollBarThickness = 4
		pingList.CanvasSize = UDim2.new(0, 0, 0, 0)
		pingList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		pingList.Parent = frame
		Theme.corner(pingList, Theme.Radius.M)
		Theme.padding(pingList, Theme.Spacing.S)

		local pingLayout = Instance.new("UIListLayout")
		pingLayout.Padding = UDim.new(0, 3)
		pingLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pingLayout.Parent = pingList

		local function renderPingList(players: { { Name: string, DisplayName: string, Ping: number } })
			for _, child in ipairs(pingList:GetChildren()) do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			for i, p in ipairs(players) do
				local row = Instance.new("Frame")
				row.LayoutOrder = i
				row.Size = UDim2.new(1, 0, 0, 28)
				row.BackgroundColor3 = Theme.Colors.SurfaceRaised
				row.BorderSizePixel = 0
				row.Parent = pingList
				Theme.corner(row, Theme.Radius.S)
				Theme.padding(row, 6)

				local nameLabel = Instance.new("TextLabel")
				nameLabel.BackgroundTransparency = 1
				nameLabel.Size = UDim2.new(0.5, 0, 1, 0)
				nameLabel.Font = Theme.Font.Medium
				nameLabel.TextSize = 13
				nameLabel.TextColor3 = Theme.Colors.Text
				nameLabel.TextXAlignment = Enum.TextXAlignment.Left
				nameLabel.Text = p.DisplayName .. "  @" .. p.Name
				nameLabel.Parent = row

				local pingColor = if p.Ping < 100 then Theme.Colors.Success elseif p.Ping < 200 then Theme.Colors.Warning else Theme.Colors.Error
				local pingLabel = Instance.new("TextLabel")
				pingLabel.BackgroundTransparency = 1
				pingLabel.AnchorPoint = Vector2.new(1, 0.5)
				pingLabel.Position = UDim2.new(1, -6, 0.5, 0)
				pingLabel.Size = UDim2.new(0.5, 0, 1, 0)
				pingLabel.Font = Theme.Font.Medium
				pingLabel.TextSize = 13
				pingLabel.TextColor3 = pingColor
				pingLabel.TextXAlignment = Enum.TextXAlignment.Right
				pingLabel.Text = tostring(p.Ping) .. "ms"
				pingLabel.Parent = row
			end
		end

		task.spawn(function()
			while true do
				if getServerStatsRemote then
					local ok, stats = pcall(function()
						return getServerStatsRemote:InvokeServer()
					end)
					if ok and stats then
						local uptimeSeconds = stats.UptimeSeconds or 0
						local hours = math.floor(uptimeSeconds / 3600)
						local minutes = math.floor((uptimeSeconds % 3600) / 60)
						uptimeValue.Text = ("%dh %dm"):format(hours, minutes)
						heartbeatValue.Text = tostring(stats.HeartbeatRate) .. "/s"
						memoryValue.Text = tostring(stats.MemoryMb) .. " MB"
						playerCountValue.Text = tostring(stats.PlayerCount)
					end
				end
				if getPlayerListRemote then
					local ok, result = pcall(function()
						return getPlayerListRemote:InvokeServer()
					end)
					if ok and result then
						local players = result :: { { Name: string, DisplayName: string, Ping: number } }
						local sorted = {}
						for _, p in ipairs(players) do
							table.insert(sorted, { Name = p.Name, DisplayName = p.DisplayName, Ping = p.Ping })
						end
						table.sort(sorted, function(a, b)
							return a.Ping < b.Ping
						end)
						renderPingList(sorted)
					end
				end
				task.wait(4)
			end
		end)

		return frame
	end

	local function buildConsoleTab(): Frame
		local frame = Instance.new("Frame")
		frame.Name = "ConsoleContent"
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = tabContent

		local consoleList = Instance.new("ScrollingFrame")
		consoleList.Name = "ConsoleList"
		consoleList.Size = UDim2.new(1, 0, 1, 0)
		consoleList.BackgroundColor3 = Theme.Colors.Surface
		consoleList.BorderSizePixel = 0
		consoleList.ScrollBarThickness = 4
		consoleList.CanvasSize = UDim2.new(0, 0, 0, 0)
		consoleList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		consoleList.Parent = frame
		Theme.corner(consoleList, Theme.Radius.M)
		Theme.padding(consoleList, Theme.Spacing.S)

		local consoleLayout = Instance.new("UIListLayout")
		consoleLayout.Padding = UDim.new(0, 3)
		consoleLayout.SortOrder = Enum.SortOrder.LayoutOrder
		consoleLayout.Parent = consoleList

		local function renderEntries(entries: { { Timestamp: number, MessageType: string, Message: string } })
			for _, child in ipairs(consoleList:GetChildren()) do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			for i = #entries, 1, -1 do
				local entry = entries[i]
				local row = Instance.new("Frame")
				row.LayoutOrder = #entries - i
				row.Size = UDim2.new(1, 0, 0, 0)
				row.AutomaticSize = Enum.AutomaticSize.Y
				row.BackgroundColor3 = Theme.Colors.SurfaceRaised
				row.BorderSizePixel = 0
				row.Parent = consoleList
				Theme.corner(row, Theme.Radius.S)
				Theme.padding(row, 6)

				local isError = (entry.MessageType == "Enum.MessageType.MessageError")
				local color = if isError then Theme.Colors.Error else Theme.Colors.Warning
				local timeText = os.date("%H:%M:%S", entry.Timestamp)

				local headerLabel = Instance.new("TextLabel")
				headerLabel.BackgroundTransparency = 1
				headerLabel.Size = UDim2.new(1, 0, 0, 18)
				headerLabel.Font = Theme.Font.Medium
				headerLabel.TextSize = 12
				headerLabel.TextColor3 = color
				headerLabel.TextXAlignment = Enum.TextXAlignment.Left
				headerLabel.Text = ("[%s] %s"):format(timeText, if isError then "ERROR" else "WARNING")
				headerLabel.Parent = row

				local messageLabel = Instance.new("TextLabel")
				messageLabel.BackgroundTransparency = 1
				messageLabel.Size = UDim2.new(1, 0, 0, 0)
				messageLabel.AutomaticSize = Enum.AutomaticSize.Y
				messageLabel.Font = Theme.Font.Mono
				messageLabel.TextSize = 11
				messageLabel.TextColor3 = Theme.Colors.Text
				messageLabel.TextXAlignment = Enum.TextXAlignment.Left
				messageLabel.TextWrapped = true
				messageLabel.Text = entry.Message
				messageLabel.Parent = row
			end
		end

		local polling = false
		local function startPolling()
			if polling then
				return
			end
			polling = true
			task.spawn(function()
				while polling and frame.Visible do
					if getRecentLogsRemote then
						local ok, entries = pcall(function()
							return getRecentLogsRemote:InvokeServer(50)
						end)
						if ok and entries then
							renderEntries(entries :: { { Timestamp: number, MessageType: string, Message: string } })
						end
					end
					task.wait(3)
				end
			end)
		end

		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible then
				startPolling()
			else
				polling = false
			end
		end)

		task.delay(0.5, startPolling)

		return frame
	end

	local function buildRemotesTab(): Frame
		local frame = Instance.new("Frame")
		frame.Name = "RemotesContent"
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = tabContent

		local remoteList = Instance.new("ScrollingFrame")
		remoteList.Name = "RemoteList"
		remoteList.Size = UDim2.new(1, 0, 1, 0)
		remoteList.BackgroundColor3 = Theme.Colors.Surface
		remoteList.BorderSizePixel = 0
		remoteList.ScrollBarThickness = 4
		remoteList.CanvasSize = UDim2.new(0, 0, 0, 0)
		remoteList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		remoteList.Parent = frame
		Theme.corner(remoteList, Theme.Radius.M)
		Theme.padding(remoteList, Theme.Spacing.S)

		local remoteLayout = Instance.new("UIListLayout")
		remoteLayout.Padding = UDim.new(0, 3)
		remoteLayout.SortOrder = Enum.SortOrder.LayoutOrder
		remoteLayout.Parent = remoteList

		local function renderEntries(entries: { { Timestamp: number, Path: string, Kind: string, PlayerName: string } })
			for _, child in ipairs(remoteList:GetChildren()) do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			for i = #entries, 1, -1 do
				local entry = entries[i]
				local row = Instance.new("Frame")
				row.LayoutOrder = #entries - i
				row.Size = UDim2.new(1, 0, 0, 36)
				row.BackgroundColor3 = Theme.Colors.SurfaceRaised
				row.BorderSizePixel = 0
				row.Parent = remoteList
				Theme.corner(row, Theme.Radius.S)
				Theme.padding(row, 6)

				local timeText = os.date("%H:%M:%S", entry.Timestamp)
				local kindColor = if entry.Kind == "Event" then Theme.Colors.Accent else Theme.Colors.Warning

				local headerLabel = Instance.new("TextLabel")
				headerLabel.BackgroundTransparency = 1
				headerLabel.Size = UDim2.new(1, 0, 0, 18)
				headerLabel.Font = Theme.Font.Medium
				headerLabel.TextSize = 12
				headerLabel.TextColor3 = kindColor
				headerLabel.TextXAlignment = Enum.TextXAlignment.Left
				headerLabel.Text = ("[%s] %s (%s)"):format(timeText, entry.Kind, entry.PlayerName)
				headerLabel.Parent = row

				local pathLabel = Instance.new("TextLabel")
				pathLabel.BackgroundTransparency = 1
				pathLabel.Position = UDim2.new(0, 0, 0, 18)
				pathLabel.Size = UDim2.new(1, 0, 0, 14)
				pathLabel.Font = Theme.Font.Mono
				pathLabel.TextSize = 11
				pathLabel.TextColor3 = Theme.Colors.TextSecondary
				pathLabel.TextXAlignment = Enum.TextXAlignment.Left
				pathLabel.Text = entry.Path
				pathLabel.Parent = row
			end
		end

		local polling = false
		local function startPolling()
			if polling then
				return
			end
			polling = true
			task.spawn(function()
				while polling and frame.Visible do
					if getRecentRemoteCallsRemote then
						local ok, entries = pcall(function()
							return getRecentRemoteCallsRemote:InvokeServer(50)
						end)
						if ok and entries then
							renderEntries(entries :: { { Timestamp: number, Path: string, Kind: string, PlayerName: string } })
						end
					end
					task.wait(3)
				end
			end)
		end

		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible then
				startPolling()
			else
				polling = false
			end
		end)

		task.delay(0.5, startPolling)

		return frame
	end

	local function buildDataStoresTab(): Frame
		local frame = Instance.new("Frame")
		frame.Name = "DataStoresContent"
		frame.Size = UDim2.new(1, 0, 1, 0)
		frame.BackgroundTransparency = 1
		frame.Visible = false
		frame.Parent = tabContent

		local scroll = Instance.new("ScrollingFrame")
		scroll.Name = "DataStoreScroll"
		scroll.Size = UDim2.new(1, 0, 1, 0)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 4
		scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroll.Parent = frame

		local scrollLayout = Instance.new("UIListLayout")
		scrollLayout.Padding = UDim.new(0, 12)
		scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
		scrollLayout.Parent = scroll

		local resultBox = Instance.new("TextLabel")
		resultBox.Name = "ResultBox"
		resultBox.LayoutOrder = 99
		resultBox.BackgroundColor3 = Theme.Colors.Surface
		resultBox.BorderSizePixel = 0
		resultBox.Size = UDim2.new(1, 0, 0, 0)
		resultBox.AutomaticSize = Enum.AutomaticSize.Y
		resultBox.Font = Theme.Font.Mono
		resultBox.TextSize = 12
		resultBox.TextColor3 = Theme.Colors.Text
		resultBox.TextWrapped = true
		resultBox.Text = ""
		resultBox.Parent = scroll
		Theme.corner(resultBox, Theme.Radius.M)
		Theme.padding(resultBox, Theme.Spacing.S)

		local function runCommand(text: string)
			if executeCommandRemote then
				executeCommandRemote:FireServer(text)
			end
		end

		local function makeSectionLabel(order: number, text: string)
			local label = Instance.new("TextLabel")
			label.LayoutOrder = order
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, 0, 0, 20)
			label.Font = Theme.Font.Bold
			label.TextSize = 13
			label.TextColor3 = Theme.Colors.TextSecondary
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = text
			label.Parent = scroll
		end

		local function makeInputRow(order: number, inputs: { { Label: string, Placeholder: string, Width: number } }, actionLabel: string, onAction: ({ string }) -> ())
			local row = Instance.new("Frame")
			row.LayoutOrder = order
			row.Size = UDim2.new(1, 0, 0, 32)
			row.BackgroundColor3 = Theme.Colors.SurfaceRaised
			row.BorderSizePixel = 0
			row.Parent = scroll
			Theme.corner(row, Theme.Radius.S)
			Theme.padding(row, Theme.Spacing.S)

			local inputFields: { TextBox } = {}
			local xOffset = 0
			for i, inputDef in ipairs(inputs) do
				local inputBox = Instance.new("TextBox")
				inputBox.Name = inputDef.Label .. "Input"
				inputBox.Position = UDim2.new(0, xOffset, 0.5, -13)
				inputBox.Size = UDim2.new(0, inputDef.Width, 0, 26)
				inputBox.BackgroundColor3 = Theme.Colors.Surface
				inputBox.Font = Theme.Font.Regular
				inputBox.TextSize = 13
				inputBox.TextColor3 = Theme.Colors.Text
				inputBox.PlaceholderText = inputDef.Placeholder
				inputBox.PlaceholderColor3 = Theme.Colors.TextSecondary
				inputBox.Text = ""
				inputBox.ClearTextOnFocus = false
				inputBox.TextXAlignment = Enum.TextXAlignment.Left
				inputBox.Parent = row
				Theme.corner(inputBox, Theme.Radius.S)
				Theme.padding(inputBox, 6)
				table.insert(inputFields, inputBox)
				xOffset += inputDef.Width + 6
			end

			local actionButton = Instance.new("TextButton")
			actionButton.Position = UDim2.new(1, -60, 0.5, -13)
			actionButton.Size = UDim2.new(0, 60, 0, 26)
			actionButton.BackgroundColor3 = Theme.Colors.Accent
			actionButton.Font = Theme.Font.Medium
			actionButton.TextSize = 12
			actionButton.TextColor3 = Color3.new(1, 1, 1)
			actionButton.Text = actionLabel
			actionButton.Parent = row
			Theme.corner(actionButton, Theme.Radius.S)
			actionButton.MouseButton1Click:Connect(function()
				local values = {}
				for _, field in ipairs(inputFields) do
					table.insert(values, field.Text)
				end
				onAction(values)
			end)

			return row, inputFields
		end

		makeSectionLabel(1, "Get Key")
		makeInputRow(2, {
			{ Label = "Key", Placeholder = "Key name", Width = 180 },
		}, "Get", function(args)
			resultBox.Text = "Fetching..."
			runCommand("/datastoreget " .. args[1])
		end)

		makeSectionLabel(3, "Set Key")
		makeInputRow(4, {
			{ Label = "Key", Placeholder = "Key name", Width = 140 },
			{ Label = "Value", Placeholder = "Value (string)", Width = 180 },
		}, "Set", function(args)
			if #args[1] > 0 and #args[2] > 0 then
				resultBox.Text = "Setting..."
				runCommand("/datastoreset " .. args[1] .. " " .. args[2])
			end
		end)

		makeSectionLabel(5, "List Keys")
		makeInputRow(6, {
			{ Label = "Prefix", Placeholder = "Prefix (optional)", Width = 180 },
		}, "List", function(args)
			resultBox.Text = "Listing..."
			local prefix = if #args[1] > 0 then args[1] else ""
			runCommand("/datastorelist " .. prefix)
		end)

		local note = Instance.new("TextLabel")
		note.LayoutOrder = 7
		note.BackgroundTransparency = 1
		note.Size = UDim2.new(1, 0, 0, 20)
		note.Font = Theme.Font.Regular
		note.TextSize = 11
		note.TextColor3 = Theme.Colors.TextSecondary
		note.TextXAlignment = Enum.TextXAlignment.Left
		note.Text = "⚠ DataStore commands are Owner-only. Results appear via CommandResultRemote."
		note.Parent = scroll

		-- Listen for results
		local commandResultRemoteDS = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
		if commandResultRemoteDS then
			commandResultRemoteDS.OnClientEvent:Connect(function(results: { any })
				if #results > 0 then
					local last = results[#results]
					resultBox.Text = if last.Success then tostring(last.Message or "OK") else "Error: " .. tostring(last.Error or "?")
				end
			end)
		end

		return frame
	end

	tabFrames.Performance = buildPerformanceTab()
	tabFrames.Console = buildConsoleTab()
	tabFrames.Remotes = buildRemotesTab()
	tabFrames.DataStores = buildDataStoresTab()

	local tabButtons: { [string]: TextButton } = {}

	local function switchTab(tabId: string)
		if activeTabId == tabId then
			return
		end

		if tabButtons[activeTabId] then
			tabButtons[activeTabId].BackgroundTransparency = 1
			tabButtons[activeTabId].TextColor3 = Theme.Colors.TextSecondary
		end

		if tabFrames[activeTabId] then
			tabFrames[activeTabId].Visible = false
		end

		activeTabId = tabId

		if tabButtons[tabId] then
			tabButtons[tabId].BackgroundTransparency = 0.85
			tabButtons[tabId].TextColor3 = Theme.Colors.Text
		end

		if tabFrames[tabId] then
			tabFrames[tabId].Visible = true
		end
	end

	for i, tabDef in ipairs(TABS) do
		local button = Instance.new("TextButton")
		button.Name = tabDef.Id .. "Tab"
		button.LayoutOrder = i
		button.Size = UDim2.new(0, 130, 1, 0)
		button.BackgroundColor3 = Theme.Colors.Accent
		button.BackgroundTransparency = if tabDef.Id == activeTabId then 0.85 else 1
		button.AutoButtonColor = false
		button.Font = Theme.Font.Medium
		button.TextSize = 13
		button.TextColor3 = if tabDef.Id == activeTabId then Theme.Colors.Text else Theme.Colors.TextSecondary
		button.Text = tabDef.Label
		button.Parent = tabBar
		Theme.corner(button, Theme.Radius.S)
		button.MouseButton1Click:Connect(function()
			switchTab(tabDef.Id)
		end)
		tabButtons[tabDef.Id] = button
	end

	tabFrames[activeTabId].Visible = true
end

return DeveloperPage
