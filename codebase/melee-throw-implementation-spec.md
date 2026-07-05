# Throwable Melee Weapon — Implementation Spec

**Created**: 2026-07-01 · **Updated**: 2026-07-05
**Status**: ✅ **BUILT & shipped** (both C++ classes on `deploy/steam-testing`, deployed, Marco playtested). Sections below are the original spec; the **AS-BUILT** block right under this header is the authoritative final shape — read it first, it captures the deviations from the spec.
**Background/deep-dive**: [[weapons-and-grenade-deepdive]]
**Goal**: Two **general, reusable** C++ base classes (not Spear/Axe-specific) so any melee weapon can be thrown. Spear/Axe (currently Blueprint) can later reparent onto these.

---

## AS-BUILT (2026-07-05) — the authoritative final shape

Two C++ classes shipped (files exact):
- `BASShooterCoreRuntime/…/AbilitySystem/Abilities/ThrowMeleeWeaponGameplayAbility.h|.cpp` — `UThrowMeleeWeaponGameplayAbility : ULyraGameplayAbility`
- `BASShooterCoreRuntime/…/Actors/TeamProjectiles/MeleeWeaponProjectile.h|.cpp` — `AMeleeWeaponProjectile : ATeamProjectile`

**Final flow:** `ActivateAbility` (reset `bThrowExecuted`, commit, pick **grounded vs glider** montage via `HasMatchingGameplayTag(GlidingStateTag)`, async-load) → `OnThrowMontageLoaded` (`ASC->PlayMontage`; server registers `GenericGameplayEventCallbacks[ThrowGameplayEventTag]`) → **`OnThrowGameplayEventReceived`** (the throw-notify, once): `SwapMeleeSlotToUnarmed()` then spawn `AMeleeWeaponProjectile` via `FActorWithCharacterRotationAndOffsetSpawner` → `OnProjectileSpawned` hands the projectile the re-equip data (`InitializeReEquip`) → `EndAbility`. Projectile: flies, on contact **sticks into the hit character** and (if enemy) applies single-target damage GE, then re-equips the real weapon on **walk-over or after 5 s**. All authoritative work is **server-only**.

