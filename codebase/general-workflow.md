# ApeShooter Development Workflow

The game runs on UE5.5 (built from source) on a GCP Windows VM. Code changes are made via SSH, Blueprint/asset changes require RDP into the Editor. Builds deploy to Steam automatically.

---

## VM Access

| Method | Command |
|--------|---------|
| **SSH** | `ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42` |
| **SCP** | `scp -i ~/.ssh/arcas_build_key <local> daniel@34.65.146.42:"C:/A/staging/"` |
| **RDP** | Windows Remote Desktop to `34.65.146.42` (user: `daniel`) |

**Staging area**: `C:\A\staging\` - drop zone for files before deploying to project.

---

## Development Cycle

```
┌─────────────────────────────────────────────────────────────────┐
│  1. SCOPE + ANALYSIS                                            │
│                                                                  │
│  - Read existing C++ files from VM via SSH                      │
│  - Understand class hierarchy, existing patterns                │
│  - Check .Build.cs for module dependencies (UMG, GAS, etc.)    │
│  - Read research docs (research/, codebase/)                    │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  2. C++ CODE CHANGES (Claude via SSH)                           │
│                                                                  │
│  a. Write files locally to /tmp/                                │
│  b. Write a PowerShell deploy script                            │
│  c. SCP all files to C:\A\staging\                              │
│  d. SSH execute deploy script (backs up originals, copies)      │
│  e. SSH trigger compile                                          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  3. EDITOR WORK (Dan via RDP)                                   │
│                                                                  │
│  - Open UE5 Editor on VM                                        │
│  - Modify Blueprint assets (.uasset) - binary, can't edit SSH  │
│  - Set UPROPERTY values in Class Defaults                       │
│  - Wire Blueprint Event Graph nodes                             │
│  - Reparent widgets to new C++ base classes                     │
│  - Adjust layout/positioning in Widget Designer                 │
│  - PIE test (Play in Editor)                                    │
│  - Compile + Save all                                           │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  4. COMMIT + PUSH                                               │
│                                                                  │
│  - git add specific files (skip .bak, .umap PIE autosaves)     │
│  - git commit on deploy/steam-testing branch                    │
│  - git push origin deploy/steam-testing                          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  5. BUILD + DEPLOY (Automated)                                  │
│                                                                  │
│  - Trigger: SSH execute build.bat                               │
│  - Script: git pull → BuildCookRun (~10-15 min) → Steam upload  │
│  - Output: Live on Steam Demo (3487030) testing branch          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  6. TEST ON STEAM                                               │
│                                                                  │
│  - Dan updates Steam client to testing branch                   │
│  - Password: PrimeTester262                                     │
│  - Play and verify changes in-game                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## SCP Strategy for File Changes

### Pattern: Local Write → SCP → Deploy Script → Compile

```bash
# 1. Write files locally
/tmp/my-change/
├── NewFile.h
├── NewFile.cpp
├── ModifiedFile.h
├── ModifiedFile.cpp
└── deploy.ps1          # PowerShell script to place files + make backups

# 2. Create staging dir on VM
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'if not exist C:\A\staging mkdir C:\A\staging'"

# 3. SCP everything
scp -i ~/.ssh/arcas_build_key /tmp/my-change/* \
  daniel@34.65.146.42:"C:/A/staging/"

# 4. Execute deploy script
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -ExecutionPolicy Bypass -File C:\A\staging\deploy.ps1"
```

### Deploy Script Template (PowerShell)

```powershell
$ErrorActionPreference = "Stop"
$PluginSrc = "C:\A\ApeShooter\NewApeShooter\Plugins\GameFeatures\BASShooterCore\Source\BASShooterCoreRuntime"

# Always backup before overwriting
Copy-Item "$PluginSrc\Public\Path\OriginalFile.h" "$PluginSrc\Public\Path\OriginalFile.h.bak" -Force

# Copy new/modified files
Copy-Item "C:\A\staging\NewFile.h" "$PluginSrc\Public\UI\NewFile.h" -Force
Copy-Item "C:\A\staging\NewFile.cpp" "$PluginSrc\Private\UI\NewFile.cpp" -Force
Copy-Item "C:\A\staging\ModifiedFile.h" "$PluginSrc\Public\Path\ModifiedFile.h" -Force

Write-Host "All files deployed!"
```

