# Sentinel — AI Agent Handoff

> **Read this first.** It is the shared memory between AI agent sessions
> working on this project. It tells you what the project is, how to work in
> it, what state it is in right now, and the rules every session follows.

_Last updated: 2026-11-16 (cross-server session) — Cross-Server Management
(schedule W17-W21, done out of order at the user's request) built and
verified in Play; **not committed yet** (user commits on request). W08-W16
are still open. Start with §6 "Next session"._

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
    permissions + ranks + security + autocomplete + framework + cross-server, 72 cases). Run in Edit mode:
    `local c = game.ServerScriptService.Sentinel:Clone(); require(c.Tests.TestRunner).Run(); c:Destroy()`
    Cloning the server folder does **not** refresh `ReplicatedStorage.Shared`
    modules (cached between calls) — a spec that tests Shared code must
    require from `Shared.Sentinel:Clone()` (see `Autocomplete.spec`).
  - **Without Studio:** Lune (Aftman) can run pure-Luau specs with a small
    harness that fakes `game`/`script`/`WaitForChild` (used for
    `Autocomplete.spec` in W06; the harness lived in the session scratchpad,
    rewrite it if needed — ~80 lines).
  - Save (`save_place`) after important Studio-only edits; Studio can crash.
- Open the panel in Play with **F6**; command palette **Ctrl+Shift+P**;
  chat prefix `;`.

## 3. Architecture & conventions

- `src/ReplicatedStorage/Shared/Sentinel/` — `Types.lua` (single contract
  for all modules), `EventBus.lua`, `Signal.lua`, `Config.lua`, plus
  auto-created remotes. **W05:** `ArgumentTypes.lua` (type registry:
  players/player/duration/number/integer/boolean/choice/rank/team/string/
  text + `Register` for custom types; validate + suggest) and
  `UsageSpec.lua` (parses `Usage` into typed `Args`; `Analyze` tells the
  palette which argument the cursor is on, errors, missing args).
- **Typed command args:** `CommandRegistry.Register` sets `def.Args` from
  `Usage` (grammar in `UsageSpec` header). Refine with `ArgHints = { name =
  { Type, Choices (list or function), Description, Min, Max, Suggestions } }`,
  or give `Args` outright; `Examples = {...}` show in the palette. Keep
  `Usage` strings in the `name [optional] a|b text... target:mod` grammar.
  `GetCommandListRemote` now sends `Args`, `RequiresTarget`, `Examples`;
  `GetAutocompleteDataRemote` sends rank names/colours.
- `TargetResolver` name lookup = exact name, then case-insensitive
  Name/DisplayName, then a unique prefix (`ArgumentTypes.FindPlayer`).
- **W06 palette II:** `UsageSpec.Walk` (highlight spans + per-segment
  values/errors for every `&&` link), `Breakdown` (live parse),
  `Examples` (explicit `Examples` first, then generated from Args),
  `PrettyDuration`. `CommandProcessor.Preview` = dry run (targets after
  rank protection, confirmation needed; no state change —
  `TargetResolver.Resolve(..., dryRun)` skips "last" targets), exposed as
  `PreviewCommandRemote` (palette calls it 0.3 s after typing stops).
  `StarterGui/SentinelUI/CommandDocs.lua` renders a command's docs; the
  palette shows it on F1 or for `help <command>`, and Commands page cards
  have a **Docs** button (opens the palette on `help <cmd>`).
  `Commands/Server/Help.lua` adds `;help [command]` (aliases `docs`, `?`).
  The palette input draws a highlighted RichText copy under a transparent
  TextBox plus its own caret (`InputHolder.Caret`); it falls back to the
  plain TextBox once the text overflows the box.
