# Progression — DB + API target state (weapon-variant edition)

**Created**: 2026-08-26 (rev 3) · **Status**: 🟠 PARTLY SUPERSEDED 2026-09-09 — the weapon/totem/mod/unlock half is **BUILT** per [[loadout-system-build-spec]] (AS-BUILT block): **no `weapon_catalog`/`weapon_mods`**, three mod columns not one, `reward JSONB`, `playerconsumables`, client sends variant ids directly (no `{Base, Mod}`, no `WeaponDetails`). D20–D24 hold in spirit; §1.3 "only the API derives ids" and §2.2/§3.1 are void. The champion/skins/prestige half is still only proposed
**Diagram**: `arcas-champions/docs/progression-db-api-target.drawio.svg` (also in `drive/`)
**Builds on**: [[progression-ranking-spec]] (D1–D19, still authoritative for prestige / tiers / decay / payouts / skins / vials) · [[database-structure]] · [[barracks-vault-flow]] · [[weapon-mods-design]]

---

## 0. What changed on 2026-08-26 (the pivot)

| # | Decision | Effect |
|---|---|---|
| **D20** | **Weapon mods ship as weapon variants with their own item IDs.** 21 base weapons × (1 + 3 class mods) = **84 weapon IDs** in the game and in the DB. | Supersedes the *in-game* half of D14 / spec §10.1–10.5 (`UBASWeaponModDefinition`, `EquipItem` hook, `OnEquipped()` mutation — **not built**). Phase 10 becomes editor content work (Marco authors variant `ID_*` assets), not C++. |
| **D21** | **The "mod" abstraction lives only in the API and the client.** Ownership stays composed (base weapon + mod, N + M ids); the loadout and the game see a single weapon id. | D14's *player-facing* promise ("one Double Tap, usable on every primary") is kept. The vault does **not** store 84 ids. |
| **D22** | **Mods are what progression unlocks; the API derives variant ids.** `playervault.weaponmods` is the granted object; the client never computes a variant id. | Unlock order no longer matters: equippability = owned base × owned mod, computed on write. |
| **D24** | **Numeric id blocks — three parallel triplets.** WEAPONS `1xx/2xx/3xx` (primary/utility/melee), TOTEMS `4xx/5xx/6xx` (unchanged), **MODS `7xx/8xx/9xx`** (primary/utility/melee mods). Mods are first-class owned objects, same offset convention as everything else. | Supersedes the spec's "800 block" (801–809). Class match is arithmetic: `mod div 100 − 6 == base div 100`. |
| **D25** | **Skins leave the offset scheme.** A skin is equipped onto a *champion*, never into a loadout slot, so it lives in the **Champion system** (with bananas, vials, prestige/rank) with its own id space. | Supersedes spec §8.3 "700 block". `playervault.skins` / `champions.skin_id` keep their shape; ids become 1..8. |
| **D23** | **UI flow: Vault shows BASE weapons only → click → Tuning Table → attach one owned mod of that class.** `GET_Vault` returns base ids + owned mods, never expanded variants. The loadout save sends `{Base, Mod}`; the API stores the derived variant id for the game. | The existing `TuningTable` C++ widget family (`UI/Menu/Barracks/`, see [[barracks-vault-flow]]) is the surface for this. |

Everything else in the spec (four axes, prestige math, decay, monthly payout, skins 700 block, vials, custodial-wallet retirement) is unchanged and not repeated here.

---

## 1. Id blocks and the variant id

### 1.1 Two systems, two id spaces (D24, D25)

| System | Objects | Id space | Stored in |
|---|---|---|---|
| **Loadout system** | weapons, totems, **mods** | the offset scheme below (`LoadoutDAO.h` convention) | `playervault` arrays, `playerloadouts` JSONB |
| **Champion system** | champions, **skins**, bananas, vials, prestige / tier / rank | champions: `champid` serial · skins: **1..8** (own space) · consumables: counters | `champions`, `championprestige`, `playervault.skins/bananas/vials`, `playerrank` |

