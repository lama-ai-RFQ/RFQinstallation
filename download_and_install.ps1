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
    
    # Check if component has any files
    if (!$ComponentInfo.files -or $ComponentInfo.files.Count -eq 0) {
        Write-Warning "  [$CurrentComponent/$TotalComponents] Skipping $ComponentName (no files in component)"
        continue
    }
    
    Write-Info "  [$CurrentComponent/$TotalComponents] Downloading: $ComponentName"
    
    $filesDownloaded = 0
    foreach ($FileInfo in $ComponentInfo.files) {
        $Filename = $FileInfo.filename
        
        # Find the asset
        $Asset = $Release.assets | Where-Object { $_.name -eq $Filename } | Select-Object -First 1
        
        if (!$Asset) {
            Write-Warning "  [!] Asset not found: $Filename (component may be empty, skipping)"
            continue
        }
        
        # Download file
        $FilePath = Join-Path $TempDownloadDir $Filename
        try {
            $DownloadHeaders = $Headers.Clone()
            $DownloadHeaders["Accept"] = "application/octet-stream"
            
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Asset.url -OutFile $FilePath -Headers $DownloadHeaders -UseBasicParsing
            $ProgressPreference = 'Continue'
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

# Rejoin multi-part files and extract
Write-Info "`n[7/8] Extracting installation files..."

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
        }
        finally {
            $OutputFile.Close()
        }
    }
    

    # Extract component
    try {
        # Extract to a temp location first to check for unwanted nested paths
        $TempExtractDir = Join-Path $env:TEMP "rfq_extract_$ComponentName"
        if (Test-Path $TempExtractDir) {
            Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
        
        Expand-Archive -Path $ComponentZip -DestinationPath $TempExtractDir -Force
        
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
        exit 1
    }
}

Write-Success "[OK] Extracted all components to: $InstallPath"

# Cleanup temp directory
Remove-Item $TempDownloadDir -Recurse -Force -ErrorAction SilentlyContinue

# Setup .env file with GitHub token
Write-Info "`n[8/8] Configuring application..."
$EnvPath = Join-Path $InstallPath ".env"
$EnvTemplatePath = Join-Path $InstallPath ".env.template"

# Check if .env.template exists, if so use it as base
if (Test-Path $EnvTemplatePath) {
    Write-Info "  Found .env.template, using as base..."
    Copy-Item $EnvTemplatePath $EnvPath -Force
    
    # Update GITHUB_PAT in the .env file
    $EnvContent = Get-Content $EnvPath -Raw
    $EnvContent = $EnvContent -replace "GITHUB_PAT=.*", "GITHUB_PAT=$GitHubToken"
    
    # Add generation timestamp as comment
    $EnvContent = "# RFQ Application Configuration`n# Generated by installer on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" + $EnvContent
    
    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env from template with GitHub token"
}
else {
    # Create .env from scratch if template doesn't exist
    Write-Info "  .env.template not found, creating .env from default..."
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

# Database Configuration (for setup_database_auto.bat)
# SQL super user password (for database setup)
SQL_SUPER_USER=your_sql_super_user_password_here

# Database password (for rfq_user)
RFQ_USER_PASSWORD=your_database_password_here
"@
    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env configuration with GitHub token"
}

# Create version file
$VersionPath = Join-Path $InstallPath "version.txt"
Set-Content -Path $VersionPath -Value $Version -Force

