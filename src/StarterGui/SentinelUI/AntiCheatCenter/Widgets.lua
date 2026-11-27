--!strict
--[[
	Widgets.lua (Sentinel AntiCheat - Control Center)

	Purpose:
		Building blocks for the Anti-Cheat Control Center pages, on top of
		Sentinel's Theme: labels, buttons that are disabled with a tooltip
		when the viewer lacks the permission node, chips, cards, text boxes,
		select menus, a data table (column sorting, text filter, 50-row
		pages, empty and loading states, row selection, right-click),
		sparkline and bar charts, a modal form and a copy box.

	Public API:
		Widgets.Init(screenGui, can)      -- tooltip / modal layer + permission table
		Widgets.SetCan(can)               -- { View, Review, Exempt, Act, Ban, Config, Master }
		Widgets.make(class, props, parent?)
		Widgets.list(frame, direction, padding, align?)  -> UIListLayout
		Widgets.label(parent, text, opts?)
		Widgets.button(parent, text, opts?)  opts = { Name, Kind = "primary"|"danger"|"ghost"|"soft",
		    Need = "Config" (permission key), OnClick, Width, Height, LayoutOrder, Tooltip }
		Widgets.chip(parent, text, active, onClick, opts?) -> button (SetActive(b, on))
		Widgets.card(parent, title, value, opts?) -> frame (SetCard(card, value, sub?))
		Widgets.textbox(parent, placeholder, opts?) -> TextBox
		Widgets.select(parent, options, current, onChange, opts?) -> button (SetSelect(b, value))
		Widgets.menu(position, items)      -- items = { { Text, Need?, OnClick } }
		Widgets.Table(parent, config) -> table object (SetRows, SetLoading, Selected, ...)
		Widgets.sparkline(parent, values, opts?) / Widgets.bars(parent, entries, opts?)
		Widgets.form(title, fields, onSubmit, opts?)   -- modal; fields { Key, Label, Kind, Choices, Default, Required }
		Widgets.copyBox(title, text)
		Widgets.tooltip(guiObject, text)
		Widgets.ago(time) / Widgets.clock(time)
--]]

