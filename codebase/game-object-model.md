# Arcas Champions — Game Object Model (working doc)

**Created**: 2026-08-05 · **Status**: 🟡 WORKING DRAFT — thinking doc, not yet a spec
**Purpose**: One model of what the game's objects are, what owns what, and where the
progression axes attach — *before* we build the vault/unlock half. This is the doc to
argue with.

> ### ⚠️ Design sections superseded — see [[progression-ranking-spec]]
> Dan locked the design on 2026-08-05. **[[progression-ranking-spec]] is now the
> buildable spec**; the sections below that *proposed* a design (§3 axes, §4 rank,
> §5 tier) are kept for rationale and are partly **out of date**:
> - Rank (MMR) is **profile-attached** ✅ (still holds)
> - **Champion Prestige** exists — per champion, 0-based, up *and* down, **decays**
> - **Champion Tier is DERIVED from prestige**, not purchased — this reverses §5's
>   central proposal
> - **Tier 5 = top-100 + threshold**, a sub-tier of Bastonium
> - **Monthly rewards** (bananas / vials / champions) paid on overall prestige
>
> Read §1, §2, §6, §7 and §8 here for current state and drift; read the spec for design.

**Sources reconciled** (three, and they disagree — see §8):

| # | Source | What it is | Age |
|---|--------|-----------|-----|
| **B** | `shared-drive/Design Documents/ArcasChampions GameBible Full.docx` | Original design intent, full game | 2022-ish, last touched 19 Jul 2026 |
| **D** | `Copy of ArcasChampion Progression.xlsx` + `Arcas Champions Early Access Database Structure.xlsx` | The unlock table, weapon stat table, asset ID scheme | design-era |
| **L** | Live DB (`ADMIN_ViewSchema`, 2026-08-05) + `server.js` + `ApeShooter@a83d7548b` | What actually runs | now |

