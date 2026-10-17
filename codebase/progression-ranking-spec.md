# Arcas Champions — Progression & Ranking: System Spec

**Created**: 2026-08-05 · **Status**: 🟢 SPEC (v1) — buildable, open items flagged inline
**Supersedes**: the design half of [[game-object-model]] (§3–§5). That doc remains the
**current-state / rationale** reference — read it for why things are the way they are and
for the drift register. **This doc is what we build.**

**Related**: [[xp-leveling-system]] (the XP half, already shipping) ·
[[barracks-vault-flow]] (the vault seam) · [[database-structure.md]] ·
[[progression-system-status-2026-07]]

---

## 0. Decision log

| # | Decision | Date | By |
|---|---|---|---|
| D1 | **Rank (MMR) is PROFILE-attached.** Overrides the Game Bible. | 2026-08-05 | Dan |
| D2 | **Champion Prestige exists**: per-champion, starts at 0, goes up *and* down. | 2026-08-05 | Dan |
| D3 | **Champion Tier is DERIVED from Champion Prestige** — not purchased. | 2026-08-05 | Dan |
| D4 | **Tier 5 ("Master") = top-100 by prestige AND above a threshold.** A sub-tier of Bastonium, not a fifth band. | 2026-08-05 | Dan |
| D5 | **Monthly rewards** awarded on overall champion prestige. *(Superseded in part by D17: currency only, no direct champion grants.)* | 2026-08-05 | Dan |
| D6 | **Prestige decays** on inactivity. | 2026-08-05 | Dan |
| D7 | Rank/prestige must **not** directly scale combat stats. | proposed — §3.4 | — |
| D8 | **Prestige resets to 0 on Black Market transfer.** | proposed — §7.3 | — |
| D9 | **Skins are account-scoped, non-exclusive cosmetics.** Owning one lets you apply it to **any number** of your champions at once; it is never consumed. | 2026-08-06 | Dan |
| D10 | **8 skins: 4 native, 2 via progression, 2 bought with bananas.** | 2026-08-06 | Dan |
| D11 | **A new champion defaults to one of the 4 native skins**; the player can re-skin any champion freely, any time. | 2026-08-06 | Dan |
| D12 | **Bananas** come from progression *and* the rank-based monthly payout, and are spent in the shop on **champions or skins**. | 2026-08-06 | Dan |
| D13 | **Suspicious Vials upgrade champion stats, with a per-champion limit.** Earned from progression + monthly rewards. | 2026-08-06 | Dan |
| D14 | **Weapon mods are composable items, not weapon variants** — one Double Tap mod usable across many weapons. | 2026-08-06 | Dan |
| D15 | **One mod slot per weapon**, with **3 mods available per weapon class**. Three real choices per loadout. | 2026-08-06 | Dan |
| D16 | **SkillStaking becomes a rank-based prediction market.** No per-player custodial wallet is needed, so `wallet` / `privatekey` / `iv` leave the model. | 2026-08-08 | Dan |
| D17 | **Ancient Scrolls are cut.** The only rewards are **bananas and vials**. Champions and skins are **bought in the marketplace**, never granted directly. | 2026-08-08 | Dan |
| D18 | **The top tier is "Master", not "Elite"** — "Elite" already means a faction and a skin family. | 2026-08-08 | Dan |
| D19 | **`peak_prestige` is cut.** It was display-only and load-bearing for nothing. | 2026-08-08 | Dan |

> D4 also resolves a long-standing contradiction: the Bible says *"There are **4** totem
> stages"* and then lists **5** names. It was never a typo — **Master is a
> designation on top of Bastonium**, not a band of its own. The live code comment
> (`LeaderboardWidget.cpp:17`) lists exactly the 4 bands.

---

## 1. Principles

1. **Four axes, four jobs.** Nothing does two jobs (§2).
2. **Server-authoritative.** Every XP, prestige, currency and unlock mutation originates
   from the dedicated server's match report. The client never asserts its own numbers.
3. **Config in data, not code.** Curves, tier bands, prestige constants, decay rates and
   reward tables all live in DB config tables. **Retuning must never require a game
   build** — this already holds for the XP curve and must hold for everything here.
4. **Earning ≠ winning.** Content and capability come from *playing*; status comes from
   *winning*. Keeps the ladder an honest measurement (§3.4).
5. **Idempotent batch jobs.** Decay and monthly payouts run on schedules and must be safe
   to re-run.

---

## 2. The four axes

| | **ACCOUNT LEVEL** | **ACCOUNT MMR** | **CHAMPION PRESTIGE** | **CHAMPION TIER** |
|---|---|---|---|---|
| Key | `playerid` | `playerid` | `champid` | derived from prestige |
| Visibility | public | **hidden** | public | public |
| Earned by | playing any mode | ranked outcomes | ranked outcomes | — |
| Direction | ↑ only | ↕ | ↕, floored at 0 | ↕ follows prestige |
| Decays | no | no | **yes** (§6) | via prestige |
| Grants | content unlocks | fair matchmaking | leaderboard, monthly rewards | shield, card art, T5 status |
| Grants combat power | **yes** (items) | no | **no** | **no** (§3.4) |
| Status today | ✅ built | 🟡 stub (flat ±25) | ❌ | ❌ |

**Why MMR and Prestige are both needed and are not duplicates** — this is the standard
hidden-MMR/visible-points split used by most competitive games:

- **MMR** answers *"who should this player be matched against?"* It must be per-human
  (a player's skill doesn't change when they swap champion), stable, and hidden so it
  can't be gamed or tilted over.
- **Prestige** answers *"what has this champion achieved?"* It is per-champion, visible,
  decays, and is the thing the leaderboard sorts and the monthly payout reads.

MMR feeds the prestige calculation (beating a stronger lobby is worth more) but is never
shown.

---

## 3. Champion Prestige

### 3.1 Award

Applies **per ranked match, to the champion the player fielded**. Casual matches award
XP only (unchanged) — no prestige.

```
base    = win ? PRESTIGE_WIN : PRESTIGE_LOSS            // +25 / -20
mmrAdj  = clamp( round( (avgOpponentMMR - myMMR) / MMR_DIVISOR ), -MMR_CAP, +MMR_CAP )
perf    = clamp( round( (3*K + A - 3*D) / PERF_DIVISOR ), -PERF_CAP_DOWN, +PERF_CAP_UP )

delta     = base + mmrAdj + perf
prestige  = max( 0, prestige + delta )                  // hard floor at 0 (D2)
```

`mmrAdj` is added on both win and loss: beating a stronger lobby gains more, losing to a
weaker one costs more. `perf` keeps a losing player who carried from being flattened.

**Constants** — all live in `progression_config` (§4.4), tunable without deploy:

