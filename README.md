# Arcas Build Automation

Automated UE5 build and Steam deployment pipeline for Arcas Champions.

**Stack:** GCP Windows VM + UE5.5 (source) + SteamCMD + SSH

```
┌─────────────┐      SSH       ┌─────────────────┐                ┌─────────────┐
│   Mac/PC    │ ──────────────▶│  GCP Windows VM │───────────────▶│ Steam Demo  │
│  (trigger)  │   1 command    │                 │    SteamCMD    │  (testing)  │
└─────────────┘                │  1. git pull    │                └─────────────┘
                               │  2. BuildCookRun│
                               │  3. Upload      │
                               └─────────────────┘
```

---

## Branch Strategy

```
feature/* ──▶ deploy/steam-testing ──▶ (automated build) ──▶ main (when stable)
```

| Branch | Purpose | Auto-build? |
|--------|---------|-------------|
| `main` | Stable code (don't touch) | NO |
| `deploy/steam-testing` | Active development | YES |
| `beta`, `early-access` | Legacy | NO |

**Workflow:**
1. Create feature branch from `deploy/steam-testing`
2. Work on feature, test locally
3. Merge to `deploy/steam-testing`
4. Trigger automated build → Steam testing branch

---

## Quick Start

### Start a Build

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.158.27.129 \
  "powershell -Command \"Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\\A\\Scripts\\build.bat'\""
```

### Check Status

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.158.27.129 "type C:\\A\\status.txt"
```

**Status values:** `IDLE` | `PULLING` | `BUILDING` | `UPLOADING` | `COMPLETE` | `PULL_FAILED` | `BUILD_FAILED` | `UPLOAD_FAILED`

### Monitor Progress

```bash
# View recent log output
ssh -i ~/.ssh/arcas_build_key daniel@34.158.27.129 \
  "powershell -Command \"Get-Content 'C:\\UE5.5\\Engine\\Programs\\AutomationTool\\Saved\\Logs\\Log.txt' -Tail 30\""

# Check if build is running
ssh -i ~/.ssh/arcas_build_key daniel@34.158.27.129 "tasklist | findstr /i dotnet"
```

---

## Arcas Configuration

### VM Details

| Property | Value |
|----------|-------|
| **VM Name** | arcas-build-server |
| **GCP Project** | arcas-champions |
| **Zone** | europe-west6-a |
| **External IP** | 34.158.27.129 |
| **Machine Type** | n2-standard-16 (64GB RAM) |
| **Disk** | 500GB SSD |
| **SSH User** | daniel |
| **SSH Key** | ~/.ssh/arcas_build_key |

### Directory Structure (on VM)

```
C:\
├── A\
│   ├── ApeShooter\                      # Git repo
│   │   └── NewApeShooter\               # UE5 project
│   │       └── NewApeShooter.uproject
│   ├── Builds\
│   │   └── ArcasChampionsSteam\Windows\ # Build output (4.87 GB)
│   ├── Scripts\
│   │   ├── build-and-deploy.ps1         # Main automation script
│   │   └── build.bat                    # Wrapper
│   ├── Logs\                            # Build logs
│   └── status.txt                       # Quick status file
│
├── UE5.5\                               # Engine (built from source)
│
└── SteamCMD\
    ├── steamcmd.exe
    └── app_build_3487030.vdf            # Demo app config
```

### Steam Apps

| App | ID | Depot | Automated? |
|-----|-----|-------|------------|
| **Arcas Champions Demo** | 3487030 | 3487031 | YES - `testing` branch |
| **Arcas Champions** | 3211990 | 3211991 | NO - manual only |

**Testing branch password:** `PrimeTester262`

### Build Target

- **Target:** `ArcasChampionsSteam`
- **Config:** Shipping
- **Platform:** Win64
- **Output:** `C:\A\Builds\ArcasChampionsSteam\Windows\`

---

## Build Pipeline

### What Happens

1. **Trigger** - SSH command starts `build.bat` as detached process
2. **Pull** - Fetches and pulls latest from `deploy/steam-testing` branch
3. **Build** - RunUAT.bat BuildCookRun (~2-2.5 hours)
   - Compile (~30-45 min)
   - Cook assets (~60-90 min)
   - Stage, Pak, Archive (~15 min)
4. **Upload** - SteamCMD uploads to Demo `testing` branch (~5-10 min)
5. **Complete** - Status updated, build live on Steam (includes git commit hash)

### Build Times

| Phase | Duration |
|-------|----------|
| Compile | 30-45 min |
| Cook | 60-90 min |
| Package | 10-15 min |
| Upload | 5-10 min |
| **Total** | **~2-3 hours** |

---

## Files in This Repo

```
arcas-build-automation/
├── README.md                 # This file
├── scripts/
│   ├── build-and-deploy.ps1  # Main PowerShell script (runs on VM)
│   └── build.bat             # Batch wrapper
└── docs/
    └── setup-guide.md        # Full setup guide (GCP, UE5, Steam)
```

---

## Adapting for Other Games

This pipeline can be adapted for any UE5 game with Steam deployment. See [docs/setup-guide.md](docs/setup-guide.md) for the full setup process.

### Key Changes Needed

1. **VM Setup**
   - Create your own GCP project and VM
   - Generate your own SSH keys
   - Clone your UE5 project

2. **Script Configuration** (`build-and-deploy.ps1`)
   ```powershell
   # Modify these variables:
   $UE5Path = "C:\UE5.5"                              # Engine path
   $ProjectPath = "C:\A\YourProject\YourGame.uproject" # Your .uproject
   $TargetName = "YourTargetName"                      # Build target
   $BuildDir = "C:\A\Builds\YourTarget"               # Output path
   $SteamVDF = "C:\SteamCMD\app_build_XXXXX.vdf"      # Your VDF
   $SteamUser = "your_builder_account"                 # Steam account
   ```

3. **Steam VDF** (`app_build_XXXXX.vdf`)
   ```vdf
   "AppBuild"
   {
       "AppID" "YOUR_APP_ID"
       "Desc" "Automated build"
       "SetLive" "testing"
       "ContentRoot" "C:\A\Builds\YourTarget\Windows"
       "Depots"
       {
           "YOUR_DEPOT_ID"
           {
               "FileMapping"
               {
                   "LocalPath" "*"
                   "DepotPath" "."
                   "recursive" "1"
               }
           }
       }
   }
   ```

4. **SSH Commands**
   - Update IP address and username
   - Update SSH key path

### Requirements

- **UE5 from Source** - Required if using `CustomConfig` or custom build environments
- **GCP Account** - Or any Windows VM provider (AWS, Azure, etc.)
- **Steam Partner Access** - With builder account permissions
- **~750GB disk** - UE5 source + project + builds

### Estimated Setup Time

| Task | Duration |
|------|----------|
| GCP VM creation | 30 min |
| Build tools install | 1-2 hours |
| UE5 source clone + build | 4-6 hours |
| SteamCMD setup | 30 min |
| Script configuration | 30 min |
| **Total** | **~1 day** |

---

## Troubleshooting

### "Unique build environment" error
Your target uses `CustomConfig` or similar. You must use UE5 built from source, not Epic Games Launcher.

### SSH disconnects during build
The build runs detached via WMI - it continues even if SSH drops. Just reconnect and check status.

### Steam auth fails
Re-authenticate: `ssh ... "C:\SteamCMD\steamcmd.exe +login your_account +quit"`

### Out of disk space
UE5 source needs ~200GB, builds need ~10-50GB each. Use 750GB+ disk.

---

## Cost

| Resource | Cost |
|----------|------|
| VM (on-demand) | ~$0.76/hr |
| VM (spot) | ~$0.23/hr |
| 500GB SSD | ~$85/month |
| **Per build (on-demand)** | **~$2.30** |
| **Per build (spot)** | **~$0.70** |

**Tip:** Stop VM when not building.

---

## Contact

**Arcas Games** - dan@arcas.games
