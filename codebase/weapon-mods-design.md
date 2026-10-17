# Weapon Mods — Design & Decision Record

**Created**: 2026-08-12 · **Status**: 🟡 DESIGN IN PROGRESS, not yet built
**Participants**: Dan, Marco (live in the editor on the build VM), Claude
**Companion docs**: [[weapon-system-deepdive]] (the evidence pass) ·
[[weapon-mods-approach]] (the Marco-facing pitch) · [[progression-ranking-spec]] §10 ·
[[weapons-and-grenade-deepdive]] (trace / VFX / the tracer bug)

> **Why this doc exists**: the 2026-08-10 → 08-12 investigation produced a lot of verified
> fact, several reversals, and a handful of options we deliberately rejected. Conclusions
> alone would lose the reasoning, and the rejected options are the ones most likely to be
> re-proposed. **Everything here is either marked as verified evidence, a decision, or an
> open question.**

---

## 0. Decision log

| # | Decision | Rationale | By | Date |
|---|---|---|---|---|
| **W1** | **Mods are a separate system from weapon tuning.** Do not build mods on `FBASRangedWeaponStatsSettings`. | They are different features. Tuning is four continuous sliders earned via mastery trials; mods are discrete equipped items. The tuning struct also physically cannot express magazine size or bullets per shot. Coupling them would make tuning harder to finish later. | Dan | 08-12 |
| **W2** | **Do not use `PowerMultiplier` for mod damage.** | It is the field the tuning pass writes (`TryApplyStats` → `SetPowerMultiplier`). Two systems assigning the same float would fight. Keep them on separate fields. | Dan | 08-12 |
| **W3** | **Build the 3 primary mods first** (Double Tap, High Damage Rounds, High Capacity Mag), then the rest. | They are the three that need no new gameplay concepts. If they work the pattern is proven and the other six are content. | Dan | 08-12 |
| **W4** | **One mod slot per weapon; 3 mods available per weapon class.** | Three real choices per loadout. Giving every weapon all three of its class's mods removes the decision entirely. (= D15 in the spec.) | Dan | 08-06 |
| **W5** | **Prefer C++ wherever the engine allows it.** | Keeps logic reviewable in one place and avoids editing `GA_Weapon_Fire`, which all 22 weapons inherit from. | Dan | 08-12 |
| **W6** | **Explore splitting the weapon instance hierarchy** into Primary / Utility / Melee parents. | Makes mod compatibility structural rather than a runtime check, and stops melee weapons carrying ammo and spread fields. **Proposed, not committed.** | Marco/Dan | 08-12 |

---

## 1. Verified facts (evidence, with how each was established)

Everything in this section was confirmed either by reading project C++ or by opening the
real `.uasset` files. Local Mac clones are **git-lfs pointers**, so assets were pulled off
the build VM (`34.65.124.207`) or read from Marco's editor screenshots.

### 1.1 Item and weapon data

| Fact | Source |
|---|---|
| `ID_Rifle`: **ItemId = 103**, Category = Primary Weapon | editor |
| That matches the Asset Identifiers sheet (103 = MELONRIFLE) exactly → **asset IDs and the design spreadsheet agree** | cross-check |
| A weapon ItemDefinition carries **6 fragments**: `EquippableItem`, `QuickBarIcon`, `SetStats`, `PickupIcon`, `ReticleConfig`, `BarrackSlot` | editor + asset strings |
| Weapons do **not** carry `InventoryFragment_GrantAdditionalAbilities` — that is totems only | asset strings |
| `SetStats` on the Rifle: `MagazineSize 60`, `MagazineAmmo 60`, `SpareAmmo 120` | editor |
| `B_WeaponInstance_Rifle`: `BulletsPerCartridge 1`, `MaxDamageRange` = `MaxTraceRange` = 15000cm, `FireDelay 0.12`, sweep radius 5.5, WeakSpot material multiplier 1.5 | editor |
| `DA_MinMaxWeaponsStatsSettings`: **all four stats 0.5 → 2.0** (Power, Accuracy, Handling, DistanceDamageFalloff) | editor |
| **All 22 weapon instances** reference `DA_MinMaxWeaponsStatsSettings`; the base BP does not, so it is authored per weapon and **none were missed** | swept every asset on the VM |
| `B_BASPlayerState` has **no** `Weapons Stats Settings` field → confirms `af4691a18` (Jan 2025) removed the `UPROPERTY` | editor |

