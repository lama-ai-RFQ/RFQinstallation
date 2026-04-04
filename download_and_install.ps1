# RFQ Application - Windows Installation Script

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

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $env:TEMP "rfq_installer_$LogTimestamp.log"
$script:PendingCredentials = @()
$script:CloudFrontConfig = $null
$script:ResolvedChannel = if (![string]::IsNullOrWhiteSpace($Channel)) { $Channel } elseif (![string]::IsNullOrWhiteSpace($UpdateChannel)) { $UpdateChannel } else { "customer" }
$script:SkippedSteps = @()

function Write-Log { param([string]$Message, [string]$Color = "White"); Write-Host $Message -ForegroundColor $Color; try { Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ErrorAction SilentlyContinue } catch {} }

function Write-Info { Write-Log ($args -join " ") "Cyan" }
function Write-Success { Write-Log ($args -join " ") "Green" }
function Write-Warning { Write-Log ($args -join " ") "Yellow" }
function Write-Error-Custom { Write-Log ($args -join " ") "Red" }

function Exit-WithError { Write-Log "" "Red"; Write-Log "Installation failed. Log file saved to: $script:LogFile" "Yellow"; Write-Host ""; Write-Host "Press any key to exit..." -ForegroundColor Yellow; if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }; exit 1 }

function Get-FirstNonEmpty {
    param([string[]]$Values); foreach ($value in $Values) { if (![string]::IsNullOrWhiteSpace($value)) { return $value } }; return ""
}

function Get-EnvFileValues {
    param([string]$Path); $values = @{}; if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path)) { return $values }
    foreach ($line in Get-Content -Path $Path -ErrorAction SilentlyContinue) { if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') { $values[$matches[1]] = $matches[2].Trim() } }
    return $values
}

function Set-OrAddEnvValue {
    param([string]$Content, [string]$Key, [string]$Value); $pattern = "(?m)^#?\s*$([regex]::Escape($Key))=.*$"; $line = "$Key=$Value"
    if ($Content -match $pattern) { return [regex]::Replace($Content, $pattern, $line) }
    if ([string]::IsNullOrEmpty($Content)) { return $line }
    return $Content.TrimEnd("`r", "`n") + "`n$line"
}

