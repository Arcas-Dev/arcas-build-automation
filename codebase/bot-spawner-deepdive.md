# Bot Spawner — Deep Dive (2026-11-01)

Read-only code research on `deploy/steam-testing` @ `0c3068378` (pulled 2026-11-01; the 4 commits since `67dcc7eab` touch no C++ and no bot assets). Blueprint structure read off the real `.uasset`s via the LFS batch API (`strings`), so class references are verified; **numeric defaults (`NumBotsToCreate`, `RandomBotNames`) were not read** — they need the VM commandlet.

Nothing was changed. Diagram (hierarchy, config layers, runtime flow): `arcas-champions/docs/bot-spawning-system.drawio.svg`.

---

## 1. The three layers

| Layer | Class | File | Who wrote it |
|---|---|---|---|
| Lyra base | `ULyraBotCreationComponent` (`UGameStateComponent`, Abstract) | `Source/LyraGame/GameModes/LyraBotCreationComponent.{h,cpp}` | Epic, modified by Bevium |
| Arcas spawner | `UArcasBotCreationComponent : ULyraBotCreationComponent` | `Source/LyraGame/GameModes/ArcasBotCreationComponent.{h,cpp}` | Bevium (Darakuu, Driver2579, manuelgerardzuccaro), split out 2025-04-14 (`4766e1a76`) |
| Single-bot placer | `ACustomBotSpawnPoint : ALyraPlayerStart` | `Plugins/GameFeatures/BASShooterCore/.../Actors/PlayerStarts/CustomBotSpawnPoint.{h,cpp}` | Bevium (Driver2579, `3a6c73354`, 2025-02-19), for tutorials/single-player |

Plus the hooks that drive it, all in `ABASGameMode` (`Source/LyraGame/GameModes/BASGameMode.cpp`) and one in `UScoringGameStateComponentBase`.

Controllers: `ALyraPlayerBotController` → `ABASPlayerBotController` (adds `UPlayerInfoComponent`, so bots carry a loadout like players) → `AArcasBotController` (BASShooterCore plugin, 922 lines: behaviour tree, perception, state/context tags, patrol, blind handling, `UArcasAILoadoutComponent`) → `AArcasBotControllerRaider`.

### What Bevium changed in the Lyra base
- **Lyra's auto-spawn is disabled.** `ULyraBotCreationComponent::OnExperienceLoaded` (`LyraBotCreationComponent.cpp:35-44`) has `ServerCreateBots()` commented out. Nothing spawns on experience load any more; spawning is driven by the GameMode (§3).
- `SpawnOneBot` gained `(ControllerClass, StartSpot, BotName, TeamId)` parameters (`:145`), replacing the old `SpawnOneBotWithName` hack (`d65b7d2eb`). It sets the team on the **PlayerState** before `RestartPlayer`, and can restart at a specific `PlayerStart`.
- `RemoveOneBot` can target a specific controller. Both are exposed as `Cheat_AddBot` / `Cheat_RemoveBot` — and **`Cheat_RemoveBot` is used by real gameplay code** (the bot↔player swap, §4), not just cheats.
- Fallback names are `"Tinplate 260..360"` (random, can repeat) once `RandomBotNames` runs out.

---

## 2. Which experience uses which spawner (verified off the assets)

| Experience | Spawner BP | Parent | Controller class |
|---|---|---|---|
| `B_BASShooterGame_TDM` | `B_ShooterBotSpawner` | Arcas | `BP_ArcasBotController_Raider` |
| `B_BASShooterGame_Elimination` (Brawl) | `B_ShooterBotSpawner_Elimination` | Arcas | `BP_ArcasBotController_Raider` |
| `B_BASShooterGame_BombScenario` (Eggsplosion) | `B_ShooterBotSpawner_Elimination` (shared) | Arcas | `BP_ArcasBotController_Raider` |
| `B_BASShooterGame_ControlPoints` | `B_ShooterBotSpawner_ControlPoint` | Arcas | `BP_ArcasBotController_Raider` |
| `B_BASShooterGame_ControlPoints_Prologue` | `B_ShooterBotSpawner_ControlPoint_Prologue` | Arcas | `BP_ArcasBotController_Raider` |
| `B_LobbyRoom_Experience` | `B_ShooterBotSpawner_LobbyRoom` | Arcas | `BP_ArcasBotController_Raider` |
| `B_EliteTutorial_Experience`, `B_RenegadeTutorial_Experience`, `B_ArcasAITesting_Experience` | `B_ArcasBotSpawner` | Arcas | `BP_ArcasBotController_NewRaider` |
| `B_BASBasicShooterTest` | none | — | — |
| *(unused leftovers)* `B_ShooterBotSpawner_ControlPointBiG` | — | Arcas | `B_AI_Controller_BASShooter` |
| *(Lyra sample)* `B_ShooterBotSpawnerBIG` | — | **Lyra** | `B_AI_Controller_LyraShooter` |

