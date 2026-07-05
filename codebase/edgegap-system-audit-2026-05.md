# Edgegap + Arcas System Audit — May 16, 2026

**Live state captured directly from Edgegap API + ArcasChampionsAPI source. This is reality, not docs.**

---

## TL;DR

1. **Only 1 of 3 matchmakers is alive.** `arcas-testing` (Milan, HEALTHY) is the only working one. `testqueue` (DOWN) and `demo1` (HTTP 522 / dead) are still wired into our API but unreachable.
2. **Our API default route is broken.** `GET_MatchmakerCredentials` with no `?type=` falls through to the dead `demo1` matchmaker. Old Demo builds may still hit this path.
3. **No active deployments, no active tickets.** We have zero servers running, zero players matchmaking. This is fine — no traffic, no cost, but also no validation that the path works end-to-end since Feb.
4. **App slot limit hit.** Hobbyist plan = 3 apps max. We're at 3: `arcas-champions` (current), `arcastest6` (legacy, still enabled), `arcastest_args` (disabled). Cleanup unlocks a slot for a future `arcas-prod` app.
5. **Lobbies-relevant facts**: `POST /group-tickets` exists on `arcas-testing` Swagger, takes `{ player_tickets: [...] }` array, returns `{ player_tickets: [ReadTicketResponse, ...] }`. Endpoint matches the shape our commented-out `FGroupTicketRequestBody` code already expects.

---

## 1. Edgegap Account State (live data)

### Plan tier
| Item | Value | Implication |
|------|-------|-------------|
| Matchmaker size | **Hobbyist** | $22.46/mo per matchmaker, 10 req/s create, 200 req/s read, 10 req/s backfill |
| Apps allowed | 3 (at limit) | Need to delete `arcastest_args` or `arcastest6` to add `arcas-prod` later |
| Container registry | 12.56 / 21.47 GB (58%) | Comfortable, but old `arcastest6` images are eating space |

### Apps (3 total — at plan cap)
| Name | State | Last Updated | Versions | Notes |
|------|-------|--------------|----------|-------|
| `arcas-champions` | ENABLED ✅ | 2026-02-14 | 1 (`testing-server`) | **Current production app** |
| `arcastest6` | ENABLED ⚠️ | 2024-08-23 | 10 (legacy) | Bevium-era app — versions like `NextFestDemo-1.0`, `Beta2.1BuildServer`, `dev-server-release-1.0/1.1`. Still active in dashboard. |
| `arcastest_args` | DISABLED | 2025-03-13 | unknown | Experiment from Bevium era, disabled — safe to delete |

### Active version: `arcas-champions / testing-server`
```json
{
  "docker_image": "arcas-champions-n3tkvcfhbvhf/arcastest6",
  "docker_repository": "registry.edgegap.com",
  "docker_tag": "2026-02-15_23-38",         // last build pushed Feb 15
  "command": "./StartServer.sh",
  "port": 7777 UDP (gameport),
  "req_cpu": 2048, "req_memory": 4096 MB,
  "max_duration": 30 min,
  "inject_context_env": true,
  "envs": [{ "key": "UE_COMMANDLINE_ARGS", "value": "-server -log" }],
  "enable_all_locations": false,            // ← NOT enabled for all regions; only specific ones
  "last_updated": "2026-03-04 12:30"        // someone PATCHed something March 4
}
```

### Matchmakers (3 referenced in our API; 1 alive)

| Matchmaker | URL | Token | Status | Profiles | Wired into API as `?type=` |
|------------|-----|-------|--------|----------|---------------------------|
| **arcas-testing** | `om-pjotlrwfa6.edgegap.net` | `5b0bcde2-db8f-45cf-abc9-f160c0e168be` | ✅ ONLINE/HEALTHY (5/5) | `casual`, `ranked` | `casual`, `ranked` |
| **testqueue** | `om-2uonabzubh.edgegap.net` | `84f8532a-bdeb-...` | ❌ HTTP 000 (unreachable) | `testqueue` | `test` |
| **demo1** | `om-bh9bhh571s.edgegap.net` | `735fdf0d-3023-...` | ❌ HTTP 522 (Cloudflare bad gateway) | `demo1` | `demo` **(DEFAULT FALLBACK)** |

