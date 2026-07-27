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
