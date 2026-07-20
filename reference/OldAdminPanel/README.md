# Old Admin Panel (V4.3) — extracted reference

This directory holds text extracted from `AdminPanelBetaV4_3Setup.rbxm`
(the user's own, previously-built Admin Panel — ownership confirmed, see
the README embedded in that model crediting GabrielDev/Cooki6310/NeoOrange7
plus a Discord contact matching the user's own handle).

`extracted_source_fragments.txt` contains decompressed, readable script
fragments pulled out of the binary model (LZ4 chunks decoded), useful as a
reference when building the Phase 10 "Player Controls" category later.

Notable reusable pieces identified:
- Fly system (BodyGyro/BodyVelocity-based flight, start/stop functions)
- A `commandHandlers` map covering ~80 short player-effect functions:
  movement (fling, ragdoll, jump), visual effects (explode, forcefield,
  fire, smoke, sparkles, glow), appearance (invisible, neon/gold/silver/
  diamond/metal skins, bighead), and character tricks (r6/r15 convert,
  clone, zombify, stun).
- A toast-style notification system and a `Config.THEMES` color table —
  a reasonable seed for Phase 7's notification center.

None of this has been ported yet — it's saved here for Phase 10, per the
user's decision to defer it. When porting: wrap each effect as its own
CommandRegistry.Register() entry (permission node, logging, undo data)
rather than reusing the old flat handler-map pattern directly.
