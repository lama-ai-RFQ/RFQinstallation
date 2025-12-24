# RFQ Application - Windows Installation Script
# Downloads and installs the RFQ application from GitHub releases
# This script is for first-time installation only

param(
    [string]$InstallPath = "$env:LOCALAPPDATA\RFQApplication",
    [string]$GitHubToken = "",
    [switch]$Help,
    [switch]$OverwriteExisting,
    [string]$ModelPath = "",
    [switch]$SkipModelDownload,
    [string]$AWSKey = "",
    [string]$AWSSecret = "",
    [string]$AWSRegion = "us-east-1",
    [string]$SettingsPassword = "",
    [string]$SuperUserPassword = "",
    [string]$RFQUserPassword = "",
    # Base64 encoded password parameters (for special character handling)
    [string]$SettingsPasswordB64 = "",
    [string]$SuperUserPasswordB64 = "",
    [string]$RFQUserPasswordB64 = "",
    [string]$AWSSecretB64 = "",
    [string]$ServerURL = "https://localhost",
    [switch]$AzureKeyGenerate,
    [string]$AzureKeyCustom = "",
    [switch]$CleanReinstall,
    [switch]$CleanupAfterInstall,
    [string]$UpdateChannel = "customer"
)

# Set error action preference to continue so we can handle errors gracefully
$ErrorActionPreference = "Continue"

# Decode Base64 passwords if provided (handles special characters like ^, %, !, ", etc.)
function Decode-Base64Password {
    param([string]$Base64String)
    if ([string]::IsNullOrEmpty($Base64String)) {
        return ""
    }
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64String))
    }
    catch {
        Write-Warning "Failed to decode Base64 password: $_"
        return ""
    }
}

# Use Base64 passwords if provided, otherwise fall back to plain text parameters
if (-not [string]::IsNullOrEmpty($SettingsPasswordB64)) {
    $SettingsPassword = Decode-Base64Password $SettingsPasswordB64
}
if (-not [string]::IsNullOrEmpty($SuperUserPasswordB64)) {
    $SuperUserPassword = Decode-Base64Password $SuperUserPasswordB64
}
if (-not [string]::IsNullOrEmpty($RFQUserPasswordB64)) {
    $RFQUserPassword = Decode-Base64Password $RFQUserPasswordB64
}
if (-not [string]::IsNullOrEmpty($AWSSecretB64)) {
    $AWSSecret = Decode-Base64Password $AWSSecretB64
}

# Setup log file - use temp directory initially until installation directory is created
$LogTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TempLogFile = Join-Path $env:TEMP "rfq_installer_$LogTimestamp.log"
$script:LogFile = $TempLogFile
$script:LogFileInitialized = $false

# Function to write to both console and log file
function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    
    # Write to console with color
    Write-Host $Message -ForegroundColor $Color
    
    # Write to log file with timestamp
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] $Message"
        Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Silently ignore log file errors to not interrupt installation
    }
}

# Show immediate output to confirm script is running
Write-Log "Script started..." "Green"
Write-Log "Working directory: $PWD" "Cyan"
Write-Log "Script path: $PSCommandPath" "Cyan"
Write-Log "Log file: $script:LogFile" "Cyan"

