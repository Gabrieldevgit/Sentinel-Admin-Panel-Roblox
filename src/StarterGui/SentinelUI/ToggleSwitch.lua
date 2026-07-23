--!strict
--[[
	ToggleSwitch.lua

	Purpose:
		Single, real shared implementation of the on/off toggle switch used
		by QuickActionsPanel (Lock/Maintenance), PlayersPage (Freeze/Jail/
		Mute), and ServerPage (Lock/Maintenance/Time Freeze). Before this,
		each file had its own copy-pasted switch-drawing code with slightly
		different sizes — this consolidates them into one place, since a
		custom switch design is being made and shouldn't require the same
		edit in three files.

	IMPORTANT — this is a functional placeholder, not the final design:
		green pill = on, red pill = off, a plain circular knob that slides.
		Swap the internals of ToggleSwitch.Create once the custom design
		is ready; every panel that calls this updates automatically.

	Public API:
		ToggleSwitch.Create(parent: Instance, config: {
			Position: UDim2,
			AnchorPoint: Vector2?,
			Size: UDim2?,          -- defaults to a 36x16 pill
			Initial: boolean?,     -- starting state, defaults to false
			OnToggle: (boolean) -> (),  -- called with the NEW state after a click
		}): ToggleHandle

		ToggleHandle.Set(value: boolean): ()  -- push a state update without
		                                         firing OnToggle (e.g. after
		                                         polling the server)
		ToggleHandle.Get(): boolean

	Example usage:
		local handle = ToggleSwitch.Create(card, {
			Position = UDim2.new(1, 0, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			OnToggle = function(newValue)
				runCommand(if newValue then "lockserver" else "unlockserver")
			end,
		})
		-- later, after polling the server:
		handle.Set(actualServerState)
--]]

local Theme = require(script.Parent:WaitForChild("Theme"))

local ToggleSwitch = {}

export type ToggleHandle = {
	Set: (value: boolean) -> (),
	Get: () -> boolean,
}

export type ToggleConfig = {
	Position: UDim2,
	AnchorPoint: Vector2?,
	Size: UDim2?,
	Initial: boolean?,
	OnToggle: (boolean) -> (),
}

function ToggleSwitch.Create(parent: Instance, config: ToggleConfig): ToggleHandle
	local size = config.Size or UDim2.new(0, 36, 0, 16)

	local track = Instance.new("Frame")
	track.Name = "SwitchTrack"
	track.AnchorPoint = config.AnchorPoint or Vector2.new(0, 0)
	track.Position = config.Position
	track.Size = size
	track.BorderSizePixel = 0
	track.Parent = parent
	Theme.corner(track, UDim.new(1, 0))

	local knob = Instance.new("Frame")
	knob.Name = "SwitchKnob"
	knob.Size = UDim2.new(0, 12, 0, 12)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	knob.Parent = track
	Theme.corner(knob, UDim.new(1, 0))

	local clickButton = Instance.new("TextButton")
	clickButton.BackgroundTransparency = 1
	clickButton.Size = UDim2.new(1, 0, 1, 0)
	clickButton.Text = ""
	clickButton.Parent = track

	local isOn = config.Initial or false

	local function render()
		track.BackgroundColor3 = if isOn then Theme.Colors.Success else Theme.Colors.Error
		knob.Position = if isOn then UDim2.new(1, -14, 0.5, -6) else UDim2.new(0, 2, 0.5, -6)
	end

	clickButton.MouseButton1Click:Connect(function()
		isOn = not isOn
		render() -- optimistic UI update; caller's poll loop corrects it if the command failed
		config.OnToggle(isOn)
	end)

	render()

	return {
		Set = function(value: boolean)
			isOn = value
			render()
		end,
		Get = function(): boolean
			return isOn
		end,
	}
end

return ToggleSwitch
