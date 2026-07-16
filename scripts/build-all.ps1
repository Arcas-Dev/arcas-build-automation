# ============================================
# Arcas Champions - Unified Build Pipeline
# ============================================
#
# Builds BOTH client (Win64) and server (Linux), deploys to Steam and Edgegap.
#
# Pipeline order (optimized for parallelism):
#   1. Git pull
#   2. Linux server build (~10 min incremental, ~45 min full)
#   3. Cloud Build submit (background) + Win64 client build (parallel)
#   4. PATCH Edgegap docker_tag + Steam upload (parallel-ish)
#
# Trigger command (run via SSH):
#   Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList 'cmd /c C:\A\Scripts\build-all.bat'
#
# Monitor:
#   type C:\A\status.txt
#   Get-Content C:\A\Logs\build-all-*.log -Tail 30
#

$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$dockerTag = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$logFile = "C:\A\Logs\build-all-$timestamp.log"
$statusFile = "C:\A\status.txt"

# ============================================
# CONFIGURATION
# ============================================
$UE5Path = "C:\UE5.5"
$RepoPath = "C:\A\ApeShooter"
$ProjectPath = "C:\A\ApeShooter\NewApeShooter\NewApeShooter.uproject"
$GitBranch = "deploy/steam-testing"

# Win64 Client
$ClientTarget = "ArcasChampionsSteam"
$ClientPlatform = "Win64"
$ClientConfig = "Shipping"
$ClientBuildDir = "C:\A\Builds\ArcasChampionsSteam"
$SteamVDF = "C:\SteamCMD\app_build_3487030.vdf"
$SteamUser = "dandadevarcas"

# Linux Server
$ServerTarget = "ArcasChampionsServer"
$ServerPlatform = "Linux"
$ServerConfig = "Development"
$ServerBuildDir = "C:\A\Builds\LinuxServer"

# Edgegap
$EdgegapToken = "2dd0f063-c76d-4e30-af80-942dbc8fe75c"
$EdgegapApp = "arcas-champions"
$EdgegapVersion = "testing-server"

# Cloud Build
$CloudBuildConfig = "C:\A\Builds\LinuxServer\cloudbuild.yaml"
$GCPProject = "arcas-champions"
$GCPRegion = "europe-west6"
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
    $content = "$status`nLog: $logFile`nStarted: $timestamp`nDocker tag: $dockerTag"
    Set-Content -Path $statusFile -Value $content
}

$pipelineStart = Get-Date

Log '=========================================='
Log 'ARCAS CHAMPIONS - UNIFIED BUILD PIPELINE'
Log '=========================================='
Log "Timestamp: $timestamp"
Log "Docker tag: $dockerTag"
Log "Log file: $logFile"
Log ''

# ============================================
# PHASE 1: GIT PULL
# ============================================

UpdateStatus 'PULLING'
Log '=========================================='
Log 'PHASE 1: GIT PULL'
Log '=========================================='

Push-Location $RepoPath

Log 'Fetching from origin...'
$fetchOutput = & git fetch origin 2>&1
$fetchOutput | ForEach-Object { Log $_ }

Log "Checking out $GitBranch..."
$checkoutOutput = & git checkout $GitBranch 2>&1
$checkoutOutput | ForEach-Object { Log $_ }

Log 'Pulling latest changes...'
$pullOutput = & git pull origin $GitBranch 2>&1
$pullExitCode = $LASTEXITCODE
$pullOutput | ForEach-Object { Log $_ }

if ($pullExitCode -ne 0) {
    UpdateStatus 'PULL_FAILED'
    Log 'GIT PULL FAILED!'
    Pop-Location
    exit 1
}

$commitHash = & git rev-parse --short HEAD
$commitMsg = & git log -1 --pretty=%s
Log "Current commit: $commitHash - $commitMsg"
Log ''

Pop-Location

# ============================================
# PHASE 2: LINUX SERVER BUILD
# ============================================

UpdateStatus 'BUILDING_SERVER'
Log '=========================================='
Log 'PHASE 2: LINUX SERVER BUILD'
Log '=========================================='
Log "Target: $ServerTarget"
Log "Platform: $ServerPlatform"
Log "Config: $ServerConfig"
Log ''

$serverStart = Get-Date

$buildCmd = "$UE5Path\Engine\Build\BatchFiles\RunUAT.bat"
$serverArgs = "BuildCookRun -project=`"$ProjectPath`" -noP4 -platform=$ServerPlatform -server -noclient -serverconfig=$ServerConfig -cook -build -stage -pak -archive -archivedirectory=`"$ServerBuildDir`" -target=$ServerTarget -utf8output -unattended"

