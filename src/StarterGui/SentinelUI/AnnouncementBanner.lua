--!strict
--[[
	AnnouncementBanner.lua - announcements, private messages and Owner
	approval requests, drawn in the panel's Roblox-style look. Built for
	every player (not only staff) by init.client.

	ScreenGui SentinelAnnouncements:
		Banner        top centre, below Roblox's top bar: author avatar,
		              display name, @username, scope chip, optional title,
		              message, close button, timer line. Queued, one at a time.
		Full          full-screen card on a dimmed backdrop (style=full).
		Cards         right-hand stack (below the top bar):
		              PM_<thread>        private message: reply box + Send,
		                                 "Got it" (read receipt), close
		              Approval_<id>      Owner only: requester, command, risk,
		                                 Approve / Deny, countdown
		              Popup PMs (style=popup) sit in the centre instead.

	Remotes: AnnounceRemote (payload table, or the old (text, color)),
	UtilityRemote "Hint", PrivateMessageRemote, ApprovalRemote.

	Public API:
		AnnouncementBanner.Init()
		AnnouncementBanner.Show(payload)          -- also used by the page's Preview
		AnnouncementBanner.ShowHint(text)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local AnnouncementBanner = {}

local localPlayer = Players.LocalPlayer
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")

local SCOPE_LABEL = { server = "Server", global = "Global", players = "Private", staff = "Staff" }
local LEVEL_COLOR_KEY = { info = "Accent", success = "Success", warning = "Warning", error = "Error" }

local gui: ScreenGui? = nil
local cardStack: Frame? = nil
local popupHolder: Frame? = nil
local bannerQueue: { any } = {}
local bannerBusy = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
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

local function list(parent: Instance, props: { [string]: any }?): UIListLayout
	local layout = new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, parent)
	for k, v in pairs(props or {}) do
		(layout :: any)[k] = v
	end
	return layout
end

local function pad(parent: Instance, t: number, r: number, b: number, l: number)
	new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b),
		PaddingLeft = UDim.new(0, l),
	}, parent)
end

local function text(parent: Instance, name: string, value: string, size: number, font: Enum.Font, color: Color3, order: number, props: { [string]: any }?): TextLabel
	local label = new("TextLabel", {
		Name = name,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = font,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = value,
	}, parent)
	for k, v in pairs(props or {}) do
		(label :: any)[k] = v
	end
	return label
end

local function topInset(): number
	local ok, inset = pcall(function()
		return GuiService.TopbarInset
	end)
	if ok and inset and inset.Height > 0 then
		return inset.Max.Y
	end
	return 58
end

local function screenWidth(): number
	local g = gui
	return if g then g.AbsoluteSize.X else 800
end

-- Round avatar (headshot) with a coloured ring; "S" badge when there is no
-- user (system / anonymous messages).
local function avatar(parent: Instance, userId: number?, size: number, ring: Color3, order: number?): Frame
	local holder = new("Frame", {
		Name = "Avatar",
		LayoutOrder = order or 0,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
	}, parent)
	Theme.corner(holder, Theme.Radius.Pill)
	new("UIStroke", { Color = ring, Thickness = 2, Transparency = 0.1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, holder)
	if userId and userId > 0 then
		local image = new("ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId),
		}, holder)
		Theme.corner(image, Theme.Radius.Pill)
	else
		holder.BackgroundColor3 = ring
		new("TextLabel", {
			Name = "Badge",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Font = Theme.Font.Black,
			TextSize = math.floor(size * 0.5),
			TextColor3 = Color3.new(1, 1, 1),
			Text = "S",
		}, holder)
	end
	return holder
end

local function chip(parent: Instance, name: string, value: string, color: Color3, order: number): Frame
	local pill = new("Frame", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
	}, parent)
	Theme.corner(pill, Theme.Radius.Pill)
	pad(pill, 0, 9, 0, 9)
	new("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Font.Bold,
		TextSize = 12,
		TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35),
		Text = value,
	}, pill)
	return pill
