# RFQ Updater Bootstrap
# ---------------------
# ONE-TIME, IT-run swap that replaces an existing install's old
# windows_updater.exe with the NEW self-update-capable build.
#
# Existing installs predate the updater "updater.zip" self-update special-case,
# so their on-disk windows_updater.exe cannot self-update. After IT runs this
# once, that machine's updater can self-update thereafter.
#
# Scope: ONLY swaps windows_updater.exe (+ its sidecars). It does NOT touch the
# application, the database, configuration, or any other service.
#
# Rollback-safe: stops RFQUpdaterService, backs the current binary up to
# .previous, copies the new binary in, then starts the service and verifies it
# reaches RUNNING. On ANY failure it restores .previous and restarts the
# service, so the machine is never left with the updater down or broken.
#
# Idempotent: if the installed binary already matches the bundled one, it logs
# "already current", ensures the service is running, and exits 0.
#
# Identity is env-var-direct (matches download_and_install.ps1 / INFA-669/670/671):
#   RFQ_UPDATER_SERVICE_NAME  (default: RFQUpdaterService)
#   RFQ_INSTALL_DIR           (used for discovery when set)

[CmdletBinding()]
param(
    # Path to the existing RFQ install dir. When omitted it is discovered from
    # RFQ_INSTALL_DIR, then the updater service's image path, then the default.
    [string]$InstallPath = "",

    # The updater Windows service name. Defaults to the env-var-direct value.
    [string]$UpdaterServiceName = "",

    # The NEW bundled windows_updater.exe to install. Defaults to the copy that
    # ships next to this script (the Inno mini-installer drops both together).
    [string]$NewUpdaterExe = "",

    # Bounded waits (seconds) for the service to reach STOPPED / RUNNING.
    [int]$StopTimeoutSeconds = 60,
    [int]$StartTimeoutSeconds = 60,

    # Log file. Defaults to a timestamped file beside this script.
    [string]$LogPath = "",

    # Skip the "press any key" pause at the end (used by silent/automated runs).
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------
$script:ScriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogPath = Join-Path $script:ScriptDir "bootstrap-updater_$stamp.log"
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
    try { Add-Content -Path $LogPath -Value $line -ErrorAction Stop } catch { }
}

# --------------------------------------------------------------------------
# Identity helpers (env-var-direct, matching download_and_install.ps1)
# --------------------------------------------------------------------------
function Get-RfqEnvValueOrDefault {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DefaultValue
    )
    $value = [Environment]::GetEnvironmentVariable($EnvName, "Process")
    if ($null -eq $value -or $value -eq "") { return $DefaultValue }
    return $value
}

# --------------------------------------------------------------------------
# Install-path discovery
# --------------------------------------------------------------------------
function Get-ServiceImagePath {
    param([Parameter(Mandatory)][string]$ServiceName)
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
        if ($svc -and $svc.PathName) { return $svc.PathName }
    }
    catch {
        Write-Log "Could not query image path for service '$ServiceName': $_" "WARN"
    }
    return $null
}

# Pull the first executable token out of a service PathName (which may be quoted
# and may carry arguments, e.g. '"C:\...\nssm.exe"' or '"C:\...\windows_updater.exe" --service').
function Get-FirstExeFromCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine)
    $cl = $CommandLine.Trim()
    if ($cl.StartsWith('"')) {
        $end = $cl.IndexOf('"', 1)
        if ($end -gt 0) { return $cl.Substring(1, $end - 1) }
    }
    return ($cl -split '\s+')[0]
}

