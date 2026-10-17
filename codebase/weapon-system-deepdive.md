# Weapon System Deep Dive — and what weapon mods actually require

**Created**: 2026-08-10 · **Status**: 🟢 Investigation complete, findings verified
**Trigger**: Marco is not convinced by [[weapon-mods-approach]]. This is the evidence pass.
**Related**: [[weapon-mods-approach]] (the Marco-facing pitch) · [[progression-ranking-spec]] §10 ·
[[weapons-and-grenade-deepdive]] (trace/range/VFX) · [[barracks-vault-flow]]

> ⚠️ **Superseded in part by [[weapon-mods-design]] (2026-08-12).** Two claims in this doc
> were corrected during the live editor session with Marco:
> 1. **§5's "use `PowerMultiplier`" is no longer the plan.** Dan ruled it out (W2) because it
>    is the field the tuning pass assigns; mods must not share it.
> 2. **`UBASGameplayAbility_RangedWeapon` is NOT a stub.** It holds `GE_Damage` as a C++
>    `UPROPERTY` plus an `IsDataValid`. An earlier grep here searched only the other variable
>    names and wrongly concluded the class was empty. The "thin C++ parents" generalisation
>    holds for `AWeaponVisualization` (a genuine 25-line stub) but not for the fire ability.
>
> Read this doc for the **evidence and the archaeology**; read [[weapon-mods-design]] for the
> **current design, decisions and open questions**.

## Method

- Full read of the C++ weapon, equipment and inventory stack on `deploy/steam-testing`.
- **Real `.uasset` files pulled off the build VM** (`34.65.124.207`, repo @ `ef7da39fc`) and
  inspected. Local Mac clones are git-lfs *pointers* (129 bytes), so asset contents are not
  readable locally — this is why the VM matters and why earlier passes had gaps.
  Assets examined: `ID_MadRifle`, `WID_MadRifle`, `B_WeaponInstance_MadRifle`,
  `AbilitySet_ShooterMadRifle`, `GE_Damage_MadRifleAuto`, `GA_Weapon_Reload_MadRifle`,
  `GA_Weapon_ReloadMagazine`, `DA_MinMaxWeaponsStatsSettings`.
- Asset internals were read via name/import-table extraction. That reliably reveals
  **structure** (which classes, which fragments, which tags, which references). It does
  **not** reveal **numeric property values** — those still need the editor. Every claim
  below is marked for how it was established.

---

## 1. Headline findings

1. 🔴 **A per-weapon, ItemId-keyed, equip-time stat-modification pipeline is already
   built and wired into the game — and it is dormant because nothing ever fills its data
   source.** `FAllBASRangedWeaponsStatsSettings::ApplyStats` runs on every equip and
   currently iterates an empty array. This is 90% of the mods delivery mechanism, already
   written, by the previous team. (§6)

1b. 🔴 **It is Bevium-era, it was alive, and it died by cleanup on 2025-01-31.** One
   developer (`Driver2579`) built it Nov 2024 to Mar 2025. The `UPROPERTY(EditDefaultsOnly)`
   that was its only data source was removed to satisfy a `// TODO`, the real backend source
   was never built, and the contract ended eleven months later. The previous team also left
   an empty `UTuningTableModSlotButton` whose comments specify a mod struct stored per
   weapon and saved via a subsystem — i.e. our design. (§6b, §6c)

2. 🔴 **`ULyraWeaponInstance::PowerMultiplier` already exists and is already multiplied
   into every damage, heal and custom-power result.** "High Damage Rounds ×1.5" is a float
   assignment on an object that already exists, not a new Gameplay Effect. Its designed
   range is **0.5× to 2.0×**, so ×1.5 is comfortably inside what the existing system was
   built for. (§5)

3. 🔴 **The dormant pipeline has a latent dedicated-server bug.** `ApplyStats()` early-returns
   unless `HasAuthority()`, but three of the five values it sets are consumed **only on the
   owning client**. In PIE (listen server) it would look fine; on our dedicated servers it
   would half-work. Mods riding this rail inherit the bug unless we fix it. (§7)