### 1.2 The asset reference chain

```
ID_Rifle ──(EquippableItem fragment)──► WID_Rifle ──┬──► B_WeaponInstance_Rifle
                                                    └──► AbilitySet_ShooterRifle
                                                             └──► GA_Weapon_Fire_Rifle_Auto
                                                                      └──► GE_Damage_RifleAuto
```

This chain is why the variant approach is expensive: you cannot duplicate only the file
holding the value you want to change, you must duplicate everything above it.

### 1.3 Damage

| Fact | Detail |
|---|---|
| `GE_Damage_RifleAuto` parent | `GE_Damage_Basic_Instant`, Duration `Instant` |
| **`Modifiers` array is EMPTY** | the damage is not a plain modifier |
| One Execution | `CustomizableDamageExecution` |
| Its Calculation Modifier | Captured Attribute `BaseDamage`, Source, **Snapshotted**, Op **Add (Base)**, Magnitude **ScalableFloat = 15.0** |
| 15.0 matches the design sheet's WeaponStats tab for MelonRifle | so those spreadsheet numbers are live values |
| Damage formula | `BaseDamage × DistanceAtten × PhysMatAtten × TeamMul × PowerMultiplier` |
| `PowerMultiplier` | plain float on `ULyraWeaponInstance`, applied to **every** output modifier by `WeaponCustomizableExecutionLibrary::ApplyPowerMultiplierToOutExecutionOutput`, shared by the Damage, Heal and CustomPower executions |

### 1.4 Ammo

