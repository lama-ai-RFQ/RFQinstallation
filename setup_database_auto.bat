@echo off
echo ========================================
echo   PostgreSQL Database Setup (Automatic)
echo ========================================
echo.
echo This script will:
echo   - Check if database 'rfq_db' exists (create if not)
echo   - Check if user 'rfq_user' exists (create or update password)
echo   - Grant all necessary permissions
echo.
echo Credentials are read from .env file or Windows Credential Manager
echo.

REM Check if .env file exists
if not exist ".env" (
    echo ERROR: .env file not found
    echo Please copy env.template to .env and update the SQL_SUPER_USER value
    echo.
    echo Example:
    echo   copy env.template .env
    echo   edit .env
    echo.
    pause
    exit /b 1
)

REM Create temporary SQL script files to avoid command-line password issues
set "TEMP_SQL_1=%TEMP%\rfq_setup_1_%RANDOM%.sql"
set "TEMP_SQL_2=%TEMP%\rfq_setup_2_%RANDOM%.sql"
set "TEMP_SQL_3=%TEMP%\rfq_setup_3_%RANDOM%.sql"

REM Read SQL_SUPER_USER from .env file
for /f "tokens=1* delims==" %%a in ('findstr "SQL_SUPER_USER" .env') do set SQL_SUPER_USER=%%b

REM Check if SQL_SUPER_USER is a Credential Manager placeholder
if "%SQL_SUPER_USER%"=="__CREDENTIAL_MANAGER__" (
    echo Retrieving SQL_SUPER_USER from Windows Credential Manager...
    REM Use Python to retrieve password from Credential Manager
    REM Try to find Python in PATH
    set "SQL_SUPER_USER="
    where python >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        REM Python found in PATH, try to retrieve credential
        REM Try multiple path strategies to find the windows module
        for /f "delims=" %%p in ('python -c "import sys; import os; from pathlib import Path; cwd = Path(os.getcwd()); parent = cwd.parent if cwd.name == \"RFQinstallation\" else cwd; sys.path.insert(0, str(parent)); from windows.run_windows_wrapper import get_password_from_credential_manager; pwd = get_password_from_credential_manager(\"RFQApplication_SQL_SUPER_USER\"); print(pwd if pwd else \"\")"') do set SQL_SUPER_USER=%%p
    )
    
    REM If still empty, provide helpful error message
    if "%SQL_SUPER_USER%"=="" (
        echo ERROR: Could not retrieve SQL_SUPER_USER from Windows Credential Manager
        echo.
        echo The password is stored in Windows Credential Manager, but this batch script
        echo cannot retrieve it automatically. Please use one of these options:
        echo.
        echo Option 1: Temporarily set password in .env file
        echo   Edit .env and change: SQL_SUPER_USER=__CREDENTIAL_MANAGER__
        echo   To: SQL_SUPER_USER=your_actual_password
        echo   Run this script, then change it back to __CREDENTIAL_MANAGER__
        echo.
        echo Option 2: Use Python to retrieve and set PGPASSWORD
        echo   python -c "from windows.run_windows_wrapper import get_password_from_credential_manager; import os; pwd = get_password_from_credential_manager('RFQApplication_SQL_SUPER_USER'); os.environ['PGPASSWORD'] = pwd if pwd else ''"
        echo.
        echo To verify the credential exists:
        echo   cmdkey /list:RFQApplication_SQL_SUPER_USER
        echo.
        pause
        exit /b 1
    ) else (
        echo [OK] Retrieved SQL_SUPER_USER from Credential Manager
    )
)

REM Check if SQL_SUPER_USER was found
if "%SQL_SUPER_USER%"=="" (
    echo ERROR: SQL_SUPER_USER not found in .env file
    echo Please add SQL_SUPER_USER=your_sql_super_user_password to your .env file
    echo   OR set SQL_SUPER_USER=__CREDENTIAL_MANAGER__ to use Windows Credential Manager
    echo.
    pause
    exit /b 1
)

echo Using SQL super user password from .env file or Credential Manager...
echo.

REM Set PGPASSWORD for psql commands
set PGPASSWORD=%SQL_SUPER_USER%

REM Read RFQ_USER_PASSWORD from .env file
for /f "tokens=1* delims==" %%a in ('findstr "RFQ_USER_PASSWORD" .env') do set RFQ_PASSWORD=%%b

