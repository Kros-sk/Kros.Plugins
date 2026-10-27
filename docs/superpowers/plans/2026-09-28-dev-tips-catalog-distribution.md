# dev-tips catalog distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tip content reach developers without anyone running `plugin update`, by replacing the packaged catalog with three sources resolved at runtime.

**Architecture:** A single seam — `Get-TipCatalog` — replaces every direct read of `catalog/tips.json`. Behind it sit three sources: local discovery of installed tools, `.dev-tips/` in the working repository, and a background-refreshed snapshot of authored `tip.json` files fetched from `Kros.AiDevTools`. Nothing is generated or published; the refresh reads source files from a shallow git mirror, derives the missing fields and writes one merged snapshot that `SessionStart` opens.

**Tech Stack:** PowerShell 7.6.6, Pester 5.9.1, git 2.x, GitHub Actions (one validation workflow, in another repository).

**Spec:** `plugins/dev-tips/docs/catalog-distribution.md`, with the reasoning in `plugins/dev-tips/docs/catalog-distribution-analysis.md`.

## Global Constraints

- Every hook swallows errors and **exits 0**. A broken tip must never block a session. `Update-DevTipsData.ps1` is not a hook and may exit non-zero.
- Every run appends a line to `$StateDir/debug.log`. Silence must mean *did not run*, never *ran and did nothing*.
- `SessionStart` never touches the network and never opens the git mirror. It reads `remote-tips.json` and local state only.
- Fetched configuration is used **as given**. No clamping to bounds.
- `Update-DevTipsData.ps1` requires `-StateDir`. It has no fallback and must not call `Get-StateDir`.
- The detached refresh is spawned with `-WindowStyle Hidden`, never `-NoNewWindow`.
- Any file the refresh writes is written to a temp path and moved into place. Never a direct write.
- Every `git` invocation in the refresh runs with `GIT_TERMINAL_PROMPT=0`, `-c credential.interactive=false`, `-c core.askPass=`.
- Shipping any change means bumping `version` in **both** `plugins/dev-tips/.claude-plugin/plugin.json` and the matching entry in `.claude-plugin/marketplace.json`.
- Tests live in `plugins/dev-tips/tests/`, are named `*.Tests.ps1`, and must pass without network access.

## File Structure

Paths are relative to the repository root, `C:\Users\krajkovic\Documents\Projects\Kros.Plugins`.

**Created:**

| File | Responsibility |
|---|---|
| `plugins/dev-tips/hooks/DevTips.Catalog.ps1` | `Get-TipCatalog` and `Merge-Tips` — the seam and the precedence rules |
| `plugins/dev-tips/hooks/DevTips.Discovery.ps1` | channel A: what is installed on this machine |
| `plugins/dev-tips/hooks/DevTips.RepoTips.ps1` | channel B: `.dev-tips/` in the working repository |
| `plugins/dev-tips/hooks/DevTips.Remote.ps1` | channel C: mirror, fetch, derive, snapshot |
| `plugins/dev-tips/hooks/DevTips.History.ps1` | what the developer used before the plugin existed |
| `plugins/dev-tips/hooks/Update-DevTipsData.ps1` | the detached refresh entry point, one job per data source |
| `plugins/dev-tips/tools/Test-TipFiles.ps1` | validator, to be run by CI in `Kros.AiDevTools` |
| `plugins/dev-tips/tools/dev-tips-validate.yml` | the workflow that calls it, to be copied into that repository |
| `plugins/dev-tips/tests/TestHelpers.ps1` | fixture builders shared by the test files |
| `plugins/dev-tips/tests/*.Tests.ps1` | one per source file above |

**Modified:** `Show-DevTip.ps1` and `Test-TurnForSkills.ps1` (both stop reading `catalog/tips.json` directly), `catalog/config.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `plugins/dev-tips/README.md`.

`DevTips.Common.ps1` is not restructured. New behaviour goes in new files; it keeps the helpers it has.

## Phase boundary

Tasks 1–6 need no network and touch no other repository. Tasks 7–10 add the remote source. The two halves can be executed as separate sessions; after Task 6 the plugin is coherent and shippable on its own.

---

### Task 1: Ship a usable cooldown

**Files:**
- Modify: `plugins/dev-tips/catalog/config.json`
- Test: `plugins/dev-tips/tests/Config.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other code calls. This task exists so the shipped default stops being a test value.

- [ ] **Step 1: Install the test framework**

```bash
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -Scope CurrentUser -Force -SkipPublisherCheck"
```

Expected: completes without error. Verify with:

```bash
pwsh -NoProfile -Command "(Get-Module -ListAvailable Pester | Where-Object { \/c/Users/krajkovic/Documents/Projects/Kros.Plugins.Version -ge [version]'5.0' } | Select-Object -First 1).Version.ToString()"
```

Expected: `5.9.1` or another 5.x version.

- [ ] **Step 2: Write the failing test**

Create `plugins/dev-tips/tests/Config.Tests.ps1`:

```powershell
BeforeAll {
    $script:ConfigPath = Join-Path $PSScriptRoot '../catalog/config.json'
}

Describe 'Shipped config.json' {
    It 'does not ship test cooldowns' {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.cooldownDays | Should -BeGreaterOrEqual 1
        $config.candidateCooldownHours | Should -BeGreaterOrEqual 1
    }
}
```

- [ ] **Step 3: Run it to make sure it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/Config.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `Expected 0 to be greater than or equal to 1`.

- [ ] **Step 4: Fix the shipped values**

`plugins/dev-tips/catalog/config.json`:

```json
{
  "cooldownDays": 2,
  "candidateCooldownHours": 12
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/Config.Tests.ps1 -Output Detailed"
```

Expected: PASS, 1 test.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/catalog/config.json plugins/dev-tips/tests/Config.Tests.ps1
git commit -m "fix(dev-tips): ship real cooldowns instead of test values"
```

---

### Task 2: The `Get-TipCatalog` seam

Both hooks read `catalog/tips.json` directly today. Route them through one function first, with no behaviour change, so every later task has one place to extend.

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.Catalog.ps1`
- Create: `plugins/dev-tips/tests/TestHelpers.ps1`
- Create: `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`
- Modify: `plugins/dev-tips/hooks/Show-DevTip.ps1:27-32`
- Modify: `plugins/dev-tips/hooks/Test-TurnForSkills.ps1:29-30`

**Interfaces:**
- Consumes: `Read-JsonFile`, `Get-PluginRoot` from `DevTips.Common.ps1`.
- Produces: `Get-TipCatalog([string]$StateDir, [string]$PluginRoot, [string]$PluginsRoot, [string]$RepoRoot)` returning `[pscustomobject]@{ tips = @(...); config = [pscustomobject] }`. `tips` is an array in the shape the hooks already iterate: objects with `id`, `kind`, `title`, `body`, `ref`, `repos`, `maxShows`, `install`, optional `when`, `expires`, `suppressIfUsed`. `config` carries `cooldownDays`, `candidateCooldownHours`, `ttlHours`, `enabled`.

