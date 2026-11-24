--!strict
--[[
	EventsPage.lua (W24) - Announcements > Events (page id "Events").

	Blocks:
		Now       current multipliers (Coins / XP / Gems).
		Form      preset chips, name (custom events, or to rename a preset),
		          length chips, start chips (Now / in 1-30 min), scope (This
		          server / All servers), multiplier overrides, Announce switch,
		          the command line it will send, Start. Starting sends ;event /
		          ;gevent through ExecuteCommandRemote (permissions, filtering,
		          logging on the server).
		Running   every active / scheduled event: time left or "starts in",
		          multipliers, scope, author, Stop (;stopevent <id>).
		History   finished events (newest first).

	Data: GetEventsRemote() -> { Active, History, Presets, Multipliers,
	CanServer, CanGlobal, Now }; live updates from EventRemote ("state").

	Stable instance names (Studio MCP tests):
		Body.Now.Value
		Body.Form.{Presets.Chip_<id>, NameBox, Length.Chip_<label>,
		  Start.Chip_<label>, Scope.Chip_<server|global>,
		  Multipliers.{Coins,XP,Gems}, Switches.Chip_Announce, Command,
		  Buttons.Start, Status}
		Body.RunningEvents.Event_<id>.{Top.{Title,Time}, Buttons.Stop}
		Body.History.Row_<id>

	Public API:
		EventsPage.Build(container)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local EventsPage = {}

local LENGTHS = { { "5 min", "5m" }, { "15 min", "15m" }, { "30 min", "30m" }, { "1 hour", "1h" }, { "2 hours", "2h" }, { "Until stopped", "none" } }
local STARTS = { { "Now", "" }, { "In 1 min", "1m" }, { "In 5 min", "5m" }, { "In 10 min", "10m" }, { "In 30 min", "30m" } }
local STATS = { "Coins", "XP", "Gems" }

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

local function button(parent: Instance, name: string, value: string, color: Color3?, width: number?): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(width or 96, 32),
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = Theme.Font.Bold,
		TextSize = 13,
		TextColor3 = if color then Color3.new(1, 1, 1) else Theme.Colors.Text,
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
	Theme.tween(b, Theme.Motion.Fast, {
		BackgroundColor3 = if on then Theme.Colors.Accent else Theme.Colors.SurfaceRaised,
		TextColor3 = if on then Color3.new(1, 1, 1) else Theme.Colors.Text,
	})
end

local function row(parent: Instance, name: string): Frame
	local f = make("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Wraps = true, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, f)
	return f
end

local function textBox(parent: Instance, name: string, placeholder: string, size: UDim2): TextBox
	local b = make("TextBox", {
		Name = name,
		Size = size,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Theme.Font.Regular,
		TextSize = 14,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClipsDescendants = true,
		Text = "",
	}, parent) :: TextBox
	Theme.corner(b, Theme.Radius.S)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
	return b
end

local function card(parent: Instance, name: string): Frame
	local f = make("Frame", { Name = name, BackgroundColor3 = Theme.Colors.Surface, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	Theme.corner(f, Theme.Radius.M)
	make("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, f)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, f)
	return f
end

-- Name words: no "|", "&&", "=" or line breaks (they'd change the command).
local function clean(value: string): string
	return (value:gsub("[\r\n\t|=]+", " "):gsub("&&", "&"):gsub("%s+", " "):match("^%s*(.-)%s*$")) :: string
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%dh %02dm"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
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

local function multiplierText(m: any): string
	local parts = {}
	if type(m) == "table" then
		for _, stat in ipairs(STATS) do
			local v = tonumber(m[stat])
			if v and v ~= 1 then
				table.insert(parts, ("%s x%s"):format(stat, tostring(v)))
			end
		end
	end
	return table.concat(parts, ", ")
end

local function hexColor(hex: any): Color3
	if type(hex) == "string" and #hex == 6 then
		local ok, c = pcall(Color3.fromHex, hex)
		if ok then
			return c
		end
	end
	return Theme.Colors.Accent
end

function EventsPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local dataRemote = SentinelShared:WaitForChild("GetEventsRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local eventRemote = SentinelShared:WaitForChild("EventRemote", 15) :: RemoteEvent?

	label(container, "Header", "Events", { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", "Double Coins, Double XP and custom events - now or scheduled, here or in every server.", { Position = UDim2.new(0, 0, 0, 28), TextColor3 = Theme.Colors.TextSecondary })
	local body = make("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 52),
		Size = UDim2.new(1, 0, 1, -52),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, container)
	make("UIListLayout", { Padding = UDim.new(0, 10) }, body)
	make("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, body)

	local snapshot: any = { Active = {}, History = {}, Presets = {}, Multipliers = {}, CanServer = true, CanGlobal = false }
	local running: { any } = {}
	local offset = 0

	-- ======================================================================
	-- Current multipliers
	-- ======================================================================
	local nowCard = card(body, "Now")
	caption(nowCard, "Multipliers right now")
	local nowValue = label(nowCard, "Value", "Coins x1   XP x1   Gems x1", { Font = Theme.Font.Bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 22) })
	label(nowCard, "Hint", "Applies to earned rewards (;reward, EconomyService.Award). Staff grants like ;givecurrency stay exact.", {
		TextColor3 = Theme.Colors.TextSecondary,
		TextSize = 12,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	local function renderNow()
		local parts = {}
		local m = snapshot.Multipliers or {}
		for _, stat in ipairs(STATS) do
			table.insert(parts, ("%s x%s"):format(stat, tostring(tonumber(m[stat]) or 1)))
		end
		nowValue.Text = table.concat(parts, "   ")
	end

	-- ======================================================================
	-- Form
	-- ======================================================================
	local form = card(body, "Form")
	local state = { Preset = "doublecoins", Length = "15m", Start = "", Scope = "server", Announce = true }
	local commandLabel: TextLabel
	local statusLabel: TextLabel

	caption(form, "Event")
	local presetRow = row(form, "Presets")
	local presetChips: { [string]: TextButton } = {}

	caption(form, "Name (custom events, or to rename)")
	local nameBox = textBox(form, "NameBox", "e.g. Weekend rush", UDim2.new(1, 0, 0, 36))

	caption(form, "Length")
	local lengthRow = row(form, "Length")
	caption(form, "Start")
	local startRow = row(form, "Start")
	caption(form, "Where")
	local scopeRow = row(form, "Scope")

	caption(form, "Multipliers (leave empty for the preset's)")
	local multRow = row(form, "Multipliers")
	local multBoxes: { [string]: TextBox } = {}
	for _, stat in ipairs(STATS) do
		label(multRow, "Label_" .. stat, stat, { Size = UDim2.fromOffset(44, 34), TextColor3 = Theme.Colors.TextSecondary, TextXAlignment = Enum.TextXAlignment.Right })
		multBoxes[stat] = textBox(multRow, stat, "x1", UDim2.fromOffset(70, 34))
	end

	caption(form, "Settings")
	local switchRow = row(form, "Switches")
	local announceChip = chipButton(switchRow, "Chip_Announce", "Announce start and end")

	local function multiplierWords(): { string }
		local out = {}
		for _, stat in ipairs(STATS) do
			local v = (multBoxes[stat].Text:gsub("[xX%s]", ""))
			if v ~= "" and tonumber(v) then
				table.insert(out, ("%s=%s"):format(stat:lower(), v))
			end
		end
		return out
	end

	local function commandText(): string
		local words = { if state.Scope == "global" then "gevent" else "event", state.Preset }
		if state.Length ~= "15m" then
			table.insert(words, "time=" .. state.Length)
		end
		if state.Start ~= "" then
			table.insert(words, "in=" .. state.Start)
		end
		for _, w in ipairs(multiplierWords()) do
			table.insert(words, w)
		end
		if not state.Announce then
			table.insert(words, "announce=off")
		end
		local name = clean(nameBox.Text)
		if name ~= "" then
			if state.Preset == "custom" then
				table.insert(words, name)
			else
				table.insert(words, "name=" .. (name:gsub(" ", "_")))
			end
		end
		return table.concat(words, " ")
	end

	local function updateCommand()
		if commandLabel then
			commandLabel.Text = ";" .. commandText()
		end
	end

	local function renderPresets()
		for _, c in ipairs(presetRow:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(presetChips)
		local list = snapshot.Presets or {}
		if #list == 0 then
			list = { { Id = "doublecoins", Name = "Double Coins" }, { Id = "doublexp", Name = "Double XP" }, { Id = "doublegems", Name = "Double Gems" }, { Id = "doubleall", Name = "Double Everything" }, { Id = "custom", Name = "Custom event" } }
		end
		for _, def in ipairs(list) do
			local chip = chipButton(presetRow, "Chip_" .. tostring(def.Id), tostring(def.Name))
			presetChips[def.Id] = chip
			chip.MouseButton1Click:Connect(function()
				state.Preset = def.Id
				for id, c in pairs(presetChips) do
					setChip(c, id == state.Preset)
				end
				updateCommand()
			end)
			setChip(chip, def.Id == state.Preset)
		end
	end
	renderPresets()

	local function chipGroup(parent: Frame, entries: { { string } }, key: string)
		local chips: { [string]: TextButton } = {}
		for _, entry in ipairs(entries) do
			local chip = chipButton(parent, "Chip_" .. entry[1]:gsub("%s", ""), entry[1])
			chips[entry[2]] = chip
			chip.MouseButton1Click:Connect(function()
				(state :: any)[key] = entry[2]
				for value, c in pairs(chips) do
					setChip(c, value == (state :: any)[key])
				end
				updateCommand()
			end)
		end
		for value, c in pairs(chips) do
			setChip(c, value == (state :: any)[key])
		end
	end
	chipGroup(lengthRow, LENGTHS, "Length")
	chipGroup(startRow, STARTS, "Start")

	local serverChip = chipButton(scopeRow, "Chip_server", "This server")
	local globalChip = chipButton(scopeRow, "Chip_global", "All servers")
	local function renderScope()
		if not snapshot.CanGlobal and state.Scope == "global" then
			state.Scope = "server"
		end
		setChip(serverChip, state.Scope == "server")
		setChip(globalChip, state.Scope == "global")
		globalChip.Visible = snapshot.CanGlobal == true
		serverChip.Visible = snapshot.CanServer ~= false
		updateCommand()
	end
	serverChip.MouseButton1Click:Connect(function()
		state.Scope = "server"
		renderScope()
	end)
	globalChip.MouseButton1Click:Connect(function()
		state.Scope = "global"
		renderScope()
	end)

	setChip(announceChip, state.Announce)
	announceChip.MouseButton1Click:Connect(function()
		state.Announce = not state.Announce
		setChip(announceChip, state.Announce)
		updateCommand()
	end)

	commandLabel = label(form, "Command", "", {
		Font = Theme.Font.Mono,
		TextColor3 = Theme.Colors.TextSecondary,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	nameBox:GetPropertyChangedSignal("Text"):Connect(updateCommand)
	for _, box in pairs(multBoxes) do
		box:GetPropertyChangedSignal("Text"):Connect(updateCommand)
	end
	renderScope()

	local buttonRow = row(form, "Buttons")
	local startButton = button(buttonRow, "Start", "Start event", Theme.Colors.Accent, 120)
	local clearButton = button(buttonRow, "Clear", "Clear", nil, 80)
	statusLabel = label(form, "Status", "", { TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y })

	local awaiting = false
	local refresh: () -> ()
	startButton.MouseButton1Click:Connect(function()
		if state.Preset == "custom" and clean(nameBox.Text) == "" then
			statusLabel.Text = "Give the custom event a name."
			statusLabel.TextColor3 = Theme.Colors.Error
			return
		end
		if not executeRemote then
			return
		end
		awaiting = true
		statusLabel.Text = "Starting..."
		statusLabel.TextColor3 = Theme.Colors.TextSecondary
		executeRemote:FireServer(commandText())
	end)
	clearButton.MouseButton1Click:Connect(function()
		nameBox.Text = ""
		for _, box in pairs(multBoxes) do
			box.Text = ""
		end
		statusLabel.Text = ""
	end)
	if resultRemote then
		resultRemote.OnClientEvent:Connect(function(results: any)
			if type(results) ~= "table" then
				return
			end
			for _, r in ipairs(results) do
				if type(r) ~= "table" or type(r.Command) ~= "string" then
					continue
				end
				if (r.Command == "event" or r.Command == "gevent") and awaiting then
					awaiting = false
					statusLabel.Text = tostring(r.Message or ""):sub(1, 240)
					statusLabel.TextColor3 = if r.Success then Theme.Colors.Success else Theme.Colors.Error
					if r.Success then
						nameBox.Text = ""
						task.delay(0.5, refresh)
					end
				elseif r.Command == "stopevent" then
					task.delay(0.5, refresh)
				end
			end
		end)
	end

	-- ======================================================================
	-- Running / scheduled events + history
	-- ======================================================================
	label(body, "RunningHeader", "Running and scheduled", { Font = Theme.Font.Bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 24) })
	local runningFrame = make("Frame", { Name = "RunningEvents", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, runningFrame)

	label(body, "HistoryHeader", "History", { Font = Theme.Font.Bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 24) })
	local historyFrame = make("Frame", { Name = "History", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, historyFrame)

	local timeLabels: { { Label: TextLabel, View: any } } = {}

	local function renderRunning()
		for _, c in ipairs(runningFrame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(timeLabels)
		if #running == 0 then
			label(runningFrame, "Empty", "No event is running or scheduled.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		for _, v in ipairs(running) do
			local box = card(runningFrame, "Event_" .. tostring(v.Id))
			make("UIStroke", { Color = hexColor(v.Color), Transparency = 0.5, Thickness = 1 }, box)
			local top = row(box, "Top")
			label(top, "Title", tostring(v.Name), { Font = Theme.Font.Bold, TextSize = 15, Size = UDim2.new(1, -230, 0, 22), TextColor3 = hexColor(v.Color) })
			local t = label(top, "Time", "", { Size = UDim2.fromOffset(220, 22), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
			table.insert(timeLabels, { Label = t, View = v })
			local m = multiplierText(v.Multipliers)
			label(box, "Bonus", if m ~= "" then m else "No multipliers", { Font = Theme.Font.Medium })
			label(box, "Info", ("#%s  -  %s  -  by %s  -  %s"):format(
				tostring(v.Id),
				if v.Scope == "global" then "all servers" else "this server",
				if type(v.Author) == "table" then tostring(v.Author.Name) else "?",
				if (tonumber(v.EndsAt) or 0) == 0 then "until stopped" else ("for %s"):format(clock((tonumber(v.EndsAt) or 0) - (tonumber(v.StartsAt) or 0)))
			), { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
			local buttons = row(box, "Buttons")
			local stop = button(buttons, "Stop", if v.Status == "scheduled" then "Cancel" else "Stop", Theme.Colors.Error, 90)
			stop.Visible = (v.Scope == "global" and snapshot.CanGlobal) or (v.Scope ~= "global" and snapshot.CanServer ~= false)
			stop.MouseButton1Click:Connect(function()
				if executeRemote then
					executeRemote:FireServer("stopevent " .. tostring(v.Id))
				end
			end)
		end
	end

	local function renderHistory()
		for _, c in ipairs(historyFrame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local list = snapshot.History or {}
		if #list == 0 then
			label(historyFrame, "Empty", "No finished events yet.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		for i, r in ipairs(list) do
			if i > 15 then
				break
			end
			local box = card(historyFrame, "Row_" .. tostring(r.Id))
			label(box, "Title", tostring(r.Name), { Font = Theme.Font.Bold, TextSize = 14, TextColor3 = hexColor(r.Color) })
			local m = multiplierText(r.Multipliers)
			label(box, "Info", ("#%s  -  %s  -  %s  -  by %s%s  -  %s%s"):format(
				tostring(r.Id),
				if r.Scope == "global" then "global" else "server",
				tostring(r.Status),
				if type(r.Author) == "table" then tostring(r.Author.Name) else "?",
				if m ~= "" then "  -  " .. m else "",
				ago(tonumber(r.EndedAt) or os.time()),
				if r.EndedBy then (", stopped by " .. tostring(r.EndedBy)) else ""
			), { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12, TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y })
		end
	end

	refresh = function()
		if not dataRemote then
			return
		end
		local ok, data = pcall(function()
			return (dataRemote :: RemoteFunction):InvokeServer()
		end)
		if ok and type(data) == "table" then
			snapshot = data
			if type(data.Now) == "number" then
				offset = data.Now - os.time()
			end
			running = data.Active or {}
			renderNow()
			renderPresets()
			renderScope()
			renderRunning()
			renderHistory()
		end
	end

	if eventRemote then
		eventRemote.OnClientEvent:Connect(function(action: any, list: any)
			if action ~= "state" or type(list) ~= "table" then
				return
			end
			local hadIds = {}
			for _, v in ipairs(running) do
				hadIds[v.Id] = true
			end
			running = list
			local ended = false
			for id in pairs(hadIds) do
				local still = false
				for _, v in ipairs(list) do
					if v.Id == id then
						still = true
					end
				end
				ended = ended or not still
			end
			if container.Visible then
				if ended then
					task.delay(1, refresh) -- picks up the history entry + multipliers
				else
					task.spawn(refresh)
				end
			end
		end)
	end

	task.spawn(function()
		while container.Parent do
			local now = os.time() + offset
			for _, entry in ipairs(timeLabels) do
				local v = entry.View
				if entry.Label.Parent then
					local startsAt = tonumber(v.StartsAt) or 0
					local endsAt = tonumber(v.EndsAt) or 0
					entry.Label.Text = if now < startsAt
						then "starts in " .. clock(startsAt - now)
						elseif endsAt > 0 then clock(endsAt - now) .. " left"
						else "live, no timer"
				end
			end
			task.wait(0.5)
		end
	end)

	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible then
			task.spawn(refresh)
		end
	end)
	task.spawn(refresh)
end

return EventsPage