Related: [[progression-system-status-2026-07]] (what's built), [[progression-system-plan]]
(target), [[barracks-vault-flow]] (the vault seam), [[database-structure.md]] (schema),
[[xp-leveling-system]] (the XP half that ships today).

---

## 1. The object graph (as-is, live)

```
                          ┌─────────────────────┐
                          │   PLAYER PROFILE    │  playerprofile
                          │  playerid (PK)      │  identity only
                          │  auth, wallet,      │
                          │  username, steamid  │
                          │  tutorialcomplete   │
                          └──────────┬──────────┘
                                     │ 1
             ┌───────────────┬───────┼────────────┬──────────────────┐
             │ 1             │ 1     │ 1          │ 1                │ N
             ▼               ▼       ▼            ▼                  ▼
   ┌──────────────┐ ┌──────────────┐ ┌─────────┐ ┌──────────────┐ ┌────────────┐
   │ PROGRESSION  │ │    VAULT     │ │  RANK   │ │  LOADOUTS    │ │ CHAMPIONS  │
   │ playerprog.  │ │ playervault  │ │playerrank│ │playerloadouts│ │ champions  │
   ├──────────────┤ ├──────────────┤ ├─────────┤ ├──────────────┤ ├────────────┤
   │ total_xp ★   │ │ primary[]    │ │ rank    │ │ loadout1..5  │ │ champid PK │
   │ level        │ │ secondary[]  │ │  =2500  │ │  (jsonb)     │ │ playerowner│
   │ pending_lvlup│ │ melee[]      │ │ delegVP │ │  {Champion,  │ │ gender     │
   │ updated_at   │ │ dmgTotems[]  │ │ permVP  │ │   Weapons[3],│ │ skinteam   │
   └──────┬───────┘ │ utilTotems[] │ └─────────┘ │   Totems[3]} │ │ health     │
          │         │ superTotems[]│   🔒 stays  └──────┬───────┘ │ strength   │
          │         └──────┬───────┘   profile-        │         │ intelligence│
          │ derives        │ gates      attached        │         │ agility    │
          ▼                └────────────────────────────┘         │ luck       │
   ┌──────────────┐                                                │ name       │
   │progression_  │  ┌───────────────────┐                        │ ✗ NO TIER  │
   │  levels      │  │  MATCH HISTORY    │ match_history          └────────────┘
   │ level → xp   │  │ match_id,playerid │ (live, undocumented
   │ (70 rows)    │  │ result,K/D/A,rankd│  until now)
   └──────────────┘  └───────────────────┘
   ★ = authoritative; everything else derived or cached
```

**Read of the graph**: the profile is a hub with five 1:1 satellites and one 1:N
(champions). Everything progression-shaped hangs off `playerid` — and per the locked
decision, **it stays that way**. Champions are inert stat containers today; §5 gives
them their own axis.

---

## 2. Entity by entity — designed vs live

### 2.1 Player Profile
Identity only. No progression fields. ✅ live matches design.

### 2.2 Account Progression (`playerprogression`) — **BUILT, shipping**
`total_xp` (authoritative, cumulative, monotonic) → `level` derived from
`progression_levels`. 70-level convex curve, max 38,970 XP. Per-match XP =
base (win 100 / loss 40) + `min(120, 3K + A − 3D)`, floored at 10 → **range 10–220**.

- **B**: "Player Profile Level unlocks: Weapons, Weapon Mods, Totems, Skins, Consumables."
- **D**: 100-level table with a named reward at nearly every level up to 79.
- **L**: 70 levels, **zero rewards attached**. The level is a number with no consequence
  beyond darkening/brightening icons in `W_PlayerProgression`.

→ **The unlock table exists in D and has never been entered anywhere.** This is the
single largest piece of already-done design work sitting unused.

### 2.3 Vault (`playervault`) — the ownership ledger
Six `INT[]` arrays of offset-encoded IDs. Granted **in full** at registration by
`initialize_player_associations()`. Gates loadouts server-side via `validate_loadout`
triggers, which already work.

**Designed contents (D) vs live**: the design-era "Player Vault" object also held
`Suspicious Vials`, `Ancient Scrolls`, `Bananas`, `Champions[]`. **None of the three
consumables exist anywhere in the live DB.** See §6.

### 2.4 Champions (`champions`) — inert today
5 stats (health/strength/intelligence/agility/luck), gender, skinteam, name.
Created via marketplace/unpack flow, owned by a player, referenced by a loadout.

**Stats DO reach gameplay** — verified this session, contradicting the assumption that
they're cosmetic:
```
LyraCharacter.cpp:588   ASC->AddBASBaseStatsAbilities(StatsAbilities, PlayerInfo.Champion.Stats)
   └─ each stat becomes an FGameplayAbilitySpec at Level = the stat value (4–12)
      └─ ability scales off CT_PlayerStats curve tables (MinLevel 1 … MaxLevel 20)
```
So a champion's stat value is a **curve index**. The mechanism for "a number on the
champion changes combat" is already built and working — **and it is the rail the
Champion Tier system in §5 rides on.**

⚠️ Note `LyraCombatComponent.cpp:79-82` separately initialises the same attributes at
`GetMinLevel()` (=1) as a base. The champion's stat abilities layer on top. Confirm
ordering in-editor before tuning anything.

### 2.5 Rank (`playerrank`) — 🔒 **stays on the profile**
Live: one `rank INT` default 2500, ±25 flat per ranked match, plus two SkillStaking
voting-power columns. That is the entire ranking system.

**The Bible said the opposite** — worth recording, because parts of the client were
built to it:
> "*The rank is solely tied to the Ape Champion Character; it's not profile based.*"
> "**Champion Prestige** — by winning ranked games your selected champion will obtain
> Prestige... prestige is the parameter used to set the leaderboard ranks."

**We are not doing that.** Rank measures the *human*, not the asset. §4 covers what
that buys us and what it costs.

### 2.6 Loadouts (`playerloadouts`) — already the roster
Five JSONB slots, each `{Champion, Weapons[3], Totems[3]}`. `validate_loadout` enforces
champion ownership, initialised+unpacked, **a champion cannot sit in two loadouts**, and
every weapon/totem must be in the vault.

→ **The 5 loadout slots ARE the bible's "roster of up to 5 champions"**, and the
one-champion-one-slot rule is already enforced. We don't need to build a roster; we
have one.

### 2.7 Match History (`match_history`) — live, was undocumented
`match_id, playerid, result, kills, deaths, assists, ranked, created_at`. Written
(non-fatally) by `awardMatch`; read back by an endpoint at `server.js:2233`.
No `champid` column — fine now that rank is profile-scoped, but we'd want one if we
ever attribute performance per champion.

---

## 3. The three axes

Rank on the profile means we now have **three** distinct progressions. They must not
be collapsed into each other:

| | **ACCOUNT LEVEL** | **ACCOUNT RANK (MMR)** | **CHAMPION TIER** |
|---|---|---|---|
| Attaches to | `playerid` | `playerid` 🔒 | `champid` |
| Earned by | playing (any mode) | winning ranked | **investing** (currency/vials) |
| Direction | monotonic ↑ | bidirectional ↕ | monotonic ↑ (purchased) |
| Represents | time invested | current skill | investment in one asset |
| Grants | **content** — weapons, totems, mods, skins, consumables | **status** — matchmaking, leaderboard league, shield, SkillStaking yield | **capability ceiling** — see §5 |
| Cap | L70 live / L100 designed | uncapped ladder | 5 tiers (proposed) |
| Live today | ✅ built | 🟡 stub (flat ±25) | ❌ nothing |

The important property: **Level and Tier are earned by playing; Rank is earned by
winning.** Only the first two grant capability. That keeps the ladder honest — see §4.

---

## 4. ⚠️ Rank must not touch stats (holds under the new decision)

Now that rank is profile-attached the temptation is bigger, not smaller: one number per
human, easy to scale things off. Don't.

**If rank raises stats, the game acquires a positive feedback loop.** Winning → higher
rank → higher stats → easier winning. Because matchmaking pairs you with people near
your rank, the advantage lands precisely on the opponents least able to absorb it. It
also corrupts SkillStaking: if rank buys power, rank stops measuring skill and starts
measuring the advantage it granted itself — and rank *is* the RWA the whole protocol
prices.

| Option | Rank → power | Verdict |
|---|---|---|
| **A. Rank is status only** | none | ✅ **Recommend.** Leaderboard, shield league, card frame, staking yield, matchmaking. |
| **B. Rank gates cosmetics** | indirect | Fine. Shield tiers unlock skins/emotes/card art. |
| **C. Rank scales stats** | direct | ❌ Advise against, for the reasons above. |

**Power should come from the other two axes** — account level (unlocks content) and
champion tier (raises a ceiling you invest into). Both are available to any player who
plays, regardless of whether they win. Same growth fantasy, no death spiral.

### What the profile-attached decision buys us

1. **Buying a champion cannot buy *rank*.** MMR stays with the human, so matchmaking and
   any per-human skill signal are unpurchasable.
   ⚠️ **But after D2 the exploit returns for *prestige*** — which is champion-scoped and
   therefore tradeable. That is why [[progression-ranking-spec]] §7.3 proposes prestige
   resetting to 0 on Black Market transfer.
2. ~~**The "prestige splits across deployed champions" rule disappears.**~~
   **Correction (after D2):** this was true of *rank*, but Champion Prestige is
   champion-scoped, so the split rule is **live again** the moment mid-match champion
   swapping ships. Tracked in [[progression-ranking-spec]] §7.2.
3. **One number per human for matchmaking.** Champion-scoped MMR would have meant a
   player's effective skill changed with their loadout slot — a matchmaking nightmare.
4. **SkillStaking gets the right primitive.** You stake under a *player*. That is what
   the pitch has always said.

### What it costs

- **Client code was built champion-scoped** and needs reinterpreting (§5.1). It's small.
- **We lose the "my champion has a record" fantasy.** §5 is how we give that back —
  through investment rather than win/loss.

---

## 5. Champion Tier — ⚠️ SUPERSEDED by [[progression-ranking-spec]] §3

> **Outcome**: Dan chose a different mechanism than this section proposed. Tier is
> **derived from Champion Prestige** (earned by winning ranked matches), *not* purchased
> with currency. §5.2's "Tier is the stat ceiling" proposal is **dead** — the stat budget
> (25→50) is now spent with vials alone, decoupled from tier, precisely to avoid the
> win-more loop that a prestige-derived tier would otherwise create.
>
> **§5.1 below is still valuable** — it inventories the champion-scoped scaffolding that
> already exists in the client, which the spec builds on. §5.2–5.5 are superseded.

### 5.1 What already exists (more than expected)

Found in the client this session — the champion-scoped scaffolding is **already there**,
it's just mock:

| Artefact | Where | State |
|---|---|---|
| `FLeaderboardChampion.RankValue` (int32) | `CommonUIStructs.h:403` | per-champion number, unused |
| `FBlackMarketChampion.ActivePrestigeLevel` / `PassivePrestigeLevel` | `CommonUIStructs.h:312/315` | **two** per-champion ints, unused |
| `FBlackMarketChampionFilter.PrestigeLevelMin/Max` | `CommonUIStructs.h:356/359` | you can already *filter the market by prestige* |
| Shield bands | `LeaderboardWidget.cpp:17` | `// Bamboo 0-50, Scavenger 50-100, Banana 100-150, Bastonium >150` — **"for now pretend"** |
| `MinimumRankShieldsImages` | `LeaderboardWidget.h:66` | `TMap<int32 minRank, Texture>` — **data-driven, editable in the widget, no code change to reband** |
| Leaderboard data source | `LeaderboardWidget.cpp:30` | `// TODO: Get ULeaderboardSubsystem* or URankSubsystem*` — entirely mock |
| `Champion Object → Tier` | design sheet (D) | *"Tier = Banana, Scavenger..."* — **a Tier field was always in the design** |

→ We are not inventing Champion Tier. It was designed, partly scaffolded, and never
wired. And because rank moved to the profile, `FLeaderboardChampion` becomes "the
profile's showcased champion" (the Bible's PFP rule: your slot-1 champion is your face) —
decorative, small client change.

