# QOL Features — Analysis (2026-09-09) + build day (2026-10-17)

> **Status 2026-10-17:** items **1, 4, 5, 8, 9, 10, 11, 12, 13 done** (C++ compiled + PIE-tested by Marco), first Steam build `2026-10-17_18-20` @ `8af840038` **failed at the server cook**: `IMC_Default_Gamepad` (unused in matches, untouched since 2025) shares `LyraPlayerMappableKeySettings` subobjects that live **inside `IMC_Default_KBM`**; deleting the `IA_WallMove` rows there removed `_5` → "Failed import" = cook error (the Editor only warns). Marco fixed it in the Editor (`67dcc7eab`, gamepad now borrows only `_6`/`_7`, both present); **rebuild `2026-10-17_19-41` COMPLETE: Steam demo `testing` BuildID 26014993, Edgegap `testing-server` = `2026-10-17_19-41` (verified GET). Needs in-match testing on Steam.** **Lesson: before deleting IMC rows, check other IMCs that borrow their key-settings subobjects; validate data before a build.** **Still open: 2 (phys materials), 3 (melee throw replication), 6 (Disguise crash, root cause below; `9e5bbd274` changed Disguise movement only), 7 (ADS tags)**, plus #9 step 2 (better wall detection).

Source: Marco's "QOL Features" card on the admin Kanban (created 19 Jul 2026), 8 checklist items.
Research done against `deploy/steam-testing` @ `e228c3a4e` (5 Sep 2026); item 8 re-checked @ `42c3c5e9f` (9 Sep). Nothing has been changed yet.

`.uasset` files are git-lfs pointers locally, so every Blueprint/data-asset fact below is either inferred from C++ or flagged "confirm in Editor".

Paths: `PLUGIN/` = `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/`.

---

## Summary table

| # | Item | Type | Root cause / mechanism found | C++ | Editor | Effort |
|---|------|------|------------------------------|-----|--------|--------|
| 1 | ✅ **DONE 2026-09-09** (`ad5953f9a`, `b544c2350`, `15de92556`, Marco PIE-tested; Disguise deliberately excluded) — Override movement state for totem activations | Feature | Deployment-anim base blocks activation on `Status.Moving` and cancels on any velocity. Lyra's `Gameplay.MovementStopped` tag exists, is read by the CMC, and is **unused** — it already ignores falling | ★ main | per-GA flag defaults | S–M |
| 2 | Set Phys Material in all maps | Data | Only 3 surfaces exist (Character/Concrete/Glass). Null phys mat = **silent footsteps + no context effects**, not "default". No project landscape LayerInfos | 1-line fallback | all the real work | M–L (Marco) |
| 3 | Refine replication code for throwing melee | Bug | "Stick into character" is server-only cosmetics; no `bInterpMovement`; `check()` on tag crashes dedicated server; overlap path passes an empty hit (no bone) | ★ all | none | M |
| 4 | ✅ **DONE 2026-10-17** (`5fc82e2fa`, `3f8527ebc` + Marco `b4f9711ac`, `d8f7b9add`) — Add icon to friendly totem devices | Feature | `ATeamDevice` has replicated `TeamId` + `IsSameTeamWithActor`. Three indicator systems exist (Lyra indicators, radar, WidgetComponent); no C++ caller of any | base class hook | icon widget/texture | S–M |
| 5 | ✅ **DONE 2026-10-17** (`c45676442`, `b1ba09e4b`) — Pop up on reticle when super totem active ("Super Totem Ready") | Feature | "Super totem" = Support slot (`USynergyTotemGameplayAbilityBase`). State is only local delegates on `UTotemGameplayAbilitySubsystem`; reticle base already has a message-listener pattern | ★ small | anim in reticle | S |
| 6 | Disguise Totem crash | Bug | `Disguise()` derefs `GetController()` unchecked + fatal `check`s on `AvatarActor`; the identical bug was fixed in `EndAbility` (`9ddc4498f`) but not here. Raw `ActorInfo*` in timer payloads | ★ all | confirm `Can Be Canceled` | S |
| 7 | Rework GA_AimingDownSights tags | Data | Asset is `GA_AimDownSights`. C++ base has **zero** tag logic; no `Status.ADS` tag exists; block/cancel pairs authored ad hoc in each GA (4 reactive fixes in history) | new tag + 2 small fixes | ★ tag relationships | S–M |
| 8 | ✅ **DONE 2026-09-09** (`f916f6e26`, `3bab700be`, Marco PIE-tested) — Blind + slow-down disappear when healed | Feature | No cleanse concept in project (zero `RemoveActiveEffectsWithGrantedTags` calls). Blind **visual** is a fire-and-forget RPC + local timer, so removing the GE alone won't clear the screen | heal hook + blind widget | granted tags on 4 GEs | M |
| 9 | ✅ **DONE 2026-10-17, step 1** (`3a20ad71e`, `daafe3de2`, `56029aab9` + Marco `226b072a4`, `985e1bb3c`, `8af840038`; step 2 wall detection open) — Double Jump / Wall Jump / Chicken Glider on one button, KBM + Gamepad *(newer card)* | Input | Jump + Glide share Space / A (Glide = Hold). V / B = WallMove, which **falls back to Roll → Air Roll (+400 Z) = the double jump** when no wall is found. Wall proximity = 3 chest-height rays, 100 cm | ★ arbitration in `UJumpGameplayAbility` (recommended) | IMC rows, WallMove fallback tags | S–M |
| 10 | ✅ **DONE 2026-10-17** (`b81d28db5`, Marco) — Drastically increase TTK by doubling health *(newer card)* | Data | Max health = `GE_Grant_Stamina` (Instant, Override) × `CT_PlayerStats.Curve_MaxHealth` at the champion Health stat. Curve doubled (220–310 HP in matches). Heals / burn / fall damage are absolute and were **not** scaled | none | curve | S |
| 11 | ✅ **DONE 2026-10-17** (`309a52cee`, `9e5bbd274`, Marco compiled + PIE-tested) — Remove standard sprint, keep only primal sprint *(newer card)* | Feature | Primal sprint = `GA_Sprint` while crouched. Now always crouches, pauses on uncrouch and resumes, no stamina, Ctrl ignored. Totems were crouch-blocked (fixed); deployment per-tick uncrouch outlived the animation (fixed); Disguise moved to `Gameplay.MovementStopped` | ★ sprint + totem base + Disguise | tag edits on 9 GAs | M |
| 12 | ✅ **DONE 2026-10-17** (`45fc9e3bb`, Marco PIE-tested) — GA_Supercharge doesn't give initial damage *(newer card)* | Bug | Inverted `ensure` under `#if WITH_EDITOR` skipped the damage in PIE; in builds it was applied by the victim to himself (suicide, no kill credit). Now `MakeOutgoingGameplayEffectSpec` from the attacker, level 1, damage before stun | ★ Supercharge | tune `GE_Damage_SuperCharge` | S |
| 13 | ✅ **DONE 2026-10-17** (`5a755dd78` hit marker, `f737611cb` damage number, Marco PIE-tested) — Reticle hitmarker for the Supercharge ability *(newer card)* | Feature | Hit markers were gun-only (`ULyraWeaponStateComponent`). New `ClientShowHitMarker` + exported `ShowHitMarkerForController`. Number pop reads its position from the context hit result, Supercharge had none → now `AddHitResult` | ★ Lyra component + Supercharge | none | S |

Item 4: as-built in **`friendly-device-indicator-spec.md`**. Items 5 and 9: as-built in their sections below. Items 10 and 11: full as-built, decisions and open points in **`ttk-and-primal-sprint-2026-10.md`**. Items 12 and 13: **`supercharge-damage-hitmarker-2026-10.md`**.

Effort: S = hours, M = a day, L = multi-day.

---

## 1. Override movement state for totem activations

**Marco's rule** (card comment, 19 Jul): Personal Healing must work while moving (like Supercharge and Grenade). All other totems must stop the player while the button is pressed, except when falling.

### As-is
- Class map (authoritative, from `PLUGIN/Private/AI/Services/BTService_SetLoadout.cpp:62-79`):

| Slot | Totems | Base |
|------|--------|------|
| Damage | Grenade, Supercharge, Rage | Base, Base, **Deployment** |
| Personal | PersonalHealing (`USelfHealingTotemGameplayAbility`), AmmoCrate, Disguise, AnimalInstinct | **Deployment**, **Deployment**, Base, **Deployment** |
| Support ("super") | TeamHealing, ChimpCompanion, AutoTurret | all `USynergyTotemGameplayAbilityBase` → **Deployment** |

- The whole movement rule lives in one constructor: `PLUGIN/Private/AbilitySystem/Abilities/TotemAbilities/TotemGameplayAbilityWithDeploymentAnimationBase.cpp:13-17` adds `Status.Crouching` + `Status.Moving` to `ActivationBlockedTags`. So today it is "can't even start while moving", plus `OnCharacterMovementUpdated` (`:80-105`) cancels the ability if velocity > 0 during the montage.
- `Status.Moving` is a per-frame loose tag set in `APlayingCharacter::Tick` (`PLUGIN/Private/Characters/PlayingCharacters/PlayingCharacter.cpp:96-107`).
- Grenade and Supercharge derive straight from `UTotemGameplayAbilityBase` and never touch movement, which is why they already work while moving.
- Disguise is the odd one: not deployment-based, hard-`DisableMovement()` at `DisguiseTotemGameplayAbility.cpp:52` (which also freezes a falling player, `MOVE_None`).

### The unused hook that does exactly what Marco wants
`Source/LyraGame/Character/LyraCharacterMovementComponent.cpp:22` defines `Gameplay.MovementStopped`. `GetMaxSpeed()` (`:158-173`) returns 0 and `GetDeltaRotation()` (`:145-156`) returns zero **only when `MovementMode == MOVE_Walking`**, so it inherently does nothing while falling. Nothing in the project applies this tag today.

Falling is also available as the loose tag `Movement.Mode.Falling` (`LyraCharacter.cpp:448-476`) or `GetCharacterMovement()->IsFalling()` (precedents: `RollGameplayAbility.cpp:104`, `WallMoveGameplayAbility.cpp:30`).

### Plan (C++)
1. Add `UPROPERTY(EditDefaultsOnly) bool bAllowMovementDuringDeployment = false;` on `UTotemGameplayAbilityWithDeploymentAnimationBase`. Set `true` in `USelfHealingTotemGameplayAbility` ctor (`SelfHealingTotemGameplayAbility.cpp:8-13`).
2. Remove `Status_Moving` from `ActivationBlockedTags` (ctor runs before BP defaults load, so gating must move into a `CanActivateAbility` override or simply be dropped).
3. On activation, if `!bAllowMovementDuringDeployment && !IsFalling()` → `SetLooseGameplayTagCount(TAG_Gameplay_MovementStopped, 1)`; clear in `EndAbility` (`:159-191`) and `CancelAbility`. Note this sets speed to 0 but leaves the player standing in a walking mode — no `MOVE_None` freeze.
4. `OnCharacterMovementUpdated` (`:80-105`): stop cancelling on velocity when the flag is set or when falling (otherwise the ability self-cancels the moment you move).
5. Disguise: add an `IsFalling()` guard around `DisableMovement()` or convert it to the tag approach.