REM Check if RFQ_USER_PASSWORD is a Credential Manager placeholder
if "%RFQ_PASSWORD%"=="__CREDENTIAL_MANAGER__" (
    echo Retrieving RFQ_USER_PASSWORD from Windows Credential Manager...
    REM Use Python to retrieve password from Credential Manager
    REM Try to find Python in PATH
    set "RFQ_PASSWORD="
    where python >nul 2>&1
    if %ERRORLEVEL% EQU 0 (
        REM Python found in PATH, try to retrieve credential
        REM Try multiple path strategies to find the windows module
        for /f "delims=" %%p in ('python -c "import sys; import os; from pathlib import Path; cwd = Path(os.getcwd()); parent = cwd.parent if cwd.name == \"RFQinstallation\" else cwd; sys.path.insert(0, str(parent)); from windows.run_windows_wrapper import get_password_from_credential_manager; pwd = get_password_from_credential_manager(\"RFQApplication_RFQ_USER_PASSWORD\"); print(pwd if pwd else \"\")"') do set RFQ_PASSWORD=%%p
    )
    
    REM If still empty, provide helpful error message
    if "%RFQ_PASSWORD%"=="" (
        echo ERROR: Could not retrieve RFQ_USER_PASSWORD from Windows Credential Manager
        echo.
        echo The password is stored in Windows Credential Manager, but this batch script
        echo cannot retrieve it automatically. Please use one of these options:
        echo.
        echo Option 1: Temporarily set password in .env file
        echo   Edit .env and change: RFQ_USER_PASSWORD=__CREDENTIAL_MANAGER__
        echo   To: RFQ_USER_PASSWORD=your_actual_password
        echo   Run this script, then change it back to __CREDENTIAL_MANAGER__
        echo.
        echo Option 2: Use Python to retrieve and set environment variable
        echo   python -c "from windows.run_windows_wrapper import get_password_from_credential_manager; import os; pwd = get_password_from_credential_manager('RFQApplication_RFQ_USER_PASSWORD'); print(pwd if pwd else '')"
        echo.
        echo To verify the credential exists:
        echo   cmdkey /list:RFQApplication_RFQ_USER_PASSWORD
        echo.
        pause
        exit /b 1
    ) else (
        echo [OK] Retrieved RFQ_USER_PASSWORD from Credential Manager
    )
)

REM Check if RFQ_USER_PASSWORD was found
if "%RFQ_PASSWORD%"=="" (
    echo ERROR: RFQ_USER_PASSWORD not found in .env file
    echo Please add RFQ_USER_PASSWORD=your_database_password to your .env file
    echo   OR set RFQ_USER_PASSWORD=__CREDENTIAL_MANAGER__ to use Windows Credential Manager
    echo.
    pause
    exit /b 1
)

REM Check if psql command is available
where psql >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PostgreSQL 'psql' command not found
    echo.
    echo Please ensure PostgreSQL is installed and psql.exe is in your PATH
    echo.
    echo Common PostgreSQL installation paths:
    echo   C:\Program Files\PostgreSQL\16\bin
    echo   C:\Program Files\PostgreSQL\15\bin
    echo.
    echo You can add PostgreSQL to your PATH by:
    echo   1. Right-click 'This PC' ^> Properties ^> Advanced System Settings
    echo   2. Click 'Environment Variables'
    echo   3. Edit 'Path' under System Variables
    echo   4. Add PostgreSQL bin directory
    echo.
    pause
    exit /b 1
)

echo [STEP 2/6] Checking PostgreSQL client...
echo [OK] Found psql
echo.

echo [STEP 3/6] Testing PostgreSQL connection...
echo.

REM Test PostgreSQL connection
psql -U postgres -h localhost -p 5432 -c "SELECT version();" > nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Cannot connect to PostgreSQL server
    echo.
    echo Error details:
    psql -U postgres -h localhost -p 5432 -c "SELECT version();" 2>&1 | findstr /V "PostgreSQL"
    echo.
    echo Please check:
    echo   1. PostgreSQL service is running
    echo   2. SQL_SUPER_USER password in .env is correct (or Credential Manager has correct password)
    echo   3. PostgreSQL is listening on localhost:5432
    echo   4. User 'postgres' exists and has superuser privileges
    echo.
    echo To start PostgreSQL service:
    echo   - Windows Services: services.msc ^(look for 'postgresql-x64-XX'^)
    echo   - Command Line: net start postgresql-x64-16
    echo.
    pause
    exit /b 1
)

echo [OK] Connected to PostgreSQL
echo.

echo [STEP 4/6] Checking database and user...
echo.

REM Check if database exists
echo Checking if database 'rfq_db' exists...
psql -U postgres -h localhost -p 5432 -lqt | findstr /C:"rfq_db" > nul 2>&1
set "DB_EXISTS=%ERRORLEVEL%"

