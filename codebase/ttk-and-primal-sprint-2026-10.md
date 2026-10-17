# TTK (doubled health) + Primal Sprint — as built (2026-10-17)

The first two items of Marco's newer QOL card ("Drasticly Increase TTK by doubling health", "Remove standard sprint and leave only the primal sprint"). Both **done 2026-10-17**: health by Marco in the Editor (`b81d28db5`), sprint in C++ (`309a52cee`, `9e5bbd274`), compiled and PIE-tested by Marco on his machine. **cooked in Steam demo build `2026-10-17_19-41` (BuildID 26014993, Edgegap verified), awaiting in-match testing.**

Paths: `PLUGIN/` = `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/`. Asset facts below were read off Editor screenshots during the session.

---

## 1. Doubled health

### How a player's max health is set (the whole chain)
1. `ULyraHealthSet` C++ default 100/100 (`Source/LyraGame/AbilitySystem/Attributes/LyraHealthSet.cpp:22-24`). Lives on the **PlayerState** ASC, so it survives respawns.
2. `LyraCharacter.cpp:588` → `AddBASBaseStatsAbilities` grants the champion stat abilities with **ability level = stat value** (3–12, `LoadoutDAO.h:4-5`).
3. `GA_Setup_Stamina` (`AbilityName = Health` — the champion "Health" stat was the old "Stamina" stat, renamed 2023/2024, assets kept the old name) applies **`GE_Grant_Stamina`**:
   - Duration **Instant**, one modifier on `LyraHealthSet.MaxHealth`, op **Override**, Scalable Float coefficient **1.0** × `CT_PlayerStats` / **`Curve_MaxHealth`**, stacking None.
   - Instant + Override = sets the base value, so it **cannot stack across respawns** and the C++ 100 default never matters.
4. Any MaxHealth change refills Health (`LyraHealthComponent.cpp:166-175`).

`CharacterStatsSettings::GetMaxHealth` (DefaultGame.ini `UCharacterStatsSettings`) is never called by C++ — the curve reaches gameplay only through the GE. `GE_HealthMultiplier` is the **AutoTurret's**, not a player effect.

### The change
`CT_PlayerStats` (`Plugins/BlockApeScissors/Content/CurveTables/`) row `Curve_MaxHealth`:

| | L1 | L3 | L12 | L20 | step |
|---|---|---|---|---|---|
| Before | 100 | 110 | 155 | 195 | +5 |
| **After** | **200** | **220** | **310** | **390** | **+10** |

In-match champions are stat 3–12 → **220–310 HP** (was 110–155). The spread between the weakest and strongest Health stat doubled too (45 → 90).

### Who it affects
- Players **and bots** (bots get a `PlayerInfoComponent` + the same stat abilities).
- **Not** team devices (turret, chimp, team healing, dummies) — they use their own `DT_*Health` tables via `ATeamDevice::InitStats`.

### Side effects (accepted / open)
Everything absolute did **not** scale, so relative to the new pool:
- Heals restore half as much of the bar (Personal/Team Healing, health grenade, Chimp heal, healing ammo, heal pads). **Open: double the heal values or not.**
- Burn, grenades, fall damage (`CT_FallDamage`), water/pad damage take half the share.
- One-shot breakpoints (sniper headshot, melee throw) are gone.
- Still correct: kill volumes / self-destruct deal `GetMaxHealth()` (`LyraHealthComponent.cpp:359`).
- To check: `W_Healthbar` / nameplate low-health threshold and `BTS_CheckOwnHealth` (bot "hide when low") — if they use absolute numbers they trigger at half the intended point.

Rejected: changing the C++ default (overwritten by the GE), halving damage (kill volumes would leave players at 50%, and turrets/devices would take half damage too).

---

## 2. Primal sprint only

### The key fact
Primal sprint was never its own ability. It is **`GA_Sprint` while the character is crouched** — "primal stance" *is* crouch (native toggle, `LyraCharacter::ToggleCrouch`, Ctrl / `IA_Crouch`). `USprintGameplayAbility` (`PLUGIN/.../Abilities/SprintGameplayAbility.cpp`) branched on `bIsCrouched`: standing → `Uncrouched()` (×0.5 additive boost, no stamina), crouched → `Crouched()` (×2.6, stamina drain, fire/melee blocked). Removing the mapping or the ability would have removed primal sprint too.