- [ ] **Step 1: Write the fixture helper**

Create `plugins/dev-tips/tests/TestHelpers.ps1`:

```powershell
function New-TempDir
{
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('devtips-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-FakePluginRoot([hashtable]$Tips, [hashtable]$Config)
{
    $root = New-TempDir
    New-Item -ItemType Directory -Path (Join-Path $root 'catalog') -Force | Out-Null
    $catalog = [pscustomobject]@{ version = 2; tips = @($Tips) }
    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'catalog/tips.json') -Encoding UTF8
    ([pscustomobject]$Config) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'catalog/config.json') -Encoding UTF8
    return $root
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`:

```powershell
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
```

- [ ] **Step 3: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `The term 'Get-TipCatalog' is not recognized`.

- [ ] **Step 4: Write the minimal implementation**

Create `plugins/dev-tips/hooks/DevTips.Catalog.ps1`:

```powershell
#!/usr/bin/env pwsh
# The one place tips come from. Hooks must not read catalog files directly.

function Get-TipCatalog([string]$StateDir, [string]$PluginRoot)
{
    if ([string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot = Get-PluginRoot }

    $packaged = Read-JsonFile (Join-Path $PluginRoot 'catalog/tips.json')
    $tips = @()
    if ($null -ne $packaged -and $null -ne $packaged.tips) { $tips = @($packaged.tips) }

    $config = Read-JsonFile (Join-Path $PluginRoot 'catalog/config.json')
    if ($null -eq $config) { $config = [pscustomobject]@{} }

    return [pscustomobject]@{ tips = $tips; config = $config }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1 -Output Detailed"
```

Expected: PASS, 2 tests.

- [ ] **Step 6: Rewire `Show-DevTip.ps1`**

Dot-source the new file next to the existing one, near the top of the script:

```powershell
. (Join-Path $PSScriptRoot 'DevTips.Catalog.ps1')
```

Replace the catalog and config reads (the block starting `$catalog = Read-JsonFile (Join-Path $pluginRoot 'catalog/tips.json')` down to the `$cooldownDays = ...` line) with:

```powershell
    $catalog = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)
    if ($catalog.tips.Count -eq 0)
    {
        Write-Log 'exit: catalog missing or empty'
        exit 0
    }

    $config = $catalog.config
    $cooldownDays = if ($null -ne $config.cooldownDays) { [int]$config.cooldownDays } else { 2 }
```

- [ ] **Step 7: Rewire `Test-TurnForSkills.ps1`**

Dot-source `DevTips.Catalog.ps1` alongside `DevTips.Common.ps1`, then replace:

```powershell
    $catalog = Read-JsonFile (Join-Path (Get-PluginRoot) 'catalog/tips.json')
    if ($null -eq $catalog -or $null -eq $catalog.tips) { exit 0 }
```

with:

```powershell
    $catalog = Get-TipCatalog -StateDir $stateDir -PluginRoot (Get-PluginRoot)
    if ($catalog.tips.Count -eq 0) { exit 0 }
```

- [ ] **Step 8: Verify the hooks still behave**

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force
```

Expected: JSON on stdout containing a tip, exactly as before the change.

- [ ] **Step 9: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "refactor(dev-tips): route both hooks through Get-TipCatalog"
```

---

### Task 3: Backfill skill usage from the transcript history

`Record-SkillUse.ps1` only ever sees the future. Somebody who has used `/commit` for two months
installs the plugin and is told about `/commit` — one experience, and the plugin is off for good.
Claude Code has already written the past to disk: every skill invocation appears in
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` as `"name":"Skill","input":{"skill":"..."}`,
with a `timestamp` on the line.

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.History.ps1`
- Create: `plugins/dev-tips/hooks/Update-DevTipsData.ps1`
- Create: `plugins/dev-tips/tests/DevTips.History.Tests.ps1`
- Create: `plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1`
- Modify: `plugins/dev-tips/hooks/DevTips.Common.ps1` (three helpers appended)
- Modify: `plugins/dev-tips/hooks/Test-TurnForSkills.ps1`
- Modify: `plugins/dev-tips/tests/TestHelpers.ps1`

**Interfaces:**
- Consumes: `Read-JsonFile`, `Write-JsonFile`, `Write-Log` from `DevTips.Common.ps1`.
- Produces:
  - `Get-HistoricalSkillUse([string]$ProjectsRoot, [datetime]$Since)` → hashtable, key = skill name,
    value = `[pscustomobject]@{ count; last }`. A plugin-qualified name is recorded under **both**
    `kros-shared:git-diff` and `git-diff`, because `Test-AlreadyUsed` matches either form.
  - `Merge-UsageFile([string]$StateDir, [hashtable]$Found)` → folds the result into `usage.json`
    without overwriting what `Record-SkillUse.ps1` recorded live.
  - `Test-StampStale([string]$StateDir, [string]$Name, [int]$Hours)` and
    `Update-Stamp([string]$StateDir, [string]$Name)` — per-job staleness, reused by Task 8.
  - `Start-DataRefresh([string]$StateDir, [string]$HookRoot)` — spawns the detached process.
  - `Update-DevTipsData.ps1 -StateDir <path> [-ProjectsRoot <path>]` — exit 0 on success, 1 when
    `-StateDir` is missing, 2 when the lock is held.

- [ ] **Step 1: Extend the fixture helper**

Append to `plugins/dev-tips/tests/TestHelpers.ps1`:

```powershell
function New-FakeTranscripts
{
    # Two skill invocations and one line that is not one, in the layout Claude Code uses.
    $root = New-TempDir
    $project = Join-Path $root 'C--Users-someone-Projects-Invoicing'
    New-Item -ItemType Directory -Path $project -Force | Out-Null

    @(
        '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"kros-shared:git-diff"}}]}}'
        '{"type":"assistant","timestamp":"2026-09-02T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"kros-shared:git-diff"}}]}}'
        '{"type":"user","timestamp":"2026-09-02T10:01:00.000Z","message":{"content":"no skill here"}}'
    ) | Set-Content -LiteralPath (Join-Path $project 'session-1.jsonl') -Encoding UTF8

    return $root
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/dev-tips/tests/DevTips.History.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.History.ps1')
}

Describe 'Get-HistoricalSkillUse' {
    It 'records a qualified skill under both the qualified and the bare name' {
        $found = Get-HistoricalSkillUse -ProjectsRoot (New-FakeTranscripts) -Since ([datetime]'2000-01-01')

        $found['kros-shared:git-diff'].count | Should -Be 2
        $found['git-diff'].count | Should -Be 2
        $found['git-diff'].last | Should -BeGreaterThan ([datetime]'2026-09-01T12:00:00Z')
    }

    It 'skips transcripts older than the window' {
        $root = New-FakeTranscripts
        Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -Recurse | ForEach-Object {
            $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-200)
        }

        $found = Get-HistoricalSkillUse -ProjectsRoot $root -Since ((Get-Date).ToUniversalTime().AddDays(-90))

        $found.Keys.Count | Should -Be 0
    }

    It 'returns an empty result when the projects directory does not exist' {
        (Get-HistoricalSkillUse -ProjectsRoot 'C:\no\such\dir' -Since ([datetime]'2000-01-01')).Keys.Count |
            Should -Be 0
    }
}

Describe 'Merge-UsageFile' {
    It 'adds historical names without discarding live records' {
        $stateDir = New-TempDir
        ([pscustomobject]@{ 'push' = '2026-09-20T00:00:00.0000000Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Encoding UTF8

        $found = @{ 'git-diff' = [pscustomobject]@{ count = 2; last = [datetime]'2026-09-02T10:00:00Z' } }
        Merge-UsageFile -StateDir $stateDir -Found $found | Out-Null

        $usage = Get-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Raw | ConvertFrom-Json
        $usage.push | Should -Not -BeNullOrEmpty
        $usage.'git-diff' | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.History.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Get-HistoricalSkillUse' is not recognized`.

