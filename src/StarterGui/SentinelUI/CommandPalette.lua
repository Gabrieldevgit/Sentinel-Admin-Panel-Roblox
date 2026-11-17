--!strict
--[[
	CommandPalette.lua

	Purpose:
		The floating command launcher (Ctrl+K by default, or the panel's search
		button). Executes through ExecuteCommandRemote, the same
		CommandProcessor path as chat, so permissions, cooldowns, risk
		confirmation and logging behave identically.

	W05 — typed autocomplete:
		- Fuzzy command + alias search; empty input shows recent commands
		  and the full (permission-filtered) command list.
		- Each command's typed Args (Shared/UsageSpec, built on the server)
		  drive context-aware suggestions for the argument under the cursor:
		  players (avatars + display names), selectors, teams, ranks,
		  durations, numbers, choices and custom types (Shared/ArgumentTypes).
		- Ghost text shows the completion of the selected suggestion; Tab
		  accepts it, ↑/↓ move the selection (or walk history on an empty
		  line), clicking a row accepts it.
		- Signature line marks <required> and [optional] arguments and
		  highlights the current one; the hint line describes it; the
		  validation line shows inline errors, what is still missing, or
		  "ready" with the permission node and risk.

	Public API:
		CommandPalette.Init(): ()
		CommandPalette.Open(initialText: string?): ()
		CommandPalette.Close(): ()
		CommandPalette.IsOpen(): boolean
		CommandPalette.ClearHistory(): ()
		CommandPalette.GetHistoryCount(): number
--]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local TextService = game:GetService("TextService")

local Theme = require(script.Parent:WaitForChild("Theme", 15))

local SentinelShared = ReplicatedStorage:WaitForChild("Shared", 15):WaitForChild("Sentinel", 15)
local ArgumentTypes = require(SentinelShared:WaitForChild("ArgumentTypes", 15))
local UsageSpec = require(SentinelShared:WaitForChild("UsageSpec", 15))
local CommandDocs = require(script.Parent:WaitForChild("CommandDocs", 15))

local CommandPalette = {}

local localPlayer = Players.LocalPlayer

type Suggestion = ArgumentTypes.Suggestion

local commandCache: { any }? = nil
local byInvocable: { [string]: any } = {}
local autocompleteData: any = nil
local autocompleteFetchedAt = 0
local history: { string } = {}
local MAX_HISTORY = 30
local MAX_ROWS = 40

-- Risk badge text/color for a command (from Core/CommandPolicy).
local function riskTag(meta: any): (string, Color3?)
	local owner = if meta.OwnerOnly then "  · OWNER ONLY" else ""
	if meta.Risk == "critical" then
		return "  ⛔ CRITICAL" .. owner, Theme.Colors.Error
	elseif meta.Risk == "high" then
		return "  ⚠ HIGH RISK" .. owner, Theme.Colors.Error
	elseif meta.Risk == "medium" then
		return "  ⚠ medium" .. owner, Theme.Colors.Warning
	end
	return owner, nil
end

local function hex(c: Color3): string
	return ("#%02X%02X%02X"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function esc(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- Subsequence fuzzy match with a contiguity bonus and a prefix bonus.
local function fuzzyScore(query: string, candidate: string): number?
	if query == "" then
		return 0
	end
	query = query:lower()
	candidate = candidate:lower()
	if candidate == query then
		return 1000
	end
	local qi, score, lastMatch = 1, 0, 0
	for ci = 1, #candidate do
		if qi > #query then
			break
		end
		if candidate:sub(ci, ci) == query:sub(qi, qi) then
			score += (if ci == lastMatch + 1 then 3 else 1)
			lastMatch = ci
			qi += 1
		end
	end
	if qi <= #query then
		return nil
	end
	if candidate:sub(1, #query) == query then
		score += 20
	end
	return score - #candidate * 0.05
end

local function fetchCommandList(): { any }
	if commandCache then
		return commandCache
	end
	local remote = SentinelShared:WaitForChild("GetCommandListRemote", 15) :: RemoteFunction?
	local ok, result = false, nil
	if remote then
		ok, result = pcall(function()
			return remote:InvokeServer()
		end)
	end
	if not ok or type(result) ~= "table" then
		return {} -- don't cache a failure; try again next keystroke/open
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

-- W07: the player's command library (favorites, presets, persisted recent).
local libraryCache: any = nil
local libraryFetchedAt = 0
local function fetchLibrary(force: boolean?): any
	if libraryCache and not force and os.clock() - libraryFetchedAt < 20 then
		return libraryCache
	end
	local remote = SentinelShared:FindFirstChild("GetCommandLibraryRemote") :: RemoteFunction?
	if not remote then
		return libraryCache
	end
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	if ok and type(result) == "table" then
		libraryCache = result
		libraryFetchedAt = os.clock()
	end
	return libraryCache
end

local function isFavorite(name: string): boolean
	return libraryCache ~= nil and table.find(libraryCache.Favorites or {}, name) ~= nil
end

local function fetchAutocompleteData()
	if autocompleteData and os.clock() - autocompleteFetchedAt < 30 then
		return
	end
	local remote = SentinelShared:FindFirstChild("GetAutocompleteDataRemote") :: RemoteFunction?
	if not remote then
		return
	end
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	if ok and type(result) == "table" then
		autocompleteData = result
		autocompleteFetchedAt = os.clock()
	end
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

local function resolve(name: string): any?
	fetchCommandList()
	return byInvocable[name:lower()]
end

local function label(parent: Instance, name: string, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Theme.Font.Regular
	l.TextSize = 12
	l.TextColor3 = Theme.Colors.TextSecondary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = ""
	for k, v in pairs(props) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
function CommandPalette.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelCommandPalette"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 200
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	CommandPalette.screenGui = screenGui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Parent = screenGui
	backdrop.MouseButton1Click:Connect(function()
		CommandPalette.Close()
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0.12, 0)
	panel.Size = UDim2.new(0, 680, 0, 470)
	panel.BackgroundColor3 = Theme.Colors.Surface
	panel.BorderSizePixel = 0
	panel.Parent = screenGui
	Theme.corner(panel, Theme.Radius.L)
	Theme.stroke(panel, Theme.Colors.Border, 1)
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(680, 520)
	sizeLimit.Parent = panel
	-- Narrow screens: shrink with the viewport.
	local function fit()
		local camera = workspace.CurrentCamera
		local width = if camera then camera.ViewportSize.X else 1000
		panel.Size = UDim2.new(0, math.min(680, width - 24), 0, 520)
	end
	fit()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end

	-- Input with a syntax-highlighted copy underneath (same font/size/
	-- padding so the characters line up). While the copy is shown, the
	-- TextBox's own text is transparent; it still owns the caret/editing.
	local inputHolder = Instance.new("Frame")
	inputHolder.Name = "InputHolder"
	inputHolder.Position = UDim2.new(0, 16, 0, 12)
	inputHolder.Size = UDim2.new(1, -32, 0, 40)
	inputHolder.BackgroundColor3 = Theme.Colors.SurfaceRaised
	inputHolder.ClipsDescendants = true
	inputHolder.Parent = panel
	Theme.corner(inputHolder, Theme.Radius.S)

	local ghost = label(inputHolder, "Highlight", {
		Size = UDim2.new(1, 0, 1, 0),
		Font = Theme.Font.Mono,
		TextSize = 18,
		TextColor3 = Theme.Colors.Text,
		TextTruncate = Enum.TextTruncate.None,
		RichText = true,
	})
	Theme.padding(ghost, 10)

	local inputBox = Instance.new("TextBox")
	inputBox.Name = "Input"
	inputBox.Size = UDim2.new(1, 0, 1, 0)
	inputBox.BackgroundTransparency = 1
	inputBox.Font = Theme.Font.Mono
	inputBox.TextSize = 18
	inputBox.TextColor3 = Theme.Colors.Text
	inputBox.PlaceholderText = "Type a command — e.g. ban Player1:30m Exploiting"
	inputBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	inputBox.Text = ""
	inputBox.ClearTextOnFocus = false
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.ZIndex = 2
	inputBox.Parent = inputHolder
	Theme.padding(inputBox, 10)
	CommandPalette.inputBox = inputBox

	-- Our own caret: while the highlighted copy is shown the TextBox text is
	-- transparent, so draw a caret that doesn't depend on it. "Code" is
	-- monospaced, so the caret's x = characters before it * glyph width.
	local caret = Instance.new("Frame")
	caret.Name = "Caret"
	caret.AnchorPoint = Vector2.new(0, 0.5)
	caret.Size = UDim2.new(0, 2, 0, 20)
	caret.BackgroundColor3 = Theme.Colors.Accent
	caret.BorderSizePixel = 0
	caret.Visible = false
	caret.ZIndex = 3
	caret.Parent = inputHolder
	local glyphWidth = TextService:GetTextSize("MMMMMMMMMM", inputBox.TextSize, inputBox.Font, Vector2.new(10000, 100)).X / 10
	local function placeCaret()
		local show = inputBox:IsFocused() and inputBox.TextTransparency >= 1 and inputBox.CursorPosition > 0
		caret.Visible = show
		if show then
			local before = inputBox.Text:sub(1, inputBox.CursorPosition - 1)
			caret.Position = UDim2.new(0, 10 + (utf8.len(before) or #before) * glyphWidth, 0.5, 0)
		end
	end
	inputBox.Focused:Connect(placeCaret)
	inputBox.FocusLost:Connect(placeCaret)
	task.spawn(function()
		local on = true
		while caret.Parent do
			task.wait(0.5)
			on = not on
			caret.BackgroundTransparency = if on then 0 else 1
		end
	end)

	local signature = label(panel, "Signature", {
		Position = UDim2.new(0, 16, 0, 58),
		Size = UDim2.new(1, -32, 0, 20),
		Font = Theme.Font.Mono,
		TextSize = 14,
		TextColor3 = Theme.Colors.TextSecondary,
		RichText = true,
	})
	local hint = label(panel, "Hint", {
		Position = UDim2.new(0, 16, 0, 80),
		Size = UDim2.new(1, -32, 0, 18),
		RichText = true,
	})
	local validation = label(panel, "Validation", {
		Position = UDim2.new(0, 16, 0, 100),
		Size = UDim2.new(1, -32, 0, 18),
		Font = Theme.Font.Medium,
	})
	local parse = label(panel, "Parse", {
		Position = UDim2.new(0, 16, 0, 120),
		Size = UDim2.new(1, -32, 0, 18),
		Font = Theme.Font.Mono,
		TextSize = 12,
		RichText = true,
	})
	-- Dry-run preview from the server: affected players (avatars), rank-
	-- protected skips, confirmation needed.
	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.Position = UDim2.new(0, 16, 0, 140)
	preview.Size = UDim2.new(1, -32, 0, 28)
	preview.BackgroundTransparency = 1
	preview.ClipsDescendants = true
	preview.Parent = panel
	local previewLayout = Instance.new("UIListLayout")
	previewLayout.FillDirection = Enum.FillDirection.Horizontal
	previewLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	previewLayout.Padding = UDim.new(0, 4)
	previewLayout.SortOrder = Enum.SortOrder.LayoutOrder
	previewLayout.Parent = preview
	CommandPalette.signature = signature
	CommandPalette.hint = hint
	CommandPalette.validation = validation

	local list = Instance.new("ScrollingFrame")
	list.Name = "Suggestions"
	list.Position = UDim2.new(0, 16, 0, 174)
	list.Size = UDim2.new(1, -32, 1, -214)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 2)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list
	CommandPalette.suggestionsFrame = list

	-- Docs viewer (F1, or "help <command>"): replaces the suggestion list.
	local docsHolder = Instance.new("Frame")
	docsHolder.Name = "DocsHolder"
	docsHolder.Position = list.Position
	docsHolder.Size = list.Size
	docsHolder.BackgroundTransparency = 1
	docsHolder.Visible = false
	docsHolder.Parent = panel

	local footer = label(panel, "Footer", {
		Position = UDim2.new(0, 16, 1, -32),
		Size = UDim2.new(1, -32, 0, 20),
		TextSize = 11,
	})
	local DEFAULT_FOOTER = "Tab complete · ↑↓ select · Enter run · F1 docs · Esc close · && chains"
	footer.Text = DEFAULT_FOOTER
	CommandPalette.footer = footer

	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function(results: any)
			if type(results) ~= "table" then
				return
			end
			for _, result in ipairs(results) do
				if type(result) == "table" and result.Message then
					footer.Text = (if result.Success then "✅ " else "❌ ") .. tostring(result.Message)
					footer.TextColor3 = if result.Success then Theme.Colors.Success else Theme.Colors.Error
				end
			end
		end)
	end

	-- -----------------------------------------------------------------------
	-- State + rendering
	-- -----------------------------------------------------------------------
	local suggestions: { Suggestion } = {}
	local selected = 1
	local analysis: any = nil
	local historyIndex = 0
	local suppress = false -- ignore our own Text writes

	local function setText(text: string)
		suppress = true
		inputBox.Text = text
		inputBox.CursorPosition = #text + 1
		suppress = false
	end

	local spans: { any } = {}
	local KIND_COLORS: { [string]: Color3 } = {
		command = Theme.Colors.Accent,
		unknown = Theme.Colors.TextSecondary,
		target = Color3.fromRGB(120, 220, 160),
		selector = Color3.fromRGB(190, 140, 255),
		modifier = Color3.fromRGB(255, 170, 90),
		duration = Color3.fromRGB(255, 170, 90),
		number = Color3.fromRGB(240, 200, 100),
		keyword = Color3.fromRGB(90, 210, 230),
		name = Color3.fromRGB(255, 130, 190),
		string = Theme.Colors.Text,
		text = Color3.fromRGB(215, 215, 185),
		prefix = Theme.Colors.TextSecondary,
		punct = Theme.Colors.TextSecondary,
		chain = Theme.Colors.TextSecondary,
		extra = Theme.Colors.TextSecondary,
		error = Theme.Colors.Error,
	}

	-- Paints the highlighted copy of the input plus the ghost completion.
	local function updateGhost()
		local text = inputBox.Text
		if text == "" or inputBox.TextBounds.X > inputHolder.AbsoluteSize.X - 60 then
			-- Empty, or the box has scrolled and a copy would not line up.
			ghost.Text = ""
			inputBox.TextTransparency = 0
			placeCaret()
			return
		end
		local out, pos = {}, 1
		for _, sp in ipairs(spans) do
			if sp.Start >= pos and sp.Stop <= #text then
				if sp.Start > pos then
					table.insert(out, esc(text:sub(pos, sp.Start - 1)))
				end
				local chunk = ('<font color="%s">%s</font>'):format(
					hex(KIND_COLORS[sp.Kind] or Theme.Colors.Text),
					esc(text:sub(sp.Start, sp.Stop))
				)
				table.insert(out, if sp.Kind == "error" then "<u>" .. chunk .. "</u>" else chunk)
				pos = sp.Stop + 1
			end
		end
		if pos <= #text then
			table.insert(out, esc(text:sub(pos)))
		end
		local s = suggestions[selected]
		if s and analysis and inputBox.CursorPosition == #text + 1 then
			local partial = analysis.Partial or ""
			if s.Text:lower():sub(1, #partial) == partial:lower() and #s.Text > #partial then
				table.insert(out, ('<font color="%s" transparency="0.35">%s</font>'):format(
					hex(Theme.Colors.TextSecondary),
					esc(s.Text:sub(#partial + 1))
				))
			end
		end
		ghost.Text = table.concat(out)
		inputBox.TextTransparency = 1
		placeCaret()
	end

	-- -----------------------------------------------------------------------
	-- Dry-run preview (server)
	-- -----------------------------------------------------------------------
	local previewSeq = 0
	local function clearPreview()
		for _, child in ipairs(preview:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	local function renderPreview(entries: { any })
		clearPreview()
		local phrases = {}
		local color = Theme.Colors.TextSecondary
		local shown: any = nil
		for _, e in ipairs(entries) do
			local phrase
			if e.Problem then
				phrase = ("✗ %s: %s"):format(tostring(e.Command), tostring(e.Problem))
				color = Theme.Colors.Error
			elseif e.RequiresTarget then
				local n = e.TargetCount or #e.Targets
				phrase = ("%s → %d player%s"):format(e.Command, n, if n == 1 then "" else "s")
				if (e.Blocked or 0) > 0 then
					phrase ..= (" · %d skipped (rank)"):format(e.Blocked)
				end
				shown = e
			else
				phrase = e.Command .. " (no targets)"
			end
			if e.NeedsConfirmation and not e.Problem then
				phrase ..= " · will ask to confirm"
				if color ~= Theme.Colors.Error then
					color = Theme.Colors.Warning
				end
			end
			table.insert(phrases, phrase)
		end
		local summary = label(preview, "Summary", {
			LayoutOrder = 0,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			TextColor3 = color,
			Text = "Preview: " .. table.concat(phrases, "  ⟶  "),
		})
		summary.TextTruncate = Enum.TextTruncate.None
		if shown then
			for i, t in ipairs(shown.Targets) do
				if i > 8 then
					label(preview, "More", {
						LayoutOrder = 100,
						Size = UDim2.new(0, 0, 1, 0),
						AutomaticSize = Enum.AutomaticSize.X,
						Text = ("+%d"):format((shown.TargetCount or #shown.Targets) - 8),
					})
					break
				end
				local img = Instance.new("ImageLabel")
				img.Name = "Target_" .. t.Name
				img.LayoutOrder = i
				img.Size = UDim2.new(0, 22, 0, 22)
				img.BackgroundColor3 = Theme.Colors.Border
				img.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(t.UserId)
				img.Parent = preview
				Theme.corner(img, UDim.new(1, 0))
			end
		end
	end

	local function schedulePreview(text: string, segments: { any })
		previewSeq += 1
		local seq = previewSeq
		clearPreview()
		local hasCommand = false
		for _, seg in ipairs(segments) do
			if seg.Command then
				hasCommand = true
			end
		end
		if not hasCommand then
			return
		end
		task.delay(0.3, function()
			if seq ~= previewSeq or not screenGui.Enabled then
				return
			end
			local remote = SentinelShared:FindFirstChild("PreviewCommandRemote") :: RemoteFunction?
			if not remote then
				return
			end
			local ok, result = pcall(function()
				return remote:InvokeServer(text)
			end)
			if seq == previewSeq and ok and type(result) == "table" then
				renderPreview(result)
			end
		end)
	end

	local function paintSelection()
		for _, row in ipairs(list:GetChildren()) do
			if row:IsA("TextButton") then
				local isSel = row.LayoutOrder == selected
				row.BackgroundTransparency = if isSel then 0 else 0.55
				local stroke = row:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Enabled = isSel
				end
			end
		end
		local row = list:FindFirstChild("Row_" .. selected)
		if row and row:IsA("GuiObject") then
			local top = row.AbsolutePosition.Y - list.AbsolutePosition.Y
			local bottom = top + row.AbsoluteSize.Y
			if top < 0 then
				list.CanvasPosition = Vector2.new(0, list.CanvasPosition.Y + top)
			elseif bottom > list.AbsoluteSize.Y then
				list.CanvasPosition = Vector2.new(0, list.CanvasPosition.Y + bottom - list.AbsoluteSize.Y)
			end
		end
		updateGhost()
	end

	local accept: (index: number?) -> ()

	local function renderRows()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		list.CanvasPosition = Vector2.zero
		for i, s in ipairs(suggestions) do
			if i > MAX_ROWS then
				break
			end
			local row = Instance.new("TextButton")
			row.Name = "Row_" .. i
			row.LayoutOrder = i
			row.Size = UDim2.new(1, -6, 0, 36)
			row.BackgroundColor3 = Theme.Colors.SurfaceRaised
			row.AutoButtonColor = false
			row.Text = ""
			row.Parent = list
			Theme.corner(row, Theme.Radius.S)
			Theme.stroke(row, Theme.Colors.Accent, 1)

			local x = 10
			if s.Image then
				local img = Instance.new("ImageLabel")
				img.Name = "Avatar"
				img.Size = UDim2.new(0, 26, 0, 26)
				img.Position = UDim2.new(0, 6, 0.5, -13)
				img.BackgroundColor3 = Theme.Colors.Border
				img.Image = s.Image
				img.Parent = row
				Theme.corner(img, UDim.new(1, 0))
				x = 40
			elseif s.Color then
				local swatch = Instance.new("Frame")
				swatch.Name = "Swatch"
				swatch.Size = UDim2.new(0, 10, 0, 10)
				swatch.Position = UDim2.new(0, 10, 0.5, -5)
				swatch.BackgroundColor3 = s.Color
				swatch.BorderSizePixel = 0
				swatch.Parent = row
				Theme.corner(swatch, UDim.new(1, 0))
				x = 28
			end

			local main = label(row, "Label", {
				Position = UDim2.new(0, x, 0, 0),
				Size = UDim2.new(0.45, -x, 1, 0),
				Font = Theme.Font.Bold,
				TextSize = 14,
				TextColor3 = (s :: any).LabelColor or Theme.Colors.Text,
				Text = s.Label or s.Text,
			})
			main.RichText = (s :: any).Rich == true
			label(row, "Detail", {
				Position = UDim2.new(0.45, 0, 0, 0),
				Size = UDim2.new(0.55, -10, 1, 0),
				Text = s.Detail or "",
			})

			row.MouseButton1Click:Connect(function()
				accept(i)
			end)
			row.MouseEnter:Connect(function()
				selected = i
				paintSelection()
			end)
		end
		paintSelection()
	end

	-- Command-name suggestions (fuzzy over names and aliases).
	local function commandSuggestions(query: string): { Suggestion }
		local out: { Suggestion } = {}
		local cmds = fetchCommandList()
		if query == "" then
			-- Recent first, then everything.
			local seen = {}
			for i = #history, math.max(1, #history - 4), -1 do
				local line = history[i]
				if not seen[line] then
					seen[line] = true
					table.insert(out, { Text = line, Label = line, Detail = "Recent", Whole = true } :: any)
				end
			end
			-- W07: saved presets, then favorites, then everything else.
			for _, preset in ipairs((libraryCache and libraryCache.Presets) or {}) do
				local name = if preset.Name:find("%s") then ('"%s"'):format(preset.Name) else preset.Name
				table.insert(out, {
					Text = "preset " .. name,
					Label = "▶ " .. preset.Name,
					LabelColor = Theme.Colors.Accent,
					Detail = "Preset: " .. preset.Text,
					Whole = true,
				} :: any)
			end
			local rest = {}
			for _, meta in ipairs(cmds) do
				local tag, tagColor = riskTag(meta)
				local fav = isFavorite(meta.Name)
				table.insert(if fav then out else rest, {
					Text = meta.Name,
					Label = (if fav then "★ " else "") .. meta.Name .. tag,
					LabelColor = tagColor,
					Detail = meta.Description,
				} :: any)
			end
			for _, entry in ipairs(rest) do
				table.insert(out, entry)
			end
			return out
		end

		local scored = {}
		for _, meta in ipairs(cmds) do
			local best = fuzzyScore(query, meta.Name)
			local via: string? = nil
			for _, alias in ipairs(meta.Aliases or {}) do
				local s = fuzzyScore(query, alias)
				if s and (not best or s > best) then
					best, via = s, alias
				end
			end
			if best then
				table.insert(scored, { Meta = meta, Score = best, Via = via })
			end
		end
		table.sort(scored, function(a, b)
			if a.Score == b.Score then
				return a.Meta.Name < b.Meta.Name
			end
			return a.Score > b.Score
		end)
		for _, entry in ipairs(scored) do
			local meta = entry.Meta
			local tag, tagColor = riskTag(meta)
			local aliasNote = if entry.Via then ("  (alias %s)"):format(entry.Via) else ""
			if isFavorite(meta.Name) then
				aliasNote = "  ★" .. aliasNote
			end
			table.insert(out, {
				-- Keep what the user typed if they're typing an alias.
				Text = entry.Via or meta.Name,
				Label = meta.Name .. aliasNote .. tag,
				LabelColor = tagColor,
				Detail = meta.Description,
			} :: any)
		end
		return out
	end

	local function renderSignature(meta: any, a: any)
		local accent = hex(Theme.Colors.Accent)
		local parts = { ("<b>%s</b>"):format(esc(meta.Name)) }
		for i, arg in ipairs(meta.Args or {}) do
			local active = a.ArgIndex == i and (a.Part == "arg" or a.Part == "selectorValue")
			local modActive = a.ArgIndex == i and a.Part == "modifier"
			local name = esc(arg.Name .. (if arg.Rest then "…" else ""))
			if active then
				name = ('<font color="%s"><b>%s</b></font>'):format(accent, name)
			end
			local s = if arg.Optional then "[" .. name .. "]" else "&lt;" .. name .. "&gt;"
			if arg.Modifier then
				local m = esc(arg.Modifier.Name)
				if modActive then
					m = ('<font color="%s"><b>%s</b></font>'):format(accent, m)
				end
				s ..= if arg.Modifier.Optional then "[:" .. m .. "]" else ":&lt;" .. m .. "&gt;"
			end
			table.insert(parts, s)
		end
		signature.Text = table.concat(parts, " ")
	end

	local function describeArg(arg: any, a: any): string
		local typeDef = ArgumentTypes.Get(arg.Type)
		local desc = arg.Description or (typeDef and typeDef.Description) or ""
		if a.Part == "selectorValue" then
			return ("<b>%s name</b> for the selector"):format(esc(arg.Type))
		end
		local req = if arg.Optional then "optional" else "required"
		local range = ""
		if arg.Min or arg.Max then
			range = (" · %s–%s"):format(tostring(arg.Min or "…"), tostring(arg.Max or "…"))
		end
		return ("<b>%s</b>  <i>%s · %s%s</i>  —  %s"):format(esc(arg.Name), req, esc(arg.Type), range, esc(desc))
	end

	local docsMode = false -- F1
	local docsShownFor: string? = nil

	local function showDocs(meta: any?, env: any)
		if not meta then
			docsHolder.Visible = false
			list.Visible = true
			docsShownFor = nil
			return
		end
		if docsShownFor ~= meta.Name then
			docsShownFor = meta.Name
			CommandDocs.Build(docsHolder, meta, {
				Env = env,
				OnExample = function(line: string)
					docsMode = false
					setText(line)
					inputBox:CaptureFocus()
					CommandPalette._refresh()
				end,
			})
		end
		docsHolder.Visible = true
		list.Visible = false
	end

	local function refresh()
		local text = inputBox.Text
		local env = buildEnv()
		analysis = UsageSpec.Analyze(text, resolve, env)
		local walked
		spans, walked = UsageSpec.Walk(text, resolve, env)
		local a = analysis
		suggestions = {}
		signature.Text = ""
		hint.Text = ""
		validation.Text = ""
		parse.Text = ""

		if a.Part == "command" then
			suggestions = commandSuggestions(a.Partial)
			if a.Partial == "" and #history == 0 then
				hint.Text = "Start typing a command name. Fuzzy matching works: <b>frz</b> → freeze."
			end
			local top = suggestions[1]
			local meta = top and not (top :: any).Whole and resolve(top.Text)
			if meta and a.Partial ~= "" then
				renderSignature(meta, { ArgIndex = 0 })
				hint.Text = esc(meta.Description or "")
			elseif a.Partial ~= "" and #suggestions == 0 then
				validation.Text = "✗ No command matches '" .. a.Partial .. "'"
				validation.TextColor3 = Theme.Colors.Error
			end
		elseif a.Part == "unknown" then
			validation.Text = "✗ " .. (a.Errors[1] or "Unknown command")
			validation.TextColor3 = Theme.Colors.Error
			suggestions = commandSuggestions(a.CommandWord)
			-- Accepting replaces the bad command word.
			local firstTok = UsageSpec.Tokenize(text:sub(1))[1]
			a.Partial = a.CommandWord
			a.ReplaceStart = if firstTok then (text:find(firstTok.Text, 1, true) or 1) else 1
		else
			local meta = a.Command
			renderSignature(meta, a)
			if a.Arg then
				hint.Text = describeArg(a.Arg, a)
				suggestions = ArgumentTypes.Suggest(a.Arg, a.Partial, env)
				if a.Partial ~= "" then
					-- Drop an exact match that is the only suggestion: nothing to add.
					if #suggestions == 1 and suggestions[1].Text == a.Partial then
						suggestions = {}
					end
				end
			elseif meta.Examples and #meta.Examples > 0 then
				hint.Text = "Examples: " .. esc(table.concat(meta.Examples, "   ·   "))
			end

			if #a.Errors > 0 then
				local extra = if #a.Errors > 1 then ("  (+%d more)"):format(#a.Errors - 1) else ""
				validation.Text = "✗ " .. a.Errors[1] .. extra
				validation.TextColor3 = Theme.Colors.Error
			elseif #a.Missing > 0 then
				local names = {}
				for _, m in ipairs(a.Missing) do
					table.insert(names, "<" .. m.Name .. ">")
				end
				validation.Text = "Still needed: " .. table.concat(names, " ")
				validation.TextColor3 = Theme.Colors.Warning
			else
				local tag = riskTag(meta)
				validation.Text = ("✓ Ready — Enter to run · needs %s%s"):format(meta.Permission, tag)
				validation.TextColor3 = if meta.Risk == "high" or meta.Risk == "critical"
					then Theme.Colors.Warning
					else Theme.Colors.Success
			end
		end

		-- Errors in earlier "&&" links.
		if validation.TextColor3 ~= Theme.Colors.Error or validation.Text == "" then
			for i = 1, #walked - 1 do
				if #walked[i].Errors > 0 then
					validation.Text = ("✗ Command %d: %s"):format(i, walked[i].Errors[1])
					validation.TextColor3 = Theme.Colors.Error
					break
				end
			end
		end

		-- Live parse of the segment being typed.
		local seg = walked[#walked]
		if seg and seg.Command then
			local parsed = UsageSpec.Breakdown(seg)
			parse.Text = ('<font color="%s">parsed</font>  %s%s%s'):format(
				hex(Theme.Colors.TextSecondary),
				if #walked > 1 then ("[%d/%d] "):format(#walked, #walked) else "",
				esc(seg.Command.Name),
				if parsed ~= "" then "  →  " .. esc(parsed) else ""
			)
		end
		schedulePreview(text, walked)

		-- Docs: F1 toggles them for the current command; "help <cmd>"
		-- shows them automatically.
		local docsMeta: any = nil
		if a.Command and a.Command.Name == "help" and a.Part ~= "command" then
			local word = text:match("(%S+)%s*$")
			local target = word and resolve(word)
			if target and target.Name ~= "help" then
				docsMeta = target
			end
		end
		if not docsMeta and docsMode then
			docsMeta = a.Command
			if not docsMeta and a.Part == "command" and suggestions[1] and not (suggestions[1] :: any).Whole then
				docsMeta = resolve(suggestions[1].Text)
			end
		end
		showDocs(docsMeta, env)

		selected = 1
		renderRows()
	end

	accept = function(index: number?)
		local s = suggestions[index or selected]
		if not s or not analysis then
			return
		end
		local text = inputBox.Text
		local newText: string
		if (s :: any).Whole then
			newText = s.Text
		else
			local trailer = if analysis.Part == "command" or analysis.Part == "unknown" then " " else analysis.Trailer
			newText = text:sub(1, analysis.ReplaceStart - 1) .. s.Text .. trailer
		end
		setText(newText)
		inputBox:CaptureFocus()
		task.defer(function()
			inputBox.CursorPosition = #inputBox.Text + 1
		end)
		refresh()
	end

	inputBox:GetPropertyChangedSignal("Text"):Connect(function()
		if suppress then
			return
		end
		-- Tab may type a tab character; strip it (accept happens in InputBegan).
		if inputBox.Text:find("\t", 1, true) then
			setText((inputBox.Text:gsub("\t", "")))
			return
		end
		footer.Text = DEFAULT_FOOTER
		footer.TextColor3 = Theme.Colors.TextSecondary
		refresh()
	end)
	inputBox:GetPropertyChangedSignal("CursorPosition"):Connect(updateGhost)

	local function executeCurrent()
		local text = inputBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
		text = text:gsub("^;", "")
		if text == "" then
			return
		end
		if history[#history] ~= text then
			table.insert(history, text)
			if #history > MAX_HISTORY then
				table.remove(history, 1)
			end
		end
		historyIndex = #history + 1
		local remote = SentinelShared:FindFirstChild("ExecuteCommandRemote") :: RemoteEvent?
		if remote then
			remote:FireServer(text)
		end
		footer.Text = "Running…"
		footer.TextColor3 = Theme.Colors.TextSecondary
		setText("")
		refresh()
	end

	inputBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed and screenGui.Enabled then
			executeCurrent()
			task.defer(function()
				if screenGui.Enabled then
					inputBox:CaptureFocus()
				end
			end)
		end
	end)

	-- Keys while the palette is open. The input box is focused, so
	-- gameProcessed is true for these — don't filter on it.
	UserInputService.InputBegan:Connect(function(input)
		if not screenGui.Enabled or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Escape then
			CommandPalette.Close()
		elseif key == Enum.KeyCode.Tab then
			accept(nil)
		elseif key == Enum.KeyCode.F1 then
			docsMode = not docsMode
			refresh()
		elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.Down then
			local down = key == Enum.KeyCode.Down
			if inputBox.Text == "" then
				historyIndex = #history + 1
			end
			local onHistory = inputBox.Text == "" or (historyIndex <= #history and inputBox.Text == history[historyIndex])
			if onHistory and #history > 0 then
				historyIndex = if down then math.min(#history + 1, historyIndex + 1) else math.max(1, historyIndex - 1)
				setText(history[historyIndex] or "")
				refresh()
			elseif #suggestions > 0 then
				local count = math.min(#suggestions, MAX_ROWS)
				selected = if down then (selected % count) + 1 else ((selected - 2) % count) + 1
				paintSelection()
			end
		end
	end)

	-- The open key (default Ctrl+K) is a W08 keybind preference,
	-- handled with the other shortcuts in init.client -> CommandPalette.Toggle.

	CommandPalette._refresh = refresh
	CommandPalette._resetDocs = function()
		docsMode = false
	end
	CommandPalette._accept = accept
	CommandPalette._setText = setText
end

function CommandPalette.Toggle()
	if CommandPalette.IsOpen() then
		CommandPalette.Close()
	else
		CommandPalette.Open()
	end
end

function CommandPalette.Open(initialText: string?)
	local gui = CommandPalette.screenGui
	if not gui then
		return
	end
	gui.Enabled = true
	CommandPalette._resetDocs()
	CommandPalette._setText(initialText or "")
	CommandPalette.inputBox:CaptureFocus()
	-- A shortcut that opened us can leave a "P" in the box.
	task.defer(function()
		local box = CommandPalette.inputBox
		if box.Text ~= (initialText or "") then
			CommandPalette._setText(initialText or "")
		end
		box.CursorPosition = #box.Text + 1
	end)
	CommandPalette._refresh()
	task.spawn(function()
		local hadCache = commandCache ~= nil
		fetchCommandList()
		fetchAutocompleteData()
		local hadLibrary = libraryCache ~= nil
		local lib = fetchLibrary()
		-- Seed the session history from the persisted "Recent" list once.
		if lib and #history == 0 and type(lib.Recent) == "table" then
			for i = math.min(#lib.Recent, MAX_HISTORY), 1, -1 do
				table.insert(history, lib.Recent[i])
			end
		end
		if (not hadCache or not hadLibrary) and gui.Enabled then
			CommandPalette._refresh()
		end
	end)
end

function CommandPalette.Close()
	if CommandPalette.screenGui then
		CommandPalette.screenGui.Enabled = false
		CommandPalette.inputBox:ReleaseFocus()
	end
end

function CommandPalette.IsOpen(): boolean
	return CommandPalette.screenGui ~= nil and CommandPalette.screenGui.Enabled
end

-- Called after the Library page changes favorites / presets.
function CommandPalette.InvalidateLibrary()
	libraryCache = nil
end

function CommandPalette.ClearHistory()
	table.clear(history)
end

function CommandPalette.GetHistoryCount(): number
	return #history
end

return CommandPalette
