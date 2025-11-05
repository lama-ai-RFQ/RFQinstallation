# Prepare RFQ Installation Package
# Creates a ZIP file ready for upload to lama-ai-RFQ/RFQinstallation releases

param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,
    
    [Parameter(Mandatory=$true)]
    [string]$Version,
    
    [string]$OutputPath = ".",
    
    [switch]$Help
)

function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Error-Custom { Write-Host $args -ForegroundColor Red }

if ($Help) {
    Write-Host @"
RFQ Installation Package Preparation Script

USAGE:
    .\prepare_installer_package.ps1 -SourcePath <path> -Version <version> [-OutputPath <path>]

PARAMETERS:
    -SourcePath     Path to built RFQ application directory
    -Version        Version number (e.g., 3.0.815)
    -OutputPath     Where to save the installer ZIP (default: current directory)
    -Help           Show this help message

EXAMPLE:
    .\prepare_installer_package.ps1 -SourcePath ".\dist\RFQ_Application" -Version "3.0.815"

OUTPUT:
    Creates: RFQ-windows-installer-v3.0.815.zip

NOTES:
    - Source must contain RFQ_Application.exe
    - Creates a clean installer package
    - Excludes unnecessary files (logs, temp, __pycache__)
    - Ready for upload to GitHub releases

"@
    exit 0
}

Write-Host @"
================================================================================
    RFQ Installation Package Preparation
================================================================================
"@ -ForegroundColor Cyan

# Validate source path
Write-Info "`n[1/6] Validating source path..."
if (!(Test-Path $SourcePath)) {
    Write-Error-Custom "ERROR: Source path does not exist: $SourcePath"
    exit 1
}

$ExePath = Join-Path $SourcePath "RFQ_Application.exe"
if (!(Test-Path $ExePath)) {
    Write-Error-Custom "ERROR: RFQ_Application.exe not found in source path"
    Write-Error-Custom "Expected: $ExePath"
    exit 1
}

Write-Success "✓ Source path validated: $SourcePath"

# Create output directory
Write-Info "`n[2/6] Preparing output directory..."
if (!(Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$OutputZip = Join-Path $OutputPath "RFQ-windows-installer-v$Version.zip"
if (Test-Path $OutputZip) {
    Write-Warning "⚠ Output file already exists: $OutputZip"
    $overwrite = Read-Host "Overwrite? (y/N)"
    if ($overwrite -ne 'y') {
        exit 1
    }
    Remove-Item $OutputZip -Force
}

Write-Success "✓ Output will be: $OutputZip"

# Create temporary staging directory
Write-Info "`n[3/6] Creating staging directory..."
$TempDir = Join-Path $env:TEMP "rfq_installer_$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
Write-Success "✓ Staging directory: $TempDir"

# Copy files to staging (excluding unnecessary files)
Write-Info "`n[4/6] Copying files to staging..."

$ExcludePatterns = @(
    "*.pyc",
    "__pycache__",
    "logs",
    "temp",
    "temp_*",
    "*.log",
    "local_manifest.json",
    "updates",
    "backup",
    "email_attachments",
    "quotations",
    ".git",
    ".idea",
    "node_modules"
)

Write-Info "Copying files (this may take a few minutes)..."

# Copy everything first
Copy-Item -Path "$SourcePath\*" -Destination $TempDir -Recurse -Force

# Remove excluded patterns
foreach ($pattern in $ExcludePatterns) {
    Get-ChildItem -Path $TempDir -Recurse -Filter $pattern -Force -ErrorAction SilentlyContinue | 
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Calculate size
$TotalSize = (Get-ChildItem -Path $TempDir -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1GB
Write-Success "✓ Copied files (${TotalSize:F2} GB)"

# Create version.txt
Write-Info "`n[5/6] Creating version metadata..."
$VersionFile = Join-Path $TempDir "version.txt"
Set-Content -Path $VersionFile -Value $Version -Force

# Create .env.template
$EnvTemplate = Join-Path $TempDir ".env.template"
$EnvContent = @"
# RFQ Application Configuration Template
# Copy this file to .env and fill in your values

# GitHub Personal Access Token (for updates)
# Get token from: https://github.com/settings/tokens
GITHUB_PAT=your_github_pat_here

# Application Mode
APP_MODE=fastapi

# Windows Specific
WINDOWS=true
LOCAL_DATABASE=1

# Optional: Database Configuration
# RFQ_USER_PASSWORD=your_database_password_here
# DB_HOST=localhost
# DB_PORT=5432
# DB_NAME=rfq_db
# DB_USER=rfq_user

# Optional: Debug Mode
# DEBUG=1
"@
Set-Content -Path $EnvTemplate -Value $EnvContent -Force

Write-Success "✓ Created version and template files"

# Create installer ZIP
Write-Info "`n[6/6] Creating installer ZIP..."
try {
    Compress-Archive -Path "$TempDir\*" -DestinationPath $OutputZip -CompressionLevel Optimal -Force
    $ZipSize = (Get-Item $OutputZip).Length / 1MB
    Write-Success "✓ Created installer ZIP (${ZipSize:F2} MB)"
}
catch {
    Write-Error-Custom "ERROR: Failed to create ZIP: $_"
    exit 1
}

# Cleanup staging
Write-Info "`nCleaning up staging directory..."
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Success "✓ Cleanup complete"

# Summary
Write-Host @"

================================================================================
✓✓✓ Installation Package Ready!
================================================================================

Output File: $OutputZip
Size: ${ZipSize:F2} MB
Version: $Version

NEXT STEPS:
  1. Go to https://github.com/lama-ai-RFQ/RFQinstallation/releases/new
  2. Create a new tag: v$Version
  3. Set release title: "RFQ Application v$Version"
  4. Upload: $OutputZip
  5. Check "Set as the latest release"
  6. Publish release

VERIFICATION:
  - ZIP contains RFQ_Application.exe
  - Version file is included
  - .env.template is included
  - Size is reasonable (~${TotalSize:F2} GB uncompressed)

TEST INSTALLATION:
  After publishing the release, test with:
  
  .\download_and_install.ps1 -GitHubToken "ghp_xxxxx"

================================================================================
"@ -ForegroundColor Green

