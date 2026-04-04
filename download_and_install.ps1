# RFQ Application - Windows Installation Script
# Downloads and installs the RFQ application from GitHub releases
# This script is for first-time installation only

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
    [string]$Channel = "",
    [string]$UpdateChannel = "customer",
    [switch]$UseCredentialManager,
    [string]$ServiceAccount = "CurrentUser",
    [switch]$SettingsPasswordAlreadyStored,
    [switch]$SuperUserPasswordAlreadyStored,
    [switch]$RFQUserPasswordAlreadyStored
)

# Set error action preference to continue so we can handle errors gracefully
$ErrorActionPreference = "Continue"

# Enforce TLS 1.2 for all HTTPS connections. Older .NET Framework versions
# (4.5 and below) default to SSL3/TLS1.0 which CloudFront and GitHub reject.
# Windows 10 1607+ with .NET 4.6+ defaults to TLS 1.2, but corporate GPOs
# or hardened systems may override this. Setting it explicitly is cheap insurance.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
    if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
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
    if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    exit 1
}

# ── CloudFront signed-URL support ────────────────────────────────────────────
# Fetch signing config (key + key-pair-id + distribution domain) from S3 once,
# then generate short-lived signed URLs so all subsequent downloads go through
# CloudFront instead of hitting S3 directly.  Falls back gracefully when the
# config objects are missing or the fetch fails.

$script:CloudFrontConfig = $null  # cached after first successful fetch

function Get-CloudFrontSigningConfig {
    <#
    .SYNOPSIS
        Downloads cloudfront-config.json and cloudfront-key.pem from the S3
        bucket and caches the result in $script:CloudFrontConfig.
    .DESCRIPTION
        Returns a hashtable with keys: Domain, KeyPairId, PrivateKeyPem.
        Returns $null on any failure (caller should fall back to direct S3).
    #>
    param(
        [string]$Bucket,
        [string]$Region,
        [string]$AwsKey,
        [string]$AwsSecret
    )

    # Return cached config if we already fetched it
    if ($null -ne $script:CloudFrontConfig) {
        return $script:CloudFrontConfig
    }

    try {
        $cfgTmp  = Join-Path $env:TEMP "rfq_cf_config.json"
        $keyTmp  = Join-Path $env:TEMP "rfq_cf_key.pem"

        # Temporarily set AWS credentials
        $env:AWS_ACCESS_KEY_ID     = $AwsKey
        $env:AWS_SECRET_ACCESS_KEY = $AwsSecret

        # Fetch config JSON
        & aws s3api get-object --bucket $Bucket --key "signing/cloudfront-config.json" --region $Region $cfgTmp *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch cloudfront-config.json" }

        # Fetch private key
        & aws s3api get-object --bucket $Bucket --key "signing/cloudfront-key.pem" --region $Region $keyTmp *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch cloudfront-key.pem" }

        # Clean up AWS env vars
        Remove-Item Env:\AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue

        $cfgJson = Get-Content $cfgTmp -Raw | ConvertFrom-Json
        $pemText = Get-Content $keyTmp -Raw

        Remove-Item $cfgTmp -Force -ErrorAction SilentlyContinue
        Remove-Item $keyTmp -Force -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($cfgJson.cloudfront_url) -or
            [string]::IsNullOrWhiteSpace($cfgJson.key_pair_id) -or
            [string]::IsNullOrWhiteSpace($pemText)) {
            throw "Incomplete CloudFront signing config"
        }

        $script:CloudFrontConfig = @{
            Domain       = $cfgJson.cloudfront_url.TrimEnd('/')
            KeyPairId    = $cfgJson.key_pair_id
            PrivateKeyPem = $pemText
        }
        Write-Info "  CloudFront signing config loaded (key-pair: $($cfgJson.key_pair_id))"
        return $script:CloudFrontConfig
    }
    catch {
        # Clean up env vars on failure too
        Remove-Item Env:\AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:TEMP "rfq_cf_config.json") -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:TEMP "rfq_cf_key.pem")     -Force -ErrorAction SilentlyContinue

        Write-Info "  CloudFront signing config not available: $_ (will use direct S3)"
        $script:CloudFrontConfig = $null
        return $null
    }
}

function New-CloudFrontSignedUrl {
    <#
    .SYNOPSIS
        Generates a CloudFront signed URL for the given S3 object path.
    .PARAMETER Path
        The S3 key / resource path (e.g. "internal/windows/latest.json").
    .PARAMETER ExpiresInSeconds
        Lifetime of the signed URL in seconds (default: 900 = 15 min).
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [int]$ExpiresInSeconds = 900
    )

    $cfg = $script:CloudFrontConfig
    if ($null -eq $cfg) { return $null }

    $resourceUrl = "$($cfg.Domain)/$Path"

    # Epoch expiry
    $epoch  = [int][double]::Parse(
        (Get-Date -Date ((Get-Date).ToUniversalTime().AddSeconds($ExpiresInSeconds)) -UFormat %s)
    )

    # Canned policy JSON (compact, no extra whitespace — CloudFront is strict)
    $policy = '{"Statement":[{"Resource":"' + $resourceUrl + '","Condition":{"DateLessThan":{"AWS:EpochTime":' + $epoch + '}}}]}'

    try {
        # ── RSA-SHA1 signature via openssl ────────────────────────────
        # .NET Framework 4.x RSACryptoServiceProvider does not support
        # ImportPkcs8PrivateKey. openssl is already an installer
        # dependency (used for Azure encryption key generation).
        $guid    = [guid]::NewGuid().ToString('N')
        $keyTmp  = Join-Path $env:TEMP "cf_key_$guid.pem"
        $polTmp  = Join-Path $env:TEMP "cf_pol_$guid.bin"
        $sigTmp  = Join-Path $env:TEMP "cf_sig_$guid.bin"

        [System.IO.File]::WriteAllText($keyTmp, $cfg.PrivateKeyPem)
        $policyBytes = [System.Text.Encoding]::UTF8.GetBytes($policy)
        [System.IO.File]::WriteAllBytes($polTmp, $policyBytes)

        & openssl dgst -sha1 -sign $keyTmp -out $sigTmp $polTmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "openssl signing failed (exit code $LASTEXITCODE)" }

        $signatureBytes = [System.IO.File]::ReadAllBytes($sigTmp)
        Remove-Item $keyTmp, $polTmp, $sigTmp -Force -ErrorAction SilentlyContinue

        # CloudFront-safe Base64: + → -, = → _, / → ~
        $sig64 = [Convert]::ToBase64String($signatureBytes)
        $sig64 = $sig64.Replace('+', '-').Replace('=', '_').Replace('/', '~')

        $signedUrl = "$resourceUrl`?Expires=$epoch&Signature=$sig64&Key-Pair-Id=$($cfg.KeyPairId)"
        return $signedUrl
    }
    catch {
        Write-Warning "  Failed to generate CloudFront signed URL: $_"
        return $null
    }
}

# Windows Credential Manager functions
function Save-ToCredentialManager {
    param(
        [string]$TargetName,
        [string]$UserName,
        [string]$Password
    )
    
    try {
        Write-Verbose "Saving credential $TargetName to current user's credential store"
        $output = & cmdkey.exe /generic:$TargetName /user:$UserName /pass:$Password 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Verbose "Successfully saved credential: $TargetName (to current user)"
            return $true
        } else {
            $errorMsg = $output | Out-String
            Write-Warning "Failed to save credential $TargetName (exit code: $exitCode)"
            if ($errorMsg -and $errorMsg.Trim() -ne "") {
                Write-Verbose "Error details: $errorMsg"
            }
            return $false
        }
    }
    catch {
        Write-Warning "Error saving credential to Windows Credential Manager: $_"
        return $false
    }
}

