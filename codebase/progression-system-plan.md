# Arcas Champions — Progression System Plan

**Created**: 2026-06-24
**Status**: Planning / pre-build
**Scope decisions (locked with Dan, 2026-06-24)**:
1. **Account-level progression first** — player XP, level, currency, rewards keyed to `playerid`. Champion-level progression is a later phase.
2. **Gameplay unlocks** — shrink the starter kit; players earn weapons/totems by leveling. (Changes the current "everyone gets everything at registration" model.)
3. **Off-chain now** — all state in Cloud SQL Postgres. Rank/MMR designed so it *can* be mirrored on-chain later for SkillStaking RWA. No smart contracts this quarter.

> This doc has three parts: **(A) Current state** (DB + API + UE5 touchpoints), **(B) Target design**, **(C) Phased build plan** mapped to the Q3/Q4 gameplan. Plus open decisions and the outstanding VM-verification pass.

---

# PART A — Current State Overview

## A.1 Database (`game-backend-db`, Cloud SQL Postgres 16)

Full schema: `database-structure.md`. Five tables today, all keyed off `playerprofile.playerid`:

| Table | Progression relevance |
|-------|----------------------|
| `playerprofile` | Identity (auth, wallet, username, steamid, `tutorialcomplete`). No progression fields. |
| `champions` | Per-champion RPG stats (health/strength/intelligence/agility/luck 4–12), gender, skin, name. **Fixed stats, not leveled.** NFT-like. |
| `playervault` | Owned weapon/totem ID arrays by category. **Granted in full at registration** (see bootstrap below). |
| `playerloadouts` | 5 loadout slots (JSONB), validated against vault + champion ownership. |
| `playerrank` | Single `rank INT`, default **2500**. That's the entire MMR system. |

**New-player bootstrap** (DB trigger `initialize_player_associations()`, fires `AFTER INSERT` on `playerprofile`):
- Inserts `playervault` with **all default items**: weapons `[101-105]`, `[201-204]`, `[301-302]`; totems `[401-403]`, `[501-504]`, `[601-603]`.
- Inserts empty `playerloadouts`.
- Inserts `playerrank` = 2500.

→ **This is the function we rewrite for gameplay unlocks** (small starter kit instead of everything).

## A.2 API (`ArcasChampionsAPI/server.js`, 1931 lines, Node/Express on Cloud Run)

**20 endpoints.** Auth: client endpoints use `x-authorization` + `auth-type` headers → `verifyAuth()` (Steam/Epic). Server endpoints use a hardcoded bearer token. `TABLE_PREFIX` env (`''` prod / `'Test'` test) switches table sets.

| Endpoint | Method | Progression-relevant? |
|----------|--------|----------------------|
| `GET_CheckService` | GET | — |
| `GET_Profile` | GET | ✅ returns rank (⚠️ **only for hardcoded tester IDs** — bug) |
| `GET_Vault` | GET | ✅ owned items (unlock surface) |
| `GET_Loadouts` / `GET_LoadoutByIndex` / `GET_PlayerLoadouts` | GET | indirect (uses vault) |
| `GET_UnpackedChampions` | GET | champion data |
| `POST_SetLoadout` / `POST_SetLoadouts` | POST | uses vault validation |
| `POST_ValidatePlayerLoadout` | POST | vault ownership check |
| `POST_CompleteTutorial` | POST | onboarding flag |
| `POST_UnpackChampion` | POST | champion naming |
| `GET_MatchmakerCredentials` | GET | matchmaking (⚠️ dead `default:` route — see audit doc) |
| **`POST_RankedMatchResults`** | POST | ✅ **the only rank mutation** |
| `GET_SteamData` | GET | Steam profile |
| `POST_DevResetTutorial` | POST | dev tool |
| `ADMIN_*` (4) | mixed | test infra mgmt |

**`POST_RankedMatchResults` — the critical existing endpoint** (`server.js:1273`):
- Payload: `{ win: [playerIds], loss: [playerIds] }` — **player IDs only, NO match stats** (no kills/score/mode/duration).
- Logic: `Rank +25` winners, `Rank -25` losers. Flat. No Elo math, no K-factor, no decay, no floor.
- On-chain write was stubbed out ("removed for testing environment").
- → To grant XP/rewards we must **enrich this payload** (server-side UE5 change) and rewrite the handler.

