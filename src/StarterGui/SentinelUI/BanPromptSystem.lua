--!strict
--[[
	BanPromptSystem.lua (W09, rewritten from the V4.3 ban prompt)

	Purpose:
		Modal that builds a ban for one player: temporary or permanent, a
		duration (chips or typed, e.g. 45m, 2d, 1w), and a reason. It only
		builds the command text and sends it as a normal command:

			ban <name>:<duration> <reason>      (duration "perm" = permanent)

		so permissions, rank protection, required reasons, the maximum ban
		duration, risk confirmation and logging all stay on the server.

	Used by the Players page "Ban" button.

	Stable names (Studio MCP): PlayerGui.SentinelBanPrompt.Card.{
		Type.TempButton, Type.PermButton, Durations.D_<label>,
		Durations.CustomBox, ReasonBox, Preview, Buttons.BanButton,
		Buttons.CancelButton }

	Public API:
		BanPromptSystem.Show(target: { Name: string, DisplayName: string? })
		BanPromptSystem.Close()
		BanPromptSystem.BuildCommand(name, permanent, duration, reason) -> string
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local BanPromptSystem = {}

local DURATIONS = { "1h", "6h", "12h", "1d", "3d", "7d", "14d", "30d" }
local DEFAULT_DURATION = "1d"

local current: ScreenGui? = nil

-- "1d", "45m", "2w" ... (number + unit). The server's DurationParser is
-- the authority; this only stops obviously wrong input early.
local function validDuration(text: string): boolean
	return text:match("^%d+[smhdwy]$") ~= nil or text:match("^%d+mo$") ~= nil
end

function BanPromptSystem.BuildCommand(name: string, permanent: boolean, duration: string, reason: string): string
	local modifier = if permanent then "perm" else duration
	local cleanReason = (reason:gsub("[%c]", " "):gsub("&&", "&"):match("^%s*(.-)%s*$")) :: string
	local text = ("ban %s:%s"):format(name, modifier)
	if cleanReason ~= "" then
		text ..= " " .. cleanReason
	end
	return text
end

function BanPromptSystem.Close()
	if current then
		current:Destroy()
		current = nil
	end
end

local function label(parent: Instance, name: string, text: string, size: number, font: Enum.Font, color: Color3, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.LayoutOrder = order
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size + 8)
	l.Font = font
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent: Instance, name: string, text: string, width: number, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.LayoutOrder = order
	b.Size = UDim2.new(0, width, 0, 30)
	b.BackgroundColor3 = Theme.Colors.SurfaceRaised
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Font = Theme.Font.Medium
	b.TextSize = 13
	b.TextColor3 = Theme.Colors.Text
	b.Text = text
	b.Parent = parent
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function row(parent: Instance, name: string, order: number, wraps: boolean): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.LayoutOrder = order
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, 0)
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.Parent = parent
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.Wraps = wraps
	l.Padding = UDim.new(0, 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = f
	return f
end

local function textBox(parent: Instance, name: string, placeholder: string, order: number): TextBox
	local box = Instance.new("TextBox")
	box.Name = name
	box.LayoutOrder = order
	box.Size = UDim2.new(1, 0, 0, 32)
	box.BackgroundColor3 = Theme.Colors.Background
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Theme.Font.Regular
	box.TextSize = 13
	box.TextColor3 = Theme.Colors.Text
	box.PlaceholderColor3 = Theme.Colors.TextSecondary
	box.PlaceholderText = placeholder
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = ""
	box.Parent = parent
	Theme.corner(box, Theme.Radius.S)
	Theme.stroke(box, Theme.Colors.Border, 1)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = box
	return box
end

function BanPromptSystem.Show(target: { Name: string, DisplayName: string? })
	BanPromptSystem.Close()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local executeRemote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):FindFirstChild("ExecuteCommandRemote") :: RemoteEvent?

	local gui = Instance.new("ScreenGui")
	gui.Name = "SentinelBanPrompt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 70
	gui.Parent = playerGui
	current = gui

	local shade = Instance.new("TextButton")
	shade.Name = "Shade"
	shade.Size = UDim2.new(1, 0, 1, 0)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BackgroundTransparency = 0.45
	shade.AutoButtonColor = false
	shade.Text = ""
	shade.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.new(0.5, 0, 0.5, 0)
	-- Fits a phone: never wider than the screen minus a margin.
	card.Size = UDim2.new(0.92, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.Colors.Surface
	card.BorderSizePixel = 0
	card.Parent = gui
	Theme.corner(card, Theme.Radius.L)
	Theme.stroke(card, Theme.Colors.Error, 1)
	Theme.padding(card, Theme.Spacing.L)
	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(460, math.huge)
	maxWidth.Parent = card
	local cardLayout = Instance.new("UIListLayout")
	cardLayout.Padding = UDim.new(0, 8)
	cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardLayout.Parent = card

	local shownName = if target.DisplayName and target.DisplayName ~= target.Name
		then ("%s (@%s)"):format(target.DisplayName, target.Name)
		else target.Name
	label(card, "Title", "Ban " .. shownName, 18, Theme.Font.Bold, Theme.Colors.Error, 1)
	label(card, "TypeLabel", "Type", 12, Theme.Font.Medium, Theme.Colors.TextSecondary, 2)
	local typeRow = row(card, "Type", 3, false)
	local tempButton = button(typeRow, "TempButton", "Temporary", 120, 1)
	local permButton = button(typeRow, "PermButton", "Permanent", 120, 2)

	local durationLabel = label(card, "DurationLabel", "Duration", 12, Theme.Font.Medium, Theme.Colors.TextSecondary, 4)
	local durations = row(card, "Durations", 5, true)
	local chips: { [string]: TextButton } = {}
	for i, d in ipairs(DURATIONS) do
		chips[d] = button(durations, "D_" .. d, d, 52, i)
	end
	local customBox = textBox(durations, "CustomBox", "other: 45m, 2w", #DURATIONS + 1)
	customBox.Size = UDim2.new(0, 120, 0, 30)

	label(card, "ReasonLabel", "Reason (shown to the player)", 12, Theme.Font.Medium, Theme.Colors.TextSecondary, 6)
	local reasonBox = textBox(card, "ReasonBox", "e.g. Exploiting", 7)

	local preview = label(card, "Preview", "", 12, Theme.Font.Mono, Theme.Colors.TextSecondary, 8)

	local buttons = row(card, "Buttons", 9, false)
	local banButton = button(buttons, "BanButton", "Ban", 110, 2)
	banButton.BackgroundColor3 = Theme.Colors.Error
	banButton.Font = Theme.Font.Bold
	banButton.TextColor3 = Color3.new(1, 1, 1)
	local cancelButton = button(buttons, "CancelButton", "Cancel", 90, 1)

	local permanent = false
	local duration = DEFAULT_DURATION

	local function commandText(): string
		return BanPromptSystem.BuildCommand(target.Name, permanent, duration, reasonBox.Text)
	end

	local function refresh()
		tempButton.BackgroundColor3 = if permanent then Theme.Colors.SurfaceRaised else Theme.Colors.Accent
		permButton.BackgroundColor3 = if permanent then Theme.Colors.Error else Theme.Colors.SurfaceRaised
		durationLabel.Visible = not permanent
		durations.Visible = not permanent
		for d, chip in pairs(chips) do
			chip.BackgroundColor3 = if d == duration then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		end
		local custom = customBox.Text:lower():gsub("%s", "")
		local customBad = custom ~= "" and not validDuration(custom)
		customBox.TextColor3 = if customBad then Theme.Colors.Error else Theme.Colors.Text
		banButton.Active = not customBad or permanent
		banButton.AutoButtonColor = banButton.Active
		banButton.BackgroundTransparency = if banButton.Active then 0 else 0.5
		preview.Text = ";" .. commandText()
	end

	tempButton.MouseButton1Click:Connect(function()
		permanent = false
		refresh()
	end)
	permButton.MouseButton1Click:Connect(function()
		permanent = true
		refresh()
	end)
	for d, chip in pairs(chips) do
		chip.MouseButton1Click:Connect(function()
			duration = d
			customBox.Text = ""
			refresh()
		end)
	end
	customBox:GetPropertyChangedSignal("Text"):Connect(function()
		local custom = customBox.Text:lower():gsub("%s", "")
		if validDuration(custom) then
			duration = custom
		elseif custom == "" and not chips[duration] then
			duration = DEFAULT_DURATION
		end
		refresh()
	end)
	reasonBox:GetPropertyChangedSignal("Text"):Connect(function()
		if #reasonBox.Text > 200 then
			reasonBox.Text = reasonBox.Text:sub(1, 200)
		end
		refresh()
	end)

	cancelButton.MouseButton1Click:Connect(BanPromptSystem.Close)
	shade.MouseButton1Click:Connect(BanPromptSystem.Close)
	local escConnection
	escConnection = UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			BanPromptSystem.Close()
		end
	end)
	gui.Destroying:Connect(function()
		escConnection:Disconnect()
	end)

	banButton.MouseButton1Click:Connect(function()
		if not banButton.Active then
			return
		end
		-- Risk confirmation (if any) comes back from the server as the
		-- usual ConfirmDialog.
		if executeRemote then
			executeRemote:FireServer(commandText(), { Source = "panel" })
		end
		BanPromptSystem.Close()
	end)

	refresh()
	return gui
end

return BanPromptSystem
