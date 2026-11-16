-- ============================================
-- RANK MANAGEMENT PAGE
-- ============================================
-- Adapted from Admin Panel V4.3 Rank Management GUI
-- Features: User/Group/GamePass/Asset bindings, Owner-only access

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local Config = require(ReplicatedStorage.Shared.Sentinel.Config)

local RankManagementPage = {}
RankManagementPage.__index = RankManagementPage

-- ============================================
-- STATE
-- ============================================
local adminList = {}
local bindingMethods = {}

-- ============================================
-- INITIALIZATION
-- ============================================
function RankManagementPage.new(parent)
	local self = setmetatable({}, RankManagementPage)
	self.parent = parent
	self.container = nil
	self.theme = Theme
	self.isOwner = false
	self:Build()
	return self
end

function RankManagementPage:Build()
	-- Main container
	self.container = Instance.new("ScrollingFrame")
	self.container.Name = "RankManagementPage"
	self.container.Size = UDim2.new(1, 0, 1, 0)
	self.container.BackgroundTransparency = 1
	self.container.ScrollBarThickness = 6
	self.container.CanvasSize = UDim2.new(0, 0, 0, 0)
	self.container.AutomaticCanvasSize = Enum.AutomaticSize.Y
	self.container.Parent = self.parent

	local layout = Instance.new("UIListLayout", self.container)
	layout.Padding = UDim.new(0, 15)

	local padding = Instance.new("UIPadding", self.container)
	padding.PaddingTop = UDim.new(0, 15)
	padding.PaddingLeft = UDim.new(0, 15)
	padding.PaddingRight = UDim.new(0, 15)

	-- Check if owner
	self:CheckPermissions()

	-- Build sections
	self:BuildHeader()
	self:BuildBindingMethodsSection()
	self:BuildAdminListSection()
end

-- ============================================
-- PERMISSION CHECK
-- ============================================
function RankManagementPage:CheckPermissions()
	-- This would normally call a remote to check if player is game owner
	-- For now, we'll assume the player has permission if they're testing in Studio
	local player = Players.LocalPlayer
	self.isOwner = game.GameId == 0 or player.UserId == game.CreatorId
end

