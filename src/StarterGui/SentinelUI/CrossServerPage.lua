--!strict
--[[
	CrossServerPage.lua (W18)

	Purpose:
		The Cross-Server page: every running server of the experience and the
		tools that act on all of them.

		Servers     live list (health, players, staff, uptime, version) with
		            search, Join, and a details row with the server's players
		Players     find a player in any server or offline; Follow, Bring,
		            Kick, Warn, Ban, Unban
		Global      announcement, staff notification, lockdown, update
		            countdown / migration, shutdown, global command
		Staff Chat  cross-server staff chat
		Operations  what this server sent, and which servers acknowledged
		History     global actions taken from any server (persisted)

	Reads GetCrossServerSnapshotRemote / GetCrossServerServerRemote /
	CrossServerFindRemote; live updates arrive on CrossServerEventRemote.
	Every action is a normal command sent with ExecuteCommandRemote, so
	permissions, confirmations (ConfirmDialog) and logging apply.

	Widgets have stable names for Studio MCP input, e.g.
	Tabs.Tab_Servers, List.Server_<short id>.Actions.Join,
	Controls.FindBox, List.Player_<userId>.Actions.Kick.

	Public API:
		CrossServerPage.Build(container, notificationCenter?)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local CrossServerPage = {}

local TABS = { "Servers", "Players", "Global", "Staff Chat", "Operations", "History" }

local layoutCounter = 0
local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	if inst:IsA("GuiObject") then
		layoutCounter += 1
		inst.LayoutOrder = layoutCounter
		inst.BorderSizePixel = 0
	elseif inst:IsA("UIListLayout") then
		inst.SortOrder = Enum.SortOrder.LayoutOrder
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
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
	}, nil)
	for k, v in pairs(props or {}) do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

