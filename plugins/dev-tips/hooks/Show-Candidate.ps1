#!/usr/bin/env pwsh
# UserPromptSubmit: delivers a candidate recorded by the Stop hook, on the very next prompt.
#
# Sits in the critical path of every prompt, so it does nothing but read two small local files when
# no candidate is pending. Its own cooldown is shorter than the scheduled one — a retrospective
# notice is worth more — but `maxShows` still applies.

$ErrorActionPreference = 'SilentlyContinue'

try { $null = [Console]::In.ReadToEnd() } catch { }

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')

try
{
    $stateDir = Get-StateDir
    $candidatePath = Join-Path $stateDir 'candidates.json'
    if (-not (Test-Path -LiteralPath $candidatePath)) { exit 0 }

    Initialize-Log $stateDir
    $candidate = Read-JsonFile $candidatePath
    Remove-Item -LiteralPath $candidatePath -Force
    if ($null -eq $candidate) { exit 0 }

    $catalog = Read-JsonFile (Join-Path (Get-PluginRoot) 'catalog/tips.json')
    if ($null -eq $catalog) { exit 0 }
    $tip = $catalog.tips | Where-Object { $_.id -eq $candidate.id } | Select-Object -First 1
    if ($null -eq $tip) { exit 0 }

    $shownPath = Join-Path $stateDir 'shown.json'
    $shown = Read-JsonFile $shownPath
    $entries = @{}
    if ($null -ne $shown -and $null -ne $shown.entries)
    {
        foreach ($p in $shown.entries.PSObject.Properties) { $entries[$p.Name] = $p.Value }
    }

    $count = 0
    if ($entries.ContainsKey($tip.id)) { $count = [int]$entries[$tip.id].count }
    $maxShows = if ($null -ne $tip.maxShows) { [int]$tip.maxShows } else { 3 }
    if ($count -ge $maxShows)
    {
        Write-Log ("candidate {0} dropped: maxShows {1} reached" -f $tip.id, $maxShows)
        exit 0
    }

    $config = Read-JsonFile (Join-Path (Get-PluginRoot) 'catalog/config.json')
    $hours = if ($null -ne $config -and $null -ne $config.candidateCooldownHours) { [double]$config.candidateCooldownHours } else { 24 }
    if ($null -ne $shown -and -not [string]::IsNullOrWhiteSpace($shown.lastCandidateAt))
    {
        $elapsed = (Get-Date).ToUniversalTime() - ([datetime]$shown.lastCandidateAt).ToUniversalTime()
        if ($elapsed.TotalHours -lt $hours)
        {
            Write-Log ("candidate {0} dropped: cooldown {1:N1}h of {2}h" -f $tip.id, $elapsed.TotalHours, $hours)
            exit 0
        }
    }

    $installState = Get-InstallState $tip
    $userMessage = (New-TipText $tip $installState) + "`n`n" + (New-Question $tip $installState)
    $lead = 'Používateľ práve odkrokoval ručne to, čo tento skill spraví jedným príkazom.'

    Write-HookOutput 'UserPromptSubmit' $userMessage $lead (New-ActionHint $tip $installState)

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $entries[$tip.id] = [pscustomobject]@{ count = $count + 1; last = $now }
    Write-JsonFile $shownPath ([pscustomobject]@{
        lastShownAt      = if ($null -ne $shown) { $shown.lastShownAt } else { $null }
        lastCandidateAt  = $now
        entries          = [pscustomobject]$entries
    })

    Write-Log ("candidate {0} delivered on UserPromptSubmit | install={1}" -f $tip.id, $installState)
}
catch
{
    Write-Log ("ERROR (candidate): {0} | at {1}:{2}" -f
        $_.Exception.Message, $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
}

exit 0
