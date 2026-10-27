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

    # ADR 0018's decision is a numbered list. Flattened with the numbers left in, the body ended
    # "...mapuje na CompanyId. 3." - an orphan enumerator, the same defect as a dangling bullet.
    It 'does not leave an orphan number where a numbered list was cut' {
        $dir = New-TempDir
        $items = 1..8 | ForEach-Object { "$_. Polozka cislo $_ popisuje nieco dolezite a zrozumitelne." }
        New-Adr $dir '0018-cisla.md' ("---`ntitle: Cisla`n---`n`n## Rozhodnutie`n`n" + ($items -join "`n") + "`n")

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body.TrimEnd() | Should -Not -Match '\d+\.$' -Because 'a trailing list number is markup, not a sentence'
        $body | Should -Not -Match '^\d+\.\s' -Because 'the first item should not open with its number either'
    }

    # The band draws Text, not markdown. A decision written as **this** would reach the person
    # with the asterisks still in it, and ADR 0002 is written exactly that way.
    It 'strips the markup the document wrote for a renderer the band does not have' {
        $dir = New-TempDir
        $body = 'Prechod na **TeaPie framework** pre `integračné` testy.'
        New-Adr $dir '0002-teapie.md' "---`ntitle: TeaPie`n---`n`n## Rozhodnutie`n`n$body`n"

        @(Get-AdrTips -Root $dir)[0].body | Should -Be 'Prechod na TeaPie framework pre integračné testy.'
    }

    # The band composes a path from the state directory and this ref, so a bare file name leaves
    # the model hunting for a file it has no directory for.
    It 'refers to the ADR by its path inside the mirror, not by its bare name' {
        $dir = New-TempDir
        New-Adr $dir '0018-CompanyId.md' "---`ntitle: X`n---`n`n## Rozhodnutie`n`nRobime to takto.`n"

        @(Get-AdrTips -Root $dir)[0].ref | Should -Be 'Adrs/0018-CompanyId.md'
    }

    # ADR 0018 - one of the two the config names as worth announcing - opens its decision with a
    # sub-heading and then a table. Announcing "### Definicie pojmov" tells the person nothing.
    It 'passes over a sub-heading and a table to find prose' {
        $dir = New-TempDir
        New-Adr $dir '0018-CompanyId.md' @'
---
title: CompanyId vs TenantId
---

## Kontext

V systemoch dochadza k nedorozumeniam okolo pojmov.

## Rozhodnutie

### Definicie pojmov

| Pojem | Vyznam |
|-------|--------|
| CompanyId | Identifikator spolocnosti. |
'@

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body | Should -Not -Match '^#' -Because 'a heading is not a sentence'
        $body | Should -Not -Match '^\|' -Because 'a table row is not a sentence either'
        $body | Should -Be 'V systemoch dochadza k nedorozumeniam okolo pojmov.'
    }

    It 'skips the document when neither the decision nor the context has prose' {
        $dir = New-TempDir
        New-Adr $dir '0050-tabulka.md' "---`ntitle: Iba tabulka`n---`n`n## Rozhodnutie`n`n| a | b |`n|---|---|`n"

        @(Get-AdrTips -Root $dir).Count | Should -Be 0
    }

    # 7 of the 20 real bodies carried an interior " - " and three were cut after "napr.", leaving an
    # unclosed bracket. Both pass the existing first-character and last-character assertions.
    It 'joins a list into prose instead of leaving the markers in the middle' {
        $dir = New-TempDir
        $list = "- Prvá vec je takáto.`n- Druhá vec je onaká.`n- Tretia vec je iná."
        New-Adr $dir '0005-zoznam.md' "---`ntitle: Zoznam`n---`n`n## Rozhodnutie`n`n$list`n"

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body | Should -Not -Match ' - ' -Because 'a flattened list reads as prose or not at all'
    }

    It 'does not cut after an abbreviation, leaving a bracket open' {
        $dir = New-TempDir
        # Long enough that the 240 cap actually cuts, with "napr." as the last sentence end before
        # it - which is how three of the real bodies ended up truncated mid-clause.
        $text = 'Zaviedli sme pravidlo, ktoré platí všade a popisuje veci veľmi zoširoka. ' +
                'Druhá veta hovorí o module Invoicing a o module Framework a aj o ďalších (napr. ' +
                'v Účtovníctve a v ERP a v iných systémoch, ktoré používame na rôznych projektoch a v tímoch), ' +
                'čo presne tým myslíme a prečo to tak je.'
        New-Adr $dir '0004-skratka.md' "---`ntitle: Skratka`n---`n`n## Rozhodnutie`n`n$text`n"

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body | Should -Not -Match '\(napr\.$' -Because 'a cut after an abbreviation leaves the bracket open'
        ($body.ToCharArray() | Where-Object { $_ -eq '(' }).Count |
            Should -Be ($body.ToCharArray() | Where-Object { $_ -eq ')' }).Count -Because 'brackets must balance'
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

Describe 'Get-AdrTips when a block mixes prose with markup' {
    # The guard is for a block that OPENS with a heading or a table, which is ADR 0018. Applied to
    # every line it threw away the whole block the moment a stray markup line appeared further
    # down, and announced the NEXT paragraph as if it were the decision - a silent substitution.
    It 'keeps the prose and stops at the markup, instead of announcing a different paragraph' {
        $dir = New-TempDir
        New-Adr $dir '0030-mix.md' @'
---
title: Mix
---

## Rozhodnutie

Pouzivame nasledovne pravidlo pre kazdy projekt.
#region internals

Druhy odstavec nie je rozhodnutie.
'@

        $body = @(Get-AdrTips -Root $dir)[0].body

        $body | Should -Be 'Pouzivame nasledovne pravidlo pre kazdy projekt.'
    }
}

Describe 'Get-AdrTips and an ADR written without sections' {
    # ADR 0017 is Accepted and says something worth knowing, but it is flat prose under its H1 with
    # no ## headings at all, so neither the decision nor the context fallback could reach it. It was
    # announced to nobody. Such a document is announced from its own opening, and the band shows
    # the whole of it once the person expands the notice.
    It 'announces a sectionless document from its opening paragraph' {
        $dir = New-TempDir
        New-Adr $dir '0017-agenticky.md' @'
---
title: Agentický prístup k vývoju
status: Accepted
---

# Agentický prístup k vývoju

| Dátum | Status |
|-------|--------|
| 25.03.2026 | Accepted |

Chceme, aby sme v plnej miere využívali AI pri vývoji všetkých našich produktov.

Druhý odsek hovorí o tom, aký prístup chceme v tímoch mať.
'@

        $tip = @(Get-AdrTips -Root $dir)[0]

        $tip.title | Should -Be 'Agentický prístup k vývoju'
        $tip.body | Should -Be 'Chceme, aby sme v plnej miere využívali AI pri vývoji všetkých našich produktov.'
        $tip.full | Should -Match 'Druhý odsek' -Because 'expanding the notice shows the whole document'
    }

    It 'carries no full text for a document that has a decision section' {
        $dir = New-TempDir
        New-Adr $dir '0001-sekcie.md' "---`ntitle: Sekcie`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

        @(Get-AdrTips -Root $dir)[0].full | Should -BeNullOrEmpty -Because 'the decision is the whole point of a sectioned ADR'
    }

    It 'still skips a document that has no prose anywhere' {
        $dir = New-TempDir
        New-Adr $dir '0040-prazdne.md' "---`ntitle: Prázdne`n---`n`n# Prázdne`n`n| a | b |`n|---|---|`n"

        @(Get-AdrTips -Root $dir).Count | Should -Be 0
    }
}

Describe 'Get-GuidelineTips and the rest of the document' {
    # The band announces a guideline from its opening paragraph, so the body is always an excerpt -
    # the same situation as a sectionless ADR, and expanding should show the rest.
    It 'carries the whole document, with its headings as the outline' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'workflow.md') -Encoding UTF8 -Value @'
# Development Workflow

This document defines the mandatory workflow.

## Filename

docs/design-docs/{issue}-{name}.md

## Steps

Always extract the issue number from the branch name.
'@

        $tip = @(Get-GuidelineTips -RepoRoot $repo)[0]

        $tip.body | Should -Be 'This document defines the mandatory workflow.'
        $tip.full | Should -Match 'Always extract the issue number' -Because 'expanding shows the rest'
        $tip.full | Should -Match 'Filename' -Because 'without its heading a bare path says nothing'
    }
}