end

local function iconButton(parent: Instance, name: string, size: number): TextButton
	local b = new("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
	}, parent)
	Theme.corner(b, Theme.Radius.Pill)
	Theme.crossIcon(b, math.floor(size * 0.42), Theme.Colors.TextSecondary, 2)
	b.MouseEnter:Connect(function()
		Theme.tween(b, Theme.Motion.Fast, { BackgroundTransparency = 0 })
	end)
	b.MouseLeave:Connect(function()
		Theme.tween(b, Theme.Motion.Fast, { BackgroundTransparency = 1 })
	end)
	return b
end

local function actionButton(parent: Instance, name: string, label: string, color: Color3?, order: number, width: UDim?): TextButton
	local filled = color ~= nil
	local b = new("TextButton", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(width or UDim.new(0.5, -4), UDim.new(0, 34)),
		BackgroundColor3 = color or Theme.Colors.SurfaceRaised,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Font = Theme.Font.Bold,
		TextSize = 14,
		TextColor3 = if filled then Color3.new(1, 1, 1) else Theme.Colors.Text,
		Text = label,
	}, parent)
	Theme.corner(b, Theme.Radius.S)
	local base = b.BackgroundColor3
	b.MouseEnter:Connect(function()
		Theme.tween(b, Theme.Motion.Fast, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.1) })
	end)
	b.MouseLeave:Connect(function()
		Theme.tween(b, Theme.Motion.Fast, { BackgroundColor3 = base })
	end)
	return b
end

