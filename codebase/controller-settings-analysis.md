# Controller settings: analysis and plan (2026-11-08)

**Status: ANALYSIS ONLY, nothing built. Phase 0 Editor steps sent to Marco 2026-11-10 (D1 + D2 = reorder accepted by Dan); awaiting his PIE result.** Source: Marco's Kanban "Features" card:

1. Add controller deadzone settings
2. Make controller sensitivity settings work
3. Investigate and set up a system where we can tweak the controller analog curve
4. Investigate and set up aim assist settings

Method: 4 parallel read-only investigations (sensitivity chain, deadzone + curve, aim assist, settings/input map). Real `.uasset` files were read off GitHub LFS and decoded with the tagged-property parser. UE 5.5 engine source was read from EpicGames/UnrealEngine@5.5. The load-bearing claims were re-checked by hand afterwards (marked ✔). Repo state: `deploy/steam-testing` @ `b2fa4f7de`.

**V** = verified (code or asset bytes). **I** = inferred.

---

## 0. TL;DR

- **All four items sit on one chain:** the gamepad right stick → `IA_Look_Stick` mapping. It lives in **`IMC_Default_KBM`**, not in a gamepad IMC. Every gameplay experience adds that IMC via `LAS_ShooterGame_SharedInput`.
  - `IMC_Default_Gamepad` is **dead data**: nothing adds it, and it has no look mapping.
  - `IMC_ShooterGame_Gamepad` is empty.
  - **Edit `IMC_Default_KBM` rows [13] (move) and [19] (look), nothing else.**
- **Item 2, sensitivity, has two causes. Both clamp the stick value to 1 after the sensitivity multiplier has been applied.**
  1. The aim assist step clamps its output to ±1 (`AimAssistInputModifier.cpp:508/514` ✔).
  2. The action-level engine dead zone on `IA_Look_Stick` clamps magnitude to 1.
  - Result: every preset from **Normal up to Insane has the same top turn speed** (300°/s yaw, 165°/s pitch, hard-coded at `LyraHeroComponent.cpp:35-36` ✔). Only the presets below Normal do anything.
- **Item 1, deadzones: the sliders already exist** ("Left/Right Stick DeadZone", `LyraGameSettingRegistry_Gamepad.cpp:201-241` ✔, default 25%).
  - A **hidden second dead zone** (engine default 0.2) sits on `IA_Move` and `IA_Look_Stick` and stacks on top of the slider.
  - **Effective dead zone at default ≈ 40%. Players can never get below ≈ 24%.**
  - There is no outer dead zone setting.
- **Item 3, analog curve: nothing is in effect.**
  - The look mapping ends in a `ResponseCurveExponential` with default exponent 1, which does nothing.
  - The only real curve, from April 2025, pointed at assets that never existed. That is what broke the right stick, and `3e6ca59e3` "fixed" it by swapping in the do-nothing modifier.
  - So a tunable curve is new work.
- **Item 4, aim assist is wired and probably live for gamepad players**, at stock Lyra strength and never tuned. Bevium added it 31 Mar to 2 Apr 2025 (`211f9b0ea`, `7dbfcfaad`, `167bcd3c1`, `4381afa71`).
  - **The on/off setting does nothing in the Steam build.** It sets a `ECVF_Cheat` cvar whose only check is inside `#if !UE_BUILD_SHIPPING` ✔, and the client is built Shipping (`build-all.ps1:38` ✔).
  - **Friendly turrets and healing totems pull your aim.**
  - It **would reveal Disguised enemies**.
  - The ADS variant is never used.
- **Bonus finding: the ADS settings are dead.** "Aim Sensitivity (ADS)" (gamepad) and the mouse "Targeting Multiplier" do nothing.
  - Only `IMC_ADS_Speed` uses them, and nothing adds it.
  - Our C++ `UAimDownSightsGameplayAbility`, which replaced Lyra's `GA_ADS` in Dec 2024, never pushes it ✔.
- **The fastest win is Editor-only and needs no compile** (Phase 0 below). It fixes sensitivity and the 40% dead zone.

---

## 1. Settings framework (where options live)

