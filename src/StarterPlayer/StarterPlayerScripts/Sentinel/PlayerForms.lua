--!strict
--[[
	PlayerForms.lua (W14)

	Player-facing forms, built for EVERY player (staff or not):
		- Report form   (;report, or PlayerForms.OpenReport(targetId?))
		- Appeal form   (;appeal)
		- Ban screen    (a banned player is held on it before the kick)
		- Notices       (appeal decisions, report confirmations)

	Self-contained on purpose: a banned player never spawns, so StarterGui
	(SentinelUI, Theme) is never copied to their PlayerGui. This module
	lives next to init.client in StarterPlayerScripts and only needs
	ReplicatedStorage.Shared.Sentinel (Icons, remotes).

	Server side: Systems/PlayerFormsService (PlayerFormsRemote /
	PlayerFormsEvent).

	Instance paths (ScreenGui "SentinelForms"):
		Modal.Card.{Header.{Title,Close}, Body, Footer.{Send,Cancel}, Status}
		Report: Body.PlayerList.Player_<UserId>, Body.Categories.Cat_<name>,
		        Body.Description, Body.Evidence
		Appeal: Body.Items.Item_<n>, Body.AppealText
		BanScreen.Card.{Title, Reason, Countdown, AppealText, Send, Status}
		Notices.Notice_<n>
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Icons = require(SentinelShared:WaitForChild("Icons"))

local PlayerForms = {}

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local formsRemote: RemoteFunction? = nil
local formsEvent: RemoteEvent? = nil

-- Roblox-style dark palette (matches the panel's default "Roblox" theme).
local C = {
	Backdrop = Color3.fromRGB(0, 0, 0),
	Card = Color3.fromRGB(25, 27, 29),
	Raised = Color3.fromRGB(39, 41, 44),
	Field = Color3.fromRGB(18, 19, 21),
	Border = Color3.fromRGB(57, 59, 63),
	Text = Color3.fromRGB(240, 241, 242),
	Muted = Color3.fromRGB(163, 166, 171),
	Accent = Color3.fromRGB(51, 95, 255),
	Success = Color3.fromRGB(46, 184, 108),
	Warning = Color3.fromRGB(245, 166, 35),
	Error = Color3.fromRGB(232, 72, 72),
}
local FONT = Enum.Font.BuilderSans
local FONT_BOLD = Enum.Font.BuilderSansBold
local FONT_MED = Enum.Font.BuilderSansMedium

local gui: ScreenGui
local noticeStack: Frame
local noticeCount = 0
local currentModal: Frame? = nil

-- ---------------------------------------------------------------------------
-- Small UI helpers
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

local function corner(inst: Instance, r: number)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, inst)
end

local function stroke(inst: Instance, color: Color3?)
	new("UIStroke", { Color = color or C.Border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, inst)
end

local function pad(inst: Instance, p: number)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, p),
		PaddingRight = UDim.new(0, p),
		PaddingTop = UDim.new(0, p),
		PaddingBottom = UDim.new(0, p),
	}, inst)
end

local function list(inst: Instance, gap: number, horizontal: boolean?)
	return new("UIListLayout", {
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
	}, inst)
end

local function text(parent: Instance, name: string, value: string, size: number, color: Color3?, font: Enum.Font?, order: number?): TextLabel
	return new("TextLabel", {
		Name = name,
		LayoutOrder = order or 0,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = font or FONT,
		TextSize = size,
		TextColor3 = color or C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		RichText = false,
		Text = value,
	}, parent)
end

local function button(parent: Instance, name: string, label: string, primary: boolean?, order: number?): TextButton
	local b = new("TextButton", {
		Name = name,
		LayoutOrder = order or 0,
		AutoButtonColor = true,
		BackgroundColor3 = if primary then C.Accent else C.Raised,
		Size = UDim2.new(0, 0, 0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = FONT_BOLD,
		TextSize = 15,
		TextColor3 = C.Text,
		Text = label,
	}, parent)
	corner(b, 8)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, b)
	return b
end

