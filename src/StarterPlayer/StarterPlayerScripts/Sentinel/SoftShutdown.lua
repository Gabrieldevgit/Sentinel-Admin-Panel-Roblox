--!strict
--[[
	SoftShutdown.lua (client, every player) - the "Servers are restarting"
	screen for Systems/SoftShutdownService.

	- SoftShutdownRemote ("leaving", label): full-screen card, also handed to
	  TeleportService:SetTeleportGui so it stays up through the teleport.
	- In the waiting room (own teleport data has SentinelSoftShutdown /
	  SentinelMigration) or on ("waiting", seconds): "Sending you to a fresh
	  server..." with a countdown.
	- ("cancel"): hide (Studio dry run / failed move).

	ScreenGui SentinelSoftShutdown.Card.{Title,Message,Status}.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

local SoftShutdown = {}

local gui: ScreenGui? = nil
local spinning = false

local function build(): ScreenGui
	local g = Instance.new("ScreenGui")
	g.Name = "SentinelSoftShutdown"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = 1000
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local back = Instance.new("Frame")
	back.Name = "Backdrop"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
	back.BorderSizePixel = 0
	back.Parent = g

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(420, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Color3.fromRGB(26, 26, 32)
	card.BorderSizePixel = 0
	card.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(420, math.huge)
	constraint.Parent = card
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 24), UDim.new(0, 24)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 24), UDim.new(0, 24)
	pad.Parent = card
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.Padding = UDim.new(0, 10)
	list.Parent = card

	local ring = Instance.new("Frame")
	ring.Name = "Spinner"
	ring.LayoutOrder = 1
	ring.Size = UDim2.fromOffset(36, 36)
	ring.BackgroundTransparency = 1
	ring.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(51, 95, 255)
	stroke.Parent = ring
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(1, 0)
	ringCorner.Parent = ring
	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	gradient.Parent = stroke

	local function text(name: string, order: number, size: number, color: Color3, font: Enum.Font): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.LayoutOrder = order
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, size + 4)
		l.AutomaticSize = Enum.AutomaticSize.Y
		l.TextWrapped = true
		l.Font = font
		l.TextSize = size
		l.TextColor3 = color
		l.Text = ""
		l.Parent = card
		return l
	end
	text("Title", 2, 22, Color3.fromRGB(240, 240, 245), Enum.Font.BuilderSansBold)
	text("Message", 3, 15, Color3.fromRGB(180, 180, 190), Enum.Font.BuilderSans)
	text("Status", 4, 13, Color3.fromRGB(120, 120, 135), Enum.Font.BuilderSans)

	task.spawn(function()
		spinning = true
		while spinning and g.Parent do
			TweenService:Create(gradient, TweenInfo.new(0.9, Enum.EasingStyle.Linear), { Rotation = gradient.Rotation + 360 }):Play()
			task.wait(0.9)
		end
	end)
	return g
end

local function show(title: string, message: string, status: string)
	local player = Players.LocalPlayer
	if not gui then
		gui = build()
		gui.Parent = player:WaitForChild("PlayerGui")
	end
	local card = (gui :: ScreenGui):FindFirstChild("Card") :: Frame
	(card :: any).Title.Text = title;
	(card :: any).Message.Text = message;
	(card :: any).Status.Text = status
end

local function hide()
	spinning = false
	if gui then
		gui:Destroy()
		gui = nil
	end
end

local function countdown(seconds: number)
	task.spawn(function()
		for left = seconds, 1, -1 do
			if not gui then
				return
			end
			((gui :: ScreenGui).Card :: any).Status.Text = ("Sending you to a fresh server in %d s..."):format(left)
			task.wait(1)
		end
		if gui then
			((gui :: ScreenGui).Card :: any).Status.Text = "Teleporting..."
		end
	end)
end

function SoftShutdown.Init()
	-- Waiting room: our own teleport data says we came from a soft shutdown.
	local ok, data = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	if ok and type(data) == "table" and (data.SentinelSoftShutdown == 1 or data.SentinelMigration == true) then
		show("Restarting servers", if type(data.Label) == "string" then data.Label else "Servers are restarting for an update.", "Please wait - you'll be moved automatically.")
	end

	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("SoftShutdownRemote", 60) :: RemoteEvent?
		if not remote then
			return
		end
		remote.OnClientEvent:Connect(function(kind: any, value: any)
			if kind == "leaving" then
				show("Restarting servers", if type(value) == "string" then value else "Servers are restarting.", "Moving you to a new server - don't leave!")
				pcall(function()
					TeleportService:SetTeleportGui(gui :: ScreenGui)
				end)
			elseif kind == "waiting" then
				show("Restarting servers", "Almost there.", "Please wait...")
				countdown(tonumber(value) or 8)
			elseif kind == "cancel" then
				hide()
			end
		end)
	end)
end

return SoftShutdown
