--!strict
--[[
	ModulesPage.lua (W-FINAL.1) - nav section Modules (page id "Modules").

	List view (Body):
		Overview   counts (available / enabled / disabled / needs setup /
		           errors), compatibility warnings, recent activity.
		Library    search + category chips, one card per module: name,
		           version, category, status chip, description, dependencies,
		           last update, buttons Enable|Disable, Configure, Details,
		           Docs, Reset.
	Detail view (Detail, replaces Body): Back, header (status, version),
	tabs Overview / Configuration / Dependencies / Permissions / Activity.
	Configuration rows are generated from the module's schema; every change
	is a normal command (;module <id> set <key> <value>, ;module <id> on|off|
	reset) sent through ExecuteCommandRemote, so permissions, logging and the
	reset confirmation all run on the server.

	Data: GetModulesRemote() -> { Modules, Activity, Can };
	GetModulesRemote(id) -> { Module, Can }. Refreshes after a command result
	and when ModuleRemote pushes a new state.

	Stable instance names (Studio MCP tests):
		Body.Overview.Counts.Count_<Status>
		Body.Library.{Search, Categories.Chip_<category>, Cards.Card_<id>.
		  {Top.{Title,Status}, Buttons.{Toggle,Configure,Details,Docs,Reset}}}
		Detail.{Back, Header.{Title,Status}, Tabs.Tab_<name>, Content.
		  Field_<Key>.Controls.{Box,Save,Chip_<value>}}

	Public API:
		ModulesPage.Build(container)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local ModulesPage = {}

local TABS = { "Overview", "Configuration", "Dependencies", "Permissions", "Activity" }

local order = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		order += 1
		inst.LayoutOrder = order
	elseif inst:IsA("UIListLayout") then
		(inst :: any).SortOrder = Enum.SortOrder.LayoutOrder
	end
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function label(parent: Instance, name: string, value: string, props: { [string]: any }?): TextLabel
	local l = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = value,
	}, parent)
	for k, v in pairs(props or {}) do
		(l :: any)[k] = v
	end
	return l
end

local function para(parent: Instance, name: string, value: string, color: Color3?)
	return label(parent, name, value, {
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 16),
		TextSize = 12,
		TextColor3 = color or Theme.Colors.TextSecondary,
	})
end

local function caption(parent: Instance, value: string)
	label(parent, "Caption", value:upper(), { Font = Theme.Font.Bold, TextSize = 11, TextColor3 = Theme.Colors.TextSecondary, Size = UDim2.new(1, 0, 0, 14) })
end

local function card(parent: Instance, name: string): Frame
	local f = make("Frame", { Name = name, BackgroundColor3 = Theme.Colors.Surface, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	Theme.corner(f, Theme.Radius.M)
	make("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, f)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, f)
	return f
end

local function row(parent: Instance, name: string): Frame
	local f = make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, f)
	return f
end

local function chip(parent: Instance, name: string, value: string, on: boolean?, color: Color3?): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = if on then (color or Theme.Colors.Accent) else Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.Text,
		Text = value,
	}, parent)
	Theme.corner(b, Theme.Radius.Pill)
	make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, b)
	return b
end

local function clear(frame: Instance)
	for _, c in ipairs(frame:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function statusColor(status: string): Color3
	if status == "Enabled" then
		return Theme.Colors.Success
	elseif status == "Error" or status == "Incompatible" then
		return Theme.Colors.Error
	elseif status == "Needs Setup" or status == "Restart Required" then
		return Theme.Colors.Warning
	end
	return Theme.Colors.TextSecondary
end

local function statusPill(parent: Instance, status: string): TextLabel
	local l = make("TextLabel", {
		Name = "Status",
		BackgroundColor3 = statusColor(status),
		BackgroundTransparency = 0.75,
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Font.Bold,
		TextSize = 11,
		TextColor3 = statusColor(status),
		Text = status,
	}, parent)
	Theme.corner(l, Theme.Radius.Pill)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, l)
	return l
end

local function ago(t: any): string
	t = tonumber(t)
	if not t then
		return ""
	end
	local d = math.max(0, os.time() - t)
	if d < 60 then
		return "just now"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m ago"
	elseif d < 86400 then
		return math.floor(d / 3600) .. "h ago"
	end
	return math.floor(d / 86400) .. "d ago"
end

function ModulesPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local dataRemote = SentinelShared:WaitForChild("GetModulesRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local moduleRemote = SentinelShared:WaitForChild("ModuleRemote", 15) :: RemoteEvent?

	label(container, "Header", "Modules", { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", "Optional gameplay systems for this experience. Enable, configure and monitor them here.", {
		Position = UDim2.new(0, 0, 0, 28),
		TextColor3 = Theme.Colors.TextSecondary,
	})
	local function scroller(name: string): ScrollingFrame
		local s = make("ScrollingFrame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 0, 52),
			Size = UDim2.new(1, 0, 1, -52),
			ScrollBarThickness = 4,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, container)
		make("UIListLayout", { Padding = UDim.new(0, 10) }, s)
		make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, s)
		return s
	end
	local body = scroller("Body")
	local detail = scroller("Detail")
	detail.Visible = false

	local data: any = nil
	local selected: string? = nil
	local selectedData: any = nil
	local tab = "Overview"
	local search = ""
	local category = "All"

	local function run(command: string)
		if executeRemote then
			executeRemote:FireServer(command)
		end
	end

	-- ======================================================================
	-- List view
	-- ======================================================================
	local overview = card(body, "Overview")
	caption(overview, "Overview")
	local counts = row(overview, "Counts")
	local warningsBox = make("Frame", { Name = "Warnings", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, overview)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, warningsBox)
	local recentBox = make("Frame", { Name = "Recent", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, overview)
	make("UIListLayout", { Padding = UDim.new(0, 2) }, recentBox)

	local library = card(body, "Library")
	caption(library, "Module library")
	local searchBox = make("TextBox", {
		Name = "Search",
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "Search modules...",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, library) :: TextBox
	Theme.corner(searchBox, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10) }, searchBox)
	local categories = row(library, "Categories")
	local cards = make("Frame", { Name = "Cards", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, library)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, cards)
	local statusLine = para(body, "StatusLine", "")

	local openDetail: (string, string?) -> ()

	local function renderList()
		if not data then
			return
		end
		local list = data.Modules or {}
		local can = data.Can or {}
		-- overview
		clear(counts)
		local tally = { Available = #list, Enabled = 0, Disabled = 0, ["Needs Setup"] = 0, Error = 0 }
		for _, m in ipairs(list) do
			if m.Status == "Enabled" then
				tally.Enabled += 1
			elseif m.Status == "Needs Setup" then
				tally["Needs Setup"] += 1
			elseif m.Status == "Error" or m.Status == "Incompatible" or m.Status == "Restart Required" then
				tally.Error += 1
			else
				tally.Disabled += 1
			end
		end
		for _, k in ipairs({ "Available", "Enabled", "Disabled", "Needs Setup", "Error" }) do
			local tile = make("Frame", { Name = "Count_" .. k:gsub(" ", ""), BackgroundColor3 = Theme.Colors.SurfaceRaised, BorderSizePixel = 0, Size = UDim2.fromOffset(110, 48) }, counts)
			Theme.corner(tile, Theme.Radius.S)
			label(tile, "Title", k:upper(), { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 12), TextSize = 10, Font = Theme.Font.Bold, TextColor3 = Theme.Colors.TextSecondary })
			label(tile, "Value", tostring(tally[k]), { Position = UDim2.fromOffset(10, 20), Size = UDim2.new(1, -20, 0, 22), TextSize = 18, Font = Theme.Font.Bold })
		end
		clear(warningsBox)
		for _, m in ipairs(list) do
			for _, w in ipairs(m.Warnings or {}) do
				para(warningsBox, "Warning", ("%s: %s"):format(m.Name, w), Theme.Colors.Warning)
			end
			for _, p in ipairs(m.Problems or {}) do
				para(warningsBox, "Problem", ("%s %s"):format(m.Name, p), Theme.Colors.Error)
			end
		end
		clear(recentBox)
		for i, a in ipairs(data.Activity or {}) do
			if i > 5 then
				break
			end
			para(recentBox, "Activity_" .. i, ("%s - %s (%s)"):format(tostring(a.Text), tostring(a.By), ago(a.At)))
		end
		if #(data.Activity or {}) == 0 then
			para(recentBox, "NoActivity", "No module activity yet.")
		end

		-- categories
		clear(categories)
		local cats = { "All" }
		for _, m in ipairs(list) do
			if not table.find(cats, m.Category) then
				table.insert(cats, m.Category)
			end
		end
		for _, c in ipairs(cats) do
			local b = chip(categories, "Chip_" .. c:gsub("%W", ""), c, c == category)
			b.MouseButton1Click:Connect(function()
				category = c
				renderList()
			end)
		end

		-- cards
		clear(cards)
		local shown = 0
		local q = search:lower()
		for _, m in ipairs(list) do
			local hay = (m.Name .. " " .. m.Description .. " " .. m.Category .. " " .. m.Id):lower()
			if (category == "All" or m.Category == category) and (q == "" or hay:find(q, 1, true)) then
				shown += 1
				local c = make("Frame", { Name = "Card_" .. m.Id, BackgroundColor3 = Theme.Colors.SurfaceRaised, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, cards)
				Theme.corner(c, Theme.Radius.S)
				make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, c)
				make("UIListLayout", { Padding = UDim.new(0, 6) }, c)
				local top = row(c, "Top")
				label(top, "Title", m.Name, { Font = Theme.Font.Bold, TextSize = 15, Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X })
				statusPill(top, m.Status)
				label(top, "Meta", ("v%s  -  %s"):format(m.Version, m.Category), { Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, TextColor3 = Theme.Colors.TextSecondary })
				para(c, "Description", m.Description, Theme.Colors.Text)
				local deps = if #(m.Dependencies or {}) > 0 then table.concat(m.Dependencies, ", ") else "none"
				para(c, "Info", ("Dependencies: %s   Last update: %s%s"):format(deps, tostring(m.LastUpdate or "-"), if #(m.Warnings or {}) > 0 then ("   %d warning(s)"):format(#m.Warnings) else ""))
				local buttons = row(c, "Buttons")
				local toggle = chip(buttons, "Toggle", if m.Enabled then "Disable" else "Enable", true, if m.Enabled then Theme.Colors.Error else Theme.Colors.Success)
				toggle.Visible = if m.Enabled then can.Disable == true else can.Activate == true
				toggle.MouseButton1Click:Connect(function()
					run(("module %s %s"):format(m.Id, if m.Enabled then "off" else "on"))
				end)
				local configure = chip(buttons, "Configure", "Configure")
				configure.MouseButton1Click:Connect(function()
					openDetail(m.Id, "Configuration")
				end)
				local details = chip(buttons, "Details", "Details")
				details.MouseButton1Click:Connect(function()
					openDetail(m.Id, "Overview")
				end)
				local docs = chip(buttons, "Docs", "Documentation")
				docs.MouseButton1Click:Connect(function()
					openDetail(m.Id, "Overview")
				end)
				local reset = chip(buttons, "Reset", "Reset config")
				reset.Visible = can.Configure == true
				reset.MouseButton1Click:Connect(function()
					run(("module %s reset"):format(m.Id))
				end)
			end
		end
		if shown == 0 then
			para(cards, "Empty", if #list == 0 then "No modules are installed." else "No module matches.")
		end
	end

	-- ======================================================================
	-- Detail view
	-- ======================================================================
	local function renderDetail()
		clear(detail)
		local m = selectedData and selectedData.Module
		local can = (selectedData and selectedData.Can) or {}
		local back = chip(detail, "Back", "< All modules")
		back.MouseButton1Click:Connect(function()
			selected = nil
			detail.Visible = false
			body.Visible = true
		end)
		if not m then
			para(detail, "Missing", "Loading...")
			return
		end
		local header = row(detail, "Header")
		label(header, "Title", m.Name, { Font = Theme.Font.Bold, TextSize = 18, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X })
		statusPill(header, m.Status)
		label(header, "Meta", ("v%s  -  %s  -  id %s"):format(m.Version, m.Category, m.Id), { Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, TextSize = 12, TextColor3 = Theme.Colors.TextSecondary })
		local actions = row(detail, "Actions")
		if (m.Enabled and can.Disable) or (not m.Enabled and can.Activate) then
			local t = chip(actions, "Toggle", if m.Enabled then "Disable module" else "Enable module", true, if m.Enabled then Theme.Colors.Error else Theme.Colors.Success)
			t.MouseButton1Click:Connect(function()
				run(("module %s %s"):format(m.Id, if m.Enabled then "off" else "on"))
			end)
		end
		local tabs = row(detail, "Tabs")
		for _, name in ipairs(TABS) do
			local b = chip(tabs, "Tab_" .. name, name, name == tab)
			b.MouseButton1Click:Connect(function()
				tab = name
				renderDetail()
			end)
		end
		local content = card(detail, "Content")
		if m.Error then
			para(content, "Error", m.Error, Theme.Colors.Error)
		end
		for _, w in ipairs(m.Warnings or {}) do
			para(content, "Warning", "Warning: " .. w, Theme.Colors.Warning)
		end

		if tab == "Overview" then
			para(content, "Description", m.Description, Theme.Colors.Text)
			caption(content, "Features")
			for i, f in ipairs(m.Features or {}) do
				para(content, "Feature_" .. i, "- " .. f, Theme.Colors.Text)
			end
			caption(content, "Documentation")
			para(content, "Docs", tostring(m.Docs or "No documentation."), Theme.Colors.Text)
			caption(content, "Requirements")
			para(content, "Rigs", "Rigs: " .. table.concat(m.Rigs or {}, ", "))
			para(content, "Platforms", "Platforms: " .. table.concat(m.Platforms or {}, ", "))
			para(content, "Services", "Uses: " .. table.concat(m.Services or {}, ", "))
			if m.Since then
				para(content, "Since", "Active since " .. ago(m.Since))
			end
			if m.Diagnostics then
				caption(content, "Diagnostics")
				local parts = {}
				for k, v in pairs(m.Diagnostics) do
					table.insert(parts, ("%s: %s"):format(k, tostring(v)))
				end
				table.sort(parts)
				para(content, "Diagnostics", table.concat(parts, "   "), Theme.Colors.Text)
			end
			caption(content, "Changelog")
			for i, c in ipairs(m.Changelog or {}) do
				para(content, "Change_" .. i, ("v%s (%s): %s"):format(tostring(c.Version), tostring(c.Date), tostring(c.Notes)))
			end
		elseif tab == "Configuration" then
			if not can.Configure then
				para(content, "ReadOnly", "Read only - you need modules.configure to change settings.", Theme.Colors.Warning)
			end
			for _, f in ipairs(m.Schema or {}) do
				local field = make("Frame", { Name = "Field_" .. f.Key, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, content)
				make("UIListLayout", { Padding = UDim.new(0, 4) }, field)
				local value = m.Config[f.Key]
				local isDefault = value == (m.Defaults or {})[f.Key]
				label(field, "Label", ("%s%s"):format(f.Label or f.Key, if isDefault then "" else "  (changed)"), { Font = Theme.Font.Bold, TextSize = 13 })
				local hint = f.Description or ""
				if f.Min or f.Max then
					hint ..= ("  [%s - %s]"):format(tostring(f.Min or ""), tostring(f.Max or ""))
				end
				hint ..= ("  Default: %s"):format(tostring((m.Defaults or {})[f.Key]))
				para(field, "Hint", hint)
				local controls = row(field, "Controls")
				if f.Type == "boolean" or f.Type == "choice" then
					local options = if f.Type == "boolean" then { "On", "Off" } else f.Choices or {}
					for _, opt in ipairs(options) do
						local on = if f.Type == "boolean" then ((opt == "On") == (value == true)) else opt == value
						local b = chip(controls, "Chip_" .. opt, opt, on)
						b.Active = can.Configure == true
						b.MouseButton1Click:Connect(function()
							if can.Configure and not on then
								run(("module %s set %s %s"):format(m.Id, f.Key, opt:lower()))
							end
						end)
					end
				else
					local box = make("TextBox", {
						Name = "Box",
						Size = UDim2.fromOffset(160, 28),
						BackgroundColor3 = Theme.Colors.SurfaceRaised,
						BorderSizePixel = 0,
						ClearTextOnFocus = false,
						Font = Theme.Font.Mono,
						TextSize = 13,
						TextColor3 = Theme.Colors.Text,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextEditable = can.Configure == true,
						Text = tostring(value),
					}, controls) :: TextBox
					Theme.corner(box, Theme.Radius.S)
					make("UIPadding", { PaddingLeft = UDim.new(0, 8) }, box)
					if can.Configure then
						local save = chip(controls, "Save", "Save", true)
						local function submit()
							local text = box.Text:gsub("[\r\n]", ""):gsub("&&", ""):match("^%s*(.-)%s*$") or ""
							if text ~= "" and text ~= tostring(value) then
								run(("module %s set %s %s"):format(m.Id, f.Key, text))
							end
						end
						save.MouseButton1Click:Connect(submit)
						box.FocusLost:Connect(function(enter)
							if enter then
								submit()
							end
						end)
					end
				end
			end
			if can.Configure then
				local reset = chip(content, "ResetConfig", "Reset to defaults", true, Theme.Colors.Warning)
				reset.MouseButton1Click:Connect(function()
					run(("module %s reset"):format(m.Id))
				end)
			end
		elseif tab == "Dependencies" then
			caption(content, "Required modules")
			para(content, "Deps", if #(m.Dependencies or {}) > 0 then table.concat(m.Dependencies, ", ") else "None.", Theme.Colors.Text)
			caption(content, "Optional integrations")
			for i, it in ipairs(m.Integrations or {}) do
				para(content, "Integration_" .. i, ("%s - %s"):format(tostring(it.Id), tostring(it.Description)), Theme.Colors.Text)
			end
			if #(m.Integrations or {}) == 0 then
				para(content, "NoIntegrations", "None.")
			end
			caption(content, "Conflicts")
			para(content, "Conflicts", if #(m.Conflicts or {}) > 0 then table.concat(m.Conflicts, ", ") else "None.", Theme.Colors.Text)
			caption(content, "Compatibility")
			if #(m.Warnings or {}) == 0 and #(m.Problems or {}) == 0 then
				para(content, "Compatible", "No compatibility problems found.", Theme.Colors.Success)
			end
			for i, p in ipairs(m.Problems or {}) do
				para(content, "Problem_" .. i, p, Theme.Colors.Error)
			end
		elseif tab == "Permissions" then
			local perms = m.Permissions or {}
			local lines = {
				{ "View the module", perms.View },
				{ "Configure it", perms.Configure },
				{ "Enable it", perms.Activate },
				{ "Disable it", perms.Disable },
				{ "See diagnostics", perms.Diagnostics },
			}
			for i, l in ipairs(lines) do
				para(content, "Perm_" .. i, ("%s: %s"):format(l[1], tostring(l[2])), Theme.Colors.Text)
			end
			para(content, "PermHint", "The Owner rank has every node. Grant others with ;rankperm <rank> +modules.configure (etc.).")
			local mine = {}
			for k, v in pairs(can) do
				table.insert(mine, ("%s %s"):format(k, if v then "yes" else "no"))
			end
			table.sort(mine)
			para(content, "Yours", "You: " .. table.concat(mine, ", "))
		elseif tab == "Activity" then
			caption(content, "Changes (all servers)")
			for i, a in ipairs(m.Activity or {}) do
				para(content, "Activity_" .. i, ("%s - %s (%s)"):format(tostring(a.Text), tostring(a.By), ago(a.At)), Theme.Colors.Text)
			end
			if #(m.Activity or {}) == 0 then
				para(content, "NoActivity", "No changes yet.")
			end
			caption(content, "This server (initialization, warnings, errors)")
			for i, r in ipairs(m.Runtime or {}) do
				local color = if r.Kind == "error" then Theme.Colors.Error elseif r.Kind == "warning" then Theme.Colors.Warning else Theme.Colors.TextSecondary
				para(content, "Runtime_" .. i, ("%s (%s)"):format(tostring(r.Text), ago(r.At)), color)
			end
		end
	end

	local function loadDetail()
		if not selected or not dataRemote then
			return
		end
		local ok, result = pcall(function()
			return (dataRemote :: RemoteFunction):InvokeServer(selected)
		end)
		if ok and type(result) == "table" then
			selectedData = result
		end
		renderDetail()
	end

	openDetail = function(id: string, startTab: string?)
		selected = id
		tab = startTab or "Overview"
		selectedData = nil
		body.Visible = false
		detail.Visible = true
		renderDetail()
		task.spawn(loadDetail)
	end

	local function refresh()
		if not dataRemote then
			return
		end
		local ok, result = pcall(function()
			return (dataRemote :: RemoteFunction):InvokeServer()
		end)
		if not ok then
			return
		end
		if type(result) ~= "table" then
			statusLine.Text = "You need modules.view to see modules."
			statusLine.TextColor3 = Theme.Colors.Warning
			return
		end
		data = result
		statusLine.Text = ""
		renderList()
		if selected then
			loadDetail()
		end
	end

	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		search = searchBox.Text
		renderList()
	end)
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function()
			if container.Visible then
				task.delay(0.3, refresh)
			end
		end)
	end
	if moduleRemote then
		moduleRemote.OnClientEvent:Connect(function(kind)
			if kind == "state" and container.Visible then
				task.delay(0.2, refresh)
			end
		end)
	end
	local wasVisible = false
	task.spawn(function()
		while container.Parent do
			if container.Visible and not wasVisible then
				refresh()
			end
			wasVisible = container.Visible
			task.wait(1)
		end
	end)
end

return ModulesPage