- [ ] **Step 4: Write the scanner**

Create `plugins/dev-tips/hooks/DevTips.History.ps1`:

```powershell
#!/usr/bin/env pwsh
# What the developer used BEFORE this plugin existed. Record-SkillUse.ps1 only sees the future;
# the transcripts hold the past. Never call this from a hook - the directory runs to hundreds of
# megabytes. It belongs in the detached refresh.

function Get-HistoricalSkillUse([string]$ProjectsRoot, [datetime]$Since)
{
    $found = @{}
    if (-not (Test-Path -LiteralPath $ProjectsRoot)) { return $found }

    $files = @(Get-ChildItem -LiteralPath $ProjectsRoot -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $files)
    {
        if ($file.LastWriteTimeUtc -lt $Since) { continue }

        # ReadLines streams; Get-Content -Raw on this directory would load it all into memory.
        foreach ($line in [System.IO.File]::ReadLines($file.FullName))
        {
            if ($line -notlike '*"name":"Skill"*') { continue }
            if ($line -notmatch '"skill"\s*:\s*"([^"]+)"') { continue }
            $name = $Matches[1]

            $when = $file.LastWriteTimeUtc
            if ($line -match '"timestamp"\s*:\s*"([^"]+)"')
            {
                try { $when = ([datetime]$Matches[1]).ToUniversalTime() } catch { }
            }

            $keys = @($name)
            if ($name -match ':') { $keys += ($name -split ':', 2)[1] }

            foreach ($key in $keys)
            {
                if (-not $found.ContainsKey($key))
                {
                    $found[$key] = [pscustomobject]@{ count = 0; last = [datetime]::MinValue }
                }
                $found[$key].count++
                if ($when -gt $found[$key].last) { $found[$key].last = $when }
            }
        }
    }
    return $found
}

function Merge-UsageFile([string]$StateDir, [hashtable]$Found)
{
    $path = Join-Path $StateDir 'usage.json'
    $usage = Read-JsonFile $path
    if ($null -eq $usage) { $usage = [pscustomobject]@{} }

    foreach ($key in $Found.Keys)
    {
        # A live record from Record-SkillUse.ps1 always wins: it is first-hand, this is inference.
        if ($null -ne $usage.PSObject.Properties[$key]) { continue }
        $usage | Add-Member -NotePropertyName $key `
                            -NotePropertyValue ($Found[$key].last.ToString('o')) -Force
    }

    Write-JsonFile $path $usage
    return $usage
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.History.Tests.ps1 -Output Detailed"
```

Expected: PASS, 4 tests.

- [ ] **Step 6: Add the shared refresh helpers**

Append to `plugins/dev-tips/hooks/DevTips.Common.ps1`:

```powershell
function Test-StampStale([string]$StateDir, [string]$Name, [int]$Hours)
{
    $path = Join-Path $StateDir "$Name.stamp"
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return ($age.TotalHours -ge $Hours)
}

function Update-Stamp([string]$StateDir, [string]$Name)
{
    (Get-Date).ToUniversalTime().ToString('o') |
        Set-Content -LiteralPath (Join-Path $StateDir "$Name.stamp") -Encoding UTF8
}

function Start-DataRefresh([string]$StateDir, [string]$HookRoot)
{
    # -WindowStyle Hidden, never -NoNewWindow: the child must not inherit the hook's stdout, which
    # Claude Code parses as JSON.
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', (Join-Path $HookRoot 'Update-DevTipsData.ps1'),
        '-StateDir', $StateDir) | Out-Null
}
```

- [ ] **Step 7: Write the failing test for the entry point**

Create `plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1`:

```powershell
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
```

- [ ] **Step 8: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1 -Output Detailed"
```

Expected: FAIL — the script does not exist.

- [ ] **Step 9: Write the entry point**

Create `plugins/dev-tips/hooks/Update-DevTipsData.ps1`:

```powershell
#!/usr/bin/env pwsh
# The detached refresh. Not a hook: it may exit non-zero, and nothing waits for it.
#
# -StateDir is mandatory and has NO fallback. Guessing it would write to a directory SessionStart
# does not read, and the failure would be invisible: the log would report success.
#
# Each job guards itself with its own stamp, so one failing job never blocks another.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StateDir,
    [string]$ProjectsRoot,
    [int]$HistoryWindowDays = 90,
    [int]$HistoryTtlHours = 24,
    [int]$LockStaleMinutes = 30
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')
. (Join-Path $PSScriptRoot 'DevTips.History.ps1')

if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
Initialize-Log $StateDir

if ([string]::IsNullOrWhiteSpace($ProjectsRoot))
{
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $ProjectsRoot = Join-Path $userHome '.claude/projects'
}

$lock = Join-Path $StateDir 'refresh.lock'
if (Test-Path -LiteralPath $lock)
{
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lock).LastWriteTimeUtc
    if ($age.TotalMinutes -lt $LockStaleMinutes)
    {
        Write-Log ('refresh: lock held, {0:N1} min old' -f $age.TotalMinutes)
        exit 2
    }
    Write-Log ('refresh: breaking stale lock, {0:N1} min old' -f $age.TotalMinutes)
    Remove-Item -LiteralPath $lock -Force
}

try
{
    $PID | Set-Content -LiteralPath $lock -Encoding UTF8

    if (Test-StampStale -StateDir $StateDir -Name 'history' -Hours $HistoryTtlHours)
    {
        try
        {
            $since = (Get-Date).ToUniversalTime().AddDays(-$HistoryWindowDays)
            $found = Get-HistoricalSkillUse -ProjectsRoot $ProjectsRoot -Since $since
            Merge-UsageFile -StateDir $StateDir -Found $found | Out-Null
            Update-Stamp -StateDir $StateDir -Name 'history'
            Write-Log ('refresh: history scanned | names={0}' -f $found.Keys.Count)
        }
        catch
        {
            Write-Log ('refresh: history scan failed | {0}' -f $_.Exception.Message)
        }
    }
    else
    {
        Write-Log 'refresh: history stamp fresh, skipped'
    }

    exit 0
}
catch
{
    Write-Log ("refresh ERROR: {0} | at {1}:{2}" -f $_.Exception.Message,
        $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
    exit 3
}
finally
{
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 10: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1 -Output Detailed"
```

