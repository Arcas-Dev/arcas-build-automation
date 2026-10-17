# Client — weapon progression: API ingestion analysis (read-only, 2026-09-09)

**Status**: 🔍 ANALYSIS — nothing modified. Source: `ApeShooter` @ `3bab700be` (`deploy/steam-testing`), local clone == remote HEAD.
**Backend it must match**: [[loadout-system-build-spec]] AS-BUILT block (live on test since `a9e370a`).

Every backend call goes through `FBASBackendRequest` subclasses in `Source/LyraGame/Backend/Requests/BAS/` and is parsed by
`FRequestManager::ParseBASStructResponse<T>` / `ParseBASArrayResponse<T>` (`Plugins/BlockApeScissors/.../Network/RequestManager.h`)
= `FJsonObjectConverter::JsonObjectStringToUStruct` on the `Payload` string. **Unknown JSON keys are ignored, missing keys keep the
struct default** — so every additive field the API gained today is invisible to the current client until a UPROPERTY exists for it.

---

## 1. Per endpoint: caller → struct → consumer

| API | Called from | Parsed into | Fields the client actually uses | Gap vs the new backend |
|---|---|---|---|---|
| `GET_Vault` | `UVault::GetVaultFromBackend()` (`UI/Menu/Barracks/Vault.cpp:89`), on every `PopulateVault()` | `FVaultData` (`Plugins/BlockApeScissors/.../DAO/VaultData.h`): 6× `TArray<uint8>` + `TArray<FChampion> Champions` | **only `Champions`** (`AddChampionsSlots`). The six weapon/totem arrays are received and discarded — `Vault.cpp:103` `/* TODO: AddWeaponSlots and AddTotemSlots ez. */` | ① `PrimaryMods/SecondaryMods/MeleeMods` not in the struct → dropped by the parser. ② arrays are `uint8` — fine for base ids (≤ 999? no: **uint8 max 255**, so 3xx…6xx ids already overflow… they are never read, which is why nobody noticed). Mods 7xx–9xx need `int32` |
| `GET_Loadouts` | `UBarracks::NativeOnInitialized` (`Barracks.cpp:95`) → `OnLoadoutsRetrieved` → `BarrackSavedLoadoutsBar`, `VaultWidget->SetLoadouts` | `TArray<FLoadoutDAO>` (`DAO/LoadoutDAO.h:253`): `FChampion` + `FWeapons{int32 Primary,Utility,Melee}` + `FTotems{int32 Damage,Personal,Support}` | all three | none — a variant id `101701` is just an `int32` |
| `GET_LoadoutByIndex` | `UPlayerInfoComponent` (`PlayerInfoComponent.cpp:76`) at startup → `SetActiveLoadout` | `FLoadoutDAO` | all three | none for the struct; **resolution gap** below (§2) |
| `POST_SetLoadouts` | `UBarracks::NativeOnDeactivated` (`Barracks.cpp:190`) — all 5 loadouts on leaving the Barracks | body built in `FSetLoadoutsRequest::GetContent` from `FLoadoutDAO` (manual JSON writer) | — | none: sends `Weapons.Primary = <ItemId>`; a variant asset with `ItemId = 101701` serialises the same way. **Failure path**: success lambda only logs a warning (`Barracks.cpp:206`) — the new 400 reason is available in `Request->GetErrorMessage()` but never shown |
| `POST_SetLoadout` (single) | no caller in the client (`FSetLoadoutRequest` exists, unused) | — | — | — |
| `GET_Profile` | `UBASCommonUserSubsystem::GetProfile()/RefreshProfile()` + 2 tutorial checks | `FProfile` (`Structs/Profile.h`): `TutorialComplete, PlayerId, Rank, Level, LevelXP, LevelXPRequired, LeveledUp` | `PlayerAccountWidget` (level + bar), `PlayerProgressionSlotWidget:29` (`Level` → locked/unlocked), tutorial checks | none — unchanged endpoint |
| `POST_MatchResults` / `POST_RankedMatchResults` | dedicated server, `ABASGameMode::SendMatchResults` (`BASGameMode.cpp:927`), only when the matchmaker injected a mode | `ParseResponse()` → `return true` (body ignored) | — | none (body is `Payload: null` now) |
| `POST_ValidatePlayerLoadout` | dedicated server, `ABASGameMode::ValidatePlayerLoadout` on `PostLogin` | simple response | kick on `bSuccess=false` | none — ints compared server-side |
| `GET_ProgressionRewards` | **no request class exists** | — | — | needs `FGetProgressionRewardsRequest` + a `FProgressionReward` struct (`Level, XpRequired, Reward{Type, Id, Qty}`) |

