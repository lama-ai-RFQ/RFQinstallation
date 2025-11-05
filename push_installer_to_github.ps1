# Push RFQ Installer Package to Public GitHub Repository
# Automates the process of creating and uploading installer to lama-ai-RFQ/RFQinstallation

param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,
    
    [Parameter(Mandatory=$true)]
    [string]$Version,
    
    [string]$GitHubToken = "",
    
    [string]$ReleaseNotes = "",
    
    [switch]$Draft,
    
    [switch]$Prerelease,
    
    [switch]$Help
)

function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Error-Custom { Write-Host $args -ForegroundColor Red }

if ($Help) {
    Write-Host @"
Push RFQ Installer to Public GitHub Repository

USAGE:
    .\push_installer_to_github.ps1 -SourcePath <path> -Version <version> [options]

REQUIRED PARAMETERS:
    -SourcePath     Path to built RFQ application directory
    -Version        Version number (e.g., 3.0.815)

OPTIONAL PARAMETERS:
    -GitHubToken    GitHub Personal Access Token (or set GH_TOKEN env var)
    -ReleaseNotes   Release notes/changelog (markdown supported)
    -Draft          Create as draft release (not published immediately)
    -Prerelease     Mark as pre-release/beta version
    -Help           Show this help message

EXAMPLES:
    # Basic usage (will prompt for token if not provided)
    .\push_installer_to_github.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815"

    # With GitHub token
    .\push_installer_to_github.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815" -GitHubToken "ghp_xxxxx"

    # With release notes
    .\push_installer_to_github.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815" -ReleaseNotes "Fixed bugs, added features"

    # Create as draft
    .\push_installer_to_github.ps1 -SourcePath "..\..\dist\RFQ_Application" -Version "3.0.815" -Draft

PREREQUISITES:
    - GitHub CLI (gh) installed: https://cli.github.com/
      OR
    - GitHub Personal Access Token with 'repo' scope

PROCESS:
    1. Prepares installer package (ZIP file)
    2. Creates GitHub release in lama-ai-RFQ/RFQinstallation
    3. Uploads installer ZIP
    4. Uploads installer scripts (download_and_install.ps1, install.bat)
    5. Sets as latest release (unless -Draft specified)

"@
    exit 0
}

Write-Host @"
================================================================================
    Push RFQ Installer to Public GitHub Repository
================================================================================
"@ -ForegroundColor Cyan

$PUBLIC_REPO = "lama-ai-RFQ/RFQinstallation"
$TAG = "v$Version"

# Step 1: Check prerequisites
Write-Info "`n[1/8] Checking prerequisites..."

# Check if GitHub CLI is available
$UseGHCLI = $false
try {
    $null = Get-Command gh -ErrorAction Stop
    $UseGHCLI = $true
    Write-Success "GitHub CLI found"
}
catch {
    Write-Warning "[WARN] GitHub CLI not found, will use API"
    Write-Info "  Install from: https://cli.github.com/"
}

# Get GitHub token
if (!$GitHubToken) {
    $GitHubToken = $env:GH_TOKEN
    if (!$GitHubToken) {
        $GitHubToken = $env:GITHUB_TOKEN
    }
}

if (!$GitHubToken -and !$UseGHCLI) {
    Write-Error-Custom "ERROR: GitHub token required when not using GitHub CLI"
    Write-Error-Custom "  Provide with -GitHubToken parameter or set GH_TOKEN environment variable"
    exit 1
}

if ($GitHubToken) {
    Write-Success "[OK] GitHub token provided"
}

# Step 2: Prepare installer package
Write-Info "`n[2/8] Preparing installer package..."

$PrepareScript = Join-Path $PSScriptRoot "prepare_installer_package.ps1"
if (!(Test-Path $PrepareScript)) {
    Write-Error-Custom "ERROR: prepare_installer_package.ps1 not found"
    Write-Error-Custom "Expected at: $PrepareScript"
    exit 1
}

$OutputDir = Join-Path $env:TEMP "rfq_release_$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

try {
    & $PrepareScript -SourcePath $SourcePath -Version $Version -OutputPath $OutputDir
    if ($LASTEXITCODE -ne 0) {
        throw "Package preparation failed"
    }
}
catch {
    Write-Error-Custom "ERROR: Failed to prepare package: $_"
    exit 1
}