# Download Mistral model (optional)
Write-Info "`nModel download..."
Write-Info "The application requires the Mistral-7B-Instruct-v0.3 language model."
Write-Info "This is a large download (~4-5 GB) and may take some time."
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
        }
    }
    
    if ($downloadModel -ne 'n') {
        # Model will be downloaded to a subdirectory
        $modelDir = Join-Path $modelBasePath "Mistral-7B-Instruct-v0-3"
        $modelPath = $modelBasePath  # MODEL_PATH should point to the base directory
        
        Write-Info ""
        Write-Info "Downloading Mistral-7B-Instruct-v0.3 model from AWS S3..."
        Write-Info "  Bucket: rfq-models"
        Write-Info "  Destination: $modelDir"
        Write-Info "  This may take 10-30 minutes depending on your internet connection..."
        Write-Info ""
        
        # Read AWS credentials from .env file
        $awsKey = ""
        $awsSecret = ""
        $awsRegion = "us-east-1"  # Default region
        
        if (Test-Path $EnvPath) {
            $EnvContent = Get-Content $EnvPath -Raw
            if ($EnvContent -match "AWS_KEY\s*=\s*([^\r\n]+)") {
                $awsKey = $matches[1].Trim()
            }
            if ($EnvContent -match "AWS_SECRET\s*=\s*([^\r\n]+)") {
                $awsSecret = $matches[1].Trim()
            }
            if ($EnvContent -match "AWS_REGION\s*=\s*([^\r\n]+)") {
                $awsRegion = $matches[1].Trim()
            }
        }
        
        # Prompt for AWS credentials if not found
        if ([string]::IsNullOrWhiteSpace($awsKey) -or [string]::IsNullOrWhiteSpace($awsSecret)) {
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
    print("Starting model download from AWS S3...")
    print(f"Bucket: rfq-models")
    print(f"Region: $awsRegion")
    print(f"Destination: $modelDir")
    
    # Create destination directory
    os.makedirs(r"$modelDir", exist_ok=True)
    
    # Initialize S3 client
    s3 = boto3.client(
        "s3",
        aws_access_key_id=r"$awsKey",
        aws_secret_access_key=r"$awsSecret",
        region_name=r"$awsRegion"
    )
    
    bucket_name = "rfq-models"
    model_prefix = "Mistral-7B-Instruct-v0-3/"
    
    # List all objects in the model directory
    print("Listing model files in S3...")
    paginator = s3.get_paginator('list_objects_v2')
    pages = paginator.paginate(Bucket=bucket_name, Prefix=model_prefix)
    
    files_downloaded = 0
    total_size = 0
    
    for page in pages:
        if 'Contents' not in page:
            continue
            
        for obj in page['Contents']:
            key = obj['Key']
            size = obj['Size']
            
            # Skip directories
            if key.endswith('/'):
                continue
            
            # Get relative path from model prefix
            relative_path = key[len(model_prefix):]
            local_path = os.path.join(r"$modelDir", relative_path)
            
            # Create subdirectories if needed
            local_dir = os.path.dirname(local_path)
            if local_dir:
                os.makedirs(local_dir, exist_ok=True)
            
            # Download file
            print(f"Downloading: {relative_path} ({size / 1024 / 1024:.2f} MB)")
            s3.download_file(bucket_name, key, local_path)
            files_downloaded += 1
            total_size += size
    
    if files_downloaded == 0:
        print("")
        print("WARNING: No files found in S3 bucket. Check bucket name and prefix.")
        sys.exit(1)
    
    print("")
    print(f"SUCCESS: Model downloaded successfully!")
    print(f"Files downloaded: {files_downloaded}")
    print(f"Total size: {total_size / 1024 / 1024 / 1024:.2f} GB")
    print(f"Model location: $modelDir")
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
                }
                
                # Cleanup
                Remove-Item $downloadScript -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host ""
    Write-Host "WARNING: Model download skipped" -ForegroundColor Yellow
    Write-Host "=================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "The application requires the Mistral-7B-Instruct-v0.3 model to function." -ForegroundColor Yellow
    Write-Host "Without the model, language processing features will not work." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To download the model later:" -ForegroundColor Cyan
    Write-Host "  1. Ensure AWS credentials (AWS_KEY, AWS_SECRET, AWS_REGION) are in .env" -ForegroundColor Cyan
    Write-Host "  2. Run the model download script or use model_downloader.py" -ForegroundColor Cyan
    Write-Host "  3. Configure MODEL_PATH in .env to point to the model directory" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Model location: AWS S3 bucket 'rfq-models' (prefix: Mistral-7B-Instruct-v0-3/)" -ForegroundColor Cyan
    Write-Host ""
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
        
        if ($setupDb -eq 'y') {
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
                } else {
                    # Run database setup
                    Write-Info "Running database setup..."
                    try {
                        Push-Location $InstallPath
                        & cmd.exe /c $SetupDbScript
                        if ($LASTEXITCODE -eq 0) {
                            Write-Success "[OK] Database setup completed"
                        } else {
                            Write-Warning "[!] Database setup may have encountered issues. Check the output above."
                        }
                    }
                    catch {
                        Write-Warning "[!] Failed to run database setup: $_"
                        Write-Info "  You can run it manually later: $SetupDbScript"
                    }
                    finally {
                        Pop-Location
                    }
                }
            }
        } else {
            Write-Info "  Skipping database setup. You can run it manually later:"
            Write-Info "  $SetupDbScript"
        }
    } else {
        Write-Warning "[!] PostgreSQL (psql) not found in PATH"
        Write-Info "  Database setup script is available at: $SetupDbScript"
        Write-Info "  Please install PostgreSQL first, then run the setup script manually"
    }
} else {
    Write-Warning "[!] Database setup script not found in installation"
}

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
"@ -ForegroundColor Green

# Check and warn about missing parameters
if ($MissingParams.Count -gt 0) {
    Write-Host ""
    Write-Host "IMPORTANT: Configuration Required" -ForegroundColor Yellow
    Write-Host "===================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Before running the application, please edit the .env file and fill in:" -ForegroundColor Yellow
    foreach ($param in $MissingParams) {
        Write-Host "  - $param" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "File location: $EnvPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After editing .env, you can:" -ForegroundColor Cyan
    Write-Host "  1. Run setup_database_auto.bat to set up the database" -ForegroundColor Cyan
    Write-Host "  2. Then launch the application" -ForegroundColor Cyan
    Write-Host ""
}

# Ask to launch
$launch = Read-Host "Launch RFQ Application now? (Y/n)"
if ($launch -ne 'n') {
    if ($ExePath) {
        Write-Info "Launching application..."
        Start-Process -FilePath $ExePath.FullName -WorkingDirectory $InstallPath
    }
}