### ✅ AS-BUILT (2026-09-09, all three steps Marco PIE-tested OK; Editor tag removal done by Marco on the 7 GAs)

### AS-BUILT step 1 (2026-09-09) — Personal Healing on the move
Dan's decision: Personal Healing = free movement during the whole heal (Marco reworks the montage to upper-body); the other six get "start while moving, then stop for the animation" in a later step.
- C++: `bAllowMovementDuringDeployment` (EditDefaultsOnly, default false) on `UTotemGameplayAbilityWithDeploymentAnimationBase`; `OnCharacterMovementUpdated` skips the velocity-cancel when set. `USelfHealingTotemGameplayAbility` ctor sets it true + removes `Status_Moving` from `ActivationBlockedTags`. Compiled OK.
- **Editor (Marco, required)**: `GA_SelfHealing` → Activation Blocked Tags: remove `Status.Moving` (and `Movement.Mode.Falling` if mid-air use is wanted). The BP class defaults override the C++ container, so without this the totem still refuses to start while moving.
- Other six totems untouched (they still block on Moving/Crouching/Falling and cancel on movement).

### AS-BUILT step 2 (2026-09-09) — the other six: start while moving, held for the animation
- C++ (base class only): `Status.Moving` removed from the ctor's `ActivationBlockedTags` (Crouching stays). Unless `bAllowMovementDuringDeployment`, `StartDeploymentAnimationAsync()` adds the loose tag `Gameplay.MovementStopped` on the owner's ASC (each side sets its own; `GetMaxSpeed()` reads locally). Released on montage blend-out (natural or interrupted), on interrupt, and in `EndAbility` (whichever first), via `StopCharacterMovement()` / `ReleaseCharacterMovement()` guarded by `bMovementStopApplied`. Velocity-cancel in `OnCharacterMovementUpdated` removed for everyone (it would fire during the braking frames); un-crouch kept. Falling: the tag is walking-only in the CMC, so a mid-air activation keeps falling and is held on landing — no extra code.
- Behaviour per totem (verified in code): Rage, AnimalInstinct, AutoTurret, TeamHealing **and ChimpCompanion** keep the ability alive past the montage (buff timers / synergy combo window / until the device is destroyed) → held for the **whole** montage. **AmmoCrate is the only one** that ends the ability at the deploy notify (`AmmoCrateTotemGameplayAbility.cpp:94`, right after spawning the crate) → hold released at the notify, the tail of the drop animation plays while moving; the crate itself is unaffected. If that looks wrong, Marco moves the notify later in `AM_MA_AmmoBoxDrop_01`.
- **Step 2b (same day, after Marco's first test)**: the character still crept forward with the stick held. `GetMaxSpeed() == 0` alone leaves `CalcVelocity` clamping input to `MinAnalogWalkSpeed` (a BP class default on the hero CMC). Fix in `ULyraCharacterMovementComponent`: `GetMinAnalogSpeed()` and `GetMaxAcceleration()` also return 0 while `Gameplay.MovementStopped` + walking (`IsMovementStoppedByGameplay()`), so input is ignored and braking gives a full stop. Disguise deliberately left on its old `DisableMovement()` path (Dan's call).
- Not covered on purpose: external displacement (knockback, Supercharge push) no longer cancels a deployment; Disguise (not deployment-based, hard `DisableMovement`) untouched.
- **Editor (Marco, required, 6 GAs)**: `GA_Rage`, `GA_AmmoCrate`, `GA_AnimalInstinct`, `GA_AutoTurret`, `GA_TeamHealing`, `GA_ChimpCompanion` → Activation Blocked Tags: remove `Status.Moving` (and `Movement.Mode.Falling` for mid-air activation). Optional: add `Ability.Type.Action.Glide/Roll/WallMove` to Block Abilities With Tag so a wall-jump can't break the held pose.

### Deeper pass (2026-09-09, BP class defaults read off the VM)
- **Every deployment-based GA carries `ActivationBlockedTags = {Status.Moving, Status.Crouching, Movement.Mode.Falling}`** (`GA_SelfHealing`, `GA_Rage`, `GA_AmmoCrate`, `GA_AnimalInstinct`, `GA_AutoTurret`, `GA_TeamHealing`, `GA_ChimpCompanion`). The first two come from the C++ ctor, `Movement.Mode.Falling` was added in the Editor. So today a deployment totem cannot be started while moving, crouching **or falling**. `GA_Grenade` / `GA_SuperCharge` have none of these.
- Because the BP CDO serialises the whole container, **removing `Status_Moving` from the C++ ctor does not remove it from the BPs** — the 7 GAs need an Editor edit (drop `Status.Moving`, and drop `Movement.Mode.Falling` for the falling exception). Trivial, but it is Blueprint work.
- The cancel-on-velocity check (`OnCharacterMovementUpdated`, `:93`) is the second half of the same rule and **must be removed/changed at the same time**: with `Gameplay.MovementStopped` the character brakes over a few frames, so velocity > 0 on the first ticks would cancel the ability instantly; while falling velocity is never 0.
- Rotation is safe: `bUseControllerRotationYaw = true` (`LyraCharacter.cpp:97`), `bOrientRotationToMovement = false`, so the `GetDeltaRotation() = 0` branch of the stop tag does not freeze camera/aim.
- **When to lift the stop** differs per totem: SelfHealing / AmmoCrate / ChimpCompanion end the ability at the deploy event; **Rage, AnimalInstinct and the synergy totems stay active long after** (buff timers, combo windows). So the stop must be scoped to the *deployment window* (activation → deploy event / interrupt / EndAbility, whichever first), never to ability lifetime.
- `Status.Moving` is a per-tick loose tag (velocity ≠ 0). While stopped the velocity brakes to 0 → the tag clears itself; no interaction problem.
- Synergy totems already `CancelAbilitiesWithTag` Sprint/ADS/Reload; SelfHealing blocks ADS/Grenade/AmmoCrate. Glide/Roll/WallMove are **not** in any totem's block list (Editor question).

### Refined plan
C++ (`TotemGameplayAbilityWithDeploymentAnimationBase`):
1. `UPROPERTY(EditDefaultsOnly) bool bStopMovementDuringDeployment = true;` (SelfHealing ctor → `false`). Keep `Status.Crouching` blocked in the ctor; **drop `Status.Moving` from the ctor**.
2. `StartDeploymentAnimationAsync()`: if `bStopMovementDuringDeployment && !CMC->IsFalling()` → `ASC->AddLooseGameplayTag(TAG_Gameplay_MovementStopped)` (+ `AddReplicatedLooseGameplayTag` is unnecessary: the ability runs on both owning client and server, so each side sets its own loose tag; `GetMaxSpeed()` is evaluated locally on both). Remember `bMovementStopApplied`.
3. Lift the stop (remove the loose tag) in `OnDeployedGameplayEventReceived`, `OnDeploymentAnimationInterrupted` and `EndAbility` (guarded by the flag so it is removed exactly once).
4. `OnCharacterMovementUpdated`: remove the velocity-cancel branch (keep the UnCrouch). The stop tag now guarantees the player stays put on the ground; in the air they keep falling, which is the requested exception.
5. If the montage is still meant to be cancellable by movement input for the `false` case (SelfHealing while moving), nothing cancels it — that is the desired "works while moving" behaviour.
Editor (Marco, 7 GAs): remove `Status.Moving` and `Movement.Mode.Falling` from `ActivationBlockedTags`. Optionally add `Ability.Type.Action.Glide/Roll/WallMove` to `BlockAbilitiesWithTag` on the stopped totems so a wall-jump can't break the pose.
Disguise (not deployment-based): wrap `DisableMovement()` in `!IsFalling()` or switch it to the same tag. Separate small change.

Open question for Marco: "while pressing the button" — totems are `OnInputTriggered` and end on the deployment notify, not on release. Is the stop meant to last the full deployment, or should release cancel? (If release cancels, override `InputReleased`; precedent `DefuseBombGameplayAbility.h:41`.)

Editor: deployment montages may assume in-place; check Personal Healing's montage looks right while walking.

---

## 2. Set Phys Material in all maps

### What phys materials drive (C++)
- **Footsteps / context effects**: `Source/LyraGame/Feedback/ContextEffects/LyraContextEffectComponent.cpp:80-83` — if `HitResult.PhysMaterial` is null the surface tag block is **skipped entirely**; the library lookup (`LyraContextEffectsLibrary.cpp:11-31`) then early-outs on an empty context → **no footstep sound, no dust, no landing FX**. It does not fall back to `SurfaceType.Default`.
- **Step Niagara** `User.SurfaceType` (`PlayingCharacter.cpp:737-738`): graceful, falls to surface 0.
- **Weapon damage multiplier / weak spot** (`LyraRangedWeaponInstance.cpp:131-146`, `LyraGameplayAbility.cpp:319-325`, both damage executions): needs `UPhysicalMaterialWithTags`; a plain `UPhysicalMaterial` silently casts to null → 1.0×. Mostly character-side, less map-dependent.
- **Hit-marker zone** (`LyraWeaponStateComponent.cpp:118-131`): null → no crit marker.
- Impact VFX/decals/sounds are surface-keyed BPs (`GCN_Weapon_Impact`, `B_WeaponImpacts`, `B_WeaponDecals`).

### Inventory
- Surfaces registered: only `Character`, `Concrete`, `Glass` (`Config/DefaultEngine.ini:456-458`; context map `Config/DefaultGame.ini:238-239`; tags from `DT_SurfaceTypes`).
- Phys material assets: `PM_Character`, `PM_Concrete`, `PM_Concrete1` (dup?), `PM_Glass`, `PhysMat_Player`, `PhysMat_Player_WeakSpot`.
- No project-authored landscape `LayerInfo` assets (only marketplace ones) → landscape phys materials on Jungle/Beach almost certainly unset.
- Realistic map scope: 10 `BASMaps` + 6 `ShooterMaps` Arcas/BAS maps + `BAS_ShooterGym` (not all 60 umaps).

