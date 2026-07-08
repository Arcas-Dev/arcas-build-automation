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

> **⏸️ PARKED 2026-07-08 (low priority).** C++ is done, compiled and proven correct by logging. What remains is Editor-side only — see **§6b** below for the measured evidence, the exact fix, and the trap to avoid.
>
> **AS-BUILT (2026-07-08) — two commits on `deploy/steam-testing`:**
> 1. **`2910a4321`** — `MaxTraceRange` added to `ULyraRangedWeaponInstance`; `:402` now uses `GetMaxTraceRange()`. Default `-1` = fall back to `MaxDamageRange`, so **no weapon changes behaviour until authored** in its `B_WeaponInstance_*` asset. Caps every pellet, since `EndTrace` is computed inside the `BulletsPerCartridge` loop.
> 2. **`f85da3aa0`** — the `:429` per-pellet fix (see "the shotgun tracer bug" below). Required because capping the trace alone still left 3 of a 4-pellet shotgun's tracers unsourced.
>
> ✅ **Compiles**; `Max Trace Range` confirmed visible in `Weapon Config` on the `B_WeaponInstance_*` assets.
> ✅ **Blueprint cleanup DONE** — the `Add Limit to trace` box + `TraceMaxDistance` / `Object Types` vars have been deleted from `GA_Weapon_Fire`.
> ⬜ **Per-weapon tuning still owed** — every weapon is still at `-1`. PlasmaShotgun was set to 1000 cm during testing; verify that's intended (it's a 10 m gun).
> Diagram: `arcas-champions/docs/weapon-trace-clamp-fix.drawio.svg` (+ `.png`) — **historical only.** Its "change #1" (rewire the `>` node) was superseded; the Blueprint it describes no longer exists. Keep it for the *why the clamp never fired* explanation.

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

### The shotgun tracer bug — `:429`, fixed in `f85da3aa0`
**How the beams are actually drawn** (traced through the assets, 2026-07-08):
```
TraceBulletsInCartridge → OutHits → FLyraGameplayAbilityTargetData_SingleTargetHit (:597)
  → one GameplayCue execution PER TARGET-DATA ENTRY
    → GCN_Weapon_<Weapon>_Fire :: On Burst
       Break Gameplay Cue Parameters → Location (a SINGLE FVector) → Make Array → Fire(ImpactPositions, …)
       → NS_WeaponFire_Tracer_<Weapon> :: Set PARTICLES.HitPosition
            = Select Vector from Array( USER.ImpactPositions, index = Return Exec Index, mode = Clamp )
```
So **one target-data entry = one tracer**. The old guard was cumulative:
```cpp
if (OutHits.Num() == 0) { /* plant fake impact at EndTrace, add to OutHits */ }
```
`OutHits` is shared across the whole cartridge, so once pellet 0 added an entry, **any later pellet that hit nothing contributed no hit result at all** → no cue execution → no tracer, and the surviving tracers indexed past the end of `ImpactPositions` (defaults `0,0,0` → beams toward world origin). A pellet that *hits* always appends via `OutHits.Append(AllImpacts)`, so the bug only ever dropped **misses** — and it also **shifted the `ExecIndex → pellet` mapping**, wiring surviving tracers to the wrong pellets' endpoints.

Single-pellet weapons are structurally immune, which is why only shotguns showed it.

**Empirically confirmed before fixing** (Marco, in Editor): point-blank into a wall → all 4 pellets hit → all 4 beams correct. Aiming at open sky → **exactly one beam** from a 4-pellet gun. That one-beam result is what proved the cue count follows target-data entries (a Niagara/GCN-side fix would have been a no-op — those executions never happened).

Fix: make the guard per-pellet — `if (!HitActor || AllImpacts.Num() == 0)`.

### ❌ Correction: there is NO cross-pellet pawn short-circuit
An earlier draft of this doc claimed `:309`/`:314` (`FindFirstPawnHitResult(OutHits) == INDEX_NONE`) short-circuits tracing across pellets once any pellet hits a pawn, so a shotgun would register only one pellet's damage. **That is wrong.** `AllImpacts` is declared *inside* the pellet loop (`:405`) and is what's passed to `DoSingleBulletTrace`, so `FindFirstPawnHitResult` only ever sees the **current pellet's** hits. Every pellet traces. No damage is lost.

### ⚠️ Known remaining imprecision (not fixed)
`WeaponTrace` uses `LineTraceMultiByChannel` and appends **every** non-duplicate hit, so a single pellet can still contribute **more than one** entry (e.g. shooting through foliage). The `ExecIndex → pellet` mapping the Niagara system assumes is therefore still not strictly 1:1. Correct in the common case. A proper fix would hand the cue an explicit per-pellet endpoint array rather than inferring it from hit count.

### ⚠️ Watch after `f85da3aa0`
Misses now reach `AddUnconfirmedServerSideHitMarkers` (`:609`) and replicate (a 4-pellet miss sends 4 hit results, not 1). Misses carry no `HitActor` so `GE_Damage` cannot apply — but **if hit markers key off entry count rather than a valid pawn, expect phantom hitmarkers when missing.** Untested.

---

## 6b. Shotgun tracers — PARKED, low priority (2026-07-08)

