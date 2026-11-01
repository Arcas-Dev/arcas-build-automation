# Team spawns: players starting in the enemy base (2026-11-01, analysis only, PARKED)

> **Status: documented, not being fixed now (Dan, 2026-11-01).** Nothing changed in code or maps.

## Symptom (Dan)

At the start of almost every TDM or Control Point match, about 6 players of one team spawn together in one base, and 1 or 2 players of the **other** team spawn in that same base. They get killed straight away, so the match is chaotic from the first second. This happens to humans and bots alike.

## Verified facts (3 agents + direct code read)

1. **Every mode uses the team filter, but the maps give it nothing to filter.**
   - TDM, Control Point, Elimination (Brawl) and BombScenario (Eggsplosion) all add `B_BASTeamSpawningRules`.
   - Its chain is `UTDM_PlayerSpawningManagmentComponent` → `UBASPlayerSpawningManagerComponent` → Lyra. No Blueprint overrides it, and `OnChoosePlayerStart` is not a UFUNCTION.
   - The live maps (`mp_BasBeachClub`, `mp_BlackMarket`, `mp_VillagePlaza` in BASMaps) contain **only plain `ALyraPlayerStart`**: 27, 20 and 23 of them. They have **zero `ATeamPlayerStart`** and no `PlayerStart.DontSpawn` tags.
   - `BASPlayerSpawningManagerComponent.cpp:29-31` only removes starts that implement the team interface, so it removes nothing. Both teams pick from every start on the map.
   - `ATeamPlayerStart` + `B_TeamPlayerStart_Elite/_Renegade` were added in `abb3a7301` (2025-05-16) but only ever placed in `BAS_ShooterGame_Gym`.
2. **The side is decided by Lyra's stock TDM picker** (`ShooterCore/.../TDM_PlayerSpawningManagmentComponent.cpp:25-91`):
   - **It only looks at enemies that currently have a pawn.** If none do, it returns null, and the base code falls back to `GetFirstRandomUnoccupiedPlayerStart` over **all** starts on the map (`LyraPlayerSpawningManagerComponent.cpp:111-114`). The first spawns of a match are therefore random across the whole map.
   - **It measures the wrong distance.** It takes the maximum over every (enemy pawn, start) pair, i.e. the start furthest from *some* enemy, not the start whose *nearest* enemy is furthest. Once one enemy sits in each base, a start right next to an enemy can win.
   - **Overflow.** Claimed starts are only a fallback. A start stays claimed until its pawn walks off it (`ALyraPlayerStart::CheckUnclaimed`). When a base's starts are all taken, the next player goes wherever is "far from some enemy", which can be the enemy base. `mp_BlackMarket`'s east cluster has exactly 8 starts for an 8-player team.
3. **The team is always set before a spawn**: warmup join, warmup-end bots, queue swap, Logout replacement bot. The controller reads it from the PlayerState on the server. Nothing teleports pawns after spawn. Ruled out as a cause.
4. **The old F1 double spawn (`04774198a`, now fixed) made it worse.** The destroyed first bot batch left starts claimed and blocked, so the second batch ran out of own-side starts sooner.

## Why "6 + 1-2, almost every time"

This is inferred and fits the facts above. At warmup end, everyone respawns within a frame or two, and bots are spawned in a burst in `ResetLevel`.
1. The first pawn(s) have no enemy pawn to measure from, so they land on a random start, about 50/50 either base.
2. Everyone after that is placed relative to the pawns that already exist.
3. Because of the max-of-pairs rule, one misplaced seed pulls more players after it.
4. Each base fills up, and overflow spills to the other side.

The result is one base holding most of a team plus the one or two unlucky early or overflow spawns from the other team.

**Possible confounder:** skins follow the champion's faction, not the match team (`CharacterMeshPickerComponent.cpp:92`, `SkinTeamFunctionLibrary.cpp:11-17`). A teammate on a Renegade champion can look like an enemy. Dan's description (they get killed) points to real enemies, though.

## Fix options (when picked up)

**A. Maps, Editor only (the proper fix).** Replace the plain starts in the three maps with `B_TeamPlayerStart_Elite` / `_Renegade`, one team per base. The existing C++ filter then confines each player to their own base, including the random first spawn. Checks for Marco:
- the `TeamID` on both Blueprints must match the team ids the game actually assigns (not readable off the asset; verify in the Editor);
- **10+ starts per base** for 8v8 (BlackMarket east has 8);
- `mp_VillagePlaza` has no clean two-base layout, and its 2 middle starts (#5 at (-1395,-5590), #16 at (1926,-3100)) should be assigned to a team or deleted;
- confirm Brawl/Eggsplosion don't swap sides between rounds (fixed team starts would break that).

**Risk of A:** if a player ever had no team when spawning, every team start would be filtered out and they would spawn at the world origin. This was verified not to happen on current paths.

**B. C++ only (no map work, ~10 lines in the TDM picker).**
- Rank each start by its distance to the **nearest** enemy pawn.
- When no enemy pawn exists yet, seed deterministically: pick the start furthest from any **teammate** of the other team, or fixed per team.

Fixes the cascade, but a "base" stays implicit, so A is still better. B on top of A matters little, because the picker then only chooses within the player's own base.

## Not checked
- The `ShooterMaps/*` copies (`JungleMap_New`, `ArcasVillage`, OFPA). Only the BASMaps used by the current playlists were read.
- The key→map pairing inside `DA_MapsPerGameMode`. The mode→map list was taken from the playlist names.
- The exact human vs bot spawn order at warmup end. Humans probably respawn a frame later through `GA_AutoRespawn` → `RequestPlayerRestartNextFrame` (inferred from asset strings).

Downloaded maps/assets and the start-position decoder: session scratchpad `spawnbug/`, `spawnmaps/`, `scripts/starts.py` (temporary).
