#Requires -Version 5.1
<#
.SYNOPSIS
    Helper script for database setup password handling.

.DESCRIPTION
    Handles password reading from .env files and creates necessary
    configuration files for PostgreSQL setup. Designed to handle
    ALL special characters including caret (^), dollar ($),
    exclamation (!), and others.

.PARAMETER Action
    The action to perform:
    - CreatePgpass: Create pgpass.conf for postgres authentication
    - CreateUserSQL: Create SQL file for user creation
    - CreateAlterSQL: Create SQL file for password update
    - Cleanup: Restore original pgpass.conf

.PARAMETER EnvFile
    Path to the .env file. Defaults to ".env" in current directory.

.PARAMETER OutputFile
    Path to output file (required for SQL actions).

.PARAMETER BackupPgpass
    If specified, backup existing pgpass.conf before overwriting.
    Default is $true.

.OUTPUTS
    Exit codes:
    0  - Success
    1  - .env file not found
    2  - Required password variable not found in .env
    3  - Failed to create pgpass directory
    4  - Failed to write pgpass.conf
    5  - Failed to write SQL file

.EXAMPLE
    .\setup_db_helper.ps1 -Action CreatePgpass -EnvFile ".env"
    Creates pgpass.conf using SQL_SUPER_USER from .env

.EXAMPLE
    .\setup_db_helper.ps1 -Action CreateUserSQL -EnvFile ".env" -OutputFile "C:\temp\create.sql"
    Creates SQL file for user creation with RFQ_USER_PASSWORD from .env

.NOTES
    Author: RFQ Development Team
    Version: 1.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('CreatePgpass', 'CreateUserSQL', 'CreateAlterSQL', 'Cleanup')]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [string]$EnvFile = ".env",

    [Parameter(Mandatory=$false)]
    [string]$OutputFile,

    [Parameter(Mandatory=$false)]
    [bool]$BackupPgpass = $true
)

#region Exit Codes
$script:EXIT_SUCCESS = 0
$script:EXIT_ENV_NOT_FOUND = 1
$script:EXIT_VAR_NOT_FOUND = 2
$script:EXIT_PGPASS_DIR_FAILED = 3
$script:EXIT_PGPASS_WRITE_FAILED = 4
$script:EXIT_SQL_WRITE_FAILED = 5
#endregion

#region Helper Functions

function Get-PasswordFromEnv {
    <#
    .SYNOPSIS
        Reads a password variable from .env file.
    .DESCRIPTION
        Uses regex to extract variable value, handling all special characters.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvFilePath,

        [Parameter(Mandatory=$true)]
        [string]$VariableName
    )

    try {
        # Read entire file as raw text - this preserves ALL characters
        $content = Get-Content -Path $EnvFilePath -Raw -Encoding UTF8 -ErrorAction Stop

        # Build regex pattern
        # (?m) = multiline mode (^ and $ match line boundaries)
        $escapedVarName = [regex]::Escape($VariableName)
        $pattern = "(?m)^$escapedVarName=(.*)$"

        if ($content -match $pattern) {
            $password = $matches[1]

            # Remove trailing carriage return if present (Windows line endings)
            $password = $password.TrimEnd("`r")

            # Remove leading/trailing whitespace
            $password = $password.Trim()

            Write-Verbose "Found $VariableName in .env (length: $($password.Length) chars)"
            return $password
        }

        Write-Verbose "$VariableName not found in .env file"
        return $null
    }
    catch {
        Write-Error "Failed to read .env file: $_"
        return $null
    }
}

function Get-PgpassPath {
    return Join-Path $env:APPDATA "postgresql\pgpass.conf"
}

function Get-PgpassBackupPath {
    return Join-Path $env:APPDATA "postgresql\pgpass.conf.backup"
}

function New-PgpassContent {
    <#
    .SYNOPSIS
        Creates pgpass.conf content string
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Password
    )

    # pgpass format: hostname:port:database:username:password
    # Escape backslashes first, then colons
    $escapedPassword = $Password
    $escapedPassword = $escapedPassword -replace '\\', '\\'
    $escapedPassword = $escapedPassword -replace ':', '\:'

    return "localhost:5432:*:postgres:$escapedPassword"
}