function Save-ToCredentialManagerAsUser {
    param(
        [string]$TargetName,
        [string]$UserName,
        [string]$Password,
        [string]$ServiceAccount,
        [string]$ServiceAccountPassword
    )
    
    try {
        # Check if credential already exists and delete it first (as service user)
        $securePassword = ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($ServiceAccount, $securePassword)
        
        # Check if credential exists (as service user)
        $checkProcess = Start-Process -FilePath "cmdkey.exe" `
            -ArgumentList "/list:$TargetName" `
            -Credential $credential `
            -Wait `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput "$env:TEMP\cmdkey_check_service.txt" `
            -RedirectStandardError "$env:TEMP\cmdkey_check_service_err.txt"
        
        if ($checkProcess.ExitCode -eq 0) {
            # Credential exists, delete it first
            Write-Verbose "Credential $TargetName already exists for service user, deleting first..."
            $deleteProcess = Start-Process -FilePath "cmdkey.exe" `
                -ArgumentList "/delete:$TargetName" `
                -Credential $credential `
                -Wait `
                -PassThru `
                -WindowStyle Hidden
            if ($deleteProcess.ExitCode -ne 0) {
                Write-Warning "Warning: Could not delete existing credential $TargetName for service user, but continuing..."
            }
            Start-Sleep -Milliseconds 500  # Brief pause to ensure deletion completes
        }
        
        Remove-Item "$env:TEMP\cmdkey_check_service.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\cmdkey_check_service_err.txt" -ErrorAction SilentlyContinue
        
        # Use cmdkey.exe to store credentials as the service user (same as original, just with -Credential)
        # This saves to the service user's credential store
        $output = Start-Process -FilePath "cmdkey.exe" `
            -ArgumentList "/generic:$TargetName", "/user:$UserName", "/pass:$Password" `
            -Credential $credential `
            -Wait `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput "$env:TEMP\cmdkey_save_service.txt" `
            -RedirectStandardError "$env:TEMP\cmdkey_save_service_err.txt"
        
        $exitCode = $output.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Verbose "Successfully saved credential: $TargetName (to service user's store)"
            Remove-Item "$env:TEMP\cmdkey_save_service.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\cmdkey_save_service_err.txt" -ErrorAction SilentlyContinue
            return $true
        } else {
            $errorMsg = Get-Content "$env:TEMP\cmdkey_save_service_err.txt" -ErrorAction SilentlyContinue | Out-String
            Write-Verbose "Failed to save credential $TargetName as service user (exit code: $exitCode)"
            if ($errorMsg -and $errorMsg.Trim() -ne "") {
                Write-Verbose "Error details: $errorMsg"
            }
            Remove-Item "$env:TEMP\cmdkey_save_service.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\cmdkey_save_service_err.txt" -ErrorAction SilentlyContinue
            return $false
        }
    }
    catch {
        Write-Verbose "Error saving credential as service user: $_"
        return $false
    }
}

function Add-PendingCredential {
    param(
        [string]$TargetName,
        [string]$UserName,
        [string]$Password,
        [switch]$AlreadyStored
    )

    if ($AlreadyStored) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Password) -or $Password.StartsWith("your_")) {
        return $false
    }

    if (-not $script:PendingCredentials) {
        $script:PendingCredentials = @()
    }

    $script:PendingCredentials += @{
        TargetName = $TargetName
        UserName = $UserName
        Password = $Password
    }

    return $true
}

function Save-PendingCredentials {
    param(
        [string]$ServiceAccount = "",
        [string]$ServiceAccountPassword = ""
    )

    if (-not $script:PendingCredentials -or $script:PendingCredentials.Count -eq 0) {
        return
    }

    $saveToServiceUser = ![string]::IsNullOrWhiteSpace($ServiceAccount) -and ![string]::IsNullOrWhiteSpace($ServiceAccountPassword)
    if ($saveToServiceUser) {
        Write-Info "  Saving credentials to service user's credential store..."
    }

    foreach ($credInfo in $script:PendingCredentials) {
        $saved = $false

        if ($saveToServiceUser) {
            $saved = Save-ToCredentialManagerAsUser `
                -TargetName $credInfo.TargetName `
                -UserName $credInfo.UserName `
                -Password $credInfo.Password `
                -ServiceAccount $ServiceAccount `
                -ServiceAccountPassword $ServiceAccountPassword

            if ($saved) {
                Write-Success "    [OK] Saved $($credInfo.TargetName) to service user's credential store"
            } else {
                Write-Warning "    [!] Failed to save $($credInfo.TargetName) to service user's credential store"
                Write-Warning "        Will try saving to current user's store as fallback..."
            }
        }

        if (-not $saved) {
            $saved = Save-ToCredentialManager `
                -TargetName $credInfo.TargetName `
                -UserName $credInfo.UserName `
                -Password $credInfo.Password

            if ($saved) {
                if ($saveToServiceUser) {
                    Write-Warning "        Saved to current user's store (service may not be able to access)"
                } else {
                    Write-Success "    [OK] Saved $($credInfo.TargetName) to current user's credential store"
                }
            }
        }
    }

    $script:PendingCredentials = @()
}

function Test-CredentialManagerAvailable {
    # Check if cmdkey.exe is available (should be on all Windows systems)
    $cmdkeyPath = Get-Command cmdkey -ErrorAction SilentlyContinue
    if ($cmdkeyPath) {
        return $true
    }
    return $false
}

function Get-FirstNonEmpty {
    param([string[]]$Values)

    foreach ($value in $Values) {
        if (![string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ""
}

function Get-EnvFileValues {
    param([string]$Path)

    $values = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path)) {
        return $values
    }

    foreach ($line in Get-Content -Path $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $values[$matches[1]] = $matches[2].Trim()
        }
    }

    return $values
}

function Set-OrAddEnvValue {
    param(
        [string]$Content,
        [string]$Key,
        [string]$Value
    )

    $pattern = "(?m)^#?\s*$([regex]::Escape($Key))=.*$"
    $newLine = "$Key=$Value"

    if ($Content -match $pattern) {
        return [regex]::Replace($Content, $pattern, $newLine)
    }

    if ([string]::IsNullOrEmpty($Content)) {
        return $newLine
    }

    return $Content.TrimEnd("`r", "`n") + "`n$newLine"
}