A skin is applied to a champion; the champion is put in a loadout. Skins never appear in a loadout id, so they need no block.

### 1.2 The offset scheme (extended, nothing renumbered)

```
                base objects            headroom
WEAPONS  1xx primary   101-110 today    up to 199
         2xx utility   201-206 today    up to 299
         3xx melee     301-305 today    up to 399
TOTEMS   4xx damage    401-403          5xx personal 501-504     6xx support 601-603   (unchanged)
MODS     7xx primary   701 DoubleTap    702 HighDamageRounds     703 HighCapacityMag
         8xx utility   801 FireRounds   802 HealingRounds        803 DemolitionRounds
         9xx melee     901 LuckyStrike  902 BerserkBoost         903 Resourceful
```

- A mod fits a weapon iff **`mod div 100 − 6 == base div 100`** (701–799 ↔ 1xx, 801–899 ↔ 2xx, 901–999 ↔ 3xx).
- No new categories are planned; growth = more weapons and more mods inside these blocks (99 each).
- Mod ids exceed `uint8`; the client's `FVaultData` gains a **new `int32` array** for mods, the existing `uint8` weapon/totem arrays are untouched.

### 1.3 The variant id (API-derived, game-facing)

```
variant = base × 1000 + mod          Rifle(103) + DoubleTap(701) = 103701
base    = variant div 1000           mod = variant mod 1000        unmodded stays 103
```

- Self-describing: both ids are readable inside the number, and a wrong class pairing (`103801`) is visibly wrong.
- Fits `int32` everywhere the game reads a loadout id (`FWeapons.Primary/Utility/Melee`, `ULyraInventoryItemDefinition::ItemId`, `PlayerInfoComponent::SetItem` — all `int32`, verified 2026-08-26). Only `FVaultData` is `uint8`, and it never carries a variant (D23).
- One `ID_*` ItemDefinition per variant row = **63 new assets** (Marco, editor), each with its `ItemId` = the variant id.
- **Only the API derives ids** (D22): the client sends `{Base, Mod}` and reads back `{Id, Base, Mod}`. `weapon_catalog` (§2.2) is the runtime truth; the arithmetic is the convention it is seeded from.

---

## 2. Database — target state

Conventions as today: every player table gets a `test`-prefixed mirror (`LIKE … INCLUDING ALL`); config tables are global (no mirror).

### 2.1 Existing tables — new columns

```sql
-- playervault: ownership stays composed. Weapon arrays hold BASE ids only.
ALTER TABLE playervault ADD COLUMN weaponmods INT[] NOT NULL DEFAULT '{}';             -- 7xx/8xx/9xx, owned mods (D24)
ALTER TABLE playervault ADD COLUMN skins      INT[] NOT NULL DEFAULT '{1,2,3,4}';       -- skin ids 1..8, own space (D25)
ALTER TABLE playervault ADD COLUMN bananas    INT   NOT NULL DEFAULT 0;
ALTER TABLE playervault ADD COLUMN vials      INT   NOT NULL DEFAULT 0;

-- playerloadouts: NO schema change. loadoutN JSONB keeps {Champion, Weapons:[P,U,M], Totems:[D,P,S]}.
--   Weapons[] now carry VARIANT ids (103701 = Rifle + DoubleTap). The spec's extra "WeaponMods":[] array is DROPPED.

-- champions
ALTER TABLE champions ADD COLUMN skin_id           INT NOT NULL DEFAULT 1;
ALTER TABLE champions ADD COLUMN vial_points_spent INT NOT NULL DEFAULT 0;
UPDATE champions SET skin_id = 1 + skinteam * 2 + (1 - gender);                        -- backfill: 1 EM · 2 EF · 3 RM · 4 RF (spec §8.4 renumbered)

-- match_history
ALTER TABLE match_history ADD COLUMN champid        INT;
ALTER TABLE match_history ADD COLUMN prestige_delta INT;

-- progression_levels: the level -> reward map
ALTER TABLE progression_levels ADD COLUMN reward_type TEXT;    -- weapon | mod | totem | banana | vial | skin
ALTER TABLE progression_levels ADD COLUMN reward_id   INT;     -- weapon/totem/mod id (offset scheme) or skin id 1..8 (reward_type disambiguates), or NULL
ALTER TABLE progression_levels ADD COLUMN reward_qty  INT DEFAULT 1;

-- playerprofile: wallet / privatekey / iv -> RETIRE per spec §4.7 (stop generating -> stop returning -> sweep 829 -> archive -> drop). NOT a DROP.
```