⚠️ **Production hazard:** `GET_MatchmakerCredentials` with no `?type=` parameter, or with `?type=demo`, returns the dead `demo1` URL. Players on older client builds (pre-Feb 14 `DefaultBeviumTools.ini`) may still be hitting this.

### Container registry
| Field | Value |
|-------|-------|
| URL | `registry.edgegap.com` |
| Project | `arcas-champions-n3tkvcfhbvhf` |
| Push username | `robot$arcas-champions-n3tkvcfhbvhf+client-push` |
| Push token | `SFiNqps7tu5e3efrWCj9AzxR03c8YfAk` |
| Repo | `arcas-champions-n3tkvcfhbvhf/arcastest6` (note: name kept from legacy app for path compat) |
| Tags | 5 (incl. `2026-02-15_23-38` = active, `2026-02-13_20-16` = first successful push) |
| Storage | 12.56 / 21.47 GB |

### Active matchmaker `arcas-testing` Swagger endpoints (source of truth)
```
POST   /tickets                      Solo matchmaking ticket
GET    /tickets/{ticketId}           Poll ticket status
DELETE /tickets/{ticketId}           Cancel ticket
POST   /group-tickets                ← GROUP MATCHMAKING (one call, all players)
POST   /backfills                    Server-owned backfill ticket
GET    /backfills/{backfillId}       Poll backfill status
DELETE /backfills/{backfillId}       Delete backfill
GET    /locations/beacons            Ping targets per region
GET    /monitor                      Health check (no auth)
```

Swagger spec saved to `repos/arcas-build-automation/matchmaker-config/edgegap-matchmaker-swagger-2026-05-16.json`.

---

## 2. Full System Architecture (current reality)

```
                                                                          
   PLAYER CLIENT (UE5 Win64)                                              
   ApeShooter @ deploy/steam-testing branch                               
   Reads DefaultBeviumTools.ini → QueryValueKey="casual" / Ranked="ranked"
       │                                                                  
       │  1. Asks our API for matchmaker creds                            
       ▼                                                                  
   ┌─────────────────────────────────────────────────────────┐            
   │ ArcasChampionsAPI (Cloud Run, europe-west1)              │           
   │  - prod:   arcaschampionsapi (Bevium era, live)          │           
   │  - test:   arcaschampionsapi-test (Feb 2026, test infra) │           
   │                                                          │           
   │  GET /GET_MatchmakerCredentials?type=casual              │           
   │    → { Url, Token, Profile=casual, Status=true }         │           
   │                                                          │           
   │  POST /POST_RankedMatchResults (server → API, after match)│          
   │  Various player/inventory/rank endpoints                 │           
   └─────────────┬────────────────────────────┬───────────────┘           
                 │                            │                           
                 ▼                            ▼                           
   ┌──────────────────────────┐    ┌────────────────────────┐             
   │ Cloud SQL: game-backend-db│    │ EDGEGAP MATCHMAKER     │            
   │ PostgreSQL                │    │ arcas-testing (Milan)  │            
   │ Champions, PlayerVault,   │    │ om-pjotlrwfa6.edgegap  │            
   │ PlayerLoadouts,           │    │                        │            
   │ PlayerRank                │    │ POST /tickets          │            
   │ Test* prefix dual-write   │    │ POST /group-tickets    │            
   └──────────────────────────┘    │ GET /tickets/{id} poll │            
                                   └───────────┬────────────┘             
                                               │                          
                                               │ on HOST_ASSIGNED         
                                               ▼                          
                          ┌─────────────────────────────────────┐         
                          │ EDGEGAP DEPLOYMENT (dynamic)        │         
                          │ App: arcas-champions                │         
                          │ Version: testing-server             │         
                          │ Image: arcastest6:2026-02-15_23-38  │         
                          │ Port: 7777 UDP gameport             │         
                          │ Max duration: 30 min                │         
                          │                                     │         
                          │ Container runs:                     │         
                          │   ./StartServer.sh                  │         
                          │   → ArcasChampionsServer.sh         │         
                          │      -server -log -PORT=$gameport   │         
                          │                                     │         
                          │ Reads env vars:                     │         
                          │   ARBITRIUM_CONTEXT_URL → ctx data  │         
                          │   MM_TICKET_IDS, MM_MATCH_PROFILE   │         
                          │   MM_EQUALITY (selected_game_mode)  │         
                          │   MM_INTERSECTION (selected_map)    │         
                          │                                     │         
                          │ Auth token baked at compile:        │         
                          │   Secrets/SecretToken.txt           │         
                          │   "jids3udj_su8xiajnsndks"          │         
                          └─────────────────────────────────────┘         
                                                                          
                            BUILD PIPELINE (currently idle)                
   ┌────────────────────────────────────────────────────────┐             
   │ GitHub: dandad3v/ApeShooter @ deploy/steam-testing     │             
   └────────────────┬───────────────────────────────────────┘             
                    │ git pull on VM                                      
                    ▼                                                     
   ┌────────────────────────────────────────────────────────┐             
   │ Build VM: arcas-build-server-gpu (STOPPED currently)   │             
   │ - C:\A\Scripts\build-all.bat (24m30s end-to-end)       │             
   │ - Compiles Linux server (cross-compile clang)          │             
   │ - Compiles Win64 client                                │             
   │ - Submits Cloud Build job                              │             
   └────────────────┬───────────────────────────────────────┘             
                    │ gcloud builds submit                                
                    ▼                                                     
   ┌────────────────────────────────────────────────────────┐             
   │ Google Cloud Build (europe-west6)                      │             
   │ - Docker build of Linux server                         │             
   │ - Push to Edgegap registry                             │             
   └────────────────┬───────────────────────────────────────┘             
                    │ docker push                                         
                    ▼                                                     
   ┌────────────────────────────────────────────────────────┐             
   │ registry.edgegap.com/arcas-champions-n3tkvcfhbvhf/      │           
   │   arcastest6:2026-02-15_23-38                          │             
   └────────────────┬───────────────────────────────────────┘             
                    │ PATCH docker_tag                                    
                    ▼                                                     
   ┌────────────────────────────────────────────────────────┐             
   │ Edgegap App: arcas-champions / Version: testing-server │             
   └────────────────────────────────────────────────────────┘             
                    │ + Steam upload in parallel                          
                    ▼                                                     
   ┌────────────────────────────────────────────────────────┐             
   │ Steam Demo (App 3487030) / testing branch              │             
   │ Password: PrimeTester262                               │             
   └────────────────────────────────────────────────────────┘             
```

