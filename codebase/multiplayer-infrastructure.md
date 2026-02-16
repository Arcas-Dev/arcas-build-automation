# Multiplayer Infrastructure - Complete Guide

## Architecture Overview

```
UE5 Game Client
    │
    ├─ Reads DefaultBeviumTools.ini → QueryValueKey="casual" / QueryValueKey_Ranked="ranked"
    │
    ├─ GET_MatchmakerCredentials?type=casual|ranked
    │   → Returns: { Url, Token, Profile, Status }
    │
    ├─ GET /locations/beacons (ping measurement)
    │   → Returns beacon IPs per region, client pings each
    │
    ├─ POST /tickets (create matchmaking ticket)
    │   → Body: { profile, attributes: { beacons, selected_game_mode, selected_map } }
    │   → Returns: { id, group_id, status: "SEARCHING" }
    │
    ├─ GET /tickets/{id} (poll every 1.5s, max 200 attempts = 5 min)
    │   → When status = HOST_ASSIGNED:
    │     { assignment: { fqdn, public_ip, ports: { gameport: { external } } } }
    │
    └─ ClientTravel to <public_ip>:<gameport.external>?MMTicketId=X&EpicId=Y&ArcasId=Z
         │
         ▼
Edgegap Dedicated Server Container (Ubuntu 22.04 + UE5 -server)
    │
    ├─ Reads ARBITRIUM_CONTEXT_URL → GET deployment context (FQDN, ports, etc.)
    ├─ Reads MM_MATCH_PROFILE, MM_MATCH_ID
    ├─ Reads MM_EQUALITY → { selected_game_mode: "Elimination" }
    ├─ Reads MM_INTERSECTION → { selected_map: ["Irrelevant"] }
    ├─ Reads MM_TICKET_IDS → ["ticket-123", "ticket-456", ...]
    ├─ Reads MM_TICKET_{id} → per-player data (IP, group_id, team_id, attributes)
    │
    ├─ Verifies connecting players' MMTicketId against injected tickets
    ├─ Selects game mode from MM_EQUALITY.selected_game_mode
    ├─ Selects map from MM_INTERSECTION.selected_map[0] (currently always "Irrelevant")
    │
    └─ On match end: POST /POST_RankedMatchResults (winners/losers → rank update)
```

---

## Current UE5 Code (Source of Truth)

### File Map

