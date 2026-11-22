--!strict
--[[
	ReportsPage.lua (W14 - Reports & appeals)

	Two pages in the Moderation section, one module:
		Reports  queue (pending by default) with status / category chips and
		         a query box (;reports syntax), detail: reporter, target,
		         category, description, evidence (recent chat, position,
		         reporter + staff evidence), other reports about the same
		         player, internal notes. Actions: Claim, Unassign, Resolve /
		         Dismiss (note box text = resolution, "#12" links case 12),
		         Reopen, Open investigation case, Open linked case.
		Appeals  queue (pending by default) with status / type chips, detail:
		         player, punishment + case, appeal text, the player's other
		         cases, internal notes. Actions: Claim, Accept / Reject (note
		         box text = decision shown to the player), Open case.

	Reads SearchReportsRemote / GetReportRemote / SearchAppealsRemote /
	GetAppealRemote; every change is a normal command (;reportclaim,
	;reportresolve, ;appealaccept, ...) through ExecuteCommandRemote.
	Refreshes on ModerationQueueEvent and after command results.

	Stable instance names (Studio MCP tests), under each page container:
		QueryRow.{Query,Search}, Chips.<Group>_<Value>
		List.Item_<id>, Detail.{Back,Fields,Text,Evidence,Others,Notes,
		NoteRow.{NoteBox,Add,AddEvidence},Actions.<Name>}

	Public API:
		ReportsPage.Build({ Reports = Frame, Appeals = Frame }, openCase(id))
		ReportsPage.Open(kind, id)   kind "report" | "appeal"
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local ReportsPage = {}

local counter = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		counter += 1
		inst.LayoutOrder = counter
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

local function label(parent: Instance, name: string, text: string, props: { [string]: any }?): TextLabel
	local l = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
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

-- Wrapping paragraph that grows with its text.
local function para(parent: Instance, name: string, text: string, color: Color3?, size: number?): TextLabel
	return label(parent, name, text, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextColor3 = color or Theme.Colors.Text,
		TextSize = size or 12,
	})
end

local function button(parent: Instance, name: string, text: string, width: number?, accent: Color3?): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = accent or Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width or 80, 0, 26),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = if accent then Color3.new(1, 1, 1) else Theme.Colors.Text,
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

local function flow(parent: Instance, name: string): Frame
	local f = make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 4) }, f)
	return f
end