Log "Starting Linux server BuildCookRun..."
$serverOutput = & cmd /c "`"$buildCmd`" $serverArgs 2>&1"
$serverExitCode = $LASTEXITCODE

$serverOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

$serverEnd = Get-Date
$serverDuration = $serverEnd - $serverStart

Log ''
Log "Linux server build: $($serverDuration.Hours)h $($serverDuration.Minutes)m $($serverDuration.Seconds)s"
Log "Exit code: $serverExitCode"

if ($serverExitCode -ne 0) {
    UpdateStatus 'SERVER_BUILD_FAILED'
    Log 'LINUX SERVER BUILD FAILED!'
    exit 1
}

Log 'Linux server build SUCCESS'
Log ''

# ============================================
# PHASE 3: CLOUD BUILD (background) + WIN64 BUILD (foreground)
# ============================================

UpdateStatus 'BUILDING_CLIENT_AND_UPLOADING_SERVER'
Log '=========================================='
Log 'PHASE 3: CLOUD BUILD + WIN64 BUILD (PARALLEL)'
Log '=========================================='

# --- Start Cloud Build in background ---
Log "Starting Cloud Build in background (tag: $dockerTag)..."
$cloudBuildLog = "C:\A\Logs\cloud-build-$timestamp.log"
$cloudBuildErrLog = "C:\A\Logs\cloud-build-$timestamp-err.log"

$gcloudCmd = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
$cloudBuildProcess = Start-Process -FilePath $gcloudCmd `
    -ArgumentList "builds submit `"$ServerBuildDir`" --config=`"$CloudBuildConfig`" --substitutions=_TAG=$dockerTag --project=$GCPProject --region=$GCPRegion" `
    -RedirectStandardOutput $cloudBuildLog `
    -RedirectStandardError $cloudBuildErrLog `
    -NoNewWindow -PassThru

Log "Cloud Build PID: $($cloudBuildProcess.Id)"
Log ''

# --- Win64 Client Build (foreground) ---
Log 'Starting Win64 client BuildCookRun...'
$clientStart = Get-Date

$clientArgs = "BuildCookRun -project=`"$ProjectPath`" -target=$ClientTarget -platform=$ClientPlatform -clientconfig=$ClientConfig -build -cook -stage -pak -archive -archivedirectory=`"$ClientBuildDir`""

