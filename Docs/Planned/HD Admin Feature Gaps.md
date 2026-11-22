# HD Admin feature gaps (planned)

Source: the HD Admin copy in the testing place (`Workspace.HD Admin`,
`Core.MainModule.Value.Modules.Internal.Commands`, 174 commands in 8 packs),
compared with Sentinel's commands on 2026-11-22. Features only: never copy
HD Admin's code or design.

## Excluded

- **Every emote command** (Aura, Helicopter, Plane, Tank, Car, RatDance, ...
  and the Emotes menu): they play HD Admin's own uploaded animations, not
  Roblox ones. Rule from the user: ignore anything that needs custom
  animations.
- **Crash** (freezes a player's screen): harmful, not moderation.
- **Control** (take over a player's character): too invasive.
- **Insert** (catalogue model into the map): security risk; at most an
  Owner-only developer command later.
- **Already in Sentinel:** Clone, Kick, Ban, Mute, Jail, Fling, Fly / NoClip,
  View, Bring / GoTo, Follow, Heal, God, Explode, ForceField, Respawn,
  Fire / Smoke / Sparkles, Spin, Sit / Jump, BigHead / SmallHead,
  Hint / Message, Shutdown, Building tools, Give.
- **Too small to matter:** Fly2 / Noclip2, Farland, LaserEyes, Fast / Slow
  (`;speed`), Disasters (empty in HD Admin).

## Worth adding

### Chat and player identity (no W row yet)
- ChatTag / ChatTagColor: tag before a player's name in chat; could follow
  Sentinel ranks automatically.
- ChatName / ChatNameColor: change the name shown in chat.
- SystemMessage: a chat line styled like a system message.
- Name / HideName / Title: change or hide the overhead name, add a title.

### Map and world (no W row yet)
- SaveMap / LoadMap / ClearMap: map snapshot + restore (`;clear` only
  removes debris).
- ClearEffects / ClearAll: stop every server-wide effect at once.
- LockMap / LockCharacter: stop building tools editing the map / a
  player's parts (pairs with `;btools`).
- Music / Pitch / Volume: play a sound for everyone by id.
- FogColor.

### Teams and stats
- CreateTeam / RemoveTeam / Team: also closes the W15 team leftover.
- CreateStat / RemoveStat / ChangeStat / AddStat / SubtractStat /
  ResetStats: any leaderstat, not only Sentinel currencies (W28).

### Moderation and server
- ServerBan / UnServerBan: ban from this server only.
- Punish: hide a player's character until undone.
- LockServer by rank: kick everyone below a rank and block their joins.
- Rejoin: send a player back into the same server.
- Place / ForcePlace: send a player to another place in the game (ask
  first or force).
- Reset: remove every effect on a player in one command.
- Tasks page: every effect running on each player (pairs with Reset).

### Character (W30)
- Size, Height, Width, Depth, Fat, Thin, Squash, Dwarf, BodyTypeScale.
- Paint, Transparency, Reflect.
- Shirt / Pants / Accessory / ClearHats (blueprint "outfit changes").
- Char: become another user's avatar.
- R6 / R15.

### Tools (W29)
- HandTo (give the tool you hold), GiveAll, ClearBackpack, Sword, Gear
  (catalogue gear by id).

### Player screen effects
- FieldOfView, Blur, HideGuis, NightVision, Ice (freeze in a block of ice).

### Messages and monetisation
- Alert / ServerAlert (notice with a sound), ServerMessage (sent "from the
  server"), CountdownNotice (countdown in a corner notice).
- Sell commands: prompt a game pass, catalogue item, bundle or developer
  product purchase.
- Vote / GlobalVote: already planned as W23 Polls (server + all servers).

## Where it goes

Character -> W30, stats -> W28, tools -> W29, votes -> W23. Chat tags, map
snapshots, teams, music and the server-only ban have no row yet: a small
extra batch next to W23 is the suggestion (ask the user before scheduling).
