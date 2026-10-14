#!/usr/bin/env pwsh
# The one place tips come from. Hooks must not read catalog files directly.

. (Join-Path $PSScriptRoot 'DevTips.Discovery.ps1')
. (Join-Path $PSScriptRoot 'DevTips.RepoTips.ps1')
. (Join-Path $PSScriptRoot 'DevTips.Docs.ps1')

# Authored copy beats generated copy. Discovery exists so the plugin works before anyone writes
# anything; once somebody has written a tip, theirs is the better text and goes first.
function Get-SourceRank($Tip)
{
    if ($Tip.source -eq 'discovered') { return 1 }
    return 0
}

function Merge-Tips([object[]]$Authored, [object[]]$Discovered)
{
    # Authored first, so an authored tip keeps an authored tip's position. Assigning an existing key
    # in an ordered dictionary keeps the ORIGINAL slot, so inserting discovered first would have left
    # every overriding tip sitting in the discovered half of the list.
    $byId = [ordered]@{}
    foreach ($tip in @($Authored)) { if ($null -ne $tip) { $byId[$tip.id] = $tip } }
    foreach ($tip in @($Discovered))
    {
        if ($null -ne $tip -and -not $byId.Contains($tip.id)) { $byId[$tip.id] = $tip }
    }

    # The comma is load-bearing: returning @() unrolls to nothing, and the caller's property
    # becomes $null instead of an empty array.
    return ,@($byId.Values)
}

function Get-TipCatalog([string]$StateDir, [string]$PluginRoot, [string]$PluginsRoot, [string]$RepoRoot)
{
    if ([string]::IsNullOrWhiteSpace($PluginRoot)) { $PluginRoot = Get-PluginRoot }

    if ([string]::IsNullOrWhiteSpace($RepoRoot))
    {
        $RepoRoot = $env:CLAUDE_PROJECT_DIR
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Get-Location).Path }
    }

    # Injectable so a test never reads the real profile; defaulted so hooks need not know the path.
    if ([string]::IsNullOrWhiteSpace($PluginsRoot))
    {
        $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
        $PluginsRoot = Join-Path $userHome '.claude/plugins'
    }

    $packaged = Read-JsonFile (Join-Path $PluginRoot 'catalog/tips.json')
    $tips = @()
    if ($null -ne $packaged -and $null -ne $packaged.tips) { $tips = @($packaged.tips) }

    $config = Read-JsonFile (Join-Path $PluginRoot 'catalog/config.json')
    if ($null -eq $config) { $config = [pscustomobject]@{} }

    # Fetched policy overrides the packaged bootstrap, field by field. No value read from the
    # snapshot is bounded or second-guessed - see D8 in the analysis.
    $snapshot = Read-JsonFile (Join-Path $StateDir 'remote-tips.json')
    if ($null -ne $snapshot -and $null -ne $snapshot.config)
    {
        foreach ($p in $snapshot.config.PSObject.Properties)
        {
            $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }

    if ($null -ne $config.enabled -and -not $config.enabled)
    {
        return [pscustomobject]@{ tips = @(); config = $config }
    }

    # Authored copy is a channel, not a requirement. A skill carries its own description and
    # that is the tip text; a second, hand-written copy of the same sentence was work nobody
    # did - the catalog shipped eight authored tips and not one *.tip.json was ever written.
    # With the switch off the packaged catalog, the fetched tips and a repository's .dev-tips
    # are all passed over. The readers stay where they are, so turning the channel back on is
    # a config change and not a revert.
    $authoredOn = ($null -eq $config.authoredTips) -or [bool]$config.authoredTips

    if (-not $authoredOn)
    {
        $tips = @()
    }
    else
    {
        if ($null -ne $snapshot -and $null -ne $snapshot.tips) { $tips = @($tips) + @($snapshot.tips) }

        # Repository tips count as authored: they win over discovered copy for the same id.
        $tips = @($tips) + @(Get-RepoTips -RepoRoot $RepoRoot)
    }

    $discovered = @()
    try
    {
        # discoverMarketplaces is policy, so it travels in the fetched config like the rest of it.
        $discovered = Get-DiscoveredTips -StateDir $StateDir -PluginsRoot $PluginsRoot `
                                         -Marketplaces $config.discoverMarketplaces
    }
    catch { }

    # Documents are announcements, not tips: maxShows 1 and no usage suppression, because nobody
    # "already uses" a rule. They ride the same single notice per cooldown, and the baseline is
    # what keeps the backlog of everything written so far from eating it.
    if ($null -eq $config.announceDocs -or [bool]$config.announceDocs)
    {
        $spare = @($config.announceAnyway)
        $docs = @()

        # Each source baselines on its own, and only when it actually produced something: a source
        # that is not there yet must not be recorded as having been seen and found empty.
        foreach ($source in @(
            @{ name = 'adr';       tips = { Get-AdrTips -Root (Join-Path $StateDir 'adr/Adrs') } }
            @{ name = 'guideline'; tips = { Get-GuidelineTips -RepoRoot $RepoRoot } }
        ))
        {
            $found = @()
            try { $found = @(& $source.tips) } catch { $found = @() }
            if ($found.Count -eq 0) { continue }

            try
            {
                Initialize-DocsBaseline -StateDir $StateDir -Source $source.name -Tips $found -AnnounceAnyway $spare
            }
            catch
            {
                # The baseline writes shown.json. If that write fails, offering the documents anyway
                # would announce the whole backlog, so this source sits out the session instead.
                continue
            }
            $docs += $found
        }

        if ($docs.Count -gt 0) { $discovered = @($discovered) + @($docs) }
    }

    return [pscustomobject]@{ tips = (Merge-Tips -Authored $tips -Discovered $discovered); config = $config }
}
