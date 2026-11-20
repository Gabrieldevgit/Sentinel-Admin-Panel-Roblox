--!strict
--[[
	ModerationPage.lua (W12 - Moderation center)

	Tabs:
		Dashboard  cards (active cases, open investigations, active bans /
		           mutes, pending reports, moderators online, actions in
		           24 h), 24-hour activity bars, recent punishments, recent
		           warnings, active bans, active mutes, moderators online,
		           most active moderators. Rows open the case.
		Cases      query (;cases syntax) + status / type chips, case list,
		           detail with every field, notes, add note, close / reopen,
		           assign to me, lift the punishment, new investigation case.
		Bulk       pick online players, an action, a duration and a reason
		           (templates as chips) -> one command for all of them.

	Reads GetModerationDashboardRemote, SearchCasesRemote, GetCaseRemote.
	Every change is a normal command through ExecuteCommandRemote, so
	permissions, confirmation, logging and cases apply.

	Stable instance names (Studio MCP tests):
		Tabs.Tab_<Dashboard|Cases|Bulk>, Tabs.Refresh
		Dashboard.Cards.Card_<Key>.Value, Dashboard.Activity.Bars.Bar_<1..24>
		Dashboard.<Section>.List.Case_<id>
		Cases.QueryRow.{Query,Search,New}, Cases.Chips.<Group>_<Value>
		Cases.List.Case_<id>, Cases.Detail.{Fields,Notes,NoteRow.{NoteBox,Add},Actions.*}
		Bulk.Players.Row_<name>, Bulk.Actions.Action_<name>,
		Bulk.Durations.Dur_<value>, Bulk.Reasons.Reason_<name>,
		Bulk.ReasonBox, Bulk.Preview, Bulk.Run
	Public API:
		ModerationPage.Build(container)
		ModerationPage.OpenCase(id)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local ModerationPage = {}

local layoutCounter = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		layoutCounter += 1
		inst.LayoutOrder = layoutCounter
	elseif inst:IsA("UIListLayout") or inst:IsA("UIGridLayout") then
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

local function label(parent: Instance, name: string, text: string, props: { [string]: any }?): TextLabel
	local l = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
	}, parent)
	for k, v in pairs(props or {}) do
		(l :: any)[k] = v
	end
	return l
end

local function button(parent: Instance, name: string, text: string, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width or 80, 0, 26),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function chip(parent: Instance, name: string, text: string): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 0, 22),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Font = Theme.Font.Medium,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextSecondary,
		Text = text,
	}, parent) :: TextButton
	Theme.corner(b, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
	return b
end

local function paint(b: TextButton, on: boolean)
	b.BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
	b.TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
end

local function flow(parent: Instance, name: string, height: number?): Frame
	local f = make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or 22),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 4) }, f)
	return f
end

local function ago(t: number): string
	local d = os.time() - t
	if d < 60 then
		return d .. "s ago"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m ago"
	elseif d < 86400 then
		return math.floor(d / 3600) .. "h ago"
	end
	return math.floor(d / 86400) .. "d ago"
end

local function expiryText(c: any): string
	if c.ExpiresAt == -1 then
		return "permanent"
	elseif type(c.ExpiresAt) == "number" then
		local left = c.ExpiresAt - os.time()
		if left <= 0 then
			return "expired"
		elseif left < 3600 then
			return math.ceil(left / 60) .. "m left"
		elseif left < 86400 then
			return math.floor(left / 3600) .. "h left"
		end
		return math.floor(left / 86400) .. "d left"
	end
	return "-"
end

local STATUS_COLOR = {
	Open = "Warning",
	Active = "Error",
	Expired = "TextSecondary",
	Revoked = "TextSecondary",
	Closed = "Success",
}

local function statusColor(status: string): Color3
	return (Theme.Colors :: any)[STATUS_COLOR[status] or "TextSecondary"]
end

local api: any = {}

function ModerationPage.OpenCase(id: number)
	if api.OpenCase then
		api.OpenCase(id)
	end
end

function ModerationPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local dashboardRemote = SentinelShared:WaitForChild("GetModerationDashboardRemote", 15) :: RemoteFunction?
	local searchRemote = SentinelShared:WaitForChild("SearchCasesRemote", 15) :: RemoteFunction?
	local caseRemote = SentinelShared:WaitForChild("GetCaseRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?

	local function run(text: string)
		if executeRemote then
			executeRemote:FireServer(text)
		end
	end

	label(container, "Header", "Moderation Center", {
		Size = UDim2.new(1, -260, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
	})
	local statusLine = label(container, "SubHeader", "Cases, punishments and staff activity.", {
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = Theme.Colors.TextSecondary,
	})

	local tabs = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 260, 0, 26),
	}, container)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 4),
	}, tabs)

	local pages: { [string]: GuiObject } = {}
	local tabButtons: { [string]: TextButton } = {}
	local current = "Dashboard"
	local refreshers: { [string]: () -> () } = {}

	local function show(name: string)
		current = name
		for id, page in pairs(pages) do
			page.Visible = id == name
		end
		for id, b in pairs(tabButtons) do
			paint(b, id == name)
		end
		if name == "Bulk" then
			statusLine.Text = "One punishment for several players: pick players, action, duration and reason."
		end
		if refreshers[name] then
			task.spawn(refreshers[name])
		end
	end

	for _, id in ipairs({ "Dashboard", "Cases", "Bulk" }) do
		local b = button(tabs, "Tab_" .. id, id, 72)
		tabButtons[id] = b
		b.Activated:Connect(function()
			show(id)
		end)
	end
	local refreshBtn = button(tabs, "Refresh", "Refresh", 64)
	refreshBtn.Activated:Connect(function()
		if refreshers[current] then
			task.spawn(refreshers[current])
		end
	end)

	local function pageFrame(name: string, scrolling: boolean): any
		local f = make(if scrolling then "ScrollingFrame" else "Frame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 0, 52),
			Size = UDim2.new(1, 0, 1, -52),
			Visible = false,
		}, container)
		if scrolling then
			f.ScrollBarThickness = 4
			f.CanvasSize = UDim2.new()
			f.AutomaticCanvasSize = Enum.AutomaticSize.Y
			f.ScrollingDirection = Enum.ScrollingDirection.Y
		end
		pages[name] = f
		return f
	end

	-- ======================================================================
	-- Dashboard
	-- ======================================================================
	local dash = pageFrame("Dashboard", true)
	make("UIListLayout", { Padding = UDim.new(0, 10) }, dash)
	make("UIPadding", { PaddingRight = UDim.new(0, 8) }, dash)

	local cards = make("Frame", { Name = "Cards", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60), AutomaticSize = Enum.AutomaticSize.Y }, dash)
	make("UIGridLayout", { CellSize = UDim2.new(0, 132, 0, 56), CellPadding = UDim2.new(0, 6, 0, 6) }, cards)
	local cardValues: { [string]: TextLabel } = {}
	for _, spec in ipairs({
		{ "Active", "Active cases" },
		{ "Open", "Open investigations" },
		{ "ActiveBans", "Active bans" },
		{ "ActiveMutes", "Active mutes" },
		{ "Reports", "Pending reports" },
		{ "Online", "Moderators online" },
		{ "Today", "Actions (24 h)" },
	}) do
		local card = make("Frame", { Name = "Card_" .. spec[1], BackgroundColor3 = Theme.Colors.Surface }, cards)
		Theme.corner(card, Theme.Radius.S)
		Theme.padding(card, 8)
		cardValues[spec[1]] = label(card, "Value", "-", { Size = UDim2.new(1, 0, 0, 24), Font = Theme.Font.Bold, TextSize = 20 })
		label(card, "Label", spec[2], {
			Position = UDim2.new(0, 0, 0, 24),
			Size = UDim2.new(1, 0, 0, 14),
			TextSize = 11,
			TextColor3 = Theme.Colors.TextSecondary,
		})
	end

	local activityBox = make("Frame", { Name = "Activity", BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 96) }, dash)
	Theme.corner(activityBox, Theme.Radius.S)
	label(activityBox, "Title", "Moderation activity, last 24 hours (cases per hour)", {
		Position = UDim2.new(0, 8, 0, 4),
		Size = UDim2.new(1, -16, 0, 16),
		TextColor3 = Theme.Colors.TextSecondary,
		TextSize = 11,
	})
	local barArea = make("Frame", {
		Name = "Bars",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 10, 0, 22),
		Size = UDim2.new(1, -20, 1, -30),
	}, activityBox)
	local bars: { Frame } = {}
	for i = 1, 24 do
		local bar = make("Frame", {
			Name = "Bar_" .. i,
			BackgroundColor3 = Theme.Colors.Accent,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new((i - 1) / 24, 0, 1, 0),
			Size = UDim2.new(1 / 24, -4, 0, 2),
		}, barArea)
		Theme.corner(bar, UDim.new(0, 2))
		table.insert(bars, bar)
	end

	local function section(name: string, title: string): (Frame, Frame)
		local box = make("Frame", { Name = name, BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 40), AutomaticSize = Enum.AutomaticSize.Y }, dash)
		Theme.corner(box, Theme.Radius.S)
		Theme.padding(box, 8)
		make("UIListLayout", { Padding = UDim.new(0, 4) }, box)
		label(box, "Title", title, { Size = UDim2.new(1, 0, 0, 16), Font = Theme.Font.Bold, TextSize = 13 })
		local list = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, box)
		make("UIListLayout", { Padding = UDim.new(0, 2) }, list)
		return box, list
	end

	local sections: { [string]: Frame } = {}
	for _, spec in ipairs({
		{ "RecentPunishments", "Recent punishments" },
		{ "RecentWarnings", "Recent warnings" },
		{ "ActiveBans", "Active bans" },
		{ "ActiveMutes", "Active mutes" },
		{ "ModeratorsOnline", "Moderators online" },
		{ "TopModerators", "Most active moderators (24 h)" },
		{ "Reasons", "Reason templates (type #name in any reason)" },
	}) do
		local _, list = section(spec[1], spec[2])
		sections[spec[1]] = list
	end

	local function clear(frame: Instance)
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function caseRow(parent: Instance, c: any, extra: string?): TextButton
		local row = make("TextButton", {
			Name = "Case_" .. tostring(c.Id),
			AutoButtonColor = true,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, 0, 0, 24),
			Text = "",
		}, parent) :: TextButton
		Theme.corner(row, UDim.new(0, 4))
		local dot = make("Frame", {
			Name = "Status",
			BackgroundColor3 = statusColor(c.Status),
			Position = UDim2.new(0, 6, 0.5, -4),
			Size = UDim2.new(0, 8, 0, 8),
		}, row)
		Theme.corner(dot, UDim.new(1, 0))
		label(row, "Line", ("#%d  %s  %s  by %s%s%s"):format(
			c.Id,
			c.Type,
			c.TargetName,
			c.ModeratorName,
			if c.Reason then '  "' .. c.Reason .. '"' else "",
			if extra then "  " .. extra else ""
		), { Position = UDim2.new(0, 20, 0, 0), Size = UDim2.new(1, -96, 1, 0) })
		label(row, "When", ago(c.CreatedAt), {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0, 70, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = Theme.Colors.TextSecondary,
			TextSize = 11,
		})
		row.Activated:Connect(function()
			ModerationPage.OpenCase(c.Id)
		end)
		return row
	end

	local function emptyLine(parent: Instance, text: string)
		label(parent, "Empty", text, { Size = UDim2.new(1, 0, 0, 18), TextColor3 = Theme.Colors.TextSecondary, TextSize = 11 })
	end

	local dashboardData: any = nil
	local bulkReasonsChanged: (() -> ())? = nil

	refreshers.Dashboard = function()
		if not dashboardRemote then
			return
		end
		local ok, data = pcall(function()
			return dashboardRemote:InvokeServer()
		end)
		if not ok or type(data) ~= "table" then
			statusLine.Text = "Could not load the moderation dashboard."
			return
		end
		if data.Error then
			statusLine.Text = data.Error
			return
		end
		dashboardData = data
		statusLine.Text = ("%d case(s) on record. Updated %s."):format(data.Known or 0, os.date("%H:%M:%S") :: string)
		local counts = data.Counts or {}
		cardValues.Active.Text = tostring(counts.Active or 0)
		cardValues.Open.Text = tostring(counts.Open or 0)
		cardValues.ActiveBans.Text = tostring(counts.ActiveBans or 0)
		cardValues.ActiveMutes.Text = tostring(counts.ActiveMutes or 0)
		cardValues.Reports.Text = if data.PendingReports then tostring(data.PendingReports) else "-"
		cardValues.Online.Text = tostring(#(data.ModeratorsOnline or {}))
		cardValues.Today.Text = tostring(counts.Today or 0)

		local peak = 1
		for _, n in ipairs(data.Activity or {}) do
			peak = math.max(peak, n)
		end
		for i, bar in ipairs(bars) do
			local n = (data.Activity or {})[i] or 0
			bar.Size = UDim2.new(1 / 24, -4, 0, 2 + math.floor(60 * n / peak))
			bar.BackgroundTransparency = if n == 0 then 0.7 else 0
		end

		for key, list in pairs(sections) do
			clear(list)
			local items = data[key] or {}
			if key == "ModeratorsOnline" then
				for _, m in ipairs(items) do
					label(list, "Mod_" .. m.Name, ("%s (@%s)  %s"):format(m.DisplayName, m.Name, m.Rank), { Size = UDim2.new(1, 0, 0, 18) })
				end
			elseif key == "TopModerators" then
				for _, m in ipairs(items) do
					label(list, "Top_" .. m.Name, ("%s  %d action(s)"):format(m.Name, m.Count), { Size = UDim2.new(1, 0, 0, 18) })
				end
			elseif key == "Reasons" then
				for _, r in ipairs(items) do
					label(list, "Reason_" .. r.Name, ("#%s  %s"):format(r.Name, r.Text), { Size = UDim2.new(1, 0, 0, 18) })
				end
			else
				for _, c in ipairs(items) do
					local extra = if key == "ActiveBans" or key == "ActiveMutes" then expiryText(c) else c.Status
					caseRow(list, c, extra)
				end
			end
			if #items == 0 then
				emptyLine(list, "Nothing here.")
			end
		end
		if bulkReasonsChanged then
			bulkReasonsChanged()
		end
	end

	-- ======================================================================
	-- Cases
	-- ======================================================================
	local casesPage = pageFrame("Cases", false)
	local queryRow = make("Frame", { Name = "QueryRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, casesPage)
	local queryBox = make("TextBox", {
		Name = "Query",
		Size = UDim2.new(1, -184, 1, 0),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Mono,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "player:Bob mod:Alice type:ban status:active since:7d #12  text...",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Text = "",
	}, queryRow) :: TextBox
	Theme.corner(queryBox, Theme.Radius.S)
	Theme.padding(queryBox, 6)
	local searchBtn = button(queryRow, "Search", "Search", 84)
	searchBtn.Position = UDim2.new(1, -176, 0, 0)
	searchBtn.BackgroundColor3 = Theme.Colors.Accent
	local newBtn = button(queryRow, "New", "New case", 84)
	newBtn.Position = UDim2.new(1, -84, 0, 0)

	local chips = make("Frame", { Name = "Chips", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 34), Size = UDim2.new(1, 0, 0, 22) }, casesPage)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 4) }, chips)
	local chipState = { Status = "status:active", Type = "" }
	local chipButtons: { [string]: { [string]: TextButton } } = { Status = {}, Type = {} }
	local searchCases: (boolean?) -> () -- forward

	local function paintChips()
		for group, list in pairs(chipButtons) do
			for value, b in pairs(list) do
				paint(b, (chipState :: any)[group] == value)
			end
		end
	end
	local function addChip(group: string, text: string, value: string)
		local b = chip(chips, group .. "_" .. text:gsub("%W", ""), text)
		chipButtons[group][value] = b
		b.Activated:Connect(function()
			(chipState :: any)[group] = value
			paintChips()
			searchCases(false)
		end)
	end
	for _, s in ipairs({ { "Active", "status:active" }, { "Open", "status:open" }, { "Closed", "status:closed" }, { "All", "" } }) do
		addChip("Status", s[1], s[2])
	end
	make("Frame", { Name = "Gap", BackgroundTransparency = 1, Size = UDim2.new(0, 8, 0, 22) }, chips)
	for _, t in ipairs({ { "Any type", "" }, { "Bans", "type:ban" }, { "Mutes", "type:mute" }, { "Warnings", "type:warn" }, { "Kicks", "type:kick" }, { "Jails", "type:jail" }, { "Investigations", "type:investigation" } }) do
		addChip("Type", t[1], t[2])
	end
	paintChips()

	local split = make("Frame", { Name = "Split", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 62), Size = UDim2.new(1, 0, 1, -62) }, casesPage)
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Size = UDim2.new(0.5, -4, 1, 0),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, split)
	Theme.corner(list, Theme.Radius.S)
	Theme.padding(list, 6)
	make("UIListLayout", { Padding = UDim.new(0, 2) }, list)

	local detail = make("ScrollingFrame", {
		Name = "Detail",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.5, -4, 1, 0),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, split)
	Theme.corner(detail, Theme.Radius.S)
	Theme.padding(detail, 8)
	make("UIListLayout", { Padding = UDim.new(0, 6) }, detail)

	-- Re-parent the Cases list/detail references so instance paths stay
	-- short: Cases.List / Cases.Detail.
	list.Parent = casesPage
	detail.Parent = casesPage
	list.Position = UDim2.new(0, 0, 0, 62)
	list.Size = UDim2.new(0.5, -4, 1, -62)
	detail.Position = UDim2.new(1, 0, 0, 62)
	detail.Size = UDim2.new(0.5, -4, 1, -62)
	split:Destroy()

	local loaded: { any } = {}
	local cursor: number? = nil
	local selectedId: number? = nil
	local loadMore: TextButton? = nil

	local function renderDetail(c: any?)
		clear(detail)
		if not c then
			label(detail, "Empty", "Select a case, or press New case.", { Size = UDim2.new(1, 0, 0, 18), TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		selectedId = c.Id
		label(detail, "Title", ("Case #%d  -  %s %s"):format(c.Id, c.Type, c.TargetName), { Size = UDim2.new(1, 0, 0, 20), Font = Theme.Font.Bold, TextSize = 15 })
		local fields = make("Frame", { Name = "Fields", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, detail)
		make("UIListLayout", { Padding = UDim.new(0, 1) }, fields)
		local function field(key: string, value: string, color: Color3?)
			local row = make("Frame", { Name = "F_" .. key:gsub("%W", ""), BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) }, fields)
			label(row, "Key", key, { Size = UDim2.new(0, 96, 1, 0), TextColor3 = Theme.Colors.TextSecondary })
			label(row, "Value", value, {
				Position = UDim2.new(0, 100, 0, 0),
				Size = UDim2.new(1, -100, 1, 0),
				TextColor3 = color or Theme.Colors.Text,
				TextTruncate = Enum.TextTruncate.None,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
			})
			row.AutomaticSize = Enum.AutomaticSize.Y
		end
		field("Status", c.Status, statusColor(c.Status))
		field("Player", ("%s (%d)"):format(c.TargetName, c.TargetId))
		field("Moderator", ("%s (%d)"):format(c.ModeratorName, c.ModeratorId))
		field("Assigned to", c.Assignee or "nobody")
		field("Reason", c.Reason or "-")
		field("Duration", c.Duration or "-")
		field("Expires", expiryText(c))
		field("Created", os.date("%Y-%m-%d %H:%M:%S", c.CreatedAt) :: string)
		field("Server", tostring(c.Server or "?") .. (if c.Global then "  (global action)" else ""))
		field("Source", c.Source or "-")

		local actions = flow(detail, "Actions", 26)
		local function act(name: string, text: string, command: string)
			local b = button(actions, name, text, 96)
			b.Activated:Connect(function()
				run(command)
				task.delay(0.8, function()
					if selectedId == c.Id then
						api.OpenCase(c.Id)
					end
					searchCases(false)
				end)
			end)
		end
		if c.Status == "Open" or c.Status == "Active" then
			act("Close", "Close case", "caseclose " .. c.Id)
		else
			act("Reopen", "Reopen", "casereopen " .. c.Id)
		end
		act("AssignMe", "Assign to me", "caseassign " .. c.Id .. " me")
		if c.Status == "Active" then
			if c.Type == "ban" then
				act("Lift", "Unban", "gunban " .. c.TargetId)
			elseif c.Type == "mute" and Players:FindFirstChild(c.TargetName) then
				act("Lift", "Unmute", "unmute " .. c.TargetName)
			elseif c.Type == "jail" and Players:FindFirstChild(c.TargetName) then
				act("Lift", "Unjail", "unjail " .. c.TargetName)
			end
		end
		local hist = button(actions, "History", "Player cases", 96)
		hist.Activated:Connect(function()
			queryBox.Text = "player:" .. tostring(c.TargetId)
			chipState.Status = ""
			paintChips()
			searchCases(false)
		end)

		label(detail, "NotesTitle", ("Notes and discussion (%d)"):format(#(c.Notes or {})), { Size = UDim2.new(1, 0, 0, 18), Font = Theme.Font.Bold })
		local notes = make("Frame", { Name = "Notes", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, detail)
		make("UIListLayout", { Padding = UDim.new(0, 3) }, notes)
		for i, n in ipairs(c.Notes or {}) do
			label(notes, "Note_" .. i, ("%s  %s: %s"):format(os.date("%m-%d %H:%M", n.At) :: string, n.By, n.Text), {
				Size = UDim2.new(1, 0, 0, 16),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
			})
		end
		if #(c.Notes or {}) == 0 then
			emptyLine(notes, "No notes yet.")
		end
		local noteRow = make("Frame", { Name = "NoteRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, detail)
		local noteBox = make("TextBox", {
			Name = "NoteBox",
			Size = UDim2.new(1, -88, 1, 0),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Font = Theme.Font.Regular,
			TextSize = 12,
			TextColor3 = Theme.Colors.Text,
			PlaceholderText = "Add a note for staff...",
			PlaceholderColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
			ClipsDescendants = true,
			Text = "",
		}, noteRow) :: TextBox
		Theme.corner(noteBox, Theme.Radius.S)
		Theme.padding(noteBox, 6)
		local addBtn = button(noteRow, "Add", "Add note", 80)
		addBtn.Position = UDim2.new(1, -80, 0, 0)
		local function addNote()
			local text = noteBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
			if text == "" then
				return
			end
			run(("casenote %d %s"):format(c.Id, text:gsub("&&", "&")))
			noteBox.Text = ""
			task.delay(0.8, function()
				if selectedId == c.Id then
					api.OpenCase(c.Id)
				end
			end)
		end
		addBtn.Activated:Connect(addNote)
		noteBox.FocusLost:Connect(function(enter)
			if enter then
				addNote()
			end
		end)
	end

	local function renderNewCaseForm()
		clear(detail)
		selectedId = nil
		label(detail, "Title", "New investigation case", { Size = UDim2.new(1, 0, 0, 20), Font = Theme.Font.Bold, TextSize = 15 })
		local function box(name: string, placeholder: string): TextBox
			local b = make("TextBox", {
				Name = name,
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				Font = Theme.Font.Regular,
				TextSize = 12,
				TextColor3 = Theme.Colors.Text,
				PlaceholderText = placeholder,
				PlaceholderColor3 = Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Left,
				ClearTextOnFocus = false,
				ClipsDescendants = true,
				Text = "",
			}, detail) :: TextBox
			Theme.corner(b, Theme.Radius.S)
			Theme.padding(b, 6)
			return b
		end
		local playerBox = box("PlayerBox", "Player (online name, username or UserId)")
		local summaryBox = box("SummaryBox", "What is this case about?")
		local create = button(detail, "Create", "Open case", 100)
		create.BackgroundColor3 = Theme.Colors.Accent
		create.Activated:Connect(function()
			local who = playerBox.Text:match("^%s*(%S+)")
			local summary = summaryBox.Text:gsub("&&", "&"):match("^%s*(.-)%s*$")
			if not who or summary == "" then
				return
			end
			run(("caseopen %s %s"):format(who, summary))
			chipState.Status = "status:open"
			paintChips()
			task.delay(1, function()
				searchCases(false)
			end)
		end)
	end
	newBtn.Activated:Connect(renderNewCaseForm)

	local function renderList()
		clear(list)
		for _, c in ipairs(loaded) do
			caseRow(list, c, c.Status)
		end
		if #loaded == 0 then
			emptyLine(list, "No cases match.")
		end
		if cursor then
			loadMore = button(list, "LoadMore", "Load more", 100)
			;(loadMore :: TextButton).Activated:Connect(function()
				searchCases(true)
			end)
		end
	end

	searchCases = function(more: boolean?)
		if not searchRemote then
			return
		end
		local query = table.concat({ chipState.Status, chipState.Type, queryBox.Text }, " ")
		local ok, data = pcall(function()
			return searchRemote:InvokeServer(query, if more then cursor else nil, 40)
		end)
		if not ok or type(data) ~= "table" then
			statusLine.Text = "Could not search cases."
			return
		end
		if data.Error then
			statusLine.Text = data.Error
		else
			statusLine.Text = ("%d case(s) match."):format(data.Total or 0)
		end
		if not more then
			loaded = {}
		end
		for _, c in ipairs(data.Cases or {}) do
			table.insert(loaded, c)
		end
		cursor = data.Cursor
		renderList()
	end

	api.OpenCase = function(id: number)
		if current ~= "Cases" then
			current = "Cases"
			for pid, page in pairs(pages) do
				page.Visible = pid == "Cases"
			end
			for pid, b in pairs(tabButtons) do
				paint(b, pid == "Cases")
			end
			if #loaded == 0 then
				task.spawn(searchCases, false)
			end
		end
		if not caseRemote then
			return
		end
		local ok, c = pcall(function()
			return caseRemote:InvokeServer(id)
		end)
		if ok and type(c) == "table" then
			renderDetail(c)
		end
	end

	searchBtn.Activated:Connect(function()
		searchCases(false)
	end)
	queryBox.FocusLost:Connect(function(enter)
		if enter then
			searchCases(false)
		end
	end)
	refreshers.Cases = function()
		searchCases(false)
		if selectedId then
			api.OpenCase(selectedId)
		end
	end
	renderDetail(nil)

	-- ======================================================================
	-- Bulk punishments
	-- ======================================================================
	local bulk = pageFrame("Bulk", true)
	make("UIListLayout", { Padding = UDim.new(0, 6) }, bulk)
	make("UIPadding", { PaddingRight = UDim.new(0, 8) }, bulk)

	local function heading(name: string, text: string)
		label(bulk, name, text, { Size = UDim2.new(1, 0, 0, 18), Font = Theme.Font.Bold, TextSize = 13 })
	end

	local selected: { [string]: boolean } = {}
	local action = "kick"
	local duration = "1d"
	local reasonText = ""
	local updatePreview: () -> () -- forward

	heading("PlayersTitle", "1. Players")
	local selRow = flow(bulk, "Selection", 22)
	local playersBox = make("Frame", { Name = "Players", BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 30), AutomaticSize = Enum.AutomaticSize.Y }, bulk)
	Theme.corner(playersBox, Theme.Radius.S)
	Theme.padding(playersBox, 6)
	make("UIGridLayout", { CellSize = UDim2.new(0, 170, 0, 24), CellPadding = UDim2.new(0, 4, 0, 4) }, playersBox)

	local function renderPlayers()
		clear(playersBox)
		local present = {}
		for _, p in ipairs(Players:GetPlayers()) do
			present[p.Name] = true
			local row = make("TextButton", {
				Name = "Row_" .. p.Name,
				AutoButtonColor = true,
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				Font = Theme.Font.Medium,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = "",
			}, playersBox) :: TextButton
			Theme.corner(row, UDim.new(0, 4))
			local box = make("Frame", { Name = "Check", Position = UDim2.new(0, 6, 0.5, -6), Size = UDim2.new(0, 12, 0, 12), BackgroundColor3 = Theme.Colors.Border }, row)
			Theme.corner(box, UDim.new(0, 3))
			local name = label(row, "Name", ("%s (@%s)"):format(p.DisplayName, p.Name), { Position = UDim2.new(0, 24, 0, 0), Size = UDim2.new(1, -28, 1, 0) })
			local function repaint()
				box.BackgroundColor3 = if selected[p.Name] then Theme.Colors.Accent else Theme.Colors.Border
				name.TextColor3 = if selected[p.Name] then Theme.Colors.Text else Theme.Colors.TextSecondary
			end
			repaint()
			row.Activated:Connect(function()
				selected[p.Name] = not selected[p.Name] or nil
				repaint()
				updatePreview()
			end)
		end
		for n in pairs(selected) do
			if not present[n] then
				selected[n] = nil
			end
		end
	end

	local function selectAll(on: boolean, exceptSelf: boolean?)
		selected = {}
		if on then
			for _, p in ipairs(Players:GetPlayers()) do
				if not (exceptSelf and p == Players.LocalPlayer) then
					selected[p.Name] = true
				end
			end
		end
		renderPlayers()
		updatePreview()
	end
	chip(selRow, "All", "Select all").Activated:Connect(function()
		selectAll(true)
	end)
	chip(selRow, "Others", "Everyone but me").Activated:Connect(function()
		selectAll(true, true)
	end)
	chip(selRow, "None", "Clear").Activated:Connect(function()
		selectAll(false)
	end)

	heading("ActionTitle", "2. Action")
	local actionRow = flow(bulk, "Actions", 22)
	local actionButtons: { [string]: TextButton } = {}
	for _, a in ipairs({ "kick", "ban", "mute", "warn", "jail" }) do
		local b = chip(actionRow, "Action_" .. a, a)
		actionButtons[a] = b
		b.Activated:Connect(function()
			action = a
			for k, other in pairs(actionButtons) do
				paint(other, k == action)
			end
			updatePreview()
		end)
	end
	paint(actionButtons.kick, true)

	heading("DurationTitle", "3. Duration (ban / mute)")
	local durRow = flow(bulk, "Durations", 22)
	local durButtons: { [string]: TextButton } = {}
	local customDur = make("TextBox", {
		Name = "CustomDuration",
		Size = UDim2.new(0, 90, 0, 22),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Mono,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "custom e.g. 3d",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		ClearTextOnFocus = false,
		Text = "",
	}, nil) :: TextBox
	for _, d in ipairs({ "15m", "1h", "6h", "1d", "7d", "30d", "perm" }) do
		local b = chip(durRow, "Dur_" .. d, d)
		durButtons[d] = b
		b.Activated:Connect(function()
			duration = d
			customDur.Text = ""
			for k, other in pairs(durButtons) do
				paint(other, k == duration)
			end
			updatePreview()
		end)
	end
	paint(durButtons["1d"], true)
	layoutCounter += 1
	customDur.LayoutOrder = layoutCounter
	customDur.Parent = durRow
	Theme.corner(customDur, Theme.Radius.S)
	customDur:GetPropertyChangedSignal("Text"):Connect(function()
		local t = customDur.Text:match("^%s*(%S+)")
		if t then
			duration = t
			for _, other in pairs(durButtons) do
				paint(other, false)
			end
			updatePreview()
		end
	end)

	heading("ReasonTitle", "4. Reason")
	local reasonRow = flow(bulk, "Reasons", 22)
	local reasonBox = make("TextBox", {
		Name = "ReasonBox",
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "Reason (or click a template above)",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Text = "",
	}, bulk) :: TextBox
	Theme.corner(reasonBox, Theme.Radius.S)
	Theme.padding(reasonBox, 6)
	reasonBox:GetPropertyChangedSignal("Text"):Connect(function()
		reasonText = reasonBox.Text
		updatePreview()
	end)

	bulkReasonsChanged = function()
		clear(reasonRow)
		for _, r in ipairs((dashboardData and dashboardData.Reasons) or {}) do
			local b = chip(reasonRow, "Reason_" .. r.Name, "#" .. r.Name)
			b.Activated:Connect(function()
				reasonBox.Text = "#" .. r.Name
			end)
		end
	end

	local preview = label(bulk, "Preview", "", {
		Size = UDim2.new(1, 0, 0, 34),
		Font = Theme.Font.Mono,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextColor3 = Theme.Colors.TextSecondary,
	})
	local runBtn = button(bulk, "Run", "Apply to selected", 160)
	runBtn.BackgroundColor3 = Theme.Colors.Error

	local function buildCommand(): (string?, string?)
		local names = {}
		for n in pairs(selected) do
			table.insert(names, n)
		end
		table.sort(names)
		if #names == 0 then
			return nil, "Select at least one player."
		end
		local reason = reasonText:gsub("&&", "&"):match("^%s*(.-)%s*$") or ""
		if action == "warn" and reason == "" then
			return nil, "Warnings need a reason."
		end
		local target = table.concat(names, ",")
		if action == "ban" or action == "mute" then
			target ..= ":" .. duration
		end
		return ("%s %s%s"):format(action, target, if reason ~= "" then " " .. reason else ""), nil
	end

	updatePreview = function()
		local text, problem = buildCommand()
		preview.Text = if text then ";" .. text else problem or ""
		preview.TextColor3 = if text then Theme.Colors.Text else Theme.Colors.TextSecondary
	end

	runBtn.Activated:Connect(function()
		local text = buildCommand()
		if text then
			run(text)
			task.delay(1, function()
				renderPlayers()
				updatePreview()
			end)
		end
	end)

	refreshers.Bulk = function()
		renderPlayers()
		updatePreview()
		if not dashboardData then
			refreshers.Dashboard()
		end
	end
	Players.PlayerAdded:Connect(function()
		if current == "Bulk" and container.Visible then
			renderPlayers()
		end
	end)
	Players.PlayerRemoving:Connect(function()
		if current == "Bulk" and container.Visible then
			task.defer(renderPlayers)
		end
	end)

	-- ======================================================================
	-- Refresh
	-- ======================================================================
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function()
			if container.Visible then
				task.delay(0.6, function()
					if current == "Dashboard" then
						refreshers.Dashboard()
					end
				end)
			end
		end)
	end
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible and refreshers[current] then
			task.spawn(refreshers[current])
		end
	end)
	task.spawn(function()
		while container.Parent do
			task.wait(20)
			if container.Visible and current == "Dashboard" then
				refreshers.Dashboard()
			end
		end
	end)
	show("Dashboard")
end

return ModerationPage
