# Cost Model Analysis

**Last Updated:** 2026-01-28

---

## Current Arcas Setup Costs (Reference)

| Resource | Specs | Cost |
|----------|-------|------|
| VM | n2-standard-16, 16 vCPU, 64GB RAM | $0.76/hr |
| Disk | 1TB SSD | $170/mo |
| **Per 10-min build** | | **$0.13** |
| **Monthly (disk only, VM stopped)** | | **$170** |

---

## Disk Requirements Analysis

### Minimum Viable VM Disk

| Component | Size |
|-----------|------|
| Windows Server 2022 | 30 GB |
| Visual Studio Build Tools | 20 GB |
| UE5.5 Source + Built | 300 GB |
| Working space (1 project) | 150 GB |
| **Total** | **500 GB** |

### For Multi-Project VMs

| Projects on VM | Disk Needed | GCP Cost |
|----------------|-------------|----------|
| 1 project | 500 GB | $85/mo |
| 2-3 projects | 750 GB | $127/mo |
| 4-5 projects | 1 TB | $170/mo |

**Note:** Projects can be swapped from cloud storage, so "projects on VM" means hot/loaded projects.

---

## Multi-Tenant Scenarios

### Scenario A: 10 Customers, 2 Always-On VMs

```
VM-1: UE5.5, handles customers 1-5 (projects rotate)
VM-2: UE5.5, handles customers 6-10 (projects rotate)
```

| Item | Cost/Month |
|------|------------|
| 2x n2-standard-16 (730 hrs each) | $1,109 |
| 2x 750GB SSD | $254 |
| GCS storage (1TB total) | $20 |
| GCS egress (200GB) | $24 |
| **Total** | **$1,407** |
| **Per Customer** | **$141** |

**Break-even price:** $150/customer/month
**Suggested price:** $199/customer/month (30% margin)

---

### Scenario B: 10 Customers, Spot VMs (Stopped When Idle)

```
VMs start on-demand, stop after builds complete
Disk persists (contains UE5 engine)
Projects pulled from GCS at build time
```

**Assumptions:**
- 20 builds/day average (2 per customer)
- 20 min average per build (including project swap)
- ~7 hours VM time/day = ~210 hours/month

| Item | Cost/Month |
|------|------------|
| VM time (210 hrs × $0.76) | $160 |
| 2x 750GB SSD (persistent) | $254 |
| GCS storage | $20 |
| GCS egress | $24 |
| **Total** | **$458** |
| **Per Customer** | **$46** |

**Break-even price:** $50/customer/month
**Suggested price:** $99/customer/month (54% margin)

---

### Scenario C: 10 Customers, Spot Instances (Cheapest)

```
Use preemptible/spot VMs at ~70% discount
Risk: VM can be terminated mid-build (retry needed)
```

| Item | Cost/Month |
|------|------------|
| Spot VM time (210 hrs × $0.23) | $48 |
| 2x 750GB SSD | $254 |
| GCS | $44 |
| **Total** | **$346** |
| **Per Customer** | **$35** |

**Suggested price:** $79/customer/month (56% margin)

---

## Scaling Analysis

### How Many Customers Per VM?

| Builds/Day | Build Time | VM Hours/Day | Max Customers/VM |
|------------|------------|--------------|------------------|
| 10 | 15 min | 2.5 hrs | 5 (conservative) |
| 20 | 15 min | 5 hrs | 10 |
| 30 | 15 min | 7.5 hrs | 15 (queue risk) |

**Recommendation:** 5-8 customers per VM to avoid queues.

### VM Pool Sizing Table

| Customers | VMs Needed | Disk Cost | Suggested Price | Revenue | Margin |
|-----------|------------|-----------|-----------------|---------|--------|
| 10 | 2 | $254 | $99/mo | $990 | 74% |
| 25 | 4 | $508 | $99/mo | $2,475 | 79% |
| 50 | 8 | $1,016 | $99/mo | $4,950 | 79% |
| 100 | 15 | $1,905 | $99/mo | $9,900 | 81% |

**Key insight:** Disk is the dominant cost. More customers = better margins.

---

## Per-Build Cost Breakdown

### Incremental Build (10 min)

| Item | Cost |
|------|------|
| VM time (10 min × $0.76/hr) | $0.13 |
| GCS project restore (50GB × $0.12/GB) | $0.00 (internal) |
| GCS build upload (5GB) | $0.00 (internal) |
| Steam upload (5GB egress) | $0.60 |
| **Total** | **~$0.75** |

### Full Rebuild (3 hours)

| Item | Cost |
|------|------|
| VM time (3 hrs × $0.76/hr) | $2.28 |
| Same storage costs | $0.60 |
| **Total** | **~$2.90** |

---

## Pricing Strategy Options

### Option 1: Simple Subscription

| Tier | Builds/Month | Price | Target Customer |
|------|--------------|-------|-----------------|
| Trial | 3 | Free | Onboarding |
| Indie | 30 | $99/mo | Solo devs |
| Studio | 100 | $249/mo | Small teams |
| Unlimited | ∞ | $499/mo | Active studios |

### Option 2: Hybrid (Base + Usage)

| Component | Price |
|-----------|-------|
| Base fee | $49/mo |
| Per build (1-20) | Included |
| Per build (21+) | $1.50 each |

**Example:** Customer with 50 builds/month = $49 + (30 × $1.50) = $94

### Option 3: Per-Project

| Connected Projects | Price |
|--------------------|-------|
| 1 project | $99/mo |
| 2 projects | $179/mo |
| 3+ projects | $79/mo each |

---

## Break-Even Analysis

### Minimum Viable Business (10 customers)

| Expense | Monthly |
|---------|---------|
| Infrastructure | $460 |
| Domain/hosting | $20 |
| Monitoring/logging | $50 |
| **Total** | **$530** |

**At $99/customer:** $990 revenue, $460 profit (46% margin)
**Break-even:** 6 customers

### Growth Path

| Customers | Revenue | Infra Cost | Gross Margin |
|-----------|---------|------------|--------------|
| 10 | $990 | $460 | 54% |
| 25 | $2,475 | $900 | 64% |
| 50 | $4,950 | $1,600 | 68% |
| 100 | $9,900 | $2,800 | 72% |

---

## Risk Factors

| Risk | Impact | Mitigation |
|------|--------|------------|
| Spot VM preemption | Build fails, retry needed | Use on-demand for paying customers |
| Long queues | Customer frustration | Auto-scale VM pool |
| Steam auth expires | Builds fail | Monitor + alert customer |
| UE5 version mismatch | Build fails | Support multiple versions |
| Large projects (>100GB) | Slow transfers | Tiered pricing for large projects |

---

## Conclusion

**Viable at $99/mo with 10+ customers.**

Key economics:
- Disk is dominant cost (~$127/customer for dedicated)
- Sharing VMs drops cost to ~$35-50/customer
- 70%+ margins achievable at scale
- Trial (3 free builds) costs ~$2.25, acceptable CAC

**Recommended starting point:**
- $99/mo subscription
- 30 builds included
- 3 free trial builds
- Target: 10 customers in first 3 months
