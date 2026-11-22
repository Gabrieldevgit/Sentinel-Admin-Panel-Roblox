--!strict
--[[
	AppearancePage.lua (UI redesign)

	Purpose:
		Where a staff member customises the panel (theme, accent, animations,
		size) and their command bar (look, position, width, opacity, text
		size, lines, suggestions, key). Every control saves straight away to
		their personal settings; the server answers on UIPrefsChangedRemote
		and init.client applies it live.

		Ranks with "config.ui" (Owner) also get "Make this the server
		default": everyone who hasn't chosen their own then gets this look.

	The rows are generated from Shared/UIPrefs (SPEC + ORDER), so a new
	setting added there shows up here without more code.

	Stable names: Body.Row_<Section>_<Field>.Controls.{Choice_<value>,
	Minus, Plus, Toggle}, Toolbar.{ResetMine, SaveDefault, ResetDefault,
	OpenBar}. Sound rows (Kind "sound"): Body.Row_Sounds_<Event>.Controls.
	{Prev, Value, Next, Play} and .Custom.{Link, Use}.

	The same generator builds the System > Sounds page (sound effects) with
	options { Sections = { "Sounds" }, Title = "Sounds" }; there
	"Use server default" only resets that page's sections.

	Public API:
		AppearancePage.Build(container, commandBar?, options?)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))
local SoundLibrary = require(SentinelShared:WaitForChild("SoundLibrary"))
local Icons = require(SentinelShared:WaitForChild("Icons"))
local SoundPlayer = require(script.Parent:WaitForChild("SoundPlayer"))

local AppearancePage = {}

