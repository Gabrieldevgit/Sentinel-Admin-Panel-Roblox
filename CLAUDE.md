# Sentinel — agent instructions

Before doing anything else in a session, read [HANDOFF.md](HANDOFF.md). It
holds the project's current state, setup, architecture and lessons learned.

Two standing rules from that file (see its §0 for details):

1. **Every 3–5 user messages, update `HANDOFF.md` as part of your turn**
   (current state, session log entry, open issues, "last updated" line) to
   preserve the context window. Do a final update before a session ends.
2. **When a feature from
   `Docs/Planned/Sentinel Admin Panel Complete Feature Blueprint.md` is
   implemented and verified in Studio, add ✅ to the start of its bullet.**
   Don't reword, reorder or remove the user's items.

Commit only when the user asks (they commit to `main`).
