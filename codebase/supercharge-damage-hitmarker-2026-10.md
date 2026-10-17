# Supercharge: initial damage, hit marker, damage number — as built (2026-10-17)

Two items from Marco's newer QOL card ("GA_Supercharge doesn't give initial damage", "Add reticle hitmarker to supercharge ability") plus the damage number pop that came up while testing. All **done 2026-10-17**, C++ only, compiled and PIE-tested (2 players) by Marco on his machine. **cooked in Steam demo build `2026-10-17_19-41` (BuildID 26014993, Edgegap verified), awaiting in-match testing.**

| Commit | What |
|---|---|
| `45fc9e3bb` | The attacker deals the initial hit damage (works in Editor + builds) |
| `5a755dd78` | Reticle hit marker when the dash damages an enemy |
| `f737611cb` | Damage number pop on the hit enemy |

Paths: `PLUGIN/` = `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/`. Asset facts were read off the real `.uasset`s via the LFS batch API (`strings`) and one Editor screenshot of `GCNL_Character_DamageTaken`.

---

## 1. How a Supercharge hit works (`PLUGIN/.../TotemAbilities/SuperChargeTotemGameplayAbility.cpp`)

- `GA_SuperCharge` (BP child of `USuperChargeTotemGameplayAbility`, `ReplicateYes`): root-motion dash (`FRootMotionSource_ConstantForce`), `UAbilityTask_WaitForTargetLoop` sphere overlap (`HitOverlapSphereRadius` 120) on the `PlayingCharacter` channel.
- `OnPawnsOverlapChanged` runs on **both** sides: skips teammates and anyone already hit this dash (`EverOverlappedActors`), launches the enemy (`HitLaunchXYStrength` 4000 / `HitLaunchZStrength` 500), turns him to face the attacker. On the **server only** → `ApplyStunAndDamageEffectsToCharacter`.
- BP-set classes: `HitDamageGameplayEffectClass` = `GE_Damage_SuperCharge`, `HitStunGameplayEffectClass` = `GE_StunEffect` (HasDuration, grants `Event.Movement.Stunned` + `GameplayCue.Character.Stun`, **no damage**), cooldown `GE_SuperCharge_Cooldown`, cue `GameplayCue.Character.Dash`.
- `GE_Damage_SuperCharge` → `GE_Damage_Basic_Instant` → `GameplayEffectParent_Damage_Basic`. Runs `LyraDamageExecution`; scoped modifier `LyraCombatSet.BaseDamage` (captured from **Source**) AddBase = Scalable Float × `CT_PlayerStats` / `Curve_Strength`, applied at **level 1**. `BaseDamage` is 0 on every player, so the damage is just that curve value. Inherits the parent's `GameplayCue.Character.DamageTaken`.

