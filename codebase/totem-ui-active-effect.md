# Adding/Modifying UI Effects for Totem Abilities

This doc covers the pattern for connecting a UI widget to a totem ability's active state - e.g. showing a progress bar, timer, or visual effect while an ability is active.

---

## Architecture Pattern

```
UTotemGameplayAbility (C++)
  ├── Creates widget on ActivateAbility [local player only]
  ├── Updates widget state via timer during active phase
  └── Destroys widget on EndAbility

USideBarAbilityWidget : UUserWidget (C++)
  ├── Properties exposed to Blueprint (BlueprintReadOnly)
  ├── Setter methods (BlueprintCallable)
  └── BlueprintImplementableEvents for Blueprint to react

W_SideBarRage : USideBarAbilityWidget (Blueprint)
  ├── Visual layout (images, materials, animations)
  └── Event overrides wired to material parameters
```

**Key principle**: C++ controls the lifecycle and data flow. Blueprint controls the visuals. They communicate through exposed properties and BlueprintImplementableEvents.

---

## Step-by-Step: Adding a New Active Effect UI

### 1. Create C++ Widget Base Class

**Header** (`Public/UI/YourWidget.h`):

```cpp
#pragma once

#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "YourWidget.generated.h"

UCLASS()
class BASSHOOTERCORERUNTIME_API UYourWidget : public UUserWidget
{
    GENERATED_BODY()

public:
    // Properties that Blueprint can read
    UPROPERTY(BlueprintReadOnly, Category="YourWidget")
    float Progress = 0.0f;

    UPROPERTY(BlueprintReadOnly, Category="YourWidget")
    bool bSomeState = false;

    // Setters called from C++ ability code
    UFUNCTION(BlueprintCallable, Category="YourWidget")
    void SetProgress(float InProgress);

    UFUNCTION(BlueprintCallable, Category="YourWidget")
    void SetSomeState(bool bInState);

protected:
    // Blueprint overrides these to update visuals
    UFUNCTION(BlueprintImplementableEvent, Category="YourWidget")
    void OnProgressChanged(float NewProgress);

    UFUNCTION(BlueprintImplementableEvent, Category="YourWidget")
    void OnSomeStateChanged(bool bNewState);
};
```

**Implementation** (`Private/UI/YourWidget.cpp`):

```cpp
#include "UI/YourWidget.h"

void UYourWidget::SetProgress(float InProgress)
{
    Progress = FMath::Clamp(InProgress, 0.0f, 1.0f);
    OnProgressChanged(Progress);
}

void UYourWidget::SetSomeState(bool bInState)
{
    if (bSomeState != bInState)
    {
        bSomeState = bInState;
        OnSomeStateChanged(bSomeState);
    }
}
```

**Note**: The `SetSomeState` pattern with change detection avoids triggering Blueprint events every tick when the value hasn't changed.

### 2. Add Widget Management to the Ability

**Header additions** (in the ability `.h`):

```cpp
// Forward declare
class UYourWidget;

// In the class body (private section):
UPROPERTY(EditDefaultsOnly, Category="UI")
TSubclassOf<UYourWidget> WidgetClass;

UPROPERTY()
TObjectPtr<UYourWidget> Widget;

FTimerHandle UIUpdateTimerHandle;

void CreateWidget();
void DestroyWidget();
void UpdateWidgetUI();
bool IsOwnerLocallyControlled() const;
```

**Implementation** (in the ability `.cpp`):

```cpp
#include "UI/YourWidget.h"

void UYourAbility::CreateWidget()
{
    if (!IsOwnerLocallyControlled()) return;
    if (!WidgetClass) return;
    if (Widget) return;

    APlayerController* PC = CurrentActorInfo->PlayerController.Get();
    if (!PC) return;

    Widget = CreateWidget<UYourWidget>(PC, WidgetClass);
    if (Widget)
    {
        Widget->AddToViewport(10);  // ZOrder 10 = above most HUD
    }
}

void UYourAbility::DestroyWidget()
{
    if (GetWorld())
    {
        GetWorld()->GetTimerManager().ClearTimer(UIUpdateTimerHandle);
    }
    if (Widget)
    {
        Widget->RemoveFromParent();
        Widget = nullptr;
    }
}

void UYourAbility::UpdateWidgetUI()
{
    if (!Widget) return;
    Widget->SetProgress(GetSomeProgress());
    Widget->SetSomeState(IsSomeConditionActive());
}

bool UYourAbility::IsOwnerLocallyControlled() const
{
    if (!CurrentActorInfo) return false;
    const APawn* AvatarPawn = Cast<APawn>(CurrentActorInfo->AvatarActor.Get());
    return AvatarPawn && AvatarPawn->IsLocallyControlled();
}
```

### 3. Integrate into Ability Lifecycle

```cpp
void UYourAbility::ActivateAbility(...)
{
    Super::ActivateAbility(...);
    // ... existing activation code ...
    CreateWidget();  // Shows widget immediately (progress=0)
}

void UYourAbility::OnDeployedGameplayEventReceived(...)
{
    Super::OnDeployedGameplayEventReceived(...);
    // ... existing code (start timers, etc.) ...

    // Start UI updates AFTER timers are running
    if (IsOwnerLocallyControlled() && Widget)
    {
        GetWorld()->GetTimerManager().SetTimer(
            UIUpdateTimerHandle, this,
            &ThisClass::UpdateWidgetUI,
            0.05f, true);  // 20fps = smooth enough for fill bars
    }
}

void UYourAbility::EndAbility(...)
{
    DestroyWidget();  // Remove widget FIRST
    // ... existing cleanup code ...
    Super::EndAbility(...);
}
```

### 4. Compile and Deploy to VM

See `general-workflow.md` for the full SCP + compile process.

