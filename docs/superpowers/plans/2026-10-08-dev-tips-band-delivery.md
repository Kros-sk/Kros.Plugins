# dev-tips band delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the session-start tip as a band above the prompt, so it reaches the person on the desktop Code tab where `systemMessage` is dropped, and so its question can be answered by pressing rather than by prose.

**Architecture:** Selection stays where it already is. `Show-DevTip.ps1` keeps the cooldown, `maxShows`, usage suppression and source merging, and writes the tip it picked to `pending.json`. A hooks module reads that file and draws it; its buttons write back into the same `usage.json` and `shown.json` the PowerShell reads. The classic hook stays as the escape: the module writes a marker when it loads, and the hook stays silent only while that marker is fresh.

**Tech Stack:** PowerShell 7.6.6, Pester 5.9.1, TypeScript hooks module against the Claude Code mod API (early access), `claude plugin validate` / `claude plugin test`.

**Spec:** `plugins/dev-tips/docs/catalog-distribution.md`, decision D14 in `plugins/dev-tips/docs/catalog-distribution-analysis.md`.

**Prototype:** `~/.claude/dev-mods/<session>/dev-tips-probe` — the probe that proved the band draws, takes input and carries a `Link`. Its layout, its terminal focus hint and its `×` glyph choice are settled questions; copy them rather than rediscovering them.

## Global Constraints

- **The module never selects a tip.** Cooldown, `maxShows`, `suppressIfUsed`, source ranking and merging stay in PowerShell. A second implementation of any of them is a defect, not a convenience.
- **The tip is delivered once.** Either the band draws it or the classic hook emits it, never both.
- **Degradation is to today's behaviour, not to nothing.** Where the module does not load — an old build, hot reloading declined, an unsupported environment — the hook must deliver exactly as it does now.
- Every hook still swallows errors and **exits 0**, and still logs a line to `debug.log`.
- `SessionStart` still touches no network and opens no git mirror.
- The module writes only inside `$CLAUDE_PLUGIN_DATA`; every write is temp-file-plus-move, as `Write-RemoteSnapshot` already does.
- Button `key`s are the test's handle and must not change with a label. Labels carry no digits; `hotkey` stays off the label.
- `claude plugin validate` and `claude plugin test` pass before any task is called done, alongside Pester.
- The mod API is early access: one release already changed both the band's painting and its focus handling. Pin nothing to a build; prefer what the types declare over what a build happens to do.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/dev-tips/hooks/Write-PendingTip.ps1` | **new** — the selected tip as structured data, written for the band |
| `plugins/dev-tips/hooks/Show-DevTip.ps1` | modified — writes `pending.json`, and stays silent while a renderer marker is fresh |
| `plugins/dev-tips/hooks/DevTips.Common.ps1` | modified — marker read/write helpers beside the stamp helpers |
| `plugins/dev-tips/hooks/band/register.tsx` | **new** — the module: reads `pending.json`, draws the band, writes answers back |
| `plugins/dev-tips/hooks/band/hooks.json` | **new** — `{ "modules": ["./register.tsx"] }`, or merged into the existing file if one may carry both |
| `plugins/dev-tips/types/index.d.ts` | **new** — the module's `$.state` contract |
| `plugins/dev-tips/hooks/band/*.test.tsx` | **new** — the module's tests |
| `plugins/dev-tips/tests/PendingTip.Tests.ps1` | **new** — Pester for the PowerShell half |

`pending.json`, `renderer.json` and `answers.log` live in `$CLAUDE_PLUGIN_DATA` beside `shown.json`.

## Task 1: Can one plugin carry both kinds of hook?

Everything downstream is shaped by the answer, and it is unknown. Settle it before writing the module.

**Files:**
- Modify: `plugins/dev-tips/hooks/hooks.json` (experimentally; revert if refused)

**Interfaces:** none yet. This task produces a decision and a note, not code.

- [ ] **Step 1: Ask the validator**

Add a `modules` key beside the existing `hooks` key in a scratch copy of the plugin, with a module that only registers `session.start`, then:

```bash
claude plugin validate plugins/dev-tips
```

Expected: either both are listed (`hooks: …` and `./register.tsx hooks: session.start`), or the manifest is refused with a reason.

- [ ] **Step 2: Record the answer where the next reader will look**