### Screens

| Opened from | Widget | C++ parent | Notes |
|---|---|---|---|
| Main menu "Options" | `/Game/UI/Settings/W_LyraSettingScreen` | `ULyraSettingScreenOnBarracks` | Doesn't call Super. Only Apply / Cancel, **no Back** |
| In-match Esc menu | `W_LyraSettingScreenInGame` | `ULyraSettingScreen` | Back = Apply + close (`LyraSettingScreen.cpp:43`) |

Both screens are stock GameSettingPanel screens. Their tabs are Video, Audio, Gameplay, MouseAndKeyboard and GamepadCollection.

### Registry

`LyraGameSettingRegistry.cpp:54-73` builds the tabs. The Gamepad tab (`LyraGameSettingRegistry_Gamepad.cpp`) contains:
- Hardware type and vibration
- Invert vertical / horizontal (these share their fields with the KBM settings)
- **Sensitivity** (`:140`): Look and ADS presets, 10-step enums
- **Controller DeadZone** (`:201`): move and look, 5-95%, default 0.25 from the cvars `gpad.DefaultLeft/RightStickInnerDeadZone`
- **Aim Assist** (`:244-265`): a bool added by Bevium

The gamepad key-binding block is commented out (`91649306a`).

### Persistence

- `ULyraSettingsShared` is a `ULocalPlayerSaveGame`, slot `SharedGameSettings` (`.sav`).
- `ULyraSettingsLocal` is stored in `GameUserSettings.ini`.
- Saving goes through `SaveChanges` (`LyraGameSettingRegistry.cpp:75-87`).

### Live apply

- Input modifiers read `GetSharedSettings()` every frame, so dead zone, sensitivity and invert apply as soon as the value changes.
- Aim assist only applies on Apply or Back. `SetAimAssist` does not call `ApplyAimAssist`.
- The main menu has no gameplay IMC active, so feel testing has to happen in a match or in `BAS_ShooterGym`.

### Recipe: adding a gamepad setting (no widget work for scalar, bool or enum)

1. In `LyraSettingsShared.h`, add a private `UPROPERTY()` field with a default, plus a `UFUNCTION()` getter and setter.
   - The setter uses `ChangeValueAndDirty` (template at `:404`); copy the GamepadDeadzone block at `:134-156`.
   - They must be UFUNCTIONs, because `GET_SHARED_SETTINGS_FUNCTION_PATH` resolves them by name.
2. In `LyraGameSettingRegistry_Gamepad.cpp`, create a `UGameSettingValueScalarDynamic`, `DiscreteDynamic_Bool` or `DiscreteDynamic_Enum`:
   - set the dev name, display name, description, dynamic getter/setter, default and range;
   - add it to a collection (copy the DeadZone block at `:201-241`);
   - it appears on both screens automatically.
3. Consume it in an input modifier's `ModifyRaw` via `LocalPlayer->GetSharedSettings()` (pattern at `LyraInputModifiers.cpp:91-128`).
4. If the modifier is new, insert it on the `IMC_Default_KBM` row. That step is Editor work.
5. **To change the default for existing players**, bump `GetLatestDataVersion` (currently 1) and migrate. Otherwise old saves keep their value.

---

## 2. Input stack (what is live in a match)

`ULyraHeroComponent::InitializePlayerInput` calls `ClearAllMappings`, then adds the hero's `DefaultInputMappings`. **That array is empty on every hero BP.** All match IMCs therefore come from `LAS_ShooterGame_SharedInput`, used by TDM, Elimination, ControlPoints (+Prologue), BombScenario, LobbyRoom, PracticeGrounds and both Tutorials.