`playerprogression` and `playerrank` are unchanged.

### 2.2 New tables

```sql
-- the variant <-> base + mod registry (84 rows). Global config, no test mirror.
CREATE TABLE weapon_catalog (
    itemid      INT  PRIMARY KEY,                 -- base id (103) or variant id (103701), see §1.3
    base_itemid INT  NOT NULL,                    -- 101..305
    mod_id      INT  NULL REFERENCES weapon_mods(modid),   -- 7xx/8xx/9xx, NULL for the 21 bases
    category    TEXT NOT NULL CHECK (category IN ('primary','utility','melee')),
    name        TEXT NOT NULL
);

CREATE TABLE weapon_mods (                        -- 9 rows, icons already shipped 29 Jul
    modid    INT  PRIMARY KEY,                    -- 701-703 primary · 801-803 utility · 901-903 melee
    name     TEXT NOT NULL,
    description TEXT
);                                                -- class is implied: modid div 100 − 6 == weapon class

-- straight from the spec §4.1-4.5 (unchanged)
championprestige  (champid PK FK, prestige, tier, is_master, matches_ranked, last_ranked_at, decay_applied_at, updated_at)
prestige_tiers    (tier PK, name, min_prestige, requires_top_n)                       -- config
prestige_rewards  (tier PK, bananas, vials)                                           -- config
progression_config(key PK, value NUMERIC, description)                               -- config; also absorbs XP_WIN/LOSS/FLOOR
prestige_payouts  (id, playerid, period, tier, profile_prestige, bananas, vials, paid_at, UNIQUE(playerid, period))
```

### 2.3 Functions / triggers

**`validate_loadout(name)`** (BEFORE UPDATE on `playerloadouts`, exists today) gains, per weapon slot:

```
row  := weapon_catalog[Weapons[i]]                       -- unknown id -> reject
base ∈ playervault.<category>weapons                      -- as today, but on row.base_itemid
row.mod_id IS NULL  OR  row.mod_id ∈ playervault.weaponmods
row.mod_id IS NULL OR row.mod_id div 100 − 6 = row.base_itemid div 100   -- class match (D24)
row.category = category of slot i                         -- primary / utility / melee
```
Champion ownership / uniqueness / totem checks unchanged.

**`initialize_player_associations()`** (AFTER INSERT on `playerprofile`): starter kit **6 items** (Pistol, Blend Gun, Hunting Knife, Grenade, Personal Healing, Turret — ids to reconcile, spec §11) + `skins {1,2,3,4}` + a small banana/vial float, instead of the full range. `weaponmods` starts empty.

### 2.4 The ownership rule (one line, enforced in the trigger and mirrored in the API)

```
equippable(variantId)  ⇔  owns( base(variantId) )  ∧  ( mod(variantId) = NULL ∨ owns( mod(variantId) ) )
```
Granting **Double Tap** = append `701` to `playervault.weaponmods` once → every owned primary can be equipped as its `×1000 + 701` variant. No per-weapon unlock rows, no 84-id vault.

---

## 3. API — target state (`server.js`)

### 3.1 Modified

