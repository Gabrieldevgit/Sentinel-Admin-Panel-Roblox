--!strict
--[[
	OverviewPage.lua (Anti-Cheat Control Center, page 1)

	The health of the system at a glance: system switch + mode selector +
	Panic, six cards (flags last hour, players above 40, actions today,
	awaiting review, server cost, false-positive rate - each opens its
	page), the live feed (last 20 flags) and flags per minute over the hour.

	Stable names: Page_Overview.{System.{SystemButton, Mode_observe,
	Mode_balanced, Mode_strict, PanicButton}, Cards.Card_<Title>, Feed.Feed_<n>,
	ViewAllButton, Sparkline}
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AntiCheatTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("AntiCheatTypes"))
local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local OverviewPage = {}

function OverviewPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 12)

	local system = Widgets.make("Frame", { Name = "System", BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, frame)
	Theme.corner(system, Theme.Radius.M)
	Theme.padding(system, 10)
	local sl = Widgets.list(system, Enum.FillDirection.Horizontal, 8)
	sl.VerticalAlignment = Enum.VerticalAlignment.Center
	sl.Wraps = true
	local stateLabel = Widgets.label(system, "System", { Name = "State", Bold = true, Size = UDim2.fromOffset(150, 30), LayoutOrder = 1 })
	local systemButton = Widgets.button(system, "Turn off", { Name = "SystemButton", Need = "Master", Width = 90, LayoutOrder = 2, OnClick = function()
		local on = not ((Center.Status or {}).Enabled == true)
		Center.Act("setEnabled", { On = on }, { Confirm = { Title = if on then "Turn anti-cheat on" else "Turn anti-cheat off", Message = if on then "Run every enabled detection on every server?" else "Stop every detection on every server?" } })
	end })
	Widgets.label(system, "Mode:", { Color = Theme.Colors.TextSecondary, Size = UDim2.fromOffset(44, 30), LayoutOrder = 3 })
	local modeChips = {}
	for i, mode in ipairs(AntiCheatTypes.MODES) do
		local chip
		chip = Widgets.chip(system, mode:sub(1, 1):upper() .. mode:sub(2), false, function()
			if not Center.Can("Config") then
				Center.Toast(false, "Changing the mode needs anticheat.config.")
				return
			end
			if (Center.Status or {}).Mode == mode then
				return
			end
			Center.Act("setMode", { Mode = mode }, if mode == "strict" then { Confirm = { Title = "Switch to Strict", Message = "Strict kicks, temp-bans and proposes bans automatically. Switch every server to Strict?" } } else nil)
		end, { Name = "Mode_" .. mode, LayoutOrder = 3 + i })
		modeChips[mode] = chip
		if not Center.Can("Config") then
			Widgets.tooltip(chip, "Needs anticheat.config")
		end
	end
	local panicButton = Widgets.button(system, "Panic", { Name = "PanicButton", Kind = "danger", Need = "Config", LayoutOrder = 10, Tooltip = "Switch every automatic action off at once; detections keep logging", OnClick = function()
		local on = not ((Center.Status or {}).Panic == true)
		Center.Act("setPanic", { On = on }, if on then { Confirm = { Title = "Panic", Message = "Turn every automatic anti-cheat action off on every server? Detections keep logging." } } else nil)
	end })

	local cards = Widgets.make("Frame", { Name = "Cards", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local cl = Widgets.list(cards, Enum.FillDirection.Horizontal, 10)
	cl.Wraps = true
	local function card(title: string, page: string, order: number, tip: string): Frame
		return Widgets.card(cards, title, "-", { LayoutOrder = order, Tooltip = tip, OnClick = function()
			Center.ShowPage(page)
		end })
	end
	local cFlags = card("Flags last hour", "Flags", 1, "Open Live Flags")
	local cAbove = card("Players above 40", "Players", 2, "Open Players")
	local cActions = card("Actions today", "Logs", 3, "Open Logs")
	local cReview = card("Awaiting review", "Review", 4, "Open the Review Queue")
	local cCost = card("Server cost", "Analytics", 5, "ms of server time per second spent on checks")
	local cFp = card("False positives", "Analytics", 6, "Share of reviewed flags marked false positive")

	local feedHeader = Widgets.make("Frame", { Name = "FeedHeader", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3 }, frame)
	Widgets.label(feedHeader, "Live feed", { Bold = true, TextSize = 15, Size = UDim2.new(0.5, 0, 1, 0) })
	local viewAll = Widgets.button(feedHeader, "View all", { Name = "ViewAllButton", OnClick = function()
		Center.ShowPage("Flags")
	end })
	viewAll.AnchorPoint = Vector2.new(1, 0)
	viewAll.Position = UDim2.fromScale(1, 0)
	local feed = Widgets.make("Frame", { Name = "Feed", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4 }, frame)
	Widgets.list(feed, nil, 3)

	Widgets.label(frame, "Flags per minute (last hour)", { Bold = true, TextSize = 15, LayoutOrder = 5 })
	local sparkHolder = Widgets.make("Frame", { Name = "SparkHolder", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 80), LayoutOrder = 6 }, frame)

	local api: any = { Live = true }

	function api.Refresh()
		local data = Center.Call("overview")
		if not data or not data.Ok then
			return
		end
		Center.ApplyStatus(data.Status)
		local s = data.Status
		stateLabel.Text = if s.Enabled then "System: ON" else "System: OFF"
		stateLabel.TextColor3 = if s.Enabled then Theme.Colors.Success else Theme.Colors.Error
		systemButton.Text = if s.Enabled then "Turn off" else "Turn on"
		for mode, chip in pairs(modeChips) do
			Widgets.SetActive(chip, s.Mode == mode)
		end
		panicButton.Text = if s.Panic then "End panic" else "Panic"
		local c = data.Cards
		Widgets.SetCard(cFlags, tostring(c.FlagsHour), "this server + shared")
		Widgets.SetCard(cAbove, tostring(c.Above40), "score 40 or more")
		Widgets.SetCard(cActions, tostring(c.ActionsToday), "automatic + staff")
		Widgets.SetCard(cReview, tostring(c.AwaitingReview), ("%d queue item(s)"):format(c.OpenReviews or 0), if c.AwaitingReview > 0 then Theme.Colors.Warning else nil)
		Widgets.SetCard(cCost, ("%.2f ms/s"):format(c.CostMs), ("budget %.1f ms/s"):format(s.Budget or 2), if c.CostMs > (s.Budget or 2) then Theme.Colors.Error else nil)
		Widgets.SetCard(cFp, ("%.1f %%"):format(c.FalsePositiveRate), "of reviewed flags")
		for _, child in ipairs(feed:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if #data.Feed == 0 then
			Widgets.label(feed, "No flags yet. Clean so far.", { Color = Theme.Colors.TextSecondary })
		end
		for i, f in ipairs(data.Feed) do
			local row = Widgets.make("TextButton", { Name = "Feed_" .. i, Text = "", AutoButtonColor = true, BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i }, feed)
			Theme.corner(row, Theme.Radius.S)
			local sev = Widgets.label(row, tostring(f.Severity), { Bold = true, TextSize = 12, Color = Color3.new(0, 0, 0), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(26, 20) })
			sev.BackgroundTransparency = 0
			sev.BackgroundColor3 = AntiCheatTypes.SeverityColor(f.Severity)
			sev.Position = UDim2.fromOffset(6, 5)
			Theme.corner(sev, Theme.Radius.Pill)
			local text = Widgets.label(row, ("%s   %s   %s"):format(f.Name, f.Module, f.Reason), { TextSize = 13, Size = UDim2.new(1, -130, 1, 0) })
			text.Position = UDim2.fromOffset(40, 0)
			local t = Widgets.label(row, Widgets.ago(f.Time), { TextSize = 12, Color = Theme.Colors.TextSecondary, XAlign = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(80, 30) })
			t.Position = UDim2.new(1, -88, 0, 0)
			row.Activated:Connect(function()
				Center.OpenFlag(f.Id)
			end)
			row.MouseButton2Click:Connect(function()
				Center.RowMenu("flag", f, game:GetService("UserInputService"):GetMouseLocation())
			end)
		end
		for _, child in ipairs(sparkHolder:GetChildren()) do
			child:Destroy()
		end
		local labels = {}
		for i, v in ipairs(data.Sparkline) do
			labels[i] = ("%d min ago: %d flag(s)"):format(60 - i, v)
		end
		Widgets.sparkline(sparkHolder, data.Sparkline, { Name = "Sparkline", Size = UDim2.fromScale(1, 1), Labels = labels })
	end

	return api
end

return OverviewPage
