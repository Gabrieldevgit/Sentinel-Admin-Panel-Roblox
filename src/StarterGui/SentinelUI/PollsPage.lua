--!strict
--[[
	PollsPage.lua (W23) - Announcements > Polls (page id "Polls").

	Three blocks:
		Form      question, 2-8 options (+ Add option / remove), time chips,
		          scope (This server / All servers), switches (Change vote,
		          Live results, Announce results), the command line it will
		          send, Start. Starting sends ;poll / ;gpoll through
		          ExecuteCommandRemote (permissions, filtering, logging on the
		          server).
		Active    every running poll with live bars, votes, time left and
		          End / Cancel (;endpoll / ;cancelpoll).
		History   recent results (newest first).

	Data: GetPollsRemote() -> { Active = {view}, History = {record}, CanServer,
	CanGlobal }; live updates from PollRemote ("state" / "remove").

	Stable instance names (Studio MCP tests):
		Body.Form.{Question, Options.Option_<n>.{Box,Remove}, Options.AddOption,
		  Time.Chip_<label>, Scope.Chip_<server|global>, Switches.Chip_<Change|Live|Announce>,
		  Command, Buttons.Start, Status}
		Body.ActivePolls.Poll_<id>.{Bars.Bar_<n>, Buttons.{End,Cancel}}
		Body.History.Row_<id>

	Public API:
		PollsPage.Build(container)
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local PollsPage = {}

local MAX_OPTIONS = 8
local TIMES = { { "30s", "30" }, { "1 min", "60" }, { "2 min", "2m" }, { "5 min", "5m" }, { "No timer", "none" } }
local POLL_COLOR = Color3.fromRGB(167, 139, 250)

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

-- No "|" or "&&" or line breaks inside a question / option (they'd change the command).
local function clean(value: string): string
	return (value:gsub("[\r\n\t|]+", " "):gsub("&&", "&"):gsub("%s+", " "):match("^%s*(.-)%s*$")) :: string
end

local function clockText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
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

-- Result bars (shared by Active and History rows).
local function bars(parent: Instance, options: { string }, counts: { number }?, winners: { number }?, myVote: number?): Frame
	local holder = make("Frame", { Name = "Bars", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, parent)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, holder)
	local total = 0
	for _, n in ipairs(counts or {}) do
		total += n
	end
	for k, option in ipairs(options) do
		local n = if counts then counts[k] or 0 else 0
		local share = if total > 0 then n / total else 0
		local won = winners ~= nil and table.find(winners, k) ~= nil
		local bar = make("Frame", { Name = "Bar_" .. k, BackgroundColor3 = Theme.Colors.SurfaceRaised, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 28), ClipsDescendants = true }, holder)
		Theme.corner(bar, Theme.Radius.S)
		local fill = make("Frame", { Name = "Fill", BackgroundColor3 = if won then Theme.Colors.Success else POLL_COLOR, BackgroundTransparency = 0.7, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0) }, bar)
		Theme.corner(fill, Theme.Radius.S)
		Theme.tween(fill, Theme.Motion.Normal, { Size = UDim2.new(share, 0, 1, 0) })
		label(bar, "Label", ("%d.  %s%s"):format(k, option, if myVote == k then "  (your vote)" else ""), {
			Position = UDim2.fromOffset(10, 0),
			Size = UDim2.new(1, -110, 1, 0),
			Font = if won then Theme.Font.Bold else Theme.Font.Medium,
			ZIndex = 2,
		})
		label(bar, "Value", if counts then ("%d%%  %d"):format(math.floor(share * 100 + 0.5), n) else "hidden", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 0),
			Size = UDim2.new(0, 96, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			Font = Theme.Font.Bold,
			TextColor3 = if won then Theme.Colors.Success else Theme.Colors.TextSecondary,
			ZIndex = 2,
		})
	end
	return holder
end

