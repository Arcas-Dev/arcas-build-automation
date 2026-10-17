# Weapon mods — show + equip in the Barracks: what's left

**Created**: 2026-09-13 · **Status**: 🔍 ANALYSIS, nothing built. Source: `ApeShooter` @ `cebb3cd95`, assets inspected on the VM.
**Precondition (DONE)**: progression unlocks work end-to-end on test — see [[loadout-system-build-spec]] AS-BUILT and
[[client-weapon-progression-ingestion]]. Mods are already granted, stored, returned and validated; they are simply not shown.

---

## 0. TL;DR

Far more exists than expected. The **backend is finished**, the **UI shell is already laid out** (the Tuning Table has
`Mod1` / `Mod2` / `Mod3` slots and two TODOs marking exactly where the logic goes), **all 9 mod icons are shipped**, and
Marco has already authored **11 of 63 variant assets** — three primary weapons have all three mods.

The single hard blocker is that **no variant class is registered in `DA_WeaponsClasses`**, so the game cannot resolve a
variant id to a weapon at all. That is an editor fix, not code.

---

## 1. What already exists

### Backend — 100% done, no changes needed
`playervault.primarymods / secondarymods / meleemods` · granted on level-up (701 L25, 702 L49, 703 L5, 801 L63, 802 L12,
803 L33, 901 L54, 902 L42, 903 L18) · returned by `GET_Vault` · `validate_loadout` enforces base-owned ∧ mod-owned ∧
class-fits ∧ slot-class. A loadout slot accepts a **variant id** `base*1000 + mod`.

### Client C++ — ingestion done, display not
`FVaultData` already parses `PrimaryMods / SecondaryMods / MeleeMods` as `TArray<int32>` (`a2846069e`). Nothing reads them.

### UI shell — already laid out
`UTuningTable` (`UI/Menu/Barracks/TuningTable.h`) binds **`Mod1`, `Mod2`, `Mod3`** (`UVaultSlotButton`) plus
`ActiveWeapon` (`UTuningTableActiveWeapon`: title, slot, and Damage/Accuracy/Range/Handling stat lines) and
`WeaponMasterTasks`. Three slots is exactly three mods per class. `SetActiveWeapon` ends with:
```cpp
// TODO : Get the available mods for this weapon and set the Mod Slots
// TODO : Get the active mod of this weapon and set the ActiveModSlot
```
Opened from `HoverItemSlotDescription` (`TuningTableWidgetClass` pushed to `TuningTableLayerName`).

### Art — complete
All 9 icons in `Content/UI/Menu/Barracks/Textures/WeaponMods/`:
`T_UI_Icon_PrimaryMod_DoubleTap` · `_DamageBuff` (702) · `_AmmoCapBuff` (703) ·
`T_UI_Icon_UtilityMod_FireAmmo` (801) · `_HealingAmmo` (802) · `_DemoAmmo` (803) ·
`T_UI_Icon_MeleeMod_LuckyStrike` (901) · `_BerserkBoost` (902) · `_Resourceful` (903).