Expected: PASS, 5 tests.

- [ ] **Step 11: Spawn it from the Stop hook**

In `Test-TurnForSkills.ps1`, immediately after `Initialize-Log $stateDir` and **before** the ledger is
read, add:

```powershell
    if (Test-StampStale -StateDir $stateDir -Name 'refresh' -Hours 6)
    {
        Update-Stamp -StateDir $stateDir -Name 'refresh'
        Start-DataRefresh -StateDir $stateDir -HookRoot $PSScriptRoot
        Write-Log 'stop: data refresh spawned'
    }
```

This is the first thing the hook does, because it runs after every turn. One spawn gate here; each
job inside the refresh decides for itself whether it is due.

- [ ] **Step 12: Verify against the real transcripts**

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Update-DevTipsData.ps1 -StateDir "$env:USERPROFILE/.claude/plugins/data/dev-tips-local"
```

Then read the result:

```bash
pwsh -NoProfile -Command "Get-Content \"$env:USERPROFILE/.claude/plugins/data/dev-tips-local/usage.json\" -Raw"
```

Expected: names such as `new-worktree`, `create-pr-description` and `commit` are present, so the tips
for those tools will never be offered on this machine. The scan only reads; it writes nothing outside
`$StateDir`.

- [ ] **Step 13: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): backfill skill usage from the transcript history"
```

---

### Task 4: Channel A — discover what is installed

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.Discovery.ps1`
- Create: `plugins/dev-tips/tests/DevTips.Discovery.Tests.ps1`
- Modify: `plugins/dev-tips/tests/TestHelpers.ps1`

**Interfaces:**
- Consumes: `Read-JsonFile`, `Test-AlreadyUsed` from `DevTips.Common.ps1`.
- Produces:
  - `Read-SkillFrontmatter([string]$Path)` → `[pscustomobject]@{ name; description }` or `$null`.
  - `Get-DiscoveredTips([string]$StateDir, [string]$PluginsRoot)` → array of tip objects with `id`, `kind`, `title`, `body`, `ref`, `repos`, `maxShows`, `install`, `suppressIfUsed`, `source = 'discovered'`.

- [ ] **Step 1: Extend the fixture helper**

Append to `plugins/dev-tips/tests/TestHelpers.ps1`:

```powershell
function New-FakePluginsRoot
{
    # Builds ~/.claude/plugins with one installed plugin carrying one skill.
    $root = New-TempDir
    $installPath = Join-Path $root 'cache/kros-ai-dev-tools/kros-shared/abc123'
    New-Item -ItemType Directory -Path (Join-Path $installPath 'skills/git-diff') -Force | Out-Null

    @(
        '---'
        'name: git-diff'
        'description: Analyze git changes against master.'
        '---'
        ''
        'body text'
    ) | Set-Content -LiteralPath (Join-Path $installPath 'skills/git-diff/SKILL.md') -Encoding UTF8

    $installed = [pscustomobject]@{
        version = 2
        plugins = [pscustomobject]@{
            'kros-shared@kros-ai-dev-tools' = @(
                [pscustomobject]@{ scope = 'user'; installPath = $installPath; version = 'abc123' }
            )
        }
    }
    $installed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'installed_plugins.json') -Encoding UTF8
    return $root
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/dev-tips/tests/DevTips.Discovery.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Discovery.ps1')
}

Describe 'Read-SkillFrontmatter' {
    It 'reads name and description' {
        $pluginsRoot = New-FakePluginsRoot
        $skill = Get-ChildItem -Path $pluginsRoot -Filter 'SKILL.md' -Recurse | Select-Object -First 1

        $fm = Read-SkillFrontmatter $skill.FullName

        $fm.name | Should -Be 'git-diff'
        $fm.description | Should -Be 'Analyze git changes against master.'
    }

    It 'returns null for a file with no frontmatter' {
        $path = Join-Path (New-TempDir) 'SKILL.md'
        'no frontmatter here' | Set-Content -LiteralPath $path -Encoding UTF8

        Read-SkillFrontmatter $path | Should -BeNullOrEmpty
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

    It 'skips a skill the developer has already used' {
        $stateDir = New-TempDir
        ([pscustomobject]@{ 'kros-shared:git-diff' = '2026-09-01T00:00:00Z' }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'usage.json') -Encoding UTF8

        $tips = Get-DiscoveredTips -StateDir $stateDir -PluginsRoot (New-FakePluginsRoot)

        $tips.Count | Should -Be 0
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Discovery.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Read-SkillFrontmatter' is not recognized`.

- [ ] **Step 4: Write the implementation**

Create `plugins/dev-tips/hooks/DevTips.Discovery.ps1`:

```powershell
#!/usr/bin/env pwsh
# Channel A: tips about tools that are already on this machine. Needs no catalog and no network.

function Read-SkillFrontmatter([string]$Path)
{
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $null }

    $name = $null
    $description = $null
    for ($i = 1; $i -lt $lines.Count; $i++)
    {
        if ($lines[$i].Trim() -eq '---') { break }
        if ($lines[$i] -match '^name:\s*(.+)$') { $name = $Matches[1].Trim() }
        elseif ($lines[$i] -match '^description:\s*(.+)$') { $description = $Matches[1].Trim() }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return [pscustomobject]@{ name = $name; description = $description }
}

function Get-DiscoveredTips([string]$StateDir, [string]$PluginsRoot)
{
    $installed = Read-JsonFile (Join-Path $PluginsRoot 'installed_plugins.json')
    if ($null -eq $installed -or $null -eq $installed.plugins) { return @() }

    $tips = @()
    $seen = @{}

    foreach ($entry in $installed.plugins.PSObject.Properties)
    {
        $parts = $entry.Name -split '@', 2
        if ($parts.Count -ne 2) { continue }
        $pluginName = $parts[0]
        $marketplace = $parts[1]

        foreach ($install in @($entry.Value))
        {
            if ([string]::IsNullOrWhiteSpace($install.installPath)) { continue }
            $skillsDir = Join-Path $install.installPath 'skills'
            if (-not (Test-Path -LiteralPath $skillsDir)) { continue }

            foreach ($dir in Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue)
            {
                $fm = Read-SkillFrontmatter (Join-Path $dir.FullName 'SKILL.md')
                if ($null -eq $fm) { continue }
                if ($seen.ContainsKey($fm.name)) { continue }
                $seen[$fm.name] = $true

                # What the developer types is the plugin-qualified form. The bare name is not
                # guaranteed to resolve, and telling somebody to run a command that does not exist
                # is worse than saying nothing. `id` and `suppressIfUsed` stay bare: ids are how
                # authored tips override discovered ones, and Test-AlreadyUsed matches either form.
                $qualified = "$pluginName`:$($fm.name)"

                $tip = [pscustomobject]@{
                    id             = $fm.name
                    kind           = 'skill'
                    title          = "/$qualified"
                    body           = $fm.description
                    ref            = "/$qualified"
                    repos          = @('*')
                    maxShows       = 3
                    suppressIfUsed = $fm.name
                    source         = 'discovered'
                    install        = [pscustomobject]@{ plugin = $pluginName; marketplace = $marketplace }
                }

                if (Test-AlreadyUsed $tip $StateDir) { continue }
                $tips += $tip
            }
        }
    }

    return $tips
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Discovery.Tests.ps1 -Output Detailed"
```

Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/hooks/DevTips.Discovery.ps1 plugins/dev-tips/tests/
git commit -m "feat(dev-tips): discover installed but unused skills"
```