| Key | v1 value | Note |
|---|---|---|
| `PRESTIGE_WIN` | `+25` | |
| `PRESTIGE_LOSS` | `-20` | net-positive ladder; decay does the deflation |
| `MMR_DIVISOR` | `40` | 400 MMR gap → ±10 |
| `MMR_CAP` | `10` | |
| `PERF_DIVISOR` | `6` | K/D/A term reuses the XP system's `3K + A − 3D` |
| `PERF_CAP_UP` | `10` | |
| `PERF_CAP_DOWN` | `5` | |
| `PRESTIGE_FLOOR` | `0` | D2 |

Range per match ≈ **−35 … +45**. Roughly +15 net per win at even MMR.

**No `peak_prestige`** (D19). Tier always reads *current* prestige, otherwise decay means
nothing, so a highest-ever column would have been decoration with a maintenance cost. If
we ever want a "career best" flourish, `match_history` already holds every
`prestige_delta` and it can be reconstructed.

### 3.2 Profile Prestige (derived)

> Bible: *"Profile Prestige: this number will indicate the combined amount of every
> champion in your possession."*

```
ProfilePrestige = sum( prestige of the player's TOP 5 champions by prestige )
```

**Deviation from the Bible, deliberate**: the Bible said *every* champion. Summing all
champions makes the monthly payout (§5) reward *owning many champions* rather than
playing well — and champions are purchasable with bananas, which the payout itself pays
out. That's a closed loop that prints currency. **Capping at the top 5 matches the
roster limit** (`playerloadouts` has exactly 5 slots, and `validate_loadout` already
enforces one champion per slot), so it costs nothing in fantasy and closes the loop.

### 3.3 Tier bands

Tier is a pure function of prestige, plus one global ranked-list condition for T5.

| Tier | Name | Min prestige | Extra condition |
|---|---|---|---|
| 1 | Bamboo Shield | 0 | — |
| 2 | Scavenger Shield | 500 | — |
| 3 | Banana Shield | 1,500 | — |
| 4 | Bastonium Shield | 3,000 | — |
| 5 | **Master** | 5,000 | **AND** in the global top 100 by prestige |

At ≈ +15 net prestige/win, T4 ≈ 200 net wins and T5's floor ≈ 330. **These are strawman
numbers** — they should be sanity-checked against real match volume once prestige has run
for a few weeks. They live in `prestige_tiers` and are editable live.

⚠️ **The bands currently in code are placeholders and must be replaced.**
`LeaderboardWidget.cpp:17` reads `// For now pretend ... Bamboo 0-50, Scavenger 50-100,
Banana 100-150, Bastonium >150`. At ±25/match you'd reach the top band in six wins.
The shield→image map (`MinimumRankShieldsImages`, a `TMap<int32, Texture>`) is
**data-driven in the widget defaults**, so rebanding the client is an editor edit, not a
code change.

**T5 recomputation**: a daily job ranks all champions with `prestige >= T5 threshold`,
takes the top `elite_slots` (100), and stamps `is_master`. Losing your top-100 place drops
you to T4 (you keep Bastonium). T5 is therefore *contested continuously*, which is the
point of it.

### 3.4 ⚠️ Prestige and Tier must NOT raise combat stats

Restating, because D3 moved Tier from an *investment* axis to a *performance* axis, which
makes this sharper than it was:

If Tier raised the stat ceiling, then **winning → prestige → tier → stats → winning**.
Because matchmaking pairs you with players near your MMR, the mechanical advantage lands
exactly on the opponents least able to absorb it. It would also make prestige a measure
of the advantage it granted itself — and prestige is the number the leaderboard, the
monthly payout and (potentially) SkillStaking all read.

**Where champion power should come from instead**: the stat budget (Bible: starts at 25
points, buffs to 50) is spent with **Suspicious Vials**, which are earned from account
levels and monthly payouts. That keeps growth available to every player who plays, not
only to those who win.

**There is still an indirect loop** — win → prestige → bigger monthly payout → more vials
→ stronger champion. That is acceptable: it is *slow* (monthly), *bounded* (the 50-point
ceiling is global, so a winner reaches the same cap as everyone else, just sooner), and
*catch-up-able*. A direct tier→stat link would be none of those things.

> **🔓 OPEN — needs Dan.** This means there is **no purchased champion upgrade track**;
> tier is earned, and the stat budget is spent with vials up to a global cap of 50.
> If you still want a *paid* ceiling ladder in addition, say so — but it should be
> decoupled from Tier, or the loop above becomes direct.

---

## 4. Data model

> 📐 **Full target ERD**: `arcas-champions/docs/target-erd.drawio.svg` (also in `drive/`).
> It merges the live Cloud SQL schema with every addition below, with crow's foot
> relationships and the spec's new columns marked in green.

All new tables get a `test`-prefixed mirror created by `LIKE ... INCLUDING ALL`, matching
the existing convention. Config tables (`prestige_tiers`, `prestige_rewards`,
`progression_config`) are **global — no test mirror**, same as `progression_levels`.

### 4.1 `championprestige` (new)

Kept separate from `champions` so the champion record stays an identity/stat object and
the high-write ladder data is isolated — the same split as `playerprogression` vs
`playerprofile`.

| Column | Type | Notes |
|---|---|---|
| `champid` | INT PK, FK → champions | |
| `prestige` | INT NOT NULL DEFAULT 0 | authoritative, floored at 0 |
| `tier` | INT NOT NULL DEFAULT 1 | derived cache, recomputed on every write |
| `is_master` | BOOL DEFAULT FALSE | T5 flag, set by the daily top-100 job |
| `matches_ranked` | INT DEFAULT 0 | |
| `last_ranked_at` | TIMESTAMPTZ | |
| `decay_applied_at` | TIMESTAMPTZ | last time decay touched this row |
| `updated_at` | TIMESTAMPTZ DEFAULT now() | |

### 4.2 `prestige_tiers` (new, config)

| Column | Type | Notes |
|---|---|---|
| `tier` | INT PK | |
| `name` | TEXT | "Bamboo Shield" … |
| `min_prestige` | INT | |
| `requires_top_n` | INT NULL | `100` for T5, NULL otherwise |

### 4.3 `prestige_rewards` (new, config) — monthly payout table

| Column | Type |
|---|---|
| `tier` | INT PK |
| `bananas` / `vials` | INT |

### 4.4 `progression_config` (new, config) — key/value tuning

`key TEXT PK, value NUMERIC, description TEXT`. Holds every constant in §3.1 and §6, and
should absorb the XP constants currently hardcoded in `server.js` (`XP_WIN`, `XP_LOSS`,
`XP_FLOOR`, …) so **all** tuning is data.

### 4.5 `prestige_payouts` (new, ledger)

| Column | Type | Notes |
|---|---|---|
| `id` | BIGSERIAL PK | |
| `playerid` | INT FK | |
| `period` | TEXT | `'2026-09'` |
| `tier` / `profile_prestige` | INT | snapshot at payout |
| `bananas` / `vials` | INT | what was paid |
| `paid_at` | TIMESTAMPTZ | |
| | | **`UNIQUE (playerid, period)`** ← idempotency |

