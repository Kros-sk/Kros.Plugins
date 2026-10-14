# dev-tips ADR and guideline announcements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Announce a new ADR or guideline once, in the band that already draws tips, with its text taken from the document itself rather than from a tip file somebody has to write.

**Architecture:** Two readers beside `Get-DiscoveredTips` turn documents into the tip shape the rest of the chain already carries: an ADR's `title:` front matter plus the first paragraph of its `## Rozhodnutie`, a guideline's `# H1` plus its first paragraph, both trimmed by the existing `ConvertTo-TipBody`. They emit `maxShows = 1`, which is what "announced once, never repeated" means in machinery that already exists. ADRs arrive through a shallow mirror fetched the same way the remote tips are; guidelines are read live from the repository being worked in. A one-time baseline writes every document that exists at switch-on into `shown.json` as already announced, so only what lands afterwards is news — except the ids named in `announceAnyway`, which are left to announce.

**Tech Stack:** PowerShell 7.6.6, Pester 5.9.1, TypeScript hooks module against the Claude Code mod API (early access), `claude plugin validate` / `claude plugin test`.

**Spec:** `plugins/dev-tips/docs/catalog-distribution.md`; decisions D1, D2, D9, D10 and D13 in `plugins/dev-tips/docs/catalog-distribution-analysis.md`. D1, D2 and D10 describe the authored-file channel this plan replaces — they are superseded, and recording that as D18 is Task 6.

**Measurements this plan is built on** (taken 14 Oct 2026, from `utils/Kros.ADR/Adrs` and `Invoicing/docs/guidelines`):

- 22 ADRs. 20 carry `## Rozhodnutie`; 2 do not and must be skipped.
- First paragraph of `## Rozhodnutie`: min 20, median 150, max 1330 characters. 14 of 20 fit under the 240 cap unaided.
- ADR 0003's first paragraph is a bullet list, not prose.
- 4 guidelines, no front matter at all: `# H1` then a paragraph.
- ADR file names carry Slovak diacritics.

## Global Constraints

- **The module never selects.** Cooldown, `maxShows`, suppression and ranking stay in PowerShell. The band draws what the handshake names.
- **Announced once.** Every document tip carries `maxShows = 1`. No document is announced twice, on any surface.
- **No authored tip files.** `authoredTips` is `false` and stays false. The only authored copy allowed is a single optional `tip:` line in the document's own front matter — next to the thing it describes, never in a separate file.
- **Nothing leaves the machine.** No telemetry, no upload, no write outside the state directory.
- **Body cap is 240 characters**, applied by the existing `ConvertTo-TipBody`, so a document reads at the same length as a skill.
- **A reader that finds nothing returns `@()`, not `$null`.** Follow the idiom and the comment in `hooks/DevTips.RepoTips.ps1`: no comma wrapper, because every caller consumes the result inline as `@(Get-… )`.

## Review Focus

- **An ADR with no `## Rozhodnutie`** (2 of the 22 today) must be skipped entirely, not announced with an empty body. Covered in Task 1.
- **A first paragraph that is a bullet list** (ADR 0003, 646 characters) must not be announced ending on a dangling `-` or half a word. Covered in Task 1.
- **`docs/guidelines` missing** must yield an empty array, not `$null` — the trap this repository has already been bitten by. Covered in Task 2.
- **The baseline marker** must stop a second run from silencing a document added since the first, which would make a genuinely new ADR disappear forever. Covered in Task 4.
- **Slovak text and file names** must survive the read: diacritics in a title or body must reach the band unmangled. Covered in Task 1.

---

### Task 1: ADR reader

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.Docs.ps1`
- Test: `plugins/dev-tips/tests/DevTips.Docs.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-TipBody` from `hooks/DevTips.Discovery.ps1`.
- Produces: `Get-AdrTips([string]$Root)` returning tip objects with `id`, `kind = 'adr'`, `title`, `body`, `ref`, `repos = @('*')`, `maxShows = 1`, `source = 'docs'`. No `install` property, so `Get-InstallState` returns `n/a` and `New-TipText` takes its `default` branch — the one that already prints `Celé znenie: <ref>`.
- Also produces `Read-DocFrontMatter([string]$Text)` and `Get-SectionParagraph([string]$Text, [string]$HeadingPattern)`, used again in Task 2.

- [ ] **Step 1: Write the failing tests**

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Discovery.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Docs.ps1')
}

function New-Adr([string]$Dir, [string]$Name, [string]$Text)
{
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $Dir $Name) -Value $Text -Encoding UTF8
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

    It 'returns an empty array when the directory does not exist' {
        $tips = Get-AdrTips -Root (Join-Path (New-TempDir) 'no-such')

        ($tips -is [array]) | Should -BeTrue -Because 'callers consume it inline as @(Get-AdrTips ...)'
        @($tips).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/DevTips.Docs.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-AdrTips` is not recognised.

