# Blend Gun blind + slow vs. Fire Ammo burn — how each was built (2026-09-09)

> **AS-BUILT 2026-09-09 — ✅ PIE-tested by Marco (blind/slow/burn all cleansed by any heal, blind now lasts the authored time). Commits `f916f6e26` + `3bab700be` on `deploy/steam-testing`. Cooked in Steam demo build `2026-10-17_19-41` (BuildID 26014993); awaiting in-match testing.**
> 1. **Every heal cleanses** — `ULyraHealthSet::PostGameplayEffectExecute` healing branch calls new `CleanseDebuffsOnHeal()` → `RemoveActiveEffectsWithGrantedTags(BASGameplayTags::GetHealCleansableTags())` (server only, positive heals only). Tag set = `Status.Blind`, `GameplayEffect.Blind`, `Status.SlowedDown`, `GameplayEffect.DamageTrait.Periodic` (mirrors Marco's healing-ammo query). Native tags added in `BASGameplayTags.h/.cpp`.
> 2. **Blind screen is now tag-driven** — `UBlindEffectWidget` binds `RegisterGameplayTagEvent(Status.Blind, NewOrRemoved)` on the owning player's ASC (character → fallback PlayerState) in `ExperienceLoaded` / `OnPossessedPawnChanged`, unbinds in `NativeDestruct`; count 0 → `RemoveAllSpots()`. Per-spot destruct timer kept as fallback.
> 3. **Bots** — `AArcasBotController` registers the same tag event on first blind, `OnBlindTagChanged` clears the fallback timer + `ResetAimAccuracy()`; listener removed in `OnUnPossess`. String-literal tag replaced by the native one.
> Files: `Source/LyraGame/{BASGameplayTags.h,.cpp, AbilitySystem/Attributes/LyraHealthSet.h,.cpp}`, `PLUGIN/{Public,Private}/UI/Widgets/BlindEffect/BlindEffectWidget.{h,cpp}`, `PLUGIN/{Public,Private}/AI/Controllers/ArcasBotController.{h,cpp}`. `.bak-20260909` copies next to each on the VM.
> Marco's per-asset removal components are now redundant (harmless); the periodic-heal validation error goes away if he deletes them.
> 4. **Blind tag duration bug found + fixed (follow-up, same day)** — first PIE test showed the screen blind ending after ~1 s. Cause (pre-existing, verified in UE5.5 `GameplayEffect.cpp`): the engine builds conditional specs via `FConditionalGameplayEffect::CreateSpec`, which does **not** copy SetByCaller magnitudes; `AttemptCalculateDurationFromDef` then defaults to **1.0 s**. So `GE_AddBlindTags` / `Status.Blind` / the bot aim penalty were always 1 s (the bot comment "Apparently the duration is one second" was this bug). `UCustomizableBlindExecution` now applies its conditional GEs itself as linked specs (`InitializeFromLinkedSpec` copies SetByCaller) and no longer calls `MarkConditionalGameplayEffectsToTrigger`. Applies to every blind source (shotgun, grenade, mine, rocket, MadZooka, MadBlower).

Verified against `deploy/steam-testing` @ `42c3c5e9f` (Marco, 9 Sep) with the real `.uasset` files pulled off the build VM (`strings`) plus the UE 5.5 GAS source on the VM. Numeric property values (durations, magnitudes) are NOT readable this way; those are flagged "Editor".

Paths: `PLUGIN/` = `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/`, `CONTENT/` = `Plugins/GameFeatures/BASShooterCore/Content/`.

---

## 0. TL;DR

| | **Blend Gun blind + slow** (default utility weapon) | **Fire Ammo burn** (Marco, Sep 2026) |
|---|---|---|
| Built by / when | Driver2579 (Bevium), Feb–Mar 2025 | Marco, Blueprint-only, 4–9 Sep 2026 |
| Applied from | `GA_Weapon_Fire_Shotgun.AdditionalGameplayEffects = [GE_Blind_Shotgun, GE_SlowDown_Shotgun]` | `GA_Weapon_Fire_Shotgun_FireAmmo.GE_Damage = GE_Damage_Shotgun_FireAmmo_Periodic` (projectile weapons apply instant + periodic from the projectile BP) |
| Blind effect | **Instant** GE → C++ `UCustomizableBlindExecution` → **reliable client RPC** → screen spot widgets with **local timers**; + conditional `GE_AddBlindTags` (HasDuration, grants `Status.Blind`) | — |
| Slow effect | `GE_SlowDown_Shotgun` (child of `GE_SlowDown_Base`): HasDuration, modifier on `MovementSpeedMultiplier`, grants `Status.SlowedDown`, **looping cue** `GCNL_SlowedDown` | — |
| Burn effect | — | HasDuration + Period GE, `LyraDamageExecution` per tick, asset tag `DamageTrait.Periodic`, **looping cue** `GCNL_Burned`. Grants **no** `Status.Burn` |
| Visual lifetime tied to GE? | Slow: **yes** (looping cue). Blind: **no** (widget timers) | **yes** (looping cue) |
| Icon above head | Slow: `NS_SlowedDownSprite` (juice icon) from `GCNL_SlowedDown`. Blind: none | `NS_Fire_Big_Simple` from `GCNL_Burned` |
| Cleansable by Marco's heal query | Slow ✅ · Blind tag ✅ but **screen stays blind** ❌ | ✅ (via `DamageTrait.Periodic`) |
| "Slowed aiming" | **Does not exist** for players (bots only) | — |

---

## 1. The weapon

- Item `ID_Shotgun` (display asset "Blend Gun", vault icon `T_UI_Vault_BlendGun`, mesh `SKM_BlendGun_01`, ammo icon `T_UI_HUD_LemonAmmo`). Fragments: `EquippableItem → WID_Shotgun`, `SetStats` (MagazineAmmo / MagazineSize / SpareAmmo), `ReticleConfig → W_Reticle_Shotgun`, `QuickBarIcon`, `PickupIcon`, `BarrackSlot`.
- `WID_Shotgun` → actor `B_Shotgun` (`AWeaponVisualization`; VFX: `NS_WeaponFire_Tracer_Shotgun_Blind`, `NS_BlindingJuice_Impact`, `NS_ImpactDecals_BlindingJuice`), instance `B_WeaponInstance_Shotgun` (`UBASRangedWeaponInstance`; tags `Gameplay.Weapon.Secondary`, spread curves, `MaxTraceRange`, `DistanceDamageFalloff`, `DA_MinMaxWeaponsStatsSettings`), ability set `AbilitySet_ShooterShotgun` = `GA_Weapon_Fire_Shotgun` (`InputTag.Weapon.FireAuto`), `GA_Weapon_Reload_Shotgun`, `GA_Weapon_AutoReload`, + `GE_Weapon_SpeedMultiplier_Base` (Infinite GE on `MovementSpeedMultiplier` = weapon handling weight).
- Ammo variants are **full duplicate chains**, not a toggle: `FireAmmo/`, `HealingAmmo/`, `DemolitionAmmo/` each have their own `ID_ → WID_ → B_ → AbilitySet_ → GA_Weapon_Fire_… → GE`. They reuse `B_WeaponInstance_Shotgun`, `W_Reticle_Shotgun`, `W_AmmoCounter_Shotgun`. The variants carry **no** blind/slow GEs.

## 2. The fire ability graph (`Content/Weapons/GA_Weapon_Fire`, parent of all `GA_Weapon_Fire_*`)

C++ base `UBASGameplayAbility_RangedWeapon : ULyraGameplayAbility_RangedWeapon`. C++ does the trace (`bReturnPhysicalMaterial = true`, `LyraGameplayAbility_RangedWeapon.cpp:151`), spread, `AddMouseRecoil`, then next tick calls the BP event `OnRangedWeaponTargetDataReady` (`.cpp:559-563`). **All GE application is Blueprint**:

```
OnRangedWeaponTargetDataReady(TargetData)
 └ ForLoop 0..GetDataCountFromTargetData
     ├ GetHitResultFromTargetData(i) → HitActor
     ├ CompareTeams(Avatar, HitActor)  → "Friendly Fire" / "Enemy Fire" / OnSameTeam branches
     ├ BP_ApplyGameplayEffectToTarget(GE_Damage, Level)          ← property on the C++ base; parent default = GE_Damage_Pistol
     ├ ForEachLoop(AdditionalGameplayEffects) → ApplyGameplayEffectToTarget(each, AdditionalGameplayEffectsTargetData)
     └ hit-react montage on the victim ("Only receiving player plays animation")
 └ ExecuteGameplayCueWithParams(GameplayCue.Weapon.<X>.Fire / .Impact, MakeGameplayCueParametersFromHitResult(index 0))
```

- `GA_Weapon_Fire_Shotgun` overrides: `AdditionalGameplayEffects = [GE_Blind_Shotgun_C, GE_SlowDown_Shotgun_C]`, `GameplayCue.Weapon.Shotgun.Fire`, BlendGun montages, `TraceMaxDistance`. ⚠️ It does **not** appear to override `GE_Damage` (no damage GE import in the asset) → it inherits the parent's `GE_Damage_Pistol` unless the property was cleared to None. **Editor check needed**: does the Blend Gun do pistol damage on top of blind + slow?
- `GA_Weapon_Fire_Shotgun_FireAmmo`: `GE_Damage = GE_Damage_Shotgun_FireAmmo_Periodic`, `AdditionalGameplayEffects` **not** overridden (empty). No blind, no slow.
- `GA_Weapon_Fire_Shotgun_HealingAmmo`: `GE_Damage = GE_Heal_Shotgun`, uses the Friendly/Enemy branches.
- Every GE the ability applies shares the same effect context (`ULyraGameplayAbility::MakeEffectContext`, `LyraGameplayAbility.cpp:290-313`): instigator, effect causer, **source object = the weapon instance** (needed by `ApplyPowerMultiplierToOutExecutionOutput`), hit result + phys-material tags into `CapturedTargetTags` (`:315-326`).

## 3. Blind — the full chain

### 3.1 Assets
- `CONTENT/Weapons/Secondary/Shotgun/GE_Blind_Shotgun` — parent `GE_Damage_Basic_Instant` (**Instant**), asset tags `GameplayEffect.DamageTrait.Instant`, `DamageType.Basic`, `DamageType.Shotgun`. Execution `UCustomizableBlindExecution` with ONE calculation modifier: `LyraCombatSet.BaseCustomPower`, Source, snapshot, `AddBase`, ScalableFloat (**the value = blind duration in seconds; Editor-only**; the bot code comments "Apparently the duration is one second"). Conditional GE `GE_AddBlindTags`. **No gameplay cue** (the grenade variant `GE_Blind_Grenade` still lists `GameplayCue.Character.BlindEffectTaken`, which has no notify asset anywhere).
- `Content/Weapons/GE_AddBlindTags` — HasDuration, duration = `SetByCaller.Duration`, granted tag `Status.Blind` (`TargetTagsGameplayEffectComponent`), asset tag `GameplayEffect.Blind`. No cues, no modifiers.
- `Content/UI/Hud/W_BlindEffect` (`UBlindEffectWidget`) + `W_BlindSpot` (`USpotWidget`, `MI_UI_HUD_BlindEffect`, `OpacityMaterialParameterName`).
- Siblings using the identical recipe: `GE_Blind_Grenade`, `_Mine`, `_Rocket`, `_MadZooka`, `_MadBlower` (all under `Weapons/Misc/Grenade/`).

### 3.2 Runtime (server)
1. BP applies `GE_Blind_Shotgun` per pellet hit (per target, per cartridge — N pellets on one victim = N executions = N RPCs = 3N spots; see 3.5).
2. `UCustomizableBlindExecution::Execute_Implementation` (`PLUGIN/Private/AbilitySystem/GameplayEffectExecutions/CustomizableBlindExecution.cpp:12-49`):
   - `Super::` = `UCustomizableCustomPowerExecution` (`Source/LyraGame/AbilitySystem/Executions/CustomizableCustomPowerExecution.cpp:20-138`): full Lyra damage math (team check, distance, phys-mat attenuation) and, if > 0, an output modifier on `LyraHealthSet.CustomPower` × `PowerMultiplier`. **`CustomPower` is a dead attribute — nothing reads it.**
   - Re-reads the captured `BaseCustomPower` → `PowerFinalMagnitude` = **duration**. Not multiplied by power, distance, phys-mat or team (so friendly pellets still blind teammates unless the BP branch skips them).
   - `ExecuteBlindEffect`: builds `FBlindEffectMessage{TargetPlayer = PlayerState, Time = duration, OpacityAlpha = 1 − Intelligence}` and calls `APlayingCharacter::AddReplicatedBlindEffect` (`PlayingCharacter.cpp:883-923`) → local broadcast + `Client_BroadcastBlindEffectMessage` (**reliable client RPC**) → `UI.BlindEffect` gameplay message.
   - Writes `SetByCaller.Duration = duration` onto the owning spec and `MarkConditionalGameplayEffectsToTrigger()` → engine creates the `GE_AddBlindTags` spec, copies SetByCaller magnitudes (`GameplayEffect.cpp:1669`), applies it → `Status.Blind` for `duration` s.
3. Bots: `AArcasBotController::HandleBlindEffectApplied` (`ArcasBotController.cpp:684-728`) sees `GE_AddBlindTags` via `OnGameplayEffectAppliedDelegateToSelf`, sets `AimAccuracy = 0.02`, restores after `GetDuration() + 5 s` on a timer.

### 3.3 Runtime (client)
`UBlindEffectWidget::AddSpots` (`BlindEffectWidget.cpp:108-137`): filters `Payload.TargetPlayer == own PlayerState`, spawns `SpotsNum` (3) `USpotWidget`s with random transform, opacity = lerp(Min, Max, alpha), and **`SetDestructTimer(Payload.Time)`** = a plain `FTimerManager` timer → `RemoveFromParent` (`SpotWidget.cpp:42-46`). `RemoveAllSpots()` only on pawn change / death (`:71-106`, `:139-142`).

→ **The screen effect has no link to `Status.Blind`, to `GE_AddBlindTags`, or to any ASC state.** Removing the GE (heal cleanse, death, anything) leaves the spots until their timers expire. This is the crux for "disappear when healed".

### 3.4 Intelligence
`ULyraCombatSet::Intelligence` initial value from `CT_PlayerStats/Curve_Intelligence` at the champion's stat level (`LyraCombatSet.cpp:24-28`, clamped `:148-165`; `AddBASBaseStatsAbilities`, `LyraAbilitySystemComponent.cpp:586-620`; stat levels 3..12). **Its only gameplay use is blind opacity** (`CustomizableBlindExecution.cpp:87-105`, assumes [0,1], no clamp).

### 3.5 Why it was built this way (history)
- Feb 2025 `d5c44e722` / `bc0c8478c`: blind first shipped as `UBlindEffectGameplayCueNotify : UGameplayCueNotify_Burst` (OnExecute → broadcast `UI.BlindEffect`, duration = `RawMagnitude`).
- 6 Mar 2025 `d99e4343c` (Driver2579): *"Moved BlindEffectGameplayCueNotify's logic into the CustomizableCustomPowerExecution because gameplay cues are unreliable. Made the blind effect to trigger another gameplay effect that adds blind tag to the character."* Deleted the cue notify, added the execution + `GE_AddBlindTags` + `SetByCaller.Duration` + the reliable client RPC on `APlayingCharacter`.
- The unreliability is real and still present: `ULyraGameplayCueManager` (`Source/LyraGame/AbilitySystem/LyraGameplayCueManager.cpp`) runs `LoadUpfront` with `ShouldSyncLoadMissingGameplayCues() == false` (`:115-118`) → a cue whose notify isn't loaded yet is **dropped** and only queued for async load; the whole delay-load path is dead in this config. Same author fixed ~8 "cue didn't play / wrong transform" bugs in that window (`dca99b6c9`, `4b2bdfc54`, `8c226223d`, `4c7723062`, `1fac64ea8`, `cecd7ed49`, `490759ef8`).
- ⚠️ Consequence: `GCNL_SlowedDown` and Marco's `GCNL_Burned` are **looping cues on exactly the mechanism the blind was moved away from**. Expect the occasional silent miss on first use in a session.

## 4. Slow — the full chain
- `GE_SlowDown_Shotgun` (child, only overrides `DurationMagnitude`, ScalableFloat — **Editor**) ← `GE_SlowDown_Base`: HasDuration, `AggregateByTarget` stacking, one modifier on `LyraCombatSet.MovementSpeedMultiplier` (magnitude **Editor**), granted tag `Status.SlowedDown`, cue `GameplayCue.Character.SlowedDown`.
- Consumer: **only** `ULyraCharacterMovementComponent::GetMaxSpeed()` → `Super::GetMaxSpeed() * MovementSpeedMultiplier` (`LyraCharacterMovementComponent.cpp:157-172`). Not rotation, not look input, not spread.
- Visual: `CONTENT/Weapons/Misc/SlowDownEffect/GCNL_SlowedDown` (`GameplayCueNotify_Looping`, AttachToTarget) → `NS_SlowedDownSprite` (`M_JuiceIcon`/`T_JuiceIcon`) = **the icon floating above the victim**. Lifetime == GE lifetime, GAS-managed, replicated through the ASC's active-GE cue path.
- Siblings: `GE_SlowDown_Grenade/_Mine/_Rocket/_MadBlower`, `Primary/PlasmaShotgun/GE_SlowDown_Shotgun` (same name, different folder), `GE_SlowingTarget`, `GE_Damage_Periodic_Slow`, `GE_StunEffect` (`SetByCaller.StunDuration`, `GameplayCue.Character.Stun`).

## 5. "Slowed aiming" — verdict: not implemented for players
- `Status.SlowedDown`: zero C++ references. `Status.Blind`: one (bot controller string literal).
- Look input is raw: `ULyraHeroComponent::Input_LookMouse/Stick` (`LyraHeroComponent.cpp:405-449`); input modifiers are settings-only (`LyraInputModifiers.cpp`). `RotationRate` only scales with **Agility** (`LyraCharacterMovementComponent.cpp:71-88`). `GetDeltaRotation` is zeroed only by `Gameplay.MovementStopped`.
- Spread (`LyraRangedWeaponInstance.cpp:166-219`) = aiming × standing-still × crouch × jump/fall × `SpreadMultiplier`; standing-still uses raw velocity → **a slowed player actually gets tighter spread**.
- The only blind-linked aim penalty is the **bot** `AimAccuracy = 0.02`.
- `ULyraCombatSet::SpeedModifier` (0.2–2.0) is read by nothing but a getter. No Handling/LookRate/AimSpeed attribute exists.
- To build it: scale `Input_LookMouse/Stick` by an attribute or tag, or add a `Status.SlowedDown` term in `UpdateMultipliers`, or scale `GetDeltaRotation` the way `GetMaxSpeed` is scaled.

## 6. The nameplate "status effect" system (the thing above the head that is NOT the juice icon)
- BP-only: `Content/UI/Indicators/NameplateManagerComponent` listens to `Gameplay.Message.Nameplate.Status.Add/Remove` (payload `Message_NameplateStatusEffect{StatusEffect: UStatusEffect, Duration, CanAutomaticallyRemove}`) → `W_Nameplate` → `CONTENT/UI/StatusEffects/W_StatusEffects` (`TryAddStatusEffect/TryRemoveStatusEffect`) → `W_EffectVisual` (icon + name). `UStatusEffect` = data asset with `Name` + `Icon` (`PLUGIN/Public/StatusEffect.h`), no C++ users.
- Only one status asset exists: `CONTENT/StatusEffects/SE_Disguise` ("Disguised", icon `Companion_v03`).
- **Nothing broadcasts `Nameplate.Status.Add`** — grep of all `Content/UI` + BASShooterCore content on the VM finds the tag only inside the manager itself. `GA_Disguise` does not send it either. The system is scaffolding; blind/slow/burn do not use it. `W_Nameplate` does hide names for `Totems.Disguise` via a tag check.
- Also listens to `Gameplay.Message.ADS` / `.End` (`FADSMessage`) — nameplates show on aim.

## 7. Differences from the fire recipe, and what it means for "disappear when healed"

| Aspect | Burn | Slow | Blind |
|---|---|---|---|
| GE duration policy | HasDuration + Period | HasDuration | **Instant** (+ separate tag GE) |
| Per-tick execution | `LyraDamageExecution` each period | none (modifier) | one-shot at apply |
| State carrier | active GE | active GE | **widget timers on the client** |
| Marker tag granted | **none** (`Status.Burn` unused) | `Status.SlowedDown` | `Status.Blind` (on the side GE) |
| Visual | looping cue (unreliable path, but GE-bound) | looping cue (same) | reliable RPC (deliberately not a cue), **not GE-bound** |
| Removal removes visual | ✅ | ✅ | ❌ |

Marco's heal query (`42c3c5e9f`, on the 5 healing-ammo GEs, fires once at application, server only, matches asset+granted tags only): hits burn via `DamageTrait.Periodic`, slow via `Status.SlowedDown`, and the blind **tag** via `Status.Blind`/`GameplayEffect.Blind`. The blind screen keeps its timers. Cue tags and `UI.BlindEffect` in the query are inert. On the two periodic heal GEs the editor flags the component as a validation error ("GE is Periodic…") but it still runs at apply.

**What has to change (C++, 2 files, no asset edits required for the query to work):**
1. `UBlindEffectWidget` becomes tag-driven: on possess, `ASC->RegisterGameplayTagEvent(Status.Blind, NewOrRemoved)` → count 0 → `RemoveAllSpots()`. Keep the destruct timer only as a fallback. Bonus: stacking N pellets no longer produces 3N timer-owned spots that outlive each other.
2. `AArcasBotController`: restore `AimAccuracy` on the same tag event instead of `Duration + 5 s`.

Recommended cleanup after that: one `Status.Debuff.Cleansable` granted by `GE_AddBlindTags`, `GE_SlowDown_Base` and the `*_FireAmmo_Periodic` GEs (they grant nothing today), and the heal query reduced to that single tag — so healing stops keying off `DamageTrait.Periodic` (which would also cleanse any future periodic damage) and the cleanse can be put on the totem/device/pickup heals too.

## 8. Editor-only unknowns
- `GE_Blind_Shotgun` ScalableFloat (blind seconds); `GE_SlowDown_Shotgun` duration + `GE_SlowDown_Base` speed magnitude.
- Whether `GA_Weapon_Fire_Shotgun.GE_Damage` is None or inherited `GE_Damage_Pistol`.
- `CT_PlayerStats/Curve_Intelligence` range (must stay within [0,1]).
- `BlindEffectWidget` `SpotsNum`, `Min/MaxOpacityValue`, `Min/MaxScaleValue` (class defaults in `W_BlindEffect`).