---

## 3. Decay state — what's broken or stale

| Item | Status | Risk | Recommended action |
|------|--------|------|---------------------|
| `demo1` matchmaker (DOWN) wired as DEFAULT route in API | High | Old client builds → dead matchmaker → no game | Change default branch in `GET_MatchmakerCredentials` to `casual` |
| `testqueue` matchmaker (DOWN) wired as `?type=test` | Low | Unused — only test infra | Remove case from switch, delete matchmaker |
| `arcastest_args` app (DISABLED) | Low | Wastes 1 of 3 app slots | Delete |
| `arcastest6` app (10 legacy versions, still ENABLED) | Medium | Wastes 1 app slot + registry storage | Delete the 10 versions (`Beta2.1BuildServer`, `NextFestDemo-1.0`, etc.) — keep the app if we want to reuse `arcastest6` name |
| `arcas-champions / testing-server` version `enable_all_locations: false` | Medium | Players outside Edgegap-deployed regions get poor pings | Either enable all locations or explicitly whitelist EU + NA |
| Matchmaker management API endpoints (404) | Low | Can't PATCH profiles via API anymore | Use dashboard for profile updates; verify in next deploy cycle |
| Live deployments: 0 / sessions: 0 | Info | No traffic since Feb | Expected (no announced demo refresh) — not a problem until lobbies + relaunch |
| `arcas-champions / testing-server` docker tag from Feb 15 | Medium | Code/data drift since Feb | Next build after lobby work will refresh |
| `vm-state.md` shows VM stopped since Feb 17 | Info | Build pipeline idle | Will restart when VM capacity returns |

---

## 4. matchmakerconfigs folder (in ArcasChampionsAPI repo)

These are profile rule JSONs stored alongside the API code. Useful as version-controlled snapshots — NOT used by the API at runtime (the API just returns URLs/tokens; the matchmaker has its own copy).

