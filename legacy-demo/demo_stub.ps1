# =====================================================================================
# RFQ Application - Windows Installer  ***DEMO STUB - NOT A REAL INSTALLER***
# =====================================================================================
# This script stands in for download_and_install.ps1 inside the legacy-demo Inno Setup
# build (setup_demo.iss). Its ONLY purpose is to reproduce, on screen, the console UX
# that the real installer shows today - banners, step-by-step progress, and the actual
# interactive y/n and credential prompts - so the flow can be compared side-by-side
# against a new installer. It performs NO real actions of any kind:
#
#   - NO network calls (no GitHub API, no S3/CloudFront, no Invoke-WebRequest,
#     no Invoke-RestMethod, no nssm.cc download)
#   - NO Windows service creation/modification/deletion (never calls nssm.exe or sc.exe)
#   - NO PostgreSQL access (never calls psql.exe)
#   - NO credential storage (never calls cmdkey.exe)
#   - NO python/python.exe invocation
#
# It accepts every named parameter the real download_and_install.ps1 accepts (so the
# Inno Setup [Run] step - built by GetPowerShellParams in setup_demo.iss - never fails
# on an unrecognized parameter), but every value is only logged for display, never
# acted upon. Only Write-Host / Write-Progress / Read-Host / Start-Sleep are used.
# =====================================================================================

param(
    [string]$InstallPath = "$env:LOCALAPPDATA\RFQApplication",
    [string]$GitHubToken = "",
    [switch]$NonInteractive,
    [switch]$Help,
    [switch]$OverwriteExisting,
    [string]$ModelPath = "",
    [switch]$SkipModelDownload,
    [string]$AWSKey = "",
    [string]$AWSSecret = "",
    [string]$AWSRegion = "us-east-1",
    [string]$S3ReleaseBucket = "rfq-distribution-us",
    [string]$S3ReleaseRegion = "",
    [string]$SettingsPassword = "",
    [string]$SuperUserPassword = "",
    [string]$RFQUserPassword = "",
    [string]$ServerURL = "https://localhost",
    [switch]$AzureKeyGenerate,
    [string]$AzureKeyCustom = "",
    [switch]$CleanReinstall,
    [switch]$CleanupAfterInstall,
    [string]$UpdateChannel = "customer",
    [switch]$UseCredentialManager,
    [string]$ServiceAccount = "CurrentUser",
    [switch]$SettingsPasswordAlreadyStored,
    [switch]$SuperUserPasswordAlreadyStored,
    [switch]$RFQUserPasswordAlreadyStored
)

# ---- Help text (mirrors the real script's -Help output; never invoked by the wizard) ----
if ($Help) {
    Write-Host @"
RFQ Application - Windows Installer  ***DEMO STUB***

This is the safe demo copy of download_and_install.ps1. It never performs any
real installation action. See the header comment in this file for details.

USAGE:
    .\demo_stub.ps1 [-InstallPath <path>] [-GitHubToken <token>] [...]
"@
    Write-Host ""
    Write-Host "Press any key to exit..."
    if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    exit 0
}

function Write-DemoLog {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Show-DemoProgress {
    # Simulates a short, realistic-looking progress animation without any real work.
    param(
        [string]$Activity,
        [string]$Status = "Working...",
        [int]$DurationMs = 900
    )
    $steps = 8
    for ($i = 1; $i -le $steps; $i++) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete (($i / $steps) * 100)
        Start-Sleep -Milliseconds ([int]($DurationMs / $steps))
    }
    Write-Progress -Activity $Activity -Completed
}

# =====================================================================================
# Banner (mirrors the real installer's banner, clearly marked as a demo)
# =====================================================================================
$BannerText = @"
================================================================================
    RFQ Application - Windows Installer   ***DEMO MODE - NOT A REAL INSTALL***
    First-Time Installation Script
