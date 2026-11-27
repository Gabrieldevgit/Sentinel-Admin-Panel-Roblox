--!strict
--[[
	ModulesPage.lua (Anti-Cheat Control Center, page 5: Modules)

	One card per detection module: name, description, ON / OFF switch
	(live on every server), flags in 24 hours, false-positive rate, average
	cost, a weight slider (0 to 2, steps of 0.05), Configure (every setting
	with its valid range), Test (runs the module once on your own character,
	log-only) and Reset (the module's defaults, confirmed).

	Stable names: Page_Modules.Grid.Module_<Name>.{Toggle, Weight.{Track,
	Value}, Configure, Test, Reset}
--]]

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local ModulesPage = {}

local function fmt(v: any): string
	if type(v) == "table" then
		local parts = {}
		for _, x in ipairs(v) do
			table.insert(parts, tostring(x))
		end
		return table.concat(parts, ",")
	end
	return tostring(v)
end

function ModulesPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = {}
	Widgets.label(frame, "Every threshold is a default you can change live. Changes reach every server.", { Color = Theme.Colors.TextSecondary, TextSize = 13, LayoutOrder = 1 })
	local grid = Widgets.make("Frame", { Name = "Grid", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local gl = Widgets.make("UIGridLayout", { CellSize = UDim2.new(0.5, -6, 0, 196), CellPadding = UDim2.fromOffset(10, 10), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	local _ = gl
	local canConfig = Center.Can("Config")

	local function configure(m: any)
		local fields = {}
		for _, s in ipairs(m.Schema) do
			if s.Key ~= "Enabled" and s.Key ~= "Weight" then
				local label = s.Key
				if s.Min ~= nil and s.Max ~= nil then
					label = ("%s (%s to %s)"):format(s.Key, tostring(s.Min), tostring(s.Max))
				elseif s.Type == "boolean" then
					label = s.Key .. " (on / off)"
				elseif s.Type == "list" then
					label = s.Key .. " (comma separated)"
				end
				table.insert(fields, {
					Key = s.Key,
					Label = label .. " - " .. tostring(s.Description or ""),
					Kind = if s.Type == "boolean" then "choice" else "text",
					Choices = if s.Type == "boolean" then { "on", "off" } else nil,
					Default = if s.Type == "boolean" then (if m.Config[s.Key] then "on" else "off") else fmt(m.Config[s.Key]),
				})
			end
		end
		Widgets.form("Configure " .. m.Name, fields, function(values)
			local clean = {}
			for _, s in ipairs(m.Schema) do
				local v = values[s.Key]
				if v ~= nil then
					if s.Type == "number" or s.Type == "integer" then
						clean[s.Key] = tonumber(v) or v
					elseif s.Type == "boolean" then
						clean[s.Key] = v == "on"
					else
						clean[s.Key] = v
					end
				end
			end
			local result = Center.Call("saveSection", { Key = "Module." .. m.Name, Values = clean })
			if not result then
				return "No answer from the server."
			end
			if not result.Ok then
				return result.Message
			end
			Center.Toast(true, result.Message)
			api.Refresh()
			return nil
		end, { Width = 520, SubmitText = "Save", Description = if canConfig then "Values outside their range are refused with the reason." else "Read only: changing settings needs anticheat.config." })
	end

	local function weightSlider(card: Instance, m: any)
		local holder = Widgets.make("Frame", { Name = "Weight", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 4 }, card)
		Widgets.label(holder, "Weight", { TextSize = 12, Color = Theme.Colors.TextSecondary, Size = UDim2.fromOffset(50, 24) })
		local track = Widgets.make("TextButton", { Name = "Track", Text = "", AutoButtonColor = false, BackgroundColor3 = Theme.Colors.Background, Position = UDim2.new(0, 56, 0.5, -5), Size = UDim2.new(1, -110, 0, 10) }, holder)
		Theme.corner(track, Theme.Radius.Pill)
		local fill = Widgets.make("Frame", { BackgroundColor3 = Theme.Colors.Accent, Size = UDim2.fromScale((m.Weight or 1) / 2, 1) }, track)
		Theme.corner(fill, Theme.Radius.Pill)
		local value = Widgets.label(holder, ("%.2f"):format(m.Weight or 1), { Name = "Value", TextSize = 12, XAlign = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(44, 24) })
		value.Position = UDim2.new(1, -44, 0, 0)
		if not canConfig then
			Widgets.tooltip(track, "Needs anticheat.config")
			return
		end
		local dragging = false
		local current = m.Weight or 1
		local function setFrom(x: number)
			local frac = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			current = math.floor(frac * 2 * 20 + 0.5) / 20
			fill.Size = UDim2.fromScale(current / 2, 1)
			value.Text = ("%.2f"):format(current)
		end
		track.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				setFrom(input.Position.X)
			end
		end)
		local moved = UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				setFrom(input.Position.X)
			end
		end)
		local ended
		ended = UserInputService.InputEnded:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				dragging = false
				if current ~= m.Weight then
					Center.Act("moduleWeight", { Name = m.Name, Weight = current })
				end
			end
		end)
		track.Destroying:Connect(function()
			moved:Disconnect()
			ended:Disconnect()
		end)
	end

	function api.Refresh()
		local result = Center.Call("modules")
		if not result or not result.Ok then
			return
		end
		for _, c in ipairs(grid:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for i, m in ipairs(result.Modules) do
			local card = Widgets.make("Frame", { Name = "Module_" .. m.Name, BackgroundColor3 = Theme.Colors.Surface, LayoutOrder = i }, grid)
			Theme.corner(card, Theme.Radius.M)
			Theme.stroke(card, if m.Enabled then Theme.Colors.Border else Theme.Colors.Error)
			Theme.padding(card, 10)
			Widgets.list(card, nil, 4)
			local head = Widgets.make("Frame", { Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 1 }, card)
			Widgets.label(head, ("%s  (sev %d)"):format(m.Name, m.Severity), { Bold = true, Size = UDim2.new(1, -60, 1, 0) })
			local toggle = Widgets.button(head, if m.Enabled then "ON" else "OFF", { Name = "Toggle", Kind = if m.Enabled then "primary" else "ghost", Width = 52, Height = 22, Need = "Config", OnClick = function()
				Center.Act("moduleToggle", { Name = m.Name, On = not m.Enabled })
			end })
			toggle.AnchorPoint = Vector2.new(1, 0)
			toggle.Position = UDim2.fromScale(1, 0)
			Widgets.label(card, m.Description, { TextSize = 12, Color = Theme.Colors.TextSecondary, Wrap = true, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 2 })
			Widgets.label(card, ("Flags 24h: %d   |   False positives: %.1f%%   |   Cost: %.3f ms/s%s"):format(m.Flags24h, m.FalsePositiveRate, m.MsPerSec, if m.Errors > 0 then ("   |   %d error(s)"):format(m.Errors) else ""), { TextSize = 12, LayoutOrder = 3, Color = if m.Errors > 0 then Theme.Colors.Warning else Theme.Colors.Text })
			if m.LastError then
				Widgets.tooltip(card :: any, "Last error: " .. m.LastError)
			end
			weightSlider(card, m)
			Widgets.label(card, ("Interval %.2fs  |  Grace %ss"):format(m.Interval or 1, tostring(m.Config.Grace or 0)), { TextSize = 12, Color = Theme.Colors.TextSecondary, LayoutOrder = 5 })
			local row = Center.ActionRow(card, 6)
			Widgets.button(row, "Configure", { Name = "Configure", Height = 26, OnClick = function()
				configure(m)
			end })
			Widgets.button(row, "Test", { Name = "Test", Height = 26, Need = "Config", Tooltip = "Run once on your own character, log-only", OnClick = function()
				Center.Act("moduleTest", { Name = m.Name }, { NoRefresh = true })
			end })
			Widgets.button(row, "Reset", { Name = "Reset", Height = 26, Need = "Config", OnClick = function()
				Center.Act("resetModule", { Name = m.Name }, { Confirm = { Title = "Reset " .. m.Name, Message = "Restore this module's default settings on every server?" } })
			end })
		end
	end

	return api
end

return ModulesPage
