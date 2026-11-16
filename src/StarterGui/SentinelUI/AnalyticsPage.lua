--!strict
--[[
	AnalyticsPage.lua

	Purpose:
		Phase 6 / Admin Panel Analytics & Audit Log page:
		- Top summary metric cards (Total commands, Success rate, Staff count, Top command)
		- Live audit ledger with real-time command execution history
		- Filterable by executor, target, command name, or outcome
		- Auto-refreshes periodically or on-demand

	Dependencies:
		Theme.lua

	Public API:
		AnalyticsPage.Build(container: Frame): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local AnalyticsPage = {}

type LogEntry = {
	Timestamp: number,
	Executor: string,
	ExecutorName: string,
	Command: string,
	Arguments: { string },
	Target: string?,
	Result: string,
	Severity: string,
	ExecutionTimeMs: number?,
	Message: string?,
}

type AuditStats = {
	Total: number,
	SuccessRate: number,
	TopCommands: { { Command: string, Count: number } },
	ActiveStaffCount: number,
}

local function formatTime(timestamp: number): string
	local d = os.date("*t", timestamp)
	return string.format("%02d:%02d:%02d", d.hour, d.min, d.sec)
end

function AnalyticsPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getAuditLogRemote = SentinelShared:WaitForChild("GetAuditLogRemote", 15) :: RemoteFunction?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Analytics & Audit Log"
	header.Parent = container

	local subHeader = Instance.new("TextLabel")
	subHeader.BackgroundTransparency = 1
	subHeader.Position = UDim2.new(0, 0, 0, 30)
	subHeader.Size = UDim2.new(1, 0, 0, 20)
	subHeader.Font = Theme.Font.Regular
	subHeader.TextSize = 12
	subHeader.TextColor3 = Theme.Colors.TextSecondary
	subHeader.TextXAlignment = Enum.TextXAlignment.Left
	subHeader.Text = "Live operational metrics, staff command telemetry, and execution history."
	subHeader.Parent = container

	-- Top Metrics Cards Row
	local cardsFrame = Instance.new("Frame")
	cardsFrame.Name = "MetricsCards"
	cardsFrame.Position = UDim2.new(0, 0, 0, 56)
	cardsFrame.Size = UDim2.new(1, 0, 0, 64)
	cardsFrame.BackgroundTransparency = 1
	cardsFrame.Parent = container

	local cardsLayout = Instance.new("UIGridLayout")
	cardsLayout.CellSize = UDim2.new(0.24, -6, 1, 0)
	cardsLayout.CellPadding = UDim2.new(0, 8, 0, 0)
	cardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardsLayout.Parent = cardsFrame

	local function makeCard(order: number, title: string, initialVal: string)
		local card = Instance.new("Frame")
		card.LayoutOrder = order
		card.BackgroundColor3 = Theme.Colors.Surface
		card.BorderSizePixel = 0
		card.Parent = cardsFrame
		Theme.corner(card, Theme.Radius.M)
		Theme.padding(card, 10)

		local tLbl = Instance.new("TextLabel")
		tLbl.BackgroundTransparency = 1
		tLbl.Size = UDim2.new(1, 0, 0, 14)
		tLbl.Font = Theme.Font.Medium
		tLbl.TextSize = 11
		tLbl.TextColor3 = Theme.Colors.TextSecondary
		tLbl.TextXAlignment = Enum.TextXAlignment.Left
		tLbl.Text = title:upper()
		tLbl.Parent = card

		local vLbl = Instance.new("TextLabel")
		vLbl.Name = "Value"
		vLbl.BackgroundTransparency = 1
		vLbl.Position = UDim2.new(0, 0, 0, 16)
		vLbl.Size = UDim2.new(1, 0, 1, -16)
		vLbl.Font = Theme.Font.Black
		vLbl.TextSize = 20
		vLbl.TextColor3 = Theme.Colors.Text
		vLbl.TextXAlignment = Enum.TextXAlignment.Left
		vLbl.Text = initialVal
		vLbl.Parent = card

		return vLbl
	end

	local totalCommandsLbl = makeCard(1, "Total Commands", "0")
	local successRateLbl = makeCard(2, "Success Rate", "100%")
	local activeStaffLbl = makeCard(3, "Staff Online", "1")
	local topCmdLbl = makeCard(4, "Top Command", "None")

	-- Filters Bar
	local filterContainer = Instance.new("Frame")
	filterContainer.Position = UDim2.new(0, 0, 0, 128)
	filterContainer.Size = UDim2.new(1, 0, 0, 32)
	filterContainer.BackgroundTransparency = 1
	filterContainer.Parent = container

	local searchBox = Instance.new("TextBox")
	searchBox.Position = UDim2.new(0, 0, 0, 0)
	searchBox.Size = UDim2.new(0.5, 0, 1, 0)
	searchBox.BackgroundColor3 = Theme.Colors.Surface
	searchBox.Font = Theme.Font.Regular
	searchBox.TextSize = 13
	searchBox.TextColor3 = Theme.Colors.Text
	searchBox.PlaceholderText = "Filter by executor, target, or command..."
	searchBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.TextXAlignment = Enum.TextXAlignment.Left
	searchBox.Parent = filterContainer
	Theme.corner(searchBox, Theme.Radius.S)
	Theme.padding(searchBox, 8)

	local refreshBtn = Instance.new("TextButton")
	refreshBtn.AnchorPoint = Vector2.new(1, 0)
	refreshBtn.Position = UDim2.new(1, 0, 0, 0)
	refreshBtn.Size = UDim2.new(0, 80, 1, 0)
	refreshBtn.BackgroundColor3 = Theme.Colors.SurfaceRaised
	refreshBtn.Font = Theme.Font.Medium
	refreshBtn.TextSize = 12
	refreshBtn.TextColor3 = Theme.Colors.Text
	refreshBtn.Text = "↻ Refresh"
	refreshBtn.Parent = filterContainer
	Theme.corner(refreshBtn, Theme.Radius.S)

	-- Table Container
	local tableContainer = Instance.new("Frame")
	tableContainer.Position = UDim2.new(0, 0, 0, 168)
	tableContainer.Size = UDim2.new(1, 0, 1, -168)
	tableContainer.BackgroundColor3 = Theme.Colors.Surface
	tableContainer.BorderSizePixel = 0
	tableContainer.Parent = container
	Theme.corner(tableContainer, Theme.Radius.M)
	Theme.padding(tableContainer, Theme.Spacing.S)

	-- Table Header Row
	local headerRow = Instance.new("Frame")
	headerRow.Size = UDim2.new(1, 0, 0, 24)
	headerRow.BackgroundColor3 = Theme.Colors.SurfaceRaised
	headerRow.BorderSizePixel = 0
	headerRow.Parent = tableContainer
	Theme.corner(headerRow, Theme.Radius.S)

	local function makeColHeader(xScale: number, widthScale: number, text: string)
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Position = UDim2.new(xScale, 8, 0, 0)
		lbl.Size = UDim2.new(widthScale, -16, 1, 0)
		lbl.Font = Theme.Font.Bold
		lbl.TextSize = 11
		lbl.TextColor3 = Theme.Colors.TextSecondary
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Text = text
		lbl.Parent = headerRow
	end

	makeColHeader(0.00, 0.14, "TIME")
	makeColHeader(0.14, 0.22, "STAFF EXECUTOR")
	makeColHeader(0.36, 0.20, "COMMAND")
	makeColHeader(0.56, 0.22, "TARGET")
	makeColHeader(0.78, 0.12, "RESULT")
	makeColHeader(0.90, 0.10, "LATENCY")

	-- Table Rows ScrollingFrame
	local tableScroll = Instance.new("ScrollingFrame")
	tableScroll.Position = UDim2.new(0, 0, 0, 28)
	tableScroll.Size = UDim2.new(1, 0, 1, -28)
	tableScroll.BackgroundTransparency = 1
	tableScroll.BorderSizePixel = 0
	tableScroll.ScrollBarThickness = 4
	tableScroll.ScrollBarImageColor3 = Theme.Colors.Border
	tableScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	tableScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	tableScroll.Parent = tableContainer

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.Padding = UDim.new(0, 4)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = tableScroll

	local currentEntries: { LogEntry } = {}

	local function renderTable()
		for _, child in ipairs(tableScroll:GetChildren()) do
			if child:IsA("Frame") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		local q = searchBox.Text:lower():gsub("^%s+", ""):gsub("%s+$", "")
		local rowCount = 0

		for idx, entry in ipairs(currentEntries) do
			local matchesQuery = true
			if #q > 0 then
				local inExec = entry.ExecutorName:lower():find(q, 1, true) ~= nil
				local inCmd = entry.Command:lower():find(q, 1, true) ~= nil
				local inTarget = entry.Target and entry.Target:lower():find(q, 1, true) ~= nil
				matchesQuery = inExec or inCmd or (inTarget == true)
			end

			if matchesQuery then
				rowCount += 1
				local row = Instance.new("Frame")
				row.Name = "Row_" .. idx
				row.Size = UDim2.new(1, 0, 0, 28)
				row.BackgroundColor3 = if idx % 2 == 0 then Theme.Colors.SurfaceRaised else Theme.Colors.Surface
				row.BorderSizePixel = 0
				row.Parent = tableScroll
				Theme.corner(row, Theme.Radius.S)

				local function makeCell(xScale: number, widthScale: number, text: string, color: Color3?, isMono: boolean?)
					local lbl = Instance.new("TextLabel")
					lbl.BackgroundTransparency = 1
					lbl.Position = UDim2.new(xScale, 8, 0, 0)
					lbl.Size = UDim2.new(widthScale, -16, 1, 0)
					lbl.Font = if isMono then Theme.Font.Mono else Theme.Font.Regular
					lbl.TextSize = 12
					lbl.TextColor3 = color or Theme.Colors.Text
					lbl.TextXAlignment = Enum.TextXAlignment.Left
					lbl.TextTruncate = Enum.TextTruncate.AtEnd
					lbl.Text = text
					lbl.Parent = row
				end

				-- Time
				makeCell(0.00, 0.14, formatTime(entry.Timestamp), Theme.Colors.TextSecondary, true)
				-- Executor
				makeCell(0.14, 0.22, entry.ExecutorName, Theme.Colors.Text)
				-- Command
				makeCell(0.36, 0.20, ";" .. entry.Command, Theme.Colors.Accent, true)
				-- Target
				makeCell(0.56, 0.22, entry.Target or "—", Theme.Colors.TextSecondary)

				-- Result status
				local resColor = Theme.Colors.Success
				if entry.Result == "Denied" then
					resColor = Theme.Colors.Warning
				elseif entry.Result == "Failure" then
					resColor = Theme.Colors.Error
				end
				makeCell(0.78, 0.12, entry.Result, resColor)

				-- Latency
				local lat = if entry.ExecutionTimeMs then ("%dms"):format(entry.ExecutionTimeMs) else "<1ms"
				makeCell(0.90, 0.10, lat, Theme.Colors.TextSecondary, true)
			end
		end

		if rowCount == 0 then
			local empty = Instance.new("TextLabel")
			empty.BackgroundTransparency = 1
			empty.Size = UDim2.new(1, 0, 0, 40)
			empty.Font = Theme.Font.Regular
			empty.TextSize = 12
			empty.TextColor3 = Theme.Colors.TextSecondary
			empty.Text = "No audit log records found."
			empty.Parent = tableScroll
		end
	end

	local function refreshData()
		if not getAuditLogRemote then return end
		local ok, data = pcall(function()
			return getAuditLogRemote:InvokeServer()
		end)
		if ok and type(data) == "table" then
			currentEntries = data.Entries or {}
			local stats: AuditStats = data.Stats or { Total = #currentEntries, SuccessRate = 100, TopCommands = {}, ActiveStaffCount = 1 }

			totalCommandsLbl.Text = tostring(stats.Total)
			successRateLbl.Text = tostring(stats.SuccessRate) .. "%"
			successRateLbl.TextColor3 = if stats.SuccessRate >= 90 then Theme.Colors.Success else Theme.Colors.Warning
			activeStaffLbl.Text = tostring(stats.ActiveStaffCount or 1)

			if stats.TopCommands and #stats.TopCommands > 0 then
				topCmdLbl.Text = ";" .. stats.TopCommands[1].Command .. " (" .. stats.TopCommands[1].Count .. ")"
			else
				topCmdLbl.Text = "None"
			end

			renderTable()
		end
	end

	refreshBtn.MouseButton1Click:Connect(refreshData)
	searchBox:GetPropertyChangedSignal("Text"):Connect(renderTable)

	refreshData()

	-- Periodic background poll when page is visible
	task.spawn(function()
		while container.Parent do
			task.wait(4)
			if container.Visible then
				refreshData()
			end
		end
	end)
end

return AnalyticsPage

