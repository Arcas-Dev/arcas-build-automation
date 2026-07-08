# Edgegap Dedicated Server & Matchmaking Setup

This doc covers how Arcas Champions uses Edgegap for dedicated game servers and matchmaking. It documents the current state, all configuration, and how the pieces connect.

**Last updated**: 2026-02-14

---

## Architecture Overview

```
Game Client (UE5)
  │
  │  GET /GET_MatchmakerCredentials?type=casual|ranked|test|demo
  ▼
Backend API (Cloud Run)
  │  Returns: { Url, Token, Profile }
  │
  │  Client uses credentials to create matchmaking ticket
  ▼
Edgegap Matchmaker (om-*.edgegap.net)
  │  Matches players based on profile rules
  │  When match found → triggers deployment
  ▼
Edgegap Deployment API
  │  Pulls container image from registry.edgegap.com
  │  Spins up game server container
  ▼
Dedicated Server Container (UE5 -server)
  │  Receives MM_* env vars with player/match data
  │  Listens on UDP 7777 (gameport)
  ▼
Players connect via FQDN:port from deployment
```

**Key insight**: The game client never talks to Edgegap directly for deployments. It only talks to the matchmaker. The matchmaker handles deployment creation automatically when a match is found.

---

## Edgegap Account

| Field | Value |
|-------|-------|
| **Dashboard** | https://app.edgegap.com |
| **API Base** | `https://api.edgegap.com/v1` |
| **API Token** | `2dd0f063-c76d-4e30-af80-942dbc8fe75c` (named "automation") |
| **Auth Header** | `Authorization: token <TOKEN>` |

---

## Applications

### Active Apps

| App | Status | Purpose | Notes |
|-----|--------|---------|-------|
| **arcas-champions** | ENABLED | New testing infrastructure | Created 2026-02-14, clean start |
| **arcastest6** | ENABLED | Legacy (Bevium era) | Main app with 11 old versions |
| **arcastest_args** | DISABLED | Experimental | Not used |

### ⚠️ Account resource limits DROPPED (discovered 2026-07-08)

**Edgegap now caps this account at `req_cpu` ≤ 1536 (1.5 vCPU) and `req_memory` ≤ 3072 MiB (3 GiB).** The versions below were created in Feb 2025 at 2048/4096, which was permitted then. Something changed on the account (plan/tier/trial — **not yet investigated**).

**Why this breaks builds silently:** Edgegap **revalidates the entire version object on any PATCH.** So even though `build-all.ps1` sends only `{"docker_tag": ...}`, the API re-checks CPU/memory, finds them over quota, and rejects the whole request:
```json
{"message": "You cannot allocate more CPU than 1536 units (1.50 vCPU), You cannot allocate more memory than 3072 MiB (3.00 GiB)"}
```
The 2026-07-08 build hit this. `build-all.ps1` treated it as a **warning**, printed `UNIFIED BUILD PIPELINE COMPLETE!`, and wrote `COMPLETE` to `status.txt` — leaving a **5-month-old server image** live against a freshly-uploaded Steam client. Caught only by manually GET-ing the version.

- **Fixed in the script** (2026-07-08): the PATCH now **reads the tag back** and a mismatch/exception is **fatal** → `status.txt = EDGEGAP_PATCH_FAILED:<tag>` + `exit 1`.
- **`testing-server` was downsized to 1536/3072** to unblock. ⬜ **A UE5 dedicated server on 3 GiB is untested under load — watch for OOM in a real match.**
- ⬜ **TODO: find out why the limits dropped** and whether 2048/4096 can be restored.
- **Any PATCH to the other versions below will fail the same way** until they're downsized too.

### App Hierarchy: arcas-champions

```
App: arcas-champions
└── Version: testing-server              ← stable name, referenced by matchmaker
    ├── docker_image: arcas-champions-n3tkvcfhbvhf/arcastest6
    ├── docker_tag: 2026-07-08_17-24     ← changes when we push new builds
    ├── req_cpu: 1536 (1.5 vCPUs)        ← downsized 2026-07-08 (account cap)
    ├── req_memory: 3072 (3 GB)          ← downsized 2026-07-08 (account cap)
    ├── max_duration: 30 min
    ├── inject_context_env: true
    ├── ports: [{7777, UDP, "gameport"}]
    ├── command: ./StartServer.sh
    └── envs: [{UE_COMMANDLINE_ARGS: "-server -log"}]
```

