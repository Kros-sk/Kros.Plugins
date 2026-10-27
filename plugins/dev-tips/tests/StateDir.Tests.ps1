BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
}

Describe 'Get-StateDir' {
    It 'is the same directory however the plugin was loaded' {
        $env:CLAUDE_PLUGIN_DATA = 'C:/somewhere/dev-tips-inline'
        try { $withVar = Get-StateDir } finally { $env:CLAUDE_PLUGIN_DATA = $null }
        $withoutVar = Get-StateDir

        $withVar | Should -Be $withoutVar -Because 'the same machine has one history, not one per load method'
        $withVar | Should -Match 'dev-tips-state$'
    }
}

Describe 'Merge-LegacyState' {
    It 'folds what earlier directories knew into the one that is kept' {
        $target = New-TempDir
        $a = New-TempDir
        $b = New-TempDir

        ([pscustomobject]@{ 'git-diff' = '2026-01-01T00:00:00Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $a 'usage.json') -Encoding UTF8
        ([pscustomobject]@{ 'teapie' = '2026-02-01T00:00:00Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $b 'usage.json') -Encoding UTF8

        Merge-LegacyState -TargetDir $target -LegacyDirs @($a, $b)

        $usage = Get-Content -LiteralPath (Join-Path $target 'usage.json') -Raw | ConvertFrom-Json
        $usage.'git-diff' | Should -Not -BeNullOrEmpty
        $usage.teapie | Should -Not -BeNullOrEmpty
    }

    It 'keeps the highest count and the latest showing for a tip both knew' {
        $target = New-TempDir
        $a = New-TempDir
        $b = New-TempDir

        ([pscustomobject]@{
            lastShownAt = '2026-03-01T00:00:00Z'
            entries = [pscustomobject]@{ 'commit' = [pscustomobject]@{ count = 1; last = '2026-01-01T00:00:00Z'; firstSeen = '2026-01-01T00:00:00Z' } }
        }) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $a 'shown.json') -Encoding UTF8

        ([pscustomobject]@{
            lastShownAt = '2026-05-01T00:00:00Z'
            entries = [pscustomobject]@{ 'commit' = [pscustomobject]@{ count = 3; last = '2026-05-01T00:00:00Z'; firstSeen = '2026-02-01T00:00:00Z' } }
        }) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $b 'shown.json') -Encoding UTF8

        Merge-LegacyState -TargetDir $target -LegacyDirs @($a, $b)

        $shown = Get-Content -LiteralPath (Join-Path $target 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.commit.count | Should -Be 3 -Because 'a tip seen three times must not be offered as if seen once'
        # Compared as a moment, not as text: a JSON round-trip through PowerShell normalises
        # the fraction, and the cooldown cares about the instant.
        ([datetime]$shown.lastShownAt).ToUniversalTime() |
            Should -Be ([datetime]'2026-05-01T00:00:00Z').ToUniversalTime() -Because 'the cooldown runs from the most recent showing'
        ([datetime]$shown.entries.commit.firstSeen).ToUniversalTime() |
            Should -Be ([datetime]'2026-01-01T00:00:00Z').ToUniversalTime() -Because 'firstSeen is the earliest, not the latest'
    }

    It 'runs once and then leaves the kept directory alone' {
        $target = New-TempDir
        $a = New-TempDir
        ([pscustomobject]@{ 'git-diff' = '2026-01-01T00:00:00Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $a 'usage.json') -Encoding UTF8

        Merge-LegacyState -TargetDir $target -LegacyDirs @($a)
        ([pscustomobject]@{}) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'usage.json') -Encoding UTF8
        Merge-LegacyState -TargetDir $target -LegacyDirs @($a)

        $usage = Get-Content -LiteralPath (Join-Path $target 'usage.json') -Raw | ConvertFrom-Json
        $usage.'git-diff' | Should -BeNullOrEmpty -Because 'a second merge would resurrect what the person has since cleared'
    }

    It 'does nothing when there is nothing to fold in' {
        $target = New-TempDir

        { Merge-LegacyState -TargetDir $target -LegacyDirs @((Join-Path $target 'no-such-dir')) } | Should -Not -Throw
    }
}

Describe 'Get-RepoRoot' {
    It 'is the top of the working tree, not the directory the hook happened to start in' {
        $repo = New-TempDir
        & git -C $repo init --initial-branch=master --quiet
        $deep = Join-Path $repo 'src/module'
        New-Item -ItemType Directory -Path $deep -Force | Out-Null

        Push-Location $deep
        try { $root = Get-RepoRoot } finally { Pop-Location }

        # Resolve-Path on both sides: git answers with forward slashes, Windows hands back its own.
        (Resolve-Path $root).Path | Should -Be (Resolve-Path $repo).Path
    }

    It 'falls back to the current directory outside a repository' {
        $plain = New-TempDir

        Push-Location $plain
        try { $root = Get-RepoRoot } finally { Pop-Location }

        (Resolve-Path $root).Path | Should -Be (Resolve-Path $plain).Path
    }
}
