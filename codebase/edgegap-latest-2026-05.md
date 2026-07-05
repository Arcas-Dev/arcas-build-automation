# Edgegap Latest — May 2026

**Doc-snapshot date:** 2026-05-16
**Sources:** see bottom
**For:** Arcas Champions player-lobby/group-matchmaking implementation
**Verdict:** **No Edgegap-native lobby service.** Pair Edgegap *groups* with Steam Lobbies (OnlineSubsystemSteam) on our end. EGIK is still the right plugin; pin v1.7 (UE5.5-compatible) and use V2-beta branch only if you want bleeding edge.

---

## 1. TL;DR (5 bullets)

1. **Matchmaker is at 3.2.2** (patch over 3.2.1 — no breaking changes for us). Native **Group Up** matchmaking is GA. `min_team_size` / `max_team_size` / `team_count` is now mandatory — `team_size` is dead.
2. **No Edgegap native Lobby** exists. The recommended pattern is identical to what we had planned: Steam/EOS lobby holds the shared `group_id`, members create memberships using it, owner triggers ticket. (Edgegap published a fresh EOS-lobby integration guide on 2026-05-15.)
3. **EGIK v1.7** (April 2025) supports Edgegap matchmaker API v2.1.0 with `GetGroupPlayerMapping`, team IDs, and the new backfill structure (`attributes.assignment.request_id`). A **V2-beta branch was merged 2026-04-20** with API tweaks and a deployer-key refactor — main branch is fine for us.
4. **Unity SDK v3.0.0 dropped 2026-05-13** with breaking changes (`_Abandon → StopMatchmaking`, `onTicketUpdate → onAssignmentUpdate`, removed caching, duplicate-ticket conflict detection). UE/EGIK has *not* shipped an equivalent v3 yet — stay on v1.7 / v2.1.0 API patterns.
5. **Our commented-out `FGroupTicketRequestBody` code is obsolete.** The current API uses **Groups + Memberships** as separate resources: `POST /groups` → share group_id via lobby → each member `POST /v1/groups/{group_id}/memberships` → owner `PATCH` to ready → poll ticket assignment. Rewrite from scratch using EGIK's Blueprint nodes.

---

## 2. Current matchmaker version + breaking changes since 3.2.1

| Item | Value |
|---|---|
| Current version | **3.2.2** (patch — no breaking changes) |
| Group Up GA | 3.2.0 (Oct 2025) — still current |
| Server Browser | v1.0.0 (2026-05-13) — separate service, not relevant for our flow |
| Unity SDK | **v3.0.0** (2026-05-13) — breaking changes vs SDK 2.x but **REST API unchanged** |
| EGIK | v1.7 (2025-04-13) targeting Edgegap API v2.1.0 |

**Breaking changes from 3.2.1 → 3.2.2:** none documented. Bug-fix release.

**Profile schema status:**
- `team_size: N` — **REMOVED in 3.2.x**. You must use `team_count`, `min_team_size`, `max_team_size`.
- New `group_inactivity_removal_period` (default `5m`) — cleans up stale groups.
- `backfill_group_size` with intersection rule is now the canonical way to keep parties together during backfill.

---

## 3. Groups/Lobbies API — current endpoints & lifecycle

> Edgegap does NOT host a lobby. A "lobby" in Edgegap-speak = an *external* lobby system (Steam, EOS, custom) that holds the shared `group_id` so members can join the matchmaking group. Edgegap owns: groups, memberships, tickets, assignments, backfill.

### Authentication

```
Authorization: <your-auth-token>
```
Header name is `Authorization`, value is the raw token (no `Bearer` prefix). One token for both REST and Swagger.

### Endpoint summary (confirmed)