All paths relative to `C:\A\ApeShooter\NewApeShooter\`

**Core Matchmaking:**

| File | Purpose |
|------|---------|
| `Source/LyraGame/Matchmaking/EdgegapComponent.h/.cpp` | Base component for Edgegap API interactions |
| `Source/LyraGame/Matchmaking/MatchmakerComponent/MatchmakerComponent.h/.cpp` | Main matchmaker client (ticket creation, polling, connection) |
| `Source/LyraGame/Matchmaking/MatchmakerComponent/RankedMatchmakerComponent.h/.cpp` | Ranked variant (sets `bIsRanked = true`, uses separate credentials) |
| `Source/LyraGame/Matchmaking/DeploymentComponent/DeploymentComponent.h/.cpp` | Server-side: reads Edgegap env vars (ARBITRIUM_CONTEXT_URL/TOKEN) |
| `Source/LyraGame/Matchmaking/MockServer/MockServerComponent.h/.cpp` | Local dev mock server (localhost:3000) |
| `Source/LyraGame/Matchmaking/Subsystems/MatchmakingServerSubsystem.h/.cpp` | Server-side player acceptance tracking |

**HTTP Request Classes:**

| File | Edgegap Endpoint | Purpose |
|------|-----------------|---------|
| `Backend/Requests/Matchmaker/EdgegapCreateTicketsRequest.h/.cpp` | `POST /tickets` | Create ticket |
| `Backend/Requests/Matchmaker/EdgegapReadTicketInformationRequest.h/.cpp` | `GET /tickets/{id}` | Poll status |
| `Backend/Requests/Matchmaker/EdgegapDeleteTicketRequest.h/.cpp` | `DELETE /tickets/{id}` | Cancel |
| `Backend/Requests/Matchmaker/EdgegapLocationsBeaconsRequest.h/.cpp` | `GET /locations/beacons` | Get ping targets |
| `Backend/Requests/Matchmaker/EdgegapMonitorRequest.h/.cpp` | `GET /monitor` | Health check |
| `Backend/Requests/Matchmaker/Deployment/EdgegapDeploymentContextRequest.h/.cpp` | `GET {ARBITRIUM_CONTEXT_URL}` | Server deployment info |
| `Backend/Requests/BAS/GetMatchmakerCredentialsRequest.h/.cpp` | `GET /GET_MatchmakerCredentials?type=X` | Get Edgegap creds from our API |

**Data Structures (BlockApeScissors Plugin):**

| File | Contains |
|------|----------|
| `Plugins/BlockApeScissors/.../Matchmaker.h` | `FMatchmakerCredentials`, `FMatchmakerError` |
| `Plugins/BlockApeScissors/.../Ticket.h` | `FTicketReceipt`, `FAssignment`, `FPortsWrapper`, `FAssignmentPort`, `FTicketAttributes`, `FCreateSimpleTicketRequestBody`, `FCreateAdvancedTicketRequestBody`, `FGroupTicketRequestBody` |
| `Plugins/BlockApeScissors/.../Beacon.h` | `FBeacon`, `FBeaconList`, `FLocation` |
| `Plugins/BlockApeScissors/.../InjectedVariable.h` | `FMatchEquality`, `FMatchIntersection`, `FPlayerEnvVarValue` |
| `Plugins/BlockApeScissors/.../MMPlayer.h` | `FMMPlayer` |
| `Plugins/BlockApeScissors/.../Deployment.h` | `FDeploymentContext` |

**Backend Subsystems:**

| File | Purpose |
|------|---------|
| `Backend/Subsystems/MatchmakerBackendSubsystem.h/.cpp` | Routes HTTP to Edgegap matchmaker URL (quickplay) |
| `Backend/Subsystems/RankedMatchmakerBackendSubsystem.h` | Same but for ranked matchmaker |
| `Backend/Subsystems/ArcaschampionsapiBackendSubsystem.h` | Routes to Arcas Champions API (Cloud Run) |

### How Quickplay vs Ranked Works

Both use the exact same code path — they just get different credentials from the API:

| Aspect | Quickplay (`UMatchmakerComponent`) | Ranked (`URankedMatchmakerComponent`) |
|--------|-------------------------------------|---------------------------------------|
| `bIsRanked` | `false` | `true` |
| API query param | `QueryValueKey` = `"casual"` | `QueryValueKey_Ranked` = `"ranked"` |
| Backend subsystem | `UMatchmakerBackendSubsystem` | `URankedMatchmakerBackendSubsystem` |
| Game mode list | `QuickplayGameModeList` | `RankedGameModList` |

The client creates the ticket with `selected_game_mode` as a string. The matchmaker's `string_equality` rule ensures only players selecting the same mode match together.

### QueryValueKey Config Mechanism

The `type` query parameter sent to `GET_MatchmakerCredentials` comes from `DefaultBeviumTools.ini`:

```ini
[/Script/BeviumTools.BeviumToolsRuntimeSettings]
AdditionalParameters=(("QueryValueKey", "casual"),("QueryValueKey_Ranked", "ranked"))
```

- `UBeviumToolsRuntimeSettings` is a standard UE5 `UDeveloperSettings` (config file name: `BeviumTools`)
- Read at runtime via `GetDefault<UBeviumToolsRuntimeSettings>()->GetAdditionalParameter(Key)`
- Any `BuildCookRun` packages the ini file correctly — no special tooling needed
- Source: `Source/BeviumToolsGame/Public/BeviumToolsRuntimeSettings.h`

### Maps in Matchmaking (Current State)

**Maps are currently irrelevant for matchmaking.** The client hardcodes:

```cpp
// PlayMatchMenu.cpp → CreateSearchTicket()
const TArray<FString> Maps = {TEXT("Irrelevant")};
MMComponent->CreateAndSendGenericMatchmakingTicket(GameMode, Maps);
```

The matchmaker's `intersection` rule still matches (all players send the same `["Irrelevant"]` array), but the server gets a meaningless value in `MM_INTERSECTION.selected_map[0]`.

**Actual map selection** happens server-side, likely via the game mode's `ExperienceDefinition` or `MapPoolDataAsset`, NOT from the matchmaker ticket.

### Known Map Files

Located in `Plugins/GameFeatures/BASMaps/Content/Maps/`:

| Map | Type | Notes |
|-----|------|-------|
| `mp_VillagePlaza` | Multiplayer | Used in casual + ranked |
| `mp_BasBeachClub` | Multiplayer | Casual only |
| `mp_BlackMarket` | Multiplayer | Casual only |
| `mp_ShipCrashSite` | Multiplayer | Base map |
| `mp_ShipCrashSite_BombScenario` | Multiplayer | Variant — needs investigation |
| `mp_ShipCrashSite_BombSmall` | Multiplayer | Variant — likely the ranked Eggsplosion map |
| `mp_LobbyRoom` | Multiplayer | Lobby |
| `sp_Elite_Tutorial_01` | Singleplayer | Tutorial |
| `sp_PrologueMap_01` | Singleplayer | Prologue |
| `sp_RenegadeTutorial_01` | Singleplayer | Tutorial |

**Future work**: If per-mode map selection is needed, update `CreateSearchTicket()` to send real map arrays instead of `"Irrelevant"`.

### Key Constants

| Constant | Value | File |
|----------|-------|------|
| `EDGEGAP_BASE_API_URL` | `https://api.edgegap.com` | `EdgegapComponent.h:12` |
| `MAX_BEACONS_RETRY_ATTEMPTS` | `16` | `MatchmakerComponent.cpp:42` |
| `MaxPollingAttempts` | `200` (= 5 min at 1.5s) | `MatchmakerComponent.h:21` |
| `PollingInterval` | `1.5` seconds | `MatchmakerComponent.h:23` |
| `MaxDeleteTicketAttempts` | `5` | `MatchmakerComponent.h:157` |
| Port name | `"gameport"` (hardcoded) | `Ticket.h:23` |

