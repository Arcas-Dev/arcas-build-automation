# Progression System — Current Status (2026-07-16)

**Supersedes the baseline in** [[progression-system-audit-2026-07]] (that audit @ `b0dcbfb69` was the *pre-work* state — "nothing built"). This session (2026-07-15/16) built the XP engine; this doc is the **as-of `d841c0f27`** reality, live-verified. Target design unchanged: [[progression-system-plan]].

## Headline

The system is now **half-built**: the **award → persist → level → notify** half exists and works end-to-end; the **own → gate → grant** half (vault/loadout unlocks) is entirely unbuilt. The two halves still don't reference each other.

---

## ✅ BUILT this session (verified live on test)

### Backend — `ArcasChampionsAPI/server.js` (committed `testing` `e7ef428`; auto-deploys to `arcaschampionsapi-test` via the git trigger)
- **`playerprogression`** table: `playerid` PK/FK, `total_xp` BIGINT (authoritative, cumulative), `level` INT (derived cache), `pending_levelup` BOOL, `updated_at`. Test mirror `testplayerprogression`. 829 players backfilled at L1.
- **`progression_levels`** config table: `level` PK, `xp_required` BIGINT (cumulative). Seeded L1–30 by formula `xp_required(L) = 400*(L-1) + 50*(L-2)*(L-1)` (L2=400, L3=900 … L30=52,200). Editable, no migration — level is always recomputed from this table.
- **XP award**: `POST_MatchResults {win:[ids], loss:[ids], ranked?:bool}` — win **+100**, loss **+40**, recomputes level, sets `pending_levelup=TRUE` (sticky) on a level rise. `ranked:true` also does ±25 MMR. `POST_RankedMatchResults` is now a thin wrapper (ranked=true). Shared logic = `awardMatch(win, loss, ranked)`.
- **`GET_Profile`** returns `Level`, `LevelXP` (into current level), `LevelXPRequired` (size of band), and `LeveledUp` (read-and-cleared: the atomic `UPDATE ... WHERE pending_levelup=TRUE RETURNING` fires once after a level-up). Pattern A: server owns the curve, client just displays.
- **Admin endpoints** (read-only unless noted): `ADMIN_ViewSchema` (full live schema), `ADMIN_GetProgression?playerid=` (a player's progression row), `ADMIN_InitializeProgression` (idempotent: creates tables + curve + backfill + extends trigger). Admin key `8923jndfsjiqijmq` via `x-admin-key`.

### Client — `dandad3v/ApeShooter` @ deploy/steam-testing (committed + pushed + in the Steam Demo build)
- `FProfile` (`Structs/Profile.h`) carries `Level, LevelXP, LevelXPRequired, LeveledUp` (BlueprintReadOnly).
- `UBASCommonUserSubsystem`: `GetStoredProfile()` (BlueprintPure), `OnProgressionUpdated` (BlueprintAssignable event, broadcast on GetProfile + the dev console cmd), `DevLevelUp()`, and a **`Arcas.LevelUp [n]` console command** (WITH_EDITOR) that bumps the editor preview level (starts at 1) and fires a one-shot level-up to test the popup in PIE.
- **Account level/XP bar**: `UPlayerAccountWidget` (`W_AccountSection`) — fills the old `PlayerAccountWidget.cpp:16` TODO. Sets `PlayerLevel` text + drives `MI_UI_Slider` "Progress" scalar (0-1) = `LevelXP/LevelXPRequired`. Refreshes on `OnProgressionUpdated`.
- **Progression slots gate by level**: `UPlayerProgressionSlotWidget` reads the real player level (was hardcoded `1`) and drives the icon material `CooldownPercent` (1 = unlocked/bright, 0 = locked/darkened) vs each row's `ItemCollectLevel`.
- **Level-up popup is now triggered**: Marco's `f9f3819d8 "Linked New Level Message to the back end"` (BP wiring on `W_MainMenu`/`W_AccountSection`/`W_NewLevelUnlockedMessage`) + our `OnProgressionUpdated` / `LeveledUp`. The audit's "no C++ triggers the popup" is now **false**.

### How the popup connects (BP, done by Marco)
Bind `OnProgressionUpdated` → `GetStoredProfile` → branch on `LeveledUp` → look up the `DT_PlayerProgressionItems` row where `ItemCollectLevel == Level` → push `W_NewLevelUnlockedMessage`. Every level has one unlockable, so "did we cross a level" (`LeveledUp`) is all the client needs.

---

## ❌ NOT built — the vault/loadout unlock half (next task)

Every joint verified still open at `d841c0f27`:

| Joint | Status | Location |
|---|---|---|
| Grant item into vault on level-up | ❌ `POST_MatchResults` awards XP only, never writes `playervault` | server-side |
| `GET_Vault` owned-ID discard | ❌ still `// TODO: AddWeaponSlots/AddTotemSlots` | `Vault.cpp:103` |
| Loadout UI respects ownership | ❌ shows all `DT_AllVaultItems`, ignores owned IDs | `Vault.cpp` |
| "Collect" grants anything | ❌ `OnSlotClicked` empty TODO | `PlayerProgressionWidget.cpp:43` |
| ID bridge: BP class ↔ offset uint8 | ❌ doesn't exist | new code |
| Shrunk starter kit | ❌ new players still get the full set | `initialize_player_associations()` |

### The two structural problems for unlocks
1. **The ID bridge is the crux.** `DT_PlayerProgressionItems` identifies items by **BP class** (`ID_Rage_C`); `playervault`/`GET_Vault` track ownership by **offset uint8** (101…601, see `LoadoutDAO.h`). Nothing maps between them, so a level-up can't become a vault grant until the bridge exists.
2. **The loadout is already gated server-side** — the `validate_loadout` DB triggers reject any loadout with an item not in `playervault`. So once we shrink the vault + grant on unlock, loadout-gating "just works"; the missing piece is the client honoring it (the `Vault.cpp:103` fix) so players don't build loadouts the server rejects.

### Recommended (leaner than the plan's normalized tables)
Use the existing `playervault` arrays as the ownership source of truth (they already gate loadouts) and grant into them on level-up, instead of the plan's separate `playerunlocks`/`progression_rewards`. Extend `progression_levels` with `unlock_item_id` + `category` as the server-side level→item map. Migration: **grandfather** existing prod players (keep full vault); **reset test** vaults to a starter kit to test unlocks.

---

## `DT_PlayerProgressionItems` contents (string-extracted, unchanged since the audit)

**25 items** — row struct `FPlayerProgressionItem` = `ItemCollectLevel` (int) + embedded `FVaultSlotItem`.

- **18 weapons**: AlienRailgun, Axe, BananaPistol, DBShotgun, GrenadeLauncher, Machete, MadBlower, MadRifle, MadSMG, MadZooka, NailSMG, PlasmaShotgun, RelicSword, Rifle, RocketLauncher, Sniper, Spear, TrapGun.
- **7 totems**: AmmoCrate, AnimalInstinct, ChimpCompanion, Disguise, Rage, Supercharge, TeamHealing.
- Categories `EUserCombatBarrackType::{PrimaryWeapon, UtilityWeapon, MeleeWeapon, ...}`.
- **Excludes the base kit** (Pistol, Shotgun, CombatKnife, Unarmed, totems AutoTurret/Grenade/PersonalHealing) — the curated "earn these by leveling" set.
- ⚠️ **The exact `ItemCollectLevel` per item is NOT captured** — it's a binary int32 not visible to `strings`, and the headless DataTable→JSON export needs the **Python plugin, which is NOT enabled in `NewApeShooter.uproject`** (enabling it = a project change). Get the per-level mapping from Marco or the editor.

## Match-end data available (for richer XP later)
`FPlayerMatchInfo` (`Structs/MatchInfo.h`) has `MatchResult` + a `TMap<FGameplayTag,int32> PlayerTagMap` (already carries `TeamId`). So kills/score/objective-based XP is *feasible* if those tags are populated — but only win/loss is sent today. Whether the tag map is actually populated with combat stats is unverified (a gameplay-code trace, next if wanted).

## Dead code to ignore/delete
`UExperiencePointSubsystem` (`Subsystems/ExperiencePointSubsystem.*`) — the old mock XP engine, still **0 callers** at `d841c0f27`. Our real system is entirely separate (`BASCommonUserSubsystem` + `FProfile`). Two parallel worlds; the mock can be deleted.