$clientOutput = & cmd /c "`"$buildCmd`" $clientArgs 2>&1"
$clientExitCode = $LASTEXITCODE

$clientOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

$clientEnd = Get-Date
$clientDuration = $clientEnd - $clientStart

Log ''
Log "Win64 client build: $($clientDuration.Hours)h $($clientDuration.Minutes)m $($clientDuration.Seconds)s"
Log "Exit code: $clientExitCode"

if ($clientExitCode -ne 0) {
    UpdateStatus 'CLIENT_BUILD_FAILED'
    Log 'WIN64 CLIENT BUILD FAILED!'
    Log 'Waiting for Cloud Build to finish before exiting...'
    $cloudBuildProcess | Wait-Process -Timeout 900
    exit 1
}

Log 'Win64 client build SUCCESS'
Log ''

# ============================================
# PHASE 4: STEAM UPLOAD + WAIT FOR CLOUD BUILD + PATCH EDGEGAP
# ============================================

UpdateStatus 'DEPLOYING'
Log '=========================================='
Log 'PHASE 4: STEAM UPLOAD + EDGEGAP PATCH'
Log '=========================================='

# --- Steam Upload ---
Log 'Uploading to Steam Demo (3487030) testing branch...'
$steamOutput = & C:\SteamCMD\steamcmd.exe +login $SteamUser +run_app_build $SteamVDF +quit 2>&1
$steamExitCode = $LASTEXITCODE
$steamOutput | ForEach-Object { Add-Content -Path $logFile -Value $_ }

if ($steamExitCode -ne 0) {
    Log "WARNING: Steam upload failed (exit code: $steamExitCode)"
    Log 'Continuing with Edgegap...'
} else {
    Log 'Steam upload SUCCESS'
}
Log ''

# --- Wait for Cloud Build ---
Log 'Waiting for Cloud Build to finish...'
$cloudBuildProcess | Wait-Process -Timeout 900

# Refresh the process object to ensure ExitCode is populated
$cloudBuildProcess.Refresh()
$cbExitCode = $cloudBuildProcess.ExitCode

Log "Cloud Build process exited with code: $cbExitCode"

if ($null -eq $cbExitCode -or $cbExitCode -ne 0) {
    # Check Cloud Build status directly via gcloud as a fallback
    Log 'Checking Cloud Build status via gcloud...'
    $cbStatusOutput = & $gcloudCmd builds list --project=$GCPProject --region=$GCPRegion --limit=1 --sort-by="~createTime" --format="value(status)" 2>&1
    $cbStatus = ($cbStatusOutput | Select-Object -First 1).Trim()
    Log "Cloud Build API status: $cbStatus"

    if ($cbStatus -eq 'SUCCESS') {
        Log 'Cloud Build confirmed SUCCESS via API (process exit code was unreliable)'
    } else {
        UpdateStatus 'CLOUD_BUILD_FAILED'
        Log "Cloud Build FAILED (exit code: $cbExitCode, API status: $cbStatus)"
        Log 'Check cloud build log:'
        Log "  $cloudBuildLog"
        Log "  $cloudBuildErrLog"

        # Show last 20 lines of cloud build error log
        if (Test-Path $cloudBuildErrLog) {
            $errTail = Get-Content $cloudBuildErrLog -Tail 20
            $errTail | ForEach-Object { Log "  CB_ERR: $_" }
        }
        exit 1
    }
}

Log "Cloud Build SUCCESS (tag: $dockerTag)"
Log ''

# --- PATCH Edgegap docker_tag ---
Log "PATCHing Edgegap version '$EdgegapVersion' with docker_tag '$dockerTag'..."

try {
    $headers = @{
        "Authorization" = "token $EdgegapToken"
        "Content-Type" = "application/json"
    }
    $body = @{ docker_tag = $dockerTag } | ConvertTo-Json

    $response = Invoke-RestMethod `
        -Uri "https://api.edgegap.com/v1/app/$EdgegapApp/version/$EdgegapVersion" `
        -Method Patch `
        -Headers $headers `
        -Body $body

    Log "Edgegap PATCH returned OK - verifying the tag actually applied..."

    # A 200 is NOT proof the tag changed. Read it back. (2026-07-08: a PATCH was
    # rejected for over-quota req_cpu/req_memory while the pipeline still reported
    # COMPLETE, leaving a 5-month-old server image live against a fresh client.)
    #
    # But Edgegap revalidates the whole version object asynchronously, so an immediate
    # GET can return an empty/stale docker_tag for a second or two. (2026-07-15: a
    # fully-good deploy false-failed here because the read-back ran ~1s after PATCH and
    # saw ''.) Poll with a short delay before declaring failure - this keeps the
    # real-failure protection while tolerating the revalidation window.
    $liveTag = ''
    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Start-Sleep -Seconds 3
        $applied = Invoke-RestMethod `
            -Uri "https://api.edgegap.com/v1/app/$EdgegapApp/version/$EdgegapVersion" `
            -Method Get `
            -Headers $headers
        $liveTag = $applied.version.docker_tag
        if ($liveTag -eq $dockerTag) { break }
        Log "  verify attempt $attempt/$maxAttempts - Edgegap reports docker_tag '$liveTag', waiting..."
    }

    if ($liveTag -ne $dockerTag) {
        throw "Edgegap still reports docker_tag '$liveTag', expected '$dockerTag' after $maxAttempts attempts"
    }

    Log "Edgegap PATCH SUCCESS (verified)"
    Log "Version '$EdgegapVersion' now points to docker_tag '$dockerTag'"
} catch {
    Log "ERROR: Edgegap PATCH failed: $_"
    Log ""
    Log "The Steam client was uploaded but the dedicated server image was NOT updated."
    Log "Do NOT test multiplayer until this is resolved - the client and server will mismatch."
    Log ""
    Log "Common cause: Edgegap revalidates the WHOLE version object on any PATCH, so an"
    Log "over-quota req_cpu / req_memory rejects the request even though only docker_tag"
    Log "was sent. Check the account limits, then retry including the resource fields:"
    Log "  curl -X PATCH -H 'Authorization: token $EdgegapToken' -H 'Content-Type: application/json' https://api.edgegap.com/v1/app/$EdgegapApp/version/$EdgegapVersion -d '{`"docker_tag`":`"$dockerTag`",`"req_cpu`":1536,`"req_memory`":3072}'"
    UpdateStatus "EDGEGAP_PATCH_FAILED:$dockerTag"
    exit 1
}
Log ''

# ============================================
# COMPLETE
# ============================================

$pipelineEnd = Get-Date
$totalDuration = $pipelineEnd - $pipelineStart

UpdateStatus "COMPLETE:$dockerTag"

Log '=========================================='
Log 'UNIFIED BUILD PIPELINE COMPLETE!'
Log '=========================================='
Log ''
Log "Total time: $($totalDuration.Hours)h $($totalDuration.Minutes)m $($totalDuration.Seconds)s"
Log "Git commit: $commitHash - $commitMsg"
Log "Docker tag: $dockerTag"
Log ''
Log 'Deployments:'
Log "  Steam: Demo (3487030) testing branch (pw: PrimeTester262)"
Log "  Edgegap: $EdgegapApp/$EdgegapVersion -> $dockerTag"
Log ''
Log 'Next matchmaker deployment will use the new server image automatically.'
