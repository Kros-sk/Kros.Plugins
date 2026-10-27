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
    [string]$Origin = 'https://github.com/Kros-sk/Kros.AiDevTools.git',
    [string]$Branch = 'master',
    [int]$HistoryWindowDays = 90,
    [int]$HistoryTtlHours = 24,
    [string]$AdrOrigin = 'https://github.com/Kros-sk/Kros.ADR.git',
    [string]$AdrBranch = 'master',
    [int]$AdrTtlHours = 24,
    [int]$LockStaleMinutes = 30
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')
. (Join-Path $PSScriptRoot 'DevTips.History.ps1')
. (Join-Path $PSScriptRoot 'DevTips.Remote.ps1')

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

    # The ADRs, on their own stamp like every other job: a failing fetch here must not cost the
    # tips. The mirror is bare, so the documents are written out beside it - see Export-MirrorFiles.
    if (Test-StampStale -StateDir $StateDir -Name 'adr' -Hours $AdrTtlHours)
    {
        try
        {
            $adrMirror = Join-Path $StateDir 'adr-mirror'
            if (Invoke-MirrorFetch -MirrorPath $adrMirror -Origin $AdrOrigin -Branch $AdrBranch)
            {
                $written = Export-MirrorFiles -MirrorPath $adrMirror `
                                              -TargetDir (Join-Path $StateDir 'adr') -Pattern '\.md$'
                Update-Stamp -StateDir $StateDir -Name 'adr'
                Write-Log ('refresh: adr mirror fetched | documents={0}' -f $written)
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
    else
    {
        Write-Log 'refresh: adr stamp fresh, skipped'
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
