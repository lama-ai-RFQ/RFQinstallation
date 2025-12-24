@echo off
REM ========================================
REM   PostgreSQL Database Setup (Automatic)
REM   Version: 3.3 - Uses environment variables for password passing
REM
REM   FEATURES:
REM   - Handles ALL special characters in passwords (including ^)
REM   - Reads Base64 encoded passwords from environment variables
REM   - Falls back to .env file if env vars not set
REM   - Proper error code handling and propagation
REM   - Clear error messages
REM   - Uses pgpass.conf for secure authentication
REM   - Uses dollar quoting for SQL passwords
REM
REM   ENVIRONMENT VARIABLES (set by PowerShell installer):
REM     SUPER_USER_B64  - Base64 encoded PostgreSQL superuser password
REM     RFQ_USER_B64    - Base64 encoded RFQ user password
REM
REM   EXIT CODES:
REM     0  - Success
REM     1  - .env file not found (when no params provided)
REM     2  - Required password variable not found
REM     3  - pgpass directory creation failed
REM     4  - pgpass.conf write failed
REM     5  - SQL file write failed
REM    10  - psql not found in PATH
REM    11  - PostgreSQL connection failed
REM    12  - Database creation failed
REM    13  - User creation failed
REM    14  - Password update failed
REM    15  - Critical privilege grant failed
REM ========================================

REM ========================================
REM Get credentials from environment variables
REM (Set by PowerShell installer before calling this script)
REM ========================================
echo [DEBUG] Checking environment variables...
echo [DEBUG] SUPER_USER_B64 from env: %SUPER_USER_B64:~0,10%...
echo [DEBUG] RFQ_USER_B64 from env: %RFQ_USER_B64:~0,10%...

REM Environment variables SUPER_USER_B64 and RFQ_USER_B64 should already be set
REM by the PowerShell installer. If not set, we'll fall back to .env file.

echo ========================================
echo   PostgreSQL Database Setup
echo ========================================
echo.
echo This script will:
echo   - Check if database 'rfq_db' exists (create if not)
echo   - Check if user 'rfq_user' exists (create or update password)
echo   - Grant all necessary permissions
echo.

REM ========================================
REM Get script directory (for finding helper)
REM ========================================
set "SCRIPT_DIR=%~dp0"

REM ========================================
REM Check prerequisites
REM ========================================

REM Check for PowerShell helper script
if not exist "%SCRIPT_DIR%setup_db_helper.ps1" (
    echo [ERROR] setup_db_helper.ps1 not found
    echo         Expected location: %SCRIPT_DIR%setup_db_helper.ps1
    echo.
    echo         Please ensure the helper script is in the same directory.
    echo.
    pause
    exit /b 1
)

REM Check for .env file (only required if Base64 params not provided)
if not defined SUPER_USER_B64 (
    if not defined RFQ_USER_B64 (
        if not exist ".env" (
            echo [ERROR] .env file not found in current directory
            echo.
            echo Please copy env.template to .env and configure:
            echo   copy env.template .env
            echo   notepad .env
            echo.
            echo Required variables:
            echo   SQL_SUPER_USER=your_postgres_password
            echo   RFQ_USER_PASSWORD=your_rfq_user_password
            echo.
            pause
            exit /b 1
        )
    )
)

REM ========================================
REM Create temporary file paths
REM Note: Created before EnableDelayedExpansion
REM ========================================
set "TEMP_SQL_CREATE=%TEMP%\rfq_create_user_%RANDOM%.sql"
set "TEMP_SQL_ALTER=%TEMP%\rfq_alter_user_%RANDOM%.sql"
set "TEMP_SQL_GRANT=%TEMP%\rfq_grant_%RANDOM%.sql"
set "TEMP_OUTPUT=%TEMP%\rfq_psql_output_%RANDOM%.txt"

REM ========================================
REM Enable delayed expansion early
REM ========================================
setlocal EnableDelayedExpansion

REM Track if we had non-fatal warnings
set "HAD_WARNINGS=0"
set "EXIT_CODE=0"

REM ========================================
REM Set up PostgreSQL authentication
REM ========================================
echo [STEP 1/6] Setting up PostgreSQL authentication...

if defined SUPER_USER_B64 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreatePgpass -SuperUserPasswordB64 "%SUPER_USER_B64%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreatePgpass -EnvFile ".env"
)
set "HELPER_EXIT=!ERRORLEVEL!"

if !HELPER_EXIT! NEQ 0 (
    call :handle_helper_error !HELPER_EXIT! "pgpass creation"
    goto :cleanup_and_exit
)

echo.

