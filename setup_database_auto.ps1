# PostgreSQL Database Setup (Automatic)
# This script will:
#   - Check if database 'rfq_db' exists (create if not)
#   - Check if user 'rfq_user' exists (create or update password)
#   - Grant all necessary permissions
#
# Credentials are read from registry (HKEY_CURRENT_USER\Software\RFQApplication\Installer)
# or from .env file as fallback

param(
    [string]$InstallPath = $PSScriptRoot
)

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
        [string]$ValueName
    )
    
    try {
        $regPath = "HKCU:\$KeyPath"
        if (Test-Path $regPath) {
            $value = Get-ItemProperty -Path $regPath -Name $ValueName -ErrorAction SilentlyContinue
            if ($value -and $value.$ValueName) {
                return $value.$ValueName
            }
        }
    }
    catch {
        # Silently fail
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
$EnvFilePath = Join-Path $InstallPath ".env"

# Check if .env file exists
if (-not (Test-Path $EnvFilePath)) {
    Write-Error-Custom "ERROR: .env file not found at: $EnvFilePath"
    Write-Host ""
    Write-Host "Please ensure the .env file exists in the installation directory."
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Info "[STEP 1/6] Reading credentials..."

# Read SQL_SUPER_USER password
# Priority: 1. Registry, 2. Environment variable (base64), 3. .env file
$SQL_SUPER_USER = $null

# Try registry first
$SQL_SUPER_USER = Get-RegistryValue -KeyPath "Software\RFQApplication\Installer" -ValueName "SuperUserPassword"
if ($SQL_SUPER_USER) {
    Write-Info "  Using SQL_SUPER_USER from registry"
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
    Write-Host "  1. Registry: HKCU:\Software\RFQApplication\Installer\SuperUserPassword"
    Write-Host "  2. Environment variable: SQL_SUPER_USER_B64 (base64 encoded)"
    Write-Host "  3. .env file: SQL_SUPER_USER=your_password"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Success "[OK] SQL_SUPER_USER password found"
Write-Host ""

# Read RFQ_USER_PASSWORD
# Priority: 1. Registry, 2. Environment variable (base64), 3. .env file
$RFQ_PASSWORD = $null

# Try registry first
$RFQ_PASSWORD = Get-RegistryValue -KeyPath "Software\RFQApplication\Installer" -ValueName "RFQUserPassword"
if ($RFQ_PASSWORD) {
    Write-Info "  Using RFQ_USER_PASSWORD from registry"
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
    Write-Host "  1. Registry: HKCU:\Software\RFQApplication\Installer\RFQUserPassword"
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

# Set PGPASSWORD environment variable for psql
$env:PGPASSWORD = $SQL_SUPER_USER

try {
    $testResult = & psql -U postgres -h localhost -p 5432 -c "SELECT version();" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error-Custom "[ERROR] Cannot connect to PostgreSQL server"
        Write-Host ""
        Write-Host "Error details:"
        Write-Host $testResult
        Write-Host ""
        Write-Host "Please check:"
        Write-Host "  1. PostgreSQL service is running"
        Write-Host "  2. SQL_SUPER_USER password is correct"
        Write-Host "  3. PostgreSQL is listening on localhost:5432"
        Write-Host "  4. User 'postgres' exists and has superuser privileges"
        Write-Host ""
        Write-Host "To start PostgreSQL service:"
        Write-Host "  - Windows Services: services.msc (look for 'postgresql-x64-XX')"
        Write-Host "  - Command Line: net start postgresql-x64-16"
        Write-Host ""
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}
catch {
    Write-Error-Custom "[ERROR] Failed to test PostgreSQL connection: $_"
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
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

