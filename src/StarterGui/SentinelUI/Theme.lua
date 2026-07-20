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
