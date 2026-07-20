--!strict
--[[
	PlayersPage.lua

	Purpose:
		Player Explorer from the design doc: a searchable table (Name/Team/
		Health/Ping/Role) with a detail panel on selection. This first
		slice covers the Overview tab with quick actions (Kick/Freeze/
		Jail); Inventory/Statistics/Moderation History/Permissions/
		Session/Notes tabs are follow-up increments (each needs its own
		read remote in UIBridge).

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
	Theme.padding(detailPanel, Theme.Spacing.M)

	local detailEmptyLabel = Instance.new("TextLabel")
	detailEmptyLabel.Name = "EmptyState"
	detailEmptyLabel.BackgroundTransparency = 1
	detailEmptyLabel.Size = UDim2.new(1, 0, 1, 0)
	detailEmptyLabel.Font = Theme.Font.Regular
	detailEmptyLabel.TextSize = 13
	detailEmptyLabel.TextColor3 = Theme.Colors.TextSecondary
	detailEmptyLabel.Text = "Select a player to view details."
	detailEmptyLabel.Parent = detailPanel

	local detailName = Instance.new("TextLabel")
	detailName.Name = "Name"
	detailName.BackgroundTransparency = 1
	detailName.Size = UDim2.new(1, 0, 0, 26)
	detailName.Font = Theme.Font.Bold
	detailName.TextSize = 18
	detailName.TextColor3 = Theme.Colors.Text
	detailName.TextXAlignment = Enum.TextXAlignment.Left
	detailName.Visible = false
	detailName.Parent = detailPanel

	local detailInfo = Instance.new("TextLabel")
	detailInfo.Name = "Info"
	detailInfo.BackgroundTransparency = 1
	detailInfo.Position = UDim2.new(0, 0, 0, 30)
	detailInfo.Size = UDim2.new(1, 0, 0, 60)
	detailInfo.Font = Theme.Font.Regular
	detailInfo.TextSize = 13
	detailInfo.TextColor3 = Theme.Colors.TextSecondary
	detailInfo.TextXAlignment = Enum.TextXAlignment.Left
	detailInfo.TextYAlignment = Enum.TextYAlignment.Top
	detailInfo.TextWrapped = true
	detailInfo.Visible = false
	detailInfo.Parent = detailPanel

	local actionsRow = Instance.new("Frame")
	actionsRow.Name = "Actions"
	actionsRow.Position = UDim2.new(0, 0, 0, 100)
	actionsRow.Size = UDim2.new(1, 0, 0, 34)
	actionsRow.BackgroundTransparency = 1
	actionsRow.Visible = false
	actionsRow.Parent = detailPanel

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.Padding = UDim.new(0, 8)
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Parent = actionsRow

	local tabsNote = Instance.new("TextLabel")
	tabsNote.Name = "TabsNote"
	tabsNote.BackgroundTransparency = 1
	tabsNote.Position = UDim2.new(0, 0, 0, 144)
	tabsNote.Size = UDim2.new(1, 0, 0, 40)
	tabsNote.Font = Theme.Font.Regular
	tabsNote.TextSize = 12
	tabsNote.TextColor3 = Theme.Colors.TextSecondary
	tabsNote.TextWrapped = true
	tabsNote.Text = "Inventory / Statistics / Moderation History / Permissions / Session / Notes tabs are coming in a follow-up pass."
	tabsNote.Visible = false
	tabsNote.Parent = detailPanel

	local selectedRow: TextButton? = nil

	local function runQuickAction(commandText: string)
		if executeCommandRemote then
			executeCommandRemote:FireServer(commandText)
		end
	end

	local function makeActionButton(parent: Instance, layoutOrder: number, label: string, onClick: () -> ())
		local button = Instance.new("TextButton")
		button.LayoutOrder = layoutOrder
		button.Size = UDim2.new(0, 70, 1, 0)
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

	local function showDetail(row: PlayerRow)
		detailEmptyLabel.Visible = false
		detailName.Visible = true
		detailInfo.Visible = true
		actionsRow.Visible = true
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

		-- NOTE: these call Sentinel commands directly by name. "kick"/
		-- "freeze"/"jail" already exist (Phases 1/3). There's no
		-- teleport-to-me command yet (that's part of the not-yet-built
		-- Player Controls phase), so a 4th "Bring" button is intentionally
		-- left out here rather than wired to something that doesn't exist.
		makeActionButton(actionsRow, 1, "Kick", function()
			runQuickAction("kick " .. row.Name)
		end)
		makeActionButton(actionsRow, 2, "Freeze", function()
			runQuickAction("freeze " .. row.Name)
		end)
		makeActionButton(actionsRow, 3, "Jail", function()
			runQuickAction("jail " .. row.Name)
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
				end
			end
			task.wait(4)
		end
	end)
end

return PlayersPage
