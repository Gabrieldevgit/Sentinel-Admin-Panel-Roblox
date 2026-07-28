--!strict
--[[
	PlayersPage.lua

	Purpose:
		Player Explorer from the design doc: a searchable table (Name/Team/
		Health/Ping/Role) with a tabbed detail panel on selection. Overview
		(Kick button + Freeze/Jail/Mute toggles) plus the six remaining
		Phase 7F tabs: Inventory, Statistics, Moderation History,
		Permissions, Session, Notes.

	Tab data sources:
		- Overview: GetPlayerListRemote (already polled for the table).
		- Inventory: GetPlayerInventoryRemote (new).
		- Statistics: GetEconomySnapshotRemote (reused from the Economy
		  page — Coins/Gems/XP/Level) plus the row data already on hand
		  (Health/Team/Ping).
		- Moderation History: GetPlayerModerationHistoryRemote (new).
		- Permissions: the row's own `Roles` field (already have it) plus
		  GetPermissionsSnapshotRemote's role catalog (reused from
		  Settings) for the node breakdown of each role the player has.
		- Session: GetPlayerSessionRemote (new).
		- Notes: GetPlayerNotesRemote (new, read) + ExecuteCommandRemote
		  ("/note target text") to add one, so the "moderation.notes"
		  permission node is actually enforced rather than bypassed by a
		  write-capable remote.

	Only the currently-selected player's currently-open tab is fetched
	(on selection and on tab switch, then refreshed every 4s while that
	tab stays open) — switching tabs doesn't fetch all six at once, and
	an unselected player's data is never requested.

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

local TABS = { "Overview", "Inventory", "Statistics", "Moderation", "Permissions", "Session", "Notes" }

function PlayersPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getPlayerListRemote = SentinelShared:WaitForChild("GetPlayerListRemote", 15) :: RemoteFunction?
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local commandResultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local getPlayerInventoryRemote = SentinelShared:WaitForChild("GetPlayerInventoryRemote", 15) :: RemoteFunction?
	local getEconomySnapshotRemote = SentinelShared:WaitForChild("GetEconomySnapshotRemote", 15) :: RemoteFunction?
	local getPlayerModerationHistoryRemote = SentinelShared:WaitForChild("GetPlayerModerationHistoryRemote", 15) :: RemoteFunction?
	local getPermissionsSnapshotRemote = SentinelShared:WaitForChild("GetPermissionsSnapshotRemote", 15) :: RemoteFunction?
	local getPlayerSessionRemote = SentinelShared:WaitForChild("GetPlayerSessionRemote", 15) :: RemoteFunction?
	local getPlayerNotesRemote = SentinelShared:WaitForChild("GetPlayerNotesRemote", 15) :: RemoteFunction?

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
	Theme.padding(detailPanel, Theme.Spacing.S)

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
	detailName.Size = UDim2.new(1, 0, 0, 24)
	detailName.Font = Theme.Font.Bold
	detailName.TextSize = 17
	detailName.TextColor3 = Theme.Colors.Text
	detailName.TextXAlignment = Enum.TextXAlignment.Left
	detailName.TextTruncate = Enum.TextTruncate.AtEnd
	detailName.Visible = false
	detailName.Parent = detailPanel

	-- ------------------------------------------------------------------
	-- Tab bar
	-- ------------------------------------------------------------------
	local tabBar = Instance.new("ScrollingFrame")
	tabBar.Name = "TabBar"
	tabBar.Position = UDim2.new(0, 0, 0, 28)
	tabBar.Size = UDim2.new(1, 0, 0, 28)
	tabBar.BackgroundTransparency = 1
	tabBar.BorderSizePixel = 0
	tabBar.ScrollBarThickness = 0
	tabBar.ScrollingDirection = Enum.ScrollingDirection.X
	tabBar.CanvasSize = UDim2.new(0, 0, 0, 0)
	tabBar.AutomaticCanvasSize = Enum.AutomaticSize.X
	tabBar.Visible = false
	tabBar.Parent = detailPanel

	local tabBarLayout = Instance.new("UIListLayout")
	tabBarLayout.FillDirection = Enum.FillDirection.Horizontal
	tabBarLayout.Padding = UDim.new(0, 4)
	tabBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabBarLayout.Parent = tabBar

	local contentArea = Instance.new("Frame")
	contentArea.Name = "ContentArea"
	contentArea.Position = UDim2.new(0, 0, 0, 62)
	contentArea.Size = UDim2.new(1, 0, 1, -62)
	contentArea.BackgroundTransparency = 1
	contentArea.Visible = false
	contentArea.Parent = detailPanel

	local tabButtons: { [string]: TextButton } = {}
	local tabPages: { [string]: ScrollingFrame } = {}

	for i, name in ipairs(TABS) do
		local button = Instance.new("TextButton")
		button.Name = name
		button.LayoutOrder = i
		button.Size = UDim2.new(0, if name == "Moderation" then 96 else 76, 1, 0)
		button.BackgroundColor3 = Theme.Colors.Surface
		button.AutoButtonColor = false
		button.Font = Theme.Font.Medium
		button.TextSize = 12
		button.TextColor3 = Theme.Colors.TextSecondary
		button.Text = name
		button.Parent = tabBar
		Theme.corner(button, Theme.Radius.S)
		tabButtons[name] = button

		local page = Instance.new("ScrollingFrame")
		page.Name = name .. "Page"
		page.Size = UDim2.new(1, 0, 1, 0)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 4
		page.CanvasSize = UDim2.new(0, 0, 0, 0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.Visible = false
		page.Parent = contentArea
		Theme.padding(page, 4)

		local pageLayout = Instance.new("UIListLayout")
		pageLayout.Padding = UDim.new(0, 6)
		pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
		pageLayout.Parent = page

		tabPages[name] = page
	end

	-- ------------------------------------------------------------------
	-- Overview tab content (built once, populated in showDetail)
	-- ------------------------------------------------------------------
	local overviewPage = tabPages.Overview

	local detailInfo = Instance.new("TextLabel")
	detailInfo.Name = "Info"
	detailInfo.LayoutOrder = 1
	detailInfo.BackgroundTransparency = 1
	detailInfo.Size = UDim2.new(1, 0, 0, 60)
	detailInfo.Font = Theme.Font.Regular
	detailInfo.TextSize = 13
	detailInfo.TextColor3 = Theme.Colors.TextSecondary
	detailInfo.TextXAlignment = Enum.TextXAlignment.Left
	detailInfo.TextYAlignment = Enum.TextYAlignment.Top
	detailInfo.TextWrapped = true
	detailInfo.Parent = overviewPage

	local actionsRow = Instance.new("Frame")
	actionsRow.Name = "Actions"
	actionsRow.LayoutOrder = 2
	actionsRow.Size = UDim2.new(1, 0, 0, 0)
	actionsRow.AutomaticSize = Enum.AutomaticSize.Y
	actionsRow.BackgroundTransparency = 1
	actionsRow.Parent = overviewPage

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.Padding = UDim.new(0, 8)
	actionsLayout.Wraps = true
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Parent = actionsRow

	-- Freeze/Jail/Mute are reversible states, not one-shot actions — each
	-- gets a toggle row (label + switch) reflecting live status, matching
	-- the same pattern as the Dashboard's Quick Actions toggles. Kick has
	-- no "undo" concept, so it stays a momentary button.
	local togglesFrame = Instance.new("Frame")
	togglesFrame.Name = "Toggles"
	togglesFrame.LayoutOrder = 3
	togglesFrame.Size = UDim2.new(1, 0, 0, 0)
	togglesFrame.AutomaticSize = Enum.AutomaticSize.Y
	togglesFrame.BackgroundTransparency = 1
	togglesFrame.Parent = overviewPage

	local togglesLayout = Instance.new("UIListLayout")
	togglesLayout.Padding = UDim.new(0, 6)
	togglesLayout.SortOrder = Enum.SortOrder.LayoutOrder
	togglesLayout.Parent = togglesFrame

	local selectedRow: TextButton? = nil
	local selectedUserId: number? = nil
	local selectedName: string? = nil
	local activeTab = "Overview"

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

	local function renderOverview(row: PlayerRow)
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

		makeActionButton(actionsRow, 1, "Kick", function()
			runQuickAction("kick " .. row.Name)
		end)

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

	-- ------------------------------------------------------------------
	-- Shared helpers for the read-only tabs
	-- ------------------------------------------------------------------
	local function clearPage(page: ScrollingFrame)
		for _, child in ipairs(page:GetChildren()) do
			if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextBox") then
				child:Destroy()
			end
		end
	end

	local function makeEmptyLabel(page: ScrollingFrame, order: number, text: string)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, 30)
		label.Font = Theme.Font.Regular
		label.TextSize = 12
		label.TextColor3 = Theme.Colors.TextSecondary
		label.TextWrapped = true
		label.Text = text
		label.Parent = page
	end

	local function makeInfoCard(page: ScrollingFrame, order: number, text: string)
		local card = Instance.new("TextLabel")
		card.LayoutOrder = order
		card.BackgroundColor3 = Theme.Colors.SurfaceRaised
		card.Size = UDim2.new(1, 0, 0, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.Font = Theme.Font.Mono
		card.TextSize = 12
		card.TextColor3 = Theme.Colors.Text
		card.TextWrapped = true
		card.TextXAlignment = Enum.TextXAlignment.Left
		card.TextYAlignment = Enum.TextYAlignment.Top
		card.Text = text
		card.Parent = page
		Theme.corner(card, Theme.Radius.S)
		Theme.padding(card, 8)
		return card
	end

	-- ------------------------------------------------------------------
	-- Inventory tab
	-- ------------------------------------------------------------------
	local function loadInventory(userId: number)
		local page = tabPages.Inventory
		clearPage(page)
		if not getPlayerInventoryRemote then
			return
		end
		local ok, items = pcall(function()
			return getPlayerInventoryRemote:InvokeServer(userId)
		end)
		if not (ok and items) then
			makeEmptyLabel(page, 1, "Couldn't load inventory.")
			return
		end
		if #items == 0 then
			makeEmptyLabel(page, 1, "No tools in Backpack or equipped.")
			return
		end
		for i, item in ipairs(items :: { any }) do
			makeInfoCard(page, i, (if item.Equipped then "🖐 " else "🎒 ") .. item.Name .. (if item.Equipped then " (equipped)" else ""))
		end
	end

	-- ------------------------------------------------------------------
	-- Statistics tab
	-- ------------------------------------------------------------------
	local function loadStatistics(userId: number, row: PlayerRow)
		local page = tabPages.Statistics
		clearPage(page)
		local healthText = if row.Health and row.MaxHealth then ("%d / %d"):format(row.Health, row.MaxHealth) else "N/A"
		makeInfoCard(page, 1, ("Team: %s\nHealth: %s\nPing: %dms"):format(row.Team or "none", healthText, row.Ping))

		if not getEconomySnapshotRemote then
			return
		end
		local ok, snapshot = pcall(function()
			return getEconomySnapshotRemote:InvokeServer(userId)
		end)
		if ok and snapshot then
			local s = snapshot :: { Coins: number, Gems: number, XP: number, Level: number }
			makeInfoCard(page, 2, ("🪙 Coins: %d\n💎 Gems: %d\n⭐ XP: %d\n📈 Level: %d"):format(s.Coins, s.Gems, s.XP, s.Level))
		else
			makeEmptyLabel(page, 2, "Economy data unavailable (player may have left).")
		end
	end

	-- ------------------------------------------------------------------
	-- Moderation History tab
	-- ------------------------------------------------------------------
	local function loadModerationHistory(userId: number)
		local page = tabPages.Moderation
		clearPage(page)
		if not getPlayerModerationHistoryRemote then
			return
		end
		local ok, entries = pcall(function()
			return getPlayerModerationHistoryRemote:InvokeServer(userId, 30)
		end)
		if not (ok and entries) then
			makeEmptyLabel(page, 1, "Couldn't load moderation history.")
			return
		end
		local list = entries :: { any }
		if #list == 0 then
			makeEmptyLabel(page, 1, "No commands have targeted this player yet.")
			return
		end
		for i, entry in ipairs(list) do
			local timeText = os.date("%m/%d %H:%M:%S", entry.Timestamp)
			local resultIcon = if entry.Result == "Success" then "✅" elseif entry.Result == "Denied" then "🚫" else "❌"
			makeInfoCard(
				page,
				i,
				("%s [%s] %s\nby %s%s"):format(
					resultIcon,
					tostring(timeText),
					entry.Command,
					entry.ExecutorName,
					if entry.Message then "\n" .. entry.Message else ""
				)
			)
		end
	end

	-- ------------------------------------------------------------------
	-- Permissions tab
	-- ------------------------------------------------------------------
	local function loadPermissions(row: PlayerRow)
		local page = tabPages.Permissions
		clearPage(page)

		if #row.Roles == 0 then
			makeEmptyLabel(page, 1, "This player has no assigned roles.")
			return
		end

		if not getPermissionsSnapshotRemote then
			makeInfoCard(page, 1, "Roles: " .. table.concat(row.Roles, ", "))
			return
		end
		local ok, snapshot = pcall(function()
			return getPermissionsSnapshotRemote:InvokeServer()
		end)
		if not (ok and snapshot) then
			makeInfoCard(page, 1, "Roles: " .. table.concat(row.Roles, ", "))
			return
		end
		local catalog = (snapshot :: { Roles: { [string]: { Nodes: { string }, Inherits: { string } } } }).Roles
		for i, roleName in ipairs(row.Roles) do
			local def = catalog[roleName]
			if def then
				local text = roleName .. "\nNodes: " .. (if #def.Nodes > 0 then table.concat(def.Nodes, ", ") else "(none)")
				if #def.Inherits > 0 then
					text ..= "\nInherits: " .. table.concat(def.Inherits, ", ")
				end
				makeInfoCard(page, i, text)
			else
				makeInfoCard(page, i, roleName)
			end
		end
	end

	-- ------------------------------------------------------------------
	-- Session tab
	-- ------------------------------------------------------------------
	local function loadSession(userId: number)
		local page = tabPages.Session
		clearPage(page)
		if not getPlayerSessionRemote then
			return
		end
		local ok, session = pcall(function()
			return getPlayerSessionRemote:InvokeServer(userId)
		end)
		if not (ok and session) then
			makeEmptyLabel(page, 1, "Session data unavailable.")
			return
		end
		local s = session :: { UserId: number, AccountAgeDays: number, JoinedAt: number?, Ping: number }
		local sessionLengthText = if s.JoinedAt then ("%d min"):format(math.floor((os.time() - s.JoinedAt) / 60)) else "unknown"
		makeInfoCard(
			page,
			1,
			("UserId: %d\nAccount age: %d days\nSession length: %s\nPing: %dms"):format(
				s.UserId, s.AccountAgeDays, sessionLengthText, s.Ping
			)
		)
	end

	-- ------------------------------------------------------------------
	-- Notes tab (read-only list + a real Add Note action)
	-- ------------------------------------------------------------------
	local function loadNotes(userId: number)
		local page = tabPages.Notes
		clearPage(page)

		local addRow = Instance.new("Frame")
		addRow.LayoutOrder = 1
		addRow.Size = UDim2.new(1, 0, 0, 32)
		addRow.BackgroundTransparency = 1
		addRow.Parent = page

		local noteInput = Instance.new("TextBox")
		noteInput.Size = UDim2.new(1, -70, 1, 0)
		noteInput.BackgroundColor3 = Theme.Colors.Surface
		noteInput.Font = Theme.Font.Regular
		noteInput.TextSize = 12
		noteInput.TextColor3 = Theme.Colors.Text
		noteInput.PlaceholderText = "Add a note..."
		noteInput.ClearTextOnFocus = false
		noteInput.TextXAlignment = Enum.TextXAlignment.Left
		noteInput.Parent = addRow
		Theme.corner(noteInput, Theme.Radius.S)
		Theme.padding(noteInput, 6)

		local addButton = Instance.new("TextButton")
		addButton.AnchorPoint = Vector2.new(1, 0.5)
		addButton.Position = UDim2.new(1, 0, 0.5, 0)
		addButton.Size = UDim2.new(0, 60, 0, 28)
		addButton.BackgroundColor3 = Theme.Colors.Accent
		addButton.Font = Theme.Font.Medium
		addButton.TextSize = 12
		addButton.TextColor3 = Color3.new(1, 1, 1)
		addButton.Text = "Add"
		addButton.Parent = addRow
		Theme.corner(addButton, Theme.Radius.S)

		local function reloadNotesList()
			if not getPlayerNotesRemote then
				return
			end
			local ok, notes = pcall(function()
				return getPlayerNotesRemote:InvokeServer(userId)
			end)
			for _, child in ipairs(page:GetChildren()) do
				if child.Name == "NoteCard" then
					child:Destroy()
				end
			end
			if not (ok and notes) then
				return
			end
			local list = notes :: { any }
			if #list == 0 then
				local emptyCard = makeInfoCard(page, 2, "No notes on this player.")
				emptyCard.Name = "NoteCard"
				return
			end
			for i = #list, 1, -1 do
				local note = list[i]
				local timeText = os.date("%m/%d %H:%M", note.Timestamp)
				local card = makeInfoCard(page, 1 + (#list - i) + 1, ("[%s] %s\n%s"):format(note.AddedBy, tostring(timeText), note.Text))
				card.Name = "NoteCard"
			end
		end

		addButton.MouseButton1Click:Connect(function()
			local text = noteInput.Text
			if text == "" then
				return
			end
			runQuickAction("note " .. selectedName .. " " .. text)
			noteInput.Text = ""
			task.wait(0.5) -- give the write a moment to land before re-reading
			reloadNotesList()
		end)

		reloadNotesList()
	end

	-- ------------------------------------------------------------------
	-- Tab switching + per-tab data loading
	-- ------------------------------------------------------------------
	local latestRow: PlayerRow? = nil

	local function loadActiveTab()
		if not (selectedUserId and latestRow) then
			return
		end
		if activeTab == "Overview" then
			renderOverview(latestRow)
		elseif activeTab == "Inventory" then
			loadInventory(selectedUserId)
		elseif activeTab == "Statistics" then
			loadStatistics(selectedUserId, latestRow)
		elseif activeTab == "Moderation" then
			loadModerationHistory(selectedUserId)
		elseif activeTab == "Permissions" then
			loadPermissions(latestRow)
		elseif activeTab == "Session" then
			loadSession(selectedUserId)
		elseif activeTab == "Notes" then
			loadNotes(selectedUserId)
		end
	end

	local function selectTab(name: string)
		activeTab = name
		for tabName, button in pairs(tabButtons) do
			local isActive = tabName == name
			button.BackgroundColor3 = if isActive then Theme.Colors.Accent else Theme.Colors.Surface
			button.TextColor3 = if isActive then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
		end
		for tabName, page in pairs(tabPages) do
			page.Visible = tabName == name
		end
		loadActiveTab()
	end

	for name, button in pairs(tabButtons) do
		button.MouseButton1Click:Connect(function()
			selectTab(name)
		end)
	end

	local function showDetail(row: PlayerRow)
		latestRow = row
		detailEmptyLabel.Visible = false
		detailName.Visible = true
		tabBar.Visible = true
		contentArea.Visible = true
		detailName.Text = ("%s (@%s)"):format(row.DisplayName, row.Name)
		loadActiveTab()
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
				button.BackgroundColor3 = if row.UserId == selectedUserId then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
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

				if row.UserId == selectedUserId then
					selectedRow = button
				end

				button.MouseButton1Click:Connect(function()
					if selectedRow then
						selectedRow.BackgroundColor3 = Theme.Colors.SurfaceRaised
					end
					button.BackgroundColor3 = Theme.Colors.Accent
					selectedRow = button
					selectedUserId = row.UserId
					selectedName = row.Name
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

					-- Keep the selected player's Overview tab (and the
					-- table row highlight — see the known selection-
					-- highlight bug logged in PHASE7-KNOWN-ISSUES.md)
					-- truthful: re-render whichever tab is open using
					-- fresh row data, not just re-poll Overview alone.
					if selectedUserId then
						local found = false
						for _, row in ipairs(allRows) do
							if row.UserId == selectedUserId then
								found = true
								latestRow = row
								if activeTab == "Overview" or activeTab == "Statistics" or activeTab == "Permissions" then
									loadActiveTab()
								end
								break
							end
						end
						if not found then
							-- Player left. Leave the last-known detail
							-- panel content up rather than snapping back
							-- to the empty state out from under the admin.
							selectedRow = nil
						end
					end
				end
			end
			task.wait(4)
		end
	end)
end

return PlayersPage
