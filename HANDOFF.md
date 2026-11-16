# Sentinel — AI Agent Handoff

> **Read this first.** It is the shared memory between AI agent sessions
> working on this project. It tells you what the project is, how to work in
> it, what state it is in right now, and the rules every session follows.

_Last updated: 2026-11-15 by the session that fixed the boot crash, Gems
grants, fly, mute and panel dragging._

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
  - `require()` from `execute_luau` gets a *fresh* module copy (e.g. an
    empty CommandRegistry). To test commands, fire
    `ReplicatedStorage.Shared.Sentinel.ExecuteCommandRemote` from the
    **Client** DataModel instead.
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
    `Parser/` (Tokenizer, CommandParser, TargetResolver, Duration/Quantity
    parsers, CommandProcessor).
  - `Systems/` — services (Economy, Inventory, ChatModeration, Punishment,
    ServerState, Environment, Developer, **UIBridge**).
  - `Commands/<Category>/*.lua` — each file self-registers commands.
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
  are gated by `isStaff()`.
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
- Local-only modules not wired up or not in Studio yet: `BanPromptSystem`,
  `InGameSettingsPage`, `PlayerControlsSystem`, `RankManagementPage`,
  `Config.lua` (see `REFERENCE_PANEL_ADAPTATION.md`).
- Harmless console noise from the game's assets: sound
  `118939739460633` (no permission), asset `203785492` (wrong type).

## 6. Current state

- Sentinel server and client boot cleanly in Play.
- Verified working: command pipeline, Gems/Coins grants, `;message`/`;msg`,
  `;hint`, alias variants (`superfling`, `bigexplosion`), fly + bottom-right
  fly menu (Deactivate / Noclip toggle / Close), mute/unmute/timed mute,
  panel drag from the whole top bar (clamped on-screen).
- On `main` and pushed to GitHub: `527f146` (boot crash, Gems, utility
  commands), `b73b056` (fly, fly menu, mute, drag), `0ea0146` (this
  handoff + CLAUDE.md), `dad045a` (the user's Phase 7 in-progress work:
  new pages, `Commands/Player/*`, `Teleport.lua`, `Config.lua`, feature
  blueprint, README/known-issues updates). Working tree clean.
- Studio-only change (not in repo): `ServerScriptService.Datastore.DataHandler`
  reuses an existing `leaderstats` folder. Saved as place version 82.
- Feature blueprint: no items checked yet.

## 7. Session log (newest first)

- **2026-11-15 (later)** — Pushed the fix/handoff commits to GitHub;
  committed and pushed the user's remaining in-progress work as `dad045a`.

- **2026-11-15** — Fixed: server boot crash (duplicate alias `m` →
  `msg`), silent Gems grants (duplicate `leaderstats`), `/message` &
  `/hint` crash, `ctx.CommandName` missing, fly frozen (late
  `UserInputService`), mute leaking to sender (`CanSend`), panel drag.
  Added the fly control menu. Diagnosed the Rojo 7.6.1 vs 7.7 plugin
  mismatch. All verified in Play. Created this handoff document.
