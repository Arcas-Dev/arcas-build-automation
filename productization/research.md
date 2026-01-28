# UE5 Build Automation SaaS - Product Research

**Date:** 2026-01-28
**Status:** Research & Ideation Phase

---

## Executive Summary

Exploring the viability of productizing our UE5 build automation pipeline as a SaaS offering. Key value proposition: "Connect GitHub + Steam → push to deploy" for Unreal Engine games.

**Market gap:** No turnkey solution exists (unlike Unity Cloud Build).

---

## 1. Market Research

### Why No Solution Exists

| Challenge | Impact |
|-----------|--------|
| UE5 project size | 80-200GB+ per project |
| Build times | 2-5 hours (full), 10-30 min (incremental) |
| Engine compilation | Source builds require specific toolchains |
| Version fragmentation | UE 5.0, 5.1, 5.2, 5.3, 5.4, 5.5 all in active use |
| Custom engine builds | Many studios modify engine source |

### What Studios Currently Use

**AAA Studios:**
- Perforce + Jenkins/Horde
- Incredibuild for acceleration
- Dedicated build farms

**Indie Studios:**
- Manual builds (most common)
- Self-hosted Jenkins/GitHub Actions
- Nothing (build locally, upload manually)

### Competitive Landscape

| Solution | UE5 Support | Steam Deploy | Managed Service |
|----------|-------------|--------------|-----------------|
| Unity Cloud Build | N/A | Yes | Yes |
| Epic Horde | Yes | No | No (self-hosted) |
| Incredibuild | Acceleration only | No | Partial |
| GameCI | Unity only | Yes | No |
| **Our Product** | Yes | Yes | **Yes** |

**Key differentiator:** First managed UE5 → Steam deployment service.

---

## 2. Disk & Storage Requirements

### Per-VM Breakdown

| Component | Size | Notes |
|-----------|------|-------|
| Windows Server 2022 | ~30 GB | Base OS |
| Visual Studio Build Tools | ~20 GB | Required for UE5 |
| UE5 Source (one version) | ~200 GB | Engine source code |
| UE5 Built Engine | ~80-100 GB | Compiled binaries, shaders |
| **Subtotal (Base VM)** | **~350 GB** | Shared across projects |
| Customer Project | 20-100 GB | Varies by project |
| DDC Cache | 20-50 GB | Derived Data Cache |
| Build Output | 5-50 GB | Cleared after Steam upload |
| **Working Space** | ~150 GB | For active build |
| **Total per VM** | **~500 GB** | Minimum viable |

### Multi-Version Considerations

If supporting multiple UE5 versions on same VM:
- Each version: +300 GB
- UE 5.4 + 5.5: ~650 GB base
- Recommendation: Separate VM pools per major version

### Storage Optimization Strategies

1. **Clear builds after upload** - Saves 5-50 GB per build
2. **Shared DDC across projects** - Some cache is reusable
3. **Project cold storage** - Move inactive projects to object storage
4. **Tiered SSD/HDD** - OS+Engine on SSD, project archives on HDD

### Recommended VM Disk Sizes

| Scenario | Disk Size | Cost (GCP) |
|----------|-----------|------------|
| Single UE5 version, 1 project | 500 GB | ~$85/mo |
| Single UE5 version, 2-3 projects | 750 GB | ~$127/mo |
| Two UE5 versions, 2-3 projects | 1 TB | ~$170/mo |

---

## 3. Multi-Tenant Architecture

### Scenario: 10 Customers, Minimizing VMs

**Assumptions:**
- Average 2 builds per customer per day = 20 builds/day
- Incremental build time: ~15 min average
- Total build time needed: 300 min/day = 5 hours

**VM Pool Sizing:**

| VMs | Capacity (8hr day) | Queue Risk | Cost |
|-----|-------------------|------------|------|
| 1 VM | 32 builds/day | High (single point of failure) | ~$260/mo |
| 2 VMs | 64 builds/day | Low | ~$430/mo |
| 3 VMs | 96 builds/day | Very low | ~$600/mo |

**Recommendation:** 2 VMs for 10 customers = ~$43/customer/month infrastructure cost.

### Project Switching Strategy

When a VM needs to build a different customer's project:

```
1. Archive current project to GCS (~5-10 min for 50GB)
2. Pull new project from GCS (~5-10 min)
3. Build (~15 min incremental, longer if cache miss)
4. Upload to Steam (~5 min)
5. VM ready for next project
```

