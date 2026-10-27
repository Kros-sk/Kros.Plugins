BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Remote.ps1')
}

Describe 'Invoke-MirrorFetch' {
    It 'creates the mirror and fetches the fixture origin' {
        $origin = New-FixtureOriginRepo
        $mirror = Join-Path (New-TempDir) 'remote'

        Invoke-MirrorFetch -MirrorPath $mirror -Origin $origin -Branch 'master' | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $mirror 'HEAD') | Should -BeTrue
    }

    It 'returns false for an origin that does not exist' {
        $mirror = Join-Path (New-TempDir) 'remote'
        Invoke-MirrorFetch -MirrorPath $mirror -Origin 'C:\no\such\repo' -Branch 'master' | Should -BeFalse
    }
}

Describe 'Get-RemoteTipFiles and ConvertTo-Tip' {
    It 'derives id, ref and install from the path' {
        $origin = New-FixtureOriginRepo
        $mirror = Join-Path (New-TempDir) 'remote'
        Invoke-MirrorFetch -MirrorPath $mirror -Origin $origin -Branch 'master' | Out-Null

        $files = Get-RemoteTipFiles -MirrorPath $mirror
        $tipFile = $files | Where-Object { $_.path -like '*skills/git-diff/tip.json' }
        $tip = ConvertTo-Tip -Path $tipFile.path -Json $tipFile.json -Marketplace 'kros-ai-dev-tools'

        $tip.id | Should -Be 'git-diff'
        $tip.ref | Should -Be '/git-diff'
        $tip.install.plugin | Should -Be 'kros-shared'
        $tip.install.marketplace | Should -Be 'kros-ai-dev-tools'
        $tip.title | Should -Be 'From the source'
        $tip.suppressIfUsed | Should -Be 'git-diff' -Because 'a migrated tip must not lose its suppression'
        $tip.PSObject.Properties.Name | Should -Not -Contain 'published'
    }
}

Describe 'ConvertTo-Tip for things that are not skills' {
    It 'names a command tip from the file, not the directory' {
        $tip = ConvertTo-Tip -Path 'plugins/kros-ssw/commands/commit.tip.json' `
                             -Json ([pscustomobject]@{ kind = 'command'; title = 't'; body = 'b' }) `
                             -Marketplace 'kros-ai-dev-tools'

        $tip.id | Should -Be 'commit'
        $tip.ref | Should -Be '/commit'
    }

    It 'strips .tip from an agent file name and does not advertise it as a command' {
        $tip = ConvertTo-Tip -Path 'plugins/kros-shared/agents/qa-branch-tester.tip.json' `
                             -Json ([pscustomobject]@{ kind = 'agent'; title = 't'; body = 'b' }) `
                             -Marketplace 'kros-ai-dev-tools'

        $tip.id | Should -Be 'qa-branch-tester'
        $tip.suppressIfUsed | Should -Be 'qa-branch-tester'
        $tip.ref | Should -Be 'qa-branch-tester' -Because 'an agent is not invoked with a slash'
    }
}

Describe 'Write-RemoteSnapshot' {
    It 'writes the snapshot without leaving a temp file behind' {
        $stateDir = New-TempDir

        Write-RemoteSnapshot -StateDir $stateDir `
            -Tips @([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' }) `
            -Config ([pscustomobject]@{ ttlHours = 24 })

        $snapshot = Get-Content -LiteralPath (Join-Path $stateDir 'remote-tips.json') -Raw | ConvertFrom-Json
        $snapshot.tips[0].id | Should -Be 'x'
        $snapshot.config.ttlHours | Should -Be 24
        @(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Test-SnapshotStale' {
    It 'is stale when there is no snapshot at all' {
        Test-SnapshotStale -StateDir (New-TempDir) -TtlHours 24 | Should -BeTrue
    }

    It 'is not stale when the snapshot is younger than the TTL' {
        $stateDir = New-TempDir
        '{}' | Set-Content -LiteralPath (Join-Path $stateDir 'remote-tips.json') -Encoding UTF8

        Test-SnapshotStale -StateDir $stateDir -TtlHours 24 | Should -BeFalse
    }

    It 'is stale once the snapshot passes the TTL' {
        $stateDir = New-TempDir
        $path = Join-Path $stateDir 'remote-tips.json'
        '{}' | Set-Content -LiteralPath $path -Encoding UTF8
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-25)

        Test-SnapshotStale -StateDir $stateDir -TtlHours 24 | Should -BeTrue
    }
}
