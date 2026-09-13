# Weapon mods in the Tuning Table — WIP build spec

**Created**: 2026-09-13 · **Status**: 🟡 WIP SPEC — build from this. Nothing below is built yet except where marked ✅.
**Supersedes the "how" half of** [[weapon-mods-client-plan]] (that doc stays as the survey + blocker list).
**Backend**: finished, see [[loadout-system-build-spec]] AS-BUILT. **Ids**: verified, see [[client-weapon-progression-ingestion]] §7.
**Diagram**: `arcas-champions/docs/weapon-mods-system.drawio.svg` (also in `drive/`) — the whole chain on one page, colour-coded by who does what.

---

## 1. Decision record (2026-09-13, Dan)

| # | Decision | Reasoning |
|---|---|---|
| **T1** | **Mods ARE `ULyraInventoryItemDefinition` assets**, 9 of them, ids 701-903, with a new `ItemCategory` value. | Dan's call, and correct: totems are already item definitions with ids 401-603, so the vault items table is not "weapons only", it is "things that are item definitions". |
| **T2** | **Mods live as a 5th row in `DT_AllVaultItems`**, alongside primary / utility / melee / totems. | One table Marco already knows. No new row struct, no new table. Verified safe: **no code iterates all rows** — every caller indexes `Rows[0]`..`Rows[3]`, and `UVault::BuildItemSlots` has an explicit `Rows.Num() >= 4` guard. |
| **T3** | **Hovering a mod shows its description**, not weapon stats — reusing the layout the totem hover already uses. | Dan's requirement. The hover panel already has two layouts behind `ContentSwitch`; `UVaultSlotButton::AddDescription` picks between them with a `bTotem` flag derived from the item category. Extending that flag to include mods gets the description layout for free. |
| **T4** | **Hide unowned mods**, fill the three slots **left to right**. | Consistent with the vault. Slots sit in a horizontal box so collapsing reflows. |
| **T5** | **One mod per weapon.** | 3 mods per class, 3 slots: the slots are the candidates, the player picks one or none. Matches what `validate_loadout` allows. |
| **T6** | **"No mods unlocked" line** when the player owns none of that class. **Left blank for now**, Marco adds it later (M6). | Common early: first primary mod is L5, the others L25 / L49. |

### Rejected, and why (so this is not re-litigated)
- **A separate 9-row mod table with its own row struct.** Rejected once T3 landed. Its only advantage was avoiding the enum
  value, and that advantage was based on a risk that **only exists if a mod takes the weapon hover branch** (see §5.2).
  Under T3 it never does.
- **Putting the variant weapon class on the mod button instead of a mod asset.** Works for the click, but then hovering a mod
  shows the *modded weapon's stats*, which is explicitly not what Dan wants.

---

## 2. The model

```
mod ids      701 Double Tap · 702 High Damage · 703 High Capacity      fit 1xx primary weapons
             801 Fire Rounds · 802 Healing · 803 Demolition            fit 2xx utility weapons
             901 Lucky Strike · 902 Berserk · 903 Resourceful          fit 3xx melee weapons
fits         mod / 100 - 6 == base / 100
variant id   base * 1000 + mod        103 + 702 = 103702        unmodded weapon keeps its base id
ownership    playervault.primarymods / secondarymods / meleemods   (arrays of mod ids)
```
A mod is **not** stored in a loadout. The loadout slot holds **one weapon id**, which is either a base id or a variant id.
The server checks `owns(base) AND owns(mod)` on save.

---

## 3. What Marco adds (editor)

| # | Task | Detail |
|---|---|---|
| **E1** 🔴 | **Register all 63 variant `ID_` classes in `DA_WeaponsClasses`** | `/Game/Weapons/DA_WeaponsClasses`, into `PrimaryWeaponClasses` / `UtilityWeaponClasses` / `MeleeWeaponClasses` by class. **Without this a mod can be chosen but never equipped** (§5.3). Currently 24 base entries, 0 variants. *We can script this — see §6 U0.* ⚠️ then check `BarracksWeaponStand` (its only referencer) does not go 21 → 84 weapons on the rack |
| **E2** | **9 mod item definitions** | Blueprints deriving `ULyraInventoryItemDefinition`, e.g. `ID_Mod_DoubleTap`. Set **`ItemId`** (701…903) and **`ItemCategory = WeaponMod`** (new value, we add it). **No fragments needed** — a mod is never spawned or equipped as an item. |
| **E3** | **5th row in `DT_AllVaultItems`** | `GroupID = 4`, 9 elements. Per element: `ItemID` = the mod asset, `ItemCategory = WeaponMod`, `Icon` = the shipped icon (`Content/UI/Menu/Barracks/Textures/WeaponMods/T_UI_Icon_*`), `Description` = what the mod does (**this is what the hover shows**), `bShouldBeSelectedFromVault = false`. |
| **E4** | Tuning Table styling | The three mod slots + the empty state. |
| **M6** | "No mods unlocked" line | T6. Later. |

