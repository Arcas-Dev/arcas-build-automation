# Arcas Champions - Database Structure

**Date**: 2026-02-02
**Database**: Cloud SQL PostgreSQL 16
**Instance**: `game-backend-db` (arcas-champions project)
**Access**: VPC-only (Cloud Console or Cloud Run)

---

> 📐 **Target ERD** (where this schema is heading): `arcas-champions/docs/target-erd.drawio.svg`.
> Merges the live schema below with [[progression-ranking-spec]]: `championprestige`,
> `prestige_tiers`, `prestige_rewards`, `progression_config`, `prestige_payouts`, plus new
> columns on `playervault` (consumables, skins, weaponmods), `champions` (skin_id,
> vial_points_spent), `match_history` (champid, prestige_delta) and `progression_levels`
> (reward_type/id/qty).

## Tables

| Table | Purpose |
|-------|---------|
| `playerprofile` | User identity (auth, wallet, username, steamid) |
| `champions` | Individual champions with skins, stats, names |
| `playervault` | Player's unlocked weapons and totems |
| `playerloadouts` | 5 saved loadout configurations per player |
| `playerrank` | Player MMR/ranking + voting power |
| `playerprogression` | **NEW (2026-07)** Account XP + level (see Progression System below) |
| `progression_levels` | **NEW (2026-07)** Editable XP→level curve config |

> **Live-drift note (verified 2026-07-15 via `ADMIN_ViewSchema`):** since the Feb doc,
> `playerrank` gained `delegatedvotingpower` + `permanentvotingpower` (int, default 0);
> `playerprofile.authtype` is now enum `authtypeenum` (was TEXT). Test mirrors exist for
> all prefixed tables (`testchampions`, `testplayervault`, `testplayerloadouts`,
> `testplayerrank`, `testplayerprogression`) — `LIKE ... INCLUDING ALL` copies, no FK
> constraints, driven by the dual-write `initialize_player_associations()` trigger.
> There is **no** `testplayerprofile` — test tables share the single prod `playerprofile`.

> **Live-drift note (2026-09-09, verified via `ADMIN_ViewSchema` after `ADMIN_InitializeLoadoutSystem`):**
> `playervault`/`testplayervault` + `primarymods, secondarymods, meleemods INT[]`; new `playerconsumables`/`testplayerconsumables`;
> `progression_levels` + `reward JSONB` (one reward per level: `{type, id}` for weapon/totem/mod, `{type, qty}` for banana/vial, NULL at L1; 69 rows filled);
> `testplayerloadouts` now has the 5 `validate_loadout` triggers (it had none) and its `loadoutN` DEFAULT is the starter kit `{Weapons:[101,201,303], Totems:[401,501,602]}`.
> `validate_loadout()` is v2 (table-aware via `TG_TABLE_NAME`); `initialize_player_associations()` v3 (prod: legacy full vault, test: starter kit, + consumables rows).

---

## Table Schemas

### playerprofile
| Column | Type | Notes |
|--------|------|-------|
| playerid | SERIAL | PK, auto-increment |
| authtype | TEXT | 'epic' or 'steam' |
| authhash | TEXT | SHA256 of auth ID |
| wallet | TEXT | Ethereum address |
| privatekey | TEXT | Encrypted |
| iv | TEXT | Encryption IV |
| username | TEXT | Display name |
| steamid | TEXT | Steam ID (if steam auth) |
| steamavatarurl | TEXT | Steam avatar URL |
| tutorialcomplete | BOOLEAN | Default FALSE |

### champions
| Column | Type | Notes |
|--------|------|-------|
| champid | SERIAL | PK, auto-increment |
| playerowner | INT | FK → playerprofile.playerid |
| gender | INT | 0=Female, 1=Male |
| skinteam | INT | 0=Elite, 1=Renegade |
| health | INT | 4-12 |
| strength | INT | 4-12 |
| intelligence | INT | 4-12 |
| agility | INT | 4-12 |
| luck | INT | 4-12 |
| championinitialised | BOOLEAN | Has stats assigned |
| championunpacked | BOOLEAN | Has name assigned |
| name | TEXT | Champion name (set on unpack) |

### playervault
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT | FK → playerprofile.playerid |
| primaryweapons | INT[] | Array of weapon IDs |
| secondaryweapons | INT[] | Array of weapon IDs |
| meleeweapons | INT[] | Array of weapon IDs |
| damagetotems | INT[] | Array of totem IDs |
| utilitytotems | INT[] | Array of totem IDs |
| supertotems | INT[] | Array of totem IDs |
| primarymods | INT[] | **NEW 2026-09-09** owned mods for primary weapons (7xx), default `{}` |
| secondarymods | INT[] | **NEW 2026-09-09** owned mods for utility weapons (8xx), default `{}` |
| meleemods | INT[] | **NEW 2026-09-09** owned mods for melee weapons (9xx), default `{}` |

