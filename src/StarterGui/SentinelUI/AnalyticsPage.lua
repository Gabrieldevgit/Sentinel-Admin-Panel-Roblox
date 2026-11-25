--!strict
--[[
	AnalyticsPage.lua (W16) - Insights > Analytics (page id "Analytics").

	Blocks (all in Body, a ScrollingFrame):
		Toolbar   range chips (24h / Today / 7d / 30d / Custom + From / To
		          boxes), scope (All servers / This server), Compare, Refresh,
		          Status line.
		Live      tiles: players, staff online, uptime, FPS, memory, ping,
		          active punishments (this server, right now).
		Totals    tiles for the range: peak players, commands, success rate,
		          failed, denied, moderation, staff commands, economy - each
		          with the change vs the previous period when Compare is on.
		Charts    Players, Performance (FPS / Ping / Memory), Commands
		          (stacked ok / failed / denied), Moderation, Staff, Economy.
		          Hover a bar for its value; Compare draws the previous period
		          as faint bars behind.
		Lists     most-used commands, most-active moderators, recent
		          moderation actions, economy by stat.

	Data: GetAnalyticsRemote({ Range, From, To, Scope, Compare }) -> report
	(Systems/AnalyticsService.Query + Live). Times are UTC.

	Stable instance names (Studio MCP tests):
		Body.Toolbar.{Ranges.Chip_<24h|today|7d|30d|custom>, Custom.{From,To,Apply},
		  Scope.Chip_<all|server>, Options.{Chip_Compare,Refresh}, Status}
		Body.Live.Tile_<key>.Value, Body.Totals.Tile_<key>.{Value,Delta}
		Body.Charts.Chart_<Players|Performance|Commands|Moderation|Staff|Economy>.
		  {Header.{Title,Readout}, Plot.Bar_<n>, Axis.{From,To}}
		Body.Lists.{TopCommands,TopModerators,RecentModeration,EconomyStats}

	Public API:
		AnalyticsPage.Build(container)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local AnalyticsPage = {}

local RANGES = { { "24h", "24h" }, { "Today", "today" }, { "7 days", "7d" }, { "30 days", "30d" }, { "Custom", "custom" } }
local CHART_HEIGHT = 120

local order = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		order += 1
		inst.LayoutOrder = order
	elseif inst:IsA("UIListLayout") then
		(inst :: any).SortOrder = Enum.SortOrder.LayoutOrder
	end
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function label(parent: Instance, name: string, value: string, props: { [string]: any }?): TextLabel
	local l = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = value,
	}, parent)
	for k, v in pairs(props or {}) do
		(l :: any)[k] = v
	end
	return l
end

local function caption(parent: Instance, value: string)
	label(parent, "Caption", value:upper(), {
		Font = Theme.Font.Bold,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextSecondary,
		Size = UDim2.new(1, 0, 0, 14),
	})
end

local function card(parent: Instance, name: string, width: UDim?): Frame
	local f = make("Frame", {
		Name = name,
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, 0)),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, parent)
	Theme.corner(f, Theme.Radius.M)
	make("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, f)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, f)
	return f
end

local function row(parent: Instance, name: string, padding: number?): Frame
	local f = make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, padding or 6), VerticalAlignment = Enum.VerticalAlignment.Center }, f)
	return f
end

local function chipButton(parent: Instance, name: string, value: string): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Font = Theme.Font.Medium,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		Text = value,
	}, parent)
	Theme.corner(b, Theme.Radius.Pill)
	make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, b)
	return b
end

local function setChip(b: TextButton, on: boolean)
	Theme.tween(b, Theme.Motion.Fast, {
		BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised,
		TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.Text,
	})
end

