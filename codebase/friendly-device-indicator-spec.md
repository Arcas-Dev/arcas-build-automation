# Friendly Device Indicator: Build Spec (v1, 2026-10-17)

**Status: ✅ DONE 2026-10-17.** C++ `5fc82e2fa` + `3f8527ebc` (distance scaling), Marco `b4f9711ac` (widget) + `d8f7b9add` (reparent, `IconImage`, component on the 4 BPs). Compiled + PIE-tested by Marco, cooked in Steam demo build `2026-10-17_19-41` (BuildID 26014993, Edgegap verified), awaiting in-match testing (first run `18-20` failed on an `IMC_Default_Gamepad` import, unrelated to this feature). See §6 as-built log. QOL item #4 ("Add Icon to friendly totem devices"). Research trail: `qol-features-analysis-2026-09.md` §4. Code facts verified @ `b4f9711ac`; Blueprint facts read from the real `.uasset`s (LFS download, no VM).

## 1. Decisions (Dan, 2026-10-17)

| # | Decision |
|---|---|
| D1 | Icon on **Auto Turret**, **Team Healing**, and synergy-made items. **Not** on the head chimps |
| D2 | **Super Tank: out.** Dan believes it doesn't currently work. If it is fixed later, adding the component to `B_SuperTank` is the only step |
| D3 | **Ammo Crate: IN v1** (Dan, same day, once it was clear it's ~15 lines; see §3.4) |
| D4 | **Spotter Chimp: out** |
| D5 | **Only teammates and the owner see the icon; enemies never do** |
| D6 | **One icon for everything**: Marco's `W_FriendlyTotem_Icon` |
| D7 | **Nothing off screen** (no clamp, no edge arrow) |
| D8 | **Not through walls**: hidden when the device is not in line of sight |
| D9 | **Team colour**: tinted with the team's `TeamColor` |

### v1 scope
| Actor | Blueprint | Notes |
|---|---|---|
| Auto Turret | `B_AutoTurretSynergyDevice` | Covers double turret, healing turret and chimp-operated turret: those synergies upgrade this actor in place, and Healing+Turret / Chimp+Turret spawn this same BP |
| Team Healing | `B_TeamHealingSynergyDevice` | Covers Healing+Healing and the barrier (a child actor of the device) |
| Artillery Cannon | `B_ArtilleryCannon` | Synergy Turret + 2 Turrets. `AArtilleryCannon : ATeamShootingDevice`, life 120 s |
| Ammo Crate | `B_AmmoCrate` | `AAmmoSpawner : ABASWeaponSpawner`, **not** a team member, so the team comes from its placer (§3.4). Life 30 s. Anchor = `WeaponMesh` |

The first three are `ATeamDevice`s. **Out:** Super Tank, Spotter Chimp, head chimps. The head chimps (`AChimpCompanion*`, attached via `AttachToCharacterMesh`, `ChimpCompanion.cpp:66-70`) share `ATeamShootingDevice` with the turret, so the icon is **opt-in per Blueprint** rather than inherited.

---

## 2. Marco's widget as pushed (`b4f9711ac`)

`Content/UI/Hud/Score/W_FriendlyTotem_Icon`, parent **`CommonUserWidget`**. Tree: SizeBox (72×72) → Overlay → Image(s). Materials: `MI_UI_CreatePrivateMatchArrow` (the triangle), `MI_UI_ControlRing_Shadow`, `MI_UI_HUD_ControlPointMarkerBurst`. One animation (`Anim`), played forward from the event graph on construct. That animation has a **`ColorAndOpacity` track on an Image**.

Not in it: team-colour logic, `IIndicatorWidgetInterface`. Both are needed (§3.3).

---

## 3. Design

### 3.1 `UFriendlyIndicatorComponent : UActorComponent` (new, C++)
`PLUGIN/Public/Components/FriendlyIndicatorComponent.h` + `Private/Components/FriendlyIndicatorComponent.cpp` (next to `RadarObjectActorComponent`). Marco adds it to the three BPs.

**Properties (EditDefaultsOnly):**
| Property | Default | Purpose |
|---|---|---|
| `IndicatorWidgetClass` (`TSoftClassPtr<UUserWidget>`) | `W_FriendlyTotem_Icon` | The widget |
| `AnchorComponentName` (`FName`) | none → root | Component the icon follows |
| `AnchorSocketName` (`FName`) | none | Optional socket |
| `WorldOffset` (`FVector`) | `(0,0,150)` | Height above the anchor (Marco tunes per BP) |
| `TeamColorParameterName` (`FName`) | `TeamColor` | Key in `ULyraTeamDisplayAsset::ColorParameters`. Present in both `TeamDA_Blue` and `TeamDA_Red`; the same name the Chimp outline reads |
| `OcclusionCheckInterval` (`float`) | `0.1` s | Line-of-sight check rate |

**BlueprintPure `GetTeamColor()`** for the widget.

**Lifecycle** (client + listen server; return early on `NM_DedicatedServer`):
1. `BeginPlay`: find the local PC. Bind the device's `GetTeamChangedDelegateChecked()` (the device is an `ILyraTeamAgentInterface`; its team arrives through Lyra's replicated `MyTeamID` / `OnRep_MyTeamID`). Also bind the **local PlayerState's** team-changed delegate, because at match start the device can replicate before your own team does. Then `Refresh()`.
2. `Refresh()`: `CompareTeams(Device, LocalPC) == OnSameTeam` → create the descriptor once:
   - `SetDataObject(this)`, `SetSceneComponent(anchor)`, `SetComponentSocketName`, `SetIndicatorClass`;
   - `SetProjectionMode(ComponentPoint)`, HAlign centre / VAlign bottom, `SetWorldPositionOffset`;
   - `SetClampToScreen(false)` (D7), `SetAutoRemoveWhenIndicatorComponentIsNull(true)`;
   - `ULyraIndicatorManagerComponent::GetComponent(LocalPC)->AddIndicator(...)`.
   Cache the colour from `ULyraTeamSubsystem::GetTeamDisplayAsset(TeamId, ViewerTeamId)` → `GetTeamColorWithFallback(Asset, TeamColorParameterName, White)`, and broadcast `OnTeamColorChanged` if a widget is bound. Not same team → `RemoveIndicator`. No owner exclusion (D5).
