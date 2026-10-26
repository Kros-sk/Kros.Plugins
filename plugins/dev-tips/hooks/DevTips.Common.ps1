#!/usr/bin/env pwsh
# Shared helpers for the dev-tips hooks. Dot-sourced; defines no top-level side effects.

$script:LogPath = $null

function Get-PluginRoot
{
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PLUGIN_ROOT)) { return $env:CLAUDE_PLUGIN_ROOT }
    return (Split-Path -Parent $PSScriptRoot)
}

# One directory, whatever loaded the plugin.
#
# CLAUDE_PLUGIN_DATA is named after the marketplace the plugin came from, so the same
# plugin on the same machine was handed dev-tips-kros-plugins when it ran from the repo,
# dev-tips-inline when it ran from the cache, and dev-tips-local when the variable was
# missing. Each kept its own shown.json and usage.json, so the cooldown, maxShows and the
# usage suppression were counted three times over and a tip already seen could return.
#
# This is the same answer the handshake already uses: a path both sides can spell.
function Get-StateDir
{
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $dir = Join-Path $userHome '.claude/plugins/data/dev-tips-state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Merge-LegacyState -TargetDir $dir -LegacyDirs @(
        (Join-Path $userHome '.claude/plugins/data/dev-tips-kros-plugins')
        (Join-Path $userHome '.claude/plugins/data/dev-tips-inline')
        (Join-Path $userHome '.claude/plugins/data/dev-tips-local')
    )

    return $dir
}

# Folds what the split directories knew into the one that is kept, once.
#
# Once only: a second pass would resurrect what the person has since cleared, and clearing
# state is how somebody silences a tip by hand.
function Merge-LegacyState([string]$TargetDir, [string[]]$LegacyDirs)
{
    $marker = Join-Path $TargetDir '.merged'
    if (Test-Path -LiteralPath $marker) { return }

    $usage = [ordered]@{}
    $entries = [ordered]@{}
    $lastShownAt = $null
    $lastCandidateAt = $null

    foreach ($dir in @($LegacyDirs))
    {
        if (-not (Test-Path -LiteralPath $dir)) { continue }

        $theirUsage = Read-JsonFile (Join-Path $dir 'usage.json')
        if ($null -ne $theirUsage)
        {
            foreach ($p in $theirUsage.PSObject.Properties)
            {
                if (-not $usage.Contains($p.Name)) { $usage[$p.Name] = $p.Value }
            }
        }

        $theirShown = Read-JsonFile (Join-Path $dir 'shown.json')
        if ($null -eq $theirShown) { continue }

        if ($theirShown.lastShownAt -and ($null -eq $lastShownAt -or $theirShown.lastShownAt -gt $lastShownAt))
        {
            $lastShownAt = $theirShown.lastShownAt
        }
        if ($theirShown.lastCandidateAt -and ($null -eq $lastCandidateAt -or $theirShown.lastCandidateAt -gt $lastCandidateAt))
        {
            $lastCandidateAt = $theirShown.lastCandidateAt
        }

        if ($null -eq $theirShown.entries) { continue }
        foreach ($p in $theirShown.entries.PSObject.Properties)
        {
            $theirs = $p.Value
            if (-not $entries.Contains($p.Name)) { $entries[$p.Name] = $theirs; continue }

            $mine = $entries[$p.Name]
            # The highest count, or a tip already seen its limit would be offered again.
            $count = [Math]::Max([int]$mine.count, [int]$theirs.count)
            $last = if ($theirs.last -gt $mine.last) { $theirs.last } else { $mine.last }
            # firstSeen is the earliest: it says how new the tip is to this person.
            $firstSeen = if ($theirs.firstSeen -and ($null -eq $mine.firstSeen -or $theirs.firstSeen -lt $mine.firstSeen))
                         { $theirs.firstSeen } else { $mine.firstSeen }

            $entries[$p.Name] = [pscustomobject]@{ count = $count; last = $last; firstSeen = $firstSeen }
        }
    }

    if ($usage.Count -gt 0)
    {
        $merged = Read-JsonFile (Join-Path $TargetDir 'usage.json')
        if ($null -eq $merged) { $merged = [pscustomobject]@{} }
        foreach ($key in $usage.Keys)
        {
            if ($null -eq $merged.PSObject.Properties[$key])
            {
                $merged | Add-Member -NotePropertyName $key -NotePropertyValue $usage[$key] -Force
            }
        }
        Write-JsonFile (Join-Path $TargetDir 'usage.json') $merged
    }

    if ($entries.Count -gt 0 -or $lastShownAt)
    {
        $shown = Read-JsonFile (Join-Path $TargetDir 'shown.json')
        $keep = @{}
        if ($null -ne $shown -and $null -ne $shown.entries)
        {
            foreach ($p in $shown.entries.PSObject.Properties) { $keep[$p.Name] = $p.Value }
        }
        foreach ($key in $entries.Keys) { if (-not $keep.ContainsKey($key)) { $keep[$key] = $entries[$key] } }

        Write-JsonFile (Join-Path $TargetDir 'shown.json') ([pscustomobject]@{
            lastShownAt     = if ($null -ne $shown -and $shown.lastShownAt -gt $lastShownAt) { $shown.lastShownAt } else { $lastShownAt }
            lastCandidateAt = if ($null -ne $shown -and $shown.lastCandidateAt -gt $lastCandidateAt) { $shown.lastCandidateAt } else { $lastCandidateAt }
            entries         = [pscustomobject]$keep
        })
    }

    (Get-Date).ToUniversalTime().ToString('o') | Set-Content -LiteralPath $marker -Encoding UTF8
}