4. ✅ **O19 is resolved.** `Lyra.ShooterGame.Weapon.MagazineSize` is a real stat tag, set by
   `InventoryFragment_SetStats` on the item definition and read by the shared
   `GA_Weapon_ReloadMagazine` Blueprint. High-Capacity Mag is `AddStatTagStack`, which is
   already replicated and already server-authoritative. **Zero new code.** (§4)

5. ⚠️ **The equip path does not carry the item instance.** `EquipItem()` takes an
   *EquipmentDefinition*, so the weapon instance has to reach back through the QuickBar to
   find out which item it came from. The existing code says so in a comment. Mods have the
   same problem and must use the same workaround. (§3)

**Net effect on the mods proposal: it gets easier, not harder.** Three of the nine mods
need no new mechanism at all, and the mechanism for the rest is already written.

---

## 2. A weapon is nine assets (verified from `WID_MadRifle` / `ID_MadRifle`)

| Asset | Class | Role |
|---|---|---|
| `ID_MadRifle` | `LyraInventoryItemDefinition` | the **item**: ItemId, ItemCategory, Fragments |
| `WID_MadRifle` | **`LyraEquipmentDefinition`** | the **equippable side**: `InstanceType`, `AbilitySetsToGrant`, `ActorsToSpawn` |
| `B_WeaponInstance_MadRifle` | `BASRangedWeaponInstance` | the **runtime object**, spawned per equip. Holds `BulletsPerCartridge`, `MaxDamageRange`, `MaxTraceRange`, spread params, recoil curve, `MinMaxStatsDataAsset` |
| `B_MadRifle` | Actor | the mesh you see in hand |
| `AbilitySet_ShooterMadRifle` | `LyraAbilitySet` | grants Fire + Reload + AutoReload, each bound to an InputTag |
| `GA_Weapon_Fire_MadRifle_Auto` | GameplayAbility | firing |
| `GA_Weapon_Reload_MadRifle` | GameplayAbility | thin child of the shared `GA_Weapon_ReloadMagazine` |
| `GE_Damage_MadRifleAuto` | GameplayEffect | child of `GE_Damage_Basic_Instant`, uses `CustomizableDamageExecution` |
| `C_MouseRecoil_MadRifle`, widgets, pickup data | — | recoil curve, reticle, ammo counter |

**`ID_MadRifle` carries exactly six fragments** (verified):
`BarrackSlot`, `EquippableItem`, `PickupIcon`, `QuickBarIcon`, `ReticleConfig`, **`SetStats`**.

Note what is **absent**: weapons do **not** carry `InventoryFragment_GrantAdditionalAbilities`.
That fragment exists and is used **only by totems** (§8). So the "totem precedent" argument
in [[weapon-mods-approach]] is real, but it is a precedent from a *sibling* system, not
something weapons already do. Worth being precise with Marco about that.

---

## 3. The equip pipeline, end to end

```
input / loadout
   └─ ULyraQuickBarComponent::SetActiveSlotIndex_Implementation      QuickBar:139
        ├─ UnequipItemInSlot()                                       QuickBar:111
        └─ EquipItemInSlot()                                         QuickBar:86
             └─ EquipmentManager->EquipItem(EquipDef)                QuickBar:100
                  │   ⚠️ takes the EquipmentDefinition, NOT the item instance
                  ▼
        ULyraEquipmentManagerComponent::EquipItem              EquipMgr:86
             ├─ NewObject<ULyraEquipmentInstance>(...)          :86   ← FRESH OBJECT PER EQUIP
             ├─ for (AbilitySet : EquipmentCDO->AbilitySetsToGrant)
             │       AbilitySet->GiveToAbilitySystem(ASC, &Entry.GrantedHandles)  :91-95
             ├─ spawn ActorsToSpawn
             └─ Instance->OnEquipped()                          :47 / :158
                  └─ UBASRangedWeaponInstance::OnEquipped()     BASRWI:12
                       ├─ InitializeMouseRecoil()
                       └─ ApplyStats()                           ← §6
   ...
   on unequip:  Entry.GrantedHandles.TakeFromAbilitySystem(ASC)  EquipMgr:121
```