-- ============================================
-- HEADER SECTION
-- ============================================
function RankManagementPage:BuildHeader()
	local headerFrame = Instance.new("Frame", self.container)
	headerFrame.Size = UDim2.new(1, 0, 0, 100)
	headerFrame.BackgroundColor3 = self.theme.Current.Primary
	headerFrame.BorderSizePixel = 0
	headerFrame.LayoutOrder = 1

	local corner = Instance.new("UICorner", headerFrame)
	corner.CornerRadius = UDim.new(0, 12)

	-- Title
	local title = Instance.new("TextLabel", headerFrame)
	title.Size = UDim2.new(1, -20, 0, 50)
	title.Position = UDim2.new(0, 10, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "👑 Admin Rank Management"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Font = self.theme.Current.FontBold
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left

	-- Subtitle
	local subtitle = Instance.new("TextLabel", headerFrame)
	subtitle.Size = UDim2.new(1, -20, 0, 30)
	subtitle.Position = UDim2.new(0, 10, 0, 60)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = self.isOwner and "Configure permissions and rank bindings" or "⚠️ Owner access required"
	subtitle.TextColor3 = Color3.new(1, 1, 1)
	subtitle.Font = self.theme.Current.Font
	subtitle.TextSize = 14
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
end

-- ============================================
-- BINDING METHODS SECTION
-- ============================================
function RankManagementPage:BuildBindingMethodsSection()
	local sectionFrame = self:CreateSectionFrame("🔗 Permission Binding Methods")
	sectionFrame.LayoutOrder = 2

	-- Method cards
	local methodsContainer = Instance.new("Frame", sectionFrame)
	methodsContainer.Size = UDim2.new(1, -20, 0, 0)
	methodsContainer.Position = UDim2.new(0, 10, 0, 50)
	methodsContainer.BackgroundTransparency = 1
	methodsContainer.AutomaticSize = Enum.AutomaticSize.Y

	local methodsLayout = Instance.new("UIGridLayout", methodsContainer)
	methodsLayout.CellSize = UDim2.new(0.48, -5, 0, 140)
	methodsLayout.CellPadding = UDim.new(0, 10)

	-- Username Method
	self:CreateMethodCard(methodsContainer, {
		icon = "👤",
		title = "Username Binding",
		description = "Assign ranks by Roblox Username",
		placeholder = "PlayerUsername",
		buttonText = "Add by Username",
		method = "Username",
	})

	-- UserId Method
	self:CreateMethodCard(methodsContainer, {
		icon = "🆔",
		title = "User ID Binding",
		description = "Assign ranks by Roblox User ID",
		placeholder = "12345678",
		buttonText = "Add by User ID",
		method = "UserId",
	})

	-- Group Method
	self:CreateMethodCard(methodsContainer, {
		icon = "👥",
		title = "Group Binding",
		description = "Link ranks to Roblox Group roles",
		placeholder = "GroupId:RoleId",
		buttonText = "Add Group Binding",
		method = "GroupId",
	})

	-- GamePass Method
	self:CreateMethodCard(methodsContainer, {
		icon = "🎫",
		title = "GamePass Binding",
		description = "Grant ranks for GamePass ownership",
		placeholder = "GamePassId",
		buttonText = "Add GamePass",
		method = "GamePassId",
	})
end

function RankManagementPage:CreateMethodCard(parent, data)
	local card = Instance.new("Frame", parent)
	card.BackgroundColor3 = self.theme.Current.Surface
	card.BorderSizePixel = 0

	local cardCorner = Instance.new("UICorner", card)
	cardCorner.CornerRadius = UDim.new(0, 10)

	-- Icon
	local icon = Instance.new("TextLabel", card)
	icon.Size = UDim2.new(0, 40, 0, 40)
	icon.Position = UDim2.new(0, 10, 0, 10)
	icon.BackgroundTransparency = 1
	icon.Text = data.icon
	icon.TextSize = 28

	-- Title
	local title = Instance.new("TextLabel", card)
	title.Size = UDim2.new(1, -60, 0, 25)
	title.Position = UDim2.new(0, 55, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = data.title
	title.TextColor3 = self.theme.Current.Text
	title.Font = self.theme.Current.FontBold
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left

	-- Description
	local desc = Instance.new("TextLabel", card)
	desc.Size = UDim2.new(1, -60, 0, 20)
	desc.Position = UDim2.new(0, 55, 0, 35)
	desc.BackgroundTransparency = 1
	desc.Text = data.description
	desc.TextColor3 = self.theme.Current.TextDim
	desc.Font = self.theme.Current.Font
	desc.TextSize = 11
	desc.TextXAlignment = Enum.TextXAlignment.Left

	-- Input field
	local input = Instance.new("TextBox", card)
	input.Size = UDim2.new(1, -20, 0, 30)
	input.Position = UDim2.new(0, 10, 0, 60)
	input.BackgroundColor3 = self.theme.Current.Background
	input.PlaceholderText = data.placeholder
	input.Text = ""
	input.TextColor3 = self.theme.Current.Text
	input.PlaceholderColor3 = self.theme.Current.TextDim
	input.Font = self.theme.Current.Font
	input.TextSize = 12
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false

	local inputCorner = Instance.new("UICorner", input)
	inputCorner.CornerRadius = UDim.new(0, 6)

	-- Rank selector
	local rankSelector = Instance.new("TextButton", card)
	rankSelector.Size = UDim2.new(1, -20, 0, 25)
	rankSelector.Position = UDim2.new(0, 10, 0, 95)
	rankSelector.BackgroundColor3 = self.theme.Current.Background
	rankSelector.Text = "Select Rank  ▼"
	rankSelector.TextColor3 = self.theme.Current.Text
	rankSelector.Font = self.theme.Current.Font
	rankSelector.TextSize = 12
	rankSelector.BorderSizePixel = 0

	local selectorCorner = Instance.new("UICorner", rankSelector)
	selectorCorner.CornerRadius = UDim.new(0, 6)

	-- Add button
	local addBtn = Instance.new("TextButton", card)
	addBtn.Size = UDim2.new(1, -20, 0, 30)
	addBtn.Position = UDim2.new(0, 10, 1, -35)
	addBtn.BackgroundColor3 = self.isOwner and self.theme.Current.Success or self.theme.Current.Secondary
	addBtn.Text = data.buttonText
	addBtn.TextColor3 = self.theme.Current.Text
	addBtn.Font = self.theme.Current.FontBold
	addBtn.TextSize = 12
	addBtn.BorderSizePixel = 0

	local addCorner = Instance.new("UICorner", addBtn)
	addCorner.CornerRadius = UDim.new(0, 6)

	-- Rank dropdown logic
	local selectedRank = "Moderator"
	rankSelector.MouseButton1Click:Connect(function()
		-- Show rank dropdown (simplified for now)
		local dropdown = self:CreateRankDropdown(rankSelector, function(rank)
			selectedRank = rank
			rankSelector.Text = rank .. "  ▼"
		end)
	end)

	-- Add binding logic
	addBtn.MouseButton1Click:Connect(function()
		if not self.isOwner then
			return
		end

		local value = input.Text
		if value ~= "" then
			self:AddBinding(data.method, value, selectedRank)
			input.Text = ""
		end
	end)
end

function RankManagementPage:CreateRankDropdown(parentButton, callback)
	-- Remove existing dropdown
	local existing = parentButton.Parent:FindFirstChild("RankDropdown")
	if existing then
		existing:Destroy()
		return
	end

	local dropdown = Instance.new("Frame", parentButton.Parent)
	dropdown.Name = "RankDropdown"
	dropdown.Size = UDim2.new(1, -20, 0, 0)
	dropdown.Position = UDim2.new(0, 10, 0, 120)
	dropdown.BackgroundColor3 = self.theme.Current.Background
	dropdown.BorderSizePixel = 0
	dropdown.ZIndex = 100
	dropdown.AutomaticSize = Enum.AutomaticSize.Y

	local corner = Instance.new("UICorner", dropdown)
	corner.CornerRadius = UDim.new(0, 8)

	local listLayout = Instance.new("UIListLayout", dropdown)

	for _, rank in ipairs(Config.RANKS) do
		local option = Instance.new("TextButton", dropdown)
		option.Size = UDim2.new(1, 0, 0, 30)
		option.BackgroundColor3 = self.theme.Current.Surface
		option.Text = rank.name
		option.TextColor3 = rank.color
		option.Font = self.theme.Current.Font
		option.TextSize = 13
		option.BorderSizePixel = 0

		local optionCorner = Instance.new("UICorner", option)
		optionCorner.CornerRadius = UDim.new(0, 6)

		option.MouseButton1Click:Connect(function()
			callback(rank.name)
			dropdown:Destroy()
		end)
	end

	-- Auto-close after 5 seconds
	task.delay(5, function()
		if dropdown and dropdown.Parent then
			dropdown:Destroy()
		end
	end)

	return dropdown
end

-- ============================================
-- ADMIN LIST SECTION
-- ============================================
function RankManagementPage:BuildAdminListSection()
	local sectionFrame = self:CreateSectionFrame("📋 Current Admin List")
	sectionFrame.LayoutOrder = 3

	-- Search bar
	local searchBar = Instance.new("TextBox", sectionFrame)
	searchBar.Size = UDim2.new(1, -20, 0, 35)
	searchBar.Position = UDim2.new(0, 10, 0, 50)
	searchBar.BackgroundColor3 = self.theme.Current.Surface
	searchBar.PlaceholderText = "🔍 Search admins..."
	searchBar.Text = ""
	searchBar.TextColor3 = self.theme.Current.Text
	searchBar.PlaceholderColor3 = self.theme.Current.TextDim
	searchBar.Font = self.theme.Current.Font
	searchBar.TextSize = 13
	searchBar.BorderSizePixel = 0

	local searchCorner = Instance.new("UICorner", searchBar)
	searchCorner.CornerRadius = UDim.new(0, 8)

	-- Admin list
	local adminListContainer = Instance.new("ScrollingFrame", sectionFrame)
	adminListContainer.Size = UDim2.new(1, -20, 0, 300)
	adminListContainer.Position = UDim2.new(0, 10, 0, 95)
	adminListContainer.BackgroundColor3 = self.theme.Current.Surface
	adminListContainer.BorderSizePixel = 0
	adminListContainer.ScrollBarThickness = 6
	adminListContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
	adminListContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y

	local listCorner = Instance.new("UICorner", adminListContainer)
	listCorner.CornerRadius = UDim.new(0, 8)

	local listLayout = Instance.new("UIListLayout", adminListContainer)
	listLayout.Padding = UDim.new(0, 8)

	local listPadding = Instance.new("UIPadding", adminListContainer)
	listPadding.PaddingTop = UDim.new(0, 8)
	listPadding.PaddingLeft = UDim.new(0, 8)
	listPadding.PaddingRight = UDim.new(0, 8)

	-- Placeholder admin entries
	self:RefreshAdminList(adminListContainer)
end

function RankManagementPage:RefreshAdminList(container)
	-- Clear existing
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Add placeholder entries
	if #adminList == 0 then
		local emptyLabel = Instance.new("TextLabel", container)
		emptyLabel.Size = UDim2.new(1, -16, 0, 50)
		emptyLabel.BackgroundTransparency = 1
		emptyLabel.Text = "No admins configured yet.\nUse the binding methods above to add admins."
		emptyLabel.TextColor3 = self.theme.Current.TextDim
		emptyLabel.Font = self.theme.Current.Font
		emptyLabel.TextSize = 12
		emptyLabel.TextWrapped = true
	else
		for _, admin in ipairs(adminList) do
			self:CreateAdminRow(container, admin)
		end
	end
end

function RankManagementPage:CreateAdminRow(parent, admin)
	local row = Instance.new("Frame", parent)
	row.Size = UDim2.new(1, -16, 0, 70)
	row.BackgroundColor3 = self.theme.Current.Background
	row.BorderSizePixel = 0

	local rowCorner = Instance.new("UICorner", row)
	rowCorner.CornerRadius = UDim.new(0, 8)

	-- Username/Identifier
	local nameLabel = Instance.new("TextLabel", row)
	nameLabel.Size = UDim2.new(0.4, 0, 0, 25)
	nameLabel.Position = UDim2.new(0, 10, 0, 10)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = admin.username or admin.identifier
	nameLabel.TextColor3 = self.theme.Current.Text
	nameLabel.Font = self.theme.Current.FontBold
	nameLabel.TextSize = 14
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Rank badge
	local rankBadge = Instance.new("TextLabel", row)
	rankBadge.Size = UDim2.new(0, 100, 0, 25)
	rankBadge.Position = UDim2.new(0.45, 0, 0, 10)
	rankBadge.BackgroundColor3 = admin.rankColor or self.theme.Current.Primary
	rankBadge.Text = admin.rank
	rankBadge.TextColor3 = self.theme.Current.Text
	rankBadge.Font = self.theme.Current.FontBold
	rankBadge.TextSize = 11

	local badgeCorner = Instance.new("UICorner", rankBadge)
	badgeCorner.CornerRadius = UDim.new(0, 12)

	-- Binding method
	local methodLabel = Instance.new("TextLabel", row)
	methodLabel.Size = UDim2.new(1, -20, 0, 20)
	methodLabel.Position = UDim2.new(0, 10, 0, 40)
	methodLabel.BackgroundTransparency = 1
	methodLabel.Text = "Via: " .. (admin.method or "Username")
	methodLabel.TextColor3 = self.theme.Current.TextDim
	methodLabel.Font = self.theme.Current.Font
	methodLabel.TextSize = 11
	methodLabel.TextXAlignment = Enum.TextXAlignment.Left

	-- Edit button
	local editBtn = Instance.new("TextButton", row)
	editBtn.Size = UDim2.new(0, 80, 0, 30)
	editBtn.Position = UDim2.new(1, -90, 0.5, -15)
	editBtn.BackgroundColor3 = self.theme.Current.Primary
	editBtn.Text = "Edit"
	editBtn.TextColor3 = self.theme.Current.Text
	editBtn.Font = self.theme.Current.FontBold
	editBtn.TextSize = 12
	editBtn.BorderSizePixel = 0

	local editCorner = Instance.new("UICorner", editBtn)
	editCorner.CornerRadius = UDim.new(0, 6)

	editBtn.MouseButton1Click:Connect(function()
		self:ShowEditDialog(admin)
	end)

	-- Remove button
	local removeBtn = Instance.new("TextButton", row)
	removeBtn.Size = UDim2.new(0, 80, 0, 30)
	removeBtn.Position = UDim2.new(1, -180, 0.5, -15)
	removeBtn.BackgroundColor3 = self.theme.Current.Error
	removeBtn.Text = "Remove"
	removeBtn.TextColor3 = self.theme.Current.Text
	removeBtn.Font = self.theme.Current.FontBold
	removeBtn.TextSize = 12
	removeBtn.BorderSizePixel = 0

	local removeCorner = Instance.new("UICorner", removeBtn)
	removeCorner.CornerRadius = UDim.new(0, 6)

	removeBtn.MouseButton1Click:Connect(function()
		self:RemoveAdmin(admin)
	end)
end

-- ============================================
-- ACTIONS
-- ============================================
function RankManagementPage:AddBinding(method, value, rank)
	-- This would call a remote to add the binding on the server
	-- For now, add to local list
	table.insert(adminList, {
		username = value,
		rank = rank,
		method = method,
		rankColor = Config.GetRank(rank) and Config.GetRank(rank).color,
	})

	self:Refresh()
end

function RankManagementPage:RemoveAdmin(admin)
	-- Remove from list
	for i, a in ipairs(adminList) do
		if a == admin then
			table.remove(adminList, i)
			break
		end
	end

	self:Refresh()
end

function RankManagementPage:ShowEditDialog(admin)
	-- Create edit dialog
	local dialog = Instance.new("ScreenGui", Players.LocalPlayer.PlayerGui)
	dialog.Name = "EditAdminDialog"
	dialog.ResetOnSpawn = false

	local overlay = Instance.new("Frame", dialog)
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.BorderSizePixel = 0

	local frame = Instance.new("Frame", dialog)
	frame.Size = UDim2.new(0, 400, 0, 300)
	frame.Position = UDim2.new(0.5, -200, 0.5, -150)
	frame.BackgroundColor3 = self.theme.Current.Surface
	frame.BorderSizePixel = 0

	local frameCorner = Instance.new("UICorner", frame)
	frameCorner.CornerRadius = UDim.new(0, 15)

	-- Title
	local title = Instance.new("TextLabel", frame)
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.new(0, 10, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "Edit Rank for " .. (admin.username or admin.identifier)
	title.TextColor3 = self.theme.Current.Text
	title.Font = self.theme.Current.FontBold
	title.TextSize = 18

	-- Rank selector
	local rankLabel = Instance.new("TextLabel", frame)
	rankLabel.Size = UDim2.new(1, -20, 0, 20)
	rankLabel.Position = UDim2.new(0, 10, 0, 60)
	rankLabel.BackgroundTransparency = 1
	rankLabel.Text = "Select new rank:"
	rankLabel.TextColor3 = self.theme.Current.TextDim
	rankLabel.Font = self.theme.Current.Font
	rankLabel.TextSize = 12
	rankLabel.TextXAlignment = Enum.TextXAlignment.Left

	local ranksContainer = Instance.new("Frame", frame)
	ranksContainer.Size = UDim2.new(1, -20, 0, 140)
	ranksContainer.Position = UDim2.new(0, 10, 0, 90)
	ranksContainer.BackgroundTransparency = 1

	local ranksLayout = Instance.new("UIGridLayout", ranksContainer)
	ranksLayout.CellSize = UDim2.new(0.48, -5, 0, 35)
	ranksLayout.CellPadding = UDim.new(0, 5)

	for _, rank in ipairs(Config.RANKS) do
		local rankBtn = Instance.new("TextButton", ranksContainer)
		rankBtn.BackgroundColor3 = rank.color
		rankBtn.Text = rank.name
		rankBtn.TextColor3 = self.theme.Current.Text
		rankBtn.Font = self.theme.Current.FontBold
		rankBtn.TextSize = 12
		rankBtn.BorderSizePixel = admin.rank == rank.name and 3 or 0

		local rankBtnCorner = Instance.new("UICorner", rankBtn)
		rankBtnCorner.CornerRadius = UDim.new(0, 8)

		rankBtn.MouseButton1Click:Connect(function()
			admin.rank = rank.name
			admin.rankColor = rank.color
			dialog:Destroy()
			self:Refresh()
		end)
	end

	-- Close button
	local closeBtn = Instance.new("TextButton", frame)
	closeBtn.Size = UDim2.new(1, -20, 0, 35)
	closeBtn.Position = UDim2.new(0, 10, 1, -45)
	closeBtn.BackgroundColor3 = self.theme.Current.Error
	closeBtn.Text = "Cancel"
	closeBtn.TextColor3 = self.theme.Current.Text
	closeBtn.Font = self.theme.Current.FontBold
	closeBtn.TextSize = 13
	closeBtn.BorderSizePixel = 0

	local closeCorner = Instance.new("UICorner", closeBtn)
	closeCorner.CornerRadius = UDim.new(0, 8)

	closeBtn.MouseButton1Click:Connect(function()
		dialog:Destroy()
	end)
end

-- ============================================
-- HELPERS
-- ============================================
function RankManagementPage:CreateSectionFrame(title)
	local frame = Instance.new("Frame", self.container)
	frame.Size = UDim2.new(1, 0, 0, 200)
	frame.BackgroundColor3 = self.theme.Current.Background
	frame.BorderSizePixel = 0
	frame.AutomaticSize = Enum.AutomaticSize.Y

	local corner = Instance.new("UICorner", frame)
	corner.CornerRadius = UDim.new(0, 12)

	-- Section header
	local header = Instance.new("TextLabel", frame)
	header.Size = UDim2.new(1, -20, 0, 35)
	header.Position = UDim2.new(0, 10, 0, 10)
	header.BackgroundTransparency = 1
	header.Text = title
	header.TextColor3 = self.theme.Current.Primary
	header.Font = self.theme.Current.FontBold
	header.TextSize = 18
	header.TextXAlignment = Enum.TextXAlignment.Left

	return frame
end

function RankManagementPage:Refresh()
	if self.container then
		self.container:Destroy()
	end
	self:Build()
end

return RankManagementPage