Only Elimination and BombScenario set `bStartPlayersAsSpectatorsAfterWarmUp`.

Each spawner BP overrides only `BotControllerClass` and `NumBotsToCreate` (plus probably `RandomBotNames`). All the logic is C++.

---

## 3. Lifecycle: when bots are created

```
Experience loaded ──► ABASGameMode::OnExperienceLoaded (BASGameMode.cpp:234)
                       └─ registers WhenPhaseEnds(ShooterGame.GamePhase.Warmup) callback
Warmup ends ──┬──► callback → ABCC->SpawnBots()                         (BASGameMode.cpp:261)
              │      + sets bStartPlayersAsSpectators if bots on && experience flag
              └──► UScoringGameStateComponentBase::OnWarmupGamePhaseEnded (Scoring…Base.cpp:179)
                     → GameMode->ResetLevel() → ABASGameMode::ResetLevel → ABCC->SpawnBots()  (:211)
Round ends (Brawl/rounds) ──► OnRoundHasEndedGamePhaseEnded (:752)
                     → ABASGameMode::ResetRoundLevel → ABCC->RespawnBots()  (:227)
```

- `SpawnBots` → `ServerCreateBots`: **destroys every existing bot** (`ClearSpawnedBots`), refills names, computes `EffectiveBotCount`, spawns that many.
- `RespawnBots` → `ServerRespawnBots`: keeps the bots and their PlayerStates (scores survive between rounds, fix `07cd1a756`), restarts each one, then `RemoveExtraBots` / `SpawnMissingBots` to the new count.
- **Experiences without a warmup phase never get bots from the component.** Tutorials get theirs from `ACustomBotSpawnPoint`s placed in the map. Whether the lobby room's spawner ever fires is open (§7).

### How many bots: `CalculateEffectiveBotCount` (`ArcasBotCreationComponent.cpp:104`)

The behaviour depends on the build. The macros live in `Plugins/BlockApeScissors/.../ExecContextMacro.h`:
`D_SERVER` = dedicated server, `L_SERVER` = listen server (game build), `*_ED` = the editor variant.

| | Dedicated server (Edgegap) | Listen server / PIE |
|---|---|---|
| `MaxPlayers` | `?MaxPlayerCount=` from the travel URL, otherwise -1 | `CommonSessionSubsystem::GetSessionMaxPlayers()`, -1 → `NumBotsToCreate` |
| `BotsOption` URL flag | **ignored: bots are always on** (the check is compiled under `L_SERVER` only) | respected (`PlayMatchMenu.cpp:749`, 0 = off) |
| Editor override | — | `LyraDeveloperSettings.bOverrideBotCount` / `OverrideNumPlayerBotsToSpawn` (`L_SERVER_ED` only) |
| Result | `MaxPlayerCount − GetNumPlayers()` | the same, or the override |

On Edgegap, the server boots into `mp_LobbyRoom` (`ServerDefaultMap`). When the matchmaker injects a mode, `TravelToRandomMap` (`BASGameMode.cpp:787`) `ServerTravel`s to `ULyraUserFacingExperienceDefinition::GetServerTravelURL()`, which always appends `?MaxPlayerCount=N`. **So in a real match, bots fill the server up to `MaxPlayerCount` at the end of warmup.** This applies to ranked (Eggsplosion 4v4) as well as casual: nothing in the spawner distinguishes the two.

`NumBotsToCreate` only matters on the dedicated server when there is no `MaxPlayerCount` in the URL, which in practice means the boot lobby.

---

## 4. Mid-match: players joining and leaving