local function field(parent: Instance, name: string, placeholder: string, height: number, multiline: boolean, maxLen: number, order: number?): TextBox
	local box = new("TextBox", {
		Name = name,
		LayoutOrder = order or 0,
		BackgroundColor3 = C.Field,
		Size = UDim2.new(1, 0, 0, height),
		Font = FONT,
		TextSize = 15,
		TextColor3 = C.Text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.Muted,
		Text = "",
		ClearTextOnFocus = false,
		MultiLine = multiline,
		TextWrapped = multiline,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if multiline then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
	}, parent)
	corner(box, 8)
	stroke(box)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, box)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > maxLen then
			box.Text = box.Text:sub(1, maxLen)
		end
	end)
	return box
end

local function viewport(): Vector2
	return gui.AbsoluteSize
end

local function call(action: string, data: any?): any
	if not formsRemote then
		return { Ok = false, Message = "Not connected yet - try again in a moment." }
	end
	local ok, result = pcall(function()
		return (formsRemote :: RemoteFunction):InvokeServer(action, data)
	end)
	if not ok then
		return { Ok = false, Message = "Could not reach the server." }
	end
	return result
end

local function dateText(t: number?): string
	if not t or t <= 0 then
		return "?"
	end
	return os.date("%b %d, %Y", t) :: string
end

local function expiryText(expiresAt: number?): string
	if not expiresAt or expiresAt == -1 then
		return "Permanent"
	end
	local left = expiresAt - os.time()
	if left <= 0 then
		return "Ending now"
	end
	if left >= 86400 then
		return ("%d day(s) left (until %s)"):format(math.ceil(left / 86400), dateText(expiresAt))
	end
	if left >= 3600 then
		return ("%d hour(s) left"):format(math.ceil(left / 3600))
	end
	return ("%d minute(s) left"):format(math.max(1, math.ceil(left / 60)))
end

-- ---------------------------------------------------------------------------
-- Notices (bottom-right cards)
-- ---------------------------------------------------------------------------
function PlayerForms.Notice(kind: string, title: string, message: string, duration: number?)
	noticeCount += 1
	local color = if kind == "success" then C.Success elseif kind == "error" then C.Error elseif kind == "warning" then C.Warning else C.Accent
	local card = new("Frame", {
		Name = "Notice_" .. noticeCount,
		LayoutOrder = -noticeCount,
		BackgroundColor3 = C.Card,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, noticeStack)
	corner(card, 12)
	stroke(card)
	pad(card, 14)
	list(card, 6)
	local header = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22) }, card)
	new("Frame", { Name = "Dot", BackgroundColor3 = color, Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 0, 0.5, -5) }, header).Name = "Dot"
	corner(header:FindFirstChild("Dot") :: Instance, 5)
	new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -46, 1, 0),
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = title,
	}, header)
	local close = new("TextButton", {
		Name = "Close",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(22, 22),
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = C.Muted,
		Text = "X",
	}, header)
	text(card, "Message", message, 14, C.Muted, FONT, 2)
	local function dismiss()
		if card.Parent then
			card:Destroy()
		end
	end
	close.MouseButton1Click:Connect(dismiss)
	task.delay(duration or 10, dismiss)
end

-- ---------------------------------------------------------------------------
-- Modal shell
-- ---------------------------------------------------------------------------
local function closeModal()
	if currentModal then
		currentModal:Destroy()
		currentModal = nil
	end
end
PlayerForms.Close = closeModal

type Modal = { Root: Frame, Card: Frame, Body: ScrollingFrame, Footer: Frame, Status: TextLabel }

