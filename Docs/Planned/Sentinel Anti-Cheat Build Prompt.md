# Sentinel Anti-Cheat: Build Prompt

Nov 26, 2026 · @GDev

Paste this whole document into your AI coding assistant, along with the Sentinel files it needs to read. It builds a server-authoritative anti-cheat for Sentinel plus an Anti-Cheat Control Center panel, opened with F7.

## 1. Role, goal and rules

You are a senior Roblox Luau engineer. Build "Sentinel AntiCheat", an advanced anti-cheat system with an "Anti-Cheat Control Center" UI, as a native add-on to my existing admin panel, Sentinel. I am the owner of Sentinel. The game is mine, and this system defends it against exploiters.

**Goal.** Detect abnormal player behavior on the server, score it, act on it automatically within limits I configure, and let staff review everything from one panel.

**Hard rules.**

1. The server is the only authority. Never trust the client for a verdict. Client scripts may only report raw observations, and the server treats those reports as untrusted hints.
2. Detect through server-side measurements first: position, velocity, health, tool and inventory state, remote call rates, and humanoid properties as the server sees them.
3. Never auto-ban on a single signal. Every detection adds to a suspicion score. Bans come only from a score threshold, a repeated pattern, or a staff decision.
4. Protect honest players. Every check needs lag tolerance, a grace period after spawn and teleport, and an exemption for legitimate game mechanics such as vehicles, seats, knockback and staff commands.
5. No hard-coded user IDs, API keys or webhook URLs anywhere. Everything comes from config or from Sentinel's rank system.
6. Validate every argument that reaches the server from the client: type, size and range. Rate-limit every remote.
7. Use `--!strict` Luau, `pcall` around every DataStore and MessagingService call, and a graceful fallback when they fail.
8. Follow Sentinel's existing patterns. Study how `CommandRegistry`, `PermissionSystem`, `ConfigService`, `AuditService`, `RateLimiter`, `UIBridge`, `PunishmentService` and the `Tests/*.spec` files are written, and match their style, naming and header comments.
9. This is defensive software. Do not write cheat code, bypass guides or exploit proofs of concept.

## 2. Architecture

Add the anti-cheat inside Sentinel's existing folders. Do not create a second admin framework, and do not touch unrelated files.

```text
ServerScriptService/Sentinel/
  Systems/AntiCheat/
    AntiCheatService      -- boot, module loader, master on/off, public API
    DetectionEngine       -- receives flags, runs the scoring pipeline
    ScoreService          -- per-player suspicion score, decay, history
    ActionService         -- action ladder (log, warn, kick, ban) via PunishmentService
    ExemptionService      -- grace periods, whitelists, staff and vehicle exemptions
    EvidenceService       -- stores a snapshot with every flag
    AntiCheatConfig       -- defaults, schema and validation (stored via ConfigService)
    Modules/              -- one ModuleScript per detection (section 3)
  Commands/AntiCheat/     -- chat and command-bar commands (section 5)
  Tests/AntiCheat.spec    -- unit tests (section 8)
ReplicatedStorage/Shared/Sentinel/AntiCheatTypes   -- shared types only
StarterGui/SentinelUI/AntiCheatCenter/            -- UI pages (sections 6 and 7)
StarterPlayer/StarterPlayerScripts/Sentinel/      -- tiny client reporter, extended
```

**Module contract.** Every detection module returns a table with `Name`, `Enabled`, `Interval`, `Check(player, state)`, and `Defaults` for its settings. `Check` returns nil or a flag: `{ Module, Severity (1-10), Confidence (0-1), Reason, Evidence }`. A module never punishes. It only reports to `DetectionEngine`. Modules load from the `Modules` folder automatically, so adding a file adds a detection.

**Scheduling.** One shared `Heartbeat` loop spreads checks across players and frames. Each module declares an interval, and the engine staggers them so no frame runs more than a fixed budget of checks. Measure the cost and expose it in the Control Center (the Performance page).

