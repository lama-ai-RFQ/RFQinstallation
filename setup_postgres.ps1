# PostgreSQL Setup Script
# Requires Administrator privileges

Write-Host "=== PostgreSQL Service Setup ===" -ForegroundColor Cyan

# Check if PostgreSQL is installed
$pgBin = "C:\Program Files\PostgreSQL\16\bin"
$pgData = "C:\Program Files\PostgreSQL\16\data"

if (-not (Test-Path "$pgBin\psql.exe")) {
    Write-Host "ERROR: PostgreSQL 16 not found at $pgBin" -ForegroundColor Red
    exit 1
}

Write-Host "PostgreSQL binaries found at: $pgBin" -ForegroundColor Green

# Check data directory
if (-not (Test-Path $pgData)) {
    Write-Host "ERROR: Data directory not found at $pgData" -ForegroundColor Red
    exit 1
}

Write-Host "Data directory found at: $pgData" -ForegroundColor Green

# Check for existing service
$existingService = Get-Service -Name "postgresql*" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Existing PostgreSQL service found: $($existingService.Name) - Status: $($existingService.Status)" -ForegroundColor Yellow

    if ($existingService.Status -ne 'Running') {
        Write-Host "Starting existing service..." -ForegroundColor Yellow
        Start-Service -Name $existingService.Name -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $existingService = Get-Service -Name $existingService.Name
        Write-Host "Service status: $($existingService.Status)" -ForegroundColor Green
    }
} else {
    Write-Host "No existing PostgreSQL service found. Registering new service..." -ForegroundColor Yellow

    # Register the service
    $pgCtl = "$pgBin\pg_ctl.exe"
    $result = & $pgCtl register -D $pgData -N "postgresql-x64-16" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Service registered successfully" -ForegroundColor Green

        # Start the service
        Write-Host "Starting service..." -ForegroundColor Yellow
        Start-Service -Name "postgresql-x64-16" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        $svc = Get-Service -Name "postgresql-x64-16" -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "Service status: $($svc.Status)" -ForegroundColor Green
        }
    } else {
        Write-Host "Failed to register service: $result" -ForegroundColor Red
        Write-Host "You may need to run this script as Administrator" -ForegroundColor Yellow
    }
}

# Test connection
Write-Host "`n=== Testing PostgreSQL Connection ===" -ForegroundColor Cyan
$env:PGPASSWORD = "postgres"  # Default password, may need to change
& "$pgBin\psql.exe" -U postgres -h localhost -p 5432 -c "SELECT version();" 2>&1

Write-Host "`nDone!" -ForegroundColor Green