| IMC | Added by | Prio | Live in match | Contents |
|---|---|---|---|---|
| `/Game/Input/Mappings/IMC_Default_KBM` | LAS SharedInput | 0 | **YES** | KBM **and all gamepad stick, face and trigger rows**: Move [13], Look_Stick [19], Fire (RT), Sprint (L3), Jump/Glide (A), Crouch (B), Reload (X) |
| `ShooterCore/.../IMC_ShooterGame_KBM` | LAS | 0 | YES | Also gamepad ADS (LT), totems (LB/RB + chords), emote, quickslot, scoreboard, melee (R3) |
| `IMC_ShooterGame_Gamepad` | LAS | 0 | added but **empty** | (labelled "Do not use this anymore") |
| `IMC_ShooterGameShowLeaderBoard` | LAS (I) | 0 | YES (I) | also swapped at prio 10 by `BaseMatchBoardWidget.cpp:58-77` |
| `/Game/Input/Mappings/IMC_Default_Gamepad` | **nothing** | n/a | **NO (dead)** | no look mapping; borrows KBM's key-settings subobjects (`67dcc7eab`) |
| `ShooterCore/.../IMC_ADS_Speed` | **nothing** | n/a | **NO** | the ADS look chain (see §4) |

The front end (`B_LyraFrontEnd_Experience`) has no pawn data and no action set, so CommonUI handles all input there.

### ⚠️ Cook fragility

Other IMCs import `IMC_Default_KBM`'s PlayerMappableKeySettings subobjects. Deleting rows there broke the server cook on 2026-10-17 (fixed in `67dcc7eab`). **Keep edits small and re-cook.** The LAS also loads it in the server bundle, so any new modifier class must live in a module the server builds (LyraGame or ShooterCoreRuntime).

### Device detection

CommonInput (`B_CommonInputData`, Windows default is MouseAndKeyboard, controller data for KBM, XSX and PS5) drives UI icons, the software cursor and force feedback. **No gameplay modifier checks the device.** Gamepad-only behaviour comes purely from sitting on `Gamepad_*` key rows.

The legacy `AxisConfig DeadZone=0.25` in `DefaultInput.ini:13-16` does **not** affect Enhanced Input, which reads `RawValue` (`EnhancedPlayerInput.cpp:391`).

---

## 3. The live stick chains (V, decoded from `IMC_Default_KBM` + action assets)

Mapping modifiers run first, in array order (`EnhancedPlayerInput.cpp:192`). Then **action-level** modifiers run (`:497-498`). Then the hero component applies the value.

### Look stick: `IMC_Default_KBM`[19], `Gamepad_Right2D` → `IA_Look_Stick`

| # | Modifier | Effect |
|---|---|---|
| 1 | `InputModifierNegate_4` | flips Y only |
| 2 | `LyraInputModifierDeadZone_1` | Radial, Lower = **player look dead zone** (default 0.25), Upper 1.0, rescaled to 0..1 |
| 3 | `LyraInputModifierGamepadSensitivity_0` | × preset from `GamepadAimSensitivity_Normal`: 0.5 / 0.75 / 0.9 / **1.0** / 1.1 / 1.25 / 1.5 / 1.75 / 2.0 / 2.5 |
| 4 | `LyraInputModifierAimInversion_0` | invert settings |
| 5 | `AimAssistInputModifier_2` | recomputes the value from assisted rotational velocity ÷ look rates, then **clamps to ±1** (`:508/:514` ✔) |
| 6 | `InputModifierResponseCurveExponential_0` | no saved properties, so exponent 1: **does nothing** |
| A | *(action level)* engine `InputModifierDeadZone` on `IA_Look_Stick` | no saved properties, so engine defaults: **Lower 0.2**, Upper 1.0, Radial; **clamps magnitude to 1** |
| → | `LyraHeroComponent::Input_LookStick` | value × **300°/s yaw**, **165°/s pitch** × dt (`:430-453`, constants `:35-36` ✔) |

Consequences (I, arithmetic on verified values):
- **Effective inner dead zone = 0.25 + 0.2 × 0.75 = 40%.**
- **Presets above Normal can't raise the top speed.** Steps 5 and A clamp to 1, so the high presets only reach the cap at less stick tilt.
- Presets below Normal shrink both the top speed and the usable range. On Slow the effective dead zone is about 55% and full stick gives 37.5% of the turn rate.
- Small aim-assist corrections (< 0.2) are swallowed by the action dead zone.

### Move stick: `IMC_Default_KBM`[13], `Gamepad_Left2D` → `IA_Move`

