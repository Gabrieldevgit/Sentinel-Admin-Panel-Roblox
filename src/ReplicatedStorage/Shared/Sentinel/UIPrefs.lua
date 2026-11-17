--!strict
--[[
	UIPrefs.lua (UI redesign)

	Purpose:
		One definition of every UI customisation setting, shared by the server
		(Systems/PrefsService validates and stores them) and the client
		(Theme, Shell, CommandBar, AppearancePage read them).

		Three layers, later ones win:
			BUILTIN            Sentinel's own look
			server default     chosen by the Owner (ConfigService "UIDefaults")
			personal           each staff member / VIP (Sentinel_Prefs_v1)

	Sections:
		Panel       Theme, Accent, Animations, Scale
		CommandBar  Preset, Position, Width, Opacity, FontSize, MaxLines,
		            Rows, Key

	Public API:
		UIPrefs.BUILTIN, .THEMES, .ACCENTS, .BAR_PRESETS, .SPEC, .ORDER
		UIPrefs.Sanitize(any) -> prefs with only valid fields
		UIPrefs.Merge(...) -> prefs (later arguments win)
		UIPrefs.Parse(section, field, text) -> (value?, err?)
		UIPrefs.Find(name) -> (section?, field?)   -- "width", "bar.width", ...
		UIPrefs.Describe(section, field) -> string
--]]

local UIPrefs = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Panel themes: the neutral surfaces. Accent and status colours are separate.
UIPrefs.THEMES = {
	Nebula = {
		Background = rgb(20, 17, 30),
		Surface = rgb(28, 23, 42),
		SurfaceRaised = rgb(39, 32, 58),
		Border = rgb(62, 50, 92),
		Text = rgb(240, 238, 248),
		TextSecondary = rgb(156, 148, 178),
	},
	Midnight = {
		Background = rgb(11, 14, 24),
		Surface = rgb(17, 22, 36),
		SurfaceRaised = rgb(25, 32, 52),
		Border = rgb(40, 52, 82),
		Text = rgb(232, 238, 250),
		TextSecondary = rgb(136, 150, 180),
	},
	Ocean = {
		Background = rgb(10, 22, 28),
		Surface = rgb(14, 31, 39),
		SurfaceRaised = rgb(20, 44, 54),
		Border = rgb(34, 70, 84),
		Text = rgb(232, 246, 248),
		TextSecondary = rgb(130, 168, 176),
	},
	Graphite = {
		Background = rgb(18, 18, 22),
		Surface = rgb(26, 26, 32),
		SurfaceRaised = rgb(34, 34, 42),
		Border = rgb(48, 48, 58),
		Text = rgb(240, 240, 245),
		TextSecondary = rgb(150, 150, 160),
	},
	Ember = {
		Background = rgb(24, 16, 16),
		Surface = rgb(34, 22, 22),
		SurfaceRaised = rgb(48, 30, 30),
		Border = rgb(78, 46, 44),
		Text = rgb(248, 238, 234),
		TextSecondary = rgb(180, 150, 144),
	},
}
UIPrefs.THEME_ORDER = { "Nebula", "Midnight", "Ocean", "Graphite", "Ember" }

UIPrefs.ACCENTS = {
	Violet = rgb(139, 108, 255),
	Blue = rgb(64, 156, 255),
	Cyan = rgb(56, 200, 220),
	Green = rgb(72, 200, 130),
	Amber = rgb(240, 176, 64),
	Rose = rgb(240, 96, 128),
}
UIPrefs.ACCENT_ORDER = { "Violet", "Blue", "Cyan", "Green", "Amber", "Rose" }

-- Command bar looks.
UIPrefs.BAR_PRESETS = {
	Classic = { -- terminal: grey panel, yellow prompt
		Background = rgb(40, 44, 48),
		Line = rgb(52, 58, 68),
		Prompt = rgb(240, 220, 90),
		Text = rgb(238, 238, 238),
		Muted = rgb(170, 174, 180),
		Popup = rgb(62, 66, 70),
		PopupHeader = rgb(48, 52, 56),
		Selected = rgb(96, 102, 108),
	},
	Sentinel = { -- follows the panel theme (filled in on the client)
		FollowTheme = true,
	},
	Carbon = {
		Background = rgb(10, 10, 12),
		Line = rgb(22, 22, 26),
		Prompt = rgb(90, 220, 140),
		Text = rgb(220, 240, 226),
		Muted = rgb(120, 150, 130),
		Popup = rgb(20, 22, 24),
		PopupHeader = rgb(14, 16, 18),
		Selected = rgb(36, 60, 44),
	},
	Frost = {
		Background = rgb(226, 232, 240),
		Line = rgb(206, 214, 226),
		Prompt = rgb(40, 96, 200),
		Text = rgb(24, 30, 42),
		Muted = rgb(90, 100, 118),
		Popup = rgb(240, 244, 250),
		PopupHeader = rgb(214, 222, 234),
		Selected = rgb(190, 206, 232),
	},
}
UIPrefs.BAR_PRESET_ORDER = { "Classic", "Sentinel", "Carbon", "Frost" }

local function choice(list: { string }, description: string)
	return { Kind = "choice", Choices = list, Description = description }
end
local function number(min: number, max: number, step: number, description: string, integer: boolean?)
	return { Kind = "number", Min = min, Max = max, Step = step, Integer = integer == true, Description = description }
end

