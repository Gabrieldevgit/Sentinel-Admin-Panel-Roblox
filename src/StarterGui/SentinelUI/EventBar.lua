--!strict
--[[
	EventBar.lua (W24) - the running / scheduled events, for every player.

	ScreenGui SentinelEventBar: a row of pills in Roblox's top bar row,
	right after Sentinel's top bar pill (centred below the top bar on
	screens narrower than 900 px). One pill per event: colour dot, name, multipliers ("2x Coins")
	and the time ("12:03 left", "starts in 0:42", the last 10 s of a
	scheduled event pulse).

	Data: EventRemote ("state", { view }) from Systems/EventService; asks
	for nothing (the server pushes on join and on every change).

	Stable names: SentinelEventBar.Row.Event_<id>.{Dot, Title, Bonus, Time}

	Public API:
		EventBar.Init()
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local EventBar = {}

local STATS = { "Coins", "XP", "Gems" }

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	if seconds >= 3600 then
		return ("%dh %02dm"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

local function bonusText(m: any): string
	local parts = {}
	if type(m) == "table" then
		for _, stat in ipairs(STATS) do
			local v = tonumber(m[stat])
			if v and v ~= 1 then
				table.insert(parts, ("%sx %s"):format(tostring(v), stat))
			end
		end
	end
	return table.concat(parts, "  ")
end

local function color(hex: any): Color3
	if type(hex) == "string" and #hex == 6 then
		local ok, c = pcall(Color3.fromHex, hex)
		if ok then
			return c
		end
	end
	return Theme.Colors.Accent
end

local started = false
function EventBar.Init()
	if started then
		return
	end
	started = true
	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local remote = SentinelShared:WaitForChild("EventRemote", 30) :: RemoteEvent?
	if not remote then
		return
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = new("ScreenGui", {
		Name = "SentinelEventBar",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 40,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	local rowFrame = new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -40, 0, 30),
	}, gui)
	local layout = new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Wraps = true,
	}, rowFrame)
	-- In Roblox's top bar row, left-aligned right after Sentinel's own top
	-- bar pill (S / >_). Not centred: games often put their HUD (money...)
	-- in the top centre. The announcement banner drops in below the top
	-- bar, so it never hides the events. Narrow / touch screens (where the
	-- pill sits on the right): centred below the top bar.
	local function place()
		local inset = GuiService.TopbarInset
		local barHeight = inset.Max.Y - inset.Min.Y
		local screenWidth = gui.AbsoluteSize.X
		local topbar = playerGui:FindFirstChild("SentinelTopbar")
		local group = topbar and topbar:FindFirstChild("Group") :: GuiObject?
		local left = inset.Min.X + 8
		if group and group.Visible and group.AbsolutePosition.X < screenWidth / 2 then
			left = group.AbsolutePosition.X + group.AbsoluteSize.X + 10
		end
		if barHeight >= 30 and screenWidth >= 900 then
			rowFrame.AnchorPoint = Vector2.new(0, 0)
			rowFrame.Position = UDim2.fromOffset(left, inset.Min.Y + math.floor((barHeight - 30) / 2))
			rowFrame.Size = UDim2.fromOffset(math.max(200, inset.Max.X - left - 8), 30)
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		else
			rowFrame.AnchorPoint = Vector2.new(0.5, 0)
			rowFrame.Position = UDim2.new(0.5, 0, 0, math.max(inset.Max.Y, 36) + 6)
			rowFrame.Size = UDim2.new(1, -40, 0, 30)
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		end
	end
	place()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	-- The top bar pill is built later / resizes (buttons appear per permission).
	task.spawn(function()
		local topbar = playerGui:WaitForChild("SentinelTopbar", 30)
		local group = topbar and topbar:WaitForChild("Group", 5)
		if group and group:IsA("GuiObject") then
			group:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
			group:GetPropertyChangedSignal("AbsolutePosition"):Connect(place)
			place()
		end
	end)

	local current: { any } = {}
	local timeLabels: { { Label: TextLabel, View: any, Pill: Frame } } = {}
	local offset = 0 -- server time - client time (os.time can drift a little)

	local function render()
		for _, c in ipairs(rowFrame:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		table.clear(timeLabels)
		for i, v in ipairs(current) do
			local tint = color(v.Color)
			local pill = new("Frame", {
				Name = "Event_" .. tostring(v.Id),
				LayoutOrder = i,
				BackgroundColor3 = Color3.fromRGB(18, 18, 22),
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				Size = UDim2.fromOffset(0, 30),
				AutomaticSize = Enum.AutomaticSize.X,
			}, rowFrame)
			Theme.corner(pill, Theme.Radius.Pill)
			new("UIStroke", { Color = tint, Transparency = 0.35, Thickness = 1 }, pill)
			new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, pill)
			new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}, pill)
			local dot = new("Frame", { Name = "Dot", LayoutOrder = 1, BackgroundColor3 = tint, BorderSizePixel = 0, Size = UDim2.fromOffset(8, 8) }, pill)
			Theme.corner(dot, Theme.Radius.Pill)
			local function lbl(name: string, order: number, value: string, font: Enum.Font, c: Color3)
				return new("TextLabel", {
					Name = name,
					LayoutOrder = order,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(0, 30),
					AutomaticSize = Enum.AutomaticSize.X,
					Font = font,
					TextSize = 14,
					TextColor3 = c,
					Text = value,
				}, pill)
			end
			lbl("Title", 2, tostring(v.Name), Theme.Font.Bold, Color3.new(1, 1, 1))
			local bonus = bonusText(v.Multipliers)
			if bonus ~= "" then
				lbl("Bonus", 3, bonus, Theme.Font.Bold, tint)
			end
			local t = lbl("Time", 4, "", Theme.Font.Medium, Color3.fromRGB(190, 190, 200))
			table.insert(timeLabels, { Label = t, View = v, Pill = pill })
		end
	end

	local function updateTimes()
		local now = os.time() + offset
		for _, entry in ipairs(timeLabels) do
			local v = entry.View
			local startsAt = tonumber(v.StartsAt) or 0
			local endsAt = tonumber(v.EndsAt) or 0
			if now < startsAt then
				local left = startsAt - now
				entry.Label.Text = "starts in " .. clock(left)
				entry.Pill.BackgroundTransparency = if left <= 10 and left % 2 == 0 then 0 else 0.15
			elseif endsAt > 0 then
				entry.Label.Text = clock(endsAt - now) .. " left"
				entry.Pill.BackgroundTransparency = 0.15
			else
				entry.Label.Text = "live"
			end
		end
	end

	remote.OnClientEvent:Connect(function(action: any, list: any, serverNow: any)
		if action ~= "state" or type(list) ~= "table" then
			return
		end
		if type(serverNow) == "number" then
			offset = serverNow - os.time()
		end
		current = {}
		for _, v in ipairs(list) do
			if type(v) == "table" and (v.Status == "active" or v.Status == "scheduled") then
				table.insert(current, v)
			end
		end
		render()
		updateTimes()
	end)

	task.spawn(function()
		while gui.Parent do
			updateTimes()
			task.wait(0.5)
		end
	end)
end

return EventBar