---

## Compilation

### Compile Command

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Start-Process -FilePath 'C:\UE5.5\Engine\Build\BatchFiles\Build.bat' \
  -ArgumentList 'LyraEditor Win64 Development -Project=C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject -WaitMutex -FromMsBuild' \
  -RedirectStandardOutput 'C:\A\Logs\compile-mychange.log' \
  -RedirectStandardError 'C:\A\Logs\compile-mychange-err.log' \
  -NoNewWindow -Wait; Write-Host 'EXIT CODE:' \$LASTEXITCODE\""
```

### What Triggers UHT (Unreal Header Tool) Regeneration

UHT regenerates reflection code when files contain new/modified:
- `UCLASS()`, `USTRUCT()`, `UENUM()`
- `UPROPERTY()`, `UFUNCTION()`
- `GENERATED_BODY()`

**Incremental compile times:**
- Header-only changes: ~30-45 seconds
- New files + header mods: ~42 seconds (11 actions typical)
- Full rebuild: ~2+ hours (avoid)

### Checking Compile Results

```bash
# Check log tail
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Get-Content 'C:\A\Logs\compile-mychange.log' -Tail 30\""

# Check errors
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Get-Content 'C:\A\Logs\compile-mychange-err.log'\""
```

**Success indicators:**
- `Total execution time: XX.XX seconds`
- No `error C` or `error :` lines in output
- `Total of N written` = UHT generated reflection code

### Benign Warning (Ignore)

```
Circular dependency on BeviumTools.Build.cs detected:
  Full Route: Target -> BeviumTools.Build.cs -> Edgegap.Build.cs -> BeviumTools.Build.cs
```

This appears every compile. Legacy from Bevium. Does not block the build.

---

## Build + Steam Deploy

### Trigger Build Script

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\\A\\Scripts\\build.bat'\""
```

### Monitor Build

```bash
# Check status
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 "cmd /c 'type C:\\A\\status.txt'"

# Check log tail
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Get-Content 'C:\\A\\Logs\\build-*.log' -Tail 30 | Select-Object -Last 30\""

# Check if build process is running
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "tasklist | findstr -i \"Unreal dotnet ShaderCompile UnrealPak\""
```

### Build Pipeline (build.bat)

1. `git pull origin deploy/steam-testing`
2. `BuildCookRun` (~10-15 min) → outputs to `C:\A\Builds\ArcasChampionsSteam\Windows`
3. `SteamCMD` upload to Demo app (3487030) `testing` branch
4. Writes status to `C:\A\status.txt`

### Steam Reference

| App | ID | Use |
|-----|-----|-----|
| **Demo** | 3487030 | Automated builds (`testing` branch, pw: `PrimeTester262`) |
| **Main** | 3211990 | Manual releases only - DO NOT deploy here |

---

## Git Workflow

### Branch Strategy

```
feature/* → deploy/steam-testing → (build & test) → main (when stable)
```

- **`main`** - Stable code from Bevium era. DO NOT TOUCH.
- **`deploy/steam-testing`** - Active development, automated builds pull from here.

### Commit Best Practices

```bash
# Stage specific files (skip .bak, .umap, temp files)
git add path/to/file.h path/to/file.cpp path/to/Asset.uasset

# Do NOT stage:
# - *.bak (backup files)
# - *.umap (map autosaves from PIE)
# - C:\A\staging\* (temp deployment files)
```

---

## Key Paths on VM

