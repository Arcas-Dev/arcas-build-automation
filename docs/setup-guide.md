# GCP Build Automation for Unreal Engine 5

**Purpose**: Automated UE5 build pipeline triggered via SSH, with Steam deployment
**Author**: Arcas Games (Daniel Fong)
**Date**: 2026-01-28
**Engine**: Unreal Engine 5.5 (built from source)
**Tested With**: Arcas Champions (ArcasChampionsSteam target)

---

## Overview

This guide documents how to set up a fully automated UE5 build and Steam deployment pipeline using:

- **GCP Windows VM** - Build server
- **UE5 from Source** - Required for custom build targets (e.g., `CustomConfig`)
- **SteamCMD** - Automated Steam uploads
- **SSH + PowerShell** - Remote triggering and monitoring
- **Claude Code** (optional) - AI-assisted build management

```
┌─────────────────┐     SSH      ┌─────────────────┐     SteamCMD    ┌─────────────┐
│  Your Machine   │ ──────────▶  │   GCP Windows   │  ────────────▶  │    Steam    │
│  (Mac/Linux)    │   trigger    │   Build Server  │     upload      │   (Demo)    │
└─────────────────┘              └─────────────────┘                 └─────────────┘
                                        │
                                        │ BuildCookRun
                                        ▼
                                 ┌─────────────────┐
                                 │   UE5.5 Source  │
                                 │   + Project     │
                                 └─────────────────┘
```

---

## 1. Prerequisites

### 1.1 GCP Project Setup

```bash
# Create or select a GCP project
gcloud projects create your-project-id
gcloud config set project your-project-id

# Enable Compute Engine API
gcloud services enable compute.googleapis.com
```

### 1.2 GitHub Access to Epic's UE5 Source