- [ ] **Step 3: Write the implementation**

```powershell
#!/usr/bin/env pwsh
# Documents that are rules rather than tools: ADRs and guidelines.
#
# The text is the document's own. A skill carries a `description`; an ADR carries a title and a
# decision, a guideline a heading and a first paragraph. Nobody writes a second copy of either -
# see D18. An optional `tip:` line in the document's front matter is the one exception, and it
# lives in the document, which is the whole point.

function Read-DocFrontMatter([string]$Text)
{
    $fm = [ordered]@{}
    if ($Text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---') { return [pscustomobject]$fm }

    foreach ($line in ($Matches[1] -split '\r?\n'))
    {
        if ($line -match '^\s*([A-Za-z][\w-]*)\s*:\s*(.*)$')
        {
            $fm[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim()
        }
    }
    return [pscustomobject]$fm
}

# The first paragraph under a heading, whatever that heading is called in this repository.
function Get-SectionParagraph([string]$Text, [string]$HeadingPattern)
{
    $m = [regex]::Match($Text, "(?ms)^##\s*(?:$HeadingPattern)\s*$(.*?)(?=^##\s|\z)")
    if (-not $m.Success) { return $null }

    foreach ($para in ($m.Groups[1].Value.Trim() -split '\r?\n\s*\r?\n'))
    {
        $flat = ($para -replace '\s+', ' ').Trim()
        if (-not [string]::IsNullOrWhiteSpace($flat)) { return $flat }
    }
    return $null
}

function Get-AdrTips([string]$Root)
{
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return @() }

    $tips = @()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.md' -File -ErrorAction SilentlyContinue)
    {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $fm = Read-DocFrontMatter $text
        $raw = if (-not [string]::IsNullOrWhiteSpace($fm.tip)) { $fm.tip }
               else { Get-SectionParagraph $text 'Rozhodnutie|Decision' }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $title = if (-not [string]::IsNullOrWhiteSpace($fm.title)) { $fm.title } else { $file.BaseName }

        $tips += [pscustomobject]@{
            id       = $file.BaseName
            kind     = 'adr'
            title    = $title
            body     = ConvertTo-TipBody $raw
            ref      = $file.Name
            repos    = @('*')
            maxShows = 1
            source   = 'docs'
        }
    }

    # No comma wrapper, for the reason spelled out in DevTips.RepoTips.ps1.
    return $tips
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/DevTips.Docs.Tests.ps1 -Output Detailed"`
Expected: 5 passed.

- [ ] **Step 5: Run it against the real ADRs, because a fixture always agrees with its author**

