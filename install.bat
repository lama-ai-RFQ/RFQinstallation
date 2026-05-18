@echo off
REM RFQ Application - Windows Installation Launcher
REM Simple wrapper to run the PowerShell installation script

REM Self-elevate to admin if not already running elevated
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$rfqEnvNames = @('RFQ_APP_SERVICE_NAME','RFQ_APP_SERVICE_DISPLAY_NAME','RFQ_APP_SERVICE_DESCRIPTION','RFQ_UPDATER_SERVICE_NAME','RFQ_UPDATER_SERVICE_DISPLAY_NAME','RFQ_UPDATER_SERVICE_DESCRIPTION','RFQ_INSTALL_DIR','RFQ_SHORTCUT_NAME','RFQ_REGISTRY_HANDOFF_KEY','RFQ_CREDMAN_SQL_SUPER_USER_TARGET','RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET','RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET'); foreach ($name in $rfqEnvNames) { $value = [Environment]::GetEnvironmentVariable($name, 'Process'); if ($null -ne $value) { Set-Item -Path ('env:' + $name) -Value $value } }; Start-Process '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

set "NONINTERACTIVE="
for %%A in (%*) do (
    if /I "%%~A"=="-NonInteractive" set "NONINTERACTIVE=1"
)

echo ================================================================================
echo     RFQ Application - Windows Installer
echo ================================================================================
echo.

REM Check if PowerShell is available
where powershell >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PowerShell is not installed or not in PATH
    echo Please install PowerShell 5.1 or later
    if not defined NONINTERACTIVE pause
    exit /b 1
)

REM Run the PowerShell script
echo Starting installation...
echo.

REM RFQ_* name override environment variables are intentionally inherited by PowerShell and validated there.
powershell.exe -ExecutionPolicy Bypass -File "%~dp0download_and_install.ps1" %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    if defined NONINTERACTIVE (
        echo Installation failed.
    ) else (
        echo Installation failed. Press any key to exit...
        pause >nul
    )
    exit /b %ERRORLEVEL%
)

echo.
if not defined NONINTERACTIVE (
    echo Press any key to exit...
    pause >nul
)