**Update workflow for new builds:**
1. Cloud Build pushes new Docker image with unique date tag (e.g., `2026-02-15_10-30`)
2. PATCH the version's `docker_tag` via API: `PATCH /v1/app/arcas-champions/version/testing-server`
3. Matchmaker still references `testing-server` — no matchmaker config change needed
4. Next matchmaker deployment pulls the new image automatically

**Confirmed**: PATCH API works for updating `docker_tag` on existing versions.

**Important**: Edgegap warns against reusing the same Docker tag name (caching issues). We always use UNIQUE date-based tags, so this is not a concern.

---

## App Versions (Container Images)

All versions use Edgegap's private container registry. Images were built and pushed by Bevium during their contract (ended Jan 2026).

### Active Versions (Used by Matchmakers)

| Version | Docker Tag | Port | CPU/RAM | Max Duration | Env Vars | Used By |
|---------|-----------|------|---------|-------------|----------|---------|
| `dev-server-earlyaccess-1.0` | `2025-05-16_13-31` | UDP 7777 | 2048/4096 | 20 min | UE_COMMANDLINE_ARGS | demo1, testqueue, prime configs |
| `Beta2.2BuildServer` | `2024-12-20_19-01` | UDP 7777 | 2048/4096 | 20 min | (none) | beta2main config |
| `NextFestDemo-1.0` | `2025-07-31_16-45` | UDP 7777 | 2048/4096 | 20 min | UE_COMMANDLINE_ARGS | Steam Next Fest demo |
| `ranked-elimination-1.0` | `2025-07-31_16-45` | UDP 7777 | 2048/4096 | 20 min | UE_COMMANDLINE_ARGS | elimination matchmaker |
| `dev-server-prime-1.0` | `2025-07-29_14-09` | UDP 7777 | 2048/4096 | 20 min | UE_COMMANDLINE_ARGS | prime matchmaker |

### Other Versions (Legacy/Test)

| Version | Docker Tag | Port | CPU/RAM | Max Duration | Notes |
|---------|-----------|------|---------|-------------|-------|
| `Beta2.1BuildServer` | `2024-12-20_19-01` | UDP 7777 | 2048/4096 | 30 min | Older beta, no env injection |
| `dev-server-release-1.0` | `2024-12-13_17-31` | TCP/UDP 7770 | 2048/4096 | 60 min | Different port (7770) |
| `dev-server-release-1.1` | `2024-12-20_19-01` | TCP/UDP 7770 | 2048/4096 | 20 min | Different port (7770) |
| `2025-07-30_17-20` | `2025-07-30_17-20` | TCP/UDP 7770 | 128/256 | 60 min | Tiny resources, registry2 |
| `2025-07-31_13-11` | `2025-07-31_13-11` | TCP/UDP 7770 | 128/256 | 60 min | Tiny resources, registry2 |
| `2025-07-31_16-45` | `2025-07-31_16-45` | TCP/UDP 7770 | 128/256 | 60 min | Tiny resources, registry2 |

**Notes**:
- `registry.edgegap.com` = primary registry (8 versions)
- `registry2.edgegap.com` = newer registry (3 versions with timestamp names)
- Versions with 128 CPU / 256 MB RAM are likely test containers, not real game servers
- The `UE_COMMANDLINE_ARGS` env var is: `-server -log -LogCmds="LogSteamSocketsAPI Verbose"`
- `inject_context_env: true` means the matchmaker sends `MM_*` environment variables to the server

### Container Image Status

**Our images**: We now build and push our own images via Cloud Build. The latest working image is `arcastest6:2026-02-14_20-13`, end-to-end tested on 2026-02-14.

**Bevium images**: Old images pushed months ago. A test deployment on 2026-02-10 failed with "Unable to pull image from registry" for `dev-server-earlyaccess-1.0`. These may be expired — use the `arcas-champions` app with `testing-server` version instead.

### Dockerfile Notes

The Dockerfile at `C:\A\Builds\LinuxServer\Dockerfile` must include:

```dockerfile
RUN sed -i 's/\r$//' /app/StartServer.sh
RUN chmod +x /app/StartServer.sh /app/ArcasChampionsServer.sh /app/NewApeShooter/Binaries/Linux/ArcasChampionsServer
```

- **`sed`**: Strips Windows line endings (`\r\n` → `\n`) from shell scripts
- **`chmod +x`**: Windows doesn't preserve Unix execute permissions — without this, the container fails with `permission denied` on startup

