--!strict
--[[
	Theme.lua

	Purpose:
		Single source of truth for Sentinel's UI colors, spacing, and
		typography, matching the "Mission Control" design spec (dark
		charcoal background, electric blue accent, restrained status
		colors) saved at /reference/UI-UX-design-docs/. Every UI module
		pulls from here instead of hardcoding colors, so a future theme
		switcher (Dark/Light/OLED, per the design doc) only has to swap
		this table.

	Public API:
		Theme.Colors, Theme.Font, Theme.Spacing, Theme.Radius, Theme.Motion
--]]

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(18, 18, 22),
	Surface = Color3.fromRGB(26, 26, 32),
	SurfaceRaised = Color3.fromRGB(34, 34, 42),
	Border = Color3.fromRGB(48, 48, 58),
	Accent = Color3.fromRGB(64, 156, 255), -- electric blue
	Success = Color3.fromRGB(87, 214, 130),
	Warning = Color3.fromRGB(240, 180, 60),
	Error = Color3.fromRGB(235, 87, 87),
	Text = Color3.fromRGB(240, 240, 245),
	TextSecondary = Color3.fromRGB(150, 150, 160),
}

Theme.Font = {
	Regular = Enum.Font.Gotham,
	Medium = Enum.Font.GothamMedium,
	Bold = Enum.Font.GothamBold,
	Black = Enum.Font.GothamBlack,
	Mono = Enum.Font.Code,
}

Theme.Spacing = {
	XS = 4,
	S = 8,
	M = 12,
	L = 20,
	XL = 32,
}

-- Roblox-style redesign: softer corners; Pill = fully rounded ends (the
-- Roblox top bar / menu look).
Theme.Radius = {
	S = UDim.new(0, 8),
	M = UDim.new(0, 12),
	L = UDim.new(0, 16),
	Pill = UDim.new(1, 0),
}

Theme.Motion = {
	Fast = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Normal = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Spring = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
}

-- ---------------------------------------------------------------------------
-- Dynamic themes (UI redesign). Theme.Colors is mutated in place, so every
-- module keeps reading Theme.Colors.X. Apply() before the pages are built;
-- when the theme changes later, Retint() recolours what already exists.
-- ---------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UIPrefs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("UIPrefs"))

Theme.Animations = true
Theme.ReducedMotion = false
Theme.AnimationSpeed = 1
Theme.IsLight = false

local BASE_MOTION = {
	Fast = { 0.15, Enum.EasingStyle.Quad },
	Normal = { 0.2, Enum.EasingStyle.Quad },
	Spring = { 0.3, Enum.EasingStyle.Back },
}

local FONT_KEYS = { "Regular", "Medium", "Bold", "Black" }

local function fontFamily(name: any): { Enum.Font }?
	local names = UIPrefs.FONTS[name]
	if not names then
		return nil
	end
	local out = {}
	for i, fontName in ipairs(names) do
		local ok, font = pcall(function()
			return (Enum.Font :: any)[fontName]
		end)
		if not ok or not font then
			return nil
		end
		out[i] = font
	end
	return out
end

-- Sets palette, fonts and motion from panel prefs. Returns the previous
-- colours and fonts (for Retint).
function Theme.Apply(panel: any): ({ [string]: Color3 }, { [string]: Enum.Font })
	local previous = table.clone(Theme.Colors)
	local previousFonts = table.clone(Theme.Font)
	local palette = UIPrefs.ResolvePalette(panel)
	for key, color in pairs(palette) do
		(Theme.Colors :: any)[key] = color
	end
	Theme.IsLight = UIPrefs.IsLight(palette)
	local family = fontFamily(panel and panel.Font) or fontFamily("Gotham")
	if family then
		for i, key in ipairs(FONT_KEYS) do
			(Theme.Font :: any)[key] = family[i]
		end
	end
	Theme.Animations = not (panel and panel.Animations == false)
	Theme.ReducedMotion = panel ~= nil and panel.ReducedMotion == true
	Theme.AnimationSpeed = if panel and type(panel.AnimationSpeed) == "number" then math.clamp(panel.AnimationSpeed, 0.25, 4) else 1
	for name, base in pairs(BASE_MOTION) do
		(Theme.Motion :: any)[name] = TweenInfo.new(base[1] / Theme.AnimationSpeed, base[2], Enum.EasingDirection.Out)
	end
	return previous, previousFonts
end

local COLOR_PROPS = { "BackgroundColor3", "TextColor3", "ImageColor3", "PlaceholderColor3", "ScrollBarImageColor3", "BorderColor3" }