### Plan
- **C++ (1 line, high value, do regardless)**: in `LyraContextEffectComponent.cpp:83` fall through to `SurfaceType_Default` when the phys material is null. Turns "silence on unset geometry" into "default footstep" and makes the map pass non-blocking. Optionally a dev-only warn log naming the unset actor.
- **Editor (Marco)**: this is a surface-vocabulary problem first. Jungle/Beach/Village need Grass/Sand/Dirt/Wood/Metal/Water surfaces (`SurfaceType4..N` in `DefaultEngine.ini`, rows in `DT_SurfaceTypes`, `SurfaceTypeToContextMap`, new `PM_*`, entries in `CFX_DefaultSkin`), then assignment at the **material level** (master materials/instances) rather than per actor. Python editor scripting could batch it but `PythonScriptPlugin` is not enabled in the uproject.
- Guard: `ensureMsgf` in `LyraRangedWeaponInstance.cpp:133` when a hit phys material isn't `UPhysicalMaterialWithTags`, so new `PM_Grass` made with the wrong factory gets caught.

---

## 3. Refine replication code for throwing melee

Files: `PLUGIN/{Public,Private}/AbilitySystem/Abilities/ThrowMeleeWeaponGameplayAbility.{h,cpp}`, `PLUGIN/{Public,Private}/Actors/TeamProjectiles/MeleeWeaponProjectile.{h,cpp}`. Unchanged since `11210a22e` (5 Jul); AS-BUILT block in `melee-throw-implementation-spec.md` matches.

### Correct today
No double spawn (spawn callback bound only under authority, `ThrowMeleeWeaponGameplayAbility.cpp:67`); damage GE authority-gated + once-only (`MeleeWeaponProjectile.cpp:152,185`); quickbar re-equip reaches the owning client via `OnRep_Slots`/`OnRep_ActiveSlotIndex`.

### Defects, ranked
1. 🔴 **Stick is server-only cosmetics.** `HandleActorHit` returns on `!HasAuthority()` (`:101`), so `StopMovementImmediately`, `PMC->SetActive(false)`, `SetCollisionEnabled(NoCollision)` (`:136-138`) never run on clients. `AttachToComponent` (`:143`) replicates via attachment replication, but the client PMC keeps simulating → the axe swims/drifts off the victim. Invisible in listen-server PIE.
2. 🔴 **Throw depends on the dedicated server's own AnimNotify firing** (`:67-79`); if missed, no projectile, no swap, ability never ends → player soft-locked. No watchdog.
3. 🔴 **`check(ThrowGameplayEventTag.IsValid())`** (`:72-74`) hard-crashes a Development/Test dedicated server if a BP forgets the tag. Same in `GrenadeTotemGameplayAbility.cpp:50-51`.
4. 🟠 `ensure(IsValid(GetOwner()))` at client `BeginPlay` (`MeleeWeaponProjectile.cpp:192`) fires under real relevancy (owner not yet resolved); same root cause kills the team-coloured trail on remote clients (`TeamProjectile.cpp:85`).
5. 🟠 **No `bInterpMovement`** in the ctor (`:23-29`) while `Grenade.cpp:36-37` sets both. `NetUpdateFrequency` never tuned. → jitter + hard snap at impact.
6. 🟠 **Overlap path forwards an empty `SweepResult`** (`:93-97`): `BoneName == None` → sticks to the pelvis instead of the hit bone; damage context gets a zero-location hit.
7. 🟡 Impact feedback is a local `SpawnSoundAtLocation` (`:83-88`), sync-loaded on the server too; detonation base uses a replicated gameplay cue instead.
8. 🟡 `GenericGameplayEventCallbacks.Remove(Tag)` (`:208`) nukes every listener on the tag, and runs on clients.
9. 🟡 No authority guard in `SwapMeleeSlotToUnarmed`/`RestoreMeleeWeapon` (`:107`, `:166`): one BP re-parent or policy change away from `check(HasAuthority())` in `FLyraInventoryList::AddEntry` (client crash).
10. 🟡 Owner-death path inherits bare `Destroy()` (`TeamProjectile.cpp:149`) — orphans `StoredMeleeItem`, leaves Unarmed in inventory. Also `TeamProjectile.cpp:136-138` PlayerState cast deref without `IsValid`.

### Plan (C++ only, all in the two classes)
- Replicate stuck state: `ReplicatedUsing=OnRep_Stuck` struct `{StuckTo, Bone, RelLoc, RelRot}`; apply the three cosmetic lines on both sides.
- Synthesize a proper hit on the overlap path (closest point + `FindClosestBone`).
- `bInterpMovement = true` (leave rotation to the BP), `SetNetUpdateFrequency(60)`.
- `check` → `ensure` + `EndAbility`; server watchdog timer (montage length + margin).
- Replicated stick cue via `ExecuteGameplayCue`; `IsNetMode(NM_DedicatedServer)` early-out on the local sound.
- Remove by `FDelegateHandle`; authority guards on the mutators; own `OnOwningCharacterEliminated`.

Editor to confirm: `NetExecutionPolicy` on `GA_ThrowAxe/Spear`, melee equipment actor BPs have `bReplicates`, `bSkipEquipMontage` is a class default.

---

## 4. Add icon to friendly totem devices

> **2026-10-17: DESIGN LOCKED → build from `friendly-device-indicator-spec.md` (v1).** v1 = Turret (+ upgrades), Team Healing, Artillery Cannon, Ammo Crate. Super Tank, Spotter, head chimps out. Design = opt-in `UFriendlyIndicatorComponent` added per BP; Marco's widget `W_FriendlyTotem_Icon`.

### Actors
`ATeamDevice : ALyraCharacterWithAbilities` (`PLUGIN/Public/Characters/TeamDevices/TeamDevice.h:11`) — `TeamId` replicated (`.h:83-84`), `IsSameTeamWithActor()` (`.cpp:160-174`), `OnOwningCharacterInitialized()` server hook (`.cpp:75-79`). Subclasses: `AAutoTurretSynergyDevice`, `ATeamHealingSynergyDevice`, `AChimpCompanionSynergyDevice`. ⚠️ `AAmmoSpawner` is **not** a `ATeamDevice`; treat separately if ammo crates count.

`ATeamDevice` never applies a `ULyraTeamDisplayAsset` (characters do, `PlayingCharacter.cpp:110-141`) — devices currently get no team colouring at all.

### Three indicator systems already present, none driven from C++
- **A. Lyra indicators** (`ULyraIndicatorManagerComponent`, `UIndicatorDescriptor`) — customised for BAS nameplates (`IndicatorDescriptor.h:72-85`), all driven by BPs in `Content/UI/Indicators/`. Already has `Gameplay.Message.Nameplate.Show/Hide.Enemy` friend/foe split. Needs a `UIndicatorLayer` in the HUD (confirm in Editor).
- **B. Radar/minimap** (`URadarObjectActorComponent`, `ERadarObjectType::Ally`, `SetVisibleToTeam`) — if Marco means the minimap.
- **C. `UWidgetComponent`** — precedent `UControlPointWidgetComponent` with per-team colours.

### Plan
Ask Marco which he means (world-space over the device vs. minimap). Either way the hook goes in `ATeamDevice` once: on `BeginPlay`/`OnRep_TeamId` on clients, compare with the local pawn via `ULyraTeamSubsystem::CompareTeams`, show/hide. Icon asset + widget is Editor work.