### `GA_Sprint` class defaults (as of 2026-10-17)
| Field | Value |
|---|---|
| Camera Mode | `CM_ThirdPersonSprint` |
| Speed Multiplier Uncrouched / Crouched | 0.5 / **2.6** (C++ defaults 0.5 / 3) |
| Block Abilities with Tag when Crouched | `Ability.Type.Action.Melee`, `Ability.Type.Action.WeaponFire` |
| Block Abilities with Tag | `Ability.Type.Action.ADS` (added this session) |
| AssetTags | `Ability.Type.Action.Sprint` |
| Activation Owned Tags | `Event.Movement.Sprint` |
| Activation Blocked Tags | `Event.Movement.ADS`, `Event.Movement.Melee` |
| Stamina Duration / Recovery Delay / Recovery Time | 6 / 1 / 10 (unused while `bUseStamina` is off) |
| Policies | On Input Triggered · Local Predicted · Instanced Per Actor · Replicate |
| Trigger | Gameplay Event `InputTag.Sprint` (no C++ sends it; possibly a mobile button) |

### Behaviour (as built)
| Situation | Result |
|---|---|
| Hold sprint, standing or crouched | Crouch (if needed) → primal sprint ×2.6, fire / melee / ADS blocked, **no stamina drain** |
| Ctrl / crouch input mid-sprint | **Ignored** |
| Jump | Stands up (the jump abilities `UnCrouch()` first, so the big primal jump still happens) → sprint **paused**; on landing with sprint held → crouch + resume |
| Deployment totem (Rage, Ammo Crate, Animal Instinct, Team Healing, Chimp, Turret) | Stands up, totem plays, sprint paused; resumes when `Gameplay.MovementStopped` is released |
| Disguise | Same as deployment totems (now uses `Gameplay.MovementStopped`) |
| Personal Healing | Used **in** the primal stance, sprint continues (animation look ignored on purpose) |
| Grenade | Thrown while sprinting, sprint continues |
| Roll (only reachable as the WallMove-fail fallback, see QOL §9) | **Ends** the sprint (`GA_Roll` cancels `Ability.Type.Action.Sprint`); press again |
| Glide / wall-move | Not specially handled; whatever their tags do. Press again afterwards |
| Release | Sprint ends, back to the starting stance (started standing → stand up, started crouched → stay crouched). If another ability *cancelled* the sprint, the stance is left as that ability left it |

### Code (`309a52cee` "Sprint: primal sprint only", `9e5bbd274` "Disguise: …")
- `SprintGameplayAbility.h/.cpp`
  - `bUseStamina` (EditDefaultsOnly, **false**) — `Crouched()` only drains when set. Flip in `GA_Sprint` to bring stamina back.
  - `bStartedCrouched` — set **before** `CommitAbility` so a failed activation can't reuse the previous sprint's value.
  - `ActivateAbility` never calls `Uncrouched()`; if standing it calls `TryResumeSprint()` → `Crouch()`. The boost and blocks are applied from `OnCrouched`.
  - `OnUncrouched` → `PauseSprint()` (remove GE, unblock, stop stamina) + `TryResumeSprint()`.
  - `TryResumeSprint()` runs **only where locally controlled** (crouch is client-driven and replicated by the CMC; the server applies the sprint from `OnCrouched` when the crouch reaches it). Conditions: active, not crouched, `IsMovingOnGround()`, no `Gameplay.MovementStopped`, none of **`AdditionalResumeBlockedTags`** (new EditDefaultsOnly container).
  - Re-checked on `ACharacter::LandedDelegate` and on removal of any resume-blocking tag (`RegisterGameplayTagEvent`). Both bound only on the local side, unbound first thing in `EndAbility`.
  - Block / unblock of `BlockAbilitiesWithTagWhenCrouched` tracked with `bBlockingAbilitiesWhenCrouched` (never applied or removed twice).
  - **Bug fixed:** `EndAbility`'s invalid-`ActorInfo` early-out had no `return` and went on to dereference the null it had just detected. Now returns, and also guards with `IsEndAbilityValid`.
  - `Uncrouched()` / `SpeedMultiplierUncrouched` kept but unused, so the standing sprint can come back.
