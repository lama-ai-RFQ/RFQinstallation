# Test script for Windows Credential Manager
# This script tests saving and retrieving credentials to verify the integration works

param(
    [switch]$Cleanup,  # If set, will delete test credentials after testing
    [switch]$ListTargetsOnly
)

function Get-ResolvedEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) {
        return $DefaultValue
    }

    return $value
}

# Test credentials
$testTargets = @(
    @{
        EnvVarName = "RFQ_CREDMAN_SQL_SUPER_USER_TARGET"
        DefaultTargetName = "RFQApplication_SQL_SUPER_USER"
        TargetName = Get-ResolvedEnvValue -Name "RFQ_CREDMAN_SQL_SUPER_USER_TARGET" -DefaultValue "RFQApplication_SQL_SUPER_USER"
        UserName = "postgres"
        Password = "TestPassword123!"
    },
    @{
        EnvVarName = "RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET"
        DefaultTargetName = "RFQApplication_RFQ_USER_PASSWORD"
        TargetName = Get-ResolvedEnvValue -Name "RFQ_CREDMAN_RFQ_USER_PASSWORD_TARGET" -DefaultValue "RFQApplication_RFQ_USER_PASSWORD"
        UserName = "rfq_user"
        Password = "TestPassword456@"
    },
    @{
        EnvVarName = "RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET"
        DefaultTargetName = "RFQApplication_SETTINGS_PASSWORD"
        TargetName = Get-ResolvedEnvValue -Name "RFQ_CREDMAN_SETTINGS_PASSWORD_TARGET" -DefaultValue "RFQApplication_SETTINGS_PASSWORD"
        UserName = "rfq_app"
        Password = "TestPassword789#"
    }
)

if ($ListTargetsOnly) {
    foreach ($test in $testTargets) {
        Write-Output "$($test.EnvVarName)=$($test.TargetName)"
    }
    exit 0
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Windows Credential Manager Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Credential targets under test:" -ForegroundColor Cyan
foreach ($test in $testTargets) {
    $envValue = [Environment]::GetEnvironmentVariable($test.EnvVarName)
    if ([string]::IsNullOrEmpty($envValue)) {
        Write-Host "  $($test.EnvVarName): <unset> -> $($test.TargetName)" -ForegroundColor Gray
    } else {
        Write-Host "  $($test.EnvVarName): $($test.TargetName)" -ForegroundColor Gray
    }
}
Write-Host ""

# Function to list all credentials (for debugging)
function Show-AllCredentials {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$TargetNames
    )

    $escapedTargets = $TargetNames | ForEach-Object { [regex]::Escape($_) }
    $targetPattern = $escapedTargets -join "|"

    Write-Host "  Listing configured RFQ credential targets:" -ForegroundColor Cyan
    $listAllProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/list" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_list_all.txt" -RedirectStandardError "$env:TEMP\cmdkey_list_all_err.txt"
    
    if (Test-Path "$env:TEMP\cmdkey_list_all.txt") {
        $allCreds = Get-Content "$env:TEMP\cmdkey_list_all.txt" -Raw
        if ($allCreds -and $allCreds.Trim() -ne "" -and $allCreds -match $targetPattern) {
            Write-Host "    Found credentials:" -ForegroundColor Yellow
            $allCreds -split "`n" | Where-Object { $_ -match $targetPattern } | ForEach-Object {
                Write-Host "      $_" -ForegroundColor Gray
            }
        } else {
            Write-Host "    No configured RFQ credential targets found in list" -ForegroundColor Yellow
            if ($allCreds) {
                Write-Host "    (Output was: $($allCreds.Substring(0, [Math]::Min(100, $allCreds.Length))))" -ForegroundColor Gray
            }
        }
        Remove-Item "$env:TEMP\cmdkey_list_all.txt" -ErrorAction SilentlyContinue
    }
    if (Test-Path "$env:TEMP\cmdkey_list_all_err.txt") {
        $errOutput = Get-Content "$env:TEMP\cmdkey_list_all_err.txt" -Raw
        if ($errOutput -and $errOutput.Trim() -ne "") {
            Write-Host "    Error output: $errOutput" -ForegroundColor Red
        }
        Remove-Item "$env:TEMP\cmdkey_list_all_err.txt" -ErrorAction SilentlyContinue
    }
}