REM ========================================
REM Check psql availability
REM ========================================
echo [STEP 2/6] Checking PostgreSQL client...

where psql >nul 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo [ERROR] PostgreSQL 'psql' command not found
    echo.
    echo Please ensure PostgreSQL is installed and psql.exe is in your PATH.
    echo.
    echo Common installation paths:
    echo   C:\Program Files\PostgreSQL\16\bin
    echo   C:\Program Files\PostgreSQL\15\bin
    echo   C:\Program Files\PostgreSQL\14\bin
    echo.
    set "EXIT_CODE=10"
    goto :cleanup_and_exit
)

echo [OK] Found psql
echo.

REM ========================================
REM Test PostgreSQL connection
REM ========================================
echo [STEP 3/6] Testing PostgreSQL connection...

psql -w -U postgres -h localhost -p 5432 -c "SELECT 1;" > "!TEMP_OUTPUT!" 2>&1
set "PSQL_EXIT=!ERRORLEVEL!"

if !PSQL_EXIT! NEQ 0 (
    echo [ERROR] Cannot connect to PostgreSQL server
    echo.
    echo Error details:
    type "!TEMP_OUTPUT!"
    echo.
    echo Please check:
    echo   1. PostgreSQL service is running
    echo   2. SQL_SUPER_USER password in .env is correct
    echo   3. PostgreSQL is listening on localhost:5432
    echo.
    set "EXIT_CODE=11"
    goto :cleanup_and_exit
)

echo [OK] Connected to PostgreSQL
echo.

REM ========================================
REM Check database existence
REM ========================================
echo [STEP 4/6] Checking database status...

psql -w -U postgres -h localhost -p 5432 -lqt 2>nul | findstr /C:"rfq_db" > nul 2>&1
set "DB_EXISTS=!ERRORLEVEL!"

psql -w -U postgres -h localhost -p 5432 -tAc "SELECT 1 FROM pg_roles WHERE rolname='rfq_user'" 2>nul | findstr "1" > nul 2>&1
set "USER_EXISTS=!ERRORLEVEL!"

if !DB_EXISTS! EQU 0 (
    echo [INFO] Database 'rfq_db' already exists
) else (
    echo [INFO] Database 'rfq_db' does not exist - will create
)

if !USER_EXISTS! EQU 0 (
    echo [INFO] User 'rfq_user' already exists - will update password
) else (
    echo [INFO] User 'rfq_user' does not exist - will create
)

echo.

REM ========================================
REM Create database if needed
REM ========================================
echo [STEP 5/6] Setting up database and user...

if !DB_EXISTS! NEQ 0 (
    echo [CREATE] Creating database 'rfq_db'...

    echo CREATE DATABASE rfq_db; > "!TEMP_SQL_GRANT!"
    psql -w -U postgres -h localhost -p 5432 -f "!TEMP_SQL_GRANT!" > "!TEMP_OUTPUT!" 2>&1
    set "PSQL_EXIT=!ERRORLEVEL!"

    if !PSQL_EXIT! NEQ 0 (
        echo [ERROR] Failed to create database ^(exit code: !PSQL_EXIT!^)
        echo.
        echo Error details:
        type "!TEMP_OUTPUT!"
        echo.
        set "EXIT_CODE=12"
        goto :cleanup_and_exit
    )

    echo [OK] Database 'rfq_db' created
) else (
    echo [SKIP] Database 'rfq_db' already exists
)