3. **Occlusion (D8)**: while the descriptor exists, a looping timer every `OcclusionCheckInterval` traces from the local `PlayerCameraManager` location to the icon's world point. The trace is `LineTraceSingleByObjectType` on **WorldStatic + WorldDynamic only**, so players and bots don't hide it, and ignores the device and the local pawn. Blocked → `SetDesiredVisibility(false)`, clear → `true`. `SActorCanvas` honours it (`SActorCanvas.cpp:221`). A timer rather than Tick keeps the cost to ~10 traces/s per visible device on the local machine only.
4. `EndPlay`: `RemoveIndicator`, clear the timer, unbind both delegates. Covers death, life expiry (`FinishLife`), being consumed by a synergy, owner death and round reset.

Lyra's indicator canvas does no occlusion or distance culling itself, so step 3 is required for D8. The indicator manager already exists on every player controller (`ShooterCore` GameFeatureData adds `LyraIndicatorManagerComponent`).

### 3.2 `UFriendlyIndicatorWidget : UCommonUserWidget` (new, C++, small)
Parent class for Marco's widget: `UPROPERTY(meta=(BindWidget)) UImage* IconImage` + `SetTeamColor(FLinearColor)` (tints `IconImage`, then fires `BlueprintImplementableEvent OnTeamColorApplied` so other layers can be tinted in BP).

**As built: no `IIndicatorWidgetInterface`.** `IIndicatorWidgetInterface` and `ULyraTeamStatics` have **no `LYRAGAME_API`**, so using them from the plugin would fail to link. Instead the component reads `ULyraTeamDisplayAsset::ColorParameters` directly, and on its update timer checks `UIndicatorDescriptor::GetIndicator()`. The canvas creates the widget asynchronously and pools it, so whenever a new widget instance appears the component calls `SetTeamColor` on it.