1. Go to [unrealengine.com](https://www.unrealengine.com) and sign in
2. Navigate to **Connected Accounts** → Link your GitHub account
3. Accept the invitation email from Epic Games to join the `EpicGames` organization
4. Verify access: https://github.com/EpicGames/UnrealEngine (should not 404)

### 1.3 Steam Partner Account

1. Access to [Steamworks Partner Portal](https://partner.steamgames.com)
2. A **builder account** with permissions:
   - Edit App Metadata
   - Publish App Changes To Steam
3. Know your **App ID** and **Depot ID** (from SteamPipe settings)

---

## 2. GCP VM Setup

### 2.1 Create the VM

```bash
gcloud compute instances create ue5-build-server \
  --project=your-project-id \
  --zone=europe-west6-a \
  --machine-type=n2-standard-16 \
  --image-family=windows-2022 \
  --image-project=windows-cloud \
  --boot-disk-size=1000GB \
  --boot-disk-type=pd-ssd \
  --tags=allow-rdp,allow-ssh
```

**Recommended specs:**

| Spec | Value | Why |
|------|-------|-----|
| Machine Type | n2-standard-16 | 16 vCPU, 64GB RAM - needed for UE5 compilation |
| Disk | 1TB+ SSD | UE5 source (~200GB) + project + builds |
| Disk Type | pd-ssd | Critical for build performance |
| OS | Windows Server 2022 | Best UE5 compatibility |

### 2.2 Set Up SSH Access

```bash
# Generate SSH key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/ue5_build_key -C "your-username"

# Add public key to GCP project metadata
gcloud compute project-info add-metadata \
  --metadata-file ssh-keys=~/.ssh/ue5_build_key.pub

# Or add to specific instance
gcloud compute instances add-metadata ue5-build-server \
  --zone=europe-west6-a \
  --metadata-from-file ssh-keys=~/.ssh/ue5_build_key.pub
```

**Get the external IP:**
```bash
gcloud compute instances describe ue5-build-server \
  --zone=europe-west6-a \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

### 2.3 Install Build Tools (on VM)

RDP into the VM and install:

1. **Visual Studio 2022 Build Tools**
   - Download from: https://visualstudio.microsoft.com/downloads/
   - Select workloads:
     - Desktop development with C++
     - Game development with C++
   - Individual components:
     - MSVC v143 build tools
     - Windows 10/11 SDK

2. **Git for Windows**
   - Download from: https://git-scm.com/download/win
   - Include Git LFS

3. **.NET SDK 8.0** (usually bundled with UE5, but good to have)

---

## 3. UE5 from Source

### 3.1 Why Source Build?

If your project uses any of these, you need UE5 built from source:
- `CustomConfig` in Target.cs (e.g., `CustomConfig = "Steam"`)
- `BuildEnvironment = TargetBuildEnvironment.Unique`
- Custom engine modifications

The Epic Games Launcher version cannot build these targets.

### 3.2 Clone and Build

```powershell
# Clone to short path (avoid 260 char limit)
cd C:\
git clone --branch 5.5 https://github.com/EpicGames/UnrealEngine.git UE5.5

# Download dependencies (~20GB)
cd C:\UE5.5
.\Setup.bat

# Generate Visual Studio project files
.\GenerateProjectFiles.bat

# Build the engine (2-3 hours first time)
.\Engine\Build\BatchFiles\Build.bat UnrealEditor Win64 Development -WaitMutex
```

**Time estimates:**
| Step | Duration |
|------|----------|
| Clone | 30-60 min |
| Setup.bat | 30-60 min |
| GenerateProjectFiles.bat | 5-10 min |
| Engine build | 2-3 hours |

---

## 4. Project Setup

### 4.1 Clone Your Project

```powershell
# Use short path
mkdir C:\A
cd C:\A
git clone https://github.com/YourOrg/YourProject.git

# Install Git LFS content
cd YourProject
git lfs pull
```

### 4.2 Directory Structure

```
C:\
├── A\                              # Short path for project
│   ├── YourProject\                # Git repo
│   │   └── YourGame\               # UE5 project folder
│   │       └── YourGame.uproject
│   ├── Builds\                     # Build output
│   │   └── YourTarget\Windows\
│   ├── Scripts\                    # Automation scripts
│   │   ├── build-and-deploy.ps1
│   │   └── build.bat
│   └── Logs\                       # Build logs
│
├── UE5.5\                          # Engine (built from source)
│
└── SteamCMD\                       # Steam upload tool
    ├── steamcmd.exe
    └── app_build_XXXXX.vdf         # Your app config
```

---

## 5. SteamCMD Setup

### 5.1 Install SteamCMD

```powershell
# Download and extract
mkdir C:\SteamCMD
cd C:\SteamCMD
Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip" -OutFile steamcmd.zip
Expand-Archive steamcmd.zip -DestinationPath .

# First-time login (will prompt for Steam Guard code)
.\steamcmd.exe +login your_builder_account +quit
```

### 5.2 Create VDF Config

Create `C:\SteamCMD\app_build_XXXXX.vdf` (replace XXXXX with your App ID):

```vdf
"AppBuild"
{
    "AppID" "XXXXX"
    "Desc" "Automated build"
    "Preview" "0"
    "SetLive" "testing"
    "ContentRoot" "C:\A\Builds\YourTarget\Windows"
    "BuildOutput" "C:\SteamCMD\output"

    "Depots"
    {
        "YYYYY"
        {
            "FileMapping"
            {
                "LocalPath" "*"
                "DepotPath" "."
                "recursive" "1"
            }
            "FileExclusion" "*.pdb"
            "FileExclusion" "*.debug"
        }
    }
}
```

**Replace:**
- `XXXXX` = Your App ID
- `YYYYY` = Your Depot ID
- `YourTarget` = Your build target name
- `testing` = Branch name to deploy to

**Important:** Create a `testing` branch in Steamworks first (SteamPipe → Builds → New Branch)

---

## 6. Automation Scripts

### 6.1 Main Script: `build-and-deploy.ps1`

Save to `C:\A\Scripts\build-and-deploy.ps1`:

```powershell
# Build and Deploy Script
# Trigger: Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\A\Scripts\build.bat'

$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logFile = "C:\A\Logs\build-$timestamp.log"
$statusFile = "C:\A\status.txt"

function Log {
    param($msg)
    $time = Get-Date -Format 'HH:mm:ss'
    $line = "[$time] $msg"
    Write-Output $line
    Add-Content -Path $logFile -Value $line
}

function UpdateStatus {
    param($status)
    $content = "$status`nLog: $logFile`nStarted: $timestamp"
    Set-Content -Path $statusFile -Value $content
}

# ============================================
# CONFIGURATION - MODIFY THESE
# ============================================
$UE5Path = "C:\UE5.5"
$ProjectPath = "C:\A\YourProject\YourGame\YourGame.uproject"
$TargetName = "YourTargetName"
$BuildDir = "C:\A\Builds\YourTarget"
$SteamVDF = "C:\SteamCMD\app_build_XXXXX.vdf"
$SteamUser = "your_builder_account"
# ============================================

UpdateStatus 'BUILDING'
Log '=========================================='
Log 'BUILD AND DEPLOY'
Log '=========================================='
Log "Log file: $logFile"
Log ''

# Build
Log 'Starting BuildCookRun...'
$buildStart = Get-Date

$buildCmd = "$UE5Path\Engine\Build\BatchFiles\RunUAT.bat"
$buildArgs = "BuildCookRun -project=`"$ProjectPath`" -target=$TargetName -platform=Win64 -clientconfig=Shipping -build -cook -stage -pak -archive -archivedirectory=`"$BuildDir`""

$buildOutput = & cmd /c "$buildCmd $buildArgs 2>&1"
$buildExitCode = $LASTEXITCODE

$buildOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

$buildEnd = Get-Date
$buildDuration = $buildEnd - $buildStart
Log ''
Log "Build completed in $($buildDuration.Hours)h $($buildDuration.Minutes)m $($buildDuration.Seconds)s"
Log "Exit code: $buildExitCode"

if ($buildExitCode -ne 0) {
    UpdateStatus 'BUILD_FAILED'
    Log 'BUILD FAILED!'
    exit 1
}

Log 'Build succeeded!'

# Upload to Steam
UpdateStatus 'UPLOADING'
Log '=========================================='
Log 'UPLOADING TO STEAM'
Log '=========================================='

$steamOutput = & C:\SteamCMD\steamcmd.exe +login $SteamUser +run_app_build $SteamVDF +quit 2>&1
$steamExitCode = $LASTEXITCODE

$steamOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

Log "Steam upload exit code: $steamExitCode"

if ($steamExitCode -ne 0) {
    UpdateStatus 'UPLOAD_FAILED'
    Log 'STEAM UPLOAD FAILED!'
    exit 1
}

UpdateStatus 'COMPLETE'
Log '=========================================='
Log 'BUILD AND DEPLOY COMPLETE!'
Log '=========================================='
```

### 6.2 Batch Wrapper: `build.bat`

Save to `C:\A\Scripts\build.bat`:

```batch
@echo off
powershell -ExecutionPolicy Bypass -File C:\A\Scripts\build-and-deploy.ps1
```

---

## 7. SSH Commands (Run from Your Machine)

### 7.1 Start a Build

```bash
ssh -i ~/.ssh/ue5_build_key username@VM_IP \
  "powershell -Command \"Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\\A\\Scripts\\build.bat'\""
```

This starts the build in background and returns immediately.

### 7.2 Check Status (Quick)

```bash
ssh -i ~/.ssh/ue5_build_key username@VM_IP "type C:\\A\\status.txt"
```

Returns one of:
- `IDLE` - No build running
- `BUILDING` - Build in progress
- `UPLOADING` - Uploading to Steam
- `COMPLETE` - Finished successfully
- `BUILD_FAILED` - Build failed
- `UPLOAD_FAILED` - Steam upload failed

### 7.3 Monitor Build Progress

```bash
# Check AutomationTool log (cook progress)
ssh -i ~/.ssh/ue5_build_key username@VM_IP \
  "powershell -Command \"Get-Content 'C:\\UE5.5\\Engine\\Programs\\AutomationTool\\Saved\\Logs\\Log.txt' -Tail 30\""

# Check if build processes are running
ssh -i ~/.ssh/ue5_build_key username@VM_IP "tasklist | findstr /i dotnet"
```

### 7.4 View Full Build Log

```bash
ssh -i ~/.ssh/ue5_build_key username@VM_IP \
  "powershell -Command \"Get-Content 'C:\\A\\Logs\\build-*.log' -Tail 50\""
```

---

## 8. Integration with Claude Code

If using Claude Code, you can trigger builds conversationally:

**Example prompt:**
> "Start a build on the GCP server and let me know when it's done"

**Claude Code can:**
1. SSH to trigger the build
2. Periodically check status
3. Report when complete or if errors occur
4. Show relevant log excerpts

**SSH key setup for Claude Code:**
- Place private key at `~/.ssh/ue5_build_key`
- Ensure proper permissions: `chmod 600 ~/.ssh/ue5_build_key`

---

## 9. Build Times (Reference)

Based on Arcas Champions (medium-sized UE5 project):

| Build Type | Duration |
|------------|----------|
| **Incremental** (typical) | ~10 minutes |
| Full rebuild | ~2-3 hours |
| Steam Upload | 5-10 min |

Note: Incremental builds (when only code/content changes) are much faster than full rebuilds.

---

## 10. Troubleshooting

### Build fails with "unique build environment" error

```
Targets with a unique build environment cannot be built with an installed engine.
```

**Fix:** You must use UE5 built from source, not the Epic Games Launcher version.

### SSH connection drops during build

The build runs as a detached process via WMI, so it continues even if SSH disconnects. Just reconnect and check status.

### Steam upload fails with auth error

```bash
# Re-authenticate (may need Steam Guard code)
ssh ... "C:\SteamCMD\steamcmd.exe +login your_account +quit"
```

### Out of disk space

UE5 source + builds can exceed 500GB. Recommended: 1TB+ disk.

```bash
# Check disk space
ssh ... "powershell Get-PSDrive C"
```

---

## 11. Cost Estimates

| Resource | Cost |
|----------|------|
| n2-standard-16 VM (on-demand) | ~$0.76/hr |
| n2-standard-16 VM (spot/preemptible) | ~$0.23/hr |
| 1TB SSD | ~$170/month |
| **Per incremental build (~10 min)** | **~$0.13** |
| **Per full rebuild (~3 hours)** | **~$2.30** |

**Tip:** Stop the VM when not building to save costs.

---

## 12. Quick Reference

### VM Details (Example)

| Property | Value |
|----------|-------|
| Name | ue5-build-server |
| Zone | europe-west6-a |
| IP | (your external IP) |
| SSH User | (your username) |
| SSH Key | ~/.ssh/ue5_build_key |

### Key Paths

| Path | Purpose |
|------|---------|
| `C:\UE5.5` | Engine (built from source) |
| `C:\A\YourProject` | Your game project |
| `C:\A\Builds` | Build output |
| `C:\A\Scripts` | Automation scripts |
| `C:\A\Logs` | Build logs |
| `C:\A\status.txt` | Quick status file |
| `C:\SteamCMD` | Steam upload tool |

### Commands Summary

| Action | Command |
|--------|---------|
| Start build | `ssh ... "powershell -Command \"Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\\A\\Scripts\\build.bat'\""` |
| Check status | `ssh ... "type C:\\A\\status.txt"` |
| View log tail | `ssh ... "powershell -Command \"Get-Content 'C:\\A\\Logs\\build-*.log' -Tail 30\""` |
| Check processes | `ssh ... "tasklist \| findstr /i dotnet"` |

---

## Questions?

Contact: dan@arcas.games