---

### Task 5: Merge the sources, and record `firstSeen`

**Files:**
- Modify: `plugins/dev-tips/hooks/DevTips.Catalog.ps1`
- Modify: `plugins/dev-tips/hooks/Show-DevTip.ps1`
- Modify: `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DiscoveredTips` from Task 4.
- Produces: `Merge-Tips([object[]]$Authored, [object[]]$Discovered)` → array. Authored copy wins per `id`; `install` is left on whichever object carries it, because `Get-InstallState` resolves it locally anyway. `Get-TipCatalog` now merges packaged, discovered and (from Task 9) remote tips.

- [ ] **Step 1: Write the failing test**

Append to `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`:

```powershell
Describe 'Merge-Tips' {
    It 'lets an authored tip override discovered copy for the same id' {
        $discovered = @([pscustomobject]@{ id = 'git-diff'; title = '/git-diff'; body = 'generated'; source = 'discovered' })
        $authored = @([pscustomobject]@{ id = 'git-diff'; title = 'Better title'; body = 'written by a human' })

        $merged = Merge-Tips -Authored $authored -Discovered $discovered

        $merged.Count | Should -Be 1
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
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Merge-Tips' is not recognized`.

- [ ] **Step 3: Implement the merge**

Add to `plugins/dev-tips/hooks/DevTips.Catalog.ps1`:

```powershell
function Merge-Tips([object[]]$Authored, [object[]]$Discovered)
{
    $byId = [ordered]@{}
    foreach ($tip in @($Discovered)) { if ($null -ne $tip) { $byId[$tip.id] = $tip } }
    foreach ($tip in @($Authored)) { if ($null -ne $tip) { $byId[$tip.id] = $tip } }

    # The comma is load-bearing: returning @() unrolls to nothing, and the caller's property
    # becomes $null instead of an empty array.
    return ,@($byId.Values)
}
```

Then extend `Get-TipCatalog` to use it, replacing the `return` line:

```powershell
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $pluginsRoot = Join-Path $userHome '.claude/plugins'
    $discovered = @()
    try { $discovered = Get-DiscoveredTips -StateDir $StateDir -PluginsRoot $pluginsRoot } catch { }

    return [pscustomobject]@{ tips = (Merge-Tips -Authored $tips -Discovered $discovered); config = $config }
```

`DevTips.Catalog.ps1` must dot-source `DevTips.Discovery.ps1` at the top:

```powershell
. (Join-Path $PSScriptRoot 'DevTips.Discovery.ps1')
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS, all tests.

- [ ] **Step 5: Record `firstSeen` when a tip is shown**

In `Show-DevTip.ps1`, at the point where the shown entry is written, keep the existing `count` and `last` and add `firstSeen` on the first write for an id:

```powershell
    $existing = if ($entries.ContainsKey($tip.id)) { $entries[$tip.id] } else { $null }
    $firstSeen = if ($null -ne $existing -and $existing.firstSeen) { $existing.firstSeen }
                 else { (Get-Date).ToUniversalTime().ToString('o') }

    $entries[$tip.id] = [pscustomobject]@{
        count     = $pick.Count + 1
        last      = (Get-Date).ToUniversalTime().ToString('o')
        firstSeen = $firstSeen
    }
```

- [ ] **Step 6: Verify end to end**

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force
```

Expected: a tip is selected, and the log line reports more candidates than the packaged catalog alone contains.

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): merge discovered tips with authored copy, record firstSeen"
```

---

### Task 6: Channel B — `.dev-tips/` in the working repository

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.RepoTips.ps1`
- Create: `plugins/dev-tips/tests/DevTips.RepoTips.Tests.ps1`
- Modify: `plugins/dev-tips/hooks/DevTips.Catalog.ps1`

**Interfaces:**
- Consumes: `Read-JsonFile` from `DevTips.Common.ps1`.
- Produces: `Get-RepoTips([string]$RepoRoot)` → array of tip objects, each with `source = 'repo'` and `id` defaulting to the file's base name when the file does not set one.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-tips/tests/DevTips.RepoTips.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.RepoTips.ps1')
}