| Operation | Method | Path | Purpose |
|---|---|---|---|
| Create ticket (solo) | POST | `/tickets` | Single-player matchmaking |
| Get ticket / assignment | GET | `/tickets/{ticketId}` | Poll status |
| Delete ticket | DELETE | `/tickets/{ticketId}` | Cancel solo MM |
| Create group | POST | `/groups` | Owner-only |
| Join group | POST | `/groups/{group_id}/memberships` | Each member |
| Update membership (ready) | PATCH | `/groups/{group_id}/memberships/{member_id}` | Toggle `ready: true` |
| Get group status | GET | `/groups/{group_id}` | Poll group + assignment |
| Leave / cancel | DELETE | `/groups/{group_id}/memberships/{member_id}` | Member leaves |
| Delete group | DELETE | `/groups/{group_id}` | Owner cancels MM for whole group |

> **Note:** group/membership paths above are reconstructed from the documented flow + EGIK source. The authoritative source is `https://{your-matchmaker-url}/swagger/v1/swagger.json` — pull this once after the matchmaker deploys and pin it into our repo.

### Ticket request (POST /tickets)

```json
{
  "profile": "casual",
  "player_ip": null,
  "attributes": {
    "beacons": { "Chicago": 12.3, "Frankfurt": 23.2 },
    "elo_rating": 1450,
    "selected_game_mode": "Elimination",
    "selected_map": ["Jungle", "Volcano"]
  }
}
```

### Group lifecycle (status field on GET /groups/{group_id})

```
INITIAL          → group created, members joining
SEARCHING        → all members ready, ticket open
TEAM_FOUND       → enough players for one team
MATCH_FOUND      → enough teams for a match
HOST_ASSIGNED    → server deployment ready; read `assignment.fqdn` + `assignment.port`
CANCELLED        → owner deleted group or a TEAM_FOUND member left
```

Poll cadence: **3–5 s**. Stop on `HOST_ASSIGNED` or `CANCELLED`.

### Hard rules to design around

- Once group enters `SEARCHING` (any member ready), **no new memberships accepted** → finalise lobby before pressing Play.
- Member leaving *after* `TEAM_FOUND` **cancels the whole group's ticket**. Show a confirm dialog.
- After `MATCH_FOUND`, deleting the group returns `409 Conflict`. Don't bother retrying — just connect.
- Groups auto-purge after `group_inactivity_removal_period` (default 5m) of inactivity → owner must heartbeat (any membership operation counts) or rebuild the group.

### Backfill (server-owned)

- Server creates a backfill ticket post-launch with `backfill_group_size` attribute = current group sizes already on the server.
- New `backfill_group_size: { type: "intersection", overlap: 1 }` rule keeps backfilled players' party intact.
- Backfill structure (API v2.1.0): `attributes.assignment.request_id` (was `attributes.deployment_request_id` in pre-2.1).

---

## 4. Unreal integration — recommended path

### Plugin choice

**Use EGIK (BetideStudio) main branch / v1.7.** Reasons:
- Edgegap's *own* `edgegap-unreal-plugin` is **deployment-only** (build container, push registry, create version). It has zero matchmaker/group code. Not what we need.
- EGIK is the Edgegap-endorsed "Verified Solution" and is now free on Fab/Marketplace.
- EGIK v1.7 already exposes Blueprint nodes for: tickets, groups, memberships, team-IDs, backfill, `GetGroupPlayerMapping`, `GetExpansionStage`, `GetMatchProfileName`.
- UE5.5 supported (folder exists in repo; covers 4.27 → 5.6).

### V2-beta branch (merged 2026-04-20)

Touches: deployer-key persistence in `.ini`, `SelfStopDeployment` simplification, dockerfile fixes, API request improvements. No matchmaker-flow changes. **Stay on main / v1.7 for now**; revisit when a tagged v2.0 ships.

### Wiring vs our current `MatchmakerComponent.cpp`

Our `// TODO PLAYER LOBBY` code uses `FGroupTicketRequestBody` and IP-based ticket distribution — that pattern is from pre-3.2 matchmaker (single-call group ticket). **Delete it.** Replace with the explicit Group + Memberships flow above. EGIK exposes one Blueprint node per operation, so the rewrite is mostly in BP/UMG (lobby UI) + a thin C++ wrapper that calls the EGIK functions.

