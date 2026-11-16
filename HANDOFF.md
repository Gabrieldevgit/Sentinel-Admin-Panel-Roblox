# Sentinel — AI Agent Handoff

> **Read this first.** It is the shared memory between AI agent sessions
> working on this project. It tells you what the project is, how to work in
> it, what state it is in right now, and the rules every session follows.

_Last updated: 2026-11-15 (end of session) — schedule written, W01–W04
done, committed and pushed. Start with §6 "Next session"._

---

## 0. Rules for every agent session (mandatory)

### 0.1 Update this handoff every 3–5 messages

To protect the context window, **every 3–5 user messages you must refresh
this document as part of your turn** — before your context gets long, not
at the end of the session. Concretely:

1. Rewrite **§6 Current state** so it describes the project as it is *now*
   (what works, what is in progress, what is uncommitted).
2. Add one entry at the top of **§7 Session log**: date, what you did, what
   you verified, what is left. Keep each entry to a few lines.
3. Update **§5 Known issues & open work** (remove fixed items, add new ones).
4. Update the `_Last updated_` line at the top.
5. Keep the whole file short and factual. Summarize, don't paste code or
   transcripts. Remove anything that is no longer true.

A fresh agent must be able to pick up the work from this file alone. If
you're about to end a session, do a final update even if you're between
the 3–5 message marks.

### 0.2 Feature blueprint: mark shipped features with ✅

The long-term feature list lives in
[`Docs/Planned/Sentinel Admin Panel Complete Feature Blueprint.md`](Docs/Planned/Sentinel%20Admin%20Panel%20Complete%20Feature%20Blueprint.md)
(15 systems: Command System, Permissions, Player Explorer, Moderation,
Server, Cross-Server, Economy, Events, Analytics, Developer Tools, Player
Controls, Notifications, Settings, Scheduling, Enterprise). Features are
built **gradually, not all at once** — the user picks what comes next.

- When a feature is **implemented and verified in Studio**, put a green
  check mark at the start of its bullet:
  `- Command aliases and shortcuts.` → `- ✅ Command aliases and shortcuts.`
- Only mark what actually works end-to-end. Partial work stays unmarked;
  note it in §5 instead.
- Don't reword, reorder or delete the user's blueprint items. If a feature
  is dropped or changed, ask the user before editing the blueprint.
- Mention newly checked features in your §7 session log entry.

### 0.3 General working rules

- **Commit only when the user asks.** The user commits straight to `main`.
  Commit messages end with the co-author line the environment provides.
- The working tree often holds the user's own uncommitted work. Don't
  revert, reformat or commit it unasked; when a file mixes their edits
  with yours, say so before committing.
- Verify in Studio (Play test + console) before saying something works.
- Treat `reference/OldAdminPanel/` as the user's own earlier panel —
  reuse its ideas, but port them into Sentinel's architecture (§3).

---

## 1. What the project is

**Sentinel** is a Roblox admin / live-operations panel: moderation, player
controls, economy, server tools, developer tools and a dark "Mission
Control" UI, all driven by one command grammar
(`;command target[:modifier] [args...]`, chainable with `&&`).

- Repo: `C:\Users\gabet\Sentinel Admin Panel Roblox Stud` (git, branch `main`).
- Studio place: **Sentinel Admin Panel [TESTING]**, placeId
  `140634395792206`, a Team Create place, so saving uploads a new version to Roblox.
- The place also contains the user's **older admin panel (V4.3)**:
  `AdminPanelServer`, `AdminPanelClient`, `AdminPanelConfig`, plus game
  scripts (`Datastore/DataHandler`, `leaderstats`, `PlotHandler`, …).
  These are **not** in the repo; only Sentinel is.
- Roadmap/phase status lives in `README.md` ("Roadmap status"). Phase 7
  (UI/UX) is in progress; Phase 6 deferred; 8–10 planned.

## 2. Tooling & setup

- **Rojo 7.7.1 via Aftman** (`aftman.toml`). The user's PATH resolves
  `rojo` to an old **WinGet Rojo 7.6.1** first, which makes the Studio
  plugin (7.7) fail with
  `ApiContext:28: attempt to index number with 'protocolVersion'`
  (7.7 speaks MessagePack, 7.6 JSON). Serve with:
  `& "$env:USERPROFILE\.aftman\tool-storage\rojo-rbx\rojo\7.7.1\rojo.exe" serve`
  (long-term fix: `winget uninstall Rojo.Rojo` + put `%USERPROFILE%\.aftman\bin` on PATH).