================================================================================
"@
Write-DemoLog $BannerText "Cyan"
Write-DemoLog ""
Write-DemoLog "[DEMO] This is a non-functional preview build." "Yellow"
Write-DemoLog "[DEMO] No files will be downloaded, no Windows services will be created or" "Yellow"
Write-DemoLog "[DEMO] modified, no PostgreSQL database will be touched, and no credentials" "Yellow"
Write-DemoLog "[DEMO] will be stored anywhere." "Yellow"
Write-DemoLog ""

# Echo the parameters the wizard passed in - for transparency only, never acted upon.
function Mask-Secret([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return "(not provided)" }
    return "********"
}
Write-DemoLog "Received installer parameters (logged only - none are acted upon):" "DarkGray"
Write-DemoLog ("  InstallPath                     = {0}" -f $InstallPath) "DarkGray"
Write-DemoLog ("  GitHubToken                     = {0}" -f (Mask-Secret $GitHubToken)) "DarkGray"
Write-DemoLog ("  NonInteractive                  = {0}" -f $NonInteractive.IsPresent) "DarkGray"
Write-DemoLog ("  OverwriteExisting               = {0}" -f $OverwriteExisting.IsPresent) "DarkGray"
Write-DemoLog ("  ModelPath                       = {0}" -f $ModelPath) "DarkGray"
Write-DemoLog ("  SkipModelDownload               = {0}" -f $SkipModelDownload.IsPresent) "DarkGray"
Write-DemoLog ("  AWSKey                          = {0}" -f (Mask-Secret $AWSKey)) "DarkGray"
Write-DemoLog ("  AWSSecret                       = {0}" -f (Mask-Secret $AWSSecret)) "DarkGray"
Write-DemoLog ("  AWSRegion                       = {0}" -f $AWSRegion) "DarkGray"
Write-DemoLog ("  S3ReleaseBucket                 = {0}" -f $S3ReleaseBucket) "DarkGray"
Write-DemoLog ("  S3ReleaseRegion                 = {0}" -f $S3ReleaseRegion) "DarkGray"
Write-DemoLog ("  SettingsPassword                = {0}" -f (Mask-Secret $SettingsPassword)) "DarkGray"
Write-DemoLog ("  SuperUserPassword               = {0}" -f (Mask-Secret $SuperUserPassword)) "DarkGray"
Write-DemoLog ("  RFQUserPassword                 = {0}" -f (Mask-Secret $RFQUserPassword)) "DarkGray"
Write-DemoLog ("  ServerURL                       = {0}" -f $ServerURL) "DarkGray"
Write-DemoLog ("  AzureKeyGenerate                = {0}" -f $AzureKeyGenerate.IsPresent) "DarkGray"
Write-DemoLog ("  AzureKeyCustom                  = {0}" -f (Mask-Secret $AzureKeyCustom)) "DarkGray"
Write-DemoLog ("  CleanReinstall                  = {0}" -f $CleanReinstall.IsPresent) "DarkGray"
Write-DemoLog ("  CleanupAfterInstall             = {0}" -f $CleanupAfterInstall.IsPresent) "DarkGray"
Write-DemoLog ("  UpdateChannel                   = {0}" -f $UpdateChannel) "DarkGray"
Write-DemoLog ("  UseCredentialManager            = {0}" -f $UseCredentialManager.IsPresent) "DarkGray"
Write-DemoLog ("  ServiceAccount                  = {0}" -f $ServiceAccount) "DarkGray"
Write-DemoLog ("  SettingsPasswordAlreadyStored   = {0}" -f $SettingsPasswordAlreadyStored.IsPresent) "DarkGray"
Write-DemoLog ("  SuperUserPasswordAlreadyStored  = {0}" -f $SuperUserPasswordAlreadyStored.IsPresent) "DarkGray"
Write-DemoLog ("  RFQUserPasswordAlreadyStored    = {0}" -f $RFQUserPasswordAlreadyStored.IsPresent) "DarkGray"
Write-DemoLog ""

