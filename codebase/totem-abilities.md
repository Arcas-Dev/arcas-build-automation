# Totem Abilities System

Totems are special abilities in Arcas Champions. Each player equips 3 totems in their loadout (Damage, Support, Personal). This doc covers the C++ architecture and how to modify them.

---

## Totem Slots

| Slot | Type | Input Action | Examples |
|------|------|--------------|----------|
| 0 | Damage | `IA_Ability_Damage` | Rage, Grenade, Companion |
| 1 | Support | `IA_Ability_Support` | Team Healing, Ammo Box, Supercharge |
| 2 | Personal | `IA_Ability_Personal` | Personal Healing, Animal Instinct, Auto Turret |

---

## Class Hierarchy

```
ULyraGameplayAbility
  └── UBASGameplayAbilityWithReset
        └── UTotemGameplayAbilityBase (FTickableGameObject)
              ├── Tick(), SetCooldownTime(), RemoveCooldown()
              ├── DeactivateWidget(), ActivateWidget()
              └── UTotemGameplayAbilityWithDeploymentAnimationBase
                    ├── StartDeploymentAnimationAsync()
                    ├── OnDeployedGameplayEventReceived()
                    ├── OnDeployedGameplayEventReceivedWithServerWait()
                    └── URageTotemGameplayAbility (concrete)
```

### Key Base Class Features

**UTotemGameplayAbilityBase** (`TotemGameplayAbilityBase.h`):
- Implements `FTickableGameObject` for per-frame updates
- Manages cooldown lifecycle (apply, remove, broadcast to UI)
- Manages widget activation/deactivation (for quickbar icon states)
- Integrates with `UTotemGameplayAbilitySubsystem` for cross-ability coordination

**UTotemGameplayAbilityWithDeploymentAnimationBase** (`TotemGameplayAbilityWithDeploymentAnimationBase.h`):
- Handles async loading and playing of deployment animation montage
- Fires `OnDeployedGameplayEventReceived` when animation reaches a notify point
- `OnDeployedGameplayEventReceivedWithServerWait` variant ensures client fires before server (for prediction)
- Auto-cancels ability if deployment animation is interrupted

---

## Source File Locations

All under: `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/`

### Headers (Public/)

| File | Class |
|------|-------|
| `AbilitySystem/Abilities/TotemAbilities/TotemGameplayAbilityBase.h` | `UTotemGameplayAbilityBase` |
| `AbilitySystem/Abilities/TotemAbilities/TotemGameplayAbilityWithDeploymentAnimationBase.h` | Base with deployment anim |
| `AbilitySystem/Abilities/TotemAbilities/RageTotemGameplayAbility.h` | `URageTotemGameplayAbility` |
| `AbilitySystem/Abilities/BASGameplayAbilityWithReset.h` | `UBASGameplayAbilityWithReset` |

### Content Assets

| Asset | Location | Purpose |
|-------|----------|---------|
| `GA_Rage.uasset` | `Plugins/.../Content/GameplayAbilities/` | Rage ability Blueprint (data-only) |
| `GE_Rage.uasset` | `Plugins/.../Content/GameplayEffects/` | Damage buff effect |
| `GE_RageCooldown.uasset` | `Plugins/.../Content/GameplayEffects/` | Cooldown timer |
| `GE_Rage_Explosion.uasset` | `Plugins/.../Content/GameplayEffects/` | Self-destruct damage |
| `ID_Rage.uasset` | `Plugins/.../Content/Totems/` | Item definition (links ability + input tag) |
| `DA_TotemsClasses.uasset` | `Content/Totems/` | Registry of all totem item definitions |

---

## Rage Ability - Deep Dive

### Parameters (Editable in GA_Rage Class Defaults)

| Property | Type | Default | Category |
|----------|------|---------|----------|
| `GameplayCueTag` | FGameplayTag | `GameplayCue.Abilities.Rage` | Gameplay Cues |
| `RageGameplayEffectClass` | TSoftClassPtr | `GE_Rage` | Gameplay Effects |
| `RageExplosionGameplayEffectClass` | TSoftClassPtr | `GE_Rage_Explosion` | Gameplay Effects |
| `SurvivalTime` | float | 30.0 | Timers |
| `DeathTime` | float | 10.0 | Timers |
| `EliminationGameplayMessageChannel` | FGameplayTag | `Lyra.Elimination.Message` | Gameplay Messages |
| `SideBarWidgetClass` | TSubclassOf | `W_SideBarRage` | UI |
| `DeploymentAnimMontage` | TSoftObjectPtr | (set in BP) | Animation > Deployment |

### Lifecycle

```
Player presses ability key
    │
    ▼
ActivateAbility()
    ├── CommitCheck() → fail? CancelAbility()
    ├── AddGameplayCue(GameplayCueTag) → VFX on character
    ├── StartDeploymentAnimationAsync() → plays anim montage
    ├── Async load RageGameplayEffectClass
    ├── Async load RageExplosionGameplayEffectClass
    └── CreateSideBarWidget() [local player only]
    │
    ▼
OnDeployedGameplayEventReceived() [anim notify fires]
    ├── SetTimer(SurvivalTimerHandle, 30s) → K2_EndAbility
    ├── SetTimer(DeathTimerHandle, 10s) → ApplyRageExplosionAndEnd
    ├── RegisterListener(Lyra.Elimination.Message)
    └── Start UIUpdateTimerHandle (0.05s loop) [local player only]
    │
    ▼
OnDeployedGameplayEventReceivedWithServerWait() [client before server]
    ├── CommitAbility() (costs + cooldown)
    └── ApplyRageGameplayEffect() → damage buff active
    │
    ▼
ACTIVE STATE (buff running, death timer counting down)
    │
    ├── OnEliminationMessageReceived()
    │     └── If instigator==self && target!=self
    │           └── Restart DeathTimerHandle (back to 10s)
    │
    ├── UpdateSideBarUI() [every 0.05s, local player]
    │     └── widget->SetProgress(GetDeathTimeProgress())
    │
    ├── DeathTimer expires → ApplyRageExplosionGameplayEffectAndEndAbility()
    │     ├── Apply GE_Rage_Explosion (self-destruct damage)
    │     └── EndAbility()
    │
    └── SurvivalTimer expires → K2_EndAbility() (survived!)
    │
    ▼
EndAbility()
    ├── DestroySideBarWidget()
    ├── ClearTimer(SurvivalTimerHandle)
    ├── ClearTimer(DeathTimerHandle)
    ├── RemoveGameplayCue(GameplayCueTag)
    ├── ReleaseStreamableHandle (unload effects)
    └── RemoveActiveGameplayEffect(RageGameplayEffectHandle)
```