**Integration points.** Use `PermissionSystem` nodes for access, `AuditService` for every action, `UIBridge` for UI-to-server calls, `ConfigService` for live settings pushed to all servers, `CrossServerService` for shared bans and alerts, and `CaseService` so a flag can become a case.

## 3. Detection modules

Build each module as its own file. Every threshold below is only a default. All of them must be editable live in the Control Center.

| Module | Detects | Server-side method | Default severity |
| --- | --- | --- | --- |
| SpeedCheck | Moving faster than allowed | Compare real distance moved per interval with `WalkSpeed` x time plus a lag margin; ignore falling, seats, vehicles and staff-granted speed | 4 |
| FlyCheck | Sustained flight or hovering | Track time airborne with no ground contact and no upward force source; flag if vertical position holds against gravity | 6 |
| TeleportCheck | Instant position jumps | Flag a jump over the max distance in one step without a known teleport source (Sentinel commands, game teleports are registered as legitimate) | 7 |
| NoclipCheck | Moving through solid geometry | Raycast along the path between two server positions; flag repeated passes through anchored, collidable parts | 6 |
| JumpCheck | Impossible jump height or rate | Compare peak height and jump frequency to `JumpPower` or `JumpHeight` | 3 |
| HealthCheck | God mode, health rewrites | Detect health that rises with no heal source, or never drops after confirmed damage | 5 |
| RemoteSpamCheck | Remote flooding and abuse | Count calls per remote per second using the shared `RateLimiter`; flag bursts and wrong argument types | 5 |
| ToolIntegrityCheck | Tools the server did not give | Compare each character's tools with `InventoryService` records; flag unknown or duplicated tools | 6 |
| CombatCheck | Impossible hit rates or ranges | Validate hits server-side: distance, line of sight, fire rate, cooldown | 6 |
| CharacterIntegrityCheck | Tampered character parts | Detect body-part size or `CanCollide` changes, a missing Humanoid, and unexpected scripts parented to the character | 5 |
| AnimationCheck | Forbidden or spoofed animations | Compare playing animation tracks with an allowlist of IDs your game uses | 3 |
| EconomyCheck | Impossible gains | Flag currency or stat deltas above a per-minute cap or from no known source | 7 |
| ClientReportCheck | Client-side tamper hints | Accept signed-in-session reports from the tiny client reporter (for example, a missing core script). Weight these low, because clients can be spoofed | 2 |
| AltAndBanEvasion | Banned users returning | Compare the joining account against banned accounts using account age and join patterns. Flag only; staff decide | 4 |

**For each module the AI must also write:** a one-paragraph header comment explaining the false-positive cases it handles, a `Defaults` table (enabled, thresholds, grace seconds), and at least two unit tests (a clean case and a flagged case).

**Never** implement a check that depends only on something the client controls and then punishes on that alone.

## 4. Suspicion score and actions

**Scoring.** Each flag adds `Severity x Confidence x ModuleWeight` to the player's suspicion score. The score decays over time (default 1 point per minute, editable) so a single odd moment fades, while repeated flags stack. Scores are per player and per session, and the history of flags is kept for review.

**Action ladder.** Actions run in `ActionService` through Sentinel's `PunishmentService`, so every action appears in the audit log and in cases. Defaults below are editable per band.

| Score | Mode: Observe | Mode: Balanced (default) | Mode: Strict |
| --- | --- | --- | --- |
| 0-19 | Log only | Log only | Log only |
| 20-39 | Log + staff alert | Log + staff alert | Silent correction (reset position or state) |
| 40-59 | Log + staff alert | Warn player | Kick |
| 60-79 | Log + staff alert | Kick | Temporary ban (server) |
| 80+ | Log + staff alert | Queue for staff review | Ban (game), with an owner-approval option |

**Rules for actions.**

1. Observe mode never punishes. It is the safe way to tune a new game before enabling anything else.
2. Automatic game-wide bans always require either staff approval or a repeated pattern across at least three different modules. Use Sentinel's owner-approval flow for this.
3. Silent corrections (snapping back to the last valid position, restoring health) come before kicks, since they fix the effect without punishing.
4. Every action stores evidence: the flag list, the last 10 seconds of position samples, ping, server FPS and the active exemptions.