### Icon → mod id
| Icon asset | Mod |
|---|---|
| `T_UI_Icon_PrimaryMod_DoubleTap` | 701 |
| `T_UI_Icon_PrimaryMod_DamageBuff` | 702 |
| `T_UI_Icon_PrimaryMod_AmmoCapBuff` | 703 |
| `T_UI_Icon_UtilityMod_FireAmmo` | 801 |
| `T_UI_Icon_UtilityMod_HealingAmmo` | 802 |
| `T_UI_Icon_UtilityMod_DemoAmmo` | 803 |
| `T_UI_Icon_MeleeMod_LuckyStrike` | 901 |
| `T_UI_Icon_MeleeMod_BerserkBoost` | 902 |
| `T_UI_Icon_MeleeMod_Resourceful` | 903 |

---

## 4. The hover (T3)

`UVaultSlotButton::AddDescription` currently decides the layout like this:
```cpp
const bool bTotem = Item.ItemCategory == DamageAbility || SupportAbility || PersonalAbility;
DescriptionOnScreen->SetDescription(Item, ChampionItem, bTotem, bHoverDescriptionOnRight);
```
`bTotem` drives three things in `UHoverItemSlotDescription::SetDescription`: the accent colour, the button style, and
`ContentSwitch->SetActiveWidgetIndex(bTotem ? TotemSwitcherActiveIndex : WeaponSwitcherActiveIndex)` — i.e. **description
layout vs stat-bars layout**.

**Change**: include `WeaponMod` in that flag and rename it for what it actually means (`bUseDescriptionLayout`).
Everything else falls out for free:
- accent colour → the totem `switch` has a benign `default` (white), so a mod gets white unless we add a case;
- `bOpenSpectrum = (Item.ItemCategory == SupportAbility)` → **false** for a mod, so the panel's button stays hidden. Correct:
  a mod hover should offer no button;
- the stats path is never reached, so `UBASRangedWeaponsStatsSubsystem` is never called with a mod (§5.2).

---

## 5. Traps found while specifying this

### 5.1 🔴 The save path — the Tuning Table cannot write the loadout directly
Two parallel states:
1. `UPlayerInfoComponent::PlayerInfo.UserCombatWeapons` — drives the **3D preview** and the Tuning Table's own display.
2. The **`UChampionCard` slot widgets** — the source for `UBarracks::Loadouts`, which is what `POST_SetLoadouts` sends.

`UBarracks::ItemSelected` keeps both in step on a vault click, binding to `OnChampionCardItemUpdated` **one-shot**
(`ChampionCardItemUpdated` opens with `RemoveAll(this)`; `ItemSelected` re-adds each time). The Tuning Table is pushed onto
its own layer with **no reference to the Barracks**, so writing only to `PlayerInfoComponent` updates the preview and the
screen while `Loadouts` stays stale — **the mod is never saved**. Same silent-divergence class as the melee fallback.

**Fix**: a new delegate on `UPlayerInfoComponent` (the shared bus both widgets already hold, next to the existing
`OnBarrackLoadout_UpdateEvent`). The Tuning Table broadcasts the chosen **variant slot item**; `UBarracks` handles it with
the same body as a vault click.

### 5.2 Two switches assert on an unknown category
- `UBASRangedWeaponsStatsSubsystem::GetWeaponStatsRanges` — `default: ensureAlways(false)` ("we should never hit this").
- `UChampionCard::UpdateItemSlot` — `default: ensureAlwaysMsgf(false, "Clicked Vault Item Slot is not supported!")`.

Neither is reachable by a mod under this design (the hover takes the description branch; the Tuning Table hands the Barracks
a **variant weapon** item, never a mod item). Add a `case WeaponMod:` no-op to both anyway, so a future caller gets a no-op
instead of an editor assert.

### 5.3 Variants are not in `DT_AllVaultItems`
Only the 21 bases are, and we are **not** adding 63 rows. The Tuning Table builds the variant's `FVaultSlotItem` by
**copying the base weapon's row entry and swapping `ItemID` for the variant class** — the icon stays the base weapon's,
which is right, it is the same gun.

