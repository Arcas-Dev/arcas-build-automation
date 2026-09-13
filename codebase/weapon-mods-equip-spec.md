# Weapon Mods: the Equip Stage

**Status**: BUILD SPEC, written 2026-09-13, implemented in the same session.
**Predecessor**: `weapon-mods-tuning-table-spec.md` (the visualise stage, shipped).
**Branch**: `deploy/steam-testing`.

The visualise stage shipped: owned mods appear in the Tuning Table for the selected weapon, with a
hover describing what each one does. This spec covers making them actually equip and persist.

---

## 1. What is already done

| Piece | State |
|-------|-------|
| Backend: vault mod columns, variant ids, `validate_loadout` v2 | LIVE on test since `a9e370a` |
| All 84 weapon `ItemId`s on the `ID_*` assets | Verified on the VM, 0 dupes |
| 63 variants registered in `DA_WeaponsClasses` | Marco, `463116c45`, verified |
| Mod rows in `DT_AllVaultItems` (row 5) | Marco, done |
| Mod slots filled + hover description | Us, `a03a1a24f` + `637045060` |

**No editor work is required for anything in this spec.** `DT_AllVaultItems` is not touched. The
63 variants never become rows in it, because a variant's tile is built in code from the base
weapon's row.

---

## 2. The two lookups, and why only one of them is done

This is the thing that keeps causing confusion, so it is written out once, here.

**Lookup A, id to class.** The loadout stores an integer. `CompareItemId`
(`PlayerInfoComponent.cpp:190`) scans the three arrays of `DA_WeaponsClasses` to turn `103702`
into `ID_Rifle_HighDamageMod_C`. Its output lands in `PlayerInfo.UserCombatWeapons`, which
`PlayingCharacter.cpp:387-400` reads to decide what weapon to spawn in a match. This is the
gameplay path. Marco's registration fixed it. Before that, a variant id resolved to null and there
was no weapon at all.

**Lookup B, class to tile.** The UI needs an icon, a name and a description. `ChampionCard::
SetConfiguration` and `TuningTable::SetWeapons` get them by scanning `DT_AllVaultItems` rows for a
row whose `ItemID` equals the equipped class. Variants are not rows, so a variant matches nothing.

Lookup B looks cosmetic and is not. **The champion card's slot is also where the equipped id is
stored.** `GetConfiguration()` (`ChampionCard.cpp:436`) reads the id straight back off the slot's
item, and the Barracks saves whatever that returns. A variant that cannot produce a slot item
leaves the base weapon sitting in the slot, and the save silently writes the base id. The mod is
dropped on the next save, every time.

---

## 3. Decisions

- **E1. The Barracks stays mod-blind.** The champion card shows the base weapon's icon, name and
  description. You only see that a weapon is modded by opening the Tuning Table. Dan, 2026-09-13.
- **E2. A variant's tile is the base weapon's row with the item definition swapped.** No new
  DataTable rows, no new art, no 63-row mapping table.
- **E3. Clicking the fitted mod takes it off.** One mod per weapon, so the slot is a toggle rather
  than a picker plus a separate remove control.
- **E4. The fitted state is shown by the active weapon's mod slot, not by an animation.** The slot
  in the top right of the Tuning Table shows the fitted mod's icon, or is empty when the weapon
  has no mod. Dan explicitly deferred the per-slot highlight animation: "right now its ok if we
  can't tell, as the icon in the top right should change or be empty based on the equip status and
  thats enough."
- **E5. The Tuning Table reaches the saved loadout through a new no-argument delegate**, not by
  writing the loadout array directly. See §5.

---

## 4. Traps

🔴 **`SetUnequipStatus(true)` also blocks clicks.** It sets `bIsEquip`, and
`UVaultSlotButton::NativeOnClicked` early-returns while that is set. Using it to mark the fitted
mod would make the mod impossible to remove. The fitted marker needs its own entry point that
leaves the flag alone.

🔴 **Do not write `UBarracks::Loadouts` directly from the Tuning Table.** Both
`ChampionCardItemUpdated` and `ChangeLoadout` reassign `Loadouts[ActiveLoadoutIndex]` from
`ChampionCardWidget->GetConfiguration()`. Anything written straight into the array is discarded the
moment the player touches any other slot. The champion card has to be the one holding the variant.

