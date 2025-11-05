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
    -GitHubToken    GitHub Personal Access Token (will prompt if not provided)
    -Help           Show this help message

EXAMPLES:
    # Basic installation (will prompt for GitHub token)
    .\download_and_install.ps1

    # Custom installation path
    .\download_and_install.ps1 -InstallPath "C:\Program Files\RFQApp"

    # With GitHub token provided
    .\download_and_install.ps1 -GitHubToken "ghp_xxxxxxxxxxxxx"

GITHUB TOKEN:
    The installer requires a GitHub Personal Access Token to download from the
    private repository. If not provided via -GitHubToken, you will be prompted.
    
    To create a token:
    1. Go to: https://github.com/settings/tokens
    2. Generate new token (classic)
    3. Select scope: repo (Full control of private repositories)
    4. Copy the generated token

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
$GITHUB_REPO = "lama-ai-RFQ/RFQwindowspackages"
$GITHUB_API = "https://api.github.com/repos"

# Check PowerShell version
Write-Info "`n[1/8] Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error-Custom "ERROR: PowerShell 5.1 or later is required"
    Write-Error-Custom "Current version: $($PSVersionTable.PSVersion)"
    exit 1
}
Write-Success "[OK] PowerShell version: $($PSVersionTable.PSVersion)"

# Check disk space
Write-Info "`n[2/8] Checking disk space..."
$Drive = (Split-Path $InstallPath -Qualifier)
$FreeSpace = (Get-PSDrive ($Drive.TrimEnd(':'))).Free / 1GB
$FreeSpaceFormatted = "{0:F2}" -f $FreeSpace
if ($FreeSpace -lt 4) {
    Write-Warning "WARNING: Low disk space - $FreeSpaceFormatted GB free. Need at least 4 GB."
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne 'y') {
        exit 1
    }
}
Write-Success "[OK] Available disk space: $FreeSpaceFormatted GB"

# Create installation directory
Write-Info "`n[3/8] Creating installation directory..."
if (!(Test-Path $InstallPath)) {
    try {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-Success "[OK] Created: $InstallPath"
    }
    catch {
        Write-Error-Custom "ERROR: Failed to create directory: $_"
        exit 1
    }
}
else {
    Write-Warning "[!] Directory already exists: $InstallPath"
    $overwrite = Read-Host "Overwrite existing installation? (y/N)"
    if ($overwrite -ne 'y') {
        exit 1
    }
}

# Setup GitHub authentication
Write-Info "`n[4/8] Checking authentication..."

if (!$GitHubToken) {
    Write-Host ""
    Write-Host "GitHub Personal Access Token Required" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The installation package is in a private repository and requires authentication."
    Write-Host ""
    Write-Host "If you don't have a token yet:" -ForegroundColor Cyan
    Write-Host "  1. Go to: https://github.com/settings/tokens"
    Write-Host "  2. Click 'Generate new token (classic)'"
    Write-Host "  3. Select scope: repo (Full control of private repositories)"
    Write-Host "  4. Generate and copy the token"
    Write-Host ""
    
    $GitHubToken = Read-Host "Please enter your GitHub Personal Access Token (ghp_...)"
    
    if (!$GitHubToken -or $GitHubToken.Trim() -eq "") {
        Write-Error-Custom "`nERROR: GitHub token is required to continue"
        exit 1
    }
    
    Write-Host ""
}

$Headers = @{
    "Accept" = "application/vnd.github.v3+json"
    "Authorization" = "token $GitHubToken"
}
Write-Success "[OK] Using GitHub token for authentication"

# Get latest release from GitHub repo
Write-Info "`n[5/8] Checking for latest installation package..."
$ReleaseUrl = "$GITHUB_API/$GITHUB_REPO/releases/latest"

try {
    $Release = Invoke-RestMethod -Uri $ReleaseUrl -Headers $Headers -ErrorAction Stop
    $Version = $Release.tag_name
    Write-Success "[OK] Found version: $Version"
}
catch {
    Write-Error-Custom "ERROR: Failed to fetch release information"
    Write-Error-Custom "  Make sure the repository exists: https://github.com/$GITHUB_REPO"
    Write-Error-Custom "  Make sure you provided a valid GitHub token (private repo)"
    Write-Error-Custom "  Error: $_"
    exit 1
}

# Download component-based installation package
Write-Info "`n[6/8] Downloading installation components..."

# Check for manifest.json (component-based release)
$ManifestAsset = $Release.assets | Where-Object { $_.name -eq "manifest.json" } | Select-Object -First 1

if (!$ManifestAsset) {
    Write-Error-Custom "ERROR: No manifest.json found in release"
    Write-Error-Custom "  This installer requires a component-based release"
    Write-Error-Custom "  Available assets:"
    foreach ($asset in $Release.assets) {
        Write-Error-Custom "    - $($asset.name)"
    }
    exit 1
}

