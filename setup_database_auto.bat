@echo off
setlocal enabledelayedexpansion
echo ========================================
echo   PostgreSQL Database Setup (Automatic)
echo ========================================
echo.
echo This script will:
echo   - Check if database 'rfq_db' exists (create if not)
echo   - Check if user 'rfq_user' exists (create or update password)
echo   - Grant all necessary permissions
echo.
echo Credentials are read from installer environment variables or .env file
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

REM Check if password was passed from installer via environment variable (base64 encoded)
if defined SQL_SUPER_USER_B64 (
    REM Decode from base64 (passed from installer)
    for /f "delims=" %%p in ('powershell -Command "[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('%SQL_SUPER_USER_B64%'))"') do set SQL_SUPER_USER=%%p
    echo Using SQL_SUPER_USER from installer (environment variable)
) else (
    REM Read SQL_SUPER_USER from .env file
    for /f "tokens=1* delims==" %%a in ('findstr "SQL_SUPER_USER" .env') do set SQL_SUPER_USER=%%b
    REM If .env has __CREDENTIAL_MANAGER__ placeholder, show error
    if "!SQL_SUPER_USER!"=="__CREDENTIAL_MANAGER__" (
        echo ERROR: SQL_SUPER_USER is set to __CREDENTIAL_MANAGER__ in .env file
        echo.
        echo This script cannot retrieve passwords from Windows Credential Manager.
        echo Please edit .env and set SQL_SUPER_USER to the actual password.
        echo.
        pause
        exit /b 1
    )
)

REM Check if SQL_SUPER_USER was found
if "!SQL_SUPER_USER!"=="" (
    echo ERROR: SQL_SUPER_USER not found in .env file
    echo Please add SQL_SUPER_USER=your_sql_super_user_password to your .env file
    echo.
    pause
    exit /b 1
)

echo Using SQL super user password from installer or .env file...
echo.

REM Set PGPASSWORD for psql commands
set PGPASSWORD=!SQL_SUPER_USER!

REM Check if password was passed from installer via environment variable (base64 encoded)
if defined RFQ_USER_B64 (
    REM Decode from base64 (passed from installer)
    for /f "delims=" %%p in ('powershell -Command "[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('%RFQ_USER_B64%'))"') do set RFQ_PASSWORD=%%p
    echo Using RFQ_USER_PASSWORD from installer (environment variable)
) else (
    REM Read RFQ_USER_PASSWORD from .env file
    for /f "tokens=1* delims==" %%a in ('findstr "RFQ_USER_PASSWORD" .env') do set RFQ_PASSWORD=%%b
    REM If .env has __CREDENTIAL_MANAGER__ placeholder, show error
    if "!RFQ_PASSWORD!"=="__CREDENTIAL_MANAGER__" (
        echo ERROR: RFQ_USER_PASSWORD is set to __CREDENTIAL_MANAGER__ in .env file
        echo.
        echo This script cannot retrieve passwords from Windows Credential Manager.
        echo Please edit .env and set RFQ_USER_PASSWORD to the actual password.
        echo.
        pause
        exit /b 1
    )
)

REM Check if RFQ_USER_PASSWORD was found
if "!RFQ_PASSWORD!"=="" (
    echo ERROR: RFQ_USER_PASSWORD not found in .env file
    echo Please add RFQ_USER_PASSWORD=your_database_password to your .env file
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
    echo   2. SQL_SUPER_USER password in .env is correct
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
echo Password: (configured from installer or .env file)
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

