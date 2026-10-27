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