| Path | Purpose |
|------|---------|
| `C:\UE5.5` | UE5.5 built from source |
| `C:\A\ApeShooter\NewApeShooter` | Game project root |
| `C:\A\Builds\ArcasChampionsSteam\Windows` | Build output |
| `C:\A\Scripts\build.bat` | Build + Deploy script |
| `C:\A\status.txt` | Build status file |
| `C:\A\Logs\` | Build and compile logs |
| `C:\A\staging\` | File deployment staging area |

### Source Code Paths (relative to project root)

| Path | Contents |
|------|----------|
| `Source/LyraGame/` | Core Lyra framework extensions |
| `Plugins/GameFeatures/BASShooterCore/Source/BASShooterCoreRuntime/` | Main game module |
| `.../Public/` | Header files (.h) |
| `.../Private/` | Implementation files (.cpp) |
| `.../Public/UI/` | UI widget headers |
| `.../Public/UI/Widgets/` | Complex widget headers (subfolders) |
| `.../Public/AbilitySystem/Abilities/TotemAbilities/` | Totem ability headers |

### Content Paths

| Path | Contents |
|------|----------|
| `Content/UI/Hud/QuickBar/` | HUD widgets (W_SideBarRage, W_QuickBar, etc.) |
| `Content/UI/Hud/Materials/` | HUD material instances |
| `Content/UI/Hud/Textures/` | HUD textures |
| `Plugins/.../Content/GameplayAbilities/` | GA_Rage and other ability Blueprints |
| `Plugins/.../Content/GameplayEffects/` | GE_Rage, GE_Rage_Explosion, etc. |
| `Plugins/.../Content/Totems/` | Totem item definitions (ID_Rage, etc.) |

---

## Content Directory Permissions

Before Editor work, ensure Content dirs are writable:

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'icacls C:\A\ApeShooter\NewApeShooter\Content /grant Users:(OI)(CI)M /T >nul 2>&1'"
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'icacls C:\A\ApeShooter\NewApeShooter\Plugins\GameFeatures\BASShooterCore\Content /grant Users:(OI)(CI)M /T >nul 2>&1'"
```

---

## Module Dependencies (BASShooterCoreRuntime)

Already available (no need to add to .Build.cs):

| Module | Provides |
|--------|----------|
| `UMG` | UUserWidget, UWidgetAnimation, UImage |
| `GameplayAbilities` | UGameplayAbility, UGameplayEffect, UAbilitySystemComponent |
| `GameplayTags` | FGameplayTag |
| `Niagara` | UNiagaraSystem, UNiagaraComponent |
| `CommonUI` | UCommonTextBlock, UCommonButtonBase |
| `EnhancedInput` | UInputAction |
| `Slate` / `SlateCore` | Low-level UI |

---

## Reading Files from VM via SSH

```bash
# Read a specific file
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'type C:\A\ApeShooter\NewApeShooter\path\to\file.h'"

# List directory contents
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'dir /b C:\A\ApeShooter\NewApeShooter\path\to\dir\'"

# Recursive list
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'dir /s /b C:\A\ApeShooter\NewApeShooter\path\to\dir\'"

# Git operations
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c 'cd /d C:\A\ApeShooter\NewApeShooter && git log --oneline -10'"
```

**Important**: Use `cmd /c` for commands, not PowerShell directly (avoids `&&` parsing issues).

---

## Troubleshooting

### SSH Timeout
The VM may be stopped. Check GCP console or start it:
```bash
gcloud compute instances start arcas-build-server-gpu --zone=europe-west6-b
```

### Compile Fails - Missing Include
Check the module's `Public/` directory structure. Headers must match the `#include` path:
- `#include "UI/SideBarAbilityWidget.h"` → file at `Public/UI/SideBarAbilityWidget.h`

### Editor Crashes on Startup
- ResonanceAudio plugin was disabled to fix this (2026-02-08)
- If it happens again, check `Plugins/` for problematic plugins

### Build Script Fails
Check status and logs:
```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 "cmd /c 'type C:\A\status.txt'"
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "powershell -Command \"Get-Content 'C:\A\Logs\build-*.log' -Tail 50 | Select-Object -Last 50\""
```