## A.3 UE5 Codebase Touchpoints (game client + dedicated server)

> ⚠️ **Not yet verified against live code** — build VM is STOPPED and gcloud auth expired (2026-06-24). The below is from `multiplayer-infrastructure.md` + CLAUDE.md. A VM verification pass is required (see Part D.5).

| Component | File (per docs) | Role for progression |
|-----------|-----------------|---------------------|
| Client backend subsystem | `ArcaschampionsapiBackendSubsystem.h:20` (API URL) | Calls GET endpoints (profile, vault, loadouts). **Add**: GET_Progression, GET_Leaderboard, GET_Unlocks. |
| Dedicated server backend | `DedicatedServerBackendSubsystem.h:30` (API URL) | Fires `POST_RankedMatchResults` at match end. **Modify**: send per-player stats. |
| Match end | (location TBD — verify) | Where win/loss is determined + where stats live server-side. |

**Known**: server already knows win/loss teams at match end (it sends them). **Unknown until VM check**: whether per-player kills/score/objective stats are tracked server-side and accessible at match-end, or whether that needs new gameplay code.

---

# PART B — Target Design

## B.1 What we're adding

```
ACCOUNT PROGRESSION (new)              RANKED / MMR (upgrade existing)
- account XP + level                   - proper MMR (replace flat ±25)
- soft currency (earned)               - games/wins/losses/streak/peak
- hard currency (premium, stub)        - seasons + leaderboard
- seasons                              
                                       
GAMEPLAY UNLOCKS (new)                 MATCH HISTORY (new)
- small starter kit                    - per-match, per-player stats
- earn weapons/totems by level         - server-authoritative
- reward/unlock config                 - feeds XP/reward grants + anti-cheat
```

## B.2 New / changed schema

**`playerprogression`** (new)
| Column | Type | Notes |
|--------|------|-------|
| playerid | INT PK FK | → playerprofile |
| account_xp | BIGINT | XP in current level |
| lifetime_xp | BIGINT | total ever |
| account_level | INT | default 1 |
| soft_currency | INT | earned coins |
| hard_currency | INT | premium (future; default 0) |
| season_id | INT | FK → seasons |
| updated_at | TIMESTAMPTZ | |

**`playerrank`** (modify — keep `rank INT` for on-chain mirror-ability, add):
`mmr_mu`, `mmr_sigma` (Glicko-2) **or** keep single rating + `games_played`, `wins`, `losses`, `current_streak`, `peak_rank`, `season_id`.

**`playerunlocks`** (new, normalized)
| Column | Type |
|--------|------|
| playerid | INT FK |
| item_type | TEXT (`weapon`/`totem`) |
| item_id | INT |
| unlocked_at | TIMESTAMPTZ |
| source | TEXT (`level`/`starter`/`grant`) |

**`progression_rewards`** (new, config — what each level grants)
`level INT, reward_type ('weapon'|'totem'|'currency'|'cosmetic'), reward_id INT, quantity INT`

**`seasons`** (new): `season_id, name, starts_at, ends_at, is_active`.

**`match_history`** + **`match_player`** (new — server-authoritative)
- `match_history`: matchid, mode, map, started_at, ended_at, server_id, season_id
- `match_player`: matchid, playerid, team, result, kills, deaths, assists, score, xp_earned, currency_earned, rank_delta

**`initialize_player_associations()`** (rewrite): grant a **small starter kit** (e.g. one primary, one secondary, one melee, one of each totem category) instead of the full set. Plus insert `playerprogression` (level 1) and `playerunlocks` (starter items, source=`starter`).

## B.3 New / changed API

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `POST_MatchResults` (evolve `POST_RankedMatchResults`) | POST | Accept per-player stats → compute MMR delta + XP + currency → detect level-ups → grant unlocks → write match_history. Keep old route as thin shim for backward compat. |
| `GET_Progression` | GET | level, xp, xp-to-next, currency, season |
| `GET_Unlocks` | GET | unlocked item IDs (drives vault/loadout availability) |
| `GET_Leaderboard` | GET | `?season=&mode=&limit=&offset=` ranked list |
| `GET_Rewards` | GET | progression track config (what unlocks at each level) |
| `GET_Profile` (modify) | GET | include progression summary; **fix tester-only rank bug** |