### 3.3 Widget changes (Marco, Editor)
- Reparent `W_FriendlyTotem_Icon` → `UFriendlyIndicatorWidget`.
- Rename the triangle image to **`IconImage`** (required by `BindWidget`, or the widget won't compile).
- ⚠️ **The `Anim` colour track must not key the colour of `IconImage`.** An animation track overwrites `ColorAndOpacity` every frame it plays (and holds its last key), which would wipe the team tint. Keep colour out of that track: animate render opacity / scale / translation, or put the colour animation on a different layer.

---

### 3.4 Ammo Crate team resolution
`ULyraTeamSubsystem::FindTeamFromObject` checks the team interface, `Instigator`, TeamInfo and PlayerState, **never `Owner`**, so it returns no team for the crate. The crate does know its placer: `Owner` = placing character (`ActorWithCharacterRotationAndOffsetSpawner.cpp:137`), and `Owner` replicates. So `ResolveTeamSource()` = the actor itself if it implements `ILyraTeamAgentInterface`, else `GetOwner()->GetOwner()`. If that's still null on a client (Owner not replicated yet), retry next tick for up to ~2 s. Bind the placer's team-changed delegate. The occlusion trace also ignores the crate. ~15 lines on top of §3.1.

---

## 4. Chronology

| # | Who | Step | Done when |
|---|---|---|---|
| 1 | Us | Start the VM (`vm-status.txt`, then `instances list` to confirm), `git pull` `deploy/steam-testing` on the VM | VM RUNNING, repo at Marco's latest |
| 2 | Us | Write **F1** `UFriendlyIndicatorComponent` (§3.1 + §3.4, default widget = `W_FriendlyTotem_Icon`) and **F2** `UFriendlyIndicatorWidget` (§3.2) | Files on the VM |
| 3 | Us | Editor compile (`Build.bat LyraEditor Win64 Development`), fix until clean | 0 errors |
| 4 | Us | Commit + push to `deploy/steam-testing`, tell Marco | Pushed |
| 5 | Marco | Pull, open the Editor (it rebuilds the C++) | New classes visible |
| 6 | Marco | `W_FriendlyTotem_Icon`: reparent to `UFriendlyIndicatorWidget`, rename the triangle image to `IconImage`, take the colour track off `IconImage` in `Anim` (§3.3) | Widget compiles |
| 7 | Marco | Add `FriendlyIndicatorComponent` to `B_AutoTurretSynergyDevice`, `B_TeamHealingSynergyDevice`, `B_ArtilleryCannon`, `B_AmmoCrate`; set the anchor (crate → `WeaponMesh`) | 4 BPs saved |
| 8 | Marco | PIE (dedicated server, 2+ clients, both teams): run the test list below, tune `WorldOffset` per BP | All 9 checks pass |
| 9 | Both | Fix whatever step 8 finds, **one change at a time** ([[one-change-then-marco-tests]]) | Re-test passes |
| 10 | Marco | Push assets | Pushed |
| 11 | Us | Cooked build: `build-all.bat` (client + server + Steam + Edgegap). ⚠️ Edgegap registry is at **7/8**, so this is the last build before the guard blocks; someone clears `arcastest6` in the Edgegap portal before the one after | Steam demo `testing` updated |
| 12 | Both | Real match on Steam to confirm the cooked build | Done |
| 13 | Us | Stop the VM, verify `TERMINATED`, leave the watcher paused, update docs | Closed |

Steps 1-4 are one session for us; Marco can't start 6 before 4 (the parent class doesn't exist yet).

**Test list (step 8):**
1. Teammates **and the owner** see the icon; **enemies never do**.
2. The tint is the team colour.
3. It hides behind walls and reappears in line of sight; players and bots don't hide it.
4. Nothing off screen.
5. Turret upgrades (double / healing / chimp-operated) keep the icon; the Artillery Cannon gets one; devices consumed by a synergy lose theirs.
6. Ammo Crate shows for teammates and owner, including a client that joined after it was placed.
7. No icon on head chimps, Super Tank or Spotter Chimp.
8. It disappears on death, expiry, owner death and round reset.
9. Late joiner sees devices placed earlier.

---

