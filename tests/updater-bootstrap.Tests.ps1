Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BootstrapScript = Join-Path $script:RepoRoot 'bootstrap-updater.ps1'
    $script:BootstrapIss = Join-Path $script:RepoRoot 'updater-bootstrap.iss'
    $script:SetupIss = Join-Path $script:RepoRoot 'setup.iss'
    $script:InstallerScript = Join-Path $script:RepoRoot 'download_and_install.ps1'

    $script:BootstrapText = Get-Content -Path $script:BootstrapScript -Raw
    $script:BootstrapIssText = Get-Content -Path $script:BootstrapIss -Raw
    $script:SetupIssText = Get-Content -Path $script:SetupIss -Raw
    $script:InstallerText = Get-Content -Path $script:InstallerScript -Raw

    # Dot-source named functions out of a script without executing its top-level
    # body (same approach as rfq-full-name-env-vars.Tests.ps1).
    function Import-ScriptFunctions {
        param(
            [Parameter(Mandatory)][string] $ScriptPath,
            [Parameter(Mandatory)][string[]] $Names
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptPath, [ref] $tokens, [ref] $parseErrors)

        if ($parseErrors.Count -gt 0) {
            throw "Unable to parse $ScriptPath`: $($parseErrors[0].Message)"
        }

        $functionAsts = @(
            $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        )

        foreach ($name in $Names) {
            $matches = @($functionAsts | Where-Object { $_.Name -eq $name })
            if ($matches.Count -ne 1) {
                throw "Expected exactly one function '$name' in $ScriptPath, found $($matches.Count)."
            }
            # Define into the global scope so Pester's per-It child scopes see it.
            $definition = [regex]::Replace(
                $matches[0].Extent.Text,
                '^\s*function\s+([A-Za-z0-9_-]+)',
                "function global:$name",
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            . ([scriptblock]::Create($definition))
        }
    }

    # Pure helpers + the backup/restore pair (the latter only log, which we stub).
    function global:Write-Log { param($Message, $Level = 'INFO') }
    Import-ScriptFunctions -ScriptPath $script:BootstrapScript -Names @(
        'Get-RfqEnvValueOrDefault',
        'Get-FirstExeFromCommandLine',
        'Test-SameFile',
        'Get-SidecarFiles',
        'Backup-CurrentUpdater',
        'Restore-FromBackups'
    )
}

Describe 'bootstrap-updater.ps1 parses' {
    It 'has no parse errors' {
        $errors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:BootstrapScript, [ref] $tokens, [ref] $errors) | Out-Null
        $errors.Count | Should -Be 0
    }
}

Describe 'bootstrap-updater.ps1 helper behavior' {
    It 'Get-RfqEnvValueOrDefault returns default when env unset' {
        [Environment]::SetEnvironmentVariable('RFQ_TEST_TMP_VAR', $null, 'Process')
        Get-RfqEnvValueOrDefault -EnvName 'RFQ_TEST_TMP_VAR' -DefaultValue 'RFQUpdaterService' |
            Should -Be 'RFQUpdaterService'
    }

    It 'Get-RfqEnvValueOrDefault honors a set env var' {
        [Environment]::SetEnvironmentVariable('RFQ_TEST_TMP_VAR', 'CustomUpdater', 'Process')
        try {
            Get-RfqEnvValueOrDefault -EnvName 'RFQ_TEST_TMP_VAR' -DefaultValue 'RFQUpdaterService' |
                Should -Be 'CustomUpdater'
        }
        finally {
            [Environment]::SetEnvironmentVariable('RFQ_TEST_TMP_VAR', $null, 'Process')
        }
    }

    It 'Get-FirstExeFromCommandLine unwraps a quoted nssm path with args' {
        Get-FirstExeFromCommandLine -CommandLine '"C:\Program Files\nssm\nssm.exe" --service' |
            Should -Be 'C:\Program Files\nssm\nssm.exe'
    }

    It 'Get-FirstExeFromCommandLine handles an unquoted path' {
        Get-FirstExeFromCommandLine -CommandLine 'C:\app\windows_updater.exe --service' |
            Should -Be 'C:\app\windows_updater.exe'
    }

    It 'Test-SameFile is true for identical content and false otherwise' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $a = Join-Path $dir 'a.bin'
            $b = Join-Path $dir 'b.bin'
            $c = Join-Path $dir 'c.bin'
            Set-Content -Path $a -Value 'same' -NoNewline
            Set-Content -Path $b -Value 'same' -NoNewline
            Set-Content -Path $c -Value 'different' -NoNewline
            Test-SameFile -PathA $a -PathB $b | Should -BeTrue
            Test-SameFile -PathA $a -PathB $c | Should -BeFalse
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force
        }
    }

    It 'Get-SidecarFiles excludes the exe itself and prior .previous backups' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            Set-Content -Path (Join-Path $dir 'windows_updater.exe') -Value 'exe' -NoNewline
            Set-Content -Path (Join-Path $dir 'windows_updater.exe.config') -Value 'cfg' -NoNewline
            Set-Content -Path (Join-Path $dir 'windows_updater.pdb') -Value 'pdb' -NoNewline
            Set-Content -Path (Join-Path $dir 'windows_updater.exe.previous') -Value 'old' -NoNewline

            $sidecars = @(Get-SidecarFiles -InstallDir $dir | ForEach-Object { $_.Name } | Sort-Object)
            $sidecars | Should -Be @('windows_updater.exe.config', 'windows_updater.pdb')
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force
        }
    }

    It 'Backup-CurrentUpdater then Restore-FromBackups round-trips the binary and sidecars' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $exe = Join-Path $dir 'windows_updater.exe'
            $cfg = Join-Path $dir 'windows_updater.exe.config'
            Set-Content -Path $exe -Value 'ORIGINAL_EXE' -NoNewline
            Set-Content -Path $cfg -Value 'ORIGINAL_CFG' -NoNewline

            $backups = Backup-CurrentUpdater -UpdaterExePath $exe -InstallDir $dir

            # .previous copies exist and match originals.
            Test-Path "$exe.previous" | Should -BeTrue
            Test-Path "$cfg.previous" | Should -BeTrue

            # Simulate a swap that we then need to roll back.
            Set-Content -Path $exe -Value 'NEW_BUT_BROKEN' -NoNewline
            Set-Content -Path $cfg -Value 'NEW_CFG' -NoNewline

            Restore-FromBackups -Backups $backups | Should -BeTrue

            (Get-Content -Path $exe -Raw) | Should -Be 'ORIGINAL_EXE'
            (Get-Content -Path $cfg -Raw) | Should -Be 'ORIGINAL_CFG'
        }
        finally {
            Remove-Item -Path $dir -Recurse -Force
        }
    }
}