# Function to delete credential (with better error handling)
function Remove-Credential {
    param([string]$TargetName)
    
    Write-Host "    Attempting to delete: $TargetName" -ForegroundColor Yellow
    
    # Try deletion
    $deleteProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/delete:$TargetName" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_delete_out.txt" -RedirectStandardError "$env:TEMP\cmdkey_delete_err.txt"
    
    if ($deleteProcess.ExitCode -eq 0) {
        Write-Host "      [OK] Deleted successfully" -ForegroundColor Green
        Remove-Item "$env:TEMP\cmdkey_delete_out.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\cmdkey_delete_err.txt" -ErrorAction SilentlyContinue
        return $true
    } else {
        $errorOut = ""
        if (Test-Path "$env:TEMP\cmdkey_delete_err.txt") {
            $errorOut = Get-Content "$env:TEMP\cmdkey_delete_err.txt" -Raw -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\cmdkey_delete_err.txt" -ErrorAction SilentlyContinue
        }
        if (Test-Path "$env:TEMP\cmdkey_delete_out.txt") {
            $stdOut = Get-Content "$env:TEMP\cmdkey_delete_out.txt" -Raw -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\cmdkey_delete_out.txt" -ErrorAction SilentlyContinue
            if ($stdOut) {
                Write-Host "      Output: $stdOut" -ForegroundColor Gray
            }
        }
        if ($errorOut) {
            Write-Host "      Error: $errorOut" -ForegroundColor Red
        }
        Write-Host "      [WARN] Delete returned exit code: $($deleteProcess.ExitCode)" -ForegroundColor Yellow
        Write-Host "      This might mean the credential doesn't exist or is in a different store" -ForegroundColor Yellow
        return $false
    }
}

# Function to save credential (same as in download_and_install.ps1)
function Save-ToCredentialManager {
    param(
        [string]$TargetName,
        [string]$UserName,
        [string]$Password
    )
    
    try {
        # Check if credential already exists by looking at the actual output
        Write-Host "    Checking if credential exists..." -ForegroundColor Gray
        $checkProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/list:$TargetName" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_check.txt" -RedirectStandardError "$env:TEMP\cmdkey_check_err.txt"
        
        $credentialExists = $false
        if (Test-Path "$env:TEMP\cmdkey_check.txt") {
            $checkOutput = Get-Content "$env:TEMP\cmdkey_check.txt" -Raw
            # Check if output actually contains the target name (not just empty or error message)
            if ($checkOutput -and $checkOutput.Trim() -ne "" -and $checkOutput -match [regex]::Escape($TargetName)) {
                $credentialExists = $true
                Write-Host "    Credential exists, attempting to delete..." -ForegroundColor Yellow
                $deleted = Remove-Credential -TargetName $TargetName
                if (-not $deleted) {
                    Write-Host "    [WARN] Could not delete existing credential, but will try to overwrite..." -ForegroundColor Yellow
                    Write-Host "    Note: cmdkey.exe may allow overwriting without explicit deletion" -ForegroundColor Gray
                }
                Start-Sleep -Milliseconds 500
            } else {
                Write-Host "    Credential does not exist (or not found in output)" -ForegroundColor Gray
            }
        }
        
        Remove-Item "$env:TEMP\cmdkey_check.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\cmdkey_check_err.txt" -ErrorAction SilentlyContinue
        
        # Use cmdkey.exe to store credentials
        # Simple direct call works best - no need for complex escaping
        Write-Host "    Attempting to save credential..." -ForegroundColor Gray
        
        # Call cmdkey.exe directly (simplest approach that works, like the user's example)
        $output = & cmdkey.exe /add:$TargetName /user:$UserName /pass:$Password 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            return $true
        } else {
            # Show any error output
            if ($output) {
                $errorMsg = $output | Out-String
                if ($errorMsg -and $errorMsg.Trim() -ne "") {
                    Write-Host "      Error output: $errorMsg" -ForegroundColor Red
                }
            }
            Write-Host "      Exit code: $exitCode" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Warning "  Exception: $_"
        return $false
    }
}