-- Hairline outline over a CanvasGroup (a stroke inside it would be clipped).
local function outline(card: GuiObject, radius: UDim)
	local o = new("Frame", {
		Name = "Outline",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -2, 1, -2),
		BackgroundTransparency = 1,
		ZIndex = 5,
	}, card)
	Theme.corner(o, radius)
	new("UIStroke", { Color = Theme.Colors.Border, Transparency = 0.3, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end

local function timerLine(card: Instance, color: Color3): Frame
	return new("Frame", {
		Name = "Timer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, card)
end

local function animated(): boolean
	return Theme.Animations and not Theme.ReducedMotion
end

-- Runs a countdown on a timer line; returns controls { Paused, Stop }.
local function countdown(timer: Frame, duration: number, onDone: () -> (), onTick: ((number) -> ())?)
	local state = { Paused = false, Stopped = false }
	task.spawn(function()
		local remaining = duration
		while not state.Stopped and timer.Parent do
			local dt = task.wait()
			if not state.Paused then
				remaining -= dt
				timer.Size = UDim2.new(math.clamp(remaining / duration, 0, 1), 0, 0, 3)
				if onTick then
					onTick(remaining)
				end
				if remaining <= 0 then
					state.Stopped = true
					onDone()
				end
			end
		end
	end)
	return state
end

local function colorOf(payload: any): Color3
	if typeof(payload.Color) == "Color3" then
		return payload.Color
	end
	return Theme.Colors.Accent
end

-- Normalises old (text, color) calls into a payload.
local function normalise(a: any, b: any): any
	if type(a) == "table" then
		return a
	end
	return {
		Kind = "announcement",
		Text = tostring(a or ""),
		Color = if typeof(b) == "Color3" then b else nil,
		Style = "banner",
		Duration = 6,
		Scope = "server",
		Author = nil,
	}
end

-- ---------------------------------------------------------------------------
-- Banner (style = banner)
-- ---------------------------------------------------------------------------
local function playBanner(payload: any)
	local root = gui
	if not root then
		return
	end
	local accent = colorOf(payload)
	local author = if type(payload.Author) == "table" then payload.Author else nil
	local width = math.min(560, screenWidth() - 24)
	local shownY = topInset() + 10

	local card = new("CanvasGroup", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, shownY - 24),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.Surface,
		BackgroundTransparency = 0.03,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		ZIndex = 10,
	}, root)
	Theme.corner(card, Theme.Radius.L)
	outline(card, Theme.Radius.L)
	new("Frame", { Name = "AccentBar", Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = accent, BorderSizePixel = 0, ZIndex = 3 }, card)

	local body = new("Frame", { Name = "Body", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	pad(body, 12, 44, 16, 16)
	list(body, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 12) })
	avatar(body, if author then author.UserId else nil, 46, accent, 1)

	local column = new("Frame", { Name = "Content", LayoutOrder = 2, Size = UDim2.new(1, -58, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, body)
	list(column, { Padding = UDim.new(0, 3) })
	local header = new("Frame", { Name = "Header", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1 }, column)
	list(header, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 7) })
	new("TextLabel", {
		Name = "DisplayName",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Font.Bold,
		TextSize = 16,
		TextColor3 = Theme.Colors.Text,
		Text = if author then author.DisplayName else "Sentinel",
	}, header)
	if author and author.Name and author.Name ~= author.DisplayName then
		new("TextLabel", {
			Name = "Username",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Theme.Font.Regular,
			TextSize = 13,
			TextColor3 = Theme.Colors.TextSecondary,
			Text = "@" .. author.Name,
		}, header)
	end
	chip(header, "Scope", SCOPE_LABEL[payload.Scope] or "Announcement", accent, 3)

	if type(payload.Title) == "string" and payload.Title ~= "" then
		text(column, "Title", payload.Title:upper(), 12, Theme.Font.Black, accent, 2)
	end
	text(column, "Message", tostring(payload.Text or ""), 15, Theme.Font.Medium, Theme.Colors.Text, 3)

	local close = iconButton(card, "CloseButton", 26)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 10)
	close.ZIndex = 6
	local timer = timerLine(card, accent)

	local finished = false
	local done = Instance.new("BindableEvent")
	local function dismiss()
		if finished then
			return
		end
		finished = true
		if animated() then
			local tween = TweenService:Create(card, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				GroupTransparency = 1,
				Position = UDim2.new(0.5, 0, 0, shownY - 20),
			})
			tween:Play()
			tween.Completed:Wait()
		end
		card:Destroy()
		done:Fire()
	end
	close.MouseButton1Click:Connect(dismiss)

	if animated() then
		TweenService:Create(card, TweenInfo.new(0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			GroupTransparency = 0,
			Position = UDim2.new(0.5, 0, 0, shownY),
		}):Play()
	else
		card.GroupTransparency = 0
		card.Position = UDim2.new(0.5, 0, 0, shownY)
	end
	local state = countdown(timer, math.clamp(tonumber(payload.Duration) or 8, 3, 60), dismiss)
	card.MouseEnter:Connect(function()
		state.Paused = true
	end)
	card.MouseLeave:Connect(function()
		state.Paused = false
	end)
	if not finished then
		done.Event:Wait()
	end
	done:Destroy()
end

