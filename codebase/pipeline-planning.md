# Build Pipeline - Status & Design

Status: COMPLETE — end-to-end tested 2026-02-14
Last updated: 2026-02-14

---

## Pipeline Status

| Component | Status | Details |
|-----------|--------|---------|
| Win64 game build | WORKING | `build.bat` → BuildCookRun → Steam upload (~10 min) |
| Linux server build | WORKING | Cross-compile on VM, ~45 min full / ~10 min incremental |
| Dockerfile + StartServer.sh | WORKING | `chmod +x` fix applied, in `C:\A\Builds\LinuxServer\` |
| Docker image build | WORKING | Via GCP Cloud Build (not on VM — no nested virt) |
| Push to registry | WORKING | Cloud Build → Edgegap registry (~4 min upload + ~6 min build) |
| Edgegap app version | WORKING | `arcas-champions/testing-server` (PATCH for docker_tag confirmed) |
| Matchmaker profiles | WORKING | `arcas-testing` with casual + ranked profiles (ONLINE) |
| API credential update | WORKING | test API returns correct casual/ranked credentials |
| UE5 client config | WORKING | `QueryValueKey=casual` in `DefaultBeviumTools.ini` |
| Server auth token | WORKING | `Secrets/SecretToken.txt` baked at compile time |
| Unified build script | WORKING | `C:\A\Scripts\build-all.ps1` — single trigger for everything |
| End-to-end test | PASSED | Client → matchmaker → server deploys → player loads in → plays |

---

## End-to-End Test Results (2026-02-14)

Successfully tested ranked matchmaking flow:
1. Client sends `type=ranked` → test API returns arcas-testing credentials
2. Matchmaker creates ticket → expands to solo after 45s
3. Edgegap deploys container → Status.READY
4. Server boots, authenticates loadout via test API (SECRET_TOKEN working)
5. ServerTravel to `mp_ShipCrashSite_BombSmall` with `B_BASShooterGame_BombScenario`
6. Player loaded in and playing

**Pre-existing bugs observed (not ours):**
- `ControlPointWidgetComponent::BeginPlay` ensure — UI widget init on server (harmless)
- `B_TeamHealingSynergyDevice` CreateExport — missing template objects (harmless)
- Animation BP warnings spam — null references in `ABP_ItemAnimLayersBase` (cosmetic)
- `DeploymentContext` 404 — context URL fails but server proceeds via env vars

None of these crash the server. They're Bevium-era Blueprint issues.

---

## Unified Build Script

**Script**: `C:\A\Scripts\build-all.ps1`
**Trigger**: `C:\A\Scripts\build-all.bat` (wrapper)

### Optimal Execution Order

```
┌──────────────────────────────────────────────────────────────┐
│  1. GIT PULL                                           ~5s   │
│  git pull origin deploy/steam-testing                        │
└──────────────────────┬───────────────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────────────┐
│  2. LINUX SERVER BUILD (first — takes longer)        ~10 min │
│  RunUAT BuildCookRun -target=ArcasChampionsServer            │
│  -platform=Linux -server -noclient                           │
└──────────────────────┬───────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
┌─────────────────────┐  ┌─────────────────────────────────────┐
│  3a. CLOUD BUILD    │  │  3b. WIN64 CLIENT BUILD     ~10 min │
│  (background)       │  │  RunUAT BuildCookRun                │
│  gcloud builds      │  │  -target=ArcasChampionsSteam        │
│  submit ~8 min      │  │  -platform=Win64                    │
│                     │  │                                     │
│  uploads 1.5 GB     │  │  (runs while Cloud Build uploads)   │
│  docker build+push  │  │                                     │
└────────┬────────────┘  └──────────────────┬──────────────────┘
         │                                  │
         ▼                                  ▼
┌─────────────────────┐  ┌─────────────────────────────────────┐
│  4a. PATCH EDGEGAP  │  │  4b. STEAM UPLOAD             ~2 min│
│  version docker_tag │  │  SteamCMD → Demo testing branch     │
│  via API            │  │                                     │
└─────────────────────┘  └─────────────────────────────────────┘
                       │
                       ▼
               ┌───────────────┐
               │  5. COMPLETE  │
               └───────────────┘
```

### Why This Order Is Optimal

**Key insight**: UBT (Unreal Build Tool) uses separate intermediate directories for Linux and Win64 targets, so they CAN'T run in parallel on the same machine. But Cloud Build runs on GCP infrastructure, not the VM.

**Parallel opportunity**: After the Linux build finishes, we can kick off Cloud Build (uploads + builds Docker remotely) AND the Win64 client build simultaneously, since:
- Cloud Build runs on Google's servers, not the VM
- Win64 build uses the VM's CPU
- No resource conflict

**Sequential constraint**: Linux must finish before Cloud Build starts (it needs the build output). Win64 must finish before Steam upload.

### Timing Estimate

| Step | Duration | Cumulative | Notes |
|------|----------|------------|-------|
| Git pull | ~5s | 0:05 | |
| Linux server build | ~10 min (incr) / ~45 min (full) | 10:05 | |
| Cloud Build + Win64 (parallel) | ~10 min | 20:05 | Cloud Build ~8 min, Win64 ~10 min |
| Steam upload + PATCH (parallel) | ~2 min | 22:05 | |
| **Total (incremental)** | **~22 min** | | vs ~30 min sequential |
| **Total (full rebuild)** | **~57 min** | | vs ~65 min sequential |

Saves ~8 min per build by overlapping Cloud Build with Win64 compilation.

---

## Completed Items

### Docker Strategy (RESOLVED)

Docker can't run on the GCP Windows VM (no nested virtualization). Solution: **GCP Cloud Build** offloads Docker operations to Google's Linux infrastructure.

```
VM: Linux BuildCookRun → C:\A\Builds\LinuxServer\ (1.53 GB)
VM: gcloud builds submit → uploads context to GCS (~4 min)
Cloud Build: docker build + push → Edgegap registry (~4 min)
```

- Submit script: `C:\A\staging\submit-build.ps1`
- Cloud Build config: `C:\A\Builds\LinuxServer\cloudbuild.yaml`
- Region: `europe-west6`
- Service account: `1093142381010-compute@developer.gserviceaccount.com`

### VM Scopes (FIXED 2026-02-12)

Scopes updated to `cloud-platform` (full access, gated by IAM).

### Registry Choice (DECIDED)

Using Edgegap registry (`registry.edgegap.com`). ~12 / 21.47 GB used.

### Matchmaker Setup (DONE 2026-02-14)

- Created `arcas-testing` matchmaker with two profiles (casual, ranked)
- Both reference `arcas-champions/testing-server` app version
- Config file: `repos/arcas-build-automation/matchmaker-config/arcas-testing.json`
- URL: `https://om-pjotlrwfa6.edgegap.net`
- Token: `5b0bcde2-db8f-45cf-abc9-f160c0e168be`

