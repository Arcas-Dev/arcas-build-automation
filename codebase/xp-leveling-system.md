# XP & Leveling System

**Status:** live on the **test** environment (client build `2026-07-18_18-59` server + the `ef7da39fc` client; API on `arcaschampionsapi-test`, branch `testing`). Built/finalized 2026-07-18.

This documents the **account XP/level half** of progression (earn XP → level up). The **vault/loadout unlock half** (granting items on level-up) is still unbuilt — see `progression-system-status-2026-07.md` and `barracks-vault-flow.md`.

---

## 1. How much XP a match awards

Per **player**, every completed matchmade game (casual **and** ranked):

```
XP = clamp( base + min(PERF_CAP, KILL_PTS*kills + ASSIST_PTS*assists + DEATH_PTS*deaths),  floor = XP_FLOOR )
```

| Constant | Value | Meaning |
|----------|------:|---------|
| base (win) | 100 | `XP_WIN` |
| base (loss) | 40 | `XP_LOSS` |
| `KILL_PTS` | +3 | per kill |
| `ASSIST_PTS` | +1 | per assist |
| `DEATH_PTS` | −3 | per death |
| `PERF_CAP` | 120 | max performance bonus (= 40 kills) |
| `XP_FLOOR` | 10 | a finished match never awards less |

- **Range: 10 (worst) → 220 (best).** Worst = any loss with enough deaths (floored). Best = a win + the +120 cap (e.g. 40 kills / 0 deaths → 100 + 120).
- Example — **15 kills / 5 deaths / 5 assists**: performance = 45 + 5 − 15 = **+35** → **win 135 / loss 75**.
- Defined in **`ArcasChampionsAPI/server.js`** as the 5 consts above + `computeMatchXp()`. `awardMatch()` computes each player's amount from the `stats` (K/D/A) array the dedicated server sends, and applies it in the same UPDATE that recomputes level. **Retuning = edit the constants, push to `testing`. No game build.**

The K/D/A also feeds `match_history` (one row per player per match: result + K/D/A + ranked flag, grouped by `match_id`; `testmatch_history` mirror on test).

---

## 2. The level curve

Stored in the **`progression_levels`** table: one row per level, `xp_required` = **cumulative** XP to *reach* that level. The per-level cost is the gap between two consecutive rows. 70 levels.

- **Shape:** convex — starts at 50, and the *jump* between consecutive levels never decreases (+10 → +26). Fast early, steadily harder, never a wall.
- **Anchors:** L1→2 = 50 xp · L2→3 = 60 · L3→4 = 70 · … · L69→70 = 1,254 xp (~13 wins). **Max level 70 reached at 38,970 xp (~390 wins).**
- Milestones to reach: L10 ≈ 8 wins · L30 ≈ 63 · L50 ≈ 184 · L70 ≈ 390.

**Where it's configured:** the `XP_REQUIRED` array in `ADMIN_InitializeProgression` (server.js). To retune: edit the array → push → `POST ADMIN_InitializeProgression` (idempotent — reseeds the curve, drops rows above the new max, and **recomputes every player's stored level**). No game build; the client reads the numbers via `GET_Profile`.

Design note: with integer XP, a *strictly* larger jump every single level forces +1/level minimum → top would be ~37 wins. Capping the top at ~13 wins requires the jump to step up (some adjacent levels share a jump) — we round the **increment**, so the jump never shrinks.

---

## 3. Client display

Everything the client shows derives from `GET_Profile`, which returns `Level`, `LevelXP` (progress into the current level), `LevelXPRequired` (size of the current level), and `LeveledUp` (a sticky one-shot flag).

- **Account level/XP bar** (`UPlayerAccountWidget`, top bar): fill = `LevelXP / LevelXPRequired`. Refreshes itself after a match via `UBASCommonUserSubsystem::RefreshProfile(OnComplete)` — a per-instance weak-lambda callback (the shared `OnProgressionUpdated` broadcast doesn't reliably reach the visible bar across the frontend widget lifecycle). `RefreshProfile` is progression-only — it does **not** re-broadcast `OnBASUserAuthenticated` (which would re-run the login flow and loop the menu).
- **Level-up popup**: fires once when `GET_Profile` returns `LeveledUp=true` (server sets a sticky `pending_levelup` on level increase; `GET_Profile` reads-and-clears it). BP wired by Marco. Dev cmd: `Arcas.LevelUp [n]` (editor only).
- **Progression-slot gating**: slots are unlocked by level (`CooldownPercent` 1 = unlocked / 0 = locked).
- **End-of-match banner** (`UEndMatchBannerWidget`): shows the **actual earned XP**, computed client-side by `ComputeEarnedXP()` mirroring the server formula (reads the local player's replicated `ShooterGame.Score.Eliminations/Deaths/Assists` stat-tags — same source as the scoreboard). Client-side because the API award is async and returns after the banner shows. The 5 modifier values are `EditAnywhere` UPROPERTYs on the widget — **keep them in sync with the API constants** if you retune (editor edit, no rebuild). Only shows on a real match end (not between rounds) and only in a public matchmade match.

---

## 4. Server plumbing (how a match reaches the award)

`ABASGameMode::EndDedicatedServerMatch` → `SendMatchResults(bRanked)` → `CalculateMatchResults()` builds the win/loss arrays + per-player K/D/A from `MatchInfo` + stat-tags → POSTs `POST_MatchResults` (casual, XP only) or `POST_RankedMatchResults` (ranked, XP + MMR).

**Two casual gotchas fixed 2026-07-18** (both were "ranked-only" and broke casual):
1. `AddPlayerToMatchInfo` (PreLogin) + `MatchInfoUpdateOnPostLogin` (PostLogin) were gated to `CurrentGameMode=="ranked"`. Casual players were never in `MatchInfo` → `CalculateMatchResults` bailed at `MatchInfoPlayers.Num()==0` → empty payload. Now gated on `GetInjectedEVGameMode()` (any matchmade match).
2. `ABASGameMode::WonTeamId` was only set by the ranked (Eggsplosion) Blueprint via `SetWonTeamId`. Now the scoring component's `HandleMatchHasEnded(NewWonTeamId)` propagates the winner to `SetWonTeamId` for every mode.

Private/lobby matches have no injected game mode → award nothing (and the banner hides the XP box).

---

## 5. Admin / ops (test API)

`x-admin-key: 8923jndfsjiqijmq` · base `https://arcaschampionsapi-test-1093142381010.europe-west1.run.app`

| Endpoint | Use |
|----------|-----|
| `POST ADMIN_InitializeProgression` | Idempotent: create tables, (re)seed the curve from `XP_REQUIRED`, backfill players, recompute levels. Run after any curve edit. |
| `POST ADMIN_ResetProgression` | Body `{ keep:[ids], env:"test"\|"prod"\|"both" }` — zero XP/level for everyone except the keep-list. |
| `GET ADMIN_GetProgression?playerid=` | A player's prod+test progression row. |
| `GET ADMIN_GetMatchHistory?playerid=` | A player's match history. |

Current test state: only players **11** and **12** carry XP; everyone else reset to 0 / L1.

---

## 6. Retuning cheat-sheet (no game build for the numbers)

- **Change per-match XP** (kill/assist/death values, cap, floor, win/loss base): edit the consts in `awardMatch` (server.js), push to `testing`. Also update the 5 `EditAnywhere` values on `W_MatchDecided_Message` (EndMatchBannerWidget) so the banner stays truthful.
- **Change the level curve**: edit `XP_REQUIRED` in `ADMIN_InitializeProgression`, push, call the endpoint.
- **Reset players**: `ADMIN_ResetProgression`.
