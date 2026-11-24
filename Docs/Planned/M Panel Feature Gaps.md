# "M" panel feature gaps (planned)

Source: the panel that opens with **M** in the client - the user's earlier
"Sentinel / Halloween" panel in the testing place (not in the repo):
`StarterPlayer.StarterPlayerScripts.AdminPanel` (12 LocalScripts: shell,
Core, ActionsModeration, settings/chat/warnings, Profile, Servers,
Whitelist, StaffActivity, HalloweenTheme / HalloweenClient) and
`ServerScriptService.AdminPanelServer` (folder: AdminHandler,
AdminHandlerData, AdminServerShared, HalloweenCommands; remotes in
`ReplicatedStorage.AdminEvents`). Explored 2026-11-23. Features only.

Its tabs: Dashboard (activity feed, server stats, command box with
autocomplete), Commands, Halloween, Actions, Moderation, Profile, Settings,
Chat Log, Alerts, Warnings, Audit Log, Servers, Whitelist, Staff. Its 49
commands: kick ban unban mute unmute kill speed teleport bring freeze fly
unfreeze jail unjail spectate invisible visible resetstats noclip whisper
grantrole revokerole restart cancelrestart lock whitelist kickall freezeall
unfreezeall killall healall respawnall bringall muteall unmuteall shutdown
cancelshutdown message respawn god heal warn unwarn sit ragdoll settime fog
explode size rainbow confetti to health note removenote logs, plus
Halloween: pumpkin ghost bats spooky unspooky clearhalloween.

## Already in Sentinel

Every moderation / movement / "all players" action (Sentinel targets
`all`, so `;heal all` = healall etc.), lock / whitelist / kick all, server
list + join, server performance stats, profile lookup + notes + quick
moderation, ban list + unban, warnings, audit log + export, panel settings
reset, PMs (= whisper). Its "grant temporary role (this server only)" is
covered by rank assignments with an expiry (`;assignrank name:1h Rank`).

## Worth adding

### Server chat log page (no W row yet)
- A staff page with the server's recent chat (all players, newest first,
  search, clear). Sentinel already captures the last 15 lines per player
  for reports (ReportService) - widen that to a server-wide buffer.

### Staff activity page (fits W16 Analytics)
- Per-session summary of staff actions by type (bans, kicks, warns,
  mutes, freezes, heals, teleports, fun) + online staff + recent actions.
  Sentinel's moderation dashboard only has moderation counts and top
  moderators.

### Alerts feed (small)
- A separate list of "alert"-level events (time changes, mass actions,
  joins of flagged players) apart from the general notifications.

### Shutdown / restart control (W22 leftover)
- **Cancel a pending shutdown or restart** (`cancelshutdown`,
  `cancelrestart`): Sentinel's `;shutdown [seconds]` can't be cancelled.
- **Scheduled restart** with automatic warnings at 5m / 2m / 1m / 30s /
  10s (Sentinel only shows one countdown).

### Broadcast templates (small, Announcements)
- Saved message templates + a character counter in the broadcast box.

### Fun / character
- `rainbow` (cycling body colour), `confetti` (particle burst), `size`
  (already in the HD Admin list, W30), set exact `health` (Sentinel has
  heal / damage / maxhealth only), `resetstats` (reset a player's
  leaderstats - W28).

### Seasonal themes + events (W25 event library)
- A seasonal panel theme (Halloween palette + title) switchable on/off.
- Seasonal effects: Pumpkin Head, Ghost Form, Bat Swarm on a player;
  **Spooky Night** as a server-wide event (dark lighting + fog), and a
  "clear all seasonal effects" command. Spooky Night fits next to Blood
  Moon / Snow Day in W25. Pumpkin / ghost / bats need meshes or parts,
  no custom animations - allowed.