### Steam lobby pairing

Populate `NAME_PartySession` (OnlineSubsystemSteam) and store the Edgegap `group_id` as a lobby attribute (e.g. key `EdgegapGroupId`). Members read the attribute on join, then POST membership. Identical pattern to the EOS guide Edgegap published 2026-05-15, just on Steam.

> **Production-security note from Edgegap:** do NOT let the lobby owner call the matchmaker API directly with a hard-coded token. Mediate through our backend (`ArcasChampionsAPI`) which holds the auth token. Owner asks our API → our API creates the group on Edgegap → returns `group_id` to owner → owner stores it in Steam lobby. Memberships likewise.

---

## 5. Config migration — exact changes to our profiles

### Current (legacy, pre-3.2 syntax)

```yaml
profiles:
  casual:
    rules:
      initial:
        match_size:
          type: player_count
          attributes:
            team_count: 2
            team_size: 8          # ← REMOVE
```

### New (3.2.2 syntax — apply to both casual and ranked)

```yaml
version: "3.2.2"
profiles:
  casual:
    ticket_expiration_period: "5m"
    ticket_removal_period: "1m"
    group_inactivity_removal_period: "5m"
    application:
      name: "arcas-champions"
      version: "testing-server"
    rules:
      initial:
        match_size:
          type: player_count
          attributes:
            team_count: 2
            min_team_size: 6      # allow short-handed start after expansion
            max_team_size: 8
        beacons:
          type: latencies
          attributes:
            difference: 125
            max_latency: 125
        elo_rating:
          type: number_difference
          attributes:
            max_difference: 100
        selected_game_mode:
          type: string_equality
        backfill_group_size:
          type: intersection
          attributes:
            overlap: 1
      expansions:
        "30":
          elo_rating: { max_difference: 200 }
          beacons:    { difference: 200, max_latency: 200 }
        "60":
          elo_rating: { max_difference: 400 }
        "120":
          match_size: { team_count: 2, min_team_size: 4, max_team_size: 8 }
          beacons:    { difference: 99999, max_latency: 99999 }

  ranked:
    ticket_expiration_period: "5m"
    ticket_removal_period: "1m"
    group_inactivity_removal_period: "5m"
    application:
      name: "arcas-champions"
      version: "testing-server"
    rules:
      initial:
        match_size:
          type: player_count
          attributes:
            team_count: 2
            min_team_size: 4
            max_team_size: 4    # ranked = strict 4v4, no short-handed
        beacons:
          type: latencies
          attributes:
            difference: 80
            max_latency: 100
        elo_rating:
          type: number_difference
          attributes:
            max_difference: 50
        selected_game_mode:
          type: string_equality
        backfill_group_size:
          type: intersection
          attributes:
            overlap: 1
      expansions:
        "45":
          elo_rating: { max_difference: 100 }
          beacons:    { difference: 150, max_latency: 200 }
        "90":
          elo_rating: { max_difference: 200 }
        "180":
          beacons:    { difference: 300, max_latency: 300 }
```

**Key migration deltas:**
- `team_size: N` → `min_team_size` + `max_team_size`
- Add `group_inactivity_removal_period`
- Add `backfill_group_size` intersection rule (keeps parties together in backfill)
- Casual: relax min via expansion to allow 4v4 starts after 2 min queue
- Ranked: keep strict, only relax ELO + latency over time
- Both: profiles route to the same Edgegap application+version (`arcas-champions / testing-server`) — that's already correct in our setup

### Backfill server attribute (set on server when it starts the backfill ticket)

```json
{
  "backfill_group_size": [3, 2, 1, 1, 1]   // current group sizes already on server
}
```
The intersection rule with `overlap: 1` ensures any incoming group will fit into a remaining slot without splitting them.

---

## 6. Punch list — do this, in this order

### P0 (this session — unblocks lobby work)