**False-positive protection.**

- Grace window after spawn, respawn, teleport, seat exit and character load (default 3 seconds).
- Lag compensation: widen thresholds by the player's measured ping and by server frame time.
- Auto-exempt staff above a chosen rank (configurable), and any player a staff member has put in "Testing" mode.
- Per-module and per-player exemptions, with a reason and an expiry.
- A "Mark as false positive" button feeds back into the system: it lowers that module's weight for the player and shows up in the module's false-positive rate on the Performance page.

## 5. Permissions, config, storage and commands

**Permission nodes** (register them in `RankService`; Owner has all, and ranks are edited in the existing Ranks page):

| Node | Allows |
| --- | --- |
| `anticheat.view` | Open the Control Center, see flags and players |
| `anticheat.review` | Open evidence, mark false positives, create cases |
| `anticheat.exempt` | Add and remove exemptions |
| `anticheat.act` | Warn, kick, silently correct from the Control Center |
| `anticheat.ban` | Ban from the Control Center (risk level: high, uses owner approval) |
| `anticheat.config` | Change thresholds, weights, modes and modules |
| `anticheat.master` | Turn the whole system on or off (Owner only by default) |

**Config.** Store every setting through `ConfigService` under `AntiCheat.*`, so changes reach all servers live. Include a schema with min, max and default for each value, and reject invalid values with a clear message. Add a "Reset to defaults" per module and globally. Config changes are audit-logged with old and new value.

**Storage.** Use versioned DataStore names, for example `Sentinel_AC_Flags_v1` and `Sentinel_AC_Exemptions_v1`. One key per player, never one key for everyone. Keep a capped history (default 200 flags per player, 30 days). Batch writes, throttle them to respect budget limits, and retry with backoff. If a DataStore fails, keep data in memory and surface a warning in the Control Center.

**Cross-server.** Publish high-severity flags and bans through `CrossServerService` so staff in any server see alerts and a banned player is removed everywhere. Cap message rate to stay within MessagingService limits.

**Commands** (register with `CommandRegistry`, prefix `;`, each with permission, risk level, help text and examples so `;help` lists them):

| Command | What it does |
| --- | --- |
| `;anticheat` (alias `;ac`) | Opens the Control Center |
| `;acstatus` | Prints mode, enabled modules, active flags and server cost |
| `;acmode <observe\|balanced\|strict>` | Sets the global mode |
| `;acmodule <name> <on\|off>` | Enables or disables one detection module |
| `;acscore <player>` | Shows a player's score and recent flags |
| `;acreset <player>` | Resets a player's score (audit-logged) |
| `;acexempt <player> [module] <duration> <reason>` | Adds an exemption |
| `;acunexempt <player> [module]` | Removes it |
| `;acwatch <player>` | Adds the player to the live watch list |
| `;acreview <flagId>` | Opens a flag's evidence |
| `;actest <player>` | Puts a player in Testing mode (all checks log only) |
| `;acexport` | Exports recent flags as text for staff |
| `;acpanic` | Emergency: switches all automatic actions off, detections keep logging |

## 6. Control Center: activation and navigation

Build the Control Center as a set of UI modules in `StarterGui/SentinelUI/AntiCheatCenter`, using Sentinel's existing `Theme`, `Shell`, `ToggleSwitch`, `ConfirmDialog`, `NotificationCenter` and `CommandPalette` modules, so it looks and behaves like the rest of the panel. Only players with `anticheat.view` can see or open it. For everyone else, the entry points do not exist (hide them, and also enforce it on the server).

**How staff open it** (all five must work):

1. Press **F7** (default keybind, rebindable in the existing Keybinds page; check that F7 is free in Sentinel and pick the next free key if not).
2. Click the shield icon labelled **AC** in Roblox's top bar, next to Sentinel's "S" button. A red dot on the icon means unreviewed high-severity flags.
3. Open the Sentinel panel (F6) and click **Anti-Cheat** in the left sidebar.
4. Press **Ctrl+K** and type "anti" to pick "Open Anti-Cheat Control Center".
5. Type `;anticheat` or `;ac` in chat or in the command bar (F2).

