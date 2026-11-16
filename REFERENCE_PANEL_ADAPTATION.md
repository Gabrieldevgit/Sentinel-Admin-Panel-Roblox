# Sentinel Admin Panel - Reference Panel Adaptation

This document describes the features adapted from the Old Admin Panel V4.3 reference and integrated into Sentinel.

## 📋 Features Adapted

### 1. In-Game Menu Settings (Account > Settings)

**Location**: `InGameSettingsPage.lua`

Adapted from the reference panel's Settings tab with the following features:

#### Custom Keybinds
- Toggle Panel key (Default: F6)
- Command Palette key (Default: P)
- Command Bar key (Default: Quote ")
- Quick Fly key (Default: F)
- Quick Noclip key (Default: N)
- Quick God key (Default: G)

Users can click any keybind to reassign it to their preferred key. All keybinds are stored in the centralized Config module.

#### Theme System
- **4 Built-in Themes**:
  - Dark (default Sentinel theme)
  - Light
  - Midnight
  - Ocean

- **Theme Import/Export**:
  - Export current theme as JSON string
  - Paste custom theme JSON to instantly apply
  - Full color customization (Background, Surface, Primary, Secondary, Accent, Text, Success, Warning, Error)

#### Preferences
- Show Notification Toasts
- Reduce Motion Effects
- Show Fly GUI
- Enable Noclip
- Auto-close Panel after Command

---

### 2. Permissions & Rank Configuration (Studio Configuration)

**Location**: `RankManagementPage.lua`

Comprehensive rank management system for game owners:

#### User & Admin Ranks
- **6 Default Ranks**:
  - Owner (Level 100) - Gold, full access
  - Developer (Level 80) - Magenta, developer tools
  - SuperAdmin (Level 70) - Red, full moderation
  - Admin (Level 50) - Orange, standard commands
  - Moderator (Level 30) - Blue, basic moderation
  - VIP (Level 10) - Green, VIP perks

#### Permission Binding Methods
1. **Username Binding**: Assign ranks by Roblox Username
2. **User ID Binding**: Assign ranks by Roblox User ID
3. **Group Binding**: Link ranks to Roblox Group roles (GroupId:RoleId)
4. **GamePass Binding**: Grant ranks for GamePass ownership
5. **Asset Binding**: Grant ranks for asset ownership

#### Rank Management Features
- Search admin list
- Edit existing admin ranks
- Remove admins from list
- Visual rank badges with color coding
- Binding method display

---

### 3. Core System & Command Properties

**Location**: `Config.lua`

Centralized configuration system:

#### Command Settings
- Configurable command prefix (default: `;`)
- Support for multiple prefixes (`;`, `/`, `!`, `.`)
- Command aliases enabled
- Configurable cooldowns (1-60 seconds)
- Command logging with max entries

#### Moderation Settings
- **Ban Durations**: 5m, 30m, 1h, 6h, 12h, 1d, 3d, 1w, 2w, 1mo, Permanent
- **Permission Restrictions**:
  - Permanent ban: Owner only
  - Temp ban: Configurable
- **Auto-escalation**: Warnings escalate to kicks/bans
- **Mute Settings**: Default 1 hour, max 24 hours
- **Jail Settings**: Default sky cell height (500 studs)

#### Server Settings
- Auto-lock on start
- Maintenance mode with custom message
- Announcement duration (8 seconds default)
- Countdown settings

#### Environment Settings
- **Time Presets**: Day, Night, Sunset, Dawn
- **Weather Presets**: Clear, Foggy, Rainy
- **Lighting Presets**: Default with ambient/brightness/outdoor ambient

---

### 4. Tabbed Controls & Server Toggles

**Location**: Integrated throughout UI system

#### Moderation Controls
- Persistent ban durations (backed by DataStores)
- Ban type selection (Permanent vs Temporary)
- Duration picker with all preset durations
- Reason input for all moderation actions

#### Environment Mechanics
- Global toggles for Server Lock
- Maintenance Mode
- Custom ambient music volume
- Day/night cycle speeds
- Physics adjustments (gravity)
- Weather presets
- Lighting presets

---

### 5. Player Controls System

**Location**: `PlayerControlsSystem.lua`

Adapted from the reference panel's fly/effects systems:

#### Fly System
- **BodyGyro/BodyVelocity-based flight**
- **Configurable speed** (1-200, default 50)
- **Speed boost** (2.5x multiplier with Left Control)
- **Movement controls**:
  - WASD: Horizontal movement
  - Space: Up
  - Left Shift: Down
  - Left Control: Speed boost
- **Anti-cheat bypass** via humanoid state manipulation
- **Fly GUI overlay** with:
  - Speed slider
  - Noclip toggle
  - Stop flying button

#### Noclip System
- Toggleable noclip mode
- Disables collisions on all character parts
- Integrated with Fly system
- Can be used independently

#### God Mode System
- Infinite health
- Auto-heal on damage
- Toggleable via keybind

#### View System
- Spectate other players
- Camera subject switching
- Press V to stop viewing

#### Visual Effects
- Fire effect
- Smoke effect
- Sparkles effect
- ForceField effect
- PointLight effect

#### Appearance Changes
- Invisible/Visible toggle
- Material changes:
  - Neon
  - Glass
  - Gold
  - Silver
  - Normal (reset)

---

### 6. Ban Prompt System

**Location**: `BanPromptSystem.lua`

Professional moderation prompt system:

#### Ban Prompt Features
- **Ban Type Selection**:
  - Temporary Ban (with duration picker)
  - Permanent Ban (owner-only)
- **Duration Selection**:
  - All predefined durations from Config
  - Visual selection buttons
  - Auto-expire indicator
- **Reason Input**:
  - Multi-line text input
  - Optional (defaults to "No reason provided")
- **Permission Checks**:
  - Owner-only permanent ban enforcement
  - Visual permission indicators

#### Kick Prompt
- Reason input (optional)
- Clean confirmation dialog
- Player notification

#### PM (Private Message) System
- Character limit enforcement
- Character counter
- Multi-line message support
- Target player selection

---

## 🎨 UI/UX Features

### Notification System
- Toast notifications with dismiss button
- Configurable duration
- Queue system (max 10)
- Animation (slide in/out)
- Color-coded by type (Success, Error, Warning, Info)

### Panel Features
- **Draggable**: Click and drag title bar
- **Resizable**: Min 600x400, default 900x600
- **Minimizable**: Collapse to sidebar
- **Closable**: Via X button or Escape key
- **Themeable**: All 4 themes + custom import

### Status Bar
- FPS counter
- Ping display
- Memory usage
- Player count
- Server status
- Notification indicator

---

## 🔧 Technical Implementation

### Configuration Architecture
```lua
Config/
├── GENERAL (version, prefix, limits)
├── RANKS (hierarchy, permissions, colors)
├── KEYBINDS (all keyboard shortcuts)
├── NOTIFICATIONS (toast settings)
├── FLY (flight mechanics)
├── MODERATION (ban/mute/jail settings)
├── PM (private message limits)
├── SPEED (movement presets)
├── THEMES (color palettes)
├── UI (panel dimensions, fonts)
├── PERMISSION_BINDINGS (methods for granting ranks)
├── COMMANDS (prefixes, cooldowns, logging)
├── SERVER (lock, maintenance, announcements)
├── ENVIRONMENT (time, weather, lighting)
└── DEVELOPER (remote monitoring, console)
```

### Module Structure
```
SentinelUI/
├── Config.lua (centralized configuration)
├── Theme.lua (theme management)
├── Shell.lua (main panel container)
├── InGameSettingsPage.lua (keybinds, themes, preferences)
├── RankManagementPage.lua (permission bindings)
├── PlayerControlsSystem.lua (fly, noclip, effects)
├── BanPromptSystem.lua (moderation prompts)
├── CommandPalette.lua (command interface)
├── DashboardPage.lua (overview)
├── PlayersPage.lua (player explorer)
├── ModerationPage.lua (moderation queue)
├── ServerPage.lua (server controls)
├── EconomyPage.lua (currency/XP/badges)
├── DeveloperPage.lua (dev tools)
├── SettingsPage.lua (permissions viewer)
├── NotificationCenter.lua (toast system)
├── QuickActionsPanel.lua (quick actions)
├── ConfirmDialog.lua (confirmation dialogs)
└── ToggleSwitch.lua (shared component)
```

---

## 🚀 Usage

### Opening the Panel
Press **F6** (configurable) to toggle the admin panel.

### Opening Command Palette
Press **Ctrl+Shift+P** or click the search bar to open the command palette.

### Quick Actions
- **F** - Toggle Fly mode
- **N** - Toggle Noclip
- **G** - Toggle God mode
- **V** - Stop viewing player

### Customizing Keybinds
1. Open the panel (F6)
2. Navigate to Settings > Keybinds
3. Click any keybind button
4. Press the new key
5. Press Escape to cancel

### Changing Theme
1. Open the panel (F6)
2. Navigate to Settings > Theme
3. Click any theme button
4. Or paste custom theme JSON

### Managing Ranks
1. Open the panel (F6)
2. Navigate to Rank Management
3. Choose binding method (Username/ID/Group/GamePass)
4. Enter the value
5. Select rank
6. Click Add

---

## 📝 Notes

- All features are permission-gated
- Owner-only features have visual indicators
- All moderation actions are logged
- Settings persist for the session
- Configuration is centralized in Config.lua
- All UI components use the shared Theme system
- Fly system includes anti-cheat bypass
- Ban durations are backed by DataStores

---

## 🔗 Related Files

- `/reference/OldAdminPanel/extracted_source_fragments.txt` - Original reference code
- `/reference/OldAdminPanel/README.md` - Reference panel documentation
- `/reference/UI-UX-design-docs/` - Design specifications
- `/src/ReplicatedStorage/Shared/Sentinel/Config.lua` - Central configuration
- `/src/StarterGui/SentinelUI/` - UI implementation