$InstallerZip = Join-Path $OutputDir "RFQ-windows-installer-v$Version.zip"
if (!(Test-Path $InstallerZip)) {
    Write-Error-Custom "ERROR: Installer ZIP not found: $InstallerZip"
    exit 1
}

$ZipSize = (Get-Item $InstallerZip).Length / 1MB
$ZipSizeFormatted = "{0:F2}" -f $ZipSize
Write-Success "Installer package ready ($ZipSizeFormatted MB)"

# Step 3: Prepare additional assets
Write-Info "`n[3/8] Preparing additional assets..."

$InstallerScript = Join-Path $PSScriptRoot "download_and_install.ps1"
$InstallBat = Join-Path $PSScriptRoot "install.bat"

$Assets = @($InstallerZip)

if (Test-Path $InstallerScript) {
    $Assets += $InstallerScript
    Write-Info "  + download_and_install.ps1"
}
if (Test-Path $InstallBat) {
    $Assets += $InstallBat
    Write-Info "  + install.bat"
}

Write-Success "$($Assets.Count) assets ready for upload"

# Step 4: Check if release already exists
Write-Info "`n[4/8] Checking for existing release..."

if ($UseGHCLI) {
    $ExistingRelease = gh release view $TAG --repo $PUBLIC_REPO 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Warning "[WARN] Release $TAG already exists in $PUBLIC_REPO"
        $overwrite = Read-Host "Delete and recreate? (y/N)"
        if ($overwrite -eq 'y') {
            Write-Info "  Deleting existing release..."
            gh release delete $TAG --repo $PUBLIC_REPO --yes
            Write-Success "[OK] Deleted existing release"
        }
        else {
            Write-Error-Custom "Aborted by user"
            exit 1
        }
    }
}
else {
    # Check via API
    $Headers = @{
        "Authorization" = "token $GitHubToken"
        "Accept" = "application/vnd.github.v3+json"
    }
    
    try {
        $CheckUrl = "https://api.github.com/repos/$PUBLIC_REPO/releases/tags/$TAG"
        $Response = Invoke-RestMethod -Uri $CheckUrl -Headers $Headers -ErrorAction Stop
        
        Write-Warning "[WARN] Release $TAG already exists"
        $overwrite = Read-Host "Delete and recreate? (y/N)"
        if ($overwrite -eq 'y') {
            Write-Info "  Deleting existing release..."
            $DeleteUrl = "https://api.github.com/repos/$PUBLIC_REPO/releases/$($Response.id)"
            Invoke-RestMethod -Uri $DeleteUrl -Method Delete -Headers $Headers | Out-Null
            Write-Success "[OK] Deleted existing release"
        }
        else {
            Write-Error-Custom "Aborted by user"
            exit 1
        }
    }
    catch {
        # Release doesn't exist, which is fine
        Write-Success "[OK] Release $TAG does not exist (ready to create)"
    }
}

# Step 5: Prepare release notes
Write-Info "`n[5/8] Preparing release notes..."

if (!$ReleaseNotes) {
    $ReleaseDate = Get-Date -Format "yyyy-MM-dd"
    $ReleaseNotes = @"
RFQ Application v$Version - Windows Installation Package

INSTALLATION:
Download and run: https://github.com/$PUBLIC_REPO/releases/download/$TAG/download_and_install.ps1

WHAT'S INCLUDED:
* Complete RFQ Application for Windows
* Automatic updater (requires GitHub PAT)
* Database setup utilities
* Documentation

REQUIREMENTS:
* Windows 10/11 (64-bit)
* 4 GB free disk space
* Internet connection
* GitHub Personal Access Token (for updates)

PACKAGE SIZE: $ZipSizeFormatted MB
RELEASE DATE: $ReleaseDate
"@
}

Write-Success "Release notes prepared"

# Step 6: Create release
Write-Info "`n[6/8] Creating GitHub release..."