Append to `plugins/dev-tips/docs/catalog-distribution.md`, under channel C's section, one short paragraph: whether the band ships inside `dev-tips` or as a companion plugin, and the validator output that settled it.

- [ ] **Step 3: Commit**

```bash
git add plugins/dev-tips/
git commit -m "docs(dev-tips): settle whether one plugin carries hooks and a module"
```

---

## Task 2: `pending.json` — the tip as data

**Files:**
- Create: `plugins/dev-tips/hooks/Write-PendingTip.ps1`
- Create: `plugins/dev-tips/tests/PendingTip.Tests.ps1`
- Modify: `plugins/dev-tips/hooks/Show-DevTip.ps1`

**Interfaces:**
- Consumes: the `$tip` object `Show-DevTip.ps1` already picks, and `Get-InstallState`.
- Produces: `Write-PendingTip([string]$StateDir, $Tip, [string]$InstallState)` writing `$StateDir/pending.json`:

```json
{
  "id": "az-pr",
  "kind": "skill",
  "title": "/kros-shared:az-pr",
  "body": "Creates an Azure DevOps pull request …",
  "ref": "/kros-shared:az-pr",
  "url": null,
  "source": "discovered",
  "installState": "installed",
  "pickedAt": "2026-10-08T06:00:00.0000000Z"
}
```

`url` is null for everything that is not a document. `ref` is already kind-aware from `ConvertTo-Tip`: a command carries a slash, an agent does not.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-tips/tests/PendingTip.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
    . (Join-Path $PSScriptRoot '../hooks/Write-PendingTip.ps1')
}

Describe 'Write-PendingTip' {
    It 'writes the fields the band draws, and nothing it cannot use' {
        $stateDir = New-TempDir
        $tip = [pscustomobject]@{
            id = 'az-pr'; kind = 'skill'; title = '/kros-shared:az-pr'
            body = 'Creates a pull request.'; ref = '/kros-shared:az-pr'; source = 'discovered'
        }

        Write-PendingTip -StateDir $stateDir -Tip $tip -InstallState 'installed'

        $pending = Get-Content -LiteralPath (Join-Path $stateDir 'pending.json') -Raw | ConvertFrom-Json
        $pending.id | Should -Be 'az-pr'
        $pending.ref | Should -Be '/kros-shared:az-pr'
        $pending.installState | Should -Be 'installed'
        $pending.pickedAt | Should -Not -BeNullOrEmpty
        $pending.url | Should -BeNullOrEmpty
    }

    It 'carries a url when the tip has one' {
        $stateDir = New-TempDir
        $tip = [pscustomobject]@{
            id = 'pre-pr'; kind = 'rule'; title = 'T'; body = 'b'
            ref = 'docs/guidelines/pre-pr-verification.md'
            url = 'https://dev.azure.com/krossk/Esw/_git/Invoicing?path=/docs/guidelines/pre-pr-verification.md'
            source = 'repo'
        }

        Write-PendingTip -StateDir $stateDir -Tip $tip -InstallState 'n/a'

        $pending = Get-Content -LiteralPath (Join-Path $stateDir 'pending.json') -Raw | ConvertFrom-Json
        $pending.url | Should -Match '^https://'
    }

    It 'leaves no temp file behind' {
        $stateDir = New-TempDir
        Write-PendingTip -StateDir $stateDir -InstallState 'n/a' `
            -Tip ([pscustomobject]@{ id = 'x'; title = 't'; body = 'b' })

        @(Get-ChildItem -LiteralPath $stateDir -Filter '*.tmp').Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/PendingTip.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Write-PendingTip' is not recognized`.

- [ ] **Step 3: Write the implementation**

Create `plugins/dev-tips/hooks/Write-PendingTip.ps1`:

```powershell
#!/usr/bin/env pwsh
# The selected tip as data for the band. The band renders; it never decides.

function Write-PendingTip([string]$StateDir, $Tip, [string]$InstallState)
{
    $pending = [pscustomobject]@{
        id           = $Tip.id
        kind         = if ($Tip.kind) { $Tip.kind } else { 'tip' }
        title        = $Tip.title
        body         = $Tip.body
        ref          = $Tip.ref
        url          = $Tip.url
        source       = if ($Tip.source) { $Tip.source } else { 'packaged' }
        installState = $InstallState
        pickedAt     = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Temp plus move: the band may read this while SessionStart is still writing it.
    $final = Join-Path $StateDir 'pending.json'
    $temp = "$final.$PID.tmp"
    $pending | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $final -Force
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/PendingTip.Tests.ps1 -Output Detailed"
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Write it from `Show-DevTip.ps1`**

Dot-source `Write-PendingTip.ps1` beside the others, and call it where the tip is chosen — after `$installState` is known and before the output is emitted:

```powershell
    Write-PendingTip -StateDir $stateDir -Tip $tip -InstallState $installState
```

- [ ] **Step 6: Verify by hand**

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force
```

Expected: `pending.json` holds the same tip the dry run printed. A dry run still writes it: the band is the thing being exercised.

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): write the selected tip as data for the band"
```

---

## Task 3: The renderer marker, and a hook that knows when to stay quiet

**Files:**
- Modify: `plugins/dev-tips/hooks/DevTips.Common.ps1`
- Modify: `plugins/dev-tips/hooks/Show-DevTip.ps1`
- Create: `plugins/dev-tips/tests/Renderer.Tests.ps1`

**Interfaces:**
- Produces:
  - `Test-RendererFresh([string]$StateDir, [int]$MaxAgeHours = 24)` → `$true` while `renderer.json` is younger than that.
  - The module writes `renderer.json` on `session.start`; this task only reads it.

**The ordering problem, and why freshness rather than existence.** `SessionStart` and the module's `session.start` run without a guaranteed order, so on the very first session the marker may not exist yet when the hook asks. Existence alone would therefore make the first tip arrive twice — or, if the marker were written eagerly, make it vanish forever on a build where the band silently fails. A marker that must be *fresh* decays on its own: the module rewrites it every session, and a session where the module no longer loads falls back to the hook within a day.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-tips/tests/Renderer.Tests.ps1`:

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
}

