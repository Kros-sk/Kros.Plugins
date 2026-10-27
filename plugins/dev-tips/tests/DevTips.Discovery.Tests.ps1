BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Discovery.ps1')
}

Describe 'Read-SkillFrontmatter' {
    It 'reads name and description' {
        $pluginsRoot = New-FakePluginsRoot
        $skill = Get-ChildItem -Path $pluginsRoot -Filter 'SKILL.md' -Recurse |
            Where-Object { $_.FullName -like '*git-diff*' } | Select-Object -First 1

        $fm = Read-SkillFrontmatter $skill.FullName

        $fm.name | Should -Be 'git-diff'
        $fm.description | Should -Be 'Analyze git changes against master.'
    }

    It 'folds a multi-line description written as a YAML block scalar' {
        $path = Join-Path (New-TempDir) 'SKILL.md'
        @(
            '---'
            'name: az-pr'
            'description: >'
            '  Creates an Azure DevOps pull request from the current branch.'
            '  Detects the org and project from the git remote.'
            '---'
            ''
            'body'
        ) | Set-Content -LiteralPath $path -Encoding UTF8

        $fm = Read-SkillFrontmatter $path

        $fm.name | Should -Be 'az-pr'
        $fm.description | Should -Be 'Creates an Azure DevOps pull request from the current branch. Detects the org and project from the git remote.'
    }

    It 'returns null for a file with no frontmatter' {
        $path = Join-Path (New-TempDir) 'SKILL.md'
        'no frontmatter here' | Set-Content -LiteralPath $path -Encoding UTF8

        Read-SkillFrontmatter $path | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-TipBody' {
    It 'leaves a short description alone' {
        ConvertTo-TipBody 'Short enough already.' | Should -Be 'Short enough already.'
    }

    It 'cuts a long description at a sentence boundary' {
        $text = 'Creates an Azure DevOps pull request (as draft) from the current branch using the az CLI. ' +
                'Automatically detects the org/project/repo from the git remote URL, parses a work item ID ' +
                'from the branch name if present (format: bugfix/12345-description), and generates a PR title ' +
                'and description by analyzing git commits and diff against master.'

        $body = ConvertTo-TipBody $text

        $body | Should -Be 'Creates an Azure DevOps pull request (as draft) from the current branch using the az CLI.'
        $body | Should -Not -Match '…'
    }

    It 'falls back to a word boundary and an ellipsis when there is no sentence to end on' {
        $text = 'word ' * 100

        $body = ConvertTo-TipBody $text

        $body.Length | Should -BeLessOrEqual 240
        $body | Should -Match '…$'
        $body | Should -Not -Match ' …$' -Because 'the ellipsis follows the last word, not a space'
    }
}

Describe 'Get-DiscoveredTips' {
    It 'produces a tip for an installed but unused skill' {
        $tips = Get-DiscoveredTips -StateDir (New-TempDir) -PluginsRoot (New-FakePluginsRoot)

        $tips.Count | Should -Be 1
        $tips[0].id | Should -Be 'git-diff' -Because 'ids stay bare so authored tips can override by id'
        $tips[0].ref | Should -Be '/kros-shared:git-diff' -Because 'the bare form may not resolve for a plugin skill'
        $tips[0].title | Should -Be '/kros-shared:git-diff'
        $tips[0].suppressIfUsed | Should -Be 'git-diff' -Because 'usage.json is matched on either form'
        $tips[0].kind | Should -Be 'skill'
        $tips[0].install.plugin | Should -Be 'kros-shared'
        $tips[0].install.marketplace | Should -Be 'kros-ai-dev-tools'
        $tips[0].body | Should -Match 'Analyze git changes'
    }

    It 'ignores skills from marketplaces that are not ours' {
        $tips = Get-DiscoveredTips -StateDir (New-TempDir) -PluginsRoot (New-FakePluginsRoot)

        @($tips).Count | Should -Be 1
        ($tips | Where-Object id -eq 'using-git-worktrees') | Should -BeNullOrEmpty `
            -Because 'we do not advertise other vendors tooling'
    }

    It 'can be pointed at a different marketplace' {
        $tips = Get-DiscoveredTips -StateDir (New-TempDir) -PluginsRoot (New-FakePluginsRoot) `
                                   -Marketplaces @('claude-plugins-official')

        @($tips).Count | Should -Be 1
        $tips[0].id | Should -Be 'using-git-worktrees'
    }

    It 'skips a skill the developer has already used' {
        $stateDir = New-TempDir
        ([pscustomobject]@{ 'kros-shared:git-diff' = '2026-09-01T00:00:00Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Encoding UTF8

        $tips = Get-DiscoveredTips -StateDir $stateDir -PluginsRoot (New-FakePluginsRoot)

        @($tips).Count | Should -Be 0
    }
}

Describe 'ConvertTo-TipBody and ordinary prose that only looks like an abbreviation' {
    # The abbreviation rule exists for "napr." and its kind. Written as "any short lowercase word"
    # it also rejects "it", "nič", "kód" - ordinary sentence endings - and then no boundary is left
    # at all, so the ellipsis fallback fires and the body ends on a full stop AND an ellipsis.
    It 'cuts after a sentence that ends in a short ordinary word' {
        $text = 'Use when someone wants to understand a pull request, branch or commit instead of ' +
                'reading the raw diff, as its author before review, as a reviewer, or to catch up ' +
                'on what landed in a project while away or when joining it. ' +
                'Triggers: vysvetli PR, explain this PR, walk me through this change and so on.'

        $body = ConvertTo-TipBody $text

        $body | Should -Not -Match '\.…$' -Because 'a full stop followed by an ellipsis reads as a bug'
        $body | Should -BeLike '*joining it.'
    }

    It 'still refuses to cut after a real abbreviation' {
        $text = 'Zaviedli sme pravidlo, ktoré platí všade a popisuje veci veľmi zoširoka. ' +
                'Druhá veta hovorí o module Invoicing a o module Framework a aj o ďalších (napr. ' +
                'v Účtovníctve a v ERP a v iných systémoch, ktoré používame na rôznych projektoch a v tímoch), ' +
                'čo presne tým myslíme a prečo to tak je.'

        ConvertTo-TipBody $text | Should -Not -Match '\(napr\.$'
    }

    It 'is not poisoned by a closing bracket that never had an opener' {
        $text = 'Pravidlo a) hovorí, že každý modul má mať vlastný priečinok a vlastné testy. ' +
                'Druhá veta vysvetľuje, prečo to tak je a čo z toho plynie pre nové projekty. ' +
                'Tretia veta je už celá za hranicou dvestoštyridsiatich znakov, nemá sa zobraziť ' +
                'a je tu len preto, aby orezávanie vôbec nastalo a bolo čo posudzovať.'

        $body = ConvertTo-TipBody $text

        $body | Should -Not -Match '…$' -Because 'a) is ordinary enumeration, not an unclosed bracket'
        $body | Should -BeLike '*plynie pre nové projekty.'
    }
}
