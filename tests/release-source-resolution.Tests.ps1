Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:InstallerScript = Join-Path $script:RepoRoot 'download_and_install.ps1'
$script:RcaHarnessPath = Join-Path $PSScriptRoot 'release-source-resolution.repro.sh'
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallerScript = Join-Path $script:RepoRoot 'download_and_install.ps1'
    $script:RcaHarnessPath = Join-Path $PSScriptRoot 'release-source-resolution.repro.sh'

function Import-ReleaseSourceContractHelpers {
    param(
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:InstallerScript,
        [ref] $tokens,
        [ref] $parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Unable to parse $script:InstallerScript`: $($parseErrors[0].Message)"
    }

    $functionAsts = @(
        $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    )

    foreach ($name in $Names) {
        $acceptedNames = @($name, "script:$name", "global:$name", "local:$name", "private:$name")
        $matches = @($functionAsts | Where-Object { $acceptedNames -contains $_.Name })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one function definition for '$name' in $script:InstallerScript, found $($matches.Count)."
        }

        $definition = [regex]::Replace(
            $matches[0].Extent.Text,
            '^\s*function\s+(?:(?:script|global|local|private):)?([A-Za-z0-9_-]+)',
            "function global:$name",
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        . ([scriptblock]::Create($definition))
    }
}

function New-TestS3Candidate {
    param([Parameter(Mandatory)][string] $Version)

    [pscustomobject]@{
        Source  = 's3'
        Version = $Version
        Release = [pscustomobject]@{
            tag_name = $Version
            assets   = @(
                [pscustomobject]@{
                    name                 = 'RFQ_Application.zip'
                    url                  = "s3://rfq-release-fixtures/$Version/RFQ_Application.zip"
                    size                 = 42
                    browser_download_url = "https://s3.example.invalid/$Version/RFQ_Application.zip"
                    source               = 's3'
                }
            )
        }
        Payload = [pscustomobject]@{
            version = $Version
            assets  = @()
        }
    }
}

function New-TestGithubCandidate {
    param([Parameter(Mandatory)][string] $Version)

    $release = [pscustomobject]@{
        tag_name = $Version
        assets   = @(
            [pscustomobject]@{
                name                 = 'RFQ_Application.zip'
                browser_download_url = "https://github.example.invalid/$Version/RFQ_Application.zip"
                size                 = 84
            }
        )
    }

    [pscustomobject]@{
        Source  = 'github'
        Version = $Version
        Release = $release
        Payload = $release
    }
}

function Assert-SelectedRelease {
    param(
        [Parameter(Mandatory)] $Selected,
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $Reason
    )

    $Selected.Source | Should -Be $Source
    $Selected.Version | Should -Be $Version
    $Selected.Reason | Should -Be $Reason
}

function Get-InstallerScriptText {
    Get-Content -LiteralPath $script:InstallerScript -Raw
}
}

# Risk: Stale S3 currently wins without comparison
# Level: unit
# Source: contract §6 T1; proposal §7 T1; A1, A2
Describe 'Resolve-ReleaseSource freshness selection' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Stale S3 currently wins without comparison
    # Level: unit
    # Source: contract §6 T1; proposal §7 T1; A1, A2
    Context 'stale S3 vs newer GitHub' {
        It 'selects GitHub when GitHub tag is newer than S3 tag' {
            $s3Candidate = New-TestS3Candidate -Version 'windows-v3.4.804-internal'
            $githubCandidate = New-TestGithubCandidate -Version 'windows-v3.5.770-internal'

            $compare = Compare-RfqVersion $s3Candidate.Version $githubCandidate.Version 'internal'
            $selected = Resolve-ReleaseSource $s3Candidate $githubCandidate 'internal'

            Assert-SelectedRelease $selected 'github' 'windows-v3.5.770-internal' 'github_newer'
            $compare.Result | Should -Be -1
        }
    }
}

# Risk: Equal versions could accidentally flip source
# Level: unit
# Source: contract §6 T2; proposal §7 T2; A1, A2
Describe 'Resolve-ReleaseSource tie policy' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Equal versions could accidentally flip source
    # Level: unit
    # Source: contract §6 T2; proposal §7 T2; A1, A2
    Context 'matching S3 and GitHub versions' {
        It 'keeps S3 selected when candidate versions tie' {
            $s3Candidate = New-TestS3Candidate -Version 'windows-v3.5.770-internal'
            $githubCandidate = New-TestGithubCandidate -Version 'windows-v3.5.770-internal'

            $compare = Compare-RfqVersion $s3Candidate.Version $githubCandidate.Version 'internal'
            $selected = Resolve-ReleaseSource $s3Candidate $githubCandidate 'internal'

            Assert-SelectedRelease $selected 's3' $s3Candidate.Version 'tie_s3_preferred'
            $compare.Result | Should -Be 0
        }
    }
}

# Risk: Missing S3 should not block pure resolution when GitHub candidate exists
# Level: unit
# Source: contract §6 T3; proposal §7 T3; A4
Describe 'Resolve-ReleaseSource missing S3 behavior' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Missing S3 should not block pure resolution when GitHub candidate exists
    # Level: unit
    # Source: contract §6 T3; proposal §7 T3; A4
    Context 'S3 absent and GitHub present' {
        It 'selects GitHub without prompting for a token during pure resolution' {
            Mock Read-Host { throw 'Read-Host should not be called by Resolve-ReleaseSource.' }
            $githubCandidate = New-TestGithubCandidate -Version 'windows-v3.5.770-internal'

            $selected = Resolve-ReleaseSource $null $githubCandidate 'internal'

            Assert-SelectedRelease $selected 'github' $githubCandidate.Version 's3_absent'
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }
}

# Risk: Both missing must still reach original prompt path
# Level: component
# Source: contract §6 T4; proposal §7 T4; A5
Describe 'Installer fallback prompt path' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Both missing must still reach original prompt path
    # Level: component
    # Source: contract §6 T4; proposal §7 T4; A5
    Context 'both release candidates absent' {
        It 'keeps GitHub as the fallback source and reaches the downstream token prompt gate' {
            Mock Read-Host { 'ghp_component_fixture' }
            $script:ReleaseSource = 'github'
            $GitHubToken = ''

            $selected = Resolve-ReleaseSource $null $null 'internal'
            if ($null -ne $selected) {
                $script:ReleaseSource = $selected.Source
            }

            if ($script:ReleaseSource -ne 's3' -and [string]::IsNullOrWhiteSpace($GitHubToken)) {
                Write-Host 'GitHub Personal Access Token Required'
                $GitHubToken = Read-Host 'Enter your GitHub Personal Access Token'
            }

            $selected | Should -BeNullOrEmpty
            $script:ReleaseSource | Should -Be 'github'
            Should -Invoke Read-Host -Times 1 -Exactly
            (Get-InstallerScriptText) | Should -Match 'GitHub Personal Access Token Required'
        }
    }
}

# Risk: RCA structural invariant could remain red despite unit logic
# Level: particular-integration
# Source: contract §6 T5; proposal §7 T5; RCA acceptance
Describe 'RCA structural harness' {
    # Risk: RCA structural invariant could remain red despite unit logic
    # Level: particular-integration
    # Source: contract §6 T5; proposal §7 T5; RCA acceptance
    Context 'post-fix resolution region structure' {
        It 'passes the release-source resolution RCA harness' {
            $output = & bash $script:RcaHarnessPath 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 0
            ($output -join "`n") | Should -Match 'PASS: resolution region consults GitHub AND performs version comparison\.'
        }
    }
}