Describe 'Test-RendererFresh' {
    It 'is false when no renderer has ever announced itself' {
        Test-RendererFresh -StateDir (New-TempDir) | Should -BeFalse
    }

    It 'is true just after one has' {
        $stateDir = New-TempDir
        '{}' | Set-Content -LiteralPath (Join-Path $stateDir 'renderer.json') -Encoding UTF8

        Test-RendererFresh -StateDir $stateDir | Should -BeTrue
    }

    It 'goes stale, so a build that stops loading the module falls back' {
        $stateDir = New-TempDir
        $path = Join-Path $stateDir 'renderer.json'
        '{}' | Set-Content -LiteralPath $path -Encoding UTF8
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-25)

        Test-RendererFresh -StateDir $stateDir | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/Renderer.Tests.ps1 -Output Detailed"
```

Expected: FAIL — `'Test-RendererFresh' is not recognized`.

- [ ] **Step 3: Write the helper**

Append to `plugins/dev-tips/hooks/DevTips.Common.ps1`:

```powershell
function Test-RendererFresh([string]$StateDir, [int]$MaxAgeHours = 24)
{
    $path = Join-Path $StateDir 'renderer.json'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return ($age.TotalHours -lt $MaxAgeHours)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests/Renderer.Tests.ps1 -Output Detailed"
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Let the hook stand down**

In `Show-DevTip.ps1`, after `pending.json` is written and before `Write-HookOutput`:

```powershell
    if (Test-RendererFresh -StateDir $stateDir)
    {
        Write-Log ("exit: band renders it | picked={0}" -f $tip.id)
        exit 0
    }
```

The state write stays above this: a tip handed to the band still counts as shown, or it would be offered again tomorrow.

- [ ] **Step 6: Verify both ways by hand**

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force
```

Expected: the tip is printed, because no marker exists. Then:

```bash
pwsh -NoProfile -Command "'{}' | Set-Content \"$env:USERPROFILE/.claude/plugins/data/dev-tips-local/renderer.json\"; pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force"
```

Expected: nothing on stdout, and `debug.log` ends with `exit: band renders it`.

- [ ] **Step 7: Commit**

```bash
git add plugins/dev-tips/hooks/ plugins/dev-tips/tests/
git commit -m "feat(dev-tips): let the hook stand down while a band is rendering"
```

---

## Task 4: The module draws what was picked

**Files:**
- Create: `plugins/dev-tips/hooks/band/register.tsx`
- Create: `plugins/dev-tips/hooks/band/hooks.json`
- Create: `plugins/dev-tips/types/index.d.ts`
- Create: `plugins/dev-tips/hooks/band/band.test.tsx`

**Interfaces:**
- Consumes: `pending.json` from Task 2, through `$.fs`.
- Produces: a band drawing the pending tip; `renderer.json` written on `session.start`; `$.state` holding only what is being drawn right now (`isOpen`, `answer`), never the tip itself.

Carry over from the probe, settled and not to be rediscovered: the body sits in its own row rather than beside the controls, `×` is U+00D7, `flexShrink={0}` on the control group, digits as `hotkey` and off the label, and the `tab aktivuje ovládanie` hint on `e.surface === 'terminal'` alone.

- [ ] **Step 1: Write the failing test**

Create `plugins/dev-tips/hooks/band/band.test.tsx`:

```tsx
import { expect, test } from 'claude-code/testing'

const BAND = { component: 'AbovePrompt' as const, props: {} }

test('nothing pending, nothing drawn', async ($, on) => {
  on('ui.render', { component: 'AbovePrompt' }, ($$, e) => {
    const { Box } = $$.ui.resolve(e)

    return <Box />
  })

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /💡/ })).toBeUndefined()

  await ui.unmount()
})

