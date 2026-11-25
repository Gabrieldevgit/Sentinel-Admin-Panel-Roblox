--!strict
-- Icons.lua
-- Central icon config for the Sentinel UI.
--
-- HOW TO USE
--   1. Upload the icon PNGs to Roblox (Creator Hub / Asset Manager).
--   2. Paste each **Image** asset ID into `Assets` below (number or "rbxassetid://...").
--      Creator Hub lists the *Decal* ID; the Image ID is the decal's Texture
--      (InsertService:LoadAsset(decalId) -> Decal.Texture). Decal IDs don't load.
--   3. That's it - every UI slot mapped to that asset switches from its emoji
--      fallback to the real image. A slot with no ID keeps its emoji.
--
-- `Assets`  : file name in assets/icons (without .png) -> uploaded asset ID.
-- `Slots`   : UI slot -> { Asset = asset name or nil, Fallback = emoji }.
--             Point a slot at a different asset (or add a new asset) here.

local Icons = {}

Icons.Assets = {
	Admins = 75393612739763,
	Analitics2 = 84367642831409,
	AnnounceButton = 140676976275068,
	Announcement2 = 88681310986422,
	Clean = 112755355882896,
	CommandLibrary = 78622918834574,
	Commands = 134476976130536,
	ComputerChip = 98615764680230,
	Copy = 109181584148389,
	Dashboard = 106977093828253,
	Delete = 96381851098163,
	DevIcon = 118680516194419,
	Download = 105758803174690,
	Economy = 89057930891476,
	Export = 81966285463693,
	FreezeIcon = 97346026263366,
	Fullscreen = 102209179800763,
	Global = 75280838877193,
	GreenDot = 78272763557123,
	GreyDot = 126510096064440,
	HalfArrow = 119366241144061,
	Heal = 75784179665185,
	HomeButton = 124602855090569,
	Location = 95991869920760,
	LockIcon = 131392182046713,
	Logs = 74332561903541,
	Map = 112940083602376,
	MayBeAnalists2 = 88822233173148,
	Moderator = 88042123483959,
	NotificationsAwaiting = 114041087723768,
	NotificationsCleared = 101933812034876,
	OnePersonButton = 118448192393365,
	OwnerIcon = 104657891265955,
	PeopleButton = 77751677623270,
	QuickActions = 115802439059979,
	Slowmode = 128960804935013,
	Weather = 74393414138356,
	Lighting = 121888298662628,
	MuteNotification = 126818904403331,
	ReduceMotion = 81716155951159,
	Appearances = 93806010894774,
	Warning = 112787170297889,
	Clock = 80859681680827,
	Keybinds = 136240084630331,
	RedDot = 112956224929391,
	Refresh = 81319011075373,
	Restricted = 133724571408454,
	Rezize = 96096081192427,
	Search = 127673140135431,
	ServersButton = 112336279232148,
	SettingsButton = 104970841426837,
	ShieldAdminButton = 131595323726423,
	Star = 72275532714634,
	Stats1 = 128062831354874,
	SuperAdmin = 121860408116849,
	TextChatButton = 87286845920893,
	ThreeDots2 = 75201883353827,
	Timer = 99334791346026,
	ToolsIcon = 104487632589104,
	Update = 133527861574445,
	VIP = 101082235932554,
	-- Speaker icons (Decals 85550394171391 / 124944718313615 -> Image ids)
	SoundIcon = 137866142678538,
	MuteSoundIcon = 86539800505739,
	-- Seasonal themes: Image ids go here (0 = not uploaded yet).
	--   *Badge   256x256 next to "Sentinel" in the title bar (replaces the S badge)
	--   *Topbar  256x256 replaces the "S" glyph of the top-bar button
	--   *Corner  ~512x256 faint decoration in the window's top-right corner
	ChristmasBadge = 81034076516220, -- snowflake (Decal 71558051820273)
	ChristmasTopbar = 128733180980740, -- star (Decal 101040650665411)
	ChristmasCorner = 73493654316616, -- light-string (Decal 104986065322595)
	-- Hat perched on the "Sentinel" title (Christmas). The upload didn't load
	-- yet (2026-11-23: "asset not found", likely moderation) - if it never
	-- shows, it's a Decal id: resolve to the Image id with InsertService.
	ChristmasHat = 128416464466695,
	HalloweenBadge = 124129872373184, -- pumpkin-jack-1 (Decal 113525435087524)
	HalloweenTopbar = 111403351128177, -- bat-medium (Decal 133579110607153)
	HalloweenCorner = 133145944015039, -- light-string (Decal 77859948330509)
}