# Risk: GitHub-side failure could make S3 installs require PAT or fail
# Level: unit
# Source: contract §6 T6; proposal §7 T6; A4, A5
Describe 'GitHub comparison lookup failure handling' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: GitHub-side failure could make S3 installs require PAT or fail
    # Level: unit
    # Source: contract §6 T6; proposal §7 T6; A4, A5
    Context 'GitHub lookup throws while S3 candidate exists' {
        It 'returns no GitHub candidate with an error and leaves S3 selectable without prompting' {
            Mock Invoke-RestMethod { throw 'simulated GitHub outage' }
            Mock Read-Host { throw 'Read-Host should not be called while S3 remains selectable.' }
            $s3Candidate = New-TestS3Candidate -Version 'windows-v3.5.770-internal'

            $lookup = Get-GithubLatestCandidate 'https://api.github.com/repos' 'lama-ai-RFQ/RFQwindowspackages-internal' ''
            $selected = Resolve-ReleaseSource $s3Candidate $lookup.Candidate 'internal'

            $lookup.Candidate | Should -BeNullOrEmpty
            $lookup.Error | Should -Not -BeNullOrEmpty
            Assert-SelectedRelease $selected 's3' $s3Candidate.Version 'github_absent'
            Should -Invoke Read-Host -Times 0 -Exactly
            (Get-InstallerScriptText) | Should -Match 'GitHub latest candidate unavailable'
        }
    }
}

