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
- [ ] **4. Player & Server Systems** — economy, inventory, server state, announcements, events, environment controls
- [ ] **5. Developer Suite** — live explorer, remote inspector, datastore viewer, profiling
- [ ] **6. Analytics & Audit** — dashboards, full searchable log UI, cross-server insights
- [ ] **7. UI/UX** — command palette, dockable windows, themes, autocomplete, mobile support
- [ ] **8. Automation & Plugins** — scheduler, triggers, plugin loader, webhook integrations
- [ ] **9. Enterprise Features** — web dashboard, cross-server admin, MFA, collaborative moderation, rollback tool, AI-assisted command generation

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
- **Command routing uses `TextChannel.MessageReceived` directly**, not
  `Player.Chatted`. The legacy `Chatted` event is bridged from
  `TextChatService` for backward compatibility, and that bridge can
  silently drop messages — which is what caused commands to "randomly"
  not fire. `MessageReceived` fires directly on the server with no
  bridge involved.
- **Warn** ships with a default escalation policy (3 warnings → auto-kick,
  5 → 1-day auto-ban) defined at the top of `Warn.lua` via
  `PunishmentService.RegisterEscalationRule` — change the thresholds/actions
  there, nothing else needs to change.
- All new permission nodes (`moderation.mute`, `moderation.warn`,
  `moderation.notes`, `moderation.blacklist`, `moderation.whitelist`,
  `player.freeze`, `player.jail`) are already covered by the `Admin` and
  `Owner` wildcard roles — no role setup needed to use them.

## Next recommended step

Phase 4 (Player & Server Systems) is next: economy controls, inventory,
server state (lock/unlock, maintenance mode), announcements, event tools,
and environment controls (weather, day/night, lighting presets). Same
pattern throughout — say the word and I'll build it next.