-- Recolours existing UI: any colour equal to an old palette colour becomes
-- the matching new one. Colours that were never palette colours stay. Fonts
-- work the same way when previousFonts is given.
function Theme.Retint(root: Instance, previous: { [string]: Color3 }, previousFonts: { [string]: Enum.Font }?)
	local map: { { Color3 } } = {}
	for key, old in pairs(previous) do
		local new = (Theme.Colors :: any)[key]
		if new and new ~= old then
			table.insert(map, { old, new })
		end
	end
	local fontMap: { [Enum.Font]: Enum.Font } = {}
	local fontChanges = 0
	if previousFonts then
		for _, key in ipairs(FONT_KEYS) do
			local old, new = previousFonts[key], (Theme.Font :: any)[key]
			if old and new and old ~= new and fontMap[old] == nil then
				fontMap[old] = new
				fontChanges += 1
			end
		end
	end
	if #map == 0 and fontChanges == 0 then
		return
	end
	local function swap(inst: any, prop: string)
		local ok, value = pcall(function()
			return inst[prop]
		end)
		if ok and typeof(value) == "Color3" then
			for _, pair in ipairs(map) do
				if value == pair[1] then
					inst[prop] = pair[2]
					return
				end
			end
		end
	end
	local count = 0
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("GuiObject") then
			if #map > 0 then
				for _, prop in ipairs(COLOR_PROPS) do
					swap(inst, prop)
				end
			end
			if fontChanges > 0 and (inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox")) then
				local newFont = fontMap[(inst :: any).Font]
				if newFont then
					(inst :: any).Font = newFont
				end
			end
		elseif inst:IsA("UIStroke") then
			swap(inst, "Color")
		end
		count += 1
		if count % 1500 == 0 then
			task.wait()
		end
	end
end

-- Properties that move or resize things: reduced motion sets them at once.
local MOTION_PROPS = { Position = true, Size = true, Scale = true, Rotation = true, AnchorPoint = true, CanvasPosition = true }

-- Tween that respects the Animations, AnimationSpeed and ReducedMotion
-- preferences (jumps to the goal when animations are off).
function Theme.tween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween?
	if not Theme.Animations then
		for prop, value in pairs(goal) do
			(inst :: any)[prop] = value
		end
		return nil
	end
	if Theme.ReducedMotion then
		local rest = {}
		for prop, value in pairs(goal) do
			if MOTION_PROPS[prop] then
				(inst :: any)[prop] = value
			else
				rest[prop] = value
			end
		end
		if next(rest) == nil then
			return nil
		end
		goal = rest
	end
	local tween = TweenService:Create(inst, info, goal)
	tween:Play()
	return tween
end

-- Small helpers used all over the UI layer.
function Theme.corner(parent: Instance, radius: UDim?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or Theme.Radius.M
	corner.Parent = parent
	return corner
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Colors.Border
	stroke.Thickness = thickness or 1
	stroke.Parent = parent
	return stroke
end

function Theme.padding(parent: Instance, amount: number?)
	local pad = Instance.new("UIPadding")
	local px = UDim.new(0, amount or Theme.Spacing.M)
	pad.PaddingTop = px
	pad.PaddingBottom = px
	pad.PaddingLeft = px
	pad.PaddingRight = px
	pad.Parent = parent
	return pad
end

-- Two thin rotated bars = an "X" glyph that renders in every font (the
-- multiplication sign does not render in Gotham). Returns the holder.
function Theme.crossIcon(parent: Instance, size: number, color: Color3?, thickness: number?): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Cross"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.5, 0)
	holder.Size = UDim2.fromOffset(size, size)
	holder.BackgroundTransparency = 1
	holder.Parent = parent
	for _, rotation in ipairs({ 45, -45 }) do
		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.new(0.5, 0, 0.5, 0)
		bar.Size = UDim2.new(1.3, 0, 0, thickness or 2)
		bar.Rotation = rotation
		bar.BackgroundColor3 = color or Theme.Colors.Text
		bar.BorderSizePixel = 0
		bar.Parent = holder
		Theme.corner(bar, Theme.Radius.Pill)
	end
	return holder
end

-- How much the device enlarges text (phones with a larger system text
-- size render TextSize 14 noticeably bigger). 1 = no enlargement. Measured
-- by comparing a probe label's rendered TextBounds with TextService's
-- nominal size; cached for a few seconds.
local textScaleCache, textScaleAt = 1, -math.huge
function Theme.textScale(): number
	if os.clock() - textScaleAt < 5 then
		return textScaleCache
	end
	textScaleAt = os.clock()
	local ok, ratio = pcall(function()
		local player = game:GetService("Players").LocalPlayer
		local gui = player and player:FindFirstChildOfClass("PlayerGui")
		if not gui then
			return 1
		end
		local holder = Instance.new("ScreenGui")
		holder.Name = "SentinelTextProbe"
		holder.Enabled = true
		local probe = Instance.new("TextLabel")
		probe.Size = UDim2.fromOffset(400, 100)
		probe.BackgroundTransparency = 1
		probe.TextTransparency = 1
		probe.Font = Enum.Font.BuilderSans
		probe.TextSize = 14
		probe.Text = "Sentinel"
		probe.Parent = holder
		holder.Parent = gui
		local rendered = probe.TextBounds.Y
		local nominal = game:GetService("TextService"):GetTextSize("Sentinel", 14, Enum.Font.BuilderSans, Vector2.new(400, 100)).Y
		holder:Destroy()
		if rendered <= 0 or nominal <= 0 then
			return 1
		end
		return rendered / nominal
	end)
	textScaleCache = if ok and type(ratio) == "number" then math.clamp(ratio, 1, 2.5) else 1
	return textScaleCache
end

-- Start from the built-in look, so UI built before any prefs arrive (e.g.
-- the join notification for a player without the panel) already matches.
Theme.Apply(UIPrefs.BUILTIN.Panel)

return Theme