# Risk: Malformed version handling could pick the wrong side or throw
# Level: unit
# Source: contract §6 T7; proposal §7 T7; A1, A2
Describe 'Resolve-ReleaseSource one-sided unparsable versions' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Malformed version handling could pick the wrong side or throw
    # Level: unit
    # Source: contract §6 T7a; proposal §7 T7; A1, A2
    Context 'S3 version is unparsable and GitHub version parses' {
        It 'selects parseable GitHub when S3 version cannot be parsed' {
            $s3Candidate = New-TestS3Candidate -Version 'not-a-version'
            $githubCandidate = New-TestGithubCandidate -Version 'windows-v3.5.770-internal'

            $compare = Compare-RfqVersion $s3Candidate.Version $githubCandidate.Version 'internal'
            $selected = Resolve-ReleaseSource $s3Candidate $githubCandidate 'internal'

            Assert-SelectedRelease $selected 'github' 'windows-v3.5.770-internal' 'github_newer'
            $compare.Result | Should -Be -1
        }
    }

    # Risk: Malformed version handling could pick the wrong side or throw
    # Level: unit
    # Source: contract §6 T7b; proposal §7 T7; A1, A2
    Context 'GitHub version is unparsable and S3 version parses' {
        It 'selects parseable S3 when GitHub version cannot be parsed' {
            $s3Candidate = New-TestS3Candidate -Version 'windows-v3.5.770-internal'
            $githubCandidate = New-TestGithubCandidate -Version 'not-a-version'

            $compare = Compare-RfqVersion $s3Candidate.Version $githubCandidate.Version 'internal'
            $selected = Resolve-ReleaseSource $s3Candidate $githubCandidate 'internal'

            Assert-SelectedRelease $selected 's3' $s3Candidate.Version 's3_newer'
            $compare.Result | Should -Be 1
        }
    }
}

