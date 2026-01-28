# Steam Credentials Handling

**Last Updated:** 2026-01-28

---

## Overview

Each customer needs to authenticate with Steam to upload builds. This document covers how SteamCMD authentication works and how we'd handle it securely in a multi-tenant environment.

---

## How SteamCMD Authentication Works

### Initial Login Flow

```
1. steamcmd.exe +login <username> <password>
2. Steam Guard prompt (email or mobile 2FA)
3. User enters code
4. SteamCMD creates/updates config.vdf with auth token
5. Subsequent logins use cached token (no password needed)
```

### Files Created

| File | Location | Purpose |
|------|----------|---------|
| `config.vdf` | `~/.steam/config/` or `SteamCMD/config/` | Auth tokens, account info |
| `loginusers.vdf` | Same | Cached user list |
| `ssfn*` | Same | Machine auth files (Steam Guard) |

### Token Validity

- Auth tokens persist until:
  - Password changed
  - Explicit logout (`+logout`)
  - Steam Guard settings changed
  - ~30-90 days inactivity (unclear exact timeout)
- **Best practice:** Re-authenticate every 30 days or on failure

---

## Multi-Customer Architecture

### Option A: Isolated Config Per Customer (Recommended)

```
GCS Storage:
  /customers/
    /cust-001/
      /steam/
        config.vdf      # Customer 1's auth token
        ssfn12345       # Steam Guard files
    /cust-002/
      /steam/
        config.vdf      # Customer 2's auth token
        ...
```

**Build Process:**
```bash
# 1. Download customer's Steam config
gsutil cp gs://arcas-build/customers/$CUSTOMER_ID/steam/* /tmp/steam-config/

# 2. Run SteamCMD with customer's config
steamcmd.exe \
  +force_install_dir /tmp/steam-config \
  +login $CUSTOMER_USERNAME \
  +run_app_build $VDF_PATH \
  +quit

# 3. Clean up (don't persist on VM)
rm -rf /tmp/steam-config
```

**Pros:**
- Full isolation between customers
- Compromise of one customer doesn't affect others
- Clear audit trail per customer

**Cons:**
- More storage management
- Need to download config for each build (~1MB, negligible)

---

### Option B: Shared Config Directory

```
VM Disk:
  /SteamCMD/
    /config/
      config.vdf  # Contains ALL customer accounts
```

**Build Process:**
```bash
steamcmd.exe +login $CUSTOMER_USERNAME +run_app_build $VDF_PATH +quit
```

**Pros:**
- Simpler management
- No download step needed

**Cons:**
- Single config.vdf with all accounts = security risk
- If VM compromised, all customer credentials exposed
- Harder to isolate/revoke individual customers

**Recommendation:** Option A (isolated)

---

## Customer Onboarding Flow

### Step 1: Customer Creates Builder Account

We provide instructions:

```markdown
## Create a Steam Builder Account

1. Create a new Steam account at store.steampowered.com
   - Suggested username: yourcompany-builder
   - Use a dedicated email (e.g., builder@yourcompany.com)

2. In Steamworks Partner Portal:
   - Go to Users & Permissions
   - Add the builder account
   - Grant ONLY these permissions:
     ✓ Edit App Metadata
     ✓ Publish App Changes to Steam
   - Do NOT grant:
     ✗ View Financial Info
     ✗ Manage Users
     ✗ Download Customer Data

3. Note your App ID and Depot ID from Steamworks
```

### Step 2: Initial Authentication

**Option A: Customer runs locally, uploads config**

```bash
# Customer runs on their machine:
steamcmd +login builder-account +quit
# Prompts for password and Steam Guard code

# Customer uploads resulting config.vdf to us
# (via dashboard upload or secure form)
```

**Option B: We authenticate via web session**

```
1. Customer enters builder username/password in our dashboard
2. We start SteamCMD login process
3. Dashboard shows "Enter Steam Guard code"
4. Customer enters code received via email/mobile
5. We capture config.vdf and store encrypted
```

**Security consideration:** Option B means we handle password (briefly). Option A is more secure but worse UX.

### Step 3: Store Credentials

