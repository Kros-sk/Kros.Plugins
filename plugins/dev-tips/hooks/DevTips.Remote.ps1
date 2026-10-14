#!/usr/bin/env pwsh
# Channel C: the authored tip files, read out of a shallow bare mirror. Nothing here is generated
# upstream - the source files are what the machine reads.

function Invoke-Git([string[]]$GitArgs)
{
    # Prompting must be impossible: a hidden process with no console would hang forever holding the
    # lock, and debug.log would never get a line because the script never reached one.
    $env:GIT_TERMINAL_PROMPT = '0'
    $out = & git -c credential.interactive=false -c core.askPass= @GitArgs 2>&1
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = ($out -join "`n") }
}

function Invoke-MirrorFetch([string]$MirrorPath, [string]$Origin, [string]$Branch)
{
    if (-not (Test-Path -LiteralPath (Join-Path $MirrorPath 'HEAD')))
    {
        New-Item -ItemType Directory -Path $MirrorPath -Force | Out-Null
        $init = Invoke-Git @('-C', $MirrorPath, 'init', '--bare', '--quiet')
        if (-not $init.ok) { return $false }
        Invoke-Git @('-C', $MirrorPath, 'remote', 'add', 'origin', $Origin) | Out-Null
    }

    $fetch = Invoke-Git @('-C', $MirrorPath, 'fetch', '--depth', '1', 'origin', $Branch)
    return $fetch.ok
}

function Get-RemoteTipFiles([string]$MirrorPath)
{
    $list = Invoke-Git @('-C', $MirrorPath, 'ls-tree', '-r', '--name-only', 'FETCH_HEAD')
    if (-not $list.ok) { return @() }

    $wanted = @($list.output -split "`n" | Where-Object {
        $_ -match 'tip\.json$' -or $_ -match 'dev-tips/(manual|config)\.json$'
    })

    $files = @()
    foreach ($path in $wanted)
    {
        $clean = $path.Trim()
        $blob = Invoke-Git @('-C', $MirrorPath, 'show', "FETCH_HEAD:$clean")
        if (-not $blob.ok) { continue }
        $json = $null
        try { $json = $blob.output | ConvertFrom-Json } catch { continue }
        $files += [pscustomobject]@{ path = $clean; json = $json }
    }
    return $files
}

function ConvertTo-Tip([string]$Path, $Json, $Marketplace)
{
    $parts = $Path -split '/'
    $plugin = if ($parts.Length -gt 1 -and $parts[0] -eq 'plugins') { $parts[1] } else { $null }

    # A skill is a directory with tip.json inside; everything else - commands, agents - is a
    # <name>.tip.json beside the file it describes. The second pattern has to stay generic, or a new
    # kind of folder silently yields an id with ".tip" still on the end.
    $name = if ($Path -match 'skills/([^/]+)/tip\.json$') { $Matches[1] }
            elseif ($Path -match '(?:^|/)([^/]+)\.tip\.json$') { $Matches[1] }
            else { [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '\.tip$', '' }

    $tip = $Json | Select-Object *
    $tip | Add-Member -NotePropertyName id -NotePropertyValue $name -Force
    # An agent is named, not invoked with a slash. Advertising "/qa-branch-tester" would tell people
    # to type a command that does not exist.
    $invocation = if ($Json.kind -eq 'agent') { $name } else { "/$name" }
    $tip | Add-Member -NotePropertyName ref -NotePropertyValue $invocation -Force
    $tip | Add-Member -NotePropertyName source -NotePropertyValue 'remote' -Force

    # Derived, not authored: a tip whose author forgot this would keep being offered to somebody who
    # already uses the tool, which is the one failure this plugin cannot afford.
    if ([string]::IsNullOrWhiteSpace($tip.suppressIfUsed))
    {
        $tip | Add-Member -NotePropertyName suppressIfUsed -NotePropertyValue $name -Force
    }
    if ($plugin)
    {
        $tip | Add-Member -NotePropertyName install `
                          -NotePropertyValue ([pscustomobject]@{ plugin = $plugin; marketplace = $Marketplace }) -Force
    }
    return $tip
}

function Write-RemoteSnapshot([string]$StateDir, [object[]]$Tips, $Config)
{
    $snapshot = [pscustomobject]@{
        fetchedAt = (Get-Date).ToUniversalTime().ToString('o')
        config    = $Config
        tips      = @($Tips)
    }

    # Temp file plus Move-Item: a direct write lets a SessionStart in another window read half a file.
    $final = Join-Path $StateDir 'remote-tips.json'
    $temp = "$final.$PID.tmp"
    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $final -Force
}

function Test-SnapshotStale([string]$StateDir, [int]$TtlHours)
{
    $path = Join-Path $StateDir 'remote-tips.json'
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    return ($age.TotalHours -ge $TtlHours)
}

# Writes files out of a bare mirror onto disk.
#
# The mirror has no working tree, so nothing in it can be read with Get-ChildItem. The documents
# are exported once per refresh and the session-start path stays a plain directory read: a hook
# that must not delay a session has no business spawning a git process per document.
function Export-MirrorFiles([string]$MirrorPath, [string]$TargetDir, [string]$Pattern)
{
    $list = Invoke-Git @('-C', $MirrorPath, 'ls-tree', '-r', '--name-only', 'FETCH_HEAD')
    if (-not $list.ok) { return 0 }

    $written = 0
    foreach ($path in @($list.output -split "`n"))
    {
        $clean = $path.Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean -notmatch $Pattern) { continue }

        $blob = Invoke-Git @('-C', $MirrorPath, 'show', "FETCH_HEAD:$clean")
        if (-not $blob.ok) { continue }

        $target = Join-Path $TargetDir $clean
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

        Set-Content -LiteralPath $target -Value $blob.output -Encoding UTF8
        $written++
    }

    return $written
}