Describe 'Get-RepoTips' {
    It 'reads every json file in .dev-tips' {
        $repo = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $repo '.dev-tips') -Force | Out-Null
        ([pscustomobject]@{ kind = 'adr'; title = 'ADR 0018'; body = 'CompanyId'; repos = @('*') }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.dev-tips/adr-0018-companyid.json') -Encoding UTF8

        $tips = Get-RepoTips -RepoRoot $repo

        $tips.Count | Should -Be 1
        $tips[0].id | Should -Be 'adr-0018-companyid' -Because 'the file name is the id when the file omits one'
        $tips[0].source | Should -Be 'repo'
    }

    It 'returns an empty array when the repository has no .dev-tips directory' {
        @(Get-RepoTips -RepoRoot (New-TempDir)).Count | Should -Be 0
    }

    It 'ignores a malformed file rather than throwing' {
        $repo = New-TempDir
        New-Item -ItemType Directory -Path (Join-Path $repo '.dev-tips') -Force | Out-Null
        'not json {' | Set-Content -LiteralPath (Join-Path $repo '.dev-tips/broken.json') -Encoding UTF8

        @(Get-RepoTips -RepoRoot $repo).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.RepoTips.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Get-RepoTips' is not recognized`.

- [ ] **Step 3: Write the implementation**

Create `plugins/dev-tips/hooks/DevTips.RepoTips.ps1`:

```powershell
#!/usr/bin/env pwsh
# Channel B: tips that belong to the repository being worked in. Arrive with git pull, read live.

function Get-RepoTips([string]$RepoRoot)
{
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return @() }
    $dir = Join-Path $RepoRoot '.dev-tips'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    $tips = @()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    {
        $tip = $null
        try { $tip = Read-JsonFile $file.FullName } catch { $tip = $null }
        if ($null -eq $tip -or [string]::IsNullOrWhiteSpace($tip.title)) { continue }

        if ([string]::IsNullOrWhiteSpace($tip.id))
        {
            $tip | Add-Member -NotePropertyName id -NotePropertyValue $file.BaseName -Force
        }
        $tip | Add-Member -NotePropertyName source -NotePropertyValue 'repo' -Force
        $tips += $tip
    }
    return $tips
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.RepoTips.Tests.ps1 -Output Detailed"
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Wire it into `Get-TipCatalog`**

Dot-source `DevTips.RepoTips.ps1` at the top of `DevTips.Catalog.ps1`, then fold repository tips into the authored set, which is the set that wins over discovery:

```powershell
    # Repository tips count as authored: they win over discovered copy for the same id.
    $tips = @($tips) + @(Get-RepoTips -RepoRoot $RepoRoot)
```

Place this before the `Merge-Tips` call.

- [ ] **Step 6: Run the whole suite**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS, all tests.

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): read .dev-tips from the working repository"
```

---

### Task 7: Channel C — mirror, fetch, derive, snapshot

Tested against a **local git repository built by the test**, so it needs no network and no credentials.

**Files:**
- Create: `plugins/dev-tips/hooks/DevTips.Remote.ps1`
- Create: `plugins/dev-tips/tests/DevTips.Remote.Tests.ps1`
- Modify: `plugins/dev-tips/tests/TestHelpers.ps1`

**Interfaces:**
- Consumes: `Read-JsonFile`, `Write-Log` from `DevTips.Common.ps1`.
- Produces:
  - `Invoke-MirrorFetch([string]$MirrorPath, [string]$Origin, [string]$Branch)` → `$true` on success, `$false` on any git failure. Creates the bare mirror on first call.
  - `Get-RemoteTipFiles([string]$MirrorPath)` → array of `[pscustomobject]@{ path; json }` for every `tip.json`, `dev-tips/manual.json` and `dev-tips/config.json` in the fetched tree.
  - `ConvertTo-Tip([string]$Path, $Json, $Marketplace)` → one tip with `id`, `ref`, `kind` and `install` derived from `$Path`.
  - `Write-RemoteSnapshot([string]$StateDir, [object[]]$Tips, $Config)` — writes `remote-tips.json` via a temp file and `Move-Item`.

- [ ] **Step 1: Extend the fixture helper**

Append to `plugins/dev-tips/tests/TestHelpers.ps1`:

```powershell
function New-FixtureOriginRepo
{
    # A stand-in for Kros.AiDevTools: a real git repo on disk, no network involved.
    $repo = New-TempDir
    $skillDir = Join-Path $repo 'plugins/kros-shared/skills/git-diff'
    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo 'dev-tips') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.claude-plugin') -Force | Out-Null

    ([pscustomobject]@{ kind = 'command'; title = 'From the source'; body = 'authored'; repos = @('*'); maxShows = 2 }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $skillDir 'tip.json') -Encoding UTF8
    ([pscustomobject]@{ ttlHours = 24; cooldownDays = 2; enabled = $true }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'dev-tips/config.json') -Encoding UTF8
    ([pscustomobject]@{ name = 'kros-ai-dev-tools' }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.claude-plugin/marketplace.json') -Encoding UTF8

    & git -C $repo init --initial-branch=master --quiet
    & git -C $repo -c user.email=t@t -c user.name=t add -A
    & git -C $repo -c user.email=t@t -c user.name=t commit -q -m 'fixture'
    return $repo
}
```

- [ ] **Step 2: Write the failing test**

Create `plugins/dev-tips/tests/DevTips.Remote.Tests.ps1`:

```powershell
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
        $tip.PSObject.Properties.Name | Should -Not -Contain 'published'
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
```

- [ ] **Step 3: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Remote.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Invoke-MirrorFetch' is not recognized`.

- [ ] **Step 4: Write the implementation**

Create `plugins/dev-tips/hooks/DevTips.Remote.ps1`:

```powershell
#!/usr/bin/env pwsh
# Channel C: the authored tip files, read out of a shallow bare mirror. Nothing here is generated
# upstream - the source files are what the machine reads.

function Invoke-Git([string[]]$GitArgs)
{
    $env:GIT_TERMINAL_PROMPT = '0'
    $out = & git -c credential.interactive=false -c core.askPass= @GitArgs 2>&1
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = ($out -join "`n") }
}

function Invoke-MirrorFetch([string]$MirrorPath, [string]$Origin, [string]$Branch)
{
    if (-not (Test-Path -LiteralPath (Join-Path $MirrorPath 'HEAD')))
    {
        New-Item -ItemType Directory -Path $MirrorPath -Force | Out-Null
        $init = Invoke-Git @('-C', $MirrorPath, 'init', '--bare', '--quiet')
        if (-not $init.ok) { return $false }
        Invoke-Git @('-C', $MirrorPath, 'remote', 'add', 'origin', $Origin) | Out-Null
    }

    $fetch = Invoke-Git @('-C', $MirrorPath, 'fetch', '--depth', '1', 'origin', $Branch)
    return $fetch.ok
}

function Get-RemoteTipFiles([string]$MirrorPath)
{
    $list = Invoke-Git @('-C', $MirrorPath, 'ls-tree', '-r', '--name-only', 'FETCH_HEAD')
    if (-not $list.ok) { return @() }

    $wanted = @($list.output -split "`n" | Where-Object {
        $_ -match 'tip\.json$' -or $_ -match 'dev-tips/(manual|config)\.json$'
    })

    $files = @()
    foreach ($path in $wanted)
    {
        $blob = Invoke-Git @('-C', $MirrorPath, 'show', "FETCH_HEAD:$path")
        if (-not $blob.ok) { continue }
        $json = $null
        try { $json = $blob.output | ConvertFrom-Json } catch { continue }
        $files += [pscustomobject]@{ path = $path.Trim(); json = $json }
    }
    return $files
}

function ConvertTo-Tip([string]$Path, $Json, $Marketplace)
{
    $parts = $Path -split '/'
    $plugin = if ($parts.Length -gt 1 -and $parts[0] -eq 'plugins') { $parts[1] } else { $null }

    $name = if ($Path -match 'skills/([^/]+)/tip\.json$') { $Matches[1] }
            elseif ($Path -match 'commands/([^/]+)\.tip\.json$') { $Matches[1] }
            else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }

    $tip = $Json | Select-Object *
    $tip | Add-Member -NotePropertyName id -NotePropertyValue $name -Force
    $tip | Add-Member -NotePropertyName ref -NotePropertyValue "/$name" -Force
    $tip | Add-Member -NotePropertyName source -NotePropertyValue 'remote' -Force
    if ($plugin)
    {
        $tip | Add-Member -NotePropertyName install `
                          -NotePropertyValue ([pscustomobject]@{ plugin = $plugin; marketplace = $Marketplace }) -Force
    }
    return $tip
}

function Write-RemoteSnapshot([string]$StateDir, [object[]]$Tips, $Config)
{
    $snapshot = [pscustomobject]@{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        config    = $Config
        tips      = @($Tips)
    }
    $final = Join-Path $StateDir 'remote-tips.json'
    $temp = "$final.$PID.tmp"
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $final -Force
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Remote.Tests.ps1 -Output Detailed"
```

Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/hooks/DevTips.Remote.ps1 plugins/dev-tips/tests/
git commit -m "feat(dev-tips): read authored tip files from a shallow git mirror"
```

---

### Task 8: The remote step in the refresh

The refresh process, its lock and its spawn already exist from Task 3. This adds a second job to it.

**Files:**
- Modify: `plugins/dev-tips/hooks/Update-DevTipsData.ps1`
- Modify: `plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-MirrorFetch`, `Get-RemoteTipFiles`, `ConvertTo-Tip`, `Write-RemoteSnapshot` from
  Task 7; `Test-StampStale` and `Update-Stamp` from Task 3.
- Produces: `Update-DevTipsData.ps1` gains `-Origin` and `-Branch`, and writes `remote-tips.json`.
  The remote job's TTL comes from `config.ttlHours` in the previous snapshot, defaulting to 24.

- [ ] **Step 1: Write the failing test**

Append to `plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1`:

```powershell
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
```

The second test states the rule the design asks for: one job failing must not take the other down.

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/UpdateDevTipsData.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `A parameter cannot be found that matches parameter name 'Origin'`.

- [ ] **Step 3: Add the parameters and the dot-source**

In `Update-DevTipsData.ps1`, extend the `param` block:

```powershell
    [string]$Origin = 'https://github.com/Kros-sk/Kros.AiDevTools.git',
    [string]$Branch = 'master',
```

and add next to the other dot-sources:

```powershell
. (Join-Path $PSScriptRoot 'DevTips.Remote.ps1')
```

- [ ] **Step 4: Add the remote job**

In `Update-DevTipsData.ps1`, after the history job and before `exit 0`:

```powershell
    $previous = Read-JsonFile (Join-Path $StateDir 'remote-tips.json')
    $ttlHours = if ($null -ne $previous -and $null -ne $previous.config -and $null -ne $previous.config.ttlHours)
                { [int]$previous.config.ttlHours } else { 24 }

    if (Test-StampStale -StateDir $StateDir -Name 'remote' -Hours $ttlHours)
    {
        try
        {
            $mirror = Join-Path $StateDir 'remote'
            if (-not (Invoke-MirrorFetch -MirrorPath $mirror -Origin $Origin -Branch $Branch))
            {
                Write-Log "refresh: fetch failed | origin=$Origin | branch=$Branch"
            }
            else
            {
                $files = Get-RemoteTipFiles -MirrorPath $mirror
                $config = ($files | Where-Object { $_.path -like '*dev-tips/config.json' } | Select-Object -First 1).json
                $marketplace = 'kros-ai-dev-tools'

                $tips = @()
                foreach ($file in $files)
                {
                    if ($file.path -like '*dev-tips/config.json') { continue }
                    if ($file.path -like '*dev-tips/manual.json')
                    {
                        foreach ($manual in @($file.json.tips)) { $tips += $manual }
                        continue
                    }
                    $tips += (ConvertTo-Tip -Path $file.path -Json $file.json -Marketplace $marketplace)
                }

                Write-RemoteSnapshot -StateDir $StateDir -Tips $tips -Config $config
                Update-Stamp -StateDir $StateDir -Name 'remote'
                Write-Log ('refresh: snapshot written | tips={0}' -f $tips.Count)
            }
        }
        catch
        {
            Write-Log ('refresh: remote step failed | {0}' -f $_.Exception.Message)
        }
    }
    else
    {
        Write-Log 'refresh: remote stamp fresh, skipped'
    }
```

The fetch failure is logged and swallowed. The stamp is only updated on success, so a failure retries
at the next spawn rather than waiting out a TTL it never earned.

- [ ] **Step 5: Run the whole suite**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS, all tests.

- [ ] **Step 6: Verify by hand**

```bash
pwsh -NoProfile -Command "'{}' | pwsh -NoProfile -File plugins/dev-tips/hooks/Test-TurnForSkills.ps1; Start-Sleep 5; Get-Content \"$env:USERPROFILE/.claude/plugins/data/dev-tips-local/debug.log\" -Tail 5"
```

Expected: a `data refresh spawned` line, then `history scanned` and either `snapshot written` or
`fetch failed` — and the session itself was never blocked.

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): fetch the remote source in the background refresh"
```

---

### Task 9: Consume the snapshot and its configuration

**Files:**
- Modify: `plugins/dev-tips/hooks/DevTips.Catalog.ps1`
- Modify: `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`

**Interfaces:**
- Consumes: `remote-tips.json` written by Task 8.
- Produces: `Get-TipCatalog` merges remote tips into the authored set and returns remote config **as given**, falling back to the packaged config per field.

- [ ] **Step 1: Write the failing test**

Append to `plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1`:

```powershell
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

        $result = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)

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

        (Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot -PluginsRoot (New-TempDir)).tips.Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/DevTips.Catalog.Tests.ps1 -Output Detailed"
```

Expected: FAIL — remote tips are absent and `cooldownDays` is still 2.

- [ ] **Step 3: Extend `Get-TipCatalog`**

In `DevTips.Catalog.ps1`, after the packaged catalog and config are read and before the merge:

```powershell
    $snapshot = Read-JsonFile (Join-Path $StateDir 'remote-tips.json')
    if ($null -ne $snapshot -and $null -ne $snapshot.config)
    {
        foreach ($p in $snapshot.config.PSObject.Properties)
        {
            $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }

    if ($null -ne $config.enabled -and -not $config.enabled)
    {
        return [pscustomobject]@{ tips = @(); config = $config }
    }

    if ($null -ne $snapshot -and $null -ne $snapshot.tips) { $tips = @($tips) + @($snapshot.tips) }
```

No value read from the snapshot is bounded, checked against a floor, or otherwise second-guessed. That is deliberate: see D8 in the analysis.

- [ ] **Step 4: Run the whole suite**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): use the fetched snapshot and its config as given"
```

---

### Task 10: The validator for `Kros.AiDevTools`

The workflow has to be installed in a repository this plan cannot reach (see open question 1 in the analysis). The script and the workflow are built and tested **here**, so installing them there is a copy.

**Files:**
- Create: `plugins/dev-tips/tools/Test-TipFiles.ps1`
- Create: `plugins/dev-tips/tools/dev-tips-validate.yml`
- Create: `plugins/dev-tips/tests/TestTipFiles.Tests.ps1`
- Modify: `plugins/dev-tips/README.md`

**Interfaces:**
- Produces: `Test-TipFiles.ps1 -RepoRoot <path>` — exit 0 when every `tip.json` is valid, exit 1 with one message per problem on stdout.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-tips/tests/TestTipFiles.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Validator = Join-Path $PSScriptRoot '../tools/Test-TipFiles.ps1'
}

Describe 'Test-TipFiles.ps1' {
    It 'passes a well-formed fixture repository' {
        & pwsh -NoProfile -File $script:Validator -RepoRoot (New-FixtureOriginRepo)
        $LASTEXITCODE | Should -Be 0
    }

    It 'fails when a tip points at a command that does not exist' {
        $repo = New-FixtureOriginRepo
        $orphan = Join-Path $repo 'plugins/kros-shared/commands'
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        ([pscustomobject]@{ title = 'Gone'; body = 'b'; repos = @('*') }) |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $orphan 'vanished.tip.json') -Encoding UTF8

        $output = & pwsh -NoProfile -File $script:Validator -RepoRoot $repo
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'vanished'
    }

    It 'fails a tip whose body is too long to fit a two-line notice' {
        $repo = New-FixtureOriginRepo
        $path = Join-Path $repo 'plugins/kros-shared/skills/git-diff/tip.json'
        ([pscustomobject]@{ title = 'T'; body = ('x' * 400); repos = @('*') }) |
            ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8

        & pwsh -NoProfile -File $script:Validator -RepoRoot $repo
        $LASTEXITCODE | Should -Be 1
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/TestTipFiles.Tests.ps1 -Output Detailed"
```

Expected: FAIL — the validator does not exist.

- [ ] **Step 3: Write the validator**

Create `plugins/dev-tips/tools/Test-TipFiles.ps1`:

```powershell
#!/usr/bin/env pwsh
# Runs in CI on pull requests in Kros.AiDevTools. The check that earns its keep is the last one:
# a tip pointing at a renamed command is worse than no tip, and only people who do not know the
# tool ever read it, so nobody else would catch it.

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RepoRoot)

$problems = @()
$ids = @{}
$maxTitle = 80
$maxBody = 240

$files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'tip.json' -or $_.Name -like '*.tip.json' })

foreach ($file in $files)
{
    $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'

    $tip = $null
    try { $tip = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $problems += "$relative : not valid JSON"; continue }

    foreach ($field in @('title', 'body', 'repos'))
    {
        if ($null -eq $tip.$field) { $problems += "$relative : missing required field '$field'" }
    }
    if ($tip.title -and $tip.title.Length -gt $maxTitle) { $problems += "$relative : title over $maxTitle chars" }
    if ($tip.body -and $tip.body.Length -gt $maxBody) { $problems += "$relative : body over $maxBody chars" }

    if ($file.Name -eq 'tip.json')
    {
        $id = Split-Path -Leaf (Split-Path -Parent $file.FullName)
        $target = Join-Path (Split-Path -Parent $file.FullName) 'SKILL.md'
    }
    else
    {
        $id = $file.Name -replace '\.tip\.json$', ''
        $target = Join-Path (Split-Path -Parent $file.FullName) "$id.md"
    }

    if (-not (Test-Path -LiteralPath $target)) { $problems += "$relative : no tool at $id - renamed or deleted?" }
    if ($ids.ContainsKey($id)) { $problems += "$relative : duplicate id '$id', also in $($ids[$id])" }
    $ids[$id] = $relative
}

if ($problems.Count -gt 0)
{
    $problems | ForEach-Object { Write-Output $_ }
    exit 1
}

Write-Output "dev-tips: $($files.Count) tip file(s) valid"
exit 0
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/TestTipFiles.Tests.ps1 -Output Detailed"
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Write the workflow to be copied**

Create `plugins/dev-tips/tools/dev-tips-validate.yml`:

```yaml
name: dev-tips validate

on:
  pull_request:
    paths:
      - '**/tip.json'
      - '**/*.tip.json'
      - 'dev-tips/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate tip files
        shell: pwsh
        run: ./tools/Test-TipFiles.ps1 -RepoRoot .
```

- [ ] **Step 6: Document the copy step**

Add to `plugins/dev-tips/README.md`, under a new `## Publishing tips` heading:

```markdown
## Publishing tips

Tips are authored in `Kros-sk/Kros.AiDevTools`, one `tip.json` beside the skill or command it
describes. Nothing is generated and nothing is published: the plugin fetches `master` shallow and
reads those files. See `docs/catalog-distribution.md`.

`tools/Test-TipFiles.ps1` and `tools/dev-tips-validate.yml` are the validator for that repository.
Copy them to `tools/` and `.github/workflows/` there. They are kept and tested here because this is
where the format is defined.
```

- [ ] **Step 7: Run the whole suite and bump the version**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS, all tests.

Then set `"version": "0.4.0"` in both `plugins/dev-tips/.claude-plugin/plugin.json` and the `dev-tips` entry in `.claude-plugin/marketplace.json`.

- [ ] **Step 8: Commit**

```bash
git add plugins/dev-tips/ .claude-plugin/marketplace.json
git commit -m "feat(dev-tips): add the tip validator and publish instructions"
```

---

## Verification

After Task 10, with the plugin reinstalled (`claude plugin marketplace update kros-plugins`, `claude plugin update dev-tips@kros-plugins`, restart):

- [ ] A session start still produces at most one tip, and `debug.log` names the source it came from.
- [ ] A skill used regularly before the plugin was installed is never offered as a tip.
- [ ] A skill installed but never used appears as a candidate without any `tip.json` existing for it.
- [ ] A `.dev-tips/*.json` added to a product repository appears after a `git pull`, with no plugin update.
- [ ] `remote-tips.json` appears in `$CLAUDE_PLUGIN_DATA` within a turn or two of first use, and `debug.log` records the refresh.
- [ ] Setting `enabled: false` in the source `dev-tips/config.json` silences the plugin on the next refresh.

## Self-review notes

- **Spec coverage.** Channels A, B and C: Tasks 4, 6, 7–9. Merge rules: Task 5. Derived fields and the
  absence of `published`: Tasks 5 and 7. Timing, TTL, lock, atomic write, no prompting: Tasks 3, 7 and 8.
  Remote configuration unclamped and the kill switch: Task 9. Validation: Task 10. Stage 0: Task 1.
- **Beyond the spec.** Task 3 (historical usage backfill) is not in the design document; it came out of
  the question of how to avoid advertising a tool somebody already uses. Fold it into the spec after it
  works, not before.
- **Not covered by any task, deliberately:** installing the workflow in `Kros.AiDevTools` (blocked on
  ownership), and the deliberate credential test named in open question 3 — that one needs a machine
  whose GCM entry can be cleared, which is not something a plan should automate.
- **`published` does not appear anywhere.** Task 7's test asserts its absence so it cannot creep back.
