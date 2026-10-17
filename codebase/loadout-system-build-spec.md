# Loadout system (weapons · totems · mods) + progression unlocks — build spec

> ## ✅ AS-BUILT — 2026-09-09, LIVE on `arcaschampionsapi-test` (commit `a9e370a` on `testing`, verified end-to-end)
>
> The plan below was **built with these deviations**, all decided with Dan on 2026-09-09. Read this block first; the body is the original plan.
>
> | Plan said | Built |
> |---|---|
> | one `playervault.weaponmods INT[]` | **three** columns mirroring the weapon columns: `primarymods` (7xx) · `secondarymods` (8xx) · `meleemods` (9xx) |
> | `bananas` counter on `playervault` | **new table `playerconsumables`** (`playerid PK FK, bananas, vials, updated_at`) + `testplayerconsumables`; 829 rows backfilled; new-player trigger inserts one. Accrue only, nothing spends |
> | `progression_levels.reward_type/id/qty(/name)` | **one column `reward JSONB`**: `{type:'weapon'\|'totem'\|'mod', id}` or `{type:'banana'\|'vial', qty}`; L1 NULL. Every banana row = **10**; scroll + skin rows → bananas; vial rows → `{vial, 1}` |
> | `weapon_catalog` (84) + `weapon_mods` (9) tables | **dropped** — nothing read them; valid ids = reward table + starter kit + the game's ItemDefinitions. Trigger uses class arithmetic only |
> | `POST_SetLoadout(s)` accept `{Base, Mod}`, API derives variant id | **not built** — the client sends the variant id (its asset's `ItemId`, e.g. `101701`) exactly as it sends `101` today. Only change: trigger `RAISE` (P0001) → **400 with the reason** (was 500) |
> | readers add `WeaponDetails {Id, Base, Mod}` | **not built** — `GET_Loadouts` / `GET_LoadoutByIndex` / `GET_PlayerLoadouts` untouched; the client matches `101701` to its own asset |
> | `POST_MatchResults` returns `rewards[]` | body is `Payload: null` (dedicated server never reads it; banner XP is the client-side `ComputeEarnedXP` mirror). Per-player xp/level/rewards go to the **API log** only |
> | `ADMIN_ResetVaults {env, keep:[…]}` (everyone except) | **`{playerids:[…], env}`** (only the named players) — other testers keep full vaults so the current client (shows every DataTable weapon) does not save unowned items and get kicked at match join |
> | starter kit for all new players | **prod new players keep the legacy full vault** (`PROD_NEW_PLAYER_VAULT`) until the client filters the vault by ownership; test new players get the 6-item kit |
>
> **Live verification (2026-09-09, test API):** init idempotent (7 steps, re-run clean) · 5 triggers on `testplayerloadouts` · schema as above · players 11+12 reset to kit · simulated casual win for 11 (40 K / 0 D → +220 xp, L6→L8) granted **203 R-Tree G → `secondaryweapons`** and **+10 bananas → `testplayerconsumables`**; `ADMIN_GrantItem {itemid:701, vials:5}` → `primarymods=[701]`, vials 5.
> ⚠️ **Not yet exercised: a trigger rejection through `POST_SetLoadout`** (needs a player auth token). The same function ran on the reset (happy path) and is the spec §3.4 text verbatim minus the catalog lookup.
>
> **Prod impact of the init (shared schema):** `playervault` + `playerconsumables` columns/rows added (harmless), `validate_loadout` v2 + `initialize_player_associations` v3 are live for prod too (prod vaults are full → ownership passes; new prod players still get the full vault).
>
> **Diagrams** (`arcas-champions/docs/`, mirrored to `drive/`): `weapon-progression-change.drawio.svg` (this change, current vs after) · `level-progression.drawio.svg` (70 levels, ids + names, read from server.js) · `weapon-progression-api-behaviour.drawio.svg` (sequence: save / vault / match end / match join / progression screen / admin) · `weapon-progression-erd.drawio.svg` (full, incl. deferred champion system).
>
> **Next = client phase (§7, needs the VM):** `FVaultData` + 3 `int32` mod arrays · `Vault.cpp:103` filter by owned ids · Tuning Table mod picker writes the variant `ItemId` · `GET_ProgressionRewards` → progression screen · Marco: variant `ID_*` assets with `ItemId = base×1000+mod` + `DT_AllVaultItems` rows for 106-110 / 205-206 / 303-305 (O26) · confirm kit ids 303 / 602.


**Created**: 2026-08-26 · **Status**: ✅ BUILT 2026-09-09 with the deviations in the AS-BUILT block above (original plan text kept below for the reasoning)
**Scope (Dan, 2026-08-26)**: a fully functioning weapon + totem + mod system wired to progression. Bananas **accrue only** (counter). **Out of scope now**: champions, skins, vials, spending, prestige/tiers/decay/payouts, wallet retirement.
**Parent design**: [[progression-db-api-target]] (D20–D25) · [[progression-ranking-spec]] · [[xp-leveling-system]] · [[barracks-vault-flow]]
**Repo**: `repos/ArcasChampionsAPI/server.js` on branch `testing` (auto-deploys to `arcaschampionsapi-test` on push)

---

## 1. Conceptual spec (one screen)

**Objects and ids** (offset scheme, `LoadoutDAO.h`):

```
WEAPONS  1xx primary  101-110      2xx utility 201-206      3xx melee 301-305
TOTEMS   4xx damage   401-403      5xx personal 501-504     6xx support 601-603
MODS     7xx primary  701-703      8xx utility  801-803     9xx melee   901-903
variant = base × 1000 + mod        103 + 701 = 103701       mod fits base ⇔ mod div 100 − 6 = base div 100
```

**Ownership** = `playervault`: six existing arrays (base weapons + totems) **+ `weaponmods INT[]`** **+ `bananas INT`**. Nothing per-variant is stored per player.

**Loadout** = `playerloadouts.loadoutN` JSONB `{Champion, Weapons:[P,U,M], Totems:[D,P,S]}` — unchanged shape; `Weapons[]` may hold a **variant id**. The game reads it as one weapon id (int32 everywhere it is parsed, verified).

**Flow**: Vault lists base weapons → Tuning Table attaches one owned mod of the class → `POST_SetLoadout` receives `{Base, Mod}` → **API derives the variant id** → trigger validates base owned ∧ mod owned ∧ class ∧ variant exists → stored → `GET_Loadouts*` returns `Weapons` (numeric, for the game) + `WeaponDetails` (`{Id, Base, Mod}`, for the UI).

**Progression**: `progression_levels` gains `reward_type / reward_id / reward_qty`. On level-up `awardMatch` grants each reward for the levels crossed: weapon/totem/mod → append to the matching vault array (idempotent), banana → `bananas += qty`. New players start with the **6-item starter kit**; everything else is earned.

**Invariant**: unlock order never matters — equippability is computed from two owned sets at save time.

---

## 2. What the read pass found (facts the changes are built on)

| # | Fact | Where | Consequence |
|---|---|---|---|
| F1 | `POST_SetLoadout(s)` accept `{Champion:{ChampId}, Weapons:{Primary,Utility,Melee}, Totems:{Damage,Personal,Support}}`, all slots `number`, and store `Weapons:[P,U,M]` | `server.js:856-1123` | add `{Base, Mod}` acceptance per slot; keep numbers working |
| F2 | The three loadout readers rebuild `Weapons` as `{Primary,Utility,Melee}` from the array in SQL | `:600-642`, `:733-763`, `:1573-1615` | add a sibling `WeaponDetails` in the same `jsonb_set` chain |
| F3 | `POST_ValidatePlayerLoadout` compares the server's submitted loadout with the stored one **as plain ints** | `:1643-1819` | variant ids round-trip unchanged → **no change needed** |
| F4 | **`testplayerloadouts` / `testchampions` have NO triggers** (`LIKE … INCLUDING ALL` copies no triggers). Verified live via `ADMIN_ViewTriggers` | — | the test API has had **zero loadout validation**; new function must be table-aware (`TG_TABLE_NAME`) and be installed on both tables |
| F5 | Live `validate_loadout()` hardcodes `Champions` / `PlayerVault` and **returns early when `Champion IS NULL`** (weapons/totems then go unvalidated) | live source | rewrite; validate items regardless of champion |
| F6 | `initialize_player_associations()` is `CREATE OR REPLACE`d in **two** endpoints (`ADMIN_InitializeTestInfrastructure:1955`, `ADMIN_InitializeProgression:2169`) with the full item range | — | centralise the body in one JS constant, otherwise re-running either endpoint reverts the starter kit |
| F7 | `awardMatch` already returns `leveled_up` per player and its `before` CTE has `old_level`, not exposed | `:1330-1362` | expose `old_level`; grant rewards for `(old_level, level]` |
| F8 | `playerloadouts.loadoutN` column default = `{Weapons:[101,201,301], Totems:[401,501,601]}` | live schema | must change to the starter kit (`301`→`303`, `601`→`602`) or new players' default loadout references items they don't own |
| F9 | `GET_Profile` reads `SELECT pp.*, pr.Rank, prog.total_xp, prog.level` via `queryProfile()` | `:172-180` | add `pv.bananas` to the join to expose `Bananas` |
| F10 | `ADMIN_InitializeProgression` re-seeds the curve with `ON CONFLICT DO UPDATE SET xp_required` | `:2131-2137` | safe: preserves the new reward columns |
| F11 | Design sheet `drive/Old Stuff/ArcasChampion Progression.xlsx` → "Player Profile EXP" has rewards for L1–L75 (§5) | — | map to 70 levels; scrolls/vials/skins → bananas for now |
| F12 | Items that never appear in the sheet as unlocks: **105 Banana Pistol**. Item with no id: **Vine Whip (L55)** | sheet + `game-object-model` §7 | proposal in §5 |

---

## 3. Database — exact changes (all inside one new idempotent endpoint `ADMIN_InitializeLoadoutSystem`, §4.8)

### 3.1 Columns

```sql
ALTER TABLE playervault     ADD COLUMN IF NOT EXISTS weaponmods INT[] NOT NULL DEFAULT '{}';
ALTER TABLE playervault     ADD COLUMN IF NOT EXISTS bananas    INT   NOT NULL DEFAULT 0;
ALTER TABLE testplayervault ADD COLUMN IF NOT EXISTS weaponmods INT[] NOT NULL DEFAULT '{}';
ALTER TABLE testplayervault ADD COLUMN IF NOT EXISTS bananas    INT   NOT NULL DEFAULT 0;

ALTER TABLE progression_levels ADD COLUMN IF NOT EXISTS reward_type TEXT;            -- weapon | totem | mod | banana
ALTER TABLE progression_levels ADD COLUMN IF NOT EXISTS reward_id   INT;             -- offset-scheme id, NULL for banana
ALTER TABLE progression_levels ADD COLUMN IF NOT EXISTS reward_qty  INT NOT NULL DEFAULT 1;
```

### 3.2 Config tables + seeds (global, no test mirror)

```sql
CREATE TABLE IF NOT EXISTS weapon_mods (
    modid       INT  PRIMARY KEY,          -- 701-703 · 801-803 · 901-903
    name        TEXT NOT NULL,
    description TEXT
);
INSERT INTO weapon_mods (modid, name) VALUES
  (701,'Double Tap'),(702,'High Damage Rounds'),(703,'High Capacity Mag'),
  (801,'Fire Rounds'),(802,'Healing Rounds'),(803,'Demolition Rounds'),
  (901,'Lucky Strike'),(902,'Berserk Boost'),(903,'Resourceful')
ON CONFLICT (modid) DO UPDATE SET name = EXCLUDED.name;

CREATE TABLE IF NOT EXISTS weapon_catalog (
    itemid      INT  PRIMARY KEY,          -- 103 or 103701
    base_itemid INT  NOT NULL,
    mod_id      INT  REFERENCES weapon_mods(modid),
    name        TEXT NOT NULL
);
-- 21 bases (design-sheet ids) × class mods → 84 rows
WITH base(itemid, name) AS (VALUES
  (101,'Pistol'),(102,'Twin Barrel'),(103,'Melon Rifle'),(104,'Send a Prayer'),(105,'Banana Pistol'),
  (106,'Mad Rifle'),(107,'Mad SMG'),(108,'Nail SMG'),(109,'Plasma Shotgun'),(110,'Alien Railgun'),
  (201,'Blend Gun'),(202,'Potato Gun'),(203,'R-Tree G'),(204,'Trap Launcher'),(205,'Madzooka'),(206,'Mad Vacuum'),
  (301,'Machete'),(302,'Relic Sword'),(303,'Hunting Knife'),(304,'Axe'),(305,'Spear'))
INSERT INTO weapon_catalog (itemid, base_itemid, mod_id, name)
SELECT itemid, itemid, NULL, name FROM base
UNION ALL
SELECT b.itemid * 1000 + m.modid, b.itemid, m.modid, b.name || ' + ' || m.name
FROM base b JOIN weapon_mods m ON m.modid / 100 - 6 = b.itemid / 100
ON CONFLICT (itemid) DO UPDATE SET name = EXCLUDED.name;
```

### 3.3 Level reward table — see §5 for the 70 rows; applied as
```sql
UPDATE progression_levels SET reward_type = $2, reward_id = $3, reward_qty = $4 WHERE level = $1;   -- per row
```

### 3.4 `validate_loadout()` v2 — table-aware, validates items even without a champion

```sql
CREATE OR REPLACE FUNCTION validate_loadout()
RETURNS TRIGGER AS $$
DECLARE
    p          TEXT := CASE WHEN TG_TABLE_NAME LIKE 'test%' THEN 'test' ELSE '' END;
    loadout    JSONB;
    champ_id   INT;
    champ_ok   BOOLEAN;
    weapon_ids INT[];
    totem_ids  INT[];
    v INT; base INT; modid INT; i INT;
    owned_p INT[]; owned_u INT[]; owned_m INT[];
    owned_d INT[]; owned_s INT[]; owned_t INT[]; owned_mods INT[];
    slot_ok BOOLEAN;
BEGIN
    CASE TG_ARGV[0]
        WHEN 'Loadout1' THEN loadout := NEW.loadout1;
        WHEN 'Loadout2' THEN loadout := NEW.loadout2;
        WHEN 'Loadout3' THEN loadout := NEW.loadout3;
        WHEN 'Loadout4' THEN loadout := NEW.loadout4;
        WHEN 'Loadout5' THEN loadout := NEW.loadout5;
        ELSE RAISE EXCEPTION 'Invalid loadout specified in trigger';
    END CASE;

    champ_id   := (loadout->>'Champion')::INT;
    weapon_ids := ARRAY[(loadout->'Weapons'->>0)::INT, (loadout->'Weapons'->>1)::INT, (loadout->'Weapons'->>2)::INT];
    totem_ids  := ARRAY[(loadout->'Totems'->>0)::INT,  (loadout->'Totems'->>1)::INT,  (loadout->'Totems'->>2)::INT];

    -- Champion: owned + unpacked, and not in another loadout (unchanged rules, now on the right table)
    IF champ_id IS NOT NULL THEN
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I WHERE champid = $1 AND playerowner = $2 AND championinitialised AND championunpacked)', p || 'champions')
            INTO champ_ok USING champ_id, NEW.playerid;
        IF NOT champ_ok THEN
            RAISE EXCEPTION 'Champion % is not owned by Player %', champ_id, NEW.playerid;
        END IF;
        IF ((NEW.loadout1->>'Champion')::INT = champ_id AND TG_ARGV[0] <> 'Loadout1') OR
           ((NEW.loadout2->>'Champion')::INT = champ_id AND TG_ARGV[0] <> 'Loadout2') OR
           ((NEW.loadout3->>'Champion')::INT = champ_id AND TG_ARGV[0] <> 'Loadout3') OR
           ((NEW.loadout4->>'Champion')::INT = champ_id AND TG_ARGV[0] <> 'Loadout4') OR
           ((NEW.loadout5->>'Champion')::INT = champ_id AND TG_ARGV[0] <> 'Loadout5') THEN
            RAISE EXCEPTION 'Champion % is already selected in another loadout for Player %', champ_id, NEW.playerid;
        END IF;
    END IF;

    EXECUTE format('SELECT primaryweapons, secondaryweapons, meleeweapons, damagetotems, utilitytotems, supertotems, weaponmods FROM %I WHERE playerid = $1', p || 'playervault')
        INTO owned_p, owned_u, owned_m, owned_d, owned_s, owned_t, owned_mods USING NEW.playerid;

    -- Weapons: slot i must hold a class-i weapon (1xx / 2xx / 3xx), owned; optional mod of the same class, owned
    FOR i IN 1..3 LOOP
        v := weapon_ids[i];
        IF v IS NULL THEN RAISE EXCEPTION 'Weapon slot % is empty in %', i, TG_ARGV[0]; END IF;
        base  := CASE WHEN v >= 1000 THEN v / 1000 ELSE v END;
        modid := CASE WHEN v >= 1000 THEN v % 1000 ELSE NULL END;
        IF base / 100 <> i THEN
            RAISE EXCEPTION 'Weapon % is not valid for slot % in %', v, i, TG_ARGV[0];
        END IF;
        slot_ok := CASE i WHEN 1 THEN base = ANY(owned_p) WHEN 2 THEN base = ANY(owned_u) ELSE base = ANY(owned_m) END;
        IF NOT COALESCE(slot_ok, FALSE) THEN
            RAISE EXCEPTION 'Weapon % is not owned by Player %', base, NEW.playerid;
        END IF;
        IF modid IS NOT NULL THEN
            IF modid / 100 - 6 <> base / 100 THEN
                RAISE EXCEPTION 'Mod % does not fit weapon %', modid, base;
            END IF;
            IF NOT COALESCE(modid = ANY(owned_mods), FALSE) THEN
                RAISE EXCEPTION 'Mod % is not owned by Player %', modid, NEW.playerid;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM weapon_catalog WHERE itemid = v) THEN
                RAISE EXCEPTION 'Unknown weapon variant %', v;
            END IF;
        END IF;
    END LOOP;

    -- Totems: slot i must hold a class-(i+3) totem (4xx / 5xx / 6xx), owned
    FOR i IN 1..3 LOOP
        v := totem_ids[i];
        IF v IS NULL THEN RAISE EXCEPTION 'Totem slot % is empty in %', i, TG_ARGV[0]; END IF;
        IF v / 100 <> i + 3 THEN
            RAISE EXCEPTION 'Totem % is not valid for slot % in %', v, i, TG_ARGV[0];
        END IF;
        slot_ok := CASE i WHEN 1 THEN v = ANY(owned_d) WHEN 2 THEN v = ANY(owned_s) ELSE v = ANY(owned_t) END;
        IF NOT COALESCE(slot_ok, FALSE) THEN
            RAISE EXCEPTION 'Totem % is not owned by Player %', v, NEW.playerid;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Behaviour changes vs today, deliberate: (a) validates against the **calling table's** vault/champions (prod or test); (b) weapons/totems are validated **even when no champion is set**; (c) slot/class mismatch and empty slots are rejected (today `[301, 201, 101]` would pass if all three are owned).

### 3.5 Triggers on the test table (missing today — F4)

```sql
DO $$ BEGIN
  FOR i IN 1..5 LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS validate_loadout%s_trigger ON testplayerloadouts', i);
    EXECUTE format('CREATE TRIGGER validate_loadout%s_trigger BEFORE UPDATE ON testplayerloadouts FOR EACH ROW EXECUTE FUNCTION validate_loadout(''Loadout%s'')', i, i);
  END LOOP;
END $$;
```
(Prod triggers already exist and pick up the replaced function automatically.)

### 3.6 Starter kit — `initialize_player_associations()` v3 + loadout defaults

Starter kit (settled by two independent sources, `game-object-model` §7): **Pistol 101 · Blend Gun 201 · Hunting Knife 303 · Grenade 401 · Personal Healing 501 · Turret 602**.

```sql
CREATE OR REPLACE FUNCTION initialize_player_associations()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO playervault (playerid, primaryweapons, secondaryweapons, meleeweapons, damagetotems, utilitytotems, supertotems, weaponmods, bananas)
    VALUES (NEW.playerid, ARRAY[101], ARRAY[201], ARRAY[303], ARRAY[401], ARRAY[501], ARRAY[602], '{}', 0);
    INSERT INTO playerloadouts   (playerid) VALUES (NEW.playerid);
    INSERT INTO playerrank       (playerid) VALUES (NEW.playerid);
    INSERT INTO playerprogression(playerid) VALUES (NEW.playerid);

    INSERT INTO testplayervault (playerid, primaryweapons, secondaryweapons, meleeweapons, damagetotems, utilitytotems, supertotems, weaponmods, bananas)
    VALUES (NEW.playerid, ARRAY[101], ARRAY[201], ARRAY[303], ARRAY[401], ARRAY[501], ARRAY[602], '{}', 0);
    INSERT INTO testplayerloadouts   (playerid) VALUES (NEW.playerid);
    INSERT INTO testplayerrank       (playerid) VALUES (NEW.playerid);
    INSERT INTO testplayerprogression(playerid) VALUES (NEW.playerid);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- default loadout must reference the kit (F8)
ALTER TABLE playerloadouts     ALTER COLUMN loadout1 SET DEFAULT '{"Champion": null, "Weapons": [101, 201, 303], "Totems": [401, 501, 602]}'::jsonb;
-- … same for loadout2..5 and for testplayerloadouts
```
This body becomes the JS constant `INIT_PLAYER_ASSOCIATIONS_SQL` and replaces the copies at `server.js:1955` and `:2169` (F6).

### 3.7 Existing players (data policy)

- **Prod**: grandfathered — nobody loses items; `weaponmods = {}`, `bananas = 0` by column default. Level rewards for items they already own are no-ops.
- **Test**: reset to the starter kit so unlocks are testable — via `ADMIN_ResetVaults` (§4.8), with a `keep` list, same pattern as `ADMIN_ResetProgression`. It also resets loadouts to the new default so no stored loadout references un-owned items.

---

## 4. API — exact changes (`server.js`)

### 4.1 Helpers (new, near the XP constants ~`:1286`)

```js
// ---- Loadout system: weapon variants ------------------------------------------------
// variant = base * 1000 + mod (103 + 701 -> 103701). A plain base id is its own "variant".
function weaponSlotToId(slot) {
    if (typeof slot === 'number') return slot;                                   // legacy / already an id
    if (slot && typeof slot === 'object' && typeof slot.Base === 'number') {
        const mod = Number(slot.Mod) || 0;
        return mod > 0 ? slot.Base * 1000 + mod : slot.Base;
    }
    return NaN;
}
function weaponIdParts(id) {
    const n = Number(id) || 0;
    return n >= 1000 ? { Id: n, Base: Math.floor(n / 1000), Mod: n % 1000 } : { Id: n, Base: n, Mod: 0 };
}
// Which vault column an offset-scheme id lands in (by hundreds digit).
const VAULT_COLUMN_BY_CLASS = { 1: 'primaryweapons', 2: 'secondaryweapons', 3: 'meleeweapons',
                                4: 'damagetotems', 5: 'utilitytotems', 6: 'supertotems',
                                7: 'weaponmods', 8: 'weaponmods', 9: 'weaponmods' };
async function grantItem(playerid, itemid) {
    const col = VAULT_COLUMN_BY_CLASS[Math.floor(itemid / 100)];
    if (!col) throw new Error(`grantItem: ${itemid} is not an offset-scheme id`);
    const r = await pool.query(
        `UPDATE ${TABLE_PREFIX}playervault SET ${col} = array_append(${col}, $2)
         WHERE playerid = $1 AND NOT ($2 = ANY(${col})) RETURNING playerid`, [playerid, itemid]);
    return r.rowCount > 0;   // false = already owned
}
async function grantBananas(playerid, qty) {
    await pool.query(`UPDATE ${TABLE_PREFIX}playervault SET bananas = bananas + $2 WHERE playerid = $1`, [playerid, qty]);
}
// Grant every reward for levels in (fromLevel, toLevel]. Returns what was granted.
async function grantLevelRewards(playerid, fromLevel, toLevel) {
    const rows = await pool.query(
        `SELECT level, reward_type, reward_id, reward_qty FROM progression_levels
         WHERE level > $1 AND level <= $2 AND reward_type IS NOT NULL ORDER BY level`, [fromLevel, toLevel]);
    const granted = [];
    for (const r of rows.rows) {
        if (r.reward_type === 'banana') await grantBananas(playerid, r.reward_qty);
        else await grantItem(playerid, r.reward_id);
        granted.push({ level: r.level, type: r.reward_type, id: r.reward_id, qty: r.reward_qty });
    }
    return granted;
}
```

### 4.2 `GET_Vault` (`:484-520`) — add mods + bananas to the CTE and the payload

```diff
             Vault AS (
                 SELECT
                     pv.PrimaryWeapons,
                     pv.SecondaryWeapons,
                     pv.MeleeWeapons,
                     pv.DamageTotems,
                     pv.UtilityTotems,
-                    pv.SuperTotems
+                    pv.SuperTotems,
+                    pv.WeaponMods,
+                    pv.Bananas
                 FROM ${TABLE_PREFIX}PlayerVault pv
 …
                 'SuperTotems', (SELECT SuperTotems FROM Vault),
+                'WeaponMods', (SELECT WeaponMods FROM Vault),
+                'Bananas', (SELECT Bananas FROM Vault),
                 'Champions', (SELECT json_agg(row_to_json(pc)) FROM PlayerChampions pc)
```
`WeaponMods` is a plain `int[]` like the other six arrays (the client filters by class with `mod div 100 − 6`; names come from its DataTables).

### 4.3 `POST_SetLoadout` (`:904-947`) and `POST_SetLoadouts` (`:1031-1068`) — accept `{Base, Mod}` per weapon slot

```diff
-        // Check Weapons structure
-        if (!loadout.Weapons || typeof loadout.Weapons !== 'object' ||
-            !('Melee' in loadout.Weapons) || !('Utility' in loadout.Weapons) || !('Primary' in loadout.Weapons) ||
-            typeof loadout.Weapons.Melee !== 'number' || typeof loadout.Weapons.Utility !== 'number' || typeof loadout.Weapons.Primary !== 'number') {
+        // Check Weapons structure: each slot is a number (id) or {Base, Mod}
+        const wP = weaponSlotToId(loadout.Weapons?.Primary);
+        const wU = weaponSlotToId(loadout.Weapons?.Utility);
+        const wM = weaponSlotToId(loadout.Weapons?.Melee);
+        if (!loadout.Weapons || [wP, wU, wM].some(Number.isNaN)) {
             return res.status(400).json({ "bSuccess": false, "Error": "Wrong loadout structure" });
         }
 …
-            Weapons: [ loadout.Weapons.Primary, loadout.Weapons.Utility, loadout.Weapons.Melee ],
+            Weapons: [ wP, wU, wM ],
```
Error mapping (`:975`, `:1111`): the trigger's `RAISE EXCEPTION` arrives as `error.code === 'P0001'` — map it to **400 with `error.message`** next to the existing `23514` case, so the client gets "Mod 701 does not fit weapon 201" instead of a 500.

### 4.4 `GET_Loadouts` (`:600-642`), `GET_LoadoutByIndex` (`:746-763`), `GET_PlayerLoadouts` (`:1573-1615`) — add `WeaponDetails`

One more `jsonb_set` in each chain (same expression, three places):

```sql
jsonb_set( <existing expression>, '{WeaponDetails}',
    json_build_object(
        'Primary', json_build_object('Id', w0, 'Base', CASE WHEN w0 >= 1000 THEN w0 / 1000 ELSE w0 END, 'Mod', CASE WHEN w0 >= 1000 THEN w0 % 1000 ELSE 0 END),
        'Utility', json_build_object('Id', w1, 'Base', CASE WHEN w1 >= 1000 THEN w1 / 1000 ELSE w1 END, 'Mod', CASE WHEN w1 >= 1000 THEN w1 % 1000 ELSE 0 END),
        'Melee',   json_build_object('Id', w2, 'Base', CASE WHEN w2 >= 1000 THEN w2 / 1000 ELSE w2 END, 'Mod', CASE WHEN w2 >= 1000 THEN w2 % 1000 ELSE 0 END)
    )::jsonb )
-- where w0/w1/w2 = (value->'Weapons'->0)::text::int etc. (the same expressions the existing Weapons block uses)
```
`Weapons.{Primary,Utility,Melee}` stays **numeric** — the game and the dedicated server parse it into `FWeapons` (int32) today.

### 4.5 `awardMatch` (`:1360`, `:1409-1418`) — expose `old_level`, grant rewards

```diff
-        SELECT u.playerid, u.total_xp, u.level, u.pending_levelup, (u.level > b.old_level) AS leveled_up
+        SELECT u.playerid, u.total_xp, u.level, u.pending_levelup, b.old_level, (u.level > b.old_level) AS leveled_up
 …
     const xpResult = await pool.query(xpQuery, [allPlayers, awardAmounts]);
+
+    // Level rewards: for every level crossed, grant the row's reward into the vault (idempotent).
+    const rewardsByPlayer = {};
+    for (const r of xpResult.rows) {
+        if (r.leveled_up) {
+            try { rewardsByPlayer[r.playerid] = await grantLevelRewards(r.playerid, r.old_level, r.level); }
+            catch (e) { console.error(`level rewards failed for ${r.playerid} (non-fatal):`, e.message); rewardsByPlayer[r.playerid] = []; }
+        }
+    }
 …
         leveled_up: r.leveled_up,
+        rewards: rewardsByPlayer[r.playerid] || [],
```
Non-fatal by design (same stance as `match_history`): XP must never fail because a grant did.

### 4.6 `GET_Profile` — `Bananas`

`queryProfile()` (`:174-179`): `LEFT JOIN ${TABLE_PREFIX}playervault pv ON pp.PlayerID = pv.PlayerID` and select `pv.bananas`. Both response objects (`:410`, `:429`) gain `Bananas: profile.bananas ?? 0` / `Bananas: 0`.

### 4.7 New public endpoint `GET_ProgressionRewards` (auth like `GET_Profile`)

Returns the level table for the client's progression screen — `[{Level, XpRequired, RewardType, RewardId, RewardQty}]` from `progression_levels ORDER BY level`. Read-only, cacheable client-side.

### 4.8 New admin endpoints (`requireAdminKey`)

| Endpoint | Body | Does |
|---|---|---|
| `POST ADMIN_InitializeLoadoutSystem` | — | idempotent: §3.1 columns → §3.2 tables + seeds → §3.3 reward rows → §3.4 function → §3.5 test triggers → §3.6 trigger fn + loadout defaults. Returns the step log + a catalog/reward sample. |
| `POST ADMIN_ResetVaults` | `{ env: "test"\|"prod"\|"both" (default test), keep: [ids] }` | vault → starter kit, `weaponmods={}`, `bananas=0`, loadouts → default, for all players except `keep` |
| `POST ADMIN_GrantItem` | `{ playerid, itemid?, bananas?, env? }` | manual grant for testing (uses `grantItem` / `grantBananas`) |
| `GET ADMIN_GetVault?playerid=` | — | prod + test vault rows (mirrors `ADMIN_GetProgression`) |

`ADMIN_ViewTriggers` (`:2058`): add `'validate_loadout'` is already listed; nothing to add.

---

## 5. Level reward table (design sheet → 70 levels)

Source: `drive/Old Stuff/ArcasChampion Progression.xlsx` → "Player Profile EXP". Substitutions for this phase: **Ancient Scroll → 50 bananas** (scrolls are cut, D17), **Suspicious Vial → 50 bananas**, **skin → 100 bananas** (placeholders until the champion system lands; data-only, retune anytime). Level 1 = start (no reward). Sheet levels 71–75 dropped (cap is 70; only L75 "200 bananas" was there).

| L | Reward | type / id / qty | L | Reward | type / id / qty |
|---|---|---|---|---|---|
| 2 | (vial) | banana · 50 | 37 | (scroll) | banana · 50 |
| 3 | Melon Rifle | weapon · 103 | 38 | Plasma Shotgun | weapon · 109 |
| 4 | 50 bananas | banana · 50 | 39 | (vial) | banana · 50 |
| 5 | High Cap Mag (P) | mod · 703 | 40 | (Bas Sentinel skin) | banana · 100 |
| 6 | Ammo Box Totem | totem · 502 | 41 | Mad Vacuum | weapon · 206 |
| 7 | R-Tree G | weapon · 203 | 42 | Berserk Boost (M) | mod · 902 |
| 8 | (scroll) | banana · 50 | 43 | 150 bananas | banana · 150 |
| 9 | (vial) | banana · 50 | 44 | Chimp Companion | totem · 603 |
| 10 | Machete | weapon · 301 | 45 | Mad Rifle | weapon · 106 |
| 11 | (scroll) | banana · 50 | 46 | (vial) | banana · 50 |
| 12 | Healing Rounds (S) | mod · 802 | 47 | (scroll) | banana · 50 |
| 13 | 100 bananas | banana · 100 | 48 | Madzooka | weapon · 205 |
| 14 | Twin Barrel | weapon · 102 | 49 | High Damage Rounds (P) | mod · 702 |
| 15 | (Alpha skin) | banana · 100 | 50 | (vial) | banana · 50 |
| 16 | Team Healing Totem | totem · 601 | 51 | (scroll) | banana · 50 |
| 17 | Trap Launcher | weapon · 204 | 52 | Mad SMG | weapon · 107 |
| 18 | Resourceful (M) | mod · 903 | 53 | 150 bananas | banana · 150 |
| 19 | (vial) | banana · 50 | 54 | Lucky Strike (M) | mod · 901 |
| 20 | 100 bananas | banana · 100 | 55 | ⚠️ Vine Whip → **Banana Pistol** | weapon · **105** (see F12) |
| 21 | Axe | weapon · 304 | 56 | Animal Instinct | totem · 503 |
| 22 | (scroll) | banana · 50 | 57 | (vial) | banana · 50 |
| 23 | 100 bananas | banana · 100 | 58 | (Alpha Premium skin) | banana · 100 |
| 24 | Nail SMG | weapon · 108 | 59 | "A Banana" | banana · 1 |
| 25 | Double Tap (P) | mod · 701 | 60 | (scroll) | banana · 50 |
| 26 | SuperCharge Totem | totem · 402 | 61 | (vial) | banana · 50 |
| 27 | Potato Gun | weapon · 202 | 62 | Relic Sword | weapon · 302 |
| 28 | (scroll) | banana · 50 | 63 | Fire Rounds (S) | mod · 801 |
| 29 | (vial) | banana · 50 | 64 | (scroll) | banana · 50 |
| 30 | 150 bananas | banana · 150 | 65 | (vial) | banana · 50 |
| 31 | Send a Prayer | weapon · 104 | 66 | Alien Railgun | weapon · 110 |
| 32 | (scroll) | banana · 50 | 67 | Rage Totem | totem · 403 |
| 33 | Demolition Rounds (S) | mod · 803 | 68 | (scroll) | banana · 50 |
| 34 | Spear | weapon · 305 | 69 | 200 bananas | banana · 200 |
| 35 | Disguise Totem | totem · 504 | 70 | (Bas Sentinel Premium) | banana · 200 |
| 36 | (vial) | banana · 50 | | | |

Coverage check: every non-kit weapon (102–110, 202–206, 301, 302, 304, 305), every non-kit totem (402, 403, 502–504, 601, 603) and all 9 mods appear exactly once. **F12**: the sheet never unlocks Banana Pistol (105) and lists Vine Whip (no id, no asset confirmed) at L55 — proposal: L55 → 105, Vine Whip parked until Marco confirms an asset (would become 306).

Starter kit ids to confirm in the editor: **303 = Hunting/Combat Knife** in `DT_AllVaultItems` (live vaults grant only 301–302 today), **602 = Turret**.

---

## 6. Test plan (test API, after deploy)

1. `POST ADMIN_InitializeLoadoutSystem` → step log; `GET ADMIN_ViewTriggers` shows 5 triggers on `testplayerloadouts`; `GET ADMIN_ViewSchema` shows the new columns.
2. `POST ADMIN_ResetVaults {env:"test", keep:[11,12]}` → `GET ADMIN_GetVault?playerid=<x>` = starter kit.
3. `POST_SetLoadout?index=1` with `Weapons.Primary = {Base:101, Mod:701}` → **400 "Mod 701 is not owned"**. With `{Base:103, Mod:0}` → **400 "Weapon 103 is not owned"**. With kit ids → 200.
4. `POST ADMIN_GrantItem {playerid, itemid:701}` + `{itemid:103}` → `SetLoadout {Base:103, Mod:701}` → 200; `GET_LoadoutByIndex` shows `Weapons.Primary = 103701` and `WeaponDetails.Primary = {Id:103701, Base:103, Mod:701}`; `{Base:201, Mod:701}` → 400 "does not fit".
5. `POST_MatchResults` (server token) with a player at L4 winning enough for L5 → payload `rewards: [{level:5, type:'mod', id:703}]`; vault `weaponmods` contains 703; `GET_Profile.Bananas` reflects L2/L4 bananas if crossed.
6. `GET_PlayerLoadouts?playerId=` (server) returns the variant id → `POST_ValidatePlayerLoadout` with the same object → `bSuccess:true` (F3).
7. Re-run `ADMIN_InitializeLoadoutSystem` → no errors, no duplicate rows (idempotency).

---

## 7. Client plan (after the API is live — separate step, needs the VM)

1. `FVaultData`: add `TArray<int32> WeaponMods` + `int32 Bananas`; `FGetVaultRequest::ParseResponse` reads them.
2. `Vault.cpp:103`: implement the commented `AddWeaponSlots` / `AddTotemSlots` — filter `DT_AllVaultItems` rows by owned ids (base only). Locked-item state for the rest.
3. Tuning Table: list `WeaponMods` where `mod/100 − 6 == base/100`; one selectable; write `{Base, Mod}` into the loadout save request (`FSetLoadoutRequest` body: `Weapons.Primary` becomes an object).
4. Loadout readers: parse `WeaponDetails` for display; keep parsing `Weapons` for gameplay.
5. Progression screen: `GET_ProgressionRewards` → replace / feed `DT_PlayerProgressionItems`.
6. Content (Marco): 63 variant `ID_*` assets with `ItemId` = variant id, + `DT_AllVaultItems` rows for 106–110 / 205–206 / 303–305 (**O26**).
7. Dedicated server: nothing — it already receives the id it must load.

---

## 8. Decisions needed before applying

| # | Question | Default if you say "go" |
|---|---|---|
| Q1 | Substitutions in §5 (scroll/vial → 50 bananas, skin → 100/200 bananas) | as listed |
| Q2 | L55: Banana Pistol (105) instead of Vine Whip | yes |
| Q3 | `validate_loadout` now validates weapons/totems **even with no champion**, and rejects slot/class mismatches (F5, §3.4) | yes |
| Q4 | `GET_Vault.WeaponMods` as a plain `int[]` (not `[{ModId, Name}]`) | plain ints |
| Q5 | Test env: reset all vaults to the starter kit except a keep-list (`ADMIN_ResetVaults`) | keep `[11, 12]` (the XP test players) |
| Q6 | Prod: grandfather (nobody loses items) | yes |
| Q7 | Deploy path: commit on `testing` → git trigger → `arcaschampionsapi-test`; run `ADMIN_InitializeLoadoutSystem` once against test only | yes; prod untouched until you say so |