- `default.project.json` maps `src/` →
  `ReplicatedStorage.Shared.Sentinel`, `ServerScriptService.Sentinel`,
  `StarterPlayer.StarterPlayerScripts.Sentinel`, `StarterGui.SentinelUI`.
- Rojo syncs into the **Edit** DataModel only — restart Play to test changes.
- When Rojo is **not** connected, edit the local file *and* patch Studio's
  copy, or they drift.
- **Roblox Studio MCP** is available (execute Luau in Edit/Server/Client,
  start/stop Play, console output, mouse/keyboard input, `save_place`).
  - Keep `execute_luau` calls small — a heavy call once froze/crashed Studio.
  - `require()` from `execute_luau` does **not** reach the running game's
    modules (e.g. you get an empty CommandRegistry). To test commands, fire
    `ReplicatedStorage.Shared.Sentinel.ExecuteCommandRemote` from the
    **Client** DataModel instead. In **Edit** mode, `require` results are
    cached between calls, so after an edit you get the old code: require a
    `:Clone()`.
  - Studio MCP mouse clicks in the panel's **top-left** can be swallowed by
    Roblox's chat window (CoreGui). Hide it for the test session:
    `TextChatService.ChatWindowConfiguration.Enabled = false` (Client).
    Also scroll a ScrollingFrame so the target is on screen before clicking.
  - Mouse `moveTo` with raw x/y takes **GUI coordinates** (inset added
    for you): use `AbsolutePosition + AbsoluteSize/2`. Screenshots are
    1.25× the viewport.
  - Never `CharacterAdded:Wait()` in an `execute_luau` call when the
    character already exists — it blocks forever and drops the MCP link.
  - **Unit tests:** `src/ServerScriptService/Sentinel/Tests/` (parser +
    permissions + ranks + security, 36 cases). Run in Edit mode:
    `local c = game.ServerScriptService.Sentinel:Clone(); require(c.Tests.TestRunner).Run(); c:Destroy()`
  - Save (`save_place`) after important Studio-only edits; Studio can crash.
- Open the panel in Play with **F6**; command palette **Ctrl+Shift+P**;
  chat prefix `;`.

## 3. Architecture & conventions

- `src/ReplicatedStorage/Shared/Sentinel/` — `Types.lua` (single contract
  for all modules), `EventBus.lua`, `Signal.lua`, `Config.lua`, plus
  auto-created remotes.
- `src/ServerScriptService/Sentinel/`
  - `init.server.lua` — bootstrap: roles, loads every `Systems/` and
    `Commands/**` module, ban enforcement, chat hook.
  - `Core/` — `CommandRegistry`, `PermissionSystem`, `Logger`,
    `RateLimiter`, `CommandPolicy` (risk levels, owner-only), `Parser/`
    (Tokenizer, CommandParser, TargetResolver, Duration/Quantity parsers,
    CommandProcessor).
  - `Systems/` — services (Economy, Inventory, ChatModeration, Punishment,
    ServerState, Environment, Developer, **UIBridge**, **RankService**,
    **TextFilterService**).
  - `Commands/<Category>/*.lua` — each file self-registers commands.
  - `Tests/` — TestRunner + `*.spec` modules (see §2).
  - `Commands/Ranks/Ranks.lua` — `;ranks`, `;rankinfo`, `;createrank`,
    `;editrank`, `;rankperm`, `;assignrank`, `;bindrank`, `;rankbindings`,
    `;rankhistory`, `;resetranks`, `;updaterank`, `;rankpreset`, …
    (see the file header). `Commands/Server/Confirm.lua` — `;confirm`.
- `src/StarterGui/SentinelUI/RankManagementPage.lua` — Ranks page (tabs
  Ranks / Assignments / History). Reads `GetRanksSnapshotRemote`; every
  write is a normal command sent via `ExecuteCommandRemote`. Widgets have
  stable names (`Body.RankList.Rank_<name>`, `Body.Detail.Field_<key>`,
  `Body.Detail.NodeList.Node_<node>`, `Body.AddForm.Row1.Box_*`, …) so
  Studio MCP mouse input can target them by instance path.
- `src/StarterGui/SentinelUI/` — `Theme`, `Shell` (window), pages
  (`DashboardPage`, `PlayersPage`, …), `CommandPalette`,
  `NotificationCenter`.
- `src/StarterPlayer/StarterPlayerScripts/Sentinel/init.client.lua` —
  overlay (announcements, countdown, fly + fly menu, noclip, utility
  remotes) and builds the UI shell.

