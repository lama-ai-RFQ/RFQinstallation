# RFQ Application - Windows Installation Script
# Downloads and installs the RFQ application from GitHub releases
# This script is for first-time installation only

param(
    [string]$InstallPath = "$env:LOCALAPPDATA\RFQApplication",
    [string]$GitHubToken = "",
    [switch]$Help
)

# Colors for output
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Error-Custom { Write-Host $args -ForegroundColor Red }

# Show help
if ($Help) {
    Write-Host @"
RFQ Application - Windows Installer

USAGE:
    .\download_and_install.ps1 [-InstallPath <path>] [-GitHubToken <token>]

OPTIONS:
    -InstallPath    Installation directory (default: %LOCALAPPDATA%\RFQApplication)
    -GitHubToken    GitHub Personal Access Token (optional, for private repos)
    -Help           Show this help message

EXAMPLES:
    # Basic installation (public repo)
    .\download_and_install.ps1

    # Custom installation path
    .\download_and_install.ps1 -InstallPath "C:\Program Files\RFQApp"

    # With GitHub token for private repos
    .\download_and_install.ps1 -GitHubToken "ghp_xxxxxxxxxxxxx"

NOTES:
    - Requires PowerShell 5.1 or later
    - Requires internet connection
    - Requires ~3.5 GB free disk space
    - First-time installation only (use built-in updater for updates)

"@
    exit 0
}

# Banner
Write-Host @"
================================================================================
    RFQ Application - Windows Installer
    First-Time Installation Script
================================================================================
"@ -ForegroundColor Cyan

# Configuration
$PUBLIC_REPO = "lama-ai-RFQ/RFQinstallation"
$PRIVATE_REPO = "lama-ai-rfq/rfqwindowspackages"
$GITHUB_API = "https://api.github.com/repos"

# Check PowerShell version
Write-Info "`n[1/8] Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error-Custom "ERROR: PowerShell 5.1 or later is required"
    Write-Error-Custom "Current version: $($PSVersionTable.PSVersion)"
    exit 1
}
Write-Success "✓ PowerShell version: $($PSVersionTable.PSVersion)"

# Check disk space
Write-Info "`n[2/8] Checking disk space..."
$Drive = (Split-Path $InstallPath -Qualifier)
$FreeSpace = (Get-PSDrive ($Drive.TrimEnd(':'))).Free / 1GB
if ($FreeSpace -lt 4) {
    Write-Warning "WARNING: Low disk space (${FreeSpace:F2} GB free). Need at least 4 GB."
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne 'y') {
        exit 1
    }
}
Write-Success "✓ Available disk space: ${FreeSpace:F2} GB"

# Create installation directory
Write-Info "`n[3/8] Creating installation directory..."
if (!(Test-Path $InstallPath)) {
    try {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-Success "✓ Created: $InstallPath"
    }
    catch {
        Write-Error-Custom "ERROR: Failed to create directory: $_"
        exit 1
    }
}
else {
    Write-Warning "⚠ Directory already exists: $InstallPath"
    $overwrite = Read-Host "Overwrite existing installation? (y/N)"
    if ($overwrite -ne 'y') {
        exit 1
    }
}

# Setup GitHub authentication
$Headers = @{
    "Accept" = "application/vnd.github.v3+json"
}

if ($GitHubToken) {
    $Headers["Authorization"] = "token $GitHubToken"
    Write-Success "✓ Using GitHub token for authentication"
}

# Get latest release from public repo
Write-Info "`n[4/8] Checking for latest installation package..."
$ReleaseUrl = "$GITHUB_API/$PUBLIC_REPO/releases/latest"

try {
    $Release = Invoke-RestMethod -Uri $ReleaseUrl -Headers $Headers -ErrorAction Stop
    $Version = $Release.tag_name
    Write-Success "✓ Found version: $Version"
}
catch {
    Write-Error-Custom "ERROR: Failed to fetch release information"
    Write-Error-Custom "  Make sure the repository exists: https://github.com/$PUBLIC_REPO"
    Write-Error-Custom "  Error: $_"
    exit 1
}

# Download installer package
Write-Info "`n[5/8] Downloading installation package..."

$InstallerAsset = $Release.assets | Where-Object { $_.name -like "*installer*.zip" -or $_.name -like "*setup*.zip" } | Select-Object -First 1