function New-DollarQuotedSql {
    <#
    .SYNOPSIS
        Creates SQL statement with dollar-quoted password
    .DESCRIPTION
        Uses PostgreSQL dollar quoting ($$..$$) which treats content literally.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$SqlPrefix,

        [Parameter(Mandatory=$true)]
        [string]$Password
    )

    # Check if password contains $$ (unlikely but handle it)
    if ($Password -match '\$\$') {
        # Use alternative delimiter $tag$...$tag$
        return "$SqlPrefix `$rfqpwd`$$Password`$rfqpwd`$;"
    }

    return "$SqlPrefix `$`$$Password`$`$;"
}

#endregion

#region Action Functions

function Invoke-CreatePgpass {
    Write-Verbose "Action: CreatePgpass"
    Write-Verbose "EnvFile: $EnvFile"

    # Check .env exists
    if (-not (Test-Path $EnvFile)) {
        Write-Host "[ERROR] .env file not found: $EnvFile" -ForegroundColor Red
        return $script:EXIT_ENV_NOT_FOUND
    }

    # Read password
    $password = Get-PasswordFromEnv -EnvFilePath $EnvFile -VariableName "SQL_SUPER_USER"
    if ($null -eq $password -or $password -eq "") {
        Write-Host "[ERROR] SQL_SUPER_USER not found in .env file" -ForegroundColor Red
        return $script:EXIT_VAR_NOT_FOUND
    }

    # Ensure pgpass directory exists
    $pgpassDir = Join-Path $env:APPDATA "postgresql"
    if (-not (Test-Path $pgpassDir)) {
        try {
            New-Item -ItemType Directory -Path $pgpassDir -Force | Out-Null
            Write-Verbose "Created directory: $pgpassDir"
        }
        catch {
            Write-Host "[ERROR] Failed to create pgpass directory: $_" -ForegroundColor Red
            return $script:EXIT_PGPASS_DIR_FAILED
        }
    }

    # Backup existing pgpass.conf
    $pgpassPath = Get-PgpassPath
    $pgpassBackup = Get-PgpassBackupPath

    if ($BackupPgpass -and (Test-Path $pgpassPath)) {
        try {
            Copy-Item -Path $pgpassPath -Destination $pgpassBackup -Force
            Write-Verbose "Backed up existing pgpass.conf"
        }
        catch {
            Write-Warning "Could not backup existing pgpass.conf: $_"
        }
    }

    # Create pgpass content
    $pgpassContent = New-PgpassContent -Password $password

    # Write pgpass.conf
    try {
        [System.IO.File]::WriteAllText($pgpassPath, $pgpassContent, [System.Text.Encoding]::UTF8)
        Write-Host "[OK] PostgreSQL authentication configured" -ForegroundColor Green
        return $script:EXIT_SUCCESS
    }
    catch {
        Write-Host "[ERROR] Failed to write pgpass.conf: $_" -ForegroundColor Red
        return $script:EXIT_PGPASS_WRITE_FAILED
    }
}

