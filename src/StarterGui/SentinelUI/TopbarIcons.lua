--!strict
--[[
	TopbarIcons.lua (Roblox-style redesign)

	Purpose:
		Sentinel's buttons in Roblox's top bar, next to the Roblox menu,
		chat and other experience buttons: one dark pill holding a round
		button per tool (Sentinel panel, command bar). Hover shows a tooltip
		under the button; the button of an open tool stays highlighted.

		Roblox does not let experiences put buttons inside its own top bar,
		so (like every top-bar icon library) this is a ScreenGui that
		ignores the GUI inset and sits in the free space Roblox reports in
		GuiService.TopbarInset (to the right of Roblox's own buttons).

	Instance paths (Studio MCP): PlayerGui.SentinelTopbar.Group.<Id>Button

	Public API:
		TopbarIcons.Init(icons: { Icon }): ScreenGui
			Icon = { Id, Glyph, Font?, GlyphSize?, Tooltip, OnClick: () -> (),
			         IsActive: (() -> boolean)? }
		TopbarIcons.SetVisible(id, visible)
		TopbarIcons.SetBadge(id, on)   -- red dot (AntiCheat: unreviewed high-severity flags)
		TopbarIcons.Add(icon)          -- add a button after Init (AntiCheat "AC")
--]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TopbarIcons = {}

export type Icon = {
	Id: string,
	Glyph: string,
	Font: Enum.Font?,
	GlyphSize: number?,
	Tooltip: string,
	OnClick: () -> (),
	IsActive: (() -> boolean)?,
}

-- Roblox's top bar look: near-black pills, white glyphs, a soft white
-- circle behind the active / hovered button.
local PILL_COLOR = Color3.fromRGB(18, 18, 21)
local PILL_TRANSPARENCY = 0.08
local HIGHLIGHT = Color3.fromRGB(255, 255, 255)
local HOVER_TRANSPARENCY = 0.9
local ACTIVE_TRANSPARENCY = 0.82
local FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local buttons: { [string]: TextButton } = {}
local screenGui: ScreenGui? = nil

local function corner(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = parent
end

-- Seasonal themes: an image replaces a button's glyph (nil = glyph back).
-- Remembered so it also applies when Init runs later.
local seasonImages: { [string]: string? } = {}

local function applyImage(id: string)
	local button = buttons[id]
	if not button then
		return
	end
	local image = seasonImages[id]
	local label = button:FindFirstChild("SeasonImage") :: ImageLabel?
	if image and not label then
		local l = Instance.new("ImageLabel")
		l.Name = "SeasonImage"
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0.5, 0.5)
		l.Position = UDim2.fromScale(0.5, 0.5)
		l.Size = UDim2.fromScale(0.72, 0.72)
		l.ScaleType = Enum.ScaleType.Fit
		l.Parent = button
		label = l
	end
	if label then
		label.Image = image or ""
		label.Visible = image ~= nil
	end
	button.TextTransparency = if image then 1 else 0
end

function TopbarIcons.SetImage(id: string, image: string?)
	seasonImages[id] = image
	applyImage(id)
end

function TopbarIcons.SetVisible(id: string, visible: boolean)
	local button = buttons[id]
	if button then
		button.Visible = visible
	end
end

function TopbarIcons.SetBadge(id: string, on: boolean)
	local button = buttons[id]
	if not button then
		return
	end
	local dot = button:FindFirstChild("Badge") :: Frame?
	if not dot then
		local d = Instance.new("Frame")
		d.Name = "Badge"
		d.AnchorPoint = Vector2.new(1, 0)
		d.Position = UDim2.new(1, -2, 0, 2)
		d.Size = UDim2.fromOffset(9, 9)
		d.BackgroundColor3 = Color3.fromRGB(235, 70, 70)
		d.BorderSizePixel = 0
		d.ZIndex = 3
		d.Parent = button
		corner(d)
		dot = d
	end
	(dot :: Frame).Visible = on
end

local pendingIcons: { Icon } = {}
local addIcon: ((Icon) -> ())? = nil

-- Adds a button after Init (or queues it until Init runs).
function TopbarIcons.Add(icon: Icon)
	if buttons[icon.Id] then
		return
	end
	if addIcon then
		addIcon(icon)
	else
		table.insert(pendingIcons, icon)
	end
end

function TopbarIcons.Init(icons: { Icon }): ScreenGui
	if screenGui then
		return screenGui
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SentinelTopbar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 70
	gui.Parent = playerGui
	screenGui = gui

	local group = Instance.new("Frame")
	group.Name = "Group"
	group.AutomaticSize = Enum.AutomaticSize.X
	group.BackgroundColor3 = PILL_COLOR
	group.BackgroundTransparency = PILL_TRANSPARENCY
	group.BorderSizePixel = 0
	group.Parent = gui
	corner(group)
	local pad = Instance.new("UIPadding")
	pad.Parent = group
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = group

	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "Tooltip"
	tooltip.AutomaticSize = Enum.AutomaticSize.X
	tooltip.Size = UDim2.fromOffset(0, 28)
	tooltip.AnchorPoint = Vector2.new(0.5, 0)
	tooltip.BackgroundColor3 = PILL_COLOR
	tooltip.BackgroundTransparency = PILL_TRANSPARENCY
	tooltip.BorderSizePixel = 0
	tooltip.Font = Enum.Font.BuilderSansMedium
	tooltip.TextSize = 15
	tooltip.TextColor3 = Color3.fromRGB(247, 247, 248)
	tooltip.Visible = false
	tooltip.ZIndex = 5
	tooltip.Parent = gui
	local tipCorner = Instance.new("UICorner")
	tipCorner.CornerRadius = UDim.new(0, 8)
	tipCorner.Parent = tooltip
	local tipPad = Instance.new("UIPadding")
	tipPad.PaddingLeft = UDim.new(0, 10)
	tipPad.PaddingRight = UDim.new(0, 10)
	tipPad.Parent = tooltip

	local hovered: TextButton? = nil

	local function showTooltip(button: TextButton, text: string)
		-- Touch screens have no hover: a tap would leave the tooltip stuck.
		if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
			return
		end
		tooltip.Text = text
		-- AbsolutePosition is measured from below Roblox's bar, Position
		-- offsets from the screen top (gui.AbsolutePosition = (0, -inset)).
		local origin = gui.AbsolutePosition
		tooltip.Position = UDim2.fromOffset(
			math.round(button.AbsolutePosition.X - origin.X + button.AbsoluteSize.X / 2),
			math.round(group.AbsolutePosition.Y - origin.Y + group.AbsoluteSize.Y + 8)
		)
		tooltip.Visible = true
	end

	local function makeButton(icon: Icon, i: number)
		local button = Instance.new("TextButton")
		button.Name = icon.Id .. "Button"
		button.LayoutOrder = i
		button.BackgroundColor3 = HIGHLIGHT
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.BorderSizePixel = 0
		button.Font = icon.Font or Enum.Font.BuilderSansExtraBold
		button.TextSize = icon.GlyphSize or 20
		button:SetAttribute("GlyphSize", button.TextSize)
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Text = icon.Glyph
		button.Parent = group
		corner(button)
		buttons[icon.Id] = button

		local function restingTransparency(): number
			return if icon.IsActive and icon.IsActive() then ACTIVE_TRANSPARENCY else 1
		end
		button.MouseEnter:Connect(function()
			hovered = button
			TweenService:Create(button, FAST, { BackgroundTransparency = math.min(HOVER_TRANSPARENCY, restingTransparency()) }):Play()
			showTooltip(button, icon.Tooltip)
		end)
		button.MouseLeave:Connect(function()
			if hovered == button then
				hovered = nil
				tooltip.Visible = false
			end
			TweenService:Create(button, FAST, { BackgroundTransparency = restingTransparency() }):Play()
		end)
		button.Activated:Connect(function()
			tooltip.Visible = false
			icon.OnClick()
		end)
		button:SetAttribute("Active", false)
	end
	for i, icon in ipairs(icons) do
		makeButton(icon, i)
	end

	-- Follow Roblox's top bar: its height and the free space to the right
	-- of Roblox's own buttons. Fallback = the classic 36 px bar.
	local function place()
		local inset = GuiService.TopbarInset
		local height = inset.Height
		if height <= 0 then
			height = 36
		end
		-- Desktop's new bar (58) gets 44 px pills like Roblox's own; the
		-- shorter phone / classic bars get smaller ones that still fit.
		local pillHeight = math.clamp(height - 14, 30, 44)
		local buttonSize = pillHeight - 4
		local y = math.max(0, height - pillHeight - 2) -- Roblox's pills sit 2 px above the inset bottom
		local touchOnly = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
		if touchOnly then
			-- Phones: Roblox's left pills (menu, chat, mic) are wider than
			-- the space TopbarInset reports, so they covered this pill. The
			-- right end of the bar is free on mobile.
			local right = if inset.Width > 0 then inset.Max.X else gui.AbsoluteSize.X - 16
			group.AnchorPoint = Vector2.new(1, 0)
			group.Position = UDim2.fromOffset(right - 8, y)
		else
			local left = if inset.Width > 0 then inset.Min.X else 104
			group.AnchorPoint = Vector2.new(0, 0)
			group.Position = UDim2.fromOffset(left + 4, y)
		end
		group.Size = UDim2.fromOffset(0, pillHeight)
		pad.PaddingLeft = UDim.new(0, 2)
		pad.PaddingRight = UDim.new(0, 2)
		for _, button in pairs(buttons) do
			button.Size = UDim2.fromOffset(buttonSize, buttonSize)
			local base = button:GetAttribute("GlyphSize") or 20
			button.TextSize = math.max(12, math.floor(base * buttonSize / 40))
		end
	end
	place()
	addIcon = function(icon: Icon)
		table.insert(icons, icon)
		makeButton(icon, #icons)
		place()
	end
	for _, icon in ipairs(pendingIcons) do
		addIcon(icon)
	end
	table.clear(pendingIcons)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)

	-- Keep the "open" highlight in sync with the panel / command bar,
	-- however they were opened (key, command, button).
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.15 then
			return
		end
		elapsed = 0
		local anyVisible = false
		for _, icon in ipairs(icons) do
			local button = buttons[icon.Id]
			if button then
				anyVisible = anyVisible or button.Visible
				local active = icon.IsActive ~= nil and icon.IsActive()
				if button:GetAttribute("Active") ~= active then
					button:SetAttribute("Active", active)
					if hovered ~= button then
						TweenService:Create(button, FAST, { BackgroundTransparency = if active then ACTIVE_TRANSPARENCY else 1 }):Play()
					end
				end
			end
		end
		group.Visible = anyVisible
	end)

	for id in pairs(seasonImages) do
		applyImage(id)
	end
	return gui
end

return TopbarIcons