type Slot = { Asset: string?, Fallback: string }

Icons.Slots = {
	-- Sidebar sections & pages
	Dashboard = { Asset = "Dashboard", Fallback = "🏠" },
	PlayersSection = { Asset = "PeopleButton", Fallback = "👥" },
	Players = { Asset = "PeopleButton", Fallback = "👥" },
	Lookup = { Asset = "Search", Fallback = "🔎" },
	ModerationSection = { Asset = "ShieldAdminButton", Fallback = "🛡" },
	Moderation = { Asset = "ShieldAdminButton", Fallback = "🛡" },
	Ranks = { Asset = "OwnerIcon", Fallback = "👑" },
	Reports = { Asset = "Warning", Fallback = "🚩" },
	Appeals = { Asset = "Moderator", Fallback = "⚖" },
	ChatLog = { Asset = "TextChatButton", Fallback = "💬" },
	-- Seasonal themes (UIPrefs.SEASONAL). Fill the asset ids in Icons.Assets
	-- (keys below); while empty the themes show colours only.
	ChristmasBadge = { Asset = "ChristmasBadge", Fallback = "" },
	ChristmasTopbar = { Asset = "ChristmasTopbar", Fallback = "" },
	ChristmasCorner = { Asset = "ChristmasCorner", Fallback = "" },
	ChristmasHat = { Asset = "ChristmasHat", Fallback = "" },
	HalloweenBadge = { Asset = "HalloweenBadge", Fallback = "" },
	HalloweenTopbar = { Asset = "HalloweenTopbar", Fallback = "" },
	HalloweenCorner = { Asset = "HalloweenCorner", Fallback = "" },
	Alerts = { Asset = "NotificationsAwaiting", Fallback = "⚠" },
	CommandsSection = { Asset = "Commands", Fallback = "📜" },
	Commands = { Asset = "Commands", Fallback = "📜" },
	Library = { Asset = "CommandLibrary", Fallback = "📚" },
	ServerSection = { Asset = "ServersButton", Fallback = "🌎" },
	Server = { Asset = "ServersButton", Fallback = "🌎" },
	CrossServer = { Asset = "Global", Fallback = "🌐" },
	Economy = { Asset = "Economy", Fallback = "💰" },
	AnnouncementsSection = { Asset = "AnnounceButton", Fallback = "📢" },
	AnnounceHistory = { Asset = "Timer", Fallback = "🕘" },
	AnnounceServer = { Asset = "AnnounceButton", Fallback = "📢" },
	AnnounceGlobal = { Asset = "Global", Fallback = "🌐" },
	AnnouncePlayers = { Asset = "OnePersonButton", Fallback = "👤" },
	Polls = { Asset = "Analitics2", Fallback = "📊" },
	Events = { Asset = "Timer", Fallback = "🎉" },
	InsightsSection = { Asset = "Stats1", Fallback = "📈" },
	ModulesSection = { Asset = "ToolsIcon", Fallback = "🧩" },
	Modules = { Asset = "ToolsIcon", Fallback = "🧩" },
	Analytics = { Asset = "Stats1", Fallback = "📈" },
	Logs = { Asset = "Logs", Fallback = "📋" },
	Developer = { Asset = "DevIcon", Fallback = "🔧" },
	SettingsSection = { Asset = "SettingsButton", Fallback = "⚙" },
	Settings = { Asset = "SettingsButton", Fallback = "⚙" },
	Appearance = { Asset = "Appearances", Fallback = "🎨" },
	Keybinds = { Asset = "Keybinds", Fallback = "⌨" },
	Sounds = { Asset = "SoundIcon", Fallback = "🔊" },
	SoundOn = { Asset = "SoundIcon", Fallback = "🔊" },
	SoundOff = { Asset = "MuteSoundIcon", Fallback = "🔇" },
	Administration = { Asset = "ToolsIcon", Fallback = "🛠" },
	Notifications = { Asset = "NotificationsCleared", Fallback = "🔔" },

	-- Top bar
	Bell = { Asset = "NotificationsCleared", Fallback = "🔔" },
	Gear = { Asset = "SettingsButton", Fallback = "⚙" },

	-- Quick actions / server toggles
	Announce = { Asset = "AnnounceButton", Fallback = "📢" },
	Freeze = { Asset = "FreezeIcon", Fallback = "❄" },
	QuickActionsHeader = { Asset = "QuickActions", Fallback = "" },
	DevPerformance = { Asset = "Stats1", Fallback = "" },
	DevConsole = { Asset = "Commands", Fallback = "" },
	DevRemotes = { Asset = "Global", Fallback = "" },
	DevDataStores = { Asset = "ComputerChip", Fallback = "" },
	Lock = { Asset = "LockIcon", Fallback = "🔒" },
	Maintenance = { Asset = "ToolsIcon", Fallback = "🛠" },
	Shutdown = { Asset = "Restricted", Fallback = "⛔" },
	Heal = { Asset = "Heal", Fallback = "💖" },
	Cleanup = { Asset = "Clean", Fallback = "🧹" },
	Spawn = { Asset = "Location", Fallback = "📍" },
	TimeFreeze = { Asset = "Timer", Fallback = "⏱" },
	Weather = { Asset = "Weather", Fallback = "☁" },
	Lighting = { Asset = "Lighting", Fallback = "💡" },
	Slowmode = { Asset = "Slowmode", Fallback = "🐢" },

	-- Top bar
	Search = { Asset = "Search", Fallback = "🔍" },
	Clock = { Asset = "Clock", Fallback = "🕒" },

	-- Risk tags (Command Palette)
	RiskWarning = { Asset = "Warning", Fallback = "⚠" },
	RiskCritical = { Asset = "Restricted", Fallback = "⛔" },

	-- Settings page
	Permissions = { Asset = "LockIcon", Fallback = "🔐" },
	Preferences = { Asset = "SettingsButton", Fallback = "⚙" },
	MuteToasts = { Asset = "MuteNotification", Fallback = "🔕" },
	ReduceMotion = { Asset = "ReduceMotion", Fallback = "🎞" },
	PaletteHistory = { Asset = "CommandLibrary", Fallback = "📜" },
	NotImplemented = { Asset = "Warning", Fallback = "🚧" },
	Discord = { Asset = "TextChatButton", Fallback = "💬" },
	TwoFactor = { Asset = "LockIcon", Fallback = "🔒" },
	Refresh = { Asset = "Refresh", Fallback = "↻" },

	-- Notification kinds (Config.NOTIFICATIONS.TYPES); no image = emoji
	NotifySuccess = { Asset = nil, Fallback = "✓" },
	NotifyError = { Asset = "Restricted", Fallback = "✗" },
	NotifyWarning = { Asset = "Warning", Fallback = "⚠" },
	NotifyInfo = { Asset = nil, Fallback = "ℹ" },
} :: { [string]: Slot }

