# Sentinel — AI Agent Handoff

> **Read this first.** It is the shared memory between AI agent sessions
> working on this project. It tells you what the project is, how to work in
> it, what state it is in right now, and the rules every session follows.

_Last updated: 2026-11-22 (W22 session) - W16 skipped for now (user's
call). W17-W21 were already built (2026-11-16). **W22 server management
built + verified in Studio Play, not committed.** Next: the **live
2-server test** of W17-W22 (user agreed: Max Players = 1, publish, main +
alt), then W23 Polls. Start with §6._

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

### 0.2b W-FINAL Modules Ecosystem is LAST

[`Docs/Planned/W-FINAL Sentinel Modules Ecosystem.md`](Docs/Planned/W-FINAL%20Sentinel%20Modules%20Ecosystem.md)
(optional gameplay modules managed from a new **Modules** nav section) is
implemented **only after every W01-W42 row is done**. Never pick it as the
next task. Hard rule from its spec: **no module may need custom character
animation assets** (emotes, slide, crouch, climbing... are excluded).
When building W11-W42, keep services reusable so the modules can sit on
top of them (polls, events, reports, rewards, inventory, webhooks).

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
    permissions + ranks + security + autocomplete + framework + cross-server + settings + audit + cases, 102 cases). Run in Edit mode:
    `local c = game.ServerScriptService.Sentinel:Clone(); require(c.Tests.TestRunner).Run(); c:Destroy()`
    Cloning the server folder does **not** refresh `ReplicatedStorage.Shared`
    modules (cached between calls) — a spec that tests Shared code must
    require from `Shared.Sentinel:Clone()` (see `Autocomplete.spec`).
  - **Without Studio:** Lune (Aftman) can run pure-Luau specs with a small
    harness that fakes `game`/`script`/`WaitForChild` (used for
    `Autocomplete.spec` in W06; the harness lived in the session scratchpad,
    rewrite it if needed — ~80 lines).
  - Save (`save_place`) after important Studio-only edits; Studio can crash.
- Open the panel in Play with **F6**; command bar **F2**; command palette
  **Ctrl+K** (all keybind preferences since W08); chat prefix `;`.
  **Never bind Shift+P**: it toggles Roblox's developer Freecam, which hides
  every ScreenGui (`UIPrefs.ParseKey` refuses it).
  - Studio MCP: wait ~0.5 s between `textInput` and `keyPress Return`, or
    Return can arrive before the text. Text boxes take `textInput` reliably
    only with an `instance_path`.

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
- **UI redesign (after W21, before W08):**
  - `Shared/UIPrefs.lua` defines every customisation setting once (SPEC,
    ORDER, THEMES, ACCENTS, BAR_PRESETS, `Sanitize`, `Merge`, `Parse`).
    Layers: BUILTIN < server default (Owner; ConfigService key
    `UIDefaults`) < personal (`Systems/PrefsService`, DataStore
    `Sentinel_Prefs_v1`, key UserId). Add a setting there and the
    Appearance page and the commands pick it up.
  - Remotes `GetUIPrefsRemote`, `SetUIPrefsRemote(scope, prefs)` (scope
    personal | reset | default | resetdefault; defaults need node
    `config.ui`), push `UIPrefsChangedRemote(snapshot)`. Commands
    `;commandbar [default] <setting> <value>` and `;theme ...` (both
    `Public`, checked inside: staff or `commandbar.use`).
  - `Theme.Apply(panelPrefs)` mutates `Theme.Colors` in place;
    `Theme.Retint(gui, previousColors)` recolours existing UI by matching
    old palette colours (so only palette colours follow a theme change);
    `Theme.tween` respects the Animations preference. init.client's
    `applyPrefs` runs them for every `Sentinel*` ScreenGui.
  - `Shell.lua` rewritten: title bar (clock, brand, minimize, close), nav
    bar with **section tabs** (Dashboard, Players, Moderation+Ranks,
    Commands+Library, Server+Cross-Server+Economy, Insights = Analytics +
    Developer) and Search / bell / gear / user, a **sub menu** for sections
    with several pages, status bar. System section (Settings, Appearance,
    Notifications) opens from the gear and bell. Instance paths:
    `Root.NavBar.Tabs.<Section>Tab`, `Root.SubNav.<PageId>NavButton`,
    `Root.NavBar.Right.{SearchButton,BellButton,GearButton}`. The panel has
    a `UIScale` (`Root.Scale`): AbsoluteSize includes it, Size offsets don't.
  - `CommandBar.lua`: terminal-style bar (top or bottom), prompt
    `name@Sentinel$`, output log, autocomplete box under the typed word
    (argument name: type, description, suggestions) built on
    `UsageSpec.Analyze` + `ArgumentTypes.Suggest`. Tab accepts, Up/Down
    select or walk history, Enter runs, Esc closes, `cls` clears. Rebuilt
    on every preference change. Available to staff and to ranks with
    `commandbar.use` (VIP default; **saved rank data is not migrated**, so
    on an existing place run `;rankperm VIP +commandbar.use`).
    `GetCommandListRemote` / `GetAutocompleteDataRemote` now also answer
    those ranks.
  - `AppearancePage.lua` (gear > Appearance): rows generated from UIPrefs;
    Owner gets "Make this the server default" / "Reset server default".
- **W08 settings integration:**
  - `Shared/UIPrefs` sections: Panel (Theme incl. **Light** and **Custom**,
    Accent, Font = Gotham/Builder/Roboto/SourceSans/Arial, Animations,
    AnimationSpeed, ReducedMotion, HighContrast, Scale, Custom palette),
    CommandBar, **Keys** (Panel F6, ClosePanel, Palette Ctrl+K, QuickFly /
    QuickNoclip / QuickGod, NextPage Ctrl+PageDown, PrevPage Ctrl+PageUp,
    Custom = up to 10 `{Key, Command}`), **Notifications** (Toasts, Sound,
    Duration, Position). Keys are `[Ctrl+][Shift+][Alt+]<KeyCode>` or
    `None`. Theme codes `SNTL1-` + 7 hex colours (`EncodeTheme` /
    `DecodeTheme`); `ResolvePalette(panel)` = theme + accent + custom + high
    contrast. `Enum.Font.Montserrat*` are aliases of Gotham - don't offer it.
  - `Theme.Apply` returns previous colours **and fonts**; `Theme.Retint(gui,
    prevColors, prevFonts)` also swaps fonts. `Theme.tween` honours
    AnimationSpeed (Theme.Motion rebuilt) and ReducedMotion (position / size
    / scale jump, colours still fade).
  - init.client has one key dispatcher for all shortcuts (Ctrl/Alt chords
    also work while typing). Quick actions send `fly|unfly me` etc. based on
    the player's `SentinelFlying` / `SentinelNoclip` / `SentinelGod`
    attribute; custom binds send their command with `{ Source = "keybind" }`.
    The palette's own Ctrl+Shift+P handler is gone (`CommandPalette.Toggle`).
    `Shell.Cycle(dir)` = next / previous page. `NotificationCenter.
    ApplyPrefs` (toasts, sound, duration, corner).
  - `Systems/AdminConfig`: admin config on top of ConfigService (new
    `ConfigService.Define/Reset/GetDefault`; a value loaded before Define is
    kept). Keys: prefixes, cooldownscale, cooldowns (overrides), defaultban,
    maxduration, escalation (`3:kick 5:ban:1d`), requirereason, logretention,
    defaultperms. Applies: `CommandRegistry.SetCooldownResolver`, a Before
    hook (`AdminConfig.CheckCommand`: required reasons, default ban
    duration, max ban / mute duration for everyone), `PunishmentService.
    SetPolicyProvider` + `RegisterEscalationAction` (Warn.lua registers kick
    / mute / ban; the old hard-coded 3/5 rules are gone),
    `PermissionSystem.SetDefaultNodes` (fallback when no rank decides; no
    `*`, config, ranks, developer, panel, crossserver nodes),
    `Logger.SetRetentionDays` (in-memory prune; W10 should reuse it).
  - Commands: `;config [setting] [value]` (cfg, settings; view = panel.open,
    change = `config.edit`), `;theme export|import <code>`, `;keybind`
    (keybinds, shortcut; `add <key> <command>`, `remove <key>`),
    `;notifyprefs` (toasts).
  - UI: System section now Settings / Appearance / **Keybinds**
    (`KeybindsPage.lua`, click + press to record, clash warnings, custom
    shortcut form) / **Administration** (`InGameSettingsPage.lua` rewritten,
    rows from `GetAdminConfigRemote`, Save / Reset send `;config`) /
    Notifications. Appearance page gained the new Panel rows, a Custom theme
    block (7 hex boxes, Use / Export / Import) and the Notifications section.
    `SetUIPrefsRemote("reset", "Keys")` resets one section.