### 4.6 Changes to existing tables

```sql
-- consumables finally get a home (unblocks BOTH the unlock table and the vial economy)
ALTER TABLE playervault ADD COLUMN bananas INT NOT NULL DEFAULT 0;
ALTER TABLE playervault ADD COLUMN vials   INT NOT NULL DEFAULT 0;

-- attribute a match to the champion that played it (required for prestige)
ALTER TABLE match_history ADD COLUMN champid INT;
ALTER TABLE match_history ADD COLUMN prestige_delta INT;

-- champion stat upgrades (§9) and weapon-mod ownership + assignment (§10)
ALTER TABLE champions   ADD COLUMN vial_points_spent INT NOT NULL DEFAULT 0;
ALTER TABLE playervault ADD COLUMN weaponmods INT[] NOT NULL DEFAULT '{}';
--  loadoutN JSONB gains  "WeaponMods": [modId, modId, modId]   (index-aligned with Weapons)

-- the level -> unlock map that the design sheet has always defined and we never entered
ALTER TABLE progression_levels ADD COLUMN reward_type TEXT;   -- weapon|totem|banana|vial|skin
ALTER TABLE progression_levels ADD COLUMN reward_id   INT;    -- offset-encoded item id, or NULL
ALTER TABLE progression_levels ADD COLUMN reward_qty  INT DEFAULT 1;
```

`initialize_player_associations()` is rewritten to grant the **6-item starter kit**
(§11) plus a starting consumable float **and the 4 native skins** (§8.4), instead of the
full item range.

Skin columns (`playervault.skins`, `champions.skin_id`) are specified in **§8.4**.

### 4.7 ⚠️ Retiring the custodial wallet columns (D16) — do NOT just DROP them

D16 removes `playerprofile.wallet`, `privatekey` and `iv` from the model. **Retiring them
is not a one-line migration**, because they are live and load-bearing today:

- `createProfile()` (`server.js:239`) generates a real **`ethers.Wallet.createRandom()`**
  for every new player, AES-encrypts the private key with a key derived from their auth
  ID, and stores ciphertext plus IV.
- `GET_Profile` returns `Wallet` to the client, and the UE5 side has wallet plumbing
  (`BlockApeScissorsSettings` `GetWallet` endpoint, the bundled `Web3AuthSDK` plugin).
- **829 players currently have one of these custodial wallets.**

🔴 **Dropping the columns permanently destroys the only copy of 829 private keys.** If any
of those addresses hold anything (ARCAS, a Gamesters NFT, a testnet airdrop, anything sent
by a player), that value becomes unrecoverable. There is no backup path: the key exists
only as ciphertext in this table.

**Recommended sequence:**

1. **Stop generating.** Remove the wallet creation from `createProfile()` so new players
   get none. Reversible, zero risk, do this first.
2. **Stop returning.** Drop `Wallet` from the `GET_Profile` payload and remove the client
   plumbing. `ethers` can come out of the API's dependencies.
3. **Check before deleting.** Sweep the 829 addresses for any on-chain balance or token
   before touching the data. This is a read-only script and it settles the question.
4. **Archive, then drop.** Move the three columns to a `player_wallet_archive` table (or
   an offline encrypted export held by Dan) and only then `ALTER TABLE ... DROP COLUMN`.

The ERD shows these three marked in red as **RETIRED** rather than deleted, to make it
obvious they still exist in the live database while steps 1 to 4 play out.

---

## 5. Monthly rewards (D5)

**Schedule**: 1st of each month, 00:00 UTC. Cloud Scheduler → `ADMIN_RunMonthlyPayout`.

**Basis**: the player's **Profile Prestige** (§3.2) determines their payout tier — i.e.
the tier band that their *summed top-5* prestige falls into, so a player with several
good champions is rewarded, not just one.

**Strawman table** (lives in `prestige_rewards`, tune freely):

| Payout tier | Bananas | Vials |
|---|---|---|
| 1 Bamboo | 100 | 1 |
| 2 Scavenger | 300 | 2 |
| 3 Banana | 700 | 4 |
| 4 Bastonium | 1,500 | 6 |
| 5 Master | 3,000 | 10 |

**Currency only (D17).** The payout never grants a champion or a skin directly; it pays
bananas, and the player spends them in the marketplace. That is strictly better than a
direct grant: it removes the closed loop where a payout hands out the very thing the
payout is measured on, it keeps one price list instead of two reward paths, and it lets a
player save for the thing they actually want.

**Idempotency**: the job writes `prestige_payouts` with `UNIQUE (playerid, period)` and
skips any player already paid for that period. Safe to re-run, safe to run late.

**Notification**: a payout summary is surfaced on next login (same pattern as the
level-up popup — but see §12.1: do **not** copy the single-consume flag design).

> **🔓 OPEN** — does prestige **reset** at month end? Recommend **no**: decay (§6) already
> provides continuous soft-deflation, and a hard monthly reset would make T5's top-100
> race restart from noise every month. Monthly is a *payout* cadence, not a season.

---

## 6. Decay (D6)

**Trigger**: player inactivity, not champion inactivity. If the *player* has played a
ranked match recently, none of their champions decay. (Champion-scoped decay would punish
you for owning a roster you can only field one at a time.)

```
if (now - player.last_ranked_at) > DECAY_GRACE_DAYS:
    for each champion of that player with prestige > DECAY_FLOOR:
        days = full days since max(last_ranked_at, decay_applied_at)
        prestige = max( DECAY_FLOOR, round( prestige * (1 - DECAY_RATE) ^ days ) )
        recompute tier
```

| Key | v1 value | Rationale |
|---|---|---|
| `DECAY_GRACE_DAYS` | `7` | a week off costs nothing |
| `DECAY_RATE` | `0.02` /day | ~13% per week, ~45% per month |
| `DECAY_FLOOR` | `500` | = T2 floor; casual players never get zeroed for taking a break |

**Percentage, not flat** — deliberately. Decay should press hardest on the top of the
ladder, because T5 is a scarce top-100 slot and it should belong to whoever is *currently*
playing, not whoever peaked in March. A flat rate would erase a new player's progress
while barely troubling a leader.

**Schedule**: daily, 03:00 UTC, Cloud Scheduler → `ADMIN_RunPrestigeDecay`. Idempotent
via `decay_applied_at` (re-running the same day is a no-op).

---

## 7. Interactions and edge cases

### 7.1 Which champion earns prestige?

The one fielded in that match. **This requires the dedicated server to report `champid`
per player**, which it does not do today — `POST_MatchResults` sends player IDs only.
The data exists server-side (`PlayerInfoComponent` holds `CurrentLoadout.Champion`), so
this is a payload change, not new gameplay code. **It is the one hard blocker that needs
the build VM** (§13, Phase 3).

