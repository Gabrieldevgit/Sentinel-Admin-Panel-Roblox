# Phase 7 Known Issues

Living list of deferred bugs found during Phase 7 (UI/UX) development.
Logged here rather than fixed piecemeal, so the end-of-phase fix pass can
address all of them at once.

## 1. Resize only resizes the outer window frame, not its contents

**Status:** Open, deferred to end-of-Phase-7 fix pass.

Dashboard cards, Quick Action cards, and other page content use hardcoded
pixel widths rather than scale-relative/reflowing layouts. Narrowing the
Shell window clips or overflows content instead of reflowing it.

**Fix approach (planned):** pass across every page at once (Dashboard,
Players, Moderation, Server, Economy, Developer, Notifications)
converting hardcoded pixel widths to `UDim2` scale-relative sizing plus
`UIListLayout`/`UIGridLayout` wrapping where needed, rather than fixing
one page at a time.

## 2. Drag and resize are both erratic

**Status:** Open, deferred to end-of-Phase-7 fix pass.

**Root cause found:** `Shell.lua`'s drag/resize handler
(`UserInputService.InputChanged`) uses `UserInputService:GetMouseDelta()`
to compute movement — this is the exact anti-pattern already flagged in
the project's own learnings (`GetMouseDelta()` is meant for camera-look
under `MouseBehavior = LockCenter`, not general UI drag/resize, and is
unreliable here). Both bugs share this one root cause; fixing it once in
the shared `InputChanged` handler fixes both.

**Fix approach (planned):** replace `GetMouseDelta()` with absolute
`input.Position` delta-tracking against a saved start position (captured
in the `MouseButton1Down` handlers for `dragHandle`/`resizeHandle`),
matching the pattern the project already uses elsewhere.

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

**Status:** Open, needs live repro — deferred to end-of-Phase-7 fix pass.

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

**Status:** Open, deferred to end-of-Phase-7 fix pass.

Reported: Admins have to click "Search Commands" to get the palette to
appear at all, and after a command runs (success or fail) the palette
no longer shows related commands.

**Root cause found (post-execution clearing):** `executeCurrent()` sets
`inputBox.Text = ""` right after firing the command. That text change
triggers `renderSuggestions("")`, which returns early on an empty query
without rendering anything — so the suggestion list goes blank the
instant a command runs. Confirmed in `CommandPalette.lua`.

**Not yet root-caused (Ctrl+Shift+P feels unresponsive):** the global
toggle handler looks structurally correct in the current source — it
doesn't check `gameProcessed`, so it should still fire even while a
TextBox elsewhere has focus. Couldn't find a defect via static review;
needs a live repro to know whether the shortcut is truly dead, silently
swallowed by something else (e.g. the client capturing Ctrl+Shift+P
before Roblox sees it), or whether this is really about wanting the
palette to already be showing *something* on open rather than a blank
box (see the related ask below).

**New ask, not a bug — inline command/syntax suggestions while typing:**
requested "same work as the Roblox AI code assisting" — i.e. as the
admin types, suggest the matching command name and its argument syntax
inline (like `givecurrency target:amount`), not just a list of full
command names. This is a real feature addition to `CommandPalette.lua`'s
`renderSuggestions`/`fuzzyScore` path, not a one-line fix — natural fit
for 7G (Command History + Favorites) since it's the same file/area.
Scoping for the fix pass: render top commands by default when the query
is empty rather than nothing, and extend the suggestion row to show
`Usage` as ghost/inline text reflecting the args typed so far.

**Fix approach (planned):** after firing the command in
`executeCurrent()`, either keep the last query's suggestions visible
until the next keystroke, or re-render suggestions for a default/
recent/top-commands view instead of an empty one — same underlying fix
covers both showing something useful on Open() and not going blank
after execution.
