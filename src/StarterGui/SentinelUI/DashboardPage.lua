--!strict
--[[
	DashboardPage.lua

	Purpose:
		Dashboard page from the design doc: summary cards (Players/FPS/
		Memory/Ping) using the same GetServerStatsRemote the status bar
		uses, plus the Quick Actions panel. Live health bars, the activity
		feed, and the "Today's Overview" briefing are follow-up increments.

	Dependencies:
		Theme.lua, QuickActionsPanel.lua

	Public API:
		DashboardPage.Build(container: Frame, commandPalette: any): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))
local QuickActionsPanel = require(script.Parent:WaitForChild("QuickActionsPanel"))

local DashboardPage = {}

local function makeCard(parent: Instance, layoutOrder: number, label: string): (Frame, TextLabel)
	local card = Instance.new("Frame")
	card.Name = label .. "Card"
	card.LayoutOrder = layoutOrder
	card.Size = UDim2.new(0, 150, 0, 80)
	card.BackgroundColor3 = Theme.Colors.Surface
	card.BorderSizePixel = 0
	card.Parent = parent
	Theme.corner(card, Theme.Radius.M)
	Theme.stroke(card, Theme.Colors.Border, 1)
	Theme.padding(card, Theme.Spacing.S)

	local labelText = Instance.new("TextLabel")
	labelText.BackgroundTransparency = 1
	labelText.Size = UDim2.new(1, 0, 0, 18)
	labelText.Font = Theme.Font.Regular
	labelText.TextSize = 12
	labelText.TextColor3 = Theme.Colors.TextSecondary
	labelText.TextXAlignment = Enum.TextXAlignment.Left
	labelText.Text = label
	labelText.Parent = card

	local valueText = Instance.new("TextLabel")
	valueText.Name = "Value"
	valueText.BackgroundTransparency = 1
	valueText.Position = UDim2.new(0, 0, 0, 22)
	valueText.Size = UDim2.new(1, 0, 0, 36)
	valueText.Font = Theme.Font.Black
	valueText.TextSize = 26
	valueText.TextColor3 = Theme.Colors.Text
	valueText.TextXAlignment = Enum.TextXAlignment.Left
	valueText.Text = "--"
	valueText.Parent = card

	return card, valueText
end

function DashboardPage.Build(container: Frame, commandPalette: any)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Dashboard"
	header.Parent = container

	-- Known issue #1 (PHASE7-KNOWN-ISSUES.md): everything below used to
	-- be positioned with fixed absolute Y offsets that assumed the card
	-- row was always exactly 80px tall. Narrowing the window didn't
	-- reflow the cards (UIListLayout doesn't wrap) — it just clipped
	-- them. Fixed by stacking every block in a scrolling body via
	-- UIListLayout (so later blocks always sit below whatever height the
	-- card row actually ends up being) and switching the card row itself
	-- to UIGridLayout, which wraps onto additional rows automatically
	-- when there isn't room for 4 cards side by side.
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
	bodyLayout.Padding = UDim.new(0, 16)
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Parent = body

	local cardRow = Instance.new("Frame")
	cardRow.Name = "CardRow"
	cardRow.LayoutOrder = 1
	cardRow.Size = UDim2.new(1, 0, 0, 0)
	cardRow.AutomaticSize = Enum.AutomaticSize.Y
	cardRow.BackgroundTransparency = 1
	cardRow.Parent = body

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0, 150, 0, 80)
	layout.CellPadding = UDim2.new(0, 12, 0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = cardRow

	local _, playersValue = makeCard(cardRow, 1, "Players Online")
	local _, fpsValue = makeCard(cardRow, 2, "Server Heartbeat")
	local _, memoryValue = makeCard(cardRow, 3, "Memory")
	local _, pingValue = makeCard(cardRow, 4, "Your Ping")

	local quickActionsContainer = Instance.new("Frame")
	quickActionsContainer.Name = "QuickActions"
	quickActionsContainer.LayoutOrder = 2
	quickActionsContainer.Size = UDim2.new(1, 0, 0, 0)
	quickActionsContainer.AutomaticSize = Enum.AutomaticSize.Y
	quickActionsContainer.BackgroundTransparency = 1
	quickActionsContainer.Parent = body
	QuickActionsPanel.Build(quickActionsContainer, commandPalette)

	local placeholder = Instance.new("TextLabel")
	placeholder.LayoutOrder = 3
	placeholder.BackgroundTransparency = 1
	placeholder.Size = UDim2.new(1, 0, 0, 24)
	placeholder.Font = Theme.Font.Regular
	placeholder.TextSize = 13
	placeholder.TextColor3 = Theme.Colors.TextSecondary
	placeholder.TextXAlignment = Enum.TextXAlignment.Left
	placeholder.Text = "Live health charts, activity feed, and today's overview are coming in a follow-up pass."
	placeholder.Parent = body

	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getServerStatsRemote = SentinelShared:WaitForChild("GetServerStatsRemote", 15) :: RemoteFunction?
	local localPlayer = Players.LocalPlayer

	task.spawn(function()
		while true do
			if getServerStatsRemote then
				local ok, stats = pcall(function()
					return getServerStatsRemote:InvokeServer()
				end)
				if ok and stats then
					playersValue.Text = tostring(stats.PlayerCount)
					fpsValue.Text = tostring(stats.HeartbeatRate) .. "/s"
					memoryValue.Text = tostring(stats.MemoryMb) .. " MB"
				end
			end
			pingValue.Text = tostring(math.floor(localPlayer:GetNetworkPing() * 1000)) .. " ms"
			task.wait(3)
		end
	end)
end

return DashboardPage