local GuiService = game:GetService("GuiService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))

local Widgets = {}

local gui: ScreenGui? = nil
local tooltipLabel: TextLabel? = nil
local menuFrame: Frame? = nil
local can: { [string]: boolean } = {}

local NODE_NAMES = {
	View = "anticheat.view",
	Review = "anticheat.review",
	Exempt = "anticheat.exempt",
	Act = "anticheat.act",
	Ban = "anticheat.ban",
	Config = "anticheat.config",
	Master = "anticheat.master",
}
Widgets.NODE_NAMES = NODE_NAMES

function Widgets.make(className: string, props: { [string]: any }?, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		(inst :: any)[k] = v
	end
	if (inst :: any):IsA("GuiObject") and (props == nil or props.BorderSizePixel == nil) then
		(inst :: any).BorderSizePixel = 0
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end
local make = Widgets.make

function Widgets.list(frame: Instance, direction: Enum.FillDirection?, padding: number?, align: Enum.HorizontalAlignment?): UIListLayout
	local layout = make("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, padding or 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	}, frame)
	return layout
end

function Widgets.Init(screenGui: ScreenGui, permissions: { [string]: boolean }?)
	gui = screenGui
	can = permissions or {}
	tooltipLabel = make("TextLabel", {
		Name = "Tooltip",
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		TextColor3 = Theme.Colors.Text,
		Font = Theme.Font.Medium,
		TextSize = 13,
		Visible = false,
		ZIndex = 200,
		Text = "",
	}, screenGui)
	Theme.corner(tooltipLabel :: any, Theme.Radius.S)
	Theme.padding(tooltipLabel :: any, 6)
	Theme.stroke(tooltipLabel :: any)
end

function Widgets.SetCan(permissions: { [string]: boolean })
	can = permissions or {}
end

function Widgets.Can(need: string?): boolean
	return need == nil or can[need] == true
end

-- Screen (mouse) coordinates -> Position offsets inside the ScreenGui.
-- Mouse coordinates include Roblox's top bar; AbsolutePosition does not.
function Widgets.toLocal(screenPos: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	local origin = if gui then (gui :: ScreenGui).AbsolutePosition else Vector2.zero
	return screenPos - inset - origin
end

-- A GuiObject's AbsolutePosition -> screen (mouse) coordinates.
function Widgets.toScreen(absolute: Vector2): Vector2
	return absolute + GuiService:GetGuiInset()
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------
local function placeTooltip()
	local label = tooltipLabel
	if not label or not label.Visible or not gui then
		return
	end
	local p = Widgets.toLocal(UserInputService:GetMouseLocation())
	label.Position = UDim2.fromOffset(p.X + 14, p.Y + 18)
end

function Widgets.hideTooltip()
	if tooltipLabel then
		tooltipLabel.Visible = false
	end
end

function Widgets.tooltip(object: GuiObject, text: string | () -> string)
	object.MouseEnter:Connect(function()
		local label = tooltipLabel
		if not label then
			return
		end
		local value = if type(text) == "function" then text() else text
		if value == "" then
			return
		end
		label.Text = value
		label.Visible = true
		placeTooltip()
	end)
	object.MouseMoved:Connect(placeTooltip)
	local function hide()
		if tooltipLabel then
			tooltipLabel.Visible = false
		end
	end
	object.MouseLeave:Connect(hide)
	-- A click often opens a dialog on top, and then MouseLeave never fires:
	-- hide on press, and when the object goes away.
	object.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.Touch then
			hide()
		end
	end)
	object.Destroying:Connect(hide)
end

-- ---------------------------------------------------------------------------
-- Basic widgets
-- ---------------------------------------------------------------------------
function Widgets.label(parent: Instance, text: string, opts: any?): TextLabel
	local o = opts or {}
	local label = make("TextLabel", {
		Name = o.Name or "Label",
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = o.Color or Theme.Colors.Text,
		Font = if o.Bold then Theme.Font.Bold elseif o.Medium then Theme.Font.Medium else Theme.Font.Regular,
		TextSize = o.TextSize or 14,
		TextXAlignment = o.XAlign or Enum.TextXAlignment.Left,
		TextYAlignment = o.YAlign or Enum.TextYAlignment.Center,
		TextWrapped = o.Wrap == true,
		RichText = o.Rich == true,
		TextTruncate = if o.Wrap then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
		Size = o.Size or UDim2.new(1, 0, 0, (o.TextSize or 14) + 8),
		AutomaticSize = o.AutoY and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		LayoutOrder = o.LayoutOrder or 0,
	}, parent)
	return label
end

local KIND_COLORS = {
	primary = function()
		return Theme.Colors.Accent, Color3.new(1, 1, 1)
	end,
	danger = function()
		return Theme.Colors.Error, Color3.new(1, 1, 1)
	end,
	soft = function()
		return Theme.Colors.SurfaceRaised, Theme.Colors.Text
	end,
	ghost = function()
		return Theme.Colors.Surface, Theme.Colors.TextSecondary
	end,
}

-- A button; when opts.Need names a permission the viewer lacks it is shown
-- dimmed, ignores clicks and explains why in its tooltip. The server checks
-- the same node again, so this is only a courtesy.
function Widgets.button(parent: Instance, text: string, opts: any?): TextButton
	local o = opts or {}
	local bg, fg = (KIND_COLORS[o.Kind or "soft"] or KIND_COLORS.soft)()
	local width = o.Width
	if not width then
		width = TextService:GetTextSize(text, 14, Theme.Font.Medium, Vector2.new(1000, 40)).X + 24
	end
	local button = make("TextButton", {
		Name = o.Name or (text:gsub("[^%w]", "") .. "Button"),
		Text = text,
		Font = Theme.Font.Medium,
		TextSize = 14,
		TextColor3 = fg,
		BackgroundColor3 = bg,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(width, o.Height or 30),
		LayoutOrder = o.LayoutOrder or 0,
	}, parent)
	Theme.corner(button, Theme.Radius.S)
	local allowed = Widgets.Can(o.Need)
	if not allowed then
		button.AutoButtonColor = false
		button.BackgroundTransparency = 0.5
		button.TextTransparency = 0.5
		button:SetAttribute("Disabled", true)
	end
	local tip = if not allowed then ("Needs %s"):format(NODE_NAMES[o.Need] or tostring(o.Need)) else o.Tooltip
	if tip then
		Widgets.tooltip(button, tip)
	end
	button.Activated:Connect(function()
		if button:GetAttribute("Disabled") or not o.OnClick then
			return
		end
		o.OnClick(button)
	end)
	return button
end

function Widgets.SetActive(button: TextButton, active: boolean)
	button.BackgroundColor3 = if active then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
	button.TextColor3 = if active then Color3.new(1, 1, 1) else Theme.Colors.TextSecondary
	button:SetAttribute("Active", active)
end

function Widgets.chip(parent: Instance, text: string, active: boolean, onClick: (TextButton) -> (), opts: any?): TextButton
	local o = opts or {}
	local width = TextService:GetTextSize(text, 13, Theme.Font.Medium, Vector2.new(1000, 40)).X + 20
	local chip = make("TextButton", {
		Name = o.Name or ("Chip_" .. text:gsub("[^%w]", "")),
		Text = text,
		Font = Theme.Font.Medium,
		TextSize = 13,
		Size = UDim2.fromOffset(width, 26),
		AutoButtonColor = true,
		LayoutOrder = o.LayoutOrder or 0,
	}, parent)
	Theme.corner(chip, Theme.Radius.Pill)
	Widgets.SetActive(chip, active)
	chip.Activated:Connect(function()
		onClick(chip)
	end)
	return chip
end

function Widgets.card(parent: Instance, title: string, value: string, opts: any?): Frame
	local o = opts or {}
	local card = make(if o.OnClick then "TextButton" else "Frame", {
		Name = o.Name or ("Card_" .. title:gsub("[^%w]", "")),
		BackgroundColor3 = Theme.Colors.Surface,
		Size = o.Size or UDim2.fromOffset(170, 74),
		LayoutOrder = o.LayoutOrder or 0,
	}, parent)
	if o.OnClick then
		card.Text = ""
		card.AutoButtonColor = true
		card.Activated:Connect(o.OnClick)
	end
	Theme.corner(card, Theme.Radius.M)
	Theme.stroke(card)
	Theme.padding(card, 10)
	Widgets.label(card, title, { Name = "Title", Color = Theme.Colors.TextSecondary, TextSize = 12, Size = UDim2.new(1, 0, 0, 16) })
	local v = Widgets.label(card, value, { Name = "Value", Bold = true, TextSize = 22, Size = UDim2.new(1, 0, 0, 28) })
	v.Position = UDim2.fromOffset(0, 16)
	local sub = Widgets.label(card, o.Sub or "", { Name = "Sub", Color = Theme.Colors.TextSecondary, TextSize = 11, Size = UDim2.new(1, 0, 0, 14) })
	sub.Position = UDim2.fromOffset(0, 42)
	if o.Tooltip then
		Widgets.tooltip(card :: any, o.Tooltip)
	end
	return card
end

function Widgets.SetCard(card: Instance, value: string, sub: string?, color: Color3?)
	local v = card:FindFirstChild("Value") :: TextLabel?
	if v then
		v.Text = value
		v.TextColor3 = color or Theme.Colors.Text
	end
	local s = card:FindFirstChild("Sub") :: TextLabel?
	if s and sub then
		s.Text = sub
	end
end

function Widgets.textbox(parent: Instance, placeholder: string, opts: any?): TextBox
	local o = opts or {}
	local box = make("TextBox", {
		Name = o.Name or "Box",
		PlaceholderText = placeholder,
		Text = o.Text or "",
		ClearTextOnFocus = false,
		Font = Theme.Font.Regular,
		TextSize = 14,
		TextColor3 = Theme.Colors.Text,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		BackgroundColor3 = Theme.Colors.SurfaceRaised, -- same as selects: visible on cards and modals
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = o.Multi == true,
		MultiLine = o.Multi == true,
		TextYAlignment = if o.Multi then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		Size = o.Size or UDim2.new(1, 0, 0, 30),
		LayoutOrder = o.LayoutOrder or 0,
	}, parent)
	Theme.corner(box, Theme.Radius.S)
	Theme.stroke(box)
	local pad = make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, if o.Multi then 6 else 0) }, box)
	local _ = pad
	return box