---

## 2. How a loadout id becomes a weapon in hand (the resolution gap)

`UPlayerInfoComponent::SetPlayerWeaponsAndAbilities` (`:167`) loads `UBlockApeScissorsSettings::WeaponsClasses` / `TotemsClasses`
(two `UPrimaryDataAsset`s: `UWeaponsClassListDataAsset{PrimaryWeaponClasses, UtilityWeaponClasses, MeleeWeaponClasses}` and the totem
equivalent — each a `TSet<TSubclassOf<ULyraInventoryItemDefinition>>`) and for each slot calls `SetItem(...)` → `CompareItemId()` (`:191`):
linear scan of the set for `ItemDefinition->ItemId == id`. **No match → `SetItem` returns silently, the slot keeps whatever it had.**

Consequences:
- A variant id `101701` resolves **iff** an `ID_*` asset with `ItemId = 101701` is in `WeaponsClasses.PrimaryWeaponClasses`. Same asset must also be in
  `DT_AllVaultItems`? **No** — the vault/Barracks UI matches `FVaultSlotItem.ItemID` (a *class* reference) against `UserCombatWeapons.PrimaryWeaponClass`
  (`TuningTable.cpp:56`, `ChampionCard.cpp:193`), so a variant only needs a DataTable row if it should be *pickable* as a standalone tile.
- Starter-kit ids **303 Hunting Knife / 602 Turret** resolve only if such assets exist in the class lists (O26 — unverified; live vaults granted 301–302 only).
- Runs on the **dedicated server too** (server loads the same loadout by id), so the variant `ID_*` assets must be in the server build.

---

## 3. The Barracks flow today (what the player can do vs what the DB now allows)

```
Barracks open   GET_Loadouts ──► Loadouts[5]  ──► BarrackSavedLoadoutsBar + ChampionCard (active) + Vault.SetLoadouts
                GET_Vault    ──► Champions only;  weapon/totem tiles = DT_AllVaultItems rows 0-3 with bShouldBeSelectedFromVault
click tile      UVault::SaveSelectedItem → UBarracks::ItemSelected (Barracks.cpp:215)
                  champion: uniqueness check across the 5 loadouts (client-side mirror of the trigger)
                  weapon/totem: NO ownership check → ChampionCard.UpdateItemSlot → PlayerInfo.SaveBarracksEquipment (3D preview)
Tuning Table    UTuningTable::SetWeapons shows the 3 equipped weapon tiles; SetActiveWeapon (:101) has
                  // TODO : Get the available mods for this weapon and set the Mod Slots
                  // TODO : Get the active mod of this weapon and set the ActiveModSlot          ← the mod picker was planned here
leave Barracks  ChampionCard.GetConfiguration() → ItemId per slot (fallbacks 101/201/301/401/501/602) → POST_SetLoadouts (all 5)
                  400 from the trigger → Warning log only; local loadout kept → mismatch → kicked at next match join
```

---

## 4. Progression screen today

`UPlayerProgressionWidget` (`UI/PlayerProgression/`) reads a **local DataTable** `ItemsDataTable` of `FPlayerProgressionItem{int32 ItemCollectLevel; FVaultSlotItem Item}`
(= `DT_PlayerProgressionItems`, 25 rows per the July audit) and creates one `UPlayerProgressionSlotWidget` per row. Lock state = `StoredProfile.Level >= ItemCollectLevel`
(already wired to the real level). `bCanBeCollected` is never set; `OnSlotClicked` is a TODO ("mark collected + add to vault") — i.e. the screen was designed
for a **manual collect** model, whereas the backend now **grants automatically on level-up**. The 70-row server table (`GET_ProgressionRewards`) is the truth the
screen should render; the DataTable would remain only as the id → icon/name lookup (or be replaced by looking the id up in `DT_AllVaultItems`).

