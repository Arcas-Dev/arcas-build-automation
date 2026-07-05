# Barracks / Vault → Weapons → Loadout — Current State

**Created**: 2026-06-28 (deep-dive, task 1 of progression-system investigation)
**Scope**: How the Barracks Vault UI gets weapons/totems and how it relates to `GET_Vault`. Read-only investigation, no code changed.
**Related**: [[progression-system-plan]], `database-structure.md`

---

## TL;DR (the key finding)

**`GET_Vault` IS called, but its weapon/totem arrays are fetched and then thrown away.** The Vault UI shows weapons/totems from a **local DataTable** (`DT_AllVaultItems`), not from the player's backend-owned IDs. Only **Champions** from the API response are actually used.

The per-player filtering code exists only as a commented-out TODO. This is the exact seam where the progression "gameplay unlocks" feature must plug in.

---

## End-to-end flow (as built)

```
API  GET_Vault  →  returns { PrimaryWeapons[], SecondaryWeapons[], MeleeWeapons[],
                              DamageTotems[], UtilityTotems[], SuperTotems[], Champions[] }
                              (six TArray<uint8> ID lists + champions)
        │
        ▼
C++  FGetVaultRequest (Backend/Requests/BAS/GetVaultRequest.cpp)
        SetURI("GET_Vault") → ParseResponse → FVaultData   (VaultData.h: 6× TArray<uint8> + TArray<FChampion>)
        │
        ▼
C++  UVault widget (UI/Menu/Barracks/Vault.cpp)  ← parent class of Blueprint W_Vault
        PopulateVault():
          GetVaultFromBackend();                       // async, fills CHAMPIONS only
          ItemsDataTable->GetAllRows(Rows);            // DT_AllVaultItems (LOCAL)
          AddPrimaryWeapons(Rows[0]);                  // Row 0 = primaries
          AddSecondaryWeapons(Rows[1]);                // Row 1 = secondaries
          AddMeleeWeapons(Rows[2]);                    // Row 2 = melee
          AddTotems(Rows[3]);                          // Row 3 = totems
        │
        ▼
UI   Each row's .Elements (FVaultSlotItem[]) → one VaultSlotButton per item where
     `bShouldBeSelectedFromVault == true`. Click → OnVaultItemClicked → Barracks assembles loadout.
```

### The discarded-data smoking gun (`Vault.cpp::GetVaultFromBackend`)
```cpp
if (bSuccess)
{
    AddChampionsSlots(Request->GetVault().Champions);     // ← ONLY champions used

    /* TODO: AddWeaponSlots and AddTotemSlots ez.:
    AddWeaponSlots(Request->GetVault().PrimaryWeapons, ...SecondaryWeapons, ...MeleeWeapons);
    AddTotemSlots(Request->GetVault().DamageTotems, ...UtilityTotems, ...SuperTotems);
    */
}
```
→ The vault's weapon/totem IDs (101-105, 201-204, …) are received but **never read**. Weapons shown = whatever is in `DT_AllVaultItems` with `bShouldBeSelectedFromVault=true`. Since the DB bootstrap grants everyone the full ID range anyway, nobody notices today — everyone has everything.

---

## The ID scheme (offset macros, `LoadoutDAO.h`)

The integer IDs are **positional offsets**, not a real item database:

```cpp
#define PRIMARY_WEAPONS_OFFSET 100   // primaries  101..105   (NUM = +5)
#define UTILITY_WEAPONS_OFFSET 200   // "secondary" 201..204   (NUM = +4)
#define MELEE_WEAPONS_OFFSET   300   // melee      301..302   (NUM = +2)
#define DAMAGE_TOTEMS_OFFSET   400   // damage     401..403   (NUM = +3)
#define PERSONAL_TOTEMS_OFFSET 500   // "utility"  501..504   (NUM = +4)
#define SUPPORT_TOTEMS_OFFSET  600   // "super"    601..603   (NUM = +3)
```
Matches `SELECT * FROM playervault` exactly. Each weapon's `ItemDefinition` (`ID_BananaPistol`, `ID_Pistol`, …) carries an `ItemId` uint8 = its offset+index; `DT_AllVaultItems` groups them into 4 category rows.

**Dev's own verdict, verbatim in the header:**
> `// TODO: Remove this macro-based worflow crap and do a proper randomize based on actual editor assets`

### Naming drift (DB/API vs game code) — watch out
| DB / API column | Game code (`LoadoutDAO.h`) | Loadout slot (`GET_Loadouts`) |
|-----------------|----------------------------|-------------------------------|
| SecondaryWeapons (201-204) | UTILITY_WEAPONS | "Utility" |
| UtilityTotems (501-504) | PERSONAL_TOTEMS | "Personal" |
| SuperTotems (601-603) | SUPPORT_TOTEMS | "Super" |
Same things, three different names across layers. Easy to trip on during the rework.

