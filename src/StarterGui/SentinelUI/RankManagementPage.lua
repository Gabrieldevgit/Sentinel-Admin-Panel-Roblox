--!strict
--[[
	RankManagementPage.lua

	Purpose:
		The Ranks page (W03): a UI over Systems/RankService. Replaces the
		earlier prototype that used local fake data.

	How it talks to the server:
		- Reads: GetRanksSnapshotRemote (staff + ranks.view) — ranks,
		  assignments, history, presets, command list, permission preview.
		- Writes: plain Sentinel commands sent through ExecuteCommandRemote
		  (;createrank, ;editrank, ;rankperm, ;rankpreset, ;bindrank,
		  ;unbindrank, ...). So every change goes through the same
		  permission / hierarchy / logging pipeline as chat commands, and
		  results show up as normal toasts.

	Tabs:
		Ranks        list + editor (details, permission editor with search,
		             allow/deny/none per node, presets, preview)
		Assignments  every binding with remove, plus an "add" form
		History      recent rank and permission changes

	Public API:
		RankManagementPage.Build(container: Frame, pageIds: {string}?): ()
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local RankManagementPage = {}

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

-- Extra nodes that aren't a command's permission but matter for ranks.
local EXTRA_NODES = {
	"panel.open",
	"ranks.view",
	"ranks.manage",
	"ranks.assign",
}

local BINDING_KINDS = { "username", "userid", "group", "grouprole", "gamepass", "asset" }

-- ---------------------------------------------------------------------------
-- Small widget helpers
-- ---------------------------------------------------------------------------
local function label(parent: Instance, text: string, size: number?, color: Color3?, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, (size or 13) + 8)
	l.Font = font or Theme.Font.Regular
	l.TextSize = size or 13
	l.TextColor3 = color or Theme.Colors.Text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextWrapped = true
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, width: number, color: Color3?): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, width, 0, 28)
	b.BackgroundColor3 = color or Theme.Colors.SurfaceRaised
	b.AutoButtonColor = true
	b.Font = Theme.Font.Medium
	b.TextSize = 13
	b.TextColor3 = Theme.Colors.Text
	b.Text = text
	b.Name = "Button_" .. text:gsub("[^%w]", "")
	b.Parent = parent
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function textbox(parent: Instance, placeholder: string, text: string?, width: UDim?): TextBox
	local t = Instance.new("TextBox")
	t.Size = UDim2.new(width or UDim.new(1, 0), UDim.new(0, 28))
	t.BackgroundColor3 = Theme.Colors.SurfaceRaised
	t.ClearTextOnFocus = false
	t.Font = Theme.Font.Regular
	t.TextSize = 13
	t.TextColor3 = Theme.Colors.Text
	t.PlaceholderText = placeholder
	t.PlaceholderColor3 = Theme.Colors.TextSecondary
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Text = text or ""
	t.ClipsDescendants = true
	t.Name = "Box_" .. placeholder:gsub("[^%w]", "")
	t.Parent = parent
	Theme.corner(t, Theme.Radius.S)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = t
	return t
end

local function row(parent: Instance, height: number?, order: number?): Frame
	local r = Instance.new("Frame")
	r.BackgroundTransparency = 1
	r.Size = UDim2.new(1, 0, 0, height or 28)
	r.LayoutOrder = order or 0
	r.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = r
	return r
end