Run:
```bash
pwsh -NoProfile -Command ". ./hooks/DevTips.Discovery.ps1; . ./hooks/DevTips.Docs.ps1; \$t = @(Get-AdrTips -Root 'C:/Users/krajkovic/Documents/Projects/utils/Kros.ADR/Adrs'); \"tips=\$(\$t.Count)\"; \$t | Select-Object -First 5 id, @{n='len';e={\$_.body.Length}}, body | Format-Table -Wrap"
```
Expected: 20 tips, no body over 240 characters, each ending on a sentence, diacritics intact.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/hooks/DevTips.Docs.ps1 plugins/dev-tips/tests/DevTips.Docs.Tests.ps1
git commit -m "feat(dev-tips): read an ADR's own decision as the announcement"
```

---

### Task 2: Guideline reader

**Files:**
- Modify: `plugins/dev-tips/hooks/DevTips.Docs.ps1`
- Modify: `plugins/dev-tips/tests/DevTips.Docs.Tests.ps1`

**Interfaces:**
- Consumes: `Read-DocFrontMatter` and `ConvertTo-TipBody`.
- Produces: `Get-GuidelineTips([string]$RepoRoot)` returning tips with `id = "guideline-<basename>"`, `kind = 'guideline'`, `source = 'docs'`, `maxShows = 1`, and `ref` the repository-relative path.

- [ ] **Step 1: Write the failing tests**

```powershell
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

    It 'returns an empty array, not null, when the repository has no guidelines' {
        $tips = Get-GuidelineTips -RepoRoot (New-TempDir)

        ($tips -is [array]) | Should -BeTrue -Because '$null would unroll and the caller consumes this inline'
        @($tips).Count | Should -Be 0
    }

    It 'skips a file with a heading and nothing under it' {
        $repo = New-TempDir
        $dir = Join-Path $repo 'docs/guidelines'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'empty.md') -Value "# Len nadpis`n" -Encoding UTF8

        @(Get-GuidelineTips -RepoRoot $repo).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/DevTips.Docs.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-GuidelineTips` is not recognised.

- [ ] **Step 3: Write the implementation**

```powershell
function Get-GuidelineTips([string]$RepoRoot)
{
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return @() }
    $dir = Join-Path $RepoRoot 'docs/guidelines'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    $tips = @()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $fm = Read-DocFrontMatter $text
        $heading = [regex]::Match($text, '(?m)^#\s+(.+?)\s*$')
        $title = if (-not [string]::IsNullOrWhiteSpace($fm.title)) { $fm.title }
                 elseif ($heading.Success) { $heading.Groups[1].Value } else { $file.BaseName }

        $raw = $fm.tip
        if ([string]::IsNullOrWhiteSpace($raw) -and $heading.Success)
        {
            $after = $text.Substring($heading.Index + $heading.Length)
            foreach ($para in ($after.Trim() -split '\r?\n\s*\r?\n'))
            {
                $flat = ($para -replace '\s+', ' ').Trim()
                if ([string]::IsNullOrWhiteSpace($flat)) { continue }
                if ($flat.StartsWith('#')) { break }
                $raw = $flat
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $tips += [pscustomobject]@{
            id       = "guideline-$($file.BaseName)"
            kind     = 'guideline'
            title    = $title
            body     = ConvertTo-TipBody $raw
            ref      = "docs/guidelines/$($file.Name)"
            repos    = @('*')
            maxShows = 1
            source   = 'docs'
        }
    }

    return $tips
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/DevTips.Docs.Tests.ps1 -Output Detailed"`
Expected: 8 passed.

- [ ] **Step 5: Run it against the real guidelines**

Run:
```bash
pwsh -NoProfile -Command ". ./hooks/DevTips.Discovery.ps1; . ./hooks/DevTips.Docs.ps1; @(Get-GuidelineTips -RepoRoot 'C:/Users/krajkovic/Documents/Projects/Invoicing') | Select-Object id, title, body | Format-Table -Wrap"
```
Expected: 4 tips, each with a readable one-line body.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/hooks/DevTips.Docs.ps1 plugins/dev-tips/tests/DevTips.Docs.Tests.ps1
git commit -m "feat(dev-tips): read a guideline's own opening as the announcement"
```

---

### Task 3: Fetch the ADR repository in the refresh

**Files:**
- Modify: `plugins/dev-tips/hooks/Update-DevTipsData.ps1` — the parameter block at lines 10-18, and the refresh body beside the existing remote job
- Modify: `plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1`
- Modify: `plugins/dev-tips/tests/TestHelpers.ps1`

**Interfaces:**
- Consumes: `Invoke-MirrorFetch -MirrorPath -Origin -Branch` from `hooks/DevTips.Remote.ps1`, and `Test-StampStale` / `Update-Stamp` from `hooks/DevTips.Common.ps1`.
- Produces: a shallow mirror at `<StateDir>/adr`, refreshed on its own `adr` stamp, so `Get-AdrTips` has a root to read on every machine and not only where the repository happens to be cloned.

- [ ] **Step 1: Write the failing test**

Add to `TestHelpers.ps1`, modelled on the existing `New-FixtureOriginRepo`:

```powershell
function New-FixtureAdrRepo
{
    # A stand-in for Kros.ADR: a real git repo on disk, no network involved.
    $repo = New-TempDir
    $dir = Join-Path $repo 'Adrs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir '0001-prve.md') -Encoding UTF8 `
                -Value "---`ntitle: Prvé rozhodnutie`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

    git -C $repo init --quiet --initial-branch=master
    git -C $repo add -A
    git -C $repo -c user.email=t@t -c user.name=t commit --quiet -m 'adr'
    return $repo
}
```

and to `UpdateDevTipsData.Tests.ps1`:

```powershell
It 'fetches the ADR mirror on its own stamp' {
    $state = New-TempDir

    & $updateScript -StateDir $state -AdrOrigin (New-FixtureAdrRepo) -ProjectsRoot (New-TempDir)

    Test-Path -LiteralPath (Join-Path $state 'adr') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $state 'adr.stamp') | Should -BeTrue
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/UpdateDevTipsData.Tests.ps1 -Output Detailed"`
Expected: FAIL — no `adr` directory, and `-AdrOrigin` is not a known parameter.

- [ ] **Step 3: Implement**

Add to the parameter block:

```powershell
    [string]$AdrOrigin = 'https://github.com/Kros-sk/Kros.ADR.git',
    [string]$AdrBranch = 'master',
    [int]$AdrTtlHours = 24,
```

and, beside the existing remote job, a job that guards itself the same way:

```powershell
    # Its own stamp, like every other job: a failing ADR fetch must not cost the tip refresh.
    if (Test-StampStale -StateDir $StateDir -Name 'adr' -Hours $AdrTtlHours)
    {
        try
        {
            if (Invoke-MirrorFetch -MirrorPath (Join-Path $StateDir 'adr') -Origin $AdrOrigin -Branch $AdrBranch)
            {
                Update-Stamp -StateDir $StateDir -Name 'adr'
                Write-Log 'refresh: adr mirror fetched'
            }
            else
            {
                Write-Log "refresh: adr fetch failed | origin=$AdrOrigin"
            }
        }
        catch
        {
            Write-Log ('refresh: adr fetch failed | {0}' -f $_.Exception.Message)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/UpdateDevTipsData.Tests.ps1 -Output Detailed"`
Expected: all passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-tips/hooks/Update-DevTipsData.ps1 plugins/dev-tips/tests
git commit -m "feat(dev-tips): keep a mirror of the ADR repository beside the tips one"
```

---

### Task 4: Wire the documents in, and baseline what already exists

**Files:**
- Modify: `plugins/dev-tips/hooks/DevTips.Catalog.ps1` — after the `$discovered` block
- Modify: `plugins/dev-tips/hooks/DevTips.Docs.ps1` — add `Initialize-DocsBaseline`
- Modify: `plugins/dev-tips/hooks/Show-DevTip.ps1` and `hooks/Show-Candidate.ps1` — dot-source `DevTips.Docs.ps1`
- Modify: `plugins/dev-tips/catalog/config.json`
- Modify: `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `Get-AdrTips`, `Get-GuidelineTips`.
- Produces: document tips in `Get-TipCatalog`'s result, and `Initialize-DocsBaseline -StateDir -Tips -AnnounceAnyway`, which writes `shown.json` entries for every document that exists at switch-on, exactly once.

**Config added to `catalog/config.json`:**

```json
{
  "cooldownDays": 2,
  "candidateCooldownHours": 12,
  "delivery": "band",
  "authoredTips": false,
  "announceDocs": true,
  "announceAnyway": [
    "0018-CompanyId-vs-TenantId",
    "0021-Nepouzivame-ApplicationType-v-novych-castiach"
  ]
}
```

These are the file base names as they stand in `Kros.ADR/Adrs` today, and they are the two ADRs measured as the most violated — left to announce although they predate the switch-on. An id that matches no document is ignored, which is the harmless direction to fail in, but it also silently delivers nothing: if the ADR repository renames a file, this list goes stale without saying so. Check both names against the mirror when implementing.

- [ ] **Step 1: Write the failing tests**

```powershell
Describe 'Get-TipCatalog with documents' {
    It 'carries ADR tips when announceDocs is on' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ authoredTips = $false; announceDocs = $true }
        $state = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $state 'adr/Adrs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'adr/Adrs/0001-x.md') -Encoding UTF8 `
                    -Value "---`ntitle: Prvé`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

        $result = Get-TipCatalog -StateDir $state -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

        @($result.tips | Where-Object { $_.kind -eq 'adr' }).Count | Should -Be 1
    }

    It 'carries no documents when announceDocs is off' {
        $pluginRoot = New-FakePluginRoot -Tips @{ id = 'alpha'; title = 'A'; body = 'b'; repos = @('*') } `
                                        -Config @{ authoredTips = $false; announceDocs = $false }
        $state = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $state 'adr/Adrs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'adr/Adrs/0001-x.md') -Encoding UTF8 `
                    -Value "---`ntitle: Prvé`n---`n`n## Rozhodnutie`n`nRobíme to takto.`n"

        $result = Get-TipCatalog -StateDir $state -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests/DevTips.Catalog.Tests.ps1 -Output Detailed"`
Expected: FAIL on all five.

- [ ] **Step 3: Implement**

In `DevTips.Catalog.ps1`, after the `$discovered` block:

```powershell
    # Documents are announcements, not tips: `maxShows = 1` and no usage suppression, because
    # nobody "already uses" a rule. They ride the same single notice per cooldown - the baseline
    # is what keeps the backlog from eating it.
    if ($null -eq $config.announceDocs -or [bool]$config.announceDocs)
    {
        $docs = @()
        try { $docs += @(Get-AdrTips -Root (Join-Path $StateDir 'adr/Adrs')) } catch { }
        try { $docs += @(Get-GuidelineTips -RepoRoot $RepoRoot) } catch { }

        if ($docs.Count -gt 0)
        {
            Initialize-DocsBaseline -StateDir $StateDir -Tips $docs -AnnounceAnyway @($config.announceAnyway)
            $discovered = @($discovered) + @($docs)
        }
    }
```

In `DevTips.Docs.ps1`:

```powershell
# Everything that exists the first time this runs is history, not news. Without it, switching the
# channel on would queue 26 announcements and the skills would not get a turn for two months.
#
# Once only, and for the same reason the state merge is once only: a second pass would silence
# every document written since the first, and those are exactly the ones worth announcing.
function Initialize-DocsBaseline([string]$StateDir, $Tips, [string[]]$AnnounceAnyway)
{
    $marker = Join-Path $StateDir '.docs-baseline'
    if (Test-Path -LiteralPath $marker) { return }

    $keep = @{}
    $shown = Read-JsonFile (Join-Path $StateDir 'shown.json')
    if ($null -ne $shown -and $null -ne $shown.entries)
    {
        foreach ($p in $shown.entries.PSObject.Properties) { $keep[$p.Name] = $p.Value }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $spare = @($AnnounceAnyway)
    foreach ($tip in @($Tips))
    {
        if ($spare -contains $tip.id) { continue }
        if ($keep.ContainsKey($tip.id)) { continue }

        $max = if ($null -ne $tip.maxShows) { [int]$tip.maxShows } else { 1 }
        $keep[$tip.id] = [pscustomobject]@{ count = $max; last = $now; firstSeen = $now }
    }

    Write-JsonFile (Join-Path $StateDir 'shown.json') ([pscustomobject]@{
        lastShownAt     = if ($null -ne $shown) { $shown.lastShownAt } else { $null }
        lastCandidateAt = if ($null -ne $shown) { $shown.lastCandidateAt } else { $null }
        entries         = [pscustomobject]$keep
    })

    $now | Set-Content -LiteralPath $marker -Encoding UTF8
}
```

- [ ] **Step 4: Run the whole PowerShell suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"`
Expected: every test passes, the existing 69 included.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-tips/hooks plugins/dev-tips/tests plugins/dev-tips/catalog/config.json
git commit -m "feat(dev-tips): announce a new ADR or guideline once, and only a new one"
```

---

### Task 5: The band says the right thing about a document

**Files:**
- Modify: `plugins/dev-tips/hooks/band/register.tsx` — the button row and `recordAnswer`
- Modify: `plugins/dev-tips/hooks/band/band.test.tsx`

**Interfaces:**
- Consumes: `Pending.kind` from the handshake. Confirm `Write-PendingTip.ps1` already writes `kind` before changing anything — it does today, at `hooks/Write-PendingTip.ps1`.
- Produces: no new exports. `recordAnswer` stops writing `usage.json` for a document.

- [ ] **Step 1: Write the failing tests**

```tsx
const DOC = {
  id: '0018-CompanyId',
  kind: 'adr',
  title: 'CompanyId vs TenantId',
  body: 'CompanyId identifikuje spoločnosť, TenantId zákazníka.',
  ref: '0018-CompanyId.md',
  url: null,
  installState: 'n/a',
  stateDir: `${HOME}/.claude/plugins/data/dev-tips-state`,
}

test('a document is offered to be read, not to be run', async ($, on) => {
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })

  expect(await ui.find({ type: 'Button', label: 'Už to používam' })).toBeUndefined()
  expect(await ui.find({ type: 'Button', label: 'Poznám' })).toBeDefined()
  expect(await ui.find({ type: 'Button', label: 'Vysvetli mi to' })).toBeDefined()

  await ui.unmount()
})

