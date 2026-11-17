--!strict
--[[
	CommandBar.lua (UI redesign)

	Purpose:
		A terminal-style command bar docked to the top (or bottom) of the
		screen: an output log, a prompt line ("name@Sentinel$ "), and an
		autocomplete box that follows the word being typed and shows what
		the argument is (name, type, description) with its suggestions.

		It is separate from the panel: staff and ranks with "commandbar.use"
		(VIP) get it even when they can't open the panel. Commands go through
		ExecuteCommandRemote like everything else.

		Keys: the toggle key (F2 by default) opens / closes; Tab accepts the
		highlighted suggestion; Up / Down move through suggestions, or
		through your history when there are none; Enter runs; Esc closes.
		"cls" clears the output.

	Look and behaviour come from the CommandBar preferences (Shared/UIPrefs):
	Preset, Position, Width, Opacity, FontSize, MaxLines, Rows, Key. The
	whole bar is rebuilt when they change, keeping its output.

	Reuses the palette's shared logic: UsageSpec.Analyze says which argument
	the cursor is on, ArgumentTypes.Suggest lists values.

	Stable names: SentinelCommandBar.Window.InputLine.Input,
	SentinelCommandBar.Popup.List.Row_<n>.

	Public API:
		CommandBar.Init(prefs)          -- prefs = effective { CommandBar, Panel }
		CommandBar.ApplyPrefs(prefs)
		CommandBar.Open(text?), Close(), Toggle(), IsOpen()
		CommandBar.Print(text, color?)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))
local UsageSpec = require(SentinelShared:WaitForChild("UsageSpec"))
local ArgumentTypes = require(SentinelShared:WaitForChild("ArgumentTypes"))

local CommandBar = {}

local localPlayer = Players.LocalPlayer
local FONT = Enum.Font.Code
local POPUP_WIDTH = 300
local ERROR_COLOR = Color3.fromRGB(240, 100, 100)
local SUCCESS_COLOR = Color3.fromRGB(120, 220, 150)

local prefs: any = UIPrefs.Merge(UIPrefs.BUILTIN)
local initialized = false
local isOpen = false

-- Output and history survive rebuilds.
local logLines: { { Text: string, Color: Color3? } } = {}
local history: { string } = {}
local historyIndex = 0
local pendingResults = 0

-- Built by build()
local screenGui: ScreenGui? = nil
local window: Frame? = nil
local inputBox: TextBox? = nil
local renderLog: (() -> ())? = nil
local refresh: (() -> ())? = nil
local handleKey: ((Enum.KeyCode) -> boolean)? = nil

-- ---------------------------------------------------------------------------
-- Data (own small caches; the bar may exist without the palette)
-- ---------------------------------------------------------------------------
local commandCache: { any }? = nil
local byInvocable: { [string]: any } = {}
local autocompleteData: any = nil

local function fetchCommands(): { any }
	if commandCache then
		return commandCache
	end
	local remote = SentinelShared:WaitForChild("GetCommandListRemote", 10) :: RemoteFunction?
	local ok, result = false, nil
	if remote then
		ok, result = pcall(function()
			return remote:InvokeServer()
		end)
	end
	if not ok or type(result) ~= "table" or #result == 0 then
		return {}
	end
	table.sort(result, function(a, b)
		return a.Name < b.Name
	end)
	commandCache = result
	table.clear(byInvocable)
	for _, meta in ipairs(result) do
		byInvocable[meta.Name:lower()] = meta
		for _, alias in ipairs(meta.Aliases or {}) do
			byInvocable[alias:lower()] = meta
		end
	end
	return result
end

local function fetchAutocomplete()
	if autocompleteData then
		return
	end
	local remote = SentinelShared:FindFirstChild("GetAutocompleteDataRemote") :: RemoteFunction?
	if remote then
		local ok, result = pcall(function()
			return remote:InvokeServer()
		end)
		if ok and type(result) == "table" then
			autocompleteData = result
		end
	end
end

