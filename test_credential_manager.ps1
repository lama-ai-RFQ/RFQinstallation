# Test script for Windows Credential Manager
# This script tests saving and retrieving credentials to verify the integration works

param(
    [switch]$Cleanup  # If set, will delete test credentials after testing
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Windows Credential Manager Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Test credentials
$testTargets = @(
    @{
        TargetName = "RFQApplication:SQL_SUPER_USER"
        UserName = "postgres"
        Password = "TestPassword123!"
    },
    @{
        TargetName = "RFQApplication:RFQ_USER_PASSWORD"
        UserName = "rfq_user"
        Password = "TestPassword456@"
    },
    @{
        TargetName = "RFQApplication:SETTINGS_PASSWORD"
        UserName = "rfq_app"
        Password = "TestPassword789#"
    }
)

# Function to save credential (same as in download_and_install.ps1)
function Save-ToCredentialManager {
    param(
        [string]$TargetName,
        [string]$UserName,
        [string]$Password
    )
    
    try {
        # Check if credential already exists and delete it first
        $checkProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/list:$TargetName" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_check.txt" -RedirectStandardError "$env:TEMP\cmdkey_check_err.txt"
        
        if ($checkProcess.ExitCode -eq 0) {
            # Credential exists, delete it first
            Write-Host "  Credential $TargetName already exists, deleting first..." -ForegroundColor Yellow
            $deleteProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/delete:$TargetName" -Wait -PassThru -WindowStyle Hidden
            if ($deleteProcess.ExitCode -ne 0) {
                Write-Warning "  Warning: Could not delete existing credential $TargetName"
                return $false
            }
            Start-Sleep -Milliseconds 500
        }
        
        Remove-Item "$env:TEMP\cmdkey_check.txt" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\cmdkey_check_err.txt" -ErrorAction SilentlyContinue
        
        # Use cmdkey.exe to store credentials
        $escapedPassword = $Password -replace '"', '""'
        $arguments = @(
            "/add:$TargetName",
            "/user:$UserName",
            "/pass:$escapedPassword"
        )
        
        $process = Start-Process -FilePath "cmdkey.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardError "$env:TEMP\cmdkey_error.txt" -RedirectStandardOutput "$env:TEMP\cmdkey_output.txt"
        
        if ($process.ExitCode -eq 0) {
            Remove-Item "$env:TEMP\cmdkey_error.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\cmdkey_output.txt" -ErrorAction SilentlyContinue
            return $true
        } else {
            $errorOutput = ""
            if (Test-Path "$env:TEMP\cmdkey_error.txt") {
                $errorOutput = Get-Content "$env:TEMP\cmdkey_error.txt" -Raw -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\cmdkey_error.txt" -ErrorAction SilentlyContinue
            }
            if (Test-Path "$env:TEMP\cmdkey_output.txt") {
                Remove-Item "$env:TEMP\cmdkey_output.txt" -ErrorAction SilentlyContinue
            }
            Write-Warning "  Error: $errorOutput"
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
Write-Host "[1/4] Checking cmdkey.exe availability..." -ForegroundColor Cyan
$cmdkeyPath = Get-Command cmdkey -ErrorAction SilentlyContinue
if ($cmdkeyPath) {
    Write-Host "  [OK] cmdkey.exe found at: $($cmdkeyPath.Path)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] cmdkey.exe not found!" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test saving credentials
Write-Host "[2/4] Testing credential save operations..." -ForegroundColor Cyan
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

# Test listing credentials
Write-Host "[3/4] Testing credential listing..." -ForegroundColor Cyan
foreach ($test in $testTargets) {
    Write-Host "  Checking: $($test.TargetName)" -ForegroundColor Yellow
    $listProcess = Start-Process -FilePath "cmdkey.exe" -ArgumentList "/list:$($test.TargetName)" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\cmdkey_list.txt"
    
    if ($listProcess.ExitCode -eq 0) {
        $listOutput = Get-Content "$env:TEMP\cmdkey_list.txt" -Raw -ErrorAction SilentlyContinue
        if ($listOutput -and $listOutput -match $test.TargetName) {
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
Write-Host "[4/4] Testing credential retrieval..." -ForegroundColor Cyan
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
Write-Host "  4. Look for entries starting with 'RFQApplication:'" -ForegroundColor White
Write-Host ""
Write-Host "Or use command line:" -ForegroundColor Cyan
Write-Host "  cmdkey /list:RFQApplication:" -ForegroundColor White
Write-Host ""

