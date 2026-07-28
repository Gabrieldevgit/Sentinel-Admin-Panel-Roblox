--!strict
--[[
	CommandPalette.lua

	Purpose:
		The "universal launcher" from the design doc: Ctrl+Shift+P opens a
		floating, centered palette. Fuzzy-searches commands as you type,
		shows inline docs for the top match, previews a parsed breakdown
		of what you've typed so far (target/modifier/args), and executes
		through UIBridge's ExecuteCommandRemote — the exact same
		CommandRegistry.Dispatch path as chat, so permission/cooldown/
		logging behave identically either way.

	Responsibilities:
		- Build the floating palette UI (hidden by default)
		- Toggle on Ctrl+Shift+P
		- Fuzzy-match against the command list fetched from
		  GetCommandListRemote (cached after first open)
		- Show a live breakdown of command/target/modifier/args
		- Track command history (session-only, in memory)
		- Send execution requests and display the result

	Dependencies:
		Theme.lua

	Public API:
		CommandPalette.Init(): ()
		CommandPalette.Open(): ()
		CommandPalette.Close(): ()
--]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Theme = require(script.Parent:WaitForChild("Theme", 15))

local CommandPalette = {}

local localPlayer = Players.LocalPlayer
local SentinelShared = ReplicatedStorage:WaitForChild("Shared", 15):WaitForChild("Sentinel", 15)

type CommandMeta = {
	Name: string,
	Aliases: { string },
	Description: string,
	Usage: string,
	Permission: string,
	Category: string,
}

local commandCache: { CommandMeta }? = nil
local history: { string } = {}
local MAX_HISTORY = 20

-- ---------------------------------------------------------------------------
-- Fuzzy matching: subsequence match with a simple contiguity bonus, good
-- enough for "frz" -> "freeze", "tp" -> "teleport" style matches without
-- pulling in an external library.
-- ---------------------------------------------------------------------------
local function fuzzyScore(query: string, candidate: string): number?
	if query == "" then
		return 0
	end
	query = query:lower()
	candidate = candidate:lower()

	local qi = 1
	local score = 0
	local lastMatch = 0
	for ci = 1, #candidate do
		if qi > #query then
			break
		end
		if candidate:sub(ci, ci) == query:sub(qi, qi) then
			score += (if ci == lastMatch + 1 then 3 else 1)
			lastMatch = ci
			qi += 1
		end
	end
	if qi <= #query then
		return nil -- not all query characters were found in order
	end
	return score
end

local function fetchCommandList(): { CommandMeta }
	if commandCache then
		return commandCache
	end
	local remote = SentinelShared:WaitForChild("GetCommandListRemote", 15) :: RemoteFunction?
	if not remote then
		commandCache = {}
		return {}
	end
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	commandCache = if ok and result then result else {}
	return commandCache :: { CommandMeta }
end

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------
function CommandPalette.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SentinelCommandPalette"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 200
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	CommandPalette.screenGui = screenGui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Parent = screenGui
	backdrop.MouseButton1Click:Connect(function()
		CommandPalette.Close()
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0.16, 0)
	panel.Size = UDim2.new(0, 640, 0, 380)
	panel.BackgroundColor3 = Theme.Colors.Surface
	panel.BorderSizePixel = 0
	panel.Parent = screenGui
	Theme.corner(panel, Theme.Radius.L)
	Theme.stroke(panel, Theme.Colors.Border, 1)

	local inputBox = Instance.new("TextBox")
	inputBox.Name = "Input"
	inputBox.Position = UDim2.new(0, 16, 0, 12)
	inputBox.Size = UDim2.new(1, -32, 0, 40)
	inputBox.BackgroundColor3 = Theme.Colors.SurfaceRaised
	inputBox.Font = Theme.Font.Mono
	inputBox.TextSize = 18
	inputBox.TextColor3 = Theme.Colors.Text
	inputBox.PlaceholderText = "Type a command, e.g. ban Player1:30m Exploiting"
	inputBox.PlaceholderColor3 = Theme.Colors.TextSecondary
	inputBox.Text = ""
	inputBox.ClearTextOnFocus = false
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.Parent = panel
	Theme.corner(inputBox, Theme.Radius.S)
	Theme.padding(inputBox, 10)
	CommandPalette.inputBox = inputBox

	local previewLabel = Instance.new("TextLabel")
	previewLabel.Name = "Preview"
	previewLabel.BackgroundTransparency = 1
	previewLabel.Position = UDim2.new(0, 16, 0, 58)
	previewLabel.Size = UDim2.new(1, -32, 0, 20)
	previewLabel.Font = Theme.Font.Regular
	previewLabel.TextSize = 12
	previewLabel.TextColor3 = Theme.Colors.TextSecondary
	previewLabel.TextXAlignment = Enum.TextXAlignment.Left
	previewLabel.Text = ""
	previewLabel.Parent = panel
	CommandPalette.previewLabel = previewLabel

	local suggestionsFrame = Instance.new("ScrollingFrame")
	suggestionsFrame.Name = "Suggestions"
	suggestionsFrame.Position = UDim2.new(0, 16, 0, 86)
	suggestionsFrame.Size = UDim2.new(1, -32, 0, 200)
	suggestionsFrame.BackgroundTransparency = 1
	suggestionsFrame.BorderSizePixel = 0
	suggestionsFrame.ScrollBarThickness = 4
	suggestionsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	suggestionsFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	suggestionsFrame.Parent = panel

	local suggestionsLayout = Instance.new("UIListLayout")
	suggestionsLayout.Padding = UDim.new(0, 2)
	suggestionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	suggestionsLayout.Parent = suggestionsFrame
	CommandPalette.suggestionsFrame = suggestionsFrame

	local footerLabel = Instance.new("TextLabel")
	footerLabel.Name = "Footer"
	footerLabel.BackgroundTransparency = 1
	footerLabel.Position = UDim2.new(0, 16, 1, -30)
	footerLabel.Size = UDim2.new(1, -32, 0, 20)
	footerLabel.Font = Theme.Font.Regular
	footerLabel.TextSize = 11
	footerLabel.TextColor3 = Theme.Colors.TextSecondary
	footerLabel.TextXAlignment = Enum.TextXAlignment.Left
	footerLabel.Text = "Enter to run · Esc to close · ↑↓ history"
	footerLabel.Parent = panel

	local commandResultRemote = SentinelShared:WaitForChild("CommandResultRemote", 15) :: RemoteEvent?
	if commandResultRemote then
		commandResultRemote.OnClientEvent:Connect(function(results: { any })
			for _, result in ipairs(results) do
				if result.Message then
					footerLabel.Text = (if result.Success then "✅ " else "❌ ") .. result.Message
				end
			end
		end)
	end

	local historyIndex = 0

	local function renderSuggestions(query: string)
		for _, child in ipairs(suggestionsFrame:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end

		local commandWord = query:match("^(%S*)")
		if not commandWord or commandWord == "" then
			previewLabel.Text = ""
			return
		end

		local scored = {}
		for _, meta in ipairs(fetchCommandList()) do
			local best = fuzzyScore(commandWord, meta.Name)
			for _, alias in ipairs(meta.Aliases) do
				local aliasScore = fuzzyScore(commandWord, alias)
				if aliasScore and (not best or aliasScore > best) then
					best = aliasScore
				end
			end
			if best then
				table.insert(scored, { Meta = meta, Score = best })
			end
		end
		table.sort(scored, function(a, b)
			return a.Score > b.Score
		end)

		for i, entry in ipairs(scored) do
			if i > 8 then
				break
			end
			local meta = entry.Meta

			local button = Instance.new("TextButton")
			button.Name = meta.Name
			button.LayoutOrder = i
			button.Size = UDim2.new(1, 0, 0, 40)
			button.BackgroundColor3 = Theme.Colors.SurfaceRaised
			button.BackgroundTransparency = if i == 1 then 0 else 0.4
			button.AutoButtonColor = false
			button.Text = ""
			button.Parent = suggestionsFrame
			Theme.corner(button, Theme.Radius.S)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Position = UDim2.new(0, 10, 0, 4)
			nameLabel.Size = UDim2.new(1, -20, 0, 18)
			nameLabel.Font = Theme.Font.Bold
			nameLabel.TextSize = 14
			nameLabel.TextColor3 = Theme.Colors.Accent
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = meta.Name
			nameLabel.Parent = button

			local descLabel = Instance.new("TextLabel")
			descLabel.BackgroundTransparency = 1
			descLabel.Position = UDim2.new(0, 10, 0, 20)
			descLabel.Size = UDim2.new(1, -20, 0, 16)
			descLabel.Font = Theme.Font.Regular
			descLabel.TextSize = 12
			descLabel.TextColor3 = Theme.Colors.TextSecondary
			descLabel.TextXAlignment = Enum.TextXAlignment.Left
			descLabel.Text = meta.Description
			descLabel.Parent = button

			button.MouseButton1Click:Connect(function()
				inputBox.Text = meta.Name .. " "
				inputBox:CaptureFocus()
			end)

			if i == 1 then
				previewLabel.Text = ("Usage: %s   |   Permission: %s"):format(meta.Usage, meta.Permission)
			end
		end

		if #scored == 0 then
			previewLabel.Text = "No matching command."
		end
	end

	inputBox:GetPropertyChangedSignal("Text"):Connect(function()
		renderSuggestions(inputBox.Text)
	end)

	local function executeCurrent()
		local text = inputBox.Text
		if text == "" then
			return
		end
		table.insert(history, text)
		if #history > MAX_HISTORY then
			table.remove(history, 1)
		end
		historyIndex = #history + 1

		local remote = SentinelShared:FindFirstChild("ExecuteCommandRemote") :: RemoteEvent?
		if remote then
			remote:FireServer(text)
		end
		inputBox.Text = ""
	end

	inputBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			executeCurrent()
			inputBox:CaptureFocus()
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not CommandPalette.screenGui.Enabled then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			CommandPalette.Close()
		elseif input.KeyCode == Enum.KeyCode.Up and not gameProcessed then
			if #history > 0 then
				historyIndex = math.max(1, historyIndex - 1)
				inputBox.Text = history[historyIndex] or ""
			end
		elseif input.KeyCode == Enum.KeyCode.Down and not gameProcessed then
			if #history > 0 then
				historyIndex = math.min(#history + 1, historyIndex + 1)
				inputBox.Text = history[historyIndex] or ""
			end
		end
	end)

	-- Global toggle: Ctrl+Shift+P
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.P
			and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl))
			and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift))
		then
			if CommandPalette.screenGui.Enabled then
				CommandPalette.Close()
			else
				CommandPalette.Open()
			end
		end
	end)
end

function CommandPalette.Open()
	CommandPalette.screenGui.Enabled = true
	CommandPalette.inputBox.Text = ""
	CommandPalette.inputBox:CaptureFocus()
	task.spawn(fetchCommandList) -- warm the cache without blocking the UI from opening
end

function CommandPalette.Close()
	CommandPalette.screenGui.Enabled = false
end

-- Client-only, session-scoped command history (see the module-level
-- `history` table above). Exposed for the Settings page (Phase 7E) so
-- "Clear Command History" is a real action, not a placeholder button.
function CommandPalette.ClearHistory()
	table.clear(history)
end

function CommandPalette.GetHistoryCount(): number
	return #history
end

return CommandPalette