Rules that keep it sound:

- **All execution goes through `CommandProcessor` → `CommandRegistry.Dispatch`**
  (permissions, cooldowns, logging). Never call `def.Execute` directly.
- **The UI only talks to the server through `UIBridge`**; staff-only remotes
  are gated by `isStaff()` = `PermissionSystem.Has(player, "panel.open")`.
- **Ranks live in `Systems/RankService`** (DataStore `Sentinel_Ranks_v1`,
  key `Config`): rank definitions + bindings (UserId/Group/GroupRole/
  GamePass/Asset/Creator/PrivateServerOwner, optional expiry). Never call
  `PermissionSystem.DefineRole/AssignRole` elsewhere. Hierarchy: actors only
  touch ranks below their priority; Owner rank and creator binding are
  protected. If the store fails to load it runs read-only on defaults.
  Outside a running game it never touches the DataStore (tests).
- **Permissions:** `!node` = explicit deny. Within one rank its own nodes
  beat inherited ones and deny beats allow; across separately assigned
  ranks any allow wins. `PermissionSystem.Evaluate` returns
  allow/deny/nil. Pages are hidden only when `page.<id>` is explicitly
  denied (`GetHiddenPagesRemote`).
- **Target protection:** `CommandProcessor.SetTargetFilter` (installed by
  RankService) drops targets ranked equal/above the executor (yourself
  and unranked players are always allowed). Harmless commands opt out
  with `TargetProtection = false` (goto, view, pingview, pm, notes,
  warnings).
- **Security (W04):**
  - Every `OnServerInvoke` in UIBridge is registered through
    `bindInvoke(remote, handler)` (per-player rate limit from `LIMITS`,
    errors caught → returns nil). Validate client values with
    `validUserId` / `clampCount` / `sanitizeLogFilter`. New remotes must use
    `bindInvoke`; RemoteEvents use `Core/RateLimiter` directly.
  - `Core/CommandPolicy.lua` holds command **risk levels** and **owner-only**
    commands. High/critical (and medium hitting ≥3 players) return
    `NeedsConfirmation` + `ConfirmId`; `;confirm [id]` replays the pending
    chain (`CommandProcessor.ConfirmPending`). The panel shows
    `ConfirmDialog` for it (init.client). UI code that already confirmed
    may send `ExecuteCommandRemote:FireServer(text, { Confirmed = true })`.
  - Text shown to other players goes through `Systems/TextFilterService`
    (`ForBroadcast` / `ForUser`); on failure show nothing, never the
    original. Studio doesn't censor, so filtering is only visible live.
- Running several commands of the **same name** in one `&&` chain trips
  their cooldown — the UI must send one command (hence `;updaterank`).
- New command = new `CommandRegistry.Register({...})` in `Commands/<Cat>/`.
  **Names and aliases must be unique across all commands** — a duplicate
  asserts and aborts server boot (happened with `m`).
- Command context fields: `Executor, Targets, Modifier, Arguments,
  RawInput, CommandName` (see `Types.lua`). For target-less commands
  `Arguments` already holds the plain arguments — there is no
  `ctx.PlainArguments`.
- Client → server remotes must validate input and only affect the sender
  unless a permission check runs.
- Each system owns its own DataStore (`Sentinel_<Thing>_v1`).

## 4. Hard-won lessons (don't relearn these)

- In a ScreenGui with `IgnoreGuiInset = true`, **`AbsolutePosition` and
  `InputObject.Position` are measured from below Roblox's top bar**, while
  `Position` offsets start at the very top of the screen
  (`screenGui.AbsolutePosition = (0, -inset)`). Convert explicitly.
  `MouseButton1Down`'s x/y include the inset — use `InputBegan` instead.
- Never use `GetMouseDelta()` for UI drag/resize.
- Mute: `ShouldDeliverCallback` only hides messages from *others*; the
  sender still sees their own. Use `TextSource.CanSend = false`.
- Another game script (`DataHandler`) also creates `leaderstats`. Sentinel
  must fill in its own stats in whatever folder exists, never assume it
  created it.
- Declare services at the top of a script; a `local` declared below a
  closure that uses it is a nil global inside that closure.
- `Player.Chatted` is the correct server-side chat hook;
  `TextChannel.MessageReceived` is client-only.
- `/`-prefixed chat collides with Roblox commands; Sentinel uses `;`.

## 5. Known issues & open work

