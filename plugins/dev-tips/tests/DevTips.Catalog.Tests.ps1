BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Catalog.ps1')
}

Describe 'Get-TipCatalog' {
    It 'returns the packaged tips and config' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ cooldownDays = 2 }
        $stateDir = New-TempDir

        $result = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

        $result.tips.Count | Should -Be 1
        $result.tips[0].id | Should -Be 'alpha'
        $result.config.cooldownDays | Should -Be 2
    }

    It 'returns an empty tip list rather than null when the catalog is missing' {
        $result = Get-TipCatalog -StateDir (New-TempDir) -PluginRoot (New-TempDir) -PluginsRoot (New-TempDir)

        ($result.tips -is [array]) | Should -BeTrue -Because 'callers foreach over it without a null check'
        $result.tips.Count | Should -Be 0
    }
}

Describe 'Merge-Tips' {
    It 'lets an authored tip override discovered copy for the same id' {
        $discovered = @([pscustomobject]@{ id = 'git-diff'; title = '/git-diff'; body = 'generated'; source = 'discovered' })
        $authored = @([pscustomobject]@{ id = 'git-diff'; title = 'Better title'; body = 'written by a human' })

        $merged = Merge-Tips -Authored $authored -Discovered $discovered

        @($merged).Count | Should -Be 1
        $merged[0].title | Should -Be 'Better title'
        $merged[0].body | Should -Be 'written by a human'
    }

    It 'keeps discovered tips that nobody has written copy for' {
        $discovered = @([pscustomobject]@{ id = 'teapie'; title = '/teapie'; body = 'generated' })
        $authored = @([pscustomobject]@{ id = 'commit'; title = '/commit'; body = 'written' })

        $merged = Merge-Tips -Authored $authored -Discovered $discovered

        @($merged).Count | Should -Be 2
        ($merged | Where-Object id -eq 'teapie').body | Should -Be 'generated'
    }

    It 'puts authored tips ahead of discovered ones' {
        $discovered = @(
            [pscustomobject]@{ id = 'alpha'; title = 'a'; body = 'b'; source = 'discovered' }
            [pscustomobject]@{ id = 'beta';  title = 'b'; body = 'b'; source = 'discovered' }
        )
        $authored = @([pscustomobject]@{ id = 'gamma'; title = 'g'; body = 'b'; source = 'repo' })

        $merged = Merge-Tips -Authored $authored -Discovered $discovered

        $merged[0].id | Should -Be 'gamma' -Because 'somebody wrote that one on purpose'
    }

    It 'keeps an overriding authored tip in the authored position, not the discovered one' {
        $discovered = @(
            [pscustomobject]@{ id = 'alpha'; title = 'a'; body = 'generated'; source = 'discovered' }
            [pscustomobject]@{ id = 'beta';  title = 'b'; body = 'generated'; source = 'discovered' }
        )
        $authored = @([pscustomobject]@{ id = 'beta'; title = 'B'; body = 'written'; source = 'repo' })

        $merged = Merge-Tips -Authored $authored -Discovered $discovered

        $merged[0].id | Should -Be 'beta'
        $merged[0].body | Should -Be 'written'
        @($merged).Count | Should -Be 2
    }
}

Describe 'Get-SourceRank' {
    It 'ranks every authored source ahead of a discovered one' {
        foreach ($s in @('repo', 'remote', 'packaged')) {
            Get-SourceRank ([pscustomobject]@{ source = $s }) |
                Should -BeLessThan (Get-SourceRank ([pscustomobject]@{ source = 'discovered' }))
        }
    }

    It 'treats a tip with no source as authored, because the packaged catalog has none' {
        Get-SourceRank ([pscustomobject]@{ id = 'x' }) |
            Should -BeLessThan (Get-SourceRank ([pscustomobject]@{ source = 'discovered' }))
    }
}