test('knowing a rule writes no usage suppression, because a rule is not a tool', async ($, on) => {
  const writes = writesOf(on)
  await given($, on, DOC)

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'known' })
  await ui.unmount()

  expect(writes[`${DOC.stateDir}/usage.json`]).toBeUndefined()
  expect(writes[`${DOC.stateDir}/answers.log`]).toBeDefined()
})
```

- [ ] **Step 2: Run them to verify they fail**

Run: `claude plugin test .`
Expected: FAIL — the labels are the skill ones, and `usage.json` is written.

- [ ] **Step 3: Implement**

Inside the render hook, beside the other derived values:

```tsx
  // A rule is not a tool: it is not run, and nobody "already uses" it. Same two presses, so the
  // answers stay comparable across kinds, but the words have to be true.
  const isDoc = pending.kind === 'adr' || pending.kind === 'guideline'
```

```tsx
            <Button key="show" label={isDoc ? 'Vysvetli mi to' : 'Ukáž ako'} hotkey="3" onPress={() => choose('show')} />
            <Button key="known" label={isDoc ? 'Poznám' : 'Už to používam'} hotkey="4" onPress={() => choose('known')} />
```

and in `recordAnswer`, where it currently returns early for anything but `known`:

```tsx
  // Usage suppression answers "do not offer me a tool I already run". A rule has nothing to run,
  // and `maxShows: 1` already keeps it from coming back.
  const isDoc = pending.kind === 'adr' || pending.kind === 'guideline'
  if (answer !== 'known' || isDoc) return