-- Returns "rbxassetid://N" for a slot (or asset name), or nil if not uploaded yet.
function Icons.image(key: string): string?
	if type(key) ~= "string" then
		return nil
	end
	if string.match(key, "^rbxassetid://%d+$") or string.match(key, "^rbxasset://") then
		return key -- a raw content id (e.g. a rank's Icon field)
	end
	local slot = Icons.Slots[key]
	local assetName = if slot then slot.Asset else key
	if not assetName then
		return nil
	end
	local id = (Icons.Assets :: any)[assetName]
	if id == nil or id == 0 or id == "" then
		return nil
	end
	if type(id) == "number" then
		return "rbxassetid://" .. id
	end
	return if string.find(id, "://") then id else "rbxassetid://" .. id
end

-- Rank badges: a rank's Icon field may name an asset ("OwnerIcon") or hold
-- an "rbxassetid://N"; otherwise the default ranks use these badges and any
-- other rank keeps its emoji.
Icons.RankBadges = {
	Owner = "OwnerIcon",
	Developer = "DevIcon",
	SuperAdmin = "SuperAdmin",
	Admin = "Admins",
	Moderator = "Moderator",
	VIP = "VIP",
}

-- Icon key for a rank ({ Name, Icon }), or nil to show rank.Icon as text.
function Icons.rankKey(rank: { Name: string?, Icon: string? }?): string?
	if not rank then
		return nil
	end
	local icon = rank.Icon
	if type(icon) == "string" and icon ~= "" and Icons.image(icon) then
		return icon
	end
	local badge = Icons.RankBadges[rank.Name or ""]
	return if badge and Icons.image(badge) then badge else nil
end

-- Emoji fallback for a slot (an unknown key is returned as-is, so raw emoji still work).
function Icons.fallback(key: string): string
	local slot = Icons.Slots[key]
	return if slot then slot.Fallback else key
end

-- Text to put where the emoji used to be: the emoji when there is no image,
-- otherwise blank spaces that reserve room for the ImageLabel.
function Icons.text(key: string, blank: string?): string
	if Icons.image(key) then
		return blank or "    "
	end
	return Icons.fallback(key)
end

-- Adds (or updates) an ImageLabel named "IconImage" inside `parent`.
-- Returns it, or nil when the slot has no uploaded image (caller keeps the emoji).
-- opts.Size (px, default 18), opts.X (left offset px; nil = centered).
function Icons.attach(parent: Instance, key: string, opts: { Size: number?, X: number? }?): ImageLabel?
	local image = Icons.image(key)
	local existing = parent:FindFirstChild("IconImage") :: ImageLabel?
	if not image then
		if existing then
			existing:Destroy()
		end
		return nil
	end
	local o = opts or {}
	local size = o.Size or 18
	local label = existing or Instance.new("ImageLabel")
	label.Name = "IconImage"
	label.BackgroundTransparency = 1
	label.Image = image
	label.ScaleType = Enum.ScaleType.Fit
	label.Size = UDim2.fromOffset(size, size)
	label.ZIndex = (parent :: any).ZIndex and (parent :: any).ZIndex + 1 or 1
	Icons.place(label, o.X)
	label.Parent = parent
	return label
end

-- Positions an attached icon: left-aligned at `x` px, or centered when x is nil.
-- Turns a TextLabel/TextButton into "[icon]  text": sets the text (with
-- blank room for the icon when an image exists) and attaches the image at
-- `x` px (default 0). Safe to call again to change the text.
function Icons.prefix(label: TextLabel | TextButton, key: string, text: string, size: number?, x: number?)
	local px = size or 16
	local blanks = ""
	if Icons.image(key) then
		local spaceWidth = math.max(3, label.TextSize * 0.28)
		blanks = string.rep(" ", math.ceil((px + 2) / spaceWidth))
	end
	label.Text = (if blanks ~= "" then blanks else Icons.fallback(key)) .. "  " .. text
	local img = Icons.attach(label, key, { Size = px, X = x or 0 })
	-- Centered text: keep the icon glued to the start of the text.
	if img and label.TextXAlignment == Enum.TextXAlignment.Center then
		Icons.follow(label)
		if not label:GetAttribute("IconFollow") then
			label:SetAttribute("IconFollow", true)
			label:GetPropertyChangedSignal("Text"):Connect(function()
				Icons.follow(label)
			end)
			label:GetPropertyChangedSignal("TextSize"):Connect(function()
				Icons.follow(label)
			end)
		end
	end
end

-- Places the IconImage of a centered label at the start of its text
-- (or centered when the label holds only blank room for the icon).
function Icons.follow(label: TextLabel | TextButton)
	local icon = label:FindFirstChild("IconImage") :: ImageLabel?
	if not icon then
		return
	end
	if string.match(label.Text, "^%s*$") then
		Icons.place(icon, nil)
	elseif label.TextXAlignment == Enum.TextXAlignment.Center then
		-- TextService width is unscaled (TextBounds includes UIScale).
		local w = game:GetService("TextService"):GetTextSize(label.Text, label.TextSize, label.Font, Vector2.new(10000, 1000)).X
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0.5, -math.floor(w / 2), 0.5, 0)
	end
end

function Icons.place(label: ImageLabel, x: number?)
	if x then
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.Position = UDim2.new(0, x, 0.5, 0)
	else
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
	end
end

return Icons
