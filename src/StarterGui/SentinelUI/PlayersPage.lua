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

	W15 (Player Explorer completion):
		- Rows: avatar, display name + @name, rank chip (rank colour), health
		  bar, ping dot (green < 100 ms, amber < 250, red), status chips
		  (Idle / Dead / Frozen / Jailed / Muted / God / Fly / Invisible) and a
		  Suspicious flag (reasons on hover in the Overview tab).
		- Filters (Toolbar.Filters.Filter_<name>): All, Staff, VIP,
		  Suspicious, Idle, New (joined < 10 min). Sort (Toolbar.Sort):
		  Name / Ping / Health / Joined. View (Toolbar.View_Online /
		  View_Recent): Recent = recently joined + recently left lists.
		- Bulk selection: each row has a check box (Row.Check); SelectBar has
		  All / All but me / None, a selector box (SelectBar.Selector +
		  SelectBar.Go) that resolves "@team Red", "@rank VIP",
		  "@attribute SentinelFlying", "@walkspeed >30", "all where Health<50"
		  on the server (ResolveTargetsRemote). Checked players become the
		  Commands page target (Selection.SetMany) and the BulkBar runs one
		  command on all of them ("heal a,b,c").
		- Notes tab: General / Investigation notes (;note / ;investigate).

	Stable names: Table.Row_<UserId>.{Check, Name, Meta},
	Toolbar.{Filters.Filter_<name>, Sort, View_Online, View_Recent},
	SelectBar.{All, Others, None, Selector, Go, Count}, BulkBar.Actions.<Cmd>.

	Dependencies:
		Theme.lua, Selection.lua, BanPromptSystem.lua

	Public API:
		PlayersPage.Build(container: Frame, options?): ()
			options.OpenCommands: () -> ()  -- "Command..." in the bulk bar
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Selection = require(script.Parent:WaitForChild("Selection"))
local BanPromptSystem = require(script.Parent:WaitForChild("BanPromptSystem"))

local PlayersPage = {}

type PlayerRow = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Team: string?,
	TeamColor: Color3?,
	Health: number?,
	MaxHealth: number?,
	Ping: number,
	Roles: { string },
	Rank: string?,
	RankColor: { number }?,
	IsStaff: boolean?,
	IsVIP: boolean?,
	AccountAge: number?,
	JoinedAt: number?,
	Status: string?,
	IdleSeconds: number?,
	Suspicious: { string }?,
	Warnings: number?,
	WalkSpeed: number?,
	JumpPower: number?,
	Position: { number }?,
	IsFrozen: boolean,
	IsJailed: boolean,
	IsMuted: boolean,
	IsGod: boolean?,
	IsFlying: boolean?,
	IsInvisible: boolean?,
}

local TABS = { "Overview", "Inventory", "Statistics", "Moderation", "Permissions", "Session", "Notes" }

local FILTERS = { "All", "Staff", "VIP", "Suspicious", "Idle", "New" }
local SORTS = { "Name", "Ping", "Health", "Joined" }
local BULK = {
	{ "Heal", "heal" }, { "Respawn", "respawn" }, { "Bring", "bring" }, { "Freeze", "freeze" },
	{ "Unfreeze", "unfreeze" }, { "Mute", "mute" }, { "Unmute", "unmute" }, { "Jail", "jail" },
	{ "Unjail", "unjail" }, { "Kick", "kick" },
}
local NEW_SECONDS = 600