**First activation (setup wizard).** The first time an Owner opens the Control Center, show a 4-step wizard instead of the Overview page:

1. Welcome: what the system does, and that it starts in Observe mode.
2. Pick a preset: Observe, Balanced or Strict (the table in section 4).
3. Pick which modules to enable (all on by default), and who is exempt (ranks at or above the one chosen).
4. Review and press **Turn on**. The wizard finishes with a confirmation toast and opens the Overview page.

The master switch lives at the top of the Overview page, so the system can be turned off or on at any time without the wizard.

**Layout.** One window, 3 areas:

- **Top bar:** title "Anti-Cheat Control Center"; the master switch; the mode badge (Observe, Balanced or Strict); a live status pill (Healthy, Degraded, Off); the global search field; a bell for alerts; a close button (X).
- **Left sidebar:** the page list from section 7, each with an icon and an unread count badge. The current page is highlighted.
- **Main area:** the page content. A right-hand **detail drawer** slides over it when a row is selected (a player or a flag), and closes with Esc or its X button.

**Navigation and shortcuts.**

| Key or action | Result |
| --- | --- |
| F7 | Open or close the Control Center |
| Esc | Close the detail drawer first, then the window |
| Up / Down | Move through the sidebar or the table rows |
| Enter | Open the selected page or row |
| 1 to 9 | Jump to sidebar pages 1 to 9 |
| / | Focus the search field |
| Ctrl+K | Open the command palette with Anti-Cheat actions listed first |
| R | Refresh the current page |
| Right-click a player or flag row | Context menu: Open, Watch, Exempt, Create case, Copy ID |

The window supports a mouse, a keyboard and a touch screen. It is draggable and resizable on desktop, and full screen on phones, with the sidebar collapsed into a menu button.

## 7. Control Center pages and every button

Build these 9 pages, in this sidebar order (keys 1 to 9). Every button below must work, ask for confirmation when it is destructive (`ConfirmDialog`), be disabled with a tooltip when the viewer lacks the permission, and write an audit-log entry. Every table must support sorting by column, text filtering, paging (50 rows) and empty and loading states.

### Page 1: Overview

Purpose: the health of the system at a glance.

- **Cards:** flags in the last hour; players currently above 40 points; actions taken today; flags awaiting review; server cost (ms per second spent on checks); false-positive rate.
- **Live feed:** the last 20 flags, newest first, each with player, module, severity badge and time.
- **Sparkline:** flags per minute over the last hour.

| Button | Action |
| --- | --- |
| Master switch | Turns the whole system on or off (`anticheat.master`; asks to confirm) |
| Mode selector (Observe, Balanced, Strict) | Changes the global mode; asks to confirm when moving to Strict |
| Panic | Disables all automatic actions at once; detections keep logging. Shows a red banner until re-enabled |
| View all | Opens Page 2 with the current filters |
| A card | Opens the page behind it (for example the "awaiting review" card opens Page 4) |

### Page 2: Live Flags

Purpose: a real-time table of every flag from every server.

Columns: time, player, module, severity (colored 1-10), confidence, score after, reason, server. Filters: module, severity range, player, time range, server, "only unreviewed".

| Button | Action |
| --- | --- |
| Pause / Resume | Freezes the live updates so staff can read |
| Filter chips | Toggle a module or severity filter |
| Row click | Opens the flag detail drawer |
| Mark reviewed | Marks the selected flags as reviewed |
| Mark false positive | Records a false positive and lowers the module's weight for that player |
| Create case | Turns the flag into a `CaseService` case with the evidence attached |
| Export | Copies the filtered rows as text (CSV) |

**Flag detail drawer:** shows the full reason, the evidence snapshot (position samples, ping, FPS, exemptions in effect), the player's score history, and the actions above.

### Page 3: Players

Purpose: every player in this server (and a lookup box for anyone else).

Columns: avatar, name, score (bar), top module, flags today, status (Clean, Watched, Exempt, Testing), ping, rank. Search by name or ID.