```javascript
// Store in Secret Manager or encrypted DB
{
  customerId: "cust-001",
  steam: {
    username: "mycompany-builder",
    appId: "1234567",
    depotId: "1234568",
    branch: "testing",
    configVdf: "base64-encoded-encrypted-config",
    lastAuth: "2026-01-28T12:00:00Z"
  }
}
```

---

## Security Measures

### Encryption

| Data | Storage | Encryption |
|------|---------|------------|
| Username | Firestore | AES-256 |
| Password | Never stored | N/A |
| config.vdf | GCS | KMS-encrypted bucket |
| App/Depot IDs | Firestore | Plain (not sensitive) |

### Access Control

```
Service Account: arcas-build-worker
  - Can read customer Steam configs
  - Can write build logs
  - Cannot access other customer data

Admin Account:
  - Can manage customers
  - Cannot read Steam credentials directly
```

### Audit Logging

```javascript
// Log every Steam interaction
{
  timestamp: "2026-01-28T12:34:56Z",
  customerId: "cust-001",
  action: "steam_upload",
  appId: "1234567",
  branch: "testing",
  buildId: "build-xyz",
  result: "success",
  vmId: "vm-02"
}
```

---

## Handling Auth Failures

### Detection

```bash
# SteamCMD exit codes
0   = Success
5   = Invalid password
63  = Steam Guard code required
84  = Rate limited
```

### Recovery Flow

```
1. Build fails with auth error
2. Mark customer's auth as "expired"
3. Email customer: "Re-authentication required"
4. Customer clicks link → re-auth flow
5. New config.vdf stored
6. Retry build
```

---

## VDF File Format Reference

### config.vdf Structure

```vdf
"InstallConfigStore"
{
    "Software"
    {
        "Valve"
        {
            "Steam"
            {
                "AutoLoginUser"    "builder-account"
                "Accounts"
                {
                    "builder-account"
                    {
                        "SteamID"    "76561198xxxxx"
                        "Timestamp"  "1706400000"
                    }
                }
                "ConnectCache"
                {
                    // Cached connection data
                }
            }
        }
    }
}
```

### App Build VDF (per customer)

```vdf
"AppBuild"
{
    "AppID"         "1234567"
    "Desc"          "Automated build via Arcas"
    "SetLive"       "testing"
    "ContentRoot"   "C:\Builds\output\Windows"
    "BuildOutput"   "C:\Builds\steam-output"

    "Depots"
    {
        "1234568"
        {
            "FileMapping"
            {
                "LocalPath"   "*"
                "DepotPath"   "."
                "recursive"   "1"
            }
            "FileExclusion"  "*.pdb"
        }
    }
}
```

---

## Per-Customer Data Model

```javascript
// Firestore: customers/{customerId}
{
  id: "cust-001",
  name: "Awesome Games LLC",
  email: "dev@awesomegames.com",

  github: {
    repoUrl: "https://github.com/awesome-games/my-game",
    branch: "deploy/steam-testing",
    webhookSecret: "encrypted-secret"
  },

  steam: {
    builderUsername: "awesomegames-builder",
    appId: "1234567",
    depotId: "1234568",
    branch: "testing",
    // config.vdf stored in GCS, not here
    configPath: "gs://arcas-build/customers/cust-001/steam/config.vdf",
    lastAuthAt: Timestamp,
    authStatus: "valid" | "expired" | "pending"
  },

  unreal: {
    engineVersion: "5.5",
    targetName: "MyGameSteam",
    projectPath: "MyGame/MyGame.uproject"
  },

  subscription: {
    plan: "indie",
    buildsThisMonth: 12,
    buildsLimit: 30
  }
}
```

---

## Open Questions

- [ ] Can we programmatically detect when Steam Guard 2FA is required?
- [ ] What's the exact token expiration timeline?
- [ ] Can multiple VMs use the same config.vdf simultaneously?
- [ ] Does Valve have any restrictions on automated uploads?
- [ ] Rate limits on SteamCMD uploads?

---

## References

- [SteamCMD Documentation](https://developer.valvesoftware.com/wiki/SteamCMD)
- [SteamPipe Documentation](https://partner.steamgames.com/doc/sdk/uploading)
- [game-ci/steam-deploy](https://github.com/game-ci/steam-deploy)
- [Steam Web API Authentication](https://partner.steamgames.com/doc/webapi_overview/auth)