```

- [ ] **Step 4: Run the module tests**

Run: `claude plugin test .`
Expected: 18 pass, 0 fail.

- [ ] **Step 5: Validate and run everything**

Run: `claude plugin validate . && pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output None -PassThru | Select-Object PassedCount, FailedCount"`
Expected: validation passes, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/hooks/band
git commit -m "feat(dev-tips): ask about a rule in words that are true of a rule"
```

---

### Task 6: Record the decision and retire the validator

**Files:**
- Modify: `plugins/dev-tips/docs/catalog-distribution-analysis.md` — new D18, inserted before `## Riziká`
- Modify: `plugins/dev-tips/docs/catalog-distribution.md`
- Delete: `plugins/dev-tips/tools/Test-TipFiles.ps1`, `plugins/dev-tips/tests/TestTipFiles.Tests.ps1`, and the `dev-tips-validate.yml` workflow in the Kros.AiDevTools pull request

- [ ] **Step 1: Write D18**

In the register's voice and in Slovak, it must say: that the authored tip file is retired, and why — a skill carries its own `description`, the catalog shipped eight authored tips and not one `*.tip.json` was ever written, so the channel cost work and delivered nothing; that the text of a rule comes from the rule itself, with the measurements in this plan's header as the evidence that it reads; that an announcement is made once (`maxShows = 1`), and that everything existing at switch-on is baselined as history with `announceAnyway` as the named exception; and that D1, D2 and D10 are superseded by it.

- [ ] **Step 2: Delete the validator and its test**

```bash
git rm plugins/dev-tips/tools/Test-TipFiles.ps1 plugins/dev-tips/tests/TestTipFiles.Tests.ps1
```

- [ ] **Step 3: Run the suite to prove nothing depended on it**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output None -PassThru | Select-Object PassedCount, FailedCount"`
Expected: 0 failed.

- [ ] **Step 4: Commit**

```bash
git add plugins/dev-tips/docs
git commit -m "docs(dev-tips): retire the authored tip file, as D18"
```