### Server Auth Token (SECRET_TOKEN)

The dedicated server authenticates with the API using a compile-time baked token.

**Chain**: `ArcasChampionsServer.Target.cs` → reads `Config/Custom/Server/DefaultEngine.ini` → finds `SecretTokenPath=Secrets/SecretToken.txt` → bakes token into binary as `GlobalDefinitions.Add("SECRET_TOKEN=...")`.

| Item | Value |
|------|-------|
| Token file | `C:\A\ApeShooter\NewApeShooter\Secrets\SecretToken.txt` |
| Token value | `jids3udj_su8xiajnsndks` |
| API check | `server.js:1524` — `req.headers['authorization'] !== 'jids3udj_su8xiajnsndks'` |
| Default | If file missing, token = `"NULL"` → all API calls return 401 |

**Important**: Changing the token requires a full Linux server rebuild (~45 min) because it's baked at compile time.

---

## Matchmakers

### Active Matchmakers

| Matchmaker | Status | URL | Token | Profiles |
|------------|--------|-----|-------|----------|
| **arcas-testing** | ONLINE | `https://om-pjotlrwfa6.edgegap.net` | `5b0bcde2-db8f-45cf-abc9-f160c0e168be` | `casual`, `ranked` |
| **elimination** | ONLINE | `https://om-8ipfbkb0aw.edgegap.net` | `17423604-84b8-4e1a-959c-1619a8d86a1d` | elimination (Bevium) |

### Legacy Matchmakers (Bevium era — do not touch)

| Matchmaker | Status | URL | Token |
|------------|--------|-----|-------|
| **demo1** | OFFLINE | `https://om-bh9bhh571s.edgegap.net` | `735fdf0d-3023-4d05-b3bc-f3f0b1b8fc3a` |
| **testqueue** | OFFLINE | `https://om-2uonabzubh.edgegap.net` | `84f8532a-bdeb-4827-a951-20c2bc3425be` |
| **prime** | OFFLINE | `https://om-iijxvl0dau.edgegap.net` | `47772276-8cab-4b1c-b205-19306c4c9444` |
| **beta2main** | OFFLINE | - | - |

### arcas-testing Matchmaker (Current)

Created 2026-02-14. One matchmaker with two isolated profile queues:

| Profile | Team Size | Game Modes | App Version |
|---------|-----------|------------|-------------|
| **casual** | 2 teams × 8 (expands: 4→2→1→solo) | Elimination, Control | `arcas-champions/testing-server` |
| **ranked** | 2 teams × 4 (expands: 2→1→solo) | Eggsplosion | `arcas-champions/testing-server` |

Config JSON: `repos/arcas-build-automation/matchmaker-config/arcas-testing.json`

### API Credential Routing (Current)

| API `?type=` | Matchmaker | Profile | Environment |
|--------------|-----------|---------|-------------|
| `casual` | arcas-testing | casual | Testing |
| `ranked` | arcas-testing | ranked | Testing |
| `test` | testqueue (legacy) | testqueue | Legacy |
| `demo` (default) | demo1 (legacy) | demo1 | Legacy |

---

## Matchmaker Profiles

### arcas-testing — Current Active Config

**Config file**: `repos/arcas-build-automation/matchmaker-config/arcas-testing.json`
**Reference configs**: `repos/ArcasChampionsAPI/matchmakerconfigs/casual.json` and `ranked.json`

Both profiles use the same rules structure with different team sizes and expansion timelines.

**Rules (both profiles)**:
- `player_count` — team_count × team_size
- `latencies` — difference: 500ms, max: 1000ms (generous for testing)
- `string_equality` on `selected_game_mode`
- `intersection` on `selected_map` (overlap: 1)

**casual profile** — 8v8 Quickplay (Elimination / Control):

| Time | Teams | Size | Match Format |
|------|-------|------|-------------|
| Initial | 2 | 8 | 8v8 |
| 10s | 2 | 4 | 4v4 |
| 20s | 2 | 2 | 2v2 |
| 30s | 2 | 1 | 1v1 |
| 45s | 1 | 1 | Solo (for testing) |

**ranked profile** — 4v4 Competitive (Eggsplosion):

| Time | Teams | Size | Match Format |
|------|-------|------|-------------|
| Initial | 2 | 4 | 4v4 |
| 20s | 2 | 2 | 2v2 |
| 30s | 2 | 1 | 1v1 |
| 45s | 1 | 1 | Solo (for testing) |

