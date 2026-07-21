--!strict
--[[
	ModerationPage.lua

	Purpose:
		Moderation Queue from the design doc. Sentinel doesn't have a
		player-submitted Reports/Appeals system built yet, so this slice
		covers what actually exists on the backend: a live feed of recent
		moderation-relevant log entries (bans, kicks, mutes, warns, jails,
		freezes...) via GetModerationLogRemote. Reports/Appeals sections
		are intentionally left out rather than faked with placeholder data
		— they're real, not-yet-built features, not this page's UI to
		pretend exists.

	Dependencies:
		Theme.lua

	Public API:
		ModerationPage.Build(container: Frame): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local ModerationPage = {}

type LogEntry = {
	Timestamp: number,
	Executor: string,
	ExecutorName: string,
	Command: string,
	Arguments: { string },
	Target: string?,
	Result: string,
	Severity: string,
	Message: string?,
}

local SEVERITY_COLOR_KEY = {
	Info = "TextSecondary",
	Warning = "Warning",
	Error = "Error",
	Critical = "Error",
}

function ModerationPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local getModerationLogRemote = SentinelShared:WaitForChild("GetModerationLogRemote", 15) :: RemoteFunction?

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Moderation Queue"
	header.Parent = container

	local subHeader = Instance.new("TextLabel")
	subHeader.BackgroundTransparency = 1
	subHeader.Position = UDim2.new(0, 0, 0, 30)
	subHeader.Size = UDim2.new(1, 0, 0, 20)
	subHeader.Font = Theme.Font.Regular
	subHeader.TextSize = 12
	subHeader.TextColor3 = Theme.Colors.TextSecondary
	subHeader.TextXAlignment = Enum.TextXAlignment.Left
	subHeader.Text = "Recent moderation actions, live. (Reports/Appeals: not built yet — no such backend exists.)"
	subHeader.Parent = container

	local listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Position = UDim2.new(0, 0, 0, 58)
	listFrame.Size = UDim2.new(1, 0, 1, -58)
	listFrame.BackgroundColor3 = Theme.Colors.Surface
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = container
	Theme.corner(listFrame, Theme.Radius.M)
	Theme.padding(listFrame, Theme.Spacing.S)

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.Name = "EmptyState"
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Size = UDim2.new(1, 0, 0, 40)
	emptyLabel.Font = Theme.Font.Regular
	emptyLabel.TextSize = 13
	emptyLabel.TextColor3 = Theme.Colors.TextSecondary
	emptyLabel.Text = "No recent moderation activity."
	emptyLabel.Visible = false
	emptyLabel.Parent = listFrame

	local function renderEntries(entries: { LogEntry })
		for _, child in ipairs(listFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		if #entries == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- Most recent first.
		for i = #entries, 1, -1 do
			local entry = entries[i]
			local row = Instance.new("Frame")
			row.Name = "Entry" .. tostring(i)
			row.LayoutOrder = #entries - i
			row.Size = UDim2.new(1, 0, 0, 40)
			row.BackgroundColor3 = Theme.Colors.SurfaceRaised
			row.BorderSizePixel = 0
			row.Parent = listFrame
			Theme.corner(row, Theme.Radius.S)

			local severityColorKey = SEVERITY_COLOR_KEY[entry.Severity] or "TextSecondary"
			local sideBar = Instance.new("Frame")
			sideBar.BorderSizePixel = 0
			sideBar.Size = UDim2.new(0, 3, 1, 0)
			sideBar.BackgroundColor3 = (Theme.Colors :: any)[severityColorKey]
			sideBar.Parent = row
			Theme.corner(sideBar, UDim.new(0, 2))

			local timeText = os.date("%H:%M:%S", entry.Timestamp)
			local titleLabel = Instance.new("TextLabel")
			titleLabel.BackgroundTransparency = 1
			titleLabel.Position = UDim2.new(0, 12, 0, 4)
			titleLabel.Size = UDim2.new(1, -24, 0, 18)
			titleLabel.Font = Theme.Font.Medium
			titleLabel.TextSize = 13
			titleLabel.TextColor3 = Theme.Colors.Text
			titleLabel.TextXAlignment = Enum.TextXAlignment.Left
			titleLabel.Text = ("[%s] %s → %s (%s)"):format(
				tostring(timeText), entry.ExecutorName, entry.Command, entry.Result
			)
			titleLabel.Parent = row

			local detailLabel = Instance.new("TextLabel")
			detailLabel.BackgroundTransparency = 1
			detailLabel.Position = UDim2.new(0, 12, 0, 20)
			detailLabel.Size = UDim2.new(1, -24, 0, 16)
			detailLabel.Font = Theme.Font.Regular
			detailLabel.TextSize = 11
			detailLabel.TextColor3 = Theme.Colors.TextSecondary
			detailLabel.TextXAlignment = Enum.TextXAlignment.Left
			detailLabel.Text = entry.Message or (entry.Target and ("Target: " .. entry.Target)) or ""
			detailLabel.Parent = row
		end
	end

	task.spawn(function()
		while true do
			if getModerationLogRemote then
				local ok, entries = pcall(function()
					return getModerationLogRemote:InvokeServer(30)
				end)
				if ok and entries then
					renderEntries(entries :: { LogEntry })
				end
			end
			task.wait(4)
		end
	end)
end

return ModerationPage
