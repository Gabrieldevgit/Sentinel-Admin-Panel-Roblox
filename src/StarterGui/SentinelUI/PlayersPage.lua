--!strict
--[[
	PlayersPage.lua

	Purpose:
		Player Explorer from the design doc: a searchable table (Name/Team/
		Health/Ping/Role) with a detail panel on selection. This slice
		covers the Overview tab with a Kick action button plus real toggle
		switches for Freeze/Jail/Mute (these are reversible states, not
		one-shot actions, so a toggle reflecting live status is correct
		here — unlike Kick, which has no "undo"). Inventory/Statistics/
		Moderation History/Permissions/Session/Notes tabs are follow-up
		increments (each needs its own read remote in UIBridge).

	Dependencies:
		Theme.lua

	Public API:
		PlayersPage.Build(container: Frame): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local PlayersPage = {}

type PlayerRow = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Team: string?,
	Health: number?,
	MaxHealth: number?,
	Ping: number,
	Roles: { string },
	IsFrozen: boolean,
	IsJailed: boolean,
	IsMuted: boolean,
}

function PlayersPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getPlayerListRemote = SentinelShared:WaitForChild("GetPlayerListRemote", 15) :: RemoteFunction?
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Players"
	header.Parent = container

	local searchBox = Instance.new("TextBox")
	searchBox.Name = "Search"
	searchBox.Position = UDim2.new(0, 0, 0, 40)
	searchBox.Size = UDim2.new(0.4, 0, 0, 32)
	searchBox.BackgroundColor3 = Theme.Colors.Surface
	searchBox.Font = Theme.Font.Regular
	searchBox.TextSize = 14
	searchBox.TextColor3 = Theme.Colors.Text
	searchBox.PlaceholderText = "Search players..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Parent = container
	Theme.corner(searchBox, Theme.Radius.S)
	Theme.padding(searchBox, 8)

	-- ------------------------------------------------------------------
	-- Table (left) + detail panel (right)
	-- ------------------------------------------------------------------
	local tableFrame = Instance.new("ScrollingFrame")
	tableFrame.Name = "Table"
	tableFrame.Position = UDim2.new(0, 0, 0, 82)
	tableFrame.Size = UDim2.new(0.58, -8, 1, -82)
	tableFrame.BackgroundColor3 = Theme.Colors.Surface
	tableFrame.BorderSizePixel = 0
	tableFrame.ScrollBarThickness = 4
	tableFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	tableFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	tableFrame.Parent = container
	Theme.corner(tableFrame, Theme.Radius.M)
	Theme.padding(tableFrame, Theme.Spacing.S)

	local tableLayout = Instance.new("UIListLayout")
	tableLayout.Padding = UDim.new(0, 4)
	tableLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tableLayout.Parent = tableFrame

	local detailPanel = Instance.new("Frame")
	detailPanel.Name = "DetailPanel"
	detailPanel.Position = UDim2.new(0.58, 8, 0, 82)
	detailPanel.Size = UDim2.new(0.42, -8, 1, -82)
	detailPanel.BackgroundColor3 = Theme.Colors.Surface
	detailPanel.BorderSizePixel = 0
	detailPanel.Parent = container
	Theme.corner(detailPanel, Theme.Radius.M)

	local detailEmptyLabel = Instance.new("TextLabel")
	detailEmptyLabel.Name = "EmptyState"
	detailEmptyLabel.BackgroundTransparency = 1
	detailEmptyLabel.Size = UDim2.new(1, 0, 1, 0)
	detailEmptyLabel.Font = Theme.Font.Regular
	detailEmptyLabel.TextSize = 13
	detailEmptyLabel.TextColor3 = Theme.Colors.TextSecondary
	detailEmptyLabel.Text = "Select a player to view details."
	detailEmptyLabel.Parent = detailPanel

	local detailScroll = Instance.new("ScrollingFrame")
	detailScroll.Name = "DetailScroll"
	detailScroll.Size = UDim2.new(1, 0, 1, 0)
	detailScroll.BackgroundTransparency = 1
	detailScroll.BorderSizePixel = 0
	detailScroll.ScrollBarThickness = 4
	detailScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	detailScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	detailScroll.Parent = detailPanel
	Theme.padding(detailScroll, Theme.Spacing.M)

	local detailLayout = Instance.new("UIListLayout")
	detailLayout.Padding = UDim.new(0, 8)
	detailLayout.SortOrder = Enum.SortOrder.LayoutOrder
	detailLayout.Parent = detailScroll

	local detailName = Instance.new("TextLabel")
	detailName.Name = "Name"
	detailName.BackgroundTransparency = 1
	detailName.Size = UDim2.new(1, 0, 0, 26)
	detailName.Font = Theme.Font.Bold
	detailName.TextSize = 18
	detailName.TextColor3 = Theme.Colors.Text
	detailName.TextXAlignment = Enum.TextXAlignment.Left
	detailName.Visible = false
	detailName.Parent = detailScroll

	local detailInfo = Instance.new("TextLabel")
	detailInfo.Name = "Info"
	detailInfo.BackgroundTransparency = 1
	detailInfo.Size = UDim2.new(1, 0, 0, 60)
	detailInfo.Font = Theme.Font.Regular
	detailInfo.TextSize = 13
	detailInfo.TextColor3 = Theme.Colors.TextSecondary
	detailInfo.TextXAlignment = Enum.TextXAlignment.Left
	detailInfo.TextYAlignment = Enum.TextYAlignment.Top
	detailInfo.TextWrapped = true
	detailInfo.Visible = false
	detailInfo.Parent = detailScroll

	local actionsRow = Instance.new("Frame")
	actionsRow.Name = "Actions"
	actionsRow.Size = UDim2.new(1, 0, 0, 0)
	actionsRow.AutomaticSize = Enum.AutomaticSize.Y
	actionsRow.BackgroundTransparency = 1
	actionsRow.Visible = false
	actionsRow.Parent = detailScroll

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.Padding = UDim.new(0, 8)
	actionsLayout.Wraps = true
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Parent = actionsRow

	-- Freeze/Jail/Mute are reversible states, not one-shot actions — each
	-- gets a toggle row (label + switch) reflecting live status, matching
	-- the same pattern as the Dashboard's Quick Actions toggles. Kick has
	-- no "undo" concept, so it stays a plain button above these.
	local togglesFrame = Instance.new("Frame")
	togglesFrame.Name = "Toggles"
	togglesFrame.Size = UDim2.new(1, 0, 0, 0)
	togglesFrame.AutomaticSize = Enum.AutomaticSize.Y
	togglesFrame.BackgroundTransparency = 1
	togglesFrame.Visible = false
	togglesFrame.Parent = detailScroll

	local togglesLayout = Instance.new("UIListLayout")
	togglesLayout.Padding = UDim.new(0, 6)
	togglesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	togglesLayout.Parent = togglesFrame

	local tabsNote = Instance.new("TextLabel")
	tabsNote.Name = "TabsNote"
	tabsNote.Size = UDim2.new(1, 0, 0, 40)
	tabsNote.BackgroundColor3 = Theme.Colors.SurfaceRaised
	tabsNote.Font = Theme.Font.Regular
	tabsNote.TextSize = 12
	tabsNote.TextColor3 = Theme.Colors.TextSecondary
	tabsNote.TextWrapped = true
	tabsNote.Text = "Inventory / Statistics / Moderation History / Permissions / Session / Notes tabs are coming in a follow-up pass."
	tabsNote.Visible = false
	tabsNote.Parent = detailScroll
	Theme.corner(tabsNote, Theme.Radius.S)
	Theme.padding(tabsNote, Theme.Spacing.S)

	local selectedRow: TextButton? = nil
	local selectedUserId: number? = nil

	local function runQuickAction(commandText: string)
		if executeCommandRemote then
			executeCommandRemote:FireServer(commandText)
		end
	end

	local function makeActionButton(parent: Instance, layoutOrder: number, label: string, onClick: () -> ())
		local button = Instance.new("TextButton")
		button.LayoutOrder = layoutOrder
		button.Size = UDim2.new(1, 0, 0, 34)
		button.BackgroundColor3 = Theme.Colors.SurfaceRaised
		button.AutoButtonColor = true
		button.Font = Theme.Font.Medium
		button.TextSize = 13
		button.TextColor3 = Theme.Colors.Text
		button.Text = label
		button.Parent = parent
		Theme.corner(button, Theme.Radius.S)
		button.MouseButton1Click:Connect(onClick)
		return button
	end

	-- A toggle row: label on the left, a small switch on the right. Same
	-- functional pattern as QuickActionsPanel's toggle cards (plain green/
	-- red pill visuals — swap once the custom switch design is ready).
	-- `initialState` seeds the visual immediately from the row data we
	-- already have (no flash-to-off before the next poll), and clicking
	-- fires `onToggle(newValue)` for the caller to send the command.
	local function makeToggleRow(parent: Instance, layoutOrder: number, label: string, initialState: boolean, onToggle: (boolean) -> ())
		local row = Instance.new("Frame")
		row.Name = label .. "Toggle"
		row.LayoutOrder = layoutOrder
		row.Size = UDim2.new(1, 0, 0, 28)
		row.BackgroundColor3 = Theme.Colors.SurfaceRaised
		row.BorderSizePixel = 0
		row.Parent = parent
		Theme.corner(row, Theme.Radius.S)
		Theme.padding(row, 6)

		local labelText = Instance.new("TextLabel")
		labelText.BackgroundTransparency = 1
		labelText.Size = UDim2.new(1, -50, 1, 0)
		labelText.Font = Theme.Font.Medium
		labelText.TextSize = 13
		labelText.TextColor3 = Theme.Colors.Text
		labelText.TextXAlignment = Enum.TextXAlignment.Left
		labelText.Text = label
		labelText.Parent = row

		local switchTrack = Instance.new("Frame")
		switchTrack.Name = "SwitchTrack"
		switchTrack.AnchorPoint = Vector2.new(1, 0.5)
		switchTrack.Position = UDim2.new(1, 0, 0.5, 0)
		switchTrack.Size = UDim2.new(0, 36, 0, 16)
		switchTrack.BorderSizePixel = 0
		switchTrack.Parent = row
		Theme.corner(switchTrack, UDim.new(1, 0))

		local switchKnob = Instance.new("Frame")
		switchKnob.Name = "SwitchKnob"
		switchKnob.Size = UDim2.new(0, 12, 0, 12)
		switchKnob.BackgroundColor3 = Color3.new(1, 1, 1)
		switchKnob.BorderSizePixel = 0
		switchKnob.Parent = switchTrack
		Theme.corner(switchKnob, UDim.new(1, 0))

		local isOn = initialState
		local function render()
			switchTrack.BackgroundColor3 = if isOn then Theme.Colors.Success else Theme.Colors.Error
			switchKnob.Position = if isOn then UDim2.new(1, -14, 0.5, -6) else UDim2.new(0, 2, 0.5, -6)
		end

		local clickButton = Instance.new("TextButton")
		clickButton.BackgroundTransparency = 1
		clickButton.Size = UDim2.new(1, 0, 1, 0)
		clickButton.Text = ""
		clickButton.Parent = row
		clickButton.MouseButton1Click:Connect(function()
			isOn = not isOn
			render() -- optimistic; corrected on the next player-list poll if the command was denied
			onToggle(isOn)
		end)

		render()
		return row
	end

	local function showDetail(row: PlayerRow)
		detailEmptyLabel.Visible = false
		detailName.Visible = true
		detailInfo.Visible = true
		actionsRow.Visible = true
		togglesFrame.Visible = true
		tabsNote.Visible = true

		detailName.Text = ("%s (@%s)"):format(row.DisplayName, row.Name)

		local healthText = if row.Health and row.MaxHealth then ("%d / %d"):format(row.Health, row.MaxHealth) else "N/A"
		local rolesText = if #row.Roles > 0 then table.concat(row.Roles, ", ") else "none"
		detailInfo.Text = ("Team: %s\nHealth: %s\nPing: %dms\nRoles: %s"):format(
			row.Team or "none", healthText, row.Ping, rolesText
		)

		for _, child in ipairs(actionsRow:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		for _, child in ipairs(togglesFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		-- Kick has no "undo" concept, so it stays a momentary button.
		-- There's no teleport-to-me command yet (that's part of the
		-- not-yet-built Player Controls phase), so no "Bring" button here.
		makeActionButton(actionsRow, 1, "Kick", function()
			runQuickAction("kick " .. row.Name)
		end)

		-- Freeze/Jail/Mute ARE reversible, so they're toggle rows instead
		-- of one-shot buttons — this is the fix for the gap where these
		-- commands had no way to be turned back off from the UI.
		makeToggleRow(togglesFrame, 1, "❄ Freeze", row.IsFrozen, function(newValue: boolean)
			runQuickAction((if newValue then "freeze " else "unfreeze ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 2, "🔒 Jail", row.IsJailed, function(newValue: boolean)
			runQuickAction((if newValue then "jail " else "unjail ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 3, "🔇 Mute", row.IsMuted, function(newValue: boolean)
			runQuickAction((if newValue then "mute " else "unmute ") .. row.Name)
		end)
	end

	local allRows: { PlayerRow } = {}

	local function renderTable(filter: string)
		for _, child in ipairs(tableFrame:GetChildren()) do
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
				button.Size = UDim2.new(1, 0, 0, 44)
				button.BackgroundColor3 = Theme.Colors.SurfaceRaised
				button.AutoButtonColor = false
				button.Text = ""
				button.Parent = tableFrame
				Theme.corner(button, Theme.Radius.S)

				local nameLabel = Instance.new("TextLabel")
				nameLabel.BackgroundTransparency = 1
				nameLabel.Position = UDim2.new(0, 10, 0, 4)
				nameLabel.Size = UDim2.new(0.5, 0, 0, 18)
				nameLabel.Font = Theme.Font.Medium
				nameLabel.TextSize = 14
				nameLabel.TextColor3 = Theme.Colors.Text
				nameLabel.TextXAlignment = Enum.TextXAlignment.Left
				nameLabel.Text = row.DisplayName
				nameLabel.Parent = button

				local metaLabel = Instance.new("TextLabel")
				metaLabel.BackgroundTransparency = 1
				metaLabel.Position = UDim2.new(0, 10, 0, 22)
				metaLabel.Size = UDim2.new(1, -20, 0, 16)
				metaLabel.Font = Theme.Font.Regular
				metaLabel.TextSize = 12
				metaLabel.TextColor3 = Theme.Colors.TextSecondary
				metaLabel.TextXAlignment = Enum.TextXAlignment.Left
				metaLabel.Text = ("Ping %dms · %s"):format(row.Ping, if #row.Roles > 0 then row.Roles[1] else "no role")
				metaLabel.Parent = button

				button.MouseButton1Click:Connect(function()
					if selectedRow then
						selectedRow.BackgroundColor3 = Theme.Colors.SurfaceRaised
					end
					button.BackgroundColor3 = Theme.Colors.Accent
					selectedRow = button
					selectedUserId = row.UserId
					showDetail(row)
				end)
			end
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		renderTable(searchBox.Text)
	end)

	task.spawn(function()
		while true do
			if getPlayerListRemote then
				local ok, result = pcall(function()
					return getPlayerListRemote:InvokeServer()
				end)
				if ok and result then
					allRows = result :: { PlayerRow }
					renderTable(searchBox.Text)

					-- Keep the selected player's toggle switches truthful:
					-- if a command was denied or the state changed from
					-- elsewhere (chat, Command Palette), this corrects the
					-- optimistic UI update from makeToggleRow's click
					-- handler within one poll interval.
					if selectedUserId then
						for _, row in ipairs(allRows) do
							if row.UserId == selectedUserId then
								showDetail(row)
								break
							end
						end
					end
				end
			end
			task.wait(4)
		end
	end)
end

return PlayersPage
