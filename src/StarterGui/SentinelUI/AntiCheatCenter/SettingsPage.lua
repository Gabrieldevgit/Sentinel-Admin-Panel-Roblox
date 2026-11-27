--!strict
--[[
	SettingsPage.lua (Anti-Cheat Control Center, page 7: Settings)

	Tuning (anticheat.config). Sections: Mode and action bands (the
	Observe / Balanced / Strict x band table, editable), Scoring, Grace and
	lag, Storage, Alerts, Cross-server (and Core). Each section: Save
	(validated on the server; the toast lists exactly which values
	changed), Discard (reverts unsaved edits), Reset section (confirmed).
	Top: Export / Import config (import is validated before anything is
	applied), Preset buttons (Observe / Balanced / Strict: preview first).

	Stable names: Page_Settings.{Top.{ExportConfig, ImportConfig, Preset_<name>,
	ResetAll}, Section_<Key>.{Field_<name>, Save, Discard, ResetSection}}
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AntiCheatTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("AntiCheatTypes"))
local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local SettingsPage = {}

local TITLES = {
	Bands = "Mode and action bands",
	Scoring = "Scoring",
	Grace = "Grace and lag",
	Storage = "Storage",
	Alerts = "Alerts",
	CrossServer = "Cross-server",
	Core = "Core",
}
local ORDER = { "Bands", "Scoring", "Grace", "Storage", "Alerts", "CrossServer", "Core" }

local function fmt(v: any): string
	if type(v) == "table" then
		return table.concat(v, ",")
	end
	return tostring(v)
end

function SettingsPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 12)
	local api: any = {}
	local canConfig = Center.Can("Config")

	local top = Widgets.make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 0 }, frame)
	local tl = Widgets.list(top, Enum.FillDirection.Horizontal, 6)
	tl.Wraps = true
	if not canConfig then
		Widgets.label(frame, "Read only: changing settings needs anticheat.config.", { Color = Theme.Colors.Warning, LayoutOrder = 0 })
	end
	Widgets.button(top, "Export config", { Name = "ExportConfig", LayoutOrder = 1, OnClick = function()
		local r = Center.Call("exportConfig")
		if r and r.Ok then
			Widgets.copyBox("Anti-cheat config", r.Text)
		end
	end })
	Widgets.button(top, "Import config", { Name = "ImportConfig", Need = "Config", LayoutOrder = 2, OnClick = function()
		Widgets.form("Import config", { { Key = "Text", Label = "Paste an exported config", Kind = "multi", Required = true } }, function(v)
			local check = Center.Call("import", { Text = v.Text, DryRun = true })
			if not check then
				return "No answer from the server."
			end
			if not check.Ok then
				return check.Message
			end
			Center.Act("import", { Text = v.Text })
			return nil
		end, { SubmitText = "Validate and import", Width = 560 })
	end })
	for i, preset in ipairs({ "Observe", "Balanced", "Strict" }) do
		Widgets.button(top, "Preset: " .. preset, { Name = "Preset_" .. preset, Need = "Config", LayoutOrder = 2 + i, OnClick = function()
			local preview = Center.Call("presetPreview", { Name = preset })
			if not preview or not preview.Ok then
				Center.Toast(false, preview and preview.Message or "Preview failed.")
				return
			end
			local lines = {}
			for _, c in ipairs(preview.Changes) do
				table.insert(lines, ("%s: %s -> %s"):format(c.Field, c.Before, c.After))
			end
			Widgets.form("Apply the " .. preset .. " preset?", {}, function()
				Center.Act("applyPreset", { Name = preset })
				return nil
			end, { SubmitText = "Apply", Danger = preset == "Strict", Description = if #lines > 0 then "These values change:\n" .. table.concat(lines, "\n") else "Nothing would change: the current values already match." })
		end })
	end
	Widgets.button(top, "Reset everything", { Name = "ResetAll", Kind = "danger", Need = "Config", LayoutOrder = 9, OnClick = function()
		Center.Act("resetAll", nil, { Confirm = { Title = "Reset all anti-cheat settings", Message = "Restore every anti-cheat setting and module to its default on every server? (The master switch stays as it is.)" } })
	end })

	local sectionsHolder = Widgets.make("Frame", { Name = "Sections", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, frame)
	Widgets.list(sectionsHolder, nil, 12)

	local function buildSection(section: any, order: number)
		local key = section.Key
		local edits: { [string]: any } = {}
		local card = Widgets.make("Frame", { Name = "Section_" .. key, BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, sectionsHolder)
		Theme.corner(card, Theme.Radius.M)
		Theme.padding(card, 12)
		Widgets.list(card, nil, 6)
		Widgets.label(card, TITLES[key] or key, { Bold = true, TextSize = 15, LayoutOrder = 0 })
		local values = section.Values
		local byKey = {}
		for _, f in ipairs(section.Fields) do
			byKey[f.Key] = f
		end

		local function fieldRow(f: any, order2: number)
			local row = Widgets.make("Frame", { Name = "Field_" .. f.Key, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order2 }, card)
			local range = if f.Min ~= nil and f.Max ~= nil then (" (%s-%s)"):format(tostring(f.Min), tostring(f.Max)) else ""
			local l = Widgets.label(row, f.Key .. range, { TextSize = 13, Size = UDim2.new(0.34, 0, 1, 0) })
			Widgets.tooltip(l, tostring(f.Description))
			local current = values[f.Key]
			if f.Type == "boolean" then
				local sel = Widgets.select(row, { "on", "off" }, if current then "on" else "off", function(v)
					edits[f.Key] = v == "on"
				end, { Width = 120, Need = "Config" })
				sel.Position = UDim2.fromScale(0.35, 0)
			elseif f.Type == "choice" then
				local sel = Widgets.select(row, f.Choices, tostring(current), function(v)
					edits[f.Key] = v
				end, { Width = 160, Need = "Config" })
				sel.Position = UDim2.fromScale(0.35, 0)
			else
				local box = Widgets.textbox(row, "", { Text = fmt(current), Size = UDim2.new(0.3, 0, 1, 0) })
				box.Position = UDim2.fromScale(0.35, 0)
				box.TextEditable = canConfig
				box.FocusLost:Connect(function()
					if box.Text ~= fmt(current) then
						edits[f.Key] = if f.Type == "number" or f.Type == "integer" then (tonumber(box.Text) or box.Text) else box.Text
					end
				end)
			end
			local desc = Widgets.label(row, tostring(f.Description), { TextSize = 11, Color = Theme.Colors.TextSecondary, Size = UDim2.new(0.34, 0, 1, 0) })
			desc.Position = UDim2.fromScale(0.66, 0)
		end

		if key == "Bands" then
			-- The section-4 table: thresholds + one select per mode and band.
			local th = Widgets.make("Frame", { Name = "Thresholds", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1 }, card)
			Widgets.list(th, Enum.FillDirection.Horizontal, 6)
			Widgets.label(th, "Band starts:", { TextSize = 13, Size = UDim2.fromOffset(90, 30), LayoutOrder = 0 })
			for i = 1, 4 do
				local name = "Band" .. i
				local box = Widgets.textbox(th, "", { Name = "Field_" .. name, Text = tostring(values[name]), Size = UDim2.fromOffset(60, 30), LayoutOrder = i })
				box.TextEditable = canConfig
				Widgets.tooltip(box, ("Score where band %d starts"):format(i + 1))
				box.FocusLost:Connect(function()
					edits[name] = tonumber(box.Text) or box.Text
				end)
			end
			local headers = Widgets.make("Frame", { Name = "BandHeaders", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 2 }, card)
			Widgets.list(headers, Enum.FillDirection.Horizontal, 6)
			Widgets.label(headers, "", { Size = UDim2.fromOffset(90, 20), LayoutOrder = 0 })
			local function bandLabel(i: number): string
				local lo = if i == 1 then 0 else values["Band" .. (i - 1)]
				local hi = if i == 5 then nil else values["Band" .. i] - 1
				return if hi then ("%d-%d"):format(lo, hi) else ("%d+"):format(lo)
			end
			for i = 1, 5 do
				Widgets.label(headers, bandLabel(i), { TextSize = 12, Color = Theme.Colors.TextSecondary, Size = UDim2.fromOffset(130, 20), LayoutOrder = i })
			end
			for m, mode in ipairs({ "Observe", "Balanced", "Strict" }) do
				local row = Widgets.make("Frame", { Name = "Bands_" .. mode, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 2 + m }, card)
				Widgets.list(row, Enum.FillDirection.Horizontal, 6)
				Widgets.label(row, mode, { Bold = true, TextSize = 13, Size = UDim2.fromOffset(90, 30), LayoutOrder = 0 })
				local list = table.clone(values[mode])
				local choices = if mode == "Observe" then { "log", "alert" } else AntiCheatTypes.ACTIONS
				for i = 1, 5 do
					Widgets.select(row, choices, list[i], function(v)
						list[i] = v
						edits[mode] = table.clone(list)
					end, { Name = ("%s_%d"):format(mode, i), Width = 130, Need = "Config", LayoutOrder = i, Tooltip = AntiCheatTypes.ACTION_LABELS[list[i]] })
				end
			end
			local order2 = 10
			for _, name in ipairs({ "RequireApproval", "PatternModules", "PatternMinutes", "TempBanMinutes", "BanDays", "DismissReduce" }) do
				if byKey[name] then
					order2 += 1
					fieldRow(byKey[name], order2)
				end
			end
		else
			local names = {}
			for _, f in ipairs(section.Fields) do
				table.insert(names, f.Key)
			end
			table.sort(names)
			for i, name in ipairs(names) do
				fieldRow(byKey[name], i)
			end
		end

		local buttons = Center.ActionRow(card, 100)
		Widgets.button(buttons, "Save", { Name = "Save", Kind = "primary", Need = "Config", OnClick = function()
			if next(edits) == nil then
				Center.Toast(true, "Nothing to save.")
				return
			end
			Center.Act("saveSection", { Key = key, Values = edits }, { OnDone = function(r)
				if r.Ok then
					table.clear(edits)
				end
			end })
		end })
		Widgets.button(buttons, "Discard", { Name = "Discard", Need = "Config", OnClick = function()
			table.clear(edits)
			api.Refresh()
		end })
		Widgets.button(buttons, "Reset section", { Name = "ResetSection", Need = "Config", OnClick = function()
			Center.Act("resetSection", { Key = key }, { Confirm = { Title = "Reset " .. (TITLES[key] or key), Message = "Restore this section's defaults on every server?" } })
		end })
	end

	function api.Refresh()
		local result = Center.Call("config")
		if not result or not result.Ok then
			return
		end
		for _, c in ipairs(sectionsHolder:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local byKey = {}
		for _, s in ipairs(result.Sections) do
			byKey[s.Key] = s
		end
		for i, key in ipairs(ORDER) do
			if byKey[key] then
				buildSection(byKey[key], i)
			end
		end
	end

	return api
end

return SettingsPage
