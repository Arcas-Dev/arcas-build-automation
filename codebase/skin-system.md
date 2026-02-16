# Arcas Champions - Skin System Analysis

**Date**: 2026-02-02
**Purpose**: Document current skin system architecture for future reference

---

## Current Architecture

### Database (PostgreSQL via Cloud SQL)

**Table**: `Champions`

| Column | Type | Description |
|--------|------|-------------|
| ChampID | SERIAL | Primary key |
| PlayerOwner | INT | FK to PlayerProfile |
| **Gender** | INTEGER | 0 = Female, 1 = Male |
| **SkinTeam** | INTEGER | 0 = Elite, 1 = Renegade |
| Health | INTEGER | 4-12 |
| Strength | INTEGER | 4-12 |
| Intelligence | INTEGER | 4-12 |
| Agility | INTEGER | 4-12 |
| Luck | INTEGER | 4-12 |
| ChampionInitialised | BOOLEAN | |
| ChampionUnpacked | BOOLEAN | |

**Current mapping (4 combinations)**:
- Gender=1, SkinTeam=0 → MaleApe Elite
- Gender=0, SkinTeam=0 → FemaleApe Elite
- Gender=1, SkinTeam=1 → MaleApe Renegade
- Gender=0, SkinTeam=1 → FemaleApe Renegade

---

### API (server.js on SteamNextFest branch)

**Location**: `repos/ArcasChampionsAPI/server.js`

**Champion Creation** (~line 306-340):
```javascript
const championQuery = `
  INSERT INTO Champions (
    PlayerOwner, Gender, SkinTeam, Health, Strength, Intelligence, Agility, Luck, ChampionInitialised
  ) VALUES (...)`;

await pool.query(championQuery, [
  hash,
  generateBinary(), // Gender: 0 or 1
  generateBinary(), // SkinTeam: 0 or 1
  generateStat(),   // Health: 4-12
  ...
]);
```

**Endpoints returning skin data**:
| Endpoint | Line | Returns |
|----------|------|---------|
| GET_Vault | ~481 | Champions with Gender, SkinTeam |
| GET_LoadoutByIndex | ~699 | Champion details |
| GET_Loadouts | ~564 | All loadouts with champions |
| GET_UnpackedChampions | ~799 | Champions pending name |
| GET_PlayerLoadouts | ~1457 | Server-side for matchmaker |
| POST_ValidatePlayerLoadout | ~1596 | Validation |

---

### UE5 (Game Client)

**FChampion Struct**:
`Plugins/BlockApeScissors/Source/BlockApeScissors/Public/Network/DAO/LoadoutDAO.h`

```cpp
USTRUCT(BlueprintType)
struct BLOCKAPESCISSORS_API FChampion
{
  GENERATED_BODY()

  UPROPERTY(EditAnywhere, BlueprintReadWrite)
  int32 ChampId;

  UPROPERTY(EditAnywhere, BlueprintReadWrite)
  FString Name;

  UPROPERTY(EditAnywhere, BlueprintReadWrite)
  uint8 Gender;

  UPROPERTY(EditAnywhere, BlueprintReadWrite)
  uint8 SkinTeam;

  UPROPERTY(EditAnywhere, BlueprintReadWrite)
  FChampionStats Stats;
};
```

**Avatar Display** (`ChampionAvatar.cpp`):
```cpp
// Uses DataTable to map Gender + SkinTeam to icon
FSoftObjectPath Path = Rows[TeamID]->IconFromGender[Champion.Gender].Icons.FindRef(HigherStat.Value).ToSoftObjectPath();
```

---

## UE5 Skin Assets

### Directory Structure

```
Content/Characters/
├── ApeChampion/
│   ├── Animations/MaleApe/
│   │   ├── Pistol/
│   │   ├── Rifle/
│   │   ├── GrenadeLauncher/
│   │   └── [11 weapon categories]
│   ├── Cosmetics/
│   │   ├── Menu/           # Menu display versions
│   │   │   ├── B_MaleApe_Elite_Menu.uasset
│   │   │   └── ...
│   │   └── Player/         # In-game player skins
│   │       ├── B_MaleApe_Base.uasset
│   │       ├── B_MaleApe_Elite.uasset
│   │       ├── B_MaleApe_Renegade.uasset
│   │       ├── B_FemaleApe_Elite.uasset
│   │       ├── B_FemaleApe_Renegade.uasset
│   │       ├── B_Bonzette.uasset          ← READY
│   │       └── B_SargerSkullfist.uasset   ← READY
│   └── Skins/
│       └── Custom/
│           ├── Bonzette/
│           │   ├── Materials/MI_Bonzette.uasset
│           │   ├── Mesh/SKM_Bonzette.uasset
│           │   └── Texture/TEX_Bonzette_*.uasset
│           └── SargerSkullfist/
│               ├── Materials/...
│               ├── Mesh/SKM_SargerSkullfist.uasset
│               └── Texture/...
├── DefaultSkins/
│   ├── Elites/
│   │   ├── SKM_MaleApe_Elite_03.uasset
│   │   └── SKM_FemaleApe_Elite_02.uasset
│   └── Renegades/
│       ├── MaleApe/SKM_MaleApe_Renegade.uasset
│       └── FemaleApe/SKM_FemaleApe_Renegade.uasset
├── MaleApe/         # Base male ape
└── FemaleApe/       # Base female ape
```