-- ---------------------------------------------------------------------------
-- Full screen (style = full)
-- ---------------------------------------------------------------------------
local function playFull(payload: any)
	local root = gui
	if not root then
		return
	end
	local accent = colorOf(payload)
	local author = if type(payload.Author) == "table" then payload.Author else nil

	local scrim = new("TextButton", {
		Name = "FullAnnouncement",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 20,
	}, root)
	local card = new("CanvasGroup", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(math.min(520, screenWidth() - 32), 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		ZIndex = 21,
	}, scrim)
	Theme.corner(card, Theme.Radius.L)
	outline(card, Theme.Radius.L)
	local body = new("Frame", { Name = "Body", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 21 }, card)
	pad(body, 26, 26, 24, 26)
	list(body, { Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center })

	avatar(body, if author then author.UserId else nil, 76, accent, 1)
	text(body, "Kicker", if type(payload.Title) == "string" and payload.Title ~= "" then payload.Title:upper() else "ANNOUNCEMENT", 13, Theme.Font.Black, accent, 2, { TextXAlignment = Enum.TextXAlignment.Center })
	text(body, "Message", tostring(payload.Text or ""), 20, Theme.Font.Bold, Theme.Colors.Text, 3, { TextXAlignment = Enum.TextXAlignment.Center })
	local who = if author
		then (author.DisplayName .. (if author.Name ~= author.DisplayName then "  @" .. author.Name else ""))
		else "Sentinel"
	text(body, "Author", ("%s  -  %s"):format(who, SCOPE_LABEL[payload.Scope] or "Server"), 13, Theme.Font.Medium, Theme.Colors.TextSecondary, 4, { TextXAlignment = Enum.TextXAlignment.Center })
	local dismissButton = actionButton(body, "DismissButton", "Dismiss", accent, 5, UDim.new(0, 160))
	local timer = timerLine(card, accent)

	local finished = false
	local done = Instance.new("BindableEvent")
	local function dismiss()
		if finished then
			return
		end
		finished = true
		if animated() then
			TweenService:Create(scrim, Theme.Motion.Normal, { BackgroundTransparency = 1 }):Play()
			local tween = TweenService:Create(card, Theme.Motion.Normal, { GroupTransparency = 1, Position = UDim2.fromScale(0.5, 0.54) })
			tween:Play()
			tween.Completed:Wait()
		end
		scrim:Destroy()
		done:Fire()
	end
	dismissButton.MouseButton1Click:Connect(dismiss)

	if animated() then
		TweenService:Create(scrim, Theme.Motion.Normal, { BackgroundTransparency = 0.45 }):Play()
		TweenService:Create(card, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) }):Play()
	else
		scrim.BackgroundTransparency = 0.45
		card.GroupTransparency = 0
		card.Position = UDim2.fromScale(0.5, 0.5)
	end
	countdown(timer, math.clamp(tonumber(payload.Duration) or 8, 3, 60) + 2, dismiss)
	if not finished then
		done.Event:Wait()
	end
	done:Destroy()
end

local function runQueue()
	if bannerBusy then
		return
	end
	bannerBusy = true
	while #bannerQueue > 0 do
		local nextPayload = table.remove(bannerQueue, 1)
		local ok, err = pcall(if nextPayload.Style == "full" then playFull else playBanner, nextPayload)
		if not ok then
			warn("[Sentinel.Announcements] " .. tostring(err))
		end
	end
	bannerBusy = false
end

function AnnouncementBanner.Show(payload: any)
	if type(payload) ~= "table" or type(payload.Text) ~= "string" or payload.Text == "" then
		return
	end
	table.insert(bannerQueue, payload)
	task.spawn(runQueue)
end

-- Small hint pill under the top bar (;hint).
function AnnouncementBanner.ShowHint(value: string)
	local root = gui
	if not root or value == "" then
		return
	end
	local pill = new("CanvasGroup", {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, topInset() + 6),
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.Surface,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		GroupTransparency = if animated() then 1 else 0,
		ZIndex = 9,
	}, root)
	Theme.corner(pill, Theme.Radius.Pill)
	outline(pill, Theme.Radius.Pill)
	pad(pill, 0, 16, 0, 8)
	list(pill, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	local dot = new("Frame", { Name = "Icon", LayoutOrder = 1, Size = UDim2.fromOffset(20, 20), BackgroundColor3 = Theme.Colors.Accent, BorderSizePixel = 0 }, pill)
	Theme.corner(dot, Theme.Radius.Pill)
	new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = Theme.Font.Black, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), Text = "i" }, dot)
	new("TextLabel", {
		Name = "Message",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Font.Medium,
		TextSize = 14,
		TextColor3 = Theme.Colors.Text,
		Text = value:sub(1, 120),
	}, pill)
	if animated() then
		Theme.tween(pill, Theme.Motion.Normal, { GroupTransparency = 0 })
	end
	task.delay(5, function()
		if animated() then
			Theme.tween(pill, Theme.Motion.Normal, { GroupTransparency = 1 })
			task.wait(0.25)
		end
		pill:Destroy()
	end)
end