| Endpoint | Change |
|---|---|
| `POST_MatchResults` | payload gains **`champid` per player** (dedicated-server change, Phase 3). Keeps XP + K/D/A and MMR as today. Adds: prestige Δ → tier → `championprestige`; level-up → grant `reward_id` by `reward_type` into the matching `playervault` array (weapon → base array, **mod → `weaponmods`**, skin → `skins`, banana/vial → counters); `match_history` gets `champid`, `prestige_delta`. |
| `GET_Profile` | + `Bananas`, `Vials`, `ProfilePrestige` (Σ top-5), `PayoutTier` |
| `GET_Vault` | weapon arrays stay **base ids** (the Vault UI lists these, nothing else); + **`WeaponMods: [{ModId, Name}]`** (class = `ModId div 100 − 6`) = the mods the player owns, which the Tuning Table filters by the clicked weapon's category; + `Skins[]`, `Bananas`, `Vials`; each champion + `Prestige`, `Tier`, `IsMaster`, `SkinId`. **Never returns expanded variants.** |
| `POST_SetLoadout` / `POST_SetLoadouts` | `Weapons.{Primary,Utility,Melee}` accept **`{Base, Mod}`** (`Mod` = 0/null for none). The API derives `variantId = Base × 1000 + Mod` (checked against `weapon_catalog` + the class rule), stores the **variant id** in `loadoutN.Weapons[]`, and the trigger (§2.3) enforces base-owned ∧ mod-owned ∧ category. Plain numeric ids stay accepted for backward compatibility. |
| `GET_Loadouts` / `GET_LoadoutByIndex` / `GET_PlayerLoadouts` | `Weapons:[P,U,M]` **stays numeric** (variant ids — the game and the dedicated server parse this into `FWeapons` today, do not change its type). **Add a sibling `WeaponDetails:[{Id, Base, Mod}]`** so the Tuning Table can show "Rifle + Double Tap" without decomposing ids client-side. |

### 3.2 New

| Endpoint | Purpose |
|---|---|
| ~~`GET_WeaponCatalog`~~ | **Not needed by the client under D22/D23** — the catalog is API-internal (derivation + validation). Keep as an `ADMIN_`/debug read at most. Display names/icons come from the client's own DataTables as today. |
| `POST_BoostStat {champid, stat}` | vial → +1 stat; enforces `VIAL_CAP_PER_CHAMPION`, `STAT_MAX`, `vials ≥ 1` (spec §9) |
| `POST_Purchase {itemid}` | bananas → champion or skin (spec §8.5 / D17) |
| `POST_SetChampionSkin {champid, skinid}` | must own the skin |
| `GET_Leaderboard`, `GET_ChampionPrestige` | spec §12.2 |
| `ADMIN_InitializePrestige` | idempotent bootstrap: all §2 DDL, seed `weapon_catalog` (84) + `weapon_mods` (9) + tiers + rewards + config, backfill `skin_id` |
| `ADMIN_RunPrestigeDecay` · `ADMIN_RecomputeMasterTier` · `ADMIN_RunMonthlyPayout?period=` | cron targets (3 Cloud Scheduler jobs) |
| `ADMIN_ResetPrestige` | test env |

### 3.3 Client contract (D23)

```
Vault (W_Vault)              lists BASE weapons from GET_Vault.PrimaryWeapons / SecondaryWeapons / MeleeWeapons
   │ click weapon
   ▼
Tuning Table (TuningTable*)  shows the owned mods of that weapon's class (GET_Vault.WeaponMods filtered by Category);
                             player attaches 0 or 1 mod
   │ save loadout
   ▼
POST_SetLoadout              Weapons: { Primary:{Base:103, Mod:701}, Utility:{Base:201, Mod:0}, Melee:{Base:301, Mod:901} }
   │ API derives variant ids → 103701 / 201 / 301901, trigger validates ownership + class
   ▼
playerloadouts.loadoutN      { Champion, Weapons:[103701, 201, 301901], Totems:[...] }
   │
   ▼
GET_Loadouts (game + UI)     Weapons:[103701,201,301901] for the game (int32, unchanged type) + WeaponDetails:[{Id:103701,Base:103,Mod:701},…] for the Tuning Table
```

The client never computes or stores a variant id; the game never sees a mod. Unlocking a mod at L12 and a new primary at L20 (or the reverse) needs no reconciliation — the Tuning Table simply offers the mod on whatever base weapons the player owns at the time of saving.

---

## 4. Build order (revised phases)