## 6. As-built log
- `5fc82e2fa` (2026-10-17): component + widget parent. Compiled by Marco; he reparented `W_FriendlyTotem_Icon` and added the component to the 4 BPs in `d8f7b9add`.
- `3f8527ebc` (2026-10-17): **distance scaling.** The Lyra canvas draws indicators at a fixed screen size (`SActorCanvas.cpp:476`, child scale hardcoded 1.0), so the icon looked like it grew next to the device as you moved away (measured: constant ~0.26× the player character's width near and far, while the crate shrank ~180 → ~40 px). The widget now `SetRenderScale(Clamp(ReferenceDistance / dist, MinScale, MaxScale))` every frame, pivot `(0.5, 1)` (the triangle tip). Defaults 1000 cm / 0.35 / 1.5, tunable in the widget's Class Defaults. The component hands the widget its tracked component in `ApplyTeamColorToWidget`.

- Marco's setup `d8f7b9add`: `W_FriendlyTotem_Icon` reparented to `UFriendlyIndicatorWidget` (`IconImage` bound, the old `PlayAnimationForward` removed, so no colour-track conflict); component on `B_AutoTurretSynergyDevice`, `B_TeamHealingSynergyDevice`, `B_ArtilleryCannon`, `B_AmmoCrate`.
- **Lessons:** (1) `ULyraTeamStatics` and `IIndicatorWidgetInterface` have no `LYRAGAME_API`, so they can't be used from the plugin; the component reads `ColorParameters` and pushes into the widget. (2) A `UIndicatorDescriptor` can be added to a manager **once** (`SetIndicatorManagerComponent` ensures null), so make a new one per show. (3) `bAutoRemoveWhenIndicatorComponentIsNull` only drops the canvas entry, not the manager entry, so remove in `EndPlay`. (4) Lyra's canvas draws indicators at a **fixed screen size** (child scale 1.0), so the widget scales itself. (5) "It gets bigger" was relative to the shrinking device; measured constant ~0.26× character width.

---

## 7. Works in PIE, missing in builds — FIX PUSHED `4e2ec886e` (2026-11-01), lands with the next `build-all`

**Root cause (very likely): `W_FriendlyTotem_Icon` is never cooked.**
- The widget is referenced in exactly one place: the **C++ constructor default** of `UFriendlyIndicatorComponent::IndicatorWidgetClass` (`FriendlyIndicatorComponent.cpp:23`, a `TSoftClassPtr`).
- Blueprints serialize only values that differ from the native default. The 4 device BPs (read via LFS @ `68df11fb3`) contain the component (`FriendlyIndicator_GEN_VARIABLE`) but **no `W_FriendlyTotem_Icon` path**, because Marco never changed the field.
- The cooker follows references found in saved packages; a native CDO is not a package, so nothing leads it to the widget. `/Game/UI/Hud/Score` is not in `DirectoriesToAlwaysCook` and no primary-asset rule covers it.
- In PIE the soft class loads straight from disk, so it works. In a build the indicator canvas's async load fails and nothing is drawn: no icon, no crash.
- Precedent: `+DirectoriesToAlwaysCook=(Path="/BASShooterCore/Game/Tutorial/DataAssets")` in `DefaultGame.ini` was the same class of fix.
- ⚠️ "Re-select the same widget in the BP" does **not** fix it: a value equal to the native default is still not serialized.

**Fix (1 line, no C++):** `Config/DefaultGame.ini`, `[/Script/UnrealEd.ProjectPackagingSettings]`, next to the existing entries: `+DirectoriesToAlwaysCook=(Path="/Game/UI/Hud/Score")` (11 small HUD widgets, the rest are already cooked via the HUD). Needs a `build-all`. Alternative (more work): empty the C++ default and set the widget in each BP so it serializes.

**Confirm before/after:** the build log/cook output should contain `W_FriendlyTotem_Icon`; a client log without the fix should show a failed load of `/Game/UI/Hud/Score/W_FriendlyTotem_Icon`. Marco's Reference Viewer on the widget should show no referencers.

**Second suspect if the icon is still missing after a cooked fix:** dedicated-server team replication (PIE listen server hides it). Test PIE with Net Mode = Play As Client, 2 players, same team.