MMR: replace flat ±25 with **Elo (K-factor scaled by rank gap)** for v1, or Glicko-2 if we want rating confidence. Must be **server-authoritative** — only the dedicated server (trusted token) can post results.

---

# PART C — Phased Build Plan (mapped to gameplan)

### Phase 1 — Ranked Leaderboards (gameplan: **Jul/Aug**)
*The MMR upgrade + the data plumbing that progression also depends on.*
1. Migrate `playerrank` (add games/wins/losses/streak/peak/season).
2. Add `seasons` + `match_history`/`match_player`.
3. Rewrite MMR math (Elo) in the match-result handler.
4. Enrich the match-result payload — **UE5 dedicated-server change** to send per-player win/loss (+ stats if available).
5. `GET_Leaderboard` endpoint.
6. Leaderboard UI (client subsystem call + screen).

### Phase 2 — Progression Backend (gameplan: **Sep**)
1. `playerprogression` table + bootstrap insert.
2. XP + currency grant on match-end (in the same handler).
3. Level curve + level-up detection.
4. `GET_Progression` endpoint + `GET_Profile` enrichment.

### Phase 3 — Gameplay Unlocks (gameplan: **Sep–Oct**)
1. `playerunlocks` + `progression_rewards` config.
2. Rewrite `initialize_player_associations()` → small starter kit.
3. Unlock-on-level-up grant logic.
4. `GET_Unlocks`; integrate with vault/loadout availability.
5. **Migration decision** for existing players (grandfather vs season reset — see D.4).

### Phase 4 — Progression Frontend (gameplan: **Oct–Nov**, the "progression: frontend (TBD scope)" row)
1. Post-match XP/reward screen.
2. Level + currency HUD.
3. Leaderboard screen (if not done in Phase 1).
4. Unlock notifications + locked-item states in loadout UI.

---

# PART D — Open Decisions, Risks, Verification

## D.1 What earns XP / rank
Win/loss is known. Decide the XP formula: flat per-match, win bonus, performance (kills/objectives), time-played. **Needs server-authoritative stats** — see D.5.

## D.2 Currency sinks
If gameplay items are level-gated (earned, not bought), what does **soft currency** buy? Options: cosmetics, champion re-rolls, loadout slots, season-pass tiers. Without a sink, currency is meaningless. **Decision needed.**

## D.3 Season cadence + rank reset
Length (6–8 wks?), soft vs hard rank reset, end-of-season rewards.

## D.4 ⚠️ Balance + migration risk (biggest one)
Gating weapons/totems behind levels changes competitive balance and adds new-player friction. Two sub-decisions:
- **Starter-kit composition** — must be viable/fun on its own.
- **Existing players** already have the full vault. Do we (a) **grandfather** them (only new accounts get the small kit), or (b) **season-reset** everyone into the unlock system? Grandfather is safer for community goodwill; reset is cleaner for balance. **Recommend grandfather for v1.**

## D.5 ⚠️ VM verification pass (REQUIRED before Phase 1 build)
Re-auth (`gcloud auth login`) + start VM, then confirm in the UE5 code:
1. Where match-end is detected on the dedicated server.
2. Whether per-player stats (kills/deaths/assists/score/mode/map) are tracked server-side and accessible at match-end — or whether that's new gameplay code.
3. Exact method in `DedicatedServerBackendSubsystem` that posts results (to enrich payload).
4. How `ArcaschampionsapiBackendSubsystem` caches profile/vault (to add progression GETs + UI).
5. Whether the client already has any progression/level UI scaffolding.

→ Until D.5 is done, Phase 1 step 4 (enriched payload) and the XP formula (D.1) are estimates.

## D.6 Anti-cheat
All XP/currency/rank grants must derive from **server-authoritative** match data only. The client must never report its own stats. The match-result token auth is currently a single hardcoded string — fine for server-to-server, but rotate it and keep it out of client builds.

## D.7 On-chain mirror (future, not this quarter)
Keep `rank INT` as the canonical mirror-able value. When SkillStaking goes live, an oracle reads `playerrank.rank` → writes on-chain RWA. No schema change needed now; just don't bury rank inside a Glicko-only representation (keep a derived integer rank).

---

**Next action**: re-auth gcloud + start the VM to run the D.5 verification pass, then lock D.1–D.4 with Dan and begin Phase 1 migrations.