- `Source/LyraGame/Character/LyraHeroComponent.cpp` — `Input_Crouch` returns early while the ASC has `Event.Movement.Sprint` (`UE_DEFINE_GAMEPLAY_TAG_STATIC` in the file). The sprint's own `Crouch()`/`UnCrouch()` calls bypass this.
- `TotemGameplayAbilityWithDeploymentAnimationBase.cpp`
  - Constructor no longer adds `Status.Crouching` to `ActivationBlockedTags`.
  - 🔑 The per-tick `OnCharacterMovementUpdated` → `UnCrouch()` used to stay bound **for the whole ability** — Rage, Animal Instinct and the synergy totems stay active long after their animation, so it would have fought the sprint resume every frame (crouch/stand flicker for the whole buff). Now unbound when the deployment montage blends out, and **never bound** for `bAllowMovementDuringDeployment` totems (Personal Healing).
- `DisguiseTotemGameplayAbility.h/.cpp` — `DisableMovement()` → `Gameplay.MovementStopped` loose tag (same helpers as the deployment base), released by a montage-length timer **on both sides** and in `EndAbility`. Previously only the server's `Disguise()` re-enabled movement; the client stayed `MOVE_None` until the ability ended unless corrected. Also no longer freezes a falling player. Both `SetDefaultMovementMode()` calls removed.

### Editor changes made by Marco (`b81d28db5`)
- `Status.Crouching` removed from **Activation Blocked Tags** of every totem GA (`GA_SelfHealing`, `GA_Rage`, `GA_AmmoCrate`, `GA_AnimalInstinct`, `GA_TeamHealing`, `GA_ChimpCompanion`, `GA_AutoTurret`). Without this no totem could start mid-sprint, because primal sprint is always crouched.
- `GA_Sprint`: `Ability.Type.Action.ADS` in Block Abilities with Tag.
- Same commit also touched `GE_Damage_SuperCharge`, `GE_Damage_Grenade`, `GA_SuperCharge` (other card items).

### Lessons
- **Blueprint class defaults override C++ constructor containers.** Removing a tag from a C++ ctor does nothing for a BP that saved its own copy — change both (same trap as the `Status.Moving` change in QOL #1).
- **Primal stance is crouch.** Anything that blocks on `Status.Crouching` or calls `UnCrouch()` interacts with the sprint. `UnCrouch()` callers: `JumpGameplayAbility.cpp:34`, `LyraGameplayAbility_Jump.cpp:55`, `RollGameplayAbility.cpp:140`, `SuperChargeTotemGameplayAbility.cpp:49`, the deployment base.
- **`IMC_Default_Gamepad` is not the live mapping.** Matches load `IMC_Default_KBM` (holds both KBM and gamepad rows) — see QOL §9. The L3 sprint read off `IMC_Default_Gamepad` is therefore unverified for real matches.

### Open / to watch
1. **Supercharge**: stands you up without `Gameplay.MovementStopped`, so the sprint re-crouches mid-dash. Add its Activation Owned tag to `GA_Sprint` → **Additional Resume Blocked Tags**.
2. **Speed hitch on a standing start**: the boost now applies from `OnCrouched` (outside the activation prediction window), so the client may see a short correction. Same as the old crouch-mid-sprint path.
3. **Gamepad sprint button in the live context** (`IMC_Default_KBM` gamepad rows).
4. Crouch-sprint animations for rifle / pistol / melee layers (only unarmed `MA_CrouchSprint_01` found by name).
5. Stamina HUD bar (if any) now sits full permanently.
6. Bots: does `AbilitySet_Enemy` grant `GA_Sprint`?
7. Can a wall-move still start from a primal sprint? (if `GA_WallMove` is blocked by `Status.Crouching`, sprinting into a wall won't climb)
8. Dedicated-server test in a real match (cooked in `2026-10-17_19-41`, PIE only so far).
