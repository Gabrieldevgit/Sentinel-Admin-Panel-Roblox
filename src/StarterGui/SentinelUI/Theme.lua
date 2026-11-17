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

Theme.Radius = {
	S = UDim.new(0, 6),
	M = UDim.new(0, 10),
	L = UDim.new(0, 14),
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

-- Sets the palette from panel prefs ({ Theme, Accent, Animations }).
-- Returns the previous colours (for Retint).
function Theme.Apply(panel: any): { [string]: Color3 }
	local previous = table.clone(Theme.Colors)
	local set = UIPrefs.THEMES[panel and panel.Theme] or UIPrefs.THEMES[UIPrefs.BUILTIN.Panel.Theme]
	for key, color in pairs(set) do
		(Theme.Colors :: any)[key] = color
	end
	Theme.Colors.Accent = UIPrefs.ACCENTS[panel and panel.Accent] or UIPrefs.ACCENTS[UIPrefs.BUILTIN.Panel.Accent]
	Theme.Animations = not (panel and panel.Animations == false)
	return previous
end

local COLOR_PROPS = { "BackgroundColor3", "TextColor3", "ImageColor3", "PlaceholderColor3", "ScrollBarImageColor3", "BorderColor3" }

-- Recolours existing UI: any colour equal to an old palette colour becomes
-- the matching new one. Colours that were never palette colours stay.
function Theme.Retint(root: Instance, previous: { [string]: Color3 })
	local map: { { Color3 } } = {}
	for key, old in pairs(previous) do
		local new = (Theme.Colors :: any)[key]
		if new and new ~= old then
			table.insert(map, { old, new })
		end
	end
	if #map == 0 then
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
			for _, prop in ipairs(COLOR_PROPS) do
				swap(inst, prop)
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

-- Tween that respects the Animations preference (jumps to the goal when off).
function Theme.tween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween?
	if not Theme.Animations then
		for prop, value in pairs(goal) do
			(inst :: any)[prop] = value
		end
		return nil
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

return Theme
