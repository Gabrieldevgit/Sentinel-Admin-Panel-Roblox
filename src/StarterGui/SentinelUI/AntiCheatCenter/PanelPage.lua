--!strict
--[[
	PanelPage.lua (Sentinel AntiCheat)

	The "Anti-Cheat" entry of the Sentinel panel (F6 > Moderation >
	Anti-Cheat). Shows a short status and opens the Control Center (it also
	opens it as soon as the page is shown). init.client hides the entry for
	players without anticheat.view.

	Stable names: SentinelShell...Workspace.AntiCheatPage.{Status, OpenButton}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local PanelPage = {}

function PanelPage.Build(container: Frame, Center: any, onOpen: () -> ())
	local holder = Widgets.make("Frame", { Name = "AntiCheatLauncher", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, container)
	Theme.padding(holder, 24)
	Widgets.list(holder, nil, 12)
	Widgets.label(holder, "Anti-Cheat Control Center", { Bold = true, TextSize = 22, LayoutOrder = 1 })
	Widgets.label(holder, "Server-authoritative detections, suspicion scores, the action ladder, reviews and exemptions live in their own window. Open it with F7, the AC button in the top bar, Ctrl+K > anti, or ;anticheat.", { Wrap = true, AutoY = true, Color = Theme.Colors.TextSecondary, LayoutOrder = 2 })
	local status = Widgets.label(holder, "", { Name = "Status", LayoutOrder = 3 })
	local open = Widgets.make("TextButton", { Name = "OpenButton", Text = "Open the Control Center", Font = Theme.Font.Bold, TextSize = 15, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Theme.Colors.Accent, Size = UDim2.fromOffset(240, 38), LayoutOrder = 4 }, holder)
	Theme.corner(open, Theme.Radius.S)
	open.Activated:Connect(onOpen)
	local function update()
		local s = Center.Status
		if s then
			status.Text = ("%s  |  mode %s  |  %s%s"):format(if s.Enabled then "ON" else "OFF", tostring(s.Mode), tostring(s.Health), if s.Panic then "  |  PANIC" else "")
		end
	end
	container:GetPropertyChangedSignal("Visible"):Connect(function()
		update()
		if container.Visible then
			onOpen()
		end
	end)
	update()
end

return PanelPage
