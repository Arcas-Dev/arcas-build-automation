# Progression System — Live Code Audit (2026-07-09)

**Branch audited:** `deploy/steam-testing` @ `b0dcbfb69`. Method: 5 parallel read-only agents over the C++ source + binary-asset string extracts (pulled off the build VM) + existing KB docs. **No code changed.** Companion to the *plan* in [[progression-system-plan]] — this doc is the *as-is* reality against that target.

---

## Headline

**There is no working progression system. There are three disconnected islands:**

1. **A client-side XP engine** (`UExperiencePointSubsystem`) that is **dead code** — zero callers anywhere in C++ or Content, fed only by a randomised mock, editor-only.
2. **A progression UI shell** (`W_PlayerProgression` + slot + level-up popup) that **renders** a reward track from a real DataTable but whose every live-data hook — player level, collected-state, granting the item — is a hardcoded constant or a `// TODO`.
3. **A backend/DB with no progression at all** — no XP/level/currency/unlocks tables; the only durable progression-ish value is `playerrank.rank` (int, default 2500, flat ±25/match).

The data to render "unlocks at level N" exists. The wiring to know *your* level, remember what you collected, and grant it is unbuilt at every joint. **[[progression-system-plan]] remains the accurate build target — nothing from its Phases 1–4 is done**; the only thing that now exists beyond that plan's snapshot is this client UI shell + mock XP subsystem.

---

## Branches: nothing to merge

All progression work is already on `deploy/steam-testing`. The three old XP branches — `xp-component`, `exp-rework`, `ExperiencePoints-rework` (all 2024) — are **0 commits ahead**: fully merged, stale, safe to delete. No other branch carries unmerged progression content. The relevant commits on the active branch: `Progression Frontend Initial Setup`, `Weapon Vault Integration + ID tweak for Database`, `Mad Rifle First setup + integration with vault`.

---

## The four subsystems

### 1. XP / levelling — `UExperiencePointSubsystem` (dead-code mock)

`Source/LyraGame/Subsystems/ExperiencePointSubsystem.{h,cpp}` — a `ULocalPlayerSubsystem`.

- **Nothing awards XP.** `grep GainExperience|AddExperience|AddXP` = 0 matches. XP is set exactly once, in `Initialize()→RetrieveExpInfo()` (`:39-47`), and **only in the mock path**.
- **Editor-only.** `IsMockBackendEnabled()` (`BlockApeScissorsSettings.cpp:94-99`) = `bUseMockBackend` `#if WITH_EDITOR` **else `false`**. → in cooked (Steam/Edgegap) builds `RetrieveExpInfo()` is a no-op; `LevelMap` stays empty, **XP=0 / Level=0 forever**. In-editor, XP is a fresh `FMath::RandRange` each session — set once, never incremented.
- **Curve** is formula-generated into a `TMap`, not an asset: cumulative XP for level L = `round(L^1.1) × 1000`, 30 levels (`MockBackend.cpp:196-210`). Hardcoded; no designer config. `GetExperienceForNextLevel()` hits `ensureAlwaysMsgf(false)` at max level (`:120`).
- **Not networked, not persisted.** LocalPlayerSubsystem, no `Replicated`/`OnRep`/RPC. No backend GET for XP exists. No XP/level column in Cloud SQL.
- **Zero consumers.** Nothing subscribes to `OnExperiencePointsChanged`; nothing calls the getters. `AddLevel()` (`:74`) is dead code, never called.
- **Base-class oddity:** `.h:4` includes `GameInstanceSubsystem.h` but the class derives `ULocalPlayerSubsystem` (`.h:12`) — compiles via transitive include, but a smell from an un-cleaned refactor; matters for per-account lifetime when wiring the real thing.