---

## Ticket Attributes (What the Client Sends)

### Simple Ticket
```json
{
    "profile": "casual-8v8",
    "attributes": {
        "beacons": { "Frankfurt": 23.2, "Chicago": 224.4, "Tokyo": 178.1 }
    }
}
```

### Advanced Ticket (Current Default)
```json
{
    "profile": "casual-8v8",
    "attributes": {
        "beacons": { "Frankfurt": 23.2, "Chicago": 224.4 },
        "selected_game_mode": "Elimination",
        "selected_map": ["VillagePlaza", "BeachClub", "BlackMarket"]
    }
}
```

### Group Ticket (Future - Code Exists but Commented Out)
```json
{
    "player_tickets": [
        {
            "profile": "casual-8v8",
            "attributes": {
                "beacons": { "Frankfurt": 23.2 },
                "selected_game_mode": "Elimination",
                "selected_map": ["VillagePlaza"]
            }
        },
        {
            "profile": "casual-8v8",
            "attributes": {
                "beacons": { "Frankfurt": 25.1 },
                "selected_game_mode": "Elimination",
                "selected_map": ["VillagePlaza"]
            }
        }
    ]
}
```

The group ticket code is in `MatchmakerComponent.cpp` → `CreateMatchmakingTicketAsGroup()`, marked with `// TODO PLAYER LOBBY`. It reads party members from `NAME_PartySession` in the Online Subsystem.

---

## Matchmaker Profile Design

### Key Concept: One Matchmaker, Multiple Profiles

Each matchmaker instance can contain any number of profiles. Profiles are **completely isolated queues** — players in `casual-8v8` will never match with players in `ranked-4v4`.

### Recommended: Two Matchmakers (Testing + Production)

| Matchmaker | Environment | Profiles |
|------------|-------------|----------|
| **testing** | Development/QA | `casual-8v8`, `ranked-4v4` |
| **production** | Live players | `casual-8v8`, `ranked-4v4` |

Why separate matchmakers per environment (not just profiles):
- Different app versions (testing points to Development build, prod to Shipping)
- Can stop/start independently
- No risk of test players mixing with real players
- Different rate limits if needed

### Profile: casual-8v8

For Elimination and Control modes (8v8 team deathmatch / objective control).

