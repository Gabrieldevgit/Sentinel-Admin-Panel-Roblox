--!strict
--[[
	LookupPage.lua (W13 - offline management)

	Players > Lookup. Two tabs:
		Profile   look up any Roblox user by username or UserId, online or
		          offline: identity, first / last seen, sessions, play time,
		          account age, usernames seen, ranks, where they are now,
		          ban status, warnings, moderation cases (click = open the
		          case), staff notes. Actions: ban (duration + reason),
		          unban, warn, open a case. Actions use the global commands
		          (gban / gwarn) so they work wherever the player is.
		Ban list  every active ban, filter box, unban per row.

	Reads GetOfflineProfileRemote(query) and GetBanListRemote(); every
	change is a command through ExecuteCommandRemote.

	Stable instance names (Studio MCP tests):
		Tabs.Tab_<Profile|Bans>
		Profile.Search.{Query,Go}, Profile.Card.{Identity,Fields,Ban,Actions,
		Warnings,Cases,Notes}, Profile.Card.Actions.{Duration,Reason,Ban,
		Unban,Warn,Case}
		Bans.Top.{Filter,Refresh}, Bans.List.Ban_<userId>.Unban
	Public API:
		LookupPage.Build(container, openCase?)
		LookupPage.Show(query)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local LookupPage = {}

local layoutCounter = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		layoutCounter += 1
		inst.LayoutOrder = layoutCounter
	elseif inst:IsA("UIListLayout") or inst:IsA("UIGridLayout") then
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

local function label(parent: Instance, name: string, text: string, props: { [string]: any }?): TextLabel
	local l = make("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 18),
		Text = text,
	}, parent)
	for k, v in pairs(props or {}) do
		(l :: any)[k] = v
	end
	return l
end

local function wrapLabel(parent: Instance, name: string, text: string, color: Color3?): TextLabel
	return label(parent, name, text, {
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		TextColor3 = color or Theme.Colors.Text,
	})
end

local function button(parent: Instance, name: string, text: string, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width or 80, 0, 26),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function textBox(parent: Instance, name: string, placeholder: string, width: UDim2): TextBox
	local b = make("TextBox", {
		Name = name,
		Size = width,
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Text = "",
	}, parent) :: TextBox
	Theme.corner(b, Theme.Radius.S)
	Theme.padding(b, 6)
	return b
end

local function age(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m"
	elseif seconds < 86400 then
		return ("%dh %dm"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
	end
	return ("%dd %dh"):format(math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

local function expiry(expiresAt: number?): string
	if expiresAt == -1 or expiresAt == nil then
		return "permanent"
	end
	return age(expiresAt - os.time()) .. " left"
end

local function clean(text: string): string
	return (text:gsub("&&", "&"):match("^%s*(.-)%s*$")) :: string
end

local api: any = {}

function LookupPage.Show(query: string)
	if api.Show then
		api.Show(query)
	end
end

function LookupPage.Build(container: Frame, openCase: ((number) -> ())?)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local profileRemote = SentinelShared:WaitForChild("GetOfflineProfileRemote", 15) :: RemoteFunction?
	local banListRemote = SentinelShared:WaitForChild("GetBanListRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?

	local function run(text: string)
		if executeRemote then
			executeRemote:FireServer(text)
		end
	end

	label(container, "Header", "Player Lookup", { Size = UDim2.new(1, -200, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	local statusLine = label(container, "SubHeader", "Any Roblox user, online or offline.", {
		Position = UDim2.new(0, 0, 0, 28),
		TextColor3 = Theme.Colors.TextSecondary,
	})

	local tabs = make("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 200, 0, 26),
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 4) }, tabs)

	local pages: { [string]: GuiObject } = {}
	local tabButtons: { [string]: TextButton } = {}
	local refreshBans: () -> () -- forward
	local function show(name: string)
		for id, page in pairs(pages) do
			page.Visible = id == name
		end
		for id, b in pairs(tabButtons) do
			b.BackgroundColor3 = if id == name then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		end
		if name == "Bans" then
			task.spawn(refreshBans)
		end
	end
	for _, spec in ipairs({ { "Profile", "Profile" }, { "Bans", "Ban list" } }) do
		local b = button(tabs, "Tab_" .. spec[1], spec[2], 84)
		tabButtons[spec[1]] = b
		b.Activated:Connect(function()
			show(spec[1])
		end)
	end

	-- ======================================================================
	-- Profile
	-- ======================================================================
	local profilePage = make("Frame", { Name = "Profile", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 1, -52) }, container)
	pages.Profile = profilePage
	local searchRow = make("Frame", { Name = "Search", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, profilePage)
	local query = textBox(searchRow, "Query", "Username or UserId (online or offline)", UDim2.new(1, -96, 1, 0))
	local go = button(searchRow, "Go", "Look up", 88)
	go.Position = UDim2.new(1, -88, 0, 0)
	go.BackgroundColor3 = Theme.Colors.Accent

	local card = make("ScrollingFrame", {
		Name = "Card",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 36),
		Size = UDim2.new(1, 0, 1, -36),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, profilePage)
	Theme.corner(card, Theme.Radius.S)
	Theme.padding(card, 10)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, card)

	local function clear(frame: Instance)
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function block(name: string, title: string): Frame
		local f = make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, card)
		make("UIListLayout", { Padding = UDim.new(0, 2) }, f)
		label(f, "Title", title, { Font = Theme.Font.Bold, TextSize = 13 })
		return f
	end

	local current: any = nil
	local lookup: (string) -> () -- forward

	local function render(p: any)
		clear(card)
		current = p
		local identity = make("Frame", { Name = "Identity", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 60) }, card)
		local avatar = make("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(0, 60, 0, 60),
			Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(p.UserId),
		}, identity)
		Theme.corner(avatar, UDim.new(1, 0))
		label(identity, "Name", ("%s%s"):format(p.DisplayName or p.Name, if p.Verified then "  (verified)" else ""), {
			Position = UDim2.new(0, 72, 0, 4),
			Size = UDim2.new(1, -72, 0, 22),
			Font = Theme.Font.Bold,
			TextSize = 18,
		})
		label(identity, "Handle", ("@%s  -  UserId %d"):format(p.Name, p.UserId), {
			Position = UDim2.new(0, 72, 0, 26),
			Size = UDim2.new(1, -72, 0, 16),
			TextColor3 = Theme.Colors.TextSecondary,
		})
		label(identity, "Where", if p.Online then "Online - " .. tostring(p.Server) else "Offline", {
			Position = UDim2.new(0, 72, 0, 42),
			Size = UDim2.new(1, -72, 0, 16),
			TextColor3 = if p.Online then Theme.Colors.Success else Theme.Colors.TextSecondary,
		})

		local banBox = make("Frame", {
			Name = "Ban",
			BackgroundColor3 = if p.Ban then Theme.Colors.Error else Theme.Colors.SurfaceRaised,
			BackgroundTransparency = if p.Ban then 0.75 else 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
		}, card)
		Theme.corner(banBox, Theme.Radius.S)
		Theme.padding(banBox, 8)
		wrapLabel(banBox, "Text", if p.Ban
			then ("BANNED (%s): %s"):format(expiry(p.Ban.ExpiresAt), tostring(p.Ban.Reason))
			else "Not banned.", if p.Ban then Theme.Colors.Text else Theme.Colors.Success)

		local fields = block("Fields", "Profile")
		local function field(key: string, value: string)
			local row = make("Frame", { Name = "F_" .. key:gsub("%W", ""), BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18) }, fields)
			label(row, "Key", key, { Size = UDim2.new(0, 120, 1, 0), TextColor3 = Theme.Colors.TextSecondary })
			label(row, "Value", value, { Position = UDim2.new(0, 124, 0, 0), Size = UDim2.new(1, -124, 1, 0) })
		end
		local now = os.time()
		if p.LastSeen then
			field("Last seen", if p.Online and p.Server == "this server" then "now" else age(now - p.LastSeen) .. " ago")
			field("First seen", os.date("%Y-%m-%d", p.FirstSeen) .. " (" .. age(now - p.FirstSeen) .. " ago)")
			field("Sessions", tostring(p.Sessions or 0))
			field("Play time", age(p.PlayTime or 0) .. if p.SessionSeconds then (" (+%s this session)"):format(age(p.SessionSeconds)) else "")
			field("Last server", tostring(p.LastServer or "?"))
		else
			field("History", "Never seen in this experience")
		end
		field("Account age", if p.AccountAge then p.AccountAge .. " days" else "unknown (only known after a visit)")
		field("Usernames seen", if p.Names and #p.Names > 0 then table.concat(p.Names, ", ") else p.Name)
		local ranks = {}
		for _, r in ipairs(p.Ranks or {}) do
			table.insert(ranks, r)
		end
		for _, r in ipairs(p.BoundRanks or {}) do
			if not table.find(ranks, r) then
				table.insert(ranks, r)
			end
		end
		field("Ranks", if #ranks > 0 then table.concat(ranks, ", ") else "none")

		-- Actions ---------------------------------------------------------------
		if p.CanBan then
			local actions = block("Actions", "Actions")
			local row = make("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26) }, actions)
			make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, row)
			local durationBox = textBox(row, "Duration", "7d / perm", UDim2.new(0, 80, 1, 0))
			durationBox.Text = "7d"
			local reasonBox = textBox(row, "Reason", "Reason or #template", UDim2.new(1, -420, 1, 0))
			local function act(name: string, text: string, build: () -> string?)
				local b = button(row, name, text, 76)
				b.Activated:Connect(function()
					local cmd = build()
					if cmd then
						run(cmd) -- the profile reloads when the result arrives
					end
				end)
				return b
			end
			act("Ban", "Ban", function()
				local d = clean(durationBox.Text)
				if d == "" then
					return nil
				end
				local r = clean(reasonBox.Text)
				return ("gban %d %s%s"):format(p.UserId, d:match("^%S+"), if r ~= "" then " " .. r else "")
			end).BackgroundColor3 = Theme.Colors.Error
			act("Unban", "Unban", function()
				local r = clean(reasonBox.Text)
				return ("unban %d%s"):format(p.UserId, if r ~= "" then " " .. r else "")
			end)
			act("Warn", "Warn", function()
				local r = clean(reasonBox.Text)
				return if r ~= "" then ("gwarn %d %s"):format(p.UserId, r) else nil
			end)
			act("Case", "Open case", function()
				local r = clean(reasonBox.Text)
				return if r ~= "" then ("caseopen %d %s"):format(p.UserId, r) else nil
			end)
		end

		-- History ---------------------------------------------------------------
		local warnings = block("Warnings", ("Warnings (%d)"):format(p.WarningCount or 0))
		for i, w in ipairs(p.Warnings or {}) do
			wrapLabel(warnings, "W_" .. i, ("%s  %s - by %s"):format(os.date("%Y-%m-%d", w.Timestamp), w.Reason, w.IssuedByName or "?"))
		end
		local cases = block("Cases", ("Moderation cases (%d)"):format(p.CaseCount or 0))
		for _, c in ipairs(p.Cases or {}) do
			local row = make("TextButton", {
				Name = "Case_" .. c.Id,
				AutoButtonColor = true,
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				Size = UDim2.new(1, 0, 0, 22),
				Text = "",
			}, cases) :: TextButton
			Theme.corner(row, UDim.new(0, 4))
			label(row, "Line", ("#%d  %s  [%s]  by %s%s  %s"):format(
				c.Id,
				c.Type,
				c.Status,
				c.ModeratorName,
				if c.Reason then '  "' .. c.Reason .. '"' else "",
				os.date("%Y-%m-%d", c.CreatedAt)
			), { Position = UDim2.new(0, 8, 0, 0), Size = UDim2.new(1, -16, 1, 0) })
			row.Activated:Connect(function()
				if openCase then
					openCase(c.Id)
				end
			end)
		end
		local notes = block("Notes", ("Staff notes (%d)"):format(#(p.Notes or {})))
		for i, n in ipairs(p.Notes or {}) do
			wrapLabel(notes, "N_" .. i, ("%s  %s: %s"):format(os.date("%Y-%m-%d", n.Timestamp), n.AddedBy, n.Text))
		end
		statusLine.Text = ("Profile of %s loaded %s."):format(p.Name, os.date("%H:%M:%S") :: string)
	end

	lookup = function(text: string)
		text = clean(text)
		if text == "" or not profileRemote then
			return
		end
		statusLine.Text = "Looking up " .. text .. "..."
		local ok, p = pcall(function()
			return profileRemote:InvokeServer(text)
		end)
		if not ok or type(p) ~= "table" then
			statusLine.Text = "Lookup failed (try again in a moment)."
			return
		end
		if p.Error then
			statusLine.Text = p.Error
			return
		end
		render(p)
	end

	go.Activated:Connect(function()
		lookup(query.Text)
	end)
	query.FocusLost:Connect(function(enter)
		if enter then
			lookup(query.Text)
		end
	end)
	label(card, "Hint", "Type a username or UserId and press Look up.", { TextColor3 = Theme.Colors.TextSecondary })

	api.Show = function(text: string)
		show("Profile")
		query.Text = text
		task.spawn(lookup, text)
	end

	-- ======================================================================
	-- Ban list
	-- ======================================================================
	local bansPage = make("Frame", { Name = "Bans", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 1, -52), Visible = false }, container)
	pages.Bans = bansPage
	local top = make("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, bansPage)
	local filter = textBox(top, "Filter", "Filter by name, id, reason or moderator", UDim2.new(1, -96, 1, 0))
	local refresh = button(top, "Refresh", "Refresh", 88)
	refresh.Position = UDim2.new(1, -88, 0, 0)
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 36),
		Size = UDim2.new(1, 0, 1, -36),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, bansPage)
	Theme.corner(list, Theme.Radius.S)
	Theme.padding(list, 6)
	make("UIListLayout", { Padding = UDim.new(0, 3) }, list)

	local bans: { any } = {}
	local function renderBans()
		clear(list)
		local needle = filter.Text:lower()
		local shown = 0
		for _, b in ipairs(bans) do
			local text = ("%s (%d)  %s  by %s  %s"):format(b.Name or "?", b.UserId, expiry(b.ExpiresAt), b.BannedByName or tostring(b.BannedBy), b.Reason or "")
			if needle == "" or text:lower():find(needle, 1, true) then
				shown += 1
				local row = make("Frame", { Name = "Ban_" .. b.UserId, BackgroundColor3 = Theme.Colors.SurfaceRaised, Size = UDim2.new(1, 0, 0, 28) }, list)
				Theme.corner(row, UDim.new(0, 4))
				local nameBtn = make("TextButton", {
					Name = "Open",
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 8, 0, 0),
					Size = UDim2.new(1, -100, 1, 0),
					Font = Theme.Font.Regular,
					TextSize = 12,
					TextColor3 = Theme.Colors.Text,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Text = text,
				}, row) :: TextButton
				nameBtn.Activated:Connect(function()
					api.Show(tostring(b.UserId))
				end)
				local unban = button(row, "Unban", "Unban", 80)
				unban.Position = UDim2.new(1, -84, 0, 1)
				unban.Activated:Connect(function()
					run("unban " .. b.UserId) -- the list reloads when the result arrives
				end)
			end
		end
		if shown == 0 then
			label(list, "Empty", if #bans == 0 then "No active bans." else "No bans match the filter.", { TextColor3 = Theme.Colors.TextSecondary })
		end
		statusLine.Text = ("%d active ban(s)."):format(#bans)
	end

	refreshBans = function()
		if not banListRemote then
			return
		end
		local ok, data = pcall(function()
			return banListRemote:InvokeServer()
		end)
		if not ok or type(data) ~= "table" then
			statusLine.Text = "Could not load the ban list."
			return
		end
		bans = data.Bans or {}
		renderBans()
		if data.Error then
			statusLine.Text = data.Error
		end
	end
	refresh.Activated:Connect(refreshBans)
	filter:GetPropertyChangedSignal("Text"):Connect(renderBans)

	-- Reload after any command result (actions may wait on a confirmation
	-- dialog first, so a fixed delay would reload too early).
	local currentTab = function(): string
		return if pages.Bans.Visible then "Bans" else "Profile"
	end
	local pendingReload = false
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function()
			if not container.Visible or pendingReload then
				return
			end
			pendingReload = true
			task.delay(0.5, function()
				pendingReload = false
				if currentTab() == "Bans" then
					refreshBans()
				elseif current then
					lookup(tostring(current.UserId))
				end
			end)
		end)
	end

	show("Profile")
end

return LookupPage