if (!$InstallerAsset) {
    Write-Error-Custom "ERROR: No installer package found in release"
    Write-Error-Custom "  Looking for files matching: *installer*.zip or *setup*.zip"
    Write-Error-Custom "  Available assets:"
    foreach ($asset in $Release.assets) {
        Write-Error-Custom "    - $($asset.name)"
    }
    exit 1
}

$DownloadUrl = $InstallerAsset.browser_download_url
$InstallerPath = Join-Path $env:TEMP $InstallerAsset.name
$FileSize = $InstallerAsset.size / 1MB

Write-Info "  Downloading: $($InstallerAsset.name) (${FileSize:F2} MB)"
Write-Info "  From: $DownloadUrl"

try {
    # Download with progress
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -Headers $Headers -UseBasicParsing
    $ProgressPreference = 'Continue'
    Write-Success "✓ Downloaded to: $InstallerPath"
}
catch {
    Write-Error-Custom "ERROR: Failed to download installer: $_"
    exit 1
}

# Extract installer package
Write-Info "`n[6/8] Extracting installation files..."
try {
    Expand-Archive -Path $InstallerPath -DestinationPath $InstallPath -Force
    Write-Success "✓ Extracted to: $InstallPath"
}
catch {
    Write-Error-Custom "ERROR: Failed to extract installer: $_"
    exit 1
}

# Setup .env file with GitHub token
Write-Info "`n[7/8] Configuring application..."
$EnvPath = Join-Path $InstallPath ".env"

if ($GitHubToken) {
    $EnvContent = @"
# RFQ Application Configuration
# Generated by installer on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# GitHub Authentication (for updates)
GITHUB_PAT=$GitHubToken

# Application Mode
APP_MODE=fastapi

# Windows Specific
WINDOWS=true
LOCAL_DATABASE=1
"@

    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "✓ Created .env configuration with GitHub token"
}
else {
    Write-Warning "⚠ No GitHub token provided - updates may not work"
    Write-Info "  You can add it later to .env file:"
    Write-Info "  GITHUB_PAT=your_token_here"
}

# Create version file
$VersionPath = Join-Path $InstallPath "version.txt"
Set-Content -Path $VersionPath -Value $Version -Force

# Create desktop shortcut (optional)
Write-Info "`n[8/8] Creating shortcuts..."
$ExePath = Get-ChildItem -Path $InstallPath -Filter "*.exe" -Recurse | Select-Object -First 1

if ($ExePath) {
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $DesktopPath = [System.Environment]::GetFolderPath('Desktop')
        $ShortcutPath = Join-Path $DesktopPath "RFQ Application.lnk"
        
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $ExePath.FullName
        $Shortcut.WorkingDirectory = $InstallPath
        $Shortcut.Description = "RFQ Automation Application"
        $Shortcut.Save()
        
        Write-Success "✓ Created desktop shortcut"
    }
    catch {
        Write-Warning "⚠ Could not create desktop shortcut: $_"
    }
}

# Cleanup
Write-Info "`nCleaning up..."
Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue

# Success message
Write-Host @"

================================================================================
✓✓✓ Installation Complete!
================================================================================

Installation Path: $InstallPath
Version: $Version

NEXT STEPS:
  1. Run the application from: $($ExePath.FullName)
  2. Or use the desktop shortcut: RFQ Application
  3. For updates, use the built-in updater (Settings → System Updates)

CONFIGURATION:
  - Config file: $InstallPath\.env
  - Database will be created on first run
  - Logs: $InstallPath\logs\

TROUBLESHOOTING:
  - If the app doesn't start, check logs in the logs\ folder
  - Make sure you have required dependencies installed
  - For database setup, see README_Windows.md

SUPPORT:
  - Documentation: $InstallPath\README_Windows.md
  - GitHub: https://github.com/$PUBLIC_REPO

================================================================================
"@ -ForegroundColor Green

# Ask to launch
$launch = Read-Host "`nLaunch RFQ Application now? (Y/n)"
if ($launch -ne 'n') {
    if ($ExePath) {
        Write-Info "Launching application..."
        Start-Process -FilePath $ExePath.FullName -WorkingDirectory $InstallPath
    }
}

