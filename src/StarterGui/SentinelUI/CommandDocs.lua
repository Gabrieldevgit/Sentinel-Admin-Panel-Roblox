--!strict
--[[
	CommandDocs.lua

	Purpose:
		Command documentation viewer (W06). Renders one command's docs —
		signature, description, aliases, category, permission, risk,
		cooldown, every argument (type, required/optional, description,
		choices, range) and usage examples — into any container. Used by
		the command palette (F1 / "help <command>") and the Commands page.

	Public API:
		CommandDocs.Build(container: GuiObject, meta: any, options: {
			Env: any?,                         -- for generated examples
			OnExample: ((line: string) -> ())?, -- example rows become buttons
		}?): ScrollingFrame
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme", 15))
local Shared = ReplicatedStorage:WaitForChild("Shared", 15):WaitForChild("Sentinel", 15)
local ArgumentTypes = require(Shared:WaitForChild("ArgumentTypes", 15))
local UsageSpec = require(Shared:WaitForChild("UsageSpec", 15))

local CommandDocs = {}

local function esc(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function hex(c: Color3): string
	return ("#%02X%02X%02X"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local RISK_COLOR = {
	critical = Theme.Colors.Error,
	high = Theme.Colors.Error,
	medium = Theme.Colors.Warning,
}

function CommandDocs.Build(container: GuiObject, meta: any, options: any?): ScrollingFrame
	options = options or {}
	local old = container:FindFirstChild("Docs")
	if old then
		old:Destroy()
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Docs"
	scroll.Size = UDim2.new(1, 0, 1, 0)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = container
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local order = 0
	local function text(name: string, content: string, props: { [string]: any }?): TextLabel
		order += 1
		local l = Instance.new("TextLabel")
		l.Name = name
		l.LayoutOrder = order
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, -8, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.Font = Theme.Font.Regular
		l.TextSize = 13
		l.TextColor3 = Theme.Colors.Text
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextWrapped = true
		l.RichText = true
		l.Text = content
		for k, v in pairs(props or {}) do
			(l :: any)[k] = v
		end
		l.Parent = scroll
		return l
	end
	local function heading(name: string, content: string)
		text(name, content, { Font = Theme.Font.Bold, TextSize = 12, TextColor3 = Theme.Colors.TextSecondary })
	end

	local args = meta.Args or {}
	local risk = meta.Risk or "low"
	local riskText = ""
	if RISK_COLOR[risk] then
		riskText = ('  <font color="%s">%s RISK</font>'):format(hex(RISK_COLOR[risk]), risk:upper())
	end
	if meta.OwnerOnly then
		riskText ..= '  <font color="' .. hex(Theme.Colors.Error) .. '">OWNER ONLY</font>'
	end

	text("Title", ('<b>%s</b>  <font color="%s">%s</font>%s'):format(
		esc(meta.Name),
		hex(Theme.Colors.TextSecondary),
		esc(meta.Category or ""),
		riskText
	), { TextSize = 18, Font = Theme.Font.Medium })
	text("Signature", esc(meta.Name .. " " .. UsageSpec.Signature(args)), {
		Font = Theme.Font.Mono,
		TextSize = 14,
		TextColor3 = Theme.Colors.Accent,
	})
	text("Description", esc(meta.Description or ""))

	local facts = { "Permission: <b>" .. esc(meta.Permission or "?") .. "</b>" }
	if meta.Aliases and #meta.Aliases > 0 then
		table.insert(facts, "Aliases: " .. esc(table.concat(meta.Aliases, ", ")))
	end
	if meta.Cooldown and meta.Cooldown > 0 then
		table.insert(facts, ("Cooldown: %ss"):format(tostring(meta.Cooldown)))
	end
	if meta.RequiresTarget then
		table.insert(facts, "Targets players")
	end
	text("Facts", table.concat(facts, "   ·   "), { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })

	if #args > 0 then
		heading("ArgsHeading", "ARGUMENTS")
		local function argLine(arg: any, isModifier: boolean): string
			local typeDef = ArgumentTypes.Get(arg.Type)
			local desc = arg.Description or (typeDef and typeDef.Description) or ""
			local bits = {
				(if isModifier then "   :" else "") .. "<b>" .. esc(arg.Name) .. "</b>",
				('<font color="%s">%s · %s%s</font>'):format(
					hex(Theme.Colors.TextSecondary),
					esc(arg.Type),
					if arg.Optional then "optional" else "required",
					if arg.Rest then " · rest of line" else ""
				),
			}
			if arg.Min or arg.Max then
				table.insert(bits, ("(%s–%s)"):format(tostring(arg.Min or "…"), tostring(arg.Max or "…")))
			end
			local line = table.concat(bits, "  ") .. "  —  " .. esc(desc)
			if type(arg.Choices) == "table" and #arg.Choices > 0 then
				line ..= "  <i>[" .. esc(table.concat(arg.Choices, " | ")) .. "]</i>"
			end
			return line
		end
		for i, arg in ipairs(args) do
			text("Arg_" .. i, argLine(arg, false))
			if arg.Modifier then
				text("Arg_" .. i .. "_Modifier", argLine(arg.Modifier, true))
			end
		end
	end

	local examples = UsageSpec.Examples(meta, options.Env)
	if #examples > 0 then
		heading("ExamplesHeading", "EXAMPLES" .. (if options.OnExample then "  (click to use)" else ""))
		for i, line in ipairs(examples) do
			order += 1
			local b = Instance.new("TextButton")
			b.Name = "Example_" .. i
			b.LayoutOrder = order
			b.Size = UDim2.new(1, -8, 0, 26)
			b.BackgroundColor3 = Theme.Colors.SurfaceRaised
			b.AutoButtonColor = options.OnExample ~= nil
			b.Font = Theme.Font.Mono
			b.TextSize = 13
			b.TextColor3 = Theme.Colors.Text
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.Text = ";" .. line
			b.Parent = scroll
			Theme.corner(b, Theme.Radius.S)
			Theme.padding(b, 8)
			if options.OnExample then
				b.MouseButton1Click:Connect(function()
					options.OnExample(line)
				end)
			end
		end
	end

	return scroll
end

return CommandDocs