### 5.4 Enum change is safe
`EUserCombatBarrackType` gains `WeaponMod` **before `Count`**. Verified: nothing anywhere iterates `::Count`; Blueprint
enums resolve by name so appending does not break assets; it serialises as `uint8` so existing values do not shift.

---

## 6. The linking chain — end to end

```
 1  Barracks → hover a weapon → "TUNING TABLE" button                    ✅ done (e74ace639)
 2  UTuningTable::SetWeapons shows the 3 EQUIPPED weapons
       (read from PlayerInfoComponent, already implemented)              ✅ exists
 3  player clicks one   → SetActiveWeapon(Item)  → ActiveWeapon + stats  ✅ exists
 4  ── NEW ── work out the active weapon's base + class
       activeId = Item.ItemID.GetDefaultObject()->ItemId
       base     = activeId >= 1000 ? activeId / 1000 : activeId      (103702 → 103)
       fittedMod= activeId >= 1000 ? activeId % 1000 : 0             (103702 → 702)
       class    = base / 100                                          (1 | 2 | 3)
 5  ── NEW ── fill Mod1..Mod3
       owned    = vault.PrimaryMods | SecondaryMods | MeleeMods   (by class)
       for each owned mod, in ascending id, left to right:
           slotItem = DT_AllVaultItems row 4 entry for that mod   (icon + description + mod asset)
           Mod[n]->SetItem(slotItem);  Mod[n]->SetUnequipStatus(mod == fittedMod)
       collapse the unused slots                                            (T4)
 6  ── NEW ── player clicks Mod[n]
       modId    = slotItem.ItemID.GetDefaultObject()->ItemId          (701…903)
       toggling the fitted mod off  → newWeaponId = base
       otherwise                    → newWeaponId = base * 1000 + modId
 7  ── NEW ── resolve the weapon class
       newClass = CompareItemId(WeaponsClasses.<category>, newWeaponId)
       ⚠️ returns null unless E1 is done → nothing happens, silently
 8  ── NEW ── build the variant slot item
       variantItem = copy of the BASE weapon's DT_AllVaultItems entry
       variantItem.ItemID = newClass                                        (5.3)
 9  ── NEW ── hand it to the Barracks
       PlayerInfoComponent->OnTuningTableItemChanged.Broadcast(variantItem, champion)
       UBarracks handles it exactly like ItemSelected:
           bind OnChampionCardItemUpdated → ChampionCardWidget->UpdateItemSlot(variantItem)
           → ChampionCardItemUpdated → Loadouts[ActiveLoadoutIndex] = GetConfiguration()   (5.1)
           PlayerInfoComponent->SaveBarracksEquipment(newClass, champion)  → 3D preview
       → OnPlayerInfoUpdate fires → UTuningTable::SetWeapons re-runs → step 4 again, slot re-highlights
10  leave the Barracks → POST_SetLoadouts sends Weapons:[103702, …]         ✅ no change needed
11  server trigger: owns(103) ∧ owns(702) ∧ 702 fits 1xx → accepted        ✅ live
12  match join → POST_ValidatePlayerLoadout compares ints → ok             ✅ no change
13  in match → server resolves 103702 via CompareItemId → variant spawns   ⚠️ needs E1 in the SERVER build too
```

### C++ work items
| # | Change | File |
|---|---|---|
| U0 | Register the 63 variants (scripted commandlet) | `DA_WeaponsClasses` (asset) |
| U1 | `WeaponMod` enum value + `case` no-ops in the two asserting switches (5.2, 5.4) | `BASPlayerInfo.h`, `BASRangedWeaponsStatsSubsystem.cpp`, `ChampionCard.cpp` |
| U2 | `bTotem` → `bUseDescriptionLayout`, include `WeaponMod` (§4) | `VaultSlotButton.cpp` |
| U3 | Cache the fetched vault so the Tuning Table can read owned mods | `BASCommonUserSubsystem`, `Vault.cpp` |
| U4 | New delegate + `UBarracks` handler (5.1) | `PlayerInfoComponent.h/.cpp`, `Barracks.cpp` |
| U5 | Steps 4-9: fill the slots, show the fitted mod, equip on click | `TuningTable.cpp/.h` |

---

## 7. Test plan