- **W09 responsive UI:**
  - `Shared/UIPrefs` section **Layout**: Mode (Auto / Desktop / Mobile; Auto
    = mobile on touch-only devices or a screen < 760 px), Compact,
    StatusBar, Labels (Auto / Full / Icons), Tabs (ordered visible section
    ids, `UIPrefs.NAV_SECTIONS`; at least one), Pinned (page ids,
    `UIPrefs.PAGE_IDS`, max 8). `UIPrefs.FindPage / FindSection`.
  - `Shell.lua`: `relayout()` runs on prefs / page / window / screen
    changes. METRICS Normal vs Compact (bar heights, sub menu width, icon
    buttons). Reflow by unscaled width: < 900 search + user chip become
    icons; tabs drop to icons when their labels don't fit (TextService);
    < 760 the sub menu shows icons only; resize minimum 560 x 360. Mobile =
    window fills the screen below Roblox's top bar, no drag / resize, sub
    menu becomes a horizontal strip; leaving mobile restores the desktop
    size. Pinned pages = `Root.SubNav.PinnedHeader` + `Pin_<id>` at the top
    of the sub menu (shown on every page); the star `NavBar.Right.PinButton`
    sends `;pin` / `;unpin`. Minimize keeps the title bar in place.
    `Shell.ApplyPrefs(panel, layout)`.
  - Commands (`Commands/Server/Appearance.lua`): `;layout [setting] [value]`
    (+ `pin|unpin|tabs|hide|show|move`), `;pin <page>` / `;unpin <page>`
    (undoable via Inverse).
  - Appearance page: Layout rows + a Navigation block
    (`Body.Navigation.Tabs.Tab_<Section>.Controls.{Up,Down,Toggle}`,
    `Body.Navigation.Pages.Page_<Id>`).
  - `BanPromptSystem.lua` rewritten (themed modal: temporary / permanent,
    duration chips + custom, reason, live command preview) and opened by
    the Players page **Ban** button; it only sends `ban <name>:<dur> <reason>`.
  - Reflow fixes: ServerPage preset rows wrap; Players page split goes
    36 / 64 below 760 px; Library status label, Cross-Server tabs and
    Appearance toolbar no longer run off a narrow panel. Players page now
    shows the Overview tab for the first selected player (was blank).
- **W10 persistent audit:**
  - `Core/Logger` entries now carry `Id` (`<server short>-<seq>`), `Action`
    (`<category>.<command>`), `RawInput`, `TargetIds`, `Reason`, `Changes`
    (`{Target, Field, Before, After}` strings), `Source`, `Server` (=
    CrossServerService id, `studio-<hex>` in Studio; set via
    `Logger.SetServerId`). `Logger.Matches(entry, filter)` is the one filter
    (Player / Moderator / Command / Action / Severity (`Warning+`) / Result
    (`Failed` = not Success) / Server prefix / Since / Until / Text /
    HasChanges). Action matches a whole dot part; commas = alternatives.
  - `CommandRegistry`: `AuditFields(def, executor, ctx, origin)`; the reason
    is the Usage argument named `reason*` (or `result.Reason` /
    `ctx.Reason`). Logged: every failure (even `Log = false`), denials
    (permission, owner-only, cooldown), Before-hook cancellations
    (`Cancelled`); severity Critical / Warning for critical / high risk.
    `CommandProcessor` also logs "no valid target" and rank-protection
    refusals.
  - Data changes: `Logger.NoteChange(target, field, before, after, actor?,
    action?)` - inside a running command it attaches to that command's
    entry (change scope per coroutine, opened by the audit middleware),
    otherwise it is its own `data.change` entry. `ConfigService.Set` calls
    it (all config / prefix / UI default changes).
  - `Systems/AuditService`: middleware snapshots each target before / after
    (`def.Audit` = false | preset list | fn; defaults by category: Economy
    leaderstats, Inventory backpack, Player/Movement humanoid+attributes,
    Effects/Moderation attributes). Logger sink -> pages of <= 100 entries
    per server in DataStore `Sentinel_Audit_v1` + OrderedDataStore
    `Sentinel_AuditIndex_v1` (value = newest timestamp), written every 30 s
    and on close. `Search(filter, cursor, limit)` reads <= 6 pages per call
    newest first (cursor `{Max, Seen}`), includes this server's unsaved
    entries on the first call; `Prune` drops pages older than
    `;config logretention` every 30 min. `ParseQuery` (`;logs` syntax),
    `SanitizeFilter`, `FormatEntry`.
  - `;logs [query]` (audit, auditlog; panel.open), `;logs status`,
    `;logs flush` / `;logs prune` (config.edit). Remote
    `SearchAuditLogRemote(query|filter, cursor, limit)` (staff, not
    `!logs.view`); Players page moderation history now reads it.
- **W11 Logs page:** `AuditLogPage.lua` (Insights > Audit Log, page id
  `Logs`): query box, chips (result / severity / range / category / This
  server / Changes), rows `Body.List.Row_<n>.Header` expand to every field
  incl. before/after, "Load older" via cursor, Export modal (copyable
  text). Page container path: `SentinelShell.Root.Workspace.LogsPage`.