### API Credential Flow (DONE 2026-02-14)

Updated `server.js` on test API:
- `type=casual` → arcas-testing matchmaker, casual profile
- `type=ranked` → arcas-testing matchmaker, ranked profile
- Legacy `test` and `demo` types preserved for backwards compat

### Server Auth Token (FIXED 2026-02-14)

Server uses compile-time `SECRET_TOKEN` for API authentication.

**Chain**: `ArcasChampionsServer.Target.cs` → reads `Config/Custom/Server/DefaultEngine.ini` → finds `SecretTokenPath=Secrets/SecretToken.txt` → bakes token into binary.

Without the secret file, token defaults to `TEXT("NULL")` → API returns 401 → player kicked.

**Fix**: Created `C:\A\ApeShooter\NewApeShooter\Secrets\SecretToken.txt` with the API auth token.

### Dockerfile chmod Fix (FIXED 2026-02-14)

Windows doesn't preserve Unix execute permissions. Added `chmod +x` in Dockerfile:
```dockerfile
RUN chmod +x /app/StartServer.sh /app/ArcasChampionsServer.sh /app/NewApeShooter/Binaries/Linux/ArcasChampionsServer
```

---

## What DOESN'T Need Changing Per Build

These are configured once and remain stable:

| Component | Why It's Stable |
|-----------|----------------|
| **Matchmaker** (`arcas-testing`) | References `testing-server` version by name — never needs updating |
| **Test API** (`server.js`) | Returns hardcoded matchmaker URL/token — only changes if matchmaker recreated |
| **UE5 client config** | `QueryValueKey=casual` in `DefaultBeviumTools.ini` — packaged by BuildCookRun |
| **Edgegap app** (`arcas-champions`) | Stable — only version's `docker_tag` changes |
| **Cloud Build config** (`cloudbuild.yaml`) | Stable — tag passed as substitution variable |
| **Dockerfile** | Stable — generic, doesn't reference specific builds |

**Only the `docker_tag` on `testing-server` version changes per build** (via PATCH API).

---

## Testing → Production Promotion (Future)

Months away, but the model:
- Testing: Development config, test API URL, arcas-testing matchmaker
- Production: Shipping config, prod API URL, production matchmaker
- Promotion = rebuild with Shipping config + prod API URL, push new container, create prod matchmaker

---

## Pitfalls & Lessons Learned

### Docker / Container
- **`chmod +x` required** — Windows doesn't set Unix execute permissions on files. Dockerfile must explicitly `chmod +x` all executables.
- **`sed -i 's/\r$//'`** — Strip Windows line endings from shell scripts in Dockerfile.
- **Single Cloud Build step** — Multi-step builds lose Docker config between steps. Auth + build + push must be in one step.
- **Cloud Build YAML escaping** — Bash `$vars` need `$$` prefix. Only `${_TAG}` is a Cloud Build substitution.

### Server Auth
- **SECRET_TOKEN is compile-time** — Baked into binary by `ArcasChampionsServer.Target.cs`. Changing the token requires a full Linux server rebuild.
- **Secret file must exist before build** — `Secrets/SecretToken.txt` at project root. Without it, token = `"NULL"` → 401 on all API calls.
- **Server sends token as `Authorization` header** — Must match the hardcoded value in `server.js`.

### Build Commands
- **`-target=ArcasChampionsServer`** — Required for Linux server builds. Without it, UBT sees 3 server targets and fails.
- **`-target=ArcasChampionsSteam`** — Required for Win64 client builds.
- **No `-platform=Linux` for client** — Client is always Win64.
- **Full rebuilds triggered by Target.cs changes** — Modifying `ArcasChampionsServer.Target.cs` triggers 895-action full recompile (~45 min).

### Registry
- **Token has `0` (zero) not `O` (letter)** in `R03c8YfAk`. Single char typo caused all 401s initially.
- **Secret Manager**: Strip trailing newline (`| tr -d '\n'`) before storing base64 credentials.
- **Unique tags only** — Edgegap caches by tag name. Always use date-based tags like `2026-02-14_20-13`.

### Server Runtime
- **DeploymentContext 404 is expected** — The context URL returns 404 but server proceeds using MM_* env vars.
- **Pre-existing BP ensure failures** — `ControlPointWidgetComponent`, `TeamHealingSynergyDevice` template errors. These are Bevium-era bugs, not crashes.
- **Animation BP warnings spam** — `ABP_ItemAnimLayersBase` null references. Cosmetic, doesn't affect gameplay.