function Set-TemporaryEnvironment {
    param([hashtable]$Values)

    $previousValues = @{}
    foreach ($entry in $Values.GetEnumerator()) {
        $name = [string]$entry.Key
        $currentValue = [Environment]::GetEnvironmentVariable($name, "Process")
        $previousValues[$name] = $currentValue
        [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
    }

    return $previousValues
}

function Restore-TemporaryEnvironment {
    param([hashtable]$PreviousValues)

    foreach ($entry in $PreviousValues.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function Remove-ServiceIfExists {
    param(
        [string]$ServiceName,
        [string]$NssmPath = "",
        [string]$FriendlyName = "service"
    )

    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existingService) {
        return
    }

    Write-Warning "[!] $FriendlyName '$ServiceName' already exists"
    Write-Info "  Stopping existing $FriendlyName..."
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        Write-Success "  [OK] Stopped existing $FriendlyName"
    }
    catch {
        Write-Warning "  [!] Could not stop existing $FriendlyName: $_"
    }

    Write-Info "  Removing existing $FriendlyName..."
    try {
        if (![string]::IsNullOrWhiteSpace($NssmPath)) {
            & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
        } else {
            sc.exe delete $ServiceName | Out-Null
        }

        Write-Info "  Waiting for $FriendlyName deletion to complete..."
        $maxWait = 30
        $waited = 0
        $serviceStillExists = $true

        while ($serviceStillExists -and $waited -lt $maxWait) {
            Start-Sleep -Seconds 2
            $waited += 2
            $checkService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if (-not $checkService) {
                $serviceStillExists = $false
                Write-Success "  [OK] $FriendlyName fully removed (waited $waited seconds)"
            } else {
                Write-Info "    Still waiting... ($waited/$maxWait seconds)"
            }
        }

        if ($serviceStillExists) {
            Write-Warning "  [!] $FriendlyName still exists after $maxWait seconds - may be marked for deletion"
            if ($FriendlyName -eq "service") {
                Write-Warning "  [!] You may need to restart the system or wait longer"
            }
        } else {
            Write-Success "  [OK] Removed existing $FriendlyName"
        }
    }
    catch {
        Write-Warning "  [!] Could not remove existing $FriendlyName: $_"
    }
}

function Resolve-ServiceAccountConfig {
    param(
        [string]$ServiceAccount,
        [switch]$NonInteractive,
        [switch]$UseCredentialManager,
        [string]$ServiceName
    )

    $adminUser = "$env:USERDOMAIN\$env:USERNAME"
    $loggedInUser = $null
    $currentDomain = $env:USERDOMAIN

    try {
        $loggedInUserWMI = (Get-WmiObject Win32_ComputerSystem).UserName
        if ($loggedInUserWMI) {
            $loggedInUser = $loggedInUserWMI
            if ($loggedInUser.Contains('\')) {
                $parts = $loggedInUser.Split('\')
                $currentDomain = $parts[0]
            }
        }
    }
    catch {
    }

    $config = [PSCustomObject]@{
        TargetServiceAccount = $null
        ServiceAccountPassword = $null
        ConfigureServiceAccount = $false
    }

    switch ($ServiceAccount.ToLower()) {
        "currentuser" {
            Write-Info "  You selected to run the service as a user account."
            Write-Info "  This allows the service to access Windows Credential Manager credentials."
            Write-Info ""
            Write-Info "  Account information:"
            Write-Info "    - Admin account (running installer): $adminUser"
            if ($loggedInUser) {
                Write-Info "    - Logged-in user: $loggedInUser"
            }
            Write-Info ""
            Write-Info "  Enter the account name to run the service as:"
            Write-Info "    - Format: DOMAIN\Username (e.g., MYDOMAIN\john)"
            Write-Info "    - Or: .\Username for local account (e.g., .\john)"
            Write-Info "    - Or: Username (will use current domain: $currentDomain)"
            Write-Info ""

            if ($NonInteractive) { $accountInput = if ($ServiceAccount -ne "CurrentUser") { $ServiceAccount } else { "" } } else { $accountInput = Read-Host "  Account name" }

            if ([string]::IsNullOrWhiteSpace($accountInput)) {
                Write-Warning "  No account name provided. Service will run as SYSTEM."
            } else {
                if ($accountInput.Contains('\')) {
                    $config.TargetServiceAccount = $accountInput
                } elseif ($accountInput.StartsWith('.\')) {
                    $config.TargetServiceAccount = "$env:COMPUTERNAME\$($accountInput.Substring(2))"
                } else {
                    $config.TargetServiceAccount = "$currentDomain\$accountInput"
                }

                Write-Info "  Service will be configured to run as: $($config.TargetServiceAccount)"
                Write-Info ""
                Write-Info "  WinSW will install the service first, then we'll configure it with the password."
                Write-Info "  Your password will NOT be stored in any files."
                Write-Info ""

                $passwordAttempts = 0
                $maxAttempts = 3

                while ($passwordAttempts -lt $maxAttempts) {
                    try {
                        if ($NonInteractive) { $securePassword = $null } else { $securePassword = Read-Host "  Enter password for $($config.TargetServiceAccount)" -AsSecureString }
                        if ($securePassword -and $securePassword.Length -gt 0) {
                            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                            $config.ServiceAccountPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                            $securePassword = $null
                            $config.ConfigureServiceAccount = $true
                            Write-Info "  Password accepted. Will configure service account after installation."
                            break
                        }

                        Write-Warning "  Password cannot be empty. Please try again."
                        $passwordAttempts++
                    }
                    catch {
                        Write-Warning "  Error reading password: $_"
                        $passwordAttempts++
                        if ($passwordAttempts -ge $maxAttempts) {
                            Write-Warning "  Maximum attempts reached. Service will run as SYSTEM."
                            Write-Warning "  You can manually configure it later using: sc.exe config $ServiceName obj= $($config.TargetServiceAccount) password= YourPassword"
                            $config.TargetServiceAccount = $null
                            break
                        }
                    }
                }
            }
        }
        "networkservice" {
            $config.TargetServiceAccount = "NT AUTHORITY\NETWORK SERVICE"
            Write-Info "  Service will be configured to run as: $($config.TargetServiceAccount)"
            if ($UseCredentialManager) {
                Write-Warning "  WARNING: Network Service cannot access Windows Credential Manager!"
                Write-Warning "  If you need Credential Manager, you must change the service account to a user account after installation."
            }
        }
        "localsystem" {
            $config.TargetServiceAccount = "LocalSystem"
            Write-Info "  Service will be configured to run as: $($config.TargetServiceAccount) (SYSTEM)"
            if ($UseCredentialManager) {
                Write-Warning "  WARNING: Local System cannot access Windows Credential Manager!"
                Write-Warning "  If you need Credential Manager, you must change the service account to a user account after installation."
            }
        }
        default {
            Write-Warning "  Unknown service account option: $ServiceAccount. Defaulting to SYSTEM."
        }
    }

    return $config
}

function Install-WindowsService {
    param(
        [string]$ServiceName,
        [string]$ServiceDisplayName,
        [string]$ServiceDescription,
        [string]$ExePath,
        [string]$InstallPath,
        [string]$NssmPath = "",
        [string]$LogDirectory = "",
        [string]$AppParameters = "",
        [psobject]$ServiceAccountConfig = $null,
        [string]$FriendlyName = "service",
        [string]$NssmMessage = "  Using NSSM to create service...",
        [string]$NoNssmWarning = ""
    )

    $result = [PSCustomObject]@{
        Created = $false
        UsedNssm = $false
        PendingCredentialServiceAccount = ""
        PendingCredentialServicePassword = ""
    }

    Remove-ServiceIfExists -ServiceName $ServiceName -NssmPath $NssmPath -FriendlyName $FriendlyName

    if (![string]::IsNullOrWhiteSpace($LogDirectory) -and !(Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    if ($NssmPath) {
        Write-Info $NssmMessage
        try {
            $nssmInstallOutput = & $NssmPath install $ServiceName "$ExePath" 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Success "[OK] Service '$ServiceName' installed successfully using NSSM"
                & $NssmPath set $ServiceName DisplayName "$ServiceDisplayName" 2>&1 | Out-Null
                & $NssmPath set $ServiceName Description "$ServiceDescription" 2>&1 | Out-Null
                & $NssmPath set $ServiceName AppDirectory "$InstallPath" 2>&1 | Out-Null
                if (![string]::IsNullOrWhiteSpace($AppParameters)) {
                    & $NssmPath set $ServiceName AppParameters "$AppParameters" 2>&1 | Out-Null
                }
                & $NssmPath set $ServiceName Start SERVICE_AUTO_START 2>&1 | Out-Null

                if (![string]::IsNullOrWhiteSpace($LogDirectory)) {
                    $stdoutLog = Join-Path $LogDirectory "${ServiceName}_stdout.log"
                    $stderrLog = Join-Path $LogDirectory "${ServiceName}_stderr.log"
                    & $NssmPath set $ServiceName AppStdout "$stdoutLog" 2>&1 | Out-Null
                    & $NssmPath set $ServiceName AppStderr "$stderrLog" 2>&1 | Out-Null
                }

                if ($ServiceAccountConfig -and $ServiceAccountConfig.TargetServiceAccount) {
                    if ($ServiceAccountConfig.TargetServiceAccount -match "^(LocalSystem|NT AUTHORITY\\NETWORK SERVICE)$") {
                        Write-Info "  Configuring service to run as $($ServiceAccountConfig.TargetServiceAccount)..."
                        & $NssmPath set $ServiceName ObjectName $ServiceAccountConfig.TargetServiceAccount 2>&1 | Out-Null
                    } elseif ($ServiceAccountConfig.ServiceAccountPassword) {
                        Write-Info "  Configuring service to run as $($ServiceAccountConfig.TargetServiceAccount)..."
                        Write-Info "  Note: Password will be stored securely in Windows registry (not plain text)"

                        $nssmAccountName = $ServiceAccountConfig.TargetServiceAccount
                        if ($ServiceAccountConfig.TargetServiceAccount -match "^$([regex]::Escape($env:COMPUTERNAME))\\(.+)$") {
                            $nssmAccountName = ".\$($matches[1])"
                        }

                        $nssmAccountOutput = & $NssmPath set $ServiceName ObjectName "$nssmAccountName" "$($ServiceAccountConfig.ServiceAccountPassword)" 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Success "  [OK] Service account configured successfully (password stored securely)"
                            $result.PendingCredentialServiceAccount = $nssmAccountName
                            $result.PendingCredentialServicePassword = $ServiceAccountConfig.ServiceAccountPassword
                        } else {
                            Write-Warning "  [!] Failed to configure service account (exit code: $LASTEXITCODE)"
                            Write-Warning "  [!] Error: $nssmAccountOutput"
                            Write-Warning "  [!] Service will run as SYSTEM"
                        }
                    } else {
                        Write-Warning "  [!] Password was not provided. Service will run as SYSTEM."
                    }
                }

                $result.Created = $true
                $result.UsedNssm = $true
                return $result
            }

            Write-Warning "  [!] NSSM service installation failed (exit code: $LASTEXITCODE)"
            if ($nssmInstallOutput) {
                Write-Warning "    Error: $nssmInstallOutput"
            }
            Write-Warning "  [!] Service may be left in 'marked for deletion' state"
            Write-Warning "  [!] Solution: Restart the system, or wait 30+ seconds and try again"
        }
        catch {
            Write-Warning "  [!] Failed to create service with NSSM: $_"
        }
    }

    if (![string]::IsNullOrWhiteSpace($NoNssmWarning) -and -not $NssmPath) {
        Write-Warning $NoNssmWarning
    } elseif ($NssmPath) {
        Write-Info "  Falling back to sc.exe method..."
    }

    try {
        $binPath = if ([string]::IsNullOrWhiteSpace($AppParameters)) { "`"$ExePath`"" } else { "`"$ExePath`" $AppParameters" }
        $createOutput = sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= $ServiceDisplayName 2>&1
        $createOutputString = $createOutput | Out-String

        if ($LASTEXITCODE -eq 0) {
            Write-Success "[OK] Service '$ServiceName' created successfully"
            try {
                sc.exe description $ServiceName $ServiceDescription | Out-Null
            }
            catch {
                Write-Warning "  [!] Could not set service description: $_"
            }

            $result.Created = $true
        } else {
            Write-Warning "[!] Failed to create service (exit code: $LASTEXITCODE)"
            if ($createOutputString) {
                Write-Warning "  Error output: $createOutputString"
            }
            Write-Warning "  Service creation may require administrator privileges"
            Write-Warning "  If service was deleted but creation failed, it may be 'marked for deletion'"
            Write-Warning "  Solution: Restart the system, or wait 30+ seconds and run installer again"
        }
    }
    catch {
        Write-Warning "[!] Could not create service: $_"
        Write-Warning "  Service creation may require administrator privileges"
    }

    return $result
}

function Resolve-ModelDownloadRequest {
    param(
        [string]$EnvPath,
        [string]$AWSKey,
        [string]$AWSSecret,
        [string]$AWSRegion,
        [bool]$CredentialsProvidedViaParams = $false,
        [switch]$NonInteractive
    )

    $request = [PSCustomObject]@{
        AwsKey = ""
        AwsSecret = ""
        AwsRegion = ""
        CredentialsProvidedViaParams = $CredentialsProvidedViaParams
    }

    Write-Info "  Debug: Checking AWS parameters..."
    Write-Info "    AWSKey parameter provided: $CredentialsProvidedViaParams, Value length: $($AWSKey.Length)"
    Write-Info "    AWSSecret parameter provided: $CredentialsProvidedViaParams, Value length: $($AWSSecret.Length)"
    Write-Info "    AWSRegion parameter: '$AWSRegion'"
    Write-Info "    credentialsProvidedViaParams: $($request.CredentialsProvidedViaParams)"

    if (-not [string]::IsNullOrWhiteSpace($AWSKey)) {
        $request.AwsKey = $AWSKey
        Write-Info "    Using AWSKey from parameters"
    }
    if (-not [string]::IsNullOrWhiteSpace($AWSSecret)) {
        $request.AwsSecret = $AWSSecret
        Write-Info "    Using AWSSecret from parameters"
    }
    if (-not [string]::IsNullOrWhiteSpace($AWSRegion)) {
        $request.AwsRegion = $AWSRegion
        Write-Info "    Using AWSRegion from parameters"
    }

    if (([string]::IsNullOrWhiteSpace($request.AwsKey) -or [string]::IsNullOrWhiteSpace($request.AwsSecret)) -and (Test-Path $EnvPath)) {
        Write-Info "  Reading AWS credentials from .env file..."
        $envValues = Get-EnvFileValues -Path $EnvPath

        if ([string]::IsNullOrWhiteSpace($request.AwsKey) -and $envValues.ContainsKey("AWS_KEY")) {
            $request.AwsKey = $envValues["AWS_KEY"]
            Write-Info "  Found AWS_KEY in .env: $($request.AwsKey.Substring(0, [Math]::Min(10, $request.AwsKey.Length)))..."
        }
        if ([string]::IsNullOrWhiteSpace($request.AwsSecret) -and $envValues.ContainsKey("AWS_SECRET")) {
            $request.AwsSecret = $envValues["AWS_SECRET"]
            Write-Info "  Found AWS_SECRET in .env: $($request.AwsSecret.Substring(0, [Math]::Min(10, $request.AwsSecret.Length)))..."
        }
        if ([string]::IsNullOrWhiteSpace($request.AwsRegion) -and $envValues.ContainsKey("AWS_REGION") -and ![string]::IsNullOrWhiteSpace($envValues["AWS_REGION"])) {
            $request.AwsRegion = $envValues["AWS_REGION"]
            Write-Info "  Found AWS_REGION in .env: $($request.AwsRegion)"
        }
    }

    if (([string]::IsNullOrWhiteSpace($request.AwsKey) -or [string]::IsNullOrWhiteSpace($request.AwsSecret)) -and -not $request.CredentialsProvidedViaParams) {
        Write-Info ""
        Write-Info "AWS credentials required for model download"
        Write-Info "============================================="
        Write-Info ""
        Write-Info "The model is stored in AWS S3 and requires credentials to download."
        Write-Info ""

        if ([string]::IsNullOrWhiteSpace($request.AwsKey)) {
            if ($NonInteractive) { $request.AwsKey = "" } else { $request.AwsKey = Read-Host "Enter AWS Access Key ID" }
        }
        if ([string]::IsNullOrWhiteSpace($request.AwsSecret)) {
            if ($NonInteractive) {
                $request.AwsSecret = ""
            } else {
                $secureSecret = Read-Host "Enter AWS Secret Access Key" -AsSecureString
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
                $request.AwsSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            }
        }

        if ($NonInteractive) { $regionInput = "" } else { $regionInput = Read-Host "Enter AWS Region (press Enter for us-east-1)" }
        if (![string]::IsNullOrWhiteSpace($regionInput)) {
            $request.AwsRegion = $regionInput.Trim()
        }

        if (Test-Path $EnvPath) {
            $envContent = Get-Content $EnvPath -Raw
            $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_KEY" -Value $request.AwsKey
            $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_SECRET" -Value $request.AwsSecret
            $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_REGION" -Value $request.AwsRegion
            Set-Content -Path $EnvPath -Value $envContent -Force
            Write-Success "[OK] AWS credentials saved to .env file"
        }
    }

    $request.AwsRegion = Get-FirstNonEmpty @($request.AwsRegion, "us-east-1")

    return $request
}

function Download-ModelIfRequested {
    param(
        [string]$ModelDir,
        [string]$EnvPath,
        [string]$AWSKey,
        [string]$AWSSecret,
        [string]$AWSRegion,
        [bool]$CredentialsProvidedViaParams = $false,
        [switch]$NonInteractive
    )

    $request = Resolve-ModelDownloadRequest `
        -EnvPath $EnvPath `
        -AWSKey $AWSKey `
        -AWSSecret $AWSSecret `
        -AWSRegion $AWSRegion `
        -CredentialsProvidedViaParams $CredentialsProvidedViaParams `
        -NonInteractive:$NonInteractive

    if ([string]::IsNullOrWhiteSpace($request.AwsKey) -or [string]::IsNullOrWhiteSpace($request.AwsSecret)) {
        Write-Error-Custom "ERROR: AWS credentials are required but not provided"
        Write-Info "  Please provide AWS_KEY and AWS_SECRET in the .env file or when prompted"
        Write-Info "  Skipping model download"
        return [PSCustomObject]@{ Success = $false; Reason = "Model download (AWS credentials missing)" }
    }

    $awsCli = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsCli) {
        Write-Warning "[!] AWS CLI not found in PATH"
        Write-Info "  Install AWS CLI and re-run the installer, or run:"
        Write-Info "    aws s3 sync s3://rfq-models/Mistral-7B-Instruct-v0-3/ `"$ModelDir`""
        return [PSCustomObject]@{ Success = $false; Reason = "Model download (AWS CLI not found)" }
    }

    $previousEnvironment = Set-TemporaryEnvironment @{
        AWS_ACCESS_KEY_ID = $request.AwsKey
        AWS_SECRET_ACCESS_KEY = $request.AwsSecret
        AWS_DEFAULT_REGION = $request.AwsRegion
    }

    try {
        Write-Info "Running model download with aws s3 sync..."
        & aws s3 sync "s3://rfq-models/Mistral-7B-Instruct-v0-3/" $ModelDir --region $request.AwsRegion --exclude ".cache/*" --exclude "*/.cache/*" --exclude "*.lock" --exclude "*.metadata"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[!] Model download failed or was interrupted"
            Write-Info "  You can download it later using:"
            Write-Info "    aws s3 sync s3://rfq-models/Mistral-7B-Instruct-v0-3/ `"$ModelDir`" --region $($request.AwsRegion)"
            return [PSCustomObject]@{ Success = $false; Reason = "Model download (download failed or interrupted)" }
        }

        Write-Success "[OK] Model downloaded successfully from S3"
        if (Test-Path $EnvPath) {
            $modelPathNormalized = $ModelDir.Replace('\', '/')
            $envContent = Get-Content $EnvPath -Raw
            $envContent = Set-OrAddEnvValue -Content $envContent -Key "MODEL_PATH" -Value $modelPathNormalized
            Set-Content -Path $EnvPath -Value $envContent -Force
            Write-Success "[OK] Updated MODEL_PATH in .env file: $modelPathNormalized"
        }

        return [PSCustomObject]@{ Success = $true; Reason = "" }
    }
    finally {
        Restore-TemporaryEnvironment -PreviousValues $previousEnvironment
    }
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
    if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
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

$script:ResolvedChannel = if (![string]::IsNullOrWhiteSpace($Channel)) {
    $Channel
} elseif (![string]::IsNullOrWhiteSpace($UpdateChannel)) {
    $UpdateChannel
} else {
    "customer"
}

# Configuration - Determine repository based on update channel
if ($script:ResolvedChannel -eq "internal") {
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
    if ($NonInteractive) { $continue = "y" } else { $continue = Read-Host "Continue anyway? (y/N)" }
    if ($continue -ne 'y') {
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
        if ($NonInteractive) { $overwrite = if ($OverwriteExisting) { "y" } else { "" } } else { $overwrite = Read-Host "Overwrite existing installation? (y/N)" }
        if ($overwrite -ne 'y') {
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

# ── Resolve release source: S3 first, GitHub fallback ──────────────────────
$script:ReleaseSource = "github"   # track where release came from
$S3LatestPayload = $null

# Read S3 config from params, env, or .env file
$s3Bucket = $S3ReleaseBucket
$s3Region = $S3ReleaseRegion
$s3AwsKey = $AWSKey
$s3AwsSecret = $AWSSecret
if ([string]::IsNullOrWhiteSpace($s3Bucket) -and (Test-Path (Join-Path $InstallPath ".env"))) {
    $envContent = Get-Content (Join-Path $InstallPath ".env") -Raw -ErrorAction SilentlyContinue
    if ($envContent -match "S3_RELEASE_BUCKET\s*=\s*([^\r\n]+)") { $s3Bucket = $matches[1].Trim() }
    if ([string]::IsNullOrWhiteSpace($s3Region) -and $envContent -match "S3_RELEASE_REGION\s*=\s*([^\r\n]+)") { $s3Region = $matches[1].Trim() }
    if ([string]::IsNullOrWhiteSpace($s3AwsKey) -and $envContent -match "AWS_KEY\s*=\s*([^\r\n]+)") { $s3AwsKey = $matches[1].Trim() }
    if ([string]::IsNullOrWhiteSpace($s3AwsSecret) -and $envContent -match "AWS_SECRET\s*=\s*([^\r\n]+)") { $s3AwsSecret = $matches[1].Trim() }
}
if ([string]::IsNullOrWhiteSpace($s3Region)) { $s3Region = if (![string]::IsNullOrWhiteSpace($AWSRegion)) { $AWSRegion } else { "us-east-1" } }

Write-Info "`n[4/8] Checking authentication..."

if (![string]::IsNullOrWhiteSpace($s3Bucket) -and ![string]::IsNullOrWhiteSpace($s3AwsKey) -and ![string]::IsNullOrWhiteSpace($s3AwsSecret)) {
    Write-Info "  S3 release bucket configured: $s3Bucket (region: $s3Region)"

    # ── Try to load CloudFront signing config from S3 ──
    Write-Info "  Checking for CloudFront signing configuration..."
    $cfConfig = Get-CloudFrontSigningConfig -Bucket $s3Bucket -Region $s3Region -AwsKey $s3AwsKey -AwsSecret $s3AwsSecret

    Write-Info "  Attempting to fetch latest release from S3..."

    try {
        $s3Channel = $script:ResolvedChannel.ToLower()
        $s3Key = "$s3Channel/windows/latest.json"
        $s3TempFile = Join-Path $env:TEMP "rfq_s3_latest.json"

        $s3DownloadOk = $false

        # ── CloudFront path ──
        if ($script:CloudFrontConfig) {
            try {
                $cfSignedUrl = New-CloudFrontSignedUrl -Path $s3Key
                if ($cfSignedUrl) {
                    Write-Info "    Downloading latest.json via CloudFront..."
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $cfSignedUrl -OutFile $s3TempFile -UseBasicParsing
                    $s3DownloadOk = $true
                }
            }
            catch {
                Write-Warning "    CloudFront download failed for latest.json: $_ (falling back to direct S3)"
            }
        }

        # ── Direct S3 fallback ──
        if (-not $s3DownloadOk) {
            $env:AWS_ACCESS_KEY_ID = $s3AwsKey
            $env:AWS_SECRET_ACCESS_KEY = $s3AwsSecret
            & aws s3api get-object --bucket $s3Bucket --key $s3Key --region $s3Region $s3TempFile *>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $s3DownloadOk = $true }
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        }

        if ($s3DownloadOk -and (Test-Path $s3TempFile)) {
            $S3LatestPayload = Get-Content $s3TempFile -Raw | ConvertFrom-Json
            Remove-Item $s3TempFile -Force -ErrorAction SilentlyContinue

            $Version = $S3LatestPayload.version
            if (![string]::IsNullOrWhiteSpace($Version)) {
                $script:ReleaseSource = "s3"

                # Build a Release-like object from S3 payload so downstream code works
                $s3Assets = @()
                foreach ($asset in $S3LatestPayload.assets) {
                    $s3Assets += [PSCustomObject]@{
                        name = $asset.name
                        url = $asset.url
                        size = $asset.size
                        browser_download_url = $asset.url
                        source = "s3"
                    }
                }
                $Release = [PSCustomObject]@{
                    tag_name = $Version
                    assets = $s3Assets
                }

                Write-Success "[OK] Found version via S3: $Version"
            } else {
                Write-Warning "  S3 latest.json did not contain a version, falling back to GitHub..."
            }
        } else {
            Write-Warning "  Failed to fetch latest.json from S3, falling back to GitHub..."
        }
    }
    catch {
        Write-Warning "  S3 check failed: $_, falling back to GitHub..."
    }
    finally {
        # Clean up env vars so they don't leak into other processes unexpectedly
        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
    }
}

# Initialize $Headers so downstream code can safely reference it even when
# S3 is the primary source. Without this, $Headers["Authorization"] throws
# "Cannot index into a null array" during S3-only installs.
if (!$Headers) { $Headers = @{} }

# GitHub fallback (or primary if no S3 config)
if ($script:ReleaseSource -ne "s3") {
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

        if ($NonInteractive) { $GitHubToken = "" } else { $GitHubToken = Read-Host "Please enter your GitHub Personal Access Token (ghp_...)" }
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
}

# Get latest release
Write-Info "`n[5/8] Checking for latest installation package..."

if ($script:ReleaseSource -ne "s3") {
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
} else {
    Write-Success "[OK] Using S3 release: $Version"
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
        if ($script:ReleaseSource -eq "s3") {
            # Resolve S3 key — may be a full S3 URL or a relative path from latest.json
            $manifestUrl = $ManifestAsset.url
            if ($manifestUrl -match "https://([^.]+)\.s3(?:\.[^.]+)?\.amazonaws\.com/(.+)") {
                $manifestS3Key = $matches[2]
            } elseif ($manifestUrl -notmatch "^https?://") {
                # Relative path from S3 latest.json (e.g. "customer/windows/.../manifest.json")
                $manifestS3Key = $manifestUrl
            } else {
                throw "Could not parse S3 URL: $manifestUrl"
            }

            $manifestDownloadOk = $false

            # ── CloudFront path ──
            if ($script:CloudFrontConfig) {
                try {
                    $cfSignedUrl = New-CloudFrontSignedUrl -Path $manifestS3Key
                    if ($cfSignedUrl) {
                        Write-Info "    Downloading manifest via CloudFront..."
                        $ProgressPreference = 'SilentlyContinue'
                        Invoke-WebRequest -Uri $cfSignedUrl -OutFile $ManifestPath -UseBasicParsing
                        $manifestDownloadOk = $true
                    }
                }
                catch {
                    Write-Warning "    CloudFront download failed for manifest: $_ (falling back to direct S3)"
                }
            }

            # ── Direct S3 fallback ──
            if (-not $manifestDownloadOk) {
                Write-Info "    Downloading from S3: s3://$s3Bucket/$manifestS3Key"
                $env:AWS_ACCESS_KEY_ID = $s3AwsKey
                $env:AWS_SECRET_ACCESS_KEY = $s3AwsSecret
                & aws s3api get-object --bucket $s3Bucket --key $manifestS3Key --region $s3Region $ManifestPath *>&1 | Out-Null
                Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
                Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) { $manifestDownloadOk = $true }
            }

            if (-not $manifestDownloadOk) { throw "Failed to download manifest from S3 (all methods)" }
        } else {
            $DownloadHeaders = $Headers.Clone()
            $DownloadHeaders["Accept"] = "application/octet-stream"
            Write-Info "    Downloading from: $($ManifestAsset.url)"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $ManifestAsset.url -OutFile $ManifestPath -Headers $DownloadHeaders -UseBasicParsing
        }

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

            $Asset = $null
            $SourceTag = $Version

            if ($script:ReleaseSource -eq "s3") {
                # S3: all assets are already in the Release object
                $Asset = Find-AssetInRelease -ReleaseObj $Release -Filename $Filename
                if ($Asset) {
                    Write-Info "    Found in S3 release: $Version"
                }
            } else {
                # GitHub: check minimum_versions, current release, then search all releases
                if ($Manifest.minimum_versions -and $Manifest.minimum_versions.$ComponentName) {
                    $ComponentVersion = $Manifest.minimum_versions.$ComponentName

                    if ($ComponentVersion -eq $Version) {
                        $Asset = Find-AssetInRelease -ReleaseObj $Release -Filename $Filename
                        if ($Asset) {
                            Write-Info "    Found in current release: $Version"
                        }
                    } else {
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
                        if ($PreviousRelease.tag_name -eq $Version) { continue }
                        if ($Manifest.minimum_versions -and $Manifest.minimum_versions.$ComponentName -and
                            $PreviousRelease.tag_name -eq $Manifest.minimum_versions.$ComponentName) { continue }

                        $Asset = Find-AssetInRelease -ReleaseObj $PreviousRelease -Filename $Filename
                        if ($Asset) {
                            $SourceTag = $PreviousRelease.tag_name
                            Write-Info "    Found in previous release: $($PreviousRelease.tag_name)"
                            break
                        }
                    }
                }
            }

            if (!$Asset) {
                Write-Warning "  [!] Asset not found: $Filename (skipping)"
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
                # Check for existing download - skip if file exists and size matches (only if not clean reinstall)
                if (!$CleanReinstall -and (Test-Path $FilePath)) {
                    $existingSize = (Get-Item $FilePath).Length
                    if ($existingSize -eq $ExpectedSize) {
                        Write-Success "    [SKIP] Already downloaded: $Filename (size matches, skipping download)"
                        $filesDownloaded++
                        continue
                    } else {
                        if ($existingSize -gt 0 -and $existingSize -lt $ExpectedSize) {
                            Write-Info "    Partial file found ($([math]::Round($existingSize / 1MB, 2)) MB), removing and downloading fresh copy..."
                        } elseif ($existingSize -gt $ExpectedSize) {
                            Write-Warning "    Existing file is larger than expected ($([math]::Round($existingSize / 1MB, 2)) MB vs $([math]::Round($ExpectedSize / 1MB, 2)) MB)"
                            Write-Info "    Removing existing file and downloading fresh copy..."
                        }
                        Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
                    }
                }

                # Show file size and estimated time for large downloads
                $sizeMsg = "$FileSizeMB MB"
                if ($FileSizeMB -gt 500) {
                    Write-Info "    Downloading: $Filename ($sizeMsg) - this file is large and may take several minutes. Please wait..."
                } else {
                    Write-Info "    Downloading: $Filename ($sizeMsg)..."
                }

                $downloadStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

                if ($script:ReleaseSource -eq "s3") {
                    # Resolve S3 key — may be a full S3 URL or a relative path from latest.json
                    $assetUrl = $Asset.url
                    if ($assetUrl -match "https://([^.]+)\.s3(?:\.[^.]+)?\.amazonaws\.com/(.+)") {
                        $assetS3Key = $matches[2]
                    } elseif ($assetUrl -notmatch "^https?://") {
                        $assetS3Key = $assetUrl
                    } else {
                        throw "Could not parse S3 URL: $assetUrl"
                    }

                    $assetDownloadOk = $false

                    # ── CloudFront path ──
                    if ($script:CloudFrontConfig) {
                        try {
                            $cfSignedUrl = New-CloudFrontSignedUrl -Path $assetS3Key
                            if ($cfSignedUrl) {
                                Write-Info "    Downloading via CloudFront..."
                                # Use WebClient.DownloadFile instead of Invoke-WebRequest to
                                # stream directly to disk. Invoke-WebRequest on PS 5.1 buffers
                                # the entire response into a Byte[] array, which hits the .NET
                                # Framework 2 GB array size limit on large component files.
                                (New-Object System.Net.WebClient).DownloadFile($cfSignedUrl, $FilePath)
                                $assetDownloadOk = $true
                            }
                        }
                        catch {
                            Write-Warning "    CloudFront download failed for $Filename : $_ (falling back to direct S3)"
                        }
                    }

                    # ── Direct S3 fallback ──
                    if (-not $assetDownloadOk) {
                        $env:AWS_ACCESS_KEY_ID = $s3AwsKey
                        $env:AWS_SECRET_ACCESS_KEY = $s3AwsSecret
                        & aws s3api get-object --bucket $s3Bucket --key $assetS3Key --region $s3Region $FilePath *>&1 | Out-Null
                        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
                        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
                        if ($LASTEXITCODE -eq 0) { $assetDownloadOk = $true }
                    }

                    if (-not $assetDownloadOk) { throw "Failed to download $Filename from S3 (all methods)" }
                } else {
                    # GitHub download — Invoke-WebRequest handles GitHub API redirects
                    # correctly with the Accept/Authorization headers
                    $DownloadHeaders = @{
                        "Accept" = "application/octet-stream"
                        "Authorization" = $Headers["Authorization"]
                    }
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $Asset.url -OutFile $FilePath -Headers $DownloadHeaders -UseBasicParsing
                }

                $downloadStopwatch.Stop()
                $downloadSeconds = [math]::Round($downloadStopwatch.Elapsed.TotalSeconds, 1)

                # Verify downloaded file size matches expected size
                $DownloadedFile = Get-Item $FilePath
                if ($DownloadedFile.Length -ne $ExpectedSize) {
                    Write-Warning "    [!] Downloaded file size mismatch: $($DownloadedFile.Length) vs expected $ExpectedSize bytes"
                    Write-Warning "    [!] File may be corrupted, will be re-downloaded on next run"
                } else {
                    $speedMBs = if ($downloadSeconds -gt 0) { [math]::Round($FileSizeMB / $downloadSeconds, 1) } else { 0 }
                    Write-Success "    [OK] Downloaded: $Filename (${downloadSeconds}s, ${speedMBs} MB/s)"
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

            # Verify zip integrity before extraction
            Write-Info "    Verifying archive integrity..."
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                $zipTest = [System.IO.Compression.ZipFile]::OpenRead($ComponentZip)
                $entryCount = $zipTest.Entries.Count
                $zipTest.Dispose()
                if ($entryCount -eq 0) {
                    Write-Error-Custom "ERROR: Archive is empty or corrupt (0 entries): $ComponentZip"
                    Exit-WithError
                }
                Write-Success "    [OK] Archive valid ($entryCount entries)"
            }
            catch {
                Write-Error-Custom "ERROR: Archive integrity check failed: $_"
                Write-Error-Custom "  The downloaded file may be corrupt. Delete it and re-run the installer:"
                Write-Error-Custom "  Remove-Item '$ComponentZip' -Force"
                Exit-WithError
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

# Check if Windows Credential Manager should be used
$UseCredentialManagerForPasswords = $false
if ($UseCredentialManager) {
    if (Test-CredentialManagerAvailable) {
        $UseCredentialManagerForPasswords = $true
        Write-Success "[OK] Windows Credential Manager detected - will store passwords securely"
    } else {
        Write-Warning "[!] Windows Credential Manager not available - falling back to .env file"
        $UseCredentialManagerForPasswords = $false
    }
}

$EnvPath = Join-Path $InstallPath ".env"
$EnvTemplatePath = Join-Path $InstallPath ".env.template"
$script:PendingCredentials = @()

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
    
    if ($UseCredentialManagerForPasswords) {
        Write-Info "  Passwords will be stored in Windows Credential Manager..."
        Write-Info "  Note: Credentials will be saved to the service user's credential store after service configuration"
        
        $anyPasswordStored = $false
        
        if ($SuperUserPasswordAlreadyStored) {
            Write-Info "    [SKIP] SQL_SUPER_USER already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_SQL_SUPER_USER" -UserName "postgres" -Password $SuperUserPassword -AlreadyStored:$SuperUserPasswordAlreadyStored) {
            $anyPasswordStored = $true
        }
        
        if ($RFQUserPasswordAlreadyStored) {
            Write-Info "    [SKIP] RFQ_USER_PASSWORD already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_RFQ_USER_PASSWORD" -UserName "rfq_user" -Password $RFQUserPassword -AlreadyStored:$RFQUserPasswordAlreadyStored) {
            $anyPasswordStored = $true
        }
        
        if ($SettingsPasswordAlreadyStored) {
            Write-Info "    [SKIP] SETTINGS_PASSWORD already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_SETTINGS_PASSWORD" -UserName "rfq_app" -Password $SettingsPassword -AlreadyStored:$SettingsPasswordAlreadyStored) {
            $anyPasswordStored = $true
        }
        
        if ($anyPasswordStored) {
            Write-Info "  Passwords will be saved to service user's credential store after service account is configured"
        }
        
        if ($anyPasswordStored) {
            # Use placeholders in .env file - passwords will be saved to service user's store after service configuration
            $EnvContent = $EnvContent -replace "SQL_SUPER_USER=.*", "SQL_SUPER_USER=__CREDENTIAL_MANAGER__"
            $EnvContent = $EnvContent -replace "RFQ_USER_PASSWORD=.*", "RFQ_USER_PASSWORD=__CREDENTIAL_MANAGER__"
            $EnvContent = $EnvContent -replace "SETTINGS_PASSWORD=.*", "SETTINGS_PASSWORD=__CREDENTIAL_MANAGER__"
        } else {
            # No passwords to save, use defaults
            $EnvContent = $EnvContent -replace "SQL_SUPER_USER=.*", "SQL_SUPER_USER=$SuperUserPassword"
            $EnvContent = $EnvContent -replace "RFQ_USER_PASSWORD=.*", "RFQ_USER_PASSWORD=$RFQUserPassword"
            $EnvContent = $EnvContent -replace "SETTINGS_PASSWORD=.*", "SETTINGS_PASSWORD=$SettingsPassword"
        }
    } else {
        # Store passwords in .env file (traditional method)
        $EnvContent = $EnvContent -replace "SQL_SUPER_USER=.*", "SQL_SUPER_USER=$SuperUserPassword"
        $EnvContent = $EnvContent -replace "RFQ_USER_PASSWORD=.*", "RFQ_USER_PASSWORD=$RFQUserPassword"
        $EnvContent = $EnvContent -replace "SETTINGS_PASSWORD=.*", "SETTINGS_PASSWORD=$SettingsPassword"
    }
    
    $EnvContent = $EnvContent -replace "GITHUB_PAT=.*", "GITHUB_PAT=$GitHubToken"
    $EnvContent = $EnvContent -replace "GITHUB_USERNAME=.*", "GITHUB_USERNAME=RFQdebugging"
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
    $EnvContent = $EnvContent -replace "RFQ_UPDATE_CHANNEL=.*", "RFQ_UPDATE_CHANNEL=$script:ResolvedChannel"
    # REQUESTS_CA_BUNDLE is left empty by default - user will fill it in if needed for GCC High
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
        if ($UseCredentialManagerForPasswords) {
            $EnvContent += "`nSQL_SUPER_USER=__CREDENTIAL_MANAGER__"
        } else {
            $EnvContent += "`nSQL_SUPER_USER=$SuperUserPassword"
        }
    }
    if ($EnvContent -notmatch "RFQ_USER_PASSWORD") {
        if ($UseCredentialManagerForPasswords) {
            $EnvContent += "`nRFQ_USER_PASSWORD=__CREDENTIAL_MANAGER__"
        } else {
            $EnvContent += "`nRFQ_USER_PASSWORD=$RFQUserPassword"
        }
    }
    if ($EnvContent -notmatch "SETTINGS_PASSWORD") {
        if ($UseCredentialManagerForPasswords) {
            $EnvContent += "`nSETTINGS_PASSWORD=__CREDENTIAL_MANAGER__"
        } else {
            $EnvContent += "`nSETTINGS_PASSWORD=$SettingsPassword"
        }
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
    if ($EnvContent -notmatch "PORT") {
        $EnvContent += "`nPORT=8000"
    }
    if ($EnvContent -notmatch "OAUTH_PORT_LOGIN") {
        $EnvContent += "`nOAUTH_PORT_LOGIN=8502"
    }
    if ($EnvContent -notmatch "OAUTH_PORT_SEND_RECEIVE") {
        $EnvContent += "`nOAUTH_PORT_SEND_RECEIVE=8502"
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
        $EnvContent += "`nRFQ_UPDATE_CHANNEL=$script:ResolvedChannel"
    }
    if ($EnvContent -notmatch "REQUESTS_CA_BUNDLE") {
        $EnvContent += "`n# SSL Certificate Configuration (for GCC High and government cloud environments)`n# Path to CA bundle file for SSL certificate verification`n# Leave empty if not using GCC High or if using system default certificates`nREQUESTS_CA_BUNDLE="
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
    # Always write S3_RELEASE_BUCKET (defaults to rfq-distribution-us)
    $EnvContent = $EnvContent -replace "# ?S3_RELEASE_BUCKET=.*", "S3_RELEASE_BUCKET=$S3ReleaseBucket"
    if ($EnvContent -notmatch "S3_RELEASE_BUCKET") {
        $EnvContent += "`nS3_RELEASE_BUCKET=$S3ReleaseBucket"
    }
    if (![string]::IsNullOrWhiteSpace($S3ReleaseRegion)) {
        $EnvContent = $EnvContent -replace "# ?S3_RELEASE_REGION=.*", "S3_RELEASE_REGION=$S3ReleaseRegion"
        if ($EnvContent -notmatch "S3_RELEASE_REGION") {
            $EnvContent += "`nS3_RELEASE_REGION=$S3ReleaseRegion"
        }
    }

    # Add generation timestamp as comment
    $EnvContent = "# RFQ Application Configuration`n# Generated by installer on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" + $EnvContent
    
    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env from template with all configuration values"
}
else {
    # Create .env from scratch if template doesn't exist
    Write-Info "  .env.template not found, creating .env from default..."
    
    # Determine password values based on storage method
    $sqlSuperUserValue = $SuperUserPassword
    $rfqUserPasswordValue = $RFQUserPassword
    $settingsPasswordValue = $SettingsPassword
    
    if ($UseCredentialManagerForPasswords) {
        Write-Info "  Passwords will be stored in Windows Credential Manager..."
        Write-Info "  Note: Credentials will be saved to the service user's credential store after service configuration"
        
        $anyPasswordStored = $false
        
        if ($SuperUserPasswordAlreadyStored) {
            Write-Info "    [SKIP] SQL_SUPER_USER already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_SQL_SUPER_USER" -UserName "postgres" -Password $SuperUserPassword -AlreadyStored:$SuperUserPasswordAlreadyStored) {
            $sqlSuperUserValue = "__CREDENTIAL_MANAGER__"
            $anyPasswordStored = $true
        }
        
        if ($RFQUserPasswordAlreadyStored) {
            Write-Info "    [SKIP] RFQ_USER_PASSWORD already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_RFQ_USER_PASSWORD" -UserName "rfq_user" -Password $RFQUserPassword -AlreadyStored:$RFQUserPasswordAlreadyStored) {
            $rfqUserPasswordValue = "__CREDENTIAL_MANAGER__"
            $anyPasswordStored = $true
        }
        
        if ($SettingsPasswordAlreadyStored) {
            Write-Info "    [SKIP] SETTINGS_PASSWORD already stored in Windows Credential Manager (skipping)"
        }
        if (Add-PendingCredential -TargetName "RFQApplication_SETTINGS_PASSWORD" -UserName "rfq_app" -Password $SettingsPassword -AlreadyStored:$SettingsPasswordAlreadyStored) {
            $settingsPasswordValue = "__CREDENTIAL_MANAGER__"
            $anyPasswordStored = $true
        }
        
        if ($anyPasswordStored) {
            Write-Info "  Passwords will be saved to service user's credential store after service account is configured"
        } else {
            # No passwords to save, use defaults
            $sqlSuperUserValue = $SuperUserPassword
            $rfqUserPasswordValue = $RFQUserPassword
            $settingsPasswordValue = $SettingsPassword
        }
    }
    
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
PORT=8000

# Debug Configuration
DEBUG_THREAD=0

# Database Configuration (for setup_database_auto.ps1)
# SQL super user password (for database setup)
# Note: If value is __CREDENTIAL_MANAGER__, password is stored in Windows Credential Manager
SQL_SUPER_USER=$sqlSuperUserValue

# Database password (for rfq_user)
# Note: If value is __CREDENTIAL_MANAGER__, password is stored in Windows Credential Manager
RFQ_USER_PASSWORD=$rfqUserPasswordValue

# Settings password
# Note: If value is __CREDENTIAL_MANAGER__, password is stored in Windows Credential Manager
SETTINGS_PASSWORD=$settingsPasswordValue

# Azure Configuration
AZURE_CONFIG_ENCRYPTION_KEY=$AzureKey

# SSL Certificate Configuration (for GCC High and government cloud environments)
# Path to CA bundle file for SSL certificate verification
# Leave empty if not using GCC High or if using system default certificates
REQUESTS_CA_BUNDLE=

# Update Channel
RFQ_UPDATE_CHANNEL=$script:ResolvedChannel
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

    # Add S3 Release Bucket if provided
    if (![string]::IsNullOrWhiteSpace($S3ReleaseBucket)) {
        $EnvContent += "`n# S3 Release Bucket (enables S3-based updates instead of GHCR)`n"
        $EnvContent += "S3_RELEASE_BUCKET=$S3ReleaseBucket`n"
        if (![string]::IsNullOrWhiteSpace($S3ReleaseRegion)) {
            $EnvContent += "S3_RELEASE_REGION=$S3ReleaseRegion`n"
        }
    }

    Set-Content -Path $EnvPath -Value $EnvContent -Force
    Write-Success "[OK] Created .env configuration with all values"
}

# Create version file
$VersionPath = Join-Path $InstallPath "version.txt"
Set-Content -Path $VersionPath -Value $Version -Force

# Download LLM model (optional)
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
    Write-Info "The application requires the LLM (language model)."
    Write-Info "This is a large download (~30 GB) and may take 30-60 minutes depending on your internet connection."
    Write-Info ""
    Write-Info "Options:"
    Write-Info "  [Y] Yes - Download now (recommended)"
    Write-Info "  [n] No - Skip download (you can download later)"
    Write-Info ""
    if ($NonInteractive) { $downloadModel = "n"; Write-Info "  NonInteractive: skipping model download (use -ModelPath to provide a pre-downloaded model)" } else { $downloadModel = Read-Host "Would you like to download the model now? (Y/n)" }
    
    if ($downloadModel -ne 'n' -and $downloadModel -ne 'N') {
        Write-Info ""
        Write-Info "Please choose where to download the model:"
        Write-Info "  - The model will be downloaded to a subdirectory in your chosen location"
        Write-Info "  - Default: $env:USERPROFILE\Documents\RFQ_Models"
        Write-Info ""
        
        $defaultModelPath = Join-Path $env:USERPROFILE "Documents\RFQ_Models"
        if ($NonInteractive) { $modelBasePath = "" } else { $modelBasePath = Read-Host "Enter model download directory (press Enter for default: $defaultModelPath)" }
        
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
        Write-Info "Downloading LLM model from AWS S3..."
        Write-Info "  Bucket: rfq-models"
        Write-Info "  Destination: $modelDir"
        Write-Info "  This is a large download (~30 GB) and may take 30-60 minutes depending on your internet connection..."
        Write-Info ""
        
        $credentialsProvidedViaParams = ($PSBoundParameters.ContainsKey('AWSKey') -or $PSBoundParameters.ContainsKey('AWSSecret'))
        $modelDownloadResult = Download-ModelIfRequested `
            -ModelDir $modelDir `
            -EnvPath $EnvPath `
            -AWSKey $AWSKey `
            -AWSSecret $AWSSecret `
            -AWSRegion $AWSRegion `
            -CredentialsProvidedViaParams $credentialsProvidedViaParams `
            -NonInteractive:$NonInteractive

        if (-not $modelDownloadResult.Success) {
            $script:SkippedSteps += $modelDownloadResult.Reason
        }
    }
} else {
    Write-Log "" "Yellow"
    Write-Log "WARNING: Model download skipped" "Yellow"
    Write-Log "=================================" "Yellow"
    Write-Log "" "Yellow"
    Write-Log "The application requires the LLM model to function." "Yellow"
    Write-Log "Without the model, language processing features will not work." "Yellow"
    Write-Log "" "Yellow"
    Write-Log "To download the model later:" "Cyan"
    Write-Log "  1. Ensure AWS credentials (AWS_KEY, AWS_SECRET, AWS_REGION) are in .env" "Cyan"
    Write-Log "  2. Run aws s3 sync for s3://rfq-models/Mistral-7B-Instruct-v0-3/" "Cyan"
    Write-Log "  3. Configure MODEL_PATH in .env to point to the model directory" "Cyan"
    Write-Log "" "Cyan"
    Write-Log "Model location: AWS S3 bucket 'rfq-models' (see model prefix in documentation)" "Cyan"
    Write-Log "" "Cyan"
    # Only add to skipped steps if not already added (to avoid duplicates)
    if ($script:SkippedSteps -notcontains "Model download (skipped by installer)" -and 
        $script:SkippedSteps -notcontains "Model download (AWS credentials missing)" -and
        $script:SkippedSteps -notcontains "Model download (AWS CLI not found)" -and
        $script:SkippedSteps -notcontains "Model download (download failed or interrupted)" -and
        $script:SkippedSteps -notcontains "Model download (failed to create directory)") {
        $script:SkippedSteps += "Model download (skipped by user)"
    }
}

# Setup database (optional)
Write-Info "`nDatabase setup..."
$SetupDbScript = Join-Path $InstallPath "setup_database_auto.ps1"

if (Test-Path $SetupDbScript) {
    # Check if PostgreSQL is installed
    $psqlFound = Get-Command psql -ErrorAction SilentlyContinue
    
    if ($psqlFound) {
        Write-Info "PostgreSQL detected. Would you like to set up the database now?"
        Write-Info "  Note: This requires .env file to be configured with SQL_SUPER_USER and RFQ_USER_PASSWORD"
        Write-Info ""
        
        if ($NonInteractive) { $setupDb = "" } else { $setupDb = Read-Host "Set up database now? (y/N)" }
        
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
                    $script:SkippedSteps += "Database setup (passwords not configured)"
                } else {
                    # Run database setup
                    Write-Info "Running database setup..."
                    try {
                        Push-Location $InstallPath
                        # Pass passwords as environment variables if available
                        $env:SQL_SUPER_USER_B64 = ""
                        $env:RFQ_USER_B64 = ""
                        if ($SuperUserPassword -and !$SuperUserPassword.StartsWith("your_")) {
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($SuperUserPassword)
                            $env:SQL_SUPER_USER_B64 = [Convert]::ToBase64String($bytes)
                        }
                        if ($RFQUserPassword -and !$RFQUserPassword.StartsWith("your_")) {
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($RFQUserPassword)
                            $env:RFQ_USER_B64 = [Convert]::ToBase64String($bytes)
                        }
                        & powershell.exe -ExecutionPolicy Bypass -File $SetupDbScript -InstallPath $InstallPath
                        if ($LASTEXITCODE -eq 0) {
                            Write-Success "[OK] Database setup completed"
                        } else {
                            Write-Warning "[!] Database setup may have encountered issues. Check the output above."
                            $script:SkippedSteps += "Database setup (setup encountered issues)"
                        }
                    }
                    catch {
                        Write-Warning "[!] Failed to run database setup: $_"
                        Write-Info "  You can run it manually later:"
                    Write-Info "    powershell.exe -ExecutionPolicy Bypass -File $SetupDbScript"
                        $script:SkippedSteps += "Database setup (setup failed)"
                    }
                    finally {
                        Pop-Location
                    }
                }
            }
        } else {
            Write-Info "  Skipping database setup. You can run it manually later:"
            Write-Info "    powershell.exe -ExecutionPolicy Bypass -File $SetupDbScript"
            $script:SkippedSteps += "Database setup (skipped by user)"
        }
    } else {
        Write-Warning "[!] PostgreSQL (psql) not found in PATH"
        Write-Info "  Database setup script is available at: $SetupDbScript"
        Write-Info "  Please install PostgreSQL first, then run the setup script manually:"
        Write-Info "    powershell.exe -ExecutionPolicy Bypass -File $SetupDbScript"
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
    
    Write-Info "`nCreating Windows service 'RFQapplication'..."
    $ServiceName = "RFQapplication"
    $ServiceDisplayName = "RFQ Application Service"
    $ServiceDescription = "RFQ Automation Application Service"
    Write-Info "  Creating service 'RFQapplication' with executable: $($ExePath.FullName)"

    # Check for NSSM in common locations
    $nssmPath = $null
    $scriptDir = Split-Path -Parent $PSCommandPath
    $currentDir = Get-Location
    $nssmLocations = @(
        "$scriptDir\nssm.exe",  # Same folder as script
        "$currentDir\nssm.exe",  # Current working directory
        "$InstallPath\nssm.exe",  # Installation directory
        "C:\Program Files\nssm\nssm.exe",
        "C:\Program Files (x86)\nssm\nssm.exe",
        "$env:ProgramFiles\nssm\nssm.exe",
        "$env:ProgramFiles(x86)\nssm\nssm.exe"
    )
    
    # Check if NSSM is in PATH
    $nssmInPath = Get-Command nssm -ErrorAction SilentlyContinue
    if ($nssmInPath) {
        $nssmPath = $nssmInPath.Path
        Write-Info "  Found NSSM in PATH: $nssmPath"
    } else {
        # Check common locations
        foreach ($location in $nssmLocations) {
            if (Test-Path $location) {
                $nssmPath = $location
                Write-Info "  Found NSSM at: $nssmPath"
                break
            }
        }
    }
    $logDir = Join-Path $InstallPath "logs"
    $serviceAccountConfig = Resolve-ServiceAccountConfig `
        -ServiceAccount $ServiceAccount `
        -NonInteractive:$NonInteractive `
        -UseCredentialManager:$UseCredentialManager `
        -ServiceName $ServiceName

    if ($serviceAccountConfig.TargetServiceAccount -and $serviceAccountConfig.TargetServiceAccount -notmatch "^(LocalSystem|NT AUTHORITY\\NETWORK SERVICE)$" -and $serviceAccountConfig.ConfigureServiceAccount) {
        Write-Info "  Granting 'Log on as a service' right to $($serviceAccountConfig.TargetServiceAccount)..."
        try {
            $tempSeceditFile = Join-Path $env:TEMP "secedit_$([System.Guid]::NewGuid().ToString()).inf"
            $seceditContent = @"
[Unicode]
Unicode=yes
[Version]
signature=`"`$CHICAGO`$`"
Revision=1
[Privilege Rights]
                    SeServiceLogonRight = $($serviceAccountConfig.TargetServiceAccount)
"@
            Set-Content -Path $tempSeceditFile -Value $seceditContent -Force
            $seceditResult = Start-Process -FilePath "secedit.exe" -ArgumentList "/configure", "/db", "secedit.sdb", "/cfg", $tempSeceditFile -Wait -PassThru -WindowStyle Hidden
            Remove-Item $tempSeceditFile -ErrorAction SilentlyContinue

            if ($seceditResult.ExitCode -eq 0) {
                Write-Success "  [OK] Granted 'Log on as a service' right"
            } else {
                Write-Warning "  [!] Could not automatically grant 'Log on as a service' right"
                Write-Warning "      You may need to grant it manually via Local Security Policy"
                Write-Warning "      Or the service installation may prompt for it"
            }
        }
        catch {
            Write-Warning "  [!] Could not grant 'Log on as a service' right: $_"
            Write-Warning "      You may need to grant it manually via Local Security Policy"
        }
    }

    if (-not $nssmPath) {
        Write-Warning "  NOTE: The installer should have included NSSM. Check C:\Program Files\nssm\nssm.exe"
    }

    $mainServiceInstall = Install-WindowsService `
        -ServiceName $ServiceName `
        -ServiceDisplayName $ServiceDisplayName `
        -ServiceDescription $ServiceDescription `
        -ExePath $ExePath.FullName `
        -InstallPath $InstallPath `
        -NssmPath $nssmPath `
        -LogDirectory $logDir `
        -ServiceAccountConfig $serviceAccountConfig `
        -FriendlyName "service" `
        -NssmMessage "  Using NSSM to create service (recommended for GUI applications)..." `
        -NoNssmWarning "  NSSM not found, using sc.exe (service may fail if application is not service-aware)..."

    $script:serviceCreated = $mainServiceInstall.Created
    $pendingCredentialServiceAccount = $mainServiceInstall.PendingCredentialServiceAccount
    $pendingCredentialServicePassword = $mainServiceInstall.PendingCredentialServicePassword

    if ($script:serviceCreated -and $mainServiceInstall.UsedNssm) {
        if (-not $serviceAccountConfig.TargetServiceAccount) {
            Write-Info "  Service will run as SYSTEM (default)"
        } elseif ($UseCredentialManager -and ![string]::IsNullOrWhiteSpace($pendingCredentialServiceAccount)) {
            Write-Info "  Service will now be able to access Windows Credential Manager credentials"
        }

        Write-Info "  Verifying service account configuration..."
        Start-Sleep -Seconds 2

        try {
            $serviceQuery = sc.exe qc $ServiceName 2>&1
            $serviceQueryString = $serviceQuery | Out-String

            if ($serviceQueryString -match "SERVICE_START_NAME\s*:\s*LocalSystem") {
                if ($serviceAccountConfig.TargetServiceAccount -and $serviceAccountConfig.TargetServiceAccount -ne "LocalSystem") {
                    Write-Warning "  [!] WARNING: Service is running as LocalSystem but was configured for: $($serviceAccountConfig.TargetServiceAccount)"
                } else {
                    Write-Info "  Service is running as LocalSystem (SYSTEM account)"
                }

                if ($UseCredentialManager) {
                    Write-Warning "  [!] WARNING: Service running as SYSTEM CANNOT access Windows Credential Manager credentials"
                    Write-Warning "  [!] You must change the service account to a user account to use Credential Manager"
                }

                if ($serviceAccountConfig.TargetServiceAccount -and $serviceAccountConfig.TargetServiceAccount -notmatch "^(LocalSystem|NT AUTHORITY\\NETWORK SERVICE)$" -and $serviceAccountConfig.ConfigureServiceAccount) {
                    Write-Warning "  [!] The service account configuration was not applied"
                    Write-Warning "  [!]"
                    Write-Warning "  [!] SOLUTION: Manually configure the service account:"
                    Write-Warning "  [!]   nssm set $ServiceName ObjectName `"$($serviceAccountConfig.TargetServiceAccount)`" `"YourPassword`""
                    Write-Warning "  [!]"
                    Write-Warning "  [!] Without this, the service will not be able to retrieve passwords"
                    Write-Warning "  [!] from Windows Credential Manager (SETTINGS_PASSWORD, etc.)"
                } else {
                    Write-Warning "  [!] Service account was not configured during installation"
                    Write-Warning "  [!] To fix, run: nssm set $ServiceName ObjectName `".\YourUsername`" `"YourPassword`""
                }
            } elseif ($serviceAccountConfig.TargetServiceAccount -and $serviceQueryString -match ("SERVICE_START_NAME\s*:\s*" + [regex]::Escape($serviceAccountConfig.TargetServiceAccount))) {
                Write-Success "  [OK] Service is correctly configured to run as: $($serviceAccountConfig.TargetServiceAccount)"
                if ($UseCredentialManager -and $serviceAccountConfig.TargetServiceAccount -notmatch "^(LocalSystem|NT AUTHORITY\\NETWORK SERVICE)$") {
                    Write-Info "  This allows access to Windows Credential Manager credentials"
                }
            } elseif ($serviceQueryString -match "SERVICE_START_NAME\s*:\s*(.+)") {
                $actualAccount = $matches[1].Trim()
                Write-Info "  Service is running as: $actualAccount"
                if ($serviceAccountConfig.TargetServiceAccount -and $actualAccount -eq $serviceAccountConfig.TargetServiceAccount) {
                    Write-Success "  [OK] Service account matches configured account"
                } elseif ($serviceAccountConfig.TargetServiceAccount) {
                    Write-Warning "  [!] Service account mismatch: Expected $($serviceAccountConfig.TargetServiceAccount), but running as $actualAccount"
                }
            } else {
                Write-Warning "  [!] Could not determine service account from query output"
            }
        }
        catch {
            Write-Warning "  [!] Could not verify service account configuration: $_"
        }

        Write-Info "  Service will start automatically on system boot"
        Write-Info "  You can manage it using:"
        Write-Info "    - Command: sc start/stop $ServiceName"
        Write-Info "    - GUI: Services.msc (look for '$ServiceDisplayName')"
        Write-Info "    - NSSM: nssm start/stop/restart $ServiceName"
    } elseif ($script:serviceCreated) {
        Write-Info "  Service will start automatically on system boot"
        Write-Info "  You can manage it using:"
        Write-Info "    - Command: sc start/stop $ServiceName"
        Write-Info "    - GUI: Services.msc (look for '$ServiceDisplayName')"
        Write-Warning ""
        Write-Warning "  IMPORTANT: Service created with sc.exe may not start properly."
        Write-Warning "  If the service fails to start, install NSSM and recreate the service."
    }

    if ($script:serviceCreated -and $UseCredentialManagerForPasswords) {
        Save-PendingCredentials `
            -ServiceAccount $pendingCredentialServiceAccount `
            -ServiceAccountPassword $pendingCredentialServicePassword
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
            $errorMessage = $_.Exception.Message
            Write-Warning "[!] Could not start service: $errorMessage"
            
            # Get more details from sc.exe start
            try {
                $scStartOutput = sc.exe start $ServiceName 2>&1
                if ($scStartOutput) {
                    $scOutputString = $scStartOutput | Out-String
                    Write-Info "  Details: $scOutputString"
                }
            } catch {
                # Ignore if sc.exe also fails
            }
            
            Write-Info "  You can start it manually later:"
            Write-Info "    - Command: sc start $ServiceName"
            Write-Info "    - GUI: Services.msc"
            Write-Info "  Check logs: $InstallPath\logs\"
        }
    }
    
    Write-Info "`nCreating updater service..."
    try {
        $updaterExePath = Join-Path $InstallPath "windows_updater.exe"
        
        if (Test-Path $updaterExePath) {
            $UpdaterServiceName = "RFQUpdaterService"
            $UpdaterServiceDisplayName = "RFQ Application Updater Service"
            $UpdaterServiceDescription = "Polls for update triggers and applies updates to RFQ Application"

            $updaterServiceInstall = Install-WindowsService `
                -ServiceName $UpdaterServiceName `
                -ServiceDisplayName $UpdaterServiceDisplayName `
                -ServiceDescription $UpdaterServiceDescription `
                -ExePath $updaterExePath `
                -InstallPath $InstallPath `
                -NssmPath $nssmPath `
                -LogDirectory $logDir `
                -AppParameters "--service" `
                -FriendlyName "updater service" `
                -NssmMessage "  Using NSSM to create updater service..."

            $script:updaterServiceCreated = $updaterServiceInstall.Created
            if (-not $script:updaterServiceCreated) {
                $script:SkippedSteps += "Updater service (creation failed)"
            }
            
            if ($script:updaterServiceCreated) {
                Write-Info "  Starting updater service..."
                try {
                    Start-Service -Name $UpdaterServiceName -ErrorAction Stop
                    Write-Success "  [OK] Updater service started successfully"
                    if ($updaterServiceInstall.UsedNssm) {
                        Write-Info "  The updater service is now polling for update triggers"
                    }
                }
                catch {
                    Write-Warning "  [!] Could not start updater service: $_"
                    Write-Info "  You can start it manually: sc start $UpdaterServiceName"
                }

                Write-Info ""
                Write-Info "  The updater service will poll for file: $InstallPath\update.trigger"
                Write-Info "  The main application can trigger updates by writing to this file"
            }
        } else {
            Write-Warning "[!] windows_updater.exe not found at: $updaterExePath"
            Write-Warning "  Updater service will not be created"
            $script:SkippedSteps += "Updater service (windows_updater.exe not found)"
        }
    }
    catch {
        Write-Warning "[!] Error creating updater service: $_"
        $script:SkippedSteps += "Updater service (error during creation)"
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
  - Database setup: Run setup_database_auto.ps1 if not already done
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
    Write-Log "  1. Run setup_database_auto.ps1 to set up the database" "Cyan"
    Write-Log "  2. Then launch the application" "Cyan"
    Write-Log "" "Cyan"
}

Write-Log "" "Green"
Write-Log "================================================================================" "Green"
Write-Log "Installation complete!" "Green"
Write-Log "================================================================================" "Green"
Write-Log "" "Green"
Write-Host "Press any key to exit..."
if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
