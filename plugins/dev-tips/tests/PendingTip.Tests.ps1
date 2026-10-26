BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/Write-PendingTip.ps1')
}

Describe 'Get-SharedDir' {
    It 'is a fixed path, not one derived from the marketplace' {
        $dir = Get-SharedDir

        $dir | Should -Match 'dev-tips-shared$' -Because 'the module cannot know which marketplace installed us'
        Test-Path -LiteralPath $dir | Should -BeTrue
    }
}

Describe 'Write-PendingTip' {
    It 'writes one file per session, named so two sessions cannot overwrite each other' {
        $shared = New-TempDir
        $stateDir = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir $stateDir -SessionId 'abc-123' -InstallState 'installed' `
            -Tip ([pscustomobject]@{ id = 'az-pr'; kind = 'skill'; title = 't'; body = 'b'; ref = '/az-pr'; source = 'discovered' })

        Test-Path -LiteralPath (Join-Path $shared 'pending-abc-123.json') | Should -BeTrue
    }

    It 'carries the state directory, which is the only way the module can write back' {
        $shared = New-TempDir
        $stateDir = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir $stateDir -SessionId 's1' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        $pending = Get-Content -LiteralPath (Join-Path $shared 'pending-s1.json') -Raw | ConvertFrom-Json
        $pending.stateDir | Should -Be $stateDir
    }

    It 'writes the fields the band draws' {
        $shared = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 's1' -InstallState 'installed' `
            -Tip ([pscustomobject]@{
                id = 'az-pr'; kind = 'skill'; title = '/kros-shared:az-pr'
                body = 'Creates a pull request.'; ref = '/kros-shared:az-pr'; source = 'discovered'
            })

        $pending = Get-Content -LiteralPath (Join-Path $shared 'pending-s1.json') -Raw | ConvertFrom-Json
        $pending.id | Should -Be 'az-pr'
        $pending.ref | Should -Be '/kros-shared:az-pr'
        $pending.installState | Should -Be 'installed'
        $pending.source | Should -Be 'discovered'
        $pending.pickedAt | Should -Not -BeNullOrEmpty
        $pending.url | Should -BeNullOrEmpty
    }

    It 'carries a url when the tip has one' {
        $shared = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 's1' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{
                id = 'pre-pr'; kind = 'rule'; title = 'T'; body = 'b'
                ref = 'docs/guidelines/pre-pr-verification.md'
                url = 'https://dev.azure.com/krossk/Esw/_git/Invoicing?path=/docs/guidelines/pre-pr-verification.md'
            })

        $pending = Get-Content -LiteralPath (Join-Path $shared 'pending-s1.json') -Raw | ConvertFrom-Json
        $pending.url | Should -Match '^https://'
        $pending.kind | Should -Be 'rule'
    }

    It 'defaults the fields an older tip may not carry' {
        $shared = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 's1' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        $pending = Get-Content -LiteralPath (Join-Path $shared 'pending-s1.json') -Raw | ConvertFrom-Json
        $pending.kind | Should -Be 'tip'
        $pending.source | Should -Be 'packaged'
    }

    It 'leaves no temp file behind' {
        $shared = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 's1' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        @(Get-ChildItem -LiteralPath $shared -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Write-PendingTip housekeeping' {
    It 'sweeps what earlier sessions left behind' {
        $shared = New-TempDir
        $old = Join-Path $shared 'pending-long-gone.json'
        '{}' | Set-Content -LiteralPath $old -Encoding UTF8
        (Get-Item -LiteralPath $old).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-30)

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 'fresh' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $shared 'pending-fresh.json') | Should -BeTrue
    }

    It 'leaves a recent one alone, because another session may still be drawing it' {
        $shared = New-TempDir
        '{}' | Set-Content -LiteralPath (Join-Path $shared 'pending-other.json') -Encoding UTF8

        Write-PendingTip -SharedDir $shared -StateDir (New-TempDir) -SessionId 'mine' -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        Test-Path -LiteralPath (Join-Path $shared 'pending-other.json') | Should -BeTrue
    }
}

Describe 'Write-PendingTip and the repository the tip was picked in' {
    # The band reaches most handshakes through its fallback, which is machine-wide: without the
    # repository written down it tells the person a guideline is "in this repository" when the
    # handshake was picked in another one. The classic.SessionStart hook that would have keyed the
    # handshake by session does not reach the module - another plugin's hook takes the event first.
    It 'writes down which repository the tip came from' {
        $shared = New-TempDir
        $stateDir = New-TempDir
        $repo = New-TempDir

        Write-PendingTip -SharedDir $shared -StateDir $stateDir -SessionId 'abc-123' -InstallState 'n/a' `
            -RepoRoot $repo `
            -Tip ([pscustomobject]@{ id = 'guideline-workflow'; kind = 'guideline'; title = 'Workflow'
                                     body = 'b'; ref = 'docs/guidelines/workflow.md'; source = 'docs' })

        $written = Get-Content -LiteralPath (Join-Path $shared 'pending-abc-123.json') -Raw | ConvertFrom-Json

        $written.repoRoot | Should -Be $repo
    }
}