if ($UseGHCLI) {
    # Use GitHub CLI
    $GHArgs = @(
        "release", "create", $TAG
        "--repo", $PUBLIC_REPO
        "--title", "RFQ Application v$Version"
        "--notes", $ReleaseNotes
    )
    
    if ($Draft) {
        $GHArgs += "--draft"
    }
    
    if ($Prerelease) {
        $GHArgs += "--prerelease"
    }
    else {
        $GHArgs += "--latest"
    }
    
    # Add assets
    foreach ($asset in $Assets) {
        $GHArgs += $asset
    }
    
    Write-Info "  Creating release with GitHub CLI..."
    & gh @GHArgs
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Custom "ERROR: Failed to create release"
        exit 1
    }
    
    Write-Success "[OK] Release created successfully"
}
else {
    # Use GitHub API
    Write-Info "  Creating release via GitHub API..."
    
    $CreateUrl = "https://api.github.com/repos/$PUBLIC_REPO/releases"
    $ReleaseData = @{
        tag_name = $TAG
        name = "RFQ Application v$Version"
        body = $ReleaseNotes
        draft = $Draft.IsPresent
        prerelease = $Prerelease.IsPresent
    } | ConvertTo-Json
    
    try {
        $Release = Invoke-RestMethod -Uri $CreateUrl -Method Post -Headers $Headers -Body $ReleaseData -ContentType "application/json"
        Write-Success "[OK] Release created (ID: $($Release.id))"
        
        # Step 7: Upload assets
        Write-Info "`n[7/8] Uploading assets..."
        
        foreach ($asset in $Assets) {
            $AssetName = [System.IO.Path]::GetFileName($asset)
            $AssetSize = (Get-Item $asset).Length / 1MB
            
            Write-Info "  Uploading: $AssetName (${AssetSize:F2} MB)..."
            
            $UploadUrl = $Release.upload_url -replace '\{\?.*\}', "?name=$AssetName"
            
            $AssetBytes = [System.IO.File]::ReadAllBytes($asset)
            $AssetHeaders = $Headers.Clone()
            $AssetHeaders["Content-Type"] = "application/octet-stream"
            
            try {
                Invoke-RestMethod -Uri $UploadUrl -Method Post -Headers $AssetHeaders -Body $AssetBytes | Out-Null
                Write-Success "    [OK] Uploaded $AssetName"
            }
            catch {
                Write-Error-Custom "    [ERR] Failed to upload $AssetName : $_"
            }
        }
    }
    catch {
        Write-Error-Custom "ERROR: Failed to create release: $_"
        exit 1
    }
}

# Step 8: Verify release
Write-Info "`n[8/8] Verifying release..."

Start-Sleep -Seconds 2

$ReleaseUrl = "https://github.com/$PUBLIC_REPO/releases/tag/$TAG"

try {
    if ($UseGHCLI) {
        $ReleaseInfo = gh release view $TAG --repo $PUBLIC_REPO --json url,assets
        Write-Success "[OK] Release verified"
    }
    else {
        $CheckUrl = "https://api.github.com/repos/$PUBLIC_REPO/releases/tags/$TAG"
        $ReleaseInfo = Invoke-RestMethod -Uri $CheckUrl -Headers $Headers
        Write-Success "[OK] Release verified ($(($ReleaseInfo.assets).Count) assets)"
    }
}
catch {
    Write-Warning "[WARN] Could not verify release, but it may have been created"
}

# Cleanup
Write-Info "`nCleaning up temporary files..."
Remove-Item $OutputDir -Recurse -Force -ErrorAction SilentlyContinue

# Success message
$StatusText = if ($Draft) { "DRAFT" } else { "PUBLISHED" }
$NextSteps = if ($Draft) {
    "1. Review the draft release
  2. Edit release notes if needed
  3. Publish the release when ready"
} else {
    "1. Test installation on a clean Windows machine
  2. Share release URL with users
  3. Update documentation with new version"
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green
Write-Host "Installer Published Successfully!" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Release: $TAG" -ForegroundColor Cyan
Write-Host "Repository: $PUBLIC_REPO" -ForegroundColor Cyan
Write-Host "Status: $StatusText" -ForegroundColor Cyan
Write-Host ""
Write-Host "RELEASE URL:" -ForegroundColor Yellow
Write-Host "  $ReleaseUrl" -ForegroundColor White
Write-Host ""
Write-Host "USER INSTALLATION:" -ForegroundColor Yellow
Write-Host "  Download: $ReleaseUrl" -ForegroundColor White
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  $NextSteps" -ForegroundColor White
Write-Host ""
Write-Host "================================================================================" -ForegroundColor Green

