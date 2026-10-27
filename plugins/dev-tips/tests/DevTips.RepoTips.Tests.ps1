BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.RepoTips.ps1')
}

Describe 'Get-RepoTips' {
    It 'reads every json file in .dev-tips' {
        $repo = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $repo '.dev-tips') -Force | Out-Null
        ([pscustomobject]@{ kind = 'adr'; title = 'ADR 0018'; body = 'CompanyId'; repos = @('*') }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.dev-tips/adr-0018-companyid.json') -Encoding UTF8

        $tips = Get-RepoTips -RepoRoot $repo

        @($tips).Count | Should -Be 1
        $tips[0].id | Should -Be 'adr-0018-companyid' -Because 'the file name is the id when the file omits one'
        $tips[0].source | Should -Be 'repo'
    }

    It 'returns an empty array when the repository has no .dev-tips directory' {
        @(Get-RepoTips -RepoRoot (New-TempDir)).Count | Should -Be 0
    }

    It 'ignores a malformed file rather than throwing' {
        $repo = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $repo '.dev-tips') -Force | Out-Null
        'not json {' | Set-Content -LiteralPath (Join-Path $repo '.dev-tips/broken.json') -Encoding UTF8

        @(Get-RepoTips -RepoRoot $repo).Count | Should -Be 0
    }
}