### Legacy Profiles (Bevium era)

Config files in `repos/ArcasChampionsAPI/matchmakerconfigs/`:
- `demo1.json` — 1v1, no expansions
- `testqueue.json` — 1v1 with 3→2→1 expansion
- `prime.json` — identical to testqueue
- `beta2main.json` — 8v8 with aggressive 5s→15s→30s→45s expansion

---

## How the Game Client Gets Matchmaker Credentials

### The QueryValueKey Mechanism

The UE5 client determines which `type` to send via `DefaultBeviumTools.ini`:

```ini
[/Script/BeviumTools.BeviumToolsRuntimeSettings]
AdditionalParameters=(("QueryValueKey", "casual"),("QueryValueKey_Ranked", "ranked"))
```

- `UMatchmakerComponent::GetMatchmakerType()` reads `GetParameter("QueryValueKey")` → sends `?type=casual`
- `URankedMatchmakerComponent::GetMatchmakerType()` reads `GetParameter("QueryValueKey_Ranked")` → sends `?type=ranked`

This is a standard UE5 `UDeveloperSettings` config — any `BuildCookRun` packages it. No special Bevium tooling needed.

**Source files**:
- Config: `Config/DefaultBeviumTools.ini`
- Settings class: `Source/BeviumToolsGame/Public/BeviumToolsRuntimeSettings.h`
- Reader: `GetDefault<UBeviumToolsRuntimeSettings>()->GetAdditionalParameter(Key)`

### API Endpoint

**Endpoint**: `GET /GET_MatchmakerCredentials?type=<type>`
**File**: `repos/ArcasChampionsAPI/server.js` (line ~1222)
**Environment**: Test API (`arcaschampionsapi-test`)

Current routing:

| `type` | Matchmaker | Profile | URL |
|--------|-----------|---------|-----|
| `casual` | arcas-testing | casual | `https://om-pjotlrwfa6.edgegap.net` |
| `ranked` | arcas-testing | ranked | `https://om-pjotlrwfa6.edgegap.net` |
| `test` | testqueue (legacy) | testqueue | `https://om-2uonabzubh.edgegap.net` |
| `demo` (default) | demo1 (legacy) | demo1 | `https://om-bh9bhh571s.edgegap.net` |

Response format:
```json
{
  "bSuccess": true,
  "Error": "",
  "Payload": "{\"Url\":\"https://om-XXX.edgegap.net\",\"Token\":\"...\",\"Profile\":\"...\",\"Status\":true}"
}
```

**Note**: `Payload` is a stringified JSON object — the client must parse it twice.

The client then uses the URL and Token to interact with the matchmaker API directly (create tickets, poll status, etc.).

---

## Matchmaking Flow (How It Works)

### 1. Ticket Lifecycle

```
SEARCHING → TEAM_FOUND → MATCH_FOUND → HOST_ASSIGNED → (play) → DELETED
                                    ↘ CANCELLED (expired/abandoned)
```

### 2. Client Flow

1. Client calls `GET_MatchmakerCredentials` to get matchmaker URL + token
2. Client measures ping to Edgegap beacons (geographic latency points)
3. Client creates a **group** (even for solo players)
4. Client creates a **ticket** with:
   - Player attributes (selected_game_mode, selected_map, etc.)
   - Beacon latencies (`{ "Chicago": 12.3, "Frankfurt": 23.2, ... }`)
5. Client polls ticket status every 3-5 seconds
6. When status = `HOST_ASSIGNED`, client receives:
   - Server FQDN
   - External port mapping (UDP 7777 mapped to external port)
7. Client connects to the dedicated server

### 3. Server-Side (Container)

When the matchmaker creates a deployment, the container receives environment variables:

```
MM_MATCH_PROFILE=elimination       # Which profile matched
MM_EXPANSION=initial               # Which expansion level triggered
MM_TICKET_IDS=["ticket-123",...]   # List of matched ticket IDs
MM_TICKET_ticket-123={...}         # Per-ticket player attributes (JSON)
MM_GROUPS={...}                    # Group → member mapping
MM_TEAMS={...}                     # Team → group mapping
MM_MATCH_ID=match-uuid             # Unique match identifier
MM_INTERSECTION={...}              # Overlapping values (e.g., maps)
MM_EQUALITY={...}                  # Equal values (e.g., game mode)
```

**Requires `inject_context_env: true`** on the app version (set on all active versions except Beta2.1 and Beta2.2).

