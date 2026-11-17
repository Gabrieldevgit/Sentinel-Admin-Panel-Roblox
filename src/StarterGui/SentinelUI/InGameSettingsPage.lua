--!strict
--[[
	InGameSettingsPage.lua (W08 rewrite - "Administration")

	Purpose:
		Server-wide administration settings (System > Administration):
		command prefixes, cooldown scale and overrides, default ban
		duration, maximum punishment, warning escalation, required reasons,
		log retention and default permissions. The list comes from
		Systems/AdminConfig through GetAdminConfigRemote; every change is a
		normal ";config <setting> <value>" command (node config.edit,
		logged, applied on every server).

		The older version of this file (V4.3 keybinds / theme import / rank
		list) was replaced: keybinds are KeybindsPage, themes AppearancePage,
		ranks RankManagementPage.

	Stable names: Toolbar.Refresh, Body.Row_<key>.{Input, Save, Reset}.

	Public API:
		InGameSettingsPage.Build(container)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local InGameSettingsPage = {}

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

function InGameSettingsPage.Build(container: Frame)
	local getRemote = SentinelShared:WaitForChild("GetAdminConfigRemote", 15) :: RemoteFunction
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent

	local data: any = nil
	local waitingFor: string? = nil

	make("TextLabel", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Administration",
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
		Text = "Server-wide settings, applied on every server. Same as ;config.",
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

	local load: () -> ()

	local function send(command: string)
		waitingFor = command
		say("Saving...", nil)
		executeRemote:FireServer(command, { Confirmed = true })
	end

	local function render()
		local scroll = body.CanvasPosition
		for _, child in ipairs(body:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		if not data then
			return
		end
		local canEdit = data.CanEdit == true
		if not canEdit then
			say("View only - changing these needs config.edit.", nil)
		end
		local order = 0
		local group: string? = nil
		for _, entry in ipairs(data.Entries) do
			if entry.Group ~= group then
				group = entry.Group
				order += 1
				make("TextLabel", {
					Name = "Group_" .. entry.Group,
					LayoutOrder = order,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -8, 0, 30),
					Font = Theme.Font.Bold,
					TextSize = 13,
					TextColor3 = Theme.Colors.TextSecondary,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Bottom,
					Text = entry.Group:upper(),
				}, body)
			end
			order += 1
			local row = make("Frame", {
				Name = "Row_" .. entry.Key,
				LayoutOrder = order,
				BackgroundColor3 = Theme.Colors.Surface,
				Size = UDim2.new(1, -8, 0, 92),
			}, body)
			Theme.corner(row, Theme.Radius.S)
			make("TextLabel", {
				Name = "Label",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 12, 0, 8),
				Size = UDim2.new(1, -24, 0, 18),
				Font = Theme.Font.Medium,
				TextSize = 13,
				TextColor3 = Theme.Colors.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = ("%s   ;config %s"):format(entry.Label, entry.Key),
			}, row)
			make("TextLabel", {
				Name = "Description",
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 12, 0, 27),
				Size = UDim2.new(1, -24, 0, 16),
				Font = Theme.Font.Regular,
				TextSize = 11,
				TextColor3 = Theme.Colors.TextSecondary,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = ("%s  Default: %s. Example: %s"):format(entry.Description, entry.Default, entry.Example),
			}, row)
			local input = make("TextBox", {
				Name = "Input",
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				Position = UDim2.new(0, 12, 0, 52),
				Size = UDim2.new(1, -200, 0, 28),
				Font = Theme.Font.Mono,
				TextSize = 13,
				TextColor3 = Theme.Colors.Text,
				PlaceholderColor3 = Theme.Colors.TextSecondary,
				PlaceholderText = entry.Example,
				ClearTextOnFocus = false,
				TextEditable = canEdit,
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = entry.Text,
			}, row)
			Theme.corner(input, Theme.Radius.S)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 8)
			pad.Parent = input
			if canEdit then
				local save = button(row, "Save", "Save", 80, 1)
				save.Position = UDim2.new(1, -178, 0, 52)
				save.BackgroundColor3 = Theme.Colors.Accent
				save.MouseButton1Click:Connect(function()
					local text = input.Text:gsub("[%c]", " ")
					if text:match("^%s*$") then
						text = "none"
					end
					send(("config %s %s"):format(entry.Key, text))
				end)
				input.FocusLost:Connect(function(enterPressed)
					if enterPressed then
						send(("config %s %s"):format(entry.Key, (input.Text:gsub("[%c]", " "))))
					end
				end)
				local reset = button(row, "Reset", "Reset", 80, 2)
				reset.Position = UDim2.new(1, -92, 0, 52)
				reset.MouseButton1Click:Connect(function()
					send(("config reset %s"):format(entry.Key))
				end)
			end
		end
		order += 1
		make("TextLabel", {
			Name = "Footer",
			LayoutOrder = order,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -8, 0, 40),
			Font = Theme.Font.Regular,
			TextSize = 11,
			TextWrapped = true,
			TextColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Panel look, command bar, keybinds and notification defaults for everyone: set your own on Appearance / Keybinds, then use \"Make this the server default\" (config.ui).",
		}, body)
		body.CanvasPosition = scroll
	end

	load = function()
		local ok, result = pcall(function()
			return getRemote:InvokeServer()
		end)
		if ok and type(result) == "table" and type(result.Entries) == "table" then
			data = result
			render()
		else
			say("Could not load the settings.", false)
		end
	end

	button(toolbar, "Refresh", "Refresh", 90, 1).MouseButton1Click:Connect(function()
		say("Server-wide settings, applied on every server. Same as ;config.", nil)
		load()
	end)

	-- Show the answer to our own ;config command, then reload.
	resultRemote.OnClientEvent:Connect(function(results: any)
		if not waitingFor or type(results) ~= "table" or type(results[1]) ~= "table" then
			return
		end
		local result = results[1]
		if result.Command == "config" or (tostring(result.Message or "")):find("config") then
			waitingFor = nil
			say(tostring(result.Message), result.Success == true)
			task.delay(0.2, load)
		end
	end)

	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			load()
		end
	end)
end

return InGameSettingsPage
