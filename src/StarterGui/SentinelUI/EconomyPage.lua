--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local EconomyPage = {}

type PlayerEconomy = {
	Coins: number,
	Gems: number,
	XP: number,
	Level: number,
}

function EconomyPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local commandResultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local getEconomySnapshotRemote = SentinelShared:WaitForChild("GetEconomySnapshotRemote", 15) :: RemoteFunction?
	local getPlayerListRemote = SentinelShared:WaitForChild("GetPlayerListRemote", 15) :: RemoteFunction?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Economy"
	header.Parent = container

	-- Left: player list
	local listFrame = Instance.new("Frame")
	listFrame.Name = "PlayerList"
	listFrame.Position = UDim2.new(0, 0, 0, 40)
	listFrame.Size = UDim2.new(0.38, -8, 1, -40)
	listFrame.BackgroundColor3 = Theme.Colors.Surface
	listFrame.BorderSizePixel = 0
	listFrame.Parent = container
	Theme.corner(listFrame, Theme.Radius.M)
	Theme.padding(listFrame, Theme.Spacing.S)

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	local allPlayersButton = Instance.new("TextButton")
	allPlayersButton.Name = "AllPlayers"
	allPlayersButton.LayoutOrder = 0
	allPlayersButton.Size = UDim2.new(1, 0, 0, 36)
	allPlayersButton.BackgroundColor3 = Theme.Colors.Accent
	allPlayersButton.BackgroundTransparency = 0.5
	allPlayersButton.AutoButtonColor = false
	allPlayersButton.Font = Theme.Font.Bold
	allPlayersButton.TextSize = 14
	allPlayersButton.TextColor3 = Theme.Colors.Text
	allPlayersButton.TextXAlignment = Enum.TextXAlignment.Left
	allPlayersButton.Text = "  👥 All Players"
	allPlayersButton.Parent = listFrame
	Theme.corner(allPlayersButton, Theme.Radius.S)

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "Search"
	searchBox.LayoutOrder = 1
	searchBox.Size = UDim2.new(1, 0, 0, 28)
	searchBox.BackgroundColor3 = Theme.Colors.SurfaceRaised
	searchBox.Font = Theme.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextColor3 = Theme.Colors.Text
	searchBox.PlaceholderText = "Search players..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Parent = listFrame
	Theme.corner(searchBox, Theme.Radius.S)
	Theme.padding(searchBox, 6)

	local playerScroll = Instance.new("ScrollingFrame")
	playerScroll.Name = "PlayerScroll"
	playerScroll.LayoutOrder = 2
	playerScroll.Size = UDim2.new(1, 0, 0, 0)
	playerScroll.BackgroundTransparency = 1
	playerScroll.BorderSizePixel = 0
	playerScroll.ScrollBarThickness = 4
	playerScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	playerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	playerScroll.Parent = listFrame

	local playerScrollLayout = Instance.new("UIListLayout")
	playerScrollLayout.Padding = UDim.new(0, 3)
	playerScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	playerScrollLayout.Parent = playerScroll

	-- Right: form panel
	local formPanel = Instance.new("ScrollingFrame")
	formPanel.Name = "FormPanel"
	formPanel.Position = UDim2.new(0.38, 8, 0, 40)
	formPanel.Size = UDim2.new(0.62, -8, 1, -40)
	formPanel.BackgroundColor3 = Theme.Colors.Surface
	formPanel.BorderSizePixel = 0
	formPanel.ScrollBarThickness = 4
	formPanel.CanvasSize = UDim2.new(0, 0, 0, 0)
	formPanel.AutomaticCanvasSize = Enum.AutomaticSize.Y
	formPanel.Parent = container
	Theme.corner(formPanel, Theme.Radius.M)
	Theme.padding(formPanel, Theme.Spacing.M)

	local formLayout = Instance.new("UIListLayout")
	formLayout.Padding = UDim.new(0, 12)
	formLayout.SortOrder = Enum.SortOrder.LayoutOrder
	formLayout.Parent = formPanel

	-- Snapshot readout (hidden in All-Players mode)
	local snapshotFrame = Instance.new("Frame")
	snapshotFrame.Name = "Snapshot"
	snapshotFrame.LayoutOrder = 1
	snapshotFrame.Size = UDim2.new(1, 0, 0, 60)
	snapshotFrame.BackgroundColor3 = Theme.Colors.SurfaceRaised
	snapshotFrame.BorderSizePixel = 0
	snapshotFrame.Visible = false
	snapshotFrame.Parent = formPanel
	Theme.corner(snapshotFrame, Theme.Radius.M)
	Theme.padding(snapshotFrame, Theme.Spacing.S)

	local snapshotLabel = Instance.new("TextLabel")
	snapshotLabel.Name = "SnapshotLabel"
	snapshotLabel.BackgroundTransparency = 1
	snapshotLabel.Size = UDim2.new(1, 0, 1, 0)
	snapshotLabel.Font = Theme.Font.Medium
	snapshotLabel.TextSize = 13
	snapshotLabel.TextColor3 = Theme.Colors.Text
	snapshotLabel.TextXAlignment = Enum.TextXAlignment.Left
	snapshotLabel.TextWrapped = true
	snapshotLabel.Text = "🪙 Coins: -- | 💎 Gems: -- | ⭐ XP: -- | 📊 Level: --"
	snapshotLabel.Parent = snapshotFrame

	-- Status line
	local statusLine = Instance.new("TextLabel")
	statusLine.Name = "Status"
	statusLine.LayoutOrder = 99
	statusLine.BackgroundTransparency = 1
	statusLine.Size = UDim2.new(1, 0, 0, 20)
	statusLine.Font = Theme.Font.Regular
	statusLine.TextSize = 12
	statusLine.TextColor3 = Theme.Colors.TextSecondary
	statusLine.TextXAlignment = Enum.TextXAlignment.Left
	statusLine.Text = ""
	statusLine.Parent = formPanel

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
		label.Parent = formPanel
		return label
	end

	local function makeFormRow(order: number, inputs: { { Label: string, Placeholder: string, Width: number } }, actionLabel: string, onAction: ({ string }) -> ())
		local row = Instance.new("Frame")
		row.LayoutOrder = order
		row.Size = UDim2.new(1, 0, 0, 32)
		row.BackgroundColor3 = Theme.Colors.SurfaceRaised
		row.BorderSizePixel = 0
		row.Parent = formPanel
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

	local selectedPlayerName: string? = nil
	local selectedUserId: number? = nil
	local isAllMode = false

	local function runCommand(text: string)
		if executeCommandRemote then
			executeCommandRemote:FireServer(text)
		end
	end

	local function doEconomyAction(command: string, target: string, args: { string })
		local fullCommand = ("/%s %s %s"):format(command, target, table.concat(args, " "))
		runCommand(fullCommand)
	end

	local function refreshSnapshot()
		if not selectedUserId or isAllMode or not getEconomySnapshotRemote then
			snapshotFrame.Visible = false
			return
		end
		local ok, data = pcall(function()
			return getEconomySnapshotRemote:InvokeServer(selectedUserId)
		end)
		if ok and data then
			snapshotFrame.Visible = true
			local eco = data :: PlayerEconomy
			snapshotLabel.Text = ("🪙 Coins: %d  |  💎 Gems: %d  |  ⭐ XP: %d  |  📊 Level: %d"):format(eco.Coins, eco.Gems, eco.XP, eco.Level)
		end
	end

	local function selectPlayer(name: string, userId: number?)
		selectedPlayerName = name
		selectedUserId = userId
		isAllMode = (userId == nil)
		refreshSnapshot()
	end

	-- All-Players mode
	allPlayersButton.MouseButton1Click:Connect(function()
		selectPlayer("all", nil)
	end)

	-- Form sections
	makeSectionLabel(10, "Coins")
	makeFormRow(11, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Give", function(args)
		doEconomyAction("givecurrency", selectedPlayerName or "all", args)
	end)
	makeFormRow(12, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Remove", function(args)
		doEconomyAction("givecurrency", selectedPlayerName or "all", { tostring(-tonumber(args[1]) or 0) })
	end)
	makeFormRow(13, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Set", function(args)
		doEconomyAction("setbalance", selectedPlayerName or "all", args)
	end)

	makeSectionLabel(14, "Gems")
	makeFormRow(15, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Give", function(args)
		doEconomyAction("addpremium", selectedPlayerName or "all", args)
	end)

	makeSectionLabel(16, "XP")
	makeFormRow(17, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Give", function(args)
		doEconomyAction("addxp", selectedPlayerName or "all", args)
	end)
	makeFormRow(18, {
		{ Label = "Amount", Placeholder = "Amount", Width = 100 },
	}, "Remove", function(args)
		doEconomyAction("addxp", selectedPlayerName or "all", { tostring(-tonumber(args[1]) or 0) })
	end)

	makeSectionLabel(19, "Level")
	makeFormRow(20, {
		{ Label = "Level", Placeholder = "Level", Width = 100 },
	}, "Set", function(args)
		doEconomyAction("setlevel", selectedPlayerName or "all", args)
	end)

	makeSectionLabel(21, "Badges")
	makeFormRow(22, {
		{ Label = "Badge ID", Placeholder = "Badge ID", Width = 140 },
	}, "Grant", function(args)
		doEconomyAction("grantbadge", selectedPlayerName or "all", args)
	end)

	-- Player list data
	local allRows: { { Name: string, DisplayName: string, UserId: number } } = {}

	local function renderPlayerList(filter: string)
		for _, child in ipairs(playerScroll:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		local lowered = filter:lower()
		local order = 0
		for _, row in ipairs(allRows) do
			if lowered == "" or row.Name:lower():find(lowered, 1, true) or row.DisplayName:lower():find(lowered, 1, true) then
				order += 1
				local button = Instance.new("TextButton")
				button.Name = row.Name
				button.LayoutOrder = order
				button.Size = UDim2.new(1, 0, 0, 32)
				button.BackgroundColor3 = Theme.Colors.SurfaceRaised
				button.AutoButtonColor = false
				button.Text = ""
				button.Parent = playerScroll
				Theme.corner(button, Theme.Radius.S)

				local nameLabel = Instance.new("TextLabel")
				nameLabel.BackgroundTransparency = 1
				nameLabel.Position = UDim2.new(0, 8, 0, 0)
				nameLabel.Size = UDim2.new(1, -12, 1, 0)
				nameLabel.Font = Theme.Font.Medium
				nameLabel.TextSize = 13
				nameLabel.TextColor3 = Theme.Colors.Text
				nameLabel.TextXAlignment = Enum.TextXAlignment.Left
				nameLabel.Text = row.DisplayName .. "  @" .. row.Name
				nameLabel.Parent = button

				button.MouseButton1Click:Connect(function()
					selectPlayer(row.Name, row.UserId)
				end)
			end
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		renderPlayerList(searchBox.Text)
	end)

	-- Listen for command results
	if commandResultRemote then
		commandResultRemote.OnClientEvent:Connect(function(results: { any })
			if #results > 0 then
				local last = results[#results]
				statusLine.Text = if last.Success then "✅ " .. (last.Message or "Done") else "❌ " .. (last.Error or "Failed")
				task.delay(5, function()
					statusLine.Text = ""
				end)
			end
		end)
	end

	-- Poll loops
	task.spawn(function()
		while true do
			if getPlayerListRemote then
				local ok, result = pcall(function()
					return getPlayerListRemote:InvokeServer()
				end)
				if ok and result then
					local list = result :: { { Name: string, DisplayName: string, UserId: number } }
					allRows = {}
					for _, p in ipairs(list) do
						table.insert(allRows, { Name = p.Name, DisplayName = p.DisplayName, UserId = p.UserId })
					end
					renderPlayerList(searchBox.Text)

					if selectedUserId and not isAllMode then
						local stillExists = false
						for _, p in ipairs(allRows) do
							if p.UserId == selectedUserId then
								stillExists = true
								break
							end
						end
						if not stillExists then
							selectPlayer("all", nil)
						end
					end
				end
			end
			task.wait(5)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(3)
			if not isAllMode and selectedUserId then
				refreshSnapshot()
			end
		end
	end)
end

return EconomyPage