1. **Update both profile configs in `matchmaker-config/`** to 3.2.2 syntax (section 5 above). Test with `curl` against staging matchmaker before pointing the game at it.
2. **Delete all `// TODO PLAYER LOBBY` code in `MatchmakerComponent.cpp`** referencing `FGroupTicketRequestBody`. It's an obsolete pattern — clean slate is faster than porting.
3. **Pull EGIK v1.7 from main into our `Plugins/` folder** if not already there. Verify the Blueprint nodes appear: `CreateGroup`, `CreateMembership`, `MarkMembershipReady`, `GetGroupStatus`, `GetGroupPlayerMapping`.
4. **Add backend group-broker endpoints to `ArcasChampionsAPI`:**
   - `POST /api/groups` — proxies to Edgegap `POST /groups`, returns `group_id`
   - `POST /api/groups/{id}/memberships` — proxies, returns `membership_id`
   - `PATCH /api/groups/{id}/memberships/{mid}/ready` — proxies ready toggle
   - `GET /api/groups/{id}` — proxies status
   - `DELETE /api/groups/{id}/memberships/{mid}` — proxies leave
   - Auth: use existing player JWT, never expose Edgegap token to client.

### P1 (next session)

5. **Steam Lobby integration (OnlineSubsystemSteam):** create `NAME_PartySession` lobby on "Play with Friends" press, store `group_id` as a lobby attribute. Add `OnLobbyMemberJoined` handler that POSTs membership.
6. **Lobby UMG:** show party members, ready toggle per member, owner-only "Start Matchmaking" button (calls `PATCH ready` for all members or just gates on all members ready).
7. **Wire dedicated server backfill ticket** at server boot — call `POST /tickets` with `backfill_group_size` array, server-side using `DedicatedServerBackendSubsystem`.

### P2 (later — defer)

8. Reconnect flow (cache `group_id` + `membership_id` on client, allow resume on disconnect within 60s).
9. Migrate to EGIK V2 once a tagged release ships.
10. Track Unity SDK v3 — if it presages a UE SDK v3 with `onAssignmentUpdate` rename, refactor event listener names.

### Leave alone

- Server build / Cloud Build / Edgegap registry push pipeline — unaffected.
- Solo `elimination` matchmaker in production — keep as-is until party flow ships in `arcas-testing`, then unify.
- Application + Version (`arcas-champions / testing-server`) — both new profiles already target this, no change.

---

## 7. Sources

- [Matchmaking overview](https://docs.edgegap.com/learn/matchmaking) — 3.2.2 confirmed, rule type catalogue
- [Matchmaker in-depth](https://docs.edgegap.com/learn/matchmaking/matchmaker-in-depth) — group lifecycle, ticket statuses, constraints
- [Release notes](https://docs.edgegap.com/docs/release-notes) — Unity SDK v3.0.0 (2026-05-13), Server Browser v1.0.0
- [Edgegap platform: Matchmaker & Lobbies](https://edgegap.com/en/platform/matchmaker-lobby) — Group Up positioning
- [Edgegap blog: EOS Lobbies vs Sessions](https://edgegap.com/blog/eos-lobbies-vs-sessions-and-how-to-add-matchmaking) — published 2026-05-15, recommended group-via-lobby pattern
- [Unreal+EOS lobby integration doc](https://docs.edgegap.com/docs/tools-and-integrations/unreal-eos-lobby-integration) — direct deploy pattern (alternative, not for us)
- [Official Edgegap UE plugin](https://github.com/edgegap/edgegap-unreal-plugin) — deployment only, no MM support
- [EGIK README](https://github.com/betidestudio/EdgegapIntegrationKit) — v1.7 changelog, API v2.1.0 features
- [EGIK V2-beta PR #7](https://github.com/betidestudio/EdgegapIntegrationKit/pull/7) — merged 2026-04-20, no MM flow changes
- [EGIK docs](https://egik.betide.studio/) — Blueprint node reference
- [Edgegap API auth](https://docs.edgegap.com/docs/getting-started) — token header format
