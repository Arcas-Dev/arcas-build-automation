# Docker Strategy for Arcas Build Pipeline

Status: COMPLETE — GCP Cloud Build working, end-to-end tested 2026-02-14
Last updated: 2026-02-14

---

## What is Docker? (Plain English)

Docker is a tool that **packages software into a standardized box** called a "container". Think of it like shipping containers in logistics — it doesn't matter what's inside, every container has the same shape and can be loaded onto any ship.

```
WITHOUT DOCKER                         WITH DOCKER

"It works on my machine" problem        Same box runs everywhere

┌─────────────────────┐                ┌─────────────────────┐
│  Your Computer      │                │  Docker Container    │
│                     │                │  ┌─────────────────┐ │
│  Ubuntu 22.04       │                │  │ Ubuntu 22.04    │ │
│  + specific libs    │                │  │ + specific libs  │ │
│  + specific config  │                │  │ + specific config│ │
│  + your game server │                │  │ + game server    │ │
│                     │                │  └─────────────────┘ │
│  ⚠️ If ANY of these  │                │  📦 All bundled     │
│  differ on another  │                │  together. Runs      │
│  machine = BROKEN   │                │  identically on ANY  │
└─────────────────────┘                │  machine with Docker │
                                       └─────────────────────┘
```

### The Three Docker Concepts

```
1. DOCKERFILE (recipe)          2. IMAGE (frozen meal)        3. CONTAINER (served meal)

A text file with steps:         The built result:              A running instance:

  FROM ubuntu:22.04             ┌──────────────────┐          ┌──────────────────┐
  RUN apt-get install jq        │  Layer 3: app    │          │  🏃 Running      │
  COPY . /app                   │  Layer 2: jq     │          │  server process  │
  CMD ./StartServer.sh          │  Layer 1: ubuntu │          │  on port 7777    │
                                └──────────────────┘          └──────────────────┘

  "Install these things,        Immutable snapshot.            Created from an image.
  copy my files, run this"      Can be pushed to a             Can have many containers
                                registry (like GitHub          from the same image.
                                for code, but for apps).       Edgegap runs this.
```

### What Edgegap Needs

Edgegap is a game server hosting platform. When a matchmaker finds a match:

```
1. Matchmaker says "deploy a server"
2. Edgegap pulls your IMAGE from a registry (like downloading it)
3. Edgegap creates a CONTAINER from your image (starts it running)
4. Container runs your game server
5. Players connect to it
6. Match ends → container is destroyed
```