test('a pending tip is drawn with its title and body', async $ => {
  await $.fs.write(
    `${$.env.get('CLAUDE_PLUGIN_DATA')}/pending.json`,
    JSON.stringify({ id: 'az-pr', title: '/kros-shared:az-pr', body: 'Creates a pull request.', ref: '/kros-shared:az-pr' }),
  )

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })

  expect(await ui.find({ type: 'Text', text: /az-pr/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /Creates a pull request/ })).toBeDefined()

  await ui.unmount()
})
```

The exact `$.fs` and `$.env` spellings are whatever the types declare: grep
`.claude-plugin/types/claude-code/index.d.ts` for `fs:` and read the declaration before writing this.

- [ ] **Step 2: Run it to verify it fails**

```bash
claude plugin test plugins/dev-tips
```

Expected: FAIL — no module, or no band drawn.

- [ ] **Step 3: Write the module**

Port `register.tsx` from the probe, with these changes and no others:

- `session.start` writes `renderer.json` (`{ "surface": …, "at": … }`) and registers no command.
- The tip comes from `pending.json`, read in the `ui.render` hook; a missing or unreadable file means `next(e)`.
- `/probe-reset` and the `session.start ran` diagnostics go.
- `Link` is drawn only when `url` is set; `ref` is drawn as the invocation only when `installState` is `installed`, as `New-TipText` already decides.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
claude plugin test plugins/dev-tips
claude plugin validate plugins/dev-tips
```

Expected: PASS, and validation lists `ui.render{component=AbovePrompt}` and `session.start`.

- [ ] **Step 5: Verify in both surfaces by hand**

Start a session in the desktop app and a terminal session, and confirm the band draws the tip that `pending.json` holds, that the hint appears on the terminal alone, and that `debug.log` says `exit: band renders it` rather than emitting the tip twice.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/
git commit -m "feat(dev-tips): draw the selected tip as a band above the prompt"
```

---

## Task 5: The answers write back

**Files:**
- Modify: `plugins/dev-tips/hooks/band/register.tsx`
- Modify: `plugins/dev-tips/hooks/band/band.test.tsx`

**Interfaces:**
- Produces: `Už to používam` adds the tip's `suppressIfUsed` (defaulting to its `id`) to `usage.json`; `×` and any answer clear `pending.json`; every press appends one line to `answers.log`.

`usage.json` is the file `Test-AlreadyUsed` reads, so a press there is the same signal `Record-SkillUse.ps1` writes and the transcript backfill infers. This is the point of the whole band: the inference becomes a statement.

- [ ] **Step 1: Write the failing test**

Append to `band.test.tsx`:

```tsx
test('pressing "already use it" writes the suppression the PowerShell reads', async $ => {
  const data = $.env.get('CLAUDE_PLUGIN_DATA')
  await $.fs.write(`${data}/pending.json`, JSON.stringify({ id: 'az-pr', title: 't', body: 'b' }))

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'open' })
  await ui.press({ key: 'known' })
  await ui.unmount()

  const usage = JSON.parse(await $.fs.read(`${data}/usage.json`))
  expect(usage['az-pr']).toBeDefined()
})