### Skin Blueprint Paths

| Skin | Blueprint Path |
|------|----------------|
| MaleApe Elite | `/Game/Characters/ApeChampion/Cosmetics/Player/B_MaleApe_Elite` |
| FemaleApe Elite | `/Game/Characters/ApeChampion/Cosmetics/Player/B_FemaleApe_Elite` |
| MaleApe Renegade | `/Game/Characters/ApeChampion/Cosmetics/Player/B_MaleApe_Renegade` |
| FemaleApe Renegade | `/Game/Characters/ApeChampion/Cosmetics/Player/B_FemaleApe_Renegade` |
| Bonzette | `/Game/Characters/ApeChampion/Cosmetics/Player/B_Bonzette` |
| Skullfist | `/Game/Characters/ApeChampion/Cosmetics/Player/B_SargerSkullfist` |

---

## DataTables

| DataTable | Location | Purpose |
|-----------|----------|---------|
| DT_AvatarGraphic | `Content/UI/Menu/Barracks/` | Maps to avatar icons |
| DT_AvatarGraphicVault | `Content/UI/Menu/Barracks/` | Vault display icons |
| DT_FullAvatarGraphic | `Content/UI/Menu/Barracks/` | Full character images |
| DT_AllVaultItems | `Content/UI/Menu/Barracks/` | All vault items |

---

## Key Source Files

### API
- `repos/ArcasChampionsAPI/server.js` - All endpoints

### UE5 C++
| File | Purpose |
|------|---------|
| `Plugins/BlockApeScissors/.../LoadoutDAO.h` | FChampion struct definition |
| `Source/LyraGame/UI/Common/ChampionAvatar.cpp` | Avatar icon display |
| `Source/LyraGame/UI/ChampionCard/ChampionCard.cpp` | Champion card UI |
| `Source/LyraGame/Player/BASPlayerInfo.h` | Player info with FChampion |
| `Source/LyraGame/Components/PlayerInfoComponent/` | Player info handling |
| `Source/LyraGame/Cosmetics/` | Cosmetics system |

### UE5 Content
| Asset | Purpose |
|-------|---------|
| `Content/Characters/ApeChampion/Cosmetics/Player/` | Skin Blueprints |
| `Content/Characters/ApeChampion/Skins/Custom/` | Custom skin meshes |
| `Content/UI/Menu/Barracks/DT_AvatarGraphic.uasset` | Skin icon mapping |

---

## Proposed SkinID System

### New Mapping (1-indexed)

| SkinID | Skin | Current Gender | Current SkinTeam |
|--------|------|----------------|------------------|
| 1 | MaleApe Elite | 1 | 0 |
| 2 | FemaleApe Elite | 0 | 0 |
| 3 | MaleApe Renegade | 1 | 1 |
| 4 | FemaleApe Renegade | 0 | 1 |
| 5 | Skullfist | - | - |
| 6 | Bonzette | - | - |

### Migration SQL
```sql
ALTER TABLE Champions ADD COLUMN SkinID INTEGER DEFAULT 1;

UPDATE Champions SET SkinID =
  CASE
    WHEN Gender=1 AND SkinTeam=0 THEN 1
    WHEN Gender=0 AND SkinTeam=0 THEN 2
    WHEN Gender=1 AND SkinTeam=1 THEN 3
    WHEN Gender=0 AND SkinTeam=1 THEN 4
    ELSE 1
  END;
```

---

## VM Access

```bash
# SSH to Windows build server
ssh -i ~/.ssh/arcas_build_key daniel@34.158.27.129

# PowerShell commands
powershell -Command "Get-ChildItem 'C:\A\ApeShooter\NewApeShooter\Content\Characters' -Directory"
```

---

## Notes

- **Bonzette and Skullfist are fully ready** - Have Blueprints in Cosmetics/Player/, full mesh/material/texture sets
- **Animations are weapon-based**, not skin-based - New skins reuse existing animation sets
- **DataTables need updating** for new skins (avatar icons, etc.)
- **No source FBX in repo** - All assets are UE5 .uasset format only