| Button | Action |
| --- | --- |
| Row click | Opens the player drawer: score graph, flag history, active exemptions, notes |
| Watch | Adds the player to the live watch list |
| Exempt | Opens a small form: module (or all), duration, reason |
| Testing mode | All checks on this player log only (for staff testing) |
| Reset score | Sets the score to 0 (confirm; audit-logged) |
| Warn / Kick | Uses `PunishmentService` with a required reason |
| Ban | Opens the existing ban prompt with the evidence attached (uses owner approval) |
| Spectate | Uses Sentinel's existing control tools to view the player |
| Lookup | Searches a player not in the server by name or ID |

### Page 4: Review Queue

Purpose: players the system wants a human to decide on (score 80 or more, repeated multi-module patterns, ban proposals).

| Button | Action |
| --- | --- |
| Approve ban | Executes the proposed ban (needs `anticheat.ban`) |
| Dismiss | Closes the item as not a cheater; the score is reduced |
| Escalate | Sends it to the Owner for approval |
| Evidence | Opens the evidence drawer with a timeline of flags |
| Add note | Saves a staff note on the player |
| Assign to me | Marks who is handling it |

### Page 5: Modules

Purpose: control each detection.

One card per module (section 3): name, description, ON or OFF switch, flags in 24 hours, false-positive rate, average cost.

| Button | Action |
| --- | --- |
| ON / OFF switch | Enables or disables the module live on all servers |
| Weight slider (0 to 2) | Changes how much this module adds to scores |
| Configure | Opens its settings: thresholds, grace seconds, interval, each with a valid range |
| Test | Runs the module against the staff member's own character in log-only mode and reports the result |
| Reset | Restores this module's defaults |

### Page 6: Exemptions and Watchlist

Two tabs: **Exemptions** (player, module, reason, who added it, expiry) and **Watchlist** (player, since, why, score).

| Button | Action |
| --- | --- |
| Add exemption | Form: player, module or all, duration (minutes, hours, days, permanent), reason (required) |
| Remove | Deletes the selected exemption or watch entry (confirm) |
| Extend | Adds time to an exemption |
| Rank exemption | Sets the minimum rank that is exempt automatically |
| Watch alerts toggle | Notifies staff when a watched player joins any server |

### Page 7: Settings

Purpose: tuning. Requires `anticheat.config`.

Sections: **Mode and action bands** (the table in section 4, editable), **Scoring** (decay per minute, score cap), **Grace and lag** (grace seconds, lag tolerance multiplier), **Storage** (history length, retention days), **Alerts** (who is notified and at what severity), **Cross-server** (share alerts, share bans).

| Button | Action |
| --- | --- |
| Save | Validates and saves; shows exactly which values changed |
| Discard | Reverts unsaved edits |
| Reset section | Restores defaults for that section (confirm) |
| Export / Import config | Copies or pastes the whole config as text; import validates before applying |
| Preset buttons | Observe, Balanced, Strict apply a full set of values (preview first) |

### Page 8: Analytics and Performance

Purpose: judge whether the system is accurate and cheap.

- **Charts:** flags by module, flags over time (24 hours, 7 days), top 10 flagged players, actions by type.
- **Accuracy:** per-module false-positive rate based on staff marks.
- **Performance:** milliseconds per second of server time per module, memory use, remote calls per second.
- **Health:** DataStore and MessagingService status, queue sizes, last error.

| Button | Action |
| --- | --- |
| Range selector | 1 hour, 24 hours, 7 days |
| Module filter | Limits the charts to selected modules |
| Recommend | Suggests threshold changes based on the false-positive data (never applies them automatically) |
| Export | Copies the numbers as text |

### Page 9: Logs and Help

Two tabs: **Audit log** (every anti-cheat action and config change: who, what, when, old and new value, filterable) and **Help** (what each module and page does, the shortcut table from section 6, and a link to the commands list).

| Button | Action |
| --- | --- |
| Filter and search | Narrow the log by staff member, action type or date |
| Undo | Reverses a reversible action (for example an exemption or score reset) |
| Copy | Copies a log line |
| Replay tour | Restarts the 4-step welcome tour |