### 5.2 What a Tier should *mean* — the proposal

Anchor on the Bible's own numbers, which already describe an upgrade track:

> "The champion card **natively starts with 25 stat points**, but the player can buff its
> stats **up to 50 stat points**." · "**Suspicious Vials**: the player must use this item
> in order to level up champion stats."

So the Bible already has: a starting budget, a ceiling, and a currency to move between
them. **Tier is the ceiling.** That is the cleanest possible meaning — one INT on the
champion, riding the GAS stat rail that already works (§2.4), spending a consumable
that's already designed (§6).

**Strawman ladder** (numbers to argue with, names see ⚠️ below):

| Tier | Total stat points | Unlocks | Upgrade cost |
|---|---|---|---|
| **T1** | 25 (as generated) | — | — (start here) |
| **T2** | 31 | card frame 2 | bananas + vials |
| **T3** | 37 | card frame 3 | ↑ |
| **T4** | 44 | card frame 4 | ↑ |
| **T5** | 50 (Bible max) | card frame 5, market prestige | ↑↑ |

Within a tier, **Suspicious Vials** spend the budget point by point across the 5 stats.
Tier raises the roof; vials fill the room. Two currencies, two decisions, both earned by
playing.

⚠️ **Naming conflict to resolve.** The shield names (Bamboo / Scavenger / Banana /
Bastonium / Champion of Arcas) are already used in live client code for **leaderboard
leagues**, which under the locked decision are now *profile rank* bands. If champion
tiers reuse them, "Bastonium" means two different things in two menus. **Recommend:
shields stay with profile rank; champion tiers get their own names** (Bible has plenty
of unused vocabulary — Scrap / Forged / Relic / Ancient / Apex).

