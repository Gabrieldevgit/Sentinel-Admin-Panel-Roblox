--!strict
--[[
	NotificationCenter.lua

	Purpose:
		Phase 7D from the roadmap: toast popups + a persistent log panel.
		Replaces the placeholder feedback channel noted in
		`init.server.lua`'s chat hook ("Placeholder feedback channel;
		Phase 7 UI replaces this with a proper notification system.") —
		that hook now fires the same `CommandResultRemote` the UI already
		used, so this single module covers feedback for BOTH chat-typed
		and UI-issued commands.

	Design notes:
		- Reuses the shape of the old Admin Panel V4.3's toast system
		  (`reference/OldAdminPanel/extracted_source_fragments.txt`,
		  `showNotification`) as a starting point — slide-in-from-the-
		  right, dismiss button, theme-colored border — but stacks
		  multiple toasts at once instead of a strict one-at-a-time
		  queue, and pulls colors/fonts from `Theme.lua` instead of the
		  old panel's own `Config.THEMES` table.
		- The toast overlay is its own top-level ScreenGui, independent of
		  Shell's — so a toast still shows even if the player has closed
		  the main panel (F6) after firing a command, matching how the
		  old panel's notifications worked.
		- Only `CommandResultRemote` feeds this — there's no separate
		  server-side alert/event stream for things like "another admin
		  changed server state," so the persistent log is honestly scoped
		  to "results of commands that ran because of something this
		  client did" (via chat OR the UI), not a general activity feed.
		  That's a real, current backend limitation, not a UI oversight.
		- History is an in-memory ring buffer (last 100), since nothing
		  server-side persists it either — it resets on rejoin, same as
		  the old panel's in-session-only toasts.

	Dependencies:
		Theme.lua

	Public API:
		NotificationCenter.Init(): () -- mounts the toast overlay + starts
			listening to CommandResultRemote. Call once.
		NotificationCenter.BuildPage(container: Frame): () -- builds the
			persistent log page. Call once, after Init().
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent:WaitForChild("Theme"))
local SoundPlayer = require(script.Parent:WaitForChild("SoundPlayer"))

local NotificationCenter = {}

type HistoryEntry = {
	Timestamp: number,
	Success: boolean,
	Message: string,
	Title: string?,
}

-- Notify() options. Kind picks the icon colour: info (accent), success,
-- warning, error.
export type Chip = { Text: string, Color: Color3? }
export type NotifyOptions = {
	Kind: string?,
	Title: string?,
	Message: string,
	RichText: boolean?,
	Chips: { Chip }?,
	Action: { Text: string, Callback: () -> () }?,
	Duration: number?,
	Record: boolean?, -- keep in the Notifications page (default true)
	Sound: boolean?, -- false = no sound effect (default: the kind's sound)
}

local MAX_HISTORY = 100
local TOAST_WIDTH = 320
local SUCCESS_DURATION = 4
local ERROR_DURATION = 6
local INFO_DURATION = 10

local history: { HistoryEntry } = {}
local historyChanged: (() -> ())? = nil
local initialized = false

-- Client-only prefs, set from the Settings page (Phase 7E).
local mutedToasts = false
local reducedMotion = false

-- W08 notification preferences (UIPrefs "Notifications", personal or the
-- Owner's server default): toasts on/off, sound, duration, corner.
local toastDuration: number? = nil
local toastPosition = "BottomRight"
local toastStack: Frame? = nil

local function placeStack()
	local stack = toastStack
	if not stack then
		return
	end
	local right = toastPosition:find("Right") ~= nil
	local bottom = toastPosition:find("Bottom") ~= nil
	stack.AnchorPoint = Vector2.new(if right then 1 else 0, if bottom then 1 else 0)
	-- Top corners sit below Roblox's top bar (this gui ignores the inset).
	stack.Position = UDim2.new(if right then 1 else 0, if right then -16 else 16, if bottom then 1 else 0, if bottom then -16 else 70)
	local layout = stack:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.VerticalAlignment = if bottom then Enum.VerticalAlignment.Bottom else Enum.VerticalAlignment.Top
	end
end

function NotificationCenter.ApplyPrefs(prefs: any)
	if type(prefs) ~= "table" then
		return
	end
	if type(prefs.Toasts) == "boolean" then
		mutedToasts = not prefs.Toasts
	end
	toastDuration = if type(prefs.Duration) == "number" then math.clamp(prefs.Duration, 1, 30) else nil
	if type(prefs.Position) == "string" then
		toastPosition = prefs.Position
	end
	placeStack()
end

function NotificationCenter.SetMuted(muted: boolean)
	mutedToasts = muted
end

function NotificationCenter.IsMuted(): boolean
	return mutedToasts
end

function NotificationCenter.SetReducedMotion(reduced: boolean)
	reducedMotion = reduced
end

function NotificationCenter.IsReducedMotion(): boolean
	return reducedMotion
end

local notifyExternal: ((NotifyOptions) -> ())? = nil

-- Shows a card (Roblox-style notification) and records it. Safe to call
-- before Init (it does nothing then).
function NotificationCenter.Notify(options: NotifyOptions)
	if notifyExternal and type(options) == "table" and type(options.Message) == "string" and options.Message ~= "" then
		notifyExternal(options)
	end
end

-- Command-result style notification (kept for older callers).
function NotificationCenter.Push(success: boolean, message: string)
	if type(message) == "string" then
		NotificationCenter.Notify({ Kind = if success then "success" else "error", Message = message:sub(1, 300) })
	end
end

function NotificationCenter.IsReady(): boolean
	return initialized
end

local function pushHistory(entry: HistoryEntry)
	table.insert(history, entry)
	if #history > MAX_HISTORY then
		table.remove(history, 1)
	end
	if historyChanged then
		historyChanged()
	end
end

-- ---------------------------------------------------------------------------
-- Notification card (matches Roblox's own in-experience notifications):
--   [icon] Title                      [pause] [X]
--   Message text (rich text allowed)
--   (o Chip) (o Chip)                 optional
--   [        (i) Action button        ] optional
--   ------------- timer line ---------
-- Instance paths: SentinelNotifications.ToastStack.Toast_<n>.Notification
--   .Body.{Header.Controls.{PauseButton, CloseButton}, Message, Chips,
--   ActionButton}
-- ---------------------------------------------------------------------------
local KIND_TITLES = { info = "Info", success = "Success", warning = "Warning", error = "Error" }
local KIND_GLYPHS = { info = "i", success = "\u{2713}", warning = "!", error = "!" }

local function kindColor(kind: string): Color3
	if kind == "success" then
		return Theme.Colors.Success
	elseif kind == "warning" then
		return Theme.Colors.Warning
	elseif kind == "error" then
		return Theme.Colors.Error
	end
	return Theme.Colors.Accent
end

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		(inst :: any)[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- Small round badge with a glyph ("i", check, "!").
local function badge(parent: Instance, kind: string, size: number, order: number?): Frame
	local circle = new("Frame", {
		Name = "Icon",
		LayoutOrder = order or 0,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = kindColor(kind),
		BorderSizePixel = 0,
	}, parent)
	Theme.corner(circle, Theme.Radius.Pill)
	new("TextLabel", {
		Name = "Glyph",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.Font.Black,
		TextSize = math.floor(size * 0.72),
		TextColor3 = Color3.new(1, 1, 1),
		Text = KIND_GLYPHS[kind] or "i",
	}, circle)
	return circle
end

-- Round, borderless icon button that lights up on hover.
local function headerButton(parent: Instance, name: string, order: number): TextButton
	local button = new("TextButton", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Text = "",
	}, parent)
	Theme.corner(button, Theme.Radius.Pill)
	button.MouseEnter:Connect(function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 0 })
	end)
	button.MouseLeave:Connect(function()
		Theme.tween(button, Theme.Motion.Fast, { BackgroundTransparency = 1 })
	end)
	return button
end

-- Builds one card (not yet animated). Returns the card, its pause / close
-- buttons, the timer line and the pause glyph bars.
local function buildCard(options: NotifyOptions, kind: string): (CanvasGroup, TextButton, TextButton, Frame, { Frame })
	local card = new("CanvasGroup", {
		Name = "Notification",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.Surface,
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
	})
	Theme.corner(card, Theme.Radius.M)

	local body = new("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, card)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 14),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 10),
	}, body)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, body)

	-- Header: icon + title, pause + close on the right.
	local header = new("Frame", { Name = "Header", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1 }, body)
	local titleGroup = new("Frame", { Name = "TitleGroup", Size = UDim2.new(1, -64, 1, 0), BackgroundTransparency = 1 }, header)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, titleGroup)
	badge(titleGroup, kind, 18, 1)
	new("TextLabel", {
		Name = "Title",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -26, 1, 0),
		Font = Theme.Font.Bold,
		TextSize = 17,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = options.Title or KIND_TITLES[kind] or "Info",
	}, titleGroup)

	local controls = new("Frame", {
		Name = "Controls",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(58, 26),
		BackgroundTransparency = 1,
	}, header)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, controls)
	local pauseButton = headerButton(controls, "PauseButton", 1)
	local pauseBars = {}
	for i = 0, 1 do
		local bar = new("Frame", {
			Name = "Bar",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, if i == 0 then -3 else 3, 0.5, 0),
			Size = UDim2.fromOffset(3, 12),
			BackgroundColor3 = Theme.Colors.TextSecondary,
			BorderSizePixel = 0,
		}, pauseButton)
		Theme.corner(bar, UDim.new(0, 1))
		table.insert(pauseBars, bar)
	end
	local closeButton = headerButton(controls, "CloseButton", 2)
	Theme.crossIcon(closeButton, 11, Theme.Colors.TextSecondary, 2)

	-- Message.
	new("TextLabel", {
		Name = "Message",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -4, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.Font.Regular,
		TextSize = 15,
		TextColor3 = Theme.Colors.Text,
		TextWrapped = true,
		RichText = options.RichText == true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = options.Message,
	}, body)

	-- Chips (e.g. the player's roles).
	if options.Chips and #options.Chips > 0 then
		local chipRow = new("Frame", {
			Name = "Chips",
			LayoutOrder = 3,
			Size = UDim2.new(1, -4, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, body)
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, chipRow)
		for i, chip in ipairs(options.Chips) do
			local pill = new("Frame", {
				Name = "Chip_" .. tostring(chip.Text),
				LayoutOrder = i,
				Size = UDim2.fromOffset(0, 28),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = Theme.Colors.SurfaceRaised,
				BorderSizePixel = 0,
			}, chipRow)
			Theme.corner(pill, Theme.Radius.Pill)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12) }, pill)
			new("UIListLayout", {
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 7),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}, pill)
			local dot = new("Frame", {
				Name = "Dot",
				LayoutOrder = 1,
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = chip.Color or Theme.Colors.TextSecondary,
				BorderSizePixel = 0,
			}, pill)
			Theme.corner(dot, Theme.Radius.Pill)
			new("TextLabel", {
				Name = "Label",
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(0, 28),
				AutomaticSize = Enum.AutomaticSize.X,
				Font = Theme.Font.Medium,
				TextSize = 14,
				TextColor3 = Theme.Colors.Text,
				Text = tostring(chip.Text),
			}, pill)
		end
	end

	-- Action button (full width, icon + label).
	local action = options.Action
	if action then
		local actionButton = new("TextButton", {
			Name = "ActionButton",
			LayoutOrder = 4,
			Size = UDim2.new(1, -4, 0, 34),
			BackgroundColor3 = Theme.Colors.SurfaceRaised,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Text = "",
		}, body)
		Theme.corner(actionButton, Theme.Radius.S)
		local content = new("Frame", {
			Name = "Content",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(0, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
		}, actionButton)
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, content)
		badge(content, "info", 16, 1)
		new("TextLabel", {
			Name = "Label",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = Theme.Font.Bold,
			TextSize = 15,
			TextColor3 = Theme.Colors.Text,
			Text = action.Text,
		}, content)
		local hoverColor = Theme.Colors.SurfaceRaised:Lerp(Theme.Colors.Text, 0.08)
		actionButton.MouseEnter:Connect(function()
			Theme.tween(actionButton, Theme.Motion.Fast, { BackgroundColor3 = hoverColor })
		end)
		actionButton.MouseLeave:Connect(function()
			Theme.tween(actionButton, Theme.Motion.Fast, { BackgroundColor3 = Theme.Colors.SurfaceRaised })
		end)
		actionButton.MouseButton1Click:Connect(function()
			task.spawn(action.Callback)
		end)
	end

	-- Timer line along the bottom edge.
	local timer = new("Frame", {
		Name = "Timer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 2),
		BackgroundColor3 = kindColor(kind),
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, card)

	return card, pauseButton, closeButton, timer, pauseBars
end

-- ---------------------------------------------------------------------------
-- Toast overlay
-- ---------------------------------------------------------------------------
function NotificationCenter.Init()
	if initialized then
		return
	end
	initialized = true

	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelNotifications"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 60 -- above Shell (50), so toasts show even while the panel is closed
	screenGui.Parent = playerGui

	local stack = Instance.new("Frame")
	stack.Name = "ToastStack"
	stack.AnchorPoint = Vector2.new(1, 1)
	stack.Position = UDim2.new(1, -16, 1, -16)
	stack.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.BackgroundTransparency = 1
	stack.Parent = screenGui

	local stackLayout = Instance.new("UIListLayout")
	stackLayout.Padding = UDim.new(0, 8)
	stackLayout.SortOrder = Enum.SortOrder.LayoutOrder
	stackLayout.Parent = stack
	toastStack = stack
	placeStack()

	local toastOrder = 0

	local function showToast(options: NotifyOptions)
		local kind = if KIND_TITLES[options.Kind or ""] then options.Kind :: string else "info"
		toastOrder += 1

		-- The holder keeps the slot in the stack; the card slides inside it.
		local holder = new("Frame", {
			Name = "Toast_" .. toastOrder,
			LayoutOrder = toastOrder,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, stack)
		local card, pauseButton, closeButton, timer, pauseBars = buildCard(options, kind)
		card.Parent = holder
		-- Hairline border so the card stays readable over dark scenes (a
		-- stroke inside the CanvasGroup would be clipped, so it sits on an
		-- overlay frame that follows the card).
		local outline = new("Frame", { Name = "Outline", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -2, 1, -2), BackgroundTransparency = 1, ZIndex = 3 }, card)
		Theme.corner(outline, Theme.Radius.M)
		new("UIStroke", { Color = Theme.Colors.Border, Transparency = 0.35, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, outline)

		local base = if kind == "success" then SUCCESS_DURATION elseif kind == "info" then INFO_DURATION else ERROR_DURATION
		local duration = options.Duration
			or (if toastDuration then (if kind == "success" then toastDuration else toastDuration + 2) else base)
		local remaining = duration
		local paused = false
		local dismissed = false
		local animate = not reducedMotion and Theme.Animations
		local fromRight = toastPosition:find("Right") ~= nil

		local function dismiss()
			if dismissed then
				return
			end
			dismissed = true
			if not animate then
				holder:Destroy()
				return
			end
			Theme.tween(card, Theme.Motion.Fast, {
				GroupTransparency = 1,
				Position = UDim2.fromOffset(if fromRight then 40 else -40, 0),
			})
			task.wait(Theme.Motion.Fast.Time)
			holder:Destroy()
		end

		local function setPaused(value: boolean)
			paused = value
			for _, bar in ipairs(pauseBars) do
				bar.BackgroundColor3 = if paused then Theme.Colors.Accent else Theme.Colors.TextSecondary
			end
			timer.BackgroundTransparency = if paused then 0.7 else 0.3
		end

		closeButton.MouseButton1Click:Connect(dismiss)
		pauseButton.MouseButton1Click:Connect(function()
			setPaused(not paused)
		end)

		if animate then
			card.GroupTransparency = 1
			card.Position = UDim2.fromOffset(if fromRight then 60 else -60, 0)
			TweenService:Create(card, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
				GroupTransparency = 0,
				Position = UDim2.fromOffset(0, 0),
			}):Play()
		end

		if options.Sound ~= false then
			SoundPlayer.Play(kind)
		end
		task.spawn(function()
			while not dismissed and holder.Parent do
				local dt = task.wait()
				if not paused then
					remaining -= dt
					timer.Size = UDim2.new(math.clamp(remaining / duration, 0, 1), 0, 0, 2)
					if remaining <= 0 then
						dismiss()
					end
				end
			end
		end)
	end

	-- Other UI modules (Cross-Server page, the join welcome) raise cards
	-- through NotificationCenter.Notify / Push.
	notifyExternal = function(options: NotifyOptions)
		if not mutedToasts then
			showToast(options)
		end
		if options.Record ~= false then
			local plain = if options.RichText then (options.Message:gsub("<[^>]->", "")) else options.Message
			pushHistory({
				Timestamp = os.time(),
				Success = options.Kind ~= "error",
				Message = plain,
				Title = options.Title,
			})
		end
	end

	local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local commandResultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	if commandResultRemote then
		commandResultRemote.OnClientEvent:Connect(function(results: { any })
			for _, result in ipairs(results) do
				if result.Message and result.Message ~= "" then
					-- The persistent log always gets every result — mute
					-- only suppresses the popup, not the record of it.
					-- Pending confirmations get the ConfirmDialog instead of a
					-- red "Failed" toast (they haven't failed, they're waiting).
					local success = result.Success == true
					if result.NeedsConfirmation then
						SoundPlayer.Play("Warning")
					end
					if not mutedToasts and not result.NeedsConfirmation then
						-- Pending = held for the Owner's approval (ApprovalService): not a failure.
						showToast({
							Kind = if success then "success" elseif result.Pending then "warning" else "error",
							Title = if result.Pending then "Waiting for approval" else nil,
							Message = tostring(result.Message),
						})
					end
					pushHistory({
						Timestamp = os.time(),
						Success = success,
						Message = result.Message,
					})
				end
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Persistent log page
-- ---------------------------------------------------------------------------
function NotificationCenter.BuildPage(container: Frame)
	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.Font = Theme.Font.Bold
	header.TextSize = 20
	header.TextColor3 = Theme.Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "Notifications"
	header.Parent = container

	local subHeader = Instance.new("TextLabel")
	subHeader.BackgroundTransparency = 1
	subHeader.Position = UDim2.new(0, 0, 0, 30)
	subHeader.Size = UDim2.new(1, -90, 0, 20)
	subHeader.Font = Theme.Font.Regular
	subHeader.TextSize = 12
	subHeader.TextColor3 = Theme.Colors.TextSecondary
	subHeader.TextXAlignment = Enum.TextXAlignment.Left
	subHeader.Text = "Results of commands run this session, via chat or this panel. Resets on rejoin."
	subHeader.Parent = container

	local clearButton = Instance.new("TextButton")
	clearButton.AnchorPoint = Vector2.new(1, 0)
	clearButton.Position = UDim2.new(1, 0, 0, 4)
	clearButton.Size = UDim2.new(0, 80, 0, 24)
	clearButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	clearButton.Font = Theme.Font.Medium
	clearButton.TextSize = 12
	clearButton.TextColor3 = Theme.Colors.TextSecondary
	clearButton.Text = "Clear"
	clearButton.Parent = container
	Theme.corner(clearButton, Theme.Radius.S)

	local listFrame = Instance.new("ScrollingFrame")
	listFrame.Name = "List"
	listFrame.Position = UDim2.new(0, 0, 0, 58)
	listFrame.Size = UDim2.new(1, 0, 1, -58)
	listFrame.BackgroundColor3 = Theme.Colors.Surface
	listFrame.BorderSizePixel = 0
	listFrame.ScrollBarThickness = 4
	listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	listFrame.Parent = container
	Theme.corner(listFrame, Theme.Radius.M)
	Theme.padding(listFrame, Theme.Spacing.S)

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = listFrame

	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.Name = "EmptyState"
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Size = UDim2.new(1, 0, 0, 40)
	emptyLabel.Font = Theme.Font.Regular
	emptyLabel.TextSize = 13
	emptyLabel.TextColor3 = Theme.Colors.TextSecondary
	emptyLabel.Text = "No notifications yet this session."
	emptyLabel.Visible = false
	emptyLabel.Parent = listFrame

	local function render()
		for _, child in ipairs(listFrame:GetChildren()) do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		if #history == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- Most recent first.
		for i = #history, 1, -1 do
			local entry = history[i]
			local row = Instance.new("Frame")
			row.LayoutOrder = #history - i
			row.Size = UDim2.new(1, 0, 0, 36)
			row.BackgroundColor3 = Theme.Colors.SurfaceRaised
			row.BorderSizePixel = 0
			row.Parent = listFrame
			Theme.corner(row, Theme.Radius.S)

			local sideBar = Instance.new("Frame")
			sideBar.BorderSizePixel = 0
			sideBar.Size = UDim2.new(0, 3, 1, 0)
			sideBar.BackgroundColor3 = if entry.Success then Theme.Colors.Success else Theme.Colors.Error
			sideBar.Parent = row
			Theme.corner(sideBar, UDim.new(0, 2))

			local timeText = os.date("%H:%M:%S", entry.Timestamp)
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Position = UDim2.new(0, 12, 0, 2)
			label.Size = UDim2.new(1, -24, 1, -4)
			label.Font = Theme.Font.Regular
			label.TextSize = 13
			label.TextColor3 = Theme.Colors.Text
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextWrapped = true
			label.Text = ("[%s] %s"):format(tostring(timeText), entry.Message)
			label.Parent = row
		end
	end

	historyChanged = render
	clearButton.MouseButton1Click:Connect(function()
		table.clear(history)
		render()
	end)

	render()
end

return NotificationCenter
