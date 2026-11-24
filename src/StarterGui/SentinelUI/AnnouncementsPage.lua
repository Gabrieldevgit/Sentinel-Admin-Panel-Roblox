--!strict
--[[
	AnnouncementsPage.lua - the Announcements section (nav tab
	"Announcements"), four pages:

		AnnounceHistory   every announcement (newest first): author avatar,
		                  scope, time, title, text, recipients. Filter chips
		                  + search. Resend / Preview per row.
		AnnounceServer    compose for everyone in this server      (;announce)
		AnnounceGlobal    compose for every server                 (;gannounce)
		AnnouncePlayers   compose for chosen players or staff only (;tannounce / ;sannounce)

	A composer has: message (with a character counter and saved template
	chips - M-panel gaps; ;btemplate saves / removes, needs server.announce),
	optional title, style (Banner / Full screen),
	time (5 / 8 / 15 / 30 s), colour swatches, a live command line,
	Preview (shows the real banner on your screen only) and Send. Sending
	is a normal command through ExecuteCommandRemote, so permissions,
	text filtering, logging and history all happen on the server.

	Reads GetAnnouncementsRemote(limit) -> { History, Players, CanServer,
	CanGlobal, Colors }.

	Stable instance names (Studio MCP tests):
		<page>.Body.Form.{Message, Title, Style.Chip_<banner|full>,
		  Time.Chip_<n>, Color.Swatch_<name>, Command, Buttons.{Preview,Send},
		  Status}
		AnnouncePlayers.Body.Form.Picker.{Tools.{All,None,Staff}, List.Player_<name>}
		AnnounceHistory.Body.{Top.{Search, Filter_<scope>, Refresh}, List.Row_<id>.{Resend,Preview}}

	Public API:
		AnnouncementsPage.Build(containers, banner, openPage)
		  containers = { History, Server, Global, Players } (Shell pages)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme"))

local AnnouncementsPage = {}

local COLOR_ORDER = { "accent", "gold", "red", "green", "blue", "purple", "orange", "pink" }
local COLOR_HEX = {
	accent = "",
	gold = "FFC94D",
	red = "EB5757",
	green = "57D682",
	blue = "409CFF",
	purple = "A78BFA",
	orange = "FF8A3D",
	pink = "F472B6",
}
local TIMES = { 5, 8, 15, 30 }
local MAX_MESSAGE = 400 -- AnnouncementService.MAX_TEXT
local SCOPE_LABEL = { server = "Server", global = "Global", players = "Players", staff = "Staff" }

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

local function caption(parent: Instance, value: string)
	label(parent, "Caption_" .. value:gsub("%W", ""), value:upper(), {
		Font = Theme.Font.Bold,
		TextSize = 11,
		TextColor3 = Theme.Colors.TextSecondary,
		Size = UDim2.new(1, 0, 0, 14),
	})
end

local function button(parent: Instance, name: string, value: string, filled: boolean?, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(width or 96, 32),
		BackgroundColor3 = if filled then Theme.Colors.Accent else Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = Theme.Font.Bold,
		TextSize = 13,
		TextColor3 = if filled then Color3.new(1, 1, 1) else Theme.Colors.Text,
		Text = value,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	return b
end

local function chipButton(parent: Instance, name: string, value: string): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Font = Theme.Font.Medium,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		Text = value,
	}, parent)
	Theme.corner(b, Theme.Radius.Pill)
	make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, b)
	return b
end

local function setChip(b: TextButton, on: boolean)
	b.BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
	b.TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.Text
end

local function row(parent: Instance, name: string, height: number?): Frame
	local f = make("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or 30),
		AutomaticSize = if height then Enum.AutomaticSize.None else Enum.AutomaticSize.Y,
	}, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, f)
	return f
end

local function textBox(parent: Instance, name: string, placeholder: string, height: number, multiLine: boolean): TextBox
	local b = make("TextBox", {
		Name = name,
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		MultiLine = multiLine,
		TextWrapped = multiLine,
		Font = Theme.Font.Regular,
		TextSize = 14,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if multiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		ClipsDescendants = true,
		Text = "",
	}, parent) :: TextBox
	Theme.corner(b, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, if multiLine then 8 else 0), PaddingBottom = UDim.new(0, if multiLine then 8 else 0) }, b)
	return b
end

local function scroller(container: Frame, top: number): ScrollingFrame
	local s = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, top),
		Size = UDim2.new(1, 0, 1, -top),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, container)
	make("UIListLayout", { Padding = UDim.new(0, 10) }, s)
	make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, s)
	return s