---

## Supporting facts

- **Backend subsystem** `UArcaschampionsapiBackendSubsystem` hardcodes the **TEST** API:
  `https://arcaschampionsapi-test-1093142381010.europe-west1.run.app` (`GetNetworkURL()`).
- **Request framework**: one `F…Request` class per endpoint under `Backend/Requests/BAS/` (GetVault, GetLoadouts, SetLoadout(s), GetLoadoutByIndex, ValidatePlayerLoadout, GetChampions, UnpackChampion, CompleteTutorial, RankedMatchResults, plus Consumable/* = BoostStat, InfuseTotem, Purchase, UseConsumable — progression-ish endpoints that have **no server-side implementation yet**).
- **Structs**: `FLoadoutDAO` = `FChampion Champion` + `FWeapons Weapons` + `FTotems Totems`. `FVaultData` = 6× `TArray<uint8>` + `TArray<FChampion>`.
- **Weapon ItemDefinitions present** (`Plugins/.../BASShooterCore/Content/Weapons/*/ID_*`): Pistol, Rifle, Shotgun, DBShotgun, GrenadeLauncher, RocketLauncher, Sniper, TrapGun, Machete, RelicSword, BananaPistol, Unarmed(×3). **Totems**: AmmoCrate, AnimalInstinct, AutoTurret, ChimpCompanion, Disguise, Grenade, PersonalHealing, Rage, Supercharge, TeamHealing.
- **Vault UI icons** (`DT_AllVaultItems` → Textures): BananaPistol, Nutcracker(NutPistol), MelonRifle, ShotgunBlendGun, DBShotgunTwinBarrel, GrenadeLauncher, RocketLauncher, SniperRifleSendaPrayer, TrapGun, Machete, RelicSword.
- **Progression scaffolding already exists**: `Content/UI/PlayerProgression/` with `DT_PlayerProgressionItems.uasset` (not yet investigated — task 2 candidate).
- **Barracks C++ widget family** (`UI/Menu/Barracks/`): Barracks, Vault, VaultSlotButton, VaultCategoryButton, BarrackSavedLoadoutsBar, BarrackCustomLoadoutButton, SynergySpectrum(+Slot), TuningTable(+6 sub-widgets — weapon mod/attribute tuning), Hover* description widgets, WeaponStatLineWidget. (TuningTable = a weapon-mastery/modding UI surface worth a later look.)

---

## Implications for the progression rework

1. **Gameplay unlocks plug in exactly here.** Implementing the commented-out `AddWeaponSlots`/`AddTotemSlots` (filter `DT_AllVaultItems` items by the player's owned uint8 IDs from `FVaultData`) is the precise change that turns "everyone sees everything" into "you see what you've unlocked." The data already flows to the client; it's just discarded.
2. **The offset-macro ID system is the thing to replace** (devs flagged it). A data-driven item registry (ItemId ↔ ItemDefinition) would let progression grant arbitrary items, not just contiguous ranges.
3. **`Consumable/*` request classes hint at an intended economy** (BoostStat, InfuseTotem, Purchase, UseConsumable) with no backend — a clue to the originally-planned progression/currency direction.
4. Champions already round-trip correctly through `GET_Vault`; weapons/totems are the gap.

## Live example (2026-06-28, commit `fdde277`)
Marco's "Mad Rifle First setup + integration with vault" added a full new weapon **MadRifle**
(17 assets: `ID_MadRifle` ItemDefinition, fire/reload GAs, damage GE, recoil curve, ammo/reticle
widgets, weapon instance, ability set, pickup data) and **edited `DT_AllVaultItems.uasset`**. This
confirms the flow above: weapons are added to the Barracks by editing the local DataTable, not the
backend. MadRifle now shows in the vault for everyone — every weapon added this way widens the
"everyone sees everything" gap, reinforcing that `AddWeaponSlots` filtering is the right seam.

> The **runtime firing** side of these hitscan guns (MadRifle, MadBlower, shotguns) — trace path,
> range (`MaxDamageRange`), impact/beam VFX and the `MaxTraceRange` fix — is documented in
> [[weapons-and-grenade-deepdive]] §6.

## Needs the UE5 Editor to confirm (binary assets)
- `DT_AllVaultItems` exact rows: which `ItemId` (101…) maps to which `ID_*` ItemDefinition, and each item's `bShouldBeSelectedFromVault`.
- `W_Vault` / `W_Barracks` Blueprint graphs (any logic layered on the C++ parents).
- `DT_PlayerProgressionItems` contents.