- **W07 command framework:**
  - `CommandRegistry.AddHook("Before"|"After", fn, name)` and
    `CommandRegistry.Use(middleware, name)` (both return a remover). Before
    hooks returning a string cancel the command (`result.Cancelled`).
    Middleware is `fn(def, ctx, nextFn)`, first registered = outermost.
    Every result gets `Command` + `DurationMs`.
  - Cancellation: a long-running command calls `ctx.Track(label, cancelFn)`
    (handle `.Finish()` when done) and sets `Cancellable = true`; `;cancel`
    runs `CommandRegistry.CancelRunning` and drops a pending `;confirm`.
    Only `countdown` uses it so far.
  - Undo/redo: `Core/CommandHistory` (per player, in memory, 200 entries;
    undo/redo stacks of 30). A command is undoable via `def.Undo(ctx,
    result)` (custom; `ban` restores the previous ban record), or
    `def.Inverse = "<cmd>"`, or the `INVERSES` default table in
    CommandHistory (freeze/unfreeze, mute, jail, effects; currency, xp and
    items keep their args; speed -> resetspeed, ...).
    `CommandProcessor.Undo/Redo` re-enter `Dispatch` (permissions, logging
    and hooks apply). `NoHistory = true` keeps undo/redo/history out of
    history.
  - `Process(executor, text, { Source = "chat"|"panel"|"preset"|... })`.
  - `Systems/ConfigService`: in-game server settings, DataStore
    `Sentinel_Config_v1` key `Global`, MessagingService topic
    `SentinelConfig`. Holds `Prefixes` (allowed `; : ! . / - ? >`); a
    prefix only triggers when a letter follows. **W08 should extend this
    service** for the rest of the admin config.
  - `Systems/CommandLibraryService`: per-staff Favorites / Presets /
    Templates / Recent, DataStore `Sentinel_CommandLibrary_v1` (key UserId,
    debounced save after 6 s and on leave). Built-in templates live there.
    Templates use `{name}`, `{name:type}`, `{name?}`; values can't inject
    `&&`. A chat `;preset save` can't contain `&&` (chat splits it); the
    panel can save chains.
  - Commands (`Commands/Server/Framework.lua`): `;undo` (z), `;redo` (y),
    `;history [search]`, `;cancel` (stop), `;prefix list|add|remove|set|
    reset` (node `config.prefix`, Owner via `*`), `;preset` (pre),
    `;template` (tpl), `;favorite` (fav). The rest need `panel.open`.
  - New def metadata: `Subcategory`, `Tags`, `Hidden`, `Cancellable`,
    `Inverse`, `Undo`, `NoHistory` (see Types.lua).
  - Remotes: `GetCommandHistoryRemote`, `GetCommandLibraryRemote`,
    `UpdateCommandLibraryRemote`; `GetCommandListRemote` also sends
    `Subcategory`, `CanUndo`, `Cancellable` and skips `Hidden` commands.
  - UI: `LibraryPage.lua` (sidebar "Library": History / Presets /
    Templates / Favorites tabs plus an Undo / Redo / Cancel / Build
    toolbar), `CommandBuilder.lua` (modal form from Args or template
    placeholders: chips, validation, live line, dry-run preview, Run /
    Open in palette / Save preset). Commands page cards have a star and
    Build. Palette empty state: recent (seeded from the persisted Recent
    list), presets, starred favorites first. The sidebar is now a
    ScrollingFrame (12 pages).