### Deeper pass (2026-10-17, @ `bf9751c02`, BPs read via LFS download — supersedes the plan above)
- **Don't use `ATeamDevice::TeamId`** — replicated but no RepNotify. The team already reaches clients through Lyra's own path: `ATeamAIController::SetGenericTeamId` → bot PlayerState (`bWantsPlayerState`) → `ALyraPlayerBotController::OnPlayerStateChangedTeam` → `ALyraCharacter::MyTeamID` (replicated, `OnRep_MyTeamID` → `OnTeamChangedDelegate`). So `CompareTeams(device, localPC)` works on clients and there is a team-changed event to hook.
- **Why devices have no icon:** `LAS_ShooterGame_StandardComponents` adds `NameplateSource` (client-only) to `B_Hero_ShooterMannequin` only. `NameplateManagerComponent` hardcodes `W_Nameplate`, which is player-specific (`GetPlayerName`, health, Disguise team matching). Not reusable for devices.
- **Indicator layer is confirmed present:** `ShooterCore` GameFeatureData adds `LyraIndicatorManagerComponent` to the controller (that's what renders nameplates). Point 4A's "confirm in Editor" is closed.
- **Precedent:** `B_ChimpCompanionSynergyDevice` already does a viewer-relative team-colour outline in BP (`OnTeamOrCosmeticsChanged`, `UpdateCustomStencilFromTeamID`, `GetTeamColorWithFallback`, `MPP_Outline_Inst`). 1 of 3 devices; the three BPs have different C++ parents, no shared BP parent → `ATeamDevice` C++ is the single place.
- **Ammo Crate:** `AAmmoSpawner : ABASWeaponSpawner`, no team stored at all. Separate work if it counts.
- **Recommended plan:** in `ATeamDevice`, client-only: on BeginPlay + `OnTeamChangedDelegate`, if `CompareTeams(this, local PC) == OnSameTeam` → `ULyraIndicatorManagerComponent::GetComponent(PC)->AddIndicator(descriptor)` (scene component = mesh, `SetIndicatorClass(FriendlyIndicatorWidgetClass)`), else remove; remove in `EndPlay`. New `UPROPERTY(EditDefaultsOnly) TSoftClassPtr<UUserWidget> FriendlyIndicatorWidgetClass`. ~60 lines. Editor: one `W_DeviceIcon` + 3 textures + set the property on the 3 BPs. Alternatives: `UWidgetComponent` per BP (all-BP, no screen-edge clamp); radar (`ERadarTeamVisibility` is absolute team ids, so would need setting per device).
- Effort S–M. Open for Marco: world vs minimap; include Ammo Crate?

---

## 5. Pop up on the reticle when the super totem is active

### What "super totem" is
The **Support slot** (`EUserCombatBarrackType::SupportAbility`): all three derive from `USynergyTotemGameplayAbilityBase`. Confirmed by `SingleTotemWidget.cpp:220-230` (`OnSuperTotemActive` anim plays only for `SupportAbility`) and `sfx_SuperTotemRecharged`. In existing UI language, "active" = **ready / off cooldown**. (`USuperChargeTotemGameplayAbility` is a Damage totem, unrelated.)

### State exposure
No gameplay message, attribute or replicated bool. Only local delegates on `UTotemGameplayAbilitySubsystem` (`OnActivateWidget`/`OnDeactivateWidget`/`OnCooldownFinished`, `.h:26-43`), broadcast from `UTotemGameplayAbilityBase::Tick` (`TotemGameplayAbilityBase.cpp:176-186`). Sole consumer: `USingleTotemWidget`.

### Reticle
`UBASReticleWidgetBase : ULyraReticleWidgetBase` (`Source/LyraGame/UI/Weapons/BASReticleWidgetBase.h:18`) already listens on a gameplay message and plays a `BindWidgetAnim` (`Elimination`, `.cpp:15-76`). Reticles are per-weapon assets via `UInventoryFragment_ReticleConfig` (~15 `W_Reticle_*`), recreated on weapon swap.

Module constraint: `LyraGame` cannot include plugin headers, so the reticle base can't touch the totem subsystem directly.

### Plan (recommended: gameplay message)
Broadcast a message on a new `UI.SuperTotemReady` tag from `USynergyTotemGameplayAbilityBase` (cooldown-finished / reset / activated), listen in `UBASReticleWidgetBase::NativeConstruct` next to the elimination listener, play a new `SuperTotemActive` optional anim. Also poll current state on construct (weapon swap). Editor: author the animation in the reticle widgets (one shared sub-widget preferred). Clarify with Marco: "active" = ready, or = currently deployed?

### Deeper pass (2026-10-17, @ `bf9751c02`, BPs read via LFS download — supersedes the plan above)
- **Trap — don't trigger on "widget activated":** `USingleTotemWidget::ActivateWidgetChecked` (`SingleTotemWidget.cpp:220-230`, where `OnSuperTotemActive` plays) fires on (a) cooldown end, but also (b) every time `UTotemGameplayAbilityBase::Tick` (`:176`) sees `CanActivateAbility` go true again after a blocking tag clears, (c) at spawn (`SetGameplayAbility` → `OnCooldownFinished` with no cooldown), (d) every round reset (`OnReset` → `ClearCooldownTimer` → `OnCooldownFinished`). The existing HUD anim very likely already replays on (b).
- **Right edge:** `USingleTotemWidget::OnCooldownFinished` (`:241`), filtered to `ItemCategory == SupportAbility` and "was on cooldown" (`CooldownTimer > 0` before clearing) → excludes spawn. Broadcasting from the widget is ideal: it is already local-player-only (`CanSwitchWidgetActivation`) and slot-aware. Message: new tag `UI.Message.SuperTotemReady`, payload `FLyraVerbMessage` (BlueprintType) with Instigator = PlayerState.
- **Reticle inventory:** 16 `W_Reticle_*` derive from `UBASReticleWidgetBase` (only Lyra's `W_Reticle_AmmoBar` doesn't). **No shared sub-widget** — each has its own hit/elimination marker copies, so a per-reticle anim = 16 edits. Melee weapons have no reticle. Reticles are destroyed on weapon swap.
- **Recommended: show it in `W_WeaponReticleHost`** (ShooterCore HUD, plain UserWidget; creates each weapon's reticle into its Overlay via `InventoryFragment_ReticleConfig`, and persists). Marco adds image + anim + BP "Listen for Gameplay Messages" on the tag. C++ = only the broadcast (~20 lines + tag). Confirm in Editor the host is visible with melee/unarmed.
- **If touching `UBASReticleWidgetBase` anyway:** new anim must be `BindWidgetAnimOptional` (`Elimination` is required `BindWidgetAnim` → a required one breaks 16 BPs). Side bug: `RegisterListener` handle (`.cpp:30`) is discarded, never unregistered → one more listener per weapon swap (weak-object, so harmless but accumulating).
- Effort S. Open for Marco: ready vs deployed; one-shot vs persistent while ready; pop at spawn / round start?

### ★ DESIGN (2026-10-17, Dan) — supersedes the display half above
> **✅ DONE (2026-10-17): compiled + PIE-tested by Marco; live in Steam build `2026-10-17_19-41`.** First push `c45676442` failed to compile ("declaration of `bCooldownActive` hides class member", a local in `DeactivateWidgetChecked`); fixed in `b1ba09e4b`. No Editor work needed. Originally: **BUILT & PUSHED UNCOMPILED `c45676442` (2026-10-17).** Round-reset popup: Dan chose to **show it** (once per finished cooldown). The flag is `bCooldownRunning` (first named `bCooldownActive`, which shadowed a local in `DeactivateWidgetChecked` and broke the build; fixed in `b1ba09e4b`), also reset in `SetGameplayAbility`. Marco: rebuild + PIE test only (steps sent in Arcas Champions Dev).
**Dan's spec:** copy the "no ammo" text popup. When the Support-slot (super) totem's countdown expires, show **"Super Totem Ready"** briefly, exactly like the out-of-ammo text.

**The popup = Lyra's stock `W_AbilityFailureFeedback`** (`ShooterCore/UserInterface/HUD/`, placed in `W_ShooterHUDLayout` under the crosshair, untouched since the initial commit apart from a reskin). Graph, read off the asset: `ListenForGameplayMessages(Ability.UserFacingSimpleActivateFail.Message)`. If `Payload.PlayerController == GetOwningPlayer()` and the pawn isn't `IsDeadOrDying`, it sets `FailureReasonText` from `UserFacingReason` (a text-equality check guards the update) and `PlayAnimationForward`. "Out of Ammo" comes from the fire ability's `FailureTagToUserFacingMessages` → `ULyraGameplayAbility::NativeOnAbilityFailedToActivate` (`LyraGameplayAbility.cpp:109-125`).

**Precedent:** `AAmmoSpawner::FillUpAmmo` already reuses that widget for "Refilled Ammo" by broadcasting an `FLyraAbilitySimpleFailureMessage` on the same channel (`AmmoSpawner.cpp:169-182`, with the comment "Why failure message?.. It's not a failure"). So: **no new widget, no Editor work, ~25 lines of C++.**

**Trigger (from the analysis above):** the true "recharged" edge = `USingleTotemWidget::OnCooldownFinished` (`SingleTotemWidget.cpp:241`), **not** `ActivateWidgetChecked` (which also fires when blocking tags clear, at spawn and at round reset). The widget is already local-player-only (`CanSwitchWidgetActivation`) and knows its slot.

**Change (all in `USingleTotemWidget`):**
- New `bool bCooldownWasActive`: set in `OnCooldownApplied` (after `CanSwitchWidgetActivation`), and checked + cleared in `OnCooldownFinished`. This kills the **spawn popup**, because `SetGameplayAbility` calls `OnCooldownFinished` directly when there's no cooldown.
- In `OnCooldownFinished`, if `GetItem().ItemCategory == EUserCombatBarrackType::SupportAbility && bCooldownWasActive`, broadcast `FLyraAbilitySimpleFailureMessage { PlayerController = GetOwningPlayer(), UserFacingReason = SuperTotemReadyText }` on `FGameplayTag::RequestGameplayTag("Ability.UserFacingSimpleActivateFail.Message")`.
- ⚠️ Link trap: `TAG_ABILITY_SIMPLE_FAILURE_MESSAGE` is `UE_DECLARE_GAMEPLAY_TAG_EXTERN` **without `LYRAGAME_API`**, so the plugin can't reference the symbol. That's why `AAmmoSpawner` takes the channel as a BP property. Look it up by name instead. The struct itself is fine (`AAmmoSpawner` already broadcasts it from the plugin).
- New `UPROPERTY(EditAnywhere) FText SuperTotemReadyText = "Super Totem Ready"` (Marco can retext it on `W_Totem`; nothing to set otherwise).

**Behaviour notes:**
- **Round reset:** `OnReset` → `ClearCooldownTimer` → `OnCooldownFinished`, so if the super totem was recharging when the round ended, the popup shows at the next round's start. Decision: accept (it is true), or suppress.
- **Recharges while dead:** the widget suppresses the popup while `IsDeadOrDying`, so you just don't get it. Acceptable.
- **Cooldown cuts** (Team Healing synergy `UpdateAbilityCooldown`, `RemoveCooldown`): the popup fires when it actually hits 0, which is correct.
- **Shares the slot with "Out of Ammo" / "Refilled Ammo":** last message wins. Fine.

**Work:** us, ~25 lines in `SingleTotemWidget.h/.cpp`, one commit. Marco: PIE-test only (place the super totem, wait out the countdown → "Super Totem Ready" once; respawn with it ready → nothing; other two totem slots → nothing).

---

## 6. Disguise Totem crash

> **✅ DONE 2026-11-01 (`93552e939`, uncompiled, Marco to PIE-test).** A 4-agent review found the crash lines real but **unreachable on current paths**: death (Lyra death ability + `ResetAbilitiesAndEffects`), round/warmup reset (PlayerState reset force-cancels), disconnect (ASC destroy) all cancel Disguise in the same frame, and `EndAbility` clears the ability's timers (`AbilitySystem.ClearAbilityTimers`), so `Disguise()` never fires on a dead pawn. `GA_Disguise` is data-only, cancellable, no `SurvivesDeath`. The only crash proven in history is the `EndAbility` one fixed by `9ddc4498f`. Dan declared it fixed with hardening: (A) `Disguise()` uses `Cast` + `IsValid` controller and ends the ability (`EndAbility`, not `CancelAbility`, so it works even if not cancellable) instead of `check`/`CastChecked`/unguarded `GetController()`; (B) `OriginalCharacterMeshPart` reset at the top of `ActivateAbility` (before the commit check) so an early end no longer restores the previous activation's part (wrong-team skin after a side swap). Root causes 3-6 below were checked: 3 is safe (ActorInfo owned by the ASC, timers weak-bound), 5 harmless, 4 and 6 not proven, left as is. The ranking below is the original pre-review note.

File: `PLUGIN/Private/AbilitySystem/Abilities/TotemAbilities/DisguiseTotemGameplayAbility.cpp`. Mechanism: montage → server timer → `Disguise()` swaps the Lyra character part via `UCharacterMeshPickerComponent` on the **Controller**, sets replicated `bDisguised`, flips team colour in `OnTeamOrCosmeticsChanged`. Ends on 15 s timer, damage taken, or weapon fire.

### Root causes, ranked
1. **`Disguise()` line 97-98**: `OwningCharacter->GetController()->FindComponentByClass<...>()` with no null check. Controller is null whenever the pawn is detached during the montage window (death → `DetachFromControllerPendingDestroy`, disconnect, match end). **The exact same line was fixed in `EndAbility` by `9ddc4498f`** ("crash … at the end of the game due to the invalid controller", lines 295-297) and never ported to `Disguise()`.
2. **Lines 87-92**: fatal `check(ActorInfo->AvatarActor.IsValid())` + bare `CastChecked` (the other two functions use `NullAllowed`). Dies if the pawn is destroyed before the montage timer fires. Death only cancels the ability if `GA_Disguise` has **Can Be Canceled** on (`ABASPlayerState::ResetAllAbilities` only calls `K2_CancelAbility`) — check in Editor.
3. **Raw `FGameplayAbilityActorInfo*` bound into timer payloads** (`:70-74`, `:156-160`): dangling if the ASC/PlayerState dies before the 15 s timer.
4. **Unguarded `GetWorld()` / `GetGameInstance()`** (`:152,164,251,261`) during teardown — three past commits (`14c25f37a`, `20b4566b4`, `9ddc4498f`) chased end-of-game problems here.
5. `EndAbility` runs its 90 lines even when `Super::EndAbility` no-ops (double-end via damage + weapon-fire listeners; re-entrancy at `:179-181`).
6. `UTotemGameplayAbilityBase` is an `FTickableGameObject` with no `IsTickable` guard and `GetWorld()->GetSubsystem` unchecked (`TotemGameplayAbilityBase.cpp:166-174`) — affects all totems.
7. Not a crash but visible: `:134` calls `PickCharacterMeshBasedOnTeam(SkinTeam)` with the **Default** profile instead of `PlayerState->GetCharacterMeshPickerProfile()` → tutorial/Elite-only/Renegade-only profiles fail the `ensureAlways` and the character can end up part-less.

### Plan (C++, small)
Mirror the `9ddc4498f` fix in `Disguise()`; `IsValid` + `Cast` instead of `check`/`CastChecked`, cancel gracefully; bind no-arg timer callbacks and read `GetCurrentActorInfo()` inside; guard `GetWorld()`/`GetGameInstance()`; early-return in `EndAbility` on `!ActorInfo` / already-ended; pass the real mesh-picker profile; null-guard `GetWorld()` in the totem base. Repro on a Development dedicated server: activate Disguise then (a) die during the animation, (b) die + corpse destroyed inside the 15 s, (c) round ends while disguised, (d) disconnect while disguised.

---

## 7. Rework GA_AimingDownSights tags

Asset is **`GA_AimDownSights`** (`Plugins/GameFeatures/BASShooterCore/Content/GameplayAbilities/`). Base `UAimDownSightsGameplayAbility` (`PLUGIN/.../AimDownSightsGameplayAbility.cpp`) does: speed GE via SetByCaller, weapon-visualization tag check (melee → refuse, sniper → scope widget), camera mode, sounds. **Zero tag logic in C++** — all `ActivationBlockedTags`/`Block`/`Cancel` are BP class defaults + `BASTagRelationships_ShooterHero`.

### Findings
- **No ADS status tag exists** (`Status.ADS`/`Status.Aiming`: none). Spread reduction is driven by the *camera mode* tag `Lyra.Weapon.SteadyAimingCamera` (`LyraRangedWeaponInstance.cpp:13,203`), which is native-only and not in any ini — if the ADS camera modes don't carry it, ADS gives no accuracy bonus.
- Block/cancel relations are authored per-ability, asymmetrically; git shows 4 reactive fixes (`f26a07f5d`, `f75faef84` "glide couldn't activate during ADS but ADS could during glide", `ce8588302`, `87cb7a995`). Sprint has its own parallel block/cancel set (`SprintGameplayAbility.h:73-79`) — second source of truth.
- `Gameplay.Weapon.NoAim` is defined (`BASShooterCoreTags.ini:70`) but never wired.
- `Gameplay.Message.ADS` lives in ShooterCore tags, `.ADS.End` in BASShooterCore tags.
- Side bugs: `AimDownSightsGameplayAbility.cpp:292-293` releases the zoom-**in** handle when playing zoom-**out** (wrong handle, possible null deref); raw `ActorInfo*` captured into an async load delegate (`:136`).

### Plan
- C++/ini: add native `Status.ADS` (next to `Status_Moving` in `BASGameplayTags.cpp`), wire `Gameplay.Weapon.NoAim` in `CheckWeaponAndTryLoadAndApplyAssets`, fix the handle bug.
- Editor (Marco/Dan): `ActivationOwnedTags = Status.ADS` on `GA_AimDownSights`; move all ADS ↔ Sprint/Glide/Roll/WallMove/QuickBarChange/Melee/Reload/totem block-cancel pairs into `BASTagRelationships_ShooterHero` keyed on `Ability.Type.Action.ADS` (authored once, symmetric); verify `CameraTypeTag == Lyra.Weapon.SteadyAimingCamera` on `CM_ThirdPersonADS`/`CM_FirstPersonADS`; verify `GA_AimDownSights` does not carry `Ability.Behavior.SurvivesDeath`.

---

## 8. Blind + slow-down disappear when healed

### As-is
- **Blind**: `GE_Blind_*` → `UCustomizableBlindExecution` (`PLUGIN/.../CustomizableBlindExecution.cpp`) sets `SetByCaller.Duration` and conditionally applies `GE_AddBlindTags` (grants `Status.Blind`). **The visual is a fire-and-forget RPC** (`PlayingCharacter.cpp:883-923` → `UI.BlindEffect` message → `BlindEffectWidget::AddSpots` → `SpotWidget::SetDestructTimer`, a plain timer to `RemoveFromParent`). `RemoveAllSpots` only runs on pawn change or death. Bots mirror it with a hard-coded `Duration + 5 s` timer (`ArcasBotController.cpp:684-728`, also hard-codes the `"Status.Blind"` string).
- **Slow**: `GE_SlowDown_Base` + children modify `ULyraCombatSet::MovementSpeedMultiplier`, read by `LyraCharacterMovementComponent.cpp:169-170`; grants `Status.SlowedDown`; looping cue `GCNL_SlowedDown` auto-removes with the GE. Zero C++. Also check `GE_SlowingTarget`, `GE_Damage_Periodic_Slow` (outside the SlowDown folder).
- **Healing** converges in one place: `ULyraHealthSet::PostGameplayEffectExecute` (`Source/LyraGame/AbilitySystem/Attributes/LyraHealthSet.cpp:151-155`). Sources: Personal Healing totem, TeamHealing device, pickups, healing ammo, chimp, turret.
- **No cleanse exists**: zero `RemoveActiveEffectsWithGrantedTags` calls in the project. Debuff GEs live on the PlayerState ASC and **survive death/respawn** — same fix cleans this up.

### As committed by Marco — `42c3c5e9f` (2026-09-09), verified from the real `.uasset`s off the VM

**Burn (works).** Fire ammo = BP projectile / hitscan applies `GE_Damage_<Weapon>_FireAmmo` (Instant) + `GE_Damage_<Weapon>_FireAmmo_Periodic` (HasDuration + Period, parent `GE_Damage_Basic_Periodic`, `LyraDamageExecution`, asset tags `GameplayEffect.DamageTrait.Periodic` + `GameplayEffect.DamageType.Basic`, cues `GameplayCue.Character.Burn` + `DamageTaken`). `GCNL_Burned` is a **looping** cue notify (attaches `NS_Fire_Big_Simple`), so its lifetime == the GE's lifetime. **Neither fire GE grants `Status.Burn`** (tag exists in ini, unused).

**Removal Marco added** = a `RemoveOtherGameplayEffectComponent` (legacy "Remove Gameplay Effects with Tags") on the **5 healing-ammo GEs only** (`GE_Heal_GrenadeLauncher_Periodic`, `GE_Heal_MadZooka_Periodic`, `GE_Heal_RocketLauncher_Periodic`, `GE_Heal_TrapGun_Periodic`, `GE_MadBlower_HealingAmmo`, `GE_Heal_Shotgun`), query:
`ANY(Status.Burn, Status.Blind, GameplayEffect.Blind, GameplayEffect.DamageTrait.Periodic, UI.BlindEffect, GameplayCue.Character.BlindEffectTaken, GameplayCue.Character.Burn, GameplayCue.Character.SlowedDown, Status.SlowedDown)`

Engine facts (UE 5.5 `GameplayEffect.cpp:5754-5776`, `RemoveOtherGameplayEffectComponent.cpp:16-50`): the query matches an active GE's **asset tags + granted tags only**. Cue tags and `UI.*` are never owning tags → 4 of the 9 entries are inert. The component fires **once, at application, server only**; on a HasDuration+Period GE the editor flags it as a data-validation error ("GE is Periodic…") but it still runs at apply time (not per tick). Not on `GE_Heal_Instance`, totem, TeamHealing device, pickups.

| Effect | What the query actually hits | Result |
|---|---|---|
| Burn | `GameplayEffect.DamageTrait.Periodic` asset tag on the periodic fire GE (NOT `Status.Burn`, NOT the cue tag) | ✅ GE removed → looping cue ends → fire VFX gone. ⚠️ Also cleanses **every** other periodic damage GE with that trait tag |
| Slow | `Status.SlowedDown` granted by `GE_SlowDown_Base` | ✅ GE removed → looping `GCNL_SlowedDown` ends |
| Blind | `Status.Blind` (granted) + `GameplayEffect.Blind` (asset) on `GE_AddBlindTags` | ⚠️ **Tag GE removed, screen stays blind.** `GE_Blind_*` is Instant; the spots are `USpotWidget`s with a local `SetDestructTimer` (`SpotWidget.cpp:42-46`) spawned by the execution's one-shot client RPC. Nothing links them to the GE. Bots also keep `AimAccuracy = 0.02` until their own `Duration + 5 s` timer |

**Why the fire recipe cannot be copied to blind in Blueprint**: blind's visual was moved out of the cue system into C++ (`d99e4343c`, "gameplay cues are unreliable") — there is no `GCN_*BlindEffectTaken` asset, the cue tag on `GE_Blind_*` fires into nothing. Making blind a HasDuration GE with `CustomizableBlindExecution` wouldn't help either: executions only run on Instant GEs or periodic ticks, and each tick would spawn 3 more spots via the RPC.

**Minimal C++ fix (2 files)**: make `UBlindEffectWidget` tag-driven — on possess, `ASC->RegisterGameplayTagEvent(Status.Blind, NewOrRemoved)`; count 0 → `RemoveAllSpots()`; keep the destruct timer as a fallback or drop it. Same for `ArcasBotController`: restore aim on tag removal instead of the timer. Then Marco's existing query works for blind with no asset change. Recommended cleanup of the query: a single `Status.Debuff.Cleansable` granted on `GE_AddBlindTags`, `GE_SlowDown_Base` and the fire periodic GEs, so healing doesn't key off `DamageTrait.Periodic`.

### Plan
- Tag: `Status.Debuff.Cleansable` (native in `BASGameplayTags.cpp`), keep `Status.Blind`/`Status.SlowedDown` as-is.
- Editor: add `Status.Debuff.Cleansable` to **Granted Tags** of `GE_AddBlindTags`, `GE_SlowDown_Base` (+ `GE_SlowingTarget`, `GE_Damage_Periodic_Slow` if separate).
- C++ removal (one choke point, catches every heal source): in `LyraHealthSet.cpp:151` after applying healing, `ASC->RemoveActiveEffectsWithGrantedTags({Status.Debuff.Cleansable})`, optionally gated on the heal spec carrying a tag so tiny heals can opt out. Alternative: a "Remove Other GE" component on each heal GE (Editor-only, repeated on ~10 assets).
- **Mandatory for blind**: make `UBlindEffectWidget` tag-driven — `RegisterGameplayTagEvent(Status.Blind, NewOrRemoved)` → `RemoveAllSpots()` at count 0 (and drop the local destruct timer). Same for bots: restore `AimAccuracy` on tag removal, not on a timer.
- Also remove cleansable debuffs on death (`LyraHealthComponent::StartDeath`) so they don't follow the player through respawn.

---

## 9. Double Jump, Wall Jump and Chicken Glider on the same button (KBM + Gamepad)

> ## ✅ AS-BUILT (final, 2026-10-17) — read this first; everything below is the research + design trail
> **Behaviour (Space / A):** ground press = jump. Air press **near a wall** = wall jump on press (unlimited chaining). Air press **no wall**: **tap = double jump on release**, **hold = glider** (double jump kept). Hold after a ground jump or wall jump = glider at the apex. Double jump = once per airtime, refreshed on landing + wall jump, plus `GE_Roll_Cooldown` 3 s **shared with the ground roll**. **V / B = ground dodge roll only.** Space does nothing while gliding (the glider blocks Jump).
>
> **Code** (`PLUGIN/.../AbilitySystem/Abilities/`):
> - `UJumpGameplayAbility` (LocalOnly): ground → `Jump()`; air → `TryWallJump` (WallMove `CanFindWall` → activate by handle) else tap/hold wait. The glider opening is detected via its owned tag `Event.Movement.Gliding` during the press; release within `MaxDoubleJumpTapDuration` (0.35) → `TryDoubleJump`. Rising window = loose `Movement.Mode.Jumping` (GA_Glide's ActivationBlockedTag) until `Velocity.Z <= 0`, min `MinRisingTime` 0.15 s. **Ends only on release** (Lyra fires "pressed" every frame on `Triggered`).
> - `UDoubleJumpGameplayAbility` (new, LocalPredicted, no input): the old air roll verbatim (LaunchCharacter +400, montage, chimp roll message) + once-per-airtime flag reset on `LandedDelegate` and by `RefreshDoubleJump` (called from WallMove's launch).
> - `UWallMoveGameplayAbility`: search in `FindWall` / public `CanFindWall`, **traces with the character's world** (see lesson). Same 3 chest-height rays as before (step 2 not built).
> - `URollGameplayAbility`: air roll deleted, `CanActivateRoll` requires `IsMovingOnGround()`.
> - Abilities are found **by C++ class** in the ASC list, so no new tags or input tags.
>
> **Editor (Marco):** `GA_DoubleJump` (`Content/Characters/Heroes/Abilities/`, cooldown `GE_Roll_Cooldown`, montage `AM_MA_AirRoll_01`, tags Roll / owned `Event.Movement.Roll` / cancels Sprint+Reload) granted with no input in both hero ability sets. `GA_Roll` → `InputTag.Ability.Roll`. **`GA_WallMove` → no input**, fallback cleared. `GA_Jump`: Walking-required, Jumping-owned and Glide-block removed. `IMC_Default_KBM`: no `IA_WallMove` rows. **`IA_Glide` Hold 0.1 → 0.2 s** (`8af840038`; this is now the tap/hold boundary).
>
> **Tuning knobs:** `GA_Jump` → `Min Rising Time`, `Rising Check Interval`, `Max Double Jump Tap Duration`; `GA_DoubleJump` → `Launch Z Velocity`; `IA_Glide` hold threshold; `GA_WallMove` launch powers (kick XY 1200 / Z 600, skip Z 500).
>
> **Bugs hit on the way (lessons):**
> 1. `GA_WallMove` left on `InputTag.Jump` → fired directly + every frame while held → 1-frame glider flash on KBM.
> 2. **`CanFindWall` called on the CDO** → `UGameplayAbility::GetWorld()` is null on a CDO, and the trace silently missed → wall jump never fired (`daafe3de2`). This was masked by bug 1.
> 3. Air press double-jumped **on press** → every hold spent the double jump (`56029aab9`).
> 4. `IA_Glide`'s own trigger overrides per-mapping hold values.
>
> **Open:** step 2 wall detection (DESIGN v2 C3); bots' BT jump/glide unverified; on-release double jump feel (~0.1-0.2 s later than on-press).

*Research 2026-10-17 @ `d8f7b9add`, nothing changed. **Second pass the same day corrects the first**: the first pass said "no double jump exists". Wrong. It's the **Air Roll**. Tag containers decoded from the real `.uasset`s in property order; IMC key↔action pairs decoded the same way.*

### How the three moves actually work today
| Move | Asset → C++ | Input | Rules (decoded) | Cooldown |
|---|---|---|---|---|
| **Jump** | `GA_Jump` → `UJumpGameplayAbility` (LocalOnly, `Jump()` on press, `StopJumping()` on release) | `IA_Jump`: Space / A, fires on press | **Requires `Movement.Mode.Walking` (ground only)**. While held: owns `Movement.Mode.Jumping`, **blocks Glide**, cancels Sprint | none |
| **Double jump = Air Roll** | `GA_Roll` → `URollGameplayAbility` | **No input tag** in the ability sets. Only reachable via the WallMove fallback below | If falling: `AirRoll()` = `LaunchCharacter(0,0,+400)` (`AirRollLaunchZVelocity`) + air-roll montage (`RollGameplayAbility.cpp:126`). If on the ground and moving: dodge roll (1850 along velocity). Cancels Sprint, Reload | `GE_Roll_Cooldown` (**reads ~2 s**, confirm) |
| **Wall jump** | `GA_WallMove` → `UWallMoveGameplayAbility` | `IA_WallMove`: Middle Mouse + V / B, Pressed | Must be falling (C++ `:30`). Wall search = **3 single line traces from the capsule centre**, 100 cm, forward then right/left, on `ECC_Visibility`. Facing wall within 30° → **WallKick** (launch off the wall normal); otherwise → **WallSkip** (reflected). Blocked by `Event.Movement.Melee`. **No wall → cancel → `AbilitiesTagsToActivateOnCancel = Ability.Type.Action.Roll`** → Air Roll | **none** (wall kicks chain freely) |
| **Glide** (chicken) | `GA_Glide` → `UGlideGameplayAbility` | `IA_Glide`: Space / A, **Hold ~0.1 s** | **Requires `Movement.Mode.Falling`, blocked by `Movement.Mode.Jumping`** (so not while the jump button from a ground jump is still held). While gliding it blocks WallMove, Roll, Jump, Sprint, ADS, Reload, Melee, quickbar. Zeroes fall speed + launches +300 | `GE_GlideCooldown` (**reads ~2 s**) |

So **V / B already is "wall jump if a wall is near, otherwise double jump"**: the fallback chain does the proximity decision. The card asks to move that onto the jump button.

Other facts: `GA_WallMove` overrides only launch powers (trace/distance/angle are C++ defaults). The `WallJump` trace channel (`ECC_GameTraceChannel6`, default Ignore) is defined in `DefaultEngine.ini:302` but **unused**. `IA_Ability_Roll` (V / MMB / B → `InputTag.Ability.Roll`) is a dead mapping: no granted ability listens to that tag. Live context is `IMC_Default_KBM` (holds the gamepad rows too); `IMC_Default_Gamepad` is not loaded.

### Target behaviour on Space / A
| Situation | Press | Keep holding |
|---|---|---|
| On the ground | Jump | (glide is blocked until you release) |
| In the air, wall in reach | **Wall kick / skip** | Glide after the kick |
| In the air, no wall, double jump ready | **Air Roll (double jump)** | Glide after the pop |
| In the air, no wall, double jump on cooldown | nothing | Glide |

### Plan A: data only (Editor), uses the existing chain
1. `IMC_Default_KBM`: map `IA_WallMove` to **Space** and **Gamepad A**; remove Middle Mouse, V, B from it.
2. `GA_WallMove`: add **`Movement.Mode.Falling` to ActivationRequiredTags**. Otherwise a ground press activates WallMove, it cancels (not falling) and the fallback **dodge-rolls you on every jump**. A failed `CanActivate` never reaches the cancel fallback.
3. Keep `AbilitiesTagsToActivateOnCancel = Roll`: that *is* the double jump.
4. Glide stays on Hold.
- Side effect: the **ground dodge roll loses its trigger** (it only ever came through the fallback, which now only fires in the air). Keep it by giving `GA_Roll` `InputTag.Ability.Roll` in `AbilitySet_BASShooterHero` + `AbilitySet_ShooterHero`. The dead `IA_Ability_Roll` mapping (V / MMB / B) then works, and V/B are free once WallMove moves.

### Plan B: better wall proximity (C++), the "key matter"
The current check is fragile: **one ray each way at chest height**, 100 cm from the capsule centre (~60 cm from its surface), on Visibility (hits players, devices and props too). It misses walls at knee or head height, corners, thin geometry and gaps, and **a miss silently becomes a double jump** (and burns its cooldown). Changes in `UWallMoveGameplayAbility::GetFacingWallData` / `ActivateAbility`:
- **Sweep a sphere/capsule instead of a line**, so wall height and edges stop mattering.
- **Measure reach from the capsule surface**: `CapsuleRadius + WallReach` instead of 100 from the centre. Expose `WallReach` (cm).
- **Search more directions**: forward, forward ±45°, left, right, and the velocity direction. Take the nearest hit, keeping the existing kick (≤30°) / skip split.
- **Only level geometry counts**: object query WorldStatic/WorldDynamic, or opt in via the unused `WallJump` channel. Decide whether kicking off turrets/players is wanted.
- **Optional lenience**: accept a wall that was in reach in the last ~0.1 s (coyote time), for presses just after leaving a wall.
- Expose all as `EditDefaultsOnly` so Marco tunes in `GA_WallMove`. Plan A still applies on top (the button mapping is Editor either way).

### ★★ DESIGN v2 (Dan, 2026-10-17): THE TARGET, build from this
**Decisions (Dan):**
- **D1** Hold after a ground jump, double jump or wall jump → glider (opens at the apex).
- **D2** Double tap = any second press while airborne, no time window.
- **D3** One double jump per airtime, **reset on landing and on a wall jump**; the cooldown stays as well.
- **D4** Wall jumps chain without limit.
- **D5** **Remove the Air Roll; the double jump lives in the jump ability.**
- **D6** Ground dodge roll (V / B) stays as is.
- **D7** Improve the wall detection.

**Behaviour on Space / A:**
| Situation | Input | Result |
|---|---|---|
| Ground | press | Jump |
| Air, wall in reach | 2nd+ press | Wall jump (kick ≤30° facing, else skip), unlimited; also refreshes the double jump |
| Air, no wall, double jump available + off cooldown | 2nd press | **Double jump** (engine 2nd jump, same height as a ground jump, air-roll montage) |
| Air, no wall, double jump used or on cooldown | press | nothing |
| Air | hold | Glider, at the apex |

#### Final rules (Dan, 2026-10-17, closes Q-V1 / Q-G1 / Q-C1)
- **V / B = ground dodge roll only.** Not usable in the air. Done by moving V/B off `IA_WallMove`: `GA_WallMove` gets **no input at all** and is only activated by GA_Jump when a wall is found. V/B drive `GA_Roll` directly through the existing (currently dead) `IA_Ability_Roll` → `InputTag.Ability.Roll` mapping. Roll is ground-only after C4.
- **No Space presses while gliding:** the glider exists only while Space is held (it already blocks Jump). Release → falling → the next press is a **double jump** (if available) or a **wall jump** (if a wall is in reach).
- **Double jump limits stay: once per airtime AND the 2 s cooldown.** The cooldown is what stops the double-jump ↔ glide loop (the glider has its own 2 s cooldown too). A wall jump or landing refreshes the once-per-airtime limit; the cooldown still applies.
- **Wall jumps chain without limit.**

**Editor changes these add (Marco):**
- `IMC_Default_KBM`: remove the `IA_WallMove` rows (Middle Mouse, V, Gamepad B). `IA_Ability_Roll` already has V, Middle Mouse, Gamepad B.
- `AbilitySet_BASShooterHero` + `AbilitySet_ShooterHero`: give `GA_Roll` the input tag `InputTag.Ability.Roll`; remove `InputTag.WallMove` from `GA_WallMove` (no input).
- `GA_WallMove`: clear `AbilitiesTagsToActivateOnCancel` (the Roll fallback was only how V/B reached the roll; GA_Jump now handles "no wall" itself).

#### ★ ACTION LIST v2 (2026-10-17, Dan: B2 + shared cooldown) — build from this
> **✅ Step 1 C++ PUSHED UNCOMPILED `3a20ad71e` (2026-10-17, VM busy building).** As built:
> - **No new tag**: GA_Jump finds WallMove and DoubleJump among the granted abilities **by C++ class** and activates them by handle.
> - **GA_DoubleJump's Ability Tags = `Ability.Type.Action.Roll`** (not a new DoubleJump tag), so existing Roll blocks apply (the glider blocks it).
> - The wall refresh is a direct `UDoubleJumpGameplayAbility::RefreshDoubleJump(ASC)` from `LaunchCharacterWithEffects` (not a tag event).
> - `RefreshDoubleJump` takes a non-const ASC (the const `GetActivatableAbilities()` overload wasn't verifiable without the VM).
> - Marco's Editor steps sent in Arcas Champions Dev. Step 2 (wall detection) pending step 1 PIE.
> - **Marco's setup `226b072a4`**: works on controller, ~1-frame glider flash on a KBM wall jump. Everything matched the plan except **`GA_WallMove` granted with `InputTag.Jump`** + `IA_WallMove` mapped to Space / A. So Space fires WallMove directly as well as via GA_Jump, and Lyra's per-frame "pressed" re-fires it every frame while held (repeat kicks + activate/cancel RPCs). Fix sent: WallMove no input tag, delete the IA_WallMove rows. **Marco applied it (`985e1bb3c`, verified correct) → wall jump stopped entirely. Root cause = my bug**: `GA_Jump` calls `CanFindWall` on the WallMove **CDO**; `UGameplayAbility::GetWorld()` returns nullptr for a CDO (`GameplayAbility.cpp:113`), and `SceneQuery.cpp:695` returns no-hit for a null world → no wall ever found → always double jump. The earlier input-bound WallMove traced on its instance, masking it. **Fixed `daafe3de2`**: `GetFacingWallData` traces with `ValidLyraCharacter->GetWorld()`. Lesson: never call a GameplayAbility method that touches `GetWorld()` / actor info through `Spec.Ability` (the CDO); use the character, or `Spec.GetPrimaryInstance()`. Then (Marco PIE) the glider only opened after a double jump: an air press without a wall double-jumped **on press**, so every hold started with one. **`56029aab9`: tap vs hold in the air.** No wall → wait. If the glider opens (detected via its owned tag `Event.Movement.Gliding` during the press, not at release, so the two abilities' release order doesn't matter) → it was a hold, no double jump. If released first, within `MaxDoubleJumpTapDuration` 0.35 s → double jump **on release**. Wall jump still on press; ground jump unchanged. Trade-off: the double jump fires on release (~0.1 s later). Asked Marco to raise **`IA_Glide`'s own Hold 0.1 → ~0.2 s**, which is now the tap/hold boundary (0.1 is shorter than a keyboard tap). Fallbacks if it persists: debug log on glide start/end, or raise GA_Jump `Min Rising Time` 0.15 → 0.3. Wall launch Z: kick 600, skip 500 (XY 1200). Note: `IA_Glide` has its own Hold 0.1 trigger, which likely overrides Marco's per-mapping 0.5 (Space) / 0.25 (A).
Supersedes the engine-double-jump parts of C1 (no `JumpMaxCount` change). Double jump = the **exact air roll** (LaunchCharacter +400 Z, `AM_MA_AirRoll_01`, chimp roll message, `GE_Roll_Cooldown` 3 s **shared with the ground roll**), in a new button-less predicted ability triggered from GA_Jump. Plus once per airtime, refreshed on landing and on a wall jump.

**Step 1 — Us (C++)**
1. **New `UDoubleJumpGameplayAbility : ULyraGameplayAbility`** (Lyra defaults: InstancedPerActor + **LocalPredicted**, runs on client and server like the air roll did). No input.
   - Requires falling; `CommitAbility` (applies its `CooldownGameplayEffectClass` = `GE_Roll_Cooldown`, so the cooldown is shared with GA_Roll both ways for free, since both check the tags that GE grants); then `LaunchCharacter(0,0,LaunchZVelocity=400, false,false)`, play `AnimMontage`, broadcast `ChimpCompanionRollGameplayMessageChannel`, end.
   - **Once per airtime**: a flag on the instance, set on use, cleared on `ACharacter::LandedDelegate` and when `Event.Movement.WallMove` is added (ASC `RegisterGameplayTagEvent`; WallMove's owned tag exists on client and server). Both bound in `OnAvatarSet`, unbound on remove. Checked in `CanActivateAbility`.
2. **New tag** `Ability.Type.Action.DoubleJump` (`BASShooterCoreTags.ini`).
3. **`UJumpGameplayAbility`** (stays LocalOnly): ground → `UnCrouch` + `Jump()` (unchanged). Air → `FindWall()` on the granted WallMove → wall ? `TryActivateAbilitiesByTag(WallMove)` : `TryActivateAbilitiesByTag(DoubleJump)`. Rising window: loose `Movement.Mode.Jumping` after any of the three, removed when `Velocity.Z <= 0` / not falling, with a ~0.15 s minimum (the launches apply on the next movement tick, so an instant check would read the old falling speed). Stays active until release (mandatory, Lyra re-fires "pressed" every frame).
4. **`UWallMoveGameplayAbility`**: public `FindWall()` wrapping the **existing** 3-trace logic, used by its own `ActivateAbility` too (behaviour unchanged in step 1).
5. **`URollGameplayAbility`**: delete the air roll (`AirRoll`, `CanActivateAirRoll`, `AirRollLaunchZVelocity`, `AirRollAnimMontage`); `CanActivateRoll` also requires `IsMovingOnGround()`.
6. Review, compile on the VM **when no build is running**, commit + push to `deploy/steam-testing`, then message Marco (below).

**Step 1 — Marco (Editor), sent after the commit**
1. **Create `GA_DoubleJump`** (child of `DoubleJumpGameplayAbility`, next to `GA_Roll`), copying the air roll's setup:
   - Cooldown GE = `GE_Roll_Cooldown`; Anim Montage = `AM_MA_AirRoll_01`; Chimp channel = `Gameplay.Message.ChimpCompanionRoll`.
   - Ability Tags = `Ability.Type.Action.DoubleJump` + `Ability.Type.Action.Roll` (the Roll tag keeps the existing blocks working, e.g. the glider blocks it).
   - Activation Owned = `Event.Movement.Roll`; Cancel Abilities With Tag = `Sprint`, `Reload` (as GA_Roll).
2. Grant `GA_DoubleJump` in `AbilitySet_BASShooterHero` + `AbilitySet_ShooterHero`, **no input tag**.
3. `GA_Jump`: remove `Movement.Mode.Walking` (Activation Required), `Movement.Mode.Jumping` (Activation Owned), `Ability.Type.Action.Glide` (Block Abilities With Tag).
4. `IMC_Default_KBM`: delete the `IA_WallMove` rows (Middle Mouse, V, Gamepad B).
5. Both ability sets: `GA_Roll` input tag = `InputTag.Ability.Roll`; `GA_WallMove` input tag = none.
6. `GA_WallMove`: empty `Abilities Tags To Activate On Cancel`.
7. PIE test (dedicated server, 2 clients):
   - ground jump; hold → glider at the top
   - release, press → double jump (same feel as the old air roll, chimp reacts), once per airtime
   - landing refreshes it; wall jump refreshes it; 3 s cooldown shared with the ground roll
   - near a wall → wall jump; wall jumps chain
   - V / B rolls on the ground, nothing in the air; Space does nothing while gliding
   - bots still jump / glide

**Step 2 — new wall detection (C3)**: us rewrite `FindWall()` (sphere sweeps chest + knee, reach from the capsule surface, 6 directions incl. velocity, WorldStatic/Dynamic only, wall-normal filter, server tolerance); Marco tunes `WallReach`, `WallProbeRadius`, `MaxWallNormalZ` in PIE.

**Info from Marco before coding: none outstanding.** (I1, I2, I4 answered; I3 = no cue; I5 bots → during testing.)

#### Marco's answers (2026-10-17, dev chat + Editor screenshots)
- **Double-jump montage = `AM_MA_AirRoll_01`** (GA_Roll's `AirRollAnimMontage`, confirmed off the asset). `AM_MA_AirRoll_BWD_01` belongs to `GA_WallMove` (Kick/Skip montages). Only `AM_MA_*` montages are referenced, so the female ape already uses them. No change.
- **The head chimp reacts to the roll**, so the double jump must broadcast `Gameplay.Message.ChimpCompanionRoll` (planned).
- ⚠️ **`GE_Roll_Cooldown` = 3.0 s** (Scalable Float). My earlier "~2 s" off-asset read was wrong.
- ⚠️ **`GE_GlideCooldown` is attribute-based: 2.0 × `LyraCombatSet.Intelligence` (Source)**, so per-champion, not a flat 2 s.
- `GE_Roll_Cooldown` has **no Gameplay Cues** (`GameplayCue.Character.Roll.Cooldown` was a name in the asset, not a cue), so there's no HUD display to replicate.
- Marco: **"same exact behaviour, no longer in GA_Roll but in the jump one"**. That conflicts with C1's engine double jump (sets Vz to JumpZ, separate cooldown); the air roll *adds* +400, runs **predicted** (client + server), and **shares its 3 s cooldown with the ground roll**. Pending Dan: **B1** make GA_Jump LocalPredicted, or **B2 (recommended)** a button-less predicted `GA_DoubleJump` with the exact air-roll code (LaunchCharacter +400, `AM_MA_AirRoll_01`, chimp message, `GE_Roll_Cooldown`), triggered by GA_Jump when no wall is found; once-per-airtime = a flag reset on landing + wall jump; no `JumpMaxCount` change. Also: keep sharing the cooldown with the ground roll?
- Bots (I5): unanswered, check during testing.

#### C1. `UJumpGameplayAbility` becomes the traversal ability (C++)
- **Double jump = the engine's own 2nd jump**, not a hand-rolled launch. `JumpMaxCount = 2` is set **on the character** (see the verification block below: the server needs it, and the LocalOnly ability can't guarantee setting it there). Then `Jump()` in the air does the second jump through `APlayingCharacter::Jump` (same combat-stat `JumpZVelocity` multiplier as a ground jump). The CMC predicts and replicates it with its saved moves, resets `JumpCurrentCount` on landing (that's D3's landing reset), and counts walking off a ledge as the first jump (one air jump left). Better than the Air Roll's `+400` additive launch, which barely helps when you're already falling fast. *(Verified against the UE 5.5 source on the VM, see below.)*
- `ActivateAbility`:
  - **On the ground** → `UnCrouch()` + `Jump()` (as today).
  - **In the air** → `FindWall()` (C3). Wall → `TryActivateAbilitiesByTag(Ability.Type.Action.WallMove)`. No wall (or WallMove refused activation, e.g. during melee) → double jump if `JumpCurrentCount < JumpMaxCount` and off cooldown: `Jump()`, play `DoubleJumpMontage` (Marco sets `AM_MA_AirRoll_01`), broadcast the existing `Gameplay.Message.ChimpCompanionRoll` so the head chimp still animates, and stamp the cooldown.
- **Cooldown (D3)**: `DoubleJumpCooldown = 2.0` s (EditDefaultsOnly, matches `GE_Roll_Cooldown`), tracked as a **world-time stamp on the ability instance**. GA_Jump is **LocalOnly**, and a LocalOnly ability can't apply a GE on the client (no prediction key), so a cooldown GE isn't an option here. Note the interaction: a wall jump refreshes the double jump, but if you double-jumped less than 2 s ago the cooldown still blocks it. Set it to 0 if that feels wrong.
- **Stays active until release (mandatory).** Lyra fires ability "pressed" on `ETriggerEvent::Triggered` (`LyraInputComponent.h:63`), every frame while held, and re-tries inactive abilities every frame (`LyraAbilitySystemComponent::ProcessAbilityInput`). Ending early would repeat the air action every frame. Ends on `InputReleased` as today.
- **Rising window (D1)**: while active, add the loose tag `Movement.Mode.Jumping` after a ground jump / double jump / wall jump, and remove it once `Velocity.Z <= 0` or not falling (looping timer ~0.05 s while active; also removed in EndAbility). `GA_Glide` is already `ActivationBlockedTags = Movement.Mode.Jumping` and its Hold trigger re-tries every frame, so the glider opens at the apex while Space is held. Glide zeroes `Velocity.Z` on start, so opening at the apex never steals height.

#### ✅ Engine verification (2026-10-17, read-only on the VM, UE 5.5 source at `C:\UE5.5`, repo @ `8bc98dafe`, during a build, nothing touched)
- `ACharacter::JumpIsAllowedInternal` (`Character.cpp:307`): with `JumpMaxHoldTime = 0` (never set in project C++/ini or the hero BPs) → allowed if `JumpCurrentCount < JumpMaxCount`; if falling with count 0 (walked off a ledge) → needs `count + 1 < max`. `CheckJumpInput` (`:1125`) bumps the count to 1 first in that case → with `JumpMaxCount = 2`: **one air jump after a ground jump, one after walking off a ledge**. ✔
- `ResetJumpState` (`:340`) zeroes the count **only when not falling**; `StopJumping` calls it, so releasing Space mid-air keeps the count; reset happens on landing via `OnMovementModeChanged` (`:1080`). ✔ (D3 landing reset is free)
- `UCharacterMovementComponent::DoJump` (`CharacterMovementComponent.cpp:1100`): sets `Velocity.Z = Max(Velocity.Z, JumpZVelocity)` only if first jump **or `bDontFallBelowJumpZVelocityDuringJump`**. That flag **defaults true** (`:644`), and nothing in the project overrides it. ✔ So the 2nd jump restores full jump speed when falling; right after a wall kick (already rising faster) it adds nothing.
- Lyra's `CanAttemptJump` drops the crouch check and allows falling (`LyraCharacterMovementComponent.cpp:51`). ✔
- Saved moves capture `JumpCurrentCount` at move start (`SetMoveFor :12371`) and restore it on replay (`PrepMoveFor :12952`); `CanCombineWith` refuses to merge moves with different counts (`:12740`). So a wall-jump refresh done between moves is carried correctly into the next move. ✔
- ⚠️ **Correction to C1:** the **server uses its own `JumpMaxCount`** (the client replay restores `RealJumpMaxCount`, `:8413/:8476`). GA_Jump is **LocalOnly**, so setting it from the ability's avatar-set isn't guaranteed to run on the server. **Set `JumpMaxCount = 2` on the character instead**: `B_Hero_ShooterApeChampion_Base` Class Defaults (Marco), or the `APlayingCharacter` constructor. Bots share the class and would get the air jump too, harmless (they only `Jump()` once via nav links).
- ⚠️ Residual net risk: the server applies the wall-jump refresh when WallMove's activation RPC arrives. A double-jump press within a few ms of a wall jump could reach the server first → the server refuses the jump → small correction. Rare at human tap speed; accept.

#### C2. `UWallMoveGameplayAbility` (C++)
- Uses the new `FindWall()` (C3) instead of the three line traces (`GetFacingWallData`), so the jump and the wall move always agree.
- **Wall jump refreshes the double jump (D3)**: after the launch, `JumpCurrentCount = FMath::Min(JumpCurrentCount, 1)`, in `LaunchCharacterWithEffects` (runs predicted on client and server).
- ~~`AbilitiesTagsToActivateOnCancel = Roll` stays~~ → **cleared** (final rules above): V/B now reach `GA_Roll` directly.

#### C3. Wall detection (C++, D7), shared by C1 and C2
`bool UWallMoveGameplayAbility::FindWall(const ALyraCharacter*, FWallMoveHit& Out) const`, public, called by GA_Jump on the granted WallMove's CDO (found by tag on the ASC), so both use the same tuned values.

| Today | New |
|---|---|
| 1 line trace each way, at the capsule centre (chest height) | **Sphere sweep** (radius `WallProbeRadius`, default 25 cm) at centre height **plus** a second at ~knee height; hit if either connects |
| 100 cm **from the centre** (~60 cm from the capsule surface) | `CapsuleRadius + WallReach` (default `WallReach = 70` cm), measured from the capsule surface |
| Forward, then right/left | Forward, forward ±45°, right, left **and the horizontal velocity direction**. Nearest valid hit wins; a forward hit within `MaxAngleForWallKick` → kick, otherwise skip (existing maths) |
| `ECC_Visibility` (players, turrets, props count) | **Object query WorldStatic + WorldDynamic**, ignore self + attached actors. Players and devices don't count (`bPawnsCountAsWalls = false`, exposed) |
| Any surface | **Must be a wall**: `abs(ImpactNormal.Z) <= MaxWallNormalZ` (default 0.3), so floors, ceilings and ramps are rejected |
| — | Optional, phase 2: **coyote time** (remember the last valid wall for ~0.1 s), needs per-tick polling while airborne |

All `EditDefaultsOnly` on `GA_WallMove` so Marco tunes them. Server re-runs `FindWall` on activation (as today); add `ServerReachTolerance = 15` cm so small client/server position differences don't make the server reject a kick the client already did.

#### C4. `URollGameplayAbility` (C++, D5)
- Delete `AirRoll()`, `CanActivateAirRoll`, `AirRollLaunchZVelocity`, `AirRollAnimMontage`.
- **`CanActivateRoll` must also require `IsMovingOnGround()`.** Today it only checks for non-zero velocity, so without the air branch a V / B press in the air with no wall (WallMove cancel → Roll fallback) would do a horizontal ground-dash in mid-air. With the check, V / B in the air with no wall does nothing (Q-V1).

#### Editor (Marco)
- `GA_Jump`: remove `Movement.Mode.Walking` (ActivationRequiredTags), `Movement.Mode.Jumping` (ActivationOwnedTags), `Ability.Type.Action.Glide` (BlockAbilitiesWithTag). Set `DoubleJumpMontage = AM_MA_AirRoll_01` and the chimp roll message channel.
- `GA_WallMove`: tune `WallReach`, `WallProbeRadius`, `MaxWallNormalZ` in PIE.
- `GA_Roll`: nothing (the removed air-roll fields disappear).
- No input mapping changes.
- Check the bot BT jump/glide tasks (BP). C++ bot jumps call `Character->Jump()` (`NavLinkProxy_JumpToDestination.cpp:77`); with `JumpMaxCount = 2`, a bot pressed twice mid-air could now double jump.
- Check whether any HUD element shows the roll cooldown (`GE_Roll_Cooldown` has `GameplayCue.Character.Roll.Cooldown`). The double-jump cooldown is now a local timer, so a HUD icon would need a hook.

#### Order (one change at a time, Marco PIE-tests each)
1. C4 + C1 (double jump moved into jump, air roll removed, rising window + glide at apex), still on the **old** wall detection.
2. C3 + C2 (new wall detection, wall jump refreshes the double jump), tuning pass.

**Open:**
- **Q-V1** V / B in the air with no wall: nothing (as designed), or also double jump?
- **Q-G1** Pressing Space **while gliding** does nothing (Glide blocks Jump); release then press. OK, or should a press while gliding wall-jump / double-jump?
- **Q-C1** Cooldown vs wall refresh interaction (above).

### Open questions
1. Keep the **ground dodge roll** on its own button (V / B)?
2. Wall kicks have **no cooldown** (infinite chains between two walls). Intended?
3. Should players / turrets / props count as walls, or only level geometry?
4. **Hold after a double jump or wall kick → glide**: wanted? (The alternative, tap vs hold decided on release, adds input delay.)
5. Confirm the two ~2 s cooldowns in the Editor.

---

## Remaining (2026-10-17)

1. **#6 Disguise crash**: smallest, pure C++, root cause known (section 6). Not touched by `9e5bbd274`.
2. **#3 Melee throw replication**: pure C++, "stick into character" is still server-only cosmetics.
3. **#9 step 2 wall detection** (DESIGN v2 C3): a missed wall silently becomes a double jump.
4. **#7 ADS tags**: mostly Editor, needs a session with Marco on the relationship table.
5. **#2 Phys materials**: 1-line C++ fallback; the rest is Marco's map/material pass.

*(The 2026-09-09 suggested order is superseded: 1, 4, 5, 8 done.)*