```json
{
    "casual-8v8": {
        "ticket_expiration_period": "3m",
        "ticket_removal_period": "1m",
        "group_inactivity_removal_period": "5m",
        "application": {
            "name": "arcastest6",
            "version": "testing-f892f00"
        },
        "rules": {
            "initial": {
                "match_size": {
                    "type": "player_count",
                    "attributes": {
                        "team_count": 2,
                        "min_team_size": 6,
                        "max_team_size": 8
                    }
                },
                "beacons": {
                    "type": "latencies",
                    "attributes": {
                        "difference": 100,
                        "max_latency": 300
                    }
                },
                "selected_game_mode": {
                    "type": "string_equality"
                },
                "selected_map": {
                    "type": "intersection",
                    "attributes": { "overlap": 1 }
                },
                "backfill_group_size": {
                    "type": "intersection",
                    "attributes": { "overlap": 1 }
                }
            },
            "expansions": {
                "30": {
                    "match_size": {
                        "min_team_size": 4,
                        "max_team_size": 8
                    },
                    "beacons": {
                        "difference": 150,
                        "max_latency": 400
                    }
                },
                "60": {
                    "match_size": {
                        "min_team_size": 2,
                        "max_team_size": 8
                    }
                },
                "90": {
                    "match_size": {
                        "min_team_size": 1,
                        "max_team_size": 8
                    }
                }
            }
        }
    }
}
```

**Expansion timeline:**
- 0-30s: Wait for 6-8 players per team (ideal 8v8)
- 30-60s: Accept 4-8 per team (4v4 minimum)
- 60-90s: Accept 2-8 per team (2v2 minimum)
- 90s+: Accept anyone (even solo for testing)

### Profile: ranked-4v4

For Eggsplosion mode (4v4 competitive).

```json
{
    "ranked-4v4": {
        "ticket_expiration_period": "5m",
        "ticket_removal_period": "1m",
        "group_inactivity_removal_period": "5m",
        "application": {
            "name": "arcastest6",
            "version": "testing-f892f00"
        },
        "rules": {
            "initial": {
                "match_size": {
                    "type": "player_count",
                    "attributes": {
                        "team_count": 2,
                        "min_team_size": 4,
                        "max_team_size": 4
                    }
                },
                "beacons": {
                    "type": "latencies",
                    "attributes": {
                        "difference": 75,
                        "max_latency": 200
                    }
                },
                "selected_game_mode": {
                    "type": "string_equality"
                },
                "selected_map": {
                    "type": "intersection",
                    "attributes": { "overlap": 1 }
                }
            },
            "expansions": {
                "60": {
                    "beacons": {
                        "difference": 125,
                        "max_latency": 300
                    }
                },
                "120": {
                    "match_size": {
                        "min_team_size": 2,
                        "max_team_size": 4
                    }
                },
                "180": {
                    "match_size": {
                        "min_team_size": 1,
                        "max_team_size": 4
                    }
                }
            }
        }
    }
}
```

**Expansion timeline (stricter for ranked):**
- 0-60s: Strict 4v4, tight latency (competitive integrity)
- 60-120s: Relax latency but keep 4v4
- 120-180s: Accept 2v2
- 180s+: Accept 1v1 (last resort)

**Note**: Ranked should add `elo_rating` rule (type: `number_difference`) once the ranking system is mature. For now, just game mode matching is sufficient.

---

## Environment Model

### Testing Environment (CURRENT)

| Component | Value |
|-----------|-------|
| **Git branch** | `deploy/steam-testing` |
| **UE5 build config** | `Development` (full logging, console commands) |
| **API URL in code** | `arcaschampionsapi-test-1093142381010.europe-west1.run.app` |
| **Steam branch** | `testing` (password: `PrimeTester262`) |
| **Edgegap app** | `arcas-champions` |
| **Edgegap version** | `testing-server` (stable name, docker_tag updated per build) |
| **Edgegap matchmaker** | `arcas-testing` (URL: `om-pjotlrwfa6.edgegap.net`) |
| **Edgegap profiles** | `casual`, `ranked` |
| **DB tables** | `TestChampions`, `TestPlayerVault`, `TestPlayerLoadouts`, `TestPlayerRank` |
| **API credentials query** | `?type=casual` → casual profile, `?type=ranked` → ranked profile |
| **QueryValueKey** | `casual` (in `DefaultBeviumTools.ini`) |
| **QueryValueKey_Ranked** | `ranked` (in `DefaultBeviumTools.ini`) |

### Production Environment

| Component | Value |
|-----------|-------|
| **Git tag** | `v0.X.Y` release tags |
| **UE5 build config** | `Shipping` (optimized, no debug) |
| **API URL in code** | `arcaschampionsapi-1093142381010.europe-west1.run.app` |
| **Steam branch** | `default` (public) |
| **Edgegap matchmaker** | `production` matchmaker instance |
| **Edgegap app version** | `prod-0.X.Y` (semver) |
| **Edgegap profiles** | `casual-8v8`, `ranked-4v4` |
| **DB tables** | `Champions`, `PlayerVault`, `PlayerLoadouts`, `PlayerRank` |
| **API credentials query** | `?type=casual` → casual profile, `?type=ranked` → ranked profile |