| # | Modifier | Effect |
|---|---|---|
| 1 | `LyraInputModifierDeadZone_3` | Radial, Lower = **player move dead zone** (0.25), Upper 1.0 |
| 2 | `LyraInputModifierGamepadSensitivity_2` | no table set, so it returns early and **does nothing** (`LyraInputModifiers.cpp:158`) |
| A | *(action level)* engine DeadZone on `IA_Move` | 0.2 / 1.0 Radial; also normalises the WASD diagonal |
| → | `LyraHeroComponent::Input_Move` → `AddMovementInput` | the CMC on `B_BASHero_ShooterMannequin` has `MinAnalogWalkSpeed` 200, so past the dead zone speed jumps from 0 to at least 200 cm/s |

`MinAnalogWalkSpeed` on `B_Hero_ShooterApeChampion_Base` is an unknown that needs an Editor check.

### Mouse

`IA_Look_Mouse` has no action modifiers. Its mapping is `LyraSettingBasedScalar` (MouseSensitivityX/Y) plus inversion. **Mouse is unaffected by all of this.**

---

## 4. ADS: two settings that do nothing

`IMC_ADS_Speed` (ShooterCore) is Lyra's ADS overlay:
- Gamepad chain: Negate, DeadZone, **GamepadSensitivity (TargetingType ADS, table `GamepadAimSensitivity_Targeting`: 0.25 … 0.5 normal … 1.1)**, Invert, **AimAssist (ADS)**.
- Mouse: `LyraSettingBasedScalar` on `MouseTargetingMultiplier` (default 0.5).

Lyra's `GA_ADS` pushed this IMC on activate. **BAS deleted `GA_ADS` (`59851727b`, 2024-12-04)** and replaced it with C++ `UAimDownSightsGameplayAbility` + `GA_AimDownSights`. That ability only does camera modes, a speed GE and the sniper scope, and **never adds the IMC** ✔.

So these are dead:
- the gamepad "Aim Sensitivity (ADS)" preset;
- the mouse "Targeting Multiplier";
- all ADS aim-assist strengths.

**Reviving the IMC changes mouse ADS too:** mouse ADS would drop to 0.5× unless the mouse row is neutralised or exposed properly.

---

## 5. Aim assist (Lyra, stock code in ShooterCore)

### How it works

Three parts:
- **`UAimAssistInputModifier`** on the look-stick mapping. It is client-only, so the dedicated server is unaffected.
- **`UAimAssistTargetManagerComponent`** on the GameState. The ShooterCore GameFeatureData adds `B_AimAssistTargetManager` on the client only.
- **`UAimAssistTargetComponent`**, a capsule on each target.

Targeting:
1. `OverlapMultiByChannel` on `Lyra_TraceChannel_AimAssist` (GameTraceChannel5). The shape is a box centred on the **pawn**, rotated to the control rotation, about 80×80 cm wide and `ReticleDepth` = 10000 (100 m) long.
2. Team filter (`AimAssistTargetManagerComponent.cpp:264`) uses `ALyraPlayerState::GetTeamId`. Dead targets are filtered too.
3. A screen-reticle pass, keeping at most 6 targets, then an async line-of-sight trace.

Effects:
- **Pull:** rotational tracking that applies only while the stick is moving.
- **Slow:** friction on the look rate.
- **No bullet magnetism.**

Strength:
- Defaults: hip 0.6/0.5 (inner/outer) for both pull and slow; ADS 0.7/0.4.
- `PullMaxRotationRate` 0, which means **uncapped**.
- Strength is **multiplied by the look-sensitivity preset** (`:588`, a Lyra quirk: higher sensitivity means a stronger assist).

### Wired? (V unless marked)