| Phase | Work | VM? |
|---|---|---|
| 1 Economy foundation | `bananas`, `vials`, `progression_config` (+ move XP consts), `GET_Profile`; stop generating custodial wallets | ❌ |
| 2 Catalog + unlocks | `weapon_catalog`, `weapon_mods` (API-internal); `progression_levels` reward columns + enter the table (mods = `reward_type='mod'`); grant-on-level-up in `awardMatch`; shrink `initialize_player_associations()`; ID reconcile | ❌ |
| 3 Loadout variants | `POST_SetLoadout(s)` accept `{Base, Mod}` + derive variant id; `validate_loadout` variant resolution; `GET_Vault.WeaponMods`; `GET_Loadouts*.WeaponDetails` | ❌ |
| 4 Prestige core | `championprestige`, tiers, prestige math in `awardMatch`, `match_history.champid` — **+ dedicated server sends `champid`** | ✅ (payload only) |
| 5 Decay + payouts | 3 `ADMIN_Run*` + `prestige_payouts` + Cloud Scheduler | ❌ |
| 6 Vials + shop + skins backend | `POST_BoostStat`, `POST_Purchase`, `POST_SetChampionSkin`, `skin_id` backfill | ❌ |
| 7 Client — ownership + Tuning Table | `Vault.cpp:103` `AddWeaponSlots`/`AddTotemSlots` from owned base ids; Tuning Table lists owned mods of the class; save sends `{Base, Mod}`; read `WeaponDetails` | ✅ |
| 8 Content — 63 variant assets | Marco: `ID_*` per variant row (and whatever the reference chain needs per mod type — see [[weapon-mods-design]] §1.2 for the asset cost, ~90 assets for the primaries alone) | ✅ (editor) |
| 9 Client — skins / ladder | as spec Phases 8 + 11 | ✅ |

Phases 1–3, 5, 6 need no VM. Phase 8 is the price of D20 and is content, not code.

---

## 5. Open decisions introduced by the pivot

| # | Question | Recommendation |
|---|---|---|
| ~~O24~~ | 🔒 **RESOLVED (D22, 2026-08-26)** — vault stores base ids + owned mods; variants are derived by the API. | — |
| ~~O25~~ | 🔒 **RESOLVED (D24, 2026-08-26)** — blocks WEAPONS 1-3xx / TOTEMS 4-6xx / MODS 7-9xx, variant = base×1000+mod, `weapon_catalog` as runtime truth, client-facing catalog endpoint dropped. | — |
| O26 | Confirm the 21 bases: primaries 101–110 (`106–110` exist as ids but are not grantable today), utility 201–206, melee 301–305. | Reconcile with `DT_AllVaultItems` in the editor before seeding the catalog. |
| O27 | Healing Rounds (802) on a utility weapon needs the effect to reach **team mates** — that is the parked friendly-fire item ([[friendly-fire-how-to]]). | Build 805 last, after the BP team branch exists. |
| O28 | Asset cost of 63 variants: which mod types need only a new `ID_` vs the full `ID_+WID_+AbilitySet_+GA_Fire_+GE_Damage_` chain? | Marco to price per mod type from [[weapon-mods-design]] §1.2 before committing Phase 8. |

---

## 6. The two systems side by side (D25)

| | **Loadout system** | **Champion system** |
|---|---|---|
| Objects | weapons · totems · mods | champions · skins · bananas · vials · prestige / tier · rank (MMR) |
| Ids | offset blocks 1xx–9xx; variant = base×1000+mod | `champid` serial; skins 1..8; consumables are counters |
| Unlocked by | account level (`progression_levels`) | bananas (shop), level rewards (skins 7/8, vials), monthly payout (bananas, vials), ranked play (prestige) |
| Written by | `POST_SetLoadout(s)` → `validate_loadout` | `POST_SetChampionSkin`, `POST_BoostStat`, `POST_Purchase`, `POST_MatchResults` (prestige) |
| Read by the game | `GET_Loadouts*` → one id per slot | champion payload → `skin_id`, stats |
| Meets at | the champion sitting in `loadoutN.Champion` | |
