#!/usr/bin/env pwsh
# Sets the state up so the next session is shown a tip of the kind you ask for.
#
# For showing somebody what this looks like. Not part of the plugin: nothing here runs on its own,
# and the plugin neither knows nor cares that it exists.
#
# It does NOT write a handshake of its own. That was the first attempt and it does not work: the
# band takes the newest handshake nobody has been shown yet, so any session that happens to redraw
# claims it first - twice it was gone before the window being demonstrated had even started. What
# works is to leave the picking to the hook and only arrange what it has to choose from.
#
#   ./Show-DevTipDemo.ps1 -Kind guideline -RepoRoot C:/src/Invoicing
#   ./Show-DevTipDemo.ps1 -Restore
#
# A guideline is read from the repository the session runs in, so -RepoRoot has to be a repository
# that has docs/guidelines, and the window has to be opened on that same repository.

[CmdletBinding(DefaultParameterSetName = 'Prepare')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Prepare')]
    [ValidateSet('skill', 'adr', 'guideline')]
    [string]$Kind,

    [Parameter(ParameterSetName = 'Prepare')]
    [string]$RepoRoot = (Get-Location).Path,

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$hooks = Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks'
. (Join-Path $hooks 'DevTips.Common.ps1')
. (Join-Path $hooks 'DevTips.Discovery.ps1')
. (Join-Path $hooks 'DevTips.Docs.ps1')

$stateDir = Get-StateDir
$shownPath = Join-Path $stateDir 'shown.json'
$backup = Join-Path $stateDir 'shown.json.demo-backup'

if ($Restore)
{
    if (-not (Test-Path -LiteralPath $backup)) { throw "nothing to restore: $backup does not exist" }

    Copy-Item -LiteralPath $backup -Destination $shownPath -Force
    Remove-Item -LiteralPath $backup -Force
    "state restored from the backup taken before the first demo"
    return
}

# Taken once and kept until -Restore, so a run of demos still rewinds to where the person started
# rather than to the middle of it.
if (-not (Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $shownPath))
{
    Copy-Item -LiteralPath $shownPath -Destination $backup -Force
    "backup taken: $backup"
}

$documents = @()
try { $documents += @(Get-AdrTips -Root (Join-Path $stateDir 'adr/Adrs')) } catch { }
try { $documents += @(Get-GuidelineTips -RepoRoot $RepoRoot) } catch { }

$wanted = @($documents | Where-Object { $_.kind -eq $Kind })
if ($Kind -ne 'skill' -and $wanted.Count -eq 0)
{
    $where = if ($Kind -eq 'adr') { "the mirror at $stateDir\adr - has the refresh run?" }
             else { "$RepoRoot\docs\guidelines - is that the right repository?" }
    throw "no document of kind '$Kind' found in $where"
}

$shown = Read-JsonFile $shownPath
$entries = @{}
if ($null -ne $shown -and $null -ne $shown.entries)
{
    foreach ($p in $shown.entries.PSObject.Properties) { $entries[$p.Name] = $p.Value }
}

$now = (Get-Date).ToUniversalTime().ToString('o')
$released = 0
$blocked = 0

foreach ($doc in $documents)
{
    if ($doc.kind -eq $Kind)
    {
        # Back into the running, whether the baseline silenced it or somebody has already seen it.
        if ($entries.Remove($doc.id)) { $released++ }
        continue
    }

    # Out of the running. Deliberately without the `baselined` mark: an id named in announceAnyway
    # would otherwise be released again on the next read, which is what that mark is for.
    if (-not $entries.ContainsKey($doc.id))
    {
        $entries[$doc.id] = [pscustomobject]@{ count = 1; last = $now; firstSeen = $now }
        $blocked++
    }
}

# Documents outrank skills, so showing a skill means every document has to be out of the way -
# which the loop above has already done, since none of them is of the wanted kind.

Write-JsonFile $shownPath ([pscustomobject]@{
    lastShownAt     = $null
    lastCandidateAt = if ($null -ne $shown) { $shown.lastCandidateAt } else { $null }
    entries         = [pscustomobject]$entries
})

"kind=${Kind}: released $released, held back $blocked, cooldown opened"

# What the hook will actually pick, asked of the hook itself rather than worked out here a second
# time. Run from the repository the window will be opened on, because that is what it reads.
Push-Location $RepoRoot
try
{
    $preview = & (Join-Path $hooks 'Show-DevTip.ps1') -DryRun 2>&1
    $preview | Select-Object -First 6
}
finally { Pop-Location }

""
"open a NEW window on $RepoRoot and type anything"