**Project switch overhead:** 10-20 min
**Mitigation:** Smart scheduling to batch builds by project

### Scheduling Algorithm (Concept)

```
Priority Queue:
1. Builds for projects already loaded on a VM (fastest)
2. Builds for projects with warm cache in GCS
3. First-time builds (cold start)

VM Assignment:
- If project loaded on VM → assign to that VM
- If all VMs busy → queue with ETA
- If queue > threshold → consider spinning up spot VM
```

---

## 4. Steam Credentials Handling

### How Steam Authentication Works

SteamCMD requires authentication to upload builds:

1. **Username + Password** - Initial login
2. **Steam Guard** - 2FA code (email or mobile)
3. **config.vdf** - Cached auth token after successful login

### Per-Customer Requirements

Each customer needs to provide:

| Item | Purpose | Security Concern |
|------|---------|------------------|
| Steam Builder Username | Login to Steamworks | Low (can be dedicated account) |
| Steam Builder Password | Login | Medium (we store it) |
| Steam Guard access | Initial auth | One-time during onboarding |
| App ID | Which game to upload | None |
| Depot ID | Which depot | None |
| Branch name | Target branch (e.g., "testing") | None |

### Recommended Security Model

**Customer creates dedicated builder account:**
1. Create new Steam account (e.g., `mycompany-builder`)
2. In Steamworks, add this account with ONLY these permissions:
   - Edit App Metadata
   - Publish App Changes to Steam
3. Do NOT give: Financial permissions, user data access, etc.

**We store:**
- Builder username (encrypted)
- Builder password (encrypted, or use secret manager)
- Cached config.vdf (encrypted)

**Authentication flow:**
```
Onboarding:
1. Customer provides builder credentials
2. We run SteamCMD login, customer provides Steam Guard code
3. We store resulting config.vdf (contains auth token)
4. Token is valid until password change or explicit logout

Per-build:
1. Use cached config.vdf for auth
2. No password needed (token-based)
3. If token expires → notify customer to re-auth
```

### VDF File Structure

```vdf
"InstallConfigStore"
{
    "Software"
    {
        "Valve"
        {
            "Steam"
            {
                "Accounts"
                {
                    "builder_account_name"
                    {
                        "SteamID" "765611..."
                        "Timestamp" "1706400000"
                    }
                }
            }
        }
    }
}
```

### Multi-Customer VDF Handling

**Option A: Separate VDF per customer**
- Store in GCS: `gs://arcas-build/customers/{id}/config.vdf`
- Copy to VM before Steam upload
- Clean after upload

**Option B: Combined VDF with multiple accounts**
- Single VDF with all builder accounts
- SteamCMD selects account via `+login username`
- Risk: Single file compromise exposes all

**Recommendation:** Option A (isolated per customer)

---

## 5. Cost Model Analysis

### Infrastructure Costs (GCP)

| Resource | Specs | Monthly Cost |
|----------|-------|--------------|
| n2-standard-16 VM | 16 vCPU, 64GB RAM | ~$550/mo (always-on) |
| n2-standard-16 VM | 16 vCPU, 64GB RAM | ~$0.76/hr (on-demand) |
| Spot VM | Same specs | ~$0.23/hr (preemptible) |
| 500GB SSD | pd-ssd | ~$85/mo |
| 1TB SSD | pd-ssd | ~$170/mo |
| GCS Storage | Standard | ~$0.02/GB/mo |
| GCS Egress | To internet | ~$0.12/GB |

### Cost Per Build (Current Arcas Setup)

| Build Type | Time | VM Cost | Total |
|------------|------|---------|-------|
| Incremental | 10 min | $0.13 | ~$0.15 |
| Incremental (spot) | 10 min | $0.04 | ~$0.05 |
| Full rebuild | 3 hours | $2.28 | ~$2.50 |

### Multi-Tenant Cost Model

**Scenario: 2 VMs serving 10 customers**

| Item | Monthly Cost |
|------|--------------|
| 2x n2-standard-16 (always-on) | $1,100 |
| 2x 750GB SSD | $254 |
| GCS for project storage (500GB) | $10 |
| GCS egress (100GB/mo) | $12 |
| **Total Infrastructure** | **~$1,376/mo** |
| **Per Customer** | **~$138/mo** |

**With spot instances (VMs stopped when idle):**

| Item | Monthly Cost |
|------|--------------|
| 2x 750GB SSD (persistent) | $254 |
| VM time (200 builds × 20min × $0.76/hr) | $51 |
| GCS | $22 |
| **Total Infrastructure** | **~$327/mo** |
| **Per Customer** | **~$33/mo** |