-- ---------------------------------------------------------------------------
-- Cards (private messages, approvals)
-- ---------------------------------------------------------------------------
local cardOrder = 0
local cardsByKey: { [string]: CanvasGroup } = {}

local function baseCard(key: string, accent: Color3, popup: boolean): (CanvasGroup, Frame, () -> ())
	cardOrder += 1
	local parent = if popup then popupHolder else cardStack
	local holder = new("Frame", {
		Name = key,
		LayoutOrder = cardOrder,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, parent)
	local card = new("CanvasGroup", {
		Name = "Card",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.Surface,
		BackgroundTransparency = 0.02,
		BorderSizePixel = 0,
	}, holder)
	Theme.corner(card, Theme.Radius.M)
	outline(card, Theme.Radius.M)
	new("Frame", { Name = "AccentBar", Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = accent, BorderSizePixel = 0, ZIndex = 3 }, card)
	local body = new("Frame", { Name = "Body", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, card)
	pad(body, 12, 12, 16, 16)
	list(body, { Padding = UDim.new(0, 8) })

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		cardsByKey[key] = nil
		if animated() then
			Theme.tween(card, Theme.Motion.Fast, { GroupTransparency = 1, Position = UDim2.fromOffset(if popup then 0 else 40, 0) })
			task.wait(Theme.Motion.Fast.Time)
		end
		holder:Destroy()
	end
	if animated() then
		card.GroupTransparency = 1
		card.Position = UDim2.fromOffset(if popup then 0 else 60, if popup then 16 else 0)
		TweenService:Create(card, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) }):Play()
	end
	cardsByKey[key] = card
	return card, body, close
end

-- Header: avatar + name + @username + chip, close button on the right.
local function personHeader(body: Frame, person: any?, accent: Color3, chipText: string, fallbackName: string): (Frame, TextButton)
	local header = new("Frame", { Name = "Header", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 }, body)
	local left = new("Frame", { Name = "Who", Size = UDim2.new(1, -34, 1, 0), BackgroundTransparency = 1 }, header)
	list(left, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) })
	avatar(left, if person then person.UserId else nil, 38, accent, 1)
	local names = new("Frame", { Name = "Names", LayoutOrder = 2, Size = UDim2.new(1, -48, 1, 0), BackgroundTransparency = 1 }, left)
	list(names, { VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 1) })
	local top = new("Frame", { Name = "Top", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1 }, names)
	list(top, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	new("TextLabel", {
		Name = "DisplayName",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, 20),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Font.Bold,
		TextSize = 15,
		TextColor3 = Theme.Colors.Text,
		Text = if person then person.DisplayName else fallbackName,
	}, top)
	chip(top, "Kind", chipText, accent, 2)
	new("TextLabel", {
		Name = "Username",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 15),
		Font = Theme.Font.Regular,
		TextSize = 12,
		TextColor3 = Theme.Colors.TextSecondary,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = if person then "@" .. person.Name else "Sentinel staff",
	}, names)
	local closeButton = iconButton(header, "CloseButton", 28)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, 0, 0, 0)
	return header, closeButton
end

local pmRemote: RemoteEvent? = nil
local approvalRemote: RemoteEvent? = nil
local replyStatus: { [string]: TextLabel } = {}

