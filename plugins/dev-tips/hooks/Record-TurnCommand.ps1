#!/usr/bin/env pwsh
# PostToolUse (Bash): appends this turn's shell commands to a per-session ledger, which the Stop
# hook reads to decide whether the developer did by hand what an available skill does in one step.
# Runs on every Bash call, so it does nothing but append one line. Never blocks.

$ErrorActionPreference = 'SilentlyContinue'

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }

$command = $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

. (Join-Path $PSScriptRoot 'DevTips.Common.ps1')

try
{
    $stateDir = Get-StateDir
    $turnsDir = Join-Path $stateDir 'turns'
    if (-not (Test-Path -LiteralPath $turnsDir)) { New-Item -ItemType Directory -Path $turnsDir -Force | Out-Null }

    $ledger = Join-Path $turnsDir ((Get-SessionId $payload) + '.txt')
    $flat = ($command -replace '\r?\n', ' ; ')
    Add-Content -LiteralPath $ledger -Value $flat -Encoding UTF8
}
catch { }

exit 0