**Two properties that matter enormously for mods:**

- **The instance is created fresh on every equip** (`EquipMgr:86`). Any mutation applied in
  `OnEquipped` needs no undo, cannot leak to the next weapon, and cannot accumulate.
- **Everything granted at equip is removed at unequip** via the same `GrantedHandles`
  (`:91-95` grant, `:121` remove). A mod's abilities and effects get free lifecycle
  management if they go through the same channel.

⚠️ **The item-instance gap.** `EquipItem` receives only the EquipmentDefinition, so the
running weapon has no direct handle on the `ULyraInventoryItemInstance` it came from. The
existing code solves this by walking `Pawn → Controller → QuickBarComponent →
GetActiveSlotItem()`, with a comment that reads, verbatim:

> `// There is no other way to get the ItemInstance of this weapon except from the`
> `// QuickBarComponent because Lyra said "Fuck you".`
> — `BASRangedWeaponInstance.cpp:286`

Mods live on the item/loadout, so they hit exactly this wall. **Use the same workaround;
do not invent a second one.**

---

## 4. Ammo and magazine — O19 RESOLVED

**Where magazine size lives** (verified in `ID_MadRifle`): `InventoryFragment_SetStats`
carries a `TMap<GameplayTag,int32>` containing three tags:

```
Lyra.ShooterGame.Weapon.MagazineAmmo     current rounds in the mag
Lyra.ShooterGame.Weapon.MagazineSize     capacity          ← the one we need
Lyra.ShooterGame.Weapon.SpareAmmo        reserve
```

`UInventoryFragment_SetStats::OnInstanceCreated` writes these into the item instance's
`StatTags` at creation (`InventoryFragment_SetStats.cpp:9`).

