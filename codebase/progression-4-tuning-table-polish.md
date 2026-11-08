# Progression System 4: locked items + Tuning Table polish (AS-BUILT 2026-11-08)

Kanban card "Progression System 4" (polish pass on the vault, Tuning Table and weapon mods).
Everything below is **built, compiled clean on the VM, and PIE-verified by Marco** on 2026-11-08,
on `deploy/steam-testing`. **Not yet cooked**: ships with the next `build-all` (with the bot heal
aggro fix `b2661e585` and Marco's sprint/Handling GE `36093bcb8`).

## 1. Locked items instead of hidden items

Before: the vault and the Tuning Table **hid** everything the player does not own (`b779aa0ee`).
Now they show it **locked**: darkened icon + lock on top, not clickable, hover still works.

| Piece | Where | Notes |
|---|---|---|
| Vault tiles | `UVault::AddItemSlots` (`Vault.cpp`) | unowned → `AddSlot(..., bLocked=true)` instead of `continue` |
| Mods | `UTuningTable::SetModSlots` | unowned mods go in `LockedModIds`, slot gets `SetLocked(...)` every time (slots are reused across weapons) |
| Tile state | `UVaultSlotButton::SetLocked` | own `bIsLocked` flag, **not** `bIsEquip` (the Barracks resets equip with `SetUnequipStatus(false)`); `NativeOnClicked` returns early |
| Lock icon | optional `LockOverlay` widget (BindWidgetOptional) in `W_VaultSlot`, `W_ModSlot`, `W_PlayerProgressionSlot` | Marco `1637e0b0d`, icon `/Game/UI/Menu/Barracks/Textures/T_UI_Icon_Locked` |
| Darkening | icon material `MI_UI_HUD_TotemExample` (all three tiles use it), scalar `CooldownPercent` 0 = dark, 1 = normal | written only when the locked state changes |
| Progression bar | `UPlayerProgressionSlotWidget::InitializeSlot` | was already darkened; now also shows `LockOverlay` |
| Hover | `UHoverSlotDescriptionBase::HideItemButton` (virtual, overridden in `UHoverItemSlotDescription`) | locked item: name + stats shown, **Fine Tune** (and synergy spectrum) button hidden |

🔴 **Lesson (cost one round trip):** `W_VaultSlot` and `W_ModSlot` have **no `UnequipAnimation`**
(only `W_VaultSlotChampion` does; `W_VaultSlot`'s only animation is `OnTotemEnterSynergy`). A first
version darkened via that animation and silently did nothing. Side effect: weapon tiles in the vault
do not darken when equipped either. Equipped + fitted still share the animation through
`RefreshDarkened()` (combined state, so clearing one never undoes the other).

Commits: `2c29b56f3`, `38e73bd97` (param rename: `bLocked` shadows `UCommonButtonBase::bLocked`, C4458),
`e58c7ff93`, `e9e918cd5`, `71f73a52e`.

## 2. Progression order

Tiles (and mods) are ordered by the level that unlocks them.

- New request `FGetProgressionRewardsRequest` (`Backend/Requests/BAS/`) → `GET_ProgressionRewards`,
  parsed by hand (levels without a reward have `"Reward": null`) into `ItemId → unlock level`.
- Cached once per session in `UBASCommonUserSubsystem` (`StoreUnlockLevels` / `HasUnlockLevels` /
  `GetUnlockLevel`). Fetched by `UVault::BuildItemSlotsInProgressionOrder` before building tiles.
- Sort: starter kit (owned, no level) first, then by level; locked items no level unlocks go last.
  Stable sort, so ties keep DataTable order. **Request failure → DataTable order** (also in the editor,
  where backend calls fail, so the order can only be seen in a Steam build).
- 💡 **Future**: "Unlocks at level N" on a locked tile's hover. The level is already cached
  (`GetUnlockLevel(ItemId)`), so it is a text line in the hover widget.

## 3. Editor mock vault

With **Use Mock Backend** on (editor only), a failed `GET_Vault` now builds a mock vault owning
everything in `DT_AllVaultItems` except **Project Settings → Block Ape Scissors → Mock → Mock Locked
Item Ids** (`UBlockApeScissorsSettings::MockLockedItemIds`, default `{104 Sniper, 702}`), stores it like
a real vault, so the vault and Tuning Table show locked items in PIE. `UVault::MakeEditorMockVault`.

## 4. Tuning Table: camera, no blur, Barracks UI hidden, delayed appearance

| Behaviour | How |
|---|---|
| Camera moves to the table on Fine Tune, back on close | `UTuningTable::CameraSequence` (set to `/Game/Cinematics/CameraAnimationSequence/TuningTable_CameraAnimation`, Marco `09b423e9b`); one `ALevelSequenceActor` kept per screen, `Play()` on activate, `PlayReverse()` on deactivate. Same `CameraActor_4` in `L_LyraFrontEnd` as `BarracksCameraAnimations`, both **Keep State** |
| Leaving the Barracks from the sidebar while the table is open | `ULyraActivatableWidget::bClosingWithParentLayer` (set by `UBASFirstLayerActivatableWidget::DeactivateAllSubLayers`) → the table **jumps** its sequence to frame 0 and pauses instead of reversing, so it does not fight `USidebar::CameraMovement(false)` |
| No blur behind the table | `ULyraActivatableWidget::bBlurLayerBelow` (default true; unticked in `W_TuningTable`). The first layer only shows `OverallBlur` for sub-layers that want it |
| Barracks UI hidden behind the table | `ULyraActivatableWidget::bHideLayerBelow` (default false; ticked in `W_TuningTable`). First layer hides itself while such a sub-layer is open, restores on close / `DeactivateAllSubLayers` |
| Table UI appears only when the camera arrives | hidden on activate, shown from the sequence player's `OnFinished` (ignored when `IsReversed()`); BlueprintImplementableEvent `OnCameraArrived` for an intro anim |

Commits: `08332159a`, `b2fa4f7de`, `14ba8f314`, `ffdadf5b3`.

## 5. Weapon stand shows the weapon being modded

**Where the stand gets its meshes (verified 2026-11-08 by headless dump of all 118 `ID_*` + 92 pickup assets):**
`BarracksWeaponStand` (`/Game/Environments/Gameplay/`) reads **`InventoryFragment_PickupIcon → StaticMesh`**
on the weapon's `ID_*` item definition (`FindItemDefinitionFragment` → `SetStaticMesh`). It never reads
`WeaponPickupData_*` / `LyraWeaponPickupDefinition.DisplayMesh` (that is the in-match pickup pad mesh).
- All 63 variants carry their base weapon's mesh.
- Only 3 weapons differ between the two sources: DBShotgun `SM_TwinBarrelShotgun_Rot` vs `_02`,
  PlasmaShotgun `Plasma_Shotgun_Rot` vs `Plasma_Shotgun`, Spear `Spear_Alt` vs `Spear`.
- Unarmed 199/299/399 have no StaticMesh (pickup data has `SM_QuestionMark_*`).

**Build:**
- C++ `ee7c4e8dc`: `UPlayerInfoComponent::OnTuningTableWeaponChanged(Item)` (BlueprintAssignable),
  broadcast from `UTuningTable::RefreshActiveWeapon` (open, weapon clicked, mod fitted) and with
  **None** from `NativeOnDeactivated`.
- Marco `7211269b7` + `5686a2767`: 4th component `Mods_SelectedWeapon` (hidden by default); BeginPlay
  binds the event next to `OnBarrackLoadout_UpdateEvent`; valid item → hide `Primary`/`Utility`/`Melee`,
  show `Mods_SelectedWeapon`, `UpdateSlotMeshByItemDefinition(Item, Slot = Mods_SelectedWeapon)`;
  None → reverse.

🔴 **`UpdateSlotMeshByItemDefinition(ItemDefinition, Slot)`: `Slot` is the `UStaticMeshComponent` to fill,
not a category.** Instructions that called it a category input cost two round trips. Verified headless:
load `L_LyraFrontEnd`, find the placed stand, `call_method("UpdateSlotMeshByItemDefinition", (ID_Rifle, Mods_SelectedWeapon))`
→ `Watermelon_Thompson` on the 4th slot. (Spawning actors with `EditorActorSubsystem` under `-NullRHI`
crashes on viewport placement; load the map and use the placed actor instead.)

## 6. Open

- Debug **Print String** in `Content/Weapons/B_Weapon` (shot `LineTraceSingle`), added in Marco's
  `d841c0f27` "WeaponTrace rework" (2026-07-15). Editor removal; also check the trace's Draw Debug Type = None.
- Healing-ammo GEs (Marco `7211269b7`): GrenadeLauncher/RocketLauncher/MadZooka/TrapGun went from
  heal-over-time (3 s, 1.5 s period) to one instant heal of the same base value, i.e. less total healing.
  Dan: parked, not acted on.
- In-match test after the next `build-all`: progression order (needs the real API), locked tiles with a
  real vault.
