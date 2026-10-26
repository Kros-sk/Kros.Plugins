#!/usr/bin/env pwsh
# SessionStart: the scheduled notice — one tip per session, rate-limited, never twice for something
# the developer already uses. Retrospective notices go through Show-Candidate.ps1 instead.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Only when stdin is redirected: a hook always has it, a manual run does not, and reading
# an interactive stdin would hang waiting for input that never comes.
$payload = $null
if ([Console]::IsInputRedirected)
{
    try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $payload = $null }
}

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')
. (Join-Path $PSScriptRoot 'DevTips.Catalog.ps1')
. (Join-Path $PSScriptRoot 'Write-PendingTip.ps1')

try
{
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $pluginRoot = Get-PluginRoot
    $stateDir = Get-StateDir
    Initialize-Log $stateDir

    $dataEnv = if ([string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_DATA)) { 'unset' } else { 'set' }
    Write-Log ("run start | pid={0} | dryRun={1} | force={2} | CLAUDE_PLUGIN_DATA={3} | pluginRoot={4} | cwd={5}" -f
        $PID, $DryRun.IsPresent, $Force.IsPresent, $dataEnv, $pluginRoot, (Get-Location).Path)

    $catalog = Get-TipCatalog -StateDir $stateDir -PluginRoot $pluginRoot
    if ($catalog.tips.Count -eq 0)
    {
        Write-Log 'exit: catalog missing or empty'
        exit 0
    }

    $config = $catalog.config
    $cooldownDays = if ($null -ne $config.cooldownDays) { [int]$config.cooldownDays } else { 2 }

    $shownPath = Join-Path $stateDir 'shown.json'
    $shown = Read-JsonFile $shownPath
    $entries = @{}
    $lastShownAt = $null
    if ($null -ne $shown)
    {
        $lastShownAt = $shown.lastShownAt
        if ($null -ne $shown.entries)
        {
            foreach ($p in $shown.entries.PSObject.Properties) { $entries[$p.Name] = $p.Value }
        }
    }

    if (-not $Force -and -not [string]::IsNullOrWhiteSpace($lastShownAt))
    {
        $elapsed = (Get-Date).ToUniversalTime() - ([datetime]$lastShownAt).ToUniversalTime()
        if ($elapsed.TotalDays -lt $cooldownDays)
        {
            Write-Log ('exit: cooldown, {0:N2}d elapsed of {1}d' -f $elapsed.TotalDays, $cooldownDays)
            exit 0
        }
    }

    $repoName = Get-RepoName
    $today = (Get-Date).ToUniversalTime()
    $candidates = @()

    foreach ($tip in $catalog.tips)
    {
        if (-not (Test-RepoMatch $tip $repoName)) { continue }
        if ($tip.expires -and ([datetime]$tip.expires) -lt $today) { continue }
        if (Test-AlreadyUsed $tip $stateDir) { continue }

        $count = 0
        $last = [datetime]::MinValue
        if ($entries.ContainsKey($tip.id))
        {
            $count = [int]$entries[$tip.id].count
            if ($entries[$tip.id].last) { $last = [datetime]$entries[$tip.id].last }
        }

        $maxShows = if ($null -ne $tip.maxShows) { [int]$tip.maxShows } else { 3 }
        if ($count -ge $maxShows) { continue }

        $candidates += [pscustomobject]@{ Tip = $tip; Count = $count; Last = $last }
    }

    if ($candidates.Count -eq 0)
    {
        Write-Log ("exit: no candidates | repo={0} | catalog={1} tips" -f $repoName, $catalog.tips.Count)
        exit 0
    }

    # Rank is explicit rather than relying on Sort-Object being stable and Merge-Tips emitting
    # authored tips first. Both are true, and neither should be load-bearing from here.
    $pick = ($candidates |
        Sort-Object Count, @{ Expression = { Get-SourceRank $_.Tip } }, Last |
        Select-Object -First 1)
    $tip = $pick.Tip
    $installState = Get-InstallState $tip
    $source = if ($tip.source) { $tip.source } else { 'packaged' }
    Write-Log ("picked={0} | source={1} | repo={2} | candidates={3} | shownBefore={4} | install={5}" -f
        $tip.id, $source, $repoName, $candidates.Count, $pick.Count, $installState)

    $userMessage = (New-TipText $tip $installState) + "`n`n" + (New-Question $tip $installState)
    $actionHint = New-ActionHint $tip $installState

    # The band reads this whoever ends up drawing the tip, a dry run included: the point of
    # the dry run is to exercise what the surfaces will show.
    Write-PendingTip -StateDir $stateDir -SessionId (Get-SessionId $payload) -Tip $tip -InstallState $installState -RepoRoot (Get-RepoRoot)

    # `delivery` says who shows it. `band` leaves it to the mod, which is the only surface
    # that reaches the desktop at all; `hook` is the original path and the way back. The
    # state write below still runs: a tip handed to the band counts as shown, or it would
    # be offered again tomorrow.
    $delivery = if ($config.delivery) { [string]$config.delivery } else { 'hook' }

    if ($DryRun)
    {
        Write-Host "repo=$repoName  picked=$($tip.id)  install=$installState  stateDir=$stateDir"
        Write-Host ''
        Write-Host $userMessage
        Write-Log 'exit: dry run, state not written'
        exit 0
    }

    if ($delivery -eq 'band')
    {
        Write-Log ("exit: band renders it | picked={0}" -f $tip.id)
    }
    else
    {
        Write-HookOutput 'SessionStart' $userMessage 'Tip pre používateľa.' $actionHint
    }

    $nowIso = $today.ToString('o')

    # firstSeen replaces the catalog's old `published` field: how new an item is, is relative to the
    # reader. To somebody who joined last week, a two-year-old skill they never heard of is new.
    $existing = if ($entries.ContainsKey($tip.id)) { $entries[$tip.id] } else { $null }
    $firstSeen = if ($null -ne $existing -and $existing.firstSeen) { $existing.firstSeen } else { $nowIso }

    $entries[$tip.id] = [pscustomobject]@{
        count     = $pick.Count + 1
        last      = $nowIso
        firstSeen = $firstSeen
    }
    Write-JsonFile $shownPath ([pscustomobject]@{
        lastShownAt     = $nowIso
        lastCandidateAt = if ($null -ne $shown) { $shown.lastCandidateAt } else { $null }
        entries         = [pscustomobject]$entries
    })

    $channel = if ($delivery -eq 'band') { 'band' }
               elseif (Test-IsDesktop) { 'additionalContext (desktop)' }
               else { 'systemMessage + additionalContext (cli)' }
    Write-Log ("delivered via {0} | shownNow={1} | state written" -f $channel, ($pick.Count + 1))
}
catch
{
    Write-Log ("ERROR: {0} | at {1}:{2}" -f
        $_.Exception.Message, $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
    exit 0
}

exit 0
