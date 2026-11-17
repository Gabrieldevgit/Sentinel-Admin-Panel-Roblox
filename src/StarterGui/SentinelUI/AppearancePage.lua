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
	OpenBar}.

	Public API:
		AppearancePage.Build(container, commandBar?)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))

local AppearancePage = {}

local SECTION_TITLES = { Panel = "Panel", CommandBar = "Command bar" }
local FIELD_LABELS = {
	Theme = "Theme",
	Accent = "Accent colour",
	Animations = "Animations",
	Scale = "Panel size",
	Preset = "Look",
	Position = "Position",
	Width = "Width",
	Opacity = "Background",
	FontSize = "Text size",
	MaxLines = "Output lines",
	Rows = "Suggestions shown",
	Key = "Open key",
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

function AppearancePage.Build(container: Frame, commandBar: any?)
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
		Text = "Appearance",
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
		Text = "Changes are saved for you straight away.",
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

	local function set(section: string, field: string, value: any)
		-- Show it at once; the server's answer confirms (or corrects) it.
		if snapshot then
			snapshot.Effective[section][field] = value
		end
		request("personal", { [section] = { [field] = value } })
	end

	local render: () -> ()

	local function buildToolbar()
		for _, child in ipairs(toolbar:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		button(toolbar, "ResetMine", "Use server default", 150, 1).MouseButton1Click:Connect(function()
			request("reset", nil)
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
		for _, section in ipairs({ "Panel", "CommandBar" }) do
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
				local personal = snapshot.Personal[section] ~= nil and snapshot.Personal[section][field] ~= nil
				local row = make("Frame", {
					Name = ("Row_%s_%s"):format(section, field),
					LayoutOrder = order,
					BackgroundColor3 = Theme.Colors.Surface,
					Size = UDim2.new(1, -8, 0, 52),
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
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, -10, 0.5, 0),
					Size = UDim2.new(1, -270, 0, 28),
				}, row)
				make("UIListLayout", {
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, 4),
				}, controls)

				if spec.Kind == "choice" then
					for i, option in ipairs(spec.Choices) do
						local hasSwatch = field == "Accent" or field == "Theme"
						local chip = button(controls, "Choice_" .. option, option, math.max(56, #option * 8 + 26) + (if hasSwatch then 14 else 0), i)
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
							swatch(chip, UIPrefs.THEMES[option].SurfaceRaised)
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
					local shown = if spec.Integer then tostring(value) elseif spec.Max <= 1.5 then ("%d%%"):format(value * 100 + 0.5) else tostring(value)
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