### 7.2 Mid-match champion swapping

The Bible allows swapping champions mid-match and splits earned prestige across every
champion deployed. **Not built** (no mid-match swap exists). If it ships later, the split
rule must come back — otherwise a player fields five champions and farms five ladders from
one match. Recorded so it isn't forgotten.

*(An earlier draft of the model doc claimed this rule was made obsolete by moving rank to
the profile. That was true of *rank*; with champion prestige (D2) the rule is live again.)*

### 7.3 ⚠️ Black Market transfers — prestige must reset (D8, proposed)

Champions are auctionable for bananas. If prestige travelled with the champion, then
leaderboard position, Tier, T5 top-100 slots and the monthly payout would all be
**directly purchasable**, and wash-trading between two accounts would manufacture
prestige out of nothing.

**Recommend: on transfer, `prestige` → 0, `is_master` → false, `tier` → 1.**

This costs less than it sounds. The Bible's stated reason to buy a champion is the *stat
roll*: *"Ideal to find already built configurations or specific types of stats."* Stats,
gender, skin, name and any vial investment all survive the sale — only the ladder record
resets. The market keeps its actual purpose and the ladder stays unbuyable.

Decay alone is **not** a sufficient mitigation here: it operates over weeks, while a
monthly payout snapshot or a top-100 placement can be captured in a day.

### 7.4 Existing players

- **Prestige**: everyone starts at 0. No backfill — there's no historical ranked data to
  derive it from, and a synthetic seed would corrupt the first month's top-100.
- **Vaults**: grandfather production (existing players keep their full item set), reset
  test to the starter kit so unlocks are testable. Unchanged from the earlier plan.
- **Consumables**: seed existing players with a small float so the vial economy isn't
  dead on arrival for them.

### 7.5 SkillStaking

🔒 **Resolved by D16: SkillStaking becomes a rank-based prediction market.** People take
positions on how a player or champion will place, rather than staking tokens *under* a
player. That changes the requirement fundamentally:

- **No per-player custodial wallet is needed.** A prediction market settles against a
  public, server-authoritative number; it does not need the game to hold keys on the
  player's behalf. So `wallet`, `privatekey` and `iv` leave the model (§4.7).
- **The number it settles on must be public, tamper-proof and decay-aware.** Champion
  prestige (§3) is exactly that, and `match_history` gives a full audit trail.
- **D8 becomes load-bearing, not optional.** If prestige transferred with a Black Market
  sale, a market could be moved by buying the outcome. Prestige resetting on transfer
  (§7.3) is what makes the settlement number honest.

---

## 8. Skins and cosmetics

### 8.1 The model (D9–D11)

A skin is **account-scoped, non-exclusive and permanent**. Owning it once lets you put it
on **every champion you own, simultaneously**. It is not consumed, not per-champion, and
re-skinning is free and unlimited.

This makes skins the **third distinct ownership shape** in the game — worth being explicit
about, because it's easy to model wrongly:

| Object | Scope | Exclusive? |
|---|---|---|
| **Champion** | per-instance object, owned by a player | yes — one champion, one loadout slot (`validate_loadout`) |
| **Weapon / totem** | account-scoped ID in `playervault` | no — usable across loadouts, but occupies a slot when equipped |
| **Skin** | account-scoped ID in `playervault` | **no — occupies nothing, unlimited simultaneous use** |

Dan's worked example, which the model must support exactly:
> 1 champion → play → earn bananas → buy **2 champions + 1 skin** → set **all three**
> champions to that one skin.

### 8.2 The eight skins — 🎉 the art is already done

The champion-card icon set landed on 29 Jul (`5b2cbcaf4` Marco + `a83d7548b` ElTraktor)
and covers **exactly eight skins × five stats × two icon sets = 80 textures**. The
character Blueprints all exist too. This was not previously written down anywhere.

| # | Prefix | Skin | Blueprint (`Cosmetics/Player/`) | Card icons | Acquisition |
|---|---|---|---|---|---|
| 1 | `EM` | Elite Male | `B_MaleApe_Elite` | ✅ | **native** |
| 2 | `EF` | Elite Female | `B_FemaleApe_Elite` | ✅ | **native** |
| 3 | `RM` | Renegade Male | `B_MaleApe_Renegade` | ✅ | **native** |
| 4 | `RF` | Renegade Female | `B_FemaleApe_Renegade` | ✅ | **native** |
| 5 | `AM` | Alpha Male | `B_MaleApe_Alpha` | ✅ | shop (bananas) |
| 6 | `AF` | Alpha Female | `B_FemaleApe_Alpha` | ✅ | shop (bananas) |
| 7 | `BZ` | Bonzette | `B_Bonzette` | ✅ | progression |
| 8 | `SS` | Sarger Skullfist | `B_SargerSkullfist` | ✅ | progression |
| — | — | Bas Sentinel | `B_BasSentinel` | ❌ **no card art** | parked — a 9th, see below |

**Why BZ/SS on progression and AM/AF in the shop**: Bonzette and Skullfist have had
complete Blueprint + mesh + material + texture sets since Feb ([[skin-system]]), i.e. they
are playable today. **Alpha Male/Female still need rigging** — an open task in CLAUDE.md
(*"Rig Alpha Male/Female — have mesh + textures in GCS, ask Marco"*). Putting the ready
pair on the progression track ships the feature sooner; the shop pair can land later
without blocking it. **Marco's call to confirm.**

⚠️ **`B_BasSentinel` exists but has no card icons.** The design sheet (D) also listed
*"Bas Sentinel Skin"* and *"Bas Sentinel Skin Premium"* as level rewards. It's a real
9th skin that the 29 Jul art pass skipped. Either it's cut, or it needs its 10 icons —
**ask Marco**.

⚠️ **Drift from the design sheet**: (D) named the four unlockable skins *Alpha Skin* (L15),
*Bas Sentinel Skin* (L40), *Alpha Skin Premium* (L58), *Bas Sentinel Skin Premium* (L70).
The art that actually shipped is Alpha **Male + Female**, Bonzette and Skullfist. **The art
is the reality; the sheet's names are stale.**

### 8.3 IDs — a new 700 block

Extends the existing offset scheme (`LoadoutDAO.h`, §11) with the next free hundred:

```
SKINS     701 EliteMale · 702 EliteFemale · 703 RenegadeMale · 704 RenegadeFemale
          705 AlphaMale · 706 AlphaFemale · 707 Bonzette · 708 SargerSkullfist
          (709 BasSentinel — reserved, pending art)
```

### 8.4 Schema