function PollsPage.Build(container: Frame)
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local dataRemote = SentinelShared:WaitForChild("GetPollsRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	local pollRemote = SentinelShared:WaitForChild("PollRemote", 15) :: RemoteEvent?

	label(container, "Header", "Polls", { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	label(container, "SubHeader", "Ask the server a question. Players vote on a card on their screen or with ;vote.", { Position = UDim2.new(0, 0, 0, 28), TextColor3 = Theme.Colors.TextSecondary })
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

	local snapshot: any = { Active = {}, History = {}, CanServer = true, CanGlobal = false }
	local live: { [string]: any } = {} -- latest view per active poll id

	-- ======================================================================
	-- Form
	-- ======================================================================
	local form = card(body, "Form")
	caption(form, "Question")
	local question = textBox(form, "Question", "What should we ask? e.g. Which map next?", UDim2.new(1, 0, 0, 36))

	caption(form, "Options")
	local optionsFrame = make("Frame", { Name = "Options", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, form)
	make("UIListLayout", { Padding = UDim.new(0, 6) }, optionsFrame)
	local optionBoxes: { TextBox } = {}
	local addOption: TextButton

	local state = { Time = "60", Scope = "server", Change = true, Live = true, Announce = true }
	local commandLabel: TextLabel
	local statusLabel: TextLabel

	local function options(): { string }
		local out = {}
		for _, box in ipairs(optionBoxes) do
			local v = clean(box.Text)
			if v ~= "" then
				table.insert(out, v)
			end
		end
		return out
	end

	local function commandText(): string
		local words = { if state.Scope == "global" then "gpoll" else "poll" }
		if state.Time ~= "60" then
			table.insert(words, "time=" .. state.Time)
		end
		if not state.Change then
			table.insert(words, "change=off")
		end
		if not state.Live then
			table.insert(words, "results=end")
		end
		if not state.Announce then
			table.insert(words, "announce=off")
		end
		local q = clean(question.Text)
		table.insert(words, if q ~= "" then q else "<question>")
		local opts = options()
		if #opts > 0 then
			table.insert(words, "| " .. table.concat(opts, " | "))
		end
		return table.concat(words, " ")
	end

	local function updateCommand()
		if commandLabel then
			commandLabel.Text = ";" .. commandText()
		end
	end

	local renumber: () -> ()
	local function addOptionRow(value: string?)
		if #optionBoxes >= MAX_OPTIONS then
			return
		end
		local index = #optionBoxes + 1
		local holder = make("Frame", { Name = "Option_" .. index, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34) }, optionsFrame)
		local box = textBox(holder, "Box", ("Option %d"):format(index), UDim2.new(1, -42, 1, 0))
		box.Text = value or ""
		local remove = make("TextButton", {
			Name = "Remove",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 0),
			Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			AutoButtonColor = true,
			BorderSizePixel = 0,
			Text = "",
		}, holder)
		Theme.corner(remove, Theme.Radius.S)
		Theme.crossIcon(remove, 12, Theme.Colors.TextSecondary, 2)
		table.insert(optionBoxes, box)
		box:GetPropertyChangedSignal("Text"):Connect(updateCommand)
		remove.MouseButton1Click:Connect(function()
			if #optionBoxes <= 2 then
				box.Text = ""
				return
			end
			local at = table.find(optionBoxes, box)
			if at then
				table.remove(optionBoxes, at)
			end
			holder:Destroy()
			renumber()
			updateCommand()
		end)
		if addOption then
			addOption.LayoutOrder = order + 1
			order += 1
			addOption.Visible = #optionBoxes < MAX_OPTIONS
		end
	end

	renumber = function()
		for i, box in ipairs(optionBoxes) do
			local holder = box.Parent :: Frame
			holder.Name = "Option_" .. i
			box.PlaceholderText = ("Option %d"):format(i)
		end
		if addOption then
			addOption.Visible = #optionBoxes < MAX_OPTIONS
		end
	end

	addOptionRow()
	addOptionRow()
	addOption = make("TextButton", {
		Name = "AddOption",
		Size = UDim2.new(0, 130, 0, 30),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		BorderSizePixel = 0,
		Font = Theme.Font.Medium,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		Text = "+  Add option",
	}, optionsFrame)
	Theme.corner(addOption, Theme.Radius.Pill)
	addOption.MouseButton1Click:Connect(function()
		addOptionRow()
		updateCommand()
	end)
	label(form, "OptionsHint", "Leave the options empty for a Yes / No poll.", { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })

	caption(form, "Time")
	local timeRow = row(form, "Time")
	local timeChips: { [string]: TextButton } = {}
	for _, entry in ipairs(TIMES) do
		local chip = chipButton(timeRow, "Chip_" .. entry[1]:gsub("%s", ""), entry[1])
		timeChips[entry[2]] = chip
		chip.MouseButton1Click:Connect(function()
			state.Time = entry[2]
			for value, c in pairs(timeChips) do
				setChip(c, value == state.Time)
			end
			updateCommand()
		end)
	end
	for value, c in pairs(timeChips) do
		setChip(c, value == state.Time)
	end

	caption(form, "Where")
	local scopeRow = row(form, "Scope")
	local serverChip = chipButton(scopeRow, "Chip_server", "This server")
	local globalChip = chipButton(scopeRow, "Chip_global", "All servers")
	local function renderScope()
		setChip(serverChip, state.Scope == "server")
		setChip(globalChip, state.Scope == "global")
		globalChip.Visible = snapshot.CanGlobal == true
		serverChip.Visible = snapshot.CanServer ~= false
	end
	serverChip.MouseButton1Click:Connect(function()
		state.Scope = "server"
		renderScope()
		updateCommand()
	end)
	globalChip.MouseButton1Click:Connect(function()
		state.Scope = "global"
		renderScope()
		updateCommand()
	end)
	renderScope()

	caption(form, "Settings")
	local switchRow = row(form, "Switches")
	local switches = {
		{ Key = "Change", Label = "Players can change their vote" },
		{ Key = "Live", Label = "Show results while voting" },
		{ Key = "Announce", Label = "Announce the results" },
	}
	for _, s in ipairs(switches) do
		local chip = chipButton(switchRow, "Chip_" .. s.Key, s.Label)
		setChip(chip, (state :: any)[s.Key])
		chip.MouseButton1Click:Connect(function()
			(state :: any)[s.Key] = not (state :: any)[s.Key]
			setChip(chip, (state :: any)[s.Key])
			updateCommand()
		end)
	end

	commandLabel = label(form, "Command", "", {
		Font = Theme.Font.Mono,
		TextColor3 = Theme.Colors.TextSecondary,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.None,
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	question:GetPropertyChangedSignal("Text"):Connect(updateCommand)
	updateCommand()

	local buttonRow = row(form, "Buttons")
	local startButton = button(buttonRow, "Start", "Start poll", Theme.Colors.Accent, 120)
	local clearButton = button(buttonRow, "Clear", "Clear", nil, 80)
	statusLabel = label(form, "Status", "", { TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y })

	local awaiting = false
	local refresh: () -> ()
	startButton.MouseButton1Click:Connect(function()
		if clean(question.Text) == "" then
			statusLabel.Text = "Type a question first."
			statusLabel.TextColor3 = Theme.Colors.Error
			return
		end
		if #options() == 1 then
			statusLabel.Text = "Add a second option (or remove the first for Yes / No)."
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
		question.Text = ""
		for _, box in ipairs(optionBoxes) do
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
				if type(r) == "table" and type(r.Command) == "string" and (r.Command == "poll" or r.Command == "gpoll") and awaiting then
					awaiting = false
					statusLabel.Text = tostring(r.Message or ""):sub(1, 240)
					statusLabel.TextColor3 = if r.Success then Theme.Colors.Success else Theme.Colors.Error
					if r.Success then
						question.Text = ""
						for _, box in ipairs(optionBoxes) do
							box.Text = ""
						end
						task.delay(0.5, refresh)
					end
				elseif type(r) == "table" and (r.Command == "endpoll" or r.Command == "cancelpoll") then
					task.delay(0.5, refresh)
				end
			end
		end)
	end

	-- ======================================================================
	-- Active polls
	-- ======================================================================
	label(body, "ActiveHeader", "Active polls", { Font = Theme.Font.Bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 24) })
	local activeFrame = make("Frame", { Name = "ActivePolls", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, activeFrame)

	label(body, "HistoryHeader", "Recent results", { Font = Theme.Font.Bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 24) })
	local historyFrame = make("Frame", { Name = "History", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, body)
	make("UIListLayout", { Padding = UDim.new(0, 8) }, historyFrame)

	local timeLabels: { [string]: { Label: TextLabel, View: any } } = {}

	local function renderActive()
		for _, c in ipairs(activeFrame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(timeLabels)
		local ids = {}
		for id, view in pairs(live) do
			if view.Status == "active" or view.Status == "closing" then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return (live[a].StartedAt or 0) < (live[b].StartedAt or 0)
		end)
		if #ids == 0 then
			label(activeFrame, "Empty", "No poll is running.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		for _, id in ipairs(ids) do
			local v = live[id]
			local box = card(activeFrame, "Poll_" .. id)
			local top = row(box, "Top")
			label(top, "Question", tostring(v.Question), { Font = Theme.Font.Bold, TextSize = 15, Size = UDim2.new(1, -230, 0, 22) })
			local meta = label(top, "Meta", "", { Size = UDim2.fromOffset(220, 22), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
			timeLabels[id] = { Label = meta, View = v }
			bars(box, v.Options or {}, v.Counts, nil, v.MyVote)
			local info = ("#%s  -  %s  -  by %s  -  %d vote%s%s"):format(
				id,
				if v.Scope == "global" then ("global (from %s)"):format(tostring(v.Origin)) else "this server",
				if type(v.Author) == "table" then tostring(v.Author.Name) else "?",
				tonumber(v.Total) or 0,
				if (tonumber(v.Total) or 0) == 1 then "" else "s",
				if v.AllowChange then "" else "  -  no vote changes"
			)
			label(box, "Info", info, { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
			local buttons = row(box, "Buttons")
			local endButton = button(buttons, "End", "End now", POLL_COLOR, 100)
			local cancelButton = button(buttons, "Cancel", "Cancel", nil, 90)
			endButton.Visible = v.Status == "active"
			cancelButton.Visible = v.Status == "active"
			endButton.MouseButton1Click:Connect(function()
				if executeRemote then
					executeRemote:FireServer("endpoll " .. id)
				end
			end)
			cancelButton.MouseButton1Click:Connect(function()
				if executeRemote then
					executeRemote:FireServer("cancelpoll " .. id)
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
			label(historyFrame, "Empty", "No finished polls yet.", { TextColor3 = Theme.Colors.TextSecondary })
			return
		end
		for i, r in ipairs(list) do
			if i > 15 then
				break
			end
			local box = card(historyFrame, "Row_" .. tostring(r.Id))
			label(box, "Question", tostring(r.Question), { Font = Theme.Font.Bold, TextSize = 14 })
			if r.Status == "cancelled" then
				label(box, "Cancelled", "Cancelled", { TextColor3 = Theme.Colors.Error, TextSize = 12 })
			else
				bars(box, r.Options or {}, r.Counts, r.Winners, nil)
			end
			label(box, "Info", ("#%s  -  %s  -  by %s  -  %d vote%s  -  %s%s"):format(
				tostring(r.Id),
				if r.Scope == "global" then "global" else "server",
				if type(r.Author) == "table" then tostring(r.Author.Name) else "?",
				tonumber(r.Total) or 0,
				if (tonumber(r.Total) or 0) == 1 then "" else "s",
				ago(tonumber(r.EndedAt) or os.time()),
				if r.EndedBy then (", ended by " .. tostring(r.EndedBy)) else ""
			), { TextColor3 = Theme.Colors.TextSecondary, TextSize = 12 })
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
			table.clear(live)
			for _, v in ipairs(data.Active or {}) do
				live[v.Id] = v
			end
			renderScope()
			renderActive()
			renderHistory()
		end
	end

	-- Live updates while the page exists (votes, end, cancel).
	if pollRemote then
		local pending = false
		pollRemote.OnClientEvent:Connect(function(action: any, a: any)
			if action == "state" and type(a) == "table" and a.Id then
				local finished = a.Status == "ended" or a.Status == "cancelled"
				if finished then
					live[a.Id] = nil
					task.delay(1, refresh) -- picks up the history entry
				else
					live[a.Id] = a
				end
				if not pending and container.Visible then
					pending = true
					task.delay(0.3, function()
						pending = false
						renderActive()
					end)
				end
			elseif action == "remove" and type(a) == "string" then
				live[a] = nil
			end
		end)
	end

	-- Time left on the active cards.
	task.spawn(function()
		while container.Parent do
			for _, entry in pairs(timeLabels) do
				local v = entry.View
				if entry.Label.Parent then
					local endsAt = tonumber(v.EndsAt) or 0
					entry.Label.Text = if v.Status == "closing"
						then "counting votes..."
						elseif endsAt > 0 then clockText(endsAt - os.time()) .. " left"
						else "no timer"
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

return PollsPage