`InventoryFragment_SetStats::OnInstanceCreated` writes its map into the item instance's
replicated `StatTags`. The shared `GA_Weapon_ReloadMagazine` Blueprint (parent of every
weapon's reload ability) reads `GetStatTagStackCount(MagazineSize)` **at reload time**,
compares to `MagazineAmmo`, checks `SpareAmmo`, then `AddStatTagStack` / `RemoveStatTagStack`.

→ **Changing `MagazineSize` at runtime takes effect on the next reload.** `AddStatTagStack`
is `BlueprintCallable, BlueprintAuthorityOnly` and `StatTags` is `UPROPERTY(Replicated)`.

⚠️ `MagazineSize` is **not** declared in C++ (`TagDefinitions.cpp` declares only
`MagazineAmmo` and `SpareAmmo`). It is a project-config tag used from Blueprint. Do not
conclude from a C++ grep that it does not exist.

### 1.5 The fire ability: what is C++ and what is Blueprint

`GA_Weapon_Fire` is a **Blueprint**; its parent `UBASGameplayAbility_RangedWeapon` is C++.

| Variable | Lives in |
|---|---|
| **`GE_Damage`** | **C++** on `UBASGameplayAbility_RangedWeapon`, `UPROPERTY(BlueprintReadOnly, EditDefaultsOnly)`, plus an `IsDataValid` that errors if empty |
| `GameplayCue_TagFiring` | Blueprint |
| `GameplayCue_Impact` | Blueprint |
| `AdditionalGameplayEffects` | Blueprint |
| `TraceMaxDistance`, `GCNParameter`, `OffsetGCN`, `ImpactPositions/Normals/SurfaceTypes` | Blueprint |

**How to tell in the editor**: select the variable and look at the Details panel. Native
properties show a **Defined Property Flags** block (`CPF_NativeAccessSpecifierPublic` etc.);
Blueprint-created variables do not.

**`AdditionalGameplayEffects` is already looped**: the graph applies the main damage GE,
does `SET Additional Gameplay Effects Target Data`, then a **For Each Loop** calling
`ApplyGameplayEffectToTarget` per array element. Per-weapon children leave it empty, so it
is an unused per-shot "apply these extra effects to whatever you hit" hook. **That is what
Fire / Healing / Demolition Rounds need, already built.**

### 1.6 C++ can already read a weapon's base damage

`BASRangedWeaponsStatsSubsystem` does:

```cpp
UGameplayEffect* DamageGE = RangedWeaponGameplayAbility->GE_Damage.GetDefaultObject();
for (const FGameplayEffectExecutionDefinition& Exec : DamageGE->Executions)
    // find the Customizable*Execution, read its ModifierMagnitude
```

This is how the Tuning Table displays a damage number. **It means a mod can be expressed as
"1.5× whatever this weapon actually does" and resolved at runtime**, with no per-weapon
hardcoding.

### 1.7 Class hierarchy (as-is)

```
ULyraEquipmentInstance (C++)
 └ ULyraWeaponInstance (C++)              PowerMultiplier, SpeedMultiplier
    └ ULyraRangedWeaponInstance (C++)     BulletsPerCartridge, MaxDamageRange, MaxTraceRange, spread
       └ UBASRangedWeaponInstance (C++)   recoil, falloff coeff, MinMaxStatsDataAsset, ApplyStats()
          └ B_BASRangedWeaponInstance_Base (BP)
             └ 22 × B_WeaponInstance_* (BP)
```

🔴 **All 22 weapons derive from this, including all five melee weapons** (Axe, CombatKnife,
Machete, RelicSword, Spear). **There is no melee weapon instance class in the project.** So
the Combat Knife currently carries `BulletsPerCartridge`, spread angle, a mouse recoil curve,
`MaxTraceRange` and magazine handling, all meaningless. This is the evidence behind W6.

### 1.8 Visuals

`AWeaponVisualization` (C++, `BASShooterCore/Actors/`) is a **25 line stub**: an `AActor`
implementing `IGameplayTagAssetInterface` with one `FGameplayTagContainer OwnedGameplayTags`.
Its only C++ consumer is `AimDownSightsGameplayAbility` checking for melee/sniper tags.

**Everything visual is a Blueprint variable on `B_Weapon`** (the actor spawned via
`WID_ → ActorsToSpawn`): `Muzzle Flash System`, `Tracer System`, `Shell Eject System`,
`Shell Eject Mesh`, four impact Niagara systems (Glass / Default / Character / Concrete),
`Decal System`, `Impact Positions`, `Max Distance Trace`, `Handling Stat`, `Impact Class`.
BP functions: `AddFakeProjectileData`, `TriggerFireAudio`, `UpdateCustomStencil`,
`UpdateTeamColors`, `Handling`.

Notes: `UpdateTeamColors` existing is relevant to the friend/foe question raised in the skins
work. `Impact Positions` on this actor is the surface behind the July shotgun tracer bug
([[weapons-and-grenade-deepdive]] §6b) — anything a mod does to tracers must respect it.

### 1.9 Equip pipeline and Blueprint reachability

| Thing | Reachable from Blueprint? |
|---|---|
| `K2_OnEquipped` (BlueprintImplementableEvent, called by `ULyraEquipmentInstance::OnEquipped`) | ✅ yes, weapon instance BPs get an equip hook |
| `ULyraQuickBarComponent::GetActiveSlotItem()` | ✅ `BlueprintCallable` |
| `ULyraInventoryItemInstance::AddStatTagStack` | ✅ `BlueprintCallable, BlueprintAuthorityOnly` |
| **`BulletsPerCartridge`** | ❌ `BlueprintReadOnly`, and the loop reading it is C++ at `LyraGameplayAbility_RangedWeapon.cpp:390` |

The equipment instance is created fresh on every equip (`LyraEquipmentManagerComponent.cpp:86`),
and everything granted at equip is removed at unequip via the same `GrantedHandles`
(`:91-95` / `:121`). So equip-time mutation needs no undo and cannot leak between weapons.

### 1.10 Replication surface for mod state

`ABASPlayerState::PlayerInfo` is `UPROPERTY(ReplicatedUsing=OnRep_PlayerInfo)` and contains
`FUserCombatWeapons` with three `TSubclassOf<ULyraInventoryItemDefinition>` (Primary /
Utility / Melee) plus `FUserCombatAbilities` for totems.

→ **Adding three more fields of the same type for equipped mods gives replication to the
owning client for free**, which structurally avoids the dedicated-server bug the dormant
tuning pass has ([[weapon-system-deepdive]] §7).

---

## 2. Options considered and rejected

Recording these because they are the ones most likely to come back.

| Option | Why it was rejected |
|---|---|
| **One weapon variant per mod** (the "obvious" way) | With 3 mods per class it is 84 weapon types, not 189 (Dan's correction). But the killer is not count: because of the reference chain (§1.2) a variant means duplicating `ID_` (1 asset) for ammo, `ID_+WID_+B_WeaponInstance_` (3) for Double Tap, or `ID_+WID_+AbilitySet_+GA_Fire_+GE_Damage_` (5) for damage. About **90 assets for three mods on primaries alone**, and they are a fork of the reference graph, so future fixes must be applied to every fork. **Above all it cannot deliver "one mod, many weapons"**: if a modded rifle is its own ItemDefinition then the vault owns `Rifle+DoubleTap`, and there is no object that *is* Double Tap for progression to grant or the Tuning Table to slot. That is a capability gap, not a cost. |
| **A GameplayEffect multiplying the player's `BaseDamage` attribute** | **Does not work.** §1.3: the weapon's damage is added as a *scoped* Calculation Modifier inside the execution, after capture. The player's `BaseDamage` attribute contributes ~0, so multiplying it multiplies nothing. It would look correct in the editor and silently fail in game. Caught only by opening `GE_Damage_RifleAuto`. |
| **`PowerMultiplier` for mod damage** | Works, and is zero-asset, but it is the field the tuning pass assigns. W2. |
| **Building mods inside `FBASRangedWeaponStatsSettings`** | The struct only carries four alphas (Power, Accuracy, Handling, DistanceDamageFalloff). It cannot express magazine size or bullets per shot, and reusing it couples two features that should ship independently. W1. |
| **"The ID offset blocks will overflow"** as an argument | **Wrong, do not use it.** `PRIMARY_WEAPONS_OFFSET 100` gives 99 slots per category; 10 primaries × 4 variants = 40. It fits. Checked before it was used. |
| **`Is Gameplay Tag Valid` as the "is a mod equipped" test** | It checks the tag is well-formed, not that the actor has it. With input `None` it returns false permanently, so the Select would always take the unmodded pin. Use `Has Matching Gameplay Tag` against the ASC, or read the mod from data. |
| **`GE_Damage_Modded` as a Blueprint variable** | Superseded: `GE_Damage` is already a C++ property, so the modded one belongs next to it in C++ as a map, which extends past one boolean and gets `IsDataValid` coverage. |

---

## 3. The design as it stands

### 3.1 Shape

A mod is **an owned item with a payload**, applied to the freshly spawned weapon objects at
equip, composing with (never overwriting) anything tuning does.

```
loadout (backend)
   └─ PlayerInfo.FUserCombatWeapons  + 3 mod fields   [replicated, §1.10]
        └─ on equip: UBASRangedWeaponInstance::ApplyMods()
             ├─ damage        → select the mod's GE via C++ (§3.3)
             ├─ bullets/shot  → BulletsPerCartridge (needs C++ write access)
             ├─ magazine      → AddStatTagStack(MagazineSize, +N) on the item instance
             ├─ on-hit fx     → AdditionalGameplayEffects (BP loop, already exists)
             └─ VFX           → ExecuteGameplayCue additive (§3.4)
```

**Composition rule, to be written into the code as a comment**: tuning uses `Set*`
(assignment); mods must **multiply or add into** the result and must run **after** tuning.
Two independent passes, neither aware of the other. Tuning can stay dormant indefinitely.

### 3.2 Where the mod payload is authored

**Leading option**: a DataTable with a C++ row struct (`DT_WeaponMods`), one row per mod. No
Blueprint asset per mod. Precedent exists: `DT_WeaponsId`, `DT_TotemsId`, `DT_AllVaultItems`.

```cpp
USTRUCT() struct FWeaponModRow : public FTableRowBase
{
    uint8  ModId;                    // 801..809
    EUserCombatBarrackType Slot;     // Primary | Utility | Melee
    float  DamageMultiplier = 1.f;
    int32  BulletsPerCartridgeAdd = 0;
    int32  MagazineSizeAdd = 0;
    FGameplayTag FireCueTag;         // additive VFX
    FGameplayTag ImpactCueTag;
    TSubclassOf<UGameplayEffect> OnHitEffect;
    TSoftObjectPtr<UTexture2D> Icon;
};
```

**Alternative**: mod as a `ULyraInventoryItemDefinition` + a new `InventoryFragment_WeaponMod`.
Gains ItemId, category, icon and vault ownership for free, and can reuse `SetStats` for the
ammo case and `GrantAdditionalAbilities` for effects. Costs a BP asset per mod. **Open, §4.**

Either way the only things that *must* be assets are the **Niagara/cue for the VFX** and the
**icon**. Those are content, not logic.

### 3.3 Damage

Put the modded GE next to the existing one, in C++:

```cpp
UPROPERTY(BlueprintReadOnly, EditDefaultsOnly)
TSubclassOf<UGameplayEffect> GE_Damage;                                  // existing

UPROPERTY(BlueprintReadOnly, EditDefaultsOnly)
TMap<FGameplayTag, TSubclassOf<UGameplayEffect>> GE_Damage_ByMod;        // new
```

Authored in the same place Marco already fills `GE_Damage` (the fire ability's Class
Defaults), extends to any number of mods, and gets the same `IsDataValid` validation.

**Blueprint surface**: replace the `Select` node with a single call to a C++
`GetDamageEffectToApply()`. One node in the graph, all logic in code. Moving the application
itself into `OnTargetDataReadyCallback` is possible but changes the firing path for all 22
weapons, so not for v1.

Alternatively §1.6 lets a mod be a pure multiplier resolved at runtime with no per-weapon GE
at all. **Open, §4.**

### 3.4 VFX — two tiers

| Tier | What | Cost |
|---|---|---|
| **1. Additive** | mod plays its own extra cue on top of the weapon's | C++ `ASC->ExecuteGameplayCue(ModCueTag, Params)`. **No Blueprint edit at all**, so no risk to the shared ability |
| **2. Replacement** | mod changes the weapon's own tracer / muzzle flash | those are BP variables on `B_Weapon` (§1.8). Requires **promoting them into `AWeaponVisualization` in C++** first |

Tier 1 is enough for a bastonium glow layered over the rifle's normal flash. Tier 2 is needed
only if a mod must suppress the weapon's own look.

### 3.5 The three refactors, in order

| | Change | Why | Risk |
|---|---|---|---|
| **A** | Mod fields + `ApplyMods()` on the existing `UBASRangedWeaponInstance`; writable `BulletsPerCartridge` on `ULyraRangedWeaponInstance`; mod fields on `FUserCombatWeapons` | the mod system itself | low, purely additive |
| **B** | Promote the VFX properties from `B_Weapon` into `AWeaponVisualization` | enables tier 2 VFX | medium, moving BP vars to C++ can drop authored values |
| **C** | Split the hierarchy into Primary / Utility / Melee instance classes (W6) | structural mod compatibility; melee stops carrying ammo and spread | highest, 22 BP reparents, 5 melee weapons shed properties |

**Do A, prove it, then B, then C.** Doing them together means a failure cannot be attributed.

Precedent for editing `ULyraRangedWeaponInstance`: we added `MaxTraceRange` to that exact
class in July (`2910a4321`), for the same reason.

---

## 4. Open decisions

| # | Question | Options | Notes |
|---|---|---|---|
| **M1** | **Who owns the numbers?** | (a) the mod does: Double Tap is +1 everywhere. (b) the weapon does: each weapon configures its own Double Tap, the mod switches it on. (c) hybrid: mod default + optional per-weapon override | (b) is what "set the values in the editor" implies and designers usually want it, but a tenth mod then means new fields plus filling 22 weapons. (c) is the standard compromise. **Changes the shape of the C++, settle before writing.** |
| **M2** | Mod asset form | DataTable row vs ItemDefinition + fragment | §3.2. ItemDefinition buys vault ownership and progression unlocks for free |
| **M3** | Damage mechanism | per-weapon modded GE (`GE_Damage_ByMod`) vs runtime multiplier resolved from §1.6 | the second needs no per-weapon assets but cannot change damage *type*, only magnitude |
| **M4** | VFX tier | additive only, or promote `B_Weapon` properties for replacement | decides whether refactor B is in scope |
| **M5** | Mod category | reuse `EUserCombatBarrackType::PrimaryWeapon` (zero code, but mods appear in the weapons vault tab) vs a new enum value | one-line enum change |
| **M6** | "Mod equipped" signal | gameplay tag granted by the mod's AbilitySet vs a field read from `PlayerInfo` | tag is BP-friendly and replicates; field is explicit and typed |
| **M7** | Is the mod count 9 or 12? | Bible says "an initial pool of 12", lists 9, nine have icons | ask Marco |
| **M8** | Melee mods buff *champion* stats (Luck / Agility / Intelligence ×1.5) | equip-scoped (recommended) vs always-on | equip-scoped is free from the engine and makes them a real choice |

---

## 5. Corrections made during this investigation

Recorded so nobody trusts a stale claim from an earlier message or doc revision.

1. **189 → 84.** Mods are per weapon class, so each weapon takes only its class's 3. Dan's correction. The scale argument was replaced by the capability argument (§2).
2. **"High Damage Rounds is a GameplayEffect on `BaseDamage`" was wrong.** The damage is a scoped Calculation Modifier inside the execution; the attribute contributes ~0. See §2.
3. **The ID-block-overflow argument was wrong** and was withdrawn before use.
4. **`UBASGameplayAbility_RangedWeapon` is not a stub.** It holds `GE_Damage` in C++. An earlier grep searched only the *other* variable names and wrongly concluded the whole class was empty.
5. **The dormant tuning pipeline is not the mods mechanism.** It is a separate feature that happens to use the same seam. W1.
6. **"Two of the three mods are Blueprint-only" was true of each mod's effect, not of the system.** Nothing in Blueprint can add a replicated field to `PlayerInfo`, so production needs C++ regardless.
7. **`AWeaponVisualization` genuinely is a stub** (25 lines), unlike the ability. The "thin C++ parents, fat Blueprint children" generalisation holds for the visuals and not for the fire ability.

---

## 6. Immediate next steps

1. **Settle M1** (who owns the numbers). It changes the C++ shape and everything else waits on it.
2. **Refactor A**, then prove **High Capacity Mag** on the Rifle alone: it is the one mod that needs no new gameplay concept and no VFX, so it isolates the plumbing.
3. Then **High Damage Rounds** with tier 1 additive VFX, which exercises `GE_Damage_ByMod` and `ExecuteGameplayCue` together.
4. Then **Double Tap**, which is the only one of the three requiring the `BulletsPerCartridge` write.
5. Only then decide B and C.

Still outstanding from [[weapon-system-deepdive]] §10: `DT_AllVaultItems` rows (the ID bridge,
needed by the unlock system too), `DT_WeaponsId` contents, per-weapon magazine sizes for the
other primaries, and how far the utility-round executions (`CustomizableHealExecution`,
`CustomizableCustomPowerExecution`, `CustomizableBlindExecution`) actually got.
