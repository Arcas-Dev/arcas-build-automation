# Friendly fire / team-selective weapon effects — how to enable it later

**Status: NOT DONE. Analysed 2026-08-26, deliberately parked by Dan. Nothing in the repo was changed.**
This is the recipe for when we want hitscan weapons to affect team mates (friendly fire, or a "healing mode" on utility weapons that applies a different effect to your own team).

## Where the team rule lives today

A hitscan shot passes through these layers. Only one of them blocks same-team damage:

| Layer | File | Team-aware? |
|---|---|---|
| Trace (who the bullet touches) | `LyraGame/Weapons/LyraGameplayAbility_RangedWeapon.cpp:106` `FindFirstPawnHitResult`; collision profile `LyraPawnMesh` blocks `Lyra_TraceChannel_Weapon` for every pawn | No, team mates are hit like anyone |
| Apply the effect | `GA_Weapon_Fire` (Blueprint, parent `UBASGameplayAbility_RangedWeapon`), in `OnRangedWeaponTargetDataReady` | No, applies `GE_Damage` to the hit actor unconditionally |
| **Damage execution** | **`LyraGame/AbilitySystem/Executions/LyraDamageExecution.cpp:95`** `DamageInteractionAllowedMultiplier = TeamSubsystem->CanCauseDamage(EffectCauser, HitActor) ? 1.0 : 0.0;` | **YES. This is the blocker.** `CanCauseDamage` (`Teams/LyraTeamSubsystem.cpp:437`) is true only for DifferentTeams, self (`bAllowDamageToSelf` defaults true) and no-team actors with an ASC. Same team = damage x 0 |
| Same gate, duplicated | `LyraGame/AbilitySystem/Executions/CustomizableCustomPowerExecution.cpp:86` | YES, for custom-power (utility) rounds |
| Heal execution | `LyraHealExecution.cpp` / `CustomizableHealExecution.cpp` | **No team logic at all**: a heal GE heals whoever it is applied to, enemies included |
| Health set / component | `LyraHealthSet.cpp:68` `PreGameplayEffectExecute`, `LyraHealthComponent.cpp` | No (only `Gameplay.DamageImmunity` / GodMode tags) |
| Hit marker (client) | `LyraGame/Weapons/LyraWeaponStateComponent.cpp:52` `ShouldShowHitAsSuccess` | Uses `CanCauseDamage` too, cosmetic only |

So: BP can already apply the GE to a team mate; it reaches the execution and is multiplied by zero there. No ini, tag or parameter turns this off. Hardcoded Lyra behaviour.

`UBASGameplayAbility_RangedWeapon` (`LyraGame/Weapons/`) holds only `GE_Damage` + an `IsDataValid`; it does not decide targeting.

## Who else goes through `LyraDamageExecution`

Every non-hitscan damage source already does its own `CompareTeams` before applying its GE, so the execution gate is only load-bearing for `GA_Weapon_Fire`:
`Grenade.cpp:160`, `MeleeWeaponProjectile.cpp:117`, `ArtilleryCannonProjectile.cpp:106`, `SuperChargeTotemGameplayAbility.cpp:206`, `SynergyTotemGameplayAbilityBase.cpp:912`, `ArcasBotController.cpp:496` (all under `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/Private/`). Unverified: `AutoTurretBarrel.cpp` has no team code of its own; check the turret's targeting in the editor before relying on it.

## The recipe (chosen approach: remove the C++ gate, decide in BP)

### Step 1, C++: one line

`LyraGame/AbilitySystem/Executions/LyraDamageExecution.cpp:95`

```diff
-			DamageInteractionAllowedMultiplier = TeamSubsystem->CanCauseDamage(EffectCauser, HitActor) ? 1.0 : 0.0;
+			// BAS: team rules (friendly / enemy fire) are decided by the applying ability (GA_Weapon_Fire), not here.
+			DamageInteractionAllowedMultiplier = 1.0f;
```

Tidier equivalent (replace lines 88 to 97): `const float DamageInteractionAllowedMultiplier = HitActor ? 1.0f : 0.0f;`

Optional, same one-liner at `CustomizableCustomPowerExecution.cpp:86` if custom-power rounds should also be team-decided in BP.

Compile: `C:\UE5.5\Engine\Build\BatchFiles\Build.bat LyraEditor Win64 Development -Project=C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject` (~42 s incremental). Self-damage, distance falloff, phys-material and `PowerMultiplier` are untouched.

### Step 2, Blueprint (Marco), in the parent `GA_Weapon_Fire`

After `OnRangedWeaponTargetDataReady`, before **Apply GE_Damage**:

```
Get Subsystem (LyraTeamSubsystem)
  -> Compare Teams (A = avatar pawn, B = hit actor)     <- already BlueprintCallable, ExpandEnumAsExecs
       DifferentTeams   -> Branch(bEnemyFire)    -> Apply GE_Damage
       OnSameTeam       -> Branch(bFriendlyFire) -> Apply GE_Damage (or a different GE, e.g. a heal GE for "healing mode")
       InvalidArgument  -> treat as enemy (target dummies)
```

`bEnemyFire` (default true) and `bFriendlyFire` (default false) can be plain BP variables on the parent `GA_Weapon_Fire`. Promote to `UPROPERTY(EditDefaultsOnly)` on `UBASGameplayAbility_RangedWeapon` later if they should be typed (4 lines).

For a healing mode: point the same-team branch at a `GE_Heal_*` (execution `CustomizableHealExecution`, already built and working, reads the shooter's `BaseHeal` x `PowerMultiplier`). Because the heal execution has no team gate, the BP branch is the only thing stopping enemies from being healed.

### Optional step 3, trace pass-through

The trace stops on the first pawn regardless of team, so an enemy in front of a wounded team mate absorbs a heal shot. `AddAdditionalTraceIgnoreActors` (`LyraGameplayAbility_RangedWeapon.cpp:130`, already `virtual`) can be overridden on `UBASGameplayAbility_RangedWeapon` to add wrong-team pawns to the ignore list. Separate decision; it changes body-blocking.

## Alternatives considered (not chosen)

- **Spec tag** (Lyra idiom, cf. `Gameplay.Damage.SelfDestruct` at `LyraHealthSet.cpp:80`): BP adds a dynamic asset tag like `Gameplay.Damage.AllowFriendly` to the spec, the execution skips `CanCauseDamage` when present. Keeps the safety net for everything else; 3 lines of C++ plus a tag.
- **Flags on the ability read by the execution** via `TypedContext->GetAbility()` (the ability CDO travels in the effect context). Was written and reverted on 2026-08-26; more C++ than needed.

## Side effects once enabled

- Hit markers: `LyraWeaponStateComponent.cpp:52` still uses `CanCauseDamage`, so team-mate hits damage but show no hit marker. Fix later by reading the flags off the fire ability.
- Safety net gone: any damage GE applied from BP without a `CompareTeams` check will hurt team mates. Today that is only `GA_Weapon_Fire`; anything new must branch.
