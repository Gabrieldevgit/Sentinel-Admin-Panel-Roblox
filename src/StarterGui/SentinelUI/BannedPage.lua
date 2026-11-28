--!strict
--[[
	BannedPage.lua (Moderation > Banned)

	Every active ban in the game (Sentinel's ban store: staff bans, global
	bans and anti-cheat bans), for staff with moderation.banlist (view) or
	moderation.ban (view + act). The page is hidden for everyone else.

	Layout:
		Header + summary cards (Active, Anti-cheat, Staff, Permanent,
		Ending in 24 h), filter chips (All / Anti-cheat / Staff / Permanent /
		Temporary), a text filter and Refresh, then one card per ban: name,
		UserId, source tag, time left or PERMANENT, who / when, reason.
		Actions (moderation.ban): Unban (;unban), Change length (;editban
		<id> <30m|12h|7d|perm>, undoable), Profile (opens Lookup). Every
		action goes through the normal commands, so permissions, confirms,
		audit log and ;undo apply. The list reloads after each command result.

	Reads GetBanListRemote() -> { Bans, CanAct, Denied?, Error? }.

	Stable names: Header, Cards.Card_<key>, Filters.{Chip_<id>, Filter,
	Refresh}, List.Ban_<userId>.{Unban, Length, Profile}, EditBox.{Duration,
	Apply, Cancel}
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent:WaitForChild("Theme"))

local BannedPage = {}

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

local function button(parent: Instance, name: string, text: string, width: number?, color: Color3?): TextButton
	local b = make("TextButton", {
		Name = name,
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		AutoButtonColor = true,
		Font = Theme.Font.Medium,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		Text = text,
		Size = UDim2.new(0, width or 80, 0, 26),
	}, parent) :: TextButton
	Theme.corner(b, UDim.new(0, 4))
	return b
end

local function left(seconds: number?): string
	if not seconds then
		return "PERMANENT"
	end
	if seconds >= 86400 then
		return ("%dd %dh left"):format(seconds // 86400, (seconds % 86400) // 3600)
	elseif seconds >= 3600 then
		return ("%dh %dm left"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%dm left"):format(math.max(1, seconds // 60))
end

local function ago(t: number?): string
	if not t then
		return "?"
	end
	local s = math.max(0, os.time() - t)
	if s < 3600 then
		return ("%dm ago"):format(s // 60)
	elseif s < 86400 then
		return ("%dh ago"):format(s // 3600)
	end
	return ("%dd ago"):format(s // 86400)
end

local FILTERS = {
	{ Id = "All", Label = "All" },
	{ Id = "AntiCheat", Label = "Anti-cheat" },
	{ Id = "Staff", Label = "Staff" },
	{ Id = "Permanent", Label = "Permanent" },
	{ Id = "Temporary", Label = "Temporary" },
}

local function matches(b: any, filterId: string): boolean
	if filterId == "AntiCheat" then
		return b.Source == "anticheat"
	elseif filterId == "Staff" then
		return b.Source ~= "anticheat"
	elseif filterId == "Permanent" then
		return b.Permanent == true
	elseif filterId == "Temporary" then
		return b.Permanent ~= true
	end
	return true
end
BannedPage._Matches = matches

-- Builds the page. Returns true when the viewer may see it (init.client
-- hides the nav entry otherwise). openProfile(userId) opens Lookup.
function BannedPage.Build(container: Frame, openProfile: ((number) -> ())?): boolean
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local listRemote = SentinelShared:WaitForChild("GetBanListRemote", 15) :: RemoteFunction?
	local executeRemote = SentinelShared:WaitForChild("ExecuteCommandRemote", 15) :: RemoteEvent?
	local resultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?

	local function run(text: string)
		if executeRemote then
			executeRemote:FireServer(text)
		end
	end

	label(container, "Header", "Banned Players", { Size = UDim2.new(1, 0, 0, 28), Font = Theme.Font.Bold, TextSize = 20 })
	local status = label(container, "SubHeader", "Loading...", { Position = UDim2.new(0, 0, 0, 28), TextColor3 = Theme.Colors.TextSecondary })

	-- Summary cards
	local cardsRow = make("Frame", { Name = "Cards", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 52), Size = UDim2.new(1, 0, 0, 56) }, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) }, cardsRow)
	local cardValues: { [string]: TextLabel } = {}
	for _, spec in ipairs({ { "Active", "Active bans" }, { "AntiCheat", "Anti-cheat" }, { "Staff", "Staff" }, { "Permanent", "Permanent" }, { "Soon", "Ending in 24 h" } }) do
		local card = make("Frame", { Name = "Card_" .. spec[1], BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(0.2, -7, 1, 0) }, cardsRow)
		Theme.corner(card, Theme.Radius.S)
		label(card, "Title", spec[2], { Position = UDim2.new(0, 10, 0, 6), Size = UDim2.new(1, -20, 0, 16), TextColor3 = Theme.Colors.TextSecondary, TextSize = 11 })
		cardValues[spec[1]] = label(card, "Value", "-", { Position = UDim2.new(0, 10, 0, 22), Size = UDim2.new(1, -20, 0, 26), Font = Theme.Font.Bold, TextSize = 20 })
	end

	-- Filters
	local filters = make("Frame", { Name = "Filters", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 116), Size = UDim2.new(1, 0, 0, 28) }, container)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, filters)
	local filterId = "All"
	local chipButtons: { [string]: TextButton } = {}
	local render: () -> () -- forward
	for _, f in ipairs(FILTERS) do
		local chip = button(filters, "Chip_" .. f.Id, f.Label, 84)
		chipButtons[f.Id] = chip
		chip.Activated:Connect(function()
			filterId = f.Id
			for id, b in pairs(chipButtons) do
				b.BackgroundColor3 = if id == filterId then Theme.Colors.Accent else Theme.Colors.SurfaceRaised
			end
			render()
		end)
	end
	chipButtons.All.BackgroundColor3 = Theme.Colors.Accent
	local filterBox = make("TextBox", {
		Name = "Filter",
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "Filter name, id, reason, moderator",
		PlaceholderColor3 = Theme.Colors.TextSecondary,
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 220, 0, 26),
	}, filters) :: TextBox
	Theme.corner(filterBox, UDim.new(0, 4))
	Theme.padding(filterBox, 6)
	local refresh = button(filters, "Refresh", "Refresh", 76)

	local list = make("ScrollingFrame", {
		Name = "List",
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 152),
		Size = UDim2.new(1, 0, 1, -152),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, container)
	Theme.corner(list, Theme.Radius.S)
	Theme.padding(list, 6)
	make("UIListLayout", { Padding = UDim.new(0, 4) }, list)

	-- Change-length box (one at a time, over the list).
	local editBox = make("Frame", {
		Name = "EditBox",
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 380, 0, 96), -- over the header / cards, never over a ban row
		Visible = false,
		ZIndex = 10,
	}, container)
	Theme.corner(editBox, Theme.Radius.S)
	local editTitle = label(editBox, "Title", "", { Position = UDim2.new(0, 10, 0, 6), Size = UDim2.new(1, -20, 0, 18), Font = Theme.Font.Bold, ZIndex = 11 })
	label(editBox, "Hint", "New length from now: 30m, 12h, 7d, 30d or perm", { Position = UDim2.new(0, 10, 0, 26), Size = UDim2.new(1, -20, 0, 16), TextColor3 = Theme.Colors.TextSecondary, TextSize = 11, ZIndex = 11 })
	local durationBox = make("TextBox", {
		Name = "Duration",
		BackgroundColor3 = Theme.Colors.Surface,
		Font = Theme.Font.Regular,
		TextSize = 13,
		TextColor3 = Theme.Colors.Text,
		PlaceholderText = "7d",
		Text = "",
		ClearTextOnFocus = false,
		Position = UDim2.new(0, 10, 0, 56),
		Size = UDim2.new(0, 170, 0, 28),
		ZIndex = 11,
	}, editBox) :: TextBox
	Theme.corner(durationBox, UDim.new(0, 4))
	local apply = button(editBox, "Apply", "Apply", 84, Theme.Colors.Accent)
	apply.Position = UDim2.new(0, 190, 0, 57)
	apply.ZIndex = 11
	local cancel = button(editBox, "Cancel", "Cancel", 84)
	cancel.Position = UDim2.new(0, 282, 0, 57)
	cancel.ZIndex = 11
	local editing: number? = nil
	cancel.Activated:Connect(function()
		editBox.Visible = false
		editing = nil
	end)
	apply.Activated:Connect(function()
		local text = durationBox.Text:gsub("%s", "")
		if editing and text ~= "" then
			run(("editban %d %s"):format(editing, text))
		end
		editBox.Visible = false
		editing = nil
	end)

	local data: any = { Bans = {} }

	render = function()
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local needle = filterBox.Text:lower()
		local shown = 0
		for _, b in ipairs(data.Bans or {}) do
			local text = ("%s %d %s %s"):format(tostring(b.Name), b.UserId, tostring(b.Reason), tostring(b.BannedByName)):lower()
			if matches(b, filterId) and (needle == "" or text:find(needle, 1, true)) then
				shown += 1
				local isAC = b.Source == "anticheat"
				local row = make("Frame", { Name = "Ban_" .. b.UserId, BackgroundColor3 = Theme.Colors.SurfaceRaised, Size = UDim2.new(1, 0, 0, 58) }, list)
				Theme.corner(row, UDim.new(0, 4))
				local tag = label(row, "Source", if isAC then "ANTI-CHEAT" else "STAFF", {
					Position = UDim2.new(0, 8, 0, 6),
					Size = UDim2.new(0, 78, 0, 18),
					BackgroundTransparency = 0,
					BackgroundColor3 = if isAC then Theme.Colors.Warning else Theme.Colors.Accent,
					TextColor3 = Color3.new(1, 1, 1),
					Font = Theme.Font.Bold,
					TextSize = 10,
					TextXAlignment = Enum.TextXAlignment.Center,
				})
				Theme.corner(tag, UDim.new(0, 4))
				label(row, "Title", ("%s (%d)   %s"):format(tostring(b.Name or "?"), b.UserId, left(b.SecondsLeft)), {
					Position = UDim2.new(0, 94, 0, 6),
					Size = UDim2.new(1, -370, 0, 18),
					Font = Theme.Font.Bold,
					TextSize = 13,
					TextColor3 = if b.Permanent then Theme.Colors.Error else Theme.Colors.Text,
				})
				label(row, "Detail", ("by %s, %s  -  %s"):format(tostring(b.BannedByName or b.BannedBy or "?"), ago(b.IssuedAt), tostring(b.Reason or "")), {
					Position = UDim2.new(0, 8, 0, 30),
					Size = UDim2.new(1, -280, 0, 20),
					TextColor3 = Theme.Colors.TextSecondary,
				})
				local actions = make("Frame", { Name = "Actions", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.new(0, 262, 0, 26) }, row)
				make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 4) }, actions)
				if data.CanAct then
					local unban = button(actions, "Unban", "Unban", 70, Theme.Colors.Error)
					unban.Activated:Connect(function()
						run("unban " .. b.UserId .. " Lifted from the Banned page")
					end)
					local length = button(actions, "Length", "Change length", 104)
					length.Activated:Connect(function()
						editing = b.UserId
						editTitle.Text = "Change ban length - " .. tostring(b.Name)
						durationBox.Text = ""
						editBox.Visible = true
					end)
				end
				local profile = button(actions, "Profile", "Profile", 70)
				profile.Activated:Connect(function()
					if openProfile then
						openProfile(b.UserId)
					end
				end)
			end
		end
		if shown == 0 then
			label(list, "Empty", if #(data.Bans or {}) == 0 then "No active bans." else "No bans match the filters.", { TextColor3 = Theme.Colors.TextSecondary })
		end
	end
	filterBox:GetPropertyChangedSignal("Text"):Connect(render)

	local allowed = true
	local function load(): boolean
		if not listRemote then
			status.Text = "The ban list is not available."
			return false
		end
		local ok, result = pcall(function()
			return listRemote:InvokeServer()
		end)
		if not ok or type(result) ~= "table" then
			status.Text = "Could not load the ban list (try Refresh)."
			return true
		end
		if result.Denied then
			allowed = false
			status.Text = tostring(result.Error)
			return false
		end
		data = result
		local counts = { Active = 0, AntiCheat = 0, Staff = 0, Permanent = 0, Soon = 0 }
		for _, b in ipairs(result.Bans or {}) do
			counts.Active += 1
			if b.Source == "anticheat" then
				counts.AntiCheat += 1
			else
				counts.Staff += 1
			end
			if b.Permanent then
				counts.Permanent += 1
			elseif (b.SecondsLeft or 0) < 86400 then
				counts.Soon += 1
			end
		end
		for key, value in pairs(counts) do
			cardValues[key].Text = tostring(value)
		end
		status.Text = ("%d active ban(s).%s%s"):format(
			counts.Active,
			if result.CanAct then "" else "  View only (lifting and editing bans needs moderation.ban).",
			if result.Error then "  " .. tostring(result.Error) else ""
		)
		render()
		return true
	end
	refresh.Activated:Connect(load)
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		if container.Visible and allowed then
			task.spawn(load)
		end
	end)
	if resultRemote then
		local pending = false
		resultRemote.OnClientEvent:Connect(function()
			if not container.Visible or pending then
				return
			end
			pending = true
			task.delay(0.6, function()
				pending = false
				load()
			end)
		end)
	end
	return load()
end

return BannedPage