### 4. Rule Types

| Rule | Purpose | Example |
|------|---------|---------|
| `player_count` | Team size/count | 2 teams of 8 = 8v8 |
| `latencies` | Ping-based regional matching | Max 500ms, diff 50ms |
| `string_equality` | Exact string match | Same game mode |
| `intersection` | Set overlap | At least 1 shared map |

### 5. Expansions

Expansions progressively relax rules after time in queue. They **overwrite** previous values (not accumulate).

Example: beta2main starts 8v8, drops to 4v4 after 5s, 2v2 after 15s, etc.

Just before expanding (or expiring), if a partial match is possible (≥ min_team_size but < max_team_size), the match is made immediately.

---

## Edgegap API Quick Reference

All requests use `Authorization: token 2dd0f063-c76d-4e30-af80-942dbc8fe75c`.

### Applications

```bash
# List all apps
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/apps"

# List versions for an app (paginated, 10 per page)
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/app/arcastest6/versions"
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/app/arcastest6/versions?page=2"

# Get specific version
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/app/arcastest6/version/dev-server-earlyaccess-1.0"

# Create new version
curl -s -X POST -H "Authorization: token TOKEN" -H "Content-Type: application/json" \
  "https://api.edgegap.com/v1/app/arcastest6/version" \
  -d '{
    "name": "my-version-1.0",
    "docker_repository": "registry.edgegap.com",
    "docker_image": "arcas-champions-n3tkvcfhbvhf/arcastest6",
    "docker_tag": "2026-02-10_latest",
    "req_cpu": 2048,
    "req_memory": 4096,
    "max_duration": 20,
    "inject_context_env": true,
    "ports": [{"name": "gameport", "port": 7777, "protocol": "UDP"}],
    "envs": [{"key": "UE_COMMANDLINE_ARGS", "value": "-server -log"}]
  }'
```

### Deployments

```bash
# Create deployment (manual, without matchmaker)
curl -s -X POST -H "Authorization: token TOKEN" -H "Content-Type: application/json" \
  "https://api.edgegap.com/v1/deploy" \
  -d '{
    "app_name": "arcastest6",
    "version_name": "dev-server-earlyaccess-1.0",
    "ip_list": ["YOUR_IP"]
  }'

# Check deployment status
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/status/REQUEST_ID"

# List active deployments
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/deployments"

# Stop deployment
curl -s -X DELETE -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/stop/REQUEST_ID"

# Get container logs (only while deployment is READY)
curl -s -H "Authorization: token TOKEN" "https://api.edgegap.com/v1/deployments/REQUEST_ID/container-logs"
```

### Matchmaker API (per-matchmaker, not global)

Each matchmaker has its own private URL and token. These are different from the global API token.

```bash
# Create matchmaking group
curl -s -X POST -H "Authorization: Bearer MM_TOKEN" \
  "https://om-XXX.edgegap.net/groups" \
  -d '{ ... }'

# Create ticket
curl -s -X POST -H "Authorization: Bearer MM_TOKEN" \
  "https://om-XXX.edgegap.net/tickets" \
  -d '{
    "profile": "elimination",
    "group_id": "group-123",
    "attributes": {
      "selected_game_mode": "elimination",
      "selected_map": ["JungleMap", "VillagePlaza"]
    },
    "latencies": {
      "Chicago": 12.3,
      "Frankfurt": 23.2
    }
  }'

# Poll ticket status
curl -s -H "Authorization: Bearer MM_TOKEN" \
  "https://om-XXX.edgegap.net/tickets/TICKET_ID"

# Delete ticket (cancel matchmaking)
curl -s -X DELETE -H "Authorization: Bearer MM_TOKEN" \
  "https://om-XXX.edgegap.net/tickets/TICKET_ID"
```

**Note**: Matchmaker tokens use `Bearer` auth, the global API uses `token` auth.

---

## Container Registry

| Field | Value |
|-------|-------|
| **Registry** | `registry.edgegap.com` |
| **Project** | `arcas-champions-n3tkvcfhbvhf` |
| **Image path** | `arcas-champions-n3tkvcfhbvhf/arcastest6` |
| **Username** | `robot$arcas-champions-n3tkvcfhbvhf+client-push` |
| **Token** | `SFiNqps7tu5e3efrWCj9AzxR03c8YfAk` |
| **Storage** | 7.95 / 21.47 GB |