### 5.3 Alternatives considered

| Model | What tier grants | Why not (yet) |
|---|---|---|
| **A. Stat ceiling** *(recommended)* | raises the 25→50 budget | uses existing rail + existing currency; one column |
| B. Slot unlocks | extra totem or weapon-mod slot | bigger balance swing than stats; no slot system built |
| C. Cosmetic only | card frame / VFX | zero balance risk, but then "upgrade" means nothing mechanically and vials have no home |
| D. Prestige multiplier | champion earns more rank | ❌ dead on arrival — rank is profile-scoped now, and this reintroduces pay-to-win |

A + C together is likely the shipping answer: mechanical ceiling **and** visible flex.

### 5.4 ⚠️ The open risk: T5 vs T1 is a power gap

A 50-point champion against a 25-point champion is a real advantage in a PvP shooter,
and unlike rank it *is* purchasable on the Black Market. Options:

- **(a) Narrow the spread** — cap at, say, 25→38 instead of 25→50.
- **(b) Measure first.** We do not actually know what a stat point is worth. It's a
  curve index into `CT_PlayerStats` (MinLevel 1 … MaxLevel 20). If the curve is gentle,
  25→50 may be a few percent; if steep, it's decisive. **This is readable in the editor
  in minutes and should happen before any number here is fixed.**
- (c) Tier-bracketed matchmaking — rejected, fragments an already-small queue.
- (d) Normalise tiers in ranked only — splits the game into two rulesets.

**Recommend (b) then (a):** measure the curve, then pick a spread that's felt but not
decisive.

### 5.5 ⚠️ Does Tier survive a Black Market sale?

The one genuinely unresolved question, and it's a direct trade:

- **Tier survives the sale** → champions have real market value, the economy works, but
  a player can *buy power* (not rank — power). Pay-to-win vector.
- **Tier resets on sale** → balance protected, but a T5 champion is worth no more than a
  T1, and the Black Market loses most of its reason to exist.