function Initialize-Log([string]$StateDir)
{
    $script:LogPath = Join-Path $StateDir 'debug.log'
}

function Write-Log([string]$Message)
{
    if (-not $script:LogPath) { return }
    try
    {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            ((Get-Item -LiteralPath $script:LogPath).Length -gt 65536))
        {
            $keep = Get-Content -LiteralPath $script:LogPath -Tail 200 -Encoding UTF8
            Set-Content -LiteralPath $script:LogPath -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value (
            '{0}  {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message)
    }
    catch { }
}

function Read-JsonFile([string]$Path)
{
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# Written beside the target and moved into place, the way Write-PendingTip and Write-RemoteSnapshot
# already do it.
#
# Set-Content truncates and then writes. shown.json holds every count, every firstSeen and the
# cooldown, so a process that dies in that gap loses the lot and the developer sees tips they have
# already answered. The move is the one step that is atomic on both filesystems we run on.
function Write-JsonFile([string]$Path, $Value)
{
    $temp = "$Path.$PID.tmp"
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-SessionId($Payload)
{
    if ($null -ne $Payload -and -not [string]::IsNullOrWhiteSpace($Payload.session_id)) { return $Payload.session_id }
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_SESSION_ID)) { return $env:CLAUDE_CODE_SESSION_ID }
    return 'unknown'
}

# The top of the working tree the session is in, which is what a guideline's path is relative to.
# Outside a repository, wherever the hook started: there is nothing better to say.
function Get-RepoRoot
{
    $root = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }

    $top = & git -C $root rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($top)) { $root = $top.Trim() }

    return $root
}

function Get-RepoName
{
    $root = Get-RepoRoot
    return (Split-Path -Leaf $root)
}

function Test-RepoMatch($Tip, [string]$RepoName)
{
    foreach ($pattern in $Tip.repos)
    {
        if ($pattern -eq '*') { return $true }
        if ($RepoName -like "*$pattern*") { return $true }
    }
    return $false
}

function Get-InstallState($Tip)
{
    if ($null -eq $Tip.install) { return 'n/a' }

    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $installed = Read-JsonFile (Join-Path $userHome '.claude/plugins/installed_plugins.json')
    $known = Read-JsonFile (Join-Path $userHome '.claude/plugins/known_marketplaces.json')

    $key = "$($Tip.install.plugin)@$($Tip.install.marketplace)"
    if ($null -ne $installed -and $null -ne $installed.plugins -and
        $null -ne $installed.plugins.PSObject.Properties[$key]) { return 'installed' }
    if ($null -ne $known -and $null -ne $known.PSObject.Properties[$Tip.install.marketplace]) { return 'marketplace-only' }
    return 'missing'
}

function Test-AlreadyUsed($Tip, [string]$StateDir)
{
    $key = $Tip.suppressIfUsed
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }
    $usage = Read-JsonFile (Join-Path $StateDir 'usage.json')
    if ($null -eq $usage) { return $false }

    # A skill is invoked either bare ("git-diff") or plugin-qualified ("kros-shared:git-diff").
    foreach ($p in $usage.PSObject.Properties)
    {
        if ($p.Name -eq $key -or $p.Name -like "*:$key") { return $true }
    }
    return $false
}

