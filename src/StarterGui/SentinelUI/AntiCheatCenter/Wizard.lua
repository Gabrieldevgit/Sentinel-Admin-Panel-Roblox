--!strict
--[[
	Wizard.lua (Anti-Cheat Control Center - first activation)

	The first time an Owner opens the Control Center (Core.SetupDone is
	false) this 4-step wizard shows instead of the Overview:
	  1 Welcome     what the system does; it starts in Observe mode
	  2 Preset      Observe, Balanced or Strict (the section-4 table)
	  3 Modules     which modules run (all on by default) and the rank at or
	                above which staff are exempt
	  4 Review      a summary and Turn on (finishSetup: preset, modules,
	                exempt rank, Enabled, SetupDone) -> toast -> Overview
	Logs & Help > Replay tour shows it again; without anticheat.master the
	last step only closes it.

	Stable names: PlayerGui.SentinelAntiCheat.Wizard.Card.{Step, Body,
	Buttons.{BackButton, NextButton, TurnOnButton, SkipButton}}
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AntiCheatTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("AntiCheatTypes"))
local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local Wizard = {}

local PRESET_TEXT = {
	observe = "Never punishes. Logs every flag and alerts staff from 20 points. The safe way to tune a new game.",
	balanced = "Log, alert at 20, warn at 40, kick at 60, staff review at 80. Bans always need a human.",
	strict = "Silent correction at 20, kick at 40, temporary server ban at 60, ban proposal at 80 (owner approval).",
}

function Wizard.Show(Center: any, replay: boolean)
	local gui = Center.ScreenGui and Center.ScreenGui() or nil
	local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local screen = gui or playerGui:FindFirstChild("SentinelAntiCheat")
	if not screen then
		return
	end
	local old = screen:FindFirstChild("Wizard")
	if old then
		old:Destroy()
	end
	local canApply = Center.Can("Master")
	local choice = { Mode = "observe", Modules = {}, ExemptRank = "Admin" }
	local moduleNames = Center.ModuleNames or {}
	for _, name in ipairs(moduleNames) do
		choice.Modules[name] = true
	end
	local ranks = { "None" }
	local cfg = Center.Call("config")
	for _, r in ipairs((cfg and cfg.Ranks) or {}) do
		table.insert(ranks, r.Name)
	end
	for _, s in ipairs((cfg and cfg.Sections) or {}) do
		if s.Key == "Core" then
			choice.ExemptRank = s.Values.ExemptRank
			choice.Mode = s.Values.Mode
		end
	end

	local backdrop = Widgets.make("Frame", { Name = "Wizard", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, Size = UDim2.fromScale(1, 1), ZIndex = 100, Active = true }, screen)
	local card = Widgets.make("Frame", { Name = "Card", BackgroundColor3 = Theme.Colors.Background, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 560, 0, 440), ZIndex = 101 }, backdrop)
	Widgets.make("UISizeConstraint", { MaxSize = Vector2.new(560, 440) }, card)
	card.Size = UDim2.new(0.95, 0, 0.9, 0)
	Theme.corner(card, Theme.Radius.L)
	Theme.stroke(card)
	Theme.padding(card, 18)
	local stepLabel = Widgets.label(card, "", { Name = "Step", Color = Theme.Colors.TextSecondary, TextSize = 12, Size = UDim2.new(1, 0, 0, 18) })
	local body = Widgets.make("ScrollingFrame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 24), Size = UDim2.new(1, 0, 1, -70), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4 }, card)
	Widgets.list(body, nil, 8)
	local buttons = Widgets.make("Frame", { Name = "Buttons", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 34) }, card)
	Widgets.list(buttons, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right)

	local step = 1
	local render: () -> ()

	local function close()
		backdrop:Destroy()
	end

	local function zAll()
		for _, d in ipairs(backdrop:GetDescendants()) do
			if d:IsA("GuiObject") and d.ZIndex < 102 then
				d.ZIndex = 102
			end
		end
	end

	render = function()
		for _, c in ipairs(body:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for _, c in ipairs(buttons:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		stepLabel.Text = ("Step %d of 4%s"):format(step, if replay then "  (tour)" else "")
		if step == 1 then
			Widgets.label(body, "Welcome to Sentinel AntiCheat", { Bold = true, TextSize = 20, LayoutOrder = 1 })
			Widgets.label(body, "The server watches what it can measure itself - movement, health, tools, remote traffic, hits, economy - and gives every player a suspicion score. One odd moment fades; repeated, different signals stack. Actions follow the score, within limits you set.", { Wrap = true, AutoY = true, LayoutOrder = 2 })
			Widgets.label(body, "It starts in Observe mode: nothing is ever punished until you choose a stricter mode. Staff get alerts and can review every flag with its evidence.", { Wrap = true, AutoY = true, LayoutOrder = 3, Color = Theme.Colors.Success })
			Widgets.label(body, "Clients are never trusted: their reports are weak hints. Game-wide bans always need a human (or, if you allow it, a pattern across three modules).", { Wrap = true, AutoY = true, LayoutOrder = 4, Color = Theme.Colors.TextSecondary })
		elseif step == 2 then
			Widgets.label(body, "Pick a preset", { Bold = true, TextSize = 18, LayoutOrder = 1 })
			for i, mode in ipairs(AntiCheatTypes.MODES) do
				local b = Widgets.make("TextButton", { Name = "Preset_" .. mode, Text = "", AutoButtonColor = true, BackgroundColor3 = if choice.Mode == mode then Theme.Colors.SurfaceRaised else Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 70), LayoutOrder = 1 + i }, body)
				Theme.corner(b, Theme.Radius.M)
				Theme.stroke(b, if choice.Mode == mode then Theme.Colors.Accent else Theme.Colors.Border, if choice.Mode == mode then 2 else 1)
				Theme.padding(b, 10)
				Widgets.label(b, mode:sub(1, 1):upper() .. mode:sub(2) .. (if mode == "observe" then "  (recommended to start)" else ""), { Bold = true, Size = UDim2.new(1, 0, 0, 20) })
				local d = Widgets.label(b, PRESET_TEXT[mode], { TextSize = 13, Color = Theme.Colors.TextSecondary, Wrap = true, Size = UDim2.new(1, 0, 0, 34) })
				d.Position = UDim2.fromOffset(0, 20)
				b.Activated:Connect(function()
					choice.Mode = mode
					render()
				end)
			end
		elseif step == 3 then
			Widgets.label(body, "Modules and exempt staff", { Bold = true, TextSize = 18, LayoutOrder = 1 })
			local grid = Widgets.make("Frame", { Name = "Modules", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, body)
			local gl = Widgets.list(grid, Enum.FillDirection.Horizontal, 6)
			gl.Wraps = true
			for i, name in ipairs(moduleNames) do
				Widgets.chip(grid, (if choice.Modules[name] then "[x] " else "[ ] ") .. name, choice.Modules[name] == true, function()
					choice.Modules[name] = not choice.Modules[name]
					render()
				end, { Name = "Module_" .. name, LayoutOrder = i })
			end
			local row = Widgets.make("Frame", { Name = "Rank", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 3 }, body)
			Widgets.list(row, Enum.FillDirection.Horizontal, 8)
			Widgets.label(row, "Exempt staff at or above:", { Size = UDim2.fromOffset(180, 30), LayoutOrder = 1 })
			Widgets.select(row, ranks, choice.ExemptRank, function(v)
				choice.ExemptRank = v
			end, { Name = "ExemptRank", Width = 150, LayoutOrder = 2 })
		else
			Widgets.label(body, "Review", { Bold = true, TextSize = 18, LayoutOrder = 1 })
			local on, off = {}, {}
			for _, name in ipairs(moduleNames) do
				table.insert(if choice.Modules[name] then on else off, name)
			end
			Center.KV(body, "Mode", choice.Mode, 2)
			Center.KV(body, "Modules on", ("%d: %s"):format(#on, table.concat(on, ", ")), 3)
			Center.KV(body, "Modules off", if #off > 0 then table.concat(off, ", ") else "none", 4)
			Center.KV(body, "Exempt rank", choice.ExemptRank, 5)
			Widgets.label(body, if canApply then "Press Turn on to start. You can change everything later; the master switch is at the top of the Overview page." else "Only anticheat.master can apply these choices - this is a tour.", { Wrap = true, AutoY = true, LayoutOrder = 6, Color = Theme.Colors.TextSecondary })
		end

		Widgets.button(buttons, if replay then "Close" else "Skip", { Name = "SkipButton", Kind = "ghost", LayoutOrder = 1, OnClick = close })
		if step > 1 then
			Widgets.button(buttons, "Back", { Name = "BackButton", LayoutOrder = 2, OnClick = function()
				step -= 1
				render()
			end })
		end
		if step < 4 then
			Widgets.button(buttons, "Next", { Name = "NextButton", Kind = "primary", LayoutOrder = 3, OnClick = function()
				step += 1
				render()
			end })
		elseif canApply then
			Widgets.button(buttons, "Turn on", { Name = "TurnOnButton", Kind = "primary", LayoutOrder = 3, OnClick = function()
				local result = Center.Call("finishSetup", { Mode = choice.Mode, Modules = choice.Modules, ExemptRank = choice.ExemptRank })
				if result then
					Center.Toast(result.Ok == true, result.Message)
					if result.Ok then
						close()
						Center.ShowPage("Overview")
					end
				end
			end })
		end
		zAll()
	end

	render()
end

return Wizard
