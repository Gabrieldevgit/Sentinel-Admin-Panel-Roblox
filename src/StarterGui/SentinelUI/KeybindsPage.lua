--!strict
--[[
	KeybindsPage.lua (W08)

	Purpose:
		Keyboard shortcuts (System > Keybinds): open / close the panel, the
		command palette, quick fly / noclip / god, next / previous page, and
		custom shortcuts that run a command. Stored in the player's personal
		UI prefs (Shared/UIPrefs section "Keys"); init.client reads them.

		Click a key button, then press the key (with Ctrl / Shift / Alt if
		wanted). Esc cancels, Backspace clears. Owners can make the current
		keys the server default.

	Stable names: Toolbar.{ResetKeys, SaveDefault}, Body.Row_<Field>.Controls.
	{KeyButton, Clear}, Body.Bind_<i>.Remove, Body.AddBind.{KeyButton,
	CommandBox, Add}.

	Public API:
		KeybindsPage.Build(container)
		KeybindsPage.IsCapturing() -> boolean   -- init.client skips shortcuts
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))

local KeybindsPage = {}

local LABELS = {
	Panel = "Open / close panel",
	ClosePanel = "Close panel",
	Palette = "Command palette",
	QuickFly = "Quick fly",
	QuickNoclip = "Quick noclip",
	QuickGod = "Quick god mode",
	NextPage = "Next page",
	PrevPage = "Previous page",
}

local MODIFIER_KEYS = {
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.RightControl] = true,
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.RightShift] = true,
	[Enum.KeyCode.LeftAlt] = true,
	[Enum.KeyCode.RightAlt] = true,
}

local capturing = false

function KeybindsPage.IsCapturing(): boolean
	return capturing
end

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

-- Waits for one key press (with modifiers). Calls done(keyString | "None")
-- or done(nil) when cancelled.
local function captureKey(target: TextButton, done: (string?) -> ())
	if capturing then
		return
	end
	capturing = true
	local previousText = target.Text
	target.Text = "Press a key..."
	target.BackgroundColor3 = Theme.Colors.Warning
	local connection: RBXScriptConnection
	connection = UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard or MODIFIER_KEYS[input.KeyCode] then
			return
		end
		connection:Disconnect()
		-- Clear the flag after this frame so init.client's shortcut handler,
		-- which sees the same key press, still skips it.
		task.defer(function()
			capturing = false
		end)
		target.BackgroundColor3 = Theme.Colors.SurfaceRaised
		if input.KeyCode == Enum.KeyCode.Escape then
			target.Text = previousText
			done(nil)
			return
		elseif input.KeyCode == Enum.KeyCode.Backspace then
			done("None")
			return
		end
		local function down(a: Enum.KeyCode, b: Enum.KeyCode): boolean
			return UserInputService:IsKeyDown(a) or UserInputService:IsKeyDown(b)
		end
		local text = (if down(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl) then "Ctrl+" else "")
			.. (if down(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift) then "Shift+" else "")
			.. (if down(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt) then "Alt+" else "")
			.. input.KeyCode.Name
		local key = UIPrefs.ParseKey(text)
		if not key then
			target.Text = input.KeyCode.Name .. " can't be used"
			target.BackgroundColor3 = Theme.Colors.Error
			task.delay(1.2, function()
				target.Text = previousText
				target.BackgroundColor3 = Theme.Colors.SurfaceRaised
			end)
			done(nil)
			return
		end
		target.Text = key
		done(key)
	end)
end

