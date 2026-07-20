# Sentinel

An enterprise-grade Live Operations Platform for Roblox — administration,
moderation, developer tools, analytics, automation, and a plugin
architecture, unified under one command grammar.

This drop is **Phase 1 (Core Engine) + the start of Phase 2 (Command
Framework)**, fully working end to end, plus two reference commands
(`/kick`, `/ban`) that prove the pipeline. Everything else in the roadmap
plugs into what's here without modifying it.

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
- [ ] **7. UI/UX** — IN PROGRESS. Mission-Control-style dockable UI, command palette, dashboard, developer tool tabs, notification center. See `/reference/UI-UX-design-docs/` for the full ChatGPT-collaborated design spec this phase is being built against.
- [ ] **9. Enterprise Features** (trimmed scope) — rollback tool, collaborative moderation, AI-assisted command generation
- [ ] **10. Player Controls** (new, added from the old Admin Panel extraction) — fly, noclip, god mode, ragdoll, visual effects (neon/gold/silver/diamond/fire/smoke), appearance changes, ported into Sentinel's permission/logging/undo architecture rather than copied as-is. Reference source saved at `/reference/OldAdminPanel/`.

- [ ] **8. Cross-Server Management** (rescoped) — manage multiple running game servers from one panel (list servers, health status, switch context, remote actions). Automation/plugin loading is dropped from this phase's original scope.

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

## Phase 7 progress (in this drop)

**Built:** Core UI Shell (top bar, sidebar nav, status bar, page container),
Command Palette (Ctrl+Shift+P — fuzzy search, inline docs, live command
history, executes through the same CommandRegistry.Dispatch path as chat),
a first-slice Dashboard page (summary cards), and a Player Explorer page
(searchable table, detail panel with Kick/Freeze/Jail quick actions).
Moderation/Economy/Server/Analytics/Developer/Settings still show "coming
soon" placeholders — those are the next increments.

- **Open the panel:** press **F6** (not "P" — deliberately avoided, since
  this game's separate AdminPanelClient already binds P for its own UI).
- **Command Palette:** **Ctrl+Shift+P** anywhere, or click the search bar
  in the panel's top bar.
- New server-side bridge: `Systems/UIBridge.lua` exposes exactly three
  narrow remotes (`GetCommandListRemote`, `ExecuteCommandRemote`,
  `GetServerStatsRemote`) — execution goes through the identical
  `CommandRegistry.Dispatch` permission/cooldown/logging path as chat, so
  there's no separate security surface to reason about.
- Reference design docs and the old Admin Panel extraction are saved
  under `/reference/` for the remaining Phase 7 pages and the later
  Player Controls phase.

## Next recommended step

Continue Phase 7: Player Explorer table + detail panel, Moderation Queue,
Developer Tools tabs (wiring Phase 5's backend into the new Developer
page), Notification Center, and live health charts on the Dashboard. Say
which piece to build next, or I'll default to Player Explorer since
almost everything else references it (right-click actions, target
picking in the Command Palette's future Target Builder).
