# Sentinel — implementation plan for the whole Feature Blueprint

## Context
`Docs/Planned/Sentinel Admin Panel Complete Feature Blueprint.md` lists 15 systems (~600 bullets) that
Sentinel should eventually have. Much of the base is already built (README phases 1–5 done, Phase 7 UI in
progress: command engine, permissions core, moderation commands, economy/inventory, server/env, dev
commands, 10 UI pages). This plan sequences **everything** in the blueprint into weekend-sized milestones.

Constraints from the user:
- Work days: **Saturday + Sunday, ~4–6 h each** (~10 h/weekend). **Fridays = buffer only** (catch-up,
  bug fixing, Studio retests) — never scheduled with new features.
- First available weekend: **Sat 2026-11-21**. Holiday weekends are marked light.

Standing rules applied to every weekend (from CLAUDE.md / HANDOFF.md §0):
- Sunday close-out: Play-test in Studio → put ✅ on blueprint bullets that work end-to-end → update
  HANDOFF.md (§5, §6, §7, last-updated) → commit to `main` only if the user asks.
- Architecture rules: everything through `CommandProcessor → CommandRegistry.Dispatch`; UI only via
  `UIBridge` (staff-gated); one DataStore per system (`Sentinel_<Thing>_v1`); unique command names/aliases.

## Weekly rhythm
- **Sat:** server-side service + commands (`Systems/`, `Commands/<Cat>/`), UIBridge endpoints.
- **Sun:** UI page work (`src/StarterGui/SentinelUI/`), Studio Play test via Studio MCP, ✅ + handoff.
- **Fri (if free):** overflow from the last weekend, `PHASE7-KNOWN-ISSUES.md` items, retests.

---

