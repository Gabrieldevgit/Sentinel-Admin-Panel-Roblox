--!strict
--[[
	UIPrefs.lua (UI redesign, extended in W08)

	Purpose:
		One definition of every UI customisation setting, shared by the server
		(Systems/PrefsService validates and stores them) and the client
		(Theme, Shell, CommandBar, AppearancePage, KeybindsPage read them).

		Three layers, later ones win:
			BUILTIN            Sentinel's own look
			server default     chosen by the Owner (ConfigService "UIDefaults")
			personal           each staff member / VIP (Sentinel_Prefs_v1)

	Sections:
		Panel          Theme, Accent, Font, Animations, AnimationSpeed,
		               ReducedMotion, HighContrast, Scale, Custom (palette)
		CommandBar     Preset, Position, Width, Opacity, FontSize, MaxLines,
		               Rows, Key
		Keys (W08)     Panel, ClosePanel, Palette, QuickFly, QuickNoclip,
		               QuickGod, NextPage, PrevPage, Custom (key -> command)
		Notifications  Toasts, Duration, Position (W08)
		Sounds         Enabled, Volume, Success, Error, Warning, Info
		               (each event: Off, a built-in sound or a custom
		               rbxassetid - see Shared/SoundLibrary)
		Layout (W09)   Mode (Auto/Desktop/Mobile), Compact, StatusBar, Labels,
		               Tabs (order + which section tabs show), Pinned (pages)

	Keys are "[Ctrl+][Shift+][Alt+]<KeyCode name>" or "None".
	Theme codes (export / import): "SNTL1-" + 7 hex colours (Background,
	Surface, SurfaceRaised, Border, Text, TextSecondary, Accent).

	Public API:
		UIPrefs.BUILTIN, .THEMES, .ACCENTS, .FONTS, .BAR_PRESETS, .SPEC,
		.ORDER, .SECTIONS, .KEYS, .PALETTE_KEYS
		UIPrefs.Sanitize(any) -> prefs with only valid fields
		UIPrefs.Merge(...) -> prefs (later arguments win)
		UIPrefs.Parse(section, field, text) -> (value?, err?)
		UIPrefs.Find(name) -> (section?, field?)   -- "width", "bar.width", ...
		UIPrefs.Describe(section, field) -> string
		UIPrefs.ResolvePalette(panel) -> { [colour]: Color3 }  (theme +
			accent + custom + high contrast)
		UIPrefs.EncodeTheme(palette) -> code
		UIPrefs.DecodeTheme(code) -> (custom?, err?)
		UIPrefs.ParseKey(text) -> normalised key?
		UIPrefs.MatchKey(key, keyCodeName, ctrl, shift, alt) -> boolean
		UIPrefs.HexToColor(hex) -> Color3?, UIPrefs.ColorToHex(color) -> hex
--]]

local SoundLibrary = require(script.Parent:WaitForChild("SoundLibrary"))

local UIPrefs = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Panel themes: the neutral surfaces. Accent and status colours are separate.
UIPrefs.THEMES = {
	-- Roblox's own in-experience look (top bar, menus, notifications):
	-- near-black neutral surfaces, white text. The default since the
	-- Roblox-style redesign.
	Roblox = {
		Background = rgb(17, 18, 21),
		Surface = rgb(25, 26, 31),
		SurfaceRaised = rgb(40, 41, 48),
		Border = rgb(56, 58, 66),
		Text = rgb(247, 247, 248),
		TextSecondary = rgb(170, 172, 180),
	},
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
	Light = {
		Background = rgb(236, 239, 245),
		Surface = rgb(250, 251, 253),
		SurfaceRaised = rgb(222, 227, 237),
		Border = rgb(196, 203, 217),
		Text = rgb(24, 27, 38),
		TextSecondary = rgb(88, 95, 114),
	},
}
-- "Custom" uses Panel.Custom (falls back to the default theme until one is saved).
UIPrefs.THEME_ORDER = { "Roblox", "Nebula", "Midnight", "Ocean", "Graphite", "Ember", "Light", "Custom" }

