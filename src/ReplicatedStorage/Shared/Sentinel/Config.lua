-- ============================================
-- SENTINEL CONFIGURATION
-- ============================================
-- Central configuration module for all Sentinel settings
-- Adapted from Admin Panel V4.3 config structure

local Config = {}

-- ============================================
-- GENERAL SETTINGS
-- ============================================
Config.GENERAL = {
	VERSION = "1.0.0",
	LAST_UPDATED = "2026-01-08",
	COMMAND_PREFIX = ";", -- Default command prefix for chat commands
	MAX_COMMAND_LENGTH = 500,
	MAX_REASON_LENGTH = 500,
	DEFAULT_NOTIFICATION_DURATION = 4,
}

-- ============================================
-- PERMISSION RANKS
-- ============================================
Config.RANKS = {
	{
		name = "Owner",
		level = 100,
		permissionNode = "*",
		color = Color3.fromRGB(255, 215, 0), -- Gold
		description = "Full access to all commands and settings",
	},
	{
		name = "Developer",
		level = 80,
		permissionNode = "developer.*",
		color = Color3.fromRGB(255, 100, 255), -- Magenta
		description = "Developer tools and advanced features",
	},
	{
		name = "SuperAdmin",
		level = 70,
		permissionNode = "moderation.*",
		color = Color3.fromRGB(255, 50, 50), -- Red
		description = "Full moderation capabilities",
	},
	{
		name = "Admin",
		level = 50,
		permissionNode = "moderation.*",
		color = Color3.fromRGB(255, 165, 0), -- Orange
		description = "Standard admin commands",
	},
	{
		name = "Moderator",
		level = 30,
		permissionNode = "moderation.kick,moderation.mute,moderation.warn,moderation.freeze",
		color = Color3.fromRGB(100, 149, 237), -- Blue
		description = "Basic moderation tools",
	},
	{
		name = "VIP",
		level = 10,
		permissionNode = "player.fly,player.noclip",
		color = Color3.fromRGB(0, 255, 127), -- Green
		description = "VIP perks and features",
	},
}

-- ============================================
-- KEYBIND SETTINGS
-- ============================================
Config.KEYBINDS = {
	-- Panel Controls
	TOGGLE_PANEL = Enum.KeyCode.F6,
	TOGGLE_COMMAND_PALETTE = Enum.KeyCode.P,
	COMMAND_BAR = Enum.KeyCode.Quote, -- " key
	
	-- Quick Actions
	QUICK_FLY = Enum.KeyCode.F,
	QUICK_NOCLIP = Enum.KeyCode.N,
	QUICK_GOD = Enum.KeyCode.G,
	
	-- Navigation
	CLOSE_UI = Enum.KeyCode.Escape,
	NEXT_TAB = Enum.KeyCode.Tab,
	
	-- Allow customization
	CUSTOM_KEYBINDS_ENABLED = true,
}

-- ============================================
-- NOTIFICATION SETTINGS
-- ============================================
Config.NOTIFICATIONS = {
	ENABLED = true,
	DEFAULT_DURATION = 4,
	MAX_QUEUE = 10,
	SHOW_DISMISS_BUTTON = true,
	POSITION = UDim2.new(1, -370, 1, -120), -- Top-right corner
	ANIMATION_DURATION = 0.5,
	
	-- Notification types
	TYPES = {
		SUCCESS = {
			color = Color3.fromRGB(76, 175, 80),
			icon = "NotifySuccess", -- Icons.lua slot (Icons.image / Icons.fallback)
		},
		ERROR = {
			color = Color3.fromRGB(244, 67, 54),
			icon = "NotifyError", -- Icons.lua slot (Icons.image / Icons.fallback)
		},
		WARNING = {
			color = Color3.fromRGB(255, 152, 0),
			icon = "NotifyWarning", -- Icons.lua slot (Icons.image / Icons.fallback)
		},
		INFO = {
			color = Color3.fromRGB(33, 150, 243),
			icon = "NotifyInfo", -- Icons.lua slot (Icons.image / Icons.fallback)
		},
	},
}

-- ============================================
-- FLY SETTINGS
-- ============================================
Config.FLY = {
	ENABLED = true,
	DEFAULT_SPEED = 50,
	MIN_SPEED = 1,
	MAX_SPEED = 200,
	BOOST_MULTIPLIER = 2.5,
	SHOW_FLY_GUI = true,
	NOCLIP_ENABLED = true,
	
	-- Controls
	KEY_UP = Enum.KeyCode.Space,
	KEY_DOWN = Enum.KeyCode.LeftShift,
	KEY_FORWARD = Enum.KeyCode.W,
	KEY_BACKWARD = Enum.KeyCode.S,
	KEY_LEFT = Enum.KeyCode.A,
	KEY_RIGHT = Enum.KeyCode.D,
	KEY_BOOST = Enum.KeyCode.LeftControl,
}