**CRITICAL**: Token contains `R03c` (zero-three) NOT `RO3c` (letter O). This single char caused all 401 auth failures initially.

Images are tagged by date: `2026-02-13_20-16`, `2025-07-31_16-45`, etc.

### How Images Get Pushed (Cloud Build Pipeline)

Docker can't run on the VM (no nested virtualization on GCP Windows). Instead:

```
VM: Linux BuildCookRun → C:\A\Builds\LinuxServer\ (1.53 GB)
VM: gcloud builds submit → uploads build context to GCS (~4 min)
Cloud Build: docker build + docker push → Edgegap registry (~4 min)
```

- Submit script: `C:\A\staging\submit-build.ps1`
- Cloud Build config: `C:\A\Builds\LinuxServer\cloudbuild.yaml`
- Region: `europe-west6`
- Uses Secret Manager for registry token (secret: `edgegap-registry-token`, version 4)

**Pitfalls solved**:
- Secret Manager: must strip trailing newline (`| tr -d '\n'`) before storing
- Cloud Build YAML: all bash `$vars` need `$$` escaping (only `${_TAG}` is Cloud Build substitution)
- Multi-step builds lose Docker config — must auth+build+push in single step

---

## Current State (2026-02-14)

### What's Working (End-to-End Tested)
- **Full pipeline tested**: Client → matchmaker → server deploys → player loads in → plays
- **arcas-testing matchmaker ONLINE** with casual + ranked profiles
- **arcas-champions app** with `testing-server` version (docker_tag: `2026-02-14_20-13`)
- **Container image working** — server boots, authenticates, loads players
- **Cloud Build pipeline** — VM → GCS → Cloud Build → Edgegap registry (~8 min)
- **API test endpoint** — returns correct casual/ranked matchmaker credentials
- **UE5 client config** — `QueryValueKey=casual`, `QueryValueKey_Ranked=ranked`
- **Server auth** — SECRET_TOKEN baked at compile time, API validates loadouts successfully
- **PATCH API confirmed** — `docker_tag` updatable on existing versions (no need to recreate)

### Legacy (Bevium Era — Don't Touch)
- `elimination` matchmaker still ONLINE (production)
- `arcastest6` app with 11 old versions (images may be expired)
- demo1, testqueue, prime, beta2main matchmakers (all OFFLINE)

---

## Hosting Tiers & Costs

| Tier | CPU | RAM | Rate Limit | Cost |
|------|-----|-----|-----------|------|
| Free | Shared | Shared | 100 req/s | Free (3h max, 1 concurrent) |
| Hobbyist | 1 vCPU | 2 GB | 200 req/s | $0.0312/hr |
| Studio | 6 vCPU | 12 GB | 750 req/s | $0.146/hr |
| Enterprise | 18 vCPU | 48 GB | 2000 req/s | $0.548/hr |

Game server containers are billed separately based on `req_cpu` and `req_memory` in the version config.

---

## File Locations

| File | Purpose |
|------|---------|
| `repos/ArcasChampionsAPI/server.js:1222` | `GET_MatchmakerCredentials` endpoint (hardcoded credentials) |
| `repos/ArcasChampionsAPI/matchmakerconfigs/demo1.json` | demo1 matchmaker profile |
| `repos/ArcasChampionsAPI/matchmakerconfigs/testqueue.json` | testqueue matchmaker profile |
| `repos/ArcasChampionsAPI/matchmakerconfigs/prime.json` | prime matchmaker profile |
| `repos/ArcasChampionsAPI/matchmakerconfigs/beta2main.json` | beta2main matchmaker profile (8v8) |

---

## Troubleshooting

### Deployment fails with "Unable to pull image"
- Container image tag is stale or expired in the registry
- Fix: Push a new image and create a new app version

### Matchmaker is OFFLINE
- Start it via the Edgegap dashboard (Matchmakers → select → Start)
- Or via API if endpoint is available

### Players stuck in SEARCHING
- Not enough players in queue to satisfy rules
- Check if expansions are configured to degrade gracefully
- Check if the matchmaker is actually ONLINE

### Players get HOST_ASSIGNED but can't connect
- Check the deployment status — is it READY?
- Verify the port mapping (external port ≠ internal port)
- Check if the game server is listening on the right port (7777 for newer versions, 7770 for older)

### No container logs after game ends
- Logs are only available while deployment is in READY state
- Enable `endpoint_storage` on the app version to persist logs
- Currently NO versions have endpoint_storage configured