Level-up popup: `UBASCommonUserSubsystem::OnProgressionUpdated` broadcast after `GET_Profile`; `TopBar.cpp:86` pushes `PlayerProgressionWidgetClass`.
Known-flaky (see CLAUDE.md #10 KNOWN BUG) — unrelated to this change but the same surface.

---

## 5. What has to change (ordered, smallest first) — for planning, not yet approved

| # | Change | Where | Kind |
|---|---|---|---|
| C1 | `FVaultData`: add `TArray<int32> PrimaryMods, SecondaryMods, MeleeMods` (and consider `uint8 → int32` on the six existing arrays: 3xx–6xx ids already exceed 255) | `Plugins/BlockApeScissors/.../DAO/VaultData.h` | C++, struct only |
| C2 | Implement the commented `AddWeaponSlots/AddTotemSlots`: filter `DT_AllVaultItems` tiles by `ItemId ∈ owned arrays`; keep unowned tiles as **locked** (needs a locked visual on `UVaultSlotButton`, which has none today) or hide them | `Vault.cpp:103`, `AddPrimaryWeapons…AddTotems`, `VaultSlotButton` | C++ + BP visual |
| C3 | Tuning Table mod picker: fill the two TODOs in `SetActiveWeapon` — list owned mods of the weapon's class (`PrimaryMods` for 1xx …), selecting one swaps the ChampionCard slot's item class to the **variant asset** (`ItemId = base×1000+mod`); "none" swaps back to the base asset | `TuningTable.cpp:101`, `ChampionCard` | C++ + BP |
| C4 | Variant `ID_*` assets (Marco): one per (base, class-mod) with `ItemId = base×1000+mod`, registered in `WeaponsClasses.*Classes` sets (client **and** server build). 21 bases × 3 = 63. Plus `DT_AllVaultItems` rows for 106-110 / 205-206 / 303-305 and confirm 303 / 602 exist | editor content | asset |
| C5 | `GET_ProgressionRewards` request + struct; `PlayerProgressionWidget` renders the 70 server rows (icon/name via DataTable lookup by id), unlocked = `Level ≥ row.Level`; drop the manual-collect TODOs | new request class, `PlayerProgression/` | C++ |
| C6 | Surface the trigger's 400 reason on save failure (`Request->GetErrorMessage()` → system message) instead of a silent warning | `Barracks.cpp:206` | C++, tiny |
| C7 | Offset macros `NUM_*_WEAPONS` in `LoadoutDAO.h` are stale (5/4/2) but **unused** in C++ (grep) — leave or delete | — | cleanup |

Not needed: any change to `FLoadoutDAO`/`FWeapons`, the loadout readers, `POST_SetLoadouts` serialisation, `GET_Profile`, the dedicated-server validation path, or the end-match banner.

---

## 6. Id reconciliation — CLOSED 2026-09-12 (O26)

`DT_AllVaultItems` (`Content/UI/Menu/Barracks/`) has 4 rows keyed by GroupID: **0 primary · 1 secondary(utility) · 2 melee · 3 totems**
— the order `Vault.cpp` indexes them in. Each element is an `FVaultSlotItem` whose `ItemID` is a **class reference** to an
`ID_*` BlueprintGeneratedClass under `Plugins/GameFeatures/BASShooterCore/Content/`; the numeric `ItemId` lives on that asset,
**not** in the DataTable, and it is **explicit — NOT derived from array position** (verified in the editor by Dan).

**Verified in the editor (2026-09-12):** `ID_CombatKnife` = **303** · `ID_Rifle` = **103** · `ID_Machete` = **301** ·
`ID_DBShotgun` = **102**. These match [[progression-ranking-spec]] / [[loadout-system-build-spec]] exactly, so the live
`progression_levels.reward` table and the 6-item starter kit (101 · 201 · 303 · 401 · 501 · 602) are **correct as shipped**.
A positional-id hypothesis (ids = offset + array index) was raised and **disproved** by these four readings — the vault display
order simply is not the id order.

### Design name → asset (the naming drift, now resolved)

| Id | Design name | Asset | | Id | Design name | Asset |
|---|---|---|---|---|---|---|
| 101 | Pistol | `ID_Pistol` | | 201 | Blend Gun | `ID_Shotgun` |
| 102 | Twin Barrel | `ID_DBShotgun` | | 202/203 | Potato Gun / R-Tree G | `ID_GrenadeLauncher` / `ID_RocketLauncher` (order unconfirmed) |
| 103 | Melon Rifle | `ID_Rifle` | | 204 | Trap Launcher | `ID_TrapGun` |
| 104 | Send a Prayer | `ID_Sniper` | | 205 | Madzooka | `ID_MadZooka` |
| 105 | Banana Pistol | `ID_BananaPistol` | | 206 | Mad Vacuum | `ID_MadBlower` |
| 106 | Mad Rifle | `ID_MadRifle` | | 301 | Machete | `ID_Machete` |
| 107 | Mad SMG | `ID_MadSMG` | | 302 | Relic Sword | `ID_RelicSword` |
| 108 | Nail SMG | `ID_NailSMG` | | 303 | Hunting Knife | `ID_CombatKnife` |
| 109 | Plasma Shotgun | `ID_PlasmaShotgun` | | 304 | Axe | `ID_Axe` |
| 110 | Alien Railgun | `ID_AlienRailgun` | | 305 | Spear | `ID_Spear` |

Totems (all under `Totems/`, display order == id order): 401 `ID_Grenade` · 402 `ID_Supercharge` · 403 `ID_Rage` ·
501 `ID_PersonalHealing` · 502 `ID_AmmoCrate` · 503 `ID_AnimalInstinct` · 504 `ID_Disguise` · 601 `ID_TeamHealing` ·
602 `ID_AutoTurret` · 603 `ID_ChimpCompanion`. Unarmed placeholders are 199/299/399 (`StartGameScreen` tutorial loadout) and
carry `bShouldBeSelectedFromVault=False`, so they never appear as vault tiles.

### Open data issues found while reconciling

| # | Issue | Fix |
|---|---|---|
| D1 | ✅ **FIXED 2026-09-12 (Dan, editor).** `ID_AlienRailgun`'s DataTable element had NO `ItemCategory` (every other element sets one) → defaulted to `None` → `UChampionCard::UpdateItemSlot`'s `switch (Item.ItemCategory)` matched no case → **clicking it equipped nothing**. Had been dormant since nobody could reach it; progression unlocks it at L66. | was: one dropdown in `DT_AllVaultItems` → `Primary Weapon` |
| D2 | ✅ **FIXED 2026-09-12** (`cebb3cd95` "ChampionCard: melee loadout fallback 301 -> 303", verified in the diff 2026-09-13 — now carries a comment tying the six fallbacks to the backend starter kit). Was: `UChampionCard::GetConfiguration` (`ChampionCard.cpp:435-482`) builds the loadout to save by reading `ItemId` off each equipped slot widget, and falls back to a hardcoded id when a slot holds no valid item: **101 · 201 · 301 · 401 · 501 · 602**. Five of those are in the starter kit — **melee is not** (kit grants **303** Hunting Knife, fallback says **301** Machete), i.e. the fallbacks were written against an older kit. The slot is only empty when the stored melee id fails to resolve (`PlayerInfoComponent::CompareItemId` finds no `ItemDefinition` with that id in `WeaponsClassListDataAsset`, or the class has no `DT_AllVaultItems` row → `UpdateItemSlot` never runs). Harmless pre-progression because everyone owned 301; now a starter-kit player would save an **unowned** 301 → `validate_loadout` rejects → 400 → `Barracks.cpp:206` only logs a warning → client keeps its local loadout while the server keeps the old one → **`POST_ValidatePlayerLoadout` mismatches at match join → "Invalid loadout" kick**. | done: 301 → 303 (`ChampionCard.cpp:453`). ⚠️ **Not yet compiled or cooked.** Better long term: don't guess — leave the slot as-is / refuse the save when a slot cannot be resolved |
| D3 | 🟢 Weapons carry no Description/Video in the DataTable; totems do. Cosmetic, explains why weapon hover panels are sparser | — |


---

## 7. Full ItemId audit — MACHINE-VERIFIED 2026-09-13

Everything in §6 was read one asset at a time in the Editor. This pass read **every** `ID_*` asset at once, off the build VM,
and so supersedes it as the authority. Method, because it is reusable and it removes the old "you need RDP to see numbers" limit:

```
UnrealEditor-Cmd.exe <uproject> -ExecutePythonScript="C:/A/staging/dump_itemids.py" \
    -EnablePlugins=PythonScriptPlugin -unattended -nopause -nosplash -NullRHI -stdout
```

`PythonScriptPlugin` ships with the engine at `C:\UE5.5\Engine\Plugins\Experimental\` and is **not** enabled in the
`.uproject` — `-EnablePlugins=` turns it on for that run alone, changing no files. The script walks the AssetRegistry,
`load_blueprint_class` + `get_default_object` on each `ID_*`, reads `ItemId`, and writes JSON to `C:/A/staging/`.
Runs in a few minutes on a warm DDC. **`strings` on a `.uasset` cannot do this** — it yields structure and references but
never numeric property values; this closes that gap for good. (Local `.uasset` are git-lfs pointers, so it must run on the VM.)

### Result — all 84 player-weapon ids correct

Marco set the 63 variant ids in `a5cb771af` "ID to all weapons" (+ `283c775fa` alien railgun category). Verified against
[[loadout-system-build-spec]]: **84 expected, 84 present — 0 missing, 0 unexpected, 0 duplicates**, every variant exactly
`base × 1000 + mod`. The two most fumble-prone survived their odd filenames: `ID_Rifle_DoubleTap` = 103701,
`ID_Sniper__HighCapacityMod` = 104703. Unarmed 199/299/399 untouched; the 10 NPC/turret weapons still `0` (correct — they are
never resolved through the loadout path). Mod suffixes: primary 701 DoubleTap / 702 HighDamage / 703 HighCapacity ·
secondary 801 Fire / 802 Healing / 803 Demolition · melee 901 LuckyStrike / 902 BerserkBoost / 903 Resourceful.

Full grid (all 84 with asset + design names): `arcas-champions/docs/weapon-mod-id-reference.drawio.svg`.

### 🔴 The remaining blocker: `DA_WeaponsClasses` has none of them

`/Game/Weapons/DA_WeaponsClasses` still holds **24 entries, all bases** — Primary 11 / Utility 7 / Melee 6, each count
including its Unarmed placeholder. **Zero variants.** So a mod still cannot be equipped:

```
loadout slot int32 → UPlayerInfoComponent::SetPlayerWeapons()
                   → SetItem(WeaponsClasses->PrimaryWeaponClasses, id)
                   → CompareItemId()  PlayerInfoComponent.cpp:190   linear scan of the TSet
                   → no match → return → slot silently left unset      (no log, no error)
```

Adding the 63 is now **safe and mechanical** — the hazard that made ordering matter (four assets sharing id 101, and
`CompareItemId` returning whichever the `TSet` yielded first) is gone now that every id is unique.

⚠️ **One side effect to check after registering.** The AssetRegistry says `DA_WeaponsClasses` has exactly one referencer:
`/Game/Environments/Gameplay/BarracksWeaponStand`. If that level enumerates the three sets to populate the display rack,
it goes from 21 weapons to 84. Nothing in C++ else touches the asset (`PlayerInfoComponent.cpp` is the only consumer).
