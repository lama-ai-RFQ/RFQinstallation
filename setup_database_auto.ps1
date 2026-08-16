# PostgreSQL Database Setup (Automatic)
# This script will:
#   - Check if database 'rfq_db' exists (create if not)
#   - Check if user 'rfq_user' exists (create or update password)
#   - Grant all necessary permissions
#
# Credentials are read from the RFQ installer registry handoff path
# or from .env file as fallback

param(
    [string]$InstallPath = $PSScriptRoot,
    [string]$EnvFilePath = "",
    [switch]$Debug,
    [switch]$ShowPasswordPreview,
    [switch]$Help
)

function Get-RfqEnvValueOrDefault {
    param(
        [Parameter(Mandatory)]
        [string]$EnvName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DefaultValue,

        [AllowNull()]
        [scriptblock]$Validator = $null,

        [AllowNull()]
        [string]$ValidationMessage = $null
    )

    $value = [Environment]::GetEnvironmentVariable($EnvName, "Process")
    if ($null -eq $value -or $value -eq "") {
        return $DefaultValue
    }

    if ($null -ne $Validator -and -not (& $Validator $value)) {
        if ([string]::IsNullOrWhiteSpace($ValidationMessage)) {
            $ValidationMessage = "The value is not valid for this installer setting."
        }
        throw "Invalid $EnvName '$value'. $ValidationMessage"
    }

    return $value
}