# Download manifest
Write-Info "  Downloading manifest..."
$ManifestPath = Join-Path $env:TEMP "manifest.json"
try {
    $DownloadHeaders = $Headers.Clone()
    $DownloadHeaders["Accept"] = "application/octet-stream"
    
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ManifestAsset.url -OutFile $ManifestPath -Headers $DownloadHeaders -UseBasicParsing
    $ProgressPreference = 'Continue'
    
    $Manifest = Get-Content $ManifestPath | ConvertFrom-Json
    Write-Success "[OK] Downloaded manifest"
}
catch {
    Write-Error-Custom "ERROR: Failed to download manifest: $_"
    exit 1
}

# Create temp directory for downloads
$TempDownloadDir = Join-Path $env:TEMP "rfq_install_temp"
if (Test-Path $TempDownloadDir) {
    Remove-Item $TempDownloadDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TempDownloadDir -Force | Out-Null

# Download all component files
$Components = $Manifest.components.PSObject.Properties
$TotalComponents = $Components.Count
$CurrentComponent = 0

foreach ($ComponentProp in $Components) {
    $CurrentComponent++
    $ComponentName = $ComponentProp.Name
    $ComponentInfo = $ComponentProp.Value
    
    Write-Info "  [$CurrentComponent/$TotalComponents] Downloading: $ComponentName"
    
    foreach ($FileInfo in $ComponentInfo.files) {
        $Filename = $FileInfo.filename
        
        # Find the asset
        $Asset = $Release.assets | Where-Object { $_.name -eq $Filename } | Select-Object -First 1
        
        if (!$Asset) {
            Write-Error-Custom "ERROR: Asset not found: $Filename"
            exit 1
        }
        
        # Download file
        $FilePath = Join-Path $TempDownloadDir $Filename
        try {
            $DownloadHeaders = $Headers.Clone()
            $DownloadHeaders["Accept"] = "application/octet-stream"
            
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Asset.url -OutFile $FilePath -Headers $DownloadHeaders -UseBasicParsing
            $ProgressPreference = 'Continue'
        }
        catch {
            Write-Error-Custom "ERROR: Failed to download $Filename : $_"
            exit 1
        }
    }
}

Write-Success "[OK] All components downloaded"

# Rejoin multi-part files and extract
Write-Info "`n[7/8] Extracting installation files..."

foreach ($ComponentProp in $Components) {
    $ComponentName = $ComponentProp.Name
    $ComponentInfo = $ComponentProp.Value
    $Files = $ComponentInfo.files
    
    Write-Info "  Extracting: $ComponentName"
    
    if ($Files.Count -eq 1) {
        # Single file, extract directly
        $ComponentZip = Join-Path $TempDownloadDir $Files[0].filename
    }
    else {
        # Multi-part, rejoin first
        Write-Info "    Rejoining $($Files.Count) parts..."
        
        # Sort by part number
        $PartFiles = $Files | Sort-Object { [int]($_.filename -replace '.*\.part(\d+)', '$1') }
        
        # Output file name (remove .part1 extension)
        $OutputFilename = $PartFiles[0].filename -replace '\.part\d+$', ''
        $ComponentZip = Join-Path $TempDownloadDir $OutputFilename
        
        # Rejoin parts
        $OutputFile = [System.IO.File]::Create($ComponentZip)
        try {
            foreach ($PartFile in $PartFiles) {
                $PartPath = Join-Path $TempDownloadDir $PartFile.filename
                $PartBytes = [System.IO.File]::ReadAllBytes($PartPath)
                $OutputFile.Write($PartBytes, 0, $PartBytes.Length)
            }
        }
        finally {
            $OutputFile.Close()
        }
    }
    
    # Extract component
    try {
        Expand-Archive -Path $ComponentZip -DestinationPath $InstallPath -Force
    }
    catch {
        Write-Error-Custom "ERROR: Failed to extract $ComponentName : $_"
        exit 1
    }
}

Write-Success "[OK] Extracted all components to: $InstallPath"

# Cleanup temp directory
Remove-Item $TempDownloadDir -Recurse -Force -ErrorAction SilentlyContinue

# Setup .env file with GitHub token
Write-Info "`n[8/8] Configuring application..."
$EnvPath = Join-Path $InstallPath ".env"

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
Write-Success "[OK] Created .env configuration with GitHub token"

# Create version file
$VersionPath = Join-Path $InstallPath "version.txt"
Set-Content -Path $VersionPath -Value $Version -Force

# Create desktop shortcut (optional)
Write-Info "`nCreating shortcuts..."
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
        
        Write-Success "[OK] Created desktop shortcut"
    }
    catch {
        Write-Warning "[!] Could not create desktop shortcut: $_"
    }
}

# Cleanup
Write-Info "`nCleaning up..."
Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue

# Success message
Write-Host @"

================================================================================
*** Installation Complete! ***
================================================================================

Installation Path: $InstallPath
Version: $Version

NEXT STEPS:
  1. Run the application from: $($ExePath.FullName)
  2. Or use the desktop shortcut: RFQ Application
  3. For updates, use the built-in updater (Settings -> System Updates)

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
  - GitHub: https://github.com/$GITHUB_REPO

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

