#!/usr/bin/env pwsh
# The selected tip, handed to whatever draws it. The band renders and takes the answer;
# it never decides which tip that is. Cooldown, maxShows, suppression and source ranking
# stay in Show-DevTip.ps1, in one place, whichever surface shows the result.
#
# Why a fixed directory rather than $CLAUDE_PLUGIN_DATA: a hooks module never receives
# that variable - the engine sets it for hook processes, and a module runs inside the
# engine. Verified with a probe rather than assumed. `$.plugin` carries `name` and `root`
# and no data directory, and the real one is named after the marketplace that installed
# us, which the module has no way to learn. So the handshake lives at a path both sides
# can spell, and it carries `stateDir` so the module can write answers back to the right
# place.
#
# One file per session, because two sessions starting together would otherwise each draw
# the tip the other was given. Both sides know the id: the hook from its stdin payload,
# the module from `classic.SessionStart`, whose `e` is that same payload.

function Get-SharedDir
{
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $dir = Join-Path $userHome '.claude/plugins/data/dev-tips-shared'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Write-PendingTip([string]$SharedDir, [string]$StateDir, [string]$SessionId, $Tip, [string]$InstallState, [string]$RepoRoot)
{
    if ([string]::IsNullOrWhiteSpace($SharedDir)) { $SharedDir = Get-SharedDir }
    if ([string]::IsNullOrWhiteSpace($SessionId)) { $SessionId = 'unknown' }

    $pending = [pscustomobject]@{
        id           = $Tip.id
        kind         = if ($Tip.kind) { $Tip.kind } else { 'tip' }
        title        = $Tip.title
        body         = $Tip.body
        # Only a document announced from its opening has one; everything else sends null.
        full         = $Tip.full
        ref          = $Tip.ref
        url          = $Tip.url
        source       = if ($Tip.source) { $Tip.source } else { 'packaged' }
        installState = $InstallState
        stateDir     = $StateDir
        # The repository this was picked in. The band reaches most handshakes through its
        # machine-wide fallback - the classic.SessionStart that would key them by session does not
        # reach the module, another plugin's hook takes the event first - so without this it would
        # tell somebody a guideline is "in this repository" about a file that is not there.
        repoRoot     = $RepoRoot
        sessionId    = $SessionId
        pickedAt     = (Get-Date).ToUniversalTime().ToString('o')
    }

    # One file per session means one file left behind per session. Nothing else would ever
    # remove them, so each write sweeps what the sessions before it left.
    foreach ($stale in Get-ChildItem -LiteralPath $SharedDir -Filter 'pending-*.json' -File -ErrorAction SilentlyContinue)
    {
        if ($stale.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-7))
        {
            Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # Temp plus move: the band may be reading this while SessionStart is still writing it.
    $final = Join-Path $SharedDir ("pending-$SessionId.json")
    $temp = "$final.$PID.tmp"
    $pending | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $final -Force
}
