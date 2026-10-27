#!/usr/bin/env pwsh
# Stop: did the developer just do by hand what a skill they already have does in one step?
#
# Reads this session's command ledger ONCE and clears it ONCE — Claude Code runs an event's hooks in
# parallel as separate processes, so read-and-clear must stay in a single process.
#
# Records a candidate rather than showing anything. Delivery belongs to Show-Candidate.ps1 on the
# next prompt, so nothing interrupts the turn that produced it, and one set of brakes governs every
# notice regardless of how many detectors exist.

$ErrorActionPreference = 'SilentlyContinue'

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $payload = $null }
if ($null -ne $payload -and $payload.stop_hook_active -eq $true) { exit 0 }

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')
. (Join-Path $PSScriptRoot 'DevTips.Catalog.ps1')

try
{
    $stateDir = Get-StateDir
    Initialize-Log $stateDir

    # First thing the hook does: it runs after every turn, so anything ahead of this is multiplied
    # by the turn count. One spawn gate here; each job inside the refresh decides if it is due.
    if (Test-StampStale -StateDir $stateDir -Name 'refresh' -Hours 6)
    {
        Update-Stamp -StateDir $stateDir -Name 'refresh'
        Start-DataRefresh -StateDir $stateDir -HookRoot $PSScriptRoot
        Write-Log 'stop: data refresh spawned'
    }

    $ledger = Join-Path $stateDir ('turns/' + (Get-SessionId $payload) + '.txt')
    if (-not (Test-Path -LiteralPath $ledger)) { exit 0 }

    $commands = @(Get-Content -LiteralPath $ledger -Encoding UTF8 | Where-Object { $_ })
    Remove-Item -LiteralPath $ledger -Force
    if ($commands.Count -eq 0) { exit 0 }

    $catalog = Get-TipCatalog -StateDir $stateDir -PluginRoot (Get-PluginRoot)
    if ($catalog.tips.Count -eq 0) { exit 0 }

    $repoName = Get-RepoName
    $best = $null

    foreach ($tip in $catalog.tips)
    {
        if ($null -eq $tip.when -or $null -eq $tip.when.did) { continue }
        if (-not (Test-RepoMatch $tip $repoName)) { continue }

        # Only ever suggest something the developer can actually run right now.
        $installState = Get-InstallState $tip
        if ($installState -ne 'installed' -and $installState -ne 'n/a') { continue }
        if (Test-AlreadyUsed $tip $stateDir) { continue }

        $matched = @()
        foreach ($pattern in $tip.when.did.commands)
        {
            foreach ($cmd in $commands)
            {
                if ($cmd -match $pattern) { $matched += $pattern; break }
            }
        }

        $minMatches = if ($null -ne $tip.when.did.minMatches) { [int]$tip.when.did.minMatches } else { 2 }
        if ($matched.Count -lt $minMatches) { continue }

        if ($null -eq $best -or $matched.Count -gt $best.Matched)
        {
            $best = [pscustomobject]@{ Id = $tip.id; Matched = $matched.Count; Patterns = $matched }
        }
    }

    if ($null -eq $best)
    {
        Write-Log ("stop: no skill matched | commands={0} | repo={1}" -f $commands.Count, $repoName)
        exit 0
    }

    Write-JsonFile (Join-Path $stateDir 'candidates.json') ([pscustomobject]@{
        id        = $best.Id
        matched   = $best.Patterns
        recorded  = (Get-Date).ToUniversalTime().ToString('o')
        commands  = $commands.Count
    })

    Write-Log ("stop: candidate={0} | matched={1}/{2} patterns | commands={3}" -f
        $best.Id, $best.Matched, $best.Patterns.Count, $commands.Count)
}
catch
{
    Write-Log ("ERROR (stop): {0} | at {1}:{2}" -f
        $_.Exception.Message, $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
}

exit 0