```sql
-- account-scoped ownership; everyone starts owning the four natives
ALTER TABLE playervault ADD COLUMN skins INT[] NOT NULL DEFAULT '{701,702,703,704}';

-- which skin this champion is currently wearing
ALTER TABLE champions ADD COLUMN skin_id INT NOT NULL DEFAULT 701;

-- backfill from the existing gender/skinteam pair
UPDATE champions SET skin_id = 701 + skinteam * 2 + (1 - gender);
--   gender 1=Male,0=Female · skinteam 0=Elite,1=Renegade
--   G1/S0 -> 701  G0/S0 -> 702  G1/S1 -> 703  G0/S1 -> 704
```

**`gender` and `skinteam` become legacy/derived.** `skin_id` is authoritative for
appearance from here on. Keep both columns written and consistent for now — the
`enforce_champion_initialization()` trigger requires them non-null, and
`USkinTeamFunctionLibrary` still reads `SkinTeam` (§8.7). Retiring them is a later cleanup.

**Champion generation** (`server.js` ~line 306) currently rolls `generateBinary()` twice
for gender + skinteam. It should instead roll a random **native** skin (701–704) and
derive gender/skinteam from it — which is the same distribution, just expressed the right
way round (D11).

### 8.5 Acquisition

| Route | Mechanism |
|---|---|
| **Native** (701–704) | granted by `initialize_player_associations()` alongside the starter kit |
| **Progression** (707, 708) | `progression_levels.reward_type='skin'`, `reward_id=707/708` — same grant path as weapons |
| **Shop** (705, 706) | `POST_Purchase`, priced in bananas |

Skins need **no new grant machinery** — they are just another ID appended to a
`playervault` array, exactly like a weapon. That is the payoff of putting them in the
offset scheme.

### 8.6 The champion card is now fully specified

The Bible defines the card as two layers:
> *"The **Hero Character** is set by the highest stat in the champion... The **Background**
> is set by the champion's placement inside the leaderboard and will display the shield
> which they belong to."*

Both halves now resolve to real data:

```
Hero Character  =  T_UI_ChampionIcon_{skinPrefix}{highestStat}   <- the 8x5 matrix (§8.2)
Background      =  shield art for championprestige.tier          <- §3.3
```

**Client change**: `ChampionAvatar.cpp` currently resolves the icon as
`Rows[TeamID]->IconFromGender[Champion.Gender].Icons.FindRef(HigherStat)` — indexed by
*team + gender*. It must be re-indexed by **`skin_id`**, which is a flat 8-way lookup and
simpler than what's there now.

### 8.7 ⚠️ Friend/foe identification — a real gameplay risk

`USkinTeamFunctionLibrary::GetSkinTeam()` returns **the champion's own `SkinTeam`**, and
only falls back to the match team when the player has *no* champion (`ChampId == 0`).

**So character appearance already does not track which team you are on.** Two players on
opposite teams can both appear Elite today. Free skin-switching across eight visually
distinct characters makes that materially worse — a Bonzette on each team, and nothing in
the silhouette tells you which one to shoot.

I found **no C++ team-colour or outline system** (the `TeamColor`/`Outline` hits are all
menu widgets). It may exist in Blueprint/materials — **needs an editor check before this
ships**. If it doesn't exist, cosmetic freedom needs a counterweight: team-coloured
outlines, a forced enemy recolour, or restricting skins to your assigned faction.

**This gates the skin feature, not the progression work.** Flagging early because it's the
kind of thing that gets found in playtest.

### 8.8 ⚠️ The banana sink is finite

Skins answer *"what do bananas buy?"* alongside champions — but only **two** skins are
purchasable. A player buys both and the skin sink is permanently exhausted; champions
(1,000 bananas each, infinitely re-rollable) remain the only ongoing sink.

That's fine for v1 and it makes the shop cadence obvious: **new purchasable skins are the
natural recurring content drop**, and the 700 block has 90 free IDs for them.

---

## 9. Champion stat upgrades — Suspicious Vials

### 9.1 The loop

A **Suspicious Vial** is a consumable earned from level rewards (§4.6) and the monthly
payout (§5). **Spend 1 vial → +1 to one stat on one champion.** That is the only way a
champion's combat power grows, and it is deliberately on the *account* axis — every
player reaches the same ceiling by playing, nobody buys it by winning (§3.4).

Endpoint: **`POST_BoostStat {champid, stat}`** — the client request class already exists
and has never had a server (§12.2).

### 9.2 The cap — ⚠️ this needed a decision, and the obvious one is a trap

Dan's ask: *"there is a limit of how much you can upgrade them."* Three ways to express
that limit, and the two obvious ones both break:

| Option | Rule | Problem |
|---|---|---|
| A. Bible-faithful | champion starts at **25** total stat points, caps at **50** | ⛔ **Requires regenerating every champion.** Live generation rolls each stat 4–12 independently, so existing champions average **~40 total** and range 20–60. New 25-point champions would be strictly worse than every champion already in the DB. |
| B. Total-sum cap | keep generation, cap the **sum** at 50 (or 60) | ⛔ **Unfair by roll.** A champion that rolled 30 gets 20 vials of headroom; one that rolled 55 gets none. Punishes good rolls, and some existing champions are already over any cap ≤ 60. |
| **C. Cap the vials, not the sum** ✅ | each champion can absorb at most **`VIAL_CAP_PER_CHAMPION`** points, whatever it rolled | no migration, no unfairness, one column |

**Recommend C.** Every champion — old, new, lucky roll, poor roll — gets exactly the same
upgrade headroom. It expresses "a limit of how much you can upgrade" literally, it needs
no population reset, and the cap is a config value we can retune at any time.

```sql
ALTER TABLE champions ADD COLUMN vial_points_spent INT NOT NULL DEFAULT 0;
```

| Key (`progression_config`) | v1 | Note |
|---|---|---|
| `VIAL_CAP_PER_CHAMPION` | `15` | total +points a single champion can ever absorb |
| `STAT_MAX` | `12` | per-stat hard ceiling — matches the live UI range (`NormalizeToRange(…, 3, 12)`) and the `enforce_champion_initialization` trigger's `> 3` floor |

Server validation on `POST_BoostStat`: reject if `vial_points_spent >= VIAL_CAP_PER_CHAMPION`,
if the target stat is already at `STAT_MAX`, or if `playervault.vials < 1`. On success:
decrement the vial, increment the stat, increment `vial_points_spent`. One transaction.

> **🔓 OPEN (O16)** — `VIAL_CAP_PER_CHAMPION = 15` is a strawman. It's the knob that decides
> how much of a champion's power is *rolled* versus *earned*. 15 on a ~40 average roll means
> ~27% earned. Blocked on the same measurement as everything else: **what a stat point is
> actually worth on `CT_PlayerStats`** (O7).

⚠️ Stat upgrades **must be server-authoritative and irreversible**. There is no respec in
this design — spending is a real decision. If we later want respec, it's a banana sink.

---

## 10. Weapon mods — architecture study

> Dan: *"the dumb way is to have a different weapon for each mod, with its own ID — but are
> there other ways? It's not a very scalable way. We should have e.g. a Double Tap mod which
> we can put on multiple weapons."*