test('every press is recorded, so the notice can finally be measured', async $ => {
  const data = $.env.get('CLAUDE_PLUGIN_DATA')
  await $.fs.write(`${data}/pending.json`, JSON.stringify({ id: 'az-pr', title: 't', body: 'b' }))

  const ui = await $.ui.mount({ plugin: 'dev-tips', surface: 'desktop', ...BAND })
  await ui.press({ key: 'drop' })
  await ui.unmount()

  expect(await $.fs.read(`${data}/answers.log`)).toMatch(/az-pr.*drop/)
})
```

- [ ] **Step 2: Run it to verify it fails**

```bash
claude plugin test plugins/dev-tips
```

Expected: FAIL — `usage.json` unchanged, no `answers.log`.

- [ ] **Step 3: Write the write-back**

Each handler: append to `answers.log`, clear `pending.json`, and for `known` merge the id into `usage.json` the way `Merge-UsageFile` does — a live record wins, so write only when the key is absent. Every write is temp-plus-move.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
claude plugin test plugins/dev-tips
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Expected: PASS on both. The Pester suite must still be green: `usage.json` is shared, and a malformed write from the module would break `Test-AlreadyUsed`.

- [ ] **Step 5: Verify the loop closes**

Press `Už to používam` on a real tip, then:

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun -Force
```

Expected: that tip is no longer among the candidates, and the log's candidate count has dropped by one.

- [ ] **Step 6: Commit**

```bash
git add plugins/dev-tips/
git commit -m "feat(dev-tips): answer the tip by pressing, and record what was pressed"
```

---

## Task 6: `Ukáž ako` reaches the model

Left last because it is the one step whose mechanism is not yet known.

**Files:**
- Modify: `plugins/dev-tips/hooks/band/register.tsx`
- Modify: `plugins/dev-tips/hooks/band/band.test.tsx`

**Interfaces:**
- Produces: pressing `Ukáž ako` causes the model to explain the tip's tool in the next turn.

- [ ] **Step 1: Find the mechanism before writing anything**

Grep the API types for what a module may hand the model, and read the declaration each lands on:

```bash
grep -n "prompt\.\|'prompt" .claude-plugin/types/claude-code/index.d.ts | head -40
```

Candidates to weigh: a `prompt.submit` hook rewriting the next prompt, `prompt.compose` adding a section, `$.model`, or `$.command`. If none fits, say so and stop: the fallback is that the press writes `answers.log` and the classic hook's `additionalContext` picks it up next session, which is worse but known.

- [ ] **Step 2: Write the failing test for whichever mechanism the types support**

Assert the observable effect, not the call: after pressing `show`, the thing the model would receive contains the tip's `ref`.

- [ ] **Step 3: Run it, implement, run it again**

```bash
claude plugin test plugins/dev-tips
```

- [ ] **Step 4: Commit**

```bash
git add plugins/dev-tips/
git commit -m "feat(dev-tips): let the band ask the model to explain the tool"
```

---

## Verification

With the plugin reinstalled and the app restarted:

- [ ] A session start draws one band, in the desktop app and in a terminal, and `debug.log` says `exit: band renders it` rather than emitting the tip as well.
- [ ] With the module not loaded — rename `band/hooks.json` — the tip arrives exactly as it does today, within a day of the marker going stale.
- [ ] `Už to používam` removes that tip from the candidates on the next run.
- [ ] `answers.log` holds one line per press.
- [ ] The terminal hint appears only on the terminal, and `tab` makes the buttons clickable there.

## Self-review notes

- **Spec coverage.** D14's escape is Task 3; its promise that an answer becomes countable is Task 5. Channel selection and merging are untouched by design.
- **The known unknowns are first and last.** Task 1 settles the packaging question that shapes every file path; Task 6 is last because its mechanism is unverified and it is the only part that can be cut without losing the rest.
- **Not covered.** Whether the band should ever show a second tip in one session; today `pending.json` holds one. And what the band does on `mobile`, which neither the probe nor this plan has seen.