**Status: the C++ is DONE and PROVEN. The remaining bug is entirely Editor-side (Blueprint + Niagara).**

### Measured ground truth
Temporary `UE_LOG` after `PerformLocalTargeting` (added as `b5a830ced`, reverted as `cf9e5bb23` — re-add it if you pick this up). PlasmaShotgun fired at open sky:
```
[TRACE] BulletsPerCartridge=4  MaxTraceRange=1000  FoundHits=4
[TRACE]   [0] blocking=0  actor=None  dist=1000
[TRACE]   [1] blocking=0  actor=None  dist=1000
[TRACE]   [2] blocking=0  actor=None  dist=1000
[TRACE]   [3] blocking=0  actor=None  dist=1000
```
Four target-data entries, one per pellet, each capped at exactly `MaxTraceRange`. **`MaxTraceRange` works. The `:429` per-pellet fix works.** In-game you still see **one** beam — so the cosmetic layer is discarding three of four hit results.

### Where they're discarded
`GA_Weapon_Fire` → `Event OnRangedWeaponTargetDataReady` → **`Get Hit Result from Target Data`, hardcoded `Index 0`.** Entries 1–3 are dropped there. One hit result → one cue execution → one tracer. Every downstream node is faithfully processing the single hit result it was handed.

The same `Index 0` read also feeds **impact decals and surface-type sounds** → one decal per cartridge, not one per pellet.

### The cosmetic chain (traced through the assets)
```
GA_Weapon_Fire (Index 0!) → GameplayCue → GCN_Weapon_<W>_Fire :: On Burst
  Break Gameplay Cue Parameters → Location (a SINGLE FVector)
    → Make Array (1 element) → Fire(ImpactPositions, ImpactNormals, ImpactSurfaceTypes)
      → B_WeaponFire :: EventGraph
          "Niagara Set Vector Array"  Override Name = User.ImpactPositions   ← OVERWRITES whole array
          "Set Niagara Variable (Bool)" User.Trigger                          ← fires the burst
            → NS_WeaponFire_Tracer_<W> :: Set PARTICLES.HitPosition
                 = Select Vector from Array( USER.ImpactPositions,
                                             index = Return Exec Index,
                                             mode  = Clamp )
```

### ⚠️ The trap — do NOT "just ForEach the cue"
The obvious fix (ForEach target data → execute the cue 4×) **will still produce one beam.** `Niagara Set Vector Array` overwrites the *entire* `User.ImpactPositions` on a Niagara component **shared by the weapon actor**, then trips `User.Trigger`. Four executions in one frame clobber each other before Niagara ticks. Last write wins.

`ImpactPositions[ExecIndex]` + `Clamp` tells you the intended design: **ONE call carrying all N endpoints, Niagara spawning N particles**, each reading its own index. Not N calls of 1 element.

### The fix (when picked up)
1. **C++** — add a helper so the BP can't mis-index (the three arrays must stay index-aligned):
   ```cpp
   UFUNCTION(BlueprintCallable, Category="Weapon")
   static void GetImpactsFromTargetData(const FGameplayAbilityTargetDataHandle& TargetData,
       TArray<FVector>& OutImpactPositions, TArray<FVector>& OutImpactNormals,
       TArray<TEnumAsByte<EPhysicalSurface>>& OutImpactSurfaceTypes);
   ```
2. **`GA_Weapon_Fire`** — delete `Get Hit Result from Target Data (Index 0)`, replace with the helper, route the three arrays onward.
3. **`NS_WeaponFire_Tracer_*`** — ⚠️ **mandatory, or nothing changes**: `Emitter Update → Spawn Per Frame` must spawn **one particle per array element** (add a `User.NumImpacts` int set alongside the array, or read the array length in Niagara). Spawn 1 → it reads index 0 → screen looks identical to today.
4. **`GCN_Weapon_<W>_Fire`** — remove the `Location → Make Array → Impact Positions` wiring. Keep sound / whiz-by / early reflections (genuinely per-shot).
5. Repeat 3–4 for **all three shotguns**: `Shotgun`, `PlasmaShotgun`, `DBShotgun` each have their own `GCN_` and tracer NS.

### Open unknowns (blockers for a precise spec)
- **The `Fire` function on `B_WeaponFire`** — is it BlueprintCallable from the GA, or reachable only from the cue notify? Because `FGameplayCueParameters` carries a single `Location`, the array **cannot** travel through the cue; the GA must call the weapon actor directly, or the tracer trigger must move out of the cue entirely.
- **How the GA gets the weapon actor reference** (`ULyraGameplayAbility_FromEquipment` has the equipment instance; the actor comes from `ActorsToSpawn`).
- **`Spawn Per Frame` config** in the tracer NS — fixed count or data-driven?

### Also still open (data-side, no build needed)
- **Per-weapon `MaxTraceRange` tuning.** Everything is still `-1` (= `MaxDamageRange`) except **PlasmaShotgun = 1000 cm**, set during testing. That makes it a 10 m gun that cannot register a hit at 11 m, and kills ~30 m of its falloff curve (last key ~4096). **Verify that's intended.**
- **Falloff curves bottom out at 0.50, not 0.0** — see §6 above.

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