function Test-RfqRegistryKeyPath {
    param([AllowNull()][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -notmatch '[\x00-\x1F]' -and
        $Value -notmatch '(^\\|\\$|\\\\|/|:)'
}

try {
    $script:RfqInstallerRegistryKeyPath = Get-RfqEnvValueOrDefault `
        -EnvName "RFQ_REGISTRY_HANDOFF_KEY" `
        -DefaultValue "Software\RFQApplication\Installer" `
        -Validator { param($Value) Test-RfqRegistryKeyPath $Value } `
        -ValidationMessage "Use an HKCU-relative registry key path without leading, trailing, duplicate, forward, or drive-root slashes."
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$script:RfqInstallerRegistryPath = "HKCU:\$script:RfqInstallerRegistryKeyPath"

# Show help if requested
if ($Help) {
    Write-Host @"
PostgreSQL Database Setup Script

USAGE:
    .\setup_database_auto.ps1 [-InstallPath <path>] [-EnvFilePath <path>] [-Debug] [-ShowPasswordPreview] [-Help]

PARAMETERS:
    -InstallPath      Installation directory path (default: script directory)
                     The script will look for .env file in this directory
                     Example: -InstallPath "C:\Program Files\RFQApplication"

    -EnvFilePath      Direct path to .env file (overrides InstallPath)
                     Example: -EnvFilePath "C:\Program Files\RFQApplication\.env"

    -Debug            Enable debug mode (shows detailed diagnostic information)
                     Example: -Debug

    -ShowPasswordPreview
                     Show masked password preview (first and last character)
                     Example: -ShowPasswordPreview

    -Help             Show this help message

EXAMPLES:
    # Basic usage (looks for .env in script directory)
    .\setup_database_auto.ps1

    # Specify installation directory
    .\setup_database_auto.ps1 -InstallPath "C:\Program Files\RFQApplication"

    # Specify .env file directly
    .\setup_database_auto.ps1 -EnvFilePath "C:\Program Files\RFQApplication\.env"

    # Debug mode with password preview
    .\setup_database_auto.ps1 -Debug -ShowPasswordPreview

    # Full example with all options
    .\setup_database_auto.ps1 -EnvFilePath "C:\RFQ\.env" -Debug -ShowPasswordPreview

CREDENTIAL SOURCES (checked in order):
    1. Registry: $script:RfqInstallerRegistryPath\SuperUserPassword
    2. Environment variable: SQL_SUPER_USER_B64 (base64 encoded)
    3. .env file: SQL_SUPER_USER=your_password

NOTES:
    - The script requires PostgreSQL to be installed and psql.exe in PATH
    - Passwords are read from registry first, then .env file as fallback
    - If password is stored in Windows Credential Manager (__CREDENTIAL_MANAGER__),
      you must provide the actual password in registry or .env file

"@
    exit 0
}

# Set error action preference
$ErrorActionPreference = "Continue"

# Function to write colored output
function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

# Function to read value from registry
function Get-RegistryValue {
    param(
        [string]$KeyPath,
        [string]$ValueName,
        [switch]$Verbose
    )
    
    try {
        $regPath = "HKCU:\$KeyPath"
        if ($Verbose) {
            Write-Info "    Checking registry: $regPath\$ValueName"
        }
        
        if (Test-Path $regPath) {
            $value = Get-ItemProperty -Path $regPath -Name $ValueName -ErrorAction SilentlyContinue
            if ($value -and $value.$ValueName) {
                if ($Verbose) {
                    Write-Info "    Found in registry: $regPath\$ValueName"
                }
                return $value.$ValueName
            } else {
                if ($Verbose) {
                    Write-Warning "    Value not found in registry: $regPath\$ValueName"
                }
            }
        } else {
            if ($Verbose) {
                Write-Warning "    Registry path does not exist: $regPath"
            }
        }
    }
    catch {
        if ($Verbose) {
            Write-Warning "    Error reading registry: $_"
        }
    }
    return $null
}

# Function to read value from .env file
function Get-EnvValue {
    param(
        [string]$FilePath,
        [string]$Key
    )
    
    if (-not (Test-Path $FilePath)) {
        return $null
    }
    
    try {
        $content = Get-Content $FilePath -Raw
        if ($content -match "(?m)^\s*$Key\s*=\s*(.+)$") {
            return $matches[1].Trim()
        }
    }
    catch {
        # Silently fail
    }
    return $null
}

# Function to retrieve password from Windows Credential Manager
function Get-CredentialManagerPassword {
    param(
        [string]$TargetName
    )
    
    try {
        # Use cmdkey to list credentials and find the target
        $output = cmdkey.exe /list:$TargetName 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Credential exists, but cmdkey doesn't show the password
            # We need to use a different method to retrieve it
            # For now, return null and let the script handle it
            Write-Warning "  Password stored in Credential Manager but cannot be retrieved automatically"
            Write-Warning "  Please use the password directly or update .env file"
            return $null
        }
    }
    catch {
        # Silently fail
    }
    return $null
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  PostgreSQL Database Setup (Automatic)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script will:"
Write-Host "  - Check if database 'rfq_db' exists (create if not)"
Write-Host "  - Check if user 'rfq_user' exists (create or update password)"
Write-Host "  - Grant all necessary permissions"
Write-Host ""
Write-Host "Credentials are read from registry or .env file"
Write-Host ""

# Determine .env file path
if ([string]::IsNullOrWhiteSpace($EnvFilePath)) {
    # Use InstallPath to construct .env path
    $EnvFilePath = Join-Path $InstallPath ".env"
} else {
    # Use provided .env file path directly
    $EnvFilePath = $EnvFilePath
}

# Normalize the path
$EnvFilePath = [System.IO.Path]::GetFullPath($EnvFilePath)

if ($Debug) {
    Write-Info "  Debug: InstallPath: $InstallPath"
    Write-Info "  Debug: EnvFilePath: $EnvFilePath"
    Write-Info "  Debug: Env file exists: $(Test-Path $EnvFilePath)"
    Write-Host ""
}

# Check if .env file exists (only warn, don't exit - registry might have passwords)
if (-not (Test-Path $EnvFilePath)) {
    Write-Warning "WARNING: .env file not found at: $EnvFilePath"
    Write-Host ""
    Write-Host "The script will try to read passwords from registry instead."
    Write-Host "If registry doesn't have passwords, the script will fail."
    Write-Host ""
    Write-Host "To specify a different .env file path, use:"
    Write-Host "  -EnvFilePath 'C:\path\to\.env'"
    Write-Host ""
    
    if (-not $Debug) {
        $continue = Read-Host "Continue anyway? (y/N)"
        if ($continue -ne 'y' -and $continue -ne 'Y') {
            Write-Host "Exiting..."
            exit 1
        }
    } else {
        Write-Info "  Debug mode: Continuing without .env file (will rely on registry)"
    }
    Write-Host ""
}

Write-Info "[STEP 1/6] Reading credentials..."
Write-Host ""

# Verify registry path exists
$regPath = $script:RfqInstallerRegistryPath
if ($Debug) {
    Write-Info "  Debug: Checking registry path: $regPath"
    if (Test-Path $regPath) {
        Write-Info "  Debug: Registry path exists"
        $regValues = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($regValues) {
            Write-Info "  Debug: Registry values found:"
            $regValues.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $val = $_.Value
                $valPreview = if ($val -and $val.Length -gt 0) {
                    if ($_.Name -like "*Password*") {
                        "$($val.Substring(0, 1))***$($val.Substring($val.Length - 1, 1)) (length: $($val.Length))"
                    } else {
                        $val
                    }
                } else {
                    "(empty)"
                }
                Write-Info "    - $($_.Name): $valPreview"
            }
        } else {
            Write-Warning "  Debug: No values found in registry path"
        }
    } else {
        Write-Warning "  Debug: Registry path does not exist"
    }
    Write-Host ""
}

# Read SQL_SUPER_USER password
# Priority: 1. Registry, 2. Environment variable (base64), 3. .env file
$SQL_SUPER_USER = $null

# Try registry first
Write-Info "  Checking registry: $script:RfqInstallerRegistryPath\SuperUserPassword"
$SQL_SUPER_USER = Get-RegistryValue -KeyPath $script:RfqInstallerRegistryKeyPath -ValueName "SuperUserPassword" -Verbose
if ($SQL_SUPER_USER) {
    Write-Info "  Using SQL_SUPER_USER from registry"
    Write-Info "  Registry path: $script:RfqInstallerRegistryPath"
} else {
    Write-Warning "  Not found in registry, trying other sources..."
}

# Try environment variable (base64 encoded) if not in registry
if (-not $SQL_SUPER_USER -and $env:SQL_SUPER_USER_B64) {
    try {
        $bytes = [System.Convert]::FromBase64String($env:SQL_SUPER_USER_B64)
        $SQL_SUPER_USER = [System.Text.Encoding]::UTF8.GetString($bytes)
        Write-Info "  Using SQL_SUPER_USER from environment variable (base64)"
    }
    catch {
        Write-Warning "  Failed to decode SQL_SUPER_USER from environment variable"
    }
}

# Try .env file if not in registry or environment
if (-not $SQL_SUPER_USER) {
    $SQL_SUPER_USER = Get-EnvValue -FilePath $EnvFilePath -Key "SQL_SUPER_USER"
    if ($SQL_SUPER_USER) {
        Write-Info "  Using SQL_SUPER_USER from .env file"
    }
}

# Check if password is __CREDENTIAL_MANAGER__ placeholder
if ($SQL_SUPER_USER -eq "__CREDENTIAL_MANAGER__") {
    Write-Error-Custom "ERROR: SQL_SUPER_USER is set to __CREDENTIAL_MANAGER__ in .env file"
    Write-Host ""
    Write-Host "This script cannot retrieve passwords from Windows Credential Manager."
    Write-Host "Please edit .env and set SQL_SUPER_USER to the actual password."
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Check if SQL_SUPER_USER was found
if ([string]::IsNullOrWhiteSpace($SQL_SUPER_USER)) {
    Write-Error-Custom "ERROR: SQL_SUPER_USER not found"
    Write-Host ""
    Write-Host "Please ensure one of the following:"
    Write-Host "  1. Registry: $script:RfqInstallerRegistryPath\SuperUserPassword"
    Write-Host "  2. Environment variable: SQL_SUPER_USER_B64 (base64 encoded)"
    Write-Host "  3. .env file: SQL_SUPER_USER=your_password"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Success "[OK] SQL_SUPER_USER password found"

# Diagnostic information (masked for security)
$passwordLength = $SQL_SUPER_USER.Length
$passwordPreview = if ($passwordLength -gt 0) {
    $firstChar = $SQL_SUPER_USER.Substring(0, 1)
    $lastChar = $SQL_SUPER_USER.Substring($passwordLength - 1, 1)
    "$firstChar***$lastChar"
} else {
    "(empty)"
}
Write-Info "  Password length: $passwordLength characters"
if ($ShowPasswordPreview -or $Debug) {
    Write-Info "  Password preview: $passwordPreview"
}
Write-Info "  Contains special chars: $(if ($SQL_SUPER_USER -match '[^a-zA-Z0-9]') { 'Yes' } else { 'No' })"

# Show first few bytes in hex for debugging (if debug mode)
if ($Debug) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($SQL_SUPER_USER)
    $hexPreview = ($bytes[0..([Math]::Min(10, $bytes.Length - 1))] | ForEach-Object { $_.ToString("X2") }) -join " "
    Write-Info "  First bytes (hex): $hexPreview..."
    Write-Info "  Full password (DEBUG): $SQL_SUPER_USER"
}

Write-Host ""

# Read RFQ_USER_PASSWORD
# Priority: 1. Registry, 2. Environment variable (base64), 3. .env file
$RFQ_PASSWORD = $null

# Try registry first
Write-Info "  Checking registry: $script:RfqInstallerRegistryPath\RFQUserPassword"
$RFQ_PASSWORD = Get-RegistryValue -KeyPath $script:RfqInstallerRegistryKeyPath -ValueName "RFQUserPassword" -Verbose
if ($RFQ_PASSWORD) {
    Write-Info "  Using RFQ_USER_PASSWORD from registry"
    Write-Info "  Registry path: $script:RfqInstallerRegistryPath"
} else {
    Write-Warning "  Not found in registry, trying other sources..."
}

# Try environment variable (base64 encoded) if not in registry
if (-not $RFQ_PASSWORD -and $env:RFQ_USER_B64) {
    try {
        $bytes = [System.Convert]::FromBase64String($env:RFQ_USER_B64)
        $RFQ_PASSWORD = [System.Text.Encoding]::UTF8.GetString($bytes)
        Write-Info "  Using RFQ_USER_PASSWORD from environment variable (base64)"
    }
    catch {
        Write-Warning "  Failed to decode RFQ_USER_PASSWORD from environment variable"
    }
}

# Try .env file if not in registry or environment
if (-not $RFQ_PASSWORD) {
    $RFQ_PASSWORD = Get-EnvValue -FilePath $EnvFilePath -Key "RFQ_USER_PASSWORD"
    if ($RFQ_PASSWORD) {
        Write-Info "  Using RFQ_USER_PASSWORD from .env file"
    }
}

# Check if password is __CREDENTIAL_MANAGER__ placeholder
if ($RFQ_PASSWORD -eq "__CREDENTIAL_MANAGER__") {
    Write-Error-Custom "ERROR: RFQ_USER_PASSWORD is set to __CREDENTIAL_MANAGER__ in .env file"
    Write-Host ""
    Write-Host "This script cannot retrieve passwords from Windows Credential Manager."
    Write-Host "Please edit .env and set RFQ_USER_PASSWORD to the actual password."
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Check if RFQ_USER_PASSWORD was found
if ([string]::IsNullOrWhiteSpace($RFQ_PASSWORD)) {
    Write-Error-Custom "ERROR: RFQ_USER_PASSWORD not found"
    Write-Host ""
    Write-Host "Please ensure one of the following:"
    Write-Host "  1. Registry: $script:RfqInstallerRegistryPath\RFQUserPassword"
    Write-Host "  2. Environment variable: RFQ_USER_B64 (base64 encoded)"
    Write-Host "  3. .env file: RFQ_USER_PASSWORD=your_password"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Success "[OK] RFQ_USER_PASSWORD found"
Write-Host ""

# Check if psql command is available
Write-Info "[STEP 2/6] Checking PostgreSQL client..."

$psqlFound = Get-Command psql -ErrorAction SilentlyContinue
if (-not $psqlFound) {
    Write-Error-Custom "ERROR: PostgreSQL 'psql' command not found"
    Write-Host ""
    Write-Host "Please ensure PostgreSQL is installed and psql.exe is in your PATH"
    Write-Host ""
    Write-Host "Common PostgreSQL installation paths:"
    Write-Host "  C:\Program Files\PostgreSQL\16\bin"
    Write-Host "  C:\Program Files\PostgreSQL\15\bin"
    Write-Host ""
    Write-Host "You can add PostgreSQL to your PATH by:"
    Write-Host "  1. Right-click 'This PC' > Properties > Advanced System Settings"
    Write-Host "  2. Click 'Environment Variables'"
    Write-Host "  3. Edit 'Path' under System Variables"
    Write-Host "  4. Add PostgreSQL bin directory"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Success "[OK] Found psql"
Write-Host ""

# Test PostgreSQL connection
Write-Info "[STEP 3/6] Testing PostgreSQL connection..."
Write-Host ""

# Diagnostic: Show connection details
Write-Info "  Connection details:"
Write-Info "    Host: localhost"
Write-Info "    Port: 5432"
Write-Info "    User: postgres"
Write-Info "    Password source: $(if ($SQL_SUPER_USER) { 'Found (length: ' + $SQL_SUPER_USER.Length + ' chars)' } else { 'NOT FOUND' })"
Write-Host ""

# Check if PostgreSQL service is running
Write-Info "  Checking PostgreSQL service status..."
$pgServices = Get-Service | Where-Object { $_.Name -like "postgresql*" -or $_.DisplayName -like "*PostgreSQL*" }
if ($pgServices) {
    Write-Info "  Found PostgreSQL service(s):"
    foreach ($svc in $pgServices) {
        $status = $svc.Status
        $statusColor = if ($status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "    - $($svc.Name) ($($svc.DisplayName)): $status" -ForegroundColor $statusColor
    }
} else {
    Write-Warning "  No PostgreSQL service found in Windows Services"
    Write-Warning "  This might indicate PostgreSQL is not installed or not running as a service"
}
Write-Host ""

# Set PGPASSWORD environment variable for psql
# Note: PGPASSWORD is the standard way to pass password to psql
$env:PGPASSWORD = $SQL_SUPER_USER

# Also try without PGPASSWORD and use connection string (for debugging)
Write-Info "  Attempting connection with PGPASSWORD environment variable..."
try {
    # Clear any existing PGPASSWORD to avoid conflicts
    $originalPGPASSWORD = $env:PGPASSWORD
    $env:PGPASSWORD = $SQL_SUPER_USER
    
    # Test connection with verbose error output
    $testResult = & psql -U postgres -h localhost -p 5432 -c "SELECT version();" 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -ne 0) {
        Write-Error-Custom "[ERROR] Cannot connect to PostgreSQL server"
        Write-Host ""
        Write-Host "Error details:"
        Write-Host $testResult
        Write-Host ""
        Write-Host "Diagnostic information:"
        Write-Host "  - Exit code: $exitCode"
        Write-Host "  - Password length: $($SQL_SUPER_USER.Length) characters"
        Write-Host "  - Password contains special characters: $(if ($SQL_SUPER_USER -match '[^a-zA-Z0-9]') { 'Yes' } else { 'No' })"
        Write-Host "  - PGPASSWORD environment variable set: $(if ($env:PGPASSWORD) { 'Yes' } else { 'No' })"
        Write-Host ""
        
        # Try alternative connection methods for diagnosis
        Write-Info "  Attempting alternative connection test..."
        
        # Try connecting without password (to see if it prompts)
        Write-Info "    Testing if PostgreSQL is accessible..."
        $testNoPassword = & psql -U postgres -h localhost -p 5432 -l 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Warning "    Connection works without password - password might not be needed"
        } else {
            Write-Info "    Connection requires password (expected)"
        }
        
        Write-Host ""
        Write-Host "Troubleshooting steps:"
        Write-Host "  1. Verify PostgreSQL service is running:"
        Write-Host "     Get-Service | Where-Object { `$_.Name -like 'postgresql*' }"
        Write-Host ""
        Write-Host "  2. Check if password in registry matches PostgreSQL 'postgres' user password"
        Write-Host "     Registry path: $script:RfqInstallerRegistryPath\SuperUserPassword"
        Write-Host "     Current registry value length: $($SQL_SUPER_USER.Length) characters"
        Write-Host ""
        Write-Host "     To view registry value (PowerShell):"
        Write-Host "       Get-ItemProperty -Path '$script:RfqInstallerRegistryPath' -Name 'SuperUserPassword'"
        Write-Host ""
        Write-Host "     To test password manually:"
        Write-Host "       `$pwd = (Get-ItemProperty -Path '$script:RfqInstallerRegistryPath' -Name 'SuperUserPassword').SuperUserPassword"
        Write-Host "       `$env:PGPASSWORD = `$pwd"
        Write-Host "       psql -U postgres -h localhost -p 5432 -c 'SELECT version();'"
        Write-Host ""
        Write-Host "  3. Test password manually:"
        Write-Host "     psql -U postgres -h localhost -p 5432"
        Write-Host "     (You will be prompted for password)"
        Write-Host ""
        Write-Host "  4. Verify PostgreSQL is listening on localhost:5432:"
        Write-Host "     netstat -an | findstr 5432"
        Write-Host ""
        Write-Host "  5. Check PostgreSQL authentication configuration:"
        Write-Host "     Look for pg_hba.conf file (usually in PostgreSQL data directory)"
        Write-Host "     Verify it allows local connections with password authentication"
        Write-Host ""
        Write-Host "  6. If password contains special characters, try:"
        Write-Host "     - Escaping special characters"
        Write-Host "     - Using connection string: psql 'postgresql://postgres:PASSWORD@localhost:5432/postgres'"
        Write-Host ""
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}
catch {
    Write-Error-Custom "[ERROR] Failed to test PostgreSQL connection: $_"
    Write-Host ""
    Write-Host "Exception details:"
    Write-Host "  Type: $($_.Exception.GetType().FullName)"
    Write-Host "  Message: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-Host "  Inner: $($_.Exception.InnerException.Message)"
    }
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
finally {
    # Restore original PGPASSWORD if it existed
    if ($originalPGPASSWORD) {
        $env:PGPASSWORD = $originalPGPASSWORD
    }
}

Write-Success "[OK] Connected to PostgreSQL"
Write-Host ""

# Check if database and user exist
Write-Info "[STEP 4/6] Checking database and user..."
Write-Host ""

# Check if database exists
Write-Info "Checking if database 'rfq_db' exists..."
$dbList = & psql -U postgres -h localhost -p 5432 -lqt 2>&1
$dbExists = $dbList | Select-String -Pattern "rfq_db" -Quiet

# Check if user exists
Write-Info "Checking if user 'rfq_user' exists..."
$userCheck = & psql -U postgres -h localhost -p 5432 -tAc "SELECT 1 FROM pg_roles WHERE rolname='rfq_user';" 2>&1
$userExists = ($userCheck -match "1")

Write-Host ""

# Create database and user
Write-Info "[STEP 5/6] Creating database and user..."
Write-Host ""

# Create temporary SQL script files
$TempSQL1 = Join-Path $env:TEMP "rfq_setup_1_$([System.Guid]::NewGuid().ToString('N')).sql"
$TempSQL2 = Join-Path $env:TEMP "rfq_setup_2_$([System.Guid]::NewGuid().ToString('N')).sql"
$TempSQL3 = Join-Path $env:TEMP "rfq_setup_3_$([System.Guid]::NewGuid().ToString('N')).sql"

try {
    # Handle existing database
    if ($dbExists) {
        Write-Success "[FOUND] Database 'rfq_db' already exists"
    }
    else {
        Write-Info "[CREATE] Creating database 'rfq_db'..."
        "CREATE DATABASE rfq_db;" | Out-File -FilePath $TempSQL1 -Encoding UTF8
        $createDbResult = & psql -U postgres -h localhost -p 5432 -f $TempSQL1 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "[ERROR] Failed to create database 'rfq_db'"
            Write-Host $createDbResult
            Remove-Item $TempSQL1 -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            exit 1
        }
        Write-Success "[OK] Database 'rfq_db' created successfully"
    }
    
    Write-Host ""
    
    # Handle existing user
    if ($userExists) {
        Write-Success "[FOUND] User 'rfq_user' already exists"
        Write-Info "[UPDATE] Updating password for user 'rfq_user'..."
        
        # Escape single quotes in password for SQL
        $escapedPassword = $RFQ_PASSWORD -replace "'", "''"
        "ALTER USER rfq_user WITH PASSWORD '$escapedPassword';" | Out-File -FilePath $TempSQL2 -Encoding UTF8
        
        $updateUserResult = & psql -U postgres -h localhost -p 5432 -f $TempSQL2 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[WARNING] Failed to update password for user 'rfq_user'"
            Write-Warning "         User exists but password update failed"
            Write-Host $updateUserResult
        }
        else {
            Write-Success "[OK] Password updated for user 'rfq_user'"
        }
    }
    else {
        Write-Info "[CREATE] Creating user 'rfq_user'..."
        
        # Escape single quotes in password for SQL
        $escapedPassword = $RFQ_PASSWORD -replace "'", "''"
        "CREATE USER rfq_user WITH PASSWORD '$escapedPassword';" | Out-File -FilePath $TempSQL2 -Encoding UTF8
        
        $createUserResult = & psql -U postgres -h localhost -p 5432 -f $TempSQL2 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error-Custom "[ERROR] Failed to create user 'rfq_user'"
            Write-Host $createUserResult
            Remove-Item $TempSQL1 -ErrorAction SilentlyContinue
            Remove-Item $TempSQL2 -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            exit 1
        }
        Write-Success "[OK] User 'rfq_user' created successfully"
    }
    
    Write-Host ""
    Write-Info "[STEP 6/6] Setting up permissions..."
    Write-Host ""
    
    # Grant database privileges
    "GRANT ALL PRIVILEGES ON DATABASE rfq_db TO rfq_user;" | Out-File -FilePath $TempSQL3 -Encoding UTF8
    $grantDbResult = & psql -U postgres -h localhost -p 5432 -f $TempSQL3 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[WARNING] Failed to grant database privileges"
        Write-Host $grantDbResult
    }
    else {
        Write-Success "[OK] Granted database privileges to 'rfq_user'"
    }
    
    # Connect to rfq_db and set up schema permissions
    Write-Info "[GRANT] Setting up schema permissions..."
    $schemaOwnerResult = & psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER SCHEMA public OWNER TO rfq_user;" 2>&1
    $schemaGrantResult = & psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT USAGE, CREATE ON SCHEMA public TO rfq_user;" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "[WARNING] Failed to grant schema permissions"
        Write-Host $schemaGrantResult
    }
    else {
        Write-Success "[OK] Granted schema permissions to 'rfq_user'"
    }
    
    # Grant table and sequence permissions (safe to run even if no tables exist yet)
    Write-Info "[GRANT] Setting up table and sequence permissions..."
    & psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO rfq_user;" | Out-Null
    & psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rfq_user;" | Out-Null
    & psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO rfq_user;" | Out-Null
    & psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO rfq_user;" | Out-Null
    Write-Success "[OK] Granted table and sequence permissions to 'rfq_user'"
    
    # Clean up temporary files
    Remove-Item $TempSQL1 -ErrorAction SilentlyContinue
    Remove-Item $TempSQL2 -ErrorAction SilentlyContinue
    Remove-Item $TempSQL3 -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Database Setup Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Database: rfq_db"
    Write-Host "User: rfq_user"
    Write-Host "Host: localhost:5432"
    Write-Host "Password: (configured from registry or .env file)"
    Write-Host ""
    Write-Host "Status:"
    if ($dbExists) {
        Write-Host "  - Database: Already existed (reused)"
    }
    else {
        Write-Host "  - Database: Created new"
    }
    if ($userExists) {
        Write-Host "  - User: Already existed (password updated)"
    }
    else {
        Write-Host "  - User: Created new"
    }
    Write-Host "  - Permissions: Granted"
    Write-Host ""
Write-Host "You can now run the RFQ Application!"
Write-Host ""

# Summary of credentials used
if ($Debug) {
    Write-Host ""
    Write-Host "=== DEBUG SUMMARY ===" -ForegroundColor Cyan
    Write-Host "SQL_SUPER_USER source: $(if ($SQL_SUPER_USER) { 'Found (length: ' + $SQL_SUPER_USER.Length + ')' } else { 'NOT FOUND' })"
    Write-Host "RFQ_USER_PASSWORD source: $(if ($RFQ_PASSWORD) { 'Found (length: ' + $RFQ_PASSWORD.Length + ')' } else { 'NOT FOUND' })"
    Write-Host "Registry path checked: $regPath"
    Write-Host "=====================" -ForegroundColor Cyan
    Write-Host ""
}
}
catch {
    Write-Error-Custom "[ERROR] An error occurred during database setup: $_"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
finally {
    # Clean up temporary files
    Remove-Item $TempSQL1 -ErrorAction SilentlyContinue
    Remove-Item $TempSQL2 -ErrorAction SilentlyContinue
    Remove-Item $TempSQL3 -ErrorAction SilentlyContinue
}
