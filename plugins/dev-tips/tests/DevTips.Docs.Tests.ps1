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

    # Asserted the way DevTips.RepoTips.Tests.ps1 asserts it, and for the reason the comment in
    # DevTips.RepoTips.ps1 gives: a bare `return @()` unrolls to $null, and the `,@()` wrapper that
    # would keep it an array is what broke Get-RepoTips when a caller consumed it inline. The
    # contract every caller actually relies on is that `@(Get-AdrTips ...)` counts zero.
    It 'counts as nothing when the directory does not exist' {
        @(Get-AdrTips -Root (Join-Path (New-TempDir) 'no-such')).Count | Should -Be 0
    }
}