function Resolve-RfqInstallPath {
    param(
        [string]$ProvidedInstallPath,
        [Parameter(Mandatory)][string]$ServiceName
    )

    # 1) Explicit parameter wins.
    if (-not [string]::IsNullOrWhiteSpace($ProvidedInstallPath)) {
        Write-Log "Install path provided explicitly: $ProvidedInstallPath"
        return $ProvidedInstallPath
    }

    # 2) RFQ_INSTALL_DIR env var (same convention as download_and_install.ps1).
    $envDir = [Environment]::GetEnvironmentVariable("RFQ_INSTALL_DIR", "Process")
    if (-not [string]::IsNullOrWhiteSpace($envDir)) {
        Write-Log "Install path from RFQ_INSTALL_DIR: $envDir"
        return $envDir
    }

    # 3) Derive from the updater service's image path (most reliable for an
    #    existing install). Handles both direct and NSSM-wrapped services.
    $imagePath = Get-ServiceImagePath -ServiceName $ServiceName
    if ($imagePath) {
        $exe = Get-FirstExeFromCommandLine -CommandLine $imagePath
        $exeName = [System.IO.Path]::GetFileName($exe)
        if ($exeName -ieq "windows_updater.exe") {
            $dir = [System.IO.Path]::GetDirectoryName($exe)
            Write-Log "Install path derived from updater image path: $dir"
            return $dir
        }
        if ($exeName -ieq "nssm.exe") {
            # NSSM wraps the real binary; its AppDirectory is the install dir.
            try {
                $appDir = (& $exe get $ServiceName AppDirectory 2>$null | Out-String).Trim()
                if (-not [string]::IsNullOrWhiteSpace($appDir) -and (Test-Path $appDir)) {
                    Write-Log "Install path derived from NSSM AppDirectory: $appDir"
                    return $appDir
                }
            }
            catch {
                Write-Log "Could not read NSSM AppDirectory for '$ServiceName': $_" "WARN"
            }
        }
    }

    # 4) Fall back to the documented default.
    $fallback = Join-Path $env:LOCALAPPDATA "RFQApplication"
    Write-Log "Install path falling back to default: $fallback" "WARN"
    return $fallback
}

# --------------------------------------------------------------------------
# Service state helpers
# --------------------------------------------------------------------------
function Get-ServiceOrNull {
    param([Parameter(Mandatory)][string]$ServiceName)
    return Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

function Wait-ForServiceState {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$DesiredState,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-ServiceOrNull -ServiceName $ServiceName
        if ($null -eq $svc) { return $false }
        if ($svc.Status -eq $DesiredState) { return $true }
        Start-Sleep -Seconds 1
    }
    $final = Get-ServiceOrNull -ServiceName $ServiceName
    return ($null -ne $final -and $final.Status -eq $DesiredState)
}

function Stop-UpdaterService {
    param([Parameter(Mandatory)][string]$ServiceName)
    $svc = Get-ServiceOrNull -ServiceName $ServiceName
    if ($null -eq $svc) {
        Write-Log "Service '$ServiceName' not found; nothing to stop." "WARN"
        return $true
    }
    if ($svc.Status -eq 'Stopped') {
        Write-Log "Service '$ServiceName' is already stopped."
        return $true
    }
    Write-Log "Stopping service '$ServiceName'..."
    try { Stop-Service -Name $ServiceName -Force -ErrorAction Stop }
    catch { Write-Log "Stop-Service raised: $_ (will still wait for STOPPED)" "WARN" }

    if (Wait-ForServiceState -ServiceName $ServiceName -DesiredState 'Stopped' -TimeoutSeconds $StopTimeoutSeconds) {
        Write-Log "Service '$ServiceName' reached STOPPED." "SUCCESS"
        return $true
    }
    Write-Log "Service '$ServiceName' did not reach STOPPED within $StopTimeoutSeconds s." "ERROR"
    return $false
}

function Start-UpdaterService {
    param([Parameter(Mandatory)][string]$ServiceName)
    Write-Log "Starting service '$ServiceName'..."
    try { Start-Service -Name $ServiceName -ErrorAction Stop }
    catch { Write-Log "Start-Service raised: $_ (will still wait for RUNNING)" "WARN" }

    if (Wait-ForServiceState -ServiceName $ServiceName -DesiredState 'Running' -TimeoutSeconds $StartTimeoutSeconds) {
        Write-Log "Service '$ServiceName' reached RUNNING." "SUCCESS"
        return $true
    }
    Write-Log "Service '$ServiceName' did not reach RUNNING within $StartTimeoutSeconds s." "ERROR"
    return $false
}

