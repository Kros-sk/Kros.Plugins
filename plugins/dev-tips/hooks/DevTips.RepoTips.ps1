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

    # No comma wrapper here, unlike Merge-Tips: every caller consumes this inline as @(Get-RepoTips ...),
    # and the pipeline would unroll the wrapper, turning an empty result into one empty-array element.
    return $tips
}