**Player leaves** (`ABASGameMode::Logout`, `:594-617`): if `bSpawnBotWhenPlayerLeaves` (default true) and bots are enabled, `SpawnOneBot(TeamId)` puts a bot on the leaver's team. Separately, `UScoringGameStateComponentBase::OnGameModeLogout` counts a **suicide score** against the leaver under the same condition.

**Player joins during `Playing`** (`HandleStartingNewPlayer_Implementation`, `:352-385`): if bots are enabled, the player is **queued** in `WaitingPlayersQueue` and not spawned.

**A bot dies** (`RequestPlayerRestartNextFrame`, `:470-525`): with an empty queue the bot respawns next tick. With a queued player:
1. that bot is destroyed (`Cheat_RemoveBot(BotController)`),
2. the player is dequeued and moved by `ChangeTeamForActor` to **the dead bot's team**,
3. the player is restarted next tick.

This is the "kick-fill-bot" feature from Sept/Oct 2023 (mHead).

---

## 5. Findings

Ranked by impact. None has been reproduced. They come from reading the code, so each says what would confirm it.

### F1. Bots are spawned twice at the end of warmup — ✅ CONFIRMED in code, FIXED `04774198a` (2026-11-01, not yet compiled)

**Mechanism (verified by a 4-agent review: code path + git history, UE 5.5 engine source, adversarial fix review, all 19 experience assets).** `ULyraGamePhaseSubsystem::OnEndPhase` (`LyraGamePhaseSubsystem.cpp:207-233`) runs High observers → the phase's own ended callback → Low observers. At warmup end:
1. High observer = `ABASGameMode` lambda (`BASGameMode.cpp:261`) → `SpawnBots()` → batch 1 (N bots).
2. Ended callback = `UScoringGameStateComponentBase::OnWarmupGamePhaseEnded` → `ResetLevel()` → `ABASGameMode::ResetLevel` → `Super::ResetLevel()` then `SpawnBots()` → `ClearSpawnedBots()` destroys batch 1 → batch 2.

No other cause: Lyra's own auto-spawn is commented out, `UArcasBotCreationComponent::Reset()` has no caller, bot `Logout` never spawns a replacement, rounds use `ResetRoundLevel` → `RespawnBots` (never clears).

**History (why it came back).** `7fba97b9f` (Driver2579, Nov 2024, "every new round there become twice more bots") had fixed it by moving the spawn into `ResetLevel` and commenting out the observer's spawn. The merge `5530af494` (Dec 2024, beta2-matchmaking → 5.5) brought the active line back; `e59843aa5` (Feb 2025, "players' positions don't restart on warmup end") re-added `ResetLevel` at warmup end and re-armed the second spawn.

**Real cost (engine source read).** Corrected from the first version of this section: batch 1 never dies. `Super::ResetLevel` → `ALyraCharacter::Reset` → `UninitAndDestroy` unpossesses the pawns first, so `RemoveOneBot` finds no pawn and skips `DamageSelfDestruct`. No kill feed, no score (listeners register only in `HandleRoundHasStarted`), no MatchInfo/XP (bots never `PostLogin`), and AI-controller `Logout` broadcasts nothing. What it does cost: N full bot builds + destroys in one frame on the 1.5 vCPU server, ~N×players reliable `BroadcastOnNewPlayerJoinedEvent` multicasts, hidden pawns replicated for a tick, PlayerIds shifted by N.