- **Middle**: tier survives, but the *vial-spent stat allocation* resets — you buy the
  roof, not the furnishing. Keeps market value, halves the p2w.

**Leaning the middle option.** Needs Dan + Marco.

---

## 6. The economy / consumables gap

Bible defines three consumables. **Zero are implemented anywhere.** With §5, two of them
now have a concrete job.

| Item | B's purpose | Job under this model | D | L |
|---|---|---|---|---|
| **Bananas** | soft currency — buy champions (1000) & skins | **Tier upgrades** + market + skins | in vault, awarded at ~10 levels | ❌ nothing |
| **Suspicious Vials** | raise one champion stat by 1 | **spend the tier budget** | in vault, awarded at ~12 levels | ❌ nothing |
| **Ancient Scrolls** | swap a champion's totem | totem reconfiguration | in vault, awarded at ~11 levels | ❌ nothing |

There *are* client-side request classes with **no server implementation**:
`BoostStat`, `InfuseTotem`, `Purchase`, `UseConsumable` (per [[barracks-vault-flow]]).
Note the names: **`BoostStat` is exactly the vial-spend endpoint §5 needs**, and
`InfuseTotem` is the scroll. The client was built for this economy years ago; the API
never got it.

→ Adding `bananas`, `vials`, `scrolls` as three `INT` columns on `playervault` is a
~30-line change that unblocks both the designed unlock table *and* the tier system.
Cheapest high-value move on the board.

---

## 7. The ID bridge (the known blocker)

Ownership uses **offset-encoded uint8** (`LoadoutDAO.h`): primaries 101+, secondaries
201+, melee 301+, damage totems 401+, utility 501+, super 601+.
`DT_PlayerProgressionItems` identifies the same items by **Blueprint class** (`ID_Rage_C`).
Nothing maps between them, so a level-up cannot become a vault grant.

**The Asset Identifiers sheet (D) is the missing map** and nobody has used it:

```
PRIMARY   101 PISTOL · 102 DBSHOTGUN · 103 MELONRIFLE · 104 SNIPER · 105 BANANAPISTOL
          106 MADRIFLE · 107 MadSMG · 108 NailSMG · 109 PlasmaShotgun · 110 AlienRailgun
SECONDARY 201 SHOTGUN · 202 GRENADELAUNCHER · 203 ROCKETLAUNCHER · 204 TRAPGUN
          205 MadZooka · 206 MadBlower
MELEE     301 MACHETE · 302 RELICSWORD · 303 CombatKnife · 304 Axe · 305 Spear
DMG TOTEM 401 GRENADE · 402 SUPERCHARGE · 403 RAGE
UTIL TOTEM 501 PERSONALHEALING · 502 AMMOCRATE · 503 ANIMALINSTINCT · 504 DISGUISE
SUPER      601 TEAMHEALING · 602 AUTOTURRET · 603 CHIMPCOMPANION
```

⚠️ **Live ranges are narrower than the design sheet** — `initialize_player_associations()`
grants primaries `101-105` (design defines **110**), secondaries `201-204` (design **206**),
melee `301-302` (design **305**). So MadRifle, MadSMG, NailSMG, PlasmaShotgun,
AlienRailgun, MadZooka, MadBlower, CombatKnife, Axe, Spear **have design IDs but are
not grantable today** — they exist only in the local `DT_AllVaultItems`, which is why
"everyone sees everything" masks it.

### 🎯 The starter kit is already settled — two sources agree independently
Design sheet cells J3–L3 / J5–L5 name a 6-item base kit:
**Pistol · Blend Gun · Hunting Knife + Grenade · Personal Healing · Turret**
`DT_PlayerProgressionItems` (25 unlockable items) **excludes exactly those six**.
Two artefacts, made years apart, drawing the same line. Treat this as decided.

⚠️ But the IDs don't line up: "Hunting Knife" = `303`, which is **outside** the live
melee grant `[301,302]`; and the default loadout jsonb ships `601 TeamHealing` as the
super totem while the starter kit says `602 Turret`. Needs a reconcile pass before we
shrink the vault.

---

## 8. Where the three sources disagree (the drift register)