local function openModal(title: string, iconKey: string): Modal
	closeModal()
	local root = new("Frame", {
		Name = "Modal",
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
	}, gui)
	-- Click outside the card = nothing (a half-typed report shouldn't vanish).
	new("TextButton", { Name = "Blocker", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", AutoButtonColor = false, ZIndex = 10 }, root)
	local vp = viewport()
	local width = math.min(520, vp.X - 24)
	local height = math.min(600, vp.Y - 24)
	local card = new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, height),
		BackgroundColor3 = C.Card,
		ZIndex = 11,
	}, root)
	corner(card, 16)
	stroke(card)

	local header = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, -32, 0, 48), Position = UDim2.fromOffset(16, 6), ZIndex = 12 }, card)
	local titleLabel = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -40, 1, 0),
		Font = FONT_BOLD,
		TextSize = 20,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 12,
	}, header)
	Icons.prefix(titleLabel, iconKey, title, 22)
	local close = new("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = C.Raised,
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = C.Muted,
		Text = "X",
		ZIndex = 12,
	}, header)
	corner(close, 16)
	close.MouseButton1Click:Connect(closeModal)

	local body = new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 58),
		Size = UDim2.new(1, -32, 1, -58 - 78),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Border,
		BorderSizePixel = 0,
		ZIndex = 12,
	}, card)
	list(body, 10)
	new("UIPadding", { PaddingRight = UDim.new(0, 6) }, body)

	local status = new("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -58),
		Size = UDim2.new(1, -32, 0, 18),
		Font = FONT_MED,
		TextSize = 14,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
		ZIndex = 12,
	}, card)
	local footer = new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -14),
		Size = UDim2.new(1, -32, 0, 36),
		ZIndex = 12,
	}, card)
	local layout = list(footer, 8, true)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	currentModal = root
	return { Root = root, Card = card, Body = body, Footer = footer, Status = status }
end

local function setStatus(m: Modal, message: string, color: Color3?)
	m.Status.Text = message
	m.Status.TextColor3 = color or C.Muted
end

local function section(body: Instance, label: string, order: number)
	text(body, "Label_" .. order, label, 14, C.Muted, FONT_BOLD, order)
end

local function setZ(root: Instance, z: number)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") and d.ZIndex < z then
			d.ZIndex = z
		end
	end
end