local function resolve(name: string): any?
	return byInvocable[name:lower()]
end

local function buildEnv(): any
	return {
		Players = Players:GetPlayers(),
		Teams = Teams:GetTeams(),
		Ranks = (autocompleteData and autocompleteData.Ranks) or {},
		Commands = commandCache or {},
		LocalPlayer = localPlayer,
	}
end

-- Prefix matches first, then names that contain the text.
local function commandSuggestions(partial: string): { any }
	local q = partial:lower()
	local starts, contains = {}, {}
	for _, meta in ipairs(fetchCommands()) do
		local name = meta.Name:lower()
		local entry = { Text = meta.Name, Label = meta.Name, Meta = meta }
		if q == "" or name:sub(1, #q) == q then
			table.insert(starts, entry)
		elseif name:find(q, 1, true) then
			table.insert(contains, entry)
		else
			for _, alias in ipairs(meta.Aliases or {}) do
				if alias:lower():sub(1, #q) == q then
					table.insert(contains, { Text = meta.Name, Label = ("%s (%s)"):format(meta.Name, alias), Meta = meta })
					break
				end
			end
		end
	end
	for _, entry in ipairs(contains) do
		table.insert(starts, entry)
	end
	return starts
end

-- ---------------------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------------------
local function palette(): any
	local preset = UIPrefs.BAR_PRESETS[prefs.CommandBar.Preset] or UIPrefs.BAR_PRESETS.Classic
	if preset.FollowTheme then
		return {
			Background = Theme.Colors.Background,
			Line = Theme.Colors.Surface,
			Prompt = Theme.Colors.Accent,
			Text = Theme.Colors.Text,
			Muted = Theme.Colors.TextSecondary,
			Popup = Theme.Colors.SurfaceRaised,
			PopupHeader = Theme.Colors.Surface,
			Selected = Theme.Colors.Border,
		}
	end
	return preset
end

local function hex(c: Color3): string
	return ("#%02x%02x%02x"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function esc(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function promptText(): string
	return ("%s@Sentinel$ "):format(localPlayer.Name)
end

function CommandBar.Print(text: string, color: Color3?)
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(logLines, { Text = line, Color = color })
	end
	local max = prefs.CommandBar.MaxLines
	while #logLines > max do
		table.remove(logLines, 1)
	end
	if renderLog then
		renderLog()
	end
end

-- ---------------------------------------------------------------------------
-- Build (called again whenever the preferences change)
-- ---------------------------------------------------------------------------
local function build()
	local bar = prefs.CommandBar
	local P = palette()
	local fontSize = bar.FontSize
	local lineHeight = fontSize + 8
	local atBottom = bar.Position == "bottom"
	local charWidth = TextService:GetTextSize("M", fontSize, FONT, Vector2.new(1000, 100)).X

	if screenGui then
		screenGui:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SentinelCommandBar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 70
	gui.Enabled = isOpen
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	screenGui = gui

	local win = Instance.new("Frame")
	win.Name = "Window"
	win.AnchorPoint = Vector2.new(0.5, if atBottom then 1 else 0)
	win.Position = UDim2.new(0.5, 0, if atBottom then 1 else 0, 0)
	win.Size = UDim2.new(bar.Width, 0, 0, 0)
	win.AutomaticSize = Enum.AutomaticSize.Y
	win.BackgroundColor3 = P.Background
	win.BackgroundTransparency = 1 - bar.Opacity
	win.BorderSizePixel = 0
	win.Parent = gui
	window = win
	local winLayout = Instance.new("UIListLayout")
	winLayout.SortOrder = Enum.SortOrder.LayoutOrder
	winLayout.Parent = win

	local log = Instance.new("Frame")
	log.Name = "Log"
	log.LayoutOrder = 1
	log.BackgroundTransparency = 1
	log.Size = UDim2.new(1, 0, 0, 0)
	log.AutomaticSize = Enum.AutomaticSize.Y
	log.Parent = win
	local logLayout = Instance.new("UIListLayout")
	logLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logLayout.Parent = log
	local logPad = Instance.new("UIPadding")
	logPad.PaddingLeft = UDim.new(0, 12)
	logPad.PaddingRight = UDim.new(0, 12)
	logPad.PaddingTop = UDim.new(0, 6)
	logPad.Parent = log

	local inputLine = Instance.new("Frame")
	inputLine.Name = "InputLine"
	inputLine.LayoutOrder = 2
	inputLine.Size = UDim2.new(1, 0, 0, lineHeight + 10)
	inputLine.BackgroundColor3 = P.Line
	inputLine.BackgroundTransparency = math.max(0, 1 - bar.Opacity - 0.05)
	inputLine.BorderSizePixel = 0
	inputLine.Parent = win

	local prompt = Instance.new("TextLabel")
	prompt.Name = "Prompt"
	prompt.BackgroundTransparency = 1
	prompt.Position = UDim2.new(0, 12, 0, 0)
	prompt.Size = UDim2.new(0, #promptText() * charWidth, 1, 0)
	prompt.Font = FONT
	prompt.TextSize = fontSize
	prompt.TextColor3 = P.Prompt
	prompt.TextXAlignment = Enum.TextXAlignment.Left
	prompt.Text = promptText()
	prompt.Parent = inputLine

	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.BackgroundTransparency = 1
	box.Position = UDim2.new(0, 12 + #promptText() * charWidth, 0, 0)
	box.Size = UDim2.new(1, -(24 + #promptText() * charWidth), 1, 0)
	box.Font = FONT
	box.TextSize = fontSize
	box.TextColor3 = P.Text
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.PlaceholderText = ""
	box.Text = ""
	box.Parent = inputLine
	inputBox = box

	-- Autocomplete popup (outside the window so it can hang below / above).
	local popup = Instance.new("Frame")
	popup.Name = "Popup"
	popup.Size = UDim2.new(0, POPUP_WIDTH, 0, 0)
	popup.AutomaticSize = Enum.AutomaticSize.Y
	popup.AnchorPoint = Vector2.new(0, if atBottom then 1 else 0)
	popup.BackgroundColor3 = P.Popup
	popup.BackgroundTransparency = 0.04
	popup.BorderSizePixel = 0
	popup.Visible = false
	popup.Parent = gui
	local popupLayout = Instance.new("UIListLayout")
	popupLayout.SortOrder = Enum.SortOrder.LayoutOrder
	popupLayout.Parent = popup

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.BackgroundColor3 = P.PopupHeader
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, 0, 0, 0)
	header.AutomaticSize = Enum.AutomaticSize.Y
	header.Parent = popup
	local headerPad = Instance.new("UIPadding")
	headerPad.PaddingLeft = UDim.new(0, 10)
	headerPad.PaddingRight = UDim.new(0, 10)
	headerPad.PaddingTop = UDim.new(0, 8)
	headerPad.PaddingBottom = UDim.new(0, 10)
	headerPad.Parent = header
	local headerLayout = Instance.new("UIListLayout")
	headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	headerLayout.Padding = UDim.new(0, 6)
	headerLayout.Parent = header

	local function headerLabel(name: string, order: number, size: number, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.LayoutOrder = order
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.Font = Enum.Font.SourceSans
		l.TextSize = size
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.RichText = true
		l.Text = ""
		l.Parent = header
		return l
	end
	local title = headerLabel("Title", 1, fontSize + 3, P.Text)
	local description = headerLabel("Description", 2, fontSize, P.Muted)
	local problem = headerLabel("Problem", 3, fontSize - 1, ERROR_COLOR)

	local list = Instance.new("Frame")
	list.Name = "List"
	list.LayoutOrder = 2
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, 0, 0, 0)
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.Parent = popup
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	-- State of the current input
	local analysis: any = nil
	local suggestions: { any } = {}
	local selected = 1
	local suppress = false

	local function setText(text: string)
		suppress = true
		box.Text = text
		suppress = false
	end

	renderLog = function()
		for _, child in ipairs(log:GetChildren()) do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		for i, line in ipairs(logLines) do
			local l = Instance.new("TextLabel")
			l.Name = "Line_" .. i
			l.LayoutOrder = i
			l.BackgroundTransparency = 1
			l.Size = UDim2.new(1, 0, 0, lineHeight)
			l.AutomaticSize = Enum.AutomaticSize.Y
			l.Font = FONT
			l.TextSize = fontSize
			l.TextColor3 = line.Color or P.Text
			l.TextXAlignment = Enum.TextXAlignment.Left
			l.TextWrapped = true
			l.RichText = true
			l.Text = line.Text
			l.Parent = log
		end
	end
	renderLog()

	local accept: (index: number?) -> ()

	local function renderPopup()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local a = analysis
		local text = box.Text
		if not a or text:gsub("%s", "") == "" then
			popup.Visible = false
			return
		end

		-- Header: what is being typed
		local problemText = ""
		if a.Part == "command" or a.Part == "unknown" then
			local pick = suggestions[selected]
			if pick then
				local meta = pick.Meta
				title.Text = ("<b>%s</b>"):format(esc(meta.Name))
				description.Text = esc(meta.Description or "")
					.. ("\n<font color=\"%s\">%s %s</font>"):format(hex(P.Muted), esc(meta.Name), esc(UsageSpec.Signature(meta.Args or {})))
			else
				title.Text = ("<b>%s</b>"):format(esc(a.Partial ~= "" and a.Partial or a.CommandWord))
				description.Text = "No command matches."
			end
		elseif a.Arg then
			title.Text = ("<b>%s</b>: %s%s"):format(esc(a.Arg.Name), esc(a.Arg.Type), if a.Arg.Optional then " (optional)" else "")
			local typeDef = ArgumentTypes.Get(a.Arg.Type)
			description.Text = esc(a.Arg.Description or (typeDef and typeDef.Description) or "")
		else
			title.Text = ("<b>%s</b>"):format(esc(a.Command and a.Command.Name or a.CommandWord))
			description.Text = if #a.Missing > 0 then "More arguments are needed." else "Press Enter to run."
		end
		if a.Part ~= "command" and #a.Errors > 0 then
			problemText = esc(a.Errors[1])
		end
		problem.Text = problemText
		problem.Visible = problemText ~= ""
		description.Visible = description.Text ~= ""

		-- A window of rows around the selection
		local rows = bar.Rows
		local first = math.clamp(selected - math.floor(rows / 2), 1, math.max(1, #suggestions - rows + 1))
		for i = first, math.min(#suggestions, first + rows - 1) do
			local s = suggestions[i]
			local row = Instance.new("TextButton")
			row.Name = "Row_" .. i
			row.LayoutOrder = i
			row.Size = UDim2.new(1, 0, 0, lineHeight + 6)
			row.AutoButtonColor = false
			row.BorderSizePixel = 0
			row.BackgroundColor3 = P.Selected
			row.BackgroundTransparency = if i == selected then 0 else 1
			row.Font = FONT
			row.TextSize = fontSize
			row.TextColor3 = P.Text
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.TextTruncate = Enum.TextTruncate.AtEnd
			row.Text = "  " .. tostring(s.Label or s.Text) .. (if s.Detail then "   " .. tostring(s.Detail) else "")
			row.Parent = list
			row.MouseEnter:Connect(function()
				if selected ~= i then
					row.BackgroundTransparency = 0.6
				end
			end)
			row.MouseLeave:Connect(function()
				row.BackgroundTransparency = if i == selected then 0 else 1
			end)
			row.MouseButton1Click:Connect(function()
				accept(i)
			end)
		end

		-- Under (or above) the word being typed
		local x = box.AbsolutePosition.X + (math.max(1, a.ReplaceStart) - 1) * charWidth
		x = math.clamp(x, 4, math.max(4, gui.AbsoluteSize.X - POPUP_WIDTH - 4))
		local y = if atBottom then win.AbsolutePosition.Y - 2 else win.AbsolutePosition.Y + win.AbsoluteSize.Y + 2
		popup.Position = UDim2.fromOffset(x, y)
		popup.Visible = true
	end

	refresh = function()
		local text = box.Text
		local env = buildEnv()
		analysis = UsageSpec.Analyze(text, resolve, env)
		local a = analysis
		suggestions = {}
		if a.Part == "command" then
			suggestions = commandSuggestions(a.Partial)
		elseif a.Part == "unknown" then
			suggestions = commandSuggestions(a.CommandWord)
			local firstTok = UsageSpec.Tokenize(text)[1]
			a.Partial = a.CommandWord
			a.ReplaceStart = if firstTok then (text:find(firstTok.Text, 1, true) or 1) else 1
		elseif a.Arg then
			suggestions = ArgumentTypes.Suggest(a.Arg, a.Partial, env)
			if #suggestions == 1 and suggestions[1].Text == a.Partial then
				suggestions = {}
			end
		end
		selected = math.clamp(selected, 1, math.max(1, #suggestions))
		local bad = a.Part == "unknown" or (a.Part ~= "command" and #a.Errors > 0) or (a.Part == "command" and a.Partial ~= "" and #suggestions == 0)
		box.TextColor3 = if bad then ERROR_COLOR else P.Text
		renderPopup()
	end

	accept = function(index: number?)
		local s = suggestions[index or selected]
		local a = analysis
		if not s or not a then
			return
		end
		local text = box.Text
		local trailer = if a.Part == "command" or a.Part == "unknown" then " " else a.Trailer
		setText(text:sub(1, a.ReplaceStart - 1) .. s.Text .. trailer)
		selected = 1
		box:CaptureFocus()
		task.defer(function()
			box.CursorPosition = #box.Text + 1
		end)
		if refresh then
			refresh()
		end
	end

	local function run()
		local text = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if text == "" then
			return
		end
		setText("")
		popup.Visible = false
		CommandBar.Print(("<font color=\"%s\">%s</font>%s"):format(hex(P.Prompt), esc(promptText()), esc(text)))
		if history[#history] ~= text then
			table.insert(history, text)
			if #history > 50 then
				table.remove(history, 1)
			end
		end
		historyIndex = #history + 1
		if text:lower() == "cls" then
			table.clear(logLines)
			if renderLog then
				renderLog()
			end
			return
		end
		local remote = SentinelShared:FindFirstChild("ExecuteCommandRemote") :: RemoteEvent?
		if remote then
			pendingResults += 1
			remote:FireServer(text)
		end
	end

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if suppress then
			return
		end
		if box.Text:find("\t", 1, true) then
			setText((box.Text:gsub("\t", "")))
			return
		end
		selected = 1
		if refresh then
			refresh()
		end
	end)

	box.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			run()
			task.defer(function()
				if isOpen then
					box:CaptureFocus()
				end
			end)
		end
	end)

	-- Returns true when the key was used.
	handleKey = function(key: Enum.KeyCode): boolean
		if key == Enum.KeyCode.Escape then
			CommandBar.Close()
			return true
		elseif key == Enum.KeyCode.Tab then
			accept(nil)
			return true
		elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.Down then
			local down = key == Enum.KeyCode.Down
			if popup.Visible and #suggestions > 1 then
				selected = if down then (selected % #suggestions) + 1 else ((selected - 2) % #suggestions) + 1
				renderPopup()
			elseif #history > 0 then
				historyIndex = math.clamp(historyIndex + (if down then 1 else -1), 1, #history + 1)
				setText(history[historyIndex] or "")
				task.defer(function()
					box.CursorPosition = #box.Text + 1
				end)
				if refresh then
					refresh()
				end
			end
			return true
		end
		return false
	end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------
function CommandBar.IsOpen(): boolean
	return isOpen
end

-- keepText: reopened after a rebuild (preferences changed) - don't wipe
-- what the player is typing.
function CommandBar.Open(initialText: string?, keepText: boolean?)
	if not initialized or not screenGui or not window or not inputBox then
		return
	end
	local gui, win, box = screenGui, window, inputBox
	isOpen = true
	gui.Enabled = true
	historyIndex = #history + 1
	-- Slide in from the edge it is docked to.
	local atBottom = prefs.CommandBar.Position == "bottom"
	local shown = UDim2.new(0.5, 0, if atBottom then 1 else 0, 0)
	win.Position = UDim2.new(0.5, 0, if atBottom then 1 else 0, if atBottom then 40 else -40)
	Theme.tween(win, Theme.Motion.Normal, { Position = shown })
	task.spawn(function()
		fetchCommands()
		fetchAutocomplete()
		if #logLines == 0 then
			CommandBar.Print("Use the help command to see all available commands. Tab completes, Esc closes.", palette().Muted)
		end
		-- The key that opened the bar may type its own character: wait a
		-- frame, then start from the intended text.
		task.wait()
		if isOpen and inputBox == box then
			box:CaptureFocus()
			if not keepText then
				task.wait()
				box.Text = initialText or ""
			end
			box.CursorPosition = #box.Text + 1
		end
	end)
end

function CommandBar.Close()
	if not screenGui then
		return
	end
	isOpen = false
	if inputBox then
		inputBox:ReleaseFocus()
	end
	screenGui.Enabled = false
end

function CommandBar.Toggle()
	if isOpen then
		CommandBar.Close()
	else
		CommandBar.Open()
	end
end

function CommandBar.ApplyPrefs(newPrefs: any)
	prefs = UIPrefs.Merge(UIPrefs.BUILTIN, newPrefs)
	if not initialized then
		return
	end
	local wasOpen = isOpen
	local typed = if inputBox then inputBox.Text else ""
	build()
	if wasOpen then
		if inputBox then
			inputBox.Text = typed
		end
		CommandBar.Open(nil, true)
	end
end

function CommandBar.Init(initialPrefs: any)
	if initialized then
		CommandBar.ApplyPrefs(initialPrefs)
		return
	end
	prefs = UIPrefs.Merge(UIPrefs.BUILTIN, initialPrefs)
	initialized = true
	build()

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local focused = inputBox ~= nil and inputBox:IsFocused()
		if input.KeyCode.Name == prefs.CommandBar.Key then
			-- Don't steal the key while the player types somewhere else.
			if isOpen and (focused or not gameProcessed) then
				-- Keys that also type a character only close an empty bar.
				if input.KeyCode.Name:sub(1, 1) == "F" or (inputBox and inputBox.Text == "") then
					CommandBar.Close()
				end
			elseif not isOpen and not gameProcessed then
				CommandBar.Open()
			end
			return
		end
		-- Esc releases the text box's focus before this fires, so it is
		-- handled whether or not the box still has focus.
		if isOpen and input.KeyCode == Enum.KeyCode.Escape then
			CommandBar.Close()
			return
		end
		if isOpen and focused and handleKey then
			handleKey(input.KeyCode)
		end
	end)

	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function(results: any)
			-- Only echo results of commands typed here (or while it is open).
			if type(results) ~= "table" or (pendingResults <= 0 and not isOpen) then
				return
			end
			pendingResults = math.max(0, pendingResults - 1)
			for _, result in ipairs(results) do
				if type(result) == "table" and type(result.Message) == "string" then
					local color = if result.Success then nil elseif result.NeedsConfirmation then Color3.fromRGB(240, 190, 80) else ERROR_COLOR
					local text = esc(result.Message)
					if result.NeedsConfirmation then
						text ..= "  (type: confirm)"
					end
					CommandBar.Print(text, color)
				elseif type(result) == "table" and result.Success then
					CommandBar.Print("Command executed.", SUCCESS_COLOR)
				end
			end
		end)
	end
end

return CommandBar
