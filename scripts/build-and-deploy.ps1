# ============================================
# Arcas Champions - Build and Deploy Script
# ============================================
#
# This script builds the game and uploads to Steam.
# It runs as a background process and updates status.txt for monitoring.
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
$ProjectPath = "C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject"
$TargetName = "ArcasChampionsSteam"
$Platform = "Win64"
$Config = "Shipping"
$BuildDir = "C:\A\Builds\ArcasChampionsSteam"
$SteamVDF = "C:\SteamCMD\app_build_3487030.vdf"
$SteamUser = "dandadevarcas"
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
# BUILD PHASE
# ============================================

UpdateStatus 'BUILDING'
Log '=========================================='
Log 'ARCAS CHAMPIONS BUILD AND DEPLOY'
Log '=========================================='
Log "Timestamp: $timestamp"
Log "Log file: $logFile"
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

Log "Command: $buildCmd $buildArgs"
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
Log ''
Log 'Build is now live on Steam Demo (3487030) testing branch'
Log 'Branch password: PrimeTester262'
Log ''
Log 'Open Steam > Arcas Champions Demo > Properties > Betas > Enter code > Select testing'