- **Roblox-style redesign (2026-11-20, from the user's screenshots of
  Roblox's top bar + an "Info" notification):**
  - `Shared/UIPrefs`: theme **Roblox** (near-black neutrals) + accent
    **Royal** (Roblox blue) + font Builder are the new BUILTIN defaults
    (old themes still selectable). `Theme.Radius` S/M/L = 8/12/16 + `Pill`;
    `Theme.crossIcon(parent, size, color, thickness)` draws an X from two
    bars; Theme applies the BUILTIN panel at load (UI built before prefs
    arrive already matches).
  - `NotificationCenter`: every toast is a Roblox-style card (CanvasGroup):
    kind badge + title, pause + close, message (RichText optional), role
    chips, full-width action button, timer line; hairline outline overlay.
    New `NotificationCenter.Notify({Kind info|success|warning|error, Title,
    Message, RichText, Chips={{Text,Color}}, Action={Text,Callback},
    Duration, Record})`; `Push(success, msg)` still works. Paths:
    `SentinelNotifications.ToastStack.Toast_<n>.Notification.Body.{Header.
    Controls.{PauseButton,CloseButton}, Message, Chips, ActionButton}`.
  - Join welcome: `GetWelcomeRemote` (UIBridge) returns ranks (name,
    colour, priority), command count, CanPanel, CanCommandBar, prefixes -
    or nil when the player can't run any non-Public command. init.client
    asks up to 3 times (4 s apart), inits NotificationCenter early (not only
    on F6 now) and shows "Welcome @name! Your roles are:" + chips + Learn
    More (a "Getting started" card with the player's real keys / prefixes,
    plus "Open Sentinel" for staff).
  - `StarterGui/SentinelUI/TopbarIcons.lua`: ScreenGui `SentinelTopbar`
    placed from `GuiService.TopbarInset` (right of Roblox's buttons): one
    dark pill with `SentinelButton` ("S", toggles the panel) and
    `CommandBarButton` (">_", toggles the bar), tooltips, highlight while
    open. Only the buttons the player may use are created.
  - Shell: rounded window (16), brand left ("S" badge + Sentinel), clock
    centred, section tabs are pills (filled when active; underline gone),
    round icon buttons, drawn X close, pill search, no sub-menu marker.
  - **Command bar and command palette were deliberately not restyled**
    (user's instruction: leave them alone for now).
- **Mobile pass (2026-11-20):**
  - Shell: `viewportSize()` = attribute `EmulateViewport` (Vector2) on the
    `SentinelShell` ScreenGui, else its AbsoluteSize. **Test phones in
    Studio by setting that attribute in the Client** (e.g. 844x390,
    667x375); Studio MCP can't emulate a device. Mobile = touch-only, or
    width < 760, or **height < 480** (phones in landscape). Mobile layout:
    compact metrics, no title bar / status bar, `NavBar.Right.
    MobileCloseButton`.
  - TopbarIcons: pill height `clamp(insetHeight - 14, 30, 44)`, glyphs
    scale with it, no hover tooltip on touch-only devices.
    **Real phone test (user screenshot):** Roblox's left pills are wider
    than TopbarInset reports and covered the S button, so on touch-only
    devices the pill is right-aligned (`inset.Max.X - 8`).
  - **Phones enlarge text** (user screenshot: 11-13 px labels rendered
    nearly as big as 20 px headers, overlapping in fixed-offset cards;
    likely the device text-size setting). `Theme.textScale()` measures it
    (probe TextBounds vs TextService) but **on the user's phone it did not
    detect the enlargement** (cards still overflowed), so the dashboard no
    longer uses it: stat + Quick Action cards are content-sized
    (AutomaticSize Y + min height, wrapping UIListLayout instead of
    UIGridLayout). Prefer content-sized layouts over textScale(). User
    says the other pages look okay on the phone.
  - Palette: on touch-only devices the syntax-coloured copy under the
    input is off (it doubled the text on the phone); plain TextBox.
  - PlayersPage: below 900 px wide the list gets 36 %; when short (< 380)
    search moves into the title row. CommandsPage: short header, narrow
    (< 640) = search / categories on own rows and card buttons under the
    text. Palette (sizing only, no restyle) starts under the top bar and
    fits the height on short screens; builder MinSize 300x240.
  - `;sentinel [page]` (aliases `opensentinel`, `panel`; node
    `panel.open`; in `Commands/Server/Appearance.lua`) fires
    `PanelRemote` ("toggle" | "open", page); init.client opens / shows the
    page. Silent on success (empty Message; NotificationCenter skips empty
    results). `CommandRegistry.Resolve` now falls back to lower case, so
    `;Sentinel` / `;openSentinel` work for every command.
  - `StarterGui/SentinelUI/Selection.lua`: the player selected on the
    Players page (`Selection.Set/Get/TargetText/Changed`). Commands page
    has `TargetBar` ("Use me" clears); Run / Fill / Build use the selected
    name (else `me`) for commands that take a target;
    `CommandBuilder.Open({Command, Target})` pre-fills the first player
    field.
- **W12 Moderation center:**
  - `Systems/CaseService`: numbered cases (DataStore `Sentinel_Cases_v1`:
    `Counter` via UpdateAsync, `Case_<id>`, `Index` = newest 500 summaries
    merged by Id, `Player_<userId>` id lists; queued, flushed every 10 s +
    on close; memory-only outside a running game). Status Open / Active /
    Expired / Revoked / Closed; ban / mute / jail start Active (expiry from
    the duration, -1 = permanent), kick / warn Closed, investigation Open.
    An **After hook** turns successful ban / kick / mute / warn / jail and
    gban / gkick / gwarn into cases (global commands set
    `ctx.CaseTarget = {UserId, Name}`); unmute / unjail / gunban revoke the
    Active case. Warn.lua escalation records SYSTEM cases
    (`CaseService.RecordSystem`). `Search(filter, offsetCursor, limit)`,
    `ParseQuery` (`player: mod: type: status: since: #id` + text),
    `Dashboard()` (counts, 24 h activity, recent lists, active bans / mutes,
    moderators online, top moderators, reasons).
  - Reason templates = ConfigService key `ReasonTemplates` (7 defaults);
    a Before hook expands `#name` tokens in any command's arguments
    (except `;reasons`). Mute / unmute / jail Usage gained `[reason...]`.
  - Commands (`Commands/Moderation/Cases.lua`, node `moderation.cases`,
    added to default Moderator + BasicModeration preset - **saved ranks not
    migrated**): `;cases [query]`, `;case <id>`, `;caseopen <player>
    <summary>`, `;casenote`, `;caseclose`, `;casereopen`, `;caseassign <id>
    me|name|none`, `;reasons [add|remove]` (edit = config.edit).
  - Remotes `GetModerationDashboardRemote`, `SearchCasesRemote(query,
    cursor, limit)`, `GetCaseRemote(id)`.
  - `ModerationPage.lua` rewritten: tabs Dashboard / Cases / Bulk (paths in
    its header; `Root.Workspace.ModerationPage.Tabs.Tab_<name>`). Bulk
    builds one `action a,b:dur reason` command.
- **W13 Offline management:**
  - `Systems/PlayerProfileService`: DataStore `Sentinel_Profiles_v1` (key
    UserId: Name, DisplayName, Names = usernames seen (<= 10), FirstSeen,
    LastSeen, Sessions, PlayTime, LastServer, AccountAge), UpdateAsync on
    join / leave / close. `Resolve(text)` (online name / display name,
    UserId, username; cached Roblox lookups), `Profile(text)` = stored
    profile + where they are (CrossServerService) + rank bindings + ban +
    warnings + cases + staff notes. Ban.lua / Note.lua hand over their
    stores with `SetProviders` (Systems can't require Commands).
  - `Ban.lua`: one write path (`writeBan`) that also keeps a ban index (key
    `_Index` in `Sentinel_Bans_v1`, UserId -> summary, expired entries
    dropped); records carry `TargetName` / `BannedByName`; Warn.lua auto-ban
    and gban go through `BanCommand.SetBan`. `ListBans(rebuild)` (rebuild
    rescans with ListKeysAsync for bans older than the index). Commands
    `;unban <user> [reason]` (ub, pardon; revokes the ban case),
    `;isbanned` (banstatus, checkban), `;banlist [search|rebuild]` (bans),
    `;profile <user>` (whois, lookup, seen; panel.open).
  - Remotes `GetOfflineProfileRemote(query)`, `GetBanListRemote()`.
  - `LookupPage.lua` = Players > **Lookup** (page id `Lookup`, in
    `UIPrefs.PAGE_IDS` and the Shell Players section): Profile tab (search,
    identity, ban banner, fields, actions gban / unban / gwarn / caseopen,
    warnings, cases -> open in Moderation, notes) and Ban list tab (filter,
    unban per row). Reloads when a CommandResultRemote result arrives (an
    action may wait on the ConfirmDialog first). `me` resolves to the
    caller. User info comes from `UserService:GetUserInfosByUserIdsAsync`
    (not Players).
  - Roblox's `Players:BanAsync` is **not** wired (it would ban real
    accounts from the test universe) - ask the user.
- **Announcements / Owner approval / PM options (2026-11-21, before W14):**
  - The user installed two other admin panels to compare **features only
    (never copy their design)**: `Workspace.TRS_Admin_Panel` and
    `ServerScriptService.Vantage` (both open with **F1**; one hides
    Sentinel's top bar button - not a bug, F6 still opens Sentinel).
  - `Systems/AnnouncementService`: scopes server / global / players /
    staff; leading options `style=banner|full time=3-60 color=<name|#hex>
    title=Word_Word` (`ParseOptions`); payload carries `Author {UserId,
    Name, DisplayName}`; history newest-first (100) in DataStore
    `Sentinel_Announcements_v1` key `History` (flushed 10 s / on close;
    only the sending server records). Commands: `;announce`, `;tannounce
    <players>`, `;sannounce` (staff), `;announcements [n]`, `;gannounce`
    (same options; CrossServerActions `announce` payload `{m,i,d,s,t,c,h}`),
    `;message` = full-screen style. Remote `GetAnnouncementsRemote`.
  - Client `SentinelUI/AnnouncementBanner` (ScreenGui
    `SentinelAnnouncements`, built for **every** player by init.client;
    replaced the old banner / PM popup there): banner with avatar, display
    name, @name, scope chip, title, timer; full-screen card; hint pill;
    right-hand card stack (ZIndex 30, above the full-screen backdrop) for PM
    and approval cards. Old `(text, color)` AnnounceRemote calls still work.
  - Panel: nav section **Announcements** (`UIPrefs.NAV_SECTIONS`) with pages
    `AnnounceHistory`, `AnnounceServer`, `AnnounceGlobal`, `AnnouncePlayers`
    (`SentinelUI/AnnouncementsPage`; paths in its header). Players whose
    saved Layout.Tabs predates it must show it in Appearance > Navigation.
  - `Systems/PrivateMessageService` + `;pm` (aliases privatemessage, dm):
    several targets, `kind= time=0|5-120 reply=on|off ack=on anon=on
    style=card|popup title=`; threads with replies (player: 5 per round,
    10 min window), read receipts, remote `PrivateMessageRemote`. `anon`
    needs node `utility.pm.anonymous` (not granted to any default rank).
  - `Systems/ApprovalService` (Before hook "OwnerApproval"): while an Owner
    is online, a command at or above `;config approvalrisk`
    (critical|high|medium, default critical) from a non-Owner is held;
    Owners get an approval card (Approve / Deny, countdown) or use
    `;approve [id]` / `;deny [id] [reason]` / `;approvals`; no answer in
    `approvaltimeout` (60 s) = denied; `;config ownerapproval off` disables.
    Approved commands replay via `CommandProcessor.Process(..., {Confirmed,
    Source="approval", ApprovalToken})`. Before hooks may now return a
    table `{Message, ...}` (extra result fields; `Pending = true` shows a
    warning toast). Studio-only `;approvals test <command>` sends you a
    test card (approving it runs nothing).
- **W14 Reports & appeals** (appeal flow decided with the user: **pre-kick
  ban screen**; appealable = active bans / mutes / jails + warnings < 30 d):
  - `Systems/ReportService`: DataStore `Sentinel_Reports_v1` (`Counter`,
    `Report_<id>`, `Index` <= 500 summaries; flushed 10 s / close; memory
    outside a game). Status Open / InProgress / Resolved / Dismissed
    ("pending" = first two). Evidence: target's last 15 chat lines (captured
    on `Player.Chatted`, filtered ForBroadcast at capture, commands shown as
    "(command)"), position + distance, reporter links/text, staff evidence.
    Limits: `ReportCooldown` per reporter, <= 5 pending per reporter, no
    self, no duplicate pending report on the same target. `ParseQuery`
    (`status: player: target: reporter: assignee:(me|none) category: #id
    mine all`), `OnChanged(fn)`.
  - `Systems/AppealService`: DataStore `Sentinel_Appeals_v1` (`Counter`,
    `Appeal_<id>`, `Index`, `User_<userId>` = {Id, Key, Status, DecidedAt,
    Seen} merged by id). Key = `case:<id>` or `ban` (a ban without a case).
    One pending appeal per case; rejected = blocked `AppealCooldownDays`.
    `Decide` checks `moderation.appeals` + the type's node (ban ->
    moderation.ban, mute, warn, jail -> player.jail) and refuses your own
    appeal; accept runs the lifter and revokes the case. Lifters are set by
    `Commands/Moderation/Reports.lua` (`SetLifters`, `SetBanReader`) since
    Systems can't require Commands: ban -> `BanCommand.SetBan(nil)` +
    `Player.Unbanned`; mute -> `ChatModerationService.UnmuteUserId` (new,
    works offline); jail -> `;unjail` via CommandProcessor; warn ->
    `PunishmentService.RemoveWarningNear(userId, case.CreatedAt)` (new).
  - `Systems/PlayerFormsService`: remotes `PlayerFormsRemote` (RF: reportInfo,
    submitReport, appealInfo, submitAppeal, seen) and `PlayerFormsEvent` (RE:
    report, appeal, banscreen, notice, release). `HoldBanned(player, ban)`
    replaces the instant kick in init.server: attribute `SentinelBanHold`,
    character destroyed on spawn, chat silenced (`ChatModerationService.
    SetSilenced`, not a saved mute), panel + commands refused (UIBridge
    `isStaff`, execute remote, chat hook), kicked after `AppealWindow` s,
    12 s after submitting, or 30 s if nothing can be appealed. A lifted ban
    (`Player.Unbanned`) releases them + `LoadCharacter`. Decision notices go
    to the player live or on next join (`Seen`). `;config appeals off` =
    old instant kick. init.server now also checks players already in the
    server when it connects PlayerAdded (the first Studio player was never
    ban-checked before - pre-existing gap).
  - Config keys (AdminConfig, group "Reports & appeals"): `reports`,
    `reportcooldown` (60), `appeals`, `appealwindow` (120), `appealcooldown`
    (7 days).
  - Commands (`Commands/Moderation/Reports.lua`): Public `;report [player]
    [category] [text]` (no args = form), `;appeal` (form); staff (node
    `moderation.reports`) `;reports`, `;reportview`, `;reportclaim`,
    `;reportassign`, `;reportstatus`, `;reportresolve <id> [#case] [note]`,
    `;reportdismiss`, `;reportnote`, `;reportevidence`; (node
    `moderation.appeals`) `;appeals`, `;appealview`, `;appealaccept`,
    `;appealreject`, `;appealnote`, `;appealassign`. Both nodes added to the
    default Moderator rank + Moderation preset (**saved ranks not migrated**).
  - Remotes (UIBridge): `SearchReportsRemote`, `GetReportRemote` (+ other
    reports on the target, linked case), `SearchAppealsRemote`,
    `GetAppealRemote` (+ case, player's cases, CanDecide), push
    `ModerationQueueEvent(kind, what, summary)`; dashboard gets
    `PendingReports` / `PendingAppeals` (cards on the Moderation dashboard).
  - Client: `StarterPlayerScripts/Sentinel/PlayerForms.lua` (self-contained,
    loaded first by init.client for every player - a held player never
    spawns so StarterGui never arrives): ScreenGui `SentinelForms` (report
    form, appeal form, ban screen, notices bottom-left).
    `StarterGui/SentinelUI/ReportsPage.lua` = Moderation > **Reports** and
    **Appeals** pages (ids in `UIPrefs.PAGE_IDS`; paths in its header):
    chips + query, list / detail (narrow < 620 px = one column with Back),
    actions are commands. init.client toasts "New report / appeal" with a
    Review button.
- **Sound effects (2026-11-22, before W15):**
  - `Shared/SoundLibrary.lua`: the user's 8 uploads (`Success1-4`,
    `Fail1-4` -> Audio ids), `EVENTS` = Success / Error / Warning / Info,
    `Normalize` (built-in name, `Off`, or a custom
    `rbxassetid://<id>` parsed from a Creator Store / library link,
    `rbxassetid://` or a bare id), `Resolve`, `Label`, `IsCustom`.
  - `Shared/UIPrefs` section **Sounds** (Enabled, Volume 0-1, Success,
    Error, Warning, Info; Kind `sound`); BUILTIN on, 50 %, Success1 / Fail1
    / Fail2 / Success2. Number settings with Max 1 accept `70%` / `70`.
    The old `Notifications.Sound` boolean was removed (Sanitize drops it).
  - `SentinelUI/SoundPlayer.lua`: `ApplyPrefs`, `Play(event|kind)` (per
    event 0.12 s debounce), `Preview(value)`, `Check(id)` (asset type must
    be Audio via MarketplaceService - **PreloadAsync reports Success for
    any asset type** - and the Sound must load), `Changed`.
    NotificationCenter plays the toast kind's sound (`Notify{Sound=false}`
    to skip) and Warning for `NeedsConfirmation`. init.client `applyPrefs`
    feeds it.
  - UI: System > **Sounds** page (= AppearancePage generator with
    `{Sections={"Sounds"}, Title="Sounds"}`; sound rows
    `Body.Row_Sounds_<Event>.Controls.{Prev,Value,Next,Play}` +
    `.Custom.{Link,Use}`), speaker toggle `Root.NavBar.Right.SoundButton`
    (SoundIcon / MuteSoundIcon). `;sounds [setting] [value]` (sfx,
    soundeffects; server also rejects non-Audio ids).
  - Icons.lua: `SoundIcon` 137866142678538 / `MuteSoundIcon`
    86539800505739 (Image ids from Decals 85550394171391 /
    124944718313615); slots Sounds / SoundOn / SoundOff.
- **W15 Player Explorer completion:**
  - `Systems/PlayerExplorerService`: `Row(p)` (GetPlayerListRemote now
    returns these): original fields + Rank, RankColor, TeamColor, IsStaff,
    IsVIP, AccountAge, JoinedAt, Status (Active / Idle / Dead; idle = no
    movement for 120 s, sampled every 3 s), IdleSeconds, Suspicious
    (reasons: account < `;config newaccount` days (7), >= `;config
    suspectwarnings` warnings (3), open reports via new
    `ReportService.PendingAgainst`), Warnings, WalkSpeed, JumpPower,
    Position. `Recent()` = last 50 joins / leaves (memory).
  - `TargetResolver`: @team / @role / @rank case-insensitive and **@rank
    now works** (matched the player's ranks; it had no provider before);
    `@attribute Name`, `Name=value`, `Name!=value` (player then
    character); `GetProperty` = Health, MaxHealth, Ping, WalkSpeed,
    JumpPower, AccountAge, Session (min) then any leaderstat or numeric
    attribute (case-insensitive) for `@prop >n` and `where`; `!=` compare.
  - UIBridge: `GetPlayerActivityRemote`, `ResolveTargetsRemote(text)`
    (selector -> UserIds, dry run, no `&&`); `GetPlayerSessionRemote` adds
    PreviousNames (W13 profile), Status, Position, WalkSpeed, JumpPower,
    Warnings, Suspicious, MembershipType.
  - `;investigate <player> <text>` (inote, investigation; node
    `moderation.notes`): notes get `Kind = "Investigation"` (same store
    as `;note`, max 200 per player).
  - `Selection.SetMany / GetMany`: checked players; `TargetText()` =
    `a,b,c` when any are checked (Commands page shows "N players").
  - PlayersPage: rows (avatar + status dot, rank chip, ping colour, health
    bar, tags), Toolbar filters / sort / Online-Recent, SelectBar (All, All
    but me, None, selector box), BulkBar (Heal ... Kick, "Other command..."
    -> Commands page), richer Overview / Session, Notes kind toggle. Paths
    in the file header. `PlayersPage.Build(container, {OpenCommands})`.
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
- **W22 Server management:**
  - `Systems/ServerStateService` = one join gate: waits (max 10 s) for
    `RankService.IsResolved(player)` (wired in init.server; group ranks
    yield), staff with `server.bypass` pass, else pure
    `EvaluateJoin(info)`: lock (custom message) > maintenance (custom
    message) > private-server access > whitelist mode > soft cap.
    `SetLocked(on, msg?)`, `SetMaintenanceMode(on, msg?)`, `GetMessages`,
    `SetCapacity(n?)` (soft cap; Players.MaxPlayers is read-only at
    runtime), `SetWhitelistProvider` (AccessList hands over its lookup).
  - ConfigService keys `WhitelistMode` (was a standalone
    `WhitelistModeEnabled` key, migrated once; now live on every server,
    staff bypass) and `PrivateServerAccess` open|friends|staff (VIP servers
    only; reserved servers untouched) = `;config privateservers`.
  - `CrossServerService.LocalInfo()` = this server's registry record +
    ShortId, Uptime, Health, SlowMode, Cap, Whitelist, PrivateAccess,
    Messages, Reserved, Owner, Location (always nil - Roblox has no region
    API), Events / Polls (empty until W23 / W24). `GetServerStateRemote`
    returns it as `Info` for `server.info` holders.
  - Commands (`Commands/Server/ServerControl.lua`): `;shutdown [seconds]
    [message]` (countdown via CountdownRemote, then lock + kick),
    `;lockserver [message]`, `;maintenancemode on|off [message]`,
    `;kickall` (kickeveryone) / `;kicknonstaff` (kickplayers) (critical,
    node `server.kickall`, skip players ranked >= you), `;servercap
    [n|off]` (playercap, node `server.capacity`), `;serverinfo` (sinfo,
    serverstatus; node `server.info`, added to the default Moderator
    rank - **saved ranks not migrated**). Messages go through
    TextFilterService. `;whitelistmode on|off|status` (confirm only for on).
    Restart / migrate is the existing `;migrateserver` (alias restartserver).
  - ServerPage: Server Info card, Join Rules (whitelist toggle, message box
    used by Lock / Maintenance / kicks, soft cap row), Server Actions (Kick
    non-staff, Kick all, Restart 30s, Shutdown 30s). Paths in its header.
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

- **W21 gaps deferred (decided 2026-11-22):** cross-server analytics goes
  with W16 (one metrics store for both); the global event activation hook
  goes with W24 (no event system yet; `;global` is the hook point).
- **W22 not verified live (needs 2 players / servers):** a joiner actually
  turned away by the custom lock / maintenance message, soft cap,
  whitelist mode and private-server access; kick all / kick non-staff with
  a real second player; restart (`;migrateserver`). Server location stays
  unavailable (no Roblox API); active events / polls wait for W23 / W24.
- **Live 2-server test plan (W17-W22):** user sets Max Players = 1 in Game
  Settings + publishes; main account + alt `gabrielgaming_offv1` land in
  separate servers. Check: server search, join server, follow, gbring,
  gkick, gban sync, gnotify toast, staff chat, update countdown +
  migration, W22 items above, global shutdown last. Then set Max Players
  back and republish.

- **Sound icons are dark grey line art** (SoundIcon / MuteSoundIcon): on
  the dark themes the top-bar speaker, the Sounds page header and its
  sidebar entry are nearly invisible (ImageColor3 can only darken). Ask the
  user for white versions; then only the two ids in `Icons.Assets` change.
- Sounds not verified by ear (Studio MCP can't hear); verified that the
  right Sound ids are created, loaded and playing at the set volume.
  Non-staff players get the BUILTIN sound prefs (no personal prefs).
- **W15 live test (2026-11-22, published place, alt `gabrielgaming_offv1`
  = SuperAdmin):** verified 2-player bulk Freeze / Unfreeze, Select all /
  All but me, `@rank superadmin`, Idle + Dead status, VIP filter (temporary
  `;assignrank gabrielgaming_offv1:5m VIP`), Recently left + its Profile
  button. Still open: team indicators / select by team (the place has no
  teams), sort order, previous usernames. Not built: badges. Testing
  place: 2 investigation notes on the test account. Something in the game
  kills the alt repeatedly (Dead -> Active -> Dead) - not Sentinel.
- **Desktop-control testing in the Roblox client:** a click where the cursor
  already rests is ignored (move the mouse first); the first click after
  typing / Esc often only refocuses; typing a command with a trailing
  newline can send Enter before the last characters - press Return
  separately. The command bar appears ~1 s after the >_ button.
- Players page re-renders only when row data changes (Recent view: when the
  lists change or every 20 s) so clicks aren't lost to a rebuild -
  published as place **version 194** (servers started before it still run
  v192). Publish = Studio File > Publish (Alt+P); `save_place` never
  publishes.

- **W14 not verified live:** accepting an appeal (the lifters: unban /
  unmute / unjail / remove warning) is only unit-tested - in solo Play you
  can't decide your own appeal. "Appeal acceptance/rejection" stays
  unchecked in the blueprint until a second account accepts one. Also
  untested live: release from the ban screen when the ban is lifted
  meanwhile, decision notice on next join, reporting a real second player
  (needs 2 players; the test report was filed server-side).
- Test data left in the testing place: report #1 (Dismissed), appeals #1
  and #2 (Rejected, "Test cleanup"), case #26 (mute, Revoked) and a
  "Ban screen test" ban case (expires by itself; the ban was removed).
- Studio MCP: `start_stop_play` can get stuck on "Start play hasn't
  finished yet" when a modal (e.g. the Disconnected / kick dialog) is open
  in Studio - close it (desktop control) and press Play in Studio.

- **Icon assets (2026-11-21):** `src/ReplicatedStorage/Shared/Sentinel/Icons.lua`
  holds `Assets` (user's upload name -> **Image** id; 52 filled in) and
  `Slots` (UI slot -> asset + emoji fallback). Helpers: `Icons.prefix(label,
  key, text, size)` for "[icon]  text" labels (centered labels follow the
  text via `Icons.follow`, measured with TextService because TextBounds
  includes the shell's UIScale). Creator Hub shows *Decal*
  ids, which fail ("Asset type does not match"); resolve with
  `InsertService:LoadAsset(decalId)` -> `Decal.Texture` in Edit.
  Wired: sidebar sections/pages + nav tabs (Shell), bell/gear buttons,
  Quick Action cards, Server page toggle rows. Also wired (2nd pass): Settings
  page (section headers, Mute/Reduce motion/history rows, Not Implemented
  rows, Refresh), Appearance/Keybinds nav, Search button, clock, Command
  Palette risk tags (icon placed after the measured name), Server page
  Weather/Lighting/Slow Mode rows. Config.NOTIFICATIONS.TYPES `icon` is now
  an Icons slot key (that table has no consumers). Unused uploads ready to wire: rank badges
  (OwnerIcon/DevIcon/SuperAdmin/Admins/Moderator/VIP), status dots,
  utility (Delete/Copy/Download/Export/Refresh/ThreeDots2/Fullscreen/
  HalfArrow), Search, Star, QuickActions, NotificationsAwaiting (unread bell).
  Not converted: inline text glyphs (✓ ✗ ★ ⚠ in sentences), Players page
  toggles, Economy/Settings/Developer labels, RankService rank icons.

- **Announcements / approval / PM - not verified (needs a 2nd player):**
  the real approval hold (a non-Owner staff member running a critical
  command while the Owner is online; logic unit-tested in
  `Announcement.spec`, the Owner card / Approve / Deny / `;deny` were
  tested with `;approvals test`); a PM reply from a non-staff player; the
  global announcement on a second server. Not built: announcement
  scheduling (blueprint item, belongs with W-scheduling), countdown not
  re-checked. TRS_Admin_Panel / Vantage stay in the testing place - ask
  the user before removing them.
- **UI redesign leftovers:** pages still hard-code a few non-palette
  colours and module-level colour tables (they keep the old colour until
  rejoin after a theme change); Esc also opens Roblox's menu when it closes
  the command bar; the command bar as a **VIP without the panel** was not
  tried (needs a second account); Animations off, panel size, Frost /
  Sentinel bar presets, bar width / opacity / rows / other keys and the
  minimize + resize handle with the new shell were not clicked through.
  No light panel theme and no custom colour picker yet (blueprint "Light
  theme", "Custom themes", "Custom color palette", import / export stay
  open). `SettingsPage`'s old preferences section is unchanged.
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
- **Panel closing on its own: solved in W08.** Ctrl+Shift+P also toggled
  Roblox's developer Freecam (Shift+P, `PlayerGui.Freecam`), which hides
  every ScreenGui. Palette is now Ctrl+K and Shift+P can't be bound.
- **W08 not verified live (so not ✅):** warning escalation from config
  (the test account has 4 warnings - don't warn yourself), default ban
  duration actually applied to a ban (unit-tested only), default
  permissions on an unranked player (needs a second player), log
  retention (no persistent log until W10), `;config prefixes` through the
  new page, UI scaling / animation speed / reduced motion by eye, the
  "Use these colours" button (import path was used), notification sound
  (can't hear it via MCP). Theme row chips (7) nearly fill the row; a
  narrower panel may overlap the label. A command cancelled by a Before
  hook (e.g. max duration) still starts its cooldown (pre-existing order).
- W06 leftovers: the dry-run preview can't show what "random" will pick
  (re-rolled each preview); the highlighted copy is hidden when the input
  overflows horizontally.
- W05 palette leftovers: ghost text is hidden for quoted completions
  (team names with spaces) and once the input scrolls horizontally; the
  value being typed isn't validated until you move past it; the
  "Recent" rows are session-only (persisted history = W06/W08).
- The old panel's `AdminPanelClient` also binds **F** to its own fly; its
  `AdminPanelV43` / `NotificationGui` duplicate in PlayerGui on each respawn.
- `StarterGui/SentinelUI/PlayerControlsSystem.lua` (V4.3 port) is **not
  wired and shouldn't be**: fly / noclip / god / effects already run
  server-side with quick keys (W08), and it binds its own keys + uses
  `Config.KEYBINDS`. Ask the user whether to delete it. `Config.lua` ranks
  are only reference; RankService owns ranks.
- **W12 not verified / open (so not ✅):** pending reports card shows "-"
  until W14; recent warnings list (no second player to warn - the test
  account has 4 warnings); automatic escalation cases; punishment expiry
  seen live (unit-tested only); cases written by two servers at once;
  pre-W12 bans / mutes have no case, so the Active bans / mutes cards only
  count punishments given since W12. There is no local `;unban` (only
  `;gunban`) - W13. Testing place has 5 test cases (#1-#5).
- **W10/W11 open:** Discord webhook integration not built (Discord blocks
  Roblox; needs an HTTP proxy - external infra decision). `;resetranks`
  style confirmations are not logged until `;confirm` runs them. Pages are
  per server, so a search sorts by page newest-time: entries from different
  servers can interleave slightly out of order across "Load older" calls.
  The 30-min prune and close-time flush were tested on demand / by restart
  only. Testing place has ~8 test audit entries (harmless; 30-day retention).
- **W09 not verified, so not ✅:** "Mobile layout" - tested only as forced
  Mobile mode on a desktop screen (no touch device / phone-size emulator
  through Studio MCP); pages were swept at 620 px, not at phone width
  (~380 px). The Ban prompt's final send was not clicked (only one test
  account: it would ban itself). Appearance rows keep fixed label widths,
  so choice chips can overlap labels in a very narrow panel.
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

- **W22 server management** built and verified in Studio Play, **not
  committed** (ServerStateService, AccessList, AdminConfig, RankService,
  CrossServerService, UIBridge, ServerControl, ServerPage, init.server,
  `Tests/ServerManagement.spec`). Unit tests **127/127** (Edit).
- **Sound effects** and **W15** committed (`8c49504`). W14 + icon assets
  committed (`5fe2e04`). Test account's sound prefs reset to defaults.
- The test account now has **5 warnings** on record (was 4; added by
  another session) - still never `;warn` yourself.
- **Mobile pass / `;sentinel` / selection targets** (see §3) built and
  verified in Play with an emulated viewport, **not committed**.
- **W12 + Roblox-style redesign** committed and pushed (`0630fd8`).
- **W10 persistent audit + W11 Logs page** committed (`6ed1d87`).
- **W09 responsive UI pass** committed (`daef915`). README roadmap marks
  Phase 7 done.
- **W08 settings integration** is committed (`0d24484`). Testing-place admin config is back to defaults and
  the test account's personal prefs were reset.
- **UI redesign** committed as `6812a92`.
- **W01-W07 are done and committed** (`b5c6620`). **Cross-server
  (W17-W21) was built out of order** on 2026-11-16 because the user asked
  for the biggest task in `Docs/Planned`; committed and pushed (`87bc1b7`). W22 (server management
  leftovers + live two-server test) is still open.
- **Schedule position:** W15 done; W16 skipped for now (user); W17-W21
  built earlier; W22 built (live test pending); next after the live test
  is **W23 - Polls**. About 8 weekends
  ahead of the dates in
  [`Docs/Planned/Implementation Schedule.md`](Docs/Planned/Implementation%20Schedule.md);
  keep the dates, just continue with the next undone row.
- **W-FINAL (Modules Ecosystem)** is planned in `Docs/Planned` and the
  schedule (Phase 7); it comes after W42 - not next.
- Testing-place state: 6 default ranks; prefixes reset to `;`; the test
  account's library only holds recent lines (test preset and favorites
  removed). Studio-only change (not in repo): `ServerScriptService.
  Datastore.DataHandler` reuses an existing `leaderstats` folder.
- Feature blueprint: **337 bullets ✅** (W22 +12: server JobId, uptime,
  player count, max capacity, version, status, performance, memory,
  heartbeat, average ping, current staff, shutdown server; +2 from the W15 live test): sound notifications 1, W15 33
  (search by UserId, avatars, thumbnails, rank / health / ping / status
  indicators, recently joined, staff + suspicious filters, 16 profile
  fields, bulk actions, select all / all but me / by rank / attribute /
  property, investigation notes), W14 8 (pending reports, player report system, report management, evidence attachment, report assignment, report status, appeal submission, appeal review), announcements 6 (staff-only,
  targeted, custom colours, duration, history, notification banner), W13 6 (offline player profiles,
  offline moderation history, unban x2, temporary ban, secure offline
  lookups), W12 20 (custom ban / mute
  durations, reason templates, required reasons, ban / mute history, bulk
  punishments, active cases, recent punishments, active bans / mutes,
  moderators online, activity, case search / filtering / details, staff
  responsible, moderator notes, internal discussion, collaboration), W10/W11 28 (12 audit fields,
  search, 7 filters, pagination, persistent, export, configurable
  retention, cross-server logs, failed-action logs, data modification
  history, admin-config log retention), W09 4 (sidebar customization,
  resizable windows, favorite pages, compact mode), W08 20 (light theme, custom themes,
  custom palette, theme import / export, font, high contrast, open / close
  panel, palette, quick fly / noclip / god, next / previous page, custom
  keybindings, command cooldowns, maximum punishment, required reasons,
  notification preferences), UI redesign 6 (command bar, open
  command bar key, dark / midnight / ocean themes, accent colour), cross-server 27 (server list,
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

- **Commit W13 + the announcements / approval / PM work** if the user
  agrees; ask about wiring Roblox's `Players:BanAsync` (experience-wide
  Roblox bans) and whether the default approval risk should be `high`
  (includes bans). Then **W14 - Reports & appeals**.

0. **Ask the user to try the mobile pass on a real phone** (top bar
   buttons, panel, palette) and commit it if they agree.
1. Ask
   whether the command bar / palette should get the Roblox look next, and
   whether page content (dashboard cards etc.) should be restyled too. Decide the Discord webhook
   proxy (W11 leftover). Ask whether to delete
   `PlayerControlsSystem.lua` (see §5).
2. **Publish and test with two
   live servers** (§5 cross-server list) and ✅ the remaining §6 blueprint
   bullets.
3. **`GrantScript`**: Studio-only `Workspace.SentinelWorkspace.GrantScript`
   is redundant and logs `unknown role 'Owner'` at boot. Ask before
   touching it.
4. **Two-player test session** (Studio *Test > Clients and Servers*, 2
   clients, one with a lower rank): rank protection, hidden pages,
   view-only Ranks page, Owner-only refusal, bulk confirmation, permission-
   denied feedback, multi-player targeting, Staff Online count.
5. **Live-server check**: text censoring (Studio doesn't filter text).
6. Phone check of the mobile layout (Studio device emulator by hand).
7. Scaffold `src/client`, `src/server`, `src/shared`: ask whether to delete.
8. Continue with **W13**.

## 7. Session log (newest first)

- **2026-11-22 (W22)** - User asked for W17-W21; they were already built
  (2026-11-16), so wrote the full W status plan and moved to W22 (user
  approved). Built the join gate, custom messages, soft cap, whitelist via
  config (staff bypass, all servers), private-server access, LocalInfo,
  `;serverinfo` / `;kickall` / `;kicknonstaff` / `;servercap`, shutdown
  countdown, Server page sections. Verified in Play: every command by
  remote (validation, confirmations), info card values, cap Apply by mouse
  -> "5 of 60", Kick non-staff -> Critical dialog, shutdown 5 s countdown
  -> player kicked. Tests 127/127. Blueprint +12 ✅. Not committed.

- **2026-11-22 (W15 live test)** - Committed + pushed `8c49504`. The
  published server already had it (Version 192). Tested by desktop control
  with the user's alt: see §5 "W15 live test". Fixed: Players page rows
  rebuilt every 4 s (could swallow clicks). Blueprint +2 ✅ (recently left,
  VIP filters).

- **2026-11-22 (sound effects + W15)** - User asked for configurable sound
  effects first (8 uploads + 2 icons; ids read off Creator Hub by desktop
  control, verified in Studio; icons resolved Decal -> Image). Built
  SoundLibrary, UIPrefs Sounds, SoundPlayer, Sounds page, speaker toggle,
  `;sounds`. Found + fixed: PreloadAsync accepted an image id as a sound.
  Then W15: PlayerExplorerService, selector fixes (@rank was dead),
  ResolveTargets / Activity remotes, `;investigate`, multi Selection,
  Players page rework. Fixed: note box showed "TextBox", UIStroke outlined
  note text. Verified in Play by remote / mouse / keyboard. Tests 122/122.
  Blueprint +34 ✅. Left: white sound icons (ask user), 2-player checks.

- **2026-11-21 (W14 reports & appeals)** - User chose the pre-kick ban
  screen and bans + mutes/jails/warnings as appealable. Built ReportService,
  AppealService, PlayerFormsService, Reports.lua commands, 5 config keys,
  UIBridge remotes + queue push, PlayerForms client (report / appeal forms,
  ban screen, notices), ReportsPage (Reports + Appeals pages), dashboard
  cards, `Reports.spec` (120/120). Play-verified: report form, report queue
  + detail + claim + dismiss with note, mute -> appeal form -> appeal ->
  staff toast -> Appeals page, self-decision refused, ban -> ban screen
  (no character, countdown) -> appeal from it -> kick. Fixed the missing
  ban check for players who join before init.server connects PlayerAdded.
  Cleaned up the test ban / appeals. Blueprint +8 ✅. Left: live accept test.

- **2026-11-21 (icon assets)** - Cut the user's icon sheet into 37
  transparent 256px PNGs in `assets/icons/`; added `Icons.lua` config with
  `image/text/attach/place` helpers; Shell, QuickActionsPanel, ServerPage
  use slot keys. Verified in Play with a temporary rbxasset placeholder on
  home/settings/freeze (tab, gear, nav, card all render; emoji slots
  unchanged), then reverted. Then read the user's 52 uploaded Decal ids
  off Creator Hub via desktop control, resolved them to Image ids in
  Studio (all 52 preload OK), filled `Assets`, remapped slots; Play shows
  real icons. 2nd pass: read 9 more uploads, wired the remaining emoji
  spots the user flagged, verified in Play. Left: W14.

- **2026-11-21 (announcements / approval / PM)** - Before W14 the user
  asked for an Announcements section (History, Current server, Global,
  Some players), a redesigned banner with the admin's display name +
  avatar, Owner approval of risky commands (configurable) and more ;pm
  options, comparing features (not design) with TRS_Admin_Panel and
  Vantage. Built the items in §3. Verified in Play: banner, full screen
  (`;sannounce`, `;message`), `;gannounce` (Global chip), history page,
  Some players composer by mouse (select, Full screen, green, Send), PM
  with kind / title / ack, reply + read receipt, approval test card
  Approve by mouse, `;approvals` / `;deny`, option errors, Security rows
  in Administration. Fixed: cards under the full-screen backdrop, reply
  status on the wrong card. Tests 113/113. ✅ 6 bullets. Not committed.

- **2026-11-20 (W13)** - Built offline management: PlayerProfileService,
  ban index + `;unban` / `;isbanned` / `;banlist` / `;profile`, two
  remotes, Lookup page, `Profile.spec` (tests 106/106). First Play boot
  failed on a malformed string in Ban.lua (escaped newlines lost by the
  edit script). After a Studio restart, verified in Play: `;profile`
  (offline Roblox + `me`), `;isbanned`, gban 5m, `;banlist`, `;unban`, the
  Lookup page by mouse (lookup, ban through the ConfirmDialog, banner
  update, Ban list + Unban row). Fixed: `GetUserInfosByUserIdsAsync` is on
  UserService; `me` didn't resolve; page reloaded before the confirmation
  finished. ✅ 6 bullets. Not committed.

- **2026-11-20 (mobile pass)** - Pushed `0630fd8`. User found the panel
  and top bar buttons not adapted on a phone, asked for `;sentinel` /
  `;opensentinel` (chat + command bar), and for the Players page selection
  to drive the Commands page. Built the items in §3 "Mobile pass". Verified
  in Play: `openSentinel` / `Sentinel Players` via remote, emulated 844x390
  and 667x375 (Commands, Players, Dashboard, Moderation, Ranks screenshots;
  automatic overflow scan of all 17 pages = 0), selecting a player then
  Commands Run `heal` -> history shows `heal gabrielethangame`. Not
  verified: a real phone (top bar inset on mobile, touch scrolling,
  palette size), portrait. Tests 102/102. Not committed.

- **2026-11-20 (Roblox-style redesign)** - User sent screenshots (Roblox
  top bar with icon pills, an "Info" welcome notification) and asked for:
  that notification style, a welcome card for everyone with command perms,
  Sentinel + command bar buttons in Roblox's top bar, and a panel redesign
  in that style - not W13, and no changes to the command bar / palette.
  Built Roblox theme + defaults, notification cards (`Notify`),
  `GetWelcomeRemote`, `TopbarIcons`, Shell restyle. Verified in Play by
  mouse: welcome card + Owner chip, pause, close, Learn More, top bar S
  (panel opens, highlight) and >_ (bar opens), Appearance with 8 theme
  chips. Tests 102/102. ✅ 2 bullets (information notifications,
  individual dismissal). Not committed.

- **2026-11-17 (W12)** - User asked to continue the plan through all rows.
  Built `Systems/CaseService` (persistent cases, statuses, notes,
  assignment, revoke, expiry, search, dashboard, reason templates with
  `#name` expansion), `Commands/Moderation/Cases.lua`, 3 UIBridge remotes,
  new Moderation page (Dashboard / Cases / Bulk), escalation cases,
  `Cases.spec` (tests 102/102). Verified in Play by remote, mouse and
  keyboard: mute / jail with `#templates` -> cases, unmute / unjail revoke,
  investigation open / note / assign / close / reopen, gban + gunban of an
  offline account (global case, active-ban count 1 -> 0), reasons add /
  remove, dashboard cards + activity bars, case list + detail + note box,
  bulk mute through the panel, cases persisting across a restart. Fixed:
  activity bar overflow, Bulk status text. ✅ 20 bullets. Not committed.

- **2026-11-17 (planning)** - Added the user's W-FINAL Modules Ecosystem
  spec to `Docs/Planned`, as Phase 7 of the schedule and rule §0.2b (last
  milestone, no animation assets). Committed with W10 + W11.

- **2026-11-17 (W10 + W11)** - Persistent audit: richer Logger entries,
  `Logger.Matches` / `NoteChange`, `Systems/AuditService` (paged DataStore
  + ordered index, snapshot middleware for before/after values, search
  with cursor, retention prune), failed / denied / cancelled / rejected
  commands logged, config changes recorded, `;logs`, `SearchAuditLogRemote`,
  `Audit.spec` (tests 94/94). Logs page (Insights > Audit Log). Fixed while
  testing: rows lost their header when expanded (AutomaticSize TextButton),
  cursor missing when unsaved entries filled a page, Config / Ranks chips
  matched nothing. Studio MCP got stuck on "Start play hasn't finished";
  the user restarted Studio. Verified in Play: entries persisting across 4
  server sessions, before/after (coins, walk speed, config), failed kick
  with reason, every filter by remote, chips / row details / export by
  mouse, pagination to the end, `;logs prune` on a planted 40-day page.
  ✅ 28 bullets. Not committed.

- **2026-11-17 (W09)** - Responsive UI pass: UIPrefs Layout section,
  Shell `relayout` (compact metrics, mobile window, width reflow, tab
  order / visibility, icon labels, pinned pages, status bar toggle,
  minimize keeps the title bar), `;layout` / `;pin` / `;unpin`, Appearance
  Layout rows + Navigation editor, themed `BanPromptSystem` + Players Ban
  button, reflow fixes (ServerPage, Players, Library, Cross-Server,
  Appearance). Fixed: Players detail panel blank until a tab was clicked.
  Tests 84/84. Verified in Play by mouse / keyboard / remote: star pin,
  compact, tab move / hide, icon labels, mobile + back to desktop, 600 px
  reflow, drag-resize, minimize / restore, status bar off, overflow sweep
  of 16 pages at 620 px, ban prompt (7d / custom / permanent / cancel),
  navigation editor show + unpin, prefs persisting across restart. ✅ 4
  bullets. `PlayerControlsSystem` left unwired (superseded). Not committed.

- **2026-11-17 (W08)** - Settings integration: UIPrefs Keys /
  Notifications sections, Light + Custom themes, fonts, animation speed,
  reduced motion, high contrast, theme codes; `Systems/AdminConfig` +
  `ConfigService.Define`; `;config`, `;theme export|import`, `;keybind`,
  `;notifyprefs`; Keybinds and Administration pages; one key dispatcher in
  init.client. Found the cause of "panel closes on its own": Ctrl+Shift+P
  also toggled Roblox Freecam; palette moved to Ctrl+K. Swapped Montserrat
  (an alias of Gotham) for Roboto. Tests 82/82. Verified in Play by remote,
  keyboard and mouse: config set / validate / reset (page + command),
  required reason, max duration, cooldown scale, quick fly / noclip / god,
  custom Ctrl+H bind, F6 / End / Ctrl+K / Ctrl+PageUp/Down, key recording,
  theme export / import, Light, Builder font refont, high contrast,
  notification corner, prefs persisting across restart. ✅ 20 bullets.
  Committed + pushed as `0d24484`.

- **2026-11-16 (UI redesign)** - User asked for a clean redesign before
  any other W: terminal-style command bar (customisable per staff / VIP,
  Owner picks the default) and a dynamic panel with animations. Built
  `Shared/UIPrefs`, `Systems/PrefsService`, `;commandbar` / `;theme`,
  dynamic `Theme` (Apply / Retint / tween), new `Shell` (section tabs, sub
  menu, status bar, open / close / page animations), `CommandBar`,
  `AppearancePage`. Fixed while testing: Esc didn't close the bar, typed
  text was lost when the bar rebuilt, theme chips overlapped their colour
  dot. Tests 72/72. Verified in Play by keyboard and mouse: bar open (F2),
  command and argument suggestions, Tab / Down / Enter, error colouring,
  Carbon preset, bottom position, font size live; section tabs and sub
  menu; Appearance page switching Ocean + Cyan live; personal > default >
  built-in layering and input validation by remote. ✅ 6 bullets. Not
  committed. (Cross-server work committed + pushed as `87bc1b7`.)

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