-- ============================================
-- MODERATION SETTINGS
-- ============================================
Config.MODERATION = {
	-- Ban Durations (name = seconds)
	BAN_DURATIONS = {
		["5 Minutes"] = 300,
		["30 Minutes"] = 1800,
		["1 Hour"] = 3600,
		["6 Hours"] = 21600,
		["12 Hours"] = 43200,
		["1 Day"] = 86400,
		["3 Days"] = 259200,
		["1 Week"] = 604800,
		["2 Weeks"] = 1209600,
		["1 Month"] = 2592000,
		["Permanent"] = -1,
	},
	
	-- Permission restrictions
	PERM_BAN_OWNER_ONLY = true,
	TEMP_BAN_OWNER_ONLY = false,
	
	-- Auto-escalation
	ENABLE_AUTO_ESCALATION = true,
	WARNING_THRESHOLDS = {
		[3] = "kick",
		[5] = "ban_1d",
		[10] = "ban_permanent",
	},
	
	-- Mute settings
	DEFAULT_MUTE_DURATION = 3600, -- 1 hour
	MAX_MUTE_DURATION = 86400, -- 24 hours
	
	-- Jail settings
	JAIL_HEIGHT = 500, -- Default sky cell height
}

-- ============================================
-- PM SETTINGS
-- ============================================
Config.PM = {
	ENABLED = true,
	MAX_MESSAGE_LENGTH = 500,
	SHOW_NOTIFICATION = true,
	ALLOW_HTML = false,
}

-- ============================================
-- SPEED PRESETS
-- ============================================
Config.SPEED = {
	DEFAULT = 16,
	SLOW = 8,
	FAST = 32,
	SUPER_FAST = 64,
	NOCLIP = 16,
}

-- ============================================
-- THEME SYSTEM
-- ============================================
Config.THEMES = {
	-- Dark Theme (Default Sentinel Theme)
	Dark = {
		Name = "Dark",
		Background = Color3.fromRGB(30, 30, 35),
		Surface = Color3.fromRGB(45, 45, 52),
		Primary = Color3.fromRGB(0, 162, 255),
		Secondary = Color3.fromRGB(100, 100, 115),
		Accent = Color3.fromRGB(138, 43, 226),
		Text = Color3.fromRGB(255, 255, 255),
		TextDim = Color3.fromRGB(180, 180, 190),
		Success = Color3.fromRGB(76, 175, 80),
		Warning = Color3.fromRGB(255, 152, 0),
		Error = Color3.fromRGB(244, 67, 54),
	},
	
	-- Light Theme
	Light = {
		Name = "Light",
		Background = Color3.fromRGB(245, 245, 247),
		Surface = Color3.fromRGB(255, 255, 255),
		Primary = Color3.fromRGB(0, 122, 255),
		Secondary = Color3.fromRGB(142, 142, 147),
		Accent = Color3.fromRGB(175, 82, 222),
		Text = Color3.fromRGB(0, 0, 0),
		TextDim = Color3.fromRGB(99, 99, 102),
		Success = Color3.fromRGB(52, 199, 89),
		Warning = Color3.fromRGB(255, 149, 0),
		Error = Color3.fromRGB(255, 59, 48),
	},
	
	-- Midnight Theme
	Midnight = {
		Name = "Midnight",
		Background = Color3.fromRGB(15, 15, 20),
		Surface = Color3.fromRGB(25, 25, 32),
		Primary = Color3.fromRGB(88, 166, 255),
		Secondary = Color3.fromRGB(72, 72, 82),
		Accent = Color3.fromRGB(187, 134, 252),
		Text = Color3.fromRGB(232, 234, 237),
		TextDim = Color3.fromRGB(154, 160, 166),
		Success = Color3.fromRGB(129, 199, 132),
		Warning = Color3.fromRGB(255, 167, 38),
		Error = Color3.fromRGB(239, 83, 80),
	},
	
	-- Ocean Theme
	Ocean = {
		Name = "Ocean",
		Background = Color3.fromRGB(13, 27, 42),
		Surface = Color3.fromRGB(27, 38, 59),
		Primary = Color3.fromRGB(65, 179, 163),
		Secondary = Color3.fromRGB(119, 141, 169),
		Accent = Color3.fromRGB(228, 193, 129),
		Text = Color3.fromRGB(224, 225, 221),
		TextDim = Color3.fromRGB(168, 173, 179),
		Success = Color3.fromRGB(100, 221, 123),
		Warning = Color3.fromRGB(255, 179, 71),
		Error = Color3.fromRGB(255, 107, 107),
	},
}