**Fix as built (`04774198a`, `BASGameMode.h/.cpp`, 4 lines):** the observer is registered `ECallbackPriority::Low` (runs **after** `ResetLevel`) and only calls `SpawnBots()` if `!bBotsSpawnedOnResetLevel` (new member, set in `ResetLevel`). So:
- normal path: one spawn (`ResetLevel`'s, the batch that already survived before), spectator flag computed afterwards from the same `EffectiveBotCount` → same value;
- **instant-warmup path** (warmup ends inside its own activation → `StartPhase` calls `OnWarmupGamePhaseEnded(nullptr)` → no `ResetLevel`): the observer still spawns once, as before. Without this guard such a mode would get **no bots**. A flag, not "bot list empty", because `CustomBotSpawnPoint` bots sit in the same list.

**Checked unchanged:** `bStartPlayersAsSpectators` is only read by the engine on login (`HandleStartingNewPlayer`), never inside `OnEndPhase`; `EffectiveBotCount` readers (`AreBotsEnabled`, `ShouldSpawnBotWhenPlayerLeaves`) see the same value; no other C++ warmup-end observer; warmup is only ever started by the scoring component (all 19 experiences read), and every bot-filled experience ends warmup through it; both game modes (`B_BASGameMode`, `B_TutorialGameMode` → `ATutorialGameMode`) keep `ABASGameMode::ResetLevel`. Lobby / Practice Grounds have no scoring component → no warmup → neither path fires, before or after (closes §7 Q1).

**⚠️ Intended visible change — round 1 count.** `HandleRoundHasStarted` counts `APlayingCharacter`s with `GetAllActorsOfClass`; batch-1 pawns (destroyed next tick) were still counted, so round 1 saw ~humans + 2×bots, now humans + bots. That count keys `TargetTeamScores` (TDM, Control) and `RoundDurations` (TDM, Elimination); C++ defaults switch at 6. Edgegap fills to `MaxPlayerCount`, so live matches only change bracket if a scoring BP has a key between the match size and ~2× it. **BP values read 2026-11-01 (Marco's screenshots): every map uses only keys 0 and 6** — TDM `RoundDurations` {0:720, 6:1200} + `TargetTeamScores` {0:30, 6:50}; Control Point `TargetTeamScores` {0:750, 6:1000}; Elimination `RoundDurations` {0:300, 6:600}; BombScenario `RoundDurations` {0:180}, a single row, so the count never matters there. Any match with ≥ 6 characters stays in the same row, so **no player-visible change on Edgegap** (bots fill to `MaxPlayerCount` ≥ 8); only a sub-6-character match with bots (e.g. a small PIE test) can switch row. Note rounds 2+ also count the previous round's not-yet-destroyed pawns, so that count is approximate anyway.

**Test (Marco):** one `EffectiveBotCount before adjustments` block at warmup end (two before); bot count = MaxPlayers − humans in TDM / Control / Brawl / Eggsplosion; Brawl/Eggsplosion late joiner still starts spectating; the three tutorials still get their bots; round-1 timer + target score look right.

Side findings from the asset pass: `B_ShooterGame_TDMBIG` uses the Lyra base spawner (`B_ShooterBotSpawnerBIG`) so `UArcasBotCreationComponent` is never found → never gets bots; `DA_ArcasJungle_TDM` and `L_Expanse` reference a `B_ShooterGame_TDM` asset that doesn't exist in git.

### F2. A reconnecting player can switch teams (likely, gameplay-visible)
§4 step 2 moves the dequeued player to the team of **whichever bot dies first**, not to the team they left. Because `Logout` already put a replacement bot on their old team, a reconnect can land them on the other side. **Confirm**: 2 humans vs bots, one leaves and rejoins, and a bot on the other team dies first.

### F3. Latent out-of-range read in `RemoveExtraBots` (low likelihood, server crash)
`ArcasBotCreationComponent.cpp:300`: `for (i = Num-1; SpawnedBotList.Num() > EffectiveCount; --i)`. The loop condition never checks `i >= 0`. A bot is removed only if it is on the "team with most players". If that team has **no** bots, nothing is removed, `i` goes to -1, and `SpawnedBotList[-1]` hits the TArray range check, which crashes the server in a Development build. It needs more humans + bots than `MaxPlayerCount` at a round reset (queued joiners) with every bot on the smaller team. That's rare without backfill, but possible with reconnects in Brawl. **Fix**: add `i >= 0` to the loop condition, and fall back to removing from any team on a second pass.

### F4. The tie-break comment is wrong
In the same function, the comment says ties remove from the bot's own team. The code (`MaximumPlayersInTeam` starts at 0, compared with a strict `>`) actually picks the **first team in `TeamIds` order** that has the maximum. When teams are tied, bots are only removed from that one team. This is harmless on its own, but it is the condition that feeds F3.

### F5. Bot accounting only half-tracks swaps
`EffectiveBotCount` is computed at warmup end or round reset only. Bots removed by the swap in §4 and bots added in `Logout` don't update it. `AreBotsEnabled()` (`EffectiveBotCount > 0`) therefore stays true even if every bot has been swapped out. A player who then joins mid-match is queued with no bot left to die for them, so they never spawn. The code comment at `BASGameMode.cpp:263` assumes "can't join when match is full", but that guard doesn't exist here. **Confirm**: more mid-match joins than bots.

### F6. Ranked matches are filled with bots
This follows from §3: the dedicated server always fills to `MaxPlayerCount`, and `BotsOption` is ignored there. It's worth an explicit decision, because bots in ranked matches affect MMR and the SkillStaking/prediction-market story. **Check**: how `SendMatchResults` treats bot kills and bot-filled teams.

### Minor
- `CustomBotSpawnPoint` bots go into the same `SpawnedBotList`, so a later `SpawnBots()` (a level reset) would destroy them. Fine in tutorials today, but a trap if spawn points are used in a mode with warmup.
- On a dedicated server, bot `AimAccuracy` is the BP or class default (0.33). The "AI Aim Accuracy" game setting only binds through a local player (`LyraPlayerBotController.cpp` `PostInitializeComponents`), so it only affects listen-server/PIE bots, and there it uses the host's setting.
- `UArcasBotCreationComponent::Reset()` (calls `SpawnBots`) is private and has no caller found.
- `LyraBotCreationComponent.h:2` itself says "Yet another class to cleanup and restore to original Lyra state."

---

## 6. Where to change what

| Want to… | Change |
|---|---|
| bot count per mode | the mode's `MaxPlayerCount` (`DA_*` GameModeDataAsset / user-facing experience) on Edgegap; `NumBotsToCreate` in the spawner BP for listen/lobby |
| turn bots off on Edgegap | currently impossible without C++: move the `BotsOption` read out of the `L_SERVER` guard in `IsBotsOptionOn()`, or add a ranked check |
| bot AI / loadout | the controller BP (`BP_ArcasBotController_*`), `UArcasAILoadoutComponent` (`bRandomizeWeapons/Totems/Stats`, `CustomLoadout`) |
| scripted single bots | place `B_CustomBotSpawnPoint` (team, mesh, colour, GEs on spawn; `SpawnBot()` callable from BP) |

## 7. Open
- ~~Does the lobby room have a warmup phase?~~ **Answered 2026-11-01: no.** `B_LobbyRoom_Experience` has no scoring component, so `B_ShooterBotSpawner_LobbyRoom` never spawns anything (mp_LobbyRoom + L_PracticesGrounds; Practice Grounds bots come from 5 `B_CustomBotSpawnPoint`s).
- Actual `NumBotsToCreate` and `RandomBotNames` per spawner BP (VM commandlet).
- `MaxPlayerCount` per Edgegap mode, which is the real bot count driver.

---

## 8. Study: "respawn at this point" on `ACustomBotSpawnPoint` (2026-11-01, nothing built)

**Today:** with `GE_DisableRespawn` in the spawn point's GE list, the bot never respawns. Take it out and the bot respawns, but somewhere else.

### 8.1 Why it respawns elsewhere (traced)

1. **First spawn bypasses selection.** `ACustomBotSpawnPoint::OnSoftClassesLoaded` → `SpawnOneBot(class, this, name)` → `GameMode->RestartPlayerAtPlayerStart(controller, this)` (`LyraBotCreationComponent.cpp:181`). The point is used directly.
2. **Respawn goes through generic selection.** Death → `GA_AutoRespawn` (BP; parent `UBASGameplayAbilityWithReset`; blocked by `Ability.Behavior.BlockRespawn`) → `GameMode.RequestPlayerRestartNextFrame` (BlueprintCallable; Lyra pattern, the exact node is not readable via `strings`) → `ABASGameMode::RequestPlayerRestartNextFrame` → (empty queue) `ALyraPlayerBotController::ServerRestartController` → `GameMode->RestartPlayer` → `ChoosePlayerStart`.
3. **Lyra ignores the controller's own start spot.** `ALyraGameMode::ShouldSpawnAtStartSpot` always returns `false` (`LyraGameMode.cpp:393`), so every restart asks the spawning manager.
4. **The spawning manager excludes the point and picks "furthest from enemies".** Every experience uses `B_BASTeamSpawningRules` → `UTDM_PlayerSpawningManagmentComponent` (ShooterCore) → `UBASPlayerSpawningManagerComponent` → `ULyraPlayerSpawningManagerComponent`:
   - the BAS layer removes every start tagged `PlayerStart.DontSpawn`, **which `ACustomBotSpawnPoint` adds to itself**, plus starts belonging to another team;
   - the TDM layer then returns the remaining start **furthest from any enemy pawn**. It calls `Super::OnChoosePlayerStart` but **discards its return value**.

   So the point can't be chosen even in principle, and the bot lands at the furthest regular PlayerStart.

### 8.2 Proposed approach

| # | Change | Where | Why there |
|---|---|---|---|
| 1 | `bRespawnAtThisPoint` (bool, `Bot\|Respawn`) | `ACustomBotSpawnPoint` | Marco ticks it per placed point |
| 2 | `TWeakObjectPtr<APlayerStart> RespawnAnchor` + getter/setter | `ABASPlayerBotController` (LyraGame) | The game mode lives in LyraGame and **cannot see plugin types**, so the anchor must be a LyraGame/engine type. Weak, so a destroyed point falls back cleanly. Set by the spawn point right after `SpawnOneBot` when the option is on |
| 3 | Override `ChoosePlayerStart_Implementation`: bot with a valid anchor → return the anchor (+ `TryClaim`), otherwise `Super` | `ABASGameMode` | **One choke point** that covers every restart path: death respawn, round reset (`RespawnBots` → `ServerRestartController`) and `FailedToRestartPlayer` retries. Hooking the spawning-manager chain instead would mean editing two layers, including Lyra's TDM component that discards `Super` |
| 4 | Re-apply per-pawn overrides on each new pawn + new `OnBotRespawned` BP delegate | `ACustomBotSpawnPoint`, bound to the controller's possessed-pawn-changed event | The colour override is applied to the **pawn** (`ApplyToActor(GetPawn())`), so it is lost on respawn. Team is on the PlayerState and the GEs are on the PlayerState ASC, so both persist. The mesh override lives on the controller's mesh-picker component and probably persists (**verify**) |
| 5 | Exclude anchored bots from the kick-fill swap and from `RemoveExtraBots` / `ClearSpawnedBots` | `ABASGameMode::RequestPlayerRestartNextFrame`, `UArcasBotCreationComponent` | Otherwise a scripted bot can be deleted to make room for a joining player, or wiped by a level reset |

**Order (one change at a time, Marco PIE-tests each):** 1+2+3 is the core feature, then 4, then 5.

### 8.3 Behaviour and edge cases
- **Respawn delay** is `GA_AutoRespawn`'s timer, the same as for players. A per-point delay would be a later option.
- **`GE_DisableRespawn` still wins.** Leaving it in the list with the option ticked means no respawn. Add an editor warning when both are set.
- **Point occupied** (someone standing on it): a blocked pawn spawn → `FailedToRestartPlayer` → for bots it retries next frame, indefinitely. Mitigate in #3: if `GetLocationOccupancy(bot) == Full`, fall back to `Super` (or wait). **Verify** the pawn's spawn collision handling.
- `PlayerStart.DontSpawn` stays, so humans and match bots still never use the point.
- Bots from match-wide spawners have no anchor, so their behaviour is unchanged.

### 8.4 Test plan (PIE)
1. Tutorial map: tick the option, remove `GE_DisableRespawn`, kill the bot → it reappears at the same point after the respawn timer.
2. Same, with colour and mesh overrides → appearance is kept after respawn.
3. Stand on the point while the bot is dead → it does not get stuck in a retry loop.
4. Brawl round reset with an anchored bot → it is back at its point.
5. An untouched point (option off) → exactly today's behaviour.

### 8.5 REVISED design after Dan's answers (2026-11-01) — supersedes 8.2

**Constraints from Dan:** this is for **training modes** (maybe campaign later), **never multiplayer**, and must not change any multiplayer behaviour. `GE_DisableRespawn` in the spawn point's GE list **overrides** the new option. Dan wants a choice between **SameBot** and **FreshBot** on respawn, so loadouts can alternate.

**Current respawn delay: 5.0 s.** `GA_AutoRespawn` CDO `RespawnDelayDuration` (DoubleProperty), read off the asset by decoding the tagged property. It applies to players and bots alike. `GA_AutoRespawn_BombScenario` was not read.

**Key change: the spawn point owns its bots' respawn end to end.** No more GameMode override and no anchor on the controller:
- When respawn is on, the spawn point applies `Ability.Behavior.BlockRespawn` to its own bot itself, so `GA_AutoRespawn` never fires for it, binds to the pawn's health-component death, and on death-finished starts **its own timer**.
- Because `GA_AutoRespawn` never fires, `ABASGameMode::RequestPlayerRestartNextFrame` is never reached, so the **kick-fill swap can't touch these bots**. `ChoosePlayerStart`, the spawning rules and `GA_AutoRespawn` stay unmodified, so **multiplayer is untouched by construction**: everything lives in `ACustomBotSpawnPoint` and only runs for points where Marco set the option.

**New properties on `ACustomBotSpawnPoint` (`Bot|Respawn`):**

| Property | Type | Default | Notes |
|---|---|---|---|
| `RespawnBehaviour` | enum `None / SameBot / FreshBot` | `None` | `None` = exactly today |
| `RespawnDelay` | float s | `5.0` | same as today's global; per point, so a training dummy can come back in 1 s and a campaign enemy in 30 s |
| `MaxRespawns` | int | `-1` (infinite) | optional, cheap; useful for campaign |
| `FreshBotControllerClasses` | array of controller classes | empty | FreshBot only; empty = reuse `BotControllerClass` |
| `FreshBotSelection` | enum `Cycle / Random` | `Cycle` | FreshBot only; this is the "alternate loadouts" knob |

**SameBot:** after the delay, `GameMode->RestartPlayerAtPlayerStart(SameController, this)`. Same controller and PlayerState, so the same name, team, loadout and score. Then re-apply the per-pawn overrides (colour, probably the mesh) and broadcast `OnBotRespawned`.

**FreshBot:** after the delay, remove the old bot through the bot component (`Cheat_RemoveBot(controller)`, public under `WITH_SERVER_CODE`), then `SpawnOneBot(nextClass, this, CustomBotName)` and re-run the full post-spawn setup (team, mesh, colour, GEs, internal BlockRespawn). The new controller rolls its loadout from its own BP (`ArcasAILoadoutComponent` `bRandomize*` / `CustomLoadout`), so alternating loadouts = alternating controller classes (or one class with randomise flags). It gets a new PlayerState: the old one leaves the scoreboard.

**Override rule:** if `OptionalGameplayEffectClassesToApplyAtSpawn` contains a GE granting `Ability.Behavior.BlockRespawn` (i.e. `GE_DisableRespawn`), `RespawnBehaviour` is treated as `None` at runtime, and the editor shows a warning (and greys out the respawn fields via `CanEditChange`).

**Remaining checks:**
- Does any training/campaign experience have a warmup phase? The tutorial experiences use `B_ArcasBotSpawner` (Arcas component), and a warmup-end/`ResetLevel` `SpawnBots()` would `ClearSpawnedBots()` and wipe point bots. Out of scope only if there's no warmup.
- Is `B_CustomBotSpawnPoint` placed in any multiplayer map? (Needs the VM `get_referencers`.) Even if it is, `RespawnBehaviour` defaults to `None`, so nothing changes.
- The mesh override persisting across SameBot respawns.
- A blocked point (someone standing on it): this design calls `RestartPlayerAtPlayerStart` directly, so test what the pawn's spawn collision handling does there.

### 8.6 REVISED again (2026-11-01): location and identity are separate options — supersedes the `RespawnBehaviour` enum in 8.5

Dan: "SameBot but normal location" must be possible, so *where* and *which bot* are independent.

| Property | Values | Default |
|---|---|---|
| `bCustomRespawn` (master switch) | off = today exactly (`GA_AutoRespawn`, 5 s, normal rules, same bot) | off |
| `RespawnLocation` | `NormalSpawnRules` / `ThisPoint` | `ThisPoint` |
| `RespawnBot` | `SameBot` / `FreshBot` | `SameBot` |
| `RespawnDelay` | seconds | 5.0 |
| `MaxRespawns` | -1 = infinite | -1 |
| `FreshBotControllerClasses` + `FreshBotSelection` (Cycle/Random) | FreshBot only | empty / Cycle |

`GE_DisableRespawn` in the GE list still overrides everything: no respawn, and the respawn fields are greyed out.

**All four combinations reuse existing calls; the location is just the start spot argument:**

| | `ThisPoint` | `NormalSpawnRules` |
|---|---|---|
| **SameBot** | `GameMode->RestartPlayerAtPlayerStart(ctrl, this)` | `ctrl->ServerRestartController()` → `RestartPlayer` → spawning rules |
| **FreshBot** | remove old, `SpawnOneBot(class, this, name)` | remove old, `SpawnOneBot(class, nullptr, name)` → spawning rules |

None of these go through `RequestPlayerRestartNextFrame`, so the multiplayer kick-fill swap stays out of reach either way.

"Normal spawn rules" is **not random**. It is the regular PlayerStart (not `DontSpawn`, same team or team-less) **furthest from the nearest living enemy pawn**, and random only when no enemy is alive (TDM component, §8.1).

### 8.7 FINAL scope (Dan, 2026-11-01): only `ACustomBotSpawnPoint` changes

**Rule: don't break anything that exists; only add to the custom bot spawn point.** Loadout variety comes from **existing controller Blueprints** (each one carries its own `ArcasAILoadoutComponent.CustomLoadout`; Marco makes small children of `BP_ArcasBotController_Raider` when he needs a new loadout). **No per-entry loadout override and no hook in `SpawnOneBot`** (both rejected, because they would touch the shared Lyra spawn function).

**Files touched: `CustomBotSpawnPoint.h` / `.cpp` only.** Everything it calls already exists and is public:
`SpawnOneBot(class, StartSpot, name)`, `Cheat_RemoveBot(controller)` (under `WITH_SERVER_CODE`), `GameMode->RestartPlayerAtPlayerStart`, `ALyraPlayerBotController::ServerRestartController`, `ULyraHealthComponent` death delegates, applying a GE to the bot's ASC.

**Final property set (`Bot|Respawn`, all inert while `bCustomRespawn` is off):**
- `bCustomRespawn`: master switch, default off = today exactly
- `RespawnLocation`: `ThisPoint` / `NormalSpawnRules`
- `RespawnBot`: `SameBot` / `FreshBot`
- `RespawnDelay` (5.0), `MaxRespawns` (-1)
- `FreshBotControllerClasses` (array of existing controller BPs; empty = `BotControllerClass`; when set, the first spawn uses entry 0)
- `FreshBotSelection`: `Cycle` / `Random`
- `CycleEnd`: `Loop` / `StopAtEnd` / `HoldLast` (Cycle only)
- `OnBotRespawned` delegate (BlueprintAssignable)
- `GE_DisableRespawn` (any GE granting `Ability.Behavior.BlockRespawn`) in the GE list overrides all of it; the respawn fields are greyed out with a warning.

**Build order (one change at a time, Marco PIE-tests each):**
1. Master switch + `SameBot` + `ThisPoint`/`NormalSpawnRules` + delay + max respawns.
2. `FreshBot` + the controller array + Cycle/Random + cycle end.
3. Editor greying-out and warning when `GE_DisableRespawn` is in the list.

### 8.8 AS-BUILT (2026-11-01): `044b95f0b` on `deploy/steam-testing`, NOT YET COMPILED

All of 8.7 shipped in **one push** (Dan: no steps, no feature branch). Only `CustomBotSpawnPoint.h/.cpp` changed. The build VM was stocked out, so Marco compiles and PIE-tests it.
- Normal respawn is blocked per bot with a **loose** `Ability.Behavior.BlockRespawn` tag on the bot's PlayerState ASC (server only, not replicated). That assumes `GA_AutoRespawn` checks the tag on the server. If the log ever says "already respawned by something else", that assumption is wrong: switch to applying `GE_DisableRespawn` itself.
- The delay counts from death **start** (like `GA_AutoRespawn`) but never fires before death **finished** + 0.1 s.
- SameBot re-applies the mesh + colour overrides. GEs are NOT re-applied: they live on the PlayerState ASC and should persist (test it).
- FreshBot removes the old bot with `Cheat_RemoveBot` (leaves the scoreboard) and spawns through `SpawnOneBot`, then the same setup as the first spawn. Fires `OnBotRespawned`, never `OnBotSpawned` again (tutorial triggers listen to that).
- If a restart gives no pawn (point blocked → Lyra `FailedToRestartPlayer` → normal rules next frame), it polls 20 x 0.25 s for the pawn and keeps tracking it.
- With custom respawn on, the soft classes stay loaded until `EndPlay` (a 2nd `SpawnBot()` call then spawns right away instead of being ignored).
- `RespawnStatus` (Details panel, read-only) summarises the setup; respawn fields are greyed out via `CanEditChange` when a blocking GE is in the list.
- Log category: `LogCustomBotSpawnPoint`.