- Modifier on the live look row: **yes** (`IMC_Default_KBM`[19] step 5). Only `TargetWeightCurve` and `ReticleDepth` are overridden; everything else is the struct defaults.
- Target manager present: **yes** (ShooterCore GFD, client bundle).
- Ape targets: `B_Hero_ShooterApeChampion_Base` has `AimAssistTarget_Body` and `_Head` (`211f9b0ea`). Their collision profile is **Custom = overlap every channel**. The proper profile, `AimAssist_OverlapDynamic` (`DefaultEngine.ini:292`), is only used on the old Mannequin.
- Devices: Auto Turret, Team Healing, Artillery Cannon, Spotter Chimp and `B_Dummy_Target` have targets (`167bcd3c1`, `7dbfcfaad`). `B_AimAssistTargetTest` is a plain test sphere.
- **Toggle**: Bevium's `bIsAimAssistEnabled`, default true → `ApplyAimAssist` → `ECVF_Cheat` cvar ✔ → checked only under `#if !UE_BUILD_SHIPPING` ✔. **It works in PIE but is a no-op in Steam builds**, where aim assist is always on for gamepad. The UI misleads anyone who turned it off.

### Defects

| # | Defect | V/I |
|---|---|---|
| AA1 | Toggle compiled out in Shipping | V |
| AA2 | ADS settings never used (no `IMC_ADS_Speed`) | V |
| AA3 | **Friendly team devices pull your aim.** The team filter needs a character with a LyraPlayerState, and `ATeamDevice` keeps its team in its own `TeamId` (`TeamDevice.h:40,107`) | I (high) |
| AA4 | **Disguised enemies get assisted**, which gives the disguise away. `FAimAssistFilter::ExclusionGameplayTags` exists but is C++-only | I |
| AA5 | Head and body report the **same** shape (`GatherTargetOptions` falls back to `FindComponentByClass<UShapeComponent>()`, and `TargetShapeComponent` is not a UPROPERTY), giving duplicate targets and ignoring the authored capsule sizes | I |
| AA6 | Overlap tube centred on the pawn while the reticle and line of sight use the camera. With the shoulder camera, a target under the crosshair can fall outside the 80 cm tube, so there is no assist | I |
| AA7 | Overlap-everything collision on the ape aim-assist capsules may trigger pickups, volumes and melee overlaps | I |
| AA8 | The ±1 clamp caps gamepad sensitivity (§3) | V |
| AA9 | No per-weapon scaling; `PullMaxRotationRate` is uncapped | V |

**Never seen working in game.** First step: in PIE, run `lyra.Weapon.DrawAimAssistDebug 1` and `lyra.Weapon.AimAssist.DrawDebugViewfinder 1`. These only work in non-Shipping builds.

---

## 6. Plan (phased; one change at a time, Marco PIE-tests each)

### Phase 0: Editor only, no compile (~30 min, Marco). Fixes most of items 1 + 2.

1. Remove the action-level `InputModifierDeadZone` from `IA_Look_Stick` and `IA_Move`. The effective dead zone drops from 40% to the slider value.
2. In `IMC_Default_KBM`[19], move **Lyra Gamepad Sensitivity after Aim Assist** (last in the chain).
   - Presets above Normal then raise the top speed for real, and aim assist sees the raw stick.
   - The C++ alternative is to widen the clamp at `:508/:514`. Pick one, not both.
3. Remove the no-op `ResponseCurveExponential_0` from [19].
4. Check the Gamepad tab is visible in Options and that the sliders move. Delete `Saved/SaveGames/SharedGameSettings.sav` to test defaults.
5. Test in `BAS_ShooterGym` with a pad:
   - Slow vs Insane at full stick;
   - dead zone 5% vs 50%;
   - WASD diagonal speed unchanged (step 1 removes the diagonal normalisation; the CMC clamps it anyway, I).

**Requires decision D1.** This is a feel change for every pad player: faster high presets and a smaller dead zone. Possible stick drift on worn pads.

### Phase 1: deadzone settings, item 1 (C++, ~½ day)

- Add `GamepadMove/LookStickOuterDeadZone` to `ULyraSettingsShared`, with cvars for the defaults.
- Make `ULyraInputModifierDeadZone` read Upper from the settings.
- Registry changes:
  - rename the existing sliders to "Inner Dead Zone", range 0-50%;
  - add "Outer Dead Zone", range 70-100%.
