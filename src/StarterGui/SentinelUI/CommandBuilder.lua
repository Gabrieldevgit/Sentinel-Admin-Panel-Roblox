--!strict
--[[
	CommandBuilder.lua (W07)

	Purpose:
		Interactive command builder: a form generated from a command's
		typed arguments (Args, see Shared/UsageSpec) or from a template's
		{placeholders}. Each field validates with Shared/ArgumentTypes and
		offers quick-pick chips (players, durations, choices, ranks, ...).
		The command line is assembled live, dry-run previewed through
		PreviewCommandRemote, and can be run, opened in the palette or
		saved as a preset.

	Public API:
		CommandBuilder.Init(commandPalette)
		CommandBuilder.Open({ Command = "kick" })        -- by name
		CommandBuilder.Open({ Template = { Name, Text, Description? } })
		CommandBuilder.Open()                              -- pick a command
		CommandBuilder.Close()
		CommandBuilder.OnLibraryChanged : callback set by the Library page

	Widgets have stable names (Window.Top.CommandBox, Window.Fields.Field_<n>
	.Input, Window.Buttons.Run, ...) so Studio MCP mouse input can target them.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local ArgumentTypes = require(SentinelShared:WaitForChild("ArgumentTypes"))

local CommandBuilder = {}
CommandBuilder.OnLibraryChanged = nil :: (() -> ())?

local localPlayer = Players.LocalPlayer
local palette: any = nil
local gui: ScreenGui? = nil
local refs: any = {}

local commandList: { any }? = nil
local autocompleteData: any = nil

-- Current form state
type Field = { Key: string, Arg: any, Input: TextBox, Status: TextLabel, Value: string }
local fields: { Field } = {}
local mode = "command" -- "command" | "template"
local currentMeta: any = nil
local currentTemplate: any = nil
local previewToken = 0

local function remote(name: string): Instance?
	return SentinelShared:FindFirstChild(name)
end

local function fetchCommands(): { any }
	if commandList then
		return commandList
	end
	local r = remote("GetCommandListRemote") :: RemoteFunction?
	local ok, result = false, nil
	if r then
		ok, result = pcall(function()
			return r:InvokeServer()
		end)
	end
	if ok and type(result) == "table" then
		commandList = result
		return result
	end
	return {}
end

local function findCommand(name: string): any
	local lower = name:lower()
	for _, meta in ipairs(fetchCommands()) do
		if meta.Name:lower() == lower then
			return meta
		end
		for _, alias in ipairs(meta.Aliases or {}) do
			if alias:lower() == lower then
				return meta
			end
		end
	end
	return nil
end

local function env(): any
	return {
		Players = Players:GetPlayers(),
		Teams = Teams:GetTeams(),
		Ranks = (autocompleteData and autocompleteData.Ranks) or {},
		Commands = commandList or {},
		LocalPlayer = localPlayer,
	}
end

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
		Size = UDim2.new(0, width or 110, 0, 30),
		Font = Theme.Font.Medium,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

-- Quote values with spaces (except rest/text arguments, which take the rest of the line).
local function formatValue(value: string, rest: boolean): string
	if rest or not value:find("%s") then
		return value
	end
	return '"' .. value:gsub('"', "'") .. '"'
end

local function buildLine(): (string, { string })
	local problems = {}
	if mode == "template" and currentTemplate then
		local line = currentTemplate.Text:gsub("{([^{}]+)}", function(inner: string)
			local optional = inner:sub(-1) == "?"
			local key = (if optional then inner:sub(1, -2) else inner):match("^%s*([%w_]+)")
			for _, f in ipairs(fields) do
				if f.Key == key then
					if f.Value:match("%S") then
						return (f.Value:gsub("&&", "&"))
					end
					break
				end
			end
			if not optional then
				table.insert(problems, ("{%s} is required"):format(key or "?"))
			end
			return ""
		end)
		return (line:gsub("%s+", " "):match("^%s*(.-)%s*$")), problems
	end
	if not currentMeta then
		return "", { "Pick a command" }
	end
	local parts = { currentMeta.Name }
	for _, f in ipairs(fields) do
		if f.Key:sub(1, 4) == "mod:" then
			continue -- appended to its base argument below
		end
		local value = f.Value
		if value:match("%S") then
			local piece = formatValue(value, f.Arg.Rest == true or f.Arg.Type == "text")
			for _, m in ipairs(fields) do
				if m.Key == "mod:" .. f.Key and m.Value:match("%S") then
					piece ..= ":" .. m.Value:gsub("%s", "")
				end
			end
			table.insert(parts, piece)
		elseif not f.Arg.Optional then
			table.insert(problems, f.Arg.Name .. " is required")
		end
	end
	return table.concat(parts, " "), problems
end

local function refreshPreview()
	local line, problems = buildLine()
	refs.Line.Text = if line ~= "" then ";" .. line else ""
	for _, f in ipairs(fields) do
		local value = f.Value
		if value:match("%S") then
			local ok, msg = ArgumentTypes.Validate(f.Arg, value, env())
			f.Status.Text = if ok then "✓" else ("✗ " .. (msg or "invalid"))
			f.Status.TextColor3 = if ok then Theme.Colors.Success else Theme.Colors.Error
			if not ok then
				table.insert(problems, msg or (f.Arg.Name .. " is invalid"))
			end
		else
			f.Status.Text = if f.Arg.Optional then "optional" else "required"
			f.Status.TextColor3 = Theme.Colors.TextSecondary
		end
	end
	refs.Problems.Text = table.concat(problems, " · ")
	refs.Problems.TextColor3 = if #problems > 0 then Theme.Colors.Warning else Theme.Colors.Success
	if #problems == 0 and line ~= "" then
		refs.Problems.Text = "Ready to run."
	end
	refs.Run.AutoButtonColor = #problems == 0
	refs.Run.BackgroundColor3 = if #problems == 0 then Theme.Colors.Accent else Theme.Colors.SurfaceRaised

	-- Dry run (debounced): who it affects, confirmation, permission.
	previewToken += 1
	local token = previewToken
	refs.Preview.Text = ""
	if line == "" or #problems > 0 then
		return
	end
	task.delay(0.35, function()
		if token ~= previewToken then
			return
		end
		local r = remote("PreviewCommandRemote") :: RemoteFunction?
		if not r then
			return
		end
		local ok, previews = pcall(function()
			return r:InvokeServer(line)
		end)
		if token ~= previewToken or not ok or type(previews) ~= "table" then
			return
		end
		local lines = {}
		for _, p in ipairs(previews) do
			local text = p.Command or "?"
			if p.Problem then
				text ..= " — ✗ " .. p.Problem
			elseif p.RequiresTarget then
				local names = {}
				for _, t in ipairs(p.Targets or {}) do
					table.insert(names, t.DisplayName or t.Name)
				end
				text ..= (" — affects %d: %s"):format(p.TargetCount or #names, table.concat(names, ", "))
				if (p.Blocked or 0) > 0 then
					text ..= (" (skips %d higher-ranked)"):format(p.Blocked)
				end
			else
				text ..= " — ✓ allowed"
			end
			if p.NeedsConfirmation then
				text ..= " ⚠ asks for confirmation"
			end
			table.insert(lines, text)
		end
		refs.Preview.Text = table.concat(lines, "\n")
	end)
end

local function addChips(parent: Instance, field: Field)
	local chips = make("ScrollingFrame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 0, 24),
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
	}, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, chips)
	local suggestions = ArgumentTypes.Suggest(field.Arg, "", env())
	for i, s in ipairs(suggestions) do
		if i > 12 then
			break
		end
		local text = (s :: any).Text or tostring(s)
		local chip = make("TextButton", {
			Name = "Chip_" .. i,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 0, 22),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Font = Theme.Font.Regular,
			TextSize = 11,
			TextColor3 = Theme.Colors.Text,
			Text = "  " .. ((s :: any).Label or text) .. "  ",
		}, chips)
		Theme.corner(chip, Theme.Radius.S)
		chip.MouseButton1Click:Connect(function()
			field.Input.Text = text
		end)
	end
	if #suggestions == 0 then
		chips.Size = UDim2.new(1, 0, 0, 0)
	end
	return #suggestions > 0
end

local function addField(key: string, arg: any, label: string, order: number)
	local holder = make("Frame", {
		Name = "Field_" .. key:gsub("[^%w_]", "_"),
		BackgroundColor3 = Theme.Colors.Surface,
		Size = UDim2.new(1, -8, 0, 82),
		LayoutOrder = order,
	}, refs.Fields)
	Theme.corner(holder, Theme.Radius.S)
	Theme.padding(holder, 8)
	make("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.6, 0, 0, 16),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = label .. "  ·  " .. tostring(arg.Type) .. (if arg.Description then "  —  " .. arg.Description else ""),
	}, holder)
	local status = make("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.new(0.6, 0, 0, 0),
		Size = UDim2.new(0.4, 0, 0, 16),
		Font = Theme.Font.Regular,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, holder)
	local input = make("TextBox", {
		Name = "Input",
		Position = UDim2.new(0, 0, 0, 20),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Theme.Colors.Background,
		Font = Theme.Font.Mono,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = if arg.Optional then "(optional)" else "(required)",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, holder)
	Theme.corner(input, Theme.Radius.S)
	Theme.padding(input, 6)
	local field: Field = { Key = key, Arg = arg, Input = input, Status = status, Value = "" }
	table.insert(fields, field)
	input:GetPropertyChangedSignal("Text"):Connect(function()
		field.Value = input.Text
		refreshPreview()
	end)
	if not addChips(holder, field) then
		holder.Size = UDim2.new(1, -8, 0, 58)
	end
end

local function clearFields()
	table.clear(fields)
	for _, child in ipairs(refs.Fields:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function loadCommand(meta: any)
	mode, currentMeta, currentTemplate = "command", meta, nil
	clearFields()
	if not meta then
		refs.Info.Text = "Type a command name above, e.g. kick, freeze, givecurrency."
		refreshPreview()
		return
	end
	refs.CommandBox.Text = meta.Name
	refs.Info.Text = (meta.Description or "") .. "   " .. (meta.Usage or "")
	local order = 0
	for _, arg in ipairs(meta.Args or {}) do
		order += 1
		addField(arg.Name, arg, arg.Name, order)
		if arg.Modifier then
			order += 1
			addField("mod:" .. arg.Name, arg.Modifier, arg.Name .. " : " .. arg.Modifier.Name, order)
		end
	end
	if #fields == 0 then
		refs.Info.Text ..= "   (no arguments)"
	end
	refreshPreview()
end

local function loadTemplate(template: any)
	mode, currentMeta, currentTemplate = "template", nil, template
	clearFields()
	refs.CommandBox.Text = "template: " .. template.Name
	refs.Info.Text = (template.Description or "") .. "   " .. template.Text
	local seen, order = {}, 0
	for inner in template.Text:gmatch("{([^{}]+)}") do
		local optional = inner:sub(-1) == "?"
		local body = if optional then inner:sub(1, -2) else inner
		local name, typ = body:match("^%s*([%w_]+)%s*:%s*([%w_]+)%s*$")
		name = name or body:match("^%s*([%w_]+)")
		if name and not seen[name] then
			seen[name] = true
			typ = typ or name
			local arg = {
				Name = name,
				Type = if ArgumentTypes.Has(typ) then typ else "text",
				Optional = optional or nil,
			}
			order += 1
			addField(name, arg, name, order)
		end
	end
	refreshPreview()
end

function CommandBuilder.Init(commandPalette: any)
	palette = commandPalette
	local screen = make("ScreenGui", {
		Name = "SentinelCommandBuilder",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 60,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
	}, localPlayer:WaitForChild("PlayerGui"))
	gui = screen

	local dim = make("TextButton", {
		Name = "Dim",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
	}, screen)
	dim.MouseButton1Click:Connect(function()
		CommandBuilder.Close()
	end)

	local window = make("Frame", {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 18), -- below Roblox's top bar
		Size = UDim2.new(0.92, 0, 1, -72), -- fits small viewports; capped below
		BackgroundColor3 = Theme.Colors.Background,
		Active = true, -- clicks inside don't fall through to the backdrop
	}, screen)
	make("UISizeConstraint", { MaxSize = Vector2.new(580, 540), MinSize = Vector2.new(320, 330) }, window)
	Theme.corner(window, Theme.Radius.L)
	Theme.stroke(window, Theme.Colors.Border)
	Theme.padding(window, 14)
	refs.Window = window

	local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30) }, window)
	make("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 150, 1, 0),
		Font = Theme.Font.Bold,
		TextSize = 16,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Command builder",
	}, top)
	local commandBox = make("TextBox", {
		Name = "CommandBox",
		Position = UDim2.new(0, 160, 0, 0),
		Size = UDim2.new(1, -200, 1, 0),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Mono,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "command name…",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, top)
	Theme.corner(commandBox, Theme.Radius.S)
	Theme.padding(commandBox, 6)
	refs.CommandBox = commandBox
	commandBox.FocusLost:Connect(function()
		local text = commandBox.Text:gsub("^%s*[;:!%./]?", ""):match("^(%S*)") or ""
		if text:sub(1, 9) == "template:" then
			return
		end
		local meta = findCommand(text)
		if meta then
			if meta ~= currentMeta then
				loadCommand(meta)
			end
		else
			loadCommand(nil)
			refs.Info.Text = if text == "" then refs.Info.Text else ("Unknown command '%s'."):format(text)
		end
	end)
	local close = button(top, "Close", "X", Theme.Colors.Surface, 30)
	close.Position = UDim2.new(1, -30, 0, 0)
	close.MouseButton1Click:Connect(function()
		CommandBuilder.Close()
	end)

	refs.Info = make("TextLabel", {
		Name = "Info",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 36),
		Size = UDim2.new(1, 0, 0, 30),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "",
	}, window)

	local fieldsFrame = make("ScrollingFrame", {
		Name = "Fields",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 70),
		Size = UDim2.new(1, 0, 1, -244),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Border,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, window)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, fieldsFrame)
	refs.Fields = fieldsFrame

	local bottom = make("Frame", {
		Name = "Bottom",
		BackgroundColor3 = Theme.Colors.Surface,
		Position = UDim2.new(0, 0, 1, -168),
		Size = UDim2.new(1, 0, 0, 128),
	}, window)
	Theme.corner(bottom, Theme.Radius.S)
	Theme.padding(bottom, 8)
	refs.Line = make("TextLabel", {
		Name = "Line",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Font = Theme.Font.Mono,
		TextSize = 14,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, bottom)
	refs.Problems = make("TextLabel", {
		Name = "Problems",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 22),
		Size = UDim2.new(1, 0, 0, 16),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Warning,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	}, bottom)
	refs.Preview = make("TextLabel", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 42),
		Size = UDim2.new(1, 0, 1, -42),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Text = "",
	}, bottom)

	local buttons = make("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 1, -32),
		Size = UDim2.new(1, 0, 0, 32),
	}, window)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 8),
	}, buttons)
	local presetName = make("TextBox", {
		Name = "PresetName",
		Size = UDim2.new(0, 130, 0, 30),
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "preset name",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		ClearTextOnFocus = false,
		Text = "",
	}, buttons)
	Theme.corner(presetName, Theme.Radius.S)
	local save = button(buttons, "SavePreset", "Save preset")
	local openPalette = button(buttons, "OpenInPalette", "Open in palette")
	local run = button(buttons, "Run", "▶ Run", Theme.Colors.Accent, 90)
	refs.Run = run

	save.MouseButton1Click:Connect(function()
		local line, problems = buildLine()
		if #problems > 0 or line == "" then
			refs.Problems.Text = "Fix the form before saving."
			return
		end
		local name = presetName.Text:match("^%s*(.-)%s*$")
		if name == "" then
			refs.Problems.Text = "Give the preset a name first."
			presetName:CaptureFocus()
			return
		end
		local r = remote("UpdateCommandLibraryRemote") :: RemoteFunction?
		local ok, result = pcall(function()
			return (r :: RemoteFunction):InvokeServer("savePreset", { Name = name, Text = line })
		end)
		refs.Problems.Text = if ok and result then result.Message else "Couldn't save."
		if ok and result and result.Success then
			refs.Problems.TextColor3 = Theme.Colors.Success
			if palette and palette.InvalidateLibrary then
				palette.InvalidateLibrary()
			end
			if CommandBuilder.OnLibraryChanged then
				CommandBuilder.OnLibraryChanged()
			end
		end
	end)
	openPalette.MouseButton1Click:Connect(function()
		local line = buildLine()
		CommandBuilder.Close()
		if palette then
			palette.Open(line)
		end
	end)
	run.MouseButton1Click:Connect(function()
		local line, problems = buildLine()
		if #problems > 0 or line == "" then
			return
		end
		local r = remote("ExecuteCommandRemote") :: RemoteEvent?
		if r then
			r:FireServer(line)
		end
		CommandBuilder.Close()
	end)
end

function CommandBuilder.Open(options: any?)
	if not gui then
		return
	end
	local opts = options or {}
	(gui :: ScreenGui).Enabled = true
	refs.Preview.Text = ""
	task.spawn(function()
		local r = remote("GetAutocompleteDataRemote") :: RemoteFunction?
		if r and not autocompleteData then
			local ok, data = pcall(function()
				return r:InvokeServer()
			end)
			if ok then
				autocompleteData = data
			end
		end
		if opts.Template then
			loadTemplate(opts.Template)
		elseif opts.Command then
			local meta = findCommand(opts.Command)
			loadCommand(meta)
			if not meta then
				refs.CommandBox.Text = opts.Command
				refs.Info.Text = ("Unknown command '%s'."):format(opts.Command)
			end
		else
			refs.CommandBox.Text = ""
			loadCommand(nil)
			refs.CommandBox:CaptureFocus()
		end
	end)
end

function CommandBuilder.Close()
	if gui then
		(gui :: ScreenGui).Enabled = false
	end
	previewToken += 1
end

function CommandBuilder.IsOpen(): boolean
	return gui ~= nil and (gui :: ScreenGui).Enabled
end

return CommandBuilder
