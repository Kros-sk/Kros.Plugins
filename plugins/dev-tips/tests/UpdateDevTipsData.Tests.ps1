BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Script = Join-Path $PSScriptRoot '../hooks/Update-DevTipsData.ps1'
}

Describe 'Update-DevTipsData.ps1' {
    It 'backfills usage.json from the transcripts' {
        $stateDir = New-TempDir

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir -ProjectsRoot (New-FakeTranscripts)
        $LASTEXITCODE | Should -Be 0

        $usage = Get-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Raw | ConvertFrom-Json
        $usage.'git-diff' | Should -Not -BeNullOrEmpty
    }

    It 'refuses to guess the state directory' {
        & pwsh -NoProfile -File $script:Script -ProjectsRoot (New-FakeTranscripts)
        $LASTEXITCODE | Should -Be 1
    }

    It 'bails out when another run holds the lock' {
        $stateDir = New-TempDir
        'held' | Set-Content -LiteralPath (Join-Path $stateDir 'refresh.lock') -Encoding UTF8

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir -ProjectsRoot (New-FakeTranscripts)
        $LASTEXITCODE | Should -Be 2
    }

    It 'breaks a stale lock' {
        $stateDir = New-TempDir
        $lock = Join-Path $stateDir 'refresh.lock'
        'held' | Set-Content -LiteralPath $lock -Encoding UTF8
        (Get-Item -LiteralPath $lock).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-2)

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir -ProjectsRoot (New-FakeTranscripts)
        $LASTEXITCODE | Should -Be 0
    }

    It 'skips the scan when the history stamp is fresh' {
        $stateDir = New-TempDir
        (Get-Date).ToUniversalTime().ToString('o') |
            Set-Content -LiteralPath (Join-Path $stateDir 'history.stamp') -Encoding UTF8

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir -ProjectsRoot (New-FakeTranscripts)
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $stateDir 'usage.json') | Should -BeFalse
    }
}

Describe 'Update-DevTipsData.ps1 remote step' {
    It 'writes a snapshot from the fixture origin' {
        $stateDir = New-TempDir

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir `
            -ProjectsRoot (New-FakeTranscripts) -Origin (New-FixtureOriginRepo) -Branch 'master'
        $LASTEXITCODE | Should -Be 0

        $snapshot = Get-Content -LiteralPath (Join-Path $stateDir 'remote-tips.json') -Raw | ConvertFrom-Json
        ($snapshot.tips | Where-Object id -eq 'git-diff').title | Should -Be 'From the source'
        $snapshot.config.ttlHours | Should -Be 24
    }

    It 'logs a failed fetch and still exits 0, because the history job succeeded' {
        $stateDir = New-TempDir

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir `
            -ProjectsRoot (New-FakeTranscripts) -Origin 'C:\no\such\repo' -Branch 'master'
        $LASTEXITCODE | Should -Be 0

        (Get-Content -LiteralPath (Join-Path $stateDir 'debug.log') -Raw) | Should -Match 'fetch failed'
        Test-Path -LiteralPath (Join-Path $stateDir 'usage.json') | Should -BeTrue
    }

    It 'skips the fetch when the remote stamp is fresh' {
        $stateDir = New-TempDir
        (Get-Date).ToUniversalTime().ToString('o') |
            Set-Content -LiteralPath (Join-Path $stateDir 'remote.stamp') -Encoding UTF8

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir `
            -ProjectsRoot (New-FakeTranscripts) -Origin (New-FixtureOriginRepo) -Branch 'master'

        Test-Path -LiteralPath (Join-Path $stateDir 'remote-tips.json') | Should -BeFalse
    }
}

Describe 'Update-DevTipsData.ps1 and the ADR mirror' {
    # The mirror git keeps is bare: it has no working tree, so Get-ChildItem finds nothing in it.
    # The refresh writes the documents out as files, and the session-start path stays a plain
    # directory read with no git process on it.
    It 'writes the ADR documents out where the reader can see them' {
        $stateDir = New-TempDir

        & pwsh -NoProfile -File $script:Script -StateDir $stateDir -ProjectsRoot (New-FakeTranscripts) `
               -AdrOrigin (New-FixtureAdrRepo)
        $LASTEXITCODE | Should -Be 0

        Test-Path -LiteralPath (Join-Path $stateDir 'adr/Adrs/0001-prve.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stateDir 'adr.stamp') | Should -BeTrue
    }
}
