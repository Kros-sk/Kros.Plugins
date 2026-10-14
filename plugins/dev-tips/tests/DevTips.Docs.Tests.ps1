BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Discovery.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Docs.ps1')

    # Inside BeforeAll, not beside it: Pester 5 runs an It in its own scope, and a function
    # declared at file scope is gone by then.
    function New-Adr([string]$Dir, [string]$Name, [string]$Text)
    {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $Dir $Name) -Value $Text -Encoding UTF8
    }
}

Describe 'Get-AdrTips' {
    It 'takes the title from the front matter and the body from the decision' {
        $dir = New-TempDir
        New-Adr $dir '0018-CompanyId.md' @'
---
title: CompanyId vs TenantId
status: Accepted
---

# CompanyId vs TenantId

## Kontext

Dochádza k nedorozumeniam okolo pojmov.

## Rozhodnutie

CompanyId identifikuje spoločnosť, TenantId zákazníka.

## Dôsledky

Nič.
'@

        $tips = @(Get-AdrTips -Root $dir)

        @($tips).Count | Should -Be 1
        $tips[0].id | Should -Be '0018-CompanyId'
        $tips[0].kind | Should -Be 'adr'
        $tips[0].title | Should -Be 'CompanyId vs TenantId'
        $tips[0].body | Should -Be 'CompanyId identifikuje spoločnosť, TenantId zákazníka.'
        $tips[0].maxShows | Should -Be 1 -Because 'an announcement is made once and never repeated'
    }

    It 'skips a document with no decision section rather than announcing an empty one' {
        $dir = New-TempDir
        New-Adr $dir '0099-nedokoncene.md' "---`ntitle: Nedokončené`n---`n`n## Kontext`n`nIba kontext.`n"

        @(Get-AdrTips -Root $dir).Count | Should -Be 0
    }

    It 'trims a bullet list to something that reads as a sentence' {
        $dir = New-TempDir
        $long = '- ' + ('Pre nové projekty volíme modulárny monolit. ' * 12)
        New-Adr $dir '0003-monolit.md' "---`ntitle: Modulárny monolit`n---`n`n## Rozhodnutie`n`n$long`n"

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body.Length | Should -BeLessOrEqual 240
        $body.TrimEnd() | Should -Not -Match '[-,;]$' -Because 'an announcement cut mid-list reads as a bug'
        $body | Should -Not -Match '^\s*[-*+]\s' -Because 'a lone bullet opening the band is markup, not a sentence'
    }

    It 'prefers a tip line in the front matter over the decision paragraph' {
        $dir = New-TempDir
        New-Adr $dir '0021-rules.md' "---`ntitle: Pravidlá`ntip: Jedna veta, ktorú napísal človek.`n---`n`n## Rozhodnutie`n`nDlhý odsek.`n"

        @(Get-AdrTips -Root $dir)[0].body | Should -Be 'Jedna veta, ktorú napísal človek.'
    }

    # The fixtures above are written with LF, every document in Kros.ADR has CRLF, and the first
    # version of this reader found 20 decisions in the fixtures and 0 in the real repository.
    It 'reads a document whose lines end CRLF, which every real one does' {
        $dir = New-TempDir
        $crlf = "---`r`ntitle: CRLF`r`n---`r`n`r`n## Rozhodnutie`r`n`r`nRobíme to takto.`r`n"
        [IO.File]::WriteAllText((Join-Path $dir '0007-crlf.md'), $crlf, [Text.UTF8Encoding]::new($false))

        @(Get-AdrTips -Root $dir)[0].body | Should -Be 'Robíme to takto.'
    }

    # The band draws Text, not markdown. A decision written as **this** would reach the person
    # with the asterisks still in it, and ADR 0002 is written exactly that way.
    It 'strips the markup the document wrote for a renderer the band does not have' {
        $dir = New-TempDir
        $body = 'Prechod na **TeaPie framework** pre `integračné` testy.'
        New-Adr $dir '0002-teapie.md' "---`ntitle: TeaPie`n---`n`n## Rozhodnutie`n`n$body`n"

        @(Get-AdrTips -Root $dir)[0].body | Should -Be 'Prechod na TeaPie framework pre integračné testy.'
    }

    # Asserted the way DevTips.RepoTips.Tests.ps1 asserts it, and for the reason the comment in
    # DevTips.RepoTips.ps1 gives: a bare `return @()` unrolls to $null, and the `,@()` wrapper that
    # would keep it an array is what broke Get-RepoTips when a caller consumed it inline. The
    # contract every caller actually relies on is that `@(Get-AdrTips ...)` counts zero.
    It 'counts as nothing when the directory does not exist' {
        @(Get-AdrTips -Root (Join-Path (New-TempDir) 'no-such')).Count | Should -Be 0
    }
}

Describe 'Get-GuidelineTips' {
    It 'takes the heading and the first paragraph' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'design-doc-template.md') -Encoding UTF8 -Value @'
# Design Document Template

Use this template for all design documents: features, bugs, and refactoring.

## Filename

Something else.
'@

        $tips = @(Get-GuidelineTips -RepoRoot $repo)

        @($tips).Count | Should -Be 1
        $tips[0].kind | Should -Be 'guideline'
        $tips[0].title | Should -Be 'Design Document Template'
        $tips[0].body | Should -Be 'Use this template for all design documents: features, bugs, and refactoring.'
        $tips[0].ref | Should -Be 'docs/guidelines/design-doc-template.md'
        $tips[0].maxShows | Should -Be 1
    }

    # The same trap Get-AdrTips fell into: the fixtures are LF, every real document is CRLF.
    It 'reads a guideline whose lines end CRLF' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'workflow.md'),
            "# Workflow`r`n`r`nPrvý odsek, ktorý sa má zobraziť.`r`n`r`n## Ďalšie`r`n",
            [Text.UTF8Encoding]::new($false))

        $tips = @(Get-GuidelineTips -RepoRoot $repo)

        $tips[0].title | Should -Be 'Workflow'
        $tips[0].body | Should -Be 'Prvý odsek, ktorý sa má zobraziť.'
    }

    It 'counts as nothing when the repository has no guidelines' {
        @(Get-GuidelineTips -RepoRoot (New-TempDir)).Count | Should -Be 0
    }

    It 'skips a file with a heading and nothing under it' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'empty.md') -Value "# Len nadpis`n" -Encoding UTF8

        @(Get-GuidelineTips -RepoRoot $repo).Count | Should -Be 0
    }
}