local function textBox(parent: Instance, name: string, placeholder: string, width: number): TextBox
	local b = make("TextBox", {
		Name = name,
		Size = UDim2.fromOffset(width, 30),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClipsDescendants = true,
		Text = "",
	}, parent) :: TextBox
	Theme.corner(b, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
	return b
end

local function clear(frame: Instance)
	for _, c in ipairs(frame:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function fmt(n: any): string
	n = tonumber(n) or 0
	if math.abs(n) >= 1e6 then
		return ("%.1fM"):format(n / 1e6)
	elseif math.abs(n) >= 1e4 then
		return ("%.1fk"):format(n / 1e3)
	elseif n % 1 ~= 0 then
		return ("%.1f"):format(n)
	end
	return tostring(math.floor(n))
end

local function uptime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 86400 then
		return ("%dd %dh"):format(seconds // 86400, (seconds % 86400) // 3600)
	elseif seconds >= 3600 then
		return ("%dh %02dm"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%dm %02ds"):format(seconds // 60, seconds % 60)
end

local function timeLabel(t: number, step: number): string
	if step >= 86400 then
		return os.date("!%b %d", t) :: string
	elseif step > 3600 then
		return os.date("!%b %d %H:00", t) :: string
	end
	return os.date("!%H:00", t) :: string
end

local function ago(t: number): string
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return "just now"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m ago"
	elseif d < 86400 then
		return math.floor(d / 3600) .. "h ago"
	end
	return math.floor(d / 86400) .. "d ago"
end

function AnalyticsPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local remote = SentinelShared:WaitForChild("GetAnalyticsRemote", 15) :: RemoteFunction?

	label(container, "Header", "Analytics", { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", "Persisted metrics across every server: players, performance, commands, moderation, staff and economy (UTC).", {
		Position = UDim2.new(0, 0, 0, 28),
		TextColor3 = Theme.Colors.TextSecondary,
	})
	local body = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 1, -52),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, container)
	make("UIListLayout", { Padding = UDim.new(0, 10) }, body)
	make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, body)

	local state = { Range = "24h", Scope = "all", Compare = false, From = "", To = "" }
	local report: any = nil
	local perfMetric = "Fps"
	local loading = false

	-- ======================================================================
	-- Toolbar
	-- ======================================================================
	local toolbar = card(body, "Toolbar")
	local ranges = row(toolbar, "Ranges")
	local rangeChips: { [string]: TextButton } = {}
	for _, r in ipairs(RANGES) do
		rangeChips[r[2]] = chipButton(ranges, "Chip_" .. r[2], r[1])
	end
	local custom = row(toolbar, "Custom")
	custom.Visible = false
	local today = os.date("!%Y-%m-%d") :: string
	local fromBox = textBox(custom, "From", "From " .. today, 150)
	local toBox = textBox(custom, "To", "To " .. today, 150)
	local applyBtn = chipButton(custom, "Apply", "Apply")
	local scopeRow = row(toolbar, "Scope")
	local scopeChips = {
		all = chipButton(scopeRow, "Chip_all", "All servers"),
		server = chipButton(scopeRow, "Chip_server", "This server"),
	}
	local options = row(toolbar, "Options")
	local compareChip = chipButton(options, "Chip_Compare", "Compare with previous period")
	local refreshBtn = chipButton(options, "Refresh", "Refresh")
	local status = label(toolbar, "Status", "Loading...", { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })

	local function paintToolbar()
		for id, chip in pairs(rangeChips) do
			setChip(chip, id == state.Range)
		end
		for id, chip in pairs(scopeChips) do
			setChip(chip, id == state.Scope)
		end
		setChip(compareChip, state.Compare)
		custom.Visible = state.Range == "custom"
	end

	-- ======================================================================
	-- Tiles
	-- ======================================================================
	local function tileRow(name: string, title: string): Frame
		local c = card(body, name)
		caption(c, title)
		local r = row(c, "Tiles", 8)
		return r
	end
	local liveRow = tileRow("Live", "Right now (this server)")
	local totalsRow = tileRow("Totals", "Selected range")

	local function tile(parent: Instance, key: string, title: string, value: string, color: Color3?, deltaText: string?, deltaColor: Color3?)
		local t = make("Frame", {
			Name = "Tile_" .. key,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(132, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, parent)
		Theme.corner(t, Theme.Radius.S)
		make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, t)
		make("UIListLayout", { Padding = UDim.new(0, 2) }, t)
		label(t, "Title", title:upper(), { Font = Theme.Font.Bold, TextSize = 10, TextColor3 = Theme.Colors.TextSecondary, Size = UDim2.new(1, 0, 0, 12) })
		label(t, "Value", value, { Font = Theme.Font.Bold, TextSize = 18, Size = UDim2.new(1, 0, 0, 22), TextColor3 = color or Theme.Colors.Text })
		if deltaText then
			label(t, "Delta", deltaText, { TextSize = 11, Size = UDim2.new(1, 0, 0, 14), TextColor3 = deltaColor or Theme.Colors.TextSecondary })
		end
	end

	-- ======================================================================
	-- Charts
	-- ======================================================================
	local charts = make("Frame", { Name = "Charts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	local chartsLayout = make("UIGridLayout", {
		CellSize = UDim2.new(0.5, -5, 0, CHART_HEIGHT + 86),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, charts)
	local function relayoutCharts()
		local w = charts.AbsoluteSize.X
		chartsLayout.CellSize = if w > 0 and w < 640 then UDim2.new(1, 0, 0, CHART_HEIGHT + 86) else UDim2.new(0.5, -5, 0, CHART_HEIGHT + 86)
	end
	charts:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutCharts)

	type Segment = { Key: string, Color: Color3, Label: string }
	local function chart(name: string, title: string, segments: { Segment }, opts: { Unit: string?, Chips: { string }?, OnChip: ((string) -> ())?, Active: string? }?)
		local o = opts or {}
		local f = make("Frame", { Name = "Chart_" .. name, BackgroundColor3 = Theme.Colors.Surface, BorderSizePixel = 0 }, charts)
		Theme.corner(f, Theme.Radius.M)
		make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, f)
		local header = make("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) }, f)
		label(header, "Title", title, { Font = Theme.Font.Bold, TextSize = 14, Size = UDim2.new(0.5, 0, 1, 0) })
		local readout = label(header, "Readout", "", {
			Size = UDim2.new(0.5, 0, 1, 0),
			Position = UDim2.new(0.5, 0, 0, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 12,
			TextColor3 = Theme.Colors.TextSecondary,
		})
		local legend = make("Frame", { Name = "Legend", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, 22) }, f)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 10), VerticalAlignment = Enum.VerticalAlignment.Center }, legend)
		if o.Chips then
			for _, c in ipairs(o.Chips) do
				local b = make("TextButton", {
					Name = "Metric_" .. c,
					Size = UDim2.fromOffset(0, 18),
					AutomaticSize = Enum.AutomaticSize.X,
					BackgroundColor3 = if c == o.Active then Theme.Colors.Accent else Theme.Colors.SurfaceRaised,
					BorderSizePixel = 0,
					Font = Theme.Font.Medium,
					TextSize = 11,
					TextColor3 = if c == o.Active then Color3.new(1, 1, 1) else Theme.Colors.Text,
					Text = c,
				}, legend)
				Theme.corner(b, Theme.Radius.Pill)
				make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
				b.MouseButton1Click:Connect(function()
					if o.OnChip then
						o.OnChip(c)
					end
				end)
			end
		else
			for _, s in ipairs(segments) do
				local item = make("Frame", { Name = "Key_" .. s.Key, BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X }, legend)
				make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), VerticalAlignment = Enum.VerticalAlignment.Center }, item)
				local dot = make("Frame", { Size = UDim2.fromOffset(8, 8), BackgroundColor3 = s.Color, BorderSizePixel = 0 }, item)
				Theme.corner(dot, UDim.new(1, 0))
				label(item, "Text", s.Label, { Size = UDim2.fromOffset(0, 18), AutomaticSize = Enum.AutomaticSize.X, TextSize = 11, TextColor3 = Theme.Colors.TextSecondary })
			end
		end
		local maxLabel = label(f, "Max", "", { Position = UDim2.new(0, 0, 0, 42), Size = UDim2.new(1, 0, 0, 12), TextSize = 10, TextColor3 = Theme.Colors.TextSecondary })
		local plot = make("Frame", {
			Name = "Plot",
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 0, 56),
			Size = UDim2.new(1, 0, 0, CHART_HEIGHT),
			ClipsDescendants = true,
		}, f)
		Theme.corner(plot, Theme.Radius.S)
		local axis = make("Frame", { Name = "Axis", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 58 + CHART_HEIGHT), Size = UDim2.new(1, 0, 0, 14) }, f)
		local fromLbl = label(axis, "From", "", { Size = UDim2.new(0.5, 0, 1, 0), TextSize = 10, TextColor3 = Theme.Colors.TextSecondary })
		local toLbl = label(axis, "To", "", { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0.5, 0, 0, 0), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 10, TextColor3 = Theme.Colors.TextSecondary })

		local function draw(series: { any }, previous: { any }?, step: number)
			clear(plot)
			local n = #series
			local maxV = 0
			local function total(p: any): number
				local sum = 0
				for _, s in ipairs(segments) do
					sum += tonumber(p[s.Key]) or 0
				end
				return sum
			end
			for i = 1, n do
				maxV = math.max(maxV, total(series[i]))
				if previous and previous[i] then
					maxV = math.max(maxV, total(previous[i]))
				end
			end
			maxLabel.Text = ("max %s%s"):format(fmt(maxV), o.Unit or "")
			fromLbl.Text = if n > 0 then timeLabel(series[1].T, step) else ""
			toLbl.Text = if n > 0 then timeLabel(series[n].T, step) else ""
			readout.Text = if maxV == 0 then "no data yet" else "hover a bar"
			if n == 0 or maxV == 0 then
				return
			end
			local gap = if n > 48 then 0 else 2
			for i, p in ipairs(series) do
				local slot = make("Frame", {
					Name = "Bar_" .. i,
					BackgroundTransparency = 1,
					Position = UDim2.new((i - 1) / n, 0, 0, 0),
					Size = UDim2.new(1 / n, -gap, 1, 0),
					Active = true,
				}, plot)
				local prevP = previous and previous[i]
				if prevP then
					local pv = total(prevP)
					if pv > 0 then
						make("Frame", {
							Name = "Previous",
							BackgroundColor3 = Theme.Colors.TextSecondary,
							BackgroundTransparency = 0.75,
							BorderSizePixel = 0,
							AnchorPoint = Vector2.new(0, 1),
							Position = UDim2.new(0, 0, 1, 0),
							Size = UDim2.new(1, 0, pv / maxV, 0),
						}, slot)
					end
				end
				local y = 0
				for _, s in ipairs(segments) do
					local v = tonumber(p[s.Key]) or 0
					if v > 0 then
						local h = v / maxV
						make("Frame", {
							Name = s.Key,
							BackgroundColor3 = s.Color,
							BorderSizePixel = 0,
							AnchorPoint = Vector2.new(0.5, 1),
							Position = UDim2.new(0.5, 0, 1 - y, 0),
							Size = UDim2.new(if prevP then 0.6 else 1, 0, h, 0),
						}, slot)
						y += h
					end
				end
				slot.MouseEnter:Connect(function()
					local parts = {}
					for _, s in ipairs(segments) do
						table.insert(parts, ("%s %s%s"):format(s.Label, fmt(p[s.Key]), o.Unit or ""))
					end
					local text = timeLabel(p.T, step) .. "  " .. table.concat(parts, " / ")
					if prevP then
						text ..= ("  (before: %s)"):format(fmt(total(prevP)))
					end
					readout.Text = text
				end)
			end
		end
		return draw
	end

	local C = Theme.Colors
	local drawPlayers = chart("Players", "Players", {
		{ Key = "Players", Color = C.Accent, Label = "Peak per server" },
	})
	local perfDraw: any
	local function buildPerf()
		local existing = charts:FindFirstChild("Chart_Performance")
		local layoutOrder = existing and (existing :: any).LayoutOrder
		if existing then
			existing:Destroy()
		end
		local unit = if perfMetric == "Ping" then " ms" elseif perfMetric == "Memory" then " MB" else " fps"
		perfDraw = chart("Performance", "Server performance", { { Key = perfMetric, Color = C.Warning, Label = perfMetric } }, {
			Unit = unit,
			Chips = { "Fps", "Ping", "Memory" },
			Active = perfMetric,
			OnChip = function(m)
				perfMetric = m
				buildPerf()
				if report then
					perfDraw(report.Series, report.Previous and report.Previous.Series, report.Range.Step)
				end
			end,
		})
		if layoutOrder then
			(charts :: any).Chart_Performance.LayoutOrder = layoutOrder
		end
	end
	buildPerf()
	local drawCommands = chart("Commands", "Command usage", {
		{ Key = "Success", Color = C.Success, Label = "Succeeded" },
		{ Key = "Failed", Color = C.Error, Label = "Failed" },
		{ Key = "Denied", Color = C.Warning, Label = "Denied" },
	})
	local drawModeration = chart("Moderation", "Moderation activity", {
		{ Key = "Moderation", Color = C.Error, Label = "Moderation actions" },
	})
	local drawStaff = chart("Staff", "Staff activity", {
		{ Key = "StaffCmd", Color = C.Accent, Label = "Staff commands" },
	})
	local drawEconomy = chart("Economy", "Economy transactions", {
		{ Key = "Economy", Color = C.Success, Label = "Leaderstat changes" },
	})

	-- ======================================================================
	-- Lists
	-- ======================================================================
	local lists = make("Frame", { Name = "Lists", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 10) }, lists)
	local function listCard(name: string, title: string): Frame
		local c = card(lists, name, UDim.new(0.5, -5))
		caption(c, title)
		return c
	end
	local topCommands = listCard("TopCommands", "Most-used commands")
	local topMods = listCard("TopModerators", "Most-active moderators")
	local recentMod = listCard("RecentModeration", "Recent moderation actions")
	local econStats = listCard("EconomyStats", "Economy by stat")
	lists:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local narrow = lists.AbsoluteSize.X < 640
		for _, c in ipairs({ topCommands, topMods, recentMod, econStats }) do
			c.Size = if narrow then UDim2.new(1, 0, 0, 0) else UDim2.new(0.5, -5, 0, 0)
		end
	end)

	local function fillList(frame: Frame, items: { { string } }, empty: string)
		for _, c in ipairs(frame:GetChildren()) do
			if c:IsA("GuiObject") and c.Name ~= "Caption" then
				c:Destroy()
			end
		end
		if #items == 0 then
			label(frame, "Empty", empty, { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
			return
		end
		for i, item in ipairs(items) do
			local r = make("Frame", { Name = "Row_" .. i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) }, frame)
			label(r, "Left", item[1], { Size = UDim2.new(0.7, 0, 1, 0) })
			label(r, "Right", item[2], { Size = UDim2.new(0.3, 0, 1, 0), Position = UDim2.new(0.7, 0, 0, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Theme.Colors.TextSecondary })
		end
	end

	-- ======================================================================
	-- Render
	-- ======================================================================
	local function deltaFor(key: string, higherIsGood: boolean?): (string?, Color3?)
		if not report or not report.Previous then
			return nil
		end
		local before = tonumber(report.Previous.Totals[key]) or 0
		local after = tonumber(report.Totals[key]) or 0
		if before == 0 then
			return if after == 0 then "no change" else "new", Theme.Colors.TextSecondary
		end
		local pct = math.floor((after - before) / before * 1000 + 0.5) / 10
		local good = (pct >= 0) == (higherIsGood ~= false)
		return ("%s%s%% vs before"):format(if pct >= 0 then "+" else "", tostring(pct)), if pct == 0 then Theme.Colors.TextSecondary elseif good then Theme.Colors.Success else Theme.Colors.Error
	end

	local function render()
		if not report then
			return
		end
		local live = report.Live or {}
		clear(liveRow)
		tile(liveRow, "Players", "Players", ("%d / %d"):format(live.Players or 0, live.MaxPlayers or 0))
		tile(liveRow, "Staff", "Staff online", tostring(live.Staff or 0))
		tile(liveRow, "Uptime", "Uptime", uptime(live.Uptime or 0))
		local fps = live.Fps or 0
		tile(liveRow, "Fps", "Server FPS", tostring(fps), if fps >= 50 then C.Success elseif fps >= 30 then C.Warning else C.Error)
		tile(liveRow, "Memory", "Memory", fmt(live.Memory) .. " MB")
		tile(liveRow, "Ping", "Avg ping", fmt(live.Ping) .. " ms")
		tile(liveRow, "Punishments", "Active punishments", tostring(live.ActivePunishments or 0), nil, ("%d bans, %d mutes"):format(live.ActiveBans or 0, live.ActiveMutes or 0))

		local t = report.Totals
		clear(totalsRow)
		tile(totalsRow, "Peak", "Peak players", fmt(t.Peak), nil, deltaFor("Peak"))
		if report.Scope == "all" then
			tile(totalsRow, "GlobalPeak", "Peak all servers", fmt(t.GlobalPeak), nil, deltaFor("GlobalPeak"))
		end
		tile(totalsRow, "Commands", "Commands", fmt(t.Commands), nil, deltaFor("Commands"))
		tile(totalsRow, "SuccessRate", "Success rate", tostring(t.SuccessRate) .. "%", if t.SuccessRate >= 90 then C.Success else C.Warning, deltaFor("SuccessRate"))
		tile(totalsRow, "Failed", "Failed", fmt(t.Failed), if t.Failed > 0 then C.Error else nil, deltaFor("Failed", false))
		tile(totalsRow, "Denied", "Denied", fmt(t.Denied), if t.Denied > 0 then C.Warning else nil, deltaFor("Denied", false))
		tile(totalsRow, "Moderation", "Moderation", fmt(t.Moderation), nil, deltaFor("Moderation"))
		tile(totalsRow, "StaffCmd", "Staff commands", fmt(t.StaffCmd), nil, deltaFor("StaffCmd"))
		tile(totalsRow, "Economy", "Economy txns", fmt(t.Economy), nil, deltaFor("Economy"))
		tile(totalsRow, "Fps", "Avg FPS", tostring(t.Fps), nil, deltaFor("Fps"))
		tile(totalsRow, "Ping", "Avg ping", fmt(t.Ping) .. " ms", nil, deltaFor("Ping", false))

		local prev = report.Previous and report.Previous.Series
		local step = report.Range.Step
		drawPlayers(report.Series, prev, step)
		perfDraw(report.Series, prev, step)
		drawCommands(report.Series, prev, step)
		drawModeration(report.Series, prev, step)
		drawStaff(report.Series, prev, step)
		drawEconomy(report.Series, prev, step)

		local items = {}
		for _, c in ipairs(report.TopCommands or {}) do
			table.insert(items, { ";" .. tostring(c.Command), fmt(c.Count) })
		end
		fillList(topCommands, items, "No commands in this range.")
		items = {}
		for _, m in ipairs(report.TopModerators or {}) do
			table.insert(items, { tostring(m.Name), fmt(m.Count) .. " actions" })
		end
		fillList(topMods, items, "No moderation actions in this range.")
		items = {}
		for _, r in ipairs(live.RecentModeration or {}) do
			table.insert(items, { ("#%s %s %s by %s"):format(tostring(r.Id), tostring(r.Type), tostring(r.Target), tostring(r.By)), if r.At then ago(r.At) else "" })
		end
		fillList(recentMod, items, "No recent moderation actions.")
		items = {}
		for _, e in ipairs(report.Economy or {}) do
			table.insert(items, { tostring(e.Stat), fmt(e.Volume) .. " moved" })
		end
		fillList(econStats, items, "No economy changes in this range.")

		local where = if report.Scope == "server" then "this server" else ("all servers (%d seen)"):format(report.Servers or 0)
		status.Text = ("%s, %s - %s. Updated %s UTC.%s"):format(
			report.Range.Label,
			where,
			if step >= 86400 then "daily bars" elseif step > 3600 then "6-hour bars" else "hourly bars",
			os.date("!%H:%M:%S", report.Now or os.time()) :: string,
			if report.Persistent then "" else " Not persisted (no DataStore access)."
		)
		status.TextColor3 = Theme.Colors.TextSecondary
	end

	local function refresh()
		if not remote or loading then
			return
		end
		loading = true
		status.Text = "Loading..."
		local ok, data = pcall(function()
			return (remote :: RemoteFunction):InvokeServer({
				Range = state.Range,
				From = state.From,
				To = state.To,
				Scope = state.Scope,
				Compare = state.Compare,
			})
		end)
		loading = false
		if not ok or type(data) ~= "table" then
			status.Text = "Could not load analytics (try again in a moment)."
			status.TextColor3 = Theme.Colors.Error
			return
		end
		if data.Error then
			status.Text = tostring(data.Error)
			status.TextColor3 = Theme.Colors.Error
			return
		end
		report = data
		render()
	end

	for id, chip in pairs(rangeChips) do
		chip.MouseButton1Click:Connect(function()
			state.Range = id
			paintToolbar()
			if id ~= "custom" then
				refresh()
			elseif fromBox.Text == "" then
				fromBox.Text = os.date("!%Y-%m-%d", os.time() - 6 * 86400) :: string
				toBox.Text = today
			end
		end)
	end
	applyBtn.MouseButton1Click:Connect(function()
		state.From = fromBox.Text:match("^%s*(.-)%s*$") or ""
		state.To = toBox.Text:match("^%s*(.-)%s*$") or ""
		refresh()
	end)
	for id, chip in pairs(scopeChips) do
		chip.MouseButton1Click:Connect(function()
			state.Scope = id
			paintToolbar()
			refresh()
		end)
	end
	compareChip.MouseButton1Click:Connect(function()
		state.Compare = not state.Compare
		paintToolbar()
		refresh()
	end)
	refreshBtn.MouseButton1Click:Connect(refresh)

	paintToolbar()
	task.defer(relayoutCharts)
	-- Refresh while visible (every 60 s; the server caches DataStore reads).
	local wasVisible = false
	task.spawn(function()
		while container.Parent do
			local visible = container.Visible
			if visible and not wasVisible then
				refresh()
			end
			wasVisible = visible
			task.wait(1)
		end
	end)
	task.spawn(function()
		while container.Parent do
			task.wait(60)
			if container.Visible then
				refresh()
			end
		end
	end)
end

return AnalyticsPage