## Phase 1 — Finish the foundation (W01–W09, Nov 21 → Jan 17)
| # | Weekend | Scope (blueprint system) |
|---|---|---|
| W01 | Nov 21–22 | **Verification sweep**: Play-test what already exists and ✅ it (chat commands, aliases, chaining, cooldowns, multi-target, moderation/player-control/economy commands). Fix Analytics "Staff Online" bug. Add in-Studio test runner (parser, TargetResolver, PermissionSystem) run via Studio MCP. Decide fate of scaffold `src/client`, `src/server`, `src/shared`. |
| W02 | Nov 28–29 | **Rank backend** (§2): new `Systems/RankService.lua` + `Sentinel_Ranks_v1`; unify bootstrap roles with `Config.lua` (Owner/Developer/SuperAdmin/Admin/Moderator/VIP); CRUD/duplicate/rename, description/icon/color, priority, inheritance, templates; assignment by UserId, username, group, group role, GamePass, asset, creator, private-server owner. |
| W03 | Dec 5–6 | **Rank UI + permission editor** (§2): wire `RankManagementPage.lua` to RankService via UIBridge; explicit deny, page/action/target-level nodes, search, presets, preview, change history; temp promotions + auto-expiry; immunity, can't punish equal/higher, protected owner, no self-demotion. |
| W04 | Dec 12–13 | **Security hardening** (§5 of blueprint): per-remote rate limiter in UIBridge, input validation audit of every remote, `TextService` filtering for announcements/polls/notes, confirmation + risk indicators for destructive commands, protected owner-only commands. |
| W05 | Dec 19–20 | **Palette I** (§1 autocomplete): argument-type registry (custom types API) in CommandRegistry; autocomplete for players (avatars/display names), teams, ranks, durations, numbers; ghost text; inline validation; required/optional markers; arg descriptions. Fix Ctrl+Shift+P (#5). |
| W06 | Dec 26–27 *(light)* | **Palette II**: syntax highlighting, live parser, execution preview + affected-player preview, permission requirement display, bulk-action confirm, docs viewer, usage examples. |
| W07 | Jan 2–3 | **Command framework** (§1): configurable prefixes, before/after hooks, middleware, cancellation, undo/redo for reversible commands, duration measurement, result history, templates, saved presets, interactive command builder. |
| W08 | Jan 9–10 | **Settings integration** (§13): load `InGameSettingsPage.lua`; themes (dark/light/midnight/ocean/custom, accent, palette, import/export, font, scaling, reduced motion, high contrast); keybinds (open/close/palette/quick fly/noclip/god/next/prev/custom); admin config (prefix, cooldowns, ban defaults, escalation, required reasons, retention); per-admin prefs `Sentinel_Prefs_v1`. |
| W09 | Jan 16–17 | **Responsive UI pass** (§13 interface): ServerPage wrap (#1), reflow sweep, resize retest, compact mode, mobile layout, sidebar customization, favorite pages, live status bar (FPS/Ping/Memory). Wire `PlayerControlsSystem`, `BanPromptSystem`. **Milestone: README roadmap Phase 7 ✔.** |

## Phase 2 — Professional administration (W10–W16, Jan 23 → Mar 7)
| # | Weekend | Scope |
|---|---|---|
| W10 | Jan 23–24 | **Persistent audit** (§9): `Systems/AuditService.lua` extending `Core/Logger.lua` — every field listed in the blueprint, before/after values, failed-action log, configurable retention, paged storage. |
| W11 | Jan 30–31 | **Log UI** (§9): search, filters (mod/player/command/action/severity/date/server), pagination, export (copyable text), Discord webhook (needs an HTTP proxy — Discord blocks Roblox). |
| W12 | Feb 6–7 | **Moderation center** (§4): `CaseService`; dashboard (active cases, recent punishments/warnings, active bans/mutes, mods online, activity); case search/filter/details; reason templates, required reasons, custom/max durations, escalation thresholds, bulk punishments. |
| W13 | Feb 13–14 | **Offline management** (§3/§4): username→UserId lookup, offline profiles & history, offline ban/unban (Roblox `Players:BanAsync` for experience-wide), ban list, "is banned" check. |
| W14 | Feb 20–21 | **Reports & appeals** (§4/§8): player report UI, report queue/assignment/status/evidence; appeal submission (pre-kick screen or appeal place — decide then), appeal review/accept/reject; moderator notes & internal discussion. |
| W15 | Feb 27–28 | **Player Explorer completion** (§3): health/ping/status indicators, staff/VIP/suspicious filters, recently joined/left, missing profile fields, bulk actions, select by team/rank/attribute/property, investigation notes. |
| W16 | Mar 6–7 | **Analytics** (§9): persisted metrics (peak players, command success/fail/denied, most-used, most-active mods, economy txns) + graphs (players, perf, commands, moderation, staff, economy), date ranges, comparisons. **Milestone: Phase 6 ✔.** |

## Phase 3 — Cross-server infrastructure (W17–W22, Mar 13 → Apr 18)
| # | Weekend | Scope |
|---|---|---|
| W17 | Mar 13–14 | `Systems/CrossServerService.lua`: MemoryStore sorted-map server registry with heartbeat (JobId, players, uptime, version, staff, health); MessagingService command bus with acks + operation status. |
| W18 | Mar 20–21 | **Cross-Server page** (§6): server list/search/health, join server, find player across servers, teleport to player's server, bring across servers. |
| W19 | Mar 27–28 | Global kick/ban/unban/warn, shared punishment DB, punishment sync, cross-server moderation history. |
| W20 | Apr 3–4 | Global announcement, lockdown, shutdown, notifications, update countdown, graceful migration / restart. |
| W21 | Apr 10–11 | Cross-server staff chat, logs, analytics, notifications, global event activation hook. |
| W22 | Apr 17–18 | **Server Management leftovers** (§5): info (location/version/memory), kick all / non-staff, capacity & private-server restrictions where supported, staff-only/targeted announcements, colors/duration/history. Test on the **published** place with 2+ servers. **Milestone: Phase 8 ✔.** |

## Phase 4 — Game operations (W23–W30, Apr 24 → Jun 13)
| # | Weekend | Scope |
|---|---|---|
| W23 | Apr 24–25 | **Polls** (§8): `PollService` — create, 2–N options, timer, live voting/results, change vote, end/cancel, announce, history, server + global. |
| W24 | May 1–2 | **Events** (§8): `EventService` — create/start/stop/schedule/duration/countdown/presets/announce/history; multipliers wired into `EconomyService` (Double Coins/XP/Gems). |
| W25 | May 8–9 | Event library: Low Gravity, Meteor Shower, Snow Day, Blood Moon, Disco Party, Special Rewards, custom-event API; Events page. |
| W26 | May 15–16 | **Scheduling & automation** (§14): `SchedulerService` (persisted), recurring jobs, scheduled announcements/shutdown/maintenance, auto lock/unlock, health alerts, scheduled reports, custom triggers, history, enable/disable, permissions. |
| W27 | May 22–23 | **Community tools** (§8): feedback, bug reports, suggestions, redeem codes, gift distributions, community announcements. |
| W28 | May 29–30 | **Economy completion** (§7): transaction history/audit trail, limits, large-amount confirm, before/after records, failed-txn handling, bulk ops, quick amounts, reset currency/level, currency integration API. |
| W29 | Jun 5–6 | **Inventory completion** (§7): view inventory, search game items, ViewportFrame previews, quantity controls, bulk grants, item history, reset, integration API. |
| W30 | Jun 12–13 | **Character customization** (§11) — Neon/Glass/Gold/Silver/Diamond, PointLight, reset appearance, scale, outfits, animations, tools, effect duration/intensity, individual removal — and **Notification Center completion** (§12): persisted history, search/filter, preferences, sounds, priority, durations, mod/report/server alerts. |

## Phase 5 — Developer experience (W31–W36, Jun 19 → Jul 25)
| # | Weekend | Scope |
|---|---|---|
| W31 | Jun 19–20 | **Live Explorer + Instance Inspector** (§10): lazy server tree over UIBridge, search, class filter, whitelisted properties, attributes, tags, paths/copy; read-only by default. |
| W32 | Jun 26–27 | **Script Console**: LogService capture (output/warn/error, stack traces), search, clear, copy, diagnostics; owner-only execute with confirm + logging. |
| W33 | Jul 3–4 | **Remote, Performance, Memory/Network monitors**: remote discovery & per-remote stats, `Stats` heartbeat/memory/physics/network, history, alerts, lag diagnostics. |
| W34 | Jul 10–11 | **DataStore Manager**: list stores/keys, inspect JSON, protected edit/delete, compare, backup/restore via versions API, budget status, access history. |
| W35 | Jul 17–18 | **Command SDK** (§1 developer framework + §15): auto-discover ModuleScripts in a `SentinelCommands` folder, custom type/validator/autocomplete APIs, command packs, generated docs page, templates. |
| W36 | Jul 24–25 | Developer productivity leftovers (debug shortcuts, saved dev commands, diagnostic reports, dev profiles). **Milestone.** |

## Phase 6 — Enterprise (W37–W42, Jul 31 → Sep 5)
| # | Weekend | Scope |
|---|---|---|
| W37 | Jul 31–Aug 1 | Config backup/restore, version management, safe DataStore schema migrations. |
| W38 | Aug 7–8 | Server/DataStore rollback tools. |
| W39 | Aug 14–15 | Saved workspace layouts, dockable windows, dashboard customization, shared workspaces, advanced access policies. |
| W40 | Aug 21–22 | **AI assistant** (§15): NL→command, explanations, recommendations, moderation summaries via `HttpService` to a small backend (Railway/Vercel) calling Claude; offline rule-based fallback. |
| W41 | Aug 28–29 | Webhooks, external logging, API integration points, multi-experience management (Open Cloud via the same backend). |
| W42 | Sep 4–5 | Final security audit against the blueprint's §5 checklist, docs, **Sentinel 2.0 release**. |

## Phase 7 — W-FINAL: Sentinel Modules Ecosystem (LAST — after W42 only)
Full spec: [`W-FINAL Sentinel Modules Ecosystem.md`](W-FINAL%20Sentinel%20Modules%20Ecosystem.md).
A **Modules** main nav section where the Owner browses, configures, enables / disables optional gameplay
modules (~90 across 8 categories: movement, world, player UI, social, economy, moderation/security, game
experience, events) through a central Module Registry (manifests, lifecycle, dependencies / conflicts,
diagnostics, `modules.*` nodes, audit + cross-server integration). **No custom character animation assets**
(emotes, slide, crouch, climbing etc. are excluded). **Not scheduled to dates and never the next task**:
start it only once W01–W42 are done. Stages:

| # | Scope |
|---|---|
| W-FINAL.1 | Module Manager foundation: registry, manifests, lifecycle, discovery, status, dependencies / compatibility, config, diagnostics. |
| W-FINAL.2 | Essential modules: Shift To Run, Day / Night Cycle, Health Bar, Server Messages, Custom Player List, Death Screen (Simple preset). |
| W-FINAL.3 | Player experience: Nickname GUI, Invite Friends, Realistic First-Person, Loading Screen, Spectator Camera, Crosshair, Player Settings GUI. |
| W-FINAL.4 | Social: Player Reports, Vote Kick, Discord Feedback, Welcome Messages, Global Announcements, Suggestions. |
| W-FINAL.5 | Economy: Gamepass Shop, Developer Product Shop, Currency Shop, Daily / Playtime Rewards, Redeem Codes, VIP. |
| W-FINAL.6 | Advanced gameplay: Stamina, Double Jump, Dash, Wall Jump, Fall Damage, physics Ragdoll, Swimming, Dynamic Weather, Footsteps. |
| W-FINAL.7 | Game experience + events: Tutorials, Onboarding, Quests, Achievements, Checkpoints, Rounds, Matchmaking, Polls, Live Events, Seasonal Pass. |
| W-FINAL.8 | Module packs (Essentials, Immersive, Community, Competitive, Economy), Module Activity, diagnostics / audit / cross-server integration, security testing, UI polish, docs. |

Overlap to resolve when reached: several modules (polls, events, reports, redeem codes, inventory, Discord
webhook) build on W11 / W14 / W23–W29 services — modules must reuse those services, not duplicate them.

**Total: 42 weekends → target completion Sun 2027-09-05.** Fridays absorb slippage; if two weekends slip,
push every later row by one weekend rather than cramming.

## Items needing a decision when reached (not blockers now)
- External infra: Discord webhook proxy (W11), AI backend (W40), multi-experience (W41).
- Platform-limited bullets ("where supported"): previous usernames, server location, runtime capacity
  change — implement what Roblox allows; ask before editing the blueprint wording.
- Appeal flow for banned players (W14).

## Critical files
- Server: `src/ServerScriptService/Sentinel/init.server.lua`, `Core/CommandRegistry.lua`,
  `Core/PermissionSystem.lua`, `Core/Logger.lua`, `Core/Parser/*`, `Systems/UIBridge.lua`,
  new `Systems/{Rank,Audit,Case,CrossServer,Poll,Event,Scheduler}Service.lua`.
- Shared: `src/ReplicatedStorage/Shared/Sentinel/{Types,Config}.lua`.
- UI: `src/StarterGui/SentinelUI/{Shell,CommandPalette,RankManagementPage,InGameSettingsPage,
  AnalyticsPage,ModerationPage,PlayersPage,ServerPage,DeveloperPage,NotificationCenter}.lua` + new pages
  (CrossServer, Events).
- Docs: `HANDOFF.md`, `README.md` roadmap, the blueprint (✅ only).

## Verification (every weekend)
1. Serve with Aftman Rojo 7.7.1 (`%USERPROFILE%\.aftman\tool-storage\rojo-rbx\rojo\7.7.1\rojo.exe serve`).
2. Studio MCP: start Play, open panel (F6), exercise new features by firing `ExecuteCommandRemote`
   from the Client DataModel; read console for errors.
3. Run the W01 in-Studio test runner; all green.
4. Cross-server weekends: also test in the published place with ≥2 servers.
5. ✅ verified blueprint bullets, update HANDOFF.md, commit on request.
