# GCloud VM - Unreal Engine Code Change Workflow

**VM**: `arcas-build-server-gpu` (34.65.146.42)
**Project**: `C:\A\ApeShooter\NewApeShooter\`
**Engine**: UE5.5 source build at `C:\UE5.5\`

---

## What Claude Can Change (via SSH)

These are text-based files that can be edited remotely without the UE5 Editor.

### C++ Source Files (.h, .cpp)

| What | Location | Example |
|------|----------|---------|
| **Headers** | `Source/` and `Plugins/.../Source/.../Public/` | `RageTotemGameplayAbility.h` |
| **Implementations** | `Source/` and `Plugins/.../Source/.../Private/` | `RageTotemGameplayAbility.cpp` |
| **Build configs** | `Source/*.Target.cs`, `Source/*.Build.cs` | `ArcasChampionsSteam.Target.cs` |
| **Module definitions** | `Source/*Module.h/cpp` | Module registration |

**Key patterns:**
- Add `UFUNCTION(BlueprintCallable)` to expose C++ functions to Blueprints
- Add `UPROPERTY(EditDefaultsOnly)` to expose variables to the Blueprint Details panel
- Modify game logic, backend subsystems, networking code
- Add new classes, structs, enums

### Config Files (.ini)

| What | Location | Example |
|------|----------|---------|
| **Engine config** | `Config/DefaultEngine.ini` | Rendering settings, plugins |
| **Game config** | `Config/DefaultGame.ini` | Project settings |
| **Input config** | `Config/DefaultInput.ini` | Key bindings |
| **Custom config** | `Config/Default*.ini` | Any custom config |

### Plugin Configs (.uplugin)

| What | Location | Example |
|------|----------|---------|
| **Plugin descriptors** | `Plugins/*/*.uplugin` | Enable/disable plugins |
| **Plugin build files** | `Plugins/*/*.Build.cs` | Dependencies |

### Data Files

| What | Location | Example |
|------|----------|---------|
| **JSON data** | Various | Localization, data tables (if JSON) |
| **Shader files** | `Shaders/` | `.usf`, `.ush` custom shaders |
| **Build scripts** | `C:\A\Scripts\` | `build.bat`, PowerShell scripts |

---

## What Requires the Editor (via RDP)

These are binary `.uasset` files that can ONLY be edited in the UE5 Editor. Claude cannot read or modify them.

### Blueprint Assets (.uasset)

| What | Example | Description |
|------|---------|-------------|
| **Gameplay Abilities** | `GA_Rage.uasset` | Visual scripting logic, event graphs |
| **Gameplay Effects** | `GE_Rage.uasset` | Buff/debuff configurations |
| **Widget Blueprints** | `W_SideBarRage.uasset` | UI layout, widget trees, bindings |
| **Actor Blueprints** | Any BP_ prefixed | Placed actors, components |
| **Animation Blueprints** | `ABP_*.uasset` | Animation state machines |
| **Animation Montages** | `AM_*.uasset` | Animation sequences |
| **Data Tables** | `DT_*.uasset` | Structured data (rows/columns) |
| **Gameplay Cues** | `GCNL_*.uasset` | VFX/SFX triggers |

### Content Assets (.uasset)

| What | Example | Description |
|------|---------|-------------|
| **Materials** | `M_*.uasset`, `MI_*.uasset` | Shaders, material instances |
| **Textures** | `T_*.uasset` | Images, icons |
| **Static Meshes** | `SM_*.uasset` | 3D models |
| **Skeletal Meshes** | `SK_*.uasset` | Rigged characters/weapons |
| **Niagara VFX** | `NS_*.uasset` | Particle systems |
| **Sound** | `*.uasset` in Audio/ | Sound cues, waves |
| **Maps/Levels** | `*.umap` | Level layouts |

---

## Code Change Workflow

### Step 1: Edit C++ Files (Claude via SSH)

```bash
# Option A: Write a PowerShell edit script locally, SCP it over, execute
scp -i ~/.ssh/arcas_build_key /tmp/edit-script.ps1 daniel@34.65.146.42:C:/A/Scripts/edit-script.ps1
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 "powershell -ExecutionPolicy Bypass -File C:\A\Scripts\edit-script.ps1"

# Option B: Simple file reads/checks
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 "cmd /c type C:\path\to\file.h"
```

**Why PowerShell scripts?** SSH + PowerShell quoting is extremely fragile. Multi-line strings, quotes inside quotes, and special characters break constantly. Writing a `.ps1` file and SCP-ing it to the VM avoids all quoting issues.

### Step 2: Compile Editor Target (Claude via SSH)

Required after ANY C++ change. This makes the changes visible in the UE5 Editor.

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 \
  "cmd /c \"C:\UE5.5\Engine\Build\BatchFiles\Build.bat\" LyraEditor Win64 Development -Project=\"C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject\" -WaitMutex"
```

- **Incremental build**: ~1-2 min (only recompiles changed files)
- **Full rebuild**: ~15-30 min (if header changes cascade)
- **Target name**: `LyraEditor` (found in `Source/LyraEditor.Target.cs`)

### Step 3: Blueprint Changes (User via RDP)

Open the Editor, make Blueprint changes, save.

```
# Launch Editor (or use desktop shortcut)
"C:\UE5.5\Engine\Binaries\Win64\UnrealEditor.exe" "C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject"
```

**Important**: The Editor must be CLOSED during Step 2 (compile). The Editor locks the DLLs.

### Step 4: Compile Shipping Target (Claude via SSH)

Build the packaged game for Steam deployment.

```bash
ssh -i ~/.ssh/arcas_build_key daniel@34.65.146.42 "cmd /c C:\A\Scripts\build.bat"
```

This runs: git pull → BuildCookRun (Shipping) → Steam upload → Demo testing branch.

### Step 5: Test on Steam

Download from Steam Demo app (3487030), testing branch, password `PrimeTester262`.

---

## Build Targets Reference

| Target | Command | Purpose | When |
|--------|---------|---------|------|
| **LyraEditor** | `Build.bat LyraEditor Win64 Development` | Editor binaries | After C++ changes, before Editor use |
| **ArcasChampionsSteam** | `build.bat` (full script) | Packaged game | Before Steam upload |
| **ArcasChampionsServer** | N/A | Dedicated server | For Edgegap (future) |

---

## Typical Workflow Examples

### Example 1: C++ Only Change (e.g., expose function to Blueprint)

```
1. Claude edits .h/.cpp via SSH (PowerShell script)
2. Claude compiles LyraEditor target (~1 min)
3. User opens Editor → new functions visible in Blueprint
4. User wires Blueprint, saves
5. Claude runs build.bat → Steam upload
```

### Example 2: Config Change (e.g., disable a plugin)

```
1. Claude edits .ini or .uplugin via SSH
2. Claude compiles LyraEditor target (may be needed)
3. User opens Editor → verifies change
4. Claude runs build.bat → Steam upload
```

### Example 3: Blueprint Only Change (e.g., adjust timer value)

```
1. User opens Editor via RDP
2. User makes changes in Blueprint, saves
3. User closes Editor
4. Claude runs build.bat → Steam upload
```

### Example 4: Mixed C++ + Blueprint Change (current rage widget work)

```
1. Claude edits C++ to add new functions/properties
2. Claude compiles LyraEditor target
3. User opens Editor, wires Blueprint to use new C++ functions
4. User saves, closes Editor
5. Claude runs build.bat → Steam upload
6. Test on Steam
```

---

## Key Learnings

### SSH + PowerShell Quoting

**NEVER** try to pass complex PowerShell commands directly through SSH. The quoting layers (bash → SSH → PowerShell) make it nearly impossible to get right with multi-line strings, quotes, or special characters.

**Always** use the SCP approach:
1. Write a `.ps1` script locally (`/tmp/scriptname.ps1`)
2. SCP to VM: `scp -i key script.ps1 daniel@34.65.146.42:C:/A/Scripts/`
3. Execute: `ssh ... "powershell -ExecutionPolicy Bypass -File C:\A\Scripts\script.ps1"`

### SSH Cannot Launch GUI Apps

Processes launched via SSH run in Session 0 (service session), not the interactive RDP desktop. GUI apps like UnrealEditor won't appear on the user's RDP screen. The user must launch the Editor from the RDP session directly (desktop shortcut or Command Prompt).

### Editor Must Be Closed During C++ Compile

The Editor locks `.dll` files while running. If you try to compile the Editor target while the Editor is open, the linker will fail because it can't overwrite the locked DLLs. Always close the Editor before compiling.

### Live Coding (Ctrl+Alt+F11) Doesn't Work Over Mac RDP

The Mac intercepts function key shortcuts before they reach the remote Windows session. If Live Coding is needed, use the UE5 Editor menu (Tools > Live Coding) or compile from command line with the Editor closed.

### UHT (UnrealHeaderTool) Regeneration

When you add/remove/change `UFUNCTION`, `UPROPERTY`, or `UCLASS` macros in headers, UHT must regenerate reflection code. This happens automatically during the build but adds ~30s to compile time. Changes to `.cpp` files only (no header changes) skip UHT and compile faster.

### Binary Assets Cannot Be Merged

`.uasset` files are binary. If two people edit the same Blueprint, there's no text merge - one version wins. This is why C++ is preferred for game logic when possible, and Blueprints are used for configuration and wiring.

---

## File Locations Quick Reference

| Category | Path on VM |
|----------|------------|
| **Game Source** | `C:\A\ApeShooter\NewApeShooter\Source\` |
| **Plugin Source** | `C:\A\ApeShooter\NewApeShooter\Plugins\GameFeatures\BASShooterCore\Source\` |
| **Content** | `C:\A\ApeShooter\NewApeShooter\Content\` |
| **Plugin Content** | `C:\A\ApeShooter\NewApeShooter\Plugins\GameFeatures\BASShooterCore\Content\` |
| **Config** | `C:\A\ApeShooter\NewApeShooter\Config\` |
| **Build Scripts** | `C:\A\Scripts\` |
| **Engine** | `C:\UE5.5\` |
| **Build Output** | `C:\A\Builds\ArcasChampionsSteam\` |