Describe 'Get-TipCatalog with a remote snapshot' {
    It 'prefers remote config over the packaged one, unclamped' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ cooldownDays = 2; ttlHours = 24 }
        $stateDir = New-TempDir
        ([pscustomobject]@{
            fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
            config    = [pscustomobject]@{ cooldownDays = 0; ttlHours = 1; enabled = $true }
            tips      = @([pscustomobject]@{ id = 'remote-one'; title = 'R'; body = 'b'; repos = @('*') })
        }) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateDir 'remote-tips.json') -Encoding UTF8

        $result = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot `
                                 -PluginsRoot (New-TempDir) -RepoRoot (New-TempDir)

        $result.config.cooldownDays | Should -Be 0 -Because 'fetched values are used as given, never clamped'
        ($result.tips | Where-Object id -eq 'remote-one') | Should -Not -BeNullOrEmpty
    }

    It 'returns no tips at all when the remote config disables the plugin' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ cooldownDays = 2 }
        $stateDir = New-TempDir
        ([pscustomobject]@{
            config = [pscustomobject]@{ enabled = $false }
            tips   = @()
        }) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateDir 'remote-tips.json') -Encoding UTF8

        $result = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot `
                                 -PluginsRoot (New-TempDir) -RepoRoot (New-TempDir)

        $result.tips.Count | Should -Be 0
    }
}