**Who reads it** (verified in `GA_Weapon_ReloadMagazine`, the shared parent of every
weapon's reload ability): the Blueprint reads `GetStatTagStackCount(MagazineSize)`,
compares against `MagazineAmmo` ("Got room in magazine?"), checks `SpareAmmo` ("got any
spare ammo?"), computes `NumToAddToMagazine`, then `AddStatTagStack` / `RemoveStatTagStack`.
Fail tags `Ability.ActivateFail.MagazineFull` and `.NoSpareAmmo` are present.

> ⚠️ Note `MagazineSize` is **not** declared in C++ (`Tags/TagDefinitions.cpp` declares only
> `MagazineAmmo` and `SpareAmmo`). It is a project-config tag used purely from Blueprint.
> Don't go looking for it in the C++ tag list and conclude it doesn't exist.

**Therefore High-Capacity Mag** = add stacks to `MagazineSize` on the item instance.
`AddStatTagStack` is `BlueprintCallable, BlueprintAuthorityOnly`, and `StatTags` is a
`UPROPERTY(Replicated)` on `ULyraInventoryItemInstance`. Server-authoritative and
replicated for free. **This mod needs no C++ and no new asset type.**

---

## 5. The damage pipeline — and the multiplier nobody mentioned

`GE_Damage_MadRifleAuto` is a Blueprint child of `GE_Damage_Basic_Instant` and runs
**`CustomizableDamageExecution`**, not stock `LyraDamageExecution`.

```
UCustomizableDamageExecution::Execute_Implementation                CustomizableDamageExecution.cpp:7
   ├─ Super::Execute_Implementation(...)          // = LyraDamageExecution
   │     DamageDone = BaseDamage
   │                × DistanceAttenuation         // BASRangedWeaponInstance falloff curve
   │                × PhysicalMaterialAttenuation
   │                × TeamDamageAllowed           LyraDamageExecution.cpp:130
   └─ FWeaponCustomizableExecutionLibrary::ApplyPowerMultiplierToOutExecutionOutput(...)
            for (Modifier : OutExecutionOutput.GetOutputModifiersRef())
                 Modifier.Magnitude *= WeaponInstance->GetPowerMultiplier();     WCEL.cpp:23
```

So the real formula is:

```
DamageDone = BaseDamage × DistanceAtten × PhysMatAtten × TeamMul × PowerMultiplier
                                                                   ^^^^^^^^^^^^^^^
                                                        per weapon INSTANCE, default 1.0
```

`PowerMultiplier` is a plain float on `ULyraWeaponInstance` (`:111`) with a public setter
(`SetPowerMultiplier`, `:45`). The same library is applied by **`CustomizableHealExecution`**
and **`CustomizableCustomPowerExecution`**, so it scales healing and utility power too.

> **Correction to [[weapon-mods-approach]]**: that doc says High Damage Rounds is "one
> Gameplay Effect multiplying the BaseDamage attribute". That would work, but it is not the
> right answer. `PowerMultiplier` is **per weapon instance**, so it cannot bleed onto your
> other weapons, whereas a GE on the player's `BaseDamage` attribute would need tag
> conditions to stay scoped. Use `PowerMultiplier`. The pitch doc should be updated.

Designed range, from `UMinMaxWeaponsStatsDataAsset` defaults: **Power 0.5 → 2.0**,
Accuracy 0.5 → 2.0, Handling 0.5 → 1.0, DistanceDamageFalloff 0.5 → (max). A ×1.5 damage
mod sits inside a range the previous team already considered normal.

---

## 6. 🔴 The dormant tuning system (the biggest finding)

There is a complete, ItemId-keyed, per-player, equip-time weapon-stat pipeline in the
codebase. It is fully wired. **It does nothing, because its data source is never populated.**

```
ABASPlayerState::WeaponsStatsSettings                      BASPlayerState.h:97
      = FAllBASRangedWeaponsStatsSettings
            TArray<FBASRangedWeaponStatsSettings> WeaponsStats     ← NEVER WRITTEN. EVER.
                     │
   UBASRangedWeaponInstance::OnEquipped()                  BASRangedWeaponInstance.cpp:12
        └─ ApplyStats()                                     :264
             ├─ if (!Pawn->HasAuthority()) return;          :272   ← see §7
             ├─ PlayerState  = Pawn->GetPlayerState<ABASPlayerState>()
             ├─ QuickBar     = Controller->FindComponentByClass<ULyraQuickBarComponent>()
             └─ PlayerState->WeaponsStatsSettings.ApplyStats(QuickBar->GetActiveSlotItem(), this)
                     └─ for each FBASRangedWeaponStatsSettings:
                            TryApplyStats(itemInstance, weaponInstance)
                                 ├─ IsSameId(item)                  ← matches on uint8 ItemId
                                 ├─ read MinMaxStatsDataAsset off the weapon
                                 └─ interpolate 4 alphas → 4 coefficients → apply:
                                        SetPowerMultiplier(power)
                                        SetSpreadMultiplier(spread)
                                        SetMouseRecoilCurveValueMultiplier(cur * spread)
                                        SetSpeedMultiplier(handling)
                                        SetDistanceDamageFalloffCoefficient(falloff)
```

**What this is**: the Game Bible's **weapon tuning** feature (the Damage↔Accuracy and
Handling↔Range sliders, and the Tuning Table UI that exists in the Barracks). Someone built
the entire runtime half and never connected a backend.

**Why it matters for mods**: this is the same job. A mod needs to say "when this weapon is
equipped, change these numbers", keyed by which weapon, sourced from player data. That is
precisely `FBASRangedWeaponStatsSettings`, down to keying on the **uint8 ItemId** that
`playervault` already uses.

**Design consequence — composition, not replacement.** `TryApplyStats` calls `SetPowerMultiplier`
(assignment). If tuning and mods both assign, the second wins silently. The mod pass must
**multiply into** the value tuning produced, and mods must run **after** tuning:

```
OnEquipped:
    ApplyStats()          // tuning: SETS the baseline coefficients
    ApplyMods()           // mods:   MULTIPLY into them
```

Note `SetMouseRecoilCurveValueMultiplier(Current * SpreadCoefficient)` already multiplies
rather than assigns, so it is order-sensitive in the other direction. Whoever implements
this needs to be deliberate about it, and it should be commented.

---

## 6b. Archaeology: where it came from and exactly when it died

All of it is **Bevium-era**, and almost all of it is one developer: **`Driver2579`**
(950 commits, 2024-05-07 → 2025-07-31). Bevium's contract ended January 2026.

| Date | Author | What |
|---|---|---|
| 2023-06-12 | ElTraktor | `InventoryFragment_SetStats` arrives with the initial Lyra import |
| **2024-10-07** | SabrinaPizzo | **`UTuningTableModSlotButton`** created — an empty stub (§6c) |
| 2024-11-14 | Driver2579 | `CustomizableDamageExecution` — *"Implemented dynamic damage/heal change depending on weapon stats **(untested yet)**"* |
| 2024-11-15 | Driver2579 | `MinMaxWeaponsStatsDataAsset` + *"added **temporary** weapons stats settings to be applied in the character at the start of the game"* — the populator lived on `PlayingCharacter` |
| 2024-11-27 | Driver2579 | range/distance parameter, geometric interpolation |
| **2024-11-28** | Driver2579 | *"Fix: Weapons' stats are being applied only at the very start of the game and only to the selected weapon. After reselecting the weapon, the stats are reset."* → moved `WeaponsStatsSettings` to `ABASPlayerState` as `UPROPERTY(EditDefaultsOnly, Category="Weapons")` with `// TODO: Remove UPROPERTY`, and added `B_BASPlayerState.uasset` |
| 2024-12-19 | Driver2579 | `UBASRangedWeaponsStatsSubsystem` (the stat-query layer the Tuning Table UI uses) |
| **2025-01-31** | Driver2579 | `af4691a18` *"Implemented the way to set up the default value for the handling"* — **removes the `UPROPERTY`**, per its own TODO |
| 2025-02-03 → 03-06 | Driver2579 | `BASWeaponsStatsRanges`, Heal / CustomPower / **Blind** executions, `WeaponCustomizableExecutionLibrary` |
| 2025-06-27 | Driver2579 | `InventoryFragment_GrantAdditionalAbilities` — the totem composition pattern (§8) |
| 2025-07-31 | Driver2579 | last commit on the project |

**This system was alive and being debugged.** The 2024-11-28 commit is a *bug fix* for stats
resetting when you re-equip — you only write that if you are watching it happen in game.

**It died on 2025-01-31, and it died by cleanup, not by decision.** The
`UPROPERTY(EditDefaultsOnly)` on `ABASPlayerState::WeaponsStatsSettings` was the **only way
data ever got into the array** — a designer typed alphas into the `B_BASPlayerState`
Blueprint defaults. `af4691a18` removed it to satisfy the `// TODO: Remove UPROPERTY`,
intending the real data source (per-player tuning from the backend) to replace it. That
replacement was never built, and Bevium's contract ended eleven months later.

Since 2025-01-31 the array has been permanently empty. Everything downstream of it has
been running and doing nothing, in every build we have shipped.

## 6c. The previous team specified our design, in a comment

`UTuningTableModSlotButton` (SabrinaPizzo, Oct 2024) is an empty class. Its entire body is
two commented-out declarations:

```cpp
// Call SetItem function to set the image and use the set mod to store the mod struct,
// probably FMod or FWeaponMod
// void SetModItem();

// override the on clicked function to set the active mod of the weapon, broadcast an
// event or call something in the subsystem to save it
// virtual void NativeOnClicked() override;
```

A **mod struct** (`FWeaponMod`), **stored per weapon**, **selected from the Tuning Table**,
**saved through a subsystem**. That is the design in [[weapon-mods-approach]], written down
by the previous team two years ago, before we ever looked at this.

The Tuning Table already has the whole widget family: `TuningTable`,
`TuningTableActiveWeapon`, `TuningTableAttributesSlider`, **`TuningTableModSlotButton`**,
`TuningTableWeaponMasterTaskLine`, `TuningTableWeaponMasterTasks` (the Bible's weapon
mastery trials). `TuningTableActiveWeapon.cpp:31` currently feeds the stat display a
**default-constructed** `FBASRangedWeaponStatsSettings` with only `ItemId` set — so the UI
shows every weapon's baseline numbers, because there is no player data to show instead.

---

## 7. 🔴 The dedicated-server bug this pipeline is carrying

`ApplyStats()` returns early unless the pawn has authority (`BASRangedWeaponInstance.cpp:272`).
But look at where each of the five values is actually consumed:

| Value it sets | Consumed by | Runs on | Server-only OK? |
|---|---|---|---|
| `PowerMultiplier` | damage/heal executions | **server** (`#if WITH_SERVER_CODE`) | ✅ yes |
| `DistanceDamageFalloffCoefficient` | damage falloff curve | **server** | ✅ yes |
| `SpreadMultiplier` | `GetCalculatedSpreadAngle()` in the bullet trace, `LyraGameplayAbility_RangedWeapon.cpp:394` — inside the `AvatarPawn->IsLocallyControlled()` block at `:360` | **owning client** | ❌ **no** |
| `MouseRecoilCurveValueMultiplier` | camera recoil | **owning client** | ❌ **no** |
| `SpeedMultiplier` | `UWeaponSpeedGameplayModMagnitudeCalculation` → movement GE, client-predicted | **both** | ❌ **no** |

On a **listen server or PIE**, the local player is authority, so everything applies and it
looks correct. On a **dedicated server** — which is what Edgegap runs — the owning client
never executes `ApplyStats`, so it traces with unmodified spread, feels unmodified recoil,
and predicts unmodified movement speed while the server disagrees.

This is the exact failure shape CLAUDE.md already warns about: *"Dedicated-server: server-only
code doesn't reach clients. Listen-server (PIE) masks this."*

It has never been observed **because the settings array is empty**, so the code has never
done anything. Any mods implementation that reuses this path inherits the bug.

**The fix is cheap and does not need replication.** The mod and tuning selections are part
of the loadout, which the **client already has** (it built it in the Barracks and the server
validated it). So both sides can compute the same result from the same data:

- Drop the `HasAuthority` early-return; run the pass on server **and** owning client.
- Keep the server authoritative for *validation* (is this mod owned, is it legal for this
  slot) — that is already enforced by `validate_loadout` in the DB and can be re-checked
  server-side at match start.
- Simulated proxies do not need it: they neither trace nor predict movement.

`BulletsPerCartridge` (Double Tap) sits in the same client-side block at `:390`, so it has
the same requirement. This is the single most important correctness detail in the whole
mods feature.

---

## 8. The totem precedent, stated accurately

`UBASAbilitySet::GiveToAbilitySystem` (`BASAbilitySet.cpp:60-104`) takes the player's chosen
totem item definitions, and for each one iterates `AbilityToGrant.GetDefaultObject()->Fragments`
looking for `UInventoryFragment_GrantAdditionalAbilities`; when found it calls
`AbilitySet->GiveToAbilitySystem(LyraASC, OutGrantedHandles, SourceObject)`.

So the pattern "player-chosen item → read a fragment off its definition → grant its
AbilitySet into the shared handles" **is running in the shipped game today**. That is a
genuine precedent and it is the right one to cite.

Be precise with Marco though: it is used **for totems only**. Weapons do not carry that
fragment (§2). We would be extending an existing pattern to a second slot, not switching on
something weapons already do.

---

## 9. Revised mechanism per mod, with confidence

| Mod | Mechanism | New code? | Confidence |
|---|---|---|---|
| **High Damage Rounds** | `SetPowerMultiplier(current × 1.5)` in the mod pass | none beyond the pass | ✅ **verified** — pipeline read end to end |
| **High Capacity Mag** | `AddStatTagStack(MagazineSize, n)` on the item instance | none | ✅ **verified** — reload BP read |
| **Double Tap** | `BulletsPerCartridge *= 2` on the instance, **applied client-side too** (§7) | tiny | ✅ **verified** — read at `RangedWeapon:390` |
| **Lucky Strike / Berserk Boost / Resourceful** (Luck / Agility / Intelligence ×1.5) | GameplayEffect with a Multiply modifier, granted via the mod's AbilitySet at equip | none (data) | ⚠️ **high confidence, one check** — these are real Attributes on `ULyraCombatSet`, but champion stats are applied as *ability levels* into curve tables (`AddBASBaseStatsAbilities`), so a multiplier's interaction with the curve needs a look |
| **Fire Rounds** | damage-over-time GE + on-hit application | per-mod BP | ⚠️ design work; `CustomizableCustomPowerExecution` may already be the intended home |
| **Healing Rounds** | `CustomizableHealExecution` already exists and already honours `PowerMultiplier` | per-mod BP | ⚠️ needs a look at what already exists |
| **Demolition Rounds** | damage vs structures | per-mod BP | ⚠️ needs a structure-damage concept; may not exist |

The three "utility round" mods map suspiciously well onto the three `Customizable*Execution`
classes that already exist (`Damage`, `Heal`, `CustomPower`) plus `CustomizableBlindExecution`.
**Someone started building the utility-round system.** Worth an hour to find out how far it got
before designing these three from scratch.

---

## 9b. ✅ Confirmed in the editor, 2026-08-12 (Marco + Dan, live VM)

Screenshots of `ID_Rifle`, `B_WeaponInstance_Rifle`, `B_BASPlayerState`,
`DA_MinMaxWeaponsStatsSettings` and `GE_Damage_RifleAuto`, plus a sweep of every
`B_WeaponInstance_*` asset. **U1 to U4 are closed.**

| # | Question | Answer |
|---|---|---|
| **U1** | `ItemId` on the weapon assets | **`ID_Rifle` = 103, Category = Primary Weapon.** Matches the Asset Identifiers sheet (103 = MELONRIFLE) exactly. Assets and design sheet agree, so mods can key on ItemId with confidence |
| **U2** | `DA_MinMaxWeaponsStatsSettings` coefficients | **All four stats 0.5 → 2.0** (Power, Accuracy, Handling, DistanceDamageFalloff). A ×1.5 damage mod is inside range; ×2.0 is the ceiling |
| **U3** | Rifle ammo values | `MagazineSize 60`, `MagazineAmmo 60`, `SpareAmmo 120` |
| **U4** | Is `MinMaxStatsDataAsset` filled in? | ✅ **All 22 weapon instances reference `DA_MinMaxWeaponsStatsSettings`.** `B_BASRangedWeaponInstance_Base` does **not** set it, so it is authored per weapon, and every weapon has it. **No gaps, the dormant pipeline would work on every weapon in the game** |
| — | `B_BASPlayerState` Class Defaults | **No `Weapons Stats Settings` field.** Confirms `af4691a18` removed the `UPROPERTY`. The dormant pipeline is **not** testable without putting that one line back |
| — | `B_WeaponInstance_Rifle` | `BulletsPerCartridge = 1`, `MaxDamageRange = MaxTraceRange = 15000cm`, `FireDelay = 0.12s`, `BulletTraceSweepRadius = 5.5cm`, WeakSpot material multiplier `1.5` |
| — | `GE_Damage_RifleAuto` | Parent `GE_Damage_Basic_Instant`, Duration `Instant`, **Modifiers array EMPTY**, one Execution = `CustomizableDamageExecution` ✅ |

### 🔴 9c. The damage number is a SCOPED modifier, which kills the GE approach outright

`GE_Damage_RifleAuto` has **zero entries in its `Modifiers` array**. The damage lives in the
Execution's **Calculation Modifiers**:

```
Backing Data:  Captured Attribute = BaseDamage, Source = Source, Status = Snapshotted
Modifier Op:   Add (Base)
Magnitude:     Scalable Float = 15.0          ← the Rifle's damage
```

So the weapon's damage is added **into the captured aggregator, inside the execution**, after
capture. The player's own `BaseDamage` attribute contributes essentially nothing.

**Consequence**: a GameplayEffect that multiplies the player's `BaseDamage` *attribute* would
multiply ~0 and change nothing. It would look correct in the editor and silently do nothing in
game. **`PowerMultiplier` is the only working lever for weapon damage**, which retro-justifies
the §5 correction rather than merely preferring it.

(15.0 also matches the design sheet's WeaponStats tab for MelonRifle, so the numbers in that
spreadsheet are live values, not aspirations.)

### ⚠️ 9d. Handling max is 2.0, and the code says it should not be

`UMinMaxWeaponsStatsDataAsset` defaults `HandlingMaxCoefficient` to **1**, with the comment
*"Best to not set the maximum more than 1 because it would make the player faster with the
weapon than without it."* The live asset sets it to **2.0**. So a handling-based tune or mod
can currently make a player move faster carrying a weapon than unarmed. Worth a decision
before any mod touches handling.

---

## 10. What is still unknown (needs the editor)

Structure came out of the assets; **numbers did not**. These need someone in the editor:

| # | Unknown | Why it matters |
|---|---|---|
| ~~U1~~ | ✅ **CLOSED 2026-08-12** — `ID_Rifle` = 103, matches the design sheet (§9b) | |
| ~~U2~~ | ✅ **CLOSED** — all four stats 0.5 → 2.0 (§9b) | |
| U3 | Per-weapon `MagazineSize` values | Rifle = 60/60/120 confirmed; still need the other primaries to pick a sane multiplier |
| ~~U4~~ | ✅ **CLOSED** — all 22 weapon instances have it set (§9b) | |
| U5 | `DT_AllVaultItems` ItemId ↔ ItemDefinition rows | Still the ID bridge gap from [[barracks-vault-flow]] |
| U6 | `DT_PlayerProgressionItems` `ItemCollectLevel` per row | Unlock levels for the spec |
| U7 | How far the utility-round executions actually got | Could save or add days on Fire/Healing/Demolition |
| U8 | Whether champion-stat multipliers compose with the curve-table ability levels | Decides if the three melee mods are really "free" |

**U1 to U4 are all readable in about 30 minutes with the editor open**, and the VM is up
right now. U7 is the one with real schedule impact.

---

## 11. Marco's likely objections, answered

**"This is a new system we'd have to build and maintain."**
Most of it exists. The equip-time stat pass is written (§6), the damage multiplier is written
and wired (§5), the ammo tags are written and replicated (§4), and the fragment-driven
ability grant is running in production for totems (§8). What is missing is a data source
and a ~50-line pass that walks it.

**"189 weapons is dumb but at least it's simple and I can see the values in the editor."**
Fair, and it is the real trade. But the tuning system already decided this argument: it
modifies weapon values at runtime from player data rather than authoring variants, because
the Bible's tuning sliders make variants combinatorially impossible (4 continuous sliders,
not 9 discrete mods). Mods are the *easier* version of a problem the project already
committed to solving this way.

