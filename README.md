# Sentinel

An enterprise-grade Live Operations Platform for Roblox — administration,
moderation, developer tools, analytics, cross-server coordination, and
player controls, unified under one command grammar.

Phases 1–5 are complete and battle-tested in Studio. Phase 6 (Analytics &
Audit) is intentionally deferred until after Phase 7. **Phase 7 (UI/UX)
is in progress** — a dark "Mission Control"-style dockable panel — and is
the current focus. See the Roadmap status section below for exactly
what's built versus still coming.

## What's implemented

| System | File | Notes |
|---|---|---|
| Shared types | `ReplicatedStorage/Shared/Sentinel/Types.lua` | Every module imports from here — one contract, no drift |
| Signal / EventBus | `.../Signal.lua`, `.../EventBus.lua` | Decouples systems; publish/subscribe by topic string |
| Logger | `ServerScriptService/Sentinel/Core/Logger.lua` | Buffered, async-flushed, pluggable sinks (Studio print sink included) |
| PermissionSystem | `.../Core/PermissionSystem.lua` | Node-based (`moderation.ban`), wildcard (`moderation.*`), role inheritance, temporary grants |
| CommandRegistry | `.../Core/CommandRegistry.lua` | Self-registration, aliases, categories, cooldowns, permission+log enforcement on every dispatch |
| Tokenizer | `.../Core/Parser/Tokenizer.lua` | Quoted strings, `&&` chaining, `target:modifier` split |
| DurationParser | `.../Core/Parser/DurationParser.lua` | `30m 2d 1w 1mo 1y forever perm` |
| QuantityParser | `.../Core/Parser/QuantityParser.lua` | Numeric modifiers for economy/inventory commands |
| TargetResolver | `.../Core/Parser/TargetResolver.lua` | `me all others random nearest last`, `@team @role @group @rank @vip @staff`, `#tag`, `@level >25`, `where Health<50` |
| CommandParser | `.../Core/Parser/CommandParser.lua` | Full grammar: `/command target[:modifier] [subcommand] [arguments...]` |
| CommandProcessor | `.../Core/Parser/CommandProcessor.lua` | The one function chat/UI calls; walks `&&` chains, stops on first failure |
| Example commands | `Commands/Moderation/Kick.lua`, `Ban.lua` | Show self-registration + DataStore persistence + Undoable contract |
| PunishmentService | `Systems/PunishmentService.lua` | Warning ledger + configurable auto-escalation (data-driven, not hardcoded) |
| ChatModerationService | `Systems/ChatModerationService.lua` | Mute enforcement via `TextChannel.ShouldDeliverCallback` |
| Moderator Toolkit commands | `Commands/Moderation/Mute.lua`, `Warn.lua`, `Jail.lua`, `Freeze.lua`, `Note.lua`, `AccessList.lua` | `/mute /unmute /warn /warnings /jail /unjail /freeze /unfreeze /note /notes /blacklist /whitelist /whitelistmode` |
| Bootstrap | `ServerScriptService/Sentinel/init.server.lua` | Starter roles, loads every Systems + Commands module, ban enforcement on join, chat hook |
| EconomyService / InventoryService | `Systems/EconomyService.lua`, `InventoryService.lua` | leaderstats-backed currency/XP/level/gems + badge grants; tool give/remove/duplicate/save/restore |
| ServerStateService / EnvironmentService | `Systems/ServerStateService.lua`, `EnvironmentService.lua` | lock/maintenance/slowmode; weather/time/fog/lighting presets |
| Phase 4 commands | `Commands/Economy/*`, `Commands/Server/*`, `Commands/Environment/*` | `/givecurrency /setbalance /addxp /setlevel /grantbadge /giveitem /removeitem /duplicatetool /saveinventory /restoreinventory /shutdown /lockserver /maintenancemode /slowmode /announce /countdown /weather /daynight /timefreeze /fog /lightingpreset` |
| DeveloperService | `Systems/DeveloperService.lua` | Server stats, ping tracking, error console capture, remote-call monitor, DataStore get/set/list, arbitrary module execution |
| Phase 5 commands | `Commands/Developer/Diagnostics.lua` | `/serverstats /pingview /errorconsole /remotelog /datastoreget /datastoreset /datastorelist /execute` — the latter two are deliberately Owner-only (not in Admin's wildcards) since they can corrupt data or run arbitrary code |
| UIBridge | `Systems/UIBridge.lua` | The only place the Phase 7 UI talks to the server — every remote either stays open (harmless metadata) or is gated behind `isStaff()`; command execution always goes through `CommandProcessor` → `CommandRegistry.Dispatch`, identical to chat |
| Phase 7 UI shell | `StarterGui/SentinelUI/Theme.lua`, `Shell.lua`, `CommandPalette.lua` | Design tokens; resizable/draggable/minimizable sidebar shell; Ctrl+Shift+P fuzzy-search command palette |
| Phase 7 pages | `StarterGui/SentinelUI/DashboardPage.lua`, `PlayersPage.lua`, `ModerationPage.lua`, `ServerPage.lua`, `EconomyPage.lua`, `DeveloperPage.lua`, `NotificationCenter.lua` | Dashboard (summary cards + Quick Actions), Player Explorer (searchable table + Freeze/Jail/Mute toggles), Moderation Queue (live actions feed), Server controls (lock/maintenance/slowmode/weather/lighting), Economy (currency/XP/level/badge grant forms), Developer Tools (Performance/Console/Remotes/DataStores tabs), Notification Center (toast overlay + persistent log page) |

## Try it

Open in Roblox Studio via Rojo (`default.project.json` is set up), or
copy `src/` into the matching Instances by hand. Then, as a player who has
been assigned the `Owner` role, type in chat:

```
;ban Player1:30m Exploiting
;kick @team Red
;kick all where Ping>500
```

**Why `;` and not `/`:** Roblox's default chat reserves several
`/`-prefixed commands for itself (e.g. `/w` for whisper), which silently
swallow matching messages before `Player.Chatted` ever sees them —
this caused `/warn`'s alias `w` to intermittently "not work." `;` isn't
reserved by anything Roblox ships, so it's collision-proof regardless of
what commands or aliases get added later. Change `COMMAND_PREFIX` in
`init.server.lua` if you'd like a different trigger character.

Assign yourself the `Owner` role from a temporary script for testing:

```lua
local PermissionSystem = require(
    game.ServerScriptService.Sentinel.Core.PermissionSystem
)
PermissionSystem.AssignRole(game.Players.SomeAdmin, "Owner")
```

## How to add a new command

Drop a `ModuleScript` anywhere under `Commands/<Category>/` — the
bootstrap requires every module in that tree automatically. Follow the
`Kick.lua` / `Ban.lua` pattern:

```lua
local CommandRegistry = require(Core.CommandRegistry)

CommandRegistry.Register({
    Name = "mute",
    Aliases = { "m" },
    Description = "Mutes a player's chat.",
    Usage = "/mute target[:duration] [reason]",
    Permission = "moderation.mute",
    Category = "Moderation",
    Cooldown = 1,
    Log = true,
    Undoable = true,
    RequiresTarget = true,
    Execute = function(ctx)
        -- ctx.Targets, ctx.Modifier, ctx.Arguments are already resolved
        return { Success = true, Message = "Muted." }
    end,
})
```

No switch statement, no registry edits, no core changes required.

## Roadmap status

- [x] **1. Core Engine** — parser, tokenizer, command registry, event bus, permission system, logging foundation
- [x] **2. Command Framework** — aliases, selectors, duration parser, quantity parser, execution pipeline (autocomplete UI still pending — needs Phase 7)
- [x] **3. Moderator Toolkit** — kick, ban, mute/unmute, warn (with auto-escalation), jail/unjail, freeze/unfreeze, staff notes, blacklist/whitelist + whitelist-mode
- [x] **4. Player & Server Systems** — currency/XP/level/badges, inventory (give/remove/duplicate/save/restore), server lock/maintenance/slowmode/shutdown, announcements/countdown, weather/day-night/timefreeze/fog/lighting presets
- [x] **5. Developer Suite** — server stats, ping viewer, error console, remote call monitor, DataStore get/set/list, module execution
- [ ] **6. Analytics & Audit** — dashboards, full searchable log UI, cross-server insights (deferred — Phase 7 first)
- [ ] **7. UI/UX** — IN PROGRESS. Built so far: core Shell, Command Palette, Dashboard, Player Explorer, Moderation Queue, Server page, Economy page, Developer Tools page, and Notification Center (7A–7D). Still to come: Settings (7E), remaining Player Explorer tabs (7F), Command History/Favorites (7G), plus an end-of-phase resize/reflow fix pass — see `/reference/PHASE7-KNOWN-ISSUES.md`. Building against `/reference/UI-UX-design-docs/`.
- [ ] **8. Cross-Server Management** (rescoped) — manage multiple running game servers from one panel (list servers, health status, switch context, remote actions). Automation/plugin loading was dropped from this phase's original scope.
- [ ] **9. Enterprise Features** (trimmed scope) — rollback tool, collaborative moderation, AI-assisted command generation
- [ ] **10. Player Controls** (new, added from the old Admin Panel extraction) — fly, noclip, god mode, ragdoll, visual effects (neon/gold/silver/diamond/fire/smoke), appearance changes, ported into Sentinel's permission/logging/undo architecture rather than copied as-is. Reference source saved at `/reference/OldAdminPanel/`.

## Design decisions worth knowing

- **Dispatch always goes through `CommandRegistry.Dispatch`**, never
  `def.Execute` directly — that's the only place permission checks,
  cooldowns, and logging are enforced, so there's no way to add a new
  command that accidentally skips security.
- **TargetResolver takes injectable providers** (`RegisterGroupProvider`,
  `RegisterTagProvider`, `RegisterPropertyProvider`) instead of hardcoding
  what "VIP" or "level" mean — Phase 4's economy/rank service wires those
  in without TargetResolver ever changing.
- **EventBus topics are a convention, not an enum** — this keeps Core from
  needing to know about plugins in advance (per the skill's "core should
  never depend on plugins" rule), at the cost of typo-safety on topic
  strings. If that trade-off becomes painful once more plugins exist, a
  generated topic-constants module is a cheap follow-up.
- **Bans/mutes/etc. should each own their DataStore**, following `Ban.lua`'s
  pattern (`Sentinel_Bans_v1`), so Phase 6's cross-server analytics can
  read them independently without a shared mega-table.

## New in Phase 3 — setup notes

- **Jail** looks for a Part named `SentinelJailSpawn` anywhere in
  `Workspace`. Add one before using `/jail`, or it degrades to a sky cell
  (500 studs up) with a warning in the server log.
- **Command routing uses `Players.PlayerChatted`.** An earlier iteration of
  this file tried `TextChannel.MessageReceived` instead, which seemed like
  the more "modern" choice — but that event is documented by Roblox as
  **client-only** ("This event is only fired on the client"), so it never
  once fires on the server no matter how correctly it's wired up. Chatted
  is bridged from `TextChatService` for backward compatibility and works
  reliably on the server under both chat systems, so it's the correct
  choice here, not a legacy fallback.
- **Warn** ships with a default escalation policy (3 warnings → auto-kick,
  5 → 1-day auto-ban) defined at the top of `Warn.lua` via
  `PunishmentService.RegisterEscalationRule` — change the thresholds/actions
  there, nothing else needs to change.
- All new permission nodes (`moderation.mute`, `moderation.warn`,
  `moderation.notes`, `moderation.blacklist`, `moderation.whitelist`,
  `player.freeze`, `player.jail`) are already covered by the `Admin` and
  `Owner` wildcard roles — no role setup needed to use them.

## New in Phase 4 — setup notes

- **Currency/XP/Level/Gems** show up as standard `leaderstats` — no extra
  setup needed, they appear in the default player list automatically.
- **`/giveitem`, `/removeitem`, `/duplicatetool`** need a Folder named
  `SentinelTools` in `ServerStorage`, containing the `Tool` instances you
  want referenced by name (e.g. a Tool named "Sword" → `/giveitem
  Player1 Sword`).
- **`/announce` and `/countdown`** work via a small `RemoteEvent`
  (`AnnounceRemote`, auto-created under `ReplicatedStorage.Shared.Sentinel`)
  and display using each client's own chat system message — no custom UI
  needed, works under both chat systems.
- New permission namespaces (`economy.*`, `inventory.*`, `server.*`,
  `environment.*`) are already covered by the `Admin`/`Owner` wildcard
  roles from Phase 1.
- **`/shutdown`** kicks everyone with a message but does not relaunch a
  fresh server — true zero-downtime restarts need Reserved Servers /
  `TeleportService`, which is a Phase 9 (Enterprise) concern.

## New in Phase 5 — setup notes

- **`/execute` and `/datastoreset`** are deliberately excluded from the
  `Admin` role's wildcard grants and only work for `Owner` — both can
  corrupt live data or run arbitrary Luau, so they're opt-in per-role
  rather than bundled into `moderation.*`/`developer.*` wildcards.
- **`/remotewatch`** hooks `RemoteEvent`/`RemoteFunction` firings for
  visibility — it observes, it does not intercept or block traffic.
- No new setup required beyond the `Owner` role already having the
  `developer.*` node from Phase 1's default roles.

## Phase 7 progress (in this drop)

**Built:** Core UI Shell (top bar, sidebar nav, status bar, page container,
now resizable/minimizable/closable), Command Palette (Ctrl+Shift+P), a
Dashboard page (summary cards + Quick Actions panel), a Player Explorer
page (searchable table, scrollable detail panel, Kick button + Freeze/
Jail/Mute toggle switches), a Moderation Queue page (live recent-actions
feed), and a Server page (Lock/Maintenance/Time Freeze toggles via a new
shared `ToggleSwitch.lua` component, Slow Mode input, Weather/Lighting
preset buttons). Commands/Economy/Analytics/Developer/Settings still show
"coming soon" placeholders.

**Reconciliation note:** this drop was built by pulling the user's GitHub
repo (the actual source of truth — their own edits had pulled ahead of
what this session had in a couple of areas) and adding the Server page on
top. `ToggleSwitch.lua` is a genuinely new shared component, used by
`ServerPage` only for now — `QuickActionsPanel` and `PlayersPage` keep
their own working, already-tested inline toggle implementations rather
than risk a regression refactoring them mid-session. Consolidating all
three onto `ToggleSwitch.lua` is a safe, low-priority follow-up whenever
wanted, not required.

**Quick Actions (new):** card-based, color-coded by risk (green/orange/
red), per the design doc — Announce (opens Command Palette pre-filled),
Freeze All, Lock Server + Maintenance Mode (real on/off toggles reflecting
live server state, not one-shot buttons), and Shutdown (gated behind a
typed-confirmation dialog requiring "SHUTDOWN"). Deliberately NOT included:
Heal All, Teleport, true Restart, Cleanup Map, Auto Moderation toggle —
none have a backing command yet, so no cards were added for them.

**Toggle switches:** the functional mechanism (live state polling, click
to flip, optimistic UI update) is built, but the switch's visual design
is a plain placeholder (green/red pill) — swap `QuickActionsPanel.lua`'s
`makeToggleCard` (and `PlayersPage.lua`'s `makeToggleRow`) internals once
the custom switch design is ready.

**Panel access gate:** the entire UI shell — not just command execution —
requires the server to confirm (via `CanOpenPanelRemote`) that the player
has at least one role before anything is built client-side. F6 re-checks
this every time until access is granted, so a player promoted mid-session
doesn't need to rejoin.

**Bug fixes in this drop:**

1. **Argument-eating parser bug (significant).** Any command with
   `RequiresTarget = false` (maintenancemode, weather, daynight, fog,
   slowmode, lightingpreset, countdown, shutdown, execute, datastoreset,
   datastorelist, datastoreget, whitelistmode...) was silently losing its
   first argument — the parser always assumed the second token was a
   player target, so `/maintenancemode on` parsed `"on"` as an (unfound)
   target and threw it away, leaving `Arguments` empty. This is why
   toggling Maintenance appeared to "do nothing." Fixed by having the
   parser track both interpretations (`Arguments` assuming a target,
   `PlainArguments` without one) and having `CommandProcessor` pick the
   correct one based on the resolved command's actual `RequiresTarget`
   flag. This also fixes several other commands that had the same latent
   bug (`/datastoreset` was almost completely broken by this).
2. **Dashboard invisible until switching tabs.** `Shell.Init()` called
   `ShowPage("Dashboard")` before any pages were registered, so the
   real Dashboard page (registered afterward) got silently skipped by
   `ShowPage`'s "already the current page" guard. Fixed by moving that
   call to after all pages (including placeholders) are registered.
3. **Freeze/Jail/Mute quick actions had no way to turn back off.** These
   are reversible states, not one-shot actions, so the Player Explorer's
   detail panel now shows them as toggle switches (same pattern as the
   Dashboard's Quick Actions) reflecting live status via three new fields
   on `GetPlayerListRemote` (`IsFrozen`/`IsJailed`/`IsMuted`), rather than
   plain buttons that could only ever turn them on. Kick stays a plain
   button since it has no "undo." The selected player's toggles also
   re-sync every 4s from the live poll, correcting the optimistic UI
   update if a toggle click was actually denied.
4. **Commands tab** added to the sidebar as a placeholder (real content —
   a full command reference/browser — is a follow-up increment).

**Still open:** a layout concern about the panel not being "cadré"
(framed/aligned) relative to the game view or the other Admin Panel —
under investigation, needs a bit more detail to pin down before fixing.

### 7B — Economy page (new in this drop)

Built `EconomyPage.lua`: a compact player list (plus a pinned "All
Players" row, since every underlying command accepts the `all` selector)
and a form panel wrapping the Phase 5 economy commands — Coins (Give/
Remove/Set), Gems (Give only — `removepremium`/`setpremium` don't exist
yet, so no dead buttons for them), XP (Give/Remove), Level (Set), and a
Badge ID + Grant row.

- Live Coins/Gems/XP/Level readout for the selected player, via a new
  `GetEconomySnapshotRemote` (staff-gated, keyed by `UserId`). Kept
  separate from `GetPlayerListRemote` rather than bolted on, so the
  list — which every page polls every 4s — doesn't get four extra
  numbers per player when most pages never need them.
- The readout hides itself in All-Players mode, since one arbitrary
  player's numbers next to an everyone-targeted grant would be
  misleading.
- Inventory (`/giveitem` etc.) is intentionally NOT on this page — the
  roadmap scopes 7B to currency/XP/level/badges only. Item grants belong
  to the Player Explorer's future Inventory tab (7F).
- Grant results show inline via a status line listening to
  `CommandResultRemote` (the same event the Command Palette listens to),
  so success/failure is visible without opening the palette.

### 7C — Developer Tools page (new in this drop)

Built `DeveloperPage.lua`: four tabs, matching the handoff's scoped-down
list rather than the original design doc's full Explorer/Inspector/
Memory/Network/Plugin-Dashboard spread (Automation & Plugins is a
non-goal per the roadmap; Explorer/Inspector/Memory/Network weren't in
the phase's remaining-work plan either).

- **Performance** — live `Uptime/Heartbeat/Memory/PlayerCount` plus a
  per-player ping list, color-coded (green <100ms, yellow <200ms, red
  above).
- **Console** — recent `LogService` errors/warnings via a new
  `GetRecentLogsRemote`, most-recent-first, same live-feed-row look as
  the Moderation Queue.
- **Remotes** — recent `RemoteEvent`/`RemoteFunction` call log via a new
  `GetRecentRemoteCallsRemote`.
- **DataStores** — Get/Set/List a DataStore key. Deliberately routed
  through `ExecuteCommandRemote` (`/datastoreget /datastoreset
  /datastorelist`) rather than a dedicated remote, so `/datastoreset`'s
  Owner-only permission node is actually enforced by
  `CommandRegistry.Dispatch` — a bespoke remote here would've had to
  reimplement that check in a second place or risk skipping it.
- Console and Remotes only poll their `GetRecentLogsRemote`/
  `GetRecentRemoteCallsRemote` while their tab is the one currently
  visible, so an idle Developer page sitting open doesn't fire two extra
  RemoteFunctions every 4s nobody's looking at.

### 7D — Notification Center (new in this drop)

Built `NotificationCenter.lua`: a toast overlay (its own top-level
ScreenGui, independent of Shell's, so a toast still shows even if the
panel's been closed via F6) plus a persistent "Notifications" log page
in the sidebar.

- Replaces the placeholder feedback path called out directly in
  `init.server.lua`'s chat hook comment ("Placeholder feedback channel;
  Phase 7 UI replaces this with a proper notification system.") — that
  hook now also fires `CommandResultRemote`, so `;command` results toast
  the same as UI-issued ones. Caught a real `script` vs `script.Parent`
  mismatch while wiring this (that file's `script` IS the Sentinel
  folder, so the Shared remotes are under `ReplicatedStorage`, not
  `script.Parent`) — same bug class as the one already logged in the
  handoff notes.
- Loosely based on the old Admin Panel V4.3's toast system
  (`reference/OldAdminPanel/`) for the slide-in/dismiss-button shape, but
  stacks multiple toasts at once instead of a strict one-at-a-time queue,
  and pulls colors from `Theme.lua` instead of the old panel's
  `Config.THEMES`.
- The persistent log is honestly scoped to "results of commands that ran
  because of something this client did" — there's no separate server-
  side alert stream (e.g. "another admin changed server state"), so nothing
  fakes one. History is an in-memory ring buffer (last 100), reset on
  rejoin, same as the old panel's notifications.

- **Open the panel:** press **F6** (not "P" — deliberately avoided, since
  this game's separate AdminPanelClient already binds P for its own UI).
- **Command Palette:** **Ctrl+Shift+P** anywhere, or click the search bar
  in the panel's top bar.
- New server-side bridge: `Systems/UIBridge.lua` has grown alongside each
  Phase 7 page — `GetCommandListRemote`/`GetServerStatsRemote` stay open
  (harmless metadata), while `GetPlayerListRemote`, `GetModerationLogRemote`,
  `CanOpenPanelRemote`, `GetServerStateRemote`, `GetEconomySnapshotRemote`,
  `GetRecentLogsRemote`, and `GetRecentRemoteCallsRemote` are all gated
  behind `isStaff()`. Execution still goes through the identical
  `CommandRegistry.Dispatch` permission/cooldown/logging path as chat
  either way, so there's no separate security surface to reason about.
- Reference design docs and the old Admin Panel extraction are saved
  under `/reference/` for the remaining Phase 7 pages and the later
  Player Controls phase.

## Next recommended step

Continue Phase 7: **7E, Settings** — a read-only Permissions viewer
against `PermissionSystem`, a few real client prefs, and explicit
"not implemented" notes for Discord/Slack integration and 2FA rather
than dead toggles. After that: 7F remaining Player Explorer tabs
(Inventory/Statistics/Moderation History/Permissions/Session/Notes),
7G Command History/Favorites, then the end-of-phase resize/reflow fix
pass logged in `/reference/PHASE7-KNOWN-ISSUES.md`.