function Invoke-CreateUserSql {
    Write-Verbose "Action: CreateUserSQL"
    Write-Verbose "EnvFile: $EnvFile"
    Write-Verbose "OutputFile: $OutputFile"

    # Validate OutputFile parameter
    if ([string]::IsNullOrEmpty($OutputFile)) {
        Write-Host "[ERROR] OutputFile parameter is required for CreateUserSQL action" -ForegroundColor Red
        return $script:EXIT_SQL_WRITE_FAILED
    }

    # Check .env exists
    if (-not (Test-Path $EnvFile)) {
        Write-Host "[ERROR] .env file not found: $EnvFile" -ForegroundColor Red
        return $script:EXIT_ENV_NOT_FOUND
    }

    # Read password
    $password = Get-PasswordFromEnv -EnvFilePath $EnvFile -VariableName "RFQ_USER_PASSWORD"
    if ($null -eq $password -or $password -eq "") {
        Write-Host "[ERROR] RFQ_USER_PASSWORD not found in .env file" -ForegroundColor Red
        return $script:EXIT_VAR_NOT_FOUND
    }

    # Create SQL statement
    $sql = New-DollarQuotedSql -SqlPrefix "CREATE USER rfq_user WITH PASSWORD" -Password $password

    # Write SQL file
    try {
        [System.IO.File]::WriteAllText($OutputFile, $sql, [System.Text.Encoding]::UTF8)
        Write-Verbose "Created SQL file: $OutputFile"
        Write-Host "[OK] User creation SQL prepared" -ForegroundColor Green
        return $script:EXIT_SUCCESS
    }
    catch {
        Write-Host "[ERROR] Failed to write SQL file: $_" -ForegroundColor Red
        return $script:EXIT_SQL_WRITE_FAILED
    }
}

function Invoke-CreateAlterSql {
    Write-Verbose "Action: CreateAlterSQL"
    Write-Verbose "EnvFile: $EnvFile"
    Write-Verbose "OutputFile: $OutputFile"

    # Validate OutputFile parameter
    if ([string]::IsNullOrEmpty($OutputFile)) {
        Write-Host "[ERROR] OutputFile parameter is required for CreateAlterSQL action" -ForegroundColor Red
        return $script:EXIT_SQL_WRITE_FAILED
    }

    # Check .env exists
    if (-not (Test-Path $EnvFile)) {
        Write-Host "[ERROR] .env file not found: $EnvFile" -ForegroundColor Red
        return $script:EXIT_ENV_NOT_FOUND
    }

    # Read password
    $password = Get-PasswordFromEnv -EnvFilePath $EnvFile -VariableName "RFQ_USER_PASSWORD"
    if ($null -eq $password -or $password -eq "") {
        Write-Host "[ERROR] RFQ_USER_PASSWORD not found in .env file" -ForegroundColor Red
        return $script:EXIT_VAR_NOT_FOUND
    }

    # Create SQL statement
    $sql = New-DollarQuotedSql -SqlPrefix "ALTER USER rfq_user WITH PASSWORD" -Password $password

    # Write SQL file
    try {
        [System.IO.File]::WriteAllText($OutputFile, $sql, [System.Text.Encoding]::UTF8)
        Write-Verbose "Created SQL file: $OutputFile"
        Write-Host "[OK] Password update SQL prepared" -ForegroundColor Green
        return $script:EXIT_SUCCESS
    }
    catch {
        Write-Host "[ERROR] Failed to write SQL file: $_" -ForegroundColor Red
        return $script:EXIT_SQL_WRITE_FAILED
    }
}

function Invoke-Cleanup {
    Write-Verbose "Action: Cleanup"

    $pgpassPath = Get-PgpassPath
    $pgpassBackup = Get-PgpassBackupPath

    try {
        if (Test-Path $pgpassBackup) {
            Move-Item -Path $pgpassBackup -Destination $pgpassPath -Force
            Write-Verbose "Restored pgpass.conf from backup"
        }
        elseif (Test-Path $pgpassPath) {
            Remove-Item -Path $pgpassPath -Force
            Write-Verbose "Removed temporary pgpass.conf"
        }

        Write-Host "[OK] Cleanup completed" -ForegroundColor Green
        return $script:EXIT_SUCCESS
    }
    catch {
        Write-Warning "Cleanup warning: $_"
        return $script:EXIT_SUCCESS
    }
}

#endregion

#region Main

switch ($Action) {
    'CreatePgpass' {
        exit (Invoke-CreatePgpass)
    }
    'CreateUserSQL' {
        exit (Invoke-CreateUserSql)
    }
    'CreateAlterSQL' {
        exit (Invoke-CreateAlterSql)
    }
    'Cleanup' {
        exit (Invoke-Cleanup)
    }
}

#endregion