# --------------------------------------------------------------------------
# Backup / swap / restore
# --------------------------------------------------------------------------
# Sidecars are any "windows_updater.*" files (e.g. .exe.config, .pdb) that live
# next to the binary, excluding the .exe itself and excluding prior .previous
# backups. Each is backed up to "<name>.previous" so a rollback is byte-exact.
function Get-SidecarFiles {
    param([Parameter(Mandatory)][string]$InstallDir)
    if (-not (Test-Path $InstallDir)) { return @() }
    return @(
        Get-ChildItem -Path $InstallDir -Filter "windows_updater.*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ine "windows_updater.exe" -and $_.Name -notlike "*.previous" }
    )
}

function Backup-CurrentUpdater {
    param(
        [Parameter(Mandatory)][string]$UpdaterExePath,
        [Parameter(Mandatory)][string]$InstallDir
    )
    # Returns a list of @{ Backup = ...; Original = ... } for rollback.
    $backups = @()

    if (Test-Path $UpdaterExePath) {
        $backup = "$UpdaterExePath.previous"
        Copy-Item -Path $UpdaterExePath -Destination $backup -Force -ErrorAction Stop
        Write-Log "Backed up '$UpdaterExePath' -> '$backup'"
        $backups += @{ Backup = $backup; Original = $UpdaterExePath }
    }
    else {
        Write-Log "No existing '$UpdaterExePath' to back up (it will be created fresh)." "WARN"
    }

    foreach ($sidecar in (Get-SidecarFiles -InstallDir $InstallDir)) {
        $backup = "$($sidecar.FullName).previous"
        Copy-Item -Path $sidecar.FullName -Destination $backup -Force -ErrorAction Stop
        Write-Log "Backed up sidecar '$($sidecar.FullName)' -> '$backup'"
        $backups += @{ Backup = $backup; Original = $sidecar.FullName }
    }

    return ,$backups
}

function Restore-FromBackups {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Backups)
    $allOk = $true
    foreach ($entry in $Backups) {
        try {
            if (Test-Path $entry.Backup) {
                Copy-Item -Path $entry.Backup -Destination $entry.Original -Force -ErrorAction Stop
                Write-Log "Restored '$($entry.Original)' from '$($entry.Backup)'" "WARN"
            }
        }
        catch {
            Write-Log "FAILED to restore '$($entry.Original)' from '$($entry.Backup)': $_" "ERROR"
            $allOk = $false
        }
    }
    return $allOk
}

