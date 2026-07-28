--!strict
--[[
	SettingsPage.lua

	Purpose:
		Phase 7E from the roadmap: a read-only Permissions viewer against
		PermissionSystem, a handful of REAL client preferences, and
		explicit "not implemented" notes for features with no backend
		(Discord/Slack integration, 2FA) instead of dead toggles.

	Scope notes:
		- Permissions are read-only by design — there's no assign/revoke
		  control here because role assignment isn't exposed anywhere in
		  Sentinel yet (it happens via `PermissionSystem.AssignRole` calls
		  in bootstrap code). Adding an assign UI here would be a much
		  bigger, separate feature (its own audit trail, its own misuse
		  risk) and isn't what 7E asked for.
		- The three preferences below are wired to real behavior, not
		  placeholders: Mute Toasts and Reduce Motion both call straight
		  into `NotificationCenter`'s actual toast pipeline, and Clear
		  Command History calls `CommandPalette.ClearHistory()`. None of
		  them persist across sessions — there's no client-side prefs
		  store yet, so this is honestly a session-only settings panel,
		  not a "saved settings" one.
		- Discord/Slack and 2FA rows are intentionally inert (no click
		  handler, dimmed text, a "Not implemented" tag) rather than
		  toggles that quietly do nothing — per the explicit instruction
		  not to build fake settings for unimplemented features.

	Dependencies:
		Theme.lua, ToggleSwitch.lua

	Public API:
		SettingsPage.Build(container: Frame, commandPalette: any, notificationCenter: any): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local ToggleSwitch = require(script.Parent:WaitForChild("ToggleSwitch"))

local SettingsPage = {}

type RoleDefinition = {
	Nodes: { string },
	Inherits: { string },
}

type PermissionsSnapshot = {
	MyRoles: { string },
	Roles: { [string]: RoleDefinition },
}

local function makeSectionHeader(parent: Frame, order: number, text: string): (Frame, Frame)
	local section = Instance.new("Frame")
	section.LayoutOrder = order
	section.Size = UDim2.new(1, 0, 0, 0)
	section.AutomaticSize = Enum.AutomaticSize.Y
	section.BackgroundTransparency = 1
	section.Parent = parent

	local sectionLayout = Instance.new("UIListLayout")
	sectionLayout.Padding = UDim.new(0, 8)
	sectionLayout.SortOrder = Enum.SortOrder.LayoutOrder
	sectionLayout.Parent = section

	local titleRow = Instance.new("Frame")
	titleRow.LayoutOrder = 1
	titleRow.BackgroundTransparency = 1
	titleRow.Size = UDim2.new(1, 0, 0, 22)
	titleRow.Parent = section

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -100, 1, 0)
	title.Font = Theme.Font.Bold
	title.TextSize = 15
	title.TextColor3 = Theme.Colors.Text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = text
	title.Parent = titleRow

	return section, titleRow
end

local function makeRow(parent: Frame, order: number, height: number): Frame
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundColor3 = Theme.Colors.SurfaceRaised
	row.BorderSizePixel = 0
	row.Parent = parent
	Theme.corner(row, Theme.Radius.M)
	Theme.padding(row, Theme.Spacing.S)
	return row
end

function SettingsPage.Build(container: Frame, commandPalette: any, notificationCenter: any)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Settings"
	header.Parent = container

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.Position = UDim2.new(0, 0, 0, 38)
	body.Size = UDim2.new(1, 0, 1, -38)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.CanvasSize = UDim2.new(0, 0, 0, 0)
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.Parent = container

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.Padding = UDim.new(0, 20)
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = body

	-- ------------------------------------------------------------------
	-- Section: Your Permissions (read-only)
	-- ------------------------------------------------------------------
	local permSection, permTitleRow = makeSectionHeader(body, 1, "🔐 Your Permissions")

	local myRolesLabel = Instance.new("TextLabel")
	myRolesLabel.LayoutOrder = 2
	myRolesLabel.BackgroundColor3 = Theme.Colors.SurfaceRaised
	myRolesLabel.Size = UDim2.new(1, 0, 0, 28)
	myRolesLabel.Font = Theme.Font.Medium
	myRolesLabel.TextSize = 13
	myRolesLabel.TextColor3 = Theme.Colors.Text
	myRolesLabel.TextXAlignment = Enum.TextXAlignment.Left
	myRolesLabel.Text = "Loading your roles..."
	myRolesLabel.Parent = permSection
	Theme.corner(myRolesLabel, Theme.Radius.S)
	Theme.padding(myRolesLabel, 8)

	local rolesListFrame = Instance.new("Frame")
	rolesListFrame.LayoutOrder = 3
	rolesListFrame.Size = UDim2.new(1, 0, 0, 0)
	rolesListFrame.AutomaticSize = Enum.AutomaticSize.Y
	rolesListFrame.BackgroundTransparency = 1
	rolesListFrame.Parent = permSection

	local rolesListLayout = Instance.new("UIListLayout")
	rolesListLayout.Padding = UDim.new(0, 4)
	rolesListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rolesListLayout.Parent = rolesListFrame

	local function renderRoleCatalog(snapshot: PermissionsSnapshot)
		myRolesLabel.Text = if #snapshot.MyRoles > 0
			then "Your roles: " .. table.concat(snapshot.MyRoles, ", ")
			else "Your roles: (none)"

		for _, child in ipairs(rolesListFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local roleNames = {}
		for roleName in pairs(snapshot.Roles) do
			table.insert(roleNames, roleName)
		end
		table.sort(roleNames)

		for i, roleName in ipairs(roleNames) do
			local def = snapshot.Roles[roleName]
			local card = Instance.new("Frame")
			card.LayoutOrder = i
			card.Size = UDim2.new(1, 0, 0, 0)
			card.AutomaticSize = Enum.AutomaticSize.Y
			card.BackgroundColor3 = Theme.Colors.Surface
			card.BorderSizePixel = 0
			card.Parent = rolesListFrame
			Theme.corner(card, Theme.Radius.S)
			Theme.padding(card, 8)

			local cardLayout = Instance.new("UIListLayout")
			cardLayout.Padding = UDim.new(0, 2)
			cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
			cardLayout.Parent = card

			local nameLabel = Instance.new("TextLabel")
			nameLabel.LayoutOrder = 1
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.new(1, 0, 0, 18)
			nameLabel.Font = Theme.Font.Bold
			nameLabel.TextSize = 13
			nameLabel.TextColor3 = Theme.Colors.Accent
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = roleName
			nameLabel.Parent = card

			local nodesLabel = Instance.new("TextLabel")
			nodesLabel.LayoutOrder = 2
			nodesLabel.BackgroundTransparency = 1
			nodesLabel.Size = UDim2.new(1, 0, 0, 0)
			nodesLabel.AutomaticSize = Enum.AutomaticSize.Y
			nodesLabel.Font = Theme.Font.Mono
			nodesLabel.TextSize = 12
			nodesLabel.TextColor3 = Theme.Colors.TextSecondary
			nodesLabel.TextWrapped = true
			nodesLabel.TextXAlignment = Enum.TextXAlignment.Left
			nodesLabel.Text = "Nodes: " .. (if #def.Nodes > 0 then table.concat(def.Nodes, ", ") else "(none)")
			nodesLabel.Parent = card

			if #def.Inherits > 0 then
				local inheritsLabel = Instance.new("TextLabel")
				inheritsLabel.LayoutOrder = 3
				inheritsLabel.BackgroundTransparency = 1
				inheritsLabel.Size = UDim2.new(1, 0, 0, 16)
				inheritsLabel.Font = Theme.Font.Regular
				inheritsLabel.TextSize = 12
				inheritsLabel.TextColor3 = Theme.Colors.TextSecondary
				inheritsLabel.TextXAlignment = Enum.TextXAlignment.Left
				inheritsLabel.Text = "Inherits: " .. table.concat(def.Inherits, ", ")
				inheritsLabel.Parent = card
			end
		end
	end

	-- ------------------------------------------------------------------
	-- Section: Preferences (real, session-only)
	-- ------------------------------------------------------------------
	local prefsSection = makeSectionHeader(body, 2, "⚙ Preferences")

	local muteRow = makeRow(prefsSection, 2, 40)
	local muteLabel = Instance.new("TextLabel")
	muteLabel.BackgroundTransparency = 1
	muteLabel.Size = UDim2.new(1, -50, 1, 0)
	muteLabel.Font = Theme.Font.Medium
	muteLabel.TextSize = 14
	muteLabel.TextColor3 = Theme.Colors.Text
	muteLabel.TextXAlignment = Enum.TextXAlignment.Left
	muteLabel.Text = "🔕  Mute notification toasts"
	muteLabel.Parent = muteRow
	ToggleSwitch.Create(muteRow, {
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Initial = if notificationCenter then notificationCenter.IsMuted() else false,
		OnToggle = function(newValue: boolean)
			if notificationCenter then
				notificationCenter.SetMuted(newValue)
			end
		end,
	})

	local motionRow = makeRow(prefsSection, 3, 40)
	local motionLabel = Instance.new("TextLabel")
	motionLabel.BackgroundTransparency = 1
	motionLabel.Size = UDim2.new(1, -50, 1, 0)
	motionLabel.Font = Theme.Font.Medium
	motionLabel.TextSize = 14
	motionLabel.TextColor3 = Theme.Colors.Text
	motionLabel.TextXAlignment = Enum.TextXAlignment.Left
	motionLabel.Text = "🎞  Reduce motion (skip toast animations)"
	motionLabel.Parent = motionRow
	ToggleSwitch.Create(motionRow, {
		Position = UDim2.new(1, 0, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Initial = if notificationCenter then notificationCenter.IsReducedMotion() else false,
		OnToggle = function(newValue: boolean)
			if notificationCenter then
				notificationCenter.SetReducedMotion(newValue)
			end
		end,
	})

	local historyRow = makeRow(prefsSection, 4, 40)
	local historyLabel = Instance.new("TextLabel")
	historyLabel.Name = "HistoryLabel"
	historyLabel.BackgroundTransparency = 1
	historyLabel.Size = UDim2.new(1, -100, 1, 0)
	historyLabel.Font = Theme.Font.Medium
	historyLabel.TextSize = 14
	historyLabel.TextColor3 = Theme.Colors.Text
	historyLabel.TextXAlignment = Enum.TextXAlignment.Left
	historyLabel.Text = "📜  Command Palette history"
	historyLabel.Parent = historyRow

	local clearHistoryButton = Instance.new("TextButton")
	clearHistoryButton.AnchorPoint = Vector2.new(1, 0.5)
	clearHistoryButton.Position = UDim2.new(1, 0, 0.5, 0)
	clearHistoryButton.Size = UDim2.new(0, 90, 0, 26)
	clearHistoryButton.BackgroundColor3 = Theme.Colors.Accent
	clearHistoryButton.Font = Theme.Font.Medium
	clearHistoryButton.TextSize = 12
	clearHistoryButton.TextColor3 = Color3.new(1, 1, 1)
	clearHistoryButton.Text = "Clear"
	clearHistoryButton.Parent = historyRow
	Theme.corner(clearHistoryButton, Theme.Radius.S)
	clearHistoryButton.MouseButton1Click:Connect(function()
		if commandPalette then
			commandPalette.ClearHistory()
			historyLabel.Text = "📜  Command Palette history (cleared)"
		end
	end)

	-- ------------------------------------------------------------------
	-- Section: Not Implemented (honest, inert — no dead toggles)
	-- ------------------------------------------------------------------
	local notImplementedSection = makeSectionHeader(body, 3, "🚧 Not Implemented")

	local function makeNotImplementedRow(order: number, icon: string, label: string)
		local row = makeRow(notImplementedSection, order, 40)
		row.BackgroundTransparency = 0.4

		local rowLabel = Instance.new("TextLabel")
		rowLabel.BackgroundTransparency = 1
		rowLabel.Size = UDim2.new(1, -110, 1, 0)
		rowLabel.Font = Theme.Font.Medium
		rowLabel.TextSize = 14
		rowLabel.TextColor3 = Theme.Colors.TextSecondary
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.Text = icon .. "  " .. label
		rowLabel.Parent = row

		local tag = Instance.new("TextLabel")
		tag.AnchorPoint = Vector2.new(1, 0.5)
		tag.Position = UDim2.new(1, 0, 0.5, 0)
		tag.Size = UDim2.new(0, 100, 0, 20)
		tag.BackgroundColor3 = Theme.Colors.Surface
		tag.Font = Theme.Font.Regular
		tag.TextSize = 11
		tag.TextColor3 = Theme.Colors.TextSecondary
		tag.Text = "Not implemented"
		tag.Parent = row
		Theme.corner(tag, Theme.Radius.S)
	end

	makeNotImplementedRow(2, "💬", "Discord/Slack integration")
	makeNotImplementedRow(3, "🔒", "Two-Factor Authentication (2FA)")

	-- ------------------------------------------------------------------
	-- Load the permissions snapshot once — role definitions don't churn
	-- during a session, so this isn't worth a 4s poll like the player-
	-- facing pages. A Refresh button covers the rare case they change.
	-- ------------------------------------------------------------------
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getPermissionsSnapshotRemote = SentinelShared:WaitForChild("GetPermissionsSnapshotRemote", 15) :: RemoteFunction?

	local function loadPermissions()
		if not getPermissionsSnapshotRemote then
			return
		end
		local ok, snapshot = pcall(function()
			return getPermissionsSnapshotRemote:InvokeServer()
		end)
		if ok and snapshot then
			renderRoleCatalog(snapshot :: PermissionsSnapshot)
		end
	end

	local refreshButton = Instance.new("TextButton")
	refreshButton.AnchorPoint = Vector2.new(1, 0.5)
	refreshButton.Position = UDim2.new(1, 0, 0.5, 0)
	refreshButton.Size = UDim2.new(0, 90, 0, 22)
	refreshButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	refreshButton.Font = Theme.Font.Medium
	refreshButton.TextSize = 11
	refreshButton.TextColor3 = Theme.Colors.TextSecondary
	refreshButton.Text = "↻ Refresh"
	refreshButton.Parent = permTitleRow
	Theme.corner(refreshButton, Theme.Radius.S)
	refreshButton.MouseButton1Click:Connect(loadPermissions)

	loadPermissions()
end

return SettingsPage
