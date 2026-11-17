--!strict
--[[
	AuditLogPage.lua (W11)

	Purpose:
		The persistent audit log of every server (Systems/AuditService):
			- query box using the ;logs syntax (mod: player: cmd: action:
			  sev: result: server: since: until: has:changes + free text)
			- quick filter chips: result, severity, time range, category,
			  this server only, changes only
			- newest-first rows; click a row for every recorded field
			  (targets + UserIds, reason, server, duration, source, message,
			  before / after values)
			- "Load older" pages through the store with the server's cursor
			- Export: copyable text of the loaded rows

	Reads SearchAuditLogRemote(query, cursor, limit) only.

	Stable instance names (Studio MCP tests):
		Body.QueryRow.{Query,Search,Export}
		Body.Chips.<Group>_<Value>          e.g. Chips.Result_Failed
		Body.List.Row_<n>.Header  (click; Row_<n>.Detail when expanded)
		Body.Footer.{LoadMore,Status}
		ExportModal.{Text,Close}
	Public API:
		AuditLogPage.Build(container)
		AuditLogPage.Search(query)   -- sets the query and runs it
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local AuditLogPage = {}

local PAGE_SIZE = 50

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

local function stamp(t: number): string
	return os.date("%m-%d %H:%M:%S", t) :: string
end

local function resultColor(result: string?): Color3
	if result == "Success" then
		return Theme.Colors.Success
	elseif result == "Denied" or result == "Cancelled" then
		return Theme.Colors.Warning
	end
	return Theme.Colors.Error
end

local function exportLine(e: any): string
	local parts = {
		os.date("!%Y-%m-%d %H:%M:%S", e.Timestamp or 0) .. "Z",
		tostring(e.ExecutorName) .. " (" .. tostring(e.Executor) .. ")",
		if e.RawInput then ";" .. e.RawInput else tostring(e.Command),
		tostring(e.Result),
		"sev " .. tostring(e.Severity),
	}
	if e.Target then
		table.insert(parts, "targets " .. e.Target .. (if e.TargetIds then " [" .. table.concat(e.TargetIds, ",") .. "]" else ""))
	end
	if e.Reason then
		table.insert(parts, "reason " .. e.Reason)
	end
	if e.Message then
		table.insert(parts, "msg " .. e.Message)
	end
	if type(e.Changes) == "table" then
		for _, c in ipairs(e.Changes) do
			table.insert(parts, ("%s%s: %s -> %s"):format(
				if c.Target then c.Target .. "." else "", tostring(c.Field), tostring(c.Before), tostring(c.After)
			))
		end
	end
	table.insert(parts, "server " .. tostring(e.Server))
	table.insert(parts, ("%sms"):format(tostring(e.ExecutionTimeMs or 0)))
	return table.concat(parts, " | ")
end

-- Chip groups: each chip adds query words. One active chip per group.
local GROUPS = {
	{ Id = "Result", Chips = { { "All", "" }, { "Failed", "result:failed" }, { "Denied", "result:denied" } } },
	{ Id = "Severity", Chips = { { "Any", "" }, { "Warning+", "sev:warning+" }, { "Error+", "sev:error+" } } },
	{ Id = "Range", Chips = { { "All time", "" }, { "1h", "since:1h" }, { "24h", "since:1d" }, { "7d", "since:7d" }, { "30d", "since:30d" } } },
	{
		Id = "Category",
		Chips = {
			{ "All", "" },
			{ "Moderation", "action:moderation" },
			{ "Economy", "action:economy" },
			{ "Player", "action:player,movement,effects" },
			{ "Ranks", "action:rank,ranks" },
			{ "Config", "action:config" },
			{ "Cross-server", "action:xs,crossserver" },
		},
	},
}

local api: any = {}

function AuditLogPage.Search(query: string)
	if api.Search then
		api.Search(query)
	end
end

function AuditLogPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local searchRemote = SentinelShared:WaitForChild("SearchAuditLogRemote", 15) :: RemoteFunction?

	label(container, "Header", "Audit Log", {
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
	})
	local statusLine = label(container, "SubHeader", "Every administrative action across all servers.", {
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = Theme.Colors.TextSecondary,
	})

	local body = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 1, -52),
	}, container)

	-- Query row --------------------------------------------------------------
	local queryRow = make("Frame", {
		Name = "QueryRow",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
	}, body)
	local queryBox = make("TextBox", {
		Name = "Query",
		Size = UDim2.new(1, -184, 1, 0),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Mono,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "mod:Alice player:Bob cmd:ban since:7d has:changes  free text...",
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
	local exportBtn = button(queryRow, "Export", "Export", 84)
	exportBtn.Position = UDim2.new(1, -84, 0, 0)

	-- Chips --------------------------------------------------------------------
	local chips = make("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 34),
		Size = UDim2.new(1, 0, 0, 22),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, body)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Wraps = true,
		Padding = UDim.new(0, 4),
	}, chips)

	local active: { [string]: string } = {}
	local chipButtons: { [string]: { [string]: TextButton } } = {}
	local toggles = { ThisServer = false, Changes = false }
	local serverId: string? = nil
	local refresh: (boolean) -> () -- forward

	local function paintChips()
		for groupId, buttons in pairs(chipButtons) do
			for value, b in pairs(buttons) do
				local on = if groupId == "Toggle" then toggles[value] else active[groupId] == value
				b.BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
				b.TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
			end
		end
	end

	local function chip(groupId: string, text: string, onClick: () -> ())
		local b = make("TextButton", {
			Name = groupId .. "_" .. text:gsub("[^%w%+]", ""),
			AutoButtonColor = true,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 0, 22),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Font = Theme.Font.Medium,
			TextSize = 11,
			TextColor3 = Theme.Colors.TextSecondary,
			Text = text,
		}, chips) :: TextButton
		Theme.corner(b, Theme.Radius.S)
		make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, b)
		b.Activated:Connect(onClick)
		return b
	end

	for gi, group in ipairs(GROUPS) do
		chipButtons[group.Id] = {}
		active[group.Id] = group.Chips[1][1]
		if gi > 1 then
			make("Frame", { Name = "Gap" .. gi, BackgroundTransparency = 1, Size = UDim2.new(0, 6, 0, 22) }, chips)
		end
		for _, c in ipairs(group.Chips) do
			local text = c[1]
			chipButtons[group.Id][text] = chip(group.Id, text, function()
				active[group.Id] = text
				paintChips()
				refresh(false)
			end)
		end
	end
	make("Frame", { Name = "GapT", BackgroundTransparency = 1, Size = UDim2.new(0, 6, 0, 22) }, chips)
	chipButtons.Toggle = {}
	chipButtons.Toggle.ThisServer = chip("Toggle", "This server", function()
		toggles.ThisServer = not toggles.ThisServer
		paintChips()
		refresh(false)
	end)
	chipButtons.Toggle.Changes = chip("Toggle", "Changes", function()
		toggles.Changes = not toggles.Changes
		paintChips()
		refresh(false)
	end)
	paintChips()

	-- List ---------------------------------------------------------------------
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 86),
		Size = UDim2.new(1, 0, 1, -122),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Colors.Border,
	}, body) :: ScrollingFrame
	Theme.corner(list, Theme.Radius.M)
	make("UIListLayout", { Padding = UDim.new(0, 2) }, list)
	Theme.padding(list, 6)

	-- The chip row wraps on narrow panels: keep the list below it.
	local function placeList()
		-- AbsoluteSize includes the panel's UIScale, offsets don't.
		local scale = math.max(0.01, queryRow.AbsoluteSize.Y / 28)
		local top = 34 + math.floor(chips.AbsoluteSize.Y / scale + 0.5) + 8
		list.Position = UDim2.new(0, 0, 0, top)
		list.Size = UDim2.new(1, 0, 1, -(top + 36))
	end
	chips:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeList)

	local footer = make("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 1, -28),
		Size = UDim2.new(1, 0, 0, 28),
	}, body)
	local loadMore = button(footer, "LoadMore", "Load older", 110)
	local footerStatus = label(footer, "Status", "", {
		Position = UDim2.new(0, 120, 0, 0),
		Size = UDim2.new(1, -120, 1, 0),
		TextColor3 = Theme.Colors.TextSecondary,
	})

	local entries: { any } = {}
	local cursor: any = nil
	local loading = false
	local expanded: { [string]: boolean } = {}

	local function esc(v: any): string
		return (tostring(v):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
	end

	local function detailText(e: any): string
		local lines = {
			("<b>Time</b>  %s (UTC %s)"):format(os.date("%Y-%m-%d %H:%M:%S", e.Timestamp), os.date("!%H:%M:%S", e.Timestamp)),
			("<b>Moderator</b>  %s  (UserId %s)"):format(esc(e.ExecutorName), esc(e.Executor)),
			("<b>Action</b>  %s   <b>Command</b>  %s"):format(esc(e.Action or e.Command), esc(e.Command)),
		}
		if e.RawInput then
			table.insert(lines, "<b>Input</b>  ;" .. esc(e.RawInput))
		end
		if e.Target then
			table.insert(lines, ("<b>Targets</b>  %s%s"):format(esc(e.Target), if e.TargetIds then "  (UserIds " .. table.concat(e.TargetIds, ", ") .. ")" else ""))
		end
		if e.Reason then
			table.insert(lines, "<b>Reason</b>  " .. esc(e.Reason))
		end
		table.insert(lines, ("<b>Result</b>  %s   <b>Severity</b>  %s   <b>Duration</b>  %s ms"):format(
			esc(e.Result), esc(e.Severity), esc(e.ExecutionTimeMs or 0)
		))
		table.insert(lines, ("<b>Server</b>  %s   <b>Source</b>  %s   <b>Id</b>  %s"):format(
			esc(if e.Server and e.Server ~= "" then e.Server else "?"), esc(e.Source or "-"), esc(e.Id or "-")
		))
		if e.Message then
			table.insert(lines, "<b>Message</b>  " .. esc(e.Message))
		end
		if type(e.Changes) == "table" and #e.Changes > 0 then
			table.insert(lines, "<b>Changes</b>")
			for _, c in ipairs(e.Changes) do
				table.insert(lines, ("   %s%s:  %s  -&gt;  %s"):format(
					if c.Target then esc(c.Target) .. " " else "", esc(c.Field), esc(c.Before), esc(c.After)
				))
			end
		end
		return table.concat(lines, string.char(10))
	end

	local function renderRows()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if #entries == 0 then
			label(list, "Empty", if loading then "Loading..." else "No log entries match.", {
				Size = UDim2.new(1, 0, 0, 30),
				TextColor3 = Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Center,
			})
			return
		end
		for i, e in ipairs(entries) do
			local key = e.Id or tostring(i)
			-- Row = Frame (list layout) holding the clickable Header and,
			-- when expanded, the Detail label.
			local row = make("Frame", {
				Name = "Row_" .. i,
				BackgroundColor3 = if i % 2 == 0 then Theme.Colors.Surface else Theme.Colors.SurfaceRaised,
				BackgroundTransparency = 0.2,
				Size = UDim2.new(1, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
			}, list)
			Theme.corner(row, Theme.Radius.S)
			make("UIListLayout", { Padding = UDim.new(0, 2) }, row)
			local header = make("TextButton", {
				Name = "Header",
				AutoButtonColor = false,
				Text = "",
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 24),
			}, row) :: TextButton
			make("Frame", {
				Name = "Result",
				BorderSizePixel = 0,
				BackgroundColor3 = resultColor(e.Result),
				Size = UDim2.new(0, 3, 0, 24),
			}, header)
			label(header, "Time", stamp(e.Timestamp or 0), {
				Position = UDim2.new(0, 8, 0, 0),
				Size = UDim2.new(0, 96, 0, 24),
				Font = Theme.Font.Mono,
				TextColor3 = Theme.Colors.TextSecondary,
			})
			label(header, "Who", tostring(e.ExecutorName), {
				Position = UDim2.new(0, 108, 0, 0),
				Size = UDim2.new(0.2, -10, 0, 24),
				Font = Theme.Font.Medium,
			})
			local summary = if e.RawInput then ";" .. e.RawInput else tostring(e.Command) .. (if e.Target then " -> " .. e.Target else "")
			if e.Reason and not (e.RawInput and e.RawInput:find(e.Reason, 1, true)) then
				summary ..= "  (" .. e.Reason .. ")"
			end
			if type(e.Changes) == "table" and #e.Changes > 0 then
				summary ..= ("  [%d change%s]"):format(#e.Changes, if #e.Changes == 1 then "" else "s")
			end
			label(header, "Summary", summary, {
				Position = UDim2.new(0.2, 100, 0, 0),
				Size = UDim2.new(0.8, -190, 0, 24),
				Font = Theme.Font.Mono,
			})
			label(header, "ResultText", tostring(e.Result), {
				Position = UDim2.new(1, -80, 0, 0),
				Size = UDim2.new(0, 74, 0, 24),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = resultColor(e.Result),
				Font = Theme.Font.Medium,
			})
			if expanded[key] then
				local detail = label(row, "Detail", detailText(e), {
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					TextWrapped = true,
					TextTruncate = Enum.TextTruncate.None,
					RichText = true,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextColor3 = Theme.Colors.TextSecondary,
				})
				make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, detail)
			end
			header.Activated:Connect(function()
				expanded[key] = not expanded[key]
				renderRows()
			end)
		end
	end

	local function buildQuery(): string
		local typed = queryBox.Text:match("^%s*(.-)%s*$") or ""
		local words = if typed ~= "" then { typed } else {}
		for _, group in ipairs(GROUPS) do
			for _, c in ipairs(group.Chips) do
				if active[group.Id] == c[1] and c[2] ~= "" then
					table.insert(words, c[2])
				end
			end
		end
		if toggles.ThisServer and serverId then
			table.insert(words, "server:" .. serverId)
		end
		if toggles.Changes then
			table.insert(words, "has:changes")
		end
		return table.concat(words, " ")
	end

	local function setStatus(found: any)
		local s = found and found.Status
		if s then
			serverId = s.ServerId
			statusLine.Text = ("%s  |  retention %s day(s)  |  this server %s, %d pending"):format(
				if s.Persistent then "Persistent store (all servers)" else "Memory only (this server)",
				tostring(s.RetentionDays or "-"),
				tostring(s.ServerId),
				s.Pending or 0
			)
		end
		footerStatus.Text = ("%d entr%s loaded%s%s"):format(
			#entries,
			if #entries == 1 then "y" else "ies",
			if cursor then "  -  older entries available" else "  -  end of log",
			if found and found.Error then "  -  " .. found.Error else ""
		)
		footerStatus.TextColor3 = if found and found.Error then Theme.Colors.Error else Theme.Colors.TextSecondary
		loadMore.Visible = cursor ~= nil
	end

	refresh = function(more: boolean)
		if loading or not searchRemote then
			return
		end
		loading = true
		if not more then
			entries = {}
			cursor = nil
			expanded = {}
			renderRows()
		end
		footerStatus.Text = "Loading..."
		local ok, found = pcall(function()
			return (searchRemote :: RemoteFunction):InvokeServer(buildQuery(), if more then cursor else nil, PAGE_SIZE)
		end)
		loading = false
		if not ok or type(found) ~= "table" then
			footerStatus.Text = "Could not load the log (try again in a moment)."
			footerStatus.TextColor3 = Theme.Colors.Error
			renderRows()
			return
		end
		local seen = {}
		for _, e in ipairs(entries) do
			if e.Id then
				seen[e.Id] = true
			end
		end
		for _, e in ipairs(found.Entries or {}) do
			if not (e.Id and seen[e.Id]) then
				table.insert(entries, e)
			end
		end
		cursor = found.Cursor
		renderRows()
		setStatus(found)
	end

	searchBtn.Activated:Connect(function()
		refresh(false)
	end)
	queryBox.FocusLost:Connect(function(enter)
		if enter then
			refresh(false)
		end
	end)
	loadMore.Activated:Connect(function()
		refresh(true)
	end)

	-- Export modal ---------------------------------------------------------------
	local modal = make("Frame", {
		Name = "ExportModal",
		Visible = false,
		ZIndex = 20,
		BackgroundColor3 = Theme.Colors.Background,
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, 0, 1, 0),
	}, container)
	Theme.corner(modal, Theme.Radius.M)
	Theme.padding(modal, 10)
	label(modal, "Title", "Export - select all (Ctrl+A) and copy (Ctrl+C)", {
		Size = UDim2.new(1, -90, 0, 24),
		Font = Theme.Font.Bold,
		TextSize = 14,
		ZIndex = 21,
	})
	local closeBtn = button(modal, "Close", "Close", 80)
	closeBtn.Position = UDim2.new(1, -80, 0, 0)
	closeBtn.ZIndex = 21
	local exportScroll = make("ScrollingFrame", {
		Name = "Scroll",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 30),
		Size = UDim2.new(1, 0, 1, -30),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.XY,
		ScrollBarThickness = 6,
		ZIndex = 21,
	}, modal)
	local exportText = make("TextBox", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		ClearTextOnFocus = false,
		TextEditable = false,
		MultiLine = true,
		Font = Theme.Font.Mono,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 22,
		Text = "",
	}, exportScroll) :: TextBox
	Theme.padding(exportText, 6)
	-- the modal's own Name must stay "ExportModal" at container level
	modal.Parent = container

	exportBtn.Activated:Connect(function()
		local lines = { ("# Sentinel audit export  |  query: %s  |  %d entries"):format(buildQuery(), #entries) }
		for _, e in ipairs(entries) do
			table.insert(lines, exportLine(e))
		end
		local text = table.concat(lines, "\n")
		if #text > 190000 then
			text = text:sub(1, 190000) .. "\n# (cut: too long for one copy)"
		end
		exportText.Text = text
		modal.Visible = true
	end)
	closeBtn.Activated:Connect(function()
		modal.Visible = false
	end)

	api.Search = function(query: string)
		queryBox.Text = query
		refresh(false)
	end

	-- First load when the page is first shown.
	local loadedOnce = false
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible and not loadedOnce then
			loadedOnce = true
			refresh(false)
		end
	end)
	if container.Visible then
		loadedOnce = true
		task.defer(refresh, false)
	end
	placeList()
end

return AuditLogPage