REM ========================================
REM Create or update user
REM ========================================
if !USER_EXISTS! NEQ 0 (
    REM Create new user
    echo [CREATE] Creating user 'rfq_user'...

    if defined RFQ_USER_B64 (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreateUserSQL -RFQUserPasswordB64 "%RFQ_USER_B64%" -OutputFile "!TEMP_SQL_CREATE!"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreateUserSQL -EnvFile ".env" -OutputFile "!TEMP_SQL_CREATE!"
    )
    set "HELPER_EXIT=!ERRORLEVEL!"

    if !HELPER_EXIT! NEQ 0 (
        echo [ERROR] Failed to prepare user creation SQL
        set "EXIT_CODE=!HELPER_EXIT!"
        goto :cleanup_and_exit
    )

    psql -w -U postgres -h localhost -p 5432 -f "!TEMP_SQL_CREATE!" > "!TEMP_OUTPUT!" 2>&1
    set "PSQL_EXIT=!ERRORLEVEL!"

    if !PSQL_EXIT! NEQ 0 (
        echo [ERROR] Failed to create user ^(exit code: !PSQL_EXIT!^)
        echo.
        echo Error details:
        type "!TEMP_OUTPUT!"
        echo.
        set "EXIT_CODE=13"
        goto :cleanup_and_exit
    )

    echo [OK] User 'rfq_user' created

) else (
    REM Update existing user password
    echo [UPDATE] Updating password for 'rfq_user'...

    if defined RFQ_USER_B64 (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreateAlterSQL -RFQUserPasswordB64 "%RFQ_USER_B64%" -OutputFile "!TEMP_SQL_ALTER!"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action CreateAlterSQL -EnvFile ".env" -OutputFile "!TEMP_SQL_ALTER!"
    )
    set "HELPER_EXIT=!ERRORLEVEL!"

    if !HELPER_EXIT! NEQ 0 (
        echo [ERROR] Failed to prepare password update SQL
        set "EXIT_CODE=!HELPER_EXIT!"
        goto :cleanup_and_exit
    )

    psql -w -U postgres -h localhost -p 5432 -f "!TEMP_SQL_ALTER!" > "!TEMP_OUTPUT!" 2>&1
    set "PSQL_EXIT=!ERRORLEVEL!"

    if !PSQL_EXIT! NEQ 0 (
        echo [ERROR] Failed to update password ^(exit code: !PSQL_EXIT!^)
        echo.
        echo Error details:
        type "!TEMP_OUTPUT!"
        echo.
        set "EXIT_CODE=14"
        goto :cleanup_and_exit
    )

    echo [OK] Password updated for 'rfq_user'
)

echo.

REM ========================================
REM Grant privileges
REM ========================================
echo [STEP 6/6] Granting privileges...

REM Grant database privileges
echo GRANT ALL PRIVILEGES ON DATABASE rfq_db TO rfq_user; > "!TEMP_SQL_GRANT!"
psql -w -U postgres -h localhost -p 5432 -f "!TEMP_SQL_GRANT!" > "!TEMP_OUTPUT!" 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo [WARNING] Failed to grant database privileges
    set "HAD_WARNINGS=1"
) else (
    echo [OK] Granted database privileges
)

REM Grant schema privileges
psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER SCHEMA public OWNER TO rfq_user;" > "!TEMP_OUTPUT!" 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo [WARNING] Failed to set schema owner
    set "HAD_WARNINGS=1"
) else (
    echo [OK] Set schema owner
)

psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT USAGE, CREATE ON SCHEMA public TO rfq_user;" > nul 2>&1
psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO rfq_user;" > nul 2>&1
psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rfq_user;" > nul 2>&1
psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO rfq_user;" > nul 2>&1
psql -w -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO rfq_user;" > nul 2>&1
echo [OK] Granted table and sequence privileges

echo.

REM ========================================
REM Success
REM ========================================
set "EXIT_CODE=0"
goto :cleanup_and_exit

REM ========================================
REM Error handler for PowerShell helper
REM ========================================
:handle_helper_error
set "ERR=%~1"
set "CONTEXT=%~2"
echo.
echo [ERROR] Failed during %CONTEXT%
if "%ERR%"=="1" echo         .env file not found
if "%ERR%"=="2" echo         Required password variable not found in .env
if "%ERR%"=="3" echo         Failed to create pgpass directory
if "%ERR%"=="4" echo         Failed to write pgpass.conf
if "%ERR%"=="5" echo         Failed to write SQL file
echo.
set "EXIT_CODE=%ERR%"
goto :eof

REM ========================================
REM Cleanup and exit
REM ========================================
:cleanup_and_exit

REM Delete temporary files
del "!TEMP_SQL_CREATE!" 2>nul
del "!TEMP_SQL_ALTER!" 2>nul
del "!TEMP_SQL_GRANT!" 2>nul
del "!TEMP_OUTPUT!" 2>nul

REM Cleanup pgpass.conf
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup_db_helper.ps1" -Action Cleanup 2>nul

REM Show final status
echo ========================================
if "!EXIT_CODE!"=="0" (
    if "!HAD_WARNINGS!"=="1" (
        echo   Setup completed with warnings
        echo ========================================
        echo.
        echo Some privilege grants may have failed.
        echo The database and user were created successfully.
        echo.
    ) else (
        echo   Database Setup Complete!
        echo ========================================
        echo.
        echo Database: rfq_db
        echo User:     rfq_user
        echo Host:     localhost:5432
        echo.
    )
) else (
    echo   Database Setup Failed
    echo ========================================
    echo.
    echo Exit code: !EXIT_CODE!
    echo.
    echo Please review the error messages above.
    echo.
)

REM Pass EXIT_CODE out of setlocal block
endlocal & set "EXIT_CODE=%EXIT_CODE%"

pause
exit /b %EXIT_CODE%