local SECTION_TITLES = { Panel = "Panel", Layout = "Layout", CommandBar = "Command bar", Notifications = "Notifications", Sounds = "Sound effects" }
local FIELD_LABELS = {
	Theme = "Theme",
	Accent = "Accent colour",
	Animations = "Animations",
	Scale = "Panel size",
	Font = "Font",
	AnimationSpeed = "Animation speed",
	ReducedMotion = "Reduced motion",
	HighContrast = "High contrast",
	Toasts = "Pop-ups",
	Enabled = "Sound effects",
	Volume = "Volume",
	Success = "Success",
	Error = "Error",
	Warning = "Warning",
	Info = "Info",
	Duration = "Duration",
	Preset = "Look",
	Position = "Position",
	Width = "Width",
	Opacity = "Background",
	FontSize = "Text size",
	MaxLines = "Output lines",
	Rows = "Suggestions shown",
	Key = "Open key",
	Mode = "Window layout",
	Compact = "Compact mode",
	StatusBar = "Status bar",
	Labels = "Tab labels",
}

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
	elseif inst:IsA("UIListLayout") then
		inst.SortOrder = Enum.SortOrder.LayoutOrder
	end
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function button(parent: Instance, name: string, text: string, width: number, order: number): TextButton
	local b = make("TextButton", {
		Name = name,
		LayoutOrder = order,
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width, 0, 28),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

function AppearancePage.Build(container: Frame, commandBar: any?, options: any?)
	options = options or {}
	local sections: { string } = options.Sections or { "Panel", "Layout", "CommandBar", "Notifications" }
	local pageTitle: string = options.Title or "Appearance"
	local getRemote = SentinelShared:WaitForChild("GetUIPrefsRemote", 15) :: RemoteFunction
	local setRemote = SentinelShared:WaitForChild("SetUIPrefsRemote", 15) :: RemoteFunction
	local changedRemote = SentinelShared:WaitForChild("UIPrefsChangedRemote", 15) :: RemoteEvent

	local snapshot: any = nil

	local header = make("TextLabel", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = pageTitle,
	}, container)
	if options.Sections and Icons.Slots[pageTitle] then
		Icons.prefix(header, pageTitle, pageTitle, 22)
	end
	local status = make("TextLabel", {
		Name = "SubHeader",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "Changes are saved for you straight away.",
	}, container)

	-- W09: scrolls sideways in a narrow panel.
	local toolbar = make("ScrollingFrame", {
		Name = "Toolbar",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 54),
		Size = UDim2.new(1, 0, 0, 28),
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 0,
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, toolbar)

	local body = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 90),
		Size = UDim2.new(1, 0, 1, -90),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Border,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, container)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, body)

	local function say(text: string, ok: boolean?)
		status.Text = text
		status.TextColor3 = if ok == false then Theme.Colors.Error elseif ok then Theme.Colors.Success else Theme.Colors.TextSecondary
	end

	local function request(scope: string, prefs: any)
		task.spawn(function()
			local ok, result = pcall(function()
				return setRemote:InvokeServer(scope, prefs)
			end)
			if ok and type(result) == "table" then
				say(tostring(result.Message), result.Success == true)
			else
				say("Could not save - try again in a moment.", false)
			end
		end)
	end

	local function set(section: string, field: string, value: any)
		-- Show it at once; the server's answer confirms (or corrects) it.
		if snapshot then
			snapshot.Effective[section][field] = value
		end
		request("personal", { [section] = { [field] = value } })
	end

	local render: () -> ()
	local buildSoundControls: (Frame, Frame, string, string, any) -> ()

	local function buildToolbar()
		for _, child in ipairs(toolbar:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		button(toolbar, "ResetMine", "Use server default", 150, 1).MouseButton1Click:Connect(function()
			if options.Sections then
				for _, section in ipairs(sections) do
					request("reset", section)
				end
			else
				request("reset", nil)
			end
		end)
		if commandBar then
			button(toolbar, "OpenBar", "Open command bar", 150, 2).MouseButton1Click:Connect(function()
				commandBar.Open()
			end)
		end
		if snapshot and snapshot.CanSetDefaults then
			local save = button(toolbar, "SaveDefault", "Make this the server default", 210, 3)
			save.BackgroundColor3 = Theme.Colors.Accent
			save.MouseButton1Click:Connect(function()
				if snapshot then
					request("default", snapshot.Effective)
				end
			end)
			button(toolbar, "ResetDefault", "Reset server default", 160, 4).MouseButton1Click:Connect(function()
				request("resetdefault", nil)
			end)
		end
	end

	local function swatch(parent: Instance, color: Color3)
		-- the chip has 16px left padding; sit inside it
		local dot = make("Frame", { Name = "Swatch", BackgroundColor3 = color, Position = UDim2.new(0, -8, 0.5, -5), Size = UDim2.new(0, 10, 0, 10) }, parent)
		Theme.corner(dot, UDim.new(1, 0))
	end

	-- Custom theme: 7 hex colours, plus theme code export / import.
	local function buildCustomTheme(order: number)
		local effective = snapshot.Effective.Panel
		local current = UIPrefs.ResolvePalette(effective)
		local start = {}
		for _, key in ipairs(UIPrefs.PALETTE_KEYS) do
			start[key] = if type(effective.Custom) == "table" and effective.Custom[key]
				then effective.Custom[key]
				else UIPrefs.ColorToHex(current[key])
		end
		local block = make("Frame", {
			Name = "CustomTheme",
			LayoutOrder = order,
			BackgroundColor3 = Theme.Colors.Surface,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, body)
		Theme.corner(block, Theme.Radius.S)
		Theme.padding(block, 10)
		make("UIListLayout", { Padding = UDim.new(0, 6) }, block)
		make("TextLabel", {
			Name = "Title",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 18),
			Font = Theme.Font.Medium,
			TextSize = 13,
			TextColor3 = Theme.Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "CUSTOM THEME - IMPORT / EXPORT",
		}, block)
		local grid = make("Frame", {
			Name = "Colours",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, block)
		local gridLayout = Instance.new("UIGridLayout")
		gridLayout.CellSize = UDim2.new(0, 196, 0, 28)
		gridLayout.CellPadding = UDim2.new(0, 6, 0, 6)
		gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
		gridLayout.Parent = grid
		local boxes: { [string]: TextBox } = {}
		for i, key in ipairs(UIPrefs.PALETTE_KEYS) do
			local cell = make("Frame", { Name = "Colour_" .. key, LayoutOrder = i, BackgroundTransparency = 1 }, grid)
			local dot = make("Frame", {
				Name = "Swatch",
				BackgroundColor3 = UIPrefs.HexToColor(start[key]) or Color3.new(),
				Position = UDim2.new(0, 0, 0.5, -9),
				Size = UDim2.new(0, 18, 0, 18),
			}, cell)
			Theme.corner(dot, UDim.new(1, 0))
			Theme.stroke(dot, Theme.Colors.Border, 1)
			make("TextLabel", {
				Name = "Name",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 24, 0, 0),
				Size = UDim2.new(0, 94, 1, 0),
				Font = Theme.Font.Regular,
				TextSize = 11,
				TextColor3 = Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = key,
			}, cell)
			local box = make("TextBox", {
				Name = "Hex",
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				Position = UDim2.new(0, 120, 0, 0),
				Size = UDim2.new(0, 72, 1, 0),
				Font = Theme.Font.Mono,
				TextSize = 12,
				TextColor3 = Theme.Colors.Text,
				ClearTextOnFocus = false,
				Text = start[key],
			}, cell)
			Theme.corner(box, Theme.Radius.S)
			box:GetPropertyChangedSignal("Text"):Connect(function()
				local c = UIPrefs.HexToColor(box.Text)
				if c then
					dot.BackgroundColor3 = c
				end
			end)
			boxes[key] = box
		end
		local actions = make("Frame", { Name = "Actions", LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, block)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, actions)
		local codeBox: TextBox = make("TextBox", {
			Name = "Code",
			LayoutOrder = 4,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, 0, 0, 28),
			Font = Theme.Font.Mono,
			TextSize = 12,
			TextColor3 = Theme.Colors.Text,
			PlaceholderColor3 = Theme.Colors.TextSecondary,
			PlaceholderText = "Theme code: SNTL1-...",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
		}, block)
		Theme.corner(codeBox, Theme.Radius.S)
		local codePad = Instance.new("UIPadding")
		codePad.PaddingLeft = UDim.new(0, 8)
		codePad.Parent = codeBox

		local apply = button(actions, "UseCustom", "Use these colours", 140, 1)
		apply.BackgroundColor3 = Theme.Colors.Accent
		apply.MouseButton1Click:Connect(function()
			local custom = {}
			for _, key in ipairs(UIPrefs.PALETTE_KEYS) do
				local c = UIPrefs.HexToColor(boxes[key].Text)
				if not c then
					say(("%s is not a hex colour like 1A2B3C."):format(key), false)
					return
				end
				custom[key] = UIPrefs.ColorToHex(c)
			end
			request("personal", { Panel = { Theme = "Custom", Custom = custom } })
		end)
		button(actions, "Export", "Export current", 120, 2).MouseButton1Click:Connect(function()
			codeBox.Text = UIPrefs.EncodeTheme(UIPrefs.ResolvePalette(snapshot.Effective.Panel))
			say("Theme code ready: select it and copy (Ctrl+C).", true)
		end)
		button(actions, "Import", "Import code", 110, 3).MouseButton1Click:Connect(function()
			local custom, err = UIPrefs.DecodeTheme(codeBox.Text)
			if not custom then
				say("Import failed: " .. tostring(err) .. ".", false)
				return
			end
			request("personal", { Panel = { Theme = "Custom", Custom = custom } })
		end)
	end

	-- W09 sidebar customisation + favorite pages: section tab order and
	-- visibility (Layout.Tabs) and pinned pages (Layout.Pinned).
	-- Names: Body.Navigation.Tabs.Tab_<Section>.{Up, Down, Toggle},
	-- Body.Navigation.Pages.Page_<PageId>.
	local function buildNavigation(order: number)
		local layoutPrefs = snapshot.Effective.Layout or {}
		local tabsList: { string } = table.clone(layoutPrefs.Tabs or UIPrefs.NAV_SECTIONS)
		local pinned: { string } = table.clone(layoutPrefs.Pinned or {})
		local block = make("Frame", {
			Name = "Navigation",
			LayoutOrder = order,
			BackgroundColor3 = Theme.Colors.Surface,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, body)
		Theme.corner(block, Theme.Radius.S)
		Theme.padding(block, 10)
		make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, block)
		local function title(name: string, text: string, layoutOrder: number)
			make("TextLabel", {
				Name = name,
				LayoutOrder = layoutOrder,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 18),
				Font = Theme.Font.Medium,
				TextSize = 13,
				TextColor3 = Theme.Colors.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = text,
			}, block)
		end
		local function saveLayout(field: string, list: { string })
			if snapshot then
				snapshot.Effective.Layout = snapshot.Effective.Layout or {}
				snapshot.Effective.Layout[field] = list
			end
			request("personal", { Layout = { [field] = list } })
			render()
		end

		title("TabsTitle", "SECTION TABS - order and visibility", 1)
		local tabsFrame = make("Frame", {
			Name = "Tabs",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, block)
		make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabsFrame)
		local ordered = table.clone(tabsList)
		for _, id in ipairs(UIPrefs.NAV_SECTIONS) do
			if not table.find(ordered, id) then
				table.insert(ordered, id)
			end
		end
		for i, id in ipairs(ordered) do
			local position = table.find(tabsList, id)
			local line = make("Frame", {
				Name = "Tab_" .. id,
				LayoutOrder = i,
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				BackgroundTransparency = if position then 0 else 0.6,
				Size = UDim2.new(1, 0, 0, 30),
			}, tabsFrame)
			Theme.corner(line, Theme.Radius.S)
			make("TextLabel", {
				Name = "Label",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 10, 0, 0),
				Size = UDim2.new(1, -200, 1, 0),
				Font = Theme.Font.Medium,
				TextSize = 13,
				TextColor3 = if position then Theme.Colors.Text else Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = (if position then ("%d.  "):format(position) else "-   ") .. id .. (if position then "" else "  (hidden)"),
			}, line)
			local controls = make("Frame", {
				Name = "Controls",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -4, 0.5, 0),
				Size = UDim2.new(0, 190, 0, 24),
			}, line)
			make("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, 4),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}, controls)
			if position then
				local up = button(controls, "Up", "Up", 44, 1)
				up.Size = UDim2.new(0, 44, 0, 24)
				up.MouseButton1Click:Connect(function()
					if position > 1 then
						local list = table.clone(tabsList)
						list[position], list[position - 1] = list[position - 1], list[position]
						saveLayout("Tabs", list)
					end
				end)
				local down = button(controls, "Down", "Down", 52, 2)
				down.Size = UDim2.new(0, 52, 0, 24)
				down.MouseButton1Click:Connect(function()
					if position < #tabsList then
						local list = table.clone(tabsList)
						list[position], list[position + 1] = list[position + 1], list[position]
						saveLayout("Tabs", list)
					end
				end)
			end
			local toggle = button(controls, "Toggle", if position then "Hide" else "Show", 56, 3)
			toggle.Size = UDim2.new(0, 56, 0, 24)
			if not position then
				toggle.BackgroundColor3 = Theme.Colors.Accent
			end
			toggle.MouseButton1Click:Connect(function()
				local list = table.clone(tabsList)
				if position then
					if #list <= 1 then
						say("Keep at least one section tab.", false)
						return
					end
					table.remove(list, position)
				else
					table.insert(list, id)
				end
				saveLayout("Tabs", list)
			end)
		end

		title("PagesTitle", ("PINNED PAGES - favorites at the top of the menu (%d / %d)"):format(#pinned, UIPrefs.MAX_PINNED), 3)
		local pagesFrame = make("Frame", {
			Name = "Pages",
			LayoutOrder = 4,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, block)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, pagesFrame)
		for i, id in ipairs(UIPrefs.PAGE_IDS) do
			local isPinned = table.find(pinned, id) ~= nil
			local chip = button(pagesFrame, "Page_" .. id, (if isPinned then "* " else "") .. id, #id * 8 + 30, i)
			chip.BackgroundColor3 = if isPinned then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
			chip.MouseButton1Click:Connect(function()
				local list = table.clone(pinned)
				local index = table.find(list, id)
				if index then
					table.remove(list, index)
				elseif #list >= UIPrefs.MAX_PINNED then
					say(("You can pin %d pages."):format(UIPrefs.MAX_PINNED), false)
					return
				else
					table.insert(list, id)
				end
				saveLayout("Pinned", list)
			end)
		end
	end

	-- Sound row: Prev / name / Next / Play, and a box for a custom Roblox
	-- audio link or id underneath.
	buildSoundControls = function(row: Frame, controls: Frame, section: string, field: string, value: any)
		local cycle = { "Off" }
		for _, name in ipairs(SoundLibrary.ORDER) do
			table.insert(cycle, name)
		end
		if SoundLibrary.IsCustom(value) then
			table.insert(cycle, value)
		end
		local index = table.find(cycle, value) or 1
		local function choose(delta: number)
			local nextValue = cycle[((index - 1 + delta) % #cycle) + 1]
			set(section, field, nextValue)
			render()
			task.spawn(SoundPlayer.Preview, nextValue)
		end
		button(controls, "Prev", "<", 32, 1).MouseButton1Click:Connect(function()
			choose(-1)
		end)
		local label = make("TextLabel", {
			Name = "Value",
			LayoutOrder = 2,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(0, 150, 0, 28),
			Font = Theme.Font.Medium,
			TextSize = 12,
			TextColor3 = if value == "Off" then Theme.Colors.TextSecondary else Theme.Colors.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = SoundLibrary.Label(value),
		}, controls)
		Theme.corner(label, Theme.Radius.S)
		button(controls, "Next", ">", 32, 3).MouseButton1Click:Connect(function()
			choose(1)
		end)
		local play = button(controls, "Play", "", 40, 4)
		play.BackgroundColor3 = Theme.Colors.Accent
		local image = Icons.image("SoundOn")
		if image then
			make("ImageLabel", {
				Name = "Icon",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(18, 18),
				Image = image,
			}, play)
		else
			play.Text = "Play"
		end
		play.MouseButton1Click:Connect(function()
			task.spawn(function()
				local ok, message = SoundPlayer.Preview(value)
				say(message, ok)
			end)
		end)

		local custom = make("Frame", {
			Name = "Custom",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 50),
			Size = UDim2.new(1, -24, 0, 28),
		}, row)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 4),
		}, custom)
		local link: TextBox = make("TextBox", {
			Name = "Link",
			LayoutOrder = 1,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, -78, 0, 28),
			Font = Theme.Font.Mono,
			TextSize = 12,
			TextColor3 = Theme.Colors.Text,
			PlaceholderColor3 = Theme.Colors.TextSecondary,
			PlaceholderText = "Custom sound: paste a Roblox audio link or id",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = if SoundLibrary.IsCustom(value) then value else "",
		}, custom)
		Theme.corner(link, Theme.Radius.S)
		local linkPad = Instance.new("UIPadding")
		linkPad.PaddingLeft = UDim.new(0, 8)
		linkPad.Parent = link
		local use = button(custom, "Use", "Use", 70, 2)
		local function applyLink()
			local normalized = SoundLibrary.Normalize(link.Text)
			if not normalized or not SoundLibrary.IsCustom(normalized) then
				say("Paste a Roblox audio link (create.roblox.com/store/asset/<id>/...) or its id.", false)
				return
			end
			say("Checking that sound...", nil)
			task.spawn(function()
				local ok, message = SoundPlayer.Preview(normalized)
				if not ok then
					say(message, false)
					return
				end
				set(section, field, normalized)
				render()
				say(("%s now plays %s."):format(FIELD_LABELS[field] or field, normalized), true)
			end)
		end
		use.MouseButton1Click:Connect(applyLink)
		link.FocusLost:Connect(function(enter: boolean)
			if enter then
				applyLink()
			end
		end)
	end

	render = function()
		local scroll = body.CanvasPosition
		for _, child in ipairs(body:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if not snapshot then
			return
		end
		local order = 0
		for _, section in ipairs(sections) do
			order += 1
			make("TextLabel", {
				Name = "Section_" .. section,
				LayoutOrder = order,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -8, 0, 30),
				Font = Theme.Font.Bold,
				TextSize = 13,
				TextColor3 = Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Bottom,
				Text = SECTION_TITLES[section]:upper(),
			}, body)
			for _, field in ipairs(UIPrefs.ORDER[section]) do
				order += 1
				local spec = UIPrefs.SPEC[section][field]
				local value = snapshot.Effective[section][field]
				if value == nil then
					value = UIPrefs.BUILTIN[section][field]
				end
				local personal = snapshot.Personal[section] ~= nil and snapshot.Personal[section][field] ~= nil
				local isSound = spec.Kind == "sound"
				local row = make("Frame", {
					Name = ("Row_%s_%s"):format(section, field),
					LayoutOrder = order,
					BackgroundColor3 = Theme.Colors.Surface,
					Size = UDim2.new(1, -8, 0, if isSound then 88 else 52),
				}, body)
				Theme.corner(row, Theme.Radius.S)
				make("TextLabel", {
					Name = "Label",
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 12, 0, 8),
					Size = UDim2.new(0, 220, 0, 18),
					Font = Theme.Font.Medium,
					TextSize = 13,
					TextColor3 = Theme.Colors.Text,
					TextXAlignment = Enum.TextXAlignment.Left,
					Text = (FIELD_LABELS[field] or field):upper(),
				}, row)
				make("TextLabel", {
					Name = "Description",
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 12, 0, 27),
					Size = UDim2.new(0, 240, 0, 16),
					Font = Theme.Font.Regular,
					TextSize = 11,
					TextColor3 = Theme.Colors.TextSecondary,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Text = spec.Description .. (if personal then "" else "  (server default)"),
				}, row)
				local controls = make("Frame", {
					Name = "Controls",
					BackgroundTransparency = 1,
					AnchorPoint = Vector2.new(1, if isSound then 0 else 0.5),
					Position = UDim2.new(1, -10, if isSound then 0 else 0.5, if isSound then 12 else 0),
					Size = UDim2.new(1, -270, 0, 28),
				}, row)
				make("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 4),
				}, controls)

				if isSound then
					buildSoundControls(row, controls, section, field, value)
				elseif spec.Kind == "choice" then
					for i, option in ipairs(spec.Choices) do
						local hasSwatch = field == "Accent" or field == "Theme"
						local chip = button(controls, "Choice_" .. option, option, math.max(50, #option * 7 + 22) + (if hasSwatch then 14 else 0), i)
						if hasSwatch then
							-- leave room for the colour dot on the left
							local pad = Instance.new("UIPadding")
							pad.PaddingLeft = UDim.new(0, 16)
							pad.Parent = chip
						end
						local active = option == value
						chip.BackgroundColor3 = if active then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
						if field == "Accent" then
							swatch(chip, UIPrefs.ACCENTS[option])
						elseif field == "Theme" then
							local set = UIPrefs.THEMES[option]
							local custom = snapshot.Effective.Panel.Custom
							local customColor = if type(custom) == "table" then UIPrefs.HexToColor(custom.SurfaceRaised) else nil
							swatch(chip, if set then set.SurfaceRaised else (customColor or Theme.Colors.SurfaceRaised))
						end
						chip.MouseButton1Click:Connect(function()
							set(section, field, option)
							render()
						end)
					end
				elseif spec.Kind == "boolean" then
					local toggle = button(controls, "Toggle", if value then "On" else "Off", 70, 1)
					toggle.BackgroundColor3 = if value then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
					toggle.MouseButton1Click:Connect(function()
						set(section, field, not value)
						render()
					end)
				else
					local function step(direction: number)
						local new = math.clamp(value + direction * spec.Step, spec.Min, spec.Max)
						new = if spec.Integer then math.floor(new + 0.5) else math.floor(new * 100 + 0.5) / 100
						if new ~= value then
							set(section, field, new)
							render()
						end
					end
					button(controls, "Minus", "-", 32, 1).MouseButton1Click:Connect(function()
						step(-1)
					end)
					local shown = if spec.Integer then tostring(value) elseif spec.Max <= 1.5 then ("%d%%"):format(value * 100 + 0.5) else tostring(value) .. "x"
					make("TextLabel", {
						Name = "Value",
						LayoutOrder = 2,
						BackgroundColor3 = Theme.Colors.SurfaceRaised,
						Size = UDim2.new(0, 64, 0, 28),
						Font = Theme.Font.Mono,
						TextSize = 13,
						TextColor3 = Theme.Colors.Text,
						Text = shown,
					}, controls)
					button(controls, "Plus", "+", 32, 3).MouseButton1Click:Connect(function()
						step(1)
					end)
				end
			end
			if section == "Panel" then
				order += 1
				buildCustomTheme(order)
			elseif section == "Layout" then
				order += 1
				buildNavigation(order)
			end
		end
		body.CanvasPosition = scroll
	end

	local function load()
		local ok, result = pcall(function()
			return getRemote:InvokeServer()
		end)
		if ok and type(result) == "table" and result.Effective then
			snapshot = result
			buildToolbar()
			render()
		end
	end

	changedRemote.OnClientEvent:Connect(function(update: any)
		if type(update) == "table" and update.Effective and snapshot then
			snapshot.Effective = update.Effective
			snapshot.Personal = update.Personal
			snapshot.Defaults = update.Defaults
			-- init.client retints first; rebuild after so the active chips
			-- use the new palette.
			task.defer(render)
		end
	end)
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible and not snapshot then
			load()
		end
	end)
	task.spawn(load)
end

return AppearancePage