### Variant assets — ALL 63 DONE (Marco, `a5cb771af` "ID to all weapons")
Every variant `ID_*` exists and its `ItemId` is **machine-verified** = `base*1000 + mod`, 0 missing / 0 extra / 0 duplicates
(headless commandlet audit, 2026-09-13 — see [[client-weapon-progression-ingestion]] §7). Reference sheet:
`arcas-champions/docs/weapon-mod-id-reference.drawio.svg`. *(An earlier revision of this doc said "11 of 63" — that was a
stale checkout at `cebb3cd95`, before Marco's push.)*

**Observed asset chain per variant** (for estimating future work):
- *Stat-only* mod (HighCapacity): `ID_` + `WID_` + `WeaponPickupData_` = **3 assets** (mag size is a stat on the `WID_`).
- *Behaviour* mod (HighDamage / DoubleTap): adds `AbilitySet_`, `B_`, `GA_Weapon_Fire_`, `GA_Weapon_Reload_`, `GCN_`,
  `GE_Damage_` = up to **9 assets**. High-damage fire audio exists for 6 primaries (`MSS_Weapons_*_HighDamage*_Fire`).

---

## 2. 🔴 Two blockers — both verified 2026-09-13

### B1 — no variant is registered in `DA_WeaponsClasses`
`Content/Weapons/DA_WeaponsClasses.uasset` holds **24 base entries and zero variants** (re-verified by commandlet:
Primary 11 = 101-110 + 199, Utility 7 = 201-206 + 299, Melee 6 = 301-305 + 399).

`UPlayerInfoComponent::SetItem` → `CompareItemId` (`PlayerInfoComponent.cpp:190`) scans exactly those three `TSet`s for
`ItemDefinition->ItemId == id`, and on no match **returns silently leaving the slot unset**. So a loadout holding `103702`
resolves to no weapon, with client and server quietly disagreeing. Must be registered in the **client and dedicated-server
builds**. Now the ids are unique and verified, registering is mechanical — and can be done by a **Python commandlet**
rather than by hand.
⚠️ The asset's only referencer is `/Game/Environments/Gameplay/BarracksWeaponStand`; if that level enumerates the sets,
the Barracks rack goes 21 → 84 weapons. Check it after registering.

### B2 — the Tuning Table cannot be opened at all
`UHoverItemSlotDescription::SetDescription` sets `bOpenWeaponTuning = true` for weapons and then **hides the button**:
```cpp
// TODO: Uncomment when tune weapon will be ready and delete the two visibility lines below
ItemButton->SetVisibility(ESlateVisibility::Hidden);
ItemButtonText->SetVisibility(ESlateVisibility::Hidden);
//ItemButton->SetVisibility(ESlateVisibility::Visible);
//ItemButtonText->SetVisibility(ESlateVisibility::SelfHitTestInvisible);
```
`TuningTableWidgetClass` is referenced from nowhere else, so this button is the **only** entry point. Fix = swap those four
lines (C++).

**Entry-point behaviour** (relevant to the picker design): the button is shared with totems — for a `SupportAbility` it
opens the Synergy Spectrum instead (`bOpenSpectrum`). `ItemButtonClicked` pushes the Tuning Table with **no context about
the hovered weapon**, which is fine: `UTuningTable::SetWeapons` reads the player's three *equipped* weapons from
`PlayerInfoComponent`, and the player picks one inside to make it the `ActiveWeapon`. So the mod picker needs no plumbing
from the hover panel.

## 3. The design decision (recommended, not yet agreed)

**How does the client turn (base weapon, chosen mod) into a variant class?**

Do **not** add a 63-row mapping table. Compute the id and reuse the existing lookup:
```
variantId = baseItemId * 1000 + modId          // 103 + 702 -> 103702
class     = CompareItemId(WeaponsClasses.<Category>WeaponClasses, variantId)
```
This is exactly how every loadout id is already resolved, so it needs no new data and no new code path — only that the
variant classes are in the data asset (§2) and carry the right `ItemId` (§4 E2).

Consequence: the only new data needed is **modId → icon + name**, 9 rows, not 63.

---

## 4. Work list

### C++ (`LyraGame`)
| # | Change | Notes |
|---|---|---|
| C0 | 🔴 **B2 — unhide the Tuning Table button** in `UHoverItemSlotDescription::SetDescription` (4 lines). Without it the screen is unreachable. | |
| C1 | **Share the fetched vault.** `GET_Vault` is fetched by `UVault` and kept local; the Tuning Table needs the owned mod arrays. Store `FVaultData` in `UBASCommonUserSubsystem` on fetch (mirroring `StoreProfile`) and read it from both widgets. | Prereq for C2. Avoids a second `GET_Vault` |
| C2 | **Fill the mod slots.** In `SetActiveWeapon`, take the active weapon's class (`ItemId / 100` → 1/2/3), pick the matching owned array, and populate `Mod1..Mod3` — one per *owned* mod of that class. Decide: hide unowned mods, or show them locked (the vault chose **hide**; be consistent). | First TODO |
| C3 | **Show the active mod.** The equipped weapon's `ItemId >= 1000` means `mod = ItemId % 1000`; highlight that slot (`SetUnequipStatus`, as champions do). Needs a **"no mod"** affordance to go back to the base weapon. | Second TODO |
| C4 | **Equip a mod.** On mod click: `variantId = base*1000 + mod` (or `base` for none) → `CompareItemId` → swap the slot's class via `ChampionCard::UpdateItemSlot` / `PlayerInfoComponent::SaveBarracksEquipment`, so the 3D preview and the stat lines update. | |
| C5 | **Mod metadata** (icon, name, description) from a new DataTable, read by C2. | See E3 |
| — | **`GetConfiguration` needs NO change.** It already reads `ItemId` off the equipped class, so a variant id flows to `POST_SetLoadouts` automatically and the trigger validates it. | ✅ |

### Editor
| # | Work | Size |
|---|---|---|
| E1 | 🔴 **B1 — register all 63 variant `ID_` classes in `DA_WeaponsClasses`.** Doable by commandlet. | 63 |
| E2 | ✅ **DONE** — all 84 ids verified correct (Marco `a5cb771af`, commandlet audit 2026-09-13). | — |
| E3 | **New `DT_WeaponMods`**: 9 rows — `ModId`, `Name`, `Icon` (textures exist), `Description`. Mirrors `FVaultSlotItem`'s shape. | 9 rows |
| E4 | ✅ **DONE** — all 63 variant assets exist. | — |
| E5 | **`W_TuningTable` BP**: visuals for the three mod slots + the "no mod" state. Slots are `BindWidget` so they already exist in the hierarchy. | styling |

---

## 5. Steps, in order

1. **E1** register the 63 variants in `DA_WeaponsClasses` (commandlet) — then check `BarracksWeaponStand`.
2. **C0** unhide the Tuning Table button (4 lines).
3. **E3** add `DT_WeaponMods` (9 rows: id, name, icon, description).
4. **C1–C5** the picker: share the vault, fill `Mod1..Mod3`, show the active mod + a "no mod" path, equip on click.
5. Compile → `build-all.bat` → test on the Steam demo testing branch.
6. `ADMIN_GrantItem` a mod to the test account first — L5 grants 703, but 701 is L25 and 702 is L49.

No new art is required: all 63 variants and all 9 icons already exist.

## 5b. Decisions taken 2026-09-13 (Dan)

| # | Decision |
|---|---|
| **D1** | **Hide unowned mods**, consistent with the vault. The three slots sit in a horizontal box so collapsing reflows cleanly; fill the slots **left to right** with whatever is owned, so visible slots are always the leading ones and this holds in any container. |
| **D2** | **One mod per weapon.** There are exactly 3 mods per class and exactly 3 slots — the slots are the three candidates, the player picks one (or none). Matches what the backend allows. |
| **D3** | **"No mods unlocked" line** when the player owns none of that class (the common case early: first primary mod is L5, the others L25 and L49). **For now leave the area blank**; Marco adds the line later — see M6. |

### Why the mod table cannot live in `DT_AllVaultItems`
Its row type is `FVaultSlotItem`, whose `ItemID` is a `TSubclassOf<ULyraInventoryItemDefinition>` — a **weapon asset**. A mod has
no such asset, so reusing the table would mean inventing 9 dummy item definitions purely to satisfy the shape. A small
purpose-built table is less work. (Adding a `ModId` field to `FVaultSlotItem` was also rejected: that struct is used
everywhere in the Barracks.)

### The trick that keeps it small
`Mod1..Mod3` are `UVaultSlotButton`s, and `UVaultSlotButton::NativeOnClicked` refuses to broadcast unless
`IsValid(Item.ItemID)`. So each mod button is given **the variant weapon class as its item** while displaying **the mod's
icon**. The button then carries exactly the weapon it would equip, and the click handler reads
`Item.ItemID.GetDefaultObject()->ItemId` to get the variant id directly — no second lookup, and the new table only has to
supply icon + name.

### 🔴 The save-path wrinkle (design constraint, not optional)
Two parallel states exist in the Barracks:
1. `PlayerInfoComponent.PlayerInfo.UserCombatWeapons` — drives the 3D preview and the Tuning Table's own display.
2. The **`UChampionCard` slot widgets** — the source for `UBarracks::Loadouts`, which is what `POST_SetLoadouts` actually sends.

`UBarracks::ItemSelected` keeps both in sync on a vault click, and it binds to `OnChampionCardItemUpdated`
**one-shot** (`ChampionCardItemUpdated` starts with `RemoveAll(this)`, `ItemSelected` re-adds it each time). The Tuning Table
is pushed onto its own layer with no reference to the Barracks, so if it only writes to `PlayerInfoComponent` the preview and
the screen update but **`Loadouts` does not, and the mod is never saved** — the same silent-divergence class of bug as the
melee fallback.
**Fix**: a new delegate on `UPlayerInfoComponent` (the shared bus both widgets already hold, alongside the existing
`OnBarrackLoadout_UpdateEvent`). The Tuning Table broadcasts the chosen variant; `UBarracks` handles it exactly as it handles
a vault click.

### Variants are not in `DT_AllVaultItems` either
Only the 21 bases are. Rather than 63 new rows, the Tuning Table **copies the base weapon's `FVaultSlotItem` and swaps
`ItemID` for the variant class** — the icon stays the base weapon's, which is correct (same gun).

---

## 6. Open questions for Dan / Marco

| # | Question |
|---|---|
| Q1 | Unowned mods in the Tuning Table: **hide** (consistent with the vault) or show locked? |
| Q2 | Is one mod per weapon still the rule (three slots suggests yes, but three slots could also mean three *simultaneous* mods)? The backend variant scheme allows **exactly one**. |
| ~~Q3~~ | ✅ Answered — all 63 carry the right ids (verified 2026-09-13). |
| Q4 | `WeaponMasterTasks` — what is that panel for? It is bound but unused in C++, and may be intended for this screen. |
| Q5 | Mad SMG has a `B_MadSMG_HighDamageMod` behaviour blueprint but no `ID_`. Half-built, or built for something else? |