**Answer: yes, and the engine already supports it.** We never create weapon variants.
A mod is a **separate item composed onto the weapon instance at equip time**. Cost is
**N + M assets, not N × M** — 21 weapons + 9 mods = 30 things, not 189.

### 10.1 Why the "dumb way" looks like the only way

`ULyraInventoryItemDefinition` is declared `UCLASS(Blueprintable, Const, Abstract)` and its
`Fragments` array is `EditDefaultsOnly`. It is a **CDO — immutable at runtime**. So if you
think of a weapon as its *definition*, the only way to vary it is to author another
definition. That's the trap.

**The weapon you actually shoot is not the definition.** `LyraEquipmentManagerComponent.cpp:86`
does `NewObject<ULyraEquipmentInstance>(...)` — a **fresh, per-equip, per-player UObject**.
Everything interesting is mutable on that instance.

### 10.2 What the engine already gives us (all verified in this codebase)

| # | Fact | Where |
|---|---|---|
| 1 | Weapon instances are **per-equip UObjects**, not CDOs | `LyraEquipmentManagerComponent.cpp:86` |
| 2 | `BulletsPerCartridge`, `MaxDamageRange`, `MaxTraceRange`, spread params are plain instance floats/ints | `LyraRangedWeaponInstance.h:187-201` |
| 3 | Runtime mutation of weapon values is **already an established pattern here** | `SetSpreadMultiplier()`, `SetDistanceDamageFalloffCoefficient()` |
| 4 | **`BaseDamage` is a GAS attribute**, captured from Source — so a GameplayEffect can scale it | `LyraCombatSet.h:86`, `LyraDamageExecution.cpp:19` |
| 5 | Damage = `BaseDamage × DistanceAttenuation × PhysMatAttenuation × TeamMultiplier` | `LyraDamageExecution.cpp:130` |
| 6 | `ULyraAbilitySet` grants **Abilities + GameplayEffects + AttributeSets** together | `LyraAbilitySet.h:26/52/73` |
| 7 | Ability sets are granted on equip into `GrantedHandles` and **auto-removed on unequip** | `LyraEquipmentManagerComponent.cpp:91-95`, `:121` |
| 8 | Item instances carry **replicated, per-instance, server-authoritative `StatTags`** | `LyraInventoryItemInstance.h` (`AddStatTagStack`, `BlueprintAuthorityOnly`) |
| 9 | Champion stats (Strength/Agility/Intelligence/Luck) are **GAS attributes** | `LyraCombatSet.h` |

Fact 7 is the important one: **anything granted at equip time is cleaned up for free.** A
mod cannot leak onto the next weapon you pull out.

### 10.3 Three mechanisms, matched to the three kinds of mod

Our nine designed mods are not all the same shape. Trying to force one mechanism is what
makes people reach for weapon variants:

| Kind | Mods | Mechanism | New code |
|---|---|---|---|
| **A. Attribute scalar** | High Damage Rounds (dmg ×1.5)<br>Lucky Strike / Berserk Boost / Resourceful (Luck / Agility / Intelligence ×1.5) | **GameplayEffect** with a `Multiply` modifier on the attribute, carried in the mod's AbilitySet | **none** — pure data |
| **B. Instance property** | Double Tap (`BulletsPerCartridge` 1→2)<br>High-Capacity Mag (×2) | mutate the weapon instance in **`OnEquipped()`** | ~30 lines |
| **C. Behavioural / on-hit** | Fire Rounds, Healing Rounds, Demolition Rounds | extra **GameplayAbility** and/or on-hit GE in the mod's AbilitySet | per-mod BP work |

Note kind A covers **four of the nine mods with zero code** — the melee mods multiply
champion attributes that already exist in `ULyraCombatSet`, and High Damage Rounds
multiplies `BaseDamage`, which the damage execution already reads as a captured attribute.

### 10.4 The mod asset

One data asset per mod. It carries both a *declarative* half (kind A + C) and a *numeric*
half (kind B):

```cpp
UCLASS(BlueprintType, Const)
class UBASWeaponModDefinition : public UPrimaryDataAsset
{
    int32 ModId;                                    // 801.. (§10.6)
    EUserCombatBarrackType CompatibleCategory;      // Primary | Utility | Melee
    FGameplayTagContainer RequiredWeaponTags;       // optional narrowing (BASRangedWeaponInstance
                                                    // already exposes GetBASWeaponRangedIdTags())
    TObjectPtr<const ULyraAbilitySet> AbilitySet;   // kinds A + C
    FWeaponModStats Stats;                          // kind B
    TSoftObjectPtr<UTexture2D> Icon;
};

USTRUCT()
struct FWeaponModStats                              // multiplicative, 1.0 = no change
{
    float BulletsPerCartridgeMul = 1.f;
    float MagazineSizeMul        = 1.f;
    float SpreadMul              = 1.f;
    float RangeMul               = 1.f;
};
```

**A fixed struct beats reflective property overrides** (`FName` + value applied by
reflection). Reflection is more general but silently breaks when a property is renamed,
can't be validated at cook time, and invites designers to modify things that were never
meant to be modified. The nine designed mods need four numbers. If we later need arbitrary
properties, reflection is the escape hatch — but don't start there.

### 10.5 Where it hooks in — two small changes

**1. Grant the mod's ability set alongside the weapon's** —
`ULyraEquipmentManagerComponent::EquipItem`, right after the existing loop at `:91`:

```cpp
for (TObjectPtr<const ULyraAbilitySet> AbilitySet : EquipmentCDO->AbilitySetsToGrant) { ... }

// NEW: same pattern, same GrantedHandles -> removed automatically on unequip
for (const UBASWeaponModDefinition* Mod : ResolveEquippedMods(ItemInstance))
    if (Mod->AbilitySet)
        Mod->AbilitySet->GiveToAbilitySystem(ASC, &NewEntry.GrantedHandles, Result);
```

**2. Apply the numeric half** — `UBASRangedWeaponInstance::OnEquipped()` (already overridden):

```cpp
void UBASRangedWeaponInstance::OnEquipped()
{
    Super::OnEquipped();
    for (const UBASWeaponModDefinition* Mod : ResolveEquippedMods(GetInstigator()))
    {
        BulletsPerCartridge = FMath::RoundToInt(BulletsPerCartridge * Mod->Stats.BulletsPerCartridgeMul);
        MaxDamageRange     *= Mod->Stats.RangeMul;
        SetSpreadMultiplier(GetSpreadMultiplier() * Mod->Stats.SpreadMul);
        // ...
    }
}
```

Because the instance is spawned fresh on every equip, these mutations need no undo.