A loadout weapon slot may hold a **variant id** `base×1000+mod` (101701 = Pistol + Double Tap); unmodded weapons keep the base id. `validate_loadout()` v2 requires the base in its class array **and** the mod in the matching mod array (mod fits ⇔ `mod/100−6 = base/100`). See [[loadout-system-build-spec]] AS-BUILT.

### playerconsumables (NEW 2026-09-09)
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT | PK, FK → playerprofile.playerid |
| bananas | INT | Default 0 — accrued by level rewards `{type:'banana', qty}` |
| vials | INT | Default 0 — accrued by level rewards `{type:'vial', qty}` |
| updated_at | TIMESTAMPTZ | |

Test mirror `testplayerconsumables`. Accrue only; nothing spends them yet. Written by `awardMatch → grantLevelRewards → grantConsumable` (upsert) and `ADMIN_GrantItem {bananas|vials}`.

### playerloadouts
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT | FK → playerprofile.playerid |
| loadout1 | JSONB | {Champion: int, Weapons: [3], Totems: [3]} |
| loadout2 | JSONB | |
| loadout3 | JSONB | |
| loadout4 | JSONB | |
| loadout5 | JSONB | |

### playerrank
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT | FK → playerprofile.playerid |
| rank | INT | Default 2500 |
| delegatedvotingpower | INT | Default 0 (SkillStaking) |
| permanentvotingpower | INT | Default 0 (SkillStaking) |

### playerprogression (NEW 2026-07)
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT | PK + FK → playerprofile.playerid |
| total_xp | BIGINT | **Authoritative**, cumulative, monotonic. Default 0 |
| level | INT | Denormalized cache, derived from `progression_levels`. Default 1 |
| pending_levelup | BOOLEAN | Default FALSE. Set TRUE (sticky) by `awardMatch` on a level rise; `GET_Profile` reads-and-clears it atomically → client fires the unlock popup once (`LeveledUp`) |
| updated_at | TIMESTAMPTZ | Default now() |

### progression_levels (NEW 2026-07)
| Column | Type | Notes |
|--------|------|-------|
| level | INT | PK |
| xp_required | BIGINT | **Cumulative** XP to reach this level |

Global config (no test mirror). Seeded L1–L30 by `ADMIN_InitializeProgression`.
Curve: `xp_required(L) = 400*(L-1) + 50*(L-2)*(L-1)` → L2=400, L3=900 … L30=52,200.
Editable live (UPDATE rows or re-run the init endpoint) with no migration —
level is always recomputed from this table, never stored authoritatively.

---

## Progression System (XP + Levels)

**Design pattern:** cumulative XP is the single source of truth; level is derived
from the `progression_levels` curve. Level cached in `playerprogression.level` for
cheap reads + level-up detection, recomputed on every XP write.

**XP awards (server-authoritative):** win = +100 XP, loss = +40 XP, via
`POST_MatchResults {win:[ids], loss:[ids], ranked?:bool}`. The `ranked` flag also
applies ±25 MMR. `POST_RankedMatchResults` is now a thin wrapper (ranked=true).
Shared logic in `awardMatch(win, loss, ranked)` in server.js.

**Client display (Pattern A):** `GET_Profile` returns `Level`, `LevelXP` (into
current level), `LevelXPRequired` (size of current band). Client derives
"XP to next" = `LevelXPRequired − LevelXP`; bar fill = `LevelXP / LevelXPRequired`.
At max level `LevelXPRequired = 0`. Client never knows the curve (a future
`GET_ProgressionConfig` endpoint would let it cache the full ladder if needed).

**Admin:** `ADMIN_InitializeProgression` (idempotent; creates tables + curve +
backfill + extends trigger). `ADMIN_ViewSchema` (read-only full schema dump).

---

## Sequences

| Sequence | Purpose |
|----------|---------|
| `champions_champid_seq` | Auto-increment for champions.champid |
| `playerprofile_playerid_seq` | Auto-increment for playerprofile.playerid |

---

## Functions

### enforce_champion_initialization()
**Purpose**: Validates champion stats when ChampionInitialised is set to TRUE

**Logic**:
- All stats (Health, Strength, Intelligence, Agility, Luck) must be > 3
- Gender and SkinTeam must not be NULL