### 5. Editor Work (RDP) - Blueprint Setup

#### 5a. Create/Reparent Widget Blueprint

If Marco already created a widget Blueprint (like `W_SideBarRage`):

1. Open it in Widget Blueprint editor
2. **File > Reparent Blueprint** → select your new C++ class (e.g. `SideBarAbilityWidget`)
3. Compile + Save

If creating from scratch:
1. Content Browser > right-click > User Interface > Widget Blueprint
2. Set parent class to your C++ widget class
3. Design the visual layout in Designer tab

#### 5b. Set Widget Class in Ability

1. Open the ability Blueprint (e.g. `GA_Rage`)
2. Click **Class Defaults**
3. Find your `Widget Class` property under the **UI** category
4. Select the widget Blueprint from the dropdown
5. Compile + Save

**Important**: The widget Blueprint only appears in the dropdown AFTER reparenting to the C++ base class. Do 5a before 5b.

#### 5c. Wire Visual Updates in Blueprint

The widget Blueprint needs to override the `OnProgressChanged` event to update its visuals.

**For Material-based visuals** (common pattern in this project):

1. Open widget Blueprint → **Graph** tab
2. Find/add **Event On Progress Changed** override
3. Wire: Get Dynamic Material (on the Image element) → Set Scalar Parameter Value
4. Parameter name depends on the material (check the Master Material for parameter names)

**Rage widget specifically uses:**
- Image widget: `I_SideBar`
- Material: `MI_UI_HUD_SideBarAbility_01` (based on `M_UI_HUD_HealthBar`)
- Parameter name: `Progress`

**Example graph flow:**
```
Event OnProgressChanged (New Progress)
    → SET Percent variable (stores the value)
    → Get Dynamic Material (target: I_SideBar image)
    → Set Scalar Parameter Value (Parameter: "Progress", Value: Percent)
```

#### 5d. Widget Positioning

Widgets added via `AddToViewport()` default to centered. To position:

1. In Designer, **right-click** the top-level child > **Wrap With...** > **Canvas Panel**
2. Select the wrapped child (now inside Canvas Panel)
3. Set **Anchor** preset (e.g. right-center)
4. Set **Position** offset from anchor
5. Set **Size** to match the SizeBox dimensions
6. Set **Alignment** (e.g. X=1.0 for right-aligned, Y=0.5 for vertical center)

**Rage widget positioning:**
- Anchor: right-center
- Position X: -20 (slight gap from edge)
- Alignment X: 1.0, Y: 0.5
- Size: 301 x 301 (constrained by SizeBox + ScaleBox)

**Note**: If the widget has a **Scale Box** in the hierarchy, it preserves aspect ratio. Making the container taller won't stretch the content - increase both width and height proportionally instead.

---

## Existing Widget Hierarchy (W_SideBarRage)

```
[W_SideBarRage] (root UserWidget, parent: SideBarAbilityWidget)
  [Canvas Panel] (added for positioning)
    [AnimBoundSB] (SizeBox, 301x301, "Is Variable")
      [Overlay]
        [Scale Box] (preserves aspect ratio)
          [Overlay]
            I_SideBar (Image - material MI_UI_HUD_SideBarAbility_01)
            Image_129 (Image - decorative overlay)
```

**Variables:**
- `I_SideBar` - Image widget with the material (used in Event Graph)
- `Image_129` - Static decorative image
- `Percent` - Float variable storing current progress
- `Team Id` - Integer (for team color, via SetTeamColor function)

**Animations:**
- `OnSpawned` - Play when widget appears
- `OnDamaged` - Flash effect

---

## Material Parameter Discovery

When you need to find what parameter name a material uses:

1. Open the Material Instance (e.g. `MI_UI_HUD_SideBarAbility_01`)
2. Look at **Scalar Parameter Values** section
3. Or open the **Master Material** (e.g. `M_UI_HUD_HealthBar`) and check parameter nodes

Common HUD material parameters:
- `Progress` or `Percent` - fill amount (0.0 to 1.0)
- `Color` - tint
- `Opacity` - transparency

---

## Troubleshooting

### Widget doesn't appear
- Check `IsOwnerLocallyControlled()` - only works on local player
- Check `WidgetClass` is set in the ability's Class Defaults
- Verify the widget Blueprint was reparented to the correct C++ class
- Check `AddToViewport()` was called

### Widget appears but doesn't update
- Verify the UI update timer is started (`SetTimer` in OnDeployed)
- Check that `OnProgressChanged` is overridden in the Blueprint Event Graph
- Verify the correct material parameter name (open the material to check)
- Make sure `Get Dynamic Material` is called (not `Get Material` - needs dynamic instance)

### Widget is in wrong position
- Check Canvas Panel wrap and anchor settings
- Remember: SizeBox/ScaleBox preserve aspect ratio
- Alignment X=1.0 means right edge aligns to anchor
- Alignment Y=0.5 means vertical center aligns to anchor

### Widget stays after ability ends
- Ensure `DestroyWidget()` is called at the top of `EndAbility()`
- Check that `EndAbility` is actually being reached (add log if needed)

### Widget appears for other players
- The `IsOwnerLocallyControlled()` guard must be in `CreateWidget()`
- On dedicated servers, this returns false (no local player)
- On listen servers, only returns true for the host's own abilities

---

## Future: Adding Effects to Other Totems

The `USideBarAbilityWidget` base class is generic enough to reuse:
- Create a new Widget Blueprint
- Reparent to `SideBarAbilityWidget`
- Override `OnProgressChanged` with different visuals
- Set it as the `SideBarWidgetClass` in that totem's ability

Example: A healing totem could show a green fill bar using the same C++ infrastructure but a different material and widget Blueprint.