**"Will designers still be able to tune it?"**
Better than with variants. Each mod is one asset with four numbers and an optional
AbilitySet. Changing Double Tap is one file instead of 21, and the mod's effect is visible
in one place instead of smeared across every weapon that has a variant.

**"What about networking?"**
This is the one real risk, and it is documented in §7 — but note it is a bug the codebase
**already has** in the dormant tuning path. Mods force us to fix it, which is a benefit, not
a cost. The fix does not require new replication because the loadout is already on both
sides.

**"Two mods on one weapon will break."**
One slot per weapon is already decided (D15), so this is out of scope. But the composition
rule in §6 (multiply, never assign, mods after tuning) means N mods would work if we ever
want it.

---

## 12. Recommended next steps

1. **30 minutes in the editor on the live VM** to close U1 to U4. Cheap, and it turns the
   remaining assumptions into facts.
2. **One hour on U7** — find out how much of the utility-round system exists. This is the
   only unknown that can move the schedule.
3. **Prototype on one weapon, one mod.** Populate `WeaponsStatsSettings` by hand for the
   MadRifle with `PowerAlpha = 1.0` and confirm the damage actually doubles on a dedicated
   server. That single test validates §5, §6 and §7 at once, and it is the honest way to
   settle the disagreement: **if the dormant pipeline works when fed, the mods design is
   proven; if it does not, we learn exactly why before committing.**
4. Only then author `UBASWeaponModDefinition` and the nine mod assets.
5. Update [[weapon-mods-approach]] with the `PowerMultiplier` correction from §5.

Step 3 is the one that should settle it with Marco. It is a few hours, touches nothing
permanent, and produces a yes or no.