**Always visible in the top bar of every page:** the master switch, mode badge, status pill, search (`/`), bell (alert list with Mark all read) and close (X). Toasts through `NotificationCenter` confirm every save, error or action.

## 8. Build order, tests and acceptance

**Work in these phases. Finish and test each one before starting the next, and show me a short summary after each.**

1. Read the existing Sentinel code listed in rule 8 and write a one-page plan: files to add, files to change (keep changes minimal), and any conflict you found (for example, an F7 key clash).
2. Core: `AntiCheatService`, `AntiCheatConfig`, `DetectionEngine`, `ScoreService`, `ExemptionService`, with Observe mode only and no punishment.
3. First modules: SpeedCheck, TeleportCheck, FlyCheck, RemoteSpamCheck, with tests.
4. `ActionService` and `EvidenceService`, wired to `PunishmentService`, `AuditService` and `CaseService`.
5. Remaining modules, one at a time, each with its tests.
6. Permissions, config schema, storage and cross-server alerts.
7. Commands (section 5).
8. Control Center UI: shell, setup wizard, then pages 1 to 9, then keyboard shortcuts and touch support.
9. Hardening pass: argument validation on every remote, rate limits, failure modes, and a review of false-positive cases.

**Tests** (`Tests/AntiCheat.spec`, in Sentinel's `t.test` style, runnable by the existing `TestRunner`):

- Each module: one clean case that must not flag, one flagged case that must.
- Scoring: adds, decays, caps; a single low flag never reaches an action band.
- Action ladder: each band and mode gives the expected action; Observe never punishes; automatic game bans need approval or a multi-module pattern.
- Exemptions: grace after spawn and teleport, staff rank, per-player and per-module, expiry.
- Permissions: each node is required for its buttons and commands, and the server rejects calls without it even if the UI is bypassed.
- Remotes: wrong types, oversized tables, nil values and floods are rejected and rate-limited.
- Config: out-of-range values are rejected; changes are audit-logged.

**Acceptance checklist.** The work is done only when all of these are true, and you list the evidence for each:

- [ ] The system starts in Observe mode and nothing punishes until I change the mode.
- [ ] All 5 ways of opening the Control Center work, and none of them is visible to players without `anticheat.view`.
- [ ] Every page and button in section 7 exists, works, and writes an audit-log entry.
- [ ] A player with no permission cannot read flags or run actions by calling remotes directly.
- [ ] A clean test player (normal sprinting, jumping, vehicles, respawns, staff teleports) produces no flags in Balanced mode.
- [ ] Server cost stays under the budget I set (default 2 ms per second for all checks at 50 players).
  - **Not met yet - measured 2026-11-27, Studio Play, 50 server-side dummy players (`;acloadtest 50 60`, 60% walking / 20% idle / 20% jumping), not live.** Full cost with the budget stretch locked at 1x: **29.4 ms/s** (0.59 ms/s per player, 412 checks/s, the 0.5 ms per-frame cap was hit in ~55 of 60 frames so checks queue), worst frame **0.93 ms**. With the 2 ms/s budget active the engine stretches intervals to the 12x limit and settles at **11.2 ms/s** (50 checks/s, about one check per player per second), worst frame **1.56 ms**. Biggest costs: position sampling 5.6 ms/s (fixed 5 Hz, never stretched), scheduler overhead 2.6, FlyCheck 0.8, NoclipCheck 0.7. Studio shares the CPU with the client and adds debugger overhead, so a live server is likely cheaper; the live number is still to be measured with `;acloadtest 50 60 nostretch` on a private server of the published place (allowed there, refused on public servers).
- [ ] With DataStore or MessagingService failing, the game and the panel keep working and show a warning.
- [ ] No hard-coded user IDs, keys or webhook URLs exist anywhere in the new code.
- [ ] All new scripts use `--!strict`, have a header comment in Sentinel's style, and pass the tests.

**Final deliverable.** List every file added or changed, a short install and rollback note, the default config, and any assumption you made. If something is unclear, ask me one short question instead of guessing.