✅ **RESOLVED 2026-08-10** ([[weapon-system-deepdive]] §4). Ammo values come from **`UInventoryFragment_SetStats`**
on the item definition (`InitialItemStats`, a `TMap<GameplayTag,int32>` written into the
instance's StatTags at creation) — so `Lyra.ShooterGame.Weapon.MagazineAmmo` is authored
there. The shared `GA_Weapon_ReloadMagazine` Blueprint reads `GetStatTagStackCount(MagazineSize)`
and tops the magazine up from `SpareAmmo`. So **High-Capacity Mag = `AddStatTagStack` on
`MagazineSize`** — already replicated, already server-authoritative, no new code.

> 🔴 See [[weapon-system-deepdive]] for the full evidence pass, including two findings that
> change this section: a **dormant equip-time weapon-stat pipeline already exists**
> (`ABASPlayerState::WeaponsStatsSettings`, never populated), and
> **`ULyraWeaponInstance::PowerMultiplier`** already multiplies every damage result — so
> High Damage Rounds is a float assignment, not a GameplayEffect. That doc also documents a
> **latent dedicated-server bug** in the dormant pipeline that any mods work must fix.

### 10.6 Ownership and storage

Mods are ordinary owned items — a new **800 block** in the offset scheme (§11), matching
the nine icons ElTraktor shipped on 29 Jul:

```
PRIMARY MODS    801 DoubleTap       802 HighDamageRounds   803 HighCapacityMag
UTILITY MODS    804 FireRounds      805 HealingRounds      806 DemolitionRounds
MELEE MODS      807 LuckyStrike     808 BerserkBoost       809 Resourceful
```
*(icons: `T_UI_Icon_PrimaryMod_{DoubleTap,DamageBuff,AmmoCapBuff}`,
`T_UI_Icon_UtilityMod_{FireAmmo,HealingAmmo,DemoAmmo}`,
`T_UI_Icon_MeleeMod_{LuckyStrike,BerserkBoost,Resourceful}` — all committed)*

**Ownership**: `playervault.weaponmods INT[]` — account-scoped, unlocked through
progression exactly like weapons. No new grant machinery.

**Assignment**: extend the loadout JSONB, parallel to the existing `Weapons[3]`:

```jsonc
{ "Champion": 12, "Weapons": [106, 201, 301], "Totems": [401, 501, 601],
  "WeaponMods": [801, 804, 807] }        // index-aligned with Weapons; 0 = no mod
```

Per-**loadout** rather than per-weapon is the better choice: the same MadRifle can run
Double Tap in one loadout and High Damage Rounds in another, and it reuses the
`validate_loadout` trigger — which just gains two checks: *is the mod in the vault*, and
*does `CompatibleCategory` match the slot*.

This also answers Dan's requirement directly: **one owned Double Tap mod, usable on every
primary you own, in every loadout, simultaneously.** Same non-exclusive ownership shape as
skins (§8.1).

### 10.7 Why this scales

| | weapon-variant approach | composed mods |
|---|---|---|
| Assets for 21 weapons × 9 mods | **189 weapon definitions** | 21 weapons + 9 mod assets |
| Add a 22nd weapon | +9 definitions | +1 |
| Add a 10th mod | +21 definitions | +1 |
| Rebalance "Double Tap" | edit 21 assets | edit 1 |
| Two mods on one weapon | combinatorial explosion (189 → 21×36) | already works |
| ID space | 189 IDs | 30 IDs |

The last row matters for the vault: weapon variants would blow through the 100-wide offset
blocks the whole ownership model depends on.

### 10.8 Open questions

- **O17 — Mod slots per weapon.** 🔒 **RESOLVED (D15): one slot per weapon, 3 mods
  available per class.** Three real choices per loadout. The Bible's *"3 native mods"* read
  would have given every weapon all three of its class's mods, i.e. no decision at all.
  The loadout JSONB already supports widening to N slots later.
- **O18 — Is the count 9 or 12?** The Bible says *"an initial pool of 12 mods"* and then
  lists **9**. Nine have icons. Assume 9; ask Marco if three were dropped.
- **O19 — Where does max magazine size come from?** (§10.5) Editor check, gates High-Capacity Mag only.
- **O20 — Do mods stack across the loadout?** Melee mods buff *champion* attributes
  (Luck/Agility/Intelligence ×1.5), so a melee mod is active while you hold the melee.
  Should it apply always, or only while that weapon is equipped? Equip-scoped is what the
  engine gives us for free and is the more interesting decision; **recommend equip-scoped.**

---

## 11. Unlocks, starter kit and the ID bridge

Unchanged from [[game-object-model]] §6–§7; restated here as spec items.

**Starter kit** (settled — the design sheet and `DT_PlayerProgressionItems` agree
independently): **Pistol · Blend Gun · Hunting Knife + Grenade · Personal Healing ·
Turret**.

⚠️ **ID reconcile required before shrinking the vault**: "Hunting Knife" is `303`, outside
the live melee grant `[301,302]`; and the default loadout JSONB ships `601 TeamHealing`
where the kit specifies `602 Turret`. Also, ten designed items (`106-110`, `205-206`,
`303-305`) have IDs but are not currently grantable.

**The ID bridge**: `progression_levels.reward_id` uses the offset-encoded uint8 scheme
(`LoadoutDAO.h`), which is the same space `playervault` uses — so a level-up grant is a
plain array append. The client-side bridge (BP class ↔ uint8) is only needed for
`DT_PlayerProgressionItems` *display*, not for ownership.

---

## 12. API surface

### 9.1 Modified

| Endpoint | Change |
|---|---|
| `POST_MatchResults` | **Payload gains `champid` per player.** Computes prestige delta (§3.1), writes `championprestige`, recomputes tier, writes `match_history` incl. `champid` + `prestige_delta`. Grants level-up rewards into `playervault` (§11). Still awards XP + MMR as today. |
| `GET_Profile` | adds `ProfilePrestige`, `PayoutTier`, `PendingPayout` |
| `GET_Vault` / `GET_UnpackedChampions` | each champion gains `Prestige`, `Tier`, `IsElite` |
| `initialize_player_associations()` | starter kit + consumable float instead of the full range |

> ⚠️ **Do not reuse the `pending_levelup` pattern** for payout notification. It is a
> single-consume server flag with four uncoordinated client readers, and it is the cause
> of the known level-up-popup bug (CLAUDE.md §10). Notifications should be **derived
> client-side** by comparing the newly-fetched value against the stored one.

### 9.2 New

| Endpoint | Purpose |
|---|---|
| `GET_Leaderboard?scope=top100\|mytier&limit&offset` | backs the existing mock leaderboard widget |
| `GET_ChampionPrestige?champid=` | single champion detail |
| `POST_BoostStat` | spend a vial → +1 to one stat, server-validates the 50-point cap. **The client request class already exists** and has never had a server. |
| `POST_Purchase` | spend bananas (champion / skin). Client class exists. |
| `ADMIN_InitializePrestige` | idempotent bootstrap: tables, tier config, reward config, `progression_config` seed, backfill |
| `ADMIN_RunPrestigeDecay` | daily cron target (§6) |
| `ADMIN_RunMonthlyPayout?period=YYYY-MM` | monthly cron target (§5), idempotent |
| `ADMIN_RecomputeMasterTier` | daily top-100 recompute (§3.3) |
| `ADMIN_ResetPrestige` | test-env reset, mirroring `ADMIN_ResetProgression` |

---

## 13. Build phases

| Phase | Work | Needs VM? |
|---|---|---|
| **1. Economy foundation** | `bananas` + `vials` columns (no scrolls, D17); `progression_config`; move XP consts into it; `GET_Profile` exposure; **stop generating custodial wallets** (§4.7 step 1) | ❌ |
| **2. Unlocks** | `progression_levels` reward columns; enter the design sheet's table (compressed to 70 levels); grant-on-level-up in `awardMatch`; shrink `initialize_player_associations()`; ID reconcile | ❌ |
| **3. Prestige core** | `championprestige`, `prestige_tiers`, tier derivation, prestige math in `awardMatch`, `match_history.champid` — **plus the UE5 dedicated-server payload change to send `champid`** | ✅ (server payload only) |
| **4. Decay + payouts** | `ADMIN_RunPrestigeDecay`, `ADMIN_RunMonthlyPayout`, `ADMIN_RecomputeMasterTier`, `prestige_payouts`, 3 Cloud Scheduler jobs | ❌ |
| **5. Vial economy** | `POST_BoostStat` (+`vial_points_spent`, `VIAL_CAP_PER_CHAMPION` + `STAT_MAX` enforcement, §9) / `POST_Purchase` (champions + skins) | ❌ |
| **6. Skins — backend** | `playervault.skins`, `champions.skin_id` + backfill, skin-aware champion generation, `POST_SetChampionSkin`, skins in `GET_Vault` / champion payloads, 707/708 into the level table, 705/706 priced in the shop | ❌ |
| **7. Client — ownership** | `Vault.cpp:103` `AddWeaponSlots`/`AddTotemSlots`; locked-item states | ✅ |
| **8. Client — skins** | re-index `ChampionAvatar.cpp` by `skin_id` (8-way, replaces team+gender); skin picker in Barracks cosmetic slot; **friend/foe pass (§8.7)** | ✅ |
| **9. Weapon mods — backend** | `playervault.weaponmods`, `WeaponMods[]` in the loadout JSONB, `validate_loadout` gains ownership + category checks, 801–809 into the level table (§10.6) | ❌ |
| **10. Weapon mods — runtime** | `UBASWeaponModDefinition` asset + `FWeaponModStats`; mod ability-sets granted in `EquipItem`; numeric half applied in `OnEquipped()`; author the 9 mod assets (§10.4–10.5) | ✅ |
| **11. Client — ladder** | `URankSubsystem`; real leaderboard; reband `MinimumRankShieldsImages`; champion card frame by tier; prestige in Barracks; payout popup | ✅ |

**Phases 1, 2, 4, 5, 6 and 9 are pure API/DB and can proceed while the build VM is stocked
out.** Phase 3 is mostly API but is gated on one small UE5 server change.

⚠️ **Phase 8 must not ship before the friend/foe question (§8.7) is answered.** The
backend half (Phase 6) is safe to build regardless — skins simply aren't switchable in
the client until then.

---

## 14. Open items

| # | Item | Ref | Owner |
|---|---|---|---|
| O1 | Confirm no purchased champion-upgrade track (tier is earned only) | §3.4 | Dan |
| O2 | Tier band numbers — strawman, validate against real match volume | §3.3 | Dan/Marco |
| O3 | Monthly reward amounts (bananas + vials only now) | §5 | Dan |
| O4 | Prestige reset on Black Market transfer (D8) | §7.3 | Dan |
| O5 | Monthly = payout cadence only, no prestige reset | §5 | Dan |
| ~~O6~~ | 🔒 **RESOLVED (D16)** — SkillStaking becomes a rank-based prediction market settling on champion prestige | §7.5 | — |
| O7 | Measure `CT_PlayerStats` curve — what a stat point is actually worth | — | Marco (editor) |
| O8 | `DT_PlayerProgressionItems` per-item `ItemCollectLevel` | — | Marco (editor) |
| O9 | Level cap: keep 70 (live curve) vs design sheet's 100 | §11 | Dan |
| O10 | What `ActivePrestigeLevel` / `PassivePrestigeLevel` were intended to be — the fields already exist in `FBlackMarketChampion` and may map to `delegatedvotingpower` / `permanentvotingpower` | — | Marco |
| O11 | **Friend/foe identification with free skin switching** — appearance already ignores match team; is there a team-colour/outline system in BP/materials? | §8.7 | Marco (editor) — **gates Phase 8** |
| O12 | Confirm the split: **BZ + SS on progression, AM + AF in the shop** (rationale: Alpha M/F still need rigging) | §8.2 | Marco |
| O13 | **`B_BasSentinel`** — real 9th skin with no card art, or cut? The design sheet listed it twice | §8.2 | Marco |
| O14 | Which **two levels** grant skins 707/708, and the **banana price** of 705/706 | §8.5 | Dan |
| O15 | Retire `champions.gender` / `skinteam` once `skin_id` is authoritative (later cleanup — the init trigger and `USkinTeamFunctionLibrary` still read them) | §8.4 | — |
| O16 | `VIAL_CAP_PER_CHAMPION = 15` — how much of a champion is *rolled* vs *earned*. Blocked on O7 | §9.2 | Dan |
| ~~O17~~ | 🔒 **RESOLVED (D15)** — one slot per weapon, 3 mods per class | §10.8 | — |
| O18 | Mod count: Bible says "12", lists **9**, and 9 have icons | §10.8 | Marco |
| ~~O19~~ | 🔒 **RESOLVED 2026-08-10** — `MagazineSize` is a real stat tag set by `InventoryFragment_SetStats` and read by the shared `GA_Weapon_ReloadMagazine` BP. High-Cap Mag = `AddStatTagStack`, replicated, zero code. See [[weapon-system-deepdive]] §4 | §10.5 | — |
| O20 | Melee mods buff *champion* attributes — equip-scoped (recommended) or always-on? | §10.8 | Dan |
| O21 | **Do the 2 progression-unlocked skins survive D17?** D10 grants skins 707/708 through levelling; D17 says skins are bought in the marketplace. Read as "the *monthly payout* pays currency only" (level unlocks unaffected), but confirm — if all 4 unlockable skins move to the shop, `progression_levels.reward_type` loses `skin` | §8.5 | Dan |
| O22 | **Totem swapping is now free** (scrolls cut). Confirm that is intended, or find another gate | §6 | Dan |
| O23 | Sweep the 829 custodial wallets for balances before any column drop | §4.7 | Dan |