**Cross-table references**: None

### initialize_player_associations()
**Purpose**: Auto-creates related records when a new player registers

**Logic**:
- Inserts default row into `PlayerVault` with starter weapons/totems
- Inserts default row into `PlayerLoadouts`
- Inserts default row into `PlayerRank` (rank defaults to 2500)

**Cross-table references**:
- INSERT INTO `PlayerVault`
- INSERT INTO `PlayerLoadouts`
- INSERT INTO `PlayerRank`

**Default items**:
```sql
PrimaryWeapons: [101, 102, 103, 104, 105]
SecondaryWeapons: [201, 202, 203, 204]
MeleeWeapons: [301, 302]
DamageTotems: [401, 402, 403]
UtilityTotems: [501, 502, 503, 504]
SuperTotems: [601, 602, 603]
```

### validate_champion_unpacking()
**Purpose**: Validates champion unpacking (naming)

**Logic**:
- Name must be non-empty string
- Other fields (stats, gender, skinteam, owner) cannot be modified during unpacking

**Cross-table references**: None

### validate_loadout(loadout_name TEXT)
**Purpose**: Validates loadout updates

**Logic**:
- Champion must be owned by player (queries `Champions`)
- Champion must be initialised and unpacked
- Champion cannot be in multiple loadouts
- Weapons must be in player's vault (queries `PlayerVault`)
- Totems must be in player's vault (queries `PlayerVault`)

**Cross-table references**:
- SELECT FROM `Champions`
- SELECT FROM `PlayerVault`

---

## Triggers

| Trigger | Table | Event | Timing | Function |
|---------|-------|-------|--------|----------|
| `validate_initialization` | champions | UPDATE | BEFORE | `enforce_champion_initialization()` |
| `validate_champion_unpacking_trigger` | champions | UPDATE | BEFORE | `validate_champion_unpacking()` |
| `validate_loadout1_trigger` | playerloadouts | UPDATE | BEFORE | `validate_loadout('Loadout1')` |
| `validate_loadout2_trigger` | playerloadouts | UPDATE | BEFORE | `validate_loadout('Loadout2')` |
| `validate_loadout3_trigger` | playerloadouts | UPDATE | BEFORE | `validate_loadout('Loadout3')` |
| `validate_loadout4_trigger` | playerloadouts | UPDATE | BEFORE | `validate_loadout('Loadout4')` |
| `validate_loadout5_trigger` | playerloadouts | UPDATE | BEFORE | `validate_loadout('Loadout5')` |
| `initialize_associations_trigger` | playerprofile | INSERT | AFTER | `initialize_player_associations()` |

---

## Trigger Flow Diagram

```
NEW USER REGISTRATION:
playerprofile INSERT
    └─→ initialize_associations_trigger (AFTER INSERT)
        └─→ initialize_player_associations()
            ├─→ INSERT INTO playervault (default items)
            ├─→ INSERT INTO playerloadouts (empty)
            └─→ INSERT INTO playerrank (2500)

CHAMPION CREATION (via API):
champions INSERT
    └─→ (no trigger on INSERT currently)

CHAMPION INITIALIZATION (setting stats):
champions UPDATE (ChampionInitialised = TRUE)
    └─→ validate_initialization (BEFORE UPDATE)
        └─→ enforce_champion_initialization()
            └─→ Validate stats > 3, gender/skinteam not null

CHAMPION UNPACKING (naming):
champions UPDATE (ChampionUnpacked = TRUE)
    └─→ validate_champion_unpacking_trigger (BEFORE UPDATE)
        └─→ validate_champion_unpacking()
            └─→ Validate name set, other fields unchanged

LOADOUT UPDATE:
playerloadouts UPDATE
    └─→ validate_loadoutN_trigger (BEFORE UPDATE)
        └─→ validate_loadout('LoadoutN')
            ├─→ SELECT FROM champions (ownership check)
            └─→ SELECT FROM playervault (item ownership check)
```

---

## Testing Infrastructure Considerations

### Functions with hard-coded table names:
1. **initialize_player_associations()** - Inserts into: `PlayerVault`, `PlayerLoadouts`, `PlayerRank`
2. **validate_loadout()** - Selects from: `Champions`, `PlayerVault`

### Functions without cross-table references:
1. **enforce_champion_initialization()** - Only validates the row itself
2. **validate_champion_unpacking()** - Only validates the row itself

### Key insight for testing:
- `initialize_associations_trigger` only fires on **INSERT** (new user)
- Existing users logging into test API won't trigger it
- Only new users in test environment would hit this issue