-- ---------------------------------------------------------------------------
-- Report form
-- ---------------------------------------------------------------------------
function PlayerForms.OpenReport(targetId: number?)
	local m = openModal("Report a player", "RiskWarning")
	setStatus(m, "Loading...")
	local info = call("reportInfo")
	if not info or not currentModal or currentModal ~= m.Root then
		return
	end
	if not info.Enabled then
		setStatus(m, "Reports are turned off in this game.", C.Warning)
		return
	end
	setStatus(m, "")
	local selectedId: number? = targetId
	local selectedCat = "Other"

	section(m.Body, "Who are you reporting?", 1)
	local players = new("Frame", { Name = "PlayerList", LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, m.Body)
	local grid = new("UIGridLayout", { CellSize = UDim2.new(0.5, -4, 0, 44), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, players)
	_ = grid
	local playerButtons: { [number]: TextButton } = {}
	local function paintPlayers()
		for id, b in pairs(playerButtons) do
			local on = id == selectedId
			b.BackgroundColor3 = if on then C.Accent else C.Raised
		end
	end
	if #info.Players == 0 then
		text(players, "Empty", "There is nobody else in this server.", 14, C.Muted)
	end
	for i, p in ipairs(info.Players) do
		local b = new("TextButton", {
			Name = "Player_" .. p.UserId,
			LayoutOrder = i,
			BackgroundColor3 = C.Raised,
			AutoButtonColor = true,
			Text = "",
		}, players)
		corner(b, 8)
		local avatar = new("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = C.Field,
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.fromOffset(32, 32),
			Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(p.UserId),
		}, b)
		corner(avatar, 16)
		new("TextLabel", {
			Name = "Name",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(46, 4),
			Size = UDim2.new(1, -52, 0, 18),
			Font = FONT_BOLD,
			TextSize = 14,
			TextColor3 = C.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = p.DisplayName,
		}, b)
		new("TextLabel", {
			Name = "User",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(46, 22),
			Size = UDim2.new(1, -52, 0, 16),
			Font = FONT,
			TextSize = 12,
			TextColor3 = C.Muted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "@" .. p.Name,
		}, b)
		playerButtons[p.UserId] = b
		b.MouseButton1Click:Connect(function()
			selectedId = p.UserId
			paintPlayers()
		end)
	end
	paintPlayers()

	section(m.Body, "What happened?", 3)
	local cats = new("Frame", { Name = "Categories", LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, m.Body)
	local catLayout = list(cats, 6, true)
	catLayout.Wraps = true
	local catButtons: { [string]: TextButton } = {}
	local function paintCats()
		for name, b in pairs(catButtons) do
			b.BackgroundColor3 = if name == selectedCat then C.Accent else C.Raised
		end
	end
	for i, cat in ipairs(info.Categories) do
		local b = new("TextButton", {
			Name = "Cat_" .. cat,
			LayoutOrder = i,
			BackgroundColor3 = C.Raised,
			Size = UDim2.new(0, 0, 0, 30),
			AutomaticSize = Enum.AutomaticSize.X,
			Font = FONT_MED,
			TextSize = 14,
			TextColor3 = C.Text,
			Text = cat,
		}, cats)
		corner(b, 15)
		new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, b)
		catButtons[cat] = b
		b.MouseButton1Click:Connect(function()
			selectedCat = cat
			paintCats()
		end)
	end
	paintCats()

	local desc = field(m.Body, "Description", "Describe what they did (required)", 96, true, 500, 5)
	section(m.Body, "Evidence (optional): a clip link, a time, anything that helps", 6)
	local evidence = field(m.Body, "Evidence", "e.g. youtu.be/... or 'at the shop around 5:10 PM'", 40, false, 200, 7)
	text(m.Body, "Hint", "Their recent chat and position are attached automatically. False reports may be punished.", 12, C.Muted, FONT, 8)

	local send = button(m.Footer, "Send", "Send report", true, 2)
	local cancel = button(m.Footer, "Cancel", "Cancel", false, 1)
	cancel.MouseButton1Click:Connect(closeModal)
	local busy = false
	send.MouseButton1Click:Connect(function()
		if busy then
			return
		end
		if not selectedId then
			setStatus(m, "Pick the player you are reporting.", C.Warning)
			return
		end
		busy = true
		setStatus(m, "Sending...")
		local result = call("submitReport", {
			TargetId = selectedId,
			Category = selectedCat,
			Description = desc.Text,
			Evidence = if evidence.Text:match("%S") then { evidence.Text } else {},
		})
		busy = false
		if result and result.Ok then
			closeModal()
			PlayerForms.Notice("success", "Report sent", result.Message)
		else
			setStatus(m, (result and result.Message) or "The report was not sent.", C.Error)
		end
	end)
	setZ(m.Root, 12)
end

-- ---------------------------------------------------------------------------
-- Appeal list (shared by the appeal form and the ban screen)
-- ---------------------------------------------------------------------------
local TYPE_LABEL = { ban = "Ban", mute = "Mute", jail = "Jail", warn = "Warning" }

local function itemCard(parent: Instance, i: number, item: any, selectable: boolean): TextButton
	local b = new("TextButton", {
		Name = "Item_" .. i,
		LayoutOrder = i,
		BackgroundColor3 = C.Raised,
		AutoButtonColor = selectable and not item.Blocked,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = "",
	}, parent)
	corner(b, 10)
	pad(b, 10)
	list(b, 2)
	local head = ("%s%s"):format(TYPE_LABEL[item.Type] or item.Type, if item.CaseId then ("  ·  case #%d"):format(item.CaseId) else "")
	text(b, "Head", head, 15, C.Text, FONT_BOLD, 1)
	text(b, "Reason", "Reason: " .. tostring(item.Reason or "none given"), 14, C.Text, FONT, 2)
	local meta = ("By %s on %s"):format(tostring(item.By or "staff"), dateText(item.CreatedAt))
	if item.Type ~= "warn" then
		meta ..= "  ·  " .. expiryText(item.ExpiresAt)
	end
	text(b, "Meta", meta, 12, C.Muted, FONT, 3)
	if item.Blocked then
		text(b, "Blocked", item.Blocked, 13, C.Warning, FONT_MED, 4)
	end
	return b
end

function PlayerForms.OpenAppeal()
	local m = openModal("Appeal a punishment", "Moderation")
	setStatus(m, "Loading...")
	local info = call("appealInfo")
	if not info or currentModal ~= m.Root then
		return
	end
	if not info.Enabled then
		setStatus(m, "Appeals are turned off in this game.", C.Warning)
		return
	end
	setStatus(m, "")
	if #info.Items == 0 then
		text(m.Body, "Empty", "You have no punishments that can be appealed. (Warnings can be appealed for 30 days; mutes and jails while they last.)", 15, C.Muted, FONT, 1)
		local ok = button(m.Footer, "Cancel", "Close", false, 1)
		ok.MouseButton1Click:Connect(closeModal)
		setZ(m.Root, 12)
		return
	end
	section(m.Body, "Which punishment?", 1)
	local items = new("Frame", { Name = "Items", LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, m.Body)
	list(items, 6)
	local selected: string? = nil
	local cards: { [string]: TextButton } = {}
	for i, item in ipairs(info.Items) do
		local card = itemCard(items, i, item, true)
		cards[item.Key] = card
		if not item.Blocked then
			selected = selected or item.Key
			card.MouseButton1Click:Connect(function()
				selected = item.Key
				for key, c in pairs(cards) do
					c.BackgroundColor3 = if key == selected then C.Accent else C.Raised
				end
			end)
		end
	end
	if selected then
		cards[selected].BackgroundColor3 = C.Accent
	end
	section(m.Body, "Why should it be lifted?", 3)
	local body = field(m.Body, "AppealText", "Explain honestly what happened and why the punishment should be removed (20+ characters).", 120, true, 1000, 4)
	local send = button(m.Footer, "Send", "Send appeal", true, 2)
	local cancel = button(m.Footer, "Cancel", "Cancel", false, 1)
	cancel.MouseButton1Click:Connect(closeModal)
	if not selected then
		setStatus(m, "Nothing can be appealed right now.", C.Warning)
		send.Visible = false
	end
	local busy = false
	send.MouseButton1Click:Connect(function()
		if busy or not selected then
			return
		end
		busy = true
		setStatus(m, "Sending...")
		local result = call("submitAppeal", { Key = selected, Text = body.Text })
		busy = false
		if result and result.Ok then
			closeModal()
			PlayerForms.Notice("success", "Appeal sent", result.Message, 14)
		else
			setStatus(m, (result and result.Message) or "The appeal was not sent.", C.Error)
		end
	end)
	setZ(m.Root, 12)
end

-- ---------------------------------------------------------------------------
-- Ban screen
-- ---------------------------------------------------------------------------
local banScreen: Frame? = nil

function PlayerForms.ShowBanScreen(data: any)
	closeModal()
	if banScreen then
		banScreen:Destroy()
	end
	local root = new("Frame", {
		Name = "BanScreen",
		BackgroundColor3 = Color3.fromRGB(10, 11, 12),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
	}, gui)
	new("TextButton", { Name = "Blocker", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", AutoButtonColor = false, ZIndex = 50 }, root)
	banScreen = root
	local vp = viewport()
	local card = new("ScrollingFrame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(math.min(560, vp.X - 24), math.min(620, vp.Y - 24)),
		BackgroundColor3 = C.Card,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		BorderSizePixel = 0,
		ZIndex = 51,
	}, root)
	corner(card, 16)
	stroke(card)
	pad(card, 22)
	list(card, 10)

	local title = text(card, "Title", "", 24, C.Text, FONT_BOLD, 1)
	Icons.prefix(title, "Shutdown", "You are banned from this game", 26)
	text(card, "Reason", "Reason: " .. tostring(data.Reason or "none given"), 16, C.Text, FONT, 2)
	text(card, "Meta", ("Banned by %s  ·  %s"):format(tostring(data.By or "staff"), expiryText(data.ExpiresAt)), 14, C.Muted, FONT, 3)
	local countdown = text(card, "Countdown", "", 14, C.Warning, FONT_MED, 4)
	local deadline = os.clock() + (data.Window or 120)

	local banItem = nil
	for _, item in ipairs(data.Items or {}) do
		if item.Type == "ban" then
			banItem = item
		end
	end

	local status = text(card, "Status", "", 14, C.Muted, FONT_MED, 9)
	if data.CanAppeal and banItem then
		new("Frame", { Name = "Divider", LayoutOrder = 5, BackgroundColor3 = C.Border, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1) }, card)
		text(card, "AppealTitle", "Think this is a mistake? Appeal it here.", 17, C.Text, FONT_BOLD, 6)
		local box = field(card, "AppealText", "Explain what happened and why the ban should be lifted (20+ characters). Staff will read it.", 130, true, 1000, 7)
		local row = new("Frame", { Name = "Actions", LayoutOrder = 8, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36) }, card)
		list(row, 8, true)
		local send = button(row, "Send", "Send appeal", true, 1)
		local busy, done = false, false
		send.MouseButton1Click:Connect(function()
			if busy or done then
				return
			end
			busy = true
			status.Text = "Sending..."
			status.TextColor3 = C.Muted
			local result = call("submitAppeal", { Key = banItem.Key, Text = box.Text })
			busy = false
			if result and result.Ok then
				done = true
				send.Visible = false
				box.TextEditable = false
				status.Text = result.Message .. " You will be disconnected in a few seconds."
				status.TextColor3 = C.Success
				deadline = math.min(deadline, os.clock() + 12)
			else
				status.Text = (result and result.Message) or "The appeal was not sent."
				status.TextColor3 = C.Error
			end
		end)
	else
		local why = if banItem and banItem.Blocked then banItem.Blocked else "This ban can't be appealed right now."
		text(card, "Blocked", why, 15, C.Warning, FONT_MED, 6)
	end
	setZ(root, 51)

	task.spawn(function()
		while banScreen == root and root.Parent do
			local left = math.max(0, math.ceil(deadline - os.clock()))
			countdown.Text = ("You will be disconnected in %ds."):format(left)
			task.wait(0.5)
		end
	end)
end

function PlayerForms.Release()
	if banScreen then
		banScreen:Destroy()
		banScreen = nil
	end
	PlayerForms.Notice("success", "Ban lifted", "Your ban was lifted. Welcome back!", 12)
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
local started = false
function PlayerForms.Init()
	if started then
		return
	end
	started = true
	gui = new("ScreenGui", {
		Name = "SentinelForms",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 200,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)
	noticeStack = new("Frame", {
		Name = "Notices",
		-- Bottom-left: the staff toasts (NotificationCenter) use the right.
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(340, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 60,
	}, gui)
	local layout = list(noticeStack, 8)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		noticeStack.Size = UDim2.fromOffset(math.min(340, gui.AbsoluteSize.X - 32), 0)
	end)

	task.spawn(function()
		formsRemote = SentinelShared:WaitForChild("PlayerFormsRemote", 30) :: RemoteFunction?
	end)
	task.spawn(function()
		local event = SentinelShared:WaitForChild("PlayerFormsEvent", 30) :: RemoteEvent?
		formsEvent = event
		if not event then
			return
		end
		event.OnClientEvent:Connect(function(kind: any, data: any)
			data = if type(data) == "table" then data else {}
			if kind == "report" then
				PlayerForms.OpenReport(if type(data.TargetId) == "number" then data.TargetId else nil)
			elseif kind == "appeal" then
				PlayerForms.OpenAppeal()
			elseif kind == "banscreen" then
				-- The remote function may not be cached yet.
				formsRemote = formsRemote or SentinelShared:WaitForChild("PlayerFormsRemote", 10) :: RemoteFunction?
				PlayerForms.ShowBanScreen(data)
			elseif kind == "release" then
				PlayerForms.Release()
			elseif kind == "notice" then
				PlayerForms.Notice(tostring(data.Kind or "info"), tostring(data.Title or ""), tostring(data.Message or ""), 14)
			end
		end)
	end)
end

_ = TweenService
return PlayerForms