local function vlist(parent: Instance, padding: number?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

local function scroller(parent: Instance, position: UDim2, size: UDim2): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.Position = position
	s.Size = size
	s.BackgroundColor3 = Theme.Colors.Surface
	s.BorderSizePixel = 0
	s.ScrollBarThickness = 4
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.Parent = parent
	Theme.corner(s, Theme.Radius.M)
	Theme.padding(s, Theme.Spacing.S)
	return s
end

local function clear(frame: Instance)
	for _, child in ipairs(frame:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") and not child:IsA("UICorner") then
			child:Destroy()
		end
	end
end

-- Values go into a command line; strip quotes and line breaks so they
-- can't break tokenizing, then quote anything with spaces.
local function arg(value: string): string
	local clean = value:gsub('["\r\n]', ""):gsub("^%s+", ""):gsub("%s+$", "")
	if clean:find("%s") then
		return '"' .. clean .. '"'
	end
	return clean
end

-- ---------------------------------------------------------------------------
-- Page
-- ---------------------------------------------------------------------------
function RankManagementPage.Build(container: Frame, pageIds: { string }?)
	local snapshotRemote = SentinelShared:WaitForChild("GetRanksSnapshotRemote", 10) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote") :: RemoteEvent
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote") :: RemoteEvent

	local snapshot: any = nil
	local selectedRank: string? = nil
	local activeTab = "Ranks"
	local nodeFilter = ""
	local pendingRefresh = false
	local render: () -> ()

	local header = label(container, "👑 Ranks", 20, Theme.Colors.Text, Theme.Font.Bold)
	header.Size = UDim2.new(1, -110, 0, 28)
	local subtitle = label(container, "Loading…", 13, Theme.Colors.TextSecondary)
	subtitle.Position = UDim2.new(0, 0, 0, 28)
	subtitle.Size = UDim2.new(1, -110, 0, 20)

	local refreshButton = button(container, "Refresh", 100)
	refreshButton.AnchorPoint = Vector2.new(1, 0)
	refreshButton.Position = UDim2.new(1, 0, 0, 0)

	local tabs = row(container, 30)
	tabs.Name = "Tabs"
	tabs.Position = UDim2.new(0, 0, 0, 54)
	local tabButtons: { [string]: TextButton } = {}
	for i, name in ipairs({ "Ranks", "Assignments", "History" }) do
		local b = button(tabs, name, 120)
		b.LayoutOrder = i
		tabButtons[name] = b
		b.MouseButton1Click:Connect(function()
			activeTab = name
			render()
		end)
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.new(0, 0, 0, 92)
	body.Size = UDim2.new(1, 0, 1, -92)
	body.Parent = container

	local function send(commandText: string)
		executeRemote:FireServer(commandText)
	end

	local function refresh()
		if not snapshotRemote then
			subtitle.Text = "Rank data is unavailable (server remote missing)."
			return
		end
		local ok, data = pcall(function()
			return (snapshotRemote :: RemoteFunction):InvokeServer()
		end)
		if not ok then
			subtitle.Text = "Could not load ranks."
			return
		end
		if data == nil then
			-- Rate-limited or no ranks.view: try once more shortly.
			if not pendingRefresh then
				pendingRefresh = true
				task.delay(0.7, function()
					pendingRefresh = false
					refresh()
				end)
			end
			return
		end
		snapshot = data
		snapshot.PageIds = pageIds or {}
		render()
	end

	-- ----------------------------------------------------------------------
	-- Ranks tab
	-- ----------------------------------------------------------------------
	local function findRank(name: string?): any
		if not snapshot or not name then
			return nil
		end
		for _, r in ipairs(snapshot.Ranks) do
			if r.Name == name then
				return r
			end
		end
		return nil
	end

	local function renderRanksTab()
		local canManage = snapshot.Me.CanManage and not snapshot.ReadOnly

		local list = scroller(body, UDim2.new(0, 0, 0, 0), UDim2.new(0, 230, 1, -40))
		list.Name = "RankList"
		vlist(list, 4)
		for i, r in ipairs(snapshot.Ranks) do
			local item = Instance.new("TextButton")
			item.LayoutOrder = i
			item.Size = UDim2.new(1, 0, 0, 40)
			item.BackgroundColor3 = if r.Name == selectedRank then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
			item.BackgroundTransparency = if r.Name == selectedRank then 0.6 else 0
			item.AutoButtonColor = true
			item.Font = Theme.Font.Medium
			item.TextSize = 13
			item.TextColor3 = Theme.Colors.Text
			item.TextXAlignment = Enum.TextXAlignment.Left
			item.Text = ("      %s %s  ·  %d%s"):format(
				r.Icon,
				r.Name,
				r.Priority,
				if #r.OnlineHolders > 0 then ("  ·  %d online"):format(#r.OnlineHolders) else ""
			)
			item.Name = "Rank_" .. r.Name
			item.Parent = list
			Theme.corner(item, Theme.Radius.S)
			local dot = Instance.new("Frame")
			dot.Size = UDim2.new(0, 10, 0, 10)
			dot.Position = UDim2.new(0, 8, 0.5, -5)
			dot.BackgroundColor3 = Color3.fromRGB(r.Color[1], r.Color[2], r.Color[3])
			dot.Parent = item
			Theme.corner(dot, UDim.new(1, 0))
			item.MouseButton1Click:Connect(function()
				selectedRank = r.Name
				render()
			end)
		end

		-- New / duplicate / delete
		local actions = row(body, 32)
		actions.Name = "Actions"
		actions.Position = UDim2.new(0, 0, 1, -32)
		actions.Size = UDim2.new(0, 230, 0, 32)
		local newName = textbox(actions, "New rank name", "", UDim.new(0, 86))
		local createB = button(actions, "+ New", 52, Theme.Colors.Accent)
		local dupB = button(actions, "Copy", 40)
		local delB = button(actions, "Del", 34, Theme.Colors.Error)
		newName.LayoutOrder, createB.LayoutOrder, dupB.LayoutOrder, delB.LayoutOrder = 1, 2, 3, 4
		for _, w in ipairs({ newName, createB, dupB, delB } :: { GuiObject }) do
			w.Visible = canManage
		end
		createB.MouseButton1Click:Connect(function()
			if newName.Text ~= "" then
				-- New ranks start at priority 1; edit it afterwards.
				send(("createrank %s 1"):format(arg(newName.Text)))
				selectedRank = newName.Text
			end
		end)
		dupB.MouseButton1Click:Connect(function()
			if selectedRank and newName.Text ~= "" then
				send(("duplicaterank %s %s"):format(selectedRank, arg(newName.Text)))
				selectedRank = newName.Text
			end
		end)
		delB.MouseButton1Click:Connect(function()
			if selectedRank then
				send(("deleterank %s"):format(selectedRank))
				selectedRank = nil
			end
		end)

		-- Detail panel
		local rank = findRank(selectedRank)
		local detail = scroller(body, UDim2.new(0, 240, 0, 0), UDim2.new(1, -240, 1, 0))
		detail.Name = "Detail"
		vlist(detail, 8)
		if not rank then
			label(detail, "Select a rank.", 14, Theme.Colors.TextSecondary)
			return
		end

		local title = label(detail, ("%s %s"):format(rank.Icon, rank.Name), 18, Theme.Colors.Text, Theme.Font.Bold)
		title.LayoutOrder = 1
		local meta = label(
			detail,
			("Priority %d%s · %d assignment(s) · online: %s"):format(
				rank.Priority,
				if rank.Protected then " · protected" else "",
				(function()
					local n = 0
					for _, b in ipairs(snapshot.Bindings) do
						if b.Rank == rank.Name then
							n += 1
						end
					end
					return n
				end)(),
				if #rank.OnlineHolders > 0 then table.concat(rank.OnlineHolders, ", ") else "nobody"
			),
			12,
			Theme.Colors.TextSecondary
		)
		meta.LayoutOrder = 2

		-- Details form
		local fields = {
			{ Key = "name", Label = "Name", Value = rank.Name },
			{ Key = "priority", Label = "Priority", Value = tostring(rank.Priority) },
			{ Key = "color", Label = "Color (R,G,B or #hex)", Value = ("%d,%d,%d"):format(rank.Color[1], rank.Color[2], rank.Color[3]) },
			{ Key = "icon", Label = "Icon", Value = rank.Icon },
			{ Key = "description", Label = "Description", Value = rank.Description },
			{ Key = "inherits", Label = "Inherits (comma list)", Value = table.concat(rank.Inherits, ",") },
		}
		local boxes: { [string]: TextBox } = {}
		for i, f in ipairs(fields) do
			local r = row(detail, 28, 10 + i)
			r.Name = "Field_" .. f.Key
			local l = label(r, f.Label, 12, Theme.Colors.TextSecondary)
			l.Size = UDim2.new(0, 150, 1, 0)
			local box = textbox(r, f.Label, f.Value, UDim.new(1, -156))
			box.TextEditable = canManage and not rank.Protected or (canManage and (f.Key == "color" or f.Key == "icon" or f.Key == "description"))
			boxes[f.Key] = box
		end
		local saveRow = row(detail, 30, 20)
		saveRow.Name = "SaveRow"
		local saveB = button(saveRow, "Save details", 120, Theme.Colors.Accent)
		saveB.Visible = canManage
		saveB.MouseButton1Click:Connect(function()
			-- One ;updaterank for all changed fields (separate commands would
			-- trip the per-command cooldown), then the rename if any.
			local pairsText = {}
			for _, f in ipairs(fields) do
				local newValue = boxes[f.Key].Text
				if f.Key ~= "name" and newValue ~= f.Value then
					local value = if newValue == "" and f.Key == "inherits" then "none" else newValue
					local quoted = arg(value)
					if quoted == "" then
						quoted = '""'
					end
					table.insert(pairsText, f.Key .. " " .. quoted)
				end
			end
			local parts = {}
			if #pairsText > 0 then
				table.insert(parts, ("updaterank %s %s"):format(rank.Name, table.concat(pairsText, " ")))
			end
			local newName = boxes.name.Text
			if newName ~= rank.Name and newName ~= "" then
				table.insert(parts, ("renamerank %s %s"):format(rank.Name, arg(newName)))
				selectedRank = newName
			end
			if #parts > 0 then
				send(table.concat(parts, " && "))
			end
		end)

		-- Presets
		local presetTitle = label(detail, "Permission presets", 14, Theme.Colors.Text, Theme.Font.Bold)
		presetTitle.LayoutOrder = 30
		local presetRow = Instance.new("Frame")
		presetRow.BackgroundTransparency = 1
		presetRow.Size = UDim2.new(1, 0, 0, 0)
		presetRow.AutomaticSize = Enum.AutomaticSize.Y
		presetRow.LayoutOrder = 31
		presetRow.Name = "Presets"
		presetRow.Parent = detail
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.new(0, 130, 0, 28)
		grid.CellPadding = UDim2.new(0, 6, 0, 6)
		grid.Parent = presetRow
		for _, preset in ipairs(snapshot.Presets) do
			local b = button(presetRow, "+ " .. preset.Name, 130)
			b.Active = canManage and not rank.Protected
			b.AutoButtonColor = b.Active
			b.TextTransparency = if b.Active then 0 else 0.5
			b.MouseButton1Click:Connect(function()
				if b.Active then
					send(("rankpreset %s %s"):format(rank.Name, preset.Name))
				end
			end)
		end

		-- Permission preview
		local previewTitle = label(
			detail,
			("Preview: can run %d of %d commands"):format(#rank.AllowedCommands, #snapshot.Commands),
			14,
			Theme.Colors.Text,
			Theme.Font.Bold
		)
		previewTitle.LayoutOrder = 40
		local previewText = label(detail, table.concat(rank.AllowedCommands, ", "), 12, Theme.Colors.TextSecondary)
		previewText.LayoutOrder = 41
		previewText.AutomaticSize = Enum.AutomaticSize.Y

		-- Permission editor
		local editorTitle = label(detail, "Permissions (click to cycle: — / Allow / Deny)", 14, Theme.Colors.Text, Theme.Font.Bold)
		editorTitle.LayoutOrder = 50
		local search = textbox(detail, "🔍 Search permissions or commands…", nodeFilter)
		search.LayoutOrder = 51

		local nodeList = Instance.new("Frame")
		nodeList.BackgroundTransparency = 1
		nodeList.Size = UDim2.new(1, 0, 0, 0)
		nodeList.AutomaticSize = Enum.AutomaticSize.Y
		nodeList.LayoutOrder = 52
		nodeList.Name = "NodeList"
		nodeList.Parent = detail
		vlist(nodeList, 3)

		-- node -> commands using it
		local nodeCommands: { [string]: { string } } = {}
		for _, cmd in ipairs(snapshot.Commands) do
			nodeCommands[cmd.Permission] = nodeCommands[cmd.Permission] or {}
			table.insert(nodeCommands[cmd.Permission], cmd.Name)
		end
		local allNodes: { [string]: boolean } = {}
		for node in pairs(nodeCommands) do
			allNodes[node] = true
		end
		for _, node in ipairs(EXTRA_NODES) do
			allNodes[node] = true
		end
		for _, pageId in ipairs(snapshot.PageIds or {}) do
			allNodes["page." .. pageId:lower()] = true
		end
		for _, n in ipairs(rank.Nodes) do
			allNodes[if n:sub(1, 1) == "!" then n:sub(2) else n] = true
		end
		local sorted = {}
		for node in pairs(allNodes) do
			table.insert(sorted, node)
		end
		table.sort(sorted)

		local allowedSet: { [string]: boolean } = {}
		for _, c in ipairs(rank.AllowedCommands) do
			allowedSet[c] = true
		end

		local function renderNodes()
			clear(nodeList)
			local filter = nodeFilter:lower()
			local shown = 0
			for i, node in ipairs(sorted) do
				local cmds = nodeCommands[node] or {}
				local haystack = (node .. " " .. table.concat(cmds, " ")):lower()
				if filter ~= "" and not haystack:find(filter, 1, true) then
					continue
				end
				shown += 1
				local direct = if table.find(rank.Nodes, "!" .. node)
					then "deny"
					elseif table.find(rank.Nodes, node) then "allow"
					else nil
				-- Effective state for nodes that gate commands.
				local effective = nil
				if #cmds > 0 then
					effective = allowedSet[cmds[1]] == true
				end

				local r = row(nodeList, 26, i)
				r.Name = "Node_" .. node:gsub("[^%w]", "_")
				local stateB = button(r, if direct == "allow" then "Allow" elseif direct == "deny" then "Deny" else "—", 64)
				stateB.BackgroundColor3 = if direct == "allow"
					then Theme.Colors.Success
					elseif direct == "deny" then Theme.Colors.Error
					else Theme.Colors.SurfaceRaised
				local nodeLabel = label(r, node, 13, Theme.Colors.Text, Theme.Font.Mono)
				nodeLabel.Size = UDim2.new(0, 200, 1, 0)
				nodeLabel.TextWrapped = false
				nodeLabel.TextTruncate = Enum.TextTruncate.AtEnd
				local info = label(
					r,
					(if effective == true then "✔ effective  " elseif effective == false then "✖ not effective  " else "")
						.. (if #cmds > 0 then table.concat(cmds, ", ") else ""),
					11,
					if effective then Theme.Colors.Success else Theme.Colors.TextSecondary
				)
				info.Size = UDim2.new(1, -282, 1, 0)
				info.TextWrapped = false
				info.TextTruncate = Enum.TextTruncate.AtEnd

				local editable = canManage and not rank.Protected
				stateB.AutoButtonColor = editable
				stateB.MouseButton1Click:Connect(function()
					if not editable then
						return
					end
					-- — -> Allow -> Deny -> —
					if direct == nil then
						send(("rankperm %s +%s"):format(rank.Name, node))
					elseif direct == "allow" then
						send(("rankperm %s +!%s"):format(rank.Name, node)) -- replaces the allow
					else
						send(("rankperm %s -!%s"):format(rank.Name, node))
					end
				end)
			end
			if shown == 0 then
				label(nodeList, "No permissions match.", 12, Theme.Colors.TextSecondary)
			end
		end
		renderNodes()
		search:GetPropertyChangedSignal("Text"):Connect(function()
			nodeFilter = search.Text
			renderNodes()
		end)
	end

	-- ----------------------------------------------------------------------
	-- Assignments tab
	-- ----------------------------------------------------------------------
	local function renderAssignmentsTab()
		local canAssign = snapshot.Me.CanAssign and not snapshot.ReadOnly
		local list = scroller(body, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, if canAssign then -76 else 0))
		list.Name = "AssignList"
		vlist(list, 4)
		for i, b in ipairs(snapshot.Bindings) do
			local r = row(list, 30, i)
			r.Name = "Binding_" .. b.Id
			local removeB = button(r, "Remove", 70, Theme.Colors.Error)
			removeB.Visible = canAssign and not b.Protected
			local l = label(r, ("[%s] %s%s"):format(b.Id, b.Description, if b.Protected then "  (protected)" else ""), 13)
			l.Size = UDim2.new(1, -80, 1, 0)
			removeB.MouseButton1Click:Connect(function()
				send(("unbindrank %s"):format(b.Id))
			end)
		end
		if not canAssign then
			return
		end

		local form = Instance.new("Frame")
		form.Name = "AddForm"
		form.BackgroundTransparency = 1
		form.Position = UDim2.new(0, 0, 1, -68)
		form.Size = UDim2.new(1, 0, 0, 68)
		form.Parent = body
		vlist(form, 6)
		local r1 = row(form, 28, 1)
		r1.Name = "Row1"
		local kindIndex = 1
		local kindB = button(r1, "Kind: username", 130)
		kindB.LayoutOrder = 1
		local valueBox = textbox(r1, "Username / id", "", UDim.new(0.3, 0))
		valueBox.LayoutOrder = 2
		local rankBox = textbox(r1, "Rank", "", UDim.new(0.2, 0))
		rankBox.LayoutOrder = 3
		local durationBox = textbox(r1, "Duration (7d; blank = forever)", "", UDim.new(0.25, 0))
		durationBox.LayoutOrder = 4
		local r2 = row(form, 28, 2)
		r2.Name = "Row2"
		local minRankBox = textbox(r2, "Min group rank (grouprole only)", "", UDim.new(0.3, 0))
		minRankBox.LayoutOrder = 1
		local addB = button(r2, "+ Add assignment", 140, Theme.Colors.Accent)
		addB.LayoutOrder = 2
		kindB.MouseButton1Click:Connect(function()
			kindIndex = kindIndex % #BINDING_KINDS + 1
			kindB.Text = "Kind: " .. BINDING_KINDS[kindIndex]
		end)
		addB.MouseButton1Click:Connect(function()
			if valueBox.Text == "" or rankBox.Text == "" then
				return
			end
			local parts = { "bindrank", BINDING_KINDS[kindIndex], arg(valueBox.Text), arg(rankBox.Text) }
			if durationBox.Text ~= "" then
				table.insert(parts, arg(durationBox.Text))
			end
			if minRankBox.Text ~= "" then
				table.insert(parts, arg(minRankBox.Text))
			end
			send(table.concat(parts, " "))
		end)
	end

	-- ----------------------------------------------------------------------
	-- History tab
	-- ----------------------------------------------------------------------
	local function renderHistoryTab()
		local list = scroller(body, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, 0))
		vlist(list, 4)
		if #snapshot.History == 0 then
			label(list, "No rank changes yet.", 13, Theme.Colors.TextSecondary)
		end
		for i, h in ipairs(snapshot.History) do
			local l = label(
				list,
				("%s  ·  %s  ·  %s"):format(os.date("%Y-%m-%d %H:%M", h.Time), h.ActorName, h.Detail),
				12
			)
			l.LayoutOrder = i
			l.AutomaticSize = Enum.AutomaticSize.Y
		end
	end

	local lastRendered = { Tab = "", Rank = "" }

	render = function()
		for name, b in pairs(tabButtons) do
			b.BackgroundColor3 = if name == activeTab then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		end
		-- Keep scroll positions across refreshes (each refresh rebuilds the
		-- body), so editing a permission far down the list doesn't jump
		-- back to the top. The detail panel only keeps its position when
		-- it still shows the same rank.
		local saved: { [string]: Vector2 } = {}
		if lastRendered.Tab == activeTab then
			for _, name in ipairs({ "RankList", "Detail", "AssignList" }) do
				local frame = body:FindFirstChild(name)
				if frame and frame:IsA("ScrollingFrame") then
					if name ~= "Detail" or lastRendered.Rank == selectedRank then
						saved[name] = frame.CanvasPosition
					end
				end
			end
		end
		clear(body)
		if not snapshot then
			return
		end
		subtitle.Text = ("You: %s (priority %s)%s%s"):format(
			snapshot.Me.TopRank or "no rank",
			if snapshot.Me.Priority == nil then "—" else tostring(snapshot.Me.Priority),
			if snapshot.Me.CanManage then "" else " · view only",
			if snapshot.ReadOnly then " · ⚠ rank data failed to load, editing disabled" else ""
		)
		if findRank(selectedRank) == nil and snapshot.Ranks[1] then
			selectedRank = snapshot.Ranks[1].Name
		end
		if activeTab == "Ranks" then
			renderRanksTab()
		elseif activeTab == "Assignments" then
			renderAssignmentsTab()
		else
			renderHistoryTab()
		end
		lastRendered.Tab = activeTab
		lastRendered.Rank = selectedRank or ""
		if next(saved) then
			task.defer(function()
				task.wait() -- let AutomaticCanvasSize settle first
				for name, position in pairs(saved) do
					local frame = body:FindFirstChild(name)
					if frame and frame:IsA("ScrollingFrame") then
						frame.CanvasPosition = position
					end
				end
			end)
		end
	end

	refreshButton.MouseButton1Click:Connect(refresh)

	-- Refresh after any command result while the page is visible (covers
	-- our own edits and rank commands typed in chat or the palette).
	resultRemote.OnClientEvent:Connect(function()
		if container.Visible then
			task.delay(0.6, refresh)
		end
	end)
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			refresh()
		end
	end)
end

return RankManagementPage