- **Cross-server (W17-W21):**
  - `Core/CrossServerNode` = the protocol with no Roblox calls (envelopes
    under MessagingService's 1 kB, broadcast / direct, acknowledgements,
    operations with status pending / complete / partial / no response /
    failed, duplicate + expiry drops, registry helpers `Summarize`,
    `FindPlayers`, `Health`). `CrossServer.spec` runs several nodes on a
    fake bus = how multi-server behaviour is tested without live servers.
  - `Systems/CrossServerService` wires one node to MessagingService (topics
    `SentinelXS1` and `SentinelXS1.<serverId>`), writes this server's
    heartbeat record to the MemoryStore sorted map `SentinelServers_v1`
    every 25 s (expiry 90 s; also 3 s after a join/leave), keeps global
    state / history / peak in DataStore `Sentinel_CrossServer_v1` (keys
    `GlobalState`, `History`, `Stats`), staff chat backlog in MemoryStore
    `SentinelStaffChat_v1`, and pushes live updates to staff on
    `CrossServerEventRemote` (kinds op / chat / notify / state / history).
    Studio has no JobId, so a Studio session is `studio-<8 hex>`.
  - `Systems/CrossServerActions` = what a server does on arrival (kick, ban,
    warn, bring, announce, notify, lockdown, shutdown, migrate, chat, cmd,
    ping). The envelope carries the actor's rank priority and every handler
    that touches a player re-checks the hierarchy locally ("protected by
    rank" ack; `;gban` then rolls its record back).
  - `Commands/CrossServer/CrossServer.lua` (category "Cross-Server", nodes
    `crossserver.*`): `;servers`, `;findplayer`, `;joinserver`, `;follow`,
    `;xping`, `;xstatus`, `;gkick`, `;gban`, `;gunban`, `;gwarn`, `;gbring`,
    `;gannounce`, `;gnotify`, `;lockdown on|off|status`, `;gshutdown`,
    `;gupdate`, `;migrateserver`, `;global <command>`, `;staffchat`. They
    take a username / UserId (not the target grammar, which only sees this
    server) and wait up to 2.5 s for acknowledgements before reporting.
  - `;global` only runs commands `CommandPolicy.IsGlobalSafe` allows
    (target-less + listed, or `Global = true` on the def); other servers run
    them through `CommandRegistry.DispatchRemote` (hooks, middleware,
    logging; executor may be a plain `{UserId, Name, DisplayName}` table).
  - New def field `ConfirmWhen = function(arguments) -> boolean` narrows
    risk confirmation (`;lockdown` only asks for "on").
  - `BanCommand.SetBan`, `PunishmentService.AddWarningOffline`,
    `NotificationCenter.Push(success, message)` were added for this.
  - UI: `CrossServerPage.lua` (sidebar "Cross-Server": Servers / Players /
    Global / Staff Chat / Operations / History). Remotes
    `GetCrossServerSnapshotRemote`, `GetCrossServerServerRemote`,
    `CrossServerFindRemote` (all need `crossserver.view`).
  - Default ranks: Moderator gets view + staffchat, Admin the moderation
    nodes, SuperAdmin `crossserver.*`. **Saved rank data is not migrated** -
    on an existing place grant them with `;rankpreset <rank> CrossServerStaff
    | CrossServerModeration | CrossServerOperations` (Owner has `*`).
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

- **Cross-server, not verified (needs the published place with 2+
  servers; Studio can't teleport):** join server, follow, bring, real
  global kick of a player in another server, global shutdown, update
  countdown + migration (reserved-server bounce in
  `CrossServerService.StartMigration`), staff toasts for `;gnotify` / staff
  chat (events arrive; toast not looked at), server search box, lockdown
  being applied by a server that starts later. Not built: global event
  activation (needs W24 events; `;global` is the hook), cross-server
  analytics beyond the overview cards, cross-server audit log (W10).
  Offline `;gwarn` stores the warning but escalation only runs while the
  player is online. Rank protection for offline targets only knows the
  creator and UserId bindings (group ranks are checked by the server the
  player is in). Testing-place leftovers: test entries in the Cross-Server
  History tab and staff chat backlog (expires after 6 h).
- **Test account warnings:** the Studio test account (`gabrielethangame`)
  has 4 stored warnings (`Sentinel_Warnings_v1`). One more `;warn` on
  yourself triggers the 5-warning auto-ban (happened once in W07 through
  the "Spam warning" template; that ban and that warning were removed).
  Don't test `warn` on yourself, or clear the warnings first.
- W07 leftovers: history lives in server memory (only the palette's
  "Recent" lines persist); only `countdown` is cancellable; undo needs the
  targets still in the server (except `ban`); a ban's `ExpiresAt =
  math.huge` may not serialize to the DataStore (pre-existing, check in
  W13). Unicode arrows and the multiplication-sign X don't render in
  Gotham: use plain text on buttons.
- `UIListLayout` defaults to **Name** sort order: set `SortOrder =
  LayoutOrder` (the `make` helper in LibraryPage/CommandBuilder does it).

- `reference/PHASE7-KNOWN-ISSUES.md` is the detailed Phase 7 bug list.
  Still open there: ServerPage preset rows don't wrap (#1). #5 (palette
  shortcut + ghost text) was rebuilt in W05 and Ctrl+Shift+P works with
  Studio MCP input; **not yet tried on a real keyboard** (Studio itself may
  grab the chord — if so, add a fallback key in W08 keybinds).
- **Panel closes on its own (intermittent, predates W06):** during palette
  tests `SentinelShell.Enabled` sometimes flips to false with no Sentinel
  code on the stack. Also, opening the palette was seen enabling the old
  V4.3 GUIs (`AdminPanelV43`, `NotificationGui`, `Interface`) — the old
  panel binds **P** without checking modifiers, so Ctrl+Shift+P can reach
  it. Not reproduced reliably; investigate with the old panel's key
  handling, or move the palette shortcut in W08 keybinds.
- W06 leftovers: the dry-run preview can't show what "random" will pick
  (re-rolled each preview); the highlighted copy is hidden when the input
  overflows horizontally.
- W05 palette leftovers: ghost text is hidden for quoted completions
  (team names with spaces) and once the input scrolls horizontally; the
  value being typed isn't validated until you move past it; the
  "Recent" rows are session-only (persisted history = W06/W08).
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

- Sentinel server and client boot cleanly in Play. Unit tests **72/72**
  (new `CrossServer.spec`, 15 cases).
- **W01-W07 are done and committed** (`b5c6620`). **Cross-server
  (W17-W21) was built out of order** on 2026-11-16 because the user asked
  for the biggest task in `Docs/Planned`; it is **uncommitted** in the
  working tree (ask the user before committing). W22 (server management
  leftovers + live two-server test) is still open.
- **Schedule position:** next undone row is **W08 - Settings integration** (themes,
  keybinds, admin config through `ConfigService`, per-admin prefs
  `Sentinel_Prefs_v1`, load `InGameSettingsPage.lua`). About 7 weekends
  ahead of the dates in
  [`Docs/Planned/Implementation Schedule.md`](Docs/Planned/Implementation%20Schedule.md);
  keep the dates, just continue with the next undone row.
- Testing-place state: 6 default ranks; prefixes reset to `;`; the test
  account's library only holds recent lines (test preset and favorites
  removed). Studio-only change (not in repo): `ServerScriptService.
  Datastore.DataHandler` reuses an existing `leaderstats` folder.
- Feature blueprint: **189 bullets ✅**: cross-server 27 (server list,
  JobIds, player counts, uptime, health, version, staff per server, find
  players across servers, global ban / unban / warn / announcement /
  lockdown, staff chat, moderation history, acknowledgements, operation
  status, live server list, health overview, find a player in another
  server, execute cross-server actions, offline ban / unban / lookup, is
  banned), W07 17 (configurable prefixes,
  categories + subcategories, cancellation, undo/redo, result history,
  duration measurement, interactive command builder, templates, saved
  presets, favorites, recently used, searchable history, before/after
  hooks, middleware, command metadata, extensible lifecycle), W06 6, W05
  21, W04 10, W03 5, W02 30, W01 73.

### Next session - open items to raise with the user

1. **Commit the cross-server work** if the user agrees. Then **publish
   and test with two live servers** (§5 cross-server list) and ✅ the
   remaining §6 blueprint bullets.
2. **`GrantScript`**: Studio-only `Workspace.SentinelWorkspace.GrantScript`
   is redundant and logs `unknown role 'Owner'` at boot. Ask before
   touching it.
3. **Two-player test session** (Studio *Test > Clients and Servers*, 2
   clients, one with a lower rank): rank protection, hidden pages,
   view-only Ranks page, Owner-only refusal, bulk confirmation, permission-
   denied feedback, multi-player targeting, Staff Online count.
4. **Live-server check**: text censoring (Studio doesn't filter text).
5. Scaffold `src/client`, `src/server`, `src/shared`: ask whether to delete.
6. Then start **W08**.

## 7. Session log (newest first)

- **2026-11-16 (cross-server, W17-W21 out of order)** - User asked for the
  biggest task in `Docs/Planned`. Built `Core/CrossServerNode`,
  `Systems/CrossServerService` + `CrossServerActions`, 19 commands in
  `Commands/CrossServer`, UIBridge remotes, `CrossServerPage`, and
  `DispatchRemote` / `IsGlobalSafe` / `ConfirmWhen`. Checked first that
  MessagingService, MemoryStore and DataStore work in Studio Play (they
  do; `math.huge` also round-trips through the DataStore). Tests 72/72.
  Verified in Play by remote, mouse and keyboard: server list with a
  second (previous-session) registry record, ping reporting 1/2 answers,
  find online + offline, gban / gunban / gwarn on an offline account,
  announcement, lockdown through the ConfirmDialog, `;global weather`,
  staff chat with backlog from the earlier session, operations and
  persisted history; and with hand-made messages from a fake server:
  acknowledgements, rank protection, remote command execution, logging.
  ✅ 27 bullets. Not committed.

- **2026-11-16 (W07)** - Command framework: hooks, middleware,
  cancellation and timing in `CommandRegistry`; `Core/CommandHistory`
  with undo/redo (`;undo`, `;redo`, inverse table, custom `ban` undo);
  `Systems/ConfigService` (chat prefixes, `;prefix`);
  `Systems/CommandLibraryService` (favorites, presets, templates,
  persisted recent); `Commands/Server/Framework.lua`; UIBridge remotes;
  Library page; command builder; palette presets / favorites / recent;
  Commands page star + Build; scrollable sidebar. Fixed while testing:
  alias `run` collided with `execute` (aborted part of command loading),
  so the preset alias is `pre`. Tests 57/57; verified in Play by remote,
  real chat (`!heal me`), mouse and keyboard. ✅ 17 bullets. Not committed.

- **2026-11-16 (W06)** — Palette II: syntax-highlighted input (own caret),
  live parse line, server dry-run preview (players with avatars, rank
  skips, confirmation) for every `&&` link, errors in earlier links,
  docs viewer (F1 / `help <cmd>` / Commands page Docs button), generated
  usage examples, `;help`. Fixed: F1 docs mode stuck on (now resets on
  open; `help <cmd>` wins). Tests 50/50 (also run under Lune before
  Studio was open); verified in Play by keyboard + mouse. ✅ 6 bullets.
  Committed and pushed.

- **2026-11-15 (W05)** — Built typed palette autocomplete: shared
  `ArgumentTypes` + `UsageSpec`; registry derives `Args` from every
  `Usage` (ArgHints on weather, lightingpreset, skin, rankpreset,
  bindrank, editrank); UIBridge sends Args + new
  `GetAutocompleteDataRemote`; rewrote `CommandPalette` (signature line,
  arg hint, inline validation, ghost text, Tab/↑↓/Enter/Esc, avatars,
  team/rank swatches, recent rows). Player names now resolve
  case-insensitively / by display name / unique prefix. Tests 46/46;
  driven in Play with keyboard + mouse (Ctrl+Shift+P, Tab accept, arrow
  selection, click accept, Enter runs + keeps focus, history ↑).
  ✅ 21 bullets. Committed and pushed.

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
