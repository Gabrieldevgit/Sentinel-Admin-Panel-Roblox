--!strict
--[[
	StaffFeedsPage.lua (M-panel gaps) - Moderation > Chat Log and Moderation >
	Alerts (page ids "ChatLog" and "Alerts").

	Chat Log: this server's recent chat, newest first. Search box (words
	and/or player:<name>), "Hide commands" chip, Clear (;clearchatlog, needs
	moderation.chatlog). Refreshes every 3 s while the page is visible.
	Data: GetChatLogRemote(query, limit) -> { Lines, Total, CanClear }.

	Alerts: high / critical risk and mass commands, environment changes,
	flagged players joining (Systems/AlertService). Chips All / Critical /
	Warning / Commands / Joins, Clear (;clearalerts, moderation.alerts).
	Data: GetAlertsRemote(limit) -> { Alerts, CanClear }; live from
	AlertRemote ("alert", entry) / ("clear").

	Stable instance names (Studio MCP tests):
		ChatLog:  Toolbar.{Search, Chip_Commands, Refresh, Clear}, Status,
		          List.Line_<id>.{Time, Who, Text}
		Alerts:   Toolbar.{Chip_<filter>, Clear}, Status, List.Alert_<id>

	Public API:
		StaffFeedsPage.BuildChatLog(container)
		StaffFeedsPage.BuildAlerts(container)
		StaffFeedsPage.Unread() -> number, StaffFeedsPage.Changed (BindableEvent)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local StaffFeedsPage = {}

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

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

local function chip(parent: Instance, name: string, value: string, color: Color3?): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = Theme.Font.Medium,
		TextSize = 13,
		TextColor3 = if color then Color3.new(1, 1, 1) else Theme.Colors.Text,
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

local function header(container: Frame, title: string, sub: string): (Frame, TextLabel, ScrollingFrame)
	label(container, "Header", title, { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", sub, { Position = UDim2.new(0, 0, 0, 28), TextColor3 = Theme.Colors.TextSecondary })
	local toolbar = make("Frame", {
		Name = "Toolbar",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 54),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, toolbar)
	local status = label(container, "Status", "Loading...", { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, container)
	Theme.corner(list, Theme.Radius.M)
	make("UIListLayout", { Padding = UDim.new(0, 2) }, list)
	make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, list)
	-- Status + list sit below the toolbar, whose height depends on wrapping.
	local function place()
		-- AbsoluteSize includes the panel's UIScale (Root.Scale); offsets don't.
		local scale = 1
		local node: Instance? = container
		while node do
			local s = node:FindFirstChildOfClass("UIScale")
			if s and s.Scale > 0 then
				scale = s.Scale
				break
			end
			node = node.Parent
		end
		local y = 54 + toolbar.AbsoluteSize.Y / scale + 6
		status.Position = UDim2.new(0, 0, 0, y)
		list.Position = UDim2.new(0, 0, 0, y + 22)
		list.Size = UDim2.new(1, 0, 1, -(y + 22))
	end
	toolbar:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	task.defer(place)
	return toolbar, status, list
end

local function clockText(t: number): string
	return os.date("%H:%M:%S", t) :: string
end

local function send(text: string)
	local remote = SentinelShared:FindFirstChild("ExecuteCommandRemote")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(text)
	end
end

local function visible(container: GuiObject): boolean
	local node: Instance? = container
	while node and node:IsA("GuiObject") do
		if not node.Visible then
			return false
		end
		node = node.Parent
	end
	return true
end

-- ===========================================================================
-- Chat Log
-- ===========================================================================
function StaffFeedsPage.BuildChatLog(container: Frame)
	local remote = SentinelShared:WaitForChild("GetChatLogRemote", 15) :: RemoteFunction?
	local toolbar, status, list = header(container, "Chat Log", "Recent chat in this server, newest first. Filter by words or player:<name>.")

	local search = make("TextBox", {
		Name = "Search",
		Size = UDim2.fromOffset(240, 30),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "Search chat or player:name",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClipsDescendants = true,
		Text = "",
	}, toolbar) :: TextBox
	Theme.corner(search, Theme.Radius.Pill)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, search)

	local hideCommands = false
	local commandsChip = chip(toolbar, "Chip_Commands", "Hide commands")
	local refresh = chip(toolbar, "Refresh", "Refresh")
	local clear = chip(toolbar, "Clear", "Clear log", Theme.Colors.Error)
	clear.Visible = false

	local lastKey = ""
	local function render(data: any)
		local lines = if type(data) == "table" and type(data.Lines) == "table" then data.Lines else {}
		local shown = {}
		for _, line in ipairs(lines) do
			if not (hideCommands and line.Command) then
				table.insert(shown, line)
			end
		end
		local key = ("%d:%s:%s"):format(#shown, if shown[1] then tostring(shown[1].Id) else "-", tostring(hideCommands))
		clear.Visible = type(data) == "table" and data.CanClear == true
		status.Text = ("%d line%s shown (%d kept on this server)"):format(#shown, if #shown == 1 then "" else "s", if type(data) == "table" then tonumber(data.Total) or 0 else 0)
		if key == lastKey then
			return
		end
		lastKey = key
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if #shown == 0 then
			label(list, "Empty", "No chat yet.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		for _, line in ipairs(shown) do
			local row = make("Frame", { Name = "Line_" .. tostring(line.Id), BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, list)
			label(row, "Time", clockText(tonumber(line.Time) or 0), { Size = UDim2.fromOffset(64, 18), Font = Theme.Font.Mono, TextSize = 12, TextColor3 = Theme.Colors.TextSecondary })
			local who = label(row, "Who", tostring(line.DisplayName) .. " (@" .. tostring(line.Name) .. ")", {
				Position = UDim2.fromOffset(68, 0),
				Size = UDim2.fromOffset(190, 18),
				Font = Theme.Font.Bold,
				TextSize = 13,
				TextColor3 = if line.Command then Theme.Colors.Warning else Theme.Colors.Accent,
			})
			who.TextTruncate = Enum.TextTruncate.AtEnd
			label(row, "Text", tostring(line.Text), {
				Position = UDim2.fromOffset(264, 0),
				Size = UDim2.new(1, -264, 0, 18),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				TextColor3 = if line.Command then Theme.Colors.TextSecondary else Theme.Colors.Text,
			})
		end
	end

	local function load()
		if not remote then
			status.Text = "Chat log unavailable."
			return
		end
		local ok, data = pcall(function()
			return (remote :: RemoteFunction):InvokeServer(search.Text, 150)
		end)
		if ok and data then
			render(data)
		end
	end

	commandsChip.MouseButton1Click:Connect(function()
		hideCommands = not hideCommands
		setChip(commandsChip, hideCommands)
		lastKey = ""
		load()
	end)
	refresh.MouseButton1Click:Connect(load)
	search.FocusLost:Connect(function()
		lastKey = ""
		load()
	end)
	clear.MouseButton1Click:Connect(function()
		send("clearchatlog")
		task.delay(0.5, function()
			lastKey = ""
			load()
		end)
	end)

	task.spawn(function()
		while container.Parent do
			if visible(container) then
				load()
			end
			task.wait(3)
		end
	end)
end

-- ===========================================================================
-- Alerts
-- ===========================================================================
local SEVERITY_COLORS = {
	critical = Color3.fromRGB(235, 87, 87),
	warning = Color3.fromRGB(240, 180, 60),
	info = Color3.fromRGB(64, 156, 255),
}
local FILTERS = {
	{ "All", "all" },
	{ "Critical", "critical" },
	{ "Warning", "warning" },
	{ "Commands", "command" },
	{ "Joins", "join" },
}

local changed = Instance.new("BindableEvent")
StaffFeedsPage.Changed = changed
local unread = 0

function StaffFeedsPage.Unread(): number
	return unread
end

function StaffFeedsPage.BuildAlerts(container: Frame)
	local remote = SentinelShared:WaitForChild("GetAlertsRemote", 15) :: RemoteFunction?
	local push = SentinelShared:WaitForChild("AlertRemote", 15) :: RemoteEvent?
	local toolbar, status, list = header(container, "Alerts", "High-risk and mass commands, time / weather changes and flagged players joining this server.")

	local filter = "all"
	local chips: { [string]: TextButton } = {}
	for _, f in ipairs(FILTERS) do
		local b = chip(toolbar, "Chip_" .. f[1], f[1])
		chips[f[2]] = b
		b.MouseButton1Click:Connect(function()
			filter = f[2]
			for key, other in pairs(chips) do
				setChip(other, key == filter)
			end
			render()
		end)
	end
	setChip(chips.all, true)
	local clear = chip(toolbar, "Clear", "Clear alerts", Theme.Colors.Error)
	clear.Visible = false

	local alerts: { any } = {}
	local render: () -> ()

	local function row(a: any)
		local color = SEVERITY_COLORS[a.Severity] or Theme.Colors.TextSecondary
		local f = make("Frame", {
			Name = "Alert_" .. tostring(a.Id),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, list)
		Theme.corner(f, Theme.Radius.S)
		make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 10) }, f)
		make("UIListLayout", { Padding = UDim.new(0, 2) }, f)
		label(f, "Title", ("%s  -  %s"):format(tostring(a.Severity):upper(), tostring(a.Title)), { Font = Theme.Font.Bold, TextColor3 = color })
		if a.Text and a.Text ~= "" then
			label(f, "Text", tostring(a.Text), { TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = Theme.Colors.Text })
		end
		label(f, "Meta", ("%s  |  %s"):format(clockText(tonumber(a.Time) or 0), tostring(a.Kind)), { TextSize = 11, TextColor3 = Theme.Colors.TextSecondary })
		local stroke = Instance.new("UIStroke")
		stroke.Color = color
		stroke.Transparency = 0.6
		stroke.Thickness = 1
		stroke.Parent = f
	end

	function render()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local n = 0
		for _, a in ipairs(alerts) do
			if filter == "all" or a.Severity == filter or a.Kind == filter then
				n += 1
				if n <= 100 then
					row(a)
				end
			end
		end
		status.Text = ("%d alert%s"):format(n, if n == 1 then "" else "s")
		if n == 0 then
			label(list, "Empty", "No alerts.", { TextColor3 = Theme.Colors.TextSecondary })
		end
	end

	local function load()
		if not remote then
			status.Text = "Alerts unavailable."
			return
		end
		local ok, data = pcall(function()
			return (remote :: RemoteFunction):InvokeServer(200)
		end)
		if ok and type(data) == "table" then
			alerts = if type(data.Alerts) == "table" then data.Alerts else {}
			clear.Visible = data.CanClear == true
			render()
		end
	end

	clear.MouseButton1Click:Connect(function()
		send("clearalerts")
	end)

	if push then
		push.OnClientEvent:Connect(function(kind: string, entry: any)
			if kind == "clear" then
				alerts = {}
				unread = 0
			elseif kind == "alert" and type(entry) == "table" then
				table.insert(alerts, 1, entry)
				while #alerts > 200 do
					table.remove(alerts)
				end
				if not visible(container) then
					unread += 1
				end
			end
			changed:Fire(unread)
			render()
		end)
	end

	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			unread = 0
			changed:Fire(unread)
		end
	end)

	task.spawn(load)
end

return StaffFeedsPage
