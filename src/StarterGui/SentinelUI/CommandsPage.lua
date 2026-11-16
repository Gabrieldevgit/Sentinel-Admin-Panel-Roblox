--!strict
--[[
	CommandsPage.lua

	Purpose:
		Dedicated Commands catalog page for Sentinel, inspired by HD Admin & Nexus Admin:
		- Searchable and category-filtered directory of all registered commands
		- Live view of usage syntax, required permission nodes, and aliases
		- One-click "Run" and "Fill into Palette" action buttons

	Dependencies:
		Theme.lua

	Public API:
		CommandsPage.Build(container: Frame, commandPalette: any): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local CommandsPage = {}

type CommandEntry = {
	Name: string,
	Aliases: { string },
	Description: string,
	Usage: string,
	Permission: string,
	Category: string,
}

local CATEGORIES = {
	"All",
	"Movement",
	"Player",
	"Effects",
	"Moderation",
	"Server",
	"Economy",
	"Environment",
	"Developer",
	"Utility",
}

function CommandsPage.Build(container: Frame, commandPalette: any)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getCommandListRemote = SentinelShared:WaitForChild("GetCommandListRemote", 15) :: RemoteFunction?
	local executeCommandRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Commands Directory"
	header.Parent = container

	local subHeader = Instance.new("TextLabel")
	subHeader.BackgroundTransparency = 1
	subHeader.Position = UDim2.new(0, 0, 0, 30)
	subHeader.Size = UDim2.new(1, 0, 0, 20)
	subHeader.Font = Theme.Font.Regular
	subHeader.TextSize = 12
	subHeader.TextColor3 = Theme.Colors.TextSecondary
	subHeader.TextXAlignment = Enum.TextXAlignment.Left
	subHeader.Text = "Browse, search, and run any command available to your role."
	subHeader.Parent = container

	-- Search Input
	local searchBox = Instance.new("TextBox")
	searchBox.Name = "CommandSearch"
	searchBox.Position = UDim2.new(0, 0, 0, 56)
	searchBox.Size = UDim2.new(0.4, 0, 0, 32)
	searchBox.BackgroundColor3 = Theme.Colors.Surface
	searchBox.Font = Theme.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextColor3 = Theme.Colors.Text
	searchBox.PlaceholderText = "Search commands or aliases..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Parent = container
	Theme.corner(searchBox, Theme.Radius.S)
	Theme.padding(searchBox, 8)

	-- Category filter bar
	local filterBar = Instance.new("ScrollingFrame")
	filterBar.Name = "CategoryFilterBar"
	filterBar.Position = UDim2.new(0.42, 0, 0, 56)
	filterBar.Size = UDim2.new(0.58, 0, 0, 32)
	filterBar.BackgroundTransparency = 1
	filterBar.BorderSizePixel = 0
	filterBar.ScrollBarThickness = 0
	filterBar.CanvasSize = UDim2.new(0, 0, 0, 0)
	filterBar.AutomaticCanvasSize = Enum.AutomaticSize.X
	filterBar.Parent = container

	local filterLayout = Instance.new("UIListLayout")
	filterLayout.FillDirection = Enum.FillDirection.Horizontal
	filterLayout.Padding = UDim.new(0, 6)
	filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	filterLayout.Parent = filterBar

	-- Commands Grid / List
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "CommandsList"
	scrollFrame.Position = UDim2.new(0, 0, 0, 98)
	scrollFrame.Size = UDim2.new(1, 0, 1, -98)
	scrollFrame.BackgroundColor3 = Theme.Colors.Surface
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 5
	scrollFrame.ScrollBarImageColor3 = Theme.Colors.Border
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.Parent = container
	Theme.corner(scrollFrame, Theme.Radius.M)
	Theme.padding(scrollFrame, Theme.Spacing.S)

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 8)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = scrollFrame

	local allCommands: { CommandEntry } = {}
	local activeCategory = "All"
	local categoryButtons: { [string]: TextButton } = {}

	local function renderCommands()
		for _, child in ipairs(scrollFrame:GetChildren()) do
			if child:IsA("Frame") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		local query = searchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
		local count = 0

		for _, cmd in ipairs(allCommands) do
			local matchesCategory = (activeCategory == "All") or (cmd.Category == activeCategory)
			local matchesQuery = true

			if #query > 0 then
				local inName = cmd.Name:lower():find(query, 1, true) ~= nil
				local inDesc = cmd.Description:lower():find(query, 1, true) ~= nil
				local inUsage = cmd.Usage:lower():find(query, 1, true) ~= nil
				local inAliases = false
				for _, a in ipairs(cmd.Aliases) do
					if a:lower():find(query, 1, true) ~= nil then
						inAliases = true
						break
					end
				end
				matchesQuery = inName or inDesc or inUsage or inAliases
			end

			if matchesCategory and matchesQuery then
				count += 1

				local card = Instance.new("Frame")
				card.Name = "CmdCard_" .. cmd.Name
				card.Size = UDim2.new(1, 0, 0, 68)
				card.BackgroundColor3 = Theme.Colors.SurfaceRaised
				card.BorderSizePixel = 0
				card.Parent = scrollFrame
				Theme.corner(card, Theme.Radius.S)
				Theme.padding(card, 8)

				-- Header line: Name + Aliases + Category
				local titleLine = Instance.new("Frame")
				titleLine.BackgroundTransparency = 1
				titleLine.Size = UDim2.new(1, -140, 0, 20)
				titleLine.Parent = card

				local titleLayout = Instance.new("UIListLayout")
				titleLayout.FillDirection = Enum.FillDirection.Horizontal
				titleLayout.Padding = UDim.new(0, 6)
				titleLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				titleLayout.Parent = titleLine

				local nameLbl = Instance.new("TextLabel")
				nameLbl.BackgroundTransparency = 1
				nameLbl.Font = Theme.Font.Bold
				nameLbl.TextSize = 15
				nameLbl.TextColor3 = Theme.Colors.Accent
				nameLbl.AutomaticSize = Enum.AutomaticSize.X
				nameLbl.Size = UDim2.new(0, 0, 1, 0)
				nameLbl.Text = ";" .. cmd.Name
				nameLbl.Parent = titleLine

				if #cmd.Aliases > 0 then
					local aliasLbl = Instance.new("TextLabel")
					aliasLbl.BackgroundTransparency = 1
					aliasLbl.Font = Theme.Font.Regular
					aliasLbl.TextSize = 12
					aliasLbl.TextColor3 = Theme.Colors.TextSecondary
					aliasLbl.AutomaticSize = Enum.AutomaticSize.X
					aliasLbl.Size = UDim2.new(0, 0, 1, 0)
					aliasLbl.Text = "(" .. table.concat(cmd.Aliases, ", ") .. ")"
					aliasLbl.Parent = titleLine
				end

				local catBadge = Instance.new("TextLabel")
				catBadge.BackgroundColor3 = Theme.Colors.Surface
				catBadge.Font = Theme.Font.Medium
				catBadge.TextSize = 10
				catBadge.TextColor3 = Theme.Colors.TextSecondary
				catBadge.AutomaticSize = Enum.AutomaticSize.X
				catBadge.Size = UDim2.new(0, 0, 0, 16)
				catBadge.Text = " " .. cmd.Category .. " "
				catBadge.Parent = titleLine
				Theme.corner(catBadge, UDim.new(0, 4))

				-- Description
				local descLbl = Instance.new("TextLabel")
				descLbl.BackgroundTransparency = 1
				descLbl.Position = UDim2.new(0, 0, 0, 22)
				descLbl.Size = UDim2.new(1, -140, 0, 16)
				descLbl.Font = Theme.Font.Regular
				descLbl.TextSize = 12
				descLbl.TextColor3 = Theme.Colors.Text
				descLbl.TextXAlignment = Enum.TextXAlignment.Left
				descLbl.TextTruncate = Enum.TextTruncate.AtEnd
				descLbl.Text = cmd.Description
				descLbl.Parent = card

				-- Usage & Permission line
				local usageLbl = Instance.new("TextLabel")
				usageLbl.BackgroundTransparency = 1
				usageLbl.Position = UDim2.new(0, 0, 0, 38)
				usageLbl.Size = UDim2.new(1, -140, 0, 16)
				usageLbl.Font = Theme.Font.Mono
				usageLbl.TextSize = 11
				usageLbl.TextColor3 = Theme.Colors.TextSecondary
				usageLbl.TextXAlignment = Enum.TextXAlignment.Left
				local risk = (cmd :: any).Risk
				local riskText = if risk and risk ~= "low" then ("   •   Risk: %s"):format(risk:upper()) else ""
				if (cmd :: any).OwnerOnly then
					riskText ..= "   •   Owner only"
				end
				usageLbl.Text = ("Usage: %s   •   Node: %s%s"):format(cmd.Usage, cmd.Permission, riskText)
				if risk == "high" or risk == "critical" then
					usageLbl.TextColor3 = Theme.Colors.Error
				elseif risk == "medium" then
					usageLbl.TextColor3 = Theme.Colors.Warning
				end
				usageLbl.Parent = card

				-- Action Buttons Container
				local btnGroup = Instance.new("Frame")
				btnGroup.BackgroundTransparency = 1
				btnGroup.AnchorPoint = Vector2.new(1, 0.5)
				btnGroup.Position = UDim2.new(1, 0, 0.5, 0)
				btnGroup.Size = UDim2.new(0, 130, 0, 30)
				btnGroup.Parent = card

				local btnLayout = Instance.new("UIListLayout")
				btnLayout.FillDirection = Enum.FillDirection.Horizontal
				btnLayout.Padding = UDim.new(0, 6)
				btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
				btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				btnLayout.Parent = btnGroup

				-- Fill into Palette button
				local fillBtn = Instance.new("TextButton")
				fillBtn.Size = UDim2.new(0, 56, 0, 26)
				fillBtn.BackgroundColor3 = Theme.Colors.Surface
				fillBtn.Font = Theme.Font.Medium
				fillBtn.TextSize = 11
				fillBtn.TextColor3 = Theme.Colors.Text
				fillBtn.Text = "Fill"
				fillBtn.Parent = btnGroup
				Theme.corner(fillBtn, Theme.Radius.S)

				fillBtn.MouseButton1Click:Connect(function()
					if commandPalette and commandPalette.Open then
						commandPalette.Open(cmd.Name .. " ")
					end
				end)

				-- Run / Execute button
				local runBtn = Instance.new("TextButton")
				runBtn.Size = UDim2.new(0, 56, 0, 26)
				runBtn.BackgroundColor3 = Theme.Colors.Accent
				runBtn.Font = Theme.Font.Medium
				runBtn.TextSize = 11
				runBtn.TextColor3 = Color3.new(1, 1, 1)
				runBtn.Text = "Run"
				runBtn.Parent = btnGroup
				Theme.corner(runBtn, Theme.Radius.S)

				runBtn.MouseButton1Click:Connect(function()
					if executeCommandRemote then
						-- Run with localplayer as default if required
						local raw = cmd.Name
						if cmd.Usage:find("target") then
							raw = cmd.Name .. " me"
						end
						executeCommandRemote:FireServer(raw)
					end
				end)
			end
		end

		if count == 0 then
			local empty = Instance.new("TextLabel")
			empty.BackgroundTransparency = 1
			empty.Size = UDim2.new(1, 0, 0, 50)
			empty.Font = Theme.Font.Regular
			empty.TextSize = 13
			empty.TextColor3 = Theme.Colors.TextSecondary
			empty.Text = "No commands matching your filter."
			empty.Parent = scrollFrame
		end
	end

	-- Build category filter pills
	for _, cat in ipairs(CATEGORIES) do
		local pill = Instance.new("TextButton")
		pill.Name = "Category_" .. cat
		pill.AutomaticSize = Enum.AutomaticSize.X
		pill.Size = UDim2.new(0, 0, 0, 26)
		pill.BackgroundColor3 = if cat == activeCategory then Theme.Colors.Accent else Theme.Colors.Surface
		pill.Font = Theme.Font.Medium
		pill.TextSize = 12
		pill.TextColor3 = if cat == activeCategory then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
		pill.Text = " " .. cat .. " "
		pill.Parent = filterBar
		Theme.corner(pill, Theme.Radius.S)
		categoryButtons[cat] = pill

		pill.MouseButton1Click:Connect(function()
			activeCategory = cat
			for name, btn in pairs(categoryButtons) do
				btn.BackgroundColor3 = if name == activeCategory then Theme.Colors.Accent else Theme.Colors.Surface
				btn.TextColor3 = if name == activeCategory then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
			end
			renderCommands()
		end)
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(renderCommands)

	-- Load command list from server
	local function fetchCommands()
		if not getCommandListRemote then return end
		local ok, list = pcall(function()
			return getCommandListRemote:InvokeServer()
		end)
		if ok and type(list) == "table" then
			allCommands = list
			table.sort(allCommands, function(a, b)
				return a.Name < b.Name
			end)
			renderCommands()
		end
	end

	fetchCommands()
end

return CommandsPage