### Blueprint-Callable UI Functions

Added to `URageTotemGameplayAbility` for widget integration:

```cpp
UFUNCTION(BlueprintCallable, Category="Rage|UI")
float GetDeathTimeRemaining() const;   // Seconds left on death timer

UFUNCTION(BlueprintCallable, Category="Rage|UI")
float GetDeathTimeProgress() const;    // 0.0 (just started) → 1.0 (about to explode)

UFUNCTION(BlueprintCallable, Category="Rage|UI")
bool IsRageActive() const;             // Wrapper around IsActive()

UFUNCTION(BlueprintCallable, Category="Rage|UI")
bool IsDeathTimerActive() const;       // True after deployment, false before
```

### Important: Async Loading Pattern

Rage uses `TSoftClassPtr` for Gameplay Effects to avoid hard references:

```cpp
// Soft reference (doesn't load until needed)
UPROPERTY(EditDefaultsOnly)
TSoftClassPtr<UGameplayEffect> RageGameplayEffectClass;

// Async load on ActivateAbility (before needed)
FStreamableManager& SM = UAssetManager::GetStreamableManager();
LoadHandle = SM.RequestAsyncLoad(
    RageGameplayEffectClass.ToSoftObjectPath(),
    FStreamableDelegate::CreateUObject(this, &ThisClass::OnLoaded));

// Apply when loaded (or queue if not yet loaded)
if (RageGameplayEffectClass.IsValid())
    ApplyRageGameplayEffect();
else
    bApplyOnLoaded = true;
```

### Important: Prediction System

The `OnDeployedGameplayEventReceivedWithServerWait` function exists specifically to ensure gameplay effects are applied on the client BEFORE the server. This prevents prediction mismatch. The pattern:

1. `OnDeployedGameplayEventReceived` fires on server first (starts timers, registers listeners)
2. `OnDeployedGameplayEventReceivedWithServerWait` fires on client first (commits ability, applies effects)

**Never apply gameplay effects in `OnDeployedGameplayEventReceived`** - use `WithServerWait` variant.

---

## How Abilities Are Granted

When a match starts, `BASAbilitySet::GiveToAbilitySystem()`:

1. Reads player's `FBASPlayerInfo` loadout
2. For each slot (Damage/Support/Personal), gets the `ULyraInventoryItemDefinition`
3. Finds `UInventoryFragment_TotemItem` fragment containing `GameplayAbility` class + `InputTag`
4. Grants the ability to the player's `UAbilitySystemComponent`

---

## Modifying a Totem Ability

### What Can Be Changed in C++ (via SSH)

| Change | How |
|--------|-----|
| Add new properties to an ability | Add `UPROPERTY` to header, use in .cpp |
| Add new Blueprint-callable functions | Add `UFUNCTION(BlueprintCallable)` |
| Change timer logic | Modify timer setup in .cpp |
| Change elimination handling | Modify `OnEliminationMessageReceived` |
| Add new UI integration | Create widget class, manage in ability lifecycle |

### What Requires UE5 Editor (RDP)

| Change | How |
|--------|-----|
| Set property default values | GA_Rage Class Defaults |
| Change which effects are used | Edit soft class references in Class Defaults |
| Change deployment animation | Set DeploymentAnimMontage in Class Defaults |
| Wire Blueprint events | Event Graph in Widget/Ability Blueprints |
| Modify visual assets | Material/Texture editors |

---

## Other Totem Abilities (For Reference)

| Totem | Likely Base Class | Key Mechanic |
|-------|-------------------|--------------|
| **Rage** | WithDeploymentAnimation | Death timer + kill reset + sidebar widget |
| **Grenade** | WithDeploymentAnimation | Projectile spawn |
| **Companion** | WithDeploymentAnimation | AI NPC spawn (ChimpCompanion) |
| **Team Healing** | WithDeploymentAnimation | Area heal device spawn |
| **Ammo Box** | WithDeploymentAnimation | Ammo resupply device spawn |
| **Auto Turret** | WithDeploymentAnimation | Deployable turret spawn |
| **Personal Healing** | Base | Self heal |
| **Animal Instinct** | Base | Enemy detection |

---

## Related Systems

| System | Key File | Purpose |
|--------|----------|---------|
| Elimination Messages | `GameplayMessageSubsystem` | Broadcasts kill events |
| Self-Destruct | `LyraHealthComponent.cpp:219` | `DamageSelfDestruct()` |
| Totem Subsystem | `TotemGameplayAbilitySubsystem` | Cross-ability coordination |
| Quickbar UI | `SingleTotemWidget.h` | Individual totem slot display |
| Totems Widget | `TotemsWidget.h` | Container for all totem slots |