REM Check if user exists
echo Checking if user 'rfq_user' exists...
psql -U postgres -h localhost -p 5432 -tAc "SELECT 1 FROM pg_roles WHERE rolname='rfq_user'" | findstr "1" > nul 2>&1
set "USER_EXISTS=%ERRORLEVEL%"

echo.

echo [STEP 5/6] Creating database and user...
echo.

REM Handle existing database
if %DB_EXISTS% EQU 0 (
    echo [FOUND] Database 'rfq_db' already exists
) else (
    echo [CREATE] Creating database 'rfq_db'...
    echo CREATE DATABASE rfq_db; > "%TEMP_SQL_1%"
    psql -U postgres -h localhost -p 5432 -f "%TEMP_SQL_1%" 2>&1 | findstr /V "CREATE DATABASE"
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Failed to create database 'rfq_db'
        del "%TEMP_SQL_1%" 2>nul
        pause
        exit /b 1
    )
    echo [OK] Database 'rfq_db' created successfully
)

echo.

REM Handle existing user
if %USER_EXISTS% EQU 0 (
    echo [FOUND] User 'rfq_user' already exists
    echo [UPDATE] Updating password for user 'rfq_user'...
    REM Update password using PowerShell to avoid batch special char issues
    powershell -Command "[System.IO.File]::WriteAllText($env:TEMP_SQL_2, 'ALTER USER rfq_user WITH PASSWORD $$' + $env:RFQ_PASSWORD + '$$;')"
    psql -U postgres -h localhost -p 5432 -f "%TEMP_SQL_2%" > nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo [WARNING] Failed to update password for user 'rfq_user'
        echo           User exists but password update failed
    ) else (
        echo [OK] Password updated for user 'rfq_user'
    )
) else (
    echo [CREATE] Creating user 'rfq_user'...
    REM Create user with password using PowerShell to avoid batch special char issues
    powershell -Command "[System.IO.File]::WriteAllText($env:TEMP_SQL_2, 'CREATE USER rfq_user WITH PASSWORD $$' + $env:RFQ_PASSWORD + '$$;')"
    psql -U postgres -h localhost -p 5432 -f "%TEMP_SQL_2%" 2>&1 | findstr /V "CREATE ROLE"
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Failed to create user 'rfq_user'
        del "%TEMP_SQL_1%" 2>nul
        del "%TEMP_SQL_2%" 2>nul
        pause
        exit /b 1
    )
    echo [OK] User 'rfq_user' created successfully
)

echo.
echo [STEP 6/6] Setting up permissions...
echo.

REM Create SQL script for privilege grants
(
    echo GRANT ALL PRIVILEGES ON DATABASE rfq_db TO rfq_user;
) > "%TEMP_SQL_3%"

REM Grant privileges using script file
psql -U postgres -h localhost -p 5432 -f "%TEMP_SQL_3%" > nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Failed to grant database privileges
) else (
    echo [OK] Granted database privileges to 'rfq_user'
)

REM Connect to rfq_db and set up schema permissions
echo [GRANT] Setting up schema permissions...
psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER SCHEMA public OWNER TO rfq_user;" > nul 2>&1
psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT USAGE, CREATE ON SCHEMA public TO rfq_user;" > nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [WARNING] Failed to grant schema permissions
) else (
    echo [OK] Granted schema permissions to 'rfq_user'
)

REM Grant table and sequence permissions (safe to run even if no tables exist yet)
echo [GRANT] Setting up table and sequence permissions...
psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO rfq_user;" > nul 2>&1
psql -U postgres -h localhost -p 5432 -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rfq_user;" > nul 2>&1
psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO rfq_user;" > nul 2>&1
psql -U postgres -h localhost -p 5432 -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO rfq_user;" > nul 2>&1
echo [OK] Granted table and sequence permissions to 'rfq_user'

REM Clean up temporary files
del "%TEMP_SQL_1%" 2>nul
del "%TEMP_SQL_2%" 2>nul
del "%TEMP_SQL_3%" 2>nul

echo.
echo ========================================
echo   Database Setup Complete!
echo ========================================
echo.
echo Database: rfq_db
echo User: rfq_user
echo Host: localhost:5432
echo Password: (configured from .env file or Credential Manager)
echo.
echo Status:
if %DB_EXISTS% EQU 0 (
    echo   - Database: Already existed ^(reused^)
) else (
    echo   - Database: Created new
)
if %USER_EXISTS% EQU 0 (
    echo   - User: Already existed ^(password updated^)
) else (
    echo   - User: Created new
)
echo   - Permissions: Granted
echo.
echo You can now run the RFQ Application!
echo.

