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
