BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.History.ps1')
}

Describe 'Get-HistoricalSkillUse' {
    It 'records a qualified skill under both the qualified and the bare name' {
        $found = Get-HistoricalSkillUse -ProjectsRoot (New-FakeTranscripts) -Since ([datetime]'2000-01-01')

        $found['kros-shared:git-diff'].count | Should -Be 2
        $found['git-diff'].count | Should -Be 2
        $found['git-diff'].last | Should -BeGreaterThan ([datetime]'2026-09-01T12:00:00Z')
    }

    It 'skips transcripts older than the window' {
        $root = New-FakeTranscripts
        Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -Recurse | ForEach-Object {
            $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
        }

        $found = Get-HistoricalSkillUse -ProjectsRoot $root -Since ((Get-Date).ToUniversalTime().AddDays(-90))

        $found.Keys.Count | Should -Be 0
    }

    It 'returns an empty result when the projects directory does not exist' {
        (Get-HistoricalSkillUse -ProjectsRoot 'C:\no\such\dir' -Since ([datetime]'2000-01-01')).Keys.Count |
            Should -Be 0
    }
}

Describe 'Merge-UsageFile' {
    It 'adds historical names without discarding live records' {
        $stateDir = New-TempDir
        ([pscustomobject]@{ 'push' = '2026-09-20T00:00:00.0000000Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Encoding UTF8

        $found = @{ 'git-diff' = [pscustomobject]@{ count = 2; last = [datetime]'2026-09-02T10:00:00Z' } }
        Merge-UsageFile -StateDir $stateDir -Found $found | Out-Null

        $usage = Get-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Raw | ConvertFrom-Json
        $usage.push | Should -Not -BeNullOrEmpty
        $usage.'git-diff' | Should -Not -BeNullOrEmpty
    }
}