function New-TipText($Tip, [string]$InstallState)
{
    $lines = @("💡 **$($Tip.title)** — $($Tip.body)")
    switch ($InstallState)
    {
        'installed' { if ($Tip.ref) { $lines += "Spúšťa sa cez ``$($Tip.ref)``." } }
        'marketplace-only' { $lines += "Nemáš ho nainštalovaný: ``/plugin install $($Tip.install.plugin)@$($Tip.install.marketplace)``" }
        'missing' { $lines += "Nemáš ani ten marketplace: ``/plugin marketplace add $($Tip.install.repo)``, potom ``/plugin install $($Tip.install.plugin)@$($Tip.install.marketplace)``" }

        # A rule, an ADR or a convention has nothing to install and nothing to run. Its ref is where
        # to read it, and without this branch it was silently dropped.
        default { if ($Tip.ref) { $lines += "Celé znenie: ``$($Tip.ref)``" } }
    }
    return ($lines -join "`n")
}

function New-Question($Tip, [string]$InstallState)
{
    switch ($InstallState)
    {
        'installed' { return 'Chceš, aby som ti ukázal, ako sa to používa?' }
        'marketplace-only' { return 'Mám ti ho pridať?' }
        'missing' { return 'Mám ti pridať marketplace aj plugin?' }
        default { return 'Chceš o tom vedieť viac?' }
    }
}

function New-ActionHint($Tip, [string]$InstallState)
{
    switch ($InstallState)
    {
        'installed' { return "vysvetli mu, na čo je ``$($Tip.ref)`` a ako sa používa" }
        'marketplace-only' { return "spusti ``claude plugin install $($Tip.install.plugin)@$($Tip.install.marketplace)``" }
        'missing' { return "spusti ``claude plugin marketplace add $($Tip.install.repo)`` a potom ``claude plugin install $($Tip.install.plugin)@$($Tip.install.marketplace)``" }
        default { return 'povedz mu k tomu viac' }
    }
}

function Test-IsDesktop
{
    return ($env:CLAUDE_CODE_ENTRYPOINT -eq 'claude-desktop') -or
        (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_DESKTOP_APP_VERSION))
}

# Emits the hook JSON for one notice. The desktop app never renders `systemMessage`
# (see docs/desktop-systemmessage-not-rendered.md), so there the text has to travel
# through the model instead.
function Write-HookOutput([string]$EventName, [string]$UserMessage, [string]$Lead, [string]$ActionHint)
{
    if (Test-IsDesktop)
    {
        $context = @"
<dev-tip>
$Lead Vypíš nasledujúci blok DOSLOVA — bez preformulovania, bez úvodnej vety a bez komentára za ním.
Potom normálne pokračuj odpoveďou na to, čo používateľ napísal.

$UserMessage

Ak jeho správa odpovedá na tú otázku, vybav to: $ActionHint
Tip nesmie ovplyvniť tvoj postup pri jeho úlohe — nezačni kvôli nemu používať iný nástroj, ako by si
použil inak.
</dev-tip>
"@
        $output = [ordered]@{}
    }
    else
    {
        $context = @"
<dev-tip>
Používateľovi bol práve zobrazený tip ako systémová správa. NEOPAKUJ mu ho a nezačínaj ním odpoveď.
Ak jeho správa odpovedá na otázku v tom tipe, vybav to: $ActionHint
Inak ho úplne ignoruj. Nesmie ovplyvniť tvoj postup pri jeho úlohe.
</dev-tip>
"@
        $output = [ordered]@{ systemMessage = $UserMessage }
    }

    $output.hookSpecificOutput = [pscustomobject]@{
        hookEventName     = $EventName
        additionalContext = $context
    }
    [pscustomobject]$output | ConvertTo-Json -Depth 6 -Compress
}

function Test-StampStale([string]$StateDir, [string]$Name, [int]$Hours)
{
    $path = Join-Path $StateDir "$Name.stamp"
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return ($age.TotalHours -ge $Hours)
}

function Update-Stamp([string]$StateDir, [string]$Name)
{
    (Get-Date).ToUniversalTime().ToString('o') |
        Set-Content -LiteralPath (Join-Path $StateDir "$Name.stamp") -Encoding UTF8
}

function Start-DataRefresh([string]$StateDir, [string]$HookRoot)
{
    # -WindowStyle Hidden, never -NoNewWindow: the child must not inherit the hook's stdout, which
    # Claude Code parses as JSON.
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', (Join-Path $HookRoot 'Update-DevTipsData.ps1'),
        '-StateDir', $StateDir) | Out-Null
}