end

local function header(container: Frame, title: string, subtitle: string)
	label(container, "Header", title, { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", subtitle, { Position = UDim2.new(0, 0, 0, 28), TextColor3 = Theme.Colors.TextSecondary })
end

local function clean(value: string): string
	return (value:gsub("[\r\n\t]+", " "):gsub("&&", "&"):gsub("%s+", " "):match("^%s*(.-)%s*$")) :: string
end

local function ago(t: number): string
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

local function swatchColor(name: string): Color3
	local hex = COLOR_HEX[name]
	if hex and hex ~= "" then
		return Color3.fromHex(hex)
	end
	return Theme.Colors.Accent
end

function AnnouncementsPage.Build(containers: { [string]: Frame }, banner: any, openPage: ((string) -> ())?)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local dataRemote = SentinelShared:WaitForChild("GetAnnouncementsRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?

	local snapshot: any = { History = {}, Players = {}, CanServer = true, CanGlobal = false }
	local listeners: { () -> () } = {}
	local function refresh()
		if not dataRemote then
			return
		end
		local ok, data = pcall(function()
			return (dataRemote :: RemoteFunction):InvokeServer(60)
		end)
		if ok and type(data) == "table" then
			snapshot = data
			for _, fn in ipairs(listeners) do
				task.spawn(fn)
			end
		end
	end

	-- Result of the last Send goes to the composer that sent it.
	local awaiting: TextLabel? = nil
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function(results: any)
			local status = awaiting
			if not status or type(results) ~= "table" then
				return
			end
			for _, r in ipairs(results) do
				if type(r) == "table" and r.Message and r.Message ~= "" and not r.NeedsConfirmation then
					awaiting = nil
					status.Text = tostring(r.Message):sub(1, 200)
					status.TextColor3 = if r.Success then Theme.Colors.Success elseif r.Pending then Theme.Colors.Warning else Theme.Colors.Error
					if r.Success then
						task.delay(1, refresh)
					end
					break
				end
			end
		end)
	end

	local composers: { [string]: any } = {}

	-- ======================================================================
	-- Composer
	-- ======================================================================
	local function composer(container: Frame, scope: string, title: string, subtitle: string)
		header(container, title, subtitle)
		local body = scroller(container, 52)
		local form = make("Frame", { Name = "Form", BackgroundColor3 = Theme.Colors.Surface, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
		Theme.corner(form, Theme.Radius.M)
		make("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, form)
		make("UIListLayout", { Padding = UDim.new(0, 8) }, form)

		local state = { Style = "banner", Time = 8, Color = "accent", Selected = {} :: { [string]: boolean }, StaffOnly = false }

		-- Players scope: who receives it.
		local pickerRefresh: (() -> ())? = nil
		local countLabel: TextLabel? = nil
		if scope == "players" then
			caption(form, "Recipients")
			local picker = make("Frame", { Name = "Picker", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, form)
			make("UIListLayout", { Padding = UDim.new(0, 6) }, picker)
			local tools = row(picker, "Tools", 30)
			local allButton = chipButton(tools, "All", "Select all")
			local noneButton = chipButton(tools, "None", "Clear")
			local staffButton = chipButton(tools, "Staff", "Staff only")
			countLabel = label(tools, "Count", "", { Size = UDim2.fromOffset(160, 30), TextColor3 = Theme.Colors.TextSecondary })
			local listFrame = make("Frame", { Name = "List", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, picker)
			make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6) }, listFrame)

			local function updateCount()
				local n = 0
				for _ in pairs(state.Selected) do
					n += 1
				end
				if countLabel then
					countLabel.Text = if state.StaffOnly then "All staff online" else ("%d selected"):format(n)
				end
				setChip(staffButton, state.StaffOnly)
				listFrame.Visible = not state.StaffOnly
			end

			pickerRefresh = function()
				for _, c in ipairs(listFrame:GetChildren()) do
					if c:IsA("GuiObject") then
						c:Destroy()
					end
				end
				local online = {}
				for _, p in ipairs(snapshot.Players or {}) do
					online[p.Name] = true
					local item = make("TextButton", {
						Name = "Player_" .. p.Name,
						Size = UDim2.fromOffset(0, 34),
						AutomaticSize = Enum.AutomaticSize.X,
						BackgroundColor3 = Theme.Colors.SurfaceRaised,
						AutoButtonColor = false,
						BorderSizePixel = 0,
						Text = "",
					}, listFrame)
					Theme.corner(item, Theme.Radius.Pill)
					make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 12) }, item)
					make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) }, item)
					local face = make("ImageLabel", { Name = "Avatar", Size = UDim2.fromOffset(26, 26), BackgroundColor3 = Theme.Colors.Surface, Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(p.UserId) }, item)
					Theme.corner(face, Theme.Radius.Pill)
					make("TextLabel", {
						Name = "Name",
						BackgroundTransparency = 1,
						Size = UDim2.fromOffset(0, 34),
						AutomaticSize = Enum.AutomaticSize.X,
						Font = Theme.Font.Medium,
						TextSize = 13,
						TextColor3 = Theme.Colors.Text,
						Text = p.DisplayName .. (if p.Staff then "  - staff" else ""),
					}, item)
					local function paint()
						local on = state.Selected[p.Name] == true
						item.BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
					end
					paint()
					item.MouseButton1Click:Connect(function()
						state.Selected[p.Name] = if state.Selected[p.Name] then nil else true
						paint()
						updateCount()
					end)
				end
				for name in pairs(state.Selected) do
					if not online[name] then
						state.Selected[name] = nil
					end
				end
				updateCount()
			end
			allButton.MouseButton1Click:Connect(function()
				state.StaffOnly = false
				for _, p in ipairs(snapshot.Players or {}) do
					state.Selected[p.Name] = true
				end
				if pickerRefresh then
					pickerRefresh()
				end
			end)
			noneButton.MouseButton1Click:Connect(function()
				state.StaffOnly = false
				table.clear(state.Selected)
				if pickerRefresh then
					pickerRefresh()
				end
			end)
			staffButton.MouseButton1Click:Connect(function()
				state.StaffOnly = not state.StaffOnly
				updateCount()
			end)
		end

		caption(form, "Message")
		local message = textBox(form, "Message", "What do you want to announce?", 84, true)
		-- M-panel gaps: character counter + saved templates.
		local counter = label(form, "Counter", ("0 / %d"):format(MAX_MESSAGE), { TextSize = 11, TextColor3 = Theme.Colors.TextSecondary, TextXAlignment = Enum.TextXAlignment.Right })
		local function updateCounter()
			local n = utf8.len(message.Text) or #message.Text
			counter.Text = ("%d / %d"):format(n, MAX_MESSAGE)
			counter.TextColor3 = if n > MAX_MESSAGE
				then Theme.Colors.Error
				elseif n > MAX_MESSAGE * 0.9 then Theme.Colors.Warning
				else Theme.Colors.TextSecondary
		end
		message:GetPropertyChangedSignal("Text"):Connect(updateCounter)
		caption(form, "Templates")
		local templateRow = row(form, "Templates")
		local saveRow = row(form, "SaveTemplate")
		local templateName = textBox(saveRow, "TemplateName", "Template name", 30, false)
		templateName.Size = UDim2.fromOffset(150, 30)
		local saveTemplate = chipButton(saveRow, "Save", "Save message as template")
		local removeTemplate = chipButton(saveRow, "Remove", "Remove template")
		local function renderTemplates()
			for _, c in ipairs(templateRow:GetChildren()) do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			local list = if type(snapshot.Templates) == "table" then snapshot.Templates else {}
			for _, t in ipairs(list) do
				local b = chipButton(templateRow, "Template_" .. tostring(t.Name), tostring(t.Name))
				b.MouseButton1Click:Connect(function()
					message.Text = tostring(t.Text)
					templateName.Text = tostring(t.Name)
				end)
			end
			if #list == 0 then
				label(templateRow, "Empty", "No templates yet.", { Size = UDim2.fromOffset(160, 30), TextColor3 = Theme.Colors.TextSecondary })
			end
			saveRow.Visible = snapshot.CanEditTemplates == true
		end
		local function templateCommand(cmd: string)
			if executeRemote then
				executeRemote:FireServer(cmd)
				task.delay(0.8, refresh)
			end
		end
		saveTemplate.MouseButton1Click:Connect(function()
			local name = templateName.Text:gsub("[^%w_]", "")
			local text = clean(message.Text)
			if name == "" or text == "" then
				return
			end
			templateCommand(("btemplate add %s %s"):format(name:sub(1, 20), text:sub(1, 200)))
		end)
		removeTemplate.MouseButton1Click:Connect(function()
			local name = templateName.Text:gsub("[^%w_]", "")
			if name ~= "" then
				templateCommand("btemplate remove " .. name)
			end
		end)
		caption(form, "Title (optional)")
		local titleBox = textBox(form, "Title", "e.g. Double XP", 32, false)

		caption(form, "Style")
		local styleRow = row(form, "Style", 30)
		local styleChips: { [string]: TextButton } = {}
		for _, spec in ipairs({ { "banner", "Banner" }, { "full", "Full screen" } }) do
			styleChips[spec[1]] = chipButton(styleRow, "Chip_" .. spec[1], spec[2])
		end
		caption(form, "Time on screen")
		local timeRow = row(form, "Time", 30)
		local timeChips: { [number]: TextButton } = {}
		for _, n in ipairs(TIMES) do
			timeChips[n] = chipButton(timeRow, "Chip_" .. n, n .. " s")
		end
		caption(form, "Colour")
		local colorRow = row(form, "Color", 30)
		local swatches: { [string]: TextButton } = {}
		for _, name in ipairs(COLOR_ORDER) do
			local sw = make("TextButton", {
				Name = "Swatch_" .. name,
				Size = UDim2.fromOffset(28, 28),
				BackgroundColor3 = swatchColor(name),
				AutoButtonColor = false,
				BorderSizePixel = 0,
				Text = "",
			}, colorRow)
			Theme.corner(sw, Theme.Radius.Pill)
			make("UIStroke", { Name = "Ring", Color = Theme.Colors.Text, Thickness = 2, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, sw)
			swatches[name] = sw
		end

		local commandLine = label(form, "Command", "", {
			Font = Theme.Font.Mono,
			TextSize = 12,
			TextColor3 = Theme.Colors.TextSecondary,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.None,
			AutomaticSize = Enum.AutomaticSize.Y,
		})
		local buttons = row(form, "Buttons", 34)
		local previewButton = button(buttons, "Preview", "Preview", false, 100)
		local sendButton = button(buttons, "Send", if scope == "global" then "Send to all servers" else "Send", true, if scope == "global" then 160 else 110)
		local status = label(form, "Status", "", { TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y })

		local function optionWords(): { string }
			local words = {}
			if state.Style ~= "banner" then
				table.insert(words, "style=" .. state.Style)
			end
			if state.Time ~= 8 then
				table.insert(words, "time=" .. state.Time)
			end
			if state.Color ~= "accent" then
				table.insert(words, "color=" .. state.Color)
			end
			local t = clean(titleBox.Text):gsub("%s", "_"):sub(1, 40)
			if t ~= "" then
				table.insert(words, "title=" .. t)
			end
			return words
		end

		local function buildCommand(): (string?, string?)
			local text = clean(message.Text)
			if text == "" then
				return nil, "Type a message first."
			end
			local options = table.concat(optionWords(), " ")
			local prefix
			if scope == "server" then
				prefix = "announce"
			elseif scope == "global" then
				prefix = "gannounce"
			elseif state.StaffOnly then
				prefix = "sannounce"
			else
				local names = {}
				for name in pairs(state.Selected) do
					table.insert(names, name)
				end
				table.sort(names)
				if #names == 0 then
					return nil, "Pick at least one player (or Staff only)."
				end
				prefix = "tannounce " .. table.concat(names, ",")
			end
			return prefix .. (if options ~= "" then " " .. options else "") .. " " .. text, nil
		end

		local function paint()
			for id, b in pairs(styleChips) do
				setChip(b, id == state.Style)
			end
			for n, b in pairs(timeChips) do
				setChip(b, n == state.Time)
			end
			for name, sw in pairs(swatches) do
				local ring = sw:FindFirstChild("Ring") :: UIStroke?
				if ring then
					ring.Transparency = if name == state.Color then 0 else 1
				end
			end
			local cmd, why = buildCommand()
			commandLine.Text = if cmd then ";" .. cmd else ("; " .. (why or ""))
		end
		for id, b in pairs(styleChips) do
			b.MouseButton1Click:Connect(function()
				state.Style = id
				paint()
			end)
		end
		for n, b in pairs(timeChips) do
			b.MouseButton1Click:Connect(function()
				state.Time = n
				paint()
			end)
		end
		for name, sw in pairs(swatches) do
			sw.MouseButton1Click:Connect(function()
				state.Color = name
				paint()
			end)
		end
		message:GetPropertyChangedSignal("Text"):Connect(paint)
		titleBox:GetPropertyChangedSignal("Text"):Connect(paint)
		paint()

		previewButton.MouseButton1Click:Connect(function()
			local text = clean(message.Text)
			if text == "" then
				status.Text = "Type a message first."
				status.TextColor3 = Theme.Colors.Warning
				return
			end
			local me = Players.LocalPlayer
			local hex = COLOR_HEX[state.Color]
			if banner then
				banner.Show({
					Text = text,
					Title = if clean(titleBox.Text) ~= "" then clean(titleBox.Text) else nil,
					Style = state.Style,
					Duration = state.Time,
					Color = if hex and hex ~= "" then Color3.fromHex(hex) else nil,
					Scope = if scope == "players" then (if state.StaffOnly then "staff" else "players") else scope,
					Author = { UserId = me.UserId, Name = me.Name, DisplayName = me.DisplayName },
				})
			end
			status.Text = "Preview shown on your screen only."
			status.TextColor3 = Theme.Colors.TextSecondary
		end)

		sendButton.MouseButton1Click:Connect(function()
			if scope == "global" and not snapshot.CanGlobal then
				status.Text = "You need crossserver.announce to send global announcements."
				status.TextColor3 = Theme.Colors.Error
				return
			end
			local cmd, why = buildCommand()
			if not cmd then
				status.Text = why or ""
				status.TextColor3 = Theme.Colors.Warning
				return
			end
			if executeRemote then
				awaiting = status
				status.Text = "Sending..."
				status.TextColor3 = Theme.Colors.TextSecondary
				executeRemote:FireServer(cmd)
				message.Text = ""
			end
		end)

		local api = {
			Fill = function(record: any)
				message.Text = tostring(record.Text or "")
				titleBox.Text = tostring(record.Title or "")
				state.Style = if record.Style == "full" then "full" else "banner"
				state.Time = if table.find(TIMES, record.Duration) then record.Duration else 8
				state.Color = "accent"
				for name, hex in pairs(COLOR_HEX) do
					if hex ~= "" and hex == record.Color then
						state.Color = name
					end
				end
				paint()
				status.Text = "Loaded from history - edit it, then Send."
				status.TextColor3 = Theme.Colors.TextSecondary
			end,
		}
		renderTemplates()
		table.insert(listeners, function()
			renderTemplates()
			if pickerRefresh then
				pickerRefresh()
			end
			if scope == "global" then
				sendButton.AutoButtonColor = snapshot.CanGlobal == true
				sendButton.BackgroundColor3 = if snapshot.CanGlobal then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
			end
		end)
		container:GetPropertyChangedSignal("Visible"):Connect(function()
			if container.Visible then
				task.spawn(refresh)
			end
		end)
		return api
	end

	composers.server = composer(containers.Server, "server", "Current server", "Everyone in this server sees it, with your name and avatar.")
	composers.global = composer(containers.Global, "global", "Global", "Every server of this game shows it at the same time.")
	composers.players = composer(containers.Players, "players", "Some players", "Only the players you pick - or every staff member online.")

	-- ======================================================================
	-- History
	-- ======================================================================
	local historyPage = containers.History
	header(historyPage, "Announcement history", "Newest first. Resend loads one into the composer.")
	local body = make("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 1, -52) }, historyPage)
	local top = row(body, "Top", 30)
	top.Size = UDim2.new(1, 0, 0, 30)
	local search = textBox(top, "Search", "Search text or author", 30, false)
	search.Size = UDim2.new(0, 200, 0, 30)
	local filter = "all"
	local filterChips: { [string]: TextButton } = {}
	for _, spec in ipairs({ { "all", "All" }, { "server", "Server" }, { "global", "Global" }, { "players", "Players" }, { "staff", "Staff" } }) do
		filterChips[spec[1]] = chipButton(top, "Filter_" .. spec[1], spec[2])
	end
	local refreshButton = chipButton(top, "Refresh", "Refresh")

	local listFrame = make("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 40),
		Size = UDim2.new(1, 0, 1, -40),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, listFrame)
	make("UIPadding", { PaddingRight = UDim.new(0, 8) }, listFrame)

	-- The Top row wraps on narrow panels; the list fills what is left.
	top.AutomaticSize = Enum.AutomaticSize.Y
	listFrame.Position = UDim2.new()
	make("UIListLayout", { Padding = UDim.new(0, 10), FillDirection = Enum.FillDirection.Vertical }, body)
	make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }, listFrame)

	local function renderHistory()
		for _, c in ipairs(listFrame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for id, b in pairs(filterChips) do
			setChip(b, id == filter)
		end
		local q = search.Text:lower()
		local shown = 0
		for _, r in ipairs(snapshot.History or {}) do
			local author = if type(r.Author) == "table" then r.Author else { UserId = 0, Name = "?", DisplayName = "?" }
			local matchesScope = filter == "all" or r.Scope == filter
			local hay = (tostring(r.Text) .. " " .. tostring(r.Title or "") .. " " .. tostring(author.Name) .. " " .. tostring(author.DisplayName)):lower()
			if matchesScope and (q == "" or hay:find(q, 1, true)) then
				shown += 1
				local accent = if type(r.Color) == "string" and #r.Color == 6 then Color3.fromHex(r.Color) else Theme.Colors.Accent
				local card = make("Frame", { Name = "Row_" .. tostring(r.Id), BackgroundColor3 = Theme.Colors.Surface, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, listFrame)
				Theme.corner(card, Theme.Radius.M)
				make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, card)
				local bar = make("Frame", { Name = "AccentBar", Size = UDim2.new(0, 3, 1, 0), Position = UDim2.new(0, -12, 0, 0), BackgroundColor3 = accent, BorderSizePixel = 0 }, card)
				bar.Size = UDim2.new(0, 3, 1, 20)
				bar.Position = UDim2.new(0, -12, 0, -10)
				local face = make("ImageLabel", { Name = "Avatar", Size = UDim2.fromOffset(40, 40), BackgroundColor3 = Theme.Colors.SurfaceRaised, Image = if (author.UserId or 0) > 0 then ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(author.UserId) else "" }, card)
				Theme.corner(face, Theme.Radius.Pill)
				local content = make("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.new(0, 52, 0, 0), Size = UDim2.new(1, -52 - 180, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, card)
				make("UIListLayout", { Padding = UDim.new(0, 2) }, content)
				local line = ("%s  @%s   -   %s   -   %s"):format(author.DisplayName, author.Name, SCOPE_LABEL[r.Scope] or "?", ago(r.Time or 0))
				label(content, "Who", line, { Font = Theme.Font.Bold, TextSize = 13 })
				if r.Title and r.Title ~= "" then
					label(content, "Title", tostring(r.Title):upper(), { Font = Theme.Font.Black, TextSize = 11, TextColor3 = accent })
				end
				label(content, "Text", tostring(r.Text), { TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y, TextSize = 14 })
				local meta = ("%s, %ds%s"):format(if r.Style == "full" then "full screen" else "banner", r.Duration or 8, if r.Recipients then ("  -  to %s%s"):format(table.concat(r.Recipients, ", "), if (r.RecipientCount or 0) > #r.Recipients then (" +" .. (r.RecipientCount - #r.Recipients)) else "") else "")
				label(content, "Meta", meta, { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })

				local actions = make("Frame", { Name = "Actions", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(176, 32) }, card)
				make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 6) }, actions)
				local previewButton = button(actions, "Preview", "Preview", false, 80)
				local resend = button(actions, "Resend", "Resend", true, 80)
				previewButton.MouseButton1Click:Connect(function()
					if banner then
						banner.Show({
							Text = r.Text,
							Title = r.Title,
							Style = r.Style,
							Duration = r.Duration,
							Color = if type(r.Color) == "string" and #r.Color == 6 then Color3.fromHex(r.Color) else nil,
							Scope = r.Scope,
							Author = author,
						})
					end
				end)
				resend.MouseButton1Click:Connect(function()
					local target = if r.Scope == "global" then "global" elseif r.Scope == "server" then "server" else "players"
					local pageId = if target == "global" then "AnnounceGlobal" elseif target == "server" then "AnnounceServer" else "AnnouncePlayers"
					if openPage then
						openPage(pageId)
					end
					composers[target].Fill(r)
				end)
			end
		end
		if shown == 0 then
			label(listFrame, "Empty", if #(snapshot.History or {}) == 0 then "No announcements yet." else "Nothing matches this filter.", { TextColor3 = Theme.Colors.TextSecondary })
		end
	end
	for id, b in pairs(filterChips) do
		b.MouseButton1Click:Connect(function()
			filter = id
			renderHistory()
		end)
	end
	search:GetPropertyChangedSignal("Text"):Connect(renderHistory)
	refreshButton.MouseButton1Click:Connect(function()
		task.spawn(refresh)
	end)
	table.insert(listeners, renderHistory)
	historyPage:GetPropertyChangedSignal("Visible"):Connect(function()
		if historyPage.Visible then
			task.spawn(refresh)
		end
	end)

	task.spawn(refresh)
end

return AnnouncementsPage