function Set-TemporaryEnvironment {
    param([hashtable]$Values); $previous = @{}
    foreach ($entry in $Values.GetEnumerator()) { $previous[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, "Process"); [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process") }
    return $previous
}

function Restore-TemporaryEnvironment {
    param([hashtable]$PreviousValues); foreach ($entry in $PreviousValues.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process") }
}

function Save-ToCredentialManager {
    param([string]$TargetName, [string]$UserName, [string]$Password)
    try {
        & cmdkey.exe /generic:$TargetName /user:$UserName /pass:$Password 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
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
        $securePassword = ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($ServiceAccount, $securePassword)
        $result = Start-Process -FilePath "cmdkey.exe" `
            -ArgumentList "/generic:$TargetName", "/user:$UserName", "/pass:$Password" `
            -Credential $credential `
            -Wait `
            -PassThru `
            -WindowStyle Hidden
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Add-PendingCredential { param([string]$TargetName, [string]$UserName, [string]$Password, [switch]$AlreadyStored); if ($AlreadyStored) { return $true }; if ([string]::IsNullOrWhiteSpace($Password) -or $Password.StartsWith("your_")) { return $false }; $script:PendingCredentials += @{ TargetName = $TargetName; UserName = $UserName; Password = $Password }; return $true }

function Save-PendingCredentials {
    param([string]$ServiceAccount = "", [string]$ServiceAccountPassword = "")
    if (-not $script:PendingCredentials -or $script:PendingCredentials.Count -eq 0) { return }
    $saveToServiceUser = ![string]::IsNullOrWhiteSpace($ServiceAccount) -and ![string]::IsNullOrWhiteSpace($ServiceAccountPassword)
    foreach ($credential in $script:PendingCredentials) {
        $saved = $false
        if ($saveToServiceUser) {
            $saved = Save-ToCredentialManagerAsUser -TargetName $credential.TargetName -UserName $credential.UserName -Password $credential.Password -ServiceAccount $ServiceAccount -ServiceAccountPassword $ServiceAccountPassword
            if ($saved) { Write-Success "    [OK] Saved $($credential.TargetName) to service user's credential store" } else { Write-Warning "    [!] Failed to save $($credential.TargetName) to service user's credential store" }
        }
        if (-not $saved) {
            $saved = Save-ToCredentialManager -TargetName $credential.TargetName -UserName $credential.UserName -Password $credential.Password
            if ($saved) { if ($saveToServiceUser) { Write-Warning "        Saved to current user's store (service may not be able to access)" } else { Write-Success "    [OK] Saved $($credential.TargetName) to current user's credential store" } }
        }
    }
    $script:PendingCredentials = @()
}

function Test-CredentialManagerAvailable { return [bool](Get-Command cmdkey -ErrorAction SilentlyContinue) }

function Get-CloudFrontSigningConfig {
    param([string]$Bucket, [string]$Region, [string]$AwsKey, [string]$AwsSecret)
    if ($null -ne $script:CloudFrontConfig) { return $script:CloudFrontConfig }
    try {
        $cfgPath = Join-Path $env:TEMP "rfq_cf_config.json"; $keyPath = Join-Path $env:TEMP "rfq_cf_key.pem"; $previous = Set-TemporaryEnvironment @{ AWS_ACCESS_KEY_ID = $AwsKey; AWS_SECRET_ACCESS_KEY = $AwsSecret }
        try {
            & aws s3api get-object --bucket $Bucket --key "signing/cloudfront-config.json" --region $Region $cfgPath *>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Failed to fetch cloudfront-config.json" }
            & aws s3api get-object --bucket $Bucket --key "signing/cloudfront-key.pem" --region $Region $keyPath *>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Failed to fetch cloudfront-key.pem" }
        } finally { Restore-TemporaryEnvironment -PreviousValues $previous }
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json; $pem = Get-Content $keyPath -Raw; Remove-Item $cfgPath, $keyPath -Force -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($cfg.cloudfront_url) -or [string]::IsNullOrWhiteSpace($cfg.key_pair_id) -or [string]::IsNullOrWhiteSpace($pem)) { throw "Incomplete CloudFront config" }
        $script:CloudFrontConfig = @{ Domain = $cfg.cloudfront_url.TrimEnd('/'); KeyPairId = $cfg.key_pair_id; PrivateKeyPem = $pem }; Write-Info "  CloudFront signing config loaded (key-pair: $($cfg.key_pair_id))"; return $script:CloudFrontConfig
    } catch { Write-Info "  CloudFront signing config not available: $_ (will use direct S3)"; $script:CloudFrontConfig = $null; return $null }
}

function New-CloudFrontSignedUrl {
    param([string]$Path, [int]$ExpiresInSeconds = 900)
    if ($null -eq $script:CloudFrontConfig) { return $null }
    $cfg = $script:CloudFrontConfig; $resourceUrl = "$($cfg.Domain)/$Path"; $epoch = [int][double]::Parse((Get-Date -Date ((Get-Date).ToUniversalTime().AddSeconds($ExpiresInSeconds)) -UFormat %s)); $policy = '{"Statement":[{"Resource":"' + $resourceUrl + '","Condition":{"DateLessThan":{"AWS:EpochTime":' + $epoch + '}}}]}'
    try {
        $id = [guid]::NewGuid().ToString('N'); $keyPath = Join-Path $env:TEMP "cf_key_$id.pem"; $policyPath = Join-Path $env:TEMP "cf_policy_$id.bin"; $sigPath = Join-Path $env:TEMP "cf_sig_$id.bin"
        [System.IO.File]::WriteAllText($keyPath, $cfg.PrivateKeyPem); [System.IO.File]::WriteAllBytes($policyPath, [System.Text.Encoding]::UTF8.GetBytes($policy))
        & openssl dgst -sha1 -sign $keyPath -out $sigPath $policyPath 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "openssl signing failed" }
        $signature = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($sigPath)).Replace('+', '-').Replace('=', '_').Replace('/', '~'); Remove-Item $keyPath, $policyPath, $sigPath -Force -ErrorAction SilentlyContinue
        return "$resourceUrl`?Expires=$epoch&Signature=$signature&Key-Pair-Id=$($cfg.KeyPairId)"
    } catch { Write-Warning "  Failed to generate CloudFront signed URL: $_"; return $null }
}

function Invoke-DistributionDownload {
    param([string]$Key, [string]$Destination, [string]$Bucket, [string]$Region, [string]$AwsKey, [string]$AwsSecret)
    $downloaded = $false
    if ($script:CloudFrontConfig) {
        try { $signedUrl = New-CloudFrontSignedUrl -Path $Key; if ($signedUrl) { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri $signedUrl -OutFile $Destination -UseBasicParsing; $downloaded = $true } }
        catch { Write-Warning "  CloudFront download failed for $Key: $_ (falling back to direct S3)" }
    }
    if ($downloaded) { return }
    $previous = Set-TemporaryEnvironment @{ AWS_ACCESS_KEY_ID = $AwsKey; AWS_SECRET_ACCESS_KEY = $AwsSecret }
    try { & aws s3api get-object --bucket $Bucket --key $Key --region $Region $Destination *>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Failed to download s3://$Bucket/$Key" } }
    finally { Restore-TemporaryEnvironment -PreviousValues $previous }
}

function Get-LatestVersion {
    param([string]$Channel, [string]$Bucket, [string]$Region, [string]$AwsKey, [string]$AwsSecret)
    $tmp = Join-Path $env:TEMP "rfq_latest_$([guid]::NewGuid().ToString('N')).json"
    try {
        Invoke-DistributionDownload -Key "$($Channel.ToLower())/windows/latest.json" -Destination $tmp -Bucket $Bucket -Region $Region -AwsKey $AwsKey -AwsSecret $AwsSecret
        $payload = Get-Content $tmp -Raw | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($payload.version)) {
            throw "latest.json did not contain a version"
        }
        return [PSCustomObject]@{ Version = $payload.version; Payload = $payload }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Get-ExpectedSha256 {
    param([string]$Path)
    $content = (Get-Content $Path -Raw -ErrorAction Stop).Trim()
    if ($content -match '([A-Fa-f0-9]{64})') {
        return $matches[1].ToLower()
    }
    throw "SHA256 file did not contain a valid hash"
}

function Resolve-ServiceAccountConfig {
    param([string]$RequestedServiceAccount, [switch]$NonInteractive, [switch]$UseCredentialManager, [string]$ServiceName)
    $config = [PSCustomObject]@{ TargetServiceAccount = $null; ServiceAccountPassword = $null; ConfigureServiceAccount = $false }
    switch ($RequestedServiceAccount.ToLower()) {
        "currentuser" {
            Write-Info "  You selected to run the service as a user account."; Write-Info "  This allows the service to access Windows Credential Manager credentials."; Write-Info ""; Write-Info "  Enter DOMAIN\Username, .\Username, or Username."
            $accountInput = if ($NonInteractive) { "" } else { Read-Host "  Account name" }
            if ([string]::IsNullOrWhiteSpace($accountInput)) { Write-Warning "  No account name provided. Service will run as SYSTEM." } else {
                $config.TargetServiceAccount = if ($accountInput.Contains('\')) { $accountInput } elseif ($accountInput.StartsWith('.\')) { "$env:COMPUTERNAME\$($accountInput.Substring(2))" } else { "$env:USERDOMAIN\$accountInput" }
                $securePassword = if ($NonInteractive) { $null } else { Read-Host "  Enter password for $($config.TargetServiceAccount)" -AsSecureString }
                if ($securePassword -and $securePassword.Length -gt 0) {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword); $config.ServiceAccountPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr); [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $config.ConfigureServiceAccount = $true; Write-Info "  Password accepted. Will configure service account after installation."
                } else { Write-Warning "  Password was not provided. Service will run as SYSTEM."; $config.TargetServiceAccount = $null }
            }
        }
        "networkservice" { $config.TargetServiceAccount = "NT AUTHORITY\NETWORK SERVICE"; if ($UseCredentialManager) { Write-Warning "  WARNING: Network Service cannot access Windows Credential Manager!" } }
        "localsystem" { $config.TargetServiceAccount = "LocalSystem"; if ($UseCredentialManager) { Write-Warning "  WARNING: Local System cannot access Windows Credential Manager!" } }
        default { Write-Warning "  Unknown service account option: $RequestedServiceAccount. Defaulting to SYSTEM." }
    }
    return $config
}

function Remove-ServiceIfExists {
    param([string]$ServiceName, [string]$NssmPath = "", [string]$FriendlyName = "service")
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    Write-Warning "[!] $FriendlyName '$ServiceName' already exists"
    try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch {}
    try {
        if (![string]::IsNullOrWhiteSpace($NssmPath)) {
            & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
        } else {
            sc.exe delete $ServiceName | Out-Null
        }
    }
    catch {
        Write-Warning "  [!] Could not remove existing $FriendlyName: $_"
    }
    for ($waited = 0; $waited -lt 30; $waited += 2) {
        Start-Sleep -Seconds 2
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            return
        }
    }
}

function Install-WindowsService {
    param([string]$ServiceName, [string]$ServiceDisplayName, [string]$ServiceDescription, [string]$ExePath, [string]$InstallPath, [string]$NssmPath = "", [string]$LogDirectory = "", [string]$AppParameters = "", [psobject]$ServiceAccountConfig = $null, [string]$FriendlyName = "service")
    $result = [PSCustomObject]@{ Created = $false; UsedNssm = $false; PendingCredentialServiceAccount = ""; PendingCredentialServicePassword = "" }
    Remove-ServiceIfExists -ServiceName $ServiceName -NssmPath $NssmPath -FriendlyName $FriendlyName
    if ($LogDirectory -and !(Test-Path $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
    if ($NssmPath) {
        try {
            & $NssmPath install $ServiceName "$ExePath" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & $NssmPath set $ServiceName DisplayName "$ServiceDisplayName" 2>&1 | Out-Null; & $NssmPath set $ServiceName Description "$ServiceDescription" 2>&1 | Out-Null; & $NssmPath set $ServiceName AppDirectory "$InstallPath" 2>&1 | Out-Null; & $NssmPath set $ServiceName Start SERVICE_AUTO_START 2>&1 | Out-Null
                if (![string]::IsNullOrWhiteSpace($AppParameters)) { & $NssmPath set $ServiceName AppParameters "$AppParameters" 2>&1 | Out-Null }
                if ($LogDirectory) { & $NssmPath set $ServiceName AppStdout (Join-Path $LogDirectory "${ServiceName}_stdout.log") 2>&1 | Out-Null; & $NssmPath set $ServiceName AppStderr (Join-Path $LogDirectory "${ServiceName}_stderr.log") 2>&1 | Out-Null }
                if ($ServiceAccountConfig -and $ServiceAccountConfig.TargetServiceAccount) {
                    if ($ServiceAccountConfig.TargetServiceAccount -match "^(LocalSystem|NT AUTHORITY\\NETWORK SERVICE)$") { & $NssmPath set $ServiceName ObjectName $ServiceAccountConfig.TargetServiceAccount 2>&1 | Out-Null }
                    elseif ($ServiceAccountConfig.ServiceAccountPassword) {
                        $nssmAccountName = $ServiceAccountConfig.TargetServiceAccount; if ($nssmAccountName -match "^$([regex]::Escape($env:COMPUTERNAME))\\(.+)$") { $nssmAccountName = ".\$($matches[1])" }
                        & $NssmPath set $ServiceName ObjectName "$nssmAccountName" "$($ServiceAccountConfig.ServiceAccountPassword)" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $result.PendingCredentialServiceAccount = $nssmAccountName; $result.PendingCredentialServicePassword = $ServiceAccountConfig.ServiceAccountPassword }
                    }
                }
                $result.Created = $true; $result.UsedNssm = $true; return $result
            }
        } catch { Write-Warning "  [!] NSSM service installation failed: $_" }
        Write-Info "  Falling back to sc.exe method..."
    } else { Write-Warning "  NSSM not found, using sc.exe (service may fail if application is not service-aware)..." }
    try {
        $binPath = if ([string]::IsNullOrWhiteSpace($AppParameters)) { "`"$ExePath`"" } else { "`"$ExePath`" $AppParameters" }
        sc.exe create $ServiceName binPath= $binPath start= auto DisplayName= $ServiceDisplayName | Out-Null; if ($LASTEXITCODE -eq 0) { sc.exe description $ServiceName $ServiceDescription | Out-Null; $result.Created = $true }
    } catch { Write-Warning "  [!] Could not create service: $_" }
    return $result
}

function Resolve-ModelDownloadRequest {
    param([string]$EnvPath, [string]$AWSKey, [string]$AWSSecret, [string]$AWSRegion, [bool]$CredentialsProvidedViaParams = $false, [switch]$NonInteractive)
    $request = [PSCustomObject]@{ AwsKey = Get-FirstNonEmpty @($AWSKey); AwsSecret = Get-FirstNonEmpty @($AWSSecret); AwsRegion = Get-FirstNonEmpty @($AWSRegion); CredentialsProvidedViaParams = $CredentialsProvidedViaParams }
    $envValues = Get-EnvFileValues -Path $EnvPath
    if ([string]::IsNullOrWhiteSpace($request.AwsKey) -and $envValues.ContainsKey("AWS_KEY")) { $request.AwsKey = $envValues["AWS_KEY"] }
    if ([string]::IsNullOrWhiteSpace($request.AwsSecret) -and $envValues.ContainsKey("AWS_SECRET")) { $request.AwsSecret = $envValues["AWS_SECRET"] }
    if ([string]::IsNullOrWhiteSpace($request.AwsRegion) -and $envValues.ContainsKey("AWS_REGION")) { $request.AwsRegion = $envValues["AWS_REGION"] }
    if (([string]::IsNullOrWhiteSpace($request.AwsKey) -or [string]::IsNullOrWhiteSpace($request.AwsSecret)) -and -not $request.CredentialsProvidedViaParams) {
        if ([string]::IsNullOrWhiteSpace($request.AwsKey)) { $request.AwsKey = if ($NonInteractive) { "" } else { Read-Host "Enter AWS Access Key ID" } }
        if ([string]::IsNullOrWhiteSpace($request.AwsSecret)) {
            if ($NonInteractive) { $request.AwsSecret = "" } else {
                $secureSecret = Read-Host "Enter AWS Secret Access Key" -AsSecureString; $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret); $request.AwsSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr); [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        $regionInput = if ($NonInteractive) { "" } else { Read-Host "Enter AWS Region (press Enter for us-east-1)" }; if (![string]::IsNullOrWhiteSpace($regionInput)) { $request.AwsRegion = $regionInput.Trim() }
        if (Test-Path $EnvPath) {
            $envContent = Get-Content $EnvPath -Raw; $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_KEY" -Value $request.AwsKey; $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_SECRET" -Value $request.AwsSecret; $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_REGION" -Value (Get-FirstNonEmpty @($request.AwsRegion, "us-east-1")); Set-Content -Path $EnvPath -Value $envContent -Force
        }
    }
    $request.AwsRegion = Get-FirstNonEmpty @($request.AwsRegion, "us-east-1"); return $request
}

function Download-ModelIfRequested {
    param([string]$ModelDir, [string]$EnvPath, [string]$AWSKey, [string]$AWSSecret, [string]$AWSRegion, [bool]$CredentialsProvidedViaParams = $false, [switch]$NonInteractive)
    $request = Resolve-ModelDownloadRequest -EnvPath $EnvPath -AWSKey $AWSKey -AWSSecret $AWSSecret -AWSRegion $AWSRegion -CredentialsProvidedViaParams $CredentialsProvidedViaParams -NonInteractive:$NonInteractive
    if ([string]::IsNullOrWhiteSpace($request.AwsKey) -or [string]::IsNullOrWhiteSpace($request.AwsSecret)) { Write-Warning "[!] AWS credentials are required for model download"; return "Model download (AWS credentials missing)" }
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Write-Warning "[!] AWS CLI not found in PATH"; return "Model download (AWS CLI not found)" }
    $previous = Set-TemporaryEnvironment @{ AWS_ACCESS_KEY_ID = $request.AwsKey; AWS_SECRET_ACCESS_KEY = $request.AwsSecret; AWS_DEFAULT_REGION = $request.AwsRegion }
    try { & aws s3 sync "s3://rfq-models/Mistral-7B-Instruct-v0-3/" $ModelDir --region $request.AwsRegion --exclude ".cache/*" --exclude "*/.cache/*" --exclude "*.lock" --exclude "*.metadata"; if ($LASTEXITCODE -ne 0) { return "Model download (download failed or interrupted)" } }
    finally { Restore-TemporaryEnvironment -PreviousValues $previous }
    if (Test-Path $EnvPath) { $envContent = Get-Content $EnvPath -Raw; $envContent = Set-OrAddEnvValue -Content $envContent -Key "MODEL_PATH" -Value ($ModelDir.Replace('\', '/')); Set-Content -Path $EnvPath -Value $envContent -Force }
    Write-Success "[OK] Model downloaded successfully from S3"; return ""
}

function Install-Certificates {
    param([string]$InstallPath, [string]$EnvPath)
    $bundleCandidates = @(
        (Join-Path (Split-Path -Parent $PSCommandPath) "cacert.pem"),
        (Join-Path (Split-Path -Parent $PSCommandPath) "gcc-high-ca-bundle.pem")
    )
    $bundleSource = $bundleCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $bundleSource -or !(Test-Path $EnvPath)) { return }
    $bundleDestination = Join-Path $InstallPath (Split-Path $bundleSource -Leaf)
    Copy-Item -Path $bundleSource -Destination $bundleDestination -Force
    $envContent = Get-Content $EnvPath -Raw
    $envContent = Set-OrAddEnvValue -Content $envContent -Key "REQUESTS_CA_BUNDLE" -Value ($bundleDestination.Replace('\', '/'))
    Set-Content -Path $EnvPath -Value $envContent -Force
}

function Write-EnvFile {
    param([string]$EnvPath, [string]$EnvTemplatePath, [bool]$UseCredentialManagerForPasswords, [string]$SuperUserPassword, [string]$RFQUserPassword, [string]$SettingsPassword, [bool]$SuperUserPasswordAlreadyStored, [bool]$RFQUserPasswordAlreadyStored, [bool]$SettingsPasswordAlreadyStored, [string]$GitHubToken, [string]$ModelPathForEnv, [string]$ServerURL, [string]$AzureKey, [string]$ResolvedChannel, [string]$AWSKey, [string]$AWSSecret, [string]$AWSRegion, [string]$S3ReleaseBucket, [string]$S3ReleaseRegion)
    $sqlValue = $SuperUserPassword; $rfqValue = $RFQUserPassword; $settingsValue = $SettingsPassword
    if ($UseCredentialManagerForPasswords) {
        if ($SuperUserPasswordAlreadyStored) { Write-Info "    [SKIP] SQL_SUPER_USER already stored in Windows Credential Manager (skipping)" }
        if ($RFQUserPasswordAlreadyStored) { Write-Info "    [SKIP] RFQ_USER_PASSWORD already stored in Windows Credential Manager (skipping)" }
        if ($SettingsPasswordAlreadyStored) { Write-Info "    [SKIP] SETTINGS_PASSWORD already stored in Windows Credential Manager (skipping)" }
        if (Add-PendingCredential -TargetName "RFQApplication_SQL_SUPER_USER" -UserName "postgres" -Password $SuperUserPassword -AlreadyStored:$SuperUserPasswordAlreadyStored) { $sqlValue = "__CREDENTIAL_MANAGER__" }
        if (Add-PendingCredential -TargetName "RFQApplication_RFQ_USER_PASSWORD" -UserName "rfq_user" -Password $RFQUserPassword -AlreadyStored:$RFQUserPasswordAlreadyStored) { $rfqValue = "__CREDENTIAL_MANAGER__" }
        if (Add-PendingCredential -TargetName "RFQApplication_SETTINGS_PASSWORD" -UserName "rfq_app" -Password $SettingsPassword -AlreadyStored:$SettingsPasswordAlreadyStored) { $settingsValue = "__CREDENTIAL_MANAGER__" }
    }
    $envContent = if (Test-Path $EnvTemplatePath) { Get-Content $EnvTemplatePath -Raw } else { (@("# RFQ Application Configuration", "APP_MODE=fastapi", "WINDOWS=true", "LOCAL_DATABASE=1", "CONTAINER=0", "MODEL_PATH=", "MODEL_NAME=Mistral-7B-Instruct-v0-3", "SERVER_URL=$ServerURL", "PORT=8000", "DEBUG_THREAD=0", "REQUESTS_CA_BUNDLE=") -join "`n") }
    $envContent = "# RFQ Application Configuration`n# Generated by installer on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n" + $envContent.Trim()
    foreach ($entry in @(@{ Key = "GITHUB_PAT"; Value = $GitHubToken }, @{ Key = "GITHUB_USERNAME"; Value = "RFQdebugging" }, @{ Key = "APP_MODE"; Value = "fastapi" }, @{ Key = "WINDOWS"; Value = "true" }, @{ Key = "LOCAL_DATABASE"; Value = "1" }, @{ Key = "CONTAINER"; Value = "0" }, @{ Key = "MODEL_NAME"; Value = "Mistral-7B-Instruct-v0-3" }, @{ Key = "SERVER_URL"; Value = $ServerURL }, @{ Key = "PORT"; Value = "8000" }, @{ Key = "OAUTH_PORT_LOGIN"; Value = "8502" }, @{ Key = "OAUTH_PORT_SEND_RECEIVE"; Value = "8502" }, @{ Key = "DEBUG_THREAD"; Value = "0" }, @{ Key = "AZURE_CONFIG_ENCRYPTION_KEY"; Value = $AzureKey }, @{ Key = "SQL_SUPER_USER"; Value = $sqlValue }, @{ Key = "RFQ_USER_PASSWORD"; Value = $rfqValue }, @{ Key = "SETTINGS_PASSWORD"; Value = $settingsValue }, @{ Key = "RFQ_UPDATE_CHANNEL"; Value = $ResolvedChannel }, @{ Key = "S3_RELEASE_BUCKET"; Value = $S3ReleaseBucket })) { $envContent = Set-OrAddEnvValue -Content $envContent -Key $entry.Key -Value $entry.Value }
    if (![string]::IsNullOrWhiteSpace($ModelPathForEnv)) { $envContent = Set-OrAddEnvValue -Content $envContent -Key "MODEL_PATH" -Value $ModelPathForEnv }
    if (![string]::IsNullOrWhiteSpace($AWSKey)) { $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_KEY" -Value $AWSKey }
    if (![string]::IsNullOrWhiteSpace($AWSSecret)) { $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_SECRET" -Value $AWSSecret }
    if (![string]::IsNullOrWhiteSpace($AWSRegion)) { $envContent = Set-OrAddEnvValue -Content $envContent -Key "AWS_REGION" -Value $AWSRegion }
    if (![string]::IsNullOrWhiteSpace($S3ReleaseRegion)) { $envContent = Set-OrAddEnvValue -Content $envContent -Key "S3_RELEASE_REGION" -Value $S3ReleaseRegion }
    if ($envContent -notmatch "(?m)^REQUESTS_CA_BUNDLE=") { $envContent += "`n# SSL Certificate Configuration`nREQUESTS_CA_BUNDLE=" }
    Set-Content -Path $EnvPath -Value $envContent -Force
}

trap { Write-Error-Custom ""; Write-Error-Custom "CRITICAL ERROR"; Write-Error-Custom $_.Exception.Message; Write-Error-Custom $_.InvocationInfo.PositionMessage; Exit-WithError }
if ($Help) { Write-Host "RFQ Application - Windows Installer`n-InstallPath <path>`n-Channel <name>`n-NonInteractive`n-SkipModelDownload`n-OverwriteExisting`n-UseCredentialManager"; exit 0 }

Write-Info "Script started..."
Write-Info "Working directory: $PWD"
Write-Info "Script path: $PSCommandPath"
Write-Info "Log file: $script:LogFile"
Write-Info "Using channel: $script:ResolvedChannel"

Write-Info "`n[1/8] Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Error-Custom "ERROR: PowerShell 5.1 or later is required"
    Exit-WithError
}
Write-Success "[OK] PowerShell version: $($PSVersionTable.PSVersion)"

Write-Info "`n[2/8] Checking disk space..."
$drive = Split-Path $InstallPath -Qualifier
$freeSpace = (Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB
if ($freeSpace -lt 4) {
    Write-Warning "WARNING: Low disk space - $('{0:F2}' -f $freeSpace) GB free. Need at least 4 GB."
    if ($NonInteractive -or ((Read-Host "Continue anyway? (y/N)") -ne 'y')) {
        Exit-WithError
    }
}
Write-Success "[OK] Available disk space: $('{0:F2}' -f $freeSpace) GB"

Write-Info "`n[3/8] Preparing installation directory..."
if (Test-Path $InstallPath) {
    if ($CleanReinstall) {
        Write-Info "  Clean reinstall requested. Removing existing directory contents..."
        Remove-Item -Path (Join-Path $InstallPath '*') -Recurse -Force -ErrorAction SilentlyContinue
    } elseif (-not $OverwriteExisting) {
        if ($NonInteractive -or ((Read-Host "Overwrite existing installation? (y/N)") -ne 'y')) {
            Exit-WithError
        }
    }
} else {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}
try {
    $newLog = Join-Path $InstallPath "installer_$LogTimestamp.log"
    if (Test-Path $script:LogFile) {
        Copy-Item -Path $script:LogFile -Destination $newLog -Force -ErrorAction SilentlyContinue
    }
    $script:LogFile = $newLog
}
catch {
}
Write-Success "[OK] Install path ready: $InstallPath"

$existingEnvPath = Join-Path $InstallPath ".env"
$existingEnvValues = Get-EnvFileValues -Path $existingEnvPath
$s3Bucket = Get-FirstNonEmpty @($S3ReleaseBucket, $existingEnvValues["S3_RELEASE_BUCKET"], "rfq-distribution-us")
$s3Region = Get-FirstNonEmpty @($S3ReleaseRegion, $AWSRegion, $existingEnvValues["S3_RELEASE_REGION"], "us-east-1")
$s3AwsKey = Get-FirstNonEmpty @($AWSKey, $existingEnvValues["AWS_KEY"])
$s3AwsSecret = Get-FirstNonEmpty @($AWSSecret, $existingEnvValues["AWS_SECRET"])

Write-Info "`n[4/8] Resolving distribution version..."
if ([string]::IsNullOrWhiteSpace($s3AwsKey) -or [string]::IsNullOrWhiteSpace($s3AwsSecret)) {
    Write-Error-Custom "ERROR: AWS credentials are required for bootstrap installation"
    Exit-WithError
}
Get-CloudFrontSigningConfig -Bucket $s3Bucket -Region $s3Region -AwsKey $s3AwsKey -AwsSecret $s3AwsSecret | Out-Null
try {
    $latestVersion = Get-LatestVersion -Channel $script:ResolvedChannel -Bucket $s3Bucket -Region $s3Region -AwsKey $s3AwsKey -AwsSecret $s3AwsSecret
    $Version = $latestVersion.Version
    Write-Success "[OK] Found version: $Version"
}
catch {
    Write-Error-Custom "ERROR: Failed to resolve latest version: $_"
    Exit-WithError
}

Write-Info "`n[5/8] Downloading bootstrap updater..."
$bootstrapDir = Join-Path $env:TEMP "rfq_bootstrap_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
$bootstrapExe = Join-Path $bootstrapDir "windows_updater.exe"
$bootstrapSha = Join-Path $bootstrapDir "windows_updater.exe.sha256"
try {
    Invoke-DistributionDownload -Key "$($script:ResolvedChannel.ToLower())/windows/updater/latest/windows_updater.exe" -Destination $bootstrapExe -Bucket $s3Bucket -Region $s3Region -AwsKey $s3AwsKey -AwsSecret $s3AwsSecret
    Invoke-DistributionDownload -Key "$($script:ResolvedChannel.ToLower())/windows/updater/latest/windows_updater.exe.sha256" -Destination $bootstrapSha -Bucket $s3Bucket -Region $s3Region -AwsKey $s3AwsKey -AwsSecret $s3AwsSecret
    $expectedSha = Get-ExpectedSha256 -Path $bootstrapSha
    $actualSha = (Get-FileHash -Algorithm SHA256 -Path $bootstrapExe).Hash.ToLower()
    if ($actualSha -ne $expectedSha) {
        throw "SHA256 mismatch for windows_updater.exe"
    }
    Write-Success "[OK] Updater download verified"
}
catch {
    Write-Error-Custom "ERROR: Failed to prepare bootstrap updater: $_"
    Exit-WithError
}

Write-Info "`n[6/8] Running updater bootstrap..."
$bootstrapMarker = Join-Path $InstallPath ".bootstrap-complete"
Remove-Item $bootstrapMarker -Force -ErrorAction SilentlyContinue
try {
    $existingService = Get-Service -Name "RFQapplication" -ErrorAction SilentlyContinue
    if ($existingService -and $existingService.Status -eq 'Running') {
        Stop-Service -Name "RFQapplication" -Force -ErrorAction SilentlyContinue
    }
}
catch {
}
$bootstrapEnv = Set-TemporaryEnvironment @{
    AWS_ACCESS_KEY_ID = $s3AwsKey
    AWS_SECRET_ACCESS_KEY = $s3AwsSecret
    AWS_DEFAULT_REGION = $s3Region
    S3_RELEASE_BUCKET = $s3Bucket
    S3_RELEASE_REGION = $s3Region
}
try {
    & $bootstrapExe --bootstrap --channel $script:ResolvedChannel --target $InstallPath --version $Version
    $bootstrapExitCode = $LASTEXITCODE
}
finally {
    Restore-TemporaryEnvironment -PreviousValues $bootstrapEnv
}
if ($bootstrapExitCode -ne 0) {
    Write-Error-Custom "ERROR: updater bootstrap failed with exit code $bootstrapExitCode"
    Exit-WithError
}
if (!(Test-Path $bootstrapMarker)) {
    Write-Error-Custom "ERROR: updater bootstrap completed without creating $bootstrapMarker"
    Exit-WithError
}
if (!(Test-Path (Join-Path $InstallPath "windows_updater.exe"))) {
    Copy-Item -Path $bootstrapExe -Destination (Join-Path $InstallPath "windows_updater.exe") -Force
}
Write-Success "[OK] Bootstrap completed"
Remove-Item $bootstrapDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Info "`n[7/8] Configuring application..."
$UseCredentialManagerForPasswords = $UseCredentialManager -and (Test-CredentialManagerAvailable)
if ($UseCredentialManagerForPasswords) {
    Write-Success "[OK] Windows Credential Manager detected - will store passwords securely"
} elseif ($UseCredentialManager) {
    Write-Warning "[!] Windows Credential Manager not available - falling back to .env file"
}
$EnvPath = Join-Path $InstallPath ".env"
$EnvTemplatePath = Join-Path $InstallPath ".env.template"
$SuperUserPassword = Get-FirstNonEmpty @($SuperUserPassword, "your_sql_super_user_password_here")
$RFQUserPassword = Get-FirstNonEmpty @($RFQUserPassword, "your_database_password_here")
$SettingsPassword = Get-FirstNonEmpty @($SettingsPassword, "your_settings_password_here")
$ServerURL = Get-FirstNonEmpty @($ServerURL, "https://localhost")
$AzureKey = if ($AzureKeyGenerate) {
    try { (& openssl rand -base64 32 2>&1).Trim() } catch { "" }
} elseif (![string]::IsNullOrWhiteSpace($AzureKeyCustom)) {
    $AzureKeyCustom
} else {
    ""
}
$ModelPathForEnv = ""
if (![string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPathForEnv = $ModelPath
} elseif ($SkipModelDownload -and (Test-Path $EnvPath)) {
    $existingEnv = Get-EnvFileValues -Path $EnvPath
    if ($existingEnv.ContainsKey("MODEL_PATH")) {
        $ModelPathForEnv = $existingEnv["MODEL_PATH"]
    }
}
Write-EnvFile `
    -EnvPath $EnvPath `
    -EnvTemplatePath $EnvTemplatePath `
    -UseCredentialManagerForPasswords $UseCredentialManagerForPasswords `
    -SuperUserPassword $SuperUserPassword `
    -RFQUserPassword $RFQUserPassword `
    -SettingsPassword $SettingsPassword `
    -SuperUserPasswordAlreadyStored $SuperUserPasswordAlreadyStored `
    -RFQUserPasswordAlreadyStored $RFQUserPasswordAlreadyStored `
    -SettingsPasswordAlreadyStored $SettingsPasswordAlreadyStored `
    -GitHubToken $GitHubToken `
    -ModelPathForEnv $ModelPathForEnv `
    -ServerURL $ServerURL `
    -AzureKey $AzureKey `
    -ResolvedChannel $script:ResolvedChannel `
    -AWSKey $AWSKey `
    -AWSSecret $AWSSecret `
    -AWSRegion $AWSRegion `
    -S3ReleaseBucket $s3Bucket `
    -S3ReleaseRegion $s3Region
Install-Certificates -InstallPath $InstallPath -EnvPath $EnvPath
Set-Content -Path (Join-Path $InstallPath "version.txt") -Value $Version -Force
Write-Success "[OK] Environment configured"

Write-Info "`nModel download..."
$downloadModel = 'n'
$modelBasePath = ""
if ($SkipModelDownload) {
    Write-Info "Model download skipped as requested by installer"
    $script:SkippedSteps += "Model download (skipped by installer)"
} elseif (![string]::IsNullOrWhiteSpace($ModelPath)) {
    $downloadModel = 'y'
    $modelBasePath = [System.IO.Path]::GetFullPath($ModelPath)
} else {
    Write-Info "The application requires the LLM model (~30 GB)."
    if ($NonInteractive) {
        Write-Info "  NonInteractive: skipping model download"
    } else {
        $downloadModel = Read-Host "Would you like to download the model now? (Y/n)"
        if ($downloadModel -ne 'n' -and $downloadModel -ne 'N') {
            $defaultModelPath = Join-Path $env:USERPROFILE "Documents\RFQ_Models"
            $modelBasePath = Read-Host "Enter model download directory (press Enter for default: $defaultModelPath)"
            if ([string]::IsNullOrWhiteSpace($modelBasePath)) { $modelBasePath = $defaultModelPath }
        }
    }
}
if ($downloadModel -ne 'n' -and $downloadModel -ne 'N' -and $modelBasePath) {
    if (!(Test-Path $modelBasePath)) {
        try {
            New-Item -ItemType Directory -Path $modelBasePath -Force | Out-Null
        }
        catch {
            $script:SkippedSteps += "Model download (failed to create directory)"
            $modelBasePath = ""
        }
    }
    if ($modelBasePath) {
        $downloadReason = Download-ModelIfRequested `
            -ModelDir (Join-Path ([System.IO.Path]::GetFullPath($modelBasePath)) "Mistral-7B-Instruct-v0-3") `
            -EnvPath $EnvPath `
            -AWSKey $AWSKey `
            -AWSSecret $AWSSecret `
            -AWSRegion $AWSRegion `
            -CredentialsProvidedViaParams ($PSBoundParameters.ContainsKey('AWSKey') -or $PSBoundParameters.ContainsKey('AWSSecret')) `
            -NonInteractive:$NonInteractive
        if ($downloadReason) {
            $script:SkippedSteps += $downloadReason
        }
    }
} else {
    Write-Log "" "Yellow"
    Write-Log "WARNING: Model download skipped" "Yellow"
    Write-Log "To download later, run aws s3 sync for s3://rfq-models/Mistral-7B-Instruct-v0-3/" "Cyan"
    if ($script:SkippedSteps -notcontains "Model download (skipped by installer)" -and
        $script:SkippedSteps -notcontains "Model download (AWS credentials missing)" -and
        $script:SkippedSteps -notcontains "Model download (AWS CLI not found)" -and
        $script:SkippedSteps -notcontains "Model download (download failed or interrupted)" -and
        $script:SkippedSteps -notcontains "Model download (failed to create directory)") {
        $script:SkippedSteps += "Model download (skipped by user)"
    }
}

$script:SkippedSteps += "Database setup (run setup_database_auto.ps1 manually if needed)"

Write-Info "`n[8/8] Installing Windows services..."
$ExePath = Get-ChildItem -Path $InstallPath -Filter "RFQ_Application.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ExePath) {
    $ExePath = Get-ChildItem -Path $InstallPath -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $ExePath) {
    Write-Warning "[!] Could not find application executable"
    Exit-WithError
}
$nssmPath = @(
    (Get-Command nssm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue),
    (Join-Path (Split-Path -Parent $PSCommandPath) "nssm.exe"),
    (Join-Path $InstallPath "nssm.exe"),
    "C:\Program Files\nssm\nssm.exe",
    "C:\Program Files (x86)\nssm\nssm.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
$logDir = Join-Path $InstallPath "logs"
$serviceAccountConfig = Resolve-ServiceAccountConfig `
    -RequestedServiceAccount $ServiceAccount `
    -NonInteractive:$NonInteractive `
    -UseCredentialManager:$UseCredentialManager `
    -ServiceName "RFQapplication"
$mainService = Install-WindowsService `
    -ServiceName "RFQapplication" `
    -ServiceDisplayName "RFQ Application Service" `
    -ServiceDescription "RFQ Automation Application Service" `
    -ExePath $ExePath.FullName `
    -InstallPath $InstallPath `
    -NssmPath $nssmPath `
    -LogDirectory $logDir `
    -ServiceAccountConfig $serviceAccountConfig
if ($mainService.Created -and $UseCredentialManagerForPasswords) {
    Save-PendingCredentials `
        -ServiceAccount $mainService.PendingCredentialServiceAccount `
        -ServiceAccountPassword $mainService.PendingCredentialServicePassword
}
if ($mainService.Created) {
    try {
        Start-Service -Name "RFQapplication" -ErrorAction Stop
        Write-Success "[OK] Service 'RFQapplication' started successfully"
    }
    catch {
        Write-Warning "[!] Could not start service: $($_.Exception.Message)"
    }
}
$updaterExePath = Join-Path $InstallPath "windows_updater.exe"
if (Test-Path $updaterExePath) {
    $updaterService = Install-WindowsService `
        -ServiceName "RFQUpdaterService" `
        -ServiceDisplayName "RFQ Application Updater Service" `
        -ServiceDescription "Polls for update triggers and applies updates to RFQ Application" `
        -ExePath $updaterExePath `
        -InstallPath $InstallPath `
        -NssmPath $nssmPath `
        -LogDirectory $logDir `
        -AppParameters "--service" `
        -FriendlyName "updater service"
    if ($updaterService.Created) {
        try {
            Start-Service -Name "RFQUpdaterService" -ErrorAction Stop
            Write-Success "[OK] Updater service started successfully"
        }
        catch {
            Write-Warning "[!] Could not start updater service: $($_.Exception.Message)"
        }
    } else {
        $script:SkippedSteps += "Updater service (creation failed)"
    }
} else {
    $script:SkippedSteps += "Updater service (windows_updater.exe not found)"
}

$missingParams = @()
$EnvContent = Get-Content $EnvPath -Raw -ErrorAction SilentlyContinue
if ($EnvContent) {
    if ($EnvContent -match "SQL_SUPER_USER\s*=\s*(your_|$|\s*$)") { $missingParams += "SQL_SUPER_USER" }
    if ($EnvContent -match "RFQ_USER_PASSWORD\s*=\s*(your_|$|\s*$)") { $missingParams += "RFQ_USER_PASSWORD" }
}

Write-Log "" ; Write-Log "================================================================================" "Green"; Write-Log "Installation Complete" "Green"; Write-Log "================================================================================" "Green"
Write-Log "Installation Path: $InstallPath" "Green"; Write-Log "Version: $Version" "Green"
if ($script:SkippedSteps.Count -gt 0) { Write-Log "Skipped steps:" "Yellow"; foreach ($step in $script:SkippedSteps) { Write-Log "  - $step" "Yellow" } }
if ($missingParams.Count -gt 0) { Write-Log "Configuration still needed in $EnvPath:" "Yellow"; foreach ($param in $missingParams) { Write-Log "  - $param" "Yellow" } }
Write-Log "Log file: $script:LogFile" "Cyan"
Write-Host "Press any key to exit..."
if (-not $NonInteractive) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
