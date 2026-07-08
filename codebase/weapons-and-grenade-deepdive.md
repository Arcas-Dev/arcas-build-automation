# Weapons System + Grenade — Deep Dive

**Created**: 2026-07-01 · **Updated**: 2026-07-05 (§6 hitscan trace/range/VFX; melee-throw shipped)
**Purpose**: Understand how weapons + the grenade work. Originally written to build Marco's two throwable-melee tasks:
1. `MeleeWeaponProjectile` (C++) — like `B_Grenade` but applies GE to the hit target instead of detonating; re-equips the melee weapon on walk-over or after a 5s cooldown.
2. `GA_ThrowMeleeWeapon` (C++) — like `GA_Grenade` but equips the **Unarmed** ID into the melee slot when the throw montage's gameplay-event notify fires.

Both are now **BUILT & shipped** — see [[melee-throw-implementation-spec]] "AS-BUILT". §6 (added 2026-07-05) covers the **hitscan ranged-weapon trace, range & impact VFX** (Marco's "infinite range" bug).
**Method**: read-only, from the local source-only clone (`repos/ApeShooter`). Blueprint `.uasset` logic still needs the Editor.

---

## 1. Weapon framework (Lyra-based)

Weapons are Lyra inventory/equipment items, defined by assets, driven by GAS:
- **`ID_<Weapon>`** = `ULyraInventoryItemDefinition` (the item; e.g. `ID_Pistol`, `ID_Spear`, `ID_UnarmedMelee`). Composed of **fragments** (`InventoryFragment_EquippableItem`, `_ReticleConfig`, `_GrantAdditionalAbilities`, `_BarrackSlot`, etc.).
- **`WID_<Weapon>`** = the equipment/weapon definition (visual actor + attach).
- **`B_WeaponInstance_<Weapon>`** = `ULyraWeaponInstance` / `BASRangedWeaponInstance` runtime instance.
- **`AbilitySet_Shoote<Weapon>`** = `ULyraAbilitySet` granting the weapon's GAs (fire, reload, attack, throw).
- Weapon C++ base classes live in `Source/LyraGame/Weapons/` (`LyraWeaponInstance`, `LyraRangedWeaponInstance`, `BASRangedWeaponInstance`, `LyraGameplayAbility_RangedWeapon` → `BASGameplayAbility_RangedWeapon`).

### Equip / weapon slots — `ULyraQuickBarComponent` (`Source/LyraGame/Equipment/`)
The held-weapon slots. **`NumSlots = 3`** (Primary / Secondary / Melee categories). Key API:
| Method | Use |
|--------|-----|
| `AddItemToSlot(int32 SlotIndex, ULyraInventoryItemInstance* Item)` | put an item in a slot *(AuthorityOnly)* |
| `RemoveItemFromSlot(int32 SlotIndex)` | take the item out, returns it *(AuthorityOnly)* |
| `SetActiveSlotIndex(int32)` | equip the item in that slot *(Server Reliable)* — internally `UnequipItemInSlot()` + `EquipItemInSlot()` |
| `GetSlots()` / `GetActiveSlotItem()` / `GetActiveSlotIndex()` | reads |
Slots replicate (`OnRep_Slots`, `OnRep_ActiveSlotIndex`) + broadcast `FLyraQuickBarSlotsChangedMessage`. Actual equip visuals go through `ULyraEquipmentManagerComponent`.
→ **"Equip Unarmed ID to the melee slot"** = build a `ULyraInventoryItemInstance` for `ID_UnarmedMelee`, then `AddItemToSlot(meleeIndex, unarmedInstance)`. Restoring the weapon = `AddItemToSlot(meleeIndex, originalInstance)`.
⚠️ **Which index is the melee slot** is set when the loadout populates the quickbar (by convention/position, likely 2), not hardcoded in the component — **confirm in Editor / loadout code**.

---

## 2. Projectile hierarchy (all C++, `BASShooterCore/.../Actors/TeamProjectiles/`)

```
AActor
 └─ ATeamProjectile                     mesh + UProjectileMovementComponent; team-colored trail;
     │                                   OnOwningCharacterEliminated() → destroy; elim-message listener
     └─ ATeamProjectileWithDetonation   Detonate(loc,normal) → spawn DetonateGameplayCue + Destroy();
         │                               OnOwningCharacterEliminated() → Detonate()
         └─ AGrenade                     ← B_Grenade's parent
```
`B_SpearProjectile`, `B_AxeProjectile`, `B_RocketLauncherProjectile`, etc. are **Blueprints** on this chain (no per-weapon C++). This is why the new `MeleeWeaponProjectile` is a C++ addition — there's no reusable single-target throwable-projectile base yet.

### `AGrenade` (`Grenade.cpp`) — the reference behaviour
- **Ctor**: `ProjectileMovementComponent` InitialSpeed 2500 / Max 2550, `bShouldBounce`, Bounciness 0.3, Friction 0.8, rotation-follows-velocity; mesh collision `QueryOnly`.
- **`BeginPlay`**: `SetUpDetonationTimer()` (server timer, `DetonationTime=2s` → `DetonateAtCurrentLocation`), `SetUpIgnoringCharacterCollision()` (ignore owner capsule for `IgnoreOwningCharacterTime=0.16s` so it doesn't bounce off the thrower), `LoadDamageGameplayEffectClassAsync()`.
- **`NotifyHit`**: play `HitSound`; via `ULyraTeamSubsystem::CompareTeams(owner, other) == DifferentTeams` → `Detonate(impactPoint, impactNormal)`. **This team check is exactly what a melee projectile needs to decide "hit an enemy".**
- **`Detonate`**: ensure GE class loaded (defer if async not ready) → `DamagePawnsInDetonationRadius` → `Super::Detonate` (cue + destroy).
- **`DamagePawnsInDetonationRadius`** (AoE): `FDamageFunctionLibrary::CalculateOverlapDamage(...)` sphere overlap → for each pawn `OwningASC->ApplyGameplayEffectToTarget(GE->GetDefaultObject(), TargetASC, Level, Context, PredKey)`.
- **`OnOwningCharacterEliminated()`** overridden to **no-op** (grenade shouldn't detonate when its thrower dies).
- Key tunables (EditDefaultsOnly, set in `B_Grenade` BP): `DamageGameplayEffectClass`, `DamageRadius=450`, `DetonationTime`, `DamageGameplayEffect{Min,Max}Level`, `HitSound`.

**GE application, single-target version (task 1):** skip `CalculateOverlapDamage`; on the enemy `NotifyHit`, call `OwningASC->ApplyGameplayEffectToTarget(GE->GetDefaultObject(), UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(HitActor), Level, Context, PredKey)` directly.

---

## 3. Grenade throw ability — `UGrenadeTotemGameplayAbility` (GA_Grenade's parent)

Base: `UTotemGameplayAbilityBase`. Flow:
1. **`ActivateAbility`**: `CommitAbility` + ensure montage set; server: `GrenadeSpawner.LoadActorClassAsync()`; async-load `ThrowGrenadeAnimMontage` → `OnThrowGrenadeAnimMontageLoaded`.
2. **`OnThrowGrenadeAnimMontageLoaded`**: `PlayMontage(ThrowGrenadeAnimMontage)`; **server only** → register on `ASC->GenericGameplayEventCallbacks[ThrowGrenadeGameplayEventTag]` → `OnThrowGrenadeGameplayEventReceived`.
3. **`OnThrowGrenadeGameplayEventReceived`** ← fired by an **AnimNotify (gameplay event) in the throw montage** at the release frame → `GrenadeSpawner.SpawnActorAsync(character)`.
4. **`OnGrenadeSpawned`** → `EndAbility`.
5. **`EndAbility`**: cancel montage-load handle, `GrenadeSpawner.UnloadActorClass()`, remove the event callback.

- **`FActorWithCharacterRotationAndOffsetSpawner GrenadeSpawner`** — struct that async-loads + spawns an actor at the character's rotation + offset, with `OnActorSpawned` delegate. Reusable for spawning the melee projectile.
- **`ThrowGrenadeGameplayEventTag`** = the montage's gameplay-event notify tag. **This is the exact "gameplay event notify on the throwing montage" hook Marco refers to** — the point where we'd both spawn the projectile *and* equip the Unarmed melee ID.

### Existing precedent (Blueprint): `GA_ThrowSpear`, `GA_ThrowAxe`
Spear & Axe are **already throwable melee weapons**, done in **Blueprint**: each has `GA_Throw{Spear,Axe}` + `GA_{Spear,Axe}_Attack` + `B_{Spear,Axe}Projectile` + `AbilitySet_Shoote{Spear,Axe}`. Marco's tasks generalize this BP pattern into reusable **C++** base classes. → Inspect `GA_ThrowSpear` + `B_SpearProjectile` in the Editor; they're the closest working reference and likely mirror the grenade C++ flow.

---

## 4. Implementation plan (BUILT — see [[melee-throw-implementation-spec]] "AS-BUILT" for the final shipped shape)

### Task 1 — `AMeleeWeaponProjectile : public ATeamProjectile`
(Choose `ATeamProjectile`, not `...WithDetonation`, since it doesn't detonate.)
- Reuse from `AGrenade`: projectile-movement config, ignore-owner-collision window, team-check in `NotifyHit`.
- **On `NotifyHit` vs enemy** (`CompareTeams == DifferentTeams`): apply `DamageGameplayEffectClass` **to that single target's ASC** (no radius). Then stop/embed the projectile in the world as a pickup (stop movement, keep actor).
- **Re-equip triggers** (server): (a) owner-overlap detection (sphere/overlap component) when the thrower walks onto it; (b) `FTimerHandle` for a **5s cooldown**. Whichever first → fire a re-equip signal (gameplay event/message to the ability or directly to the owner's quickbar) and `Destroy()` the projectile.
- Tunables (EditDefaultsOnly): `DamageGameplayEffectClass`, damage level range, `ReEquipCooldown=5`, `IgnoreOwningCharacterTime`, pickup radius, `HitSound`.

### Task 2 — `UThrowMeleeWeaponGameplayAbility` (GA_ThrowMeleeWeapon)
Mirror `UGrenadeTotemGameplayAbility`'s montage→event→spawn flow. Base TBD: likely `ULyraGameplayAbility_FromEquipment` (it's a weapon ability, not a totem) while copying the grenade's structure — **confirm the right base** (vs `UTotemGameplayAbilityBase`).
- On the **throw montage gameplay-event notify** (server): (1) spawn the `MeleeWeaponProjectile` via an `FActorWithCharacterRotationAndOffsetSpawner`; (2) **`AddItemToSlot(meleeIndex, UnarmedMeleeInstance)`** on the owner's `ULyraQuickBarComponent` so the melee slot becomes Unarmed while thrown (create the instance from `ID_UnarmedMelee`).
- Store the removed real melee item instance so the projectile's re-equip signal can restore it via `AddItemToSlot(meleeIndex, originalInstance)`.

---

## 5. Open questions — confirm in Editor / loadout code before coding
- **Melee slot index** in `ULyraQuickBarComponent` (how the loadout maps category → slot; likely 2).
- How `GA_ThrowSpear` / `B_SpearProjectile` actually work (they're the working BP reference) — reparent them to the new C++ or leave separate?
- Correct **base class** for the throw ability (equipment weapon ability vs totem base).
- Where the throw is **triggered** from (input → which montage carries the gameplay-event notify) and the **event tag** to listen for.
- How to build a `ULyraInventoryItemInstance` for `ID_UnarmedMelee` at runtime (inventory manager vs transient instance).

> **All five resolved during the build** — see the RESOLVED list in [[melee-throw-implementation-spec]] (melee slot = 2; base = `ULyraGameplayAbility`; glide tag = `Event.Movement.Gliding`; Unarmed via `AddItemDefinition`; death auto-handled by `EquipWeapons`).

---

## 6. Hitscan ranged weapons — trace, range & impact VFX (added 2026-07-05, **rewritten + FIXED 2026-07-08**)

> **AS-BUILT (2026-07-08, commit `2910a4321` on `deploy/steam-testing`)** — `MaxTraceRange` added to `ULyraRangedWeaponInstance`; `:402` now uses `GetMaxTraceRange()`. Default `-1` = fall back to `MaxDamageRange`, so **no weapon changes behaviour until authored** in its `B_WeaponInstance_*` asset. Caps every pellet, since `EndTrace` is computed inside the `BulletsPerCartridge` loop.
> **⚠️ NOT YET COMPILED** — build VM stocked out (L4 unavailable, `europe-west6-b`).
> **⚠️ Blueprint cleanup still owed** — delete the `Add Limit to trace` box + `TraceMaxDistance` / `Object Types` vars from `GA_Weapon_Fire`. **C++ first, recompile, then delete**, or the graph breaks in between.
> Diagram: `arcas-champions/docs/weapon-trace-clamp-fix.drawio.svg` (+ `.png`) — note its "change #1" is superseded by the C++ fix; keep it only for the *why it failed* explanation.

### Correcting the original 2026-07-05 diagnosis
The first pass here claimed traces had **"effectively infinite range"** and that the offending guns had `MaxDamageRange` "cranked very high". **Both were wrong.** Read off the actual assets:

| Weapon (`B_WeaponInstance_*`) | `MaxDamageRange` | Pellets | Sweep radius | Falloff last key |
|---|---|---|---|---|
| MadRifle | 15000 cm (150 m) | 1 | 5.5 cm | ~8192 cm |
| Shotgun  | 5000 cm (50 m)   | 3 | 0.4 cm | ~3072 cm |

The trace was always bounded — just *long*. Three further corrections:
- **`MaxDamageRange` is never assigned in C++**; the only occurrence is the `25000.0f` default. Per-weapon values are class defaults on the **`B_WeaponInstance_*`** blueprints. It is **not** on `WID_*` — those are `ULyraEquipmentDefinition` (only `InstanceType`, `AbilitySetsToGrant`, `ActorsToSpawn`).
- **`EndAim` (`:371`) is dead code** — written once, never read anywhere. There is no "aim trace" to preserve.
- The runtime stats system (`FBASRangedWeaponStatsSettings::TryApplyStats`) tunes only Power / Spread / Handling / `DistanceDamageFalloffCoefficient`. **It cannot touch range.**

### Where the trace happens (all base Lyra — BAS does NOT override it)
`Source/LyraGame/Weapons/` — `UBASGameplayAbility_RangedWeapon` overrides **only** `IsDataValid`; the whole trace path is inherited from `ULyraGameplayAbility_RangedWeapon`:

```
StartRangedWeaponTargeting / PerformLocalTargeting
  → TraceBulletsInCartridge   (LyraGameplayAbility_RangedWeapon.cpp:385)   one loop per pellet (BulletsPerCartridge)
      → DoSingleBulletTrace    (:295)   ray first, falls back to sweep if SweepRadius>0 and ray missed
          → WeaponTrace        (:146)   the actual LineTraceMultiByChannel / SweepMultiByChannel
```

### The range knob — was `MaxDamageRange`, now `MaxTraceRange`
The bullet trace end is computed at **`LyraGameplayAbility_RangedWeapon.cpp:402`**, inside the per-pellet loop:
```cpp
const FVector EndTrace = InputData.StartTrace + (BulletDir * WeaponData->GetMaxTraceRange());  // was GetMaxDamageRange()
```
Both live on `ULyraRangedWeaponInstance` (`LyraRangedWeaponInstance.h`) and are `EditAnywhere` → authored per weapon on `B_WeaponInstance_*`:
```cpp
float MaxDamageRange = 25000.0f;   // 250 m default
float MaxTraceRange  = -1.0f;      // -1 = use MaxDamageRange
float GetMaxTraceRange() const { return MaxTraceRange > 0.0f ? MaxTraceRange : MaxDamageRange; }
```
`GetBulletTraceSweepRadius()` (default 0 = pure ray) is the pellet "thickness".

**Tuning rule:** don't set `MaxTraceRange` below the falloff curve's last key, or you delete damage that currently lands. Above it you're only trimming the flat extrapolated tail. Suggested: Shotgun ~3000, MadRifle ~8200.

### Why a miss draws the beam/hole to the horizon (the VFX smoking gun)
`TraceBulletsInCartridge` **:429-436** — when a pellet hits nothing it plants a *fake* impact at the trace end so tracers/beams still have an endpoint:
```cpp
if (OutHits.Num() == 0) {
    if (!Impact.bBlockingHit) {
        Impact.Location    = EndTrace;   // full trace range downrange
        Impact.ImpactPoint = EndTrace;
    }
    OutHits.Add(Impact);
}
```
That hit result is packed into `FLyraGameplayAbilityTargetData_SingleTargetHit` (`:597-599`) and drives the cosmetic layer, so the waterbeam + bullet-hole decal read `ImpactPoint` → on a miss they extend to the full trace range.

**Crucially, `Distance` is NOT rewritten here.** `WeaponTrace` starts with `FHitResult Hit(ForceInit)` → `Distance = 0`, and on no-hit sets only `TraceStart`/`TraceEnd`. So a clean miss arrives at the cosmetic layer as `bBlockingHit=false, Distance=0, ImpactPoint=<full range>`. This is what defeated the old Blueprint clamp (below).

### The dead Blueprint clamp — `GA_Weapon_Fire` → `Add Limit to trace` (to be deleted)
`GA_Weapon_Fire` (parent: `UBASGameplayAbility_RangedWeapon`) had a BP variable **`TraceMaxDistance`** wired into a comment box that broke the hit result, tested `Distance > TraceMaxDistance`, and on true swapped `Location`/`ImpactPoint` for `TraceStart + Normalize(TraceEnd - TraceStart) * TraceMaxDistance` via four `Select Vector` nodes, feeding a rebuilt `Make Hit Result`. **It was never orphaned — it was broken, in two ways:**

1. **Predicate keys off `Distance`, which is `0` on a miss.** `0 > TraceMaxDistance` is false → the unclamped `ImpactPoint` passes straight through. The clamp therefore only ever fired on *genuine blocking hits* beyond the limit — visible in-game as "bullet mark appears on a wall under ~50 m, disappears when you walk back", which is the clamp firing and (wrongly) suppressing a legitimate decal via its `NOT` → `Blocking Hit` wire.
2. **It reads `Get Hit Result from Target Data` at `Index 0` only.** Single-pellet rifles look fine; on a 3-pellet shotgun only the first pellet is clamped and pellets 1–2 draw unclamped. This is why "the Blueprint works for normal bullets but not for shotguns."

Both are structural, which is why the fix moved to C++ at `:402` — `EndTrace` is per-pellet, so all pellets are capped, and a wall inside the cap gets a normal decal.

### ⚠️ Two latent multi-pellet bugs (pre-existing Lyra, NOT introduced by the fix)
Both stem from `OutHits` being a **single array shared across all pellets** in `TraceBulletsInCartridge`:
- **`:429`** — `if (OutHits.Num() == 0)`: once pellet 0 adds anything, pellets 1–2 can never plant a fake impact. A shotgun that misses everything draws **one** beam, not three.
- **`:309` / `:314`** — `if (FindFirstPawnHitResult(OutHits) == INDEX_NONE)`: once *any* pellet hits a pawn, remaining pellets **skip tracing entirely**. A shotgun may register only **one pellet's** damage on a player. Worth chasing independently.

### Damage is genuinely independent of the trace length
`ULyraRangedWeaponInstance::GetDistanceAttenuation` (`LyraRangedWeaponInstance.cpp:125`):
```cpp
const FRichCurve* Curve = DistanceDamageFalloff.GetRichCurveConst();
return Curve->HasAnyData() ? Curve->Eval(Distance) : 1.0f;   // sampled by ABSOLUTE distance, NOT normalized by MaxDamageRange
```
BAS adds the curve + a `DistanceDamageFalloffCoefficient` on `UBASRangedWeaponInstance` (`BASRangedWeaponInstance.cpp:254` scales the curve's time keys; tuned data-side by `FBASRangedWeaponStatsSettings`).

**But note the `HasAnyData()` ternary and `FRichCurve`'s default constant extrapolation:** past the last key the curve returns that key's value, and an *empty* curve returns `1.0f` at any distance. Both shipped curves bottom out at **0.50, not 0.0** — so the MadRifle does flat 50% damage from 82 m → 150 m, and the **shotgun does 50% per pellet from 30 m → 50 m**. That is a *data* bug, independent of the trace, and likely a large part of what players feel as "this gun reaches forever". **Curves should reach 0.0.** Editor-side, no build needed.

Deliberately **not** addressed by the `MaxTraceRange` change (Dan, 2026-07-08: *"don't focus so much on the damage"*).

### ⚠️ Suspected: `SetDistanceDamageFalloffCoefficient` compounds
`BASRangedWeaponInstance.cpp:258-261` multiplies the curve's `Key.Time` **in place**:
```cpp
for (FRichCurveKey& Key : DistanceDamageFalloff.GetRichCurve()->Keys) { Key.Time *= DistanceDamageFalloffCoefficient; }
```
Call it twice on the same instance and the scaling compounds. Probably safe if instances are fresh per-equip — **instance lifetime not verified.**

### Caveat carried by the shipped fix
Capping the bullet trace also caps where a hit can **register** (no damage past where you trace). Dan signed off on this explicitly (2026-07-08: *"capping where a hit can register based on its trace ending is fine, makes sense"*). Keep `MaxTraceRange` ≥ the falloff curve's last key unless the damage loss is intended.

### Related weapon data-flow facts (from the vault work)
New guns (MadRifle, MadBlower) are added by authoring the C++/BP weapon assets + editing `DT_AllVaultItems` — see [[barracks-vault-flow]]. The MadBlower's waterbeam is the VFX that surfaced this trace-range issue.