| # | Topic | Bible (B) | Design (D) | Live (L) | Status |
|---|---|---|---|---|---|
| 1 | Rank scope | champion-only | — | player-only | 🔒 **RESOLVED — profile wins** |
| 2 | Champion tier | not defined | `Tier` field on Champion Object | none | 🟡 §5 proposal |
| 3 | Level cap | — | 100 (rewards to 79) | 70 | 🟡 pick one |
| 4 | Unlock rewards | 5 categories | full per-level table | none wired | 🔴 biggest unused asset |
| 5 | Consumables | 3 defined | in vault + reward table | none exist | 🔴 blocks economy + tiers |
| 6 | Champion stats | 25 native, 50 max | — | 4–12 per stat (20–60) | 🟡 §5.2 reconciles |
| 7 | Grantable item range | 21 weapons / 10 totems | 21 IDs assigned | 11 weapons grantable | 🟡 extend arrays |
| 8 | Starter kit IDs | — | Pistol/BlendGun/HuntingKnife | knife `303` ∉ granted range | 🟡 reconcile |
| 9 | Champion roster | 5, swap mid-match | — | 5 loadout slots, no mid-match swap | 🟢 mostly there |
| 10 | Shield tiers | "4 stages", lists **5** names | — | bands in a code comment, mock | 🟡 now = profile rank leagues |
| 11 | Leaderboard | per champion | — | mock, `// TODO: RankSubsystem` | 🟡 reinterpret as profile |
| 12 | Weapon tuning/mastery | trials unlock sliders | full stat + slider table | `TuningTable` UI, no backend | 🟡 later phase |

---

## 9. Open decisions — ⚠️ moved to [[progression-ranking-spec]] §11

Resolved since this doc was written:

| | Question | Outcome |
|---|---|---|
| Q1 | Rank scope | 🔒 **profile-attached** |
| Q3 | What Tier grants | 🔒 **status + monthly rewards; derived from prestige, not purchased** |
| Q5 | Tier names | 🔒 **the shield names ARE the champion tiers** — Bamboo / Scavenger / Banana / Bastonium + *Champion of Arcas* as a top-100 sub-tier. No naming conflict: leagues and tiers are the same thing, and the Bible's "4 stages but 5 names" contradiction is explained |
| Q6 | Tier/prestige on a market sale | proposed **reset to 0** (spec §7.3) — still needs sign-off |

Still open — tracked in the spec's §11 table: rank↔stats (Q2), tier band numbers (Q4),
level cap 70 vs 100 (Q7), vault grandfathering (Q8).

---

## 10. Suggested build order

Nothing here needs the build VM except steps 5 and 7.

1. **Consumables** — `bananas`/`vials`/`scrolls` INT columns on `playervault`, exposed in `GET_Profile`.
2. **Reward table** — `progression_levels` gains `reward_type` + `reward_id` + `qty`; enter D's table (compressed to 70).
3. **Grant on level-up** — `awardMatch` writes the reward into `playervault` / consumable columns. Ownership becomes real.
4. **Shrink starter kit** — rewrite `initialize_player_associations()` to the agreed 6 items; reconcile the ID mismatches in §7.
5. **Close the client seam** — `Vault.cpp:103` `AddWeaponSlots`/`AddTotemSlots`, filter `DT_AllVaultItems` by owned IDs. *(needs VM)*
6. **Champion Tier backend** — `champions.tier INT default 1` + `POST_UpgradeChampionTier` + `POST_BoostStat` (the vial spend). Stat cap enforced server-side in `enforce_champion_initialization()`.
7. **Champion Tier client** — card frame by tier, tier-up flow in Barracks, wire the dead `BoostStat`/`Purchase` request classes. *(needs VM)*
8. **Leaderboard** — reinterpret as profile-ranked; implement `URankSubsystem` behind the existing mock widget.

Steps 1–4 and 6 are pure API/DB and can start immediately, VM or no VM.

---

## 11. Not yet examined

- **`CT_PlayerStats` curve values** — blocks Q4. Editor read, minutes of work.
- `DT_PlayerProgressionItems` per-item `ItemCollectLevel` — binary int32, needs the editor.
  **Marco can read these off in 5 minutes**; D's table is our best proxy meanwhile.
- What `ActivePrestigeLevel` vs `PassivePrestigeLevel` were meant to be (§5.1) — possibly
  maps onto `playerrank.delegatedvotingpower` / `permanentvotingpower`. Ask Marco.
- Weapon Mods (12 designed, icons committed by ElTraktor `a83d7548b`, 29 Jul) — Bible says
  "3 native mods stored inside your weapons", implying a per-weapon-instance record we don't have.
- Weapon tuning sliders + mastery trials (drift #12).
- Story mode / survival (Tschego's Lab) and `zap coins` — a **fourth** currency, mode-local.
- Seasons. Nothing exists; Bible barely covers it.