local function button(parent: Instance, name: string, text: string, color: Color3?, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		AutoButtonColor = true,
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		Size = UDim2.new(0, width or 80, 0, 26),
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function textBox(parent: Instance, name: string, placeholder: string, size: UDim2): TextBox
	local box = make("TextBox", {
		Name = name,
		Size = size,
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Text = "",
	}, parent)
	Theme.corner(box, Theme.Radius.S)
	Theme.stroke(box, Theme.Colors.Border, 1)
	Theme.padding(box, 6)
	return box
end

local function ago(t: number?, now: number): string
	local d = math.max(0, now - (t or now))
	if d < 60 then
		return d .. "s"
	elseif d < 3600 then
		return math.floor(d / 60) .. "m"
	elseif d < 86400 then
		return ("%dh %dm"):format(math.floor(d / 3600), math.floor(d % 3600 / 60))
	end
	return ("%dd %dh"):format(math.floor(d / 86400), math.floor(d % 86400 / 3600))
end

local HEALTH_COLOR = { good = Theme.Colors.Success, fair = Theme.Colors.Warning, poor = Theme.Colors.Error }
local STATUS_COLOR = {
	complete = Theme.Colors.Success,
	pending = Theme.Colors.Accent,
	sent = Theme.Colors.TextSecondary,
	partial = Theme.Colors.Warning,
	["no response"] = Theme.Colors.Error,
	failed = Theme.Colors.Error,
}

-- One word of a command line: quotes are stripped so a value can't break out.
local function word(text: string): string
	return (text:gsub("[%s\"']", ""))
end

function CrossServerPage.Build(container: Frame, notificationCenter: any?)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent
	local snapshotRemote = SentinelShared:WaitForChild("GetCrossServerSnapshotRemote", 15) :: RemoteFunction
	local serverRemote = SentinelShared:WaitForChild("GetCrossServerServerRemote", 15) :: RemoteFunction
	local findRemote = SentinelShared:WaitForChild("CrossServerFindRemote", 15) :: RemoteFunction
	local eventRemote = SentinelShared:WaitForChild("CrossServerEventRemote", 15) :: RemoteEvent

	local currentTab = "Servers"
	local snapshot: any = nil
	local serverSearch = ""
	local expandedServer: string? = nil
	local expandedInfo: any = nil
	local findQuery = ""
	local findResult: any = nil
	local findBusy = false
	local reasonText, durationText = "", "7d"
	local chatLog: { any } = {}
	local chatSeen: { [string]: boolean } = {}
	local unreadChat = 0
	local operations: { any } = {}
	local history: { any } = {}
	local expandedOp: string? = nil
	local drafts: { [string]: string } = {}

	make("TextLabel", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Font = Theme.Font.Bold,
		TextSize = 20,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Cross-Server",
	}, container)
	local subHeader = label(container, "SubHeader", "Loading servers...", {
		Position = UDim2.new(0, 0, 0, 28),
		Size = UDim2.new(1, 0, 0, 18),
	})

	-- Overview cards
	local overview = make("Frame", {
		Name = "Overview",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 0, 48),
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, overview)
	local cards: { [string]: TextLabel } = {}
	for _, def in ipairs({
		{ "Servers", "Servers" },
		{ "Players", "Players" },
		{ "Staff", "Staff online" },
		{ "Fps", "Avg FPS" },
		{ "Ping", "Avg ping" },
		{ "Peak", "Peak players" },
		{ "Lockdown", "Lockdown" },
	}) do
		local card = make("Frame", {
			Name = "Card_" .. def[1],
			BackgroundColor3 = Theme.Colors.Surface,
			Size = UDim2.new(1 / 7, -6, 1, 0),
		}, overview)
		Theme.corner(card, Theme.Radius.S)
		cards[def[1]] = make("TextLabel", {
			Name = "Value",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 8, 0, 4),
			Size = UDim2.new(1, -12, 0, 22),
			Font = Theme.Font.Bold,
			TextSize = 17,
			TextColor3 = Theme.Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "-",
		}, card)
		label(card, "Caption", def[2], { Position = UDim2.new(0, 8, 0, 27), Size = UDim2.new(1, -12, 0, 14), TextSize = 10 })
	end

	-- W09: scrolls sideways when the panel is too narrow for six tabs.
	local tabBar = make("ScrollingFrame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 106),
		Size = UDim2.new(1, 0, 0, 28),
		ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 0,
	}, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)
	local tabButtons: { [string]: TextButton } = {}

	local controls = make("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, 140),
		Size = UDim2.new(1, 0, 0, 30),
	}, container)
	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		Position = UDim2.new(0, 0, 0, 176),
		Size = UDim2.new(1, 0, 1, -176),
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Border,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, container)
	Theme.corner(list, Theme.Radius.S)
	Theme.padding(list, 6)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, list)

	local function can(node: string): boolean
		return snapshot ~= nil and snapshot.Can ~= nil and snapshot.Can[node] == true
	end

	local function send(text: string)
		executeRemote:FireServer(text)
	end

	local function setStatus(text: string, color: Color3?)
		subHeader.Text = text
		subHeader.TextColor3 = color or Theme.Colors.TextSecondary
	end

	local function clearList()
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function note(text: string)
		label(list, "Empty", text, {
			Size = UDim2.new(1, 0, 0, 40),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = true,
		})
	end

	-- A list row: coloured dot, title, detail line, action buttons on the right.
	local function row(name: string, title: string, detail: string, dot: Color3?, actionWidth: number?): (Frame, Frame)
		local r = make("Frame", {
			Name = name,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, -4, 0, 46),
			ClipsDescendants = true,
		}, list)
		Theme.corner(r, Theme.Radius.S)
		local left = 10
		if dot then
			local d = make("Frame", { Name = "Dot", BackgroundColor3 = dot, Position = UDim2.new(0, 10, 0, 9), Size = UDim2.new(0, 8, 0, 8) }, r)
			Theme.corner(d, UDim.new(1, 0))
			left = 26
		end
		local w = actionWidth or 200
		label(r, "Title", title, {
			Position = UDim2.new(0, left, 0, 4),
			Size = UDim2.new(1, -(left + w + 16), 0, 18),
			Font = Theme.Font.Medium,
			TextSize = 13,
			TextColor3 = Theme.Colors.Text,
		})
		label(r, "Detail", detail, { Position = UDim2.new(0, left, 0, 24), Size = UDim2.new(1, -(left + w + 16), 0, 16), TextSize = 11 })
		local actions = make("Frame", {
			Name = "Actions",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 10),
			Size = UDim2.new(0, w, 0, 26),
		}, r)
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 4),
		}, actions)
		return r, actions
	end

	local render: () -> ()
	local refresh: (force: boolean?) -> ()

	-- -------------------------------------------------------------------
	-- Overview
	-- -------------------------------------------------------------------
	local function renderOverview()
		if not snapshot then
			return
		end
		local totals = snapshot.Totals or {}
		local stats = snapshot.Stats or {}
		local lockdown = (snapshot.GlobalState or {}).Lockdown or {}
		cards.Servers.Text = tostring(totals.Servers or 0)
		cards.Players.Text = ("%d / %d"):format(totals.Players or 0, totals.Capacity or 0)
		cards.Staff.Text = tostring(totals.Staff or 0)
		cards.Fps.Text = tostring(totals.AvgFps or 0)
		cards.Ping.Text = ("%d ms"):format(totals.AvgPing or 0)
		cards.Peak.Text = tostring(math.max(stats.PeakPlayers or 0, totals.Players or 0))
		cards.Lockdown.Text = if lockdown.On then "ON" else "Off"
		cards.Lockdown.TextColor3 = if lockdown.On then Theme.Colors.Error else Theme.Colors.Success
		local text = ("This server: %s"):format(tostring(snapshot.ServerId))
		if stats.Studio then
			text ..= "  (Studio session: teleports are disabled)"
		end
		if stats.RegistryError then
			text ..= "  -  server list unavailable: " .. tostring(stats.RegistryError)
		end
		if lockdown.On then
			text ..= ("  -  LOCKDOWN by %s%s"):format(tostring(lockdown.By), if lockdown.Reason then ": " .. lockdown.Reason else "")
		end
		setStatus(text, if lockdown.On or stats.RegistryError then Theme.Colors.Warning else nil)
	end

	-- -------------------------------------------------------------------
	-- Servers
	-- -------------------------------------------------------------------
	local function renderServers()
		local servers = if snapshot then snapshot.Servers or {} else {}
		local now = if snapshot then snapshot.Now else os.time()
		local q = serverSearch:lower()
		local shown = 0
		for _, s in ipairs(servers) do
			local staff = table.concat(s.Staff or {}, ", ")
			local flags = {}
			if s.IsThis then
				table.insert(flags, "this server")
			end
			if s.Locked then
				table.insert(flags, "locked")
			end
			if s.Maintenance then
				table.insert(flags, "maintenance")
			end
			if s.Private then
				table.insert(flags, "private")
			end
			if s.Studio then
				table.insert(flags, "studio")
			end
			local haystack = (s.Id .. " " .. staff .. " " .. table.concat(flags, " ") .. " " .. tostring(s.Health)):lower()
			if q ~= "" and not haystack:find(q, 1, true) then
				continue
			end
			shown += 1
			local title = ("%s    %d / %d players%s"):format(s.Short, s.Players or 0, s.MaxPlayers or 0, if #flags > 0 then "    [" .. table.concat(flags, ", ") .. "]" else "")
			local detail = ("%s  -  FPS %d  -  ping %d ms  -  %d MB  -  up %s  -  v%s  -  staff: %s"):format(
				tostring(s.Health),
				s.Fps or 0,
				s.Ping or 0,
				s.MemoryMb or 0,
				ago(s.StartedAt, now),
				tostring(s.Version or "?"),
				if staff ~= "" then staff else "none"
			)
			local r, actions = row("Server_" .. s.Short, title, detail, HEALTH_COLOR[s.Health] or Theme.Colors.TextSecondary, 150)
			local expanded = expandedServer == s.Id
			button(actions, "Details", if expanded then "Hide" else "Details", nil, 64).MouseButton1Click:Connect(function()
				if expandedServer == s.Id then
					expandedServer, expandedInfo = nil, nil
					render()
					return
				end
				expandedServer, expandedInfo = s.Id, nil
				render()
				task.spawn(function()
					local ok, info = pcall(function()
						return serverRemote:InvokeServer(s.Id)
					end)
					if expandedServer == s.Id then
						expandedInfo = if ok and type(info) == "table" then info else { PlayerList = {} }
						render()
					end
				end)
			end)
			if can("join") and not s.IsThis and not s.Private and not s.Studio then
				button(actions, "Join", "Join", Theme.Colors.Accent, 56).MouseButton1Click:Connect(function()
					send("joinserver " .. s.Id)
				end)
			end
			if expanded then
				r.Size = UDim2.new(1, -4, 0, 122)
				local idBox = textBox(r, "FullId", "", UDim2.new(1, -20, 0, 24))
				idBox.Position = UDim2.new(0, 10, 0, 46)
				idBox.Font = Theme.Font.Mono
				idBox.TextEditable = false
				idBox.Text = ("JobId: %s   place %s"):format(s.Id, tostring(s.Place))
				local names = {}
				if expandedInfo then
					for _, p in ipairs(expandedInfo.PlayerList or {}) do
						table.insert(names, p.Name)
					end
				end
				label(r, "Players", if not expandedInfo
					then "Loading players..."
					elseif #names == 0 then "No players in this server."
					else ("Players (%d): %s"):format(#names, table.concat(names, ", ")), {
					Position = UDim2.new(0, 10, 0, 74),
					Size = UDim2.new(1, -20, 0, 44),
					TextWrapped = true,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextTruncate = Enum.TextTruncate.AtEnd,
				})
			end
		end
		if shown == 0 then
			note(if not snapshot then "Loading..." elseif q ~= "" then "No servers match." else "No servers are registered yet.")
		end
	end

	-- -------------------------------------------------------------------
	-- Players (find + act)
	-- -------------------------------------------------------------------
	local function reasonSuffix(): string
		local r = reasonText:gsub("^%s+", ""):gsub("%s+$", "")
		return if r ~= "" then " " .. r else ""
	end

	local function playerActions(actions: Frame, entry: any, online: boolean, banned: boolean)
		local name = word(entry.Name)
		if online and can("join") and not entry.IsThis and not entry.Private then
			button(actions, "Follow", "Follow", Theme.Colors.Accent, 58).MouseButton1Click:Connect(function()
				send("follow " .. name)
			end)
		end
		if online and can("bring") and not entry.IsThis then
			button(actions, "Bring", "Bring", nil, 52).MouseButton1Click:Connect(function()
				send("gbring " .. name)
			end)
		end
		if online and can("kick") then
			button(actions, "Kick", "Kick", nil, 46).MouseButton1Click:Connect(function()
				send(("gkick %s%s"):format(name, reasonSuffix()))
			end)
		end
		if can("warn") then
			button(actions, "Warn", "Warn", Theme.Colors.Warning, 50).MouseButton1Click:Connect(function()
				if reasonSuffix() == "" then
					setStatus("Type a reason first (the Reason box above).", Theme.Colors.Error)
					return
				end
				send(("gwarn %s%s"):format(name, reasonSuffix()))
			end)
		end
		if can("ban") then
			if banned then
				button(actions, "Unban", "Unban", Theme.Colors.Success, 58).MouseButton1Click:Connect(function()
					send("gunban " .. name)
				end)
			else
				button(actions, "Ban", "Ban", Theme.Colors.Error, 46).MouseButton1Click:Connect(function()
					local d = word(durationText)
					send(("gban %s %s%s"):format(name, if d ~= "" then d else "perm", reasonSuffix()))
				end)
			end
		end
	end

	local function avatar(r: Frame, userId: number)
		local dot = r:FindFirstChild("Dot")
		if dot then
			dot:Destroy()
		end
		local img = make("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = Theme.Colors.Surface,
			Position = UDim2.new(0, 8, 0, 7),
			Size = UDim2.new(0, 32, 0, 32),
			Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(userId),
		}, r)
		Theme.corner(img, UDim.new(1, 0))
		for _, n in ipairs({ "Title", "Detail" }) do
			local l = r:FindFirstChild(n) :: TextLabel
			l.Position = UDim2.new(0, 48, 0, l.Position.Y.Offset)
			l.Size = UDim2.new(l.Size.X.Scale, l.Size.X.Offset - 22, 0, l.Size.Y.Offset)
		end
	end

	local function renderPlayers()
		if findBusy then
			note("Searching every server...")
			return
		end
		if not findResult then
			note("Search for a username or UserId. Players are found in any server; an exact name that is offline can still be warned, banned or unbanned.")
			return
		end
		local any = false
		for _, p in ipairs(findResult.Online or {}) do
			any = true
			local r, actions = row(
				"Player_" .. tostring(p.UserId),
				("%s  (%d)"):format(p.Name, p.UserId),
				("Online in server %s%s"):format(p.Short, if p.IsThis then " (this server)" elseif p.Private then " (private)" else ""),
				Theme.Colors.Success,
				290
			)
			avatar(r, p.UserId)
			playerActions(actions, p, true, false)
		end
		local off = findResult.Offline
		if off then
			any = true
			local detail = "Not in any server."
			if off.Banned then
				detail = ("Not in any server.  BANNED%s: %s"):format(
					if off.BanPermanent then " permanently" elseif off.BanExpiresAt then " until " .. os.date("%Y-%m-%d %H:%M", off.BanExpiresAt) else "",
					tostring(off.BanReason)
				)
			end
			local r, actions = row("Player_" .. tostring(off.UserId), ("%s  (%d)"):format(off.Name, off.UserId), detail, Theme.Colors.TextSecondary, 290)
			avatar(r, off.UserId)
			playerActions(actions, off, false, off.Banned == true)
		end
		if not any then
			note(findResult.Message or "Nobody by that name is online, and no Roblox user has exactly that name.")
		end
	end

	local function runFind()
		local q = findQuery:gsub("^%s+", ""):gsub("%s+$", "")
		if q == "" or findBusy then
			return
		end
		findBusy = true
		render()
		task.spawn(function()
			local ok, result = pcall(function()
				return findRemote:InvokeServer(q)
			end)
			findBusy = false
			findResult = if ok and type(result) == "table" then result else { Online = {}, Message = "Search failed - try again in a moment." }
			if currentTab == "Players" then
				render()
			end
		end)
	end

	-- -------------------------------------------------------------------
	-- Global actions
	-- -------------------------------------------------------------------
	local function actionCard(name: string, title: string, description: string, height: number): Frame
		local card = make("Frame", {
			Name = "Card_" .. name,
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			Size = UDim2.new(1, -4, 0, height),
		}, list)
		Theme.corner(card, Theme.Radius.S)
		label(card, "Title", title, {
			Position = UDim2.new(0, 10, 0, 6),
			Size = UDim2.new(1, -20, 0, 18),
			Font = Theme.Font.Bold,
			TextSize = 13,
			TextColor3 = Theme.Colors.Text,
		})
		label(card, "Description", description, { Position = UDim2.new(0, 10, 0, 24), Size = UDim2.new(1, -20, 0, 16), TextSize = 11 })
		return card
	end

	-- A text box that keeps its text across re-renders, plus buttons.
	local function inputRow(card: Frame, key: string, placeholder: string, boxScale: number, buttons: { { any } })
		local holder = make("Frame", {
			Name = "Row",
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 10, 0, 46),
			Size = UDim2.new(1, -20, 0, 28),
		}, card)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, holder)
		local box = textBox(holder, "Box_" .. key, placeholder, UDim2.new(boxScale, 0, 1, 0))
		box.Text = drafts[key] or ""
		box:GetPropertyChangedSignal("Text"):Connect(function()
			drafts[key] = box.Text
		end)
		for _, def in ipairs(buttons) do
			local b = button(holder, def[1], def[2], def[3], def[4])
			b.Size = UDim2.new(0, def[4], 1, 0)
			b.MouseButton1Click:Connect(function()
				def[5](box)
			end)
		end
		return box
	end

	local function renderGlobal()
		local lockdown = if snapshot then (snapshot.GlobalState or {}).Lockdown or {} else {}
		local shown = false
		if can("announce") then
			shown = true
			local card = actionCard("Announce", "Global announcement", "Banner on every player's screen in every server, or a notification for staff only.", 82)
			inputRow(card, "announce", "Message", 0.6, {
				{ "Announce", "Announce to all", Theme.Colors.Accent, 120, function(box: TextBox)
					if box.Text ~= "" then
						send("gannounce " .. box.Text)
						box.Text = ""
					end
				end },
				{ "Notify", "Notify staff", nil, 100, function(box: TextBox)
					if box.Text ~= "" then
						send("gnotify " .. box.Text)
						box.Text = ""
					end
				end },
			})
		end
		if can("lockdown") then
			shown = true
			local card = actionCard(
				"Lockdown",
				if lockdown.On then "Global lockdown is ON" else "Global lockdown",
				if lockdown.On
					then ("Enabled by %s. No new players can join any server, including servers that start later."):format(tostring(lockdown.By))
					else "Locks every server (and servers that start later) to new players. Staff with server.bypass can still join.",
				82
			)
			if lockdown.On then
				(card:FindFirstChild("Title") :: TextLabel).TextColor3 = Theme.Colors.Error
			end
			inputRow(card, "lockdown", "Reason (optional)", 0.6, {
				if lockdown.On
					then { "LockdownOff", "Lift lockdown", Theme.Colors.Success, 130, function()
						send("lockdown off")
					end }
					else { "LockdownOn", "Enable lockdown", Theme.Colors.Error, 130, function(box: TextBox)
						send("lockdown on " .. box.Text)
					end },
			})
		end
		if can("migrate") then
			shown = true
			local card = actionCard("Update", "Update countdown and migration", "Counts down on every server, then moves all players to fresh servers running the latest version.", 82)
			local secondsBox: TextBox
			local messageBox = inputRow(card, "update", "Message (optional), e.g. New update", 0.42, {
				{ "UpdateAll", "All servers", Theme.Colors.Warning, 96, function(box: TextBox)
					send(("gupdate %s %s"):format(if tonumber(secondsBox.Text) then secondsBox.Text else "30", box.Text))
				end },
				{ "UpdateThis", "This server", nil, 96, function(box: TextBox)
					send(("migrateserver %s %s"):format(if tonumber(secondsBox.Text) then secondsBox.Text else "30", box.Text))
				end },
			})
			secondsBox = textBox(messageBox.Parent :: Instance, "Box_seconds", "Seconds", UDim2.new(0, 70, 1, 0))
			secondsBox.LayoutOrder = messageBox.LayoutOrder - 1
			secondsBox.Text = drafts.seconds or "30"
			secondsBox:GetPropertyChangedSignal("Text"):Connect(function()
				drafts.seconds = secondsBox.Text
			end)
		end
		if can("shutdown") then
			shown = true
			local card = actionCard("Shutdown", "Global shutdown", "Kicks every player from every server with a message. Asks for confirmation.", 82)
			inputRow(card, "shutdown", "Message shown to players (optional)", 0.6, {
				{ "Shutdown", "Shut down all servers", Theme.Colors.Error, 170, function(box: TextBox)
					send("gshutdown " .. box.Text)
				end },
			})
		end
		if can("execute") then
			shown = true
			local card = actionCard("Command", "Run a command on every server", "weather, daynight, fog, lightingpreset, timefreeze, slowmode, announce, countdown, hint, message, lockserver, maintenancemode", 82)
			local box = inputRow(card, "command", "e.g. weather foggy", 0.6, {
				{ "RunGlobal", "Run everywhere", Theme.Colors.Accent, 130, function(b: TextBox)
					if b.Text ~= "" then
						send("global " .. b.Text)
					end
				end },
			})
			box.Font = Theme.Font.Mono
		end
		if not shown then
			note("Your rank has no global actions (crossserver.announce / lockdown / migrate / shutdown / execute).")
		end
	end

	-- -------------------------------------------------------------------
	-- Staff chat
	-- -------------------------------------------------------------------
	local function addChat(entry: any): boolean
		if type(entry) ~= "table" or type(entry.Id) ~= "string" or chatSeen[entry.Id] then
			return false
		end
		chatSeen[entry.Id] = true
		table.insert(chatLog, entry)
		table.sort(chatLog, function(a, b)
			return a.Id < b.Id
		end)
		while #chatLog > 80 do
			local old = table.remove(chatLog, 1)
			if old then
				chatSeen[old.Id] = nil
			end
		end
		return true
	end

	local function renderChat()
		if not can("staffchat") then
			note("Your rank can't use staff chat (crossserver.staffchat).")
			return
		end
		if #chatLog == 0 then
			note("No messages yet. Staff in every server see what you send here.")
			return
		end
		for i, m in ipairs(chatLog) do
			local line = make("TextLabel", {
				Name = "Chat_" .. i,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -8, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Font = Theme.Font.Regular,
				TextSize = 13,
				TextColor3 = Theme.Colors.Text,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
				RichText = false,
				Text = ("[%s]  %s%s @%s:  %s"):format(
					os.date("%H:%M", m.At or os.time()),
					tostring(m.Name),
					if m.Rank then " (" .. tostring(m.Rank) .. ")" else "",
					tostring(m.Server),
					tostring(m.Text)
				),
			}, list)
			line.LayoutOrder = i
		end
		task.defer(function()
			list.CanvasPosition = Vector2.new(0, math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteWindowSize.Y))
		end)
	end

	-- -------------------------------------------------------------------
	-- Operations + history
	-- -------------------------------------------------------------------
	local function renderOperations()
		if #operations == 0 then
			note("Nothing sent from this server yet. Global actions appear here with each server's acknowledgement.")
			return
		end
		local now = if snapshot then snapshot.Now else os.time()
		for _, op in ipairs(operations) do
			local expanded = expandedOp == op.Id
			local r, actions = row(
				"Op_" .. op.Id,
				("%s    [%s]"):format(tostring(op.Label), tostring(op.Status)),
				("%s ago  -  by %s  -  %d / %d server(s) answered  -  %d affected%s"):format(
					ago(op.StartedAt, now),
					tostring(op.ActorName or "system"),
					#(op.Acks or {}),
					#(op.Expected or {}),
					op.Affected or 0,
					if op.Error then "  -  " .. tostring(op.Error) else ""
				),
				STATUS_COLOR[op.Status] or Theme.Colors.TextSecondary,
				80
			)
			button(actions, "Acks", if expanded then "Hide" else "Servers", nil, 70).MouseButton1Click:Connect(function()
				expandedOp = if expanded then nil else op.Id
				render()
			end)
			if expanded then
				local lines = {}
				local answered: { [string]: boolean } = {}
				for _, ack in ipairs(op.Acks or {}) do
					answered[ack.Server] = true
					table.insert(lines, ("%s   %s   %d affected%s"):format(
						tostring(ack.Server):sub(1, 15),
						if ack.Ok then "ok" else "refused",
						ack.Count or 0,
						if ack.Message then "   " .. tostring(ack.Message) else ""
					))
				end
				for _, id in ipairs(op.Expected or {}) do
					if not answered[id] then
						table.insert(lines, ("%s   no answer%s"):format(tostring(id):sub(1, 15), if op.Status == "pending" then " yet" else ""))
					end
				end
				r.Size = UDim2.new(1, -4, 0, 50 + #lines * 15)
				label(r, "AckList", table.concat(lines, "\n"), {
					Position = UDim2.new(0, 26, 0, 44),
					Size = UDim2.new(1, -36, 0, #lines * 15),
					Font = Theme.Font.Mono,
					TextSize = 11,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextTruncate = Enum.TextTruncate.None,
				})
			end
		end
	end

	local function renderHistory()
		if #history == 0 then
			note("No global actions recorded yet.")
			return
		end
		local now = if snapshot then snapshot.Now else os.time()
		for i, h in ipairs(history) do
			if i > 100 then
				break
			end
			row(
				"History_" .. i,
				("%s    [%s]"):format(tostring(h.Label or h.Kind), tostring(h.Status)),
				("%s ago  -  by %s  -  from server %s  -  %d / %d server(s)  -  %d affected"):format(
					ago(h.At, now),
					tostring(h.Actor),
					tostring(h.Origin),
					h.Acked or 0,
					h.Servers or 0,
					h.Affected or 0
				),
				STATUS_COLOR[h.Status] or Theme.Colors.TextSecondary,
				10
			)
		end
	end

	-- -------------------------------------------------------------------
	-- Controls per tab
	-- -------------------------------------------------------------------
	local function buildControls()
		for _, child in ipairs(controls:GetChildren()) do
			child:Destroy()
		end
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, controls)
		local function fill(b: TextButton, width: number)
			b.Size = UDim2.new(0, width, 1, 0)
		end
		if currentTab == "Servers" then
			local box = textBox(controls, "ServerSearch", "Search servers by id, staff, status...", UDim2.new(0.5, 0, 1, 0))
			box.Text = serverSearch
			box:GetPropertyChangedSignal("Text"):Connect(function()
				serverSearch = box.Text
				render()
			end)
			local r = button(controls, "Refresh", "Refresh", nil, 80)
			fill(r, 80)
			r.MouseButton1Click:Connect(function()
				refresh(true)
			end)
			local p = button(controls, "Ping", "Ping servers", nil, 100)
			fill(p, 100)
			p.MouseButton1Click:Connect(function()
				send("xping")
			end)
		elseif currentTab == "Players" then
			local box = textBox(controls, "FindBox", "Username or UserId", UDim2.new(0.26, 0, 1, 0))
			box.Text = findQuery
			box:GetPropertyChangedSignal("Text"):Connect(function()
				findQuery = box.Text
			end)
			box.FocusLost:Connect(function(enter: boolean)
				if enter then
					runFind()
				end
			end)
			local f = button(controls, "Find", "Find", Theme.Colors.Accent, 64)
			fill(f, 64)
			f.MouseButton1Click:Connect(runFind)
			local reason = textBox(controls, "ReasonBox", "Reason for kick / warn / ban", UDim2.new(0.36, 0, 1, 0))
			reason.Text = reasonText
			reason:GetPropertyChangedSignal("Text"):Connect(function()
				reasonText = reason.Text
			end)
			local dur = textBox(controls, "DurationBox", "Ban length", UDim2.new(0, 90, 1, 0))
			dur.Text = durationText
			dur:GetPropertyChangedSignal("Text"):Connect(function()
				durationText = dur.Text
			end)
		elseif currentTab == "Staff Chat" then
			local box = textBox(controls, "ChatBox", "Message every staff member in every server...", UDim2.new(0.78, 0, 1, 0))
			box.Text = drafts.chat or ""
			box:GetPropertyChangedSignal("Text"):Connect(function()
				drafts.chat = box.Text
			end)
			local function sendChat()
				local text = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
				if text ~= "" then
					send("staffchat " .. text)
					box.Text = ""
				end
			end
			box.FocusLost:Connect(function(enter: boolean)
				if enter then
					sendChat()
					task.defer(function()
						box:CaptureFocus()
					end)
				end
			end)
			local s = button(controls, "SendChat", "Send", Theme.Colors.Accent, 70)
			fill(s, 70)
			s.MouseButton1Click:Connect(sendChat)
		elseif currentTab == "Operations" or currentTab == "History" then
			local r = button(controls, "Refresh", "Refresh", nil, 80)
			fill(r, 80)
			r.MouseButton1Click:Connect(function()
				refresh(true)
			end)
			label(controls, "Hint", if currentTab == "Operations"
				then "Messages this server sent, and which servers acknowledged them."
				else "Global actions from every server (kept across restarts).", { Size = UDim2.new(0.8, 0, 1, 0) })
		else
			label(controls, "Hint", "Actions here reach every running server. Risky ones ask for confirmation.", { Size = UDim2.new(1, 0, 1, 0) })
		end
	end

	render = function()
		local scroll = list.CanvasPosition
		clearList()
		renderOverview()
		if currentTab == "Servers" then
			renderServers()
		elseif currentTab == "Players" then
			renderPlayers()
		elseif currentTab == "Global" then
			renderGlobal()
		elseif currentTab == "Staff Chat" then
			renderChat()
		elseif currentTab == "Operations" then
			renderOperations()
		elseif currentTab == "History" then
			renderHistory()
		end
		if currentTab ~= "Staff Chat" then
			list.CanvasPosition = scroll
		end
		local chatTab = tabButtons["Staff Chat"]
		if chatTab then
			chatTab.Text = if unreadChat > 0 then ("Staff Chat (%d)"):format(unreadChat) else "Staff Chat"
		end
	end

	local busy, queued = false, false
	refresh = function(force: boolean?)
		if busy then
			queued = true
			return
		end
		busy = true
		task.spawn(function()
			local ok, result = pcall(function()
				return snapshotRemote:InvokeServer({ Refresh = force == true, Chat = true, History = true })
			end)
			busy = false
			if ok and type(result) == "table" then
				snapshot = result
				operations = result.Operations or operations
				history = result.History or history
				for _, m in ipairs(result.Chat or {}) do
					addChat(m)
				end
				-- Typing in a global-action box must not be interrupted by the
				-- periodic refresh re-creating it.
				if currentTab == "Global" and list:FindFirstChildWhichIsA("Frame") then
					renderOverview()
				else
					render()
				end
			elseif not snapshot then
				setStatus("Cross-server data is unavailable (your rank needs crossserver.view).", Theme.Colors.Error)
			end
			if queued then
				queued = false
				refresh()
			end
		end)
	end

	local function selectTab(tab: string)
		currentTab = tab
		if tab == "Staff Chat" then
			unreadChat = 0
		end
		for name, b in pairs(tabButtons) do
			b.BackgroundColor3 = if name == tab then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
		end
		buildControls()
		render()
	end

	for _, tab in ipairs(TABS) do
		local b = button(tabBar, "Tab_" .. tab:gsub("%s", ""), tab, nil, if tab == "Staff Chat" then 110 else 92)
		tabButtons[tab] = b
		b.MouseButton1Click:Connect(function()
			selectTab(tab)
		end)
	end

	-- Live updates from the server.
	eventRemote.OnClientEvent:Connect(function(kind: any, data: any)
		if type(data) ~= "table" then
			return
		end
		if kind == "op" then
			local found = false
			for i, op in ipairs(operations) do
				if op.Id == data.Id then
					operations[i] = data
					found = true
				end
			end
			if not found then
				table.insert(operations, 1, data)
			end
			if container.Visible and currentTab == "Operations" then
				render()
			end
		elseif kind == "chat" then
			if addChat(data) then
				if container.Visible and currentTab == "Staff Chat" then
					render()
				else
					unreadChat += 1
					if notificationCenter and notificationCenter.Push then
						notificationCenter.Push(true, ("Staff chat - %s @%s: %s"):format(tostring(data.Name), tostring(data.Server), tostring(data.Text)))
					end
					local chatTab = tabButtons["Staff Chat"]
					if chatTab then
						chatTab.Text = ("Staff Chat (%d)"):format(unreadChat)
					end
				end
			end
		elseif kind == "notify" then
			if notificationCenter and notificationCenter.Push then
				notificationCenter.Push(data.Level ~= "warning", ("%s @%s: %s"):format(tostring(data.From), tostring(data.Server), tostring(data.Message)))
			end
		elseif kind == "state" then
			if snapshot then
				snapshot.GlobalState = data
				if container.Visible then
					render()
				end
			end
		elseif kind == "history" then
			table.insert(history, 1, data)
			if container.Visible and currentTab == "History" then
				render()
			end
		end
	end)

	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			refresh()
		end
	end)
	task.spawn(function()
		while container.Parent do
			task.wait(8)
			if container.Visible then
				refresh()
			end
		end
	end)

	selectTab("Servers")
	refresh()
end

return CrossServerPage
