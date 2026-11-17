--!strict
--[[
	LibraryPage.lua (W07)

	Purpose:
		The player's command library and history:
			History    — searchable command results (✓/✗, duration, source,
			             targets) with Re-run / Edit; undo / redo toolbar
			Presets    — saved command lines (chains allowed), run / edit /
			             delete, and a form to add one
			Templates  — built-in + own templates with {placeholders}; "Use"
			             opens the command builder
			Favorites  — favorite commands; "Build" opens the builder
		The toolbar also shows running (cancellable) commands and the active
		chat prefixes.

	Reads GetCommandHistoryRemote / GetCommandLibraryRemote; library writes go
	through UpdateCommandLibraryRemote, everything else is a normal command
	sent with ExecuteCommandRemote (undo, redo, cancel, re-run).

	Public API:
		LibraryPage.Build(container, commandPalette, commandBuilder)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local LibraryPage = {}

local TABS = { "History", "Presets", "Templates", "Favorites" }

local layoutCounter = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		layoutCounter += 1
		inst.LayoutOrder = layoutCounter -- creation order, unless props say otherwise
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

local function button(parent: Instance, name: string, text: string, color: Color3?, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width or 80, 0, 26),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function textBox(parent: Instance, name: string, placeholder: string, size: UDim2): TextBox
	local box = make("TextBox", {
		Name = name,
		Size = size,
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, parent)
	Theme.corner(box, Theme.Radius.S)
	Theme.padding(box, 6)
	return box
end

local function ago(t: number): string
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return d .. "s ago"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m ago"
	end
	return math.floor(d / 3600) .. "h ago"
end

function LibraryPage.Build(container: Frame, commandPalette: any, commandBuilder: any)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent
	local historyRemote = SentinelShared:WaitForChild("GetCommandHistoryRemote", 15) :: RemoteFunction
	local libraryRemote = SentinelShared:WaitForChild("GetCommandLibraryRemote", 15) :: RemoteFunction
	local updateRemote = SentinelShared:WaitForChild("UpdateCommandLibraryRemote", 15) :: RemoteFunction

	local currentTab = "History"
	local search = ""
	local failedOnly = false
	local refreshQueued = false

	make("TextLabel", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Command Library",
	}, container)
	local subHeader = make("TextLabel", {
		Name = "SubHeader",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "History, undo / redo, presets, templates and favorites.",
	}, container)

	-- Toolbar: undo / redo / cancel / build
	local toolbar = make("Frame", {
		Name = "Toolbar",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 0, 28),
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, toolbar)
	local undoBtn = button(toolbar, "Undo", "Undo", nil, 90)
	local redoBtn = button(toolbar, "Redo", "Redo", nil, 90)
	local cancelBtn = button(toolbar, "Cancel", "■ Cancel", nil, 110)
	local buildBtn = button(toolbar, "Build", "Build command", Theme.Colors.Accent, 130)
	local status = make("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		-- W09: whatever is left after the four buttons (truncated), not a
		-- fixed 360 px that ran past a narrow panel.
		Size = UDim2.new(1, -446, 1, 0),
		Font = Theme.Font.Regular,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, toolbar)

	-- Tabs
	local tabBar = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 86),
		Size = UDim2.new(1, 0, 0, 28),
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)
	local tabButtons: { [string]: TextButton } = {}

	-- Controls row (search / add forms), then the list
	local controls = make("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 120),
		Size = UDim2.new(1, 0, 0, 30),
	}, container)
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 156),
		Size = UDim2.new(1, 0, 1, -156),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Border,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, container)
	Theme.corner(list, Theme.Radius.S)
	Theme.padding(list, 6)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)

	local function send(text: string)
		executeRemote:FireServer(text)
	end

	local function libraryChanged()
		if commandPalette and commandPalette.InvalidateLibrary then
			commandPalette.InvalidateLibrary()
		end
	end

	local function update(action: string, payload: any): any
		local ok, result = pcall(function()
			return updateRemote:InvokeServer(action, payload)
		end)
		local r = if ok and type(result) == "table" then result else { Success = false, Message = "Request failed." }
		subHeader.Text = r.Message or ""
		subHeader.TextColor3 = if r.Success then Theme.Colors.Success else Theme.Colors.Error
		libraryChanged()
		return r
	end

	local function clearList()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function row(order: number, name: string, title: string, detail: string, titleColor: Color3?): Frame
		local r = make("Frame", {
			Name = name,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, -4, 0, 46),
			LayoutOrder = order,
		}, list)
		Theme.corner(r, Theme.Radius.S)
		make("TextLabel", {
			Name = "Title",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 10, 0, 4),
			Size = UDim2.new(1, -250, 0, 18),
			Font = Theme.Font.Mono,
			TextSize = 13,
			TextColor3 = titleColor or Theme.Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = title,
		}, r)
		make("TextLabel", {
			Name = "Detail",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 10, 0, 24),
			Size = UDim2.new(1, -250, 0, 16),
			Font = Theme.Font.Regular,
			TextSize = 11,
			TextColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = detail,
		}, r)
		local actions = make("Frame", {
			Name = "Actions",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.new(0, 236, 0, 26),
		}, r)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 4),
		}, actions)
		return r
	end

	local function emptyNote(text: string)
		make("TextLabel", {
			Name = "Empty",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 40),
			Font = Theme.Font.Regular,
			TextSize = 13,
			TextColor3 = Theme.Colors.TextSecondary,
			Text = text,
		}, list)
	end

	-- -------------------------------------------------------------------
	-- Controls per tab
	-- -------------------------------------------------------------------
	local refresh: () -> ()

	local function buildControls()
		for _, child in ipairs(controls:GetChildren()) do
			child:Destroy()
		end
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, controls)
		if currentTab == "History" then
			local box = textBox(controls, "Search", "Search commands, targets, messages…", UDim2.new(0.5, 0, 1, 0))
			box.Text = search
			box:GetPropertyChangedSignal("Text"):Connect(function()
				search = box.Text
				refresh()
			end)
			local toggle = button(controls, "FailedOnly", if failedOnly then "✗ Failed only" else "All results", nil, 110)
			toggle.Size = UDim2.new(0, 110, 1, 0)
			toggle.MouseButton1Click:Connect(function()
				failedOnly = not failedOnly
				toggle.Text = if failedOnly then "✗ Failed only" else "All results"
				refresh()
			end)
		elseif currentTab == "Presets" then
			local name = textBox(controls, "PresetName", "Preset name", UDim2.new(0.22, 0, 1, 0))
			local text = textBox(controls, "PresetText", "Command line, e.g. heal me && unfreeze me", UDim2.new(0.58, 0, 1, 0))
			text.Font = Theme.Font.Mono
			local add = button(controls, "AddPreset", "+ Save", Theme.Colors.Accent, 80)
			add.Size = UDim2.new(0, 80, 1, 0)
			add.MouseButton1Click:Connect(function()
				if update("savePreset", { Name = name.Text, Text = text.Text }).Success then
					name.Text, text.Text = "", ""
					refresh()
				end
			end)
		elseif currentTab == "Templates" then
			local name = textBox(controls, "TemplateName", "Template name", UDim2.new(0.2, 0, 1, 0))
			local text = textBox(controls, "TemplateText", "e.g. jail {player} && warn {player} {reason}", UDim2.new(0.6, 0, 1, 0))
			text.Font = Theme.Font.Mono
			local add = button(controls, "AddTemplate", "+ Save", Theme.Colors.Accent, 80)
			add.Size = UDim2.new(0, 80, 1, 0)
			add.MouseButton1Click:Connect(function()
				if update("saveTemplate", { Name = name.Text, Text = text.Text }).Success then
					name.Text, text.Text = "", ""
					refresh()
				end
			end)
		elseif currentTab == "Favorites" then
			local cmd = textBox(controls, "FavoriteCommand", "Command to add to favorites, e.g. freeze", UDim2.new(0.5, 0, 1, 0))
			local add = button(controls, "AddFavorite", "★ Add", Theme.Colors.Accent, 80)
			add.Size = UDim2.new(0, 80, 1, 0)
			add.MouseButton1Click:Connect(function()
				local name = cmd.Text:match("^%s*[;:!%./]?(%S+)")
				if name then
					send("favorite " .. name)
					cmd.Text = ""
					task.delay(0.6, function()
						libraryChanged()
						refresh()
					end)
				end
			end)
		end
	end

	-- -------------------------------------------------------------------
	-- Lists
	-- -------------------------------------------------------------------
	local function renderHistory(data: any)
		local entries = data.Entries or {}
		if #entries == 0 then
			emptyNote(if search ~= "" or failedOnly then "No matching commands." else "Commands you run this session show up here.")
			return
		end
		local undoShown = false
		for i, e in ipairs(entries) do
			local mark = if e.Success then "✓ " else "✗ "
			local detail = ("%s · %s · %s ms · via %s%s"):format(
				ago(e.Time or os.time()),
				e.Message or "",
				tostring(e.DurationMs or 0),
				e.Source or "?",
				if e.Targets and #e.Targets > 0 then " · " .. table.concat(e.Targets, ", ") else ""
			)
			local title = mark .. (e.Input or e.Command) .. (if e.State == "undone" then "   [undone]" else "")
			local r = row(i, "Entry_" .. i, title, detail, if e.Success then Theme.Colors.Text else Theme.Colors.Error)
			local actions = r:FindFirstChild("Actions") :: Frame
			local rerun = button(actions, "Rerun", "Re-run", nil, 72)
			rerun.MouseButton1Click:Connect(function()
				send(e.Input)
			end)
			local edit = button(actions, "Edit", "Edit", nil, 52)
			edit.MouseButton1Click:Connect(function()
				if commandPalette then
					commandPalette.Open(e.Input)
				end
			end)
			-- only the newest undoable entry can be undone directly
			if e.Undoable and not undoShown and search == "" and not failedOnly then
				undoShown = true
				local undo = button(actions, "UndoThis", "Undo", nil, 52)
				undo.MouseButton1Click:Connect(function()
					send("undo")
				end)
			end
		end
	end

	local function renderPresets(lib: any)
		if #(lib.Presets or {}) == 0 then
			emptyNote("No presets yet — save one above or from the command builder.")
			return
		end
		for i, p in ipairs(lib.Presets) do
			local r = row(i, "Preset_" .. p.Name:gsub("[^%w_]", "_"), "▶ " .. p.Name, p.Text, Theme.Colors.Accent)
			local actions = r:FindFirstChild("Actions") :: Frame
			button(actions, "Run", "Run", Theme.Colors.Accent, 52).MouseButton1Click:Connect(function()
				send(p.Text)
			end)
			button(actions, "Edit", "Edit", nil, 52).MouseButton1Click:Connect(function()
				if commandPalette then
					commandPalette.Open(p.Text)
				end
			end)
			button(actions, "Delete", "Delete", Theme.Colors.Error, 60).MouseButton1Click:Connect(function()
				update("deletePreset", { Name = p.Name })
				refresh()
			end)
		end
	end

	local function renderTemplates(lib: any)
		local order = 0
		for _, group in ipairs({ { lib.Templates or {}, false }, { lib.BuiltinTemplates or {}, true } }) do
			for _, t in ipairs(group[1]) do
				order += 1
				local builtin = group[2]
				local r = row(
					order,
					"Template_" .. t.Name:gsub("[^%w_]", "_"),
					t.Name .. (if builtin then "  (built-in)" else ""),
					t.Text .. (if t.Description then "  —  " .. t.Description else "")
				)
				local actions = r:FindFirstChild("Actions") :: Frame
				button(actions, "Use", "Use", Theme.Colors.Accent, 52).MouseButton1Click:Connect(function()
					if commandBuilder then
						commandBuilder.Open({ Template = t })
					end
				end)
				if not builtin then
					button(actions, "Delete", "Delete", Theme.Colors.Error, 60).MouseButton1Click:Connect(function()
						update("deleteTemplate", { Name = t.Name })
						refresh()
					end)
				end
			end
		end
		if order == 0 then
			emptyNote("No templates.")
		end
	end

	local function renderFavorites(lib: any)
		if #(lib.Favorites or {}) == 0 then
			emptyNote("No favorites yet. Favorites are listed first in the command palette.")
			return
		end
		for i, name in ipairs(lib.Favorites) do
			local r = row(i, "Favorite_" .. name, "★ " .. name, "Favorite command", Theme.Colors.Warning)
			local actions = r:FindFirstChild("Actions") :: Frame
			button(actions, "Build", "Build", Theme.Colors.Accent, 56).MouseButton1Click:Connect(function()
				if commandBuilder then
					commandBuilder.Open({ Command = name })
				end
			end)
			button(actions, "Palette", "Palette", nil, 64).MouseButton1Click:Connect(function()
				if commandPalette then
					commandPalette.Open(name .. " ")
				end
			end)
			button(actions, "Remove", "Remove", Theme.Colors.Error, 64).MouseButton1Click:Connect(function()
				update("favorite", { Command = name, On = false })
				refresh()
			end)
		end
	end

	local function updateToolbar(data: any)
		undoBtn.Text = ("Undo (%d)"):format(data.UndoCount or 0)
		redoBtn.Text = ("Redo (%d)"):format(data.RedoCount or 0)
		local running = data.Running or {}
		cancelBtn.Text = ("■ Cancel (%d)"):format(#running)
		local parts = {}
		if data.NextUndo then
			table.insert(parts, "undo: " .. data.NextUndo)
		end
		for _, op in ipairs(running) do
			table.insert(parts, ("running: %s (%ds)"):format(op.Label, op.Seconds))
		end
		status.Text = table.concat(parts, "   ·   ")
	end

	local busy = false
	refresh = function()
		if busy then
			refreshQueued = true
			return
		end
		busy = true
		task.spawn(function()
			local ok, history = pcall(function()
				return historyRemote:InvokeServer({ Search = search, Limit = 60, FailedOnly = failedOnly })
			end)
			local lib = nil
			if currentTab ~= "History" then
				local ok2, result = pcall(function()
					return libraryRemote:InvokeServer()
				end)
				lib = if ok2 then result else nil
			end
			clearList()
			if ok and type(history) == "table" then
				updateToolbar(history)
				if currentTab == "History" then
					renderHistory(history)
				end
			end
			if type(lib) == "table" then
				if currentTab == "Presets" then
					renderPresets(lib)
				elseif currentTab == "Templates" then
					renderTemplates(lib)
				elseif currentTab == "Favorites" then
					renderFavorites(lib)
				end
				if lib.Prefixes then
					subHeader.Text = "Chat prefixes: " .. table.concat(lib.Prefixes, "  ")
					subHeader.TextColor3 = Theme.Colors.TextSecondary
				end
			end
			busy = false
			if refreshQueued then
				refreshQueued = false
				refresh()
			end
		end)
	end

	local function selectTab(tab: string)
		currentTab = tab
		for name, b in pairs(tabButtons) do
			b.BackgroundColor3 = if name == tab then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		end
		buildControls()
		refresh()
	end

	for _, tab in ipairs(TABS) do
		local b = button(tabBar, "Tab_" .. tab, tab, nil, 96)
		tabButtons[tab] = b
		b.MouseButton1Click:Connect(function()
			selectTab(tab)
		end)
	end

	undoBtn.MouseButton1Click:Connect(function()
		send("undo")
	end)
	redoBtn.MouseButton1Click:Connect(function()
		send("redo")
	end)
	cancelBtn.MouseButton1Click:Connect(function()
		send("cancel")
	end)
	buildBtn.MouseButton1Click:Connect(function()
		if commandBuilder then
			commandBuilder.Open()
		end
	end)
	if commandBuilder then
		commandBuilder.OnLibraryChanged = function()
			if container.Visible then
				refresh()
			end
		end
	end

	-- Any command result may change history: refresh while visible.
	resultRemote.OnClientEvent:Connect(function()
		if container.Visible then
			task.delay(0.2, refresh)
		end
	end)
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			refresh()
		end
	end)
	task.spawn(function()
		while container.Parent do
			task.wait(5)
			if container.Visible and currentTab == "History" then
				refresh()
			end
		end
	end)

	selectTab("History")
end

return LibraryPage