local function showPM(payload: any)
	local level = if LEVEL_COLOR_KEY[payload.Level or ""] then payload.Level else "info"
	local accent = (Theme.Colors :: any)[LEVEL_COLOR_KEY[level]] :: Color3
	local key = ("PM_%s_%s"):format(tostring(payload.Thread), tostring(payload.MessageId))
	local popup = payload.Style == "popup"
	local card, body, close = baseCard(key, accent, popup)
	local _, closeButton = personHeader(body, payload.From, accent, if payload.IsReply then "Reply" else "Private message", "Staff")

	if type(payload.Title) == "string" and payload.Title ~= "" then
		text(body, "Title", payload.Title:upper(), 12, Theme.Font.Black, accent, 2)
	end
	text(body, "Message", tostring(payload.Text or ""), 15, Theme.Font.Regular, Theme.Colors.Text, 3)

	local thread = tostring(payload.Thread)
	local acked = false
	local function ack()
		if payload.NeedsAck and not acked and pmRemote then
			acked = true
			pmRemote:FireServer("ack", thread, payload.MessageId)
		end
	end

	local state: any = nil
	if payload.CanReply then
		local row = new("Frame", { Name = "Reply", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, body)
		local box = new("TextBox", {
			Name = "ReplyBox",
			Size = UDim2.new(1, -78, 1, 0),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Theme.Font.Regular,
			TextSize = 14,
			TextColor3 = Theme.Colors.Text,
			PlaceholderText = "Write a reply...",
			PlaceholderColor3 = Theme.Colors.TextSecondary,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClipsDescendants = true,
			Text = "",
		}, row) :: TextBox
		Theme.corner(box, Theme.Radius.S)
		pad(box, 0, 10, 0, 10)
		local send = actionButton(row, "SendButton", "Send", accent, 1, UDim.new(0, 70))
		send.AnchorPoint = Vector2.new(1, 0)
		send.Position = UDim2.new(1, 0, 0, 0)
		local status = text(body, "Status", "", 12, Theme.Font.Medium, Theme.Colors.TextSecondary, 5, { Visible = false })
		local function submit()
			local value = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
			if value == "" or not pmRemote then
				return
			end
			replyStatus[thread] = status -- the answer goes to the card you typed in
			pmRemote:FireServer("reply", thread, value:sub(1, 300))
			box.Text = ""
			status.Visible = true
			status.TextColor3 = Theme.Colors.TextSecondary
			status.Text = "Sending..."
			ack()
		end
		send.MouseButton1Click:Connect(submit)
		box.FocusLost:Connect(function(enter)
			if enter then
				submit()
			end
			if state then
				state.Paused = false
			end
		end)
		box.Focused:Connect(function()
			if state then
				state.Paused = true
			end
		end)
	end

	local buttons = new("Frame", { Name = "Buttons", LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, body)
	list(buttons, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 8) })
	local gotIt = actionButton(buttons, "GotItButton", if payload.NeedsAck then "Got it (mark as read)" else "Got it", nil, 1, UDim.new(if payload.NeedsAck then 0.6 else 0.4, 0))
	gotIt.MouseButton1Click:Connect(function()
		ack()
		close()
	end)
	closeButton.MouseButton1Click:Connect(close)

	local duration = tonumber(payload.Duration) or 0
	if duration > 0 then
		local timer = timerLine(card, accent)
		state = countdown(timer, duration, close)
	end
end