# Risk: Both malformed versions could abort instead of preserving installability
# Level: unit
# Source: contract §6 T8; proposal §7 T8; A4, A6
Describe 'Resolve-ReleaseSource both-unparsable and availability fallback policy' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Both malformed versions could abort instead of preserving installability
    # Level: unit
    # Source: contract §6 T8a; proposal §7 T8; A4, A6
    Context 'both candidates are present with unparsable versions' {
        It 'selects S3 because freshness is unknown' {
            $s3Candidate = New-TestS3Candidate -Version 'not-a-version'
            $githubCandidate = New-TestGithubCandidate -Version 'also-not-a-version'

            $compare = Compare-RfqVersion $s3Candidate.Version $githubCandidate.Version 'internal'
            $selected = Resolve-ReleaseSource $s3Candidate $githubCandidate 'internal'

            Assert-SelectedRelease $selected 's3' $s3Candidate.Version 'both_unparsable_s3_present'
            $compare.Result | Should -BeNullOrEmpty
        }
    }

    # Risk: Both malformed versions could abort instead of preserving installability
    # Level: unit
    # Source: contract §6 T8b; proposal §7 T8; A4, A6
    Context 'only S3 exists with an unparsable version' {
        It 'selects S3 by availability when GitHub is absent' {
            $s3Candidate = New-TestS3Candidate -Version 'not-a-version'

            $selected = Resolve-ReleaseSource $s3Candidate $null 'internal'

            Assert-SelectedRelease $selected 's3' $s3Candidate.Version 'github_absent'
        }
    }

    # Risk: Both malformed versions could abort instead of preserving installability
    # Level: unit
    # Source: contract §6 T8c; proposal §7 T8; A4, A6
    Context 'only GitHub exists with an unparsable version' {
        It 'selects GitHub by availability when S3 is absent' {
            $githubCandidate = New-TestGithubCandidate -Version 'not-a-version'

            $selected = Resolve-ReleaseSource $null $githubCandidate 'internal'

            Assert-SelectedRelease $selected 'github' $githubCandidate.Version 's3_absent'
        }
    }

    # Risk: Both malformed versions could abort instead of preserving installability
    # Level: unit
    # Source: contract §6 T8d; proposal §7 T8; A4, A6
    Context 'neither candidate exists' {
        It 'returns null when no release candidate exists' {
            $selected = Resolve-ReleaseSource $null $null 'internal'

            $selected | Should -BeNullOrEmpty
        }
    }
}

# Risk: Optional token handling in comparison request could mutate downstream auth state
# Level: unit
# Source: contract §6 T9; proposal §7 T9; A3, A5
Describe 'GitHub comparison lookup header isolation' {
    BeforeAll {
        Import-ReleaseSourceContractHelpers -Names @(
            'ConvertTo-RfqComparableVersion',
            'Compare-RfqVersion',
            'New-S3ReleaseCandidate',
            'Get-GithubLatestCandidate',
            'Resolve-ReleaseSource'
        )
    }

    # Risk: Optional token handling in comparison request could mutate downstream auth state
    # Level: unit
    # Source: contract §6 T9; proposal §7 T9; A3, A5
    Context 'comparison lookup with an optional token' {
        It 'uses local headers without mutating the shared Headers value' {
            $script:CapturedGithubHeaders = $null
            $script:Headers = @{ Existing = 'preserve-me' }
            $beforeHeaders = $script:Headers

            Mock Invoke-RestMethod {
                param($Uri, $Headers, $ErrorAction)
                $Uri | Should -Be 'https://api.github.com/repos/lama-ai-RFQ/RFQwindowspackages-internal/releases/latest'
                $script:CapturedGithubHeaders = $Headers
                [pscustomobject]@{
                    tag_name = 'windows-v3.5.770-internal'
                    assets   = @()
                }
            }

            $result = Get-GithubLatestCandidate 'https://api.github.com/repos' 'lama-ai-RFQ/RFQwindowspackages-internal' 'ghp_test_token'

            $result.Candidate.Source | Should -Be 'github'
            $result.Candidate.Version | Should -Be 'windows-v3.5.770-internal'
            [object]::ReferenceEquals($beforeHeaders, $script:Headers) | Should -BeTrue
            $script:Headers.Count | Should -Be 1
            $script:Headers['Existing'] | Should -Be 'preserve-me'
            $script:Headers.ContainsKey('Authorization') | Should -BeFalse
            [object]::ReferenceEquals($script:CapturedGithubHeaders, $script:Headers) | Should -BeFalse
            $script:CapturedGithubHeaders['Accept'] | Should -Be 'application/vnd.github.v3+json'
            $script:CapturedGithubHeaders['Authorization'] | Should -Be 'token ghp_test_token'
        }
    }
}