local function box(parent: Instance, name: string): Frame
	local f = make("Frame", {
		Name = name,
		BackgroundColor3 = Theme.Colors.Surface,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, parent)
	Theme.corner(f, Theme.Radius.S)
	Theme.padding(f, 8)
	make("UIListLayout", { Padding = UDim.new(0, 3) }, f)
	return f
end

local function clear(f: Instance)
	for _, c in ipairs(f:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function ago(t: number?): string
	if not t then
		return "?"
	end
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

local STATUS_COLOR = {
	Open = "Warning",
	InProgress = "Accent",
	Resolved = "Success",
	Dismissed = "TextSecondary",
	Pending = "Warning",
	Accepted = "Success",
	Rejected = "Error",
}
local function statusColor(status: string): Color3
	return (Theme.Colors :: any)[STATUS_COLOR[status] or "TextSecondary"] or Theme.Colors.TextSecondary
end

local api: { [string]: (number) -> () } = {}

function ReportsPage.Open(kind: string, id: number)
	local fn = api[kind]
	if fn then
		fn(id)
	end
end

-- ---------------------------------------------------------------------------
-- One queue page (reports or appeals)
-- ---------------------------------------------------------------------------
type Spec = {
	Kind: string, -- "report" | "appeal"
	Title: string,
	Subtitle: string,
	SearchRemote: string,
	GetRemote: string,
	ListKey: string, -- "Reports" | "Appeals"
	Chips: { { Group: string, Values: { { string } } } },
	Row: (any) -> (string, string, string), -- title, subtitle, status
	Detail: (any, Frame, (string) -> (), (string?) -> ()) -> (),
}

local function buildQueue(container: Frame, spec: Spec)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local searchRemote = SentinelShared:WaitForChild(spec.SearchRemote, 15) :: RemoteFunction?
	local getRemote = SentinelShared:WaitForChild(spec.GetRemote, 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local queueEvent = SentinelShared:WaitForChild("ModerationQueueEvent", 15) :: RemoteEvent?

	local function run(text: string)
		if executeRemote then
			executeRemote:FireServer(text, { Source = "panel" })
		end
	end

	label(container, "Header", spec.Title, { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	local statusLine = label(container, "SubHeader", spec.Subtitle, {
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = Theme.Colors.TextSecondary,
	})

	-- Filters ---------------------------------------------------------------
	local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 50), Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, container)
	make("UIListLayout", { Padding = UDim.new(0, 6) }, top)
	local queryRow = make("Frame", { Name = "QueryRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26) }, top)
	local query = make("TextBox", {
		Name = "Query",
		BackgroundColor3 = Theme.Colors.Surface,
		Size = UDim2.new(1, -86, 1, 0),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = if spec.Kind == "report" then "Search: player:Bob category:spam assignee:me #12 ..." else "Search: player:Bob type:ban assignee:me #3 ...",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, queryRow)
	Theme.corner(query, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, query)
	local searchBtn = button(queryRow, "Search", "Search", 80)
	searchBtn.Position = UDim2.new(1, -80, 0, 0)

	local chipState: { [string]: string } = {}
	local chipButtons: { [string]: { [string]: TextButton } } = {}
	local chipsRow = flow(top, "Chips")
	local refresh: () -> ()
	for _, group in ipairs(spec.Chips) do
		chipButtons[group.Group] = {}
		chipState[group.Group] = group.Values[1][1]
		for _, v in ipairs(group.Values) do
			local b = chip(chipsRow, group.Group .. "_" .. v[1], v[2])
			chipButtons[group.Group][v[1]] = b
			b.Activated:Connect(function()
				chipState[group.Group] = v[1]
				for key, other in pairs(chipButtons[group.Group]) do
					paint(other, key == v[1])
				end
				task.spawn(refresh)
			end)
		end
		chip(chipsRow, "Gap_" .. group.Group, " ").BackgroundTransparency = 1
		for key, b in pairs(chipButtons[group.Group]) do
			paint(b, key == chipState[group.Group])
		end
	end

	-- List + detail ---------------------------------------------------------
	local body = make("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 112), Size = UDim2.new(1, 0, 1, -112) }, container)
	local listFrame = make("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(0.4, -6, 1, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
	}, body)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, listFrame)
	local detail = make("ScrollingFrame", {
		Name = "Detail",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.4, 6, 0, 0),
		Size = UDim2.new(0.6, -6, 1, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
	}, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, detail)
	make("UIPadding", { PaddingRight = UDim.new(0, 6) }, detail)

	local selectedId: number? = nil
	local narrow = false
	-- The shell has a UIScale (Root.Scale): AbsoluteSize includes it,
	-- Size offsets don't.
	local function uiScale(): number
		local node: Instance? = container
		while node do
			local s = node:FindFirstChildOfClass("UIScale")
			if s then
				return s.Scale
			end
			node = node.Parent
		end
		return 1
	end

	local function relayout()
		local scale = math.max(uiScale(), 0.01)
		local w = container.AbsoluteSize.X / scale
		narrow = w > 0 and w < 620
		local offset = 50 + math.ceil(top.AbsoluteSize.Y / scale) + 8
		body.Position = UDim2.new(0, 0, 0, offset)
		body.Size = UDim2.new(1, 0, 1, -offset)
		if narrow then
			listFrame.Size = UDim2.new(1, 0, 1, 0)
			detail.Position = UDim2.new(0, 0, 0, 0)
			detail.Size = UDim2.new(1, 0, 1, 0)
			listFrame.Visible = selectedId == nil
			detail.Visible = selectedId ~= nil
		else
			listFrame.Size = UDim2.new(0.4, -6, 1, 0)
			detail.Position = UDim2.new(0.4, 6, 0, 0)
			detail.Size = UDim2.new(0.6, -6, 1, 0)
			listFrame.Visible = true
			detail.Visible = true
		end
	end
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	top:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	local function buildQuery(): string
		local parts = { query.Text }
		for group, value in pairs(chipState) do
			if value ~= "" then
				table.insert(parts, group:lower() .. ":" .. value)
			end
		end
		return table.concat(parts, " ")
	end

	local openDetail: (number) -> ()

	refresh = function()
		if not searchRemote then
			statusLine.Text = "Not available (remote missing)."
			return
		end
		local ok, found = pcall(function()
			return (searchRemote :: RemoteFunction):InvokeServer(buildQuery(), nil, 60)
		end)
		if not ok or type(found) ~= "table" then
			statusLine.Text = "Could not load the queue."
			return
		end
		if found.Error then
			statusLine.Text = found.Error
			return
		end
		local counts = found.Counts or {}
		local parts = {}
		for _, k in ipairs(if spec.Kind == "report" then { "Open", "InProgress", "Resolved", "Dismissed" } else { "Pending", "Accepted", "Rejected" }) do
			table.insert(parts, ("%s %d"):format(if k == "InProgress" then "In progress" else k, counts[k] or 0))
		end
		statusLine.Text = ("%d shown  ·  %s  ·  updated %s"):format(found.Total or 0, table.concat(parts, "  ·  "), os.date("%H:%M:%S") :: string)
		clear(listFrame)
		local items = found[spec.ListKey] or {}
		if #items == 0 then
			label(listFrame, "Empty", "Nothing here.", { TextColor3 = Theme.Colors.TextSecondary, Size = UDim2.new(1, 0, 0, 24) })
		end
		for _, item in ipairs(items) do
			local title, sub, status = spec.Row(item)
			local row = make("TextButton", {
				Name = "Item_" .. item.Id,
				AutoButtonColor = true,
				BackgroundColor3 = if item.Id == selectedId then Theme.Colors.SurfaceRaised else Theme.Colors.Surface,
				Size = UDim2.new(1, -4, 0, 46),
				Text = "",
			}, listFrame)
			Theme.corner(row, Theme.Radius.S)
			local bar = make("Frame", { Name = "Bar", BackgroundColor3 = statusColor(status), BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, -12), Position = UDim2.new(0, 4, 0, 6) }, row)
			Theme.corner(bar, UDim.new(1, 0))
			label(row, "Title", title, { Position = UDim2.new(0, 14, 0, 5), Size = UDim2.new(1, -100, 0, 18), Font = Theme.Font.Bold, TextSize = 13 })
			label(row, "Sub", sub, { Position = UDim2.new(0, 14, 0, 24), Size = UDim2.new(1, -20, 0, 16), TextColor3 = Theme.Colors.TextSecondary, TextSize = 11 })
			label(row, "Status", if status == "InProgress" then "In progress" else status, {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -8, 0, 5),
				Size = UDim2.new(0, 84, 0, 18),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = statusColor(status),
				Font = Theme.Font.Medium,
				TextSize = 11,
			})
			row.Activated:Connect(function()
				openDetail(item.Id)
			end)
		end
	end

	local function renderDetail(data: any)
		clear(detail)
		if narrow then
			local back = button(detail, "Back", "< Back to list", 120)
			back.Activated:Connect(function()
				selectedId = nil
				relayout()
			end)
		end
		if not data then
			label(detail, "Empty", "Select an item on the left.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		spec.Detail(data, detail, run, function(text: string?)
			statusLine.Text = text or statusLine.Text
		end)
	end

	openDetail = function(id: number)
		selectedId = id
		relayout()
		if not getRemote then
			return
		end
		local ok, data = pcall(function()
			return (getRemote :: RemoteFunction):InvokeServer(id)
		end)
		if selectedId ~= id then
			return
		end
		renderDetail(if ok then data else nil)
		for _, row in ipairs(listFrame:GetChildren()) do
			if row:IsA("TextButton") then
				row.BackgroundColor3 = if row.Name == "Item_" .. id then Theme.Colors.SurfaceRaised else Theme.Colors.Surface
			end
		end
	end
	api[spec.Kind] = function(id: number)
		openDetail(id)
	end

	searchBtn.Activated:Connect(function()
		task.spawn(refresh)
	end)
	query.FocusLost:Connect(function(enter)
		if enter then
			task.spawn(refresh)
		end
	end)

	local pending = false
	local function soon()
		if pending or not container.Visible then
			return
		end
		pending = true
		task.delay(0.6, function()
			pending = false
			refresh()
			if selectedId then
				openDetail(selectedId)
			end
		end)
	end
	if queueEvent then
		queueEvent.OnClientEvent:Connect(function(kind: any)
			if kind == spec.Kind then
				soon()
			end
		end)
	end
	if resultRemote then
		resultRemote.OnClientEvent:Connect(soon)
	end
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			task.spawn(refresh)
		end
	end)

	renderDetail(nil)
	relayout()
	task.spawn(refresh)
end

-- ---------------------------------------------------------------------------
-- Detail renderers
-- ---------------------------------------------------------------------------
local function fieldGrid(parent: Instance, rows: { { string } })
	local f = box(parent, "Fields")
	for _, r in ipairs(rows) do
		local line = make("Frame", { Name = "Field_" .. r[1]:gsub("%s", ""), BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) }, f)
		label(line, "Key", r[1], { Size = UDim2.new(0, 96, 1, 0), TextColor3 = Theme.Colors.TextSecondary })
		label(line, "Value", r[2], { Position = UDim2.new(0, 100, 0, 0), Size = UDim2.new(1, -100, 1, 0) })
	end
end

local function notesBox(parent: Instance, notes: { any }?)
	local f = box(parent, "Notes")
	label(f, "Title", "Staff discussion (internal)", { Font = Theme.Font.Bold })
	if not notes or #notes == 0 then
		label(f, "None", "No notes yet.", { TextColor3 = Theme.Colors.TextSecondary })
	end
	for i, n in ipairs(notes or {}) do
		para(f, "Note_" .. i, ("%s  ·  %s:  %s"):format(ago(n.At), tostring(n.By), tostring(n.Text)), nil, 12)
	end
end

local function noteRow(parent: Instance, withEvidence: boolean): (TextBox, TextButton, TextButton?)
	local row = make("Frame", { Name = "NoteRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26) }, parent)
	local w = if withEvidence then 176 else 86
	local noteBox = make("TextBox", {
		Name = "NoteBox",
		BackgroundColor3 = Theme.Colors.Surface,
		Size = UDim2.new(1, -w, 1, 0),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "Note, resolution or decision... (#12 links case 12)",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, row) :: TextBox
	Theme.corner(noteBox, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, noteBox)
	local add = button(row, "Add", "Add note", 80)
	add.Position = UDim2.new(1, -(w - 6), 0, 0)
	local ev: TextButton? = nil
	if withEvidence then
		ev = button(row, "AddEvidence", "Add evidence", 86)
		;(ev :: TextButton).Position = UDim2.new(1, -86, 0, 0)
	end
	return noteBox, add, ev
end

local function oneLine(text: string): string
	return (text:gsub("[\r\n]+", " "):gsub("&&", "&"))
end

local function reportDetail(r: any, detail: Frame, run: (string) -> (), _status: (string?) -> ())
	label(detail, "Title", ("Report #%d  ·  %s"):format(r.Id, if r.Status == "InProgress" then "In progress" else r.Status), {
		Font = Theme.Font.Bold,
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = statusColor(r.Status),
	})
	fieldGrid(detail, {
		{ "Reported", ("%s (%d)%s"):format(r.TargetName, r.TargetId, if r.TargetOnline then "  ·  in this server" else "") },
		{ "Reporter", ("%s (%d)"):format(r.ReporterName, r.ReporterId) },
		{ "Category", r.Category },
		{ "Assigned to", r.Assignee or "nobody" },
		{ "Linked case", if r.CaseId then "#" .. r.CaseId else "none" },
		{ "Server", tostring(r.Server or "?") },
		{ "Filed", ago(r.CreatedAt) },
		{ "Resolution", r.Resolution or "-" },
	})
	local textBox = box(detail, "Text")
	label(textBox, "Title", "What happened (reporter)", { Font = Theme.Font.Bold })
	para(textBox, "Body", r.Description or "")

	local ev = box(detail, "Evidence")
	label(ev, "Title", ("Evidence (%d)"):format(#(r.Evidence or {})), { Font = Theme.Font.Bold })
	local kinds = { chat = "Chat", position = "Position", reporter = "From reporter", staff = "Staff" }
	for i, e in ipairs(r.Evidence or {}) do
		local who = if e.By then " (" .. e.By .. ")" else ""
		para(ev, "Ev_" .. i, ("[%s] %s%s  ·  %s"):format(kinds[e.Kind] or e.Kind, e.Text, who, ago(e.At)), if e.Kind == "chat" then Theme.Colors.Text else Theme.Colors.TextSecondary, 12)
	end

	if r.OtherReports and #r.OtherReports > 0 then
		local others = box(detail, "Others")
		label(others, "Title", ("Other reports about %s (%d)"):format(r.TargetName, #r.OtherReports), { Font = Theme.Font.Bold })
		for _, o in ipairs(r.OtherReports) do
			local b = make("TextButton", {
				Name = "Other_" .. o.Id,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 16),
				Font = Theme.Font.Regular,
				TextSize = 12,
				TextColor3 = Theme.Colors.Accent,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = ("#%d  %s  ·  %s  ·  by %s  ·  %s"):format(o.Id, o.Category, o.Status, o.ReporterName, ago(o.CreatedAt)),
			}, others)
			b.Activated:Connect(function()
				ReportsPage.Open("report", o.Id)
			end)
		end
	end

	notesBox(detail, r.Notes)
	local noteBox, add, addEv = noteRow(detail, true)
	add.Activated:Connect(function()
		if noteBox.Text:match("%S") then
			run(("reportnote %d %s"):format(r.Id, oneLine(noteBox.Text)))
			noteBox.Text = ""
		end
	end)
	if addEv then
		addEv.Activated:Connect(function()
			if noteBox.Text:match("%S") then
				run(("reportevidence %d %s"):format(r.Id, oneLine(noteBox.Text)))
				noteBox.Text = ""
			end
		end)
	end

	local actions = flow(detail, "Actions")
	local pendingState = r.Status == "Open" or r.Status == "InProgress"
	if pendingState then
		button(actions, "Claim", "Claim", 70).Activated:Connect(function()
			run(("reportclaim %d"):format(r.Id))
		end)
		if r.Assignee then
			button(actions, "Unassign", "Unassign", 74).Activated:Connect(function()
				run(("reportassign %d none"):format(r.Id))
			end)
		end
		button(actions, "Resolve", "Resolve", 74, Theme.Colors.Success).Activated:Connect(function()
			run(oneLine(("reportresolve %d %s"):format(r.Id, noteBox.Text)))
			noteBox.Text = ""
		end)
		button(actions, "Dismiss", "Dismiss", 74).Activated:Connect(function()
			run(oneLine(("reportdismiss %d %s"):format(r.Id, noteBox.Text)))
			noteBox.Text = ""
		end)
		button(actions, "Investigate", "Open case", 84).Activated:Connect(function()
			run(("caseopen %d Report #%d: %s"):format(r.TargetId, r.Id, r.Category))
		end)
	else
		button(actions, "Reopen", "Reopen", 74).Activated:Connect(function()
			run(("reportstatus %d open"):format(r.Id))
		end)
	end
	if r.CaseId then
		button(actions, "OpenCase", "Case #" .. r.CaseId, 84).Activated:Connect(function()
			ReportsPage.OpenCase(r.CaseId)
		end)
	end
	para(detail, "Hint", "Resolve / Dismiss use the text box as the resolution; start it with #<case> to link the case you opened.", Theme.Colors.TextSecondary, 11)
end

local TYPE_LABEL = { ban = "Ban", mute = "Mute", jail = "Jail", warn = "Warning" }

local function appealDetail(a: any, detail: Frame, run: (string) -> (), _status: (string?) -> ())
	label(detail, "Title", ("Appeal #%d  ·  %s"):format(a.Id, a.Status), {
		Font = Theme.Font.Bold,
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 22),
		TextColor3 = statusColor(a.Status),
	})
	local c = a.Case
	fieldGrid(detail, {
		{ "Player", ("%s (%d)"):format(a.Name, a.UserId) },
		{ "Punishment", (TYPE_LABEL[a.Type] or a.Type) .. (if a.CaseId then ("  ·  case #%d"):format(a.CaseId) else "") },
		{ "Reason", a.PunishReason or "none" },
		{ "Punished by", a.PunishedBy or "?" },
		{ "Case status", if c then c.Status else "-" },
		{ "Sent from", if a.Source == "banscreen" then "ban screen" elseif a.Source == "form" then "appeal form" else tostring(a.Source or "?") },
		{ "Submitted", ago(a.CreatedAt) },
		{ "Assigned to", a.Assignee or "nobody" },
		{ "Decision", if a.ReviewerName then ("%s by %s: %s"):format(a.Status, a.ReviewerName, a.Decision or "-") else "-" },
	})
	local textBox = box(detail, "Text")
	label(textBox, "Title", "The player's appeal", { Font = Theme.Font.Bold })
	para(textBox, "Body", a.Text or "")

	if a.PlayerCases and #a.PlayerCases > 0 then
		local others = box(detail, "Others")
		label(others, "Title", ("%s's cases (%d)"):format(a.Name, #a.PlayerCases), { Font = Theme.Font.Bold })
		for _, pc in ipairs(a.PlayerCases) do
			local b = make("TextButton", {
				Name = "Case_" .. pc.Id,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 16),
				Font = Theme.Font.Regular,
				TextSize = 12,
				TextColor3 = Theme.Colors.Accent,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = ("#%d  %s  ·  %s  ·  %s  ·  %s"):format(pc.Id, pc.Type, pc.Status, pc.Reason or "no reason", ago(pc.CreatedAt)),
			}, others)
			b.Activated:Connect(function()
				ReportsPage.OpenCase(pc.Id)
			end)
		end
	end

	notesBox(detail, a.Notes)
	local noteBox, add = noteRow(detail, false)
	add.Activated:Connect(function()
		if noteBox.Text:match("%S") then
			run(("appealnote %d %s"):format(a.Id, oneLine(noteBox.Text)))
			noteBox.Text = ""
		end
	end)

	local actions = flow(detail, "Actions")
	if a.Status == "Pending" then
		button(actions, "Claim", "Claim", 70).Activated:Connect(function()
			run(("appealassign %d me"):format(a.Id))
		end)
		local accept = button(actions, "Accept", "Accept", 74, Theme.Colors.Success)
		local reject = button(actions, "Reject", "Reject", 74, Theme.Colors.Error)
		if a.CanDecide == false then
			accept.AutoButtonColor = false
			accept.BackgroundTransparency = 0.6
			reject.AutoButtonColor = false
			reject.BackgroundTransparency = 0.6
			para(detail, "CannotDecide", a.CannotDecideWhy or "You can't decide this appeal.", Theme.Colors.Warning, 11)
		else
			accept.Activated:Connect(function()
				run(oneLine(("appealaccept %d %s"):format(a.Id, noteBox.Text)))
				noteBox.Text = ""
			end)
			reject.Activated:Connect(function()
				run(oneLine(("appealreject %d %s"):format(a.Id, noteBox.Text)))
				noteBox.Text = ""
			end)
		end
	end
	if a.CaseId then
		button(actions, "OpenCase", "Case #" .. a.CaseId, 84).Activated:Connect(function()
			ReportsPage.OpenCase(a.CaseId)
		end)
	end
	para(detail, "Hint", "Accept lifts the punishment and revokes the case. The text box becomes the decision note the player sees.", Theme.Colors.TextSecondary, 11)
end

ReportsPage.OpenCase = function(_id: number) end

function ReportsPage.Build(containers: { Reports: Frame?, Appeals: Frame? }, openCase: ((number) -> ())?)
	if openCase then
		ReportsPage.OpenCase = openCase
	end
	if containers.Reports then
		buildQueue(containers.Reports, {
			Kind = "report",
			Title = "Reports",
			Subtitle = "Player reports waiting for staff.",
			SearchRemote = "SearchReportsRemote",
			GetRemote = "GetReportRemote",
			ListKey = "Reports",
			Chips = {
				{
					Group = "Status",
					Values = { { "pending", "Pending" }, { "open", "Open" }, { "inprogress", "In progress" }, { "resolved", "Resolved" }, { "dismissed", "Dismissed" }, { "all", "All" } },
				},
				{
					Group = "Assignee",
					Values = { { "", "Anyone" }, { "me", "Mine" }, { "none", "Unassigned" } },
				},
			},
			Row = function(r: any)
				return ("#%d  %s"):format(r.Id, r.TargetName),
					("%s  ·  by %s  ·  %s%s"):format(r.Category, r.ReporterName, ago(r.CreatedAt), if r.Assignee then "  ·  " .. r.Assignee else ""),
					r.Status
			end,
			Detail = reportDetail,
		})
	end
	if containers.Appeals then
		buildQueue(containers.Appeals, {
			Kind = "appeal",
			Title = "Appeals",
			Subtitle = "Punishment appeals waiting for review.",
			SearchRemote = "SearchAppealsRemote",
			GetRemote = "GetAppealRemote",
			ListKey = "Appeals",
			Chips = {
				{
					Group = "Status",
					Values = { { "pending", "Pending" }, { "accepted", "Accepted" }, { "rejected", "Rejected" }, { "all", "All" } },
				},
				{
					Group = "Type",
					Values = { { "", "Any" }, { "ban", "Bans" }, { "mute", "Mutes" }, { "warn", "Warnings" }, { "jail", "Jails" } },
				},
			},
			Row = function(a: any)
				return ("#%d  %s"):format(a.Id, a.Name),
					("%s%s  ·  %s%s"):format(TYPE_LABEL[a.Type] or a.Type, if a.CaseId then (" (case #%d)"):format(a.CaseId) else "", ago(a.CreatedAt), if a.Assignee then "  ·  " .. a.Assignee else ""),
					a.Status
			end,
			Detail = appealDetail,
		})
	end
end

return ReportsPage