### API Credential Routing (Implemented 2026-02-14)

`GET_MatchmakerCredentials` on test API (`arcaschampionsapi-test`):

| Query `?type=` | Matchmaker | Profile | Status |
|----------------|-----------|---------|--------|
| `casual` | arcas-testing | casual | WORKING |
| `ranked` | arcas-testing | ranked | WORKING |
| `test` | testqueue (legacy) | testqueue | Legacy |
| `demo` (default) | demo1 (legacy) | demo1 | Legacy |

The profile name is sent in the response, and the client includes it in the ticket `POST /tickets { "profile": "<profile>" }`.

---

## Promotion Flow: Testing → Production

### Daily Testing Build (Automated)

```
1. git pull deploy/steam-testing
2. Build Win64 Development client
3. Upload to Steam "testing" branch
4. Build Linux Development server
5. Containerize + push image tagged "testing-<commit>"
6. Create/update Edgegap app version "testing-<commit>"
7. Update testing matchmaker profiles → point to new version
```

Client already points to test API (hardcoded in code on this branch).

### Promote to Production (Manual, Deliberate)

```
1. Verify testing build is stable
2. Create git tag: v0.X.Y
3. Change API URL in .h files to production
4. Build Win64 Shipping client
5. Upload to Steam "default" branch
6. Build Linux Shipping server
7. Containerize + push image tagged "prod-0.X.Y"
8. Create Edgegap app version "prod-0.X.Y"
9. Update production matchmaker profiles → point to new version
10. Revert API URL back to test in code
11. Commit revert to deploy/steam-testing
```

### Hotfix Flow

```
1. Fix on deploy/steam-testing
2. Test via normal testing build
3. Cherry-pick fix to a hotfix branch
4. Tag: v0.X.Y+1
5. Build + deploy as production (steps 3-11 above)
```

---

## Feature Roadmap

### Phase 1: Basic Matchmaking (NEARLY COMPLETE)

Get the testing pipeline working end-to-end:
- [x] Linux server builds cross-compiled
- [x] Container pushed to registry (`arcastest6:2026-02-13_20-16`)
- [x] Edgegap app (`arcas-champions`) + version (`testing-server`) created via API
- [x] Manual deployment verified — server boots to READY
- [x] PATCH confirmed working for docker_tag updates
- [x] Testing matchmaker online (`arcas-testing`) with casual + ranked profiles
- [x] API returns correct credentials for casual/ranked
- [x] UE5 client config updated (QueryValueKey=casual)
- [ ] **End-to-end test** — client matches and connects to deployed server
- [ ] Rank update works after match

### Phase 2: Player Lobbies / Parties (Next)

**What**: Allow 2-4 players to queue together as a group.

**Edgegap support**: Full. Groups are first-class citizens in the matchmaker.