end

-- ---------------------------------------------------------------------------
-- Menus (context menu + select dropdown)
-- ---------------------------------------------------------------------------
function Widgets.closeMenu()
	if menuFrame then
		menuFrame:Destroy()
		menuFrame = nil
	end
end

-- position = screen position (absolute, as InputObject.Position / AbsolutePosition)
function Widgets.menu(position: Vector2, items: { any })
	Widgets.closeMenu()
	if not gui then
		return
	end
	local screen = gui :: ScreenGui
	local blocker = make("TextButton", {
		Name = "MenuBlocker",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 150,
	}, screen)
	blocker.Activated:Connect(Widgets.closeMenu)
	blocker.MouseButton2Click:Connect(Widgets.closeMenu)
	local holder = make("ScrollingFrame", {
		Name = "Menu",
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Size = UDim2.fromOffset(200, math.min(#items * 30 + 8, 320)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ZIndex = 151,
	}, blocker)
	Theme.corner(holder, Theme.Radius.S)
	Theme.stroke(holder)
	Theme.padding(holder, 4)
	Widgets.list(holder, nil, 0)
	local size = screen.AbsoluteSize
	local p = Widgets.toLocal(position)
	local x = math.clamp(p.X, 0, math.max(0, size.X - 204))
	local y = math.clamp(p.Y, 0, math.max(0, size.Y - holder.Size.Y.Offset - 4))
	holder.Position = UDim2.fromOffset(x, y)
	for i, item in ipairs(items) do
		local allowed = Widgets.Can(item.Need)
		local b = make("TextButton", {
			Name = "Item_" .. tostring(item.Text):gsub("[^%w]", ""),
			Text = "  " .. tostring(item.Text),
			Font = Theme.Font.Medium,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if allowed then (if item.Selected then Theme.Colors.Accent else Theme.Colors.Text) else Theme.Colors.TextSecondary,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			AutoButtonColor = allowed,
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = i,
			ZIndex = 152,
		}, holder)
		if not allowed then
			Widgets.tooltip(b, "Needs " .. (NODE_NAMES[item.Need] or tostring(item.Need)))
		end
		b.Activated:Connect(function()
			if not allowed then
				return
			end
			Widgets.closeMenu()
			item.OnClick()
		end)
	end
	menuFrame = blocker :: any
end

function Widgets.select(parent: Instance, options: { string }, current: string, onChange: (string) -> (), opts: any?): TextButton
	local o = opts or {}
	local button: TextButton
	button = Widgets.button(parent, tostring(current) .. "  v", {
		Name = o.Name or "Select",
		Width = o.Width or 150,
		Height = o.Height,
		LayoutOrder = o.LayoutOrder,
		Need = o.Need,
		Tooltip = o.Tooltip,
		OnClick = function()
			local items = {}
			for _, option in ipairs(options) do
				table.insert(items, {
					Text = option,
					Selected = option == button:GetAttribute("Value"),
					OnClick = function()
						Widgets.SetSelect(button, option)
						onChange(option)
					end,
				})
			end
			local p = Widgets.toScreen(button.AbsolutePosition)
			Widgets.menu(Vector2.new(p.X, p.Y + button.AbsoluteSize.Y + 2), items)
		end,
	})
	button.TextXAlignment = Enum.TextXAlignment.Left
	make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, button)
	button:SetAttribute("Value", current)
	return button
end

function Widgets.SetSelect(button: TextButton, value: string)
	button:SetAttribute("Value", value)
	button.Text = tostring(value) .. "  v"
end

-- ---------------------------------------------------------------------------
-- Time helpers
-- ---------------------------------------------------------------------------
function Widgets.ago(t: number?): string
	if type(t) ~= "number" then
		return "-"
	end
	local s = os.time() - t
	if s < 60 then
		return ("%ds ago"):format(math.max(0, s))
	elseif s < 3600 then
		return ("%dm ago"):format(s // 60)
	elseif s < 86400 then
		return ("%dh ago"):format(s // 3600)
	end
	return ("%dd ago"):format(s // 86400)
end

function Widgets.clock(t: number?): string
	if type(t) ~= "number" then
		return "-"
	end
	return os.date("%H:%M:%S", t) :: string
end

-- ---------------------------------------------------------------------------
-- Data table
-- ---------------------------------------------------------------------------
-- config = { Name, Columns = { { Key, Title, Width (scale 0-1), Format?(row)->string,
--   Color?(row)->Color3?, Sort?(row)->any, Bar?(row)->0..1 } }, PageSize = 50,
--   RowHeight = 30, Key = "Id", OnOpen?(row), OnContext?(row, position),
--   Multi = boolean (checkbox selection), Empty = "text", FilterPlaceholder }
function Widgets.Table(parent: Instance, config: any): any
	local self: any = {}
	local columns = config.Columns
	local pageSize = config.PageSize or 50
	local rowHeight = config.RowHeight or 30
	local keyField = config.Key or "Id"
	local rows: { any } = {}
	local view: { any } = {}
	local page = 1
	local sortKey: string? = config.SortKey
	local sortDesc = config.SortDesc ~= false
	local filterText = ""
	local selected: { [any]: boolean } = {}
	local cursor = 0
	local loading = false

	local root = make("Frame", {
		Name = config.Name or "Table",
		BackgroundTransparency = 1,
		Size = config.Size or UDim2.fromScale(1, 1),
		Position = config.Position or UDim2.new(),
		LayoutOrder = config.LayoutOrder or 0,
	}, parent)

	local filter = Widgets.textbox(root, config.FilterPlaceholder or "Filter rows...", { Name = "Filter", Size = UDim2.new(0.5, 0, 0, 28) })
	local info = Widgets.label(root, "", { Name = "Info", Color = Theme.Colors.TextSecondary, TextSize = 12, XAlign = Enum.TextXAlignment.Right, Size = UDim2.new(0.5, -6, 0, 28) })
	info.Position = UDim2.new(0.5, 6, 0, 0)

	local header = make("Frame", { Name = "Header", BackgroundColor3 = Theme.Colors.SurfaceRaised, Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 28) }, root)
	Theme.corner(header, Theme.Radius.S)
	local body = make("ScrollingFrame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 1, -64 - 34),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Colors.Border,
	}, root)
	Widgets.list(body, nil, 2)
	local state = Widgets.label(root, "", { Name = "State", Color = Theme.Colors.TextSecondary, XAlign = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 40) })
	state.Position = UDim2.fromOffset(0, 80)
	state.ZIndex = 3

	local footer = make("Frame", { Name = "Pager", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30) }, root)
	local prev = Widgets.button(footer, "Prev", { Name = "PrevButton", Width = 64, Height = 26 })
	local pageLabel = Widgets.label(footer, "", { Name = "PageLabel", XAlign = Enum.TextXAlignment.Center, Color = Theme.Colors.TextSecondary, TextSize = 12, Size = UDim2.new(1, -140, 0, 26) })
	pageLabel.Position = UDim2.fromOffset(70, 0)
	local nextB = Widgets.button(footer, "Next", { Name = "NextButton", Width = 64, Height = 26 })
	nextB.AnchorPoint = Vector2.new(1, 0)
	nextB.Position = UDim2.fromScale(1, 0)

	local function colText(col: any, row: any): string
		if col.Format then
			local ok, v = pcall(col.Format, row)
			return if ok then tostring(v) else "?"
		end
		local v = row[col.Key]
		if v == nil then
			return "-"
		end
		if type(v) == "number" and v % 1 ~= 0 then
			return ("%.2f"):format(v)
		end
		return tostring(v)
	end

	local function sortValue(col: any, row: any): any
		if col.Sort then
			return col.Sort(row)
		end
		local v = row[col.Key]
		if type(v) == "number" then
			return v
		end
		return tostring(colText(col, row)):lower()
	end

	local function rowKey(row: any): any
		return row[keyField] or row
	end

	local render: () -> ()

	-- Header buttons (click = sort; again = reverse).
	local x = 0
	local headerButtons = {}
	local offset = if config.Multi then 28 else 0
	for i, col in ipairs(columns) do
		local b = make("TextButton", {
			Name = "Col_" .. tostring(col.Key),
			Text = col.Title,
			Font = Theme.Font.Bold,
			TextSize = 12,
			TextColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundTransparency = 1,
			Position = UDim2.new(x, offset + 6, 0, 0),
			Size = UDim2.new(col.Width, -8, 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, header)
		headerButtons[i] = b
		b.Activated:Connect(function()
			if sortKey == col.Key then
				sortDesc = not sortDesc
			else
				sortKey = col.Key
				sortDesc = true
			end
			render()
		end)
		x += col.Width
	end
	if config.Multi then
		local all = make("TextButton", { Name = "SelectAll", Text = "[ ]", Font = Theme.Font.Bold, TextSize = 12, TextColor3 = Theme.Colors.TextSecondary, BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28) }, header)
		all.Activated:Connect(function()
			local start = (page - 1) * pageSize + 1
			local anyOff = false
			for i = start, math.min(#view, start + pageSize - 1) do
				if not selected[rowKey(view[i])] then
					anyOff = true
				end
			end
			for i = start, math.min(#view, start + pageSize - 1) do
				selected[rowKey(view[i])] = anyOff or nil
			end
			render()
		end)
	end

	local function rebuildView()
		view = {}
		local needle = filterText:lower()
		for _, row in ipairs(rows) do
			local keep = needle == ""
			if not keep then
				for _, col in ipairs(columns) do
					if colText(col, row):lower():find(needle, 1, true) then
						keep = true
						break
					end
				end
			end
			if keep then
				table.insert(view, row)
			end
		end
		if sortKey then
			local col
			for _, c in ipairs(columns) do
				if c.Key == sortKey then
					col = c
				end
			end
			if col then
				table.sort(view, function(a, b)
					local va, vb = sortValue(col, a), sortValue(col, b)
					if type(va) ~= type(vb) then
						va, vb = tostring(va), tostring(vb)
					end
					if sortDesc then
						return va > vb
					end
					return va < vb
				end)
			end
		end
	end

	render = function()
		rebuildView()
		local pages = math.max(1, math.ceil(#view / pageSize))
		page = math.clamp(page, 1, pages)
		for i, col in ipairs(columns) do
			headerButtons[i].Text = col.Title .. (if sortKey == col.Key then (if sortDesc then "  v" else "  ^") else "")
		end
		for _, child in ipairs(body:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local start = (page - 1) * pageSize + 1
		local stop = math.min(#view, start + pageSize - 1)
		for i = start, stop do
			local row = view[i]
			local key = rowKey(row)
			local isCursor = i - start + 1 == cursor
			local line = make("TextButton", {
				Name = "Row_" .. (i - start + 1),
				Text = "",
				AutoButtonColor = true,
				BackgroundColor3 = if selected[key] or isCursor then Theme.Colors.SurfaceRaised else Theme.Colors.Surface,
				Size = UDim2.new(1, -6, 0, rowHeight),
				LayoutOrder = i,
			}, body)
			Theme.corner(line, Theme.Radius.S)
			if isCursor then
				Theme.stroke(line, Theme.Colors.Accent)
			end
			if config.Multi then
				local box = make("TextButton", {
					Name = "Check",
					Text = if selected[key] then "[x]" else "[ ]",
					Font = Theme.Font.Bold,
					TextSize = 12,
					TextColor3 = if selected[key] then Theme.Colors.Accent else Theme.Colors.TextSecondary,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(28, rowHeight),
				}, line)
				box.Activated:Connect(function()
					selected[key] = if selected[key] then nil else true
					render()
				end)
			end
			local cx = 0
			for _, col in ipairs(columns) do
				local position = UDim2.new(cx, offset + 6, 0, 0)
				local size = UDim2.new(col.Width, -8, 1, 0)
				if col.Image then
					local img = make("ImageLabel", { Name = "Avatar", BackgroundColor3 = Theme.Colors.SurfaceRaised, Image = col.Image(row) or "", Position = position + UDim2.fromOffset(0, 2), Size = UDim2.fromOffset(rowHeight - 4, rowHeight - 4) }, line)
					Theme.corner(img, Theme.Radius.Pill)
				elseif col.Bar then
					local frac = math.clamp(tonumber(col.Bar(row)) or 0, 0, 1)
					local track = make("Frame", { Name = "Bar", BackgroundColor3 = Theme.Colors.Background, Position = position + UDim2.fromOffset(0, rowHeight / 2 - 5), Size = UDim2.new(col.Width, -50, 0, 10) }, line)
					Theme.corner(track, Theme.Radius.Pill)
					local fill = make("Frame", { BackgroundColor3 = if col.Color then col.Color(row) or Theme.Colors.Accent else Theme.Colors.Accent, Size = UDim2.fromScale(frac, 1) }, track)
					Theme.corner(fill, Theme.Radius.Pill)
					local v = Widgets.label(line, colText(col, row), { TextSize = 12, XAlign = Enum.TextXAlignment.Right, Size = UDim2.new(0, 38, 1, 0) })
					v.Position = UDim2.new(cx + col.Width, offset - 44, 0, 0)
				else
					local cell = Widgets.label(line, colText(col, row), {
						Name = "C_" .. tostring(col.Key),
						TextSize = 13,
						Color = if col.Color then (col.Color(row) or Theme.Colors.Text) else Theme.Colors.Text,
						Bold = col.Bold,
						Size = size,
					})
					cell.Position = position
				end
				cx += col.Width
			end
			line.Activated:Connect(function()
				cursor = i - start + 1
				if config.OnOpen then
					config.OnOpen(row)
				end
				render()
			end)
			line.MouseButton2Click:Connect(function()
				if config.OnContext then
					config.OnContext(row, UserInputService:GetMouseLocation())
				end
			end)
			-- Touch: long press opens the context menu.
			line.TouchLongPress:Connect(function(positions)
				if config.OnContext and positions[1] then
					config.OnContext(row, positions[1])
				end
			end)
		end
		local count = 0
		for _ in pairs(selected) do
			count += 1
		end
		info.Text = ("%d row(s)%s"):format(#view, if count > 0 then (" | %d selected"):format(count) else "")
		pageLabel.Text = ("Page %d of %d"):format(page, pages)
		prev.Visible = page > 1
		nextB.Visible = page < pages
		state.Visible = loading or #view == 0
		state.Text = if loading then "Loading..." elseif #rows == 0 then (config.Empty or "Nothing here yet.") else "No rows match the filter."
	end

	filter:GetPropertyChangedSignal("Text"):Connect(function()
		filterText = filter.Text
		page = 1
		cursor = 0
		render()
	end)
	prev.Activated:Connect(function()
		page -= 1
		cursor = 0
		render()
	end)
	nextB.Activated:Connect(function()
		page += 1
		cursor = 0
		render()
	end)

	function self.SetRows(list: { any })
		rows = list or {}
		loading = false
		-- Drop selections of rows that are gone.
		local keys = {}
		for _, r in ipairs(rows) do
			keys[rowKey(r)] = true
		end
		for k in pairs(selected) do
			if not keys[k] then
				selected[k] = nil
			end
		end
		render()
	end
	function self.SetLoading(on: boolean)
		loading = on
		render()
	end
	function self.SetFilter(text: string)
		filter.Text = text
	end
	function self.Selected(): { any }
		local out = {}
		for _, r in ipairs(rows) do
			if selected[rowKey(r)] then
				table.insert(out, r)
			end
		end
		if #out == 0 and cursor > 0 then
			local r = view[(page - 1) * pageSize + cursor]
			if r then
				table.insert(out, r)
			end
		end
		return out
	end
	function self.ClearSelection()
		table.clear(selected)
		render()
	end
	function self.Move(delta: number)
		local onPage = math.min(pageSize, #view - (page - 1) * pageSize)
		if onPage <= 0 then
			return
		end
		cursor = math.clamp(cursor + delta, 1, onPage)
		render()
	end
	function self.OpenCursor(): boolean
		local r = view[(page - 1) * pageSize + cursor]
		if r and cursor > 0 and config.OnOpen then
			config.OnOpen(r)
			return true
		end
		return false
	end
	function self.View(): { any }
		return view
	end
	function self.Columns(): { any }
		return columns
	end
	function self.CellText(col: any, row: any): string
		return colText(col, row)
	end
	self.Root = root
	render()
	return self
end

-- CSV text of a table's current (filtered, sorted) view.
function Widgets.csv(tableObject: any): string
	local cols = tableObject.Columns()
	local lines = {}
	local head = {}
	for _, c in ipairs(cols) do
		table.insert(head, c.Title)
	end
	table.insert(lines, table.concat(head, ","))
	for _, row in ipairs(tableObject.View()) do
		local cells = {}
		for _, c in ipairs(cols) do
			local text = tableObject.CellText(c, row):gsub('"', "'")
			table.insert(cells, '"' .. text .. '"')
		end
		table.insert(lines, table.concat(cells, ","))
	end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Charts
-- ---------------------------------------------------------------------------
-- Vertical bars, oldest left. opts = { Size, Color, Name, Labels? }
function Widgets.sparkline(parent: Instance, values: { number }, opts: any?): Frame
	local o = opts or {}
	local holder = make("Frame", { Name = o.Name or "Sparkline", BackgroundColor3 = Theme.Colors.Surface, Size = o.Size or UDim2.new(1, 0, 0, 70), LayoutOrder = o.LayoutOrder or 0 }, parent)
	Theme.corner(holder, Theme.Radius.M)
	Theme.padding(holder, 8)
	local max = 1
	for _, v in ipairs(values) do
		max = math.max(max, v)
	end
	local n = math.max(#values, 1)
	for i, v in ipairs(values) do
		local h = v / max
		local bar = make("Frame", {
			Name = "B" .. i,
			BackgroundColor3 = o.Color or Theme.Colors.Accent,
			BackgroundTransparency = if v == 0 then 0.8 else 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new((i - 1) / n, 1, 1, 0),
			Size = UDim2.new(1 / n, -2, math.max(h, 0.03), 0),
		}, holder)
		if o.Labels and o.Labels[i] then
			Widgets.tooltip(bar, o.Labels[i])
		end
	end
	return holder
end

-- Horizontal bars. entries = { { Label, Value, Color? } }
function Widgets.bars(parent: Instance, entries: { any }, opts: any?): Frame
	local o = opts or {}
	local holder = make("Frame", { Name = o.Name or "Bars", BackgroundColor3 = Theme.Colors.Surface, AutomaticSize = Enum.AutomaticSize.Y, Size = o.Size or UDim2.new(1, 0, 0, 0), LayoutOrder = o.LayoutOrder or 0 }, parent)
	Theme.corner(holder, Theme.Radius.M)
	Theme.padding(holder, 10)
	Widgets.list(holder, nil, 4)
	if o.Title then
		Widgets.label(holder, o.Title, { Bold = true, LayoutOrder = 0 })
	end
	local max = 1
	for _, e in ipairs(entries) do
		max = math.max(max, tonumber(e.Value) or 0)
	end
	if #entries == 0 then
		Widgets.label(holder, o.Empty or "No data yet.", { Color = Theme.Colors.TextSecondary, LayoutOrder = 1 })
	end
	for i, e in ipairs(entries) do
		local row = make("Frame", { Name = "Bar_" .. i, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = i }, holder)
		local l = Widgets.label(row, tostring(e.Label), { TextSize = 12, Size = UDim2.new(0.35, -6, 1, 0) })
		local _ = l
		local track = make("Frame", { BackgroundColor3 = Theme.Colors.Background, Position = UDim2.new(0.35, 0, 0.5, -6), Size = UDim2.new(0.5, 0, 0, 12) }, row)
		Theme.corner(track, Theme.Radius.Pill)
		local fill = make("Frame", { BackgroundColor3 = e.Color or o.Color or Theme.Colors.Accent, Size = UDim2.fromScale(math.clamp((tonumber(e.Value) or 0) / max, 0, 1), 1) }, track)
		Theme.corner(fill, Theme.Radius.Pill)
		local v = Widgets.label(row, if o.Format then o.Format(e.Value) else tostring(e.Value), { TextSize = 12, XAlign = Enum.TextXAlignment.Right, Size = UDim2.new(0.15, -4, 1, 0) })
		v.Position = UDim2.fromScale(0.85, 0)
	end
	return holder
end

-- ---------------------------------------------------------------------------
-- Modals
-- ---------------------------------------------------------------------------
local function modal(title: string, width: number?): (ScrollingFrame, () -> ())
	local screen = gui :: ScreenGui
	local backdrop = make("TextButton", {
		Name = "Modal",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 120,
	}, screen)
	-- The card scrolls once its content is taller than the space below the
	-- Roblox top bar, so long forms never push Save off screen.
	local inset = game:GetService("GuiService"):GetGuiInset().Y
	local cardWidth = math.min(width or 420, screen.AbsoluteSize.X - 24)
	local card = make("ScrollingFrame", {
		Name = "Card",
		BackgroundColor3 = Theme.Colors.Background,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, inset / 2),
		Size = UDim2.fromOffset(cardWidth, 120),
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 121,
	}, backdrop)
	Theme.corner(card, Theme.Radius.L)
	Theme.stroke(card)
	Theme.padding(card, 16)
	local layout = Widgets.list(card, nil, 8)
	local function fit()
		local content = layout.AbsoluteContentSize.Y + 32
		local maxH = math.max(160, screen.AbsoluteSize.Y - inset - 24)
		card.CanvasSize = UDim2.fromOffset(0, content)
		card.Size = UDim2.fromOffset(cardWidth, math.min(content, maxH))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	task.defer(fit)
	local heading = Widgets.label(card, title, { Name = "Title", Bold = true, TextSize = 17, LayoutOrder = 0 })
	local _ = heading
	fit()
	local function close()
		backdrop:Destroy()
	end
	return card, close
end
Widgets.modal = modal

-- fields = { { Key, Label, Kind = "text"|"multi"|"choice"|"number", Choices?, Default?, Required?, Placeholder? } }
-- onSubmit(values) may return a string error to keep the form open.
function Widgets.form(title: string, fields: { any }, onSubmit: (any) -> string?, opts: any?): () -> ()
	local o = opts or {}
	local card, close = modal(title, o.Width or 440)
	if o.Description then
		Widgets.label(card, o.Description, { Color = Theme.Colors.TextSecondary, Wrap = true, AutoY = true, LayoutOrder = 1, TextSize = 13 })
	end
	local getters = {}
	for i, f in ipairs(fields) do
		Widgets.label(card, f.Label .. (if f.Required then " *" else ""), { TextSize = 13, Color = Theme.Colors.TextSecondary, LayoutOrder = 10 + i * 2 })
		if f.Kind == "choice" then
			local value = f.Default or f.Choices[1]
			local sel = Widgets.select(card, f.Choices, value, function(v)
				value = v
			end, { Name = "Field_" .. f.Key, Width = 260, LayoutOrder = 11 + i * 2 })
			sel.ZIndex = 122
			getters[f.Key] = function()
				return value
			end
		else
			local box = Widgets.textbox(card, f.Placeholder or "", {
				Name = "Field_" .. f.Key,
				Text = if f.Default ~= nil then tostring(f.Default) else "",
				Multi = f.Kind == "multi",
				Size = if f.Kind == "multi" then UDim2.new(1, 0, 0, 120) else nil,
				LayoutOrder = 11 + i * 2,
			})
			getters[f.Key] = function()
				return box.Text
			end
		end
	end
	local errorLabel = Widgets.label(card, "", { Name = "Error", Color = Theme.Colors.Error, TextSize = 13, Wrap = true, AutoY = true, LayoutOrder = 900 })
	local row = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 1000 }, card)
	Widgets.list(row, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right)
	Widgets.button(row, "Cancel", { Name = "CancelButton", Kind = "ghost", OnClick = close, LayoutOrder = 1 })
	Widgets.button(row, o.SubmitText or "Save", {
		Name = "SubmitButton",
		Kind = o.Danger and "danger" or "primary",
		LayoutOrder = 2,
		OnClick = function()
			local values = {}
			for _, f in ipairs(fields) do
				local v = getters[f.Key]()
				if f.Required and (v == nil or tostring(v):gsub("%s", "") == "") then
					errorLabel.Text = f.Label .. " is required."
					return
				end
				values[f.Key] = v
			end
			local err = onSubmit(values)
			if type(err) == "string" then
				errorLabel.Text = err
			else
				close()
			end
		end,
	})
	for _, d in ipairs(card:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = 122
		end
	end
	return close
end

-- Roblox cannot write to the clipboard: show the text selected in a box
-- so staff copy it with Ctrl+C.
function Widgets.copyBox(title: string, text: string)
	local card, close = modal(title, 560)
	Widgets.label(card, "Select the text and press Ctrl+C (Cmd+C) to copy.", { Color = Theme.Colors.TextSecondary, TextSize = 13, LayoutOrder = 1 })
	local box = Widgets.textbox(card, "", { Name = "CopyText", Text = text, Multi = true, Size = UDim2.new(1, 0, 0, 260), LayoutOrder = 2 })
	box.TextEditable = false
	box.TextSize = 12
	box.Font = Theme.Font.Mono
	local row = make("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 3 }, card)
	Widgets.list(row, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right)
	Widgets.button(row, "Close", { Name = "CloseButton", Kind = "primary", OnClick = close })
	for _, d in ipairs(card:GetDescendants()) do
		if d:IsA("GuiObject") then
			d.ZIndex = 122
		end
	end
	task.defer(function()
		box:CaptureFocus()
		box.SelectionStart = 1
		box.CursorPosition = #text + 1
	end)
end

function Widgets.hasModal(): boolean
	return gui ~= nil and (gui :: ScreenGui):FindFirstChild("Modal") ~= nil
end

function Widgets.closeModal(): boolean
	local m = gui and (gui :: ScreenGui):FindFirstChild("Modal")
	if m then
		m:Destroy()
		return true
	end
	if menuFrame then
		Widgets.closeMenu()
		return true
	end
	return false
end

return Widgets