**Match-end is RANK, not XP** (naming trap #2): `BASGameMode.cpp:757-765` `EndDedicatedServerMatch()` → if `"ranked"` → `SendRankedMatchResults()` (`:889`) → `POST_RankedMatchResults`. Payload `FRankedMatchResults` = only `Win`/`Loss` int32 player-id arrays; server applies flat ±25 rank. **No XP is transmitted or awarded.**

### 2. The DataTable — `DT_PlayerProgressionItems` (real content, no logic)

Row struct **`FPlayerProgressionItem`** (`UI/Common/CommonUIStructs.h:252-268`): `int32 ItemCollectLevel` + an embedded `FVaultSlotItem Item` (`:17-58` — `ItemID: TSubclassOf<ULyraInventoryItemDefinition>`, `ItemCategory: EUserCombatBarrackType`, `Icon`, `Background`, `Description`, `VideoPreview`, `Video`, `bShouldBeSelectedFromVault`). A row = "at player-level N, this item becomes collectable."

- **Data is real & production-grade:** 25 genuine item references — 18 weapons + 7 totems — with correct categories, real ability descriptions, real icons + synergy-spectrum preview videos. A curated subset of `DT_AllVaultItems` (excludes base kit: Pistol, Shotgun, CombatKnife, Unarmed*, and totems AutoTurret/Grenade/PersonalHealing). No currency/XP-amount/skin/champion rows.
- **No ID bridge to the backend.** Progression identifies items by **BP class identity** (`ID_Rage_C`), while the vault/`playervault`/`GET_Vault` track ownership by **offset-macro `uint8`** (101…601). Nothing maps between them. A "collect" cannot become a backend grant without new code.
- **Consumer:** `UPlayerProgressionWidget` (`ItemsDataTable` UPROPERTY set by BP to this table) → `CreateSlots()` iterates rows → one slot each.
- **Manual curation risk:** new vault weapons (e.g. MadRifle) don't auto-appear in progression — two tables to hand-sync.

### 3. The UI — cosmetic shell on placeholder data

```
W_PlayerProgression  (UPlayerProgressionWidget : ULyraActivatableWidget)
  └ ItemsScrollBox → W_PlayerProgressionSlot  (UPlayerProgressionSlotWidget : UCommonButtonBase)  per row
W_NewLevelUnlockedMessage  (sibling popup — PURE BLUEPRINT, no C++ class)
```

- **Entry:** `UTopBar::OnAccountClicked()` (`TopBar.cpp:70-90`) pushes `W_PlayerProgression`. Opens from the Barracks top-bar account button.
- **Container** reads the static DataTable only — no subsystem, no backend, no player state.
- **Slot** renders icon (async-loaded into a dynamic material param), a `LevelNumber` badge, and four authored anims (`OnAlreadyCollected/OnReadyToCollect/OnNotAvailable/OnCollect`). Click early-returns unless `bCanBeCollected` — a bool **never set true**.
- **Level-up popup** (`W_NewLevelUnlockedMessage`) is all-Blueprint: "NEW LEVEL UNLOCKED! — Check the Barracks", plays `sfx_NewLevelReached`, previews the unlocked item from `DT_PlayerProgressionItems`, holds a BP var `CurrentPlayerLevel_Temp`. **No C++ spawns or broadcasts it** — the gameplay→popup link does not exist.
- **`MI_UI_PlayerProgressionBarBG`** is static decoration — no live fill scalar. **`M_UI_RadialProgress` does not exist** in the repo (grep = 0).
- **`ULyraSettingScreenOnBarracks`** is the account panel — it shows `PLAYER ID: <n>` (`GetBASPlayerID()`), **not a level**. There is no "current player level" getter anywhere in the codebase.

### 4. GET_Vault — owned IDs fetched then discarded (unchanged, re-verified)

The [[barracks-vault-flow]] finding **still holds line-for-line** on this branch. `GET_Vault` (`GetVaultRequest.cpp`) parses `FVaultData` (`VaultData.h:5-30`): six `TArray<uint8>` owned-ID lists (weapons ×3, totems ×3) + `Champions`. In the success branch (`Vault.cpp:101-108`) **only `AddChampionsSlots(Champions)` runs**; the weapon/totem arrays are never read, and `AddWeaponSlots`/`AddTotemSlots` **do not exist** — they are the commented `// TODO: AddWeaponSlots and AddTotemSlots ez.` at `Vault.cpp:103`. The Vault UI shows the **local** `DT_AllVaultItems`, filtered only by `bShouldBeSelectedFromVault` → **everyone sees every item regardless of ownership.** The offset-macro scheme (`LoadoutDAO.h:7-25`, self-flagged "Remove this macro-based worflow crap") drives random loadout generation, not a real registry. (Also stubbed nearby: a commented consumable/economy block in `Barracks.cpp::ItemSelected`.)

---

## The seam for gameplay-unlocks

Both ends exist; the middle is missing at every joint.

| Joint | State | Where it goes |
|---|---|---|
| Read the player's real level | ❌ hardcoded `1` | `PlayerProgressionSlotWidget.cpp:22` |
| Know what's already collected | ❌ no source, no table | `PlayerProgressionSlotWidget.cpp:30` (+ needs a `playerunlocks` table) |
| Grant the item on collect | ❌ empty `OnSlotClicked` | `PlayerProgressionWidget.cpp:43-44` |
| Enforce ownership in the loadout UI | ❌ owned IDs discarded | `Vault.cpp:103-108` — **highest-leverage single edit** |
| Map ItemDefinition class ↔ backend offset-ID | ❌ doesn't exist | new code |
| Award XP / persist level | ❌ nothing awards, nothing persists | enrich `POST_RankedMatchResults` server-side + new `GET_Progression` + `playerprogression` table |

**Recommended first move** (per agents 1 & 5): implement the discarded `AddWeaponSlots`/`AddTotemSlots` at `Vault.cpp:103` — filter `DT_AllVaultItems` by the player's already-arriving owned IDs. It converts "everyone sees everything" into "you see what you've unlocked" with data that already flows to the client, and is the prerequisite for any level-gating to bite.

---

## Two naming traps (both confirmed, both live)

1. **"Experience"** — `UExperiencePointSubsystem` (player XP) vs `ULyraExperienceDefinition`/`CurrentExperience`/`FExperienceMap`/`FExperienceGameMode`/`...OnExperienceLoaded` (Lyra **game-mode** framework — what you're playing). They even share a header: `CommonUIStructs.h:97/112` (game-mode) vs `:252` (XP reward). `PlayerInfoComponent.cpp:371 InitializeAbilitiesOnExperienceLoaded` is game-mode load, **not** XP. Rule: player-XP = only `ExperiencePointSubsystem` + `PlayerProgression*` + `FPlayerProgressionItem`. When building the real backend, name things `...ExperiencePoints...`/`...Progression...`, never bare `...Experience...`.
2. **"Level"** — `GetLevel()` = player rank/level number, unrelated to `ULevel`/maps.

---

## Verbatim TODOs (the un-plumbed joints)

- `PlayerProgressionWidget.cpp:35` — `// TODO: only if it is ready to collect`
- `PlayerProgressionWidget.cpp:43-44` — `// TODO : ... mark the item collected` / `// TODO : and actually add it to the player vault`
- `PlayerProgressionSlotWidget.cpp:22` — `// TODO: Get actual player level` (`constexpr int32 PlayerLevel = 1;`)
- `PlayerProgressionSlotWidget.cpp:30` — `// TODO : where we can take if the slot has already been collected?`
- `PlayerAccountWidget.cpp:16` — `// TODO : Set Player Level and XP on Slider`
- `PlayerInfoComponent.cpp:250` — `// TODO: send set loadout request;`
- `Vault.cpp:103` — `// TODO: AddWeaponSlots and AddTotemSlots ez.`
- `LoadoutDAO.h:7` — `// TODO: Remove this macro-based worflow crap ...`

---

## What's BUILT vs STUB (summary)

| Piece | Status |
|---|---|
| XP math (curve, CalculateLevel, xp-to-next) | pure functions correct, but no real data & zero consumers |
| XP data source / persistence / networking | **absent** (mock, editor-only, transient) |
| `DT_PlayerProgressionItems` content | **real** (25 items, level→item) |
| Progression UI rendering | **built** (list, slot, async icon, anims, menu routing) |
| Progression UI live-data hooks | **all TODO** (level, collected, grant) |
| Level-up popup art/sfx | **built** (BP) — but **not triggered** by any C++ |
| GET_Vault request + champions→UI | **built** |
| GET_Vault weapon/totem ownership | **discarded** (`Vault.cpp:103`) |
| DB progression tables | **none** (only `playerrank.rank`) |
| Backend progression endpoints | **none** |

**Bottom line:** the front half of progression (content + UI shell) is scaffolded and reusable; the entire back half (award → persist → own → gate → grant) is unbuilt, and the two halves don't reference each other. Build per [[progression-system-plan]]; start at the `Vault.cpp:103` ownership seam.