| File | Maps to | Target app | In active matchmaker? |
|------|---------|-----------|----------------------|
| `casual.json` | `casual` profile | arcas-champions | ✅ (live) |
| `ranked.json` | `ranked` profile | arcas-champions | ✅ (live) |
| `demo1.json` | `demo1` profile | arcastest6 (legacy) | ❌ (matchmaker dead) |
| `testqueue.json` | `testqueue` profile | arcastest6 (legacy) | ❌ (matchmaker dead) |
| `beta2main.json` | legacy profile | arcastest6 (legacy) | ❌ (probably retired) |
| `prime.json` | legacy profile | arcastest6 (legacy) | ❌ (probably retired) |

---

## 5. For lobbies work — confirmed live setup

Everything needed to ship lobbies is here:

| Component | Confirmed | Source |
|-----------|-----------|--------|
| Matchmaker alive | ✅ `arcas-testing` HEALTHY | curl /monitor |
| Group ticket endpoint | ✅ `POST /group-tickets` | Swagger spec |
| Request shape | ✅ `{ player_tickets: [{ player_ip, profile, attributes: {beacons, selected_game_mode, selected_map} }] }` | Swagger spec |
| Response shape | ✅ `{ player_tickets: [ReadTicketResponse, ...] }` (one per player) | Swagger spec |
| App+version targeted | ✅ `arcas-champions / testing-server` already wired into both profiles | API |
| Both profiles accept groups | ✅ casual + ranked both have GroupRequest schema | Swagger |
| Server build that handles group tickets | ✅ `arcastest6:2026-02-15_23-38` image, in registry | Edgegap API |
| Plan rate limits OK | ✅ 10 group ticket req/s — plenty | Hobbyist |

The only thing missing is **client-side code** to call it, plus Steam Lobby UI on top.

---

## 6. Cleanup recommendations (defer until post-lobbies)

1. **Fix the default fallback in `GET_MatchmakerCredentials`** — change `default:` to point to `arcas-testing/casual` instead of dead `demo1`. Otherwise old Steam Demo builds without query param get a dead matchmaker.
2. **Delete `arcastest_args` app** in dashboard — unlocks 1 of 3 app slots.
3. **Delete 10 legacy versions on `arcastest6` app** in dashboard (or keep app, prune versions) — saves registry storage.
4. **Set `enable_all_locations: true` on `arcas-champions / testing-server`** OR explicitly whitelist EU+NA — currently restricted.
5. **Decommission `testqueue` and `demo1` matchmakers** if they're not coming back — both are dead URLs that cost nothing but clutter our API code.
6. **Delete `testqueue.json`, `demo1.json`, `beta2main.json`, `prime.json`** from `matchmakerconfigs/` once we confirm they're truly retired — keep `casual.json` + `ranked.json`.

None of these block lobby work.

---

## 7. Key facts to keep handy

| Need to know | Value |
|--------------|-------|
| Matchmaker API URL | `https://om-pjotlrwfa6.edgegap.net` |
| Matchmaker user token (for client → matchmaker calls) | `5b0bcde2-db8f-45cf-abc9-f160c0e168be` |
| Matchmaker management auth (api.edgegap.com) | `2dd0f063-c76d-4e30-af80-942dbc8fe75c` (token format: `Authorization: token <X>`) |
| Server auth (server → ArcasChampionsAPI) | `jids3udj_su8xiajnsndks` (baked into server at compile) |
| Steam Demo App ID | 3487030 |
| Steam Demo testing branch password | `PrimeTester262` |
| GitHub branch for builds | `deploy/steam-testing` (NOT `main` — Bevium code) |
| Active server image | `registry.edgegap.com/arcas-champions-n3tkvcfhbvhf/arcastest6:2026-02-15_23-38` |
| GCS Test API URL | `https://arcaschampionsapi-test-1093142381010.europe-west1.run.app` |
| GCS Prod API URL | `https://arcaschampionsapi-a72oa65lxa-ew.a.run.app` |
| Build VM | `arcas-build-server-gpu` @ `europe-west6-b` (STOPPED) |
| Cloud SQL | `game-backend-db` (PostgreSQL, GCP project `arcas-champions`) |

---

**Bottom line:** The setup is leaner than it looks — only `arcas-testing` matchmaker matters; everything else is decay from Bevium era. Cleanup unlocks an app slot and removes failure modes. The path to lobbies has no infrastructure blockers; everything we need is alive and responding.