**Key deviations from the original spec (all from Marco's playtest feedback):**
1. **Swap happens on the throw-notify itself**, not at montage-end. (An intermediate "swap at montage end" version was tried and reverted — Marco confirmed the swap must fire on the same release notify.)
2. **The equip/unequip animations must NEVER cancel the throw montage.** Root cause found: the slot swap unequips the real weapon (fires its `OnUnequipped` montage) and equips Unarmed (its `OnEquipped` montage) — those montages interrupted the throw. **Fix is Blueprint-side**: Marco added a **`bSkipEquipMontage`** bool to `B_BASRangedWeaponInstance_Base` (on `UBASRangedWeaponInstance`) and gates the equip **and** unequip montages on it in the EventGraph (`K2_OnEquipped`/`K2_OnUnequipped` → Branch → skip the Activate-Anim-Layer / Play-Paired-Anim). The thrown weapon **and** Unarmed both have their montages skipped.
3. **Axe rotation** stopped because the C++ ctor set projectile-movement to orient to velocity — fixed with **`bRotationFollowsVelocity = false`** so the BP's own `RotatingMovementComponent` drives the spin.
4. **Damage wasn't applying on hit** with overlap-style weapons — added **overlap-based** damage (`OnComponentBeginOverlap` → `OnMeshBeginOverlap` → `HandleActorHit`) in addition to `NotifyHit`, since some weapons overlap rather than block.
5. **Stick-into-character** feature added: on hit, `StickToHitCharacter` attaches the projectile to the victim's mesh at `Hit.BoneName` (`KeepWorldTransform`) so it rides the body/ragdoll; stops flight + collision; arms pickup. Teammates get stuck-into (no damage), enemies get stuck-into + damaged.

**Guards / lifecycle:** `bThrowExecuted` (throw once), `bHasDealtDamage` (damage once), `bStuck`/`bPickupArmed`/`bReEquipped`. `ULyraGameplayAbility_FromEquipment` was **rejected** — not exported (`LYRAGAME_API`), so a plugin-module ability can't link it; melee is always slot 2 so `GetAssociatedItem()` wasn't needed anyway. Header includes `Inventory/LyraInventoryItemDefinition.h` (complete type for `TSubclassOf`). Unarmed placeholder is removed from the inventory on re-equip to avoid a leak.

**Still Editor/BP work for Marco:** reparent `B_Spear/AxeProjectile` (plain Actors today) → `AMeleeWeaponProjectile` and strip the placeholder visibility-toggle + tags; reparent `GA_ThrowAxe/Spear` (currently `GrenadeTotemGameplayAbility`) → the new ability; set the two montages + `ThrowGameplayEventTag` + `UnarmedMeleeItemDefinition`; ensure both montages carry the release-frame gameplay-event notify.

## The two responsibilities
| Class | Owns | One-line |
|-------|------|----------|
| `AMeleeWeaponProjectile` | **Behaviour + damage** | Flies like the grenade, deals GE damage to the enemy it hits, then lands as a pickup that re-equips the melee weapon on walk-over or after 5s. |
| `UThrowMeleeWeaponGameplayAbility` | **Animation + (un)equip** | Plays the throw montage (grounded vs glider), and on the montage's throw-notify: spawns the projectile + swaps the melee slot to Unarmed. |

They are linked only at the throw moment: the ability spawns the projectile and hands it what it needs to restore the weapon later; then the ability ends. The **projectile** owns the re-equip because the ability is gone by then.

---

## Current state of Spear/Axe (per Marco, 2026-07-01)
`B_SpearProjectile` / `B_AxeProjectile` are today **plain `AActor` Blueprints** (prototype) — **NOT** derived from `ATeamProjectile`/`AGrenade`. Each currently holds only: prototype throw mechanics, some **gameplay tags** used as a placeholder for the thrown/equipped state (**to be removed** once the real unequip mechanic replaces them), sound FX, Niagara, and the equip logic.
→ So `AMeleeWeaponProjectile` is a **from-scratch C++ base** (the first direct `ATeamProjectile` child). Migration = **reparent** `B_Spear/AxeProjectile` from `Actor` → `AMeleeWeaponProjectile`, **delete the placeholder tags/prototype logic** (now handled by the ability's quickbar unequip + the projectile's stored-item re-equip), and **keep** the mesh, sound FX, and Niagara as BP-set properties/components.

## Unequip / re-equip: fake (now) vs real (target)
**Now (prototype hack):** the thrown weapon is **never unequipped** — the held weapon mesh is just set **invisible** (`SetHiddenInGame`/visibility) and the "thrown" state is held in **placeholder gameplay tags**. Walking over the projectile (**collision**) flips the mesh **visible** again. So the player is still fully armed with an invisible weapon; no real unarmed state, animations don't switch, slot still holds the real weapon, networking is awkward.

**Target (real slot swap):** on throw → `RemoveItemFromSlot(melee)` (stash real weapon) + `AddItemToSlot(melee, ID_UnarmedMelee)` → genuine unarmed-melee state (real GAS/anims/abilities, no invisible mesh). The **trigger is unchanged** — owner overlaps the projectile's pickup collision (or 5s) → but now does a real `AddItemToSlot(melee, stashedWeapon)`. Deletes the visibility toggle + placeholder tags.

## Class 1 — `AMeleeWeaponProjectile` (behaviour + damage)

**Parent**: `ATeamProjectile` (NOT `...WithDetonation` — it doesn't detonate).
**File**: `BASShooterCore/.../Public|Private/Actors/TeamProjectiles/MeleeWeaponProjectile.h|.cpp`

### Reused from `AGrenade` (verbatim patterns)
- **Projectile movement** config in ctor (speed / bounce / friction / rotation-follows-velocity) — tunable per weapon in the derived BP.
- **Ignore-owner collision** on spawn: `IgnoreActorWhenMoving` both ways for `IgnoreOwningCharacterTime` (~0.16s), timer restores it. *(So you don't hit yourself on the way out.)*
- **Team check** in `NotifyHit`: `ULyraTeamSubsystem::CompareTeams(GetOwner(), Other)`. Only `DifferentTeams` deals damage; `SameTeam`/`InvalidArgument` (teammate/self/wall) → no damage.

### New behaviour (vs grenade)
1. **Single-target damage** (not AoE). On `NotifyHit` where `CompareTeams == DifferentTeams`:
   ```
   OwningASC->ApplyGameplayEffectToTarget(
       DamageGameplayEffectClass->GetDefaultObject<UGameplayEffect>(),
       UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(HitActor),
       DamageLevel, EffectContext, PredictionKey);
   ```
   No `CalculateOverlapDamage` sphere. Server-only. Apply once (guard `bHasDealtDamage`).
2. **Land as pickup** (don't destroy on hit). After the first impact (enemy or world), stop/settle the projectile so it can be retrieved. Enable an overlap component for pickup detection.
3. **Re-equip triggers** (server-authoritative, whichever fires first):
   - **Walk-over**: owner overlaps the projectile's pickup sphere → re-equip.
   - **Cooldown**: `FTimerHandle` for `ReEquipCooldown = 5s` from throw → re-equip.
   On trigger → `RestoreMeleeWeapon()` then `Destroy()`.

### How it restores the weapon (the link back)
The ability passes these to the projectile at spawn (setter or spawn params), held as UPROPERTYs:
- `TObjectPtr<ULyraQuickBarComponent> OwnerQuickBar`
- `TObjectPtr<ULyraInventoryItemInstance> StoredMeleeItem` (the real weapon removed from the slot)
- `int32 MeleeSlotIndex`
`RestoreMeleeWeapon()` = `OwnerQuickBar->AddItemToSlot(MeleeSlotIndex, StoredMeleeItem)` (replaces the Unarmed placeholder), authority-only.

### Members (tunable, EditDefaultsOnly)
`DamageGameplayEffectClass`, `DamageLevel` (or min/max), `IgnoreOwningCharacterTime`, `ReEquipCooldown=5`, `PickupRadius`, `HitSound`, movement config.

### Design decisions (resolved 2026-07-01, from `PlayingCharacter::EquipWeapons`)
- **Same instance, not recreate.** Stash the exact `ULyraInventoryItemInstance*` returned by `RemoveItemFromSlot` and re-add it (preserves per-instance state: weapon tuning/mastery). The projectile only holds a pointer — "destroy + re-add stash" and "same object" are equivalent.
- **Melee slot index = 2.** `EquipWeapons` fills slots in loadout order (`AddItemToSlot(i, …)`): Primary=0, Secondary=1, **Melee=2**.
- **Build the Unarmed instance** via `InventoryManagerComponent->AddItemDefinition(<ID_UnarmedMelee class>)` (same API the loadout uses), then `AddItemToSlot(2, unarmedInstance)`.
- **Owner death while unarmed → auto-handled.** On every (re)spawn `EquipWeapons()` calls `ClearInventory()` (full wipe) then rebuilds slots 0/1/2 from the loadout → the chosen melee weapon is restored in slot 2. So **no special death handling** — projectile just self-destroys on elimination (default `ATeamProjectile`), stash discarded, respawn rebuilds. ⚠️ *Confirm `EquipWeapons` runs on every respawn path (its trigger is the pawn's async weapon-class load), not only first spawn.*

### Other edge cases
- Projectile never hit an enemy (missed, hit wall) → still lands & is retrievable; no damage dealt.
- Prevent double-damage / double-re-equip with boolean guards.

---

## Class 2 — `UThrowMeleeWeaponGameplayAbility` (animation + (un)equip)

**Parent**: **`ULyraGameplayAbility`** (the exported Lyra base). ⚠️ We originally used `ULyraGameplayAbility_FromEquipment`, but that class is **not exported from LyraGame** (`class ULyraGameplayAbility_FromEquipment` — no `LYRAGAME_API`), so a plugin-module ability **can't link against it** (LNK2019 on its ctor/dtor/StaticClass/GetAssociatedItem). Since the only thing we used from it was `GetAssociatedItem()` to find the thrown weapon's slot — and **melee is always slot 2** — we dropped it and derive from `ULyraGameplayAbility` (which the totem abilities prove links cross-module). **Reimplement the grenade's montage→event→spawn flow** on it (those ~5 methods in `UGrenadeTotemGameplayAbility` are self-contained, not totem-specific).
> Editor-confirmed (2026-07-01): `GA_ThrowAxe`'s **current** parent is `GrenadeTotemGameplayAbility` — a **prototype shortcut** (the grenade's actor-spawner is generic, so it just spawns the axe). A thrown weapon is **not** a totem, so this is the class being replaced: `GA_ThrowAxe`/`GA_ThrowSpear` **reparent from the grenade totem → `UThrowMeleeWeaponGameplayAbility`**.
> Weapon input (Marco's prototype): melee weapon grants **aim = `AimDownSightsGameplayAbility`** (right-click, separate ability) + **throw = this ability** (left-click, fire input).
**File**: `BASShooterCore/.../AbilitySystem/Abilities/ThrowMeleeWeaponGameplayAbility.h|.cpp`

### Flow (mirrors `UGrenadeTotemGameplayAbility`)
1. **`ActivateAbility`**: `CommitAbility`; server pre-loads the projectile class; **select montage by movement state** (below); async-load + play it.
2. **On montage loaded** → `PlayMontage`; server registers on `ASC->GenericGameplayEventCallbacks[ThrowGameplayEventTag]` → `OnThrowGameplayEventReceived`.
3. **`OnThrowGameplayEventReceived`** ← the throw montage's **gameplay-event AnimNotify** at the release frame. Server-only, does the throw:
   - `StoredMeleeItem = OwnerQuickBar->RemoveItemFromSlot(MeleeSlotIndex)` (pull the real melee weapon).
   - Build an Unarmed instance from `ID_UnarmedMelee` → `OwnerQuickBar->AddItemToSlot(MeleeSlotIndex, UnarmedInstance)` (melee slot now shows Unarmed).
   - Spawn `MeleeWeaponProjectile` (via `FActorWithCharacterRotationAndOffsetSpawner`), then set its `OwnerQuickBar` / `StoredMeleeItem` / `MeleeSlotIndex`.
4. **On projectile spawned** → `EndAbility` (ability's job is done; projectile owns re-equip).
5. **`EndAbility`**: cancel montage-load handle, unload projectile class, remove the event callback.

### Animation: grounded vs glider montage (new requirement)
Two montage properties: `GroundedThrowMontage`, `GliderThrowMontage`.
The **behaviour is C++**; the **montages + the glide tag are set in the Editor** (properties). At montage-selection time, check movement state:
```
const bool bGliding = OwnerASC->HasMatchingGameplayTag(GlidingStateTag);   // GlidingStateTag = EditDefaultsOnly FGameplayTag property
UAnimMontage* Montage = bGliding ? GliderThrowMontage : GroundedThrowMontage;
```
Both montages carry the **same `ThrowGameplayEventTag` notify** at their release frame, so steps 3–4 are montage-agnostic.
✅ **Confirmed (Editor, 2026-07-01): the glide state tag is `Event.Movement.Gliding`** — it's `GA_Glide`'s **Activation Owned Tags**, so it sits on the owner ASC while gliding. It's a **project tag, not native C++** (the only native `Gliding` tag is the AI one `ArcasAI.Context.Gliding` — not this). So expose `GlidingStateTag` as an `EditDefaultsOnly FGameplayTag` **defaulted to `Event.Movement.Gliding`**. Behaviour = C++; the tag value lives in the property. (GA_Glide also has a separate `Gameplay.Message.Glide` message channel — not what we check.)

### The "Unarmed ID" and "melee slot"
- Unarmed = `ID_UnarmedMelee` (`.../Weapons/Unarmed/UnarmedMelee/ID_UnarmedMelee`). Runtime instance via the inventory manager or a transient `ULyraInventoryItemInstance` — **confirm which the codebase uses.**
- `MeleeSlotIndex` in `ULyraQuickBarComponent` (`NumSlots=3`) — **confirm the index the loadout assigns to melee** (likely 2).

---

## Cross-cutting: networking
All gameplay-authoritative work (spawn, GE apply, slot swaps, re-equip) is **server-only** — matches the grenade (`HasAuthority` / `K2_HasAuthority` gates, `AddItemToSlot`/`RemoveItemFromSlot` are `BlueprintAuthorityOnly`, quickbar slots replicate to clients). Client just plays the montage.

## Assets Marco creates after the C++ compiles (Editor)
- `B_MeleeWeaponProjectile` BP (reparent from `AMeleeWeaponProjectile`) per melee weapon, set `DamageGameplayEffectClass`/mesh/movement — or reparent existing `B_SpearProjectile`/`B_AxeProjectile`.
- `GA_ThrowMeleeWeapon` BP (reparent from the new ability), set the two montages + `ThrowGameplayEventTag`; grant via each melee weapon's `AbilitySet_`.
- Ensure the throw montages have the gameplay-event notify at the release frame.

## TODOs to confirm in-Editor / VM before/while coding
1. ~~Melee slot index~~ → **RESOLVED: slot 2** (Primary 0 / Secondary 1 / Melee 2, per `EquipWeapons`).
2. ~~Glide state gameplay tag~~ → **RESOLVED: `Event.Movement.Gliding`** (GA_Glide Activation Owned Tag; project tag → EditDefaultsOnly property defaulted to it).
3. ~~Throw ability base class~~ → **RESOLVED (as-built): `ULyraGameplayAbility`.** (We first tried `ULyraGameplayAbility_FromEquipment` but it's **not exported** — LNK2019 across the plugin module — and its only use `GetAssociatedItem()` was unnecessary since melee is always slot 2.) Current `GA_ThrowAxe`/`Spear` parent is `GrenadeTotemGameplayAbility` (prototype) → reparent to the new class.
4. ~~How to construct the `ID_UnarmedMelee` instance~~ → **RESOLVED: `InventoryManagerComponent->AddItemDefinition(class)`**.
5. ~~Owner death/respawn~~ → **RESOLVED: auto-handled by `EquipWeapons`/`ClearInventory` on respawn** (verify it fires on every respawn path).
6. Reparent existing `B_Spear/AxeProjectile` (plain Actors today) + `GA_ThrowSpear/Axe` onto the new bases, then strip their placeholder tags/prototype logic and keep sound/Niagara/mesh (this IS the migration path — see "Current state" above).