Describe 'bootstrap-updater.ps1 rollback-safety contract (content)' {
    It 'stops the service before copying the new binary' {
        $stopIdx = $script:BootstrapText.IndexOf('Stop-UpdaterService -ServiceName $script:ResolvedServiceName')
        $copyIdx = $script:BootstrapText.IndexOf('Copy-Item -Path $script:ResolvedNewExe -Destination $targetExe')
        $stopIdx | Should -BeGreaterThan 0
        $copyIdx | Should -BeGreaterThan 0
        $stopIdx | Should -BeLessThan $copyIdx
    }

    It 'backs up the current binary to .previous' {
        $script:BootstrapText | Should -Match '\$UpdaterExePath\.previous'
        $script:BootstrapText | Should -Match 'function Backup-CurrentUpdater'
    }

    It 'restores from backups when the new binary fails to reach RUNNING' {
        $script:BootstrapText | Should -Match 'did not reach RUNNING\. Rolling back'
        $script:BootstrapText | Should -Match 'Restore-FromBackups -Backups \$backups'
    }

    It 'verifies the service reaches RUNNING after the swap (bounded wait)' {
        $script:BootstrapText | Should -Match "Wait-ForServiceState .* -DesiredState 'Running' -TimeoutSeconds \`$StartTimeoutSeconds"
        $script:BootstrapText | Should -Match "Wait-ForServiceState .* -DesiredState 'Stopped' -TimeoutSeconds \`$StopTimeoutSeconds"
    }

    It 'is idempotent: skips the swap when the installed binary already matches' {
        $script:BootstrapText | Should -Match 'Test-SameFile -PathA \$targetExe -PathB \$script:ResolvedNewExe'
        $script:BootstrapText | Should -Match 'already matches the bundled build'
    }

    It 'uses env-var-direct identity for the updater service name' {
        $script:BootstrapText | Should -Match "Get-RfqEnvValueOrDefault -EnvName ""RFQ_UPDATER_SERVICE_NAME"" -DefaultValue ""RFQUpdaterService"""
    }

    It 'discovers the install dir via RFQ_INSTALL_DIR before falling back' {
        $script:BootstrapText | Should -Match 'RFQ_INSTALL_DIR'
        $script:BootstrapText | Should -Match 'LOCALAPPDATA'
    }
}

Describe 'updater-bootstrap.iss mini-installer (content)' {
    It 'bundles the new updater and the bootstrap script' {
        $script:BootstrapIssText | Should -Match 'Source: "windows_updater\.exe"; DestDir: "\{tmp\}"'
        $script:BootstrapIssText | Should -Match 'Source: "bootstrap-updater\.ps1"; DestDir: "\{tmp\}"'
    }

    It 'runs the bootstrap swap at ssPostInstall' {
        $script:BootstrapIssText | Should -Match 'CurStep = ssPostInstall'
        $script:BootstrapIssText | Should -Match 'RunBootstrapSwap'
        $script:BootstrapIssText | Should -Match 'bootstrap-updater\.ps1'
    }

    It 'is a one-shot tool (no app dir, not uninstallable)' {
        $script:BootstrapIssText | Should -Match 'CreateAppDir=no'
        $script:BootstrapIssText | Should -Match 'Uninstallable=no'
    }

    It 'requires admin and uses a distinct AppId from the full installer' {
        $script:BootstrapIssText | Should -Match 'PrivilegesRequired=admin'
        $script:BootstrapIssText | Should -Match 'RFQ_UPDATER_BOOTSTRAP_APP_ID'
        # Distinct from setup.iss default AppId.
        $script:BootstrapIssText | Should -Not -Match 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890'
    }

    It 'reports success and failure to the IT admin' {
        $script:BootstrapIssText | Should -Match 'mbInformation'
        $script:BootstrapIssText | Should -Match 'mbError'
    }
}

Describe 'setup.iss new-install updater prerequisites (content)' {
    It 'bundles windows_updater.exe into {app}' {
        $script:SetupIssText | Should -Match 'Source: "windows_updater\.exe"; DestDir: "\{app\}"'
    }

    It 'creates the {app}\updates staging directory' {
        $script:SetupIssText | Should -Match '\[Dirs\]'
        $script:SetupIssText | Should -Match 'Name: "\{app\}\\updates"'
    }

    It 'references the build dependency note' {
        $script:SetupIssText | Should -Match 'UPDATER_BUILD\.md'
    }
}

Describe 'download_and_install.ps1 creates the updater staging dir (content)' {
    It 'creates {InstallPath}\updates near updater service creation' {
        $script:InstallerText | Should -Match '\$updatesDir = Join-Path \$InstallPath "updates"'
        $script:InstallerText | Should -Match 'New-Item -ItemType Directory -Path \$updatesDir'
    }
}