Describe 'Get-DocumentProse and the shape of the expanded notice' {
    # Joining every block with a blank line turned a document whose paragraphs are single lines -
    # which a template mostly is - into a blank line after every line. The blank line marks a
    # section; inside one, the lines sit together.
    It 'puts a blank line before a section, not between every line' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'template.md') -Encoding UTF8 -Value @'
# Template

Use this template for everything.

## Filename

docs/design-docs/{issue}-{name}.md

Example: docs/design-docs/58061-payment.md

## Steps

Extract the issue number from the branch.
'@

        $full = @(Get-GuidelineTips -RepoRoot $repo)[0].full

        $full | Should -Be @'
Use this template for everything.

Filename
docs/design-docs/{issue}-{name}.md
Example: docs/design-docs/58061-payment.md

Steps
Extract the issue number from the branch.
'@.Replace("`r`n", "`n")
    }
}

Describe 'ConvertTo-Prose and markup that is not text' {
    It 'drops a horizontal rule and the fences around a code block' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'fence.md') -Encoding UTF8 -Value @'
# Fence

Prvy odsek dokumentu.

---

## Template

```markdown
Ticket: docs/tickets/{issue}.md
```
'@

        $full = @(Get-GuidelineTips -RepoRoot $repo)[0].full

        $full | Should -Not -Match '(?m)^-{3,}$' -Because 'a horizontal rule is a line, not a sentence'
        $full | Should -Not -Match '(?m)^markdown$' -Because 'the fence language is not content'
        $full | Should -Match 'Ticket: docs/tickets' -Because 'what is inside the fence is the template itself'
    }
}

Describe 'ConvertTo-Prose and a line that already ends in punctuation' {
    # Joining list items with "; " after a line that ends in a colon produced ":;" - ADR 0007 is
    # announced as "...podla capability a CQS-light:; Citanie: ...".
    It 'does not add a semicolon to a line that ends in a colon' {
        $dir = New-TempDir
        $body = "Zavadzame toto:`n- Citanie: Provider.`n- Zapis: Writer."
        New-Adr $dir '0007-rozhrania.md' "---`ntitle: Rozhrania`n---`n`n## Rozhodnutie`n`n$body`n"

        $text = @(Get-AdrTips -Root $dir)[0].body

        $text | Should -Not -Match ':\s*;' -Because 'a colon already joins what follows it'
        $text | Should -Be 'Zavadzame toto: Citanie: Provider. Zapis: Writer.'
    }
}
