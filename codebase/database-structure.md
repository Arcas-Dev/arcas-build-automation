# Arcas Champions - Database Structure

**Date**: 2026-02-02
**Database**: Cloud SQL PostgreSQL 16
**Instance**: `game-backend-db` (arcas-champions project)
**Access**: VPC-only (Cloud Console or Cloud Run)

---

## Tables

| Table | Purpose |
|-------|---------|
| `playerprofile` | User identity (auth, wallet, username, steamid) |
| `champions` | Individual champions with skins, stats, names |
| `playervault` | Player's unlocked weapons and totems |
| `playerloadouts` | 5 saved loadout configurations per player |
| `playerrank` | Player MMR/ranking |

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
