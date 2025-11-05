@echo off
REM RFQ Application - Windows Installation Launcher
REM Simple wrapper to run the PowerShell installation script

echo ================================================================================
echo     RFQ Application - Windows Installer
echo ================================================================================
echo.

REM Check if PowerShell is available
where powershell >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: PowerShell is not installed or not in PATH
    echo Please install PowerShell 5.1 or later
    pause
    exit /b 1
)

REM Run the PowerShell script
echo Starting installation...
echo.

powershell.exe -ExecutionPolicy Bypass -File "%~dp0download_and_install.ps1" %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Installation failed. Press any key to exit...
    pause >nul
    exit /b %ERRORLEVEL%
)

echo.
echo Press any key to exit...
pause >nul