🟡 **`SetOrIncrementUserCombatValue` already broadcasts `OnPlayerInfoUpdate`**, which the Tuning
Table is bound to, so its three weapon slots refresh for free. The active weapon panel does not,
and must be updated explicitly in the click handler.

🟡 **`OnBarrackLoadout_UpdateEvent` is already taken.** It is `BlueprintAssignable`, broadcast from
`SaveBarracksEquipment`, and drives the 3D preview from Blueprint. Do not reuse it. Add a new one.

🟡 **A mod is offered only if its class matches the weapon** (`mod div 100 - 6 == base div 100`).
The same rule is enforced independently by `validate_loadout` on save, so a client bug produces a
400 rather than a bad loadout.

---

## 5. The changes

### C1. Shared variant helper (new header, `UI/Menu/Barracks/WeaponVariantUtils.h`)

Header-only. Holds the id arithmetic that is currently duplicated in an anonymous namespace in
`TuningTable.cpp`, plus the tile resolver:

- `GetBaseId(ItemId)` / `GetFittedModId(ItemId)` / `MakeVariantId(Base, Mod)`
- `FindSlotItemForEquippedClass(DataTable, RowIndex, EquippedClass, OutItem)` finds the row whose
  id equals the **base** id, copies it, and swaps `ItemID` to the equipped class.

### C2. `ChampionCard::SetConfiguration`
Replace the three class-equality loops with C1 so a variant resolves to the base weapon's tile.
This is what makes the save keep the mod.

### C3. `TuningTable::SetWeapons`
Same replacement for its three weapon slots, so the Tuning Table can display a modded weapon.

### C4. `VaultSlotButton::SetFittedStatus(bool)`
New. Plays the same animation as the equipped state but leaves `bIsEquip` clear, so the slot stays
clickable. `SetModSlots` uses this instead of `SetUnequipStatus`.

### C5. `TuningTable::SetModSlots`
Bind `OnVaultSlotClicked` on each filled slot. Keep the existing class filter, ownership filter and
ascending sort.

### C6. `TuningTable::ModSlotClicked` (new)
Computes the new weapon id (E3: the fitted mod toggles off to the base, any other mod fits),
resolves it through `DA_WeaponsClasses`, writes it with `SetOrIncrementUserCombatValue`, refreshes
the active weapon panel and the mod slots, and broadcasts C8.

### C7. `TuningTableActiveWeapon::SetWeapon`
Takes the fitted mod item as a second argument. `ActiveWeaponSlot` shows the mod's icon when one is
fitted and collapses when none is. This is E4, the only equip feedback for now.

### C8. `PlayerInfoComponent`: new `OnBarracksLoadoutEdited` delegate (no arguments)
Broadcast by the Tuning Table after a successful change.

### C9. `Barracks`: bind C8
On receipt, rebuild the champion card from the current player info and reassign
`Loadouts[ActiveLoadoutIndex]` from the card's configuration. This is the identical path a normal
vault click takes, so saving stays consistent.

---

## 6. Build

**Full `build-all.bat`, not `build.bat`.** The dedicated server cooks the same content and has to
resolve the variant class to spawn the weapon. A client-only build would show the mod in the menu
and hand the player the base weapon in the match.

---

## 7. Test plan

1. Open the Tuning Table on a weapon whose mod you own. Slots show only owned, fitting mods.
2. Click a mod. The active weapon's top-right slot fills with that mod's icon.
3. Click the same mod again. The slot empties and the weapon returns to its base.
4. Fit a mod, leave the Barracks, come back. Still fitted.
5. `ADMIN_GetVault?playerid=` shows the variant id, e.g. `103702`, in the loadout slot.
6. The champion card still shows the base weapon's icon and name throughout (E1).
7. Join a match. The modded weapon is in hand.
8. Negative: revoke the mod in the DB and save. `validate_loadout` rejects with 400.

---

## 8. Deferred

- **Per-slot fitted highlight animation** on `W_ModSlot` (Marco). E4 stands in for it.
- **"No mods unlocked" line** when a weapon has no owned mods (Marco).
- **`BarracksWeaponStand`** loops `PrimaryWeaponClasses`, which went from 11 entries to 41. The
  surrounding nodes look like an id lookup rather than a display of every entry, so it is probably
  fine, but Marco should open it once.
- **The empty `UTuningTableModSlotButton`** from the Bevium era still has commented-out stubs for
  exactly this. Logic lives on `UTuningTable` instead, which is the only place that knows the
  active weapon and the player's owned mods. Delete the stub or leave it.