### Break-Even Pricing

| Model | Our Cost | Min Price | Suggested Price | Margin |
|-------|----------|-----------|-----------------|--------|
| Always-on VMs | $138/customer | $150/mo | $199/mo | 31% |
| Spot + stopped VMs | $33/customer | $50/mo | $99/mo | 67% |

---

## 6. Business Model Options

### Option A: Subscription Tiers

| Tier | Builds/Month | Price | Our Cost | Margin |
|------|--------------|-------|----------|--------|
| **Trial** | 3 builds | Free | ~$1 | Loss leader |
| **Indie** | 30 builds | $99/mo | ~$30 | 70% |
| **Studio** | 100 builds | $249/mo | ~$80 | 68% |
| **Team** | Unlimited | $499/mo | ~$150 | 70% |

### Option B: Pay-Per-Build

| Build Type | Price | Our Cost | Margin |
|------------|-------|----------|--------|
| Incremental | $2 | $0.15 | 92% |
| Full rebuild | $10 | $2.50 | 75% |
| First build (setup) | $25 | $10 | 60% |

**Hybrid:** $29/mo base + $1/build over 10

### Option C: Per-Project Pricing

- $149/mo per connected project
- Includes unlimited builds
- Simple, predictable

---

## 7. Technical Architecture (Concept)

```
┌─────────────────────────────────────────────────────────────────┐
│                        CUSTOMER SIDE                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   GitHub Repo ──webhook──→ Arcas Build Service                  │
│   (push to testing branch)                                      │
│                                                                 │
│   Steam Builder Account ──credentials──→ Stored encrypted       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ARCAS BUILD SERVICE                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   API Layer (Cloud Run)                                         │
│   ├── Webhook receiver                                          │
│   ├── Build queue manager                                       │
│   ├── Customer dashboard API                                    │
│   └── Billing integration                                       │
│                                                                 │
│   Build Orchestrator                                            │
│   ├── VM pool manager                                           │
│   ├── Project cache manager                                     │
│   ├── Build scheduler                                           │
│   └── Steam upload handler                                      │
│                                                                 │
│   VM Pool (GCP)                                                 │
│   ├── VM-1: UE5.5, Project A loaded                             │
│   ├── VM-2: UE5.5, Project B loaded                             │
│   └── VM-N: (auto-scaled)                                       │
│                                                                 │
│   Storage (GCS)                                                 │
│   ├── /customers/{id}/project-cache/                            │
│   ├── /customers/{id}/steam-config/                             │
│   └── /customers/{id}/build-logs/                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         STEAM                                   │
├─────────────────────────────────────────────────────────────────┤
│   SteamCMD upload to customer's app/depot/branch                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. Open Questions

### Technical
- [ ] How to handle custom engine builds?
- [ ] UE5 EULA implications for hosting builds?
- [ ] Can we cache DDC across different projects?
- [ ] How to handle build failures gracefully?

### Business
- [ ] Market size: How many UE5 indie studios ship on Steam?
- [ ] Willingness to pay: Would studios pay $99-249/mo?
- [ ] Support burden: How much hand-holding for onboarding?
- [ ] Competition risk: Could Epic or Valve build this?

### Legal
- [ ] UE5 license terms for build-as-a-service?
- [ ] Steam partner agreement implications?
- [ ] Data residency requirements?

---

## 9. Next Steps

1. **Validate demand** - Talk to indie UE5 developers
2. **Prototype dashboard** - Simple UI for connecting GitHub/Steam
3. **Test multi-tenant** - Run 2-3 projects on single VM
4. **Cost optimization** - Experiment with spot instances
5. **Legal review** - Check UE5 EULA and Steam terms

---

## 10. References

- [Epic Horde Documentation](https://dev.epicgames.com/documentation/en-us/unreal-engine/horde-in-unreal-engine)
- [GameCI Steam Deploy](https://game.ci/docs/github/deployment/steam/)
- [SteamCMD Documentation](https://developer.valvesoftware.com/wiki/SteamCMD)
- [Hetzner €0.50 Builds](https://medium.com/@anton_ds/cloud-build-of-unreal-engine-5-5-server-for-0-5-5a2fdc94cba1)
- [Azure Cloud Build Pipelines](https://learn.microsoft.com/en-us/gaming/azure/reference-architectures/azurecloudbuilds-0-intro)