- Suggested defaults to tune on a pad: move inner 0.15 / outer 0.95; look inner 0.10-0.12 / outer 0.95.
- **Bump the settings version and migrate**, otherwise every existing save keeps 0.25 (D5).
- Note: aim assist reads the dead zone settings too (`:610-663`), so tuning them also shifts when assist counts as "active".

### Phase 2: aim assist settings, item 4 part 1 (C++, ~½ day)

- **Shipping-safe toggle:** `ModifyRaw` reads `GetSharedSettings()->IsAimAssistEnabled()` directly instead of the cheat cvar. Also apply on change.
- **Strength slider** (0-100%, default 100%) → `StrengthScale`. The player can only reduce it.
- Decouple strength from the look-sensitivity preset.
- Optional mode: Standard (slow + pull) / Precision (slow only) / Off.
- **Do not add ADS snap.**

### Phase 3: ADS revival (C++, ~¼ day + Editor)

- `UAimDownSightsGameplayAbility`: on activate, push `IMC_ADS_Speed` above `IMC_Default_KBM`, locally controlled only, and remove it on end.
- Apply the Phase 0 order fix inside `IMC_ADS_Speed`.
- Decide what happens to the mouse `TargetingMultiplier` row (0.5×). Either neutralise it or keep it as an exposed setting (D6).

### Phase 4: analog curve system, item 3 (C++ ~1 day + Editor ~1 h)

- New `ULyraInputModifierStickResponseCurve` in LyraGame, next to the other Lyra modifiers:
  - properties `Stick` and `CurveData`;
  - applied radially: `out = dir × Curve(|v|)`;
  - optional clamp to 1.
- New `UBASStickResponseCurveData : UPrimaryDataAsset` holding the presets. Each preset has a display name, an `FRuntimeFloatCurve` over 0..1 and a clamp flag.
  - The modifier evaluates the asset every tick, so **designers edit the curve live in PIE**.
  - Hard references from the IMC mean it always cooks, which avoids the soft-pointer trap.
- New setting `GamepadLookResponseCurve` (enum). Presets:
  - **Linear**
  - **Classic** (about x^1.6-2.0, the default)
  - **Dynamic** (S-curve)
  - **Precision**
- Move stick: a designer-only curve, linear by default.
- Editor work:
  - create `DA_GamepadResponseCurves`;
  - insert the modifier into `IMC_Default_KBM` [13] and [19] and into `IMC_ADS_Speed`, **after the dead zone and before sensitivity**.
- Target order on each stick: **Negate → Dead zone (inner+outer) → Response curve → Sensitivity → Invert → Aim assist.** Nothing at action level.
- Optional later:
  - move `LookYawRate`/`LookPitchRate` (300/165) into the same data asset, so turn speed can be tuned without a compile;
  - turn ramp-up at full stick;
  - a dead zone/curve visualiser, modelled on `W_SafeZoneEditor`.

### Phase 5: aim assist quality, item 4 part 2 (C++ ~1-1.5 days + Editor + playtests)

- AA3 team filter: `ULyraTeamSubsystem::CompareTeams(OwnerPawn, Target)`. Check whether `ATeamDevice` resolves through `ILyraTeamAgentInterface` on clients. Fallback: a small hook in BASShooterCore. ShooterCoreRuntime can't depend on BAS, so use an interface or tag.
- AA4 exclusion by ASC tag (`Status.Disguised`, dead, etc.).
- AA5 shape fix: use the component itself as the shape (~10 lines), or keep one capsule.
- AA6 camera-centred overlap, or size it from the targeting reticle. Re-tune the reticle against our FOV.
- AA7 (Editor): set the ape and device capsules to `AimAssist_OverlapDynamic`.
- AA9: `PullMaxRotationRate` around 30-45°/s; optional per-weapon multiplier (hook at `:638`).
- Starting tune for third-person PvP, to playtest (not measured):

  | Setting | Hip | ADS |
  |---|---|---|
  | Slow, inner / outer | 0.4 / 0.25 | 0.5 / 0.3 |
  | Pull, inner / outer | 0.3 / 0.15 | 0.4 / 0.2 |

**Suggested order:** Phase 0 → 1 → 2 → 3 → 4 → 5. Phases 0-3 are small and independent, and each gives a visible fix. Phase 4 is the real new system. Phase 5 needs playtests with a pad and bots.