function Test-SameFile {
    param(
        [Parameter(Mandatory)][string]$PathA,
        [Parameter(Mandatory)][string]$PathB
    )
    if (-not (Test-Path $PathA) -or -not (Test-Path $PathB)) { return $false }
    $a = (Get-FileHash -Path $PathA -Algorithm SHA256).Hash
    $b = (Get-FileHash -Path $PathB -Algorithm SHA256).Hash
    return ($a -eq $b)
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
function Invoke-Bootstrap {
    Write-Log "=== RFQ Updater Bootstrap starting ==="
    Write-Log "Log file: $LogPath"

    # Resolve identity.
    if ([string]::IsNullOrWhiteSpace($UpdaterServiceName)) {
        $script:ResolvedServiceName = Get-RfqEnvValueOrDefault -EnvName "RFQ_UPDATER_SERVICE_NAME" -DefaultValue "RFQUpdaterService"
    } else {
        $script:ResolvedServiceName = $UpdaterServiceName
    }
    Write-Log "Updater service name: $($script:ResolvedServiceName)"

    # Resolve the new bundled binary.
    if ([string]::IsNullOrWhiteSpace($NewUpdaterExe)) {
        $script:ResolvedNewExe = Join-Path $script:ScriptDir "windows_updater.exe"
    } else {
        $script:ResolvedNewExe = $NewUpdaterExe
    }
    if (-not (Test-Path $script:ResolvedNewExe)) {
        Write-Log "Bundled new updater not found: $($script:ResolvedNewExe)" "ERROR"
        return 2
    }
    Write-Log "New updater binary: $($script:ResolvedNewExe)"

    # Resolve install path + target binary.
    $installDir = Resolve-RfqInstallPath -ProvidedInstallPath $InstallPath -ServiceName $script:ResolvedServiceName
    if (-not (Test-Path $installDir)) {
        Write-Log "Resolved install directory does not exist: $installDir" "ERROR"
        Write-Log "Pass -InstallPath or set RFQ_INSTALL_DIR to the RFQ install directory." "ERROR"
        return 2
    }
    $targetExe = Join-Path $installDir "windows_updater.exe"
    Write-Log "Install directory: $installDir"
    Write-Log "Target updater binary: $targetExe"

    # Idempotency: already current?
    if (Test-SameFile -PathA $targetExe -PathB $script:ResolvedNewExe) {
        Write-Log "Installed updater already matches the bundled build (SHA256 equal). No swap needed." "SUCCESS"
        $svc = Get-ServiceOrNull -ServiceName $script:ResolvedServiceName
        if ($svc -and $svc.Status -ne 'Running') {
            Write-Log "Service is not running; starting it to leave the machine healthy."
            if (-not (Start-UpdaterService -ServiceName $script:ResolvedServiceName)) {
                Write-Log "Service could not be started even though the binary is current." "ERROR"
                return 1
            }
        }
        return 0
    }

    # 1) Stop the service (bounded).
    if (-not (Stop-UpdaterService -ServiceName $script:ResolvedServiceName)) {
        Write-Log "Aborting before any change: could not stop the service cleanly." "ERROR"
        Write-Log "Attempting to leave the service running..." "WARN"
        Start-UpdaterService -ServiceName $script:ResolvedServiceName | Out-Null
        return 1
    }

    # 2) Back up current binary + sidecars.
    $backups = @()
    try {
        $backups = Backup-CurrentUpdater -UpdaterExePath $targetExe -InstallDir $installDir
    }
    catch {
        Write-Log "Backup failed: $_" "ERROR"
        Write-Log "No files were modified. Restarting service." "WARN"
        Start-UpdaterService -ServiceName $script:ResolvedServiceName | Out-Null
        return 1
    }

    # 3) Copy the new binary in.
    try {
        Copy-Item -Path $script:ResolvedNewExe -Destination $targetExe -Force -ErrorAction Stop
        Write-Log "Copied new updater into place: $targetExe" "SUCCESS"
    }
    catch {
        Write-Log "Copy of new updater failed: $_" "ERROR"
        Write-Log "Rolling back..." "WARN"
        Restore-FromBackups -Backups $backups | Out-Null
        if (Start-UpdaterService -ServiceName $script:ResolvedServiceName) {
            Write-Log "Rolled back and service restarted. Machine left on the previous updater." "WARN"
        } else {
            Write-Log "Rollback restored files but service did NOT restart. MANUAL ACTION REQUIRED." "ERROR"
        }
        return 1
    }

    # 4) Start the service and verify RUNNING (bounded).
    if (Start-UpdaterService -ServiceName $script:ResolvedServiceName) {
        Write-Log "Updater swap complete. '$($script:ResolvedServiceName)' is RUNNING on the new binary." "SUCCESS"
        Write-Log "This machine's updater can now self-update." "SUCCESS"
        return 0
    }

    # Start failed on the new binary -> rollback.
    Write-Log "New updater did not reach RUNNING. Rolling back to the previous binary..." "ERROR"
    if (-not (Restore-FromBackups -Backups $backups)) {
        Write-Log "Rollback file restore had errors. MANUAL ACTION REQUIRED." "ERROR"
    }
    if (Start-UpdaterService -ServiceName $script:ResolvedServiceName) {
        Write-Log "Rolled back to previous updater; service is RUNNING again. No net change to this machine." "WARN"
        return 1
    }
    Write-Log "Rollback complete but service is STILL not running. MANUAL ACTION REQUIRED." "ERROR"
    return 1
}

$exitCode = 1
try {
    $exitCode = Invoke-Bootstrap
}
catch {
    Write-Log "Unhandled error: $_" "ERROR"
    $exitCode = 1
}

Write-Log "=== RFQ Updater Bootstrap finished (exit $exitCode) ==="
if ($exitCode -eq 0) {
    Write-Log "RESULT: SUCCESS" "SUCCESS"
} else {
    Write-Log "RESULT: FAILURE (see log: $LogPath)" "ERROR"
}

if (-not $NonInteractive) {
    try { Write-Host ""; Read-Host "Press Enter to close" | Out-Null } catch { }
}

exit $exitCode
