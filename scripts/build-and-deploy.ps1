# ============================================
# Arcas Champions - Build and Deploy Script
# ============================================
#
# This script:
#   1. Pulls latest code from deploy/steam-testing branch
#   2. Builds the game (BuildCookRun)
#   3. Uploads to Steam Demo testing branch
#
# Trigger command (run via SSH):
#   Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\A\Scripts\build.bat'
#
# Monitor:
#   type C:\A\status.txt
#   Get-Content C:\A\Logs\build-*.log -Tail 30
#

$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logFile = "C:\A\Logs\build-$timestamp.log"
$statusFile = "C:\A\status.txt"

# ============================================
# CONFIGURATION - ARCAS CHAMPIONS
# ============================================
$UE5Path = "C:\UE5.5"
$RepoPath = "C:\A\ApeShooter"
$ProjectPath = "C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject"
$TargetName = "ArcasChampionsSteam"
$Platform = "Win64"
$Config = "Shipping"
$BuildDir = "C:\A\Builds\ArcasChampionsSteam"
$SteamVDF = "C:\SteamCMD\app_build_3487030.vdf"
$SteamUser = "dandadevarcas"
$GitBranch = "deploy/steam-testing"
# ============================================

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
# GIT PULL PHASE
# ============================================

UpdateStatus 'PULLING'
Log '=========================================='
Log 'ARCAS CHAMPIONS BUILD AND DEPLOY'
Log '=========================================='
Log "Timestamp: $timestamp"
Log "Log file: $logFile"
Log ''

Log '=========================================='
Log 'PULLING LATEST CODE'
Log '=========================================='
Log ''
Log "Repository: $RepoPath"
Log "Branch: $GitBranch"
Log ''

# Change to repo directory and pull
Push-Location $RepoPath

# Fetch and checkout the branch
Log 'Fetching from origin...'
$fetchOutput = & git fetch origin 2>&1
$fetchOutput | ForEach-Object { Log $_ }

Log ''
Log "Checking out $GitBranch..."
$checkoutOutput = & git checkout $GitBranch 2>&1
$checkoutOutput | ForEach-Object { Log $_ }

Log ''
Log 'Pulling latest changes...'
$pullOutput = & git pull origin $GitBranch 2>&1
$pullExitCode = $LASTEXITCODE
$pullOutput | ForEach-Object { Log $_ }

if ($pullExitCode -ne 0) {
    UpdateStatus 'PULL_FAILED'
    Log ''
    Log 'GIT PULL FAILED!'
    Log 'Check log for errors.'
    Pop-Location
    exit 1
}

# Get current commit info
$commitHash = & git rev-parse --short HEAD
$commitMsg = & git log -1 --pretty=%s

Log ''
Log "Current commit: $commitHash"
Log "Message: $commitMsg"
Log ''

Pop-Location

# ============================================
# BUILD PHASE
# ============================================

UpdateStatus 'BUILDING'
Log '=========================================='
Log 'BUILDING GAME'
Log '=========================================='
Log ''
Log "Project: $ProjectPath"
Log "Target: $TargetName"
Log "Platform: $Platform"
Log "Config: $Config"
Log ''

Log 'Starting BuildCookRun...'
Log ''

$buildStart = Get-Date

$buildCmd = "$UE5Path\Engine\Build\BatchFiles\RunUAT.bat"
$buildArgs = "BuildCookRun -project=`"$ProjectPath`" -target=$TargetName -platform=$Platform -clientconfig=$Config -build -cook -stage -pak -archive -archivedirectory=`"$BuildDir`""

Log "Command: $buildCmd"
Log "Args: $buildArgs"
Log ''

# Run build and capture output
$buildOutput = & cmd /c "$buildCmd $buildArgs 2>&1"
$buildExitCode = $LASTEXITCODE

# Write all output to log
$buildOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

$buildEnd = Get-Date
$buildDuration = $buildEnd - $buildStart

Log ''
Log '=========================================='
Log "Build completed in $($buildDuration.Hours)h $($buildDuration.Minutes)m $($buildDuration.Seconds)s"
Log "Exit code: $buildExitCode"
Log '=========================================='

if ($buildExitCode -ne 0) {
    UpdateStatus 'BUILD_FAILED'
    Log ''
    Log 'BUILD FAILED!'
    Log 'Check log for errors.'
    exit 1
}

Log ''
Log 'Build succeeded!'
Log ''

# ============================================
# STEAM UPLOAD PHASE
# ============================================

UpdateStatus 'UPLOADING'
Log '=========================================='
Log 'UPLOADING TO STEAM'
Log '=========================================='
Log ''
Log "VDF: $SteamVDF"
Log "Account: $SteamUser"
Log ''

$steamOutput = & C:\SteamCMD\steamcmd.exe +login $SteamUser +run_app_build $SteamVDF +quit 2>&1
$steamExitCode = $LASTEXITCODE

# Write steam output to log
$steamOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

Log ''
Log "Steam upload exit code: $steamExitCode"

if ($steamExitCode -ne 0) {
    UpdateStatus 'UPLOAD_FAILED'
    Log ''
    Log 'STEAM UPLOAD FAILED!'
    Log 'Check log for errors.'
    exit 1
}

# ============================================
# COMPLETE
# ============================================

UpdateStatus 'COMPLETE'

$totalEnd = Get-Date
$totalDuration = $totalEnd - $buildStart

Log ''
Log '=========================================='
Log 'BUILD AND DEPLOY COMPLETE!'
Log '=========================================='
Log ''
Log "Total time: $($totalDuration.Hours)h $($totalDuration.Minutes)m $($totalDuration.Seconds)s"
Log "Git commit: $commitHash - $commitMsg"
Log ''
Log 'Build is now live on Steam Demo (3487030) testing branch'
Log 'Branch password: PrimeTester262'
Log ''
Log 'Open Steam > Arcas Champions Demo > Properties > Betas > Enter code > Select testing'