**How it works**:
1. Lobby owner creates a group via `POST /v1/groups` → gets `group_id`
2. Owner shares `group_id` with party members (via lobby service: Steam, EOS, or custom)
3. Members join via `POST /v1/memberships` with their own attributes
4. Attributes are validated on join (must be compatible under profile rules)
5. Group size validated (can't exceed `max_team_size`)
6. All members mark ready → matchmaking starts
7. Groups match into teams without overfilling (a group of 3 + group of 1 for 4v4)

**UE5 code status**: `CreateMatchmakingTicketAsGroup()` exists but is commented out (`// TODO PLAYER LOBBY`). Uses `NAME_PartySession` from Online Subsystem. Needs:
- Uncomment and test the group ticket path
- Wire up lobby service (likely Steam Lobbies via Online Subsystem)
- Add UI for party invite/join/ready

**Profile config needed**: No changes — groups automatically respect existing rules.

**Constraints**:
- Max party size = `max_team_size` (4 for ranked, 8 for casual)
- Once matchmaking starts, group is locked (no new members)
- If any member leaves after TEAM_FOUND, entire team returns to SEARCHING
- Recommended max party: 4 players (user requirement)

### Phase 3: Backfill (Mid-term)

**What**: Replace players who leave/disconnect mid-match with new players from the queue.

**Edgegap support**: Full. Server-owned "backfill tickets" represent empty slots.

**How it works**:
1. Server detects player disconnect (after grace period, e.g., 60s)
2. Server creates a backfill ticket via `POST /v1/backfills` with:
   - `assignment` data (server's FQDN, port, location — from deployment context)
   - `tickets` of currently connected players
   - `backfill_group_size` values indicating available capacity
3. Matchmaker matches new players directly to the backfill (skips deployment creation)
4. New player connects to existing server
5. Server receives new player's ticket data via backfill response

**UE5 code status**: NOT implemented. Needs new server-side component to:
- Track player connections/disconnections
- Create backfill tickets via Edgegap API
- Accept newly matched players connecting mid-match
- Renew backfill tickets (they expire after `ticket_expiration_period`)
- Delete backfill tickets on server shutdown

**Client side**: Include `backfill_group_size` in ticket attributes:
- `"1"` for solo players
- `"2"` for duo groups
- `"new"` to opt into both new games AND joining in-progress games

**Profile config needed**: Add `backfill_group_size` intersection rule (already in casual-8v8 profile above).

### Phase 4: Reconnect (Mid-term)

**What**: Allow disconnected players to rejoin their match.

**Edgegap support**: Client-side persistence + server grace period. No special API.

**How it works**:
1. Client saves assignment data persistently (FQDN, port, ticket_id, group_id)
2. If client crashes/disconnects, on restart it checks for saved assignment
3. Client attempts reconnection using saved connection details
4. Server verifies player identity via ticket ID
5. Server re-accepts player if within grace period

**UE5 code status**: NOT implemented. Needs:
- Client: Save assignment data to local storage (SaveGame or platform-specific)
- Client: On startup, check for saved assignment before showing main menu
- Client: Attempt reconnection flow
- Server: Grace period timer per player (e.g., 60-90s)
- Server: Keep player slot reserved during grace period
- Server: Accept reconnecting player with valid ticket ID

**Note**: The current code already passes `MMTicketId` in the travel URL and the server verifies it against injected tickets. Reconnection would use the same verification.

**Profile config needed**: None. This is entirely client/server logic.

### Phase 5: Ranked ELO Matching (Later)

**What**: Match ranked players by skill level.

**Edgegap support**: `number_difference` rule type.

**How it works**:
1. Client includes `elo_rating` attribute in ranked ticket
2. Matchmaker uses `number_difference` rule: only match players within X ELO of each other
3. Expansions gradually widen the ELO range over time

**Profile config addition for ranked-4v4:**
```json
"elo_rating": {
    "type": "number_difference",
    "attributes": {
        "max_difference": 100
    }
}
```

With expansions:
```json
"60": { "elo_rating": { "max_difference": 200 } },
"120": { "elo_rating": { "max_difference": 500 } }
```

**UE5 code status**: Partially ready. The `FTicketEnvVarAttributes` struct already has `elo_rating` field. Need to:
- Read player's current rank from the API before creating ticket
- Include `elo_rating` in ticket attributes
- Server already receives per-ticket ELO via `MM_TICKET_{id}.attributes.elo_rating`

---

## Server Container Configuration

### Current Version: arcas-champions / testing-server

| Setting | Value | Notes |
|---------|-------|-------|
| **App name** | `arcas-champions` | New app (separate from legacy `arcastest6`) |
| **Version name** | `testing-server` | Stable name, docker_tag updated per build |
| **Docker tag** | `2026-02-13_20-16` | Updated via PATCH API when new builds pushed |
| **Port** | UDP 7777 (name: `gameport`) | Must match `FPortsWrapper` hardcoded name |
| **CPU** | 2048 | 2 vCPUs |
| **RAM** | 4096 MB | 4 GB |
| **Max duration** | 30 min | Extended from 20 min for longer matches |
| **inject_context_env** | `true` | Required for MM_* env vars |
| **command** | `./StartServer.sh` | Entry point |

### Environment Variables

| Key | Value | Purpose |
|-----|-------|---------|
| `UE_COMMANDLINE_ARGS` | `-server -log` | Server launch args |

### Container Entry Point

`StartServer.sh`:
```bash
#!/bin/sh
GAME_PORT=$(echo $ARBITRIUM_PORTS_MAPPING | jq '.ports.gameport.internal')
$(dirname "$0")/ArcasChampionsServer.sh -server -log -PORT=$GAME_PORT
```

### Updating Docker Tag (New Build Pipeline)

When a new server build is pushed to Edgegap registry:

```bash
# Update the version to use the new image tag
curl -X PATCH -H "Authorization: token 2dd0f063-c76d-4e30-af80-942dbc8fe75c" \
  -H "Content-Type: application/json" \
  https://api.edgegap.com/v1/app/arcas-champions/version/testing-server \
  -d '{"docker_tag": "2026-02-15_10-30"}'
```

Matchmaker config doesn't change — still references `testing-server`. Next deployment automatically uses the new image.

---

## Edgegap API Reference (For Automation)

### Authentication

| API | Auth Header | Token |
|-----|------------|-------|
| **Management API** | `Authorization: token <TOKEN>` | `2dd0f063-c76d-4e30-af80-942dbc8fe75c` |
| **Matchmaker API** | `Authorization: <TOKEN>` (no "token" prefix) | Per-matchmaker token (from dashboard) |

### Key Endpoints

**App Version Management:**
```
POST   /v1/app/{app_name}/version
GET    /v1/app/{app_name}/version/{version_name}
DELETE /v1/app/{app_name}/version/{version_name}
PATCH  /v1/app/{app_name}/version/{version_name}
```

**Matchmaker Management:**
```
GET    /v1/matchmaker
POST   /v1/matchmaker
PATCH  /v1/matchmaker/{matchmaker_name}
DELETE /v1/matchmaker/{matchmaker_name}
POST   /v1/matchmaker/{matchmaker_name}/release
GET    /v1/matchmaker/{matchmaker_name}/managed-release
```

**Container Registry:**
```
Registry URL: registry.edgegap.com
Project: arcas-champions-n3tkvcfhbvhf
Username: robot$arcas-champions-n3tkvcfhbvhf+client-push
Token: SFiNqps7tu5e3efrWCj9AzxR03c8YfAk
Image: registry.edgegap.com/arcas-champions-n3tkvcfhbvhf/arcastest6:<tag>
```

### Create App Version (Example)

```bash
curl -X POST "https://api.edgegap.com/v1/app/arcastest6/version" \
  -H "Authorization: token 2dd0f063-c76d-4e30-af80-942dbc8fe75c" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "testing-f892f00",
    "docker_repository": "arcas-champions-n3tkvcfhbvhf/arcastest6",
    "docker_image": "testing-f892f00",
    "docker_registry": "registry.edgegap.com",
    "req_cpu": 2048,
    "req_memory": 4096,
    "max_duration": 30,
    "inject_context_env": true,
    "ports": [
      {
        "port": 7777,
        "protocol": "UDP",
        "name": "gameport",
        "tls_upgrade": false
      }
    ],
    "envs": [
      {
        "key": "UE_COMMANDLINE_ARGS",
        "value": "-server -log -LogCmds=\"LogSteamSocketsAPI Verbose\"",
        "is_secret": false
      }
    ],
    "endpoint_storage": "1gb"
  }'
```

### Update Matchmaker Profile

```bash
curl -X PATCH "https://api.edgegap.com/v1/matchmaker/<matchmaker_name>" \
  -H "Authorization: token 2dd0f063-c76d-4e30-af80-942dbc8fe75c" \
  -H "Content-Type: application/json" \
  -d '{
    "configuration": {
      "version": "3.2.1",
      "profiles": { ... }
    }
  }'
```

After updating, release the new config:
```bash
curl -X POST "https://api.edgegap.com/v1/matchmaker/<matchmaker_name>/release" \
  -H "Authorization: token 2dd0f063-c76d-4e30-af80-942dbc8fe75c"
```

---

## Rule Types Reference

| Rule Type | Key | Matching Logic | Attributes |
|-----------|-----|----------------|------------|
| `player_count` | Required (one per profile) | Team composition | `team_count`, `min_team_size`, `max_team_size` |
| `string_equality` | Optional (multiple) | All players must have exact same value | (none — just the string value) |
| `number_difference` | Optional (multiple) | Players within numerical range | `max_difference` |
| `latencies` | Optional (one per profile) | Ping-based regional matching | `difference` (ms between players), `max_latency` (absolute cap) |
| `intersection` | Optional (multiple) | Overlapping arrays (at least N shared items) | `overlap` (min shared items) |

### How Rules Apply to Groups

When a group (party) enters the queue:
- Group attributes = **average** of member attributes (for numbers)
- Group attributes = **intersection** of member attributes (for arrays)
- Group attributes = **all must match** (for string equality)

### Expansion Behavior

- Keys are seconds: `"30"`, `"60"`, `"120"`
- Later expansions **override** (not cumulate) previous values
- Ticket expiration **resets** when matched to a team
- Fill rate optimization: matchmaker waits until expansion boundary before making partial matches

---

## Matchmaker Inventory (2026-02-14)

### Active

| Matchmaker | Purpose | Profiles | Status |
|------------|---------|----------|--------|
| **arcas-testing** | New testing infrastructure | casual, ranked | ONLINE |
| **elimination** | Legacy production (Bevium) | elimination | ONLINE |

### Legacy (Keep for now, don't touch)

| Matchmaker | Status | Notes |
|------------|--------|-------|
| `demo1` | OFFLINE | Legacy, may be referenced by old clients |
| `testqueue` | OFFLINE | Legacy |
| `prime` | OFFLINE | Legacy |
| `beta2main` | OFFLINE | Legacy |

### App Versions

| App | Version | Docker Tag | Status |
|-----|---------|-----------|--------|
| `arcas-champions` | `testing-server` | `2026-02-13_20-16` | WORKING (new) |
| `arcastest6` | 11 old versions | Various 2024-2025 tags | Legacy (images may be expired) |

---

## Edgegap SDK / Integration Kit

### Official Unreal SDK

- **Name**: Edgegap Integration Kit (EGIK)
- **Source**: [github.com/betidestudio/EdgegapIntegrationKit](https://github.com/betidestudio/EdgegapIntegrationKit) (MIT license)
- **Marketplace**: Available on Fab (free for Personal use)
- **Status**: NOT currently installed in the project. Bevium built custom HTTP classes instead.

### Key Blueprint Nodes (If We Adopt EGIK Later)

- `CreateMatchmakingTicket` — Submit ticket with attributes
- `GetMatchmakingTicket` — Poll status
- `DeleteMatchmakingTicket` — Cancel
- `GetGroupPlayerMapping()` — Player IDs by group
- `GetExpansionStage()` — Current expansion data
- `GetMatchProfileName()` — Profile identifier

### Current Custom Implementation

Bevium's custom HTTP classes work fine and are already battle-tested. No need to switch to EGIK unless we want Blueprint-level matchmaker control for designers.

---

## Ticket Status Flow

```
SEARCHING
    │
    ▼
TEAM_FOUND ──(member leaves)──→ SEARCHING (back to queue)
    │
    ▼
MATCH_FOUND (deployment starting)
    │
    ▼
HOST_ASSIGNED ──→ Client reads assignment { fqdn, public_ip, ports }
    │                  └→ ClientTravel to server
    ▼
(Ticket auto-deleted after connection)


CANCELLED ←── timeout (ticket_expiration_period)
          ←── manual DELETE /tickets/{id}
          ←── group member left during matchmaking
```

---

## Rate Limits (Edgegap Matchmaker)

| Tier | Create Ticket | Read Ticket | Create Backfill | Monthly Cost |
|------|--------------|-------------|-----------------|--------------|
| Free (shared) | 5 req/s | 100 req/s | 5 req/s | Free |
| Hobbyist | 10 req/s | 200 req/s | 10 req/s | $22.46 |
| Studio | 37 req/s | 750 req/s | 37 req/s | $105.12 |
| Enterprise | 100 req/s | 2000 req/s | 100 req/s | $394.56 |

For early access with small player count, Free tier is sufficient.

---

## Matchmaker Version History (Key Changes)

| Version | Date | Impact on Arcas |
|---------|------|-----------------|
| **3.2.1** | Nov 2025 | Latest stable. Use this. |
| **3.2.0** | Oct 2025 | **Group Up feature** (native lobbies, no 3rd party needed), per-profile expiration |
| **3.1.0** | Jun 2025 | Fill rate optimization, enterprise analytics |
| **3.0.0** | May 2025 | **BREAKING**: `min_team_size`/`max_team_size` replaces old `player_count` expansions |
| **2.1.0** | Feb 2025 | **BREAKING**: Separated `MM_MATCH_PROFILE` and `MM_EXPANSION_STAGE` env vars |

**Important**: Our matchmaker configs use pre-3.0 syntax (just `team_size` without `min_`/`max_`). Need to update when creating new profiles.