# =====================================================================================
# Simulated 8-step flow (step numbering/labels mirror the real installer's console
# output so the two can be compared side-by-side).
# =====================================================================================
Write-DemoLog "`n[1/8] Checking PowerShell version..." "Cyan"
Start-Sleep -Milliseconds 200
Write-DemoLog "[OK] PowerShell version: $($PSVersionTable.PSVersion)" "Green"

Write-DemoLog "`n[2/8] Checking disk space... (simulated)" "Cyan"
Start-Sleep -Milliseconds 200
Write-DemoLog "[OK] [DEMO] Skipping real disk space check." "Green"

Write-DemoLog "`n[3/8] Creating installation directory... (simulated)" "Cyan"
Start-Sleep -Milliseconds 200
Write-DemoLog "[OK] [DEMO] No directory was actually created at: $InstallPath" "Green"

Write-DemoLog "`n[4/8] Checking authentication... (simulated)" "Cyan"
Write-DemoLog "[DEMO] Skipping real GitHub token / AWS credential validation." "Yellow"
Start-Sleep -Milliseconds 300

Write-DemoLog "`n[5/8] Checking for latest installation package... (simulated)" "Cyan"
Write-DemoLog "[DEMO] No GitHub API / S3 / CloudFront requests are made." "Yellow"
Start-Sleep -Milliseconds 300

Write-DemoLog "`n[6/8] Downloading installation components..." "Cyan"
Show-DemoProgress -Activity "Downloading application components (simulated)" -Status "Downloading..." -DurationMs 1500
Write-DemoLog "[OK] [DEMO] No files were actually downloaded." "Green"

Write-DemoLog "`n[7/8] Extracting installation files..." "Cyan"
Show-DemoProgress -Activity "Extracting installation files (simulated)" -Status "Extracting..." -DurationMs 900
Write-DemoLog "[OK] [DEMO] No files were actually extracted." "Green"

Write-DemoLog "`n[8/8] Configuring application... (simulated)" "Cyan"
Start-Sleep -Milliseconds 300
Write-DemoLog "[OK] [DEMO] No .env file was actually written." "Green"

# =====================================================================================
# Simulated model download (~30 GB in the real installer) - purely cosmetic here.
# =====================================================================================
if (-not $SkipModelDownload) {
    Write-DemoLog "`nModel download... (simulated)" "Cyan"
    Write-DemoLog "[DEMO] The real installer would now download a large (~30 GB) language" "Yellow"
    Write-DemoLog "[DEMO] model from AWS S3. This demo does not download anything." "Yellow"
    Show-DemoProgress -Activity "Downloading language model (simulated, ~30 GB in real installer)" -Status "Downloading..." -DurationMs 1500
    Write-DemoLog "[OK] [DEMO] No model was actually downloaded." "Green"
}
else {
    Write-DemoLog "`nModel download skipped (per -SkipModelDownload)." "Yellow"
}

# =====================================================================================
# Database setup prompt - reproduces the real installer's unconditional interactive
# "Set up database now? (y/N)" prompt. Answered "y" or "n", nothing is ever touched:
# no psql.exe is invoked, no database is created, modified, or queried.
# =====================================================================================
Write-DemoLog "`nDatabase setup..." "Cyan"
Write-DemoLog "PostgreSQL detected. Would you like to set up the database now? (simulated)" "White"
Write-DemoLog "  Note: This requires .env file to be configured with SQL_SUPER_USER and RFQ_USER_PASSWORD" "White"
Write-DemoLog ""
if ($NonInteractive) { $setupDb = "" } else { $setupDb = Read-Host "Set up database now? (y/N)" }
if ($setupDb -eq 'y') {
    Write-DemoLog "[DEMO] Simulating database setup - psql.exe is NEVER invoked by this demo." "Yellow"
    Show-DemoProgress -Activity "Setting up database (simulated)" -Status "Configuring..." -DurationMs 900
    Write-DemoLog "[OK] [DEMO] No database was actually created, modified, or queried." "Green"
}
else {
    Write-DemoLog "[DEMO] Skipping simulated database setup." "Yellow"
}