So we need to:
1. **Build** a Docker image (from our Dockerfile + Linux server build)
2. **Push** it to a registry (Edgegap's registry at `registry.edgegap.com`)
3. **Tell** Edgegap "here's a new version, use this image"

### Why Docker is Complicated on Our VM

Docker images are like programs — they're built for a specific OS. Our game server runs on Linux (Ubuntu). Building a Linux image requires a Linux environment to execute the build steps.

```
Our VM: Windows Server 2022
Our Dockerfile: FROM ubuntu:22.04   ← This is LINUX

Problem: You can't run "apt-get install" (Linux command)
         on a Windows machine. Docker normally solves this
         by running a tiny Linux VM in the background
         (via Hyper-V or WSL2). But on our GCP GPU VM,
         we can't run VMs-inside-VMs (no nested virtualization).
```

This is the fundamental constraint we need to work around.

---

## Our VM's Constraints

| Factor | Status | Impact |
|--------|--------|--------|
| OS | Windows Server 2022 Datacenter | Docker Engine supported (not Desktop) |
| Nested virtualization | NOT AVAILABLE | No Hyper-V, no WSL2, no Linux VMs inside our VM |
| Docker installed | No | Need to install |
| GCP machine family | G2 (GPU) | GCP doesn't support nested virt on Windows VMs at all |

**Why can't we just install Docker Desktop?**
Docker Desktop is not supported on Windows Server (any version). It's a desktop-only product.
Docker Engine (the server/CLI version) CAN be installed, but it only runs Windows containers natively.

**Why can't we use Hyper-V or WSL2?**
Both require "nested virtualization" — running a VM inside a VM. GCP's virtualization layer (KVM)
does not support Hyper-V as a guest hypervisor. This is a GCP limitation, not a Docker limitation.

---

## All Options Evaluated

| Approach | Needs Nested Virt? | Works on Our VM? | Complexity | Notes |
|----------|-------------------|-------------------|-----------|-------|
| Docker Desktop | Yes (WSL2/Hyper-V) | NO | - | Not supported on Windows Server at all |
| Docker Engine + WSL2 | Yes | NO | - | GCP blocks nested virt on Windows |
| Docker Engine + Hyper-V | Yes | NO | - | GCP blocks nested virt on Windows |
| LCOW (Linux Containers on Windows) | Yes + deprecated | NO | - | Removed in Docker 23.0 |
| **GCP Cloud Build** | **No** | **YES** | **Low** | Build happens in Google's cloud |
| **Buildx Remote Builder** | **No** | **YES** | **Medium** | Needs a small Linux VM running BuildKit |
| **SSH + Remote Docker** | **No** | **YES** | **Medium** | Docker on a remote Linux machine |
| BuildKit on Windows | No | NO | - | Windows BuildKit can only build Windows images |
| QEMU emulation | Yes | NO | - | Needs Linux kernel for binfmt_misc |

**Only 3 options actually work.** All of them offload the build to a Linux environment.

---

## Recommended Approach: GCP Cloud Build

```
┌───────────────────────────────────────────────────────────────────┐
│                    OUR BUILD PIPELINE                              │
│                                                                   │
│  GCP VM (Windows Server 2022)                                     │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  1. git pull deploy/steam-testing                          │   │
│  │  2. Win64 BuildCookRun → Steam upload                      │   │
│  │  3. Linux BuildCookRun → C:\A\Builds\LinuxServer\          │   │
│  │  4. Strip debug symbols (.debug, .sym)                     │   │
│  │  5. Upload build to GCS bucket                             │   │
│  │  6. Trigger Cloud Build (gcloud builds submit)             │   │
│  │     └→ "Hey Google, build this Dockerfile for me"          │   │
│  └───────────────────────────────────────────────────────────┘   │
│       │                                                           │
│       │  Step 5: Upload ~1.5 GB to GCS                           │
│       │  Step 6: One gcloud command                               │
│       ▼                                                           │
│  GCP Cloud Build (Google's infrastructure)                        │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  - Runs on a Linux VM (Google manages it)                  │   │
│  │  - Reads our Dockerfile                                    │   │
│  │  - Builds the Linux image (FROM ubuntu:22.04...)           │   │
│  │  - Pushes to Edgegap registry                              │   │
│  └───────────────────────────────────────────────────────────┘   │
│       │                                                           │
│       │  Pushes image                                             │
│       ▼                                                           │
│  Edgegap Registry (registry.edgegap.com)                         │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  arcas-champions-n3tkvcfhbvhf/arcastest6:2026-02-12       │   │
│  │  Ready for deployment                                      │   │
│  └───────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────┘
```

### Why Cloud Build?

| Factor | Cloud Build | Remote BuildKit VM | SSH Remote Docker |
|--------|-------------|-------------------|-------------------|
| Extra VM to manage | No | Yes (~$15/mo) | Yes (~$15/mo) |
| Setup complexity | Low (1 gcloud command) | Medium (TLS certs, buildkitd) | Medium (SSH keys, dockerd) |
| Cost per build | ~$0.003/min × ~5min = $0.015 | $15/mo fixed | $15/mo fixed |
| Automation friendly | Yes (gcloud CLI) | Yes (docker buildx CLI) | Yes (docker -H ssh://) |
| Needs scope fix on VM | YES | No (runs from VM via SSH) | No (runs from VM via SSH) |

### Blocker: VM Scopes

Cloud Build requires `cloud-platform` scope on the VM's service account. Current scopes are too limited.

**To fix (one-time, takes ~2 min):**
1. Stop the VM (via gcloud or GCP Console)
2. Update scopes: `gcloud compute instances set-service-account ... --scopes=cloud-platform`
3. Start the VM
4. IP changes (ephemeral) — check new IP

---

## Alternative: Buildx Remote Builder (No Scope Fix Needed)

If we don't want to stop the VM to fix scopes, we can spin up a tiny Linux VM:

```
┌────────────────────────────┐         ┌────────────────────────────┐
│  Windows VM (existing)     │         │  Linux VM (new, e2-small)  │
│                            │  SSH    │                            │
│  docker buildx build       │ ──────► │  buildkitd daemon          │
│  --builder remote-linux    │         │  Builds Linux images       │
│  --push                    │         │  Pushes to registry        │
│                            │         │                            │
│  (just sends the context,  │         │  (does the actual work)    │
│   no Linux kernel needed)  │         │                            │
└────────────────────────────┘         └────────────────────────────┘
```

This approach:
- Does NOT need scope fix on the Windows VM
- Needs Docker Engine installed on the Windows VM (for the `docker buildx` CLI)
- Needs a small Linux VM with Docker/BuildKit (~$5/mo if e2-micro)
- Can be scripted end-to-end

But it adds another VM to manage.

---

## Alternative: Build on a Separate Linux VM via SSH (Simplest "Just Works")

Skip Docker on Windows entirely. Just SSH into a Linux VM and build there:

```
Windows VM                          Linux VM (e2-small)
  │                                   │
  │ 1. SCP build files ──────────►   │
  │                                   │ 2. docker build -t ...
  │                                   │ 3. docker push ...
  │ 4. SSH check result ◄──────────  │
  │                                   │
```

Pros: Dead simple, no Docker on Windows at all
Cons: Extra VM, SCP 1.5GB each build (slow on internal network? probably fast)

---

## Decision Matrix

| Priority | Cloud Build | Remote BuildKit | SSH Linux VM |
|----------|-------------|-----------------|--------------|
| No extra infra | ✅ | ❌ extra VM | ❌ extra VM |
| No scope fix | ❌ needs fix | ✅ | ✅ |
| Simplest automation | ✅ 1 command | ⚠️ setup needed | ✅ SCP + SSH |
| Cost | ~$0.02/build | ~$5-15/mo | ~$5-15/mo |
| Speed | ~5 min build | ~5 min build | ~5 min + SCP |
| Long-term maintenance | None | BuildKit updates | Docker updates |

---

## Recommendation

**Phase 1 (Now):** Use Cloud Build. Fix VM scopes once. Then `gcloud builds submit` handles everything.
No extra VMs, no Docker installation on Windows, minimal cost, fully scriptable.

**Phase 2 (If needed):** If Cloud Build is too slow or expensive at scale, add a dedicated Linux
build VM with Docker. But at our current build frequency (a few per week), Cloud Build is ideal.

---

## What the Automation Script Would Look Like

```powershell
# After Linux server build completes on the Windows VM:

# 1. Tag for this build
$tag = Get-Date -Format "yyyy-MM-dd_HH-mm"
$image = "registry.edgegap.com/arcas-champions-n3tkvcfhbvhf/arcastest6:$tag"

# 2. Create a cloudbuild.yaml in the build dir
$cloudbuild = @"
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', '$image', '.']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '$image']
"@
$cloudbuild | Out-File -FilePath "C:\A\Builds\LinuxServer\cloudbuild.yaml" -Encoding ascii

# 3. Submit to Cloud Build (uploads context + builds + pushes)
gcloud builds submit "C:\A\Builds\LinuxServer\" --config="C:\A\Builds\LinuxServer\cloudbuild.yaml"

# 4. Update Edgegap app version via API
# (separate step, uses curl to Edgegap API)
```

The `gcloud builds submit` command:
- Uploads the build directory (~1.5 GB) to a GCS staging bucket
- Spins up a Linux VM in Google's infrastructure
- Runs `docker build` and `docker push`
- Tears down the VM
- Total time: ~5-8 minutes

All triggered from one PowerShell command on our Windows VM. No Docker installation needed.

---

## Prerequisites Checklist

- [x] Fix VM scopes to `cloud-platform` (requires VM stop/start) — done 2026-02-12
- [x] Enable Cloud Build API in GCP project `arcas-champions`
- [x] Grant service account permissions for Cloud Build + Secret Manager
- [x] Configure Docker auth for Edgegap registry in Cloud Build — via Secret Manager (`edgegap-registry-token`, version 4)
- [x] Test `gcloud builds submit` with current Linux server build — first success 2026-02-13
- [x] Integrate into unified build script — `C:\A\Scripts\build-all.ps1`
- [x] End-to-end test (player loads into game from matchmaker-deployed container) — 2026-02-14
