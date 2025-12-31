@echo off
setlocal EnableExtensions EnableDelayedExpansion

echo ========================================
echo   PostgreSQL Database Setup (Automatic)
echo ========================================
echo.

REM --------------------------------------------------
REM Validate .env
REM --------------------------------------------------
if not exist ".env" (
    echo ERROR: .env file not found
    echo Please copy env.template to .env and update values
    pause
    exit /b 1
)

REM --------------------------------------------------
REM Temp SQL files
REM --------------------------------------------------
set "TEMP_SQL_1=%TEMP%\rfq_db_%RANDOM%.sql"
set "TEMP_SQL_2=%TEMP%\rfq_user_%RANDOM%.sql"
set "TEMP_SQL_3=%TEMP%\rfq_perm_%RANDOM%.sql"

REM --------------------------------------------------
REM Load values from .env
REM --------------------------------------------------
for /f "tokens=1* delims==" %%A in ('findstr /B "SQL_SUPER_USER=" .env') do set "SQL_SUPER_USER=%%B"
for /f "tokens=1* delims==" %%A in ('findstr /B "RFQ_USER_PASSWORD=" .env') do set "RFQ_PASSWORD=%%B"

REM --------------------------------------------------
REM Credential retrieval function
REM --------------------------------------------------
call :GET_CREDENTIAL SQL_SUPER_USER RFQApplication_SQL_SUPER_USER
call :GET_CREDENTIAL RFQ_PASSWORD RFQApplication_RFQ_USER_PASSWORD

REM --------------------------------------------------
REM Final validation
REM --------------------------------------------------
if not defined SQL_SUPER_USER (
    echo ERROR: SQL_SUPER_USER not resolved
    pause
    exit /b 1
)

if not defined RFQ_PASSWORD (
    echo ERROR: RFQ_USER_PASSWORD not resolved
    pause
    exit /b 1
)

REM --------------------------------------------------
REM PostgreSQL client
REM --------------------------------------------------
where psql >nul 2>&1 || (
    echo ERROR: psql not found in PATH
    pause
    exit /b 1
)

REM --------------------------------------------------
REM Test connection
REM --------------------------------------------------
set "PGPASSWORD=%SQL_SUPER_USER%"

psql -U postgres -h localhost -p 5432 -c "SELECT 1" >nul 2>&1 || (
    echo ERROR: Cannot connect to PostgreSQL
    pause
    exit /b 1
)

echo [OK] Connected to PostgreSQL
echo.

REM --------------------------------------------------
REM Check database
REM --------------------------------------------------
psql -U postgres -lqt | findstr /C:"rfq_db" >nul
set DB_EXISTS=%ERRORLEVEL%

REM --------------------------------------------------
REM Check user
REM --------------------------------------------------
psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='rfq_user'" | findstr 1 >nul
set USER_EXISTS=%ERRORLEVEL%

REM --------------------------------------------------
REM Create DB
REM --------------------------------------------------
if %DB_EXISTS% NEQ 0 (
    echo CREATE DATABASE rfq_db; > "%TEMP_SQL_1%"
    psql -U postgres -f "%TEMP_SQL_1%" || goto :FAIL
)

REM --------------------------------------------------
REM Create or update user
REM --------------------------------------------------
powershell -NoProfile -Command ^
"[IO.File]::WriteAllText('%TEMP_SQL_2%', 'DO $$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname=''rfq_user'') THEN ALTER USER rfq_user WITH PASSWORD ''''$env:RFQ_PASSWORD''''; ELSE CREATE USER rfq_user WITH PASSWORD ''''$env:RFQ_PASSWORD''''; END IF; END $$;')"

psql -U postgres -f "%TEMP_SQL_2%" || goto :FAIL

REM --------------------------------------------------
REM Permissions
REM --------------------------------------------------
(
    echo GRANT ALL PRIVILEGES ON DATABASE rfq_db TO rfq_user;
) > "%TEMP_SQL_3%"

psql -U postgres -f "%TEMP_SQL_3%" || goto :FAIL

psql -U postgres -d rfq_db -c "ALTER SCHEMA public OWNER TO rfq_user;" >nul
psql -U postgres -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO rfq_user;" >nul
psql -U postgres -d rfq_db -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rfq_user;" >nul
psql -U postgres -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO rfq_user;" >nul
psql -U postgres -d rfq_db -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO rfq_user;" >nul

REM --------------------------------------------------
REM Cleanup
REM --------------------------------------------------
del "%TEMP_SQL_1%" "%TEMP_SQL_2%" "%TEMP_SQL_3%" >nul 2>&1

echo.
echo ========================================
echo   Database Setup Complete
echo ========================================
echo.
exit /b 0

REM ==================================================
REM Credential function
REM ==================================================
:GET_CREDENTIAL
set "VAR_NAME=%1"
set "CRED_NAME=%2"

call set VALUE=%%%VAR_NAME%%%

if "%VALUE%"=="__CREDENTIAL_MANAGER__" (
    where python >nul 2>&1 || goto :CRED_FAIL

    python -c "from windows.run_windows_wrapper import get_password_from_credential_manager; print(get_password_from_credential_manager('%CRED_NAME%') or '')" > "%TEMP%\cred.txt" 2>nul

    setlocal DisableDelayedExpansion
    for /f "usebackq delims=" %%P in ("%TEMP%\cred.txt") do set "VALUE=%%P"
    endlocal & set "%VAR_NAME%=%VALUE%"

    del "%TEMP%\cred.txt" >nul 2>&1
)

exit /b

:CRED_FAIL
echo ERROR: Failed to retrieve credential %CRED_NAME%
exit /b 1

:FAIL
echo ERROR: PostgreSQL setup failed
pause
exit /b 1
