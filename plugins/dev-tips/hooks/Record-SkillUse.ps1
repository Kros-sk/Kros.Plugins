#!/usr/bin/env pwsh
# PreToolUse (Skill): records that this developer actually uses a skill, so no tip ever recommends
# something they already know. Cheaper and more exact than parsing transcripts. Never blocks.

$ErrorActionPreference = 'SilentlyContinue'

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }

$skill = $payload.tool_input.skill
if ([string]::IsNullOrWhiteSpace($skill)) { exit 0 }

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')

try
{
    $stateDir = Get-StateDir
    $path = Join-Path $stateDir 'usage.json'

    $usage = Read-JsonFile $path
    $map = @{}
    if ($null -ne $usage)
    {
        foreach ($p in $usage.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }

    $count = 0
    if ($map.ContainsKey($skill)) { $count = [int]$map[$skill].count }
    $map[$skill] = [pscustomobject]@{
        count = $count + 1
        last  = (Get-Date).ToUniversalTime().ToString('o')
    }

    Write-JsonFile $path ([pscustomobject]$map)
}
catch { }

exit 0