---

## 7. Decisions for Dan / Marco

| # | Decision | Recommendation |
|---|---|---|
| D1 | Accept the feel change of Phase 0 (no hidden 0.2 dead zone, high presets genuinely faster)? | Yes. It is what the settings promise |
| D2 | Fix sensitivity by reordering the IMC (Editor) or widening the clamp (C++)? | Reorder (no compile) |
| D3 | Aim assist default On? PC pad vs mouse fairness (no input-based matchmaking) | On for pad, strength slider, revisit after playtests |
| D4 | Which curve presets to expose to players; move curve player-facing or not | 4 look presets; move curve designer-only |
| D5 | Migrate old saves to new dead zone defaults (version bump)? | Yes, once, with Phase 1 |
| D6 | Revive mouse ADS "Targeting Multiplier" (0.5×) along with gamepad ADS? | Neutralise the mouse row unless Marco wants mouse ADS slowdown |

## 8. Open unknowns (need Editor, PIE or VM)

- **Steam Input** for app 3487030: if it is on, Steam applies its own dead zones and curves first. Check the Steamworks controller config.
- In game, that the Gamepad tab and sliders are visible on PC (the registry and tab binding exist).
- Aim assist actually engaging with our shoulder camera (debug cvars above).
- `MinAnalogWalkSpeed` on `B_Hero_ShooterApeChampion_Base`.
- The `C_AimAssistTargetWeightCurve` keys.
- The `C_ControllerResponseCurve` keys (decoded as plateauing at 0.5; unused anyway).
- `CM_ThirdPerson` offset curves.
- Whether `ATeamDevice` exposes its team through `ILyraTeamAgentInterface` on clients.
- `get_referencers` on `IMC_Default_Gamepad` / `PMI_Default_Gamepad` (headless commandlet on the VM) to confirm they are dead.

## 9. Testing notes

- PIE is Development, so **the aim-assist toggle works in PIE and not in Steam builds**. Test toggle fixes in a Shipping package or Steam build.
- Settings persist across PIE sessions. Delete `Saved/SaveGames/SharedGameSettings.sav` for a clean slate.
- `showdebug enhancedinput` shows the value at each modifier stage live.
- Everything here is client-side, so a normal `build-all` is enough. No server behaviour changes, but new modifier classes must compile into the server build (LyraGame/ShooterCoreRuntime).

## 10. Key files

- `NewApeShooter/Content/Input/Mappings/IMC_Default_KBM.uasset` (rows [13], [19]), `Content/Input/Actions/IA_Look_Stick`, `IA_Move`
- `NewApeShooter/Plugins/GameFeatures/ShooterCore/Content/Input/Mappings/IMC_ADS_Speed.uasset`
- `NewApeShooter/Source/LyraGame/Input/LyraInputModifiers.{h,cpp}`, `LyraAimSensitivityData.*`
- `NewApeShooter/Source/LyraGame/Settings/LyraSettingsShared.{h,cpp}`, `LyraGameSettingRegistry_Gamepad.cpp`
- `NewApeShooter/Source/LyraGame/Character/LyraHeroComponent.cpp` (look rates `:35-36`, `:430-453`)
- `NewApeShooter/Plugins/GameFeatures/ShooterCore/Source/ShooterCoreRuntime/Private/Input/AimAssist*.cpp`
- `NewApeShooter/Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/Private/AbilitySystem/Abilities/AimDownSightsGameplayAbility.cpp`
- `arcas-build-automation/scripts/build-all.ps1:38` (`$ClientConfig = "Shipping"`)

Scratch evidence (asset dumps, parsers) from the investigation:
- `/private/tmp/claude-501/-Users-danielfong-workspaces-personal-projects-arcas-master/1b649cec-edb2-476c-b468-d7727ad5ea7b/scratchpad/ctrl/`
- `/private/tmp/claude-501/-Users-danielfong-workspaces-personal-projects-arcas-master/1b649cec-edb2-476c-b468-d7727ad5ea7b/scratchpad/sensdump/`

These are temporary.