UIPrefs.SPEC = {
	Panel = {
		Theme = choice(UIPrefs.THEME_ORDER, "Panel colour theme"),
		Accent = choice(UIPrefs.ACCENT_ORDER, "Accent colour (buttons, active tab)"),
		Animations = { Kind = "boolean", Description = "Open / close and page animations" },
		Scale = number(0.8, 1.2, 0.05, "Panel size"),
	},
	CommandBar = {
		Preset = choice(UIPrefs.BAR_PRESET_ORDER, "Command bar look"),
		Position = choice({ "top", "bottom" }, "Where the command bar sits"),
		Width = number(0.4, 1, 0.1, "Width, as a share of the screen"),
		Opacity = number(0.4, 1, 0.1, "How solid the background is"),
		FontSize = number(12, 20, 1, "Text size", true),
		MaxLines = number(2, 14, 1, "Output lines kept on screen", true),
		Rows = number(4, 12, 1, "Suggestions shown at once", true),
		Key = choice({ "F2", "F4", "Semicolon", "Quote", "Backquote", "BackSlash" }, "Key that opens the command bar"),
	},
}

-- Display order for settings screens and ;commandbar / ;theme listings.
UIPrefs.ORDER = {
	Panel = { "Theme", "Accent", "Animations", "Scale" },
	CommandBar = { "Preset", "Position", "Width", "Opacity", "FontSize", "MaxLines", "Rows", "Key" },
}

UIPrefs.BUILTIN = {
	Panel = { Theme = "Nebula", Accent = "Violet", Animations = true, Scale = 1 },
	CommandBar = {
		Preset = "Classic",
		Position = "top",
		Width = 1,
		Opacity = 0.9,
		FontSize = 15,
		MaxLines = 6,
		Rows = 8,
		Key = "F2",
	},
}

local function validValue(spec: any, value: any): any
	if spec.Kind == "boolean" then
		return if type(value) == "boolean" then value else nil
	elseif spec.Kind == "choice" then
		if type(value) ~= "string" then
			return nil
		end
		for _, option in ipairs(spec.Choices) do
			if option:lower() == value:lower() then
				return option
			end
		end
		return nil
	elseif spec.Kind == "number" then
		if type(value) ~= "number" or value ~= value then
			return nil
		end
		local v = math.clamp(value, spec.Min, spec.Max)
		if spec.Integer then
			v = math.floor(v + 0.5)
		else
			v = math.floor(v * 100 + 0.5) / 100
		end
		return v
	end
	return nil
end

-- Keeps only known sections / fields with valid values. Never errors.
function UIPrefs.Sanitize(input: any): any
	local out = {}
	if type(input) ~= "table" then
		return out
	end
	for section, fields in pairs(UIPrefs.SPEC) do
		local given = input[section]
		if type(given) == "table" then
			local clean = {}
			for field, spec in pairs(fields) do
				local v = validValue(spec, given[field])
				if v ~= nil then
					clean[field] = v
				end
			end
			if next(clean) then
				out[section] = clean
			end
		end
	end
	return out
end

function UIPrefs.Merge(...: any): any
	local out = {}
	for section in pairs(UIPrefs.SPEC) do
		out[section] = {}
	end
	for _, layer in ipairs({ ... }) do
		if type(layer) == "table" then
			for section, fields in pairs(layer) do
				if out[section] and type(fields) == "table" then
					for field, value in pairs(fields) do
						out[section][field] = value
					end
				end
			end
		end
	end
	return out
end

-- Text typed in a command -> a valid value for that setting.
function UIPrefs.Parse(section: string, field: string, text: string): (any, string?)
	local spec = UIPrefs.SPEC[section] and UIPrefs.SPEC[section][field]
	if not spec then
		return nil, "unknown setting"
	end
	local raw: any = text
	if spec.Kind == "boolean" then
		local lower = text:lower()
		if lower == "on" or lower == "true" or lower == "yes" then
			raw = true
		elseif lower == "off" or lower == "false" or lower == "no" then
			raw = false
		else
			return nil, "use on or off"
		end
	elseif spec.Kind == "number" then
		raw = tonumber(text)
		if not raw then
			return nil, ("give a number from %s to %s"):format(tostring(spec.Min), tostring(spec.Max))
		end
	end
	local value = validValue(spec, raw)
	if value == nil then
		if spec.Kind == "choice" then
			return nil, "choose one of: " .. table.concat(spec.Choices, ", ")
		end
		return nil, "invalid value"
	end
	return value, nil
end

-- "width", "fontsize", "bar.width", "panel.theme" -> section, field
function UIPrefs.Find(name: string, preferSection: string?): (string?, string?)
	local wantedSection, wantedField = name:lower():match("^(%a+)%.(%a+)$")
	local key = wantedField or name:lower()
	local sections = if preferSection then { preferSection } else { "CommandBar", "Panel" }
	if wantedSection then
		sections = if wantedSection == "panel" then { "Panel" } else { "CommandBar" }
	end
	for _, section in ipairs(sections) do
		for field in pairs(UIPrefs.SPEC[section]) do
			if field:lower() == key then
				return section, field
			end
		end
	end
	return nil, nil
end

function UIPrefs.Describe(section: string, field: string): string
	local spec = UIPrefs.SPEC[section][field]
	if spec.Kind == "choice" then
		return ("%s (%s)"):format(spec.Description, table.concat(spec.Choices, " | "))
	elseif spec.Kind == "number" then
		return ("%s (%s to %s)"):format(spec.Description, tostring(spec.Min), tostring(spec.Max))
	end
	return spec.Description .. " (on | off)"
end

return UIPrefs