# Function to retrieve credential using Windows API
function Get-FromCredentialManager {
    param(
        [string]$TargetName
    )
    
    try {
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class CredentialManager {
            [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
            public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);
            
            [DllImport("advapi32.dll", EntryPoint = "CredFree")]
            public static extern void CredFree(IntPtr buffer);
            
            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
            public struct NativeCredential {
                public int Flags;
                public int Type;
                public IntPtr TargetName;
                public IntPtr Comment;
                public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
                public int CredentialBlobSize;
                public IntPtr CredentialBlob;
                public int Persist;
                public int AttributeCount;
                public IntPtr Attributes;
                public IntPtr TargetAlias;
                public IntPtr UserName;
            }
        }
"@ -ErrorAction Stop
        
        $credPtr = [IntPtr]::Zero
        if ([CredentialManager]::CredRead($TargetName, 1, 0, [ref]$credPtr)) {
            $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [type][CredentialManager+NativeCredential])
            $passwordPtr = $cred.CredentialBlob
            $passwordSize = $cred.CredentialBlobSize
            $passwordBytes = New-Object byte[] $passwordSize
            [System.Runtime.InteropServices.Marshal]::Copy($passwordPtr, $passwordBytes, 0, $passwordSize)
            $password = [System.Text.Encoding]::Unicode.GetString($passwordBytes).TrimEnd([char]0)
            [CredentialManager]::CredFree($credPtr)
            return $password
        }
        return $null
    }
    catch {
        Write-Warning "  Exception retrieving credential: $_"
        return $null
    }
}

# Test cmdkey.exe availability
Write-Host "[1/5] Checking cmdkey.exe availability..." -ForegroundColor Cyan
$cmdkeyPath = Get-Command cmdkey -ErrorAction SilentlyContinue
if ($cmdkeyPath) {
    Write-Host "  [OK] cmdkey.exe found at: $($cmdkeyPath.Path)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] cmdkey.exe not found!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Show existing credentials first
Write-Host "[2/5] Checking for existing credentials..." -ForegroundColor Cyan
Show-AllCredentials -TargetNames ($testTargets | ForEach-Object { $_.TargetName })
Write-Host ""

# Test saving credentials
Write-Host "[3/5] Testing credential save operations..." -ForegroundColor Cyan
$saveResults = @{}
foreach ($test in $testTargets) {
    Write-Host "  Testing: $($test.TargetName)" -ForegroundColor Yellow
    if (Save-ToCredentialManager -TargetName $test.TargetName -UserName $test.UserName -Password $test.Password) {
        Write-Host "    [OK] Credential saved successfully" -ForegroundColor Green
        $saveResults[$test.TargetName] = $true
    } else {
        Write-Host "    [FAIL] Failed to save credential" -ForegroundColor Red
        $saveResults[$test.TargetName] = $false
    }
}
Write-Host ""

# Show credentials after saving
Write-Host "  Verifying credentials were saved..." -ForegroundColor Cyan
Show-AllCredentials -TargetNames ($testTargets | ForEach-Object { $_.TargetName })
Write-Host ""

# Test listing credentials
Write-Host "[4/5] Testing credential listing..." -ForegroundColor Cyan
foreach ($test in $testTargets) {
    Write-Host "  Checking: $($test.TargetName)" -ForegroundColor Yellow
    $listProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/list:$($test.TargetName)" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_list.txt"
    
    if ($listProcess.ExitCode -eq 0) {
        $listOutput = Get-Content "$env:TEMP\cmdkey_list.txt" -Raw -ErrorAction SilentlyContinue
        if ($listOutput -and $listOutput -match [regex]::Escape($test.TargetName)) {
            Write-Host "    [OK] Credential found in list" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] Credential not found in list output" -ForegroundColor Yellow
        }
        Remove-Item "$env:TEMP\cmdkey_list.txt" -ErrorAction SilentlyContinue
    } else {
        Write-Host "    [FAIL] Failed to list credential" -ForegroundColor Red
    }
}
Write-Host ""