function KeybindsPage.Build(container: Frame)
	local getRemote = SentinelShared:WaitForChild("GetUIPrefsRemote", 15) :: RemoteFunction
	local setRemote = SentinelShared:WaitForChild("SetUIPrefsRemote", 15) :: RemoteFunction
	local changedRemote = SentinelShared:WaitForChild("UIPrefsChangedRemote", 15) :: RemoteEvent

	local snapshot: any = nil

	make("TextLabel", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Keybinds",
	}, container)
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
		Text = "Click a key, then press the new one (Ctrl / Shift / Alt allowed). Esc cancels, Backspace clears.",
	}, container)
	local toolbar = make("Frame", {
		Name = "Toolbar",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 54),
		Size = UDim2.new(1, 0, 0, 28),
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

	local render: () -> ()

	local function setKey(field: string, value: string)
		if snapshot then
			snapshot.Effective.Keys[field] = value
		end
		request("personal", { Keys = { [field] = value } })
		render()
	end

	local function setCustom(list: { any })
		if snapshot then
			snapshot.Effective.Keys.Custom = list
		end
		request("personal", { Keys = { Custom = list } })
		render()
	end

	local function sectionTitle(order: number, text: string)
		make("TextLabel", {
			Name = "Section_" .. order,
			LayoutOrder = order,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -8, 0, 30),
			Font = Theme.Font.Bold,
			TextSize = 13,
			TextColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			Text = text:upper(),
		}, body)
	end

	local function row(name: string, order: number, label: string, description: string, warn: boolean?): Frame
		local r = make("Frame", {
			Name = name,
			LayoutOrder = order,
			BackgroundColor3 = Theme.Colors.Surface,
			Size = UDim2.new(1, -8, 0, 52),
		}, body)
		Theme.corner(r, Theme.Radius.S)
		make("TextLabel", {
			Name = "Label",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 12, 0, 8),
			Size = UDim2.new(0.5, -12, 0, 18),
			Font = Theme.Font.Medium,
			TextSize = 13,
			TextColor3 = Theme.Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = label,
		}, r)
		make("TextLabel", {
			Name = "Description",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 12, 0, 27),
			Size = UDim2.new(0.5, -12, 0, 16),
			Font = Theme.Font.Regular,
			TextSize = 11,
			TextColor3 = if warn then Theme.Colors.Warning else Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = description,
		}, r)
		local controls = make("Frame", {
			Name = "Controls",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.new(0.5, 0, 0, 28),
		}, r)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 4),
		}, controls)
		return r
	end

	local function buildToolbar()
		for _, child in ipairs(toolbar:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		button(toolbar, "ResetKeys", "Use server default keys", 170, 1).MouseButton1Click:Connect(function()
			request("reset", "Keys")
		end)
		if snapshot and snapshot.CanSetDefaults then
			local save = button(toolbar, "SaveDefault", "Make these the server default", 210, 2)
			save.BackgroundColor3 = Theme.Colors.Accent
			save.MouseButton1Click:Connect(function()
				if snapshot then
					request("default", { Keys = snapshot.Effective.Keys })
				end
			end)
		end
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
		local keys = snapshot.Effective.Keys
		local personal = snapshot.Personal.Keys or {}

		-- Which actions share a key (shown as a warning).
		local users: { [string]: { string } } = {}
		local function note(key: string?, who: string)
			if key and key ~= "None" then
				users[key] = users[key] or {}
				table.insert(users[key], who)
			end
		end
		for _, field in ipairs(UIPrefs.ORDER.Keys) do
			note(keys[field], LABELS[field] or field)
		end
		for _, bind in ipairs(keys.Custom or {}) do
			note(bind.Key, "custom: " .. bind.Command)
		end
		local function clash(key: string?, me: string): string?
			local list = key and users[key]
			if not list or #list < 2 then
				return nil
			end
			for _, who in ipairs(list) do
				if who ~= me then
					return "Also used by " .. who
				end
			end
			return nil
		end

		local order = 1
		sectionTitle(order, "Shortcuts")
		for _, field in ipairs(UIPrefs.ORDER.Keys) do
			order += 1
			local label = LABELS[field] or field
			local value = keys[field] or "None"
			local warning = clash(value, label)
			local desc = warning or (UIPrefs.SPEC.Keys[field].Description .. (if personal[field] ~= nil then "" else "  (server default)"))
			local r = row("Row_" .. field, order, label, desc, warning ~= nil)
			local controls = r:FindFirstChild("Controls") :: Frame
			local keyButton = button(controls, "KeyButton", value, 150, 1)
			keyButton.Font = Theme.Font.Mono
			keyButton.MouseButton1Click:Connect(function()
				captureKey(keyButton, function(key)
					if key then
						setKey(field, key)
					end
				end)
			end)
			button(controls, "Clear", "Clear", 60, 2).MouseButton1Click:Connect(function()
				setKey(field, "None")
			end)
		end

		order += 1
		sectionTitle(order, ("Custom shortcuts (%d / %d)"):format(#(keys.Custom or {}), UIPrefs.MAX_CUSTOM_BINDS))
		for i, bind in ipairs(keys.Custom or {}) do
			order += 1
			local warning = clash(bind.Key, "custom: " .. bind.Command)
			local r = row("Bind_" .. i, order, bind.Key, warning or ("Runs: " .. bind.Command), warning ~= nil)
			local controls = r:FindFirstChild("Controls") :: Frame
			button(controls, "Remove", "Remove", 80, 1).MouseButton1Click:Connect(function()
				local list = table.clone(keys.Custom)
				table.remove(list, i)
				setCustom(list)
			end)
		end

		order += 1
		local add = make("Frame", {
			Name = "AddBind",
			LayoutOrder = order,
			BackgroundColor3 = Theme.Colors.Surface,
			Size = UDim2.new(1, -8, 0, 44),
		}, body)
		Theme.corner(add, Theme.Radius.S)
		Theme.padding(add, 8)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		}, add)
		local pendingKey: string? = nil
		local addKey = button(add, "KeyButton", "Pick a key", 130, 1)
		addKey.Font = Theme.Font.Mono
		addKey.MouseButton1Click:Connect(function()
			captureKey(addKey, function(key)
				if key and key ~= "None" then
					pendingKey = key
				elseif key == "None" then
					addKey.Text = "Pick a key"
					pendingKey = nil
				end
			end)
		end)
		local commandBox = make("TextBox", {
			Name = "CommandBox",
			LayoutOrder = 2,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, -240, 0, 28),
			Font = Theme.Font.Mono,
			TextSize = 12,
			TextColor3 = Theme.Colors.Text,
			PlaceholderColor3 = Theme.Colors.TextSecondary,
			PlaceholderText = "command to run, e.g. heal me",
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
		}, add)
		Theme.corner(commandBox, Theme.Radius.S)
		local boxPad = Instance.new("UIPadding")
		boxPad.PaddingLeft = UDim.new(0, 8)
		boxPad.Parent = commandBox
		local addButton = button(add, "Add", "Add", 80, 3)
		addButton.BackgroundColor3 = Theme.Colors.Accent
		addButton.MouseButton1Click:Connect(function()
			local command = (commandBox.Text:gsub("^%s*[;:!%.]?", ""):match("^(.-)%s*$")) :: string
			if not pendingKey then
				say("Pick a key for the shortcut first.", false)
				return
			end
			if command == "" then
				say("Type the command the key should run.", false)
				return
			end
			local list = {}
			for _, bind in ipairs(keys.Custom or {}) do
				if bind.Key ~= pendingKey then
					table.insert(list, bind)
				end
			end
			if #list >= UIPrefs.MAX_CUSTOM_BINDS then
				say(("You can have %d custom shortcuts."):format(UIPrefs.MAX_CUSTOM_BINDS), false)
				return
			end
			table.insert(list, { Key = pendingKey, Command = command })
			setCustom(list)
		end)

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
			if not capturing then
				task.defer(render)
			end
		end
	end)
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible and not snapshot then
			load()
		end
	end)
	task.spawn(load)
end

return KeybindsPage