-- Colours a custom theme / theme code holds, in code order.
UIPrefs.PALETTE_KEYS = { "Background", "Surface", "SurfaceRaised", "Border", "Text", "TextSecondary", "Accent" }

UIPrefs.ACCENTS = {
	Royal = rgb(51, 95, 255), -- Roblox's blue
	Violet = rgb(139, 108, 255),
	Blue = rgb(64, 156, 255),
	Cyan = rgb(56, 200, 220),
	Green = rgb(72, 200, 130),
	Amber = rgb(240, 176, 64),
	Rose = rgb(240, 96, 128),
}
UIPrefs.ACCENT_ORDER = { "Royal", "Violet", "Blue", "Cyan", "Green", "Amber", "Rose" }

-- Font families: Enum.Font names for Regular / Medium / Bold / Black.
UIPrefs.FONTS = {
	Gotham = { "Gotham", "GothamMedium", "GothamBold", "GothamBlack" },
	Builder = { "BuilderSans", "BuilderSansMedium", "BuilderSansBold", "BuilderSansExtraBold" },
	-- Enum.Font.Montserrat* are aliases of Gotham, so Montserrat is not offered.
	Roboto = { "Roboto", "Roboto", "Roboto", "Roboto" },
	SourceSans = { "SourceSans", "SourceSansSemibold", "SourceSansBold", "SourceSansBold" },
	Arial = { "Arial", "Arial", "ArialBold", "ArialBold" },
}
UIPrefs.FONT_ORDER = { "Gotham", "Builder", "Roboto", "SourceSans", "Arial" }

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

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
-- Keys a shortcut may use (KeyCode names). Escape, Tab, Return and Space
-- are left out: Roblox and text boxes need them.
UIPrefs.KEYS = {}
do
	for c = string.byte("A"), string.byte("Z") do
		table.insert(UIPrefs.KEYS, string.char(c))
	end
	for _, n in ipairs({ "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }) do
		table.insert(UIPrefs.KEYS, n)
	end
	for i = 1, 12 do
		table.insert(UIPrefs.KEYS, "F" .. i)
	end
	for _, k in ipairs({
		"Semicolon", "Quote", "Backquote", "BackSlash", "Comma", "Period", "Slash", "Minus", "Equals",
		"LeftBracket", "RightBracket", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
		"Up", "Down", "Left", "Right",
		"KeypadZero", "KeypadOne", "KeypadTwo", "KeypadThree", "KeypadFour", "KeypadFive",
		"KeypadSix", "KeypadSeven", "KeypadEight", "KeypadNine",
	}) do
		table.insert(UIPrefs.KEYS, k)
	end
end

local KEY_LOOKUP: { [string]: string } = {}
for _, k in ipairs(UIPrefs.KEYS) do
	KEY_LOOKUP[k:lower()] = k
end
do -- friendlier spellings
	local aliases = {
		["0"] = "Zero", ["1"] = "One", ["2"] = "Two", ["3"] = "Three", ["4"] = "Four",
		["5"] = "Five", ["6"] = "Six", ["7"] = "Seven", ["8"] = "Eight", ["9"] = "Nine",
		[";"] = "Semicolon", ["`"] = "Backquote", [","] = "Comma", ["."] = "Period",
		["/"] = "Slash", ["-"] = "Minus", ["="] = "Equals", ["["] = "LeftBracket", ["]"] = "RightBracket",
		pgup = "PageUp", pgdn = "PageDown", del = "Delete",
	}
	aliases[string.char(39)] = "Quote" -- '
	aliases[string.char(92)] = "BackSlash" -- \
	for alias, k in pairs(aliases) do
		KEY_LOOKUP[alias] = k
	end
end

UIPrefs.MAX_CUSTOM_BINDS = 10
UIPrefs.MAX_BIND_COMMAND = 200

-- "ctrl+shift+p", "Ctrl + K", "f6", "none" -> "Ctrl+Shift+P" / "F6" / "None".
function UIPrefs.ParseKey(text: any): string?
	if type(text) ~= "string" or #text > 40 then
		return nil
	end
	local lower = text:lower():gsub("%s", "")
	if lower == "none" or lower == "off" or lower == "" then
		return "None"
	end
	local ctrl, shift, alt = false, false, false
	local parts = string.split(lower, "+")
	local keyPart = parts[#parts]
	for i = 1, #parts - 1 do
		local m = parts[i]
		if m == "ctrl" or m == "control" then
			ctrl = true
		elseif m == "shift" then
			shift = true
		elseif m == "alt" then
			alt = true
		else
			return nil
		end
	end
	local key = KEY_LOOKUP[keyPart]
	if not key then
		return nil
	end
	-- Shift+P (with any other modifier) toggles Roblox's developer Freecam,
	-- which hides every ScreenGui - it closed the panel "on its own".
	if shift and key == "P" then
		return nil
	end
	return (if ctrl then "Ctrl+" else "") .. (if shift then "Shift+" else "") .. (if alt then "Alt+" else "") .. key
end

-- Does a key press match a stored key? Modifiers must match exactly.
function UIPrefs.MatchKey(stored: string?, keyName: string, ctrl: boolean, shift: boolean, alt: boolean): boolean
	if not stored or stored == "None" then
		return false
	end
	local parts = string.split(stored, "+")
	if parts[#parts] ~= keyName then
		return false
	end
	local wantCtrl, wantShift, wantAlt = false, false, false
	for i = 1, #parts - 1 do
		if parts[i] == "Ctrl" then
			wantCtrl = true
		elseif parts[i] == "Shift" then
			wantShift = true
		elseif parts[i] == "Alt" then
			wantAlt = true
		end
	end
	return wantCtrl == ctrl and wantShift == shift and wantAlt == alt
end

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------
function UIPrefs.HexToColor(hex: any): Color3?
	if type(hex) ~= "string" then
		return nil
	end
	local h = hex:gsub("^#", "")
	if not h:match("^%x%x%x%x%x%x$") then
		return nil
	end
	return Color3.fromRGB(
		tonumber(h:sub(1, 2), 16) :: number,
		tonumber(h:sub(3, 4), 16) :: number,
		tonumber(h:sub(5, 6), 16) :: number
	)
end

function UIPrefs.ColorToHex(c: Color3): string
	return ("%02X%02X%02X"):format(
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5)
	)
end

-- ---------------------------------------------------------------------------
-- Navigation (W09): the panel's section tabs and page ids. Shell.lua owns
-- the icons / labels; these lists are what prefs may name.
-- ---------------------------------------------------------------------------
UIPrefs.NAV_SECTIONS = { "Dashboard", "Players", "Moderation", "Commands", "Server", "Announcements", "Insights" }
UIPrefs.PAGE_IDS = {
	"Dashboard", "Players", "Lookup", "Moderation", "Reports", "Appeals", "Ranks", "Commands", "Library", "Server", "CrossServer",
	"Economy", "AnnounceHistory", "AnnounceServer", "AnnounceGlobal", "AnnouncePlayers",
	"Analytics", "Logs", "Developer", "Settings", "Appearance", "Keybinds", "Sounds", "Administration", "Notifications",
}
UIPrefs.MAX_PINNED = 8

local function canonical(list: { string }, value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local lower = value:lower():gsub("[%s%-_]", "")
	for _, item in ipairs(list) do
		if item:lower() == lower then
			return item
		end
	end
	return nil
end
function UIPrefs.FindSection(name: any): string?
	return canonical(UIPrefs.NAV_SECTIONS, name)
end
function UIPrefs.FindPage(name: any): string?
	return canonical(UIPrefs.PAGE_IDS, name)
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
local function choice(list: { string }, description: string)
	return { Kind = "choice", Choices = list, Description = description }
end
local function number(min: number, max: number, step: number, description: string, integer: boolean?)
	return { Kind = "number", Min = min, Max = max, Step = step, Integer = integer == true, Description = description }
end
local function key(description: string)
	return { Kind = "key", Description = description }
end

UIPrefs.SPEC = {
	Panel = {
		Theme = choice(UIPrefs.THEME_ORDER, "Panel colour theme"),
		Accent = choice(UIPrefs.ACCENT_ORDER, "Accent colour (buttons, active tab)"),
		Font = choice(UIPrefs.FONT_ORDER, "Panel font"),
		Animations = { Kind = "boolean", Description = "Open / close and page animations" },
		AnimationSpeed = number(0.5, 2, 0.25, "Animation speed (higher is faster)"),
		ReducedMotion = { Kind = "boolean", Description = "No sliding or zooming; colours still fade" },
		HighContrast = { Kind = "boolean", Description = "Stronger text and borders" },
		Scale = number(0.7, 1.3, 0.05, "Panel size (UI scaling)"),
		Custom = { Kind = "palette", Description = "Colours of the Custom theme" },
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
	Keys = {
		Panel = key("Open / close the panel"),
		ClosePanel = key("Close the panel only"),
		Palette = key("Open the command palette"),
		QuickFly = key("Toggle fly on yourself"),
		QuickNoclip = key("Toggle noclip on yourself"),
		QuickGod = key("Toggle god mode on yourself"),
		NextPage = key("Next panel page"),
		PrevPage = key("Previous panel page"),
		Custom = { Kind = "binds", Description = "Your own key -> command shortcuts" },
	},
	Notifications = {
		Toasts = { Kind = "boolean", Description = "Show pop-up notifications" },
		Duration = number(2, 15, 1, "Seconds a notification stays", true),
		Position = choice({ "BottomRight", "TopRight", "BottomLeft", "TopLeft" }, "Where notifications appear"),
	},
	Sounds = {
		Enabled = { Kind = "boolean", Description = "Play Sentinel sound effects" },
		Volume = number(0, 1, 0.1, "Sound effect volume"),
		Success = { Kind = "sound", Description = SoundLibrary.EVENT_INFO.Success },
		Error = { Kind = "sound", Description = SoundLibrary.EVENT_INFO.Error },
		Warning = { Kind = "sound", Description = SoundLibrary.EVENT_INFO.Warning },
		Info = { Kind = "sound", Description = SoundLibrary.EVENT_INFO.Info },
	},
	Layout = {
		Mode = choice({ "Auto", "Desktop", "Mobile" }, "Window layout (Auto = Mobile on touch screens and small screens)"),
		Compact = { Kind = "boolean", Description = "Compact mode: thinner bars and tighter spacing" },
		StatusBar = { Kind = "boolean", Description = "Live status bar (players, uptime, memory, ping, FPS)" },
		Labels = choice({ "Auto", "Full", "Icons" }, "Section tab labels (Auto = icons only when the panel is narrow)"),
		Tabs = { Kind = "sections", Description = "Section tabs, in order (missing ones are hidden)" },
		Pinned = { Kind = "pages", Description = "Favorite pages pinned to the navigation" },
	},
}

UIPrefs.SECTIONS = { "Panel", "CommandBar", "Keys", "Notifications", "Sounds", "Layout" }

-- Display order for settings screens and ;commandbar / ;theme / ;keybind
-- listings (Panel.Custom and Keys.Custom have their own editors).
UIPrefs.ORDER = {
	Panel = { "Theme", "Accent", "Font", "Animations", "AnimationSpeed", "ReducedMotion", "HighContrast", "Scale" },
	CommandBar = { "Preset", "Position", "Width", "Opacity", "FontSize", "MaxLines", "Rows", "Key" },
	Keys = { "Panel", "ClosePanel", "Palette", "QuickFly", "QuickNoclip", "QuickGod", "NextPage", "PrevPage" },
	Notifications = { "Toasts", "Duration", "Position" },
	Sounds = { "Enabled", "Volume", "Success", "Error", "Warning", "Info" },
	Layout = { "Mode", "Compact", "StatusBar", "Labels" },
}

UIPrefs.BUILTIN = {
	Panel = {
		Theme = "Roblox",
		Accent = "Royal",
		Font = "Builder",
		Animations = true,
		AnimationSpeed = 1,
		ReducedMotion = false,
		HighContrast = false,
		Scale = 1,
	},
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
	Keys = {
		Panel = "F6",
		ClosePanel = "None",
		Palette = "Ctrl+K",
		QuickFly = "None",
		QuickNoclip = "None",
		QuickGod = "None",
		NextPage = "Ctrl+PageDown",
		PrevPage = "Ctrl+PageUp",
		Custom = {},
	},
	Notifications = { Toasts = true, Duration = 5, Position = "BottomRight" },
	Sounds = { Enabled = true, Volume = 0.5, Success = "Success1", Error = "Fail1", Warning = "Fail2", Info = "Success2" },
	Layout = {
		Mode = "Auto",
		Compact = false,
		StatusBar = true,
		Labels = "Auto",
		Tabs = table.clone(UIPrefs.NAV_SECTIONS),
		Pinned = {},
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
	elseif spec.Kind == "key" then
		return UIPrefs.ParseKey(value)
	elseif spec.Kind == "sound" then
		return SoundLibrary.Normalize(value)
	elseif spec.Kind == "palette" then
		if type(value) ~= "table" then
			return nil
		end
		local out = {}
		for _, name in ipairs(UIPrefs.PALETTE_KEYS) do
			local c = UIPrefs.HexToColor(value[name])
			if not c then
				return nil -- a custom palette is all or nothing
			end
			out[name] = UIPrefs.ColorToHex(c)
		end
		return out
	elseif spec.Kind == "binds" then
		if type(value) ~= "table" then
			return nil
		end
		local out = {}
		for _, bind in ipairs(value) do
			if #out >= UIPrefs.MAX_CUSTOM_BINDS then
				break
			end
			if type(bind) == "table" and type(bind.Command) == "string" then
				local k = UIPrefs.ParseKey(bind.Key)
				local command = (bind.Command:gsub("%c", " "):match("^%s*(.-)%s*$")) :: string
				if k and k ~= "None" and #command > 0 and #command <= UIPrefs.MAX_BIND_COMMAND then
					table.insert(out, { Key = k, Command = command })
				end
			end
		end
		return out
	elseif spec.Kind == "sections" or spec.Kind == "pages" then
		if type(value) ~= "table" then
			return nil
		end
		local out, seen = {}, {}
		local limit = if spec.Kind == "pages" then UIPrefs.MAX_PINNED else #UIPrefs.NAV_SECTIONS
		for _, item in ipairs(value) do
			local id = if spec.Kind == "pages" then UIPrefs.FindPage(item) else UIPrefs.FindSection(item)
			if id and not seen[id] and #out < limit then
				seen[id] = true
				table.insert(out, id)
			end
		end
		-- At least one section tab must stay, or the panel has no navigation.
		if spec.Kind == "sections" and #out == 0 then
			return nil
		end
		return out
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
	elseif spec.Kind == "key" then
		local k = UIPrefs.ParseKey(text)
		if not k then
			return nil, "use a key like F6, K, Ctrl+K or Ctrl+Alt+P (or none; Shift+P is Roblox Freecam)"
		end
		return k, nil
	elseif spec.Kind == "sound" then
		local v = SoundLibrary.Normalize(text)
		if not v then
			return nil, "use off, " .. table.concat(SoundLibrary.ORDER, ", ") .. ", or a Roblox audio link / id"
		end
		return v, nil
	elseif spec.Kind == "palette" or spec.Kind == "binds" or spec.Kind == "sections" or spec.Kind == "pages" then
		return nil, "this setting has its own editor"
	elseif spec.Kind == "number" then
		local percent = text:match("^%s*([%d%.]+)%s*%%%s*$")
		raw = tonumber(percent or text)
		-- 0-1 settings (volume, opacity...) also take percentages: 70% or 70.
		if raw and spec.Max == 1 and (percent or raw > 1) and raw <= 100 then
			raw /= 100
		end
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

-- "width", "fontsize", "bar.width", "panel.theme", "keys.quickfly"
-- -> section, field
function UIPrefs.Find(name: string, preferSection: string?): (string?, string?)
	local wantedSection, wantedField = name:lower():match("^(%a+)%.(%a+)$")
	local wanted = wantedField or name:lower()
	local sections = if preferSection then { preferSection } else { "CommandBar", "Panel", "Keys", "Notifications", "Sounds", "Layout" }
	if wantedSection then
		sections = {}
		for _, section in ipairs(UIPrefs.SECTIONS) do
			if section:lower() == wantedSection or (wantedSection == "bar" and section == "CommandBar") then
				table.insert(sections, section)
			end
		end
	end
	for _, section in ipairs(sections) do
		for _, field in ipairs(UIPrefs.ORDER[section]) do
			if field:lower() == wanted then
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
	elseif spec.Kind == "key" then
		return spec.Description .. " (a key like F6, Ctrl+K, or none)"
	elseif spec.Kind == "boolean" then
		return spec.Description .. " (on | off)"
	elseif spec.Kind == "sound" then
		return spec.Description .. " (off | Success1-4 | Fail1-4 | a Roblox audio link or id)"
	end
	return spec.Description
end

local function luminance(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

-- The colours a panel uses for these prefs.
function UIPrefs.ResolvePalette(panel: any): { [string]: Color3 }
	panel = if type(panel) == "table" then panel else {}
	local out: { [string]: Color3 } = {}
	local base = UIPrefs.THEMES[panel.Theme] or UIPrefs.THEMES[UIPrefs.BUILTIN.Panel.Theme]
	for name, color in pairs(base) do
		out[name] = color
	end
	out.Accent = UIPrefs.ACCENTS[panel.Accent] or UIPrefs.ACCENTS[UIPrefs.BUILTIN.Panel.Accent]
	if panel.Theme == "Custom" and type(panel.Custom) == "table" then
		for _, name in ipairs(UIPrefs.PALETTE_KEYS) do
			local c = UIPrefs.HexToColor(panel.Custom[name])
			if c then
				out[name] = c
			end
		end
	end
	if panel.HighContrast == true then
		local dark = luminance(out.Background) < 0.5
		local strong = if dark then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		local deep = if dark then Color3.new(0, 0, 0) else Color3.new(1, 1, 1)
		out.Text = strong
		out.TextSecondary = out.TextSecondary:Lerp(strong, 0.6)
		out.Border = out.Border:Lerp(strong, 0.45)
		out.Background = out.Background:Lerp(deep, 0.5)
	end
	return out
end

function UIPrefs.IsLight(palette: { [string]: Color3 }): boolean
	return luminance(palette.Background) >= 0.5
end

function UIPrefs.EncodeTheme(palette: { [string]: Color3 }): string
	local parts = {}
	for _, name in ipairs(UIPrefs.PALETTE_KEYS) do
		table.insert(parts, UIPrefs.ColorToHex(palette[name] or Color3.new()))
	end
	return "SNTL1-" .. table.concat(parts, "-")
end

-- Theme code -> a Custom palette table (hex strings), or nil + reason.
function UIPrefs.DecodeTheme(code: any): (any, string?)
	if type(code) ~= "string" or #code > 120 then
		return nil, "not a theme code"
	end
	local body = (code:gsub("%s", "")):match("^[Ss][Nn][Tt][Ll]1%-(.+)$")
	if not body then
		return nil, "theme codes start with SNTL1-"
	end
	local parts = string.split(body, "-")
	if #parts ~= #UIPrefs.PALETTE_KEYS then
		return nil, ("a theme code has %d colours"):format(#UIPrefs.PALETTE_KEYS)
	end
	local out = {}
	for i, name in ipairs(UIPrefs.PALETTE_KEYS) do
		local c = UIPrefs.HexToColor(parts[i])
		if not c then
			return nil, ("colour %d (%s) is not a hex colour"):format(i, name)
		end
		out[name] = UIPrefs.ColorToHex(c)
	end
	return out, nil
end

return UIPrefs