- `reference/PHASE7-KNOWN-ISSUES.md` is the detailed Phase 7 bug list.
  Still open there: ServerPage preset rows don't wrap (#1); Ctrl+Shift+P
  responsiveness and inline ghost-text suggestions (#5).
- Resize handle was rewritten with the drag fix but **not re-tested by hand**.
- The old panel's `AdminPanelClient` also binds **F** to its own fly; its
  `AdminPanelV43` / `NotificationGui` duplicate in PlayerGui on each respawn.
- Modules not wired up yet: `BanPromptSystem`, `InGameSettingsPage`
  (W08), `PlayerControlsSystem` (W09). `Config.lua` ranks are now only
  reference; RankService owns ranks.
- Harmless console noise from the game's assets: sound
  `118939739460633` (no permission), asset `203785492` (wrong type).
- `;give` needs tools in `ServerStorage.SentinelTools` (none exist yet).
  `;weather` only has `clear`/`foggy` (more come with W25 events).
- Not yet verified, so not ✅: permission-denied feedback and multi-player
  targeting (need a second, non-staff test player), kick/ban/unban,
  bring/goto, spectate, ragdoll/sit/jump/trip/fling state, kill/respawn,
  countdown, the Staff Online fix with a non-staff player present.
- Scaffold files `src/client`, `src/server`, `src/shared` (Rojo template
  "Hello world") aren't mapped by `default.project.json`; candidates for
  deletion — ask the user.
- Studio-only `Workspace.SentinelWorkspace.GrantScript` (assigns Owner to
  the first player) is now redundant — the creator binding does it — and
  errors with `unknown role 'Owner'` because it runs before RankService.
  Ask the user to delete it.
- W03 not yet verified (need two players — Studio *Test > Clients and
  Servers* with 2 clients, give one a lower rank): target protection in
  real commands (rank immunity / can't punish equal or higher), page
  visibility (`!page.<id>` on a non-Owner rank), view-only page for a
  rank without `ranks.manage`. Logic is unit-tested in `Rank.spec`.
- UX: the open chat window overlaps the panel's top-left corner.
- W04 not yet verified: actual text censoring (live server only),
  owner-only refusal and bulk confirmation with real targets (need a
  second player). Remaining W04-adjacent work: persistent audit records
  (W10), offline lookups (W13), failure retries.
- W02 not yet verified: GamePass/Asset ownership bindings (need an owned
  pass/asset), private-server-owner binding (needs a live private server),
  automatic promotions (not built). Hierarchy rules were verified with
  fake players in `Rank.spec`, not with a second real staff member.
- The place has several `SentinelJailSpawnPart` objects in Workspace (place
  content, not created by Sentinel); `Jail.lua` looks for `SentinelJailSpawn`.

## 6. Current state

- Sentinel server and client boot cleanly in Play. Unit tests 36/36.
- **W01–W04 are done** (all pulled forward and built on 2026-11-15), except
  the unverified items in §5. Everything is committed and pushed:
  `main` = `origin/main` = `4f89db2` ("W04: security hardening…"). The
  only later change is this end-of-session HANDOFF update (commit it if
  it is still uncommitted).
- Commits this session: `47f0bd7` schedule, `88c77f6` W01+W02, `bb204a7`
  W03, `4f89db2` W04.
- **Schedule position:** the next item is **W05 — Command palette I**
  (argument types, autocomplete, ghost text, inline validation; fix
  Ctrl+Shift+P, known issue #5). It was scheduled for Dec 19–20, so the
  project is about **4 weekends ahead**. Rows in
  [`Docs/Planned/Implementation Schedule.md`](Docs/Planned/Implementation%20Schedule.md)
  keep their dates; just continue with the next undone row.
- Testing-place state: rank data is back to the 6 default ranks (history
  kept). Studio-only change (not in repo): `ServerScriptService.Datastore.
  DataHandler` reuses an existing `leaderstats` folder (place version 82).
- Feature blueprint: **118 bullets ✅** — W01 73 (command aliases/chaining/
  cooldowns, player actions, effects, moderation basics, lock/maintenance,
  announcement, currency/XP/level), W02 30 (rank CRUD/templates/hierarchy/
  inheritance/expiry, nodes/wildcards/history, UserId/username/group/
  group-role/creator/temporary assignment, owner protection, no
  self-demotion), W03 5 (explicit deny, permission search/presets/editor/
  preview), W04 10 (command visibility, risk indicators, bulk confirmation,
  server-authoritative execution, permission checks, validation, rate
  limiting, cooldowns, destructive-action confirmation, no client-trusted
  permissions).

### Next session — open items to raise with the user

1. **`GrantScript`**: Studio-only `Workspace.SentinelWorkspace.GrantScript`
   is redundant and logs `unknown role 'Owner'` at boot. The user can
   delete it in Studio (it isn't in the repo); ask before touching it.
2. **Two-player test session** (Studio *Test > Clients and Servers*, 2
   clients, give one a lower rank such as Moderator). Covers: rank
   protection in real commands (can't target equal/higher), hidden pages
   (`!page.<id>`), the view-only Ranks page, the Owner-only refusal,
   bulk confirmation with real targets, permission-denied feedback,
   multi-player targeting and the Staff Online count. Tick the matching
   blueprint bullets once verified.
3. **Live-server check**: text censoring (Studio doesn't filter text).
4. Scaffold `src/client`, `src/server`, `src/shared` — ask whether to delete.
5. Then start **W05**.

## 7. Session log (newest first)

- **2026-11-15 (session end)** — Stopped after W04 at the user's request.
  All work committed and pushed (`4f89db2`). Open items for next time are
  listed in §6 "Next session"; next feature work is W05.

- **2026-11-15 (W04)** — Audited every client→server entry point. Added
  `Core/RateLimiter` (all remotes, chat commands, MovementRemote; one
  "slow down" notice per burst, spam logged as `security.ratelimit`),
  `bindInvoke` + validation in UIBridge (staff gates on command list and
  server stats; command list is permission-aware with risk flags),
  `Core/CommandPolicy` (risk, owner-only) with `;confirm` and the panel
  ConfirmDialog, `Systems/TextFilterService` on announce/countdown/msg/
  hint/pm/kick/ban/warn text, risk badges in palette + Commands page.
  Tests 36/36; verified in Play (confirm + cancel via dialog, spam,
  malformed args, filter path). ✅ 10 bullets.

- **2026-11-15 (W03)** — Explicit deny (`!node`), permission presets
  (`;rankpreset`), multi-field `;updaterank`, allow↔deny switch in one
  `;rankperm`, target protection hook in CommandProcessor, page
  visibility via `!page.<id>`, `GetRanksSnapshotRemote`, and a rebuilt
  Ranks page (list, details form, permission editor with search and
  allow/deny cycling, presets, command preview, assignments form,
  history; scroll kept across refreshes). Tests 32/32; page driven by
  mouse in Play (create, save, allow/deny, preset, assign/remove,
  history, delete). ✅ 5 bullets; two-player items listed in §5.

- **2026-11-15 (W02)** — Added `Systems/RankService` (persistent ranks +
  bindings, hierarchy, history, expiry loop, cross-server reload) and
  `Commands/Ranks/Ranks.lua`; bootstrap no longer hard-codes roles; panel
  access is now the `panel.open` node (VIP can't open it). Logger's flush
  loop no longer starts outside a running game. Tests 29/29; Play-tested
  CRUD, validation, persistence across restart, group/group-role grants,
  temporary rank auto-expiry, `;resetranks confirm`. ✅ 30 bullets.

- **2026-11-15 (W01)** — Ran W01 early. Added `Tests/` (TestRunner + parser
  and permission specs, 19/19 pass). Fixed: Analytics Staff Online counted
  every player; `;kick @team Red` dropped the team name (value-taking
  `@selectors` now take the next token); `@staff` matched nobody;
  `normalhead`/`smallhead` did nothing on R15 (now `HeadScale`); unfreeze
  reset custom WalkSpeed/JumpPower to defaults; lighting/weather presets
  were case-sensitive. Play-tested ~70 commands with server-side state
  checks and ✅ 73 blueprint bullets. Next: W02 rank backend.

- **2026-11-15 (planning)** — Planned the full blueprint into a weekend
  schedule (`Docs/Planned/Implementation Schedule.md`). No code changed.
  Next: W01 verification sweep on 2026-11-21.

- **2026-11-15 (later)** — Pushed the fix/handoff commits to GitHub;
  committed and pushed the user's remaining in-progress work as `dad045a`.

- **2026-11-15** — Fixed: server boot crash (duplicate alias `m` →
  `msg`), silent Gems grants (duplicate `leaderstats`), `/message` &
  `/hint` crash, `ctx.CommandName` missing, fly frozen (late
  `UserInputService`), mute leaking to sender (`CanSend`), panel drag.
  Added the fly control menu. Diagnosed the Rojo 7.6.1 vs 7.7 plugin
  mismatch. All verified in Play. Created this handoff document.