# Trap all terminating errors to ensure we always show "Press any key"
trap {
    Write-Log "" "Red"
    Write-Log "================================================================================" "Red"
    Write-Log "CRITICAL ERROR" "Red"
    Write-Log "================================================================================" "Red"
    Write-Log "An unexpected error occurred:" "Red"
    Write-Log $_.Exception.Message "Red"
    Write-Log "" "Red"
    Write-Log "Error details:" "Yellow"
    Write-Log $_.InvocationInfo.PositionMessage "Yellow"
    Write-Log "" "Red"
    Write-Log "Log file saved to: $script:LogFile" "Cyan"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# TEMPORARILY DISABLE STEPS - Set to $true to enable
$ENABLE_STEP_6_DOWNLOAD = $true  # Step 6: Downloading installation components
$ENABLE_STEP_7_EXTRACT = $true   # Step 7: Extracting installation files

# Track skipped steps for final summary
$script:SkippedSteps = @()

# Colors for output - now writes to both console and log file
function Write-Info { 
    $message = $args -join " "
    Write-Log $message "Cyan"
}
function Write-Success { 
    $message = $args -join " "
    Write-Log $message "Green"
}
function Write-Warning { 
    $message = $args -join " "
    Write-Log $message "Yellow"
}
function Write-Error-Custom { 
    $message = $args -join " "
    Write-Log $message "Red"
}

# Exit with error and pause
function Exit-WithError {
    Write-Log "" "Red"
    Write-Log "Installation failed. Log file saved to: $script:LogFile" "Yellow"
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

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
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

# Banner
$BannerText = @"
================================================================================
    RFQ Application - Windows Installer
    First-Time Installation Script
================================================================================
"@
Write-Log $BannerText "Cyan"

# Configuration - Determine repository based on update channel
if ($UpdateChannel -eq "internal") {
    $GITHUB_REPO = "lama-ai-RFQ/RFQwindowspackages-internal"
    Write-Info "Using INTERNAL update channel: $GITHUB_REPO"
}
else {
    $GITHUB_REPO = "lama-ai-RFQ/RFQwindowspackages"
    Write-Info "Using CUSTOMER update channel: $GITHUB_REPO"
}
$GITHUB_API = "https://api.github.com/repos"

# Check PowerShell version
Write-Info "`n[1/8] Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error-Custom "ERROR: PowerShell 5.1 or later is required"
    Write-Error-Custom "Current version: $($PSVersionTable.PSVersion)"
    Exit-WithError
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
    if ($continue -notmatch '^[yY](es)?$') {
        Exit-WithError
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
        Exit-WithError
    }
}
else {
    Write-Warning "[!] Directory already exists: $InstallPath"
    if ($OverwriteExisting) {
        Write-Info "  Overwriting existing installation (as requested by installer)..."
    }
    else {
        $overwrite = Read-Host "Overwrite existing installation? (y/N)"
        if ($overwrite -notmatch '^[yY](es)?$') {
            Exit-WithError
        }
    }
}

# Move log file to installation directory now that it exists
if (Test-Path $InstallPath) {
    try {
        $NewLogFile = Join-Path $InstallPath "installer_$LogTimestamp.log"
        # Copy existing log content to new location
        if (Test-Path $script:LogFile) {
            Copy-Item -Path $script:LogFile -Destination $NewLogFile -Force -ErrorAction SilentlyContinue
        }
        # Update log file path
        $script:LogFile = $NewLogFile
        $script:LogFileInitialized = $true
        Write-Info "  Log file moved to: $NewLogFile"
    }
    catch {
        # If moving fails, continue using temp log file
        Write-Info "  Continuing to use temp log file: $script:LogFile"
    }
}

# Setup GitHub authentication
Write-Info "`n[4/8] Checking authentication..."

if (!$GitHubToken) {
    Write-Log "" "Yellow"
    Write-Log "GitHub Personal Access Token Required" "Yellow"
    Write-Log "=====================================" "Yellow"
    Write-Log "" "Yellow"
    Write-Log "The installation package is in a private repository and requires authentication." "White"
    Write-Log "" "White"
    Write-Log "If you don't have a token yet:" "Cyan"
    Write-Log "  1. Go to: https://github.com/settings/tokens" "White"
    Write-Log "  2. Click 'Generate new token (classic)'" "White"
    Write-Log "  3. Select scope: repo (Full control of private repositories)" "White"
    Write-Log "  4. Generate and copy the token" "White"
    Write-Log "" "White"
    
    $GitHubToken = Read-Host "Please enter your GitHub Personal Access Token (ghp_...)"
    Write-Log "GitHub token entered by user" "Cyan"
    
    if (!$GitHubToken -or $GitHubToken.Trim() -eq "") {
        Write-Error-Custom "`nERROR: GitHub token is required to continue"
        Exit-WithError
    }
    
    Write-Log "" "White"
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
    $StatusCode = $_.Exception.Response.StatusCode.value__
    
    Write-Error-Custom "ERROR: Failed to fetch release information"
    Write-Error-Custom ""
    
    # Provide specific error messages based on HTTP status code
    if ($StatusCode -eq 401) {
        Write-Error-Custom "  → Authentication Failed (401 Unauthorized)"
        Write-Error-Custom ""
        Write-Error-Custom "  Your GitHub Personal Access Token is invalid or expired."
        Write-Error-Custom ""
        Write-Error-Custom "  Please check:"
        Write-Error-Custom "    1. Token is correctly copied (should start with 'ghp_')"
        Write-Error-Custom "    2. Token hasn't expired (check: https://github.com/settings/tokens)"
        Write-Error-Custom "    3. Token hasn't been revoked"
        Write-Error-Custom ""
        Write-Error-Custom "  To create a new token:"
        Write-Error-Custom "    → Go to: https://github.com/settings/tokens"
        Write-Error-Custom "    → Generate new token (classic)"
        Write-Error-Custom "    → Select scope: repo (Full control of private repositories)"
    }
    elseif ($StatusCode -eq 403) {
        Write-Error-Custom "  → Access Forbidden (403 Forbidden)"
        Write-Error-Custom ""
        Write-Error-Custom "  Your token doesn't have permission to access this repository."
        Write-Error-Custom ""
        Write-Error-Custom "  Please check:"
        Write-Error-Custom "    1. Token has 'repo' scope enabled"
        Write-Error-Custom "    2. You have access to: https://github.com/$GITHUB_REPO"
        Write-Error-Custom "    3. The repository owner has granted you access"
        Write-Error-Custom ""
        Write-Error-Custom "  Contact the repository owner if you need access."
    }
    elseif ($StatusCode -eq 404) {
        Write-Error-Custom "  → Repository Not Found (404 Not Found)"
        Write-Error-Custom ""
        Write-Error-Custom "  The repository doesn't exist or you don't have access to it."
        Write-Error-Custom ""
        Write-Error-Custom "  Repository: https://github.com/$GITHUB_REPO"
        Write-Error-Custom ""
        Write-Error-Custom "  Please verify:"
        Write-Error-Custom "    1. The repository exists"
        Write-Error-Custom "    2. The repository name is spelled correctly"
        Write-Error-Custom "    3. Your token has access to the repository"
    }
    else {
        Write-Error-Custom "  General error occurred:"
        Write-Error-Custom "  $($_.Exception.Message)"
        Write-Error-Custom ""
        Write-Error-Custom "  Please check:"
        Write-Error-Custom "    1. Internet connection is working"
        Write-Error-Custom "    2. GitHub is accessible (https://www.githubstatus.com/)"
        Write-Error-Custom "    3. Repository exists: https://github.com/$GITHUB_REPO"
    }
    
    Exit-WithError
}

# Download component-based installation package
if ($ENABLE_STEP_6_DOWNLOAD) {
    Write-Info "`n[6/8] Downloading installation components..."
    Write-Info "  This may take several minutes depending on your internet connection."
    Write-Info "  Progress will be shown below for each file..."
    Write-Log "" "White"

    # Check for manifest.json (component-based release)
    $ManifestAsset = $Release.assets | Where-Object { $_.name -eq "manifest.json" } | Select-Object -First 1

    if (!$ManifestAsset) {
        Write-Error-Custom "ERROR: No manifest.json found in release"
        Write-Error-Custom "  This installer requires a component-based release"
        Write-Error-Custom "  Available assets:"
        foreach ($asset in $Release.assets) {
            Write-Error-Custom "    - $($asset.name)"
        }
        Exit-WithError
    }

    # Download manifest
    Write-Info "  Downloading manifest..."
    $ManifestPath = Join-Path $env:TEMP "manifest.json"
    try {
        $DownloadHeaders = $Headers.Clone()
        $DownloadHeaders["Accept"] = "application/octet-stream"
        
        # Show progress for manifest download
        Write-Info "    Downloading from: $($ManifestAsset.url)"
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $ManifestAsset.url -OutFile $ManifestPath -Headers $DownloadHeaders -UseBasicParsing
        
        $Manifest = Get-Content $ManifestPath | ConvertFrom-Json
        Write-Success "[OK] Downloaded manifest"
    }
    catch {
        Write-Error-Custom "ERROR: Failed to download manifest: $_"
        Exit-WithError
    }

    # Create temp directory for downloads
    $TempDownloadDir = Join-Path $env:TEMP "rfq_install_temp"
    
    if ($CleanReinstall) {
        # Clean reinstall: delete existing downloads
        if (Test-Path $TempDownloadDir) {
            Write-Info "  Cleaning existing downloads (clean reinstall requested)..."
            Remove-Item $TempDownloadDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $TempDownloadDir -Force | Out-Null
    } else {
        # Reuse existing downloads if available
        # Check if temp directory exists and has files
        $hasExistingDownloads = $false
        if (Test-Path $TempDownloadDir) {
            $existingFiles = Get-ChildItem -Path $TempDownloadDir -File -ErrorAction SilentlyContinue
            if ($existingFiles -and $existingFiles.Count -gt 0) {
                $hasExistingDownloads = $true
                Write-Info "  Found existing downloads in temp directory"
                Write-Info "  Existing files will be reused if they match expected sizes"
            }
        }
        
        # Only create directory if it doesn't exist (preserve existing downloads)
        if (!(Test-Path $TempDownloadDir)) {
            New-Item -ItemType Directory -Path $TempDownloadDir -Force | Out-Null
        } else {
            Write-Info "  Reusing existing downloads from previous installation attempt..."
        }
    }

    # Helper function to get a release by tag
    function Get-ReleaseByTag {
        param([string]$Tag)
        try {
            $ReleaseUrl = "$GITHUB_API/$GITHUB_REPO/releases/tags/$Tag"
            $Release = Invoke-RestMethod -Uri $ReleaseUrl -Headers $Headers -ErrorAction Stop
            return $Release
        }
        catch {
            return $null
        }
    }

    # Helper function to get all releases (cached)
    $script:AllReleasesCache = $null
    function Get-AllReleases {
        if ($null -eq $script:AllReleasesCache) {
            try {
                $ReleasesUrl = "$GITHUB_API/$GITHUB_REPO/releases?per_page=100"
                $script:AllReleasesCache = Invoke-RestMethod -Uri $ReleasesUrl -Headers $Headers -ErrorAction Stop
                # Sort by published_at descending (newest first)
                # Filter out releases with invalid or null published_at, then sort
                $script:AllReleasesCache = $script:AllReleasesCache | Where-Object {
                    $_.published_at -and $_.published_at -ne ""
                } | Sort-Object {
                    try {
                        [DateTime]::Parse($_.published_at)
                    }
                    catch {
                        # If parsing fails, use a very old date so these releases appear last
                        [DateTime]::MinValue
                    }
                } -Descending
            }
            catch {
                Write-Warning "    Warning: Could not fetch all releases: $_"
                $script:AllReleasesCache = @()
            }
        }
        return $script:AllReleasesCache
    }

    # Helper function to find asset in a release
    function Find-AssetInRelease {
        param(
            [object]$ReleaseObj,
            [string]$Filename
        )
        if (!$ReleaseObj -or !$ReleaseObj.assets) {
            return $null
        }
        return $ReleaseObj.assets | Where-Object { $_.name -eq $Filename } | Select-Object -First 1
    }

    # Download all component files
    $Components = $Manifest.components.PSObject.Properties
    $TotalComponents = $Components.Count
    $CurrentComponent = 0

    foreach ($ComponentProp in $Components) {
        $CurrentComponent++
        $ComponentName = $ComponentProp.Name
        $ComponentInfo = $ComponentProp.Value
        
        # Check if component has any files
        if (!$ComponentInfo.files -or $ComponentInfo.files.Count -eq 0) {
            Write-Warning "  [$CurrentComponent/$TotalComponents] Skipping $ComponentName (no files in component)"
            continue
        }
        
        Write-Info "  [$CurrentComponent/$TotalComponents] Downloading: $ComponentName"
        
        $filesDownloaded = 0
        foreach ($FileInfo in $ComponentInfo.files) {
            $Filename = $FileInfo.filename
            
            # The manifest tells us which release contains each component via minimum_versions
            # Check that release first (it may be current or a previous release)
            $Asset = $null
            $SourceTag = $Version
            
            # First, check the version specified in minimum_versions (this is where the manifest says the files are)
            if ($Manifest.minimum_versions -and $Manifest.minimum_versions.$ComponentName) {
                $ComponentVersion = $Manifest.minimum_versions.$ComponentName
                
                if ($ComponentVersion -eq $Version) {
                    # Component is in current release, check current release
                    $Asset = Find-AssetInRelease -ReleaseObj $Release -Filename $Filename
                    if ($Asset) {
                        Write-Info "    Found in current release: $Version"
                    }
                } else {
                    # Component is in a previous release according to manifest
                    Write-Info "    Component specified in manifest for release: $ComponentVersion (checking that release first)"
                    $ComponentRelease = Get-ReleaseByTag -Tag $ComponentVersion
                    if ($ComponentRelease) {
                        $Asset = Find-AssetInRelease -ReleaseObj $ComponentRelease -Filename $Filename
                        if ($Asset) {
                            $SourceTag = $ComponentVersion
                            Write-Info "    Found in release specified by manifest: $ComponentVersion"
                        } else {
                            Write-Warning "    File not found in release specified by manifest ($ComponentVersion), searching other releases..."
                        }
                    } else {
                        Write-Warning "    Release specified by manifest ($ComponentVersion) not found, searching other releases..."
                    }
                }
            } else {
                # No minimum_versions specified, check current release first
                $Asset = Find-AssetInRelease -ReleaseObj $Release -Filename $Filename
                if ($Asset) {
                    Write-Info "    Found in current release: $Version"
                }
            }
            
            # If still not found, iterate through all previous releases as fallback
            if (!$Asset) {
                Write-Info "    Searching all previous releases..."
                $AllReleases = Get-AllReleases
                foreach ($PreviousRelease in $AllReleases) {
                    # Skip current release
                    if ($PreviousRelease.tag_name -eq $Version) {
                        continue
                    }
                    
                    # Skip the version from minimum_versions if we already checked it
                    if ($Manifest.minimum_versions -and $Manifest.minimum_versions.$ComponentName -and 
                        $PreviousRelease.tag_name -eq $Manifest.minimum_versions.$ComponentName) {
                        continue
                    }
                    
                    $Asset = Find-AssetInRelease -ReleaseObj $PreviousRelease -Filename $Filename
                    if ($Asset) {
                        $SourceTag = $PreviousRelease.tag_name
                        Write-Info "    Found in previous release: $($PreviousRelease.tag_name)"
                        break
                    }
                }
            }
            
            if (!$Asset) {
                Write-Warning "  [!] Asset not found: $Filename (checked current and all previous releases, skipping)"
                continue
            }
            
            # Download file (check if already exists with correct size first, unless clean reinstall)
            $FilePath = Join-Path $TempDownloadDir $Filename
            $FileSizeMB = [math]::Round($Asset.size / 1MB, 2)
            $ExpectedSize = $Asset.size
            
            # Clean reinstall: delete existing file even if size matches
            if ($CleanReinstall -and (Test-Path $FilePath)) {
                Write-Info "    Clean reinstall: removing existing file $Filename..."
                Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
            }
            
            try {
                # Create fresh headers hashtable for download
                $DownloadHeaders = @{
                    "Accept" = "application/octet-stream"
                    "Authorization" = $Headers["Authorization"]
                }
                
                # Check for existing download - skip if file exists and size matches (only if not clean reinstall)
                if (!$CleanReinstall -and (Test-Path $FilePath)) {
                    $existingSize = (Get-Item $FilePath).Length
                    if ($existingSize -eq $ExpectedSize) {
                        Write-Success "    [SKIP] Already downloaded: $Filename (size matches, skipping download)"
                        $filesDownloaded++
                        continue
                    } else {
                        # File exists but size doesn't match (partial or wrong size) - remove and re-download
                        if ($existingSize -gt 0 -and $existingSize -lt $ExpectedSize) {
                            Write-Info "    Partial file found ($([math]::Round($existingSize / 1MB, 2)) MB), removing and downloading fresh copy..."
                        } elseif ($existingSize -gt $ExpectedSize) {
                            Write-Warning "    Existing file is larger than expected ($([math]::Round($existingSize / 1MB, 2)) MB vs $([math]::Round($ExpectedSize / 1MB, 2)) MB)"
                            Write-Info "    Removing existing file and downloading fresh copy..."
                        }
                        Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
                    }
                }
                
                # Show file size and progress
                if ($SourceTag -ne $Version) {
                    Write-Info "    Downloading: $Filename ($FileSizeMB MB) from release $SourceTag..."
                } else {
                    Write-Info "    Downloading: $Filename ($FileSizeMB MB)..."
                }
                
                # Show progress bar during download
                $ProgressPreference = 'Continue'
                
                # Full download
                Invoke-WebRequest -Uri $Asset.url -OutFile $FilePath -Headers $DownloadHeaders -UseBasicParsing
                
                # Verify downloaded file size matches expected size
                $DownloadedFile = Get-Item $FilePath
                if ($DownloadedFile.Length -ne $ExpectedSize) {
                    Write-Warning "    [!] Downloaded file size mismatch: $($DownloadedFile.Length) vs expected $ExpectedSize bytes"
                    Write-Warning "    [!] File may be corrupted, will be re-downloaded on next run"
                } else {
                    if ($SourceTag -ne $Version) {
                        Write-Success "    [OK] Downloaded: $Filename from release $SourceTag"
                    } else {
                        Write-Success "    [OK] Downloaded: $Filename"
                    }
                }
                $filesDownloaded++
            }
            catch {
                Write-Warning "  [!] Failed to download $Filename : $_ (skipping)"
                continue
            }
        }
        
        if ($filesDownloaded -eq 0) {
            Write-Warning "  [!] No files downloaded for $ComponentName (component may be empty)"
        }
    }

    Write-Success "[OK] All components downloaded"
}
else {
    Write-Info ""
    Write-Info "Step 6 (Downloading installation components) is disabled."
    Write-Info "Skipping component download..."
    $script:SkippedSteps += "Component download (Step 6 disabled)"
    
    # Still need to create the install directory if it doesn't exist
    if (!(Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-Success "[OK] Created installation directory: $InstallPath"
    }
}

# Rejoin multi-part files and extract
if ($ENABLE_STEP_7_EXTRACT) {
    if (-not $ENABLE_STEP_6_DOWNLOAD) {
        Write-Info ""
        Write-Info "Step 7 (Extracting installation files) requires Step 6 (Download) to be enabled."
        Write-Info "Skipping extraction..."
        $script:SkippedSteps += "File extraction (Step 6 disabled)"
    }
    else {
        Write-Info "`n[7/8] Extracting installation files..."

        # Stop Windows service if it exists
        Write-Info "  Checking for Windows service..."
        try {
            $ServiceName = "RFQapplication"
            $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            
            if ($service) {
                if ($service.Status -eq 'Running') {
                    Write-Info "  Stopping Windows service '$ServiceName'..."
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                    Write-Success "  [OK] Stopped Windows service"
                    Start-Sleep -Seconds 2
                }
                else {
                    Write-Info "  Windows service '$ServiceName' is not running"
                }
            }
            else {
                Write-Info "  Windows service not found (first-time install or not created yet)"
            }
        }
        catch {
            Write-Warning "  [!] Could not stop Windows service: $_"
            Write-Info "  Continuing with extraction anyway..."
        }
        
        # Force close any running processes from the installation directory
        Write-Info "  Checking for running processes in installation directory..."
        try {
            # Get all executable files in the installation directory
            $executableFiles = Get-ChildItem -Path $InstallPath -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue
            
            if ($executableFiles) {
                $processesToKill = @()
                
                foreach ($exeFile in $executableFiles) {
                    $exeName = $exeFile.Name
                    $processName = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
                    
                    # Find running processes with this name
                    $runningProcesses = Get-Process -Name $processName -ErrorAction SilentlyContinue
                    
                    foreach ($process in $runningProcesses) {
                        # Check if the process path matches the installation directory
                        try {
                            $processPath = $process.Path
                            if ($processPath -and $processPath.StartsWith($InstallPath, [StringComparison]::OrdinalIgnoreCase)) {
                                $processesToKill += $process
                            }
                        }
                        catch {
                            # Some processes may not allow access to their path - skip them
                            continue
                        }
                    }
                }
                
                if ($processesToKill.Count -gt 0) {
                    Write-Warning "  Found $($processesToKill.Count) running process(es) from installation directory"
                    Write-Info "  Stopping processes to allow extraction..."
                    
                    foreach ($process in $processesToKill) {
                        try {
                            Write-Info "    Stopping process: $($process.Name) (PID: $($process.Id))"
                            Stop-Process -Id $process.Id -Force -ErrorAction Stop
                            Write-Success "    [OK] Stopped: $($process.Name)"
                        }
                        catch {
                            Write-Warning "    [!] Could not stop process $($process.Name): $_"
                        }
                    }
                    
                    # Wait a moment for processes to fully terminate
                    Write-Info "  Waiting for processes to terminate..."
                    Start-Sleep -Seconds 2
                    
                    Write-Success "  [OK] All processes stopped"
                }
                else {
                    Write-Info "  No running processes found in installation directory"
                }
            }
            else {
                Write-Info "  No executable files found in installation directory (first-time install)"
            }
        }
        catch {
            Write-Warning "  [!] Error checking for running processes: $_"
            Write-Info "  Continuing with extraction anyway..."
        }

        foreach ($ComponentProp in $Components) {
            $ComponentName = $ComponentProp.Name
            $ComponentInfo = $ComponentProp.Value
            $Files = $ComponentInfo.files
            
            # Skip components with no files
            if (!$Files -or $Files.Count -eq 0) {
                Write-Info "  Skipping $ComponentName (no files to extract)"
                continue
            }
            
            # Check if any files were actually downloaded
            $hasDownloadedFiles = $false
            foreach ($FileInfo in $Files) {
                $Filename = $FileInfo.filename
                $FilePath = Join-Path $TempDownloadDir $Filename
                if (Test-Path $FilePath) {
                    $hasDownloadedFiles = $true
                    break
                }
            }
            
            if (!$hasDownloadedFiles) {
                Write-Info "  Skipping $ComponentName (no files downloaded)"
                continue
            }
            
            Write-Info "  Extracting: $ComponentName"
            
            if ($Files.Count -eq 1) {
                # Single file, extract directly
                $ComponentZip = Join-Path $TempDownloadDir $Files[0].filename
                
                # Check if file exists (may have been skipped if empty)
                if (!(Test-Path $ComponentZip)) {
                    Write-Info "    Skipping extraction (file not downloaded - component may be empty)"
                    continue
                }
            }
            else {
                # Multi-part, rejoin first
                Write-Info "    Rejoining $($Files.Count) parts..."
                
                # Sort by part number
                $PartFiles = $Files | Sort-Object { [int]($_.filename -replace '.*\.part(\d+)', '$1') }
                
                # Check if all parts exist
                $allPartsExist = $true
                foreach ($PartFile in $PartFiles) {
                    $PartPath = Join-Path $TempDownloadDir $PartFile.filename
                    if (!(Test-Path $PartPath)) {
                        $allPartsExist = $false
                        break
                    }
                }
                
                if (!$allPartsExist) {
                    Write-Info "    Skipping extraction (some parts not downloaded - component may be empty)"
                    continue
                }
                
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
                    $OutputFile.Flush()
                }
                finally {
                    $OutputFile.Close()
                }
                
                # Verify the rejoined file exists and has content
                Start-Sleep -Milliseconds 100  # Give filesystem time to sync
                if (!(Test-Path $ComponentZip)) {
                    Write-Error-Custom "ERROR: Failed to rejoin parts - output file not found"
                    Exit-WithError
                }
                $fileSize = (Get-Item $ComponentZip).Length
                if ($fileSize -eq 0) {
                    Write-Error-Custom "ERROR: Rejoined file is empty"
                    Exit-WithError
                }
                Write-Info "    Rejoined file size: $([math]::Round($fileSize / 1MB, 2)) MB"
            }
            

            # Extract component
            try {
                # Extract to a temp location first to check for unwanted nested paths
                $TempExtractDir = Join-Path $env:TEMP "rfq_extract_$ComponentName"
                if (Test-Path $TempExtractDir) {
                    Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
                
                # Try multiple extraction methods
                $extractionSuccess = $false
                $extractionError = ""
                
                # Method 1: Try 7-Zip (best for split archives)
                $sevenZipPath = $null
                $sevenZipLocations = @(
                    "C:\Program Files\7-Zip\7z.exe",
                    "C:\Program Files (x86)\7-Zip\7z.exe",
                    "$env:ProgramFiles\7-Zip\7z.exe",
                    "$env:ProgramFiles(x86)\7-Zip\7z.exe"
                )
                
                # Check common locations
                foreach ($location in $sevenZipLocations) {
                    if (Test-Path $location) {
                        $sevenZipPath = $location
                        break
                    }
                }
                
                # Check PATH if not found in common locations
                if (-not $sevenZipPath) {
                    $sevenZipCmd = Get-Command 7z -ErrorAction SilentlyContinue
                    if ($sevenZipCmd) {
                        $sevenZipPath = $sevenZipCmd.Path
                    }
                }
                
                if ($sevenZipPath) {
                    Write-Info "    Using 7-Zip to extract..."
                    try {
                        # 7-Zip output format: -o"path" (no space, path can have quotes)
                        $outputArg = "-o`"$TempExtractDir`""
                        $process = Start-Process -FilePath $sevenZipPath -ArgumentList "x", "`"$ComponentZip`"", $outputArg, "-y" -Wait -PassThru -NoNewWindow
                        if ($process.ExitCode -eq 0) {
                            $extractionSuccess = $true
                            Write-Success "    [OK] Extracted using 7-Zip"
                        } else {
                            $extractionError += "7-Zip returned exit code: $($process.ExitCode). "
                            Write-Warning "    7-Zip returned exit code: $($process.ExitCode)"
                        }
                    }
                    catch {
                        $extractionError += "7-Zip extraction failed: $_. "
                        Write-Warning "    7-Zip extraction failed: $_"
                    }
                } else {
                    $extractionError += "7-Zip not found. "
                }
                
                # Method 2: Try Python zipfile (if 7-Zip failed or not available)
                if (-not $extractionSuccess) {
                    $pythonFound = Get-Command python -ErrorAction SilentlyContinue
                    if ($pythonFound) {
                        Write-Info "    Using Python zipfile to extract..."
                        try {
                            $extractScript = Join-Path $env:TEMP "extract_zip_$ComponentName.py"
                            $scriptContent = @"
import zipfile
import sys
import os

zip_path = r"$ComponentZip"
extract_to = r"$TempExtractDir"

try:
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        zip_ref.extractall(extract_to)
    print("SUCCESS")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
"@
                            Set-Content -Path $extractScript -Value $scriptContent -Encoding UTF8
                            $output = python $extractScript 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $extractionSuccess = $true
                                Write-Success "    [OK] Extracted using Python"
                            } else {
                                $extractionError += "Python extraction failed: $output. "
                                Write-Warning "    Python extraction failed: $output"
                            }
                            Remove-Item $extractScript -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            $extractionError += "Python extraction error: $_. "
                            Write-Warning "    Python extraction error: $_"
                        }
                    } else {
                        $extractionError += "Python not found. "
                    }
                }
                
                # Method 3: Try Windows tar.exe (built-in on Windows 10/11 1803+)
                if (-not $extractionSuccess) {
                    $tarFound = Get-Command tar -ErrorAction SilentlyContinue
                    if ($tarFound) {
                        Write-Info "    Using Windows tar.exe to extract..."
                        try {
                            # tar.exe can extract zip files on Windows 10/11
                            # Use -C to change directory, xf to extract
                            $tarArgs = @("xf", $ComponentZip, "-C", $TempExtractDir)
                            $process = Start-Process -FilePath "tar" -ArgumentList $tarArgs -Wait -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\tar_error_$ComponentName.txt"
                            if ($process.ExitCode -eq 0) {
                                # Verify extraction actually worked
                                $extractedFiles = Get-ChildItem -Path $TempExtractDir -Recurse -ErrorAction SilentlyContinue
                                if ($extractedFiles -and $extractedFiles.Count -gt 0) {
                                    $extractionSuccess = $true
                                    Write-Success "    [OK] Extracted using Windows tar.exe"
                                } else {
                                    throw "Extraction completed but no files were found in destination"
                                }
                            } else {
                                $tarError = Get-Content "$env:TEMP\tar_error_$ComponentName.txt" -ErrorAction SilentlyContinue
                                if ($tarError) {
                                    throw "tar.exe returned exit code: $($process.ExitCode). Error: $tarError"
                                } else {
                                    throw "tar.exe returned exit code: $($process.ExitCode)"
                                }
                            }
                            Remove-Item "$env:TEMP\tar_error_$ComponentName.txt" -Force -ErrorAction SilentlyContinue
                        }
                        catch {
                            $extractionError += "Windows tar.exe failed: $_. "
                            Write-Warning "    Windows tar.exe extraction failed: $_"
                            Remove-Item "$env:TEMP\tar_error_$ComponentName.txt" -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        $extractionError += "Windows tar.exe not found. "
                    }
                }
                
                # Method 4: Try .NET System.IO.Compression (always available in PowerShell)
                if (-not $extractionSuccess) {
                    Write-Info "    Using .NET System.IO.Compression to extract..."
                    try {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        # .NET ExtractToDirectory requires the destination to not exist, so ensure it's clean
                        if (Test-Path $TempExtractDir) {
                            Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($ComponentZip, $TempExtractDir)
                        # Verify extraction actually worked
                        $extractedFiles = Get-ChildItem -Path $TempExtractDir -Recurse -ErrorAction SilentlyContinue
                        if ($extractedFiles -and $extractedFiles.Count -gt 0) {
                            $extractionSuccess = $true
                            Write-Success "    [OK] Extracted using .NET Compression"
                        } else {
                            throw "Extraction completed but no files were found in destination"
                        }
                    }
                    catch {
                        $extractionError += ".NET Compression failed: $_. "
                        Write-Warning "    .NET Compression extraction failed: $_"
                    }
                }
                
                # Method 5: Try PowerShell Expand-Archive (last resort)
                if (-not $extractionSuccess) {
                    Write-Info "    Using PowerShell Expand-Archive to extract..."
                    try {
                        Expand-Archive -Path $ComponentZip -DestinationPath $TempExtractDir -Force -ErrorAction Stop
                        # Verify extraction actually worked by checking if files were extracted
                        $extractedFiles = Get-ChildItem -Path $TempExtractDir -Recurse -ErrorAction SilentlyContinue
                        if ($extractedFiles -and $extractedFiles.Count -gt 0) {
                            $extractionSuccess = $true
                            Write-Success "    [OK] Extracted using PowerShell Expand-Archive"
                        } else {
                            throw "Extraction completed but no files were found in destination"
                        }
                    }
                    catch {
                        $extractionError += "PowerShell Expand-Archive failed: $_. "
                        # Don't exit here - we'll show comprehensive error at the end
                        Write-Warning "    PowerShell Expand-Archive failed: $_"
                    }
                }
                
                if (-not $extractionSuccess) {
                    Write-Error-Custom "ERROR: Failed to extract archive using any method"
                    Write-Error-Custom ""
                    Write-Error-Custom "Extraction tool status:"
                    if ($sevenZipPath) {
                        Write-Error-Custom "  7-Zip: Found at $sevenZipPath, but extraction failed"
                    } else {
                        Write-Error-Custom "  7-Zip: Not found (not installed or not in PATH)"
                    }
                    $pythonFound = Get-Command python -ErrorAction SilentlyContinue
                    if ($pythonFound) {
                        Write-Error-Custom "  Python: Found at $($pythonFound.Path), but extraction failed"
                    } else {
                        Write-Error-Custom "  Python: Not found (not installed or not in PATH)"
                    }
                    $tarFound = Get-Command tar -ErrorAction SilentlyContinue
                    if ($tarFound) {
                        Write-Error-Custom "  Windows tar.exe: Found at $($tarFound.Path), but extraction failed"
                    } else {
                        Write-Error-Custom "  Windows tar.exe: Not found (Windows 10/11 1803+ required)"
                    }
                    Write-Error-Custom "  .NET Compression: Available but extraction failed"
                    Write-Error-Custom "  PowerShell Expand-Archive: Available but extraction failed"
                    Write-Error-Custom ""
                    Write-Error-Custom "Error details: $extractionError"
                    Write-Error-Custom ""
                    Write-Error-Custom "Please install 7-Zip from https://www.7-zip.org/ and try again"
                    Write-Error-Custom "Or install Python and ensure it's in your PATH"
                    Exit-WithError
                }
                
                # Check if there's an unwanted nested directory structure
                # Look for expected files (RFQ_Application.exe or _internal directory) at the root
                $rootExe = Get-ChildItem -Path $TempExtractDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                $rootInternal = Test-Path (Join-Path $TempExtractDir "_internal")
                
                if (-not $rootExe -and -not $rootInternal) {
                    # Files are nested, find the actual content directory
                    Write-Info "    Detected nested directory structure, flattening..."
                    $contentDir = $null
                    
                    # Search for directory containing .exe or _internal
                    $allDirs = Get-ChildItem -Path $TempExtractDir -Recurse -Directory
                    foreach ($dir in $allDirs) {
                        $hasExe = Get-ChildItem -Path $dir.FullName -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                        $hasInternal = Test-Path (Join-Path $dir.FullName "_internal")
                        if ($hasExe -or $hasInternal) {
                            $contentDir = $dir.FullName
                            break
                        }
                    }
                    
                    if ($contentDir) {
                        # Move content from nested directory to root
                        Get-ChildItem -Path $contentDir | Move-Item -Destination $TempExtractDir -Force
                        # Remove empty nested directories
                        $parentDir = Split-Path $contentDir -Parent
                        while ($parentDir -and $parentDir -ne $TempExtractDir) {
                            if ((Get-ChildItem -Path $parentDir -ErrorAction SilentlyContinue).Count -eq 0) {
                                Remove-Item $parentDir -Force -ErrorAction SilentlyContinue
                            }
                            $parentDir = Split-Path $parentDir -Parent
                        }
                    }
                }
                
                # Copy all files from temp to install path
                Get-ChildItem -Path $TempExtractDir | Copy-Item -Destination $InstallPath -Recurse -Force
                
                # Cleanup temp directory
                Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Error-Custom "ERROR: Failed to extract $ComponentName : $_"
                Exit-WithError
            }
        }

        Write-Success "[OK] Extracted all components to: $InstallPath"

        # Save manifest to installation directory as local_manifest.json
        # This allows the update manager to know what was installed
        if ($Manifest) {
            Write-Info "  Saving manifest to installation directory..."
            $LocalManifestPath = Join-Path $InstallPath "local_manifest.json"
            try {
                $Manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $LocalManifestPath -Encoding UTF8 -Force
                Write-Success "  [OK] Saved local manifest: $LocalManifestPath"
            }
            catch {
                Write-Warning "  [!] Failed to save local manifest: $_"
                # Not critical, continue with installation
            }
        } else {
            Write-Warning "  [!] Manifest not available, skipping local manifest save"
        }

        # Cleanup temp directory (if requested)
        if ($CleanupAfterInstall) {
            Write-Info "  Cleaning up download directory..."
            Remove-Item $TempDownloadDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Success "  [OK] Download directory cleaned up"
        } else {
            Write-Info "  Keeping download directory for future use: $TempDownloadDir"
        }
    }
}
else {
    Write-Info ""
    Write-Info "Step 7 (Extracting installation files) is disabled."
    Write-Info "Skipping extraction..."
    $script:SkippedSteps += "File extraction (Step 7 disabled)"
}

# Setup .env file with GitHub token
Write-Info "`n[8/8] Configuring application..."
$EnvPath = Join-Path $InstallPath ".env"
$EnvTemplatePath = Join-Path $InstallPath ".env.template"

# Use provided passwords or defaults
if ([string]::IsNullOrWhiteSpace($SuperUserPassword)) {
    $SuperUserPassword = "your_sql_super_user_password_here"
}
if ([string]::IsNullOrWhiteSpace($RFQUserPassword)) {
    $RFQUserPassword = "your_database_password_here"
}
if ([string]::IsNullOrWhiteSpace($SettingsPassword)) {
    $SettingsPassword = "your_settings_password_here"
}

# Use provided ServerURL or default
if ([string]::IsNullOrWhiteSpace($ServerURL)) {
    $ServerURL = "https://localhost"
}

# Generate or use Azure encryption key
$AzureKey = ""
if ($AzureKeyGenerate) {
    Write-Info "  Generating Azure encryption key using OpenSSL..."
    try {
        $AzureKey = & openssl rand -base64 32 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to generate Azure key using OpenSSL, using empty value"
            $AzureKey = ""
        } else {
            $AzureKey = $AzureKey.Trim()
            Write-Success "  [OK] Generated Azure encryption key"
        }
    }
    catch {
        Write-Warning "  Failed to generate Azure key using OpenSSL: $_"
        $AzureKey = ""
    }
}
elseif (![string]::IsNullOrWhiteSpace($AzureKeyCustom)) {
    $AzureKey = $AzureKeyCustom
}
else {
    $AzureKey = ""
}

# Get model path for .env
$ModelPathForEnv = ""
if (![string]::IsNullOrWhiteSpace($ModelPath)) {
    # Model path provided via parameter (user is downloading now)
    $ModelPathForEnv = $ModelPath
}
elseif ($SkipModelDownload -and (Test-Path $EnvPath)) {
    # User skipped download - preserve existing MODEL_PATH from .env if it exists
    Write-Info "  Preserving existing MODEL_PATH from .env file (model download skipped)..."
    $ExistingEnvContent = Get-Content $EnvPath -Raw -ErrorAction SilentlyContinue
    if ($ExistingEnvContent -and $ExistingEnvContent -match "MODEL_PATH\s*=\s*([^\r\n]+)") {
        $existingModelPath = $matches[1].Trim()
        if (![string]::IsNullOrWhiteSpace($existingModelPath)) {
            $ModelPathForEnv = $existingModelPath
            Write-Info "  Found existing MODEL_PATH: $ModelPathForEnv"
        }
    }
}

# Check if .env.template exists, if so use it as base
if (Test-Path $EnvTemplatePath) {
    Write-Info "  Found .env.template, using as base..."
    Copy-Item $EnvTemplatePath $EnvPath -Force
    
    # Update values in the .env file
    $EnvContent = Get-Content $EnvPath -Raw
    $EnvContent = $EnvContent -replace "GITHUB_PAT=.*", "GITHUB_PAT=$GitHubToken"
    $EnvContent = $EnvContent -replace "GITHUB_USERNAME=.*", "GITHUB_USERNAME=RFQdebugging"
    $EnvContent = $EnvContent -replace "SQL_SUPER_USER=.*", "SQL_SUPER_USER=$SuperUserPassword"
    $EnvContent = $EnvContent -replace "RFQ_USER_PASSWORD=.*", "RFQ_USER_PASSWORD=$RFQUserPassword"
    $EnvContent = $EnvContent -replace "SETTINGS_PASSWORD=.*", "SETTINGS_PASSWORD=$SettingsPassword"
    $EnvContent = $EnvContent -replace "CONTAINER=.*", "CONTAINER=0"
    # Only update MODEL_PATH if we have a value (preserve existing if empty)
    if (![string]::IsNullOrWhiteSpace($ModelPathForEnv)) {
        $EnvContent = $EnvContent -replace "MODEL_PATH=.*", "MODEL_PATH=$ModelPathForEnv"
    }
    $EnvContent = $EnvContent -replace "MODEL_NAME=.*", "MODEL_NAME=Mistral-7B-Instruct-v0-3"
    $EnvContent = $EnvContent -replace "SERVER_URL=.*", "SERVER_URL=$ServerURL"
    $EnvContent = $EnvContent -replace "DEBUG_THREAD=.*", "DEBUG_THREAD=0"
    $EnvContent = $EnvContent -replace "WINDOWS=.*", "WINDOWS=true"
    $EnvContent = $EnvContent -replace "AZURE_CONFIG_ENCRYPTION_KEY=.*", "AZURE_CONFIG_ENCRYPTION_KEY=$AzureKey"
    $EnvContent = $EnvContent -replace "RFQ_UPDATE_CHANNEL=.*", "RFQ_UPDATE_CHANNEL=$UpdateChannel"
    # Only update AWS credentials if they are non-empty
    if (![string]::IsNullOrWhiteSpace($AWSKey)) {
        $EnvContent = $EnvContent -replace "AWS_KEY=.*", "AWS_KEY=$AWSKey"
    }
    if (![string]::IsNullOrWhiteSpace($AWSSecret)) {
        $EnvContent = $EnvContent -replace "AWS_SECRET=.*", "AWS_SECRET=$AWSSecret"
    }
    if (![string]::IsNullOrWhiteSpace($AWSRegion)) {
        $EnvContent = $EnvContent -replace "AWS_REGION=.*", "AWS_REGION=$AWSRegion"
    }
    
    # Add if they don't exist
    if ($EnvContent -notmatch "GITHUB_USERNAME") {
        $EnvContent += "`nGITHUB_USERNAME=RFQdebugging"
    }
    if ($EnvContent -notmatch "SQL_SUPER_USER") {
        $EnvContent += "`nSQL_SUPER_USER=$SuperUserPassword"
    }
    if ($EnvContent -notmatch "RFQ_USER_PASSWORD") {
        $EnvContent += "`nRFQ_USER_PASSWORD=$RFQUserPassword"
    }
    if ($EnvContent -notmatch "SETTINGS_PASSWORD") {
        $EnvContent += "`nSETTINGS_PASSWORD=$SettingsPassword"
    }
    if ($EnvContent -notmatch "CONTAINER") {
        $EnvContent += "`nCONTAINER=0"
    }
    # Only add MODEL_PATH if we have a value and it doesn't exist
    if ($EnvContent -notmatch "MODEL_PATH" -and ![string]::IsNullOrWhiteSpace($ModelPathForEnv)) {
        $EnvContent += "`nMODEL_PATH=$ModelPathForEnv"
    }
    if ($EnvContent -notmatch "MODEL_NAME") {
        $EnvContent += "`nMODEL_NAME=Mistral-7B-Instruct-v0-3"
    }
    if ($EnvContent -notmatch "SERVER_URL") {
        $EnvContent += "`nSERVER_URL=$ServerURL"
    }
    if ($EnvContent -notmatch "DEBUG_THREAD") {
        $EnvContent += "`nDEBUG_THREAD=0"
    }
    if ($EnvContent -notmatch "WINDOWS") {
        $EnvContent += "`nWINDOWS=true"
    }
    if ($EnvContent -notmatch "AZURE_CONFIG_ENCRYPTION_KEY") {
        $EnvContent += "`nAZURE_CONFIG_ENCRYPTION_KEY=$AzureKey"
    }
    if ($EnvContent -notmatch "RFQ_UPDATE_CHANNEL") {
        $EnvContent += "`nRFQ_UPDATE_CHANNEL=$UpdateChannel"
    }
    # Only add AWS credentials if they are non-empty
    if ($EnvContent -notmatch "AWS_KEY" -and ![string]::IsNullOrWhiteSpace($AWSKey)) {
        $EnvContent += "`nAWS_KEY=$AWSKey"
    }
    if ($EnvContent -notmatch "AWS_SECRET" -and ![string]::IsNullOrWhiteSpace($AWSSecret)) {
        $EnvContent += "`nAWS_SECRET=$AWSSecret"
    }
    if ($EnvContent -notmatch "AWS_REGION" -and ![string]::IsNullOrWhiteSpace($AWSRegion)) {
        $EnvContent += "`nAWS_REGION=$AWSRegion"
    }
    
    # Add generation timestamp as comment
    $EnvContent = "# RFQ Application Configuration`n# Generated by installer on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" + $EnvContent
    
    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env from template with all configuration values"
}
else {
    # Create .env from scratch if template doesn't exist
    Write-Info "  .env.template not found, creating .env from default..."
    $EnvContent = @"
# RFQ Application Configuration
# Generated by installer on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# GitHub Authentication (for updates)
GITHUB_PAT=$GitHubToken
GITHUB_USERNAME=RFQdebugging

# Application Mode
APP_MODE=fastapi

# Windows Specific
WINDOWS=true
LOCAL_DATABASE=1
CONTAINER=0

# Model Configuration
MODEL_PATH=$ModelPathForEnv
MODEL_NAME=Mistral-7B-Instruct-v0-3

# Server Configuration
SERVER_URL=$ServerURL

# Debug Configuration
DEBUG_THREAD=0

# Database Configuration (for setup_database_auto.bat)
# SQL super user password (for database setup)
SQL_SUPER_USER=$SuperUserPassword

# Database password (for rfq_user)
RFQ_USER_PASSWORD=$RFQUserPassword

# Settings password
SETTINGS_PASSWORD=$SettingsPassword

# Azure Configuration
AZURE_CONFIG_ENCRYPTION_KEY=$AzureKey


# Update Channel
RFQ_UPDATE_CHANNEL=$UpdateChannel
"@
    
    # Add AWS Configuration section only if credentials are provided
    if (![string]::IsNullOrWhiteSpace($AWSKey) -or ![string]::IsNullOrWhiteSpace($AWSSecret) -or ![string]::IsNullOrWhiteSpace($AWSRegion)) {
        $EnvContent += "`n"
        $EnvContent += "# AWS Configuration (for model download)`n"
        if (![string]::IsNullOrWhiteSpace($AWSKey)) {
            $EnvContent += "AWS_KEY=$AWSKey`n"
        }
        if (![string]::IsNullOrWhiteSpace($AWSSecret)) {
            $EnvContent += "AWS_SECRET=$AWSSecret`n"
        }
        if (![string]::IsNullOrWhiteSpace($AWSRegion)) {
            $EnvContent += "AWS_REGION=$AWSRegion`n"
        }
    }
    
    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env configuration with all values"
}

# Create version file
$VersionPath = Join-Path $InstallPath "version.txt"
Set-Content -Path $VersionPath -Value $Version -Force

# Download Mistral model (optional)
Write-Info "`nModel download..."

# Check if ModelPath was provided via parameter (from installer)
$downloadModel = 'n'
$modelBasePath = ""

if ($SkipModelDownload) {
    # Installer explicitly requested to skip download - don't prompt
    Write-Info "Model download skipped as requested by installer"
    $downloadModel = 'n'
    $script:SkippedSteps += "Model download (skipped by installer)"
}
elseif ($ModelPath -and $ModelPath.Trim() -ne "") {
    # Model path provided via parameter - skip prompts
    Write-Info "Model download path provided by installer: $ModelPath"
    $modelBasePath = $ModelPath
    $downloadModel = 'y'
}
else {
    # Prompt user for model download
    Write-Info "The application requires the Mistral-7B-Instruct-v0.3 language model."
    Write-Info "This is a large download (~30 GB) and may take 30-60 minutes depending on your internet connection."
    Write-Info ""
    Write-Info "Options:"
    Write-Info "  [Y] Yes - Download now (recommended)"
    Write-Info "  [n] No - Skip download (you can download later)"
    Write-Info ""
    $downloadModel = Read-Host "Would you like to download the model now? (Y/n)"
    
    if ($downloadModel -ne 'n' -and $downloadModel -ne 'N') {
        Write-Info ""
        Write-Info "Please choose where to download the model:"
        Write-Info "  - The model will be downloaded to a subdirectory in your chosen location"
        Write-Info "  - Default: $env:USERPROFILE\Documents\RFQ_Models"
        Write-Info ""
        
        $defaultModelPath = Join-Path $env:USERPROFILE "Documents\RFQ_Models"
        $modelBasePath = Read-Host "Enter model download directory (press Enter for default: $defaultModelPath)"
        
        if ([string]::IsNullOrWhiteSpace($modelBasePath)) {
            $modelBasePath = $defaultModelPath
        }
    }
}

if ($downloadModel -ne 'n' -and $downloadModel -ne 'N' -and $modelBasePath) {
    # Normalize the path
    $modelBasePath = [System.IO.Path]::GetFullPath($modelBasePath)
    
    # Create directory if it doesn't exist
    if (!(Test-Path $modelBasePath)) {
        try {
            New-Item -ItemType Directory -Path $modelBasePath -Force | Out-Null
            Write-Success "[OK] Created directory: $modelBasePath"
        }
        catch {
            Write-Error-Custom "ERROR: Failed to create directory: $_"
            Write-Info "Skipping model download"
            $downloadModel = 'n'
            $script:SkippedSteps += "Model download (failed to create directory)"
        }
    }
    
    if ($downloadModel -ne 'n') {
        # Model will be downloaded to a subdirectory
        $modelDir = Join-Path $modelBasePath "Mistral-7B-Instruct-v0-3"
        $modelPath = $modelDir  # MODEL_PATH should point to the model directory
        
        Write-Info ""
        Write-Info "Downloading Mistral-7B-Instruct-v0.3 model from AWS S3..."
        Write-Info "  Bucket: rfq-models"
        Write-Info "  Destination: $modelDir"
        Write-Info "  This is a large download (~30 GB) and may take 30-60 minutes depending on your internet connection..."
        Write-Info ""
        
        # Read AWS credentials - first from parameters, then from .env file
        $awsKey = ""
        $awsSecret = ""
        $awsRegion = "us-east-1"  # Default region
        $credentialsProvidedViaParams = $false
        
        # Check if credentials were provided via parameters (even if empty, means installer provided them)
        $credentialsProvidedViaParams = ($PSBoundParameters.ContainsKey('AWSKey') -or $PSBoundParameters.ContainsKey('AWSSecret'))
        
        # Debug: Show what parameters were received
        Write-Info "  Debug: Checking AWS parameters..."
        Write-Info "    AWSKey parameter provided: $($PSBoundParameters.ContainsKey('AWSKey')), Value length: $($AWSKey.Length)"
        Write-Info "    AWSSecret parameter provided: $($PSBoundParameters.ContainsKey('AWSSecret')), Value length: $($AWSSecret.Length)"
        Write-Info "    AWSRegion parameter: '$AWSRegion'"
        Write-Info "    credentialsProvidedViaParams: $credentialsProvidedViaParams"
        
        # Use provided parameters if available and non-empty
        if ($PSBoundParameters.ContainsKey('AWSKey') -and $AWSKey -and $AWSKey.Trim() -ne "") {
            $awsKey = $AWSKey
            Write-Info "    Using AWSKey from parameters"
        }
        if ($PSBoundParameters.ContainsKey('AWSSecret') -and $AWSSecret -and $AWSSecret.Trim() -ne "") {
            $awsSecret = $AWSSecret
            Write-Info "    Using AWSSecret from parameters"
        }
        if ($PSBoundParameters.ContainsKey('AWSRegion') -and $AWSRegion -and $AWSRegion.Trim() -ne "") {
            $awsRegion = $AWSRegion
            Write-Info "    Using AWSRegion from parameters"
        }
        
        # If credentials are still empty, try reading from .env file (regardless of whether params were provided)
        if (([string]::IsNullOrWhiteSpace($awsKey) -or [string]::IsNullOrWhiteSpace($awsSecret)) -and (Test-Path $EnvPath)) {
            Write-Info "  Reading AWS credentials from .env file..."
            $EnvContent = Get-Content $EnvPath -Raw
            if ([string]::IsNullOrWhiteSpace($awsKey) -and $EnvContent -match "AWS_KEY\s*=\s*([^\r\n]+)") {
                $awsKey = $matches[1].Trim()
                Write-Info "  Found AWS_KEY in .env: $($awsKey.Substring(0, [Math]::Min(10, $awsKey.Length)))..."
            }
            if ([string]::IsNullOrWhiteSpace($awsSecret) -and $EnvContent -match "AWS_SECRET\s*=\s*([^\r\n]+)") {
                $awsSecret = $matches[1].Trim()
                Write-Info "  Found AWS_SECRET in .env: $($awsSecret.Substring(0, [Math]::Min(10, $awsSecret.Length)))..."
            }
            if ([string]::IsNullOrWhiteSpace($awsRegion) -and $EnvContent -match "AWS_REGION\s*=\s*([^\r\n]+)") {
                $awsRegion = $matches[1].Trim()
                Write-Info "  Found AWS_REGION in .env: $awsRegion"
            }
        }
        
        # Only prompt for AWS credentials if not provided via parameters and not found in .env
        # If credentials were provided via parameters but are empty, that means user didn't enter them in installer
        if (([string]::IsNullOrWhiteSpace($awsKey) -or [string]::IsNullOrWhiteSpace($awsSecret)) -and -not $credentialsProvidedViaParams) {
            Write-Info ""
            Write-Info "AWS credentials required for model download"
            Write-Info "============================================="
            Write-Info ""
            Write-Info "The model is stored in AWS S3 and requires credentials to download."
            Write-Info ""
            
            if ([string]::IsNullOrWhiteSpace($awsKey)) {
                $awsKey = Read-Host "Enter AWS Access Key ID"
            }
            if ([string]::IsNullOrWhiteSpace($awsSecret)) {
                $awsSecret = Read-Host "Enter AWS Secret Access Key" -AsSecureString
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($awsSecret)
                $awsSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            }
            
            $regionInput = Read-Host "Enter AWS Region (press Enter for us-east-1)"
            if (![string]::IsNullOrWhiteSpace($regionInput)) {
                $awsRegion = $regionInput.Trim()
            }
            
            # Save credentials to .env file
            if (Test-Path $EnvPath) {
                $EnvContent = Get-Content $EnvPath -Raw
                $EnvContent = $EnvContent -replace "AWS_KEY=.*", "AWS_KEY=$awsKey"
                $EnvContent = $EnvContent -replace "AWS_SECRET=.*", "AWS_SECRET=$awsSecret"
                $EnvContent = $EnvContent -replace "AWS_REGION=.*", "AWS_REGION=$awsRegion"
                
                # Add if they don't exist
                if ($EnvContent -notmatch "AWS_KEY") {
                    $EnvContent += "`nAWS_KEY=$awsKey"
                }
                if ($EnvContent -notmatch "AWS_SECRET") {
                    $EnvContent += "`nAWS_SECRET=$awsSecret"
                }
                if ($EnvContent -notmatch "AWS_REGION") {
                    $EnvContent += "`nAWS_REGION=$awsRegion"
                }
                
                Set-Content -Path $EnvPath -Value $EnvContent -Force
                Write-Success "[OK] AWS credentials saved to .env file"
            }
        }
        
        # Verify we have credentials before proceeding
        if ([string]::IsNullOrWhiteSpace($awsKey) -or [string]::IsNullOrWhiteSpace($awsSecret)) {
            Write-Error-Custom "ERROR: AWS credentials are required but not provided"
            Write-Info "  Please provide AWS_KEY and AWS_SECRET in the .env file or when prompted"
            Write-Info "  Skipping model download"
            $script:SkippedSteps += "Model download (AWS credentials missing)"
        }
        else {
            # Create a temporary Python script to download the model from S3
            $downloadScript = Join-Path $env:TEMP "download_mistral_model_s3.py"
            $scriptContent = @"
import os
import sys
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

try:
    model_dir = r"$modelDir"
    aws_key = r"$awsKey"
    aws_secret = r"$awsSecret"
    aws_region = r"$awsRegion"
    
    print("Starting model download from AWS S3...")
    print(f"Bucket: rfq-models")
    print(f"Region: {aws_region}")
    print(f"Destination: {model_dir}")
    
    # Create destination directory
    os.makedirs(model_dir, exist_ok=True)
    
    # Initialize S3 client
    s3 = boto3.client(
        "s3",
        aws_access_key_id=aws_key,
        aws_secret_access_key=aws_secret,
        region_name=aws_region
    )
    
    bucket_name = "rfq-models"
    model_prefix = "Mistral-7B-Instruct-v0-3/"
    
    # List all objects in the model directory
    print("Listing model files in S3...")
    files_downloaded = 0
    total_size = 0
    
    try:
        paginator = s3.get_paginator('list_objects_v2')
        pages = paginator.paginate(Bucket=bucket_name, Prefix=model_prefix)
        
        for page in pages:
            if 'Contents' not in page:
                continue
                
            for obj in page['Contents']:
                key = obj['Key']
                size = obj['Size']
                
                # Skip directories
                if key.endswith('/'):
                    continue
                
                # Skip cache files and metadata files
                if '.cache' in key or key.endswith('.lock') or key.endswith('.metadata'):
                    continue
                
                # Get relative path from model prefix
                relative_path = key[len(model_prefix):]
                local_path = os.path.join(model_dir, relative_path)
                
                # Create subdirectories if needed
                local_dir = os.path.dirname(local_path)
                if local_dir:
                    os.makedirs(local_dir, exist_ok=True)
                
                # Download file
                print(f"Downloading: {relative_path} ({size / 1024 / 1024:.4f} MB)")
                s3.download_file(bucket_name, key, local_path)
                files_downloaded += 1
                total_size += size
    except ClientError as list_error:
        error_code = list_error.response.get('Error', {}).get('Code', '')
        if error_code == 'AccessDenied':
            print("")
            print("WARNING: Access denied when listing bucket contents.")
            print("Your IAM user may not have s3:ListBucket permission.")
            print("")
            print("Attempting to download common model files directly...")
            print("(This requires s3:GetObject permission)")
            print("")
            
            # First, try to download the model index file to get the list of all files
            index_file = "model.safetensors.index.json"
            index_key = model_prefix + index_file
            index_local_path = os.path.join(model_dir, index_file)
            model_files_from_index = []
            
            try:
                # Try to get index file metadata first
                obj_metadata = s3.head_object(Bucket=bucket_name, Key=index_key)
                index_size = obj_metadata['ContentLength']
                
                # Create directory if needed
                local_dir = os.path.dirname(index_local_path)
                if local_dir:
                    os.makedirs(local_dir, exist_ok=True)
                
                # Try to download the index file first
                print(f"Downloading index file: {index_file} ({index_size / 1024 / 1024:.4f} MB)")
                s3.download_file(bucket_name, index_key, index_local_path)
                files_downloaded += 1
                total_size += index_size
                
                # Parse the index file to get list of all model files
                import json
                with open(index_local_path, 'r') as f:
                    index_data = json.load(f)
                    if 'weight_map' in index_data:
                        # Extract unique filenames from weight_map
                        model_files_from_index = list(set(index_data['weight_map'].values()))
                        print(f"Found {len(model_files_from_index)} model files in index")
            except ClientError as e:
                error_code = e.response.get('Error', {}).get('Code', '')
                if error_code == 'AccessDenied':
                    print(f"Access denied for index file, trying common files...")
                else:
                    print(f"Index file not available, trying common files...")
            except Exception as e:
                print(f"Could not parse index file: {e}")
            
            # Try to download common model files directly
            common_files = [
                "config.json",
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "generation_config.json",
            ]
            
            # Combine files from index with common files
            all_files = list(set(common_files + model_files_from_index))
            
            for filename in all_files:
                key = model_prefix + filename
                local_path = os.path.join(model_dir, filename)
                
                try:
                    # Try to get object metadata first to check if it exists
                    try:
                        obj_metadata = s3.head_object(Bucket=bucket_name, Key=key)
                        size = obj_metadata['ContentLength']
                    except ClientError:
                        # File doesn't exist, skip
                        continue
                    
                    # Create subdirectories if needed
                    local_dir = os.path.dirname(local_path)
                    if local_dir:
                        os.makedirs(local_dir, exist_ok=True)
                    
                    # Download file
                    print(f"Downloading: {filename} ({size / 1024 / 1024:.4f} MB)")
                    s3.download_file(bucket_name, key, local_path)
                    files_downloaded += 1
                    total_size += size
                except ClientError as download_error:
                    error_code = download_error.response.get('Error', {}).get('Code', '')
                    if error_code == 'AccessDenied':
                        print(f"  [!] Access denied for: {filename}")
                    else:
                        print(f"  [!] Error downloading {filename}: {download_error}")
                    continue
                except Exception as e:
                    print(f"  [!] Error downloading {filename}: {e}")
                    continue
            
            if files_downloaded == 0:
                print("")
                print("ERROR: Could not download any files.")
                print("")
                print("Required AWS IAM permissions:")
                print("  - s3:ListBucket on arn:aws:s3:::rfq-models")
                print("  - s3:GetObject on arn:aws:s3:::rfq-models/Mistral-7B-Instruct-v0-3/*")
                print("")
                print("Please contact your AWS administrator to grant these permissions.")
                sys.exit(1)
        else:
            # Re-raise if it's not an AccessDenied error
            raise
    
    if files_downloaded == 0:
        print("")
        print("WARNING: No files found in S3 bucket. Check bucket name and prefix.")
        sys.exit(1)
    
    print("")
    print(f"SUCCESS: Model downloaded successfully!")
    print(f"Files downloaded: {files_downloaded}")
    print(f"Total size: {total_size / 1024 / 1024 / 1024:.2f} GB")
    print(f"Model location: {model_dir}")
    sys.exit(0)
    
except NoCredentialsError:
    print("")
    print("ERROR: AWS credentials not found or invalid")
    print("Please check AWS_KEY, AWS_SECRET, and AWS_REGION in .env file")
    sys.exit(1)
except ClientError as e:
    print("")
    print(f"ERROR: AWS S3 error: {e}")
    sys.exit(1)
except Exception as e:
    print("")
    print(f"ERROR: Failed to download model: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
"@
            
            Set-Content -Path $downloadScript -Value $scriptContent -Encoding UTF8
            
            # Check if Python is available
            $pythonFound = Get-Command python -ErrorAction SilentlyContinue
            
            if (!$pythonFound) {
                Write-Warning "[!] Python not found in PATH"
                Write-Info "  The model download requires Python and the boto3 package"
                Write-Info "  Please install Python and run the download manually:"
                Write-Info "    pip install boto3"
                Write-Info "    python $downloadScript"
                $script:SkippedSteps += "Model download (Python not found)"
            }
            else {
                # Check if boto3 is installed
                $boto3Check = python -c "import boto3; print('OK')" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Info "Installing boto3 package..."
                    python -m pip install boto3 --quiet
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "[!] Failed to install boto3"
                        Write-Info "  Please install it manually: pip install boto3"
                        Write-Info "  Then run: python $downloadScript"
                    }
                }
                
                # Run the download script
                Write-Info "Running model download script..."
                python $downloadScript
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "[OK] Model downloaded successfully from S3"
                    
                    # Update MODEL_PATH in .env file
                    if (Test-Path $EnvPath) {
                        $EnvContent = Get-Content $EnvPath -Raw
                        # Update MODEL_PATH - handle both Windows and Unix-style paths
                        $modelPathNormalized = $modelPath.Replace('\', '/')
                        $EnvContent = $EnvContent -replace "MODEL_PATH=.*", "MODEL_PATH=$modelPathNormalized"
                        Set-Content -Path $EnvPath -Value $EnvContent -Force
                        Write-Success "[OK] Updated MODEL_PATH in .env file: $modelPathNormalized"
                    }
                }
                else {
                    Write-Warning "[!] Model download failed or was interrupted"
                    Write-Info "  You can download it later using:"
                    Write-Info "    python $downloadScript"
                    $script:SkippedSteps += "Model download (download failed or interrupted)"
                }
                
                # Cleanup
                Remove-Item $downloadScript -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Log "" "Yellow"
    Write-Log "WARNING: Model download skipped" "Yellow"
    Write-Log "=================================" "Yellow"
    Write-Log "" "Yellow"
    Write-Log "The application requires the Mistral-7B-Instruct-v0.3 model to function." "Yellow"
    Write-Log "Without the model, language processing features will not work." "Yellow"
    Write-Log "" "Yellow"
    Write-Log "To download the model later:" "Cyan"
    Write-Log "  1. Ensure AWS credentials (AWS_KEY, AWS_SECRET, AWS_REGION) are in .env" "Cyan"
    Write-Log "  2. Run the model download script or use model_downloader.py" "Cyan"
    Write-Log "  3. Configure MODEL_PATH in .env to point to the model directory" "Cyan"
    Write-Log "" "Cyan"
    Write-Log "Model location: AWS S3 bucket 'rfq-models' (prefix: Mistral-7B-Instruct-v0-3/)" "Cyan"
    Write-Log "" "Cyan"
    # Only add to skipped steps if not already added (to avoid duplicates)
    if ($script:SkippedSteps -notcontains "Model download (skipped by installer)" -and 
        $script:SkippedSteps -notcontains "Model download (AWS credentials missing)" -and
        $script:SkippedSteps -notcontains "Model download (Python not found)" -and
        $script:SkippedSteps -notcontains "Model download (download failed or interrupted)" -and
        $script:SkippedSteps -notcontains "Model download (failed to create directory)") {
        $script:SkippedSteps += "Model download (skipped by user)"
    }
}

# Setup database (optional)
Write-Info "`nDatabase setup..."
$SetupDbScript = Join-Path $InstallPath "setup_database_auto.bat"

if (Test-Path $SetupDbScript) {
    # Check if PostgreSQL is installed
    $psqlFound = Get-Command psql -ErrorAction SilentlyContinue
    
    if ($psqlFound) {
        Write-Info "PostgreSQL detected. Would you like to set up the database now?"
        Write-Info "  Note: This requires .env file to be configured with SQL_SUPER_USER and RFQ_USER_PASSWORD"
        Write-Info ""
        
        $setupDb = Read-Host "Set up database now? (y/N)"

        if ($setupDb -match '^[yY](es)?$') {
            # Check if .env has database passwords configured
            if (!(Test-Path $EnvPath)) {
                Write-Warning "[!] .env file not found"
                Write-Info "  Please create and configure .env file with database passwords"
            }
            else {
                $EnvContent = Get-Content $EnvPath -Raw -ErrorAction SilentlyContinue
                $hasSqlSuperUser = $EnvContent -match "SQL_SUPER_USER\s*=\s*[^\r\n]+" -and $EnvContent -notmatch "SQL_SUPER_USER\s*=\s*$" -and $EnvContent -notmatch "SQL_SUPER_USER\s*=\s*your_"
                $hasRfqPassword = $EnvContent -match "RFQ_USER_PASSWORD\s*=\s*[^\r\n]+" -and $EnvContent -notmatch "RFQ_USER_PASSWORD\s*=\s*$" -and $EnvContent -notmatch "RFQ_USER_PASSWORD\s*=\s*your_"
            
                if (!$hasSqlSuperUser -or !$hasRfqPassword) {
                    Write-Warning "[!] Database passwords not configured in .env file"
                    Write-Info "  Please edit $EnvPath and add:"
                    Write-Info "    SQL_SUPER_USER=your_postgres_password"
                    Write-Info "    RFQ_USER_PASSWORD=your_database_password"
                    Write-Info ""
                    Write-Info "  After editing .env, you can run: $SetupDbScript"
                    $script:SkippedSteps += "Database setup (passwords not configured)"
                } else {
                    # Parse actual passwords from .env file
                    $envSuperUser = ""
                    $envRfqPassword = ""
                    if ($EnvContent -match "SQL_SUPER_USER\s*=\s*(.+?)(\r?\n|$)") {
                        $envSuperUser = $matches[1].Trim()
                    }
                    if ($EnvContent -match "RFQ_USER_PASSWORD\s*=\s*(.+?)(\r?\n|$)") {
                        $envRfqPassword = $matches[1].Trim()
                    }

                    # Debug: Show what we parsed
                    Write-Info "  Parsed credentials from .env:"
                    if ([string]::IsNullOrEmpty($envSuperUser)) {
                        Write-Warning "    SQL_SUPER_USER: (EMPTY - this will cause errors!)"
                    } else {
                        $maskedSuper = $envSuperUser.Substring(0, [Math]::Min(3, $envSuperUser.Length)) + "***"
                        Write-Info "    SQL_SUPER_USER: $maskedSuper (length: $($envSuperUser.Length))"
                    }
                    if ([string]::IsNullOrEmpty($envRfqPassword)) {
                        Write-Warning "    RFQ_USER_PASSWORD: (EMPTY - this will cause errors!)"
                    } else {
                        $maskedRfq = $envRfqPassword.Substring(0, [Math]::Min(3, $envRfqPassword.Length)) + "***"
                        Write-Info "    RFQ_USER_PASSWORD: $maskedRfq (length: $($envRfqPassword.Length))"
                    }

                    # Check for problematic characters in passwords
                    $problematicChars = @('&', '|', '<', '>', '^', '%', '!', '"', "'")
                    foreach ($char in $problematicChars) {
                        if ($envSuperUser.Contains($char) -or $envRfqPassword.Contains($char)) {
                            Write-Info "    Note: Password contains special char '$char' - using Base64 encoding to handle it"
                        }
                    }

                    # Run database setup
                    Write-Info ""
                    Write-Info "Running database setup..."
                    try {
                        Push-Location $InstallPath

                        # Encode passwords as Base64 for safe transmission through CMD
                        $SuperUserB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envSuperUser))
                        $RfqUserB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envRfqPassword))

                        Write-Info "  Base64 encoded credentials:"
                        Write-Info "    SuperUser B64 length: $($SuperUserB64.Length) chars"
                        Write-Info "    RfqUser B64 length: $($RfqUserB64.Length) chars"
                        Write-Info ""
                        Write-Info "  Executing: $SetupDbScript"
                        Write-Info "  Working directory: $InstallPath"
                        Write-Info ""

                        # Call setup script with Base64 encoded passwords
                        & cmd.exe /c "`"$SetupDbScript`" -SuperUserB64 `"$SuperUserB64`" -RfqUserB64 `"$RfqUserB64`""
                        $dbExitCode = $LASTEXITCODE

                        Write-Info ""
                        if ($dbExitCode -eq 0) {
                            Write-Success "[OK] Database setup completed successfully (exit code: 0)"
                        } else {
                            Write-Warning "[!] Database setup failed with exit code: $dbExitCode"
                            Write-Info ""
                            Write-Info "  Exit code meanings:"
                            Write-Info "    1  = .env file not found"
                            Write-Info "    2  = Required password variable missing"
                            Write-Info "    3  = pgpass directory creation failed"
                            Write-Info "    4  = pgpass.conf write failed"
                            Write-Info "    5  = SQL file write failed"
                            Write-Info "    10 = psql not found in PATH"
                            Write-Info "    11 = PostgreSQL connection failed"
                            Write-Info "    12 = Database creation failed"
                            Write-Info "    13 = User creation failed"
                            Write-Info "    14 = Password update failed"
                            Write-Info "    15 = Privilege grant failed"
                            Write-Info ""
                            Write-Info "  To debug, run manually:"
                            Write-Info "    cd `"$InstallPath`""
                            Write-Info "    .\setup_database_auto.bat"
                            $script:SkippedSteps += "Database setup (exit code: $dbExitCode)"
                        }
                    }
                    catch {
                        Write-Warning "[!] Exception during database setup: $($_.Exception.Message)"
                        Write-Info "  Exception type: $($_.Exception.GetType().FullName)"
                        Write-Info "  Stack trace: $($_.ScriptStackTrace)"
                        Write-Info ""
                        Write-Info "  You can run it manually later:"
                        Write-Info "    cd `"$InstallPath`""
                        Write-Info "    .\setup_database_auto.bat"
                        $script:SkippedSteps += "Database setup (exception: $($_.Exception.Message))"
                    }
                    finally {
                        Pop-Location
                    }
                }
            }
        } else {
            Write-Info "  Skipping database setup. You can run it manually later:"
            Write-Info "  $SetupDbScript"
            $script:SkippedSteps += "Database setup (skipped by user)"
        }
    } else {
        Write-Warning "[!] PostgreSQL (psql) not found in PATH"
        Write-Info "  Database setup script is available at: $SetupDbScript"
        Write-Info "  Please install PostgreSQL first, then run the setup script manually"
        $script:SkippedSteps += "Database setup (PostgreSQL not found)"
    }
} else {
    Write-Warning "[!] Database setup script not found in installation"
    $script:SkippedSteps += "Database setup (setup script not found)"
}

# Find main executable
Write-Info "`nLocating application executable..."
$ExePath = Get-ChildItem -Path $InstallPath -Filter "RFQ_Application.exe" -Recurse | Select-Object -First 1

if (!$ExePath) {
    # Fallback: find any exe
    $ExePath = Get-ChildItem -Path $InstallPath -Filter "*.exe" -Recurse | Select-Object -First 1
}

if ($ExePath) {
    Write-Success "[OK] Found executable: $($ExePath.FullName)"
    
    # Create Windows service
    Write-Info "`nCreating Windows service 'RFQapplication'..."
    $ServiceName = "RFQapplication"
    $ServiceDisplayName = "RFQ Application Service"
    $ServiceDescription = "RFQ Automation Application Service"
    $ExePathQuoted = "`"$($ExePath.FullName)`""
    
    # Check if service already exists
    $serviceExists = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    
    if ($serviceExists) {
        Write-Warning "[!] Service '$ServiceName' already exists"
        Write-Info "  Stopping existing service..."
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Write-Success "  [OK] Stopped existing service"
        }
        catch {
            Write-Warning "  [!] Could not stop existing service: $_"
        }
        
        Write-Info "  Removing existing service..."
        try {
            sc.exe delete $ServiceName | Out-Null
            Start-Sleep -Seconds 2
            Write-Success "  [OK] Removed existing service"
        }
        catch {
            Write-Warning "  [!] Could not remove existing service: $_"
        }
    }
    
    # Create the service using WinSW (preferred) or sc.exe (fallback)
    Write-Info "  Creating service 'RFQapplication' with executable: $($ExePath.FullName)"
    
    # Check for WinSW in common locations
    $winswPath = $null
    $winswLocations = @(
        "C:\Program Files\WinSW\WinSW.exe",
        "C:\Program Files (x86)\WinSW\WinSW.exe",
        "$env:ProgramFiles\WinSW\WinSW.exe",
        "$env:ProgramFiles(x86)\WinSW\WinSW.exe",
        "$InstallPath\WinSW.exe"
    )
    
    # Check if WinSW is in PATH
    $winswInPath = Get-Command WinSW -ErrorAction SilentlyContinue
    if ($winswInPath) {
        $winswPath = $winswInPath.Path
        Write-Info "  Found WinSW in PATH: $winswPath"
    } else {
        # Check common locations
        foreach ($location in $winswLocations) {
            if (Test-Path $location) {
                $winswPath = $location
                Write-Info "  Found WinSW at: $winswPath"
                break
            }
        }
    }
    
    $script:serviceCreated = $false
    
    # Try to use WinSW first (recommended for non-service-aware applications)
    if ($winswPath) {
        Write-Info "  Using WinSW to create service (recommended for GUI applications)..."
        try {
            # Remove service if it exists
            $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($existingService) {
                Write-Info "    Removing existing service first..."
                sc.exe delete $ServiceName | Out-Null
                Start-Sleep -Seconds 2
            }
            
            # Copy WinSW to installation directory with service name
            $serviceWinswPath = Join-Path $InstallPath "$ServiceName.exe"
            Copy-Item $winswPath $serviceWinswPath -Force
            
            # Create WinSW XML configuration file
            $xmlConfigPath = Join-Path $InstallPath "$ServiceName.xml"
            $logDir = Join-Path $InstallPath "logs"
            if (!(Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            
            $xmlContent = @"
<service>
  <id>$ServiceName</id>
  <name>$ServiceDisplayName</name>
  <description>$ServiceDescription</description>
  <executable>$($ExePath.FullName)</executable>
  <workingdirectory>$InstallPath</workingdirectory>
  <startmode>Automatic</startmode>
  <stopparentprocessfirst>false</stopparentprocessfirst>
  <stoptimeout>15 sec</stoptimeout>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>8</keepFiles>
  </log>
  <logpath>$logDir</logpath>
</service>
"@
            Set-Content -Path $xmlConfigPath -Value $xmlContent -Force
            
            # Install service using WinSW
            $winswOutput = & $serviceWinswPath install 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "[OK] Service '$ServiceName' created successfully using WinSW"
                $script:serviceCreated = $true
                Write-Info "  Service will start automatically on system boot"
                Write-Info "  You can manage it using:"
                Write-Info "    - Command: sc start/stop $ServiceName"
                Write-Info "    - GUI: Services.msc (look for '$ServiceDisplayName')"
                Write-Info "    - WinSW: $serviceWinswPath status/start/stop"
            } else {
                Write-Warning "  [!] WinSW service creation failed (exit code: $LASTEXITCODE)"
                if ($winswOutput) {
                    Write-Warning "    Error: $winswOutput"
                }
            }
        }
        catch {
            Write-Warning "  [!] Failed to create service with WinSW: $_"
        }
    }
    
    # Fallback to sc.exe if WinSW failed or is not available
    if (-not $script:serviceCreated) {
        if (-not $winswPath) {
            Write-Warning "  WinSW not found, using sc.exe (service may fail if application is not service-aware)..."
            Write-Warning "  NOTE: The installer should have included WinSW. Check C:\Program Files\WinSW\WinSW.exe"
        } else {
            Write-Info "  Falling back to sc.exe method..."
        }
        
        try {
            $createOutput = sc.exe create $ServiceName binPath= $ExePathQuoted start= auto DisplayName= $ServiceDisplayName 2>&1
            $createOutputString = $createOutput | Out-String
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "[OK] Service '$ServiceName' created successfully"
                
                # Set service description
                try {
                    sc.exe description $ServiceName $ServiceDescription | Out-Null
                }
                catch {
                    Write-Warning "  [!] Could not set service description: $_"
                }
                
                Write-Info "  Service will start automatically on system boot"
                Write-Info "  You can manage it using:"
                Write-Info "    - Command: sc start/stop $ServiceName"
                Write-Info "    - GUI: Services.msc (look for '$ServiceDisplayName')"
                
                # Important warning about service-aware requirement
                Write-Warning ""
                Write-Warning "  IMPORTANT: Service created with sc.exe may not start properly."
                Write-Warning "  If the service fails to start, install WinSW and recreate the service."
                $script:serviceCreated = $true
            }
            else {
                Write-Warning "[!] Failed to create service (exit code: $LASTEXITCODE)"
                if ($createOutputString) {
                    Write-Warning "  Error output: $createOutputString"
                }
                Write-Warning "  Service creation may require administrator privileges"
            }
        }
        catch {
            Write-Warning "[!] Could not create service: $_"
            Write-Warning "  Service creation may require administrator privileges"
        }
    }
    
    # Start the service if it was successfully created
    if ($script:serviceCreated) {
        Write-Info "`nStarting service '$ServiceName'..."
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Success "[OK] Service '$ServiceName' started successfully"
            Write-Info "  The application is now running as a Windows service"
        }
        catch {
            Write-Warning "[!] Could not start service: $_"
            Write-Info "  You can start it manually later:"
            Write-Info "    - Command: sc start $ServiceName"
            Write-Info "    - GUI: Services.msc"
        }
    }
    
    # Create desktop shortcut (optional)
    Write-Info "`nCreating shortcuts..."
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
else {
    Write-Warning "[!] Could not find application executable"
}

# Check for missing parameters in .env file
Write-Info "`nChecking configuration..."
$MissingParams = @()
$EnvContent = Get-Content $EnvPath -Raw -ErrorAction SilentlyContinue

if ($EnvContent) {
    # Check for placeholders or missing values
    if ($EnvContent -match "SQL_SUPER_USER\s*=\s*(your_|$|\s*$)" -or !($EnvContent -match "SQL_SUPER_USER\s*=\s*[^\r\n]+")) {
        $MissingParams += "SQL_SUPER_USER"
    }
    if ($EnvContent -match "RFQ_USER_PASSWORD\s*=\s*(your_|$|\s*$)" -or !($EnvContent -match "RFQ_USER_PASSWORD\s*=\s*[^\r\n]+")) {
        $MissingParams += "RFQ_USER_PASSWORD"
    }
}

# Success message
$SuccessMessage = @"

================================================================================
*** Installation Complete! ***
================================================================================

Installation Path: $InstallPath
Version: $Version

"@

# Add skipped steps section if any steps were skipped
if ($script:SkippedSteps.Count -gt 0) {
    $SuccessMessage += "SKIPPED STEPS:`n"
    foreach ($step in $script:SkippedSteps) {
        $SuccessMessage += "  - $step`n"
    }
    $SuccessMessage += "`n"
}

$SuccessMessage += @"
NEXT STEPS:
  1. The Windows service 'RFQapplication' has been created and started
  2. The application should now be running as a Windows service
  3. You can also run the application directly: $($ExePath.FullName)
  4. Or use the desktop shortcut: RFQ Application
  5. For updates, use the built-in updater (Settings -> System Updates)

CONFIGURATION:
  - Config file: $InstallPath\.env
  - Database setup: Run setup_database_auto.bat if not already done
  - Logs: $InstallPath\logs\

TROUBLESHOOTING:
  - If the app doesn't start, check logs in the logs\ folder
  - Make sure you have required dependencies installed
  - For database setup, see README_Windows.md

SUPPORT:
  - Documentation: $InstallPath\README_Windows.md
  - GitHub: https://github.com/$GITHUB_REPO

================================================================================
"@

Write-Log $SuccessMessage "Green"
Write-Log "" "Green"
Write-Log "Installation log saved to: $script:LogFile" "Cyan"

# Check and warn about missing parameters
if ($MissingParams.Count -gt 0) {
    Write-Log "" "Yellow"
    Write-Log "IMPORTANT: Configuration Required" "Yellow"
    Write-Log "===================================" "Yellow"
    Write-Log "" "Yellow"
    Write-Log "Before running the application, please edit the .env file and fill in:" "Yellow"
    foreach ($param in $MissingParams) {
        Write-Log "  - $param" "Yellow"
    }
    Write-Log "" "Yellow"
    Write-Log "File location: $EnvPath" "Cyan"
    Write-Log "" "Cyan"
    Write-Log "After editing .env, you can:" "Cyan"
    Write-Log "  1. Run setup_database_auto.bat to set up the database" "Cyan"
    Write-Log "  2. Then launch the application" "Cyan"
    Write-Log "" "Cyan"
}

Write-Log "" "Green"
Write-Log "================================================================================" "Green"
Write-Log "Installation complete!" "Green"
Write-Log "================================================================================" "Green"
Write-Log "" "Green"
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