local function showApproval(payload: any)
	if type(payload) ~= "table" or type(payload.Id) ~= "string" then
		return
	end
	local key = "Approval_" .. payload.Id
	if cardsByKey[key] then
		return
	end
	local accent = Theme.Colors.Warning
	local card, body, close = baseCard(key, accent, false)
	local requester = payload.Requester
	local _, closeButton = personHeader(body, requester, accent, if payload.Test then "Test request" else "Approval needed", "Staff")
	text(body, "Explain", ("%s%s wants to run a %s-risk command:"):format(
		if requester then requester.DisplayName else "A staff member",
		if requester and requester.Rank then (" (" .. requester.Rank .. ")") else "",
		tostring(payload.Risk or "high")
	), 13, Theme.Font.Medium, Theme.Colors.TextSecondary, 2)
	local commandBox = new("Frame", { Name = "Command", LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Colors.Background, BorderSizePixel = 0 }, body)
	Theme.corner(commandBox, Theme.Radius.S)
	pad(commandBox, 8, 10, 8, 10)
	text(commandBox, "Text", ";" .. tostring(payload.Text or payload.Command), 14, Theme.Font.Mono, Theme.Colors.Text, 1)

	local buttons = new("Frame", { Name = "Buttons", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, body)
	list(buttons, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8) })
	local deny = actionButton(buttons, "DenyButton", "Deny", nil, 1)
	local approve = actionButton(buttons, "ApproveButton", "Approve", Theme.Colors.Success, 2)
	local footer = text(body, "Footer", "", 12, Theme.Font.Regular, Theme.Colors.TextSecondary, 5)

	local function answer(action: string)
		if approvalRemote then
			approvalRemote:FireServer(action, payload.Id)
		end
		close()
	end
	approve.MouseButton1Click:Connect(function()
		answer("approve")
	end)
	deny.MouseButton1Click:Connect(function()
		answer("deny")
	end)
	-- Closing without answering leaves the request pending (;approve / ;deny still work).
	closeButton.MouseButton1Click:Connect(close)

	local timeout = tonumber(payload.Timeout) or 60
	local left = math.max(1, (tonumber(payload.Expires) or (os.time() + timeout)) - os.time())
	local timer = timerLine(card, accent)
	timer.Size = UDim2.new(math.clamp(left / timeout, 0, 1), 0, 0, 3)
	countdown(timer, left, close, function(remaining)
		footer.Text = ("Denied automatically in %ds  -  or ;approve %s / ;deny %s"):format(math.max(0, math.ceil(remaining)), payload.Id, payload.Id)
	end)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function AnnouncementBanner.Init()
	if gui then
		return
	end
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local screen = new("ScreenGui", {
		Name = "SentinelAnnouncements",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 110, -- above the panel (50) and toasts (60)
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	gui = screen

	local stack = new("Frame", {
		Name = "Cards",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, topInset() + 10),
		Size = UDim2.new(0, 340, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 30, -- above a full-screen announcement's backdrop (20)
	}, screen)
	list(stack, { Padding = UDim.new(0, 8) })
	cardStack = stack
	local popups = new("Frame", {
		Name = "Popups",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.new(0, 400, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 30,
	}, screen)
	list(popups, { Padding = UDim.new(0, 8) })
	popupHolder = popups

	local function fit()
		local w = screen.AbsoluteSize.X
		stack.Size = UDim2.new(0, math.min(340, w - 24), 0, 0)
		stack.Position = UDim2.new(1, if w < 400 then -12 else -16, 0, topInset() + 10)
		popups.Size = UDim2.new(0, math.min(400, w - 24), 0, 0)
	end
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()

	task.spawn(function()
		local announceRemote = SentinelShared:WaitForChild("AnnounceRemote", 30)
		if announceRemote and announceRemote:IsA("RemoteEvent") then
			announceRemote.OnClientEvent:Connect(function(a: any, b: any)
				AnnouncementBanner.Show(normalise(a, b))
			end)
		end
	end)
	task.spawn(function()
		local remote = SentinelShared:WaitForChild("PrivateMessageRemote", 30)
		if remote and remote:IsA("RemoteEvent") then
			pmRemote = remote
			remote.OnClientEvent:Connect(function(payload: any)
				if type(payload) ~= "table" then
					return
				end
				if payload.Kind == "pm" then
					showPM(payload)
				elseif payload.Kind == "replyResult" then
					local status = replyStatus[tostring(payload.Thread)]
					if status and status.Parent then
						status.Visible = true
						status.TextColor3 = if payload.Success then Theme.Colors.Success else Theme.Colors.Error
						status.Text = tostring(payload.Message or "")
					end
				end
			end)
		end
	end)
	task.spawn(function()
		local remote = SentinelShared:WaitForChild("ApprovalRemote", 30)
		if remote and remote:IsA("RemoteEvent") then
			approvalRemote = remote
			remote.OnClientEvent:Connect(function(action: any, a: any, _b: any)
				if action == "request" then
					showApproval(a)
				elseif action == "closed" and type(a) == "string" then
					local card = cardsByKey["Approval_" .. a]
					if card and card.Parent then
						card.Parent:Destroy()
						cardsByKey["Approval_" .. a] = nil
					end
				end
			end)
		end
	end)
end

return AnnouncementBanner