1. `ADMIN_GrantItem {playerid, itemid: 703}` — High Capacity is the only primary mod unlocked early (L5; 701 is L25, 702 L49).
2. Barracks → hover the Melon Rifle → **Tuning Table** button → screen opens.
3. Click the primary weapon → it becomes the active weapon.
4. **One** mod slot shows (High Capacity), the other two collapsed. Hovering it shows **its description**, not weapon stats.
5. Click it → the 3D preview swaps to the variant; the slot shows as fitted.
6. Leave the Barracks → no 400 in the log → `ADMIN_GetVault?playerid=` shows `loadout1.Weapons[0] = 103703`.
7. Click the fitted mod again → back to `103`.
8. Join a match → the modded weapon is in hand (needs E1 in the server build).
9. Negative: revoke 703 in the DB, try to save → trigger rejects with "Mod 703 is not owned".

---

## 8. AS-BUILT — verified 2026-09-13

### 8.1 U0 is DONE. Marco registered all 63 variants (`463116c45`)

Read straight off `DA_WeaponsClasses` on the VM with a headless Python commandlet.
The asset holds **three** arrays, not one: `PrimaryWeaponClasses`, `UtilityWeaponClasses`,
`MeleeWeaponClasses`. Every entry is a `TSubclassOf`, and the id lives on the CDO's `ItemId`.

| Array | Entries | Base weapons | Variants | Expected |
|-------|---------|--------------|----------|----------|
| Primary | 41 | 10 + Unarmed (199) | 30 (701/702/703 × 10) | 30 ✅ |
| Utility | 25 | 6 + Unarmed (299) | 18 (801/802/803 × 6) | 18 ✅ |
| Melee | 21 | 5 + Unarmed (399) | 15 (901/902/903 × 5) | 15 ✅ |
| **Total** | **87** | **21 + 3 unarmed** | **63** | **63 ✅** |

Every variant id equals `base × 1000 + mod`, every mod obeys `mod div 100 − 6 == base div 100`,
every entry carries the right `ItemCategory`, and there are no duplicate ids. Nothing to fix.

**Asset names have typos** — `ID_Rifle_DoubleTap_C` and `ID_Sniper_DoubleTap_C` are missing the
`Mod` suffix, `ID_NailSMG_HIghCapacityMod_C` has a capital I, `ID_Sniper__HighCapacityMod_C` has a
double underscore, `ID_MacheteResourceful_C` is missing an underscore, and
`ID_Machete_LuckyStike_C` is missing the R in Strike. **None of this matters**: `CompareItemId`
resolves by `ItemId`, never by asset name. Leave them or let Marco rename at leisure.

⚠️ **`PrimaryWeaponClasses` is now 41 entries.** Anything that iterates this array to build a
display — `BarracksWeaponStand` is the suspect — will show 41 primaries instead of 11. Check it
before the equip build.

### 8.2 U2 is DONE, plus two fixes found after the first mod build (`637045060`)

**Mod slots had no hover.** `UVaultSlotButton::NativeOnInitialized` required **both**
`HoverVaultSlotDescriptionWidgetClass` and `HoverVaultChampionSlotDescriptionWidgetClass` to be
valid before it would bind `DescriptionAnchor->OnGetUserMenuContentEvent`. `AddDescription` only
ever uses **one** of the two, picked by item category. `W_ModSlot` legitimately sets only the item
class, because a mod slot can never hold a champion, so it failed the check, never bound, showed
no hover at all, and fired two silent ensures on every construction. Now it binds if **either**
class is set, and `AddDescription` falls back to whichever one the button actually has.

**The Tuning Table stat bars were pinned to full.** `UBaseSliderWidget::UpdateStatValue` drives a
material scalar expecting **0..1**, but `UTuningTableActiveWeapon::SetWeapon` passed the raw
subsystem values straight through, skipping `Convert*StatValueToAlpha`.
`UHoverItemSlotDescription` has always converted; only this screen never did. Fixed for all four
bars. It now also collapses Accuracy and Range for melee, matching the hover panel, and **restores**
them for ranged — the hover panel does not need to, since it is created fresh per hover, but this
widget is reused across weapon selections.

### 8.3 Still open before equip

The **variant display trap** is unchanged and is the next thing to solve.
`ChampionCard::SetConfiguration` and `TuningTable::SetWeapons` resolve the equipped id against
`DT_AllVaultItems` rows. The 63 variants are in `DA_WeaponsClasses` but **not** in that DataTable,
so a variant fails to match, the slot stays empty, and `GetConfiguration()` falls back to the
hardcoded base id. A fitted mod would silently revert on the next save. Fix the lookup to be
variant-aware (strip to the base id for display) before wiring equip-on-click.
