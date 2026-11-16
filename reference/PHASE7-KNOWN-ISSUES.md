# Phase 7 Known Issues

Living list of deferred bugs found during Phase 7 (UI/UX) development.
Logged here rather than fixed piecemeal, so the end-of-phase fix pass can
address all of them at once.

## 1. Resize only resizes the outer window frame, not its contents

**Status:** Partially fixed in this drop; one more candidate found, not yet fixed.

Dashboard cards, Quick Action cards, and other page content use hardcoded
pixel widths rather than scale-relative/reflowing layouts. Narrowing the
Shell window clips or overflows content instead of reflowing it.

**Fixed:** the three clearest instances — non-wrapping horizontal card
rows that clipped instead of reflowing:
- `DashboardPage.lua`'s summary card row (Players/Heartbeat/Memory/Ping)
- `QuickActionsPanel.lua`'s action/toggle card row
- `DeveloperPage.lua`'s Performance tab stat card row (Uptime/Heartbeat/
  Memory/Players)

All three switched from a non-wrapping horizontal `UIListLayout` to
`UIGridLayout` (which wraps onto additional rows automatically) plus
`AutomaticSize` on the containing frame so it grows to fit however many
rows that ends up being. Where later content used to sit at a fixed
pixel offset assuming exactly one row (Dashboard's Quick Actions/
placeholder blocks, the Developer page's ping list under the stat
cards), that's now either a `UIListLayout`-driven vertical stack
(Dashboard) or repositioned dynamically off the grid's actual
`AbsoluteSize` (Developer Performance tab), instead of a fixed offset.

**Found, not yet fixed:** `ServerPage.lua`'s weather/lighting preset
button rows use the same non-wrapping horizontal `UIListLayout` pattern
and would clip with enough presets at a narrow width. Lower priority
than the three above since the current preset count fits comfortably at
normal window widths, but the same fix applies whenever it's picked up.

**Remaining scope:** the broader "every page, every hardcoded pixel
width" pass from the original plan below wasn't done — the three fixes
above targeted the specific non-wrapping card-row pattern that was
actually reported, not a blanket sweep of all ~90 hardcoded-pixel
`UDim2` usages across the UI (most of which are legitimately fine, e.g.
icon sizes, button heights, padding that should stay fixed regardless of
window width).

## 2. Drag and resize are both erratic

**Status:** Fixed in this drop.

**Root cause was:** `Shell.lua`'s drag/resize handler
(`UserInputService.InputChanged`) used `UserInputService:GetMouseDelta()`
to compute movement — the exact anti-pattern already flagged in the
project's own learnings (`GetMouseDelta()` is meant for camera-look
under `MouseBehavior = LockCenter`, not general UI drag/resize). Both
bugs shared this one root cause.

**Fix:** replaced `GetMouseDelta()` with absolute `input.Position`
delta-tracking against a saved start position (mouse position + frame
position/size captured in the `MouseButton1Down` handlers for
`dragHandle`/`resizeHandle`), matching the pattern already documented
as correct elsewhere in the project.

## 3. Player Explorer loses its selection highlight

**Status:** Fixed in the Phase 7F drop.

Root cause was as diagnosed: `renderTable()` rebuilt every row on each 4s
poll without reapplying the Accent color or updating the `selectedRow`
reference. Rebuilding `PlayersPage.lua` for 7F's new tabs touched this
exact code path, so it was fixed directly rather than left for the
end-of-phase pass: each rebuilt row now checks `row.UserId ==
selectedUserId` and colors itself accordingly, and `selectedRow` is
reassigned to the new live instance so a later click correctly clears
the old highlight instead of leaving a stale reference behind.

## 4. Gems economy grant fails silently in the Economy page

**Status:** Fixed (live repro done in Studio).

**Root cause:** the game's own `ServerScriptService.Datastore.DataHandler`
always created a second `leaderstats` folder. When it won the PlayerAdded
race, `EconomyService.ensureLeaderstats` returned that folder without
creating Coins/Gems/Level/XP inside it, so every grant hit `getStat() == nil`
and returned silently. **Fix:** `ensureLeaderstats` now fills missing stats
into any existing folder, `getStat`/`saveRecord` search every `leaderstats`
folder, and DataHandler reuses an existing folder instead of duplicating it
(that last change lives only in the place, not this repo).

Reported: giving Gems via the Economy page's Give button doesn't appear
to do anything, with no error shown.

**Investigated, no defect found yet:** `givepremium`'s command
definition, permission node (`economy.currency.give`, same as
`givecurrency`), and `EconomyService.AddGems` all match the working
Coins/XP code paths exactly — same `addToStat` helper, same target-loop
shape, same result-message format. Nothing gems-specific stood out in
static review. Needs a live repro with the Studio output open (does
`CommandResultRemote` fire at all? does the leaderstat `Gems` value
actually change server-side even without a toast?) to pin down whether
this is a UI-side silent swallow or a backend no-op.

## 5. Command Palette doesn't show suggestions by default, and clears them after running a command

**Status:** Partially fixed in the Phase 7G drop; one part still open.

Reported: Admins have to click "Search Commands" to get the palette to
appear at all, and after a command runs (success or fail) the palette
no longer shows related commands.

**Fixed:** `renderSuggestions("")` (empty query) now renders a default
view — Favorites first, then recent History, in the same row style as
search results — instead of returning with nothing. This covers both
complaints that had a real root cause: the post-execution blank-out
(`executeCurrent()` clears the input, which re-triggers this same
default view now) and the palette showing nothing useful right after
`Open()` (which now explicitly calls `renderSuggestions("")` rather than
relying on a Text-changed signal that won't fire if the text was already
empty from before closing).

**Still open — Ctrl+Shift+P feeling unresponsive:** unchanged from the
original investigation — the global toggle handler looks structurally
correct in the source (doesn't check `gameProcessed`, so it should fire
regardless of textbox focus). Still needs a live repro to know whether
the shortcut is truly dead, silently swallowed by something else (e.g.
this game's separate AdminPanelClient, which the README notes already
binds plain "P" for its own UI — worth checking whether it's also
intercepting the Ctrl+Shift combination), or whether this complaint was
actually about the palette showing nothing useful on open (now fixed
above, so worth re-testing before digging further into the shortcut
itself).

**Delivered in 7G, not just this bug fix — Favorites + History:** a
star toggle (☆/⭐) on every suggestion row pins/unpins a command as a
Favorite (session-only, no persistence — same as the rest of Sentinel's
client-side prefs so far); the default view surfaces Favorites and
recent History directly instead of requiring the ↑/↓ key cycling that
was the only way to reach history before.

**Still open — full inline syntax/ghost-text suggestions:** the ask was
"same work as the Roblox AI code assisting" — suggesting args inline as
you type past the command name, not just showing `Usage` in the preview
line for the top match (which already existed and still works). That's
a bigger feature (parsing partial args against the command's Usage
pattern and rendering ghost text inline in the input box) — not done in
this drop, still open for a future pass.