# =====================================================================================
# Windows service account prompts - reproduces the real installer's interactive flow
# when the service account is "Current User" (the default) or otherwise ambiguous.
# No service is ever created; nssm.exe and sc.exe are NEVER invoked by this demo.
# =====================================================================================
Write-DemoLog "`nWindows service configuration... (simulated)" "Cyan"

$normalizedServiceAccount = $ServiceAccount
if ([string]::IsNullOrWhiteSpace($normalizedServiceAccount)) { $normalizedServiceAccount = "CurrentUser" }

switch ($normalizedServiceAccount.ToLower()) {
    "currentuser" {
        Write-DemoLog "  You selected to run the service as a user account." "White"
        Write-DemoLog "  This allows the service to access Windows Credential Manager credentials." "White"
        Write-DemoLog ""
        Write-DemoLog "  Account information:" "White"
        Write-DemoLog ("    - Admin account (running installer): {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) "White"
        Write-DemoLog ""
        Write-DemoLog "  Enter the account name to run the service as:" "White"
        Write-DemoLog "    - Format: DOMAIN\Username (e.g., MYDOMAIN\john)" "White"
        Write-DemoLog "    - Or: .\Username for local account (e.g., .\john)" "White"
        Write-DemoLog ("    - Or: Username (will use current domain: {0})" -f $env:USERDOMAIN) "White"
        Write-DemoLog ""

        if ($NonInteractive) { $accountInput = "" } else { $accountInput = Read-Host "  Account name" }

        if ([string]::IsNullOrWhiteSpace($accountInput)) {
            Write-DemoLog "  No account name provided. [DEMO] No service account would be configured." "Yellow"
        }
        else {
            Write-DemoLog "  [DEMO] Service would be configured to run as: $accountInput" "White"
            Write-DemoLog "  Your password will NOT be stored anywhere - this is a demo." "White"
            Write-DemoLog ""

            if ($NonInteractive) {
                $securePassword = $null
            }
            else {
                $securePassword = Read-Host "  Enter password for $accountInput" -AsSecureString
            }
            # The password is intentionally never used, stored, or written anywhere -
            # not even to Windows Credential Manager (cmdkey.exe is never called).
            $securePassword = $null
            Write-DemoLog "  [DEMO] Password accepted and immediately discarded (not stored anywhere)." "Green"
        }
    }
    "networkservice" {
        Write-DemoLog "  [DEMO] Service would be configured to run as: NT AUTHORITY\NETWORK SERVICE" "White"
    }
    "localsystem" {
        Write-DemoLog "  [DEMO] Service would be configured to run as: LocalSystem (SYSTEM)" "White"
    }
    default {
        Write-DemoLog "  [DEMO] Unrecognized service account '$ServiceAccount' - no service would be created." "Yellow"
    }
}

Write-DemoLog "`n[DEMO] Simulating Windows service creation (nssm.exe / sc.exe are NEVER invoked)..." "Cyan"
Show-DemoProgress -Activity "Creating Windows service 'RFQapplication' (simulated)" -Status "Configuring..." -DurationMs 900
Write-DemoLog "[OK] [DEMO] No Windows service was actually created, started, or modified." "Green"

# =====================================================================================
# Final summary
# =====================================================================================
$SummaryText = @"

================================================================================
*** Demo Run Complete! ***
================================================================================

Installation Path (never created): $InstallPath

[DEMO] No files were downloaded, no services were created or modified, and no database was touched.

================================================================================
"@
Write-DemoLog $SummaryText "Green"

Write-Host ""
Write-Host "Press any key to exit..."
if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
exit 0