### Order after the fix
1. Build the damage spec from the ability → apply to the enemy → hit marker.
2. If the hit killed → stop (don't stun a dead character, his input would stay disabled).
3. Stun: animation tag (loose + replicated), input disabled both sides, `GE_StunEffect` applied by the victim to himself (`OnStunGameplayEffectRemoved` relies on the victim being the EffectCauser to re-enable input — keep it that way).

Knockback, stun, fall damage, team check and one-hit-per-dash are unchanged.

---

## 2. Initial damage (`45fc9e3bb`)

**Two bugs.**
1. **Never applied in the Editor.** `#if WITH_EDITOR if (ensureMsgf(IsValid(HitDamageGameplayEffectClass))) return;` — missing `!`, so a correctly set GE returned before the damage. `WITH_EDITOR` is off in cooked client and dedicated server, so builds did apply it → "works in prod, not in PIE".
2. **Self-damage in builds.** `ApplyGameplayEffectToSelf(..., Victim->MakeEffectContext())` made the victim the Instigator/EffectCauser. `CanCauseDamage(..., bAllowDamageToSelf = true)` let it through, but the kill counted as a suicide (no kill credit / assist / K/D/A XP for the attacker) and the Source-captured `BaseDamage` was the victim's.

**Fix.** `MakeOutgoingGameplayEffectSpec(HitDamageGameplayEffectClass, 1)` (Lyra's `MakeEffectContext` sets instigator = attacker's PlayerState, causer = attacker, ability source), `AddOrigin(attacker location)`, `OwnerASC->ApplyGameplayEffectSpecToTarget(spec, VictimASC)`. Both `WITH_EDITOR` guards became plain `ensureMsgf` checks (the stun one would otherwise crash a build with an unset class).

**Verified by Marco:** damage lands in PIE; a Supercharge kill shows the attacker in the kill feed.

**Tuning (Marco, no code):** `GE_Damage_SuperCharge` → Executions → `LyraDamageExecution` → Calculation Modifiers → `LyraCombatSet.BaseDamage` → type a fixed value in the Scalable Float (clear the curve row). Don't edit `Curve_Strength` itself. Players have 220–310 HP since QOL #10.

**Decided, not changed:** landing/fall damage after the knockback is left as is — `APlayingCharacter::Landed` applies `GE_Damage_FallDamage_Instant` only at downward speed ≥ `FallDamageVelocityRange.X` (C++ default 900); the knockback lands at ~500, so on flat ground there is none, only off a ~3 m ledge. It's applied by the victim to himself, so a fall kill stays a suicide. Damage level stays 1 (option A), not the attacker's Strength stat.

---

## 3. Reticle hit marker (`5a755dd78`)

**How hit markers work.** Every gun reticle `W_Reticle_*` (all 16 checked) contains a `HitMarkerConfirmationWidget`. Its Slate widget asks the PlayerController's `ULyraWeaponStateComponent` each frame for `GetTimeSinceLastHitNotification()` (fade over `HitNotifyDuration` 0.4 s) and `LastWeaponDamageScreenLocations` (per-hit images + the centre "any hit" image). **Only gun fire fed it**: `AddUnconfirmedServerSideHitMarkers` (`LyraGameplayAbility_RangedWeapon.cpp:617`) → server `ClientConfirmTargetData` (`:532`). Grenades, melee, totems: no marker. `UpdateDamageInstigatedTime` has no callers.

**Two different markers.** Marco first saw a marker only on kills — that is the **elimination marker** (`MI_UI_Reticles_EliminationMarker`), driven by an `AsyncAction_ListenForGameplayMessage` on the elimination message inside each reticle BP. It started showing because of the damage fix (the attacker became the killer). The per-hit marker is the `ULyraWeaponStateComponent` path.

**Fix.** `Source/LyraGame/Weapons/LyraWeaponStateComponent.h/.cpp`:
- `UFUNCTION(Client, Reliable) ClientShowHitMarker(const FVector_NetQuantize& WorldLocation)` — `ActuallyUpdateDamageInstigatedTime()`, project to screen, add a `bShowAsSuccess` entry. Same result as a confirmed gun hit.
- `static LYRAGAME_API ShowHitMarkerForController(const AController*, const FVector&)` — finds the component and calls the RPC. **Needed because `ULyraWeaponStateComponent` isn't exported** (no `LYRAGAME_API` on the class), so plugin code can't call its members or `StaticClass()` directly. Bots have no component → no-op.
- Supercharge calls it on the server right after applying the damage, with the enemy's location. Server-confirmed, like gun hits.

**Reusable:** grenades, melee and the thrown melee weapon can get a hit marker with the same one-line call.

**Verified by Marco.** Open: with a melee weapon in hand there is probably no reticle (no melee `W_Reticle_*` in the repo), so no marker.

---

## 4. Damage number pop (`f737611cb`)

**How damage numbers work.** Not from the weapon — from the damage cue. `GameplayEffectParent_Damage_Basic` has `GameplayCue.Character.DamageTaken`, inherited by every damage GE (Pistol, Grenade, SuperCharge, …). `GCNL_Character_DamageTaken` → `On Execute`, "pop up numbers" section:
- `EffectContextGetInstigatorActor` → `IsLocallyControlled` → only the attacker sees the number.
- `Get Component by Class` (`LyraNumberPopComponent`, on the PC; implementation `B_NiagaraNumberPopComponent` → `ULyraNumberPopComponent_NiagaraText`).
- **World Location = `EffectContext` → `Get Hit Result` → `Break Hit Result` → `Location`** (confirmed from Marco's screenshot).
- Number = cue magnitude → `Round`; critical = `Evaluate Weak Spot` on the hit's PhysMat (`Gameplay.Zone.WeakSpot`).
- Same graph also broadcasts `Lyra.Damage.Taken.Message` and plays the hit montage / damage-taken audio.

**Bug.** Supercharge's damage context had no hit result → `Location` (0,0,0) → the number spawned at the world origin.

**Fix.** Before applying, `DamageContext.AddHitResult(FHitResult(Enemy, Enemy capsule, enemy location, normal toward the attacker), true)` with `TraceStart` = attacker, `bBlockingHit`. No PhysMat → never critical (no headshots on a dash). Damage unchanged: `LyraDamageExecution` only uses the hit to find the hit actor (same enemy); distance still comes from the origin.

**Verified by Marco.**

---

## Lessons
- **A damage effect applied with the victim's own context is self-damage**: works on the health bar, breaks kill credit, assists, XP, hit markers and number pops (all key off the instigator / context). Build damage with `MakeOutgoingGameplayEffectSpec` from the attacking ability.
- **Damage numbers need a hit result in the effect context** — any non-trace damage (abilities, AoE) must `AddHitResult` or its number pops at the world origin.
- **Hit markers are gun-only by design in Lyra**; non-weapon damage needs `ShowHitMarkerForController`.
- **Watch inverted `ensure` under `#if WITH_EDITOR`** — the Editor and builds then disagree silently.
- `ULyraWeaponStateComponent` (and other Lyra classes without `LYRAGAME_API`) can't be used from the plugin; export a single static helper rather than the whole class.

## Open
1. Grenade / melee / thrown melee: hit marker via the same helper (and check whether their damage contexts carry a hit result for the number pop).
2. Melee-in-hand reticle: no hit marker element.
3. Dedicated-server test in a real match (cooked in `2026-10-17_19-41`, PIE-verified only).