# Test retrieving credentials
Write-Host "[5/5] Testing credential retrieval..." -ForegroundColor Cyan
$retrieveResults = @{}
foreach ($test in $testTargets) {
    Write-Host "  Testing: $($test.TargetName)" -ForegroundColor Yellow
    $retrievedPassword = Get-FromCredentialManager -TargetName $test.TargetName
    
    if ($retrievedPassword) {
        if ($retrievedPassword -eq $test.Password) {
            Write-Host "    [OK] Password retrieved and matches!" -ForegroundColor Green
            Write-Host "      Original: $($test.Password)" -ForegroundColor Gray
            Write-Host "      Retrieved: $retrievedPassword" -ForegroundColor Gray
            $retrieveResults[$test.TargetName] = $true
        } else {
            Write-Host "    [FAIL] Password retrieved but doesn't match!" -ForegroundColor Red
            Write-Host "      Original: $($test.Password)" -ForegroundColor Gray
            Write-Host "      Retrieved: $retrievedPassword" -ForegroundColor Gray
            $retrieveResults[$test.TargetName] = $false
        }
    } else {
        Write-Host "    [FAIL] Could not retrieve password" -ForegroundColor Red
        $retrieveResults[$test.TargetName] = $false
    }
}
Write-Host ""

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$allPassed = $true
foreach ($test in $testTargets) {
    $saveOk = $saveResults[$test.TargetName]
    $retrieveOk = $retrieveResults[$test.TargetName]
    
    if ($saveOk -and $retrieveOk) {
        Write-Host "  $($test.TargetName): [PASS]" -ForegroundColor Green
    } else {
        Write-Host "  $($test.TargetName): [FAIL]" -ForegroundColor Red
        if (-not $saveOk) {
            Write-Host "    - Save operation failed" -ForegroundColor Red
        }
        if (-not $retrieveOk) {
            Write-Host "    - Retrieve operation failed" -ForegroundColor Red
        }
        $allPassed = $false
    }
}
Write-Host ""

if ($allPassed) {
    Write-Host "All tests PASSED!" -ForegroundColor Green
} else {
    Write-Host "Some tests FAILED!" -ForegroundColor Red
}

# Cleanup if requested
if ($Cleanup) {
    Write-Host ""
    Write-Host "Cleaning up test credentials..." -ForegroundColor Yellow
    foreach ($test in $testTargets) {
        $deleteProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/delete:$($test.TargetName)" -Wait -PassThru -WindowStyle Hidden
        if ($deleteProcess.ExitCode -eq 0) {
            Write-Host "  [OK] Deleted: $($test.TargetName)" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not delete: $($test.TargetName)" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Test completed!" -ForegroundColor Cyan
Write-Host ""
Write-Host "To view credentials manually:" -ForegroundColor Cyan
Write-Host "  1. Open Control Panel" -ForegroundColor White
Write-Host "  2. Go to Credential Manager" -ForegroundColor White
Write-Host "  3. Click 'Windows Credentials'" -ForegroundColor White
Write-Host "  4. Look for entries named:" -ForegroundColor White
foreach ($test in $testTargets) {
    Write-Host "     - $($test.TargetName)" -ForegroundColor White
}
Write-Host ""
Write-Host "Or use command line:" -ForegroundColor Cyan
foreach ($test in $testTargets) {
    Write-Host "  cmdkey /list:$($test.TargetName)" -ForegroundColor White
}
Write-Host ""