Describe 'Get-TipCatalog when authored tips are switched off' {
    # The copy for a skill is its own `description`, so a second, hand-written copy of it was
    # work nobody did: the catalog shipped eight authored tips and not one `*.tip.json` was
    # ever written. The switch retires the channel without deleting the code that reads it.
    It 'drops the packaged tips and keeps the config' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ cooldownDays = 2; authoredTips = $false }

        $result = Get-TipCatalog -StateDir (New-TempDir) -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

        $result.tips.Count | Should -Be 0
        $result.config.cooldownDays | Should -Be 2 -Because 'the switch retires tips, not the policy around them'
    }

    It 'drops a repository tip too, because .dev-tips files are authored as well' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ authoredTips = $false }
        $repo = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $repo '.dev-tips') -Force | Out-Null
        ([pscustomobject]@{ kind = 'adr'; title = 'ADR 0018'; body = 'CompanyId'; repos = @('*') }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.dev-tips/adr-0018.json') -Encoding UTF8

        $result = Get-TipCatalog -StateDir (New-TempDir) -PluginRoot $pluginRoot `
                                 -PluginsRoot (New-TempDir) -RepoRoot $repo

        $result.tips.Count | Should -Be 0
    }

    It 'still carries authored tips when the switch is absent' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ cooldownDays = 2 }

        $result = Get-TipCatalog -StateDir (New-TempDir) -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

        $result.tips.Count | Should -Be 1 -Because 'an older config must not lose its tips to a key it never set'
    }
}

Describe 'Get-TipCatalog with documents' {
    It 'carries ADR tips when announceDocs is on' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ authoredTips = $false; announceDocs = $true }
        $state = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $state 'adr/Adrs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'adr/Adrs/0001-x.md') -Encoding UTF8 `
                    -Value "---`ntitle: Prvé`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

        $result = Get-TipCatalog -StateDir $state -PluginRoot $pluginRoot `
                                 -PluginsRoot (New-TempDir) -RepoRoot (New-TempDir)

        @($result.tips | Where-Object { $_.kind -eq 'adr' }).Count | Should -Be 1
    }

    It 'carries no documents when announceDocs is off' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ authoredTips = $false; announceDocs = $false }
        $state = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $state 'adr/Adrs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'adr/Adrs/0001-x.md') -Encoding UTF8 `
                    -Value "---`ntitle: Prvé`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

        $result = Get-TipCatalog -StateDir $state -PluginRoot $pluginRoot `
                                 -PluginsRoot (New-TempDir) -RepoRoot (New-TempDir)

        @($result.tips | Where-Object { $_.kind -eq 'adr' }).Count | Should -Be 0
    }
}

Describe 'Initialize-DocsBaseline' {
    It 'marks everything that already exists as announced' {
        $state = New-TempDir
        $tips = @([pscustomobject]@{ id = 'a'; maxShows = 1 }, [pscustomobject]@{ id = 'b'; maxShows = 1 })

        Initialize-DocsBaseline -StateDir $state -Tips $tips -AnnounceAnyway @()

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.a.count | Should -Be 1 -Because 'a document that was already there is not news'
        $shown.entries.b.count | Should -Be 1
    }

    It 'leaves the named exceptions to announce' {
        $state = New-TempDir
        $tips = @([pscustomobject]@{ id = 'a'; maxShows = 1 }, [pscustomobject]@{ id = '0021'; maxShows = 1 })

        Initialize-DocsBaseline -StateDir $state -Tips $tips -AnnounceAnyway @('0021')

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.a.count | Should -Be 1
        $shown.entries.PSObject.Properties['0021'] | Should -BeNullOrEmpty -Because 'the measured exceptions are the point of the switch'
    }

    It 'runs once, so a document added later is still news' {
        $state = New-TempDir
        Initialize-DocsBaseline -StateDir $state -Tips @([pscustomobject]@{ id = 'a'; maxShows = 1 }) -AnnounceAnyway @()
        Initialize-DocsBaseline -StateDir $state -Tips @([pscustomobject]@{ id = 'b'; maxShows = 1 }) -AnnounceAnyway @()

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.PSObject.Properties['b'] | Should -BeNullOrEmpty -Because 'a second baseline would silence every ADR written from now on'
    }

    It 'keeps the cooldown it found, because a baseline is not a showing' {
        $state = New-TempDir
        ([pscustomobject]@{ lastShownAt = '2026-10-12T06:25:33Z'; entries = [pscustomobject]@{} }) |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $state 'shown.json') -Encoding UTF8

        Initialize-DocsBaseline -StateDir $state -Tips @([pscustomobject]@{ id = 'a'; maxShows = 1 }) -AnnounceAnyway @()

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        ([datetime]$shown.lastShownAt).ToUniversalTime() |
            Should -Be ([datetime]'2026-10-12T06:25:33Z').ToUniversalTime()
    }
}

Describe 'Initialize-DocsBaseline across sources that arrive at different times' {
    # The guidelines are read live from the repository; the ADRs arrive only after the Stop hook has
    # fetched the mirror, so the first session on a fresh install sees guidelines and no ADRs. One
    # shared marker would close the baseline on that partial set and every ADR written before the
    # install would then be announced as news - the backlog the baseline exists to prevent.
    It 'does not let one source close the baseline for another' {
        $state = New-TempDir

        Initialize-DocsBaseline -StateDir $state -Source 'guideline' -AnnounceAnyway @() `
                                -Tips @([pscustomobject]@{ id = 'guideline-workflow'; maxShows = 1 })
        Initialize-DocsBaseline -StateDir $state -Source 'adr' -AnnounceAnyway @() `
                                -Tips @([pscustomobject]@{ id = '0001-stary'; maxShows = 1 })

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.'0001-stary'.count | Should -Be 1 -Because 'an ADR that predates the install is not news'
    }

    It 'still runs only once per source' {
        $state = New-TempDir

        Initialize-DocsBaseline -StateDir $state -Source 'adr' -AnnounceAnyway @() `
                                -Tips @([pscustomobject]@{ id = 'a'; maxShows = 1 })
        Initialize-DocsBaseline -StateDir $state -Source 'adr' -AnnounceAnyway @() `
                                -Tips @([pscustomobject]@{ id = 'b'; maxShows = 1 })

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.PSObject.Properties['b'] | Should -BeNullOrEmpty
    }

    # The one operational lever this feature has. Adding an id later must do something, or the
    # person pulling it has no way to tell that it did not.
    It 'releases a document the baseline had silenced when it is named later' {
        $state = New-TempDir
        $tips = @([pscustomobject]@{ id = '0021-pravidla'; maxShows = 1 })

        Initialize-DocsBaseline -StateDir $state -Source 'adr' -Tips $tips -AnnounceAnyway @()
        Initialize-DocsBaseline -StateDir $state -Source 'adr' -Tips $tips -AnnounceAnyway @('0021-pravidla')

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.PSObject.Properties['0021-pravidla'] | Should -BeNullOrEmpty -Because 'the lever has to work after the first run too'
    }

    It 'does not release a document the person has actually been shown' {
        $state = New-TempDir
        ([pscustomobject]@{
            lastShownAt = '2026-10-12T06:25:33Z'
            entries = [pscustomobject]@{ '0021-pravidla' = [pscustomobject]@{ count = 1; last = '2026-10-12T06:25:33Z'; firstSeen = '2026-10-12T06:25:33Z' } }
        }) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $state 'shown.json') -Encoding UTF8

        Initialize-DocsBaseline -StateDir $state -Source 'adr' -AnnounceAnyway @('0021-pravidla') `
                                -Tips @([pscustomobject]@{ id = '0021-pravidla'; maxShows = 1 })

        $shown = Get-Content -LiteralPath (Join-Path $state 'shown.json') -Raw | ConvertFrom-Json
        $shown.entries.'0021-pravidla'.count | Should -Be 1 -Because 'a real showing is not the baseline silencing it'
    }
}