Config.DEFAULT_THEME = "Dark"

-- ============================================
-- UI SETTINGS
-- ============================================
Config.UI = {
	-- Panel dimensions
	DEFAULT_WIDTH = 900,
	DEFAULT_HEIGHT = 600,
	MIN_WIDTH = 600,
	MIN_HEIGHT = 400,
	
	-- Animation
	ANIMATION_SPEED = 0.3,
	
	-- Font
	FONT = Enum.Font.Gotham,
	FONT_BOLD = Enum.Font.GothamBold,
	
	-- Corner radius
	CORNER_RADIUS = UDim.new(0, 12),
	
	-- Drag settings
	DRAGGABLE = true,
	RESIZABLE = true,
	
	-- ZIndex
	Z_INDEX = 10,
}

-- ============================================
-- PERMISSION BINDING METHODS
-- ============================================
Config.PERMISSION_BINDINGS = {
	-- Method types
	METHODS = {
		"Username",
		"UserId",
		"GroupId",
		"GroupRole",
		"GamePassId",
		"AssetId",
	},
	
	-- Enable/disable specific binding methods
	ENABLE_GROUP_BINDINGS = true,
	ENABLE_GAMEPASS_BINDINGS = true,
	ENABLE_ASSET_BINDINGS = true,
	
	-- Auto-rank settings
	FREE_ADMIN_RANK = "None", -- Rank given to all players by default
	PRIVATE_SERVER_OWNER_RANK = "VIP", -- Rank given to private server owners
}

-- ============================================
-- COMMAND SETTINGS
-- ============================================
Config.COMMANDS = {
	-- Prefix options
	ALLOWED_PREFIXES = { ";", "/", "!", "." },
	DEFAULT_PREFIX = ";",
	
	-- Aliases
	ENABLE_ALIASES = true,
	
	-- Cooldowns
	DEFAULT_COOLDOWN = 1,
	MAX_COOLDOWN = 60,
	
	-- Logging
	LOG_ALL_COMMANDS = true,
	MAX_LOG_ENTRIES = 1000,
}

-- ============================================
-- SERVER SETTINGS
-- ============================================
Config.SERVER = {
	-- Auto-lock
	AUTO_LOCK_ON_START = false,
	
	-- Maintenance
	MAINTENANCE_MESSAGE = "Server is under maintenance. Please try again later.",
	
	-- Announcements
	ANNOUNCEMENT_DURATION = 8,
	
	-- Countdown
	DEFAULT_COUNTDOWN_DURATION = 10,
}

-- ============================================
-- ENVIRONMENT SETTINGS
-- ============================================
Config.ENVIRONMENT = {
	-- Time presets
	TIME_PRESETS = {
		Day = 14,
		Night = 0,
		Sunset = 18,
		Dawn = 6,
	},
	
	-- Weather presets
	WEATHER_PRESETS = {
		Clear = { FogEnd = 100000, FogStart = 0 },
		Foggy = { FogEnd = 100, FogStart = 0 },
		Rainy = { FogEnd = 500, FogStart = 0 },
	},
	
	-- Lighting presets
	LIGHTING_PRESETS = {
		Default = {
			Ambient = Color3.fromRGB(170, 170, 170),
			Brightness = 2,
			OutdoorAmbient = Color3.fromRGB(128, 128, 128),
		},
	},
}

-- ============================================
-- DEVELOPER SETTINGS
-- ============================================
Config.DEVELOPER = {
	-- Remote monitoring
	MONITOR_REMOTES = true,
	MAX_REMOTE_LOG_ENTRIES = 500,
	
	-- Error console
	MAX_ERROR_LOG_ENTRIES = 200,
	
	-- DataStore settings
	ALLOW_DATASTORE_ACCESS = true, -- Owner only by default
	
	-- Script execution
	ALLOW_SCRIPT_EXECUTION = true, -- Owner only by default
}

-- ============================================
-- HELPERS
-- ============================================
function Config.GetTheme(themeName)
	return Config.THEMES[themeName] or Config.THEMES[Config.DEFAULT_THEME]
end

function Config.GetRank(rankName)
	for _, rank in ipairs(Config.RANKS) do
		if rank.name == rankName then
			return rank
		end
	end
	return nil
end

function Config.GetRankByLevel(level)
	for _, rank in ipairs(Config.RANKS) do
		if rank.level == level then
			return rank
		end
	end
	return nil
end

function Config.GetBanDuration(durationName)
	return Config.MODERATION.BAN_DURATIONS[durationName] or 86400
end

function Config.GetNotificationType(typeName)
	return Config.NOTIFICATIONS.TYPES[typeName] or Config.NOTIFICATIONS.TYPES.INFO
end

return Config