local function ago(seconds: number): string
	if seconds < 60 then
		return ("%ds"):format(seconds)
	elseif seconds < 3600 then
		return ("%dm"):format(seconds // 60)
	end
	return ("%dh %dm"):format(seconds // 3600, (seconds % 3600) // 60)
end

local function pingColor(ping: number): Color3
	return if ping < 100 then Theme.Colors.Success elseif ping < 250 then Theme.Colors.Warning else Theme.Colors.Error
end

function PlayersPage.Build(container: Frame, options: any?)
	options = options or {}
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
	local getPlayerActivityRemote = SentinelShared:WaitForChild("GetPlayerActivityRemote", 15) :: RemoteFunction?
	local resolveTargetsRemote = SentinelShared:WaitForChild("ResolveTargetsRemote", 15) :: RemoteFunction?

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
	searchBox.PlaceholderText = "Search name, display name or UserId..."

	-- W15 toolbar: filter chips, sort, Online / Recent view.
	local function chip(parent: Instance, name: string, text: string, order: number, width: number?): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.LayoutOrder = order
		b.Size = UDim2.new(0, width or (#text * 7 + 22), 0, 26)
		b.BackgroundColor3 = Theme.Colors.SurfaceRaised
		b.AutoButtonColor = true
		b.Font = Theme.Font.Medium
		b.TextSize = 12
		b.TextColor3 = Theme.Colors.Text
		b.Text = text
		b.Parent = parent
		Theme.corner(b, Theme.Radius.Pill)
		return b
	end
	local function hlist(frame: Instance, padding: number)
		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, padding)
		l.Parent = frame
	end

	local toolbar = Instance.new("ScrollingFrame")
	toolbar.Name = "Toolbar"
	toolbar.BackgroundTransparency = 1
	toolbar.BorderSizePixel = 0
	toolbar.ScrollingDirection = Enum.ScrollingDirection.X
	toolbar.ScrollBarThickness = 0
	toolbar.AutomaticCanvasSize = Enum.AutomaticSize.X
	toolbar.CanvasSize = UDim2.new()
	toolbar.Parent = container
	hlist(toolbar, 6)

	local filtersFrame = Instance.new("Frame")
	filtersFrame.Name = "Filters"
	filtersFrame.LayoutOrder = 1
	filtersFrame.BackgroundTransparency = 1
	filtersFrame.AutomaticSize = Enum.AutomaticSize.X
	filtersFrame.Size = UDim2.new(0, 0, 0, 26)
	filtersFrame.Parent = toolbar
	hlist(filtersFrame, 4)

	local activeFilter = "All"
	local sortBy = "Name"
	local view = "Online"
	local filterButtons: { [string]: TextButton } = {}
	local renderTable: (string) -> ()
	for i, name in ipairs(FILTERS) do
		local b = chip(filtersFrame, "Filter_" .. name, name, i)
		filterButtons[name] = b
		b.MouseButton1Click:Connect(function()
			activeFilter = name
			for n, other in pairs(filterButtons) do
				other.BackgroundColor3 = if n == name then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
			end
			renderTable(searchBox.Text)
		end)
	end
	filterButtons.All.BackgroundColor3 = Theme.Colors.Accent

	local sortButton = chip(toolbar, "Sort", "Sort: Name", 2, 104)
	sortButton.MouseButton1Click:Connect(function()
		local i = table.find(SORTS, sortBy) or 1
		sortBy = SORTS[(i % #SORTS) + 1]
		sortButton.Text = "Sort: " .. sortBy
		renderTable(searchBox.Text)
	end)
	local viewOnline = chip(toolbar, "View_Online", "Online", 3, 70)
	local viewRecent = chip(toolbar, "View_Recent", "Recent", 4, 70)
	viewOnline.BackgroundColor3 = Theme.Colors.Accent

	-- Selection bar: bulk selection helpers + selector box.
	local selectBar = Instance.new("ScrollingFrame")
	selectBar.Name = "SelectBar"
	selectBar.BackgroundTransparency = 1
	selectBar.BorderSizePixel = 0
	selectBar.ScrollingDirection = Enum.ScrollingDirection.X
	selectBar.ScrollBarThickness = 0
	selectBar.AutomaticCanvasSize = Enum.AutomaticSize.X
	selectBar.CanvasSize = UDim2.new()
	selectBar.Parent = container
	hlist(selectBar, 4)
	local selectAll = chip(selectBar, "All", "Select all", 1, 82)
	local selectOthers = chip(selectBar, "Others", "All but me", 2, 86)
	local selectNone = chip(selectBar, "None", "None", 3, 56)
	local selectorBox = Instance.new("TextBox")
	selectorBox.Name = "Selector"
	selectorBox.LayoutOrder = 4
	selectorBox.Size = UDim2.new(0, 230, 0, 26)
	selectorBox.BackgroundColor3 = Theme.Colors.Surface
	selectorBox.Font = Theme.Font.Mono
	selectorBox.TextSize = 12
	selectorBox.TextColor3 = Theme.Colors.Text
	selectorBox.PlaceholderText = "@team Red / @rank VIP / @walkspeed >30"
	selectorBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	selectorBox.ClearTextOnFocus = false
	selectorBox.TextXAlignment = Enum.TextXAlignment.Left
	selectorBox.Text = ""
	selectorBox.ClipsDescendants = true
	selectorBox.Parent = selectBar
	Theme.corner(selectorBox, Theme.Radius.S)
	Theme.padding(selectorBox, 6)
	local selectGo = chip(selectBar, "Go", "Select", 5, 64)
	selectGo.BackgroundColor3 = Theme.Colors.Accent
	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "Count"
	countLabel.LayoutOrder = 6
	countLabel.BackgroundTransparency = 1
	countLabel.Size = UDim2.new(0, 220, 0, 26)
	countLabel.Font = Theme.Font.Regular
	countLabel.TextSize = 12
	countLabel.TextColor3 = Theme.Colors.TextSecondary
	countLabel.TextXAlignment = Enum.TextXAlignment.Left
	countLabel.Text = "0 checked"
	countLabel.Parent = selectBar

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

	-- W15 bulk bar: under the list while players are checked.
	local bulkBar = Instance.new("Frame")
	bulkBar.Name = "BulkBar"
	bulkBar.BackgroundColor3 = Theme.Colors.SurfaceRaised
	bulkBar.BorderSizePixel = 0
	bulkBar.Visible = false
	bulkBar.ZIndex = 5
	bulkBar.Parent = container
	Theme.corner(bulkBar, Theme.Radius.M)
	local bulkActions = Instance.new("ScrollingFrame")
	bulkActions.Name = "Actions"
	bulkActions.BackgroundTransparency = 1
	bulkActions.BorderSizePixel = 0
	bulkActions.Position = UDim2.new(0, 6, 0, 0)
	bulkActions.Size = UDim2.new(1, -12, 1, 0)
	bulkActions.ScrollingDirection = Enum.ScrollingDirection.X
	bulkActions.ScrollBarThickness = 0
	bulkActions.AutomaticCanvasSize = Enum.AutomaticSize.X
	bulkActions.CanvasSize = UDim2.new()
	bulkActions.ZIndex = 5
	bulkActions.Parent = bulkBar
	local bulkLayout = Instance.new("UIListLayout")
	bulkLayout.FillDirection = Enum.FillDirection.Horizontal
	bulkLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	bulkLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bulkLayout.Padding = UDim.new(0, 4)
	bulkLayout.Parent = bulkActions
	local function bulkHeight(split: number, top: number)
		bulkBar.Position = UDim2.new(0, 0, 1, -40)
		bulkBar.Size = UDim2.new(split, -8, 0, 40)
		tableFrame.Size = UDim2.new(split, -8, 1, -top - (if bulkBar.Visible then 46 else 0))
	end

	-- W09 reflow: in a narrow panel the detail side gets most of the width
	-- (the list only needs names), and the search box fills its column.
	local function reflow()
		local width = container.AbsoluteSize.X
		if width <= 0 then
			return
		end
		-- Phones (landscape ~800 wide, ~250 tall): the search box moves
		-- into the title row so the list and details get the height.
		local narrow = width < 900
		local short = container.AbsoluteSize.Y > 0 and container.AbsoluteSize.Y < 380
		local split = if narrow then 0.36 else 0.58
		-- rows: [title (+search when short)] [search + toolbar] [select bar]
		local rowY = if short then 36 else 40
		local top = rowY + 32 + 30 + 4
		if short then
			searchBox.AnchorPoint = Vector2.new(1, 0)
			searchBox.Position = UDim2.new(1, 0, 0, 0)
			searchBox.Size = UDim2.new(1 - split, -8, 0, 32)
			toolbar.Position = UDim2.new(0, 0, 0, rowY)
			toolbar.Size = UDim2.new(1, 0, 0, 28)
			top = rowY + 30 + 30 + 4
		else
			searchBox.AnchorPoint = Vector2.new(0, 0)
			searchBox.Position = UDim2.new(0, 0, 0, rowY)
			searchBox.Size = UDim2.new(if narrow then split else 0.3, -8, 0, 32)
			toolbar.Position = UDim2.new(if narrow then split else 0.3, 0, 0, rowY + 2)
			toolbar.Size = UDim2.new(if narrow then 1 - split else 0.7, 0, 0, 28)
		end
		selectBar.Position = UDim2.new(0, 0, 0, top - 34)
		selectBar.Size = UDim2.new(1, 0, 0, 28)
		tableFrame.Size = UDim2.new(split, -8, 1, -top)
		tableFrame.Position = UDim2.new(0, 0, 0, top)
		detailPanel.Position = UDim2.new(split, 8, 0, top)
		detailPanel.Size = UDim2.new(1 - split, -8, 1, -top)
		bulkHeight(split, top)
	end
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow)

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
	detailInfo.Size = UDim2.new(1, 0, 0, 0)
	detailInfo.AutomaticSize = Enum.AutomaticSize.Y
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
		button.Size = UDim2.new(0, 72, 0, 28)
		button.BackgroundColor3 = Theme.Colors.SurfaceRaised
		button.AutoButtonColor = true
		button.Font = Theme.Font.Medium
		button.TextSize = 12
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
		local lines = {
			("UserId: %d   Account age: %s days"):format(row.UserId, tostring(row.AccountAge or "?")),
			("Rank: %s   Roles: %s"):format(row.Rank or "none", rolesText),
			("Team: %s   Status: %s%s"):format(
				row.Team or "none",
				row.Status or "?",
				if row.Status == "Idle" and row.IdleSeconds then " (" .. ago(row.IdleSeconds) .. ")" else ""
			),
			("Health: %s   Ping: %dms"):format(healthText, row.Ping),
			("WalkSpeed: %s   JumpPower: %s"):format(tostring(row.WalkSpeed or "-"), tostring(row.JumpPower or "-")),
			("Position: %s"):format(if row.Position then table.concat(row.Position, ", ") else "-"),
			("Joined: %s   Session: %s   Warnings: %d"):format(
				if row.JoinedAt then tostring(os.date("%H:%M", row.JoinedAt)) else "?",
				if row.JoinedAt then ago(math.max(0, os.time() - row.JoinedAt)) else "?",
				row.Warnings or 0
			),
		}
		local active = {}
		for _, pair in ipairs({ { row.IsFrozen, "Frozen" }, { row.IsJailed, "Jailed" }, { row.IsMuted, "Muted" } }) do
			if pair[1] then
				table.insert(active, pair[2])
			end
		end
		table.insert(lines, "Active punishments: " .. (if #active > 0 then table.concat(active, ", ") else "none"))
		if row.Suspicious and #row.Suspicious > 0 then
			table.insert(lines, "Suspicious: " .. table.concat(row.Suspicious, "; "))
		end
		detailInfo.Text = table.concat(lines, "\n")
		detailInfo.TextColor3 = if row.Suspicious and #row.Suspicious > 0 then Theme.Colors.Text else Theme.Colors.TextSecondary

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

		makeActionButton(actionsRow, 1, "Goto", function()
			runQuickAction("goto " .. row.Name)
		end)
		makeActionButton(actionsRow, 2, "Bring", function()
			runQuickAction("bring " .. row.Name)
		end)
		makeActionButton(actionsRow, 3, "Heal", function()
			runQuickAction("heal " .. row.Name)
		end)
		makeActionButton(actionsRow, 4, "Respawn", function()
			runQuickAction("respawn " .. row.Name)
		end)
		makeActionButton(actionsRow, 5, "Refresh", function()
			runQuickAction("refresh " .. row.Name)
		end)
		makeActionButton(actionsRow, 6, "Fling", function()
			runQuickAction("fling " .. row.Name)
		end)
		makeActionButton(actionsRow, 7, "Kill", function()
			runQuickAction("kill " .. row.Name)
		end)
		makeActionButton(actionsRow, 8, "View", function()
			runQuickAction("view " .. row.Name)
		end)
		makeActionButton(actionsRow, 9, "Btools", function()
			runQuickAction("btools " .. row.Name)
		end)
		makeActionButton(actionsRow, 10, "Kick", function()
			runQuickAction("kick " .. row.Name)
		end)
		-- W09: ban prompt (type, duration, reason) -> a normal ;ban command.
		local banButton = makeActionButton(actionsRow, 11, "Ban", function()
			BanPromptSystem.Show({ Name = row.Name, DisplayName = row.DisplayName })
		end)
		banButton.Name = "BanButton"
		banButton.TextColor3 = Theme.Colors.Error

		makeToggleRow(togglesFrame, 1, "❄ Freeze", row.IsFrozen, function(newValue: boolean)
			runQuickAction((if newValue then "freeze " else "unfreeze ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 2, "🔒 Jail", row.IsJailed, function(newValue: boolean)
			runQuickAction((if newValue then "jail " else "unjail ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 3, "🔇 Mute", row.IsMuted, function(newValue: boolean)
			runQuickAction((if newValue then "mute " else "unmute ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 4, "✨ God Mode", row.IsGod == true, function(newValue: boolean)
			runQuickAction((if newValue then "god " else "ungod ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 5, "🕊 Fly", row.IsFlying == true, function(newValue: boolean)
			runQuickAction((if newValue then "fly " else "unfly ") .. row.Name)
		end)
		makeToggleRow(togglesFrame, 6, "👻 Invisible", row.IsInvisible == true, function(newValue: boolean)
			runQuickAction((if newValue then "invisible " else "visible ") .. row.Name)
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
		local s = session :: any
		local sessionLengthText = if s.JoinedAt then ("%d min"):format(math.floor((os.time() - s.JoinedAt) / 60)) else "unknown"
		makeInfoCard(
			page,
			1,
			("UserId: %d\nAccount age: %d days\nMembership: %s\nJoined: %s\nSession length: %s\nPing: %dms\nStatus: %s"):format(
				s.UserId,
				s.AccountAgeDays,
				tostring(s.MembershipType or "?"),
				if s.JoinedAt then tostring(os.date("%Y-%m-%d %H:%M", s.JoinedAt)) else "unknown",
				sessionLengthText,
				s.Ping,
				tostring(s.Status or "?")
			)
		)
		makeInfoCard(
			page,
			2,
			("Position: %s\nWalkSpeed: %s\nJumpPower: %s"):format(
				if s.Position then table.concat(s.Position, ", ") else "-",
				tostring(s.WalkSpeed or "-"),
				tostring(s.JumpPower or "-")
			)
		)
		local names = if type(s.PreviousNames) == "table" and #s.PreviousNames > 0 then table.concat(s.PreviousNames, ", ") else "none seen"
		makeInfoCard(page, 3, "Previous usernames: " .. names)
		if type(s.Suspicious) == "table" and #s.Suspicious > 0 then
			local card = makeInfoCard(page, 4, "Suspicious: " .. table.concat(s.Suspicious, "; "))
			card.TextColor3 = Theme.Colors.Warning
		end
	end

	-- ------------------------------------------------------------------
	-- Notes tab (read-only list + a real Add Note action)
	-- ------------------------------------------------------------------
	local function loadNotes(userId: number)
		local page = tabPages.Notes
		clearPage(page)

		local addRow = Instance.new("Frame")
		addRow.Name = "AddRow" -- .Kind (General / Investigation), .Input, .Add
		addRow.LayoutOrder = 1
		addRow.Size = UDim2.new(1, 0, 0, 32)
		addRow.BackgroundTransparency = 1
		addRow.Parent = page

		-- W15: General note (;note) or Investigation note (;investigate).
		local noteKind = "Note"
		local kindButton = Instance.new("TextButton")
		kindButton.Name = "Kind"
		kindButton.Size = UDim2.new(0, 96, 1, 0)
		kindButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
		kindButton.Font = Theme.Font.Medium
		kindButton.TextSize = 12
		kindButton.TextColor3 = Theme.Colors.Text
		kindButton.Text = "General"
		kindButton.Parent = addRow
		Theme.corner(kindButton, Theme.Radius.S)
		kindButton.MouseButton1Click:Connect(function()
			noteKind = if noteKind == "Note" then "Investigation" else "Note"
			kindButton.Text = if noteKind == "Note" then "General" else "Investigation"
			kindButton.BackgroundColor3 = if noteKind == "Note" then Theme.Colors.SurfaceRaised else Theme.Colors.Warning
			kindButton.TextColor3 = if noteKind == "Note" then Theme.Colors.Text else Color3.new(0, 0, 0)
		end)

		local noteInput = Instance.new("TextBox")
		noteInput.Name = "Input"
		noteInput.Position = UDim2.new(0, 102, 0, 0)
		noteInput.Size = UDim2.new(1, -172, 1, 0)
		noteInput.Text = ""
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
		addButton.Name = "Add"
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
				local tag = if note.Kind then note.Kind:upper() .. " - " else ""
				local card = makeInfoCard(page, 1 + (#list - i) + 1, ("%s[%s] %s\n%s"):format(tag, note.AddedBy, tostring(timeText), note.Text))
				card.Name = "NoteCard"
				if note.Kind == "Investigation" then
					card.TextColor3 = Theme.Colors.Warning
				end
			end
		end

		addButton.MouseButton1Click:Connect(function()
			local text = noteInput.Text
			if text == "" then
				return
			end
			runQuickAction((if noteKind == "Investigation" then "investigate " else "note ") .. selectedName .. " " .. text)
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
	-- W09 fix: show + highlight the starting tab, otherwise the first
	-- selected player had an empty detail panel until a tab was clicked.
	selectTab(activeTab)

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
	local lastSignature = ""
	local lastRecentSignature = ""
	local lastRecentRender = 0
	local recent: any = nil
	local checked: { [number]: string } = {} -- UserId -> Name

	local function checkedList(): { { UserId: number, Name: string } }
		local list = {}
		for _, row in ipairs(allRows) do
			if checked[row.UserId] then
				table.insert(list, { UserId = row.UserId, Name = row.Name })
			end
		end
		return list
	end

	local function rebuildBulk()
		for _, child in ipairs(bulkActions:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local list = checkedList()
		bulkBar.Visible = #list > 0
		countLabel.Text = if #list > 0 then ("%d checked"):format(#list) else "0 checked"
		Selection.SetMany(list)
		reflow()
		if #list == 0 then
			return
		end
		local names = {}
		for _, pick in ipairs(list) do
			table.insert(names, pick.Name)
		end
		local targetText = table.concat(names, ",")
		local label = Instance.new("TextLabel")
		label.Name = "Count"
		label.LayoutOrder = 0
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(0, 70, 0, 28)
		label.Font = Theme.Font.Bold
		label.TextSize = 12
		label.TextColor3 = Theme.Colors.Text
		label.Text = ("%d player%s"):format(#list, if #list == 1 then "" else "s")
		label.ZIndex = 5
		label.Parent = bulkActions
		for i, action in ipairs(BULK) do
			local b = chip(bulkActions, action[1], action[1], i, #action[1] * 7 + 20)
			b.ZIndex = 5
			b.BackgroundColor3 = Theme.Colors.Surface
			if action[2] == "kick" then
				b.TextColor3 = Theme.Colors.Error
			end
			b.MouseButton1Click:Connect(function()
				runQuickAction(action[2] .. " " .. targetText)
			end)
		end
		if options.OpenCommands then
			local more = chip(bulkActions, "Command", "Other command...", #BULK + 1, 120)
			more.ZIndex = 5
			more.BackgroundColor3 = Theme.Colors.Accent
			more.MouseButton1Click:Connect(function()
				-- The Commands page's Run / Fill / Build target the checked players.
				options.OpenCommands()
			end)
		end
	end

	local function setChecked(userId: number, name: string?, value: boolean)
		checked[userId] = if value then name else nil
	end

	local function passesFilter(row: PlayerRow, lowered: string): boolean
		if lowered ~= "" then
			local hit = row.Name:lower():find(lowered, 1, true)
				or row.DisplayName:lower():find(lowered, 1, true)
				or tostring(row.UserId):find(lowered, 1, true)
			if not hit then
				return false
			end
		end
		if activeFilter == "Staff" then
			return row.IsStaff == true
		elseif activeFilter == "VIP" then
			return row.IsVIP == true
		elseif activeFilter == "Suspicious" then
			return row.Suspicious ~= nil and #row.Suspicious > 0
		elseif activeFilter == "Idle" then
			return row.Status == "Idle"
		elseif activeFilter == "New" then
			return row.JoinedAt ~= nil and os.time() - row.JoinedAt < NEW_SECONDS
		end
		return true
	end

	local function sorted(rows: { PlayerRow }): { PlayerRow }
		local list = table.clone(rows)
		table.sort(list, function(a, b)
			if sortBy == "Ping" then
				return a.Ping < b.Ping
			elseif sortBy == "Health" then
				return (a.Health or 0) < (b.Health or 0)
			elseif sortBy == "Joined" then
				return (a.JoinedAt or 0) > (b.JoinedAt or 0)
			end
			return a.DisplayName:lower() < b.DisplayName:lower()
		end)
		return list
	end

	local function tag(parent: Instance, text: string, color: Color3, order: number)
		local t = Instance.new("TextLabel")
		t.Name = "Tag_" .. text
		t.LayoutOrder = order
		t.BackgroundColor3 = color
		t.BackgroundTransparency = 0.75
		t.Size = UDim2.new(0, 0, 0, 16)
		t.AutomaticSize = Enum.AutomaticSize.X
		t.Font = Theme.Font.Medium
		t.TextSize = 11
		t.TextColor3 = color
		t.Text = text
		t.Parent = parent
		Theme.corner(t, Theme.Radius.Pill)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = t
	end

	local function clearTable()
		for _, child in ipairs(tableFrame:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function sectionLabel(text: string, order: number)
		local l = Instance.new("TextLabel")
		l.Name = "Section_" .. text
		l.LayoutOrder = order
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, 22)
		l.Font = Theme.Font.Bold
		l.TextSize = 12
		l.TextColor3 = Theme.Colors.TextSecondary
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = text:upper()
		l.Parent = tableFrame
	end

	local function renderRecent()
		clearTable()
		if not recent then
			sectionLabel("Loading...", 1)
			return
		end
		local now = recent.Now or os.time()
		local order = 0
		for _, part in ipairs({ { "Recently joined", recent.Joined }, { "Recently left", recent.Left } }) do
			order += 1
			sectionLabel(("%s (%d)"):format(part[1], #part[2]), order)
			for _, entry in ipairs(part[2]) do
				order += 1
				local leftList = part[2] == recent.Left
				local line = Instance.new("Frame")
				line.Name = (if leftList then "Left_" else "Joined_") .. entry.UserId
				line.LayoutOrder = order
				line.BackgroundColor3 = Theme.Colors.SurfaceRaised
				line.Size = UDim2.new(1, 0, 0, 36)
				line.Parent = tableFrame
				Theme.corner(line, Theme.Radius.S)
				local avatar = Instance.new("ImageLabel")
				avatar.BackgroundTransparency = 1
				avatar.Position = UDim2.new(0, 6, 0.5, -12)
				avatar.Size = UDim2.fromOffset(24, 24)
				avatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(entry.UserId)
				avatar.Parent = line
				Theme.corner(avatar, UDim.new(1, 0))
				local text = Instance.new("TextLabel")
				text.BackgroundTransparency = 1
				text.Position = UDim2.new(0, 38, 0, 0)
				text.Size = UDim2.new(1, -120, 1, 0)
				text.Font = Theme.Font.Regular
				text.TextSize = 12
				text.TextColor3 = Theme.Colors.Text
				text.TextXAlignment = Enum.TextXAlignment.Left
				text.TextTruncate = Enum.TextTruncate.AtEnd
				text.RichText = true
				text.Text = ("<b>%s</b> @%s  <font color=\"#%s\">%s ago%s</font>"):format(
					entry.DisplayName,
					entry.Name,
					Theme.Colors.TextSecondary:ToHex(),
					ago(math.max(0, now - entry.At)),
					if entry.SessionSeconds then ", stayed " .. ago(entry.SessionSeconds) else ""
				)
				text.Parent = line
				local button = chip(line, "Profile", if leftList then "Profile" else "Open", 1, 64)
				button.AnchorPoint = Vector2.new(1, 0.5)
				button.Position = UDim2.new(1, -6, 0.5, 0)
				button.MouseButton1Click:Connect(function()
					if leftList then
						runQuickAction("profile " .. entry.Name)
					else
						view = "Online"
						viewOnline.BackgroundColor3 = Theme.Colors.Accent
						viewRecent.BackgroundColor3 = Theme.Colors.SurfaceRaised
						searchBox.Text = entry.Name
					end
				end)
			end
		end
	end

	renderTable = function(filter: string)
		if view == "Recent" then
			renderRecent()
			return
		end
		clearTable()
		local lowered = filter:lower()
		local order = 0
		for _, row in ipairs(sorted(allRows)) do
			if passesFilter(row, lowered) then
				order += 1
				local isSelected = row.UserId == selectedUserId
				local button = Instance.new("TextButton")
				button.Name = "Row_" .. row.UserId
				button.LayoutOrder = order
				button.Size = UDim2.new(1, 0, 0, 54)
				button.BackgroundColor3 = if isSelected then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
				button.AutoButtonColor = false
				button.Text = ""
				button.Parent = tableFrame
				Theme.corner(button, Theme.Radius.S)

				-- check box (bulk selection)
				local check = Instance.new("TextButton")
				check.Name = "Check"
				check.Position = UDim2.new(0, 6, 0.5, -10)
				check.Size = UDim2.fromOffset(20, 20)
				check.BackgroundColor3 = if checked[row.UserId] then Theme.Colors.Success else Theme.Colors.Surface
				check.Font = Theme.Font.Bold
				check.TextSize = 13
				check.TextColor3 = Color3.new(1, 1, 1)
				check.Text = ""
				check.ZIndex = 3
				check.Parent = button
				Theme.corner(check, Theme.Radius.S)
				Theme.stroke(check, Theme.Colors.Border, 1)
				check.MouseButton1Click:Connect(function()
					setChecked(row.UserId, row.Name, not checked[row.UserId])
					rebuildBulk()
					renderTable(searchBox.Text)
				end)

				local avatar = Instance.new("ImageLabel")
				avatar.Name = "Avatar"
				avatar.BackgroundColor3 = Theme.Colors.Surface
				avatar.Position = UDim2.new(0, 32, 0.5, -17)
				avatar.Size = UDim2.fromOffset(34, 34)
				avatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(row.UserId)
				avatar.Parent = button
				Theme.corner(avatar, UDim.new(1, 0))
				-- status dot on the avatar
				local dot = Instance.new("Frame")
				dot.Name = "StatusDot"
				dot.AnchorPoint = Vector2.new(1, 1)
				dot.Position = UDim2.new(1, 1, 1, 1)
				dot.Size = UDim2.fromOffset(11, 11)
				dot.BackgroundColor3 = if row.Status == "Dead" then Theme.Colors.Error
					elseif row.Status == "Idle" then Theme.Colors.Warning
					else Theme.Colors.Success
				dot.Parent = avatar
				Theme.corner(dot, UDim.new(1, 0))
				Theme.stroke(dot, Theme.Colors.SurfaceRaised, 2)

				local nameLabel = Instance.new("TextLabel")
				nameLabel.Name = "Name"
				nameLabel.BackgroundTransparency = 1
				nameLabel.Position = UDim2.new(0, 74, 0, 6)
				nameLabel.Size = UDim2.new(1, -150, 0, 18)
				nameLabel.Font = Theme.Font.Medium
				nameLabel.TextSize = 14
				nameLabel.TextColor3 = Theme.Colors.Text
				nameLabel.TextXAlignment = Enum.TextXAlignment.Left
				nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
				nameLabel.RichText = true
				nameLabel.Text = ("%s <font color=\"#%s\" size=\"12\">@%s</font>"):format(row.DisplayName, (if isSelected then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary):ToHex(), row.Name)
				nameLabel.Parent = button

				-- right side: rank chip + ping
				local right = Instance.new("Frame")
				right.Name = "Right"
				right.BackgroundTransparency = 1
				right.AnchorPoint = Vector2.new(1, 0)
				right.Position = UDim2.new(1, -8, 0, 6)
				right.Size = UDim2.new(0, 120, 0, 18)
				right.Parent = button
				local rightLayout = Instance.new("UIListLayout")
				rightLayout.FillDirection = Enum.FillDirection.Horizontal
				rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
				rightLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
				rightLayout.Padding = UDim.new(0, 6)
				rightLayout.Parent = right
				if row.Rank then
					local c = row.RankColor
					tag(right, row.Rank, if c then Color3.fromRGB(c[1], c[2], c[3]) else Theme.Colors.Accent, 1)
				end
				local ping = Instance.new("TextLabel")
				ping.Name = "Ping"
				ping.LayoutOrder = 2
				ping.BackgroundTransparency = 1
				ping.Size = UDim2.new(0, 0, 0, 16)
				ping.AutomaticSize = Enum.AutomaticSize.X
				ping.Font = Theme.Font.Mono
				ping.TextSize = 11
				ping.TextColor3 = pingColor(row.Ping)
				ping.Text = ("%dms"):format(row.Ping)
				ping.Parent = right

				-- second line: health bar + status chips
				local meta = Instance.new("Frame")
				meta.Name = "Meta"
				meta.BackgroundTransparency = 1
				meta.Position = UDim2.new(0, 74, 0, 30)
				meta.Size = UDim2.new(1, -82, 0, 18)
				meta.ClipsDescendants = true
				meta.Parent = button
				local metaLayout = Instance.new("UIListLayout")
				metaLayout.FillDirection = Enum.FillDirection.Horizontal
				metaLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				metaLayout.SortOrder = Enum.SortOrder.LayoutOrder
				metaLayout.Padding = UDim.new(0, 4)
				metaLayout.Parent = meta
				local healthTrack = Instance.new("Frame")
				healthTrack.Name = "Health"
				healthTrack.LayoutOrder = 0
				healthTrack.BackgroundColor3 = Theme.Colors.Surface
				healthTrack.Size = UDim2.fromOffset(56, 6)
				healthTrack.Parent = meta
				Theme.corner(healthTrack, UDim.new(1, 0))
				local fraction = if row.Health and row.MaxHealth and row.MaxHealth > 0 then math.clamp(row.Health / row.MaxHealth, 0, 1) else 0
				local fill = Instance.new("Frame")
				fill.Name = "Fill"
				fill.BackgroundColor3 = if fraction > 0.6 then Theme.Colors.Success elseif fraction > 0.3 then Theme.Colors.Warning else Theme.Colors.Error
				fill.Size = UDim2.new(fraction, 0, 1, 0)
				fill.Parent = healthTrack
				Theme.corner(fill, UDim.new(1, 0))
				local n = 0
				local function status(on: boolean?, text: string, color: Color3)
					if on then
						n += 1
						tag(meta, text, color, n)
					end
				end
				status(row.Suspicious ~= nil and #row.Suspicious > 0, "Suspicious", Theme.Colors.Warning)
				status(row.Status == "Dead", "Dead", Theme.Colors.Error)
				status(row.Status == "Idle", "Idle " .. ago(row.IdleSeconds or 0), Theme.Colors.Warning)
				status(row.IsJailed, "Jailed", Theme.Colors.Error)
				status(row.IsFrozen, "Frozen", Theme.Colors.Accent)
				status(row.IsMuted, "Muted", Theme.Colors.Error)
				status(row.IsGod, "God", Theme.Colors.Success)
				status(row.IsFlying, "Fly", Theme.Colors.Accent)
				status(row.IsInvisible, "Invisible", Theme.Colors.TextSecondary)
				status(row.IsStaff, "Staff", Theme.Colors.TextSecondary)
				if row.Team then
					status(true, row.Team, row.TeamColor or Theme.Colors.TextSecondary)
				end

				if isSelected then
					selectedRow = button
				end

				button.MouseButton1Click:Connect(function()
					selectedUserId = row.UserId
					selectedName = row.Name
					-- Shared with the Commands page (Run / Fill target).
					Selection.Set(row.UserId, row.Name)
					showDetail(row)
					renderTable(searchBox.Text)
				end)
			end
		end
		if order == 0 then
			sectionLabel(if #allRows == 0 then "No players" else "No players match", 1)
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		renderTable(searchBox.Text)
	end)

	local function loadRecent()
		if not getPlayerActivityRemote then
			return
		end
		local ok, result = pcall(function()
			return getPlayerActivityRemote:InvokeServer()
		end)
		if ok and type(result) == "table" then
			recent = result
		end
	end

	local function setView(name: string)
		view = name
		viewOnline.BackgroundColor3 = if name == "Online" then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		viewRecent.BackgroundColor3 = if name == "Recent" then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		if name == "Recent" then
			renderRecent()
			task.spawn(function()
				loadRecent()
				if view == "Recent" then
					renderRecent()
				end
			end)
		else
			renderTable(searchBox.Text)
		end
	end
	viewOnline.MouseButton1Click:Connect(function()
		setView("Online")
	end)
	viewRecent.MouseButton1Click:Connect(function()
		setView("Recent")
	end)

	-- Bulk selection helpers.
	selectAll.MouseButton1Click:Connect(function()
		for _, row in ipairs(allRows) do
			if passesFilter(row, searchBox.Text:lower()) then
				setChecked(row.UserId, row.Name, true)
			end
		end
		rebuildBulk()
		renderTable(searchBox.Text)
	end)
	selectOthers.MouseButton1Click:Connect(function()
		local me = game:GetService("Players").LocalPlayer.UserId
		for _, row in ipairs(allRows) do
			setChecked(row.UserId, row.Name, row.UserId ~= me and passesFilter(row, searchBox.Text:lower()))
		end
		rebuildBulk()
		renderTable(searchBox.Text)
	end)
	selectNone.MouseButton1Click:Connect(function()
		checked = {}
		rebuildBulk()
		renderTable(searchBox.Text)
	end)
	local function runSelector()
		local text = selectorBox.Text:match("^%s*(.-)%s*$") or ""
		if text == "" or not resolveTargetsRemote then
			return
		end
		local ok, result = pcall(function()
			return resolveTargetsRemote:InvokeServer(text)
		end)
		if not (ok and type(result) == "table") then
			countLabel.Text = "Couldn't resolve that."
			return
		end
		if result.Error then
			countLabel.Text = tostring(result.Error)
			return
		end
		checked = {}
		local byId = {}
		for _, row in ipairs(allRows) do
			byId[row.UserId] = row
		end
		for _, id in ipairs(result.UserIds or {}) do
			local row = byId[id]
			if row then
				setChecked(id, row.Name, true)
			end
		end
		rebuildBulk()
		renderTable(searchBox.Text)
		if #(result.UserIds or {}) == 0 then
			countLabel.Text = "No players match " .. text
		end
	end
	selectGo.MouseButton1Click:Connect(runSelector)
	selectorBox.FocusLost:Connect(function(enter: boolean)
		if enter then
			runSelector()
		end
	end)

	reflow()

	task.spawn(function()
		while true do
			if getPlayerListRemote and container.Visible ~= false then
				local ok, result = pcall(function()
					return getPlayerListRemote:InvokeServer()
				end)
				if ok and result then
					-- Rebuild the rows only when something shown changed, so a
					-- click isn't lost to a rebuild every 4 s.
					local function signature(rows: { any }): string
						local parts = {}
						for _, row in ipairs(rows) do
							table.insert(parts, table.concat({
								row.UserId, row.Ping // 10, row.Health or -1, row.MaxHealth or -1, row.Status or "",
								row.IdleSeconds and row.IdleSeconds // 60 or 0, row.Rank or "", row.Team or "",
								tostring(row.IsFrozen), tostring(row.IsJailed), tostring(row.IsMuted), tostring(row.IsGod),
								tostring(row.IsFlying), tostring(row.IsInvisible), row.Suspicious and #row.Suspicious or 0,
							}, "|"))
						end
						return table.concat(parts, ";")
					end
					local newSignature = signature(result :: { any })
					local rowsChanged = newSignature ~= lastSignature
					lastSignature = newSignature
					allRows = result :: { PlayerRow }
					-- Drop checks for players who left.
					local present = {}
					for _, row in ipairs(allRows) do
						present[row.UserId] = true
					end
					local changedChecks = false
					for id in pairs(checked) do
						if not present[id] then
							checked[id] = nil
							changedChecks = true
						end
					end
					if changedChecks then
						rebuildBulk()
					end
					if view == "Recent" then
						loadRecent()
						-- Same idea: only when the lists change (or every 20 s,
						-- for the "ago" times).
						local ids = {}
						for _, part in ipairs({ recent and recent.Joined or {}, recent and recent.Left or {} }) do
							for _, entry in ipairs(part) do
								table.insert(ids, entry.UserId .. ":" .. entry.At)
							end
						end
						local recentSignature = table.concat(ids, ",")
						if recentSignature ~= lastRecentSignature or os.clock() - lastRecentRender > 20 then
							lastRecentSignature = recentSignature
							lastRecentRender = os.clock()
							renderTable(searchBox.Text)
						end
					elseif rowsChanged then
						renderTable(searchBox.Text)
					end

					-- Keep the selected player's open tab truthful with
					-- fresh row data.
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
