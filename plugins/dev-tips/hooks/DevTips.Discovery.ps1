#!/usr/bin/env pwsh
# Channel A: tips about tools that are already on this machine. Needs no catalog and no network.

function Read-SkillFrontmatter([string]$Path)
{
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $null }

    $name = $null
    $description = $null
    for ($i = 1; $i -lt $lines.Count; $i++)
    {
        if ($lines[$i].Trim() -eq '---') { break }

        if ($lines[$i] -match '^name:\s*(.+)$') { $name = $Matches[1].Trim() }
        elseif ($lines[$i] -match '^description:\s*(.*)$')
        {
            $value = $Matches[1].Trim()

            # Half our skills write the description as a YAML block scalar. Taking the first line
            # literally yields a tip whose entire body is ">".
            if ($value -match '^[>|][-+]?$')
            {
                $separator = if ($value.StartsWith('|')) { "`n" } else { ' ' }
                $block = @()
                for ($j = $i + 1; $j -lt $lines.Count; $j++)
                {
                    if ($lines[$j].Trim() -eq '---') { break }
                    if ($lines[$j] -notmatch '^\s+\S') { break }
                    $block += $lines[$j].Trim()
                    $i = $j
                }
                $description = ($block -join $separator)
            }
            else
            {
                $description = $value
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return [pscustomobject]@{ name = $name; description = $description }
}

# Marketplaces whose plugins we are willing to advertise. Anything else on the machine is somebody
# else's tooling: we have not written its copy, we do not control when it changes, and a tip for it
# spends our one notice per cooldown on something that is not ours to recommend.
$script:DefaultMarketplaces = @('kros-ai-dev-tools', 'kros-plugins')

# A skill's description is written for a model deciding whether to invoke it, so it can run to
# several sentences. The notice is two lines. 240 is the cap every derived body gets - a skill's
# description, an ADR's decision, a guideline's opening - so they all read the same length.
function ConvertTo-TipBody([string]$Text, [int]$MaxLength = 240)
{
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $Text = $Text.Trim()
    if ($Text.Length -le $MaxLength) { return $Text }

    # Ending on a sentence reads like copy; ending mid-sentence reads like a bug. Take the last
    # sentence that fits, as long as it leaves something worth reading.
    $window = $Text.Substring(0, $MaxLength)
    $cut = -1
    foreach ($m in [regex]::Matches($window, '[.!?](\s|$)'))
    {
        # A Slovak abbreviation ends in a full stop and is not the end of anything: three real ADR
        # bodies were cut after "(napr." and reached the reader with the bracket still open. A
        # lowercase word of four letters or fewer before the stop is an abbreviation, not a sentence.
        # -cmatch, not -match: PowerShell matches case-insensitively by default, and under that
        # \p{Ll} folds and matches "CLI" too, which cut every sentence ending in an acronym.
        if ($window[$m.Index] -eq '.' -and
            $window.Substring(0, $m.Index) -cmatch '(?:^|[\s(])\p{Ll}{1,4}$') { continue }

        $candidate = $window.Substring(0, $m.Index + 1)
        $opens = ($candidate.ToCharArray() | Where-Object { $_ -eq '(' }).Count
        $closes = ($candidate.ToCharArray() | Where-Object { $_ -eq ')' }).Count
        if ($opens -ne $closes) { continue }

        $cut = $m.Index
    }
    if ($cut -ge 60) { return $window.Substring(0, $cut + 1) }

    $space = $window.LastIndexOf(' ')
    if ($space -lt 60) { $space = $MaxLength - 1 }
    return $window.Substring(0, $space).TrimEnd(',', ';', ' ', '-') + [char]0x2026
}

function Get-DiscoveredTips([string]$StateDir, [string]$PluginsRoot, [string[]]$Marketplaces)
{
    if ($null -eq $Marketplaces -or $Marketplaces.Count -eq 0) { $Marketplaces = $script:DefaultMarketplaces }

    $installed = Read-JsonFile (Join-Path $PluginsRoot 'installed_plugins.json')
    if ($null -eq $installed -or $null -eq $installed.plugins) { return @() }

    $tips = @()
    $seen = @{}

    foreach ($entry in $installed.plugins.PSObject.Properties)
    {
        $parts = $entry.Name -split '@', 2
        if ($parts.Count -ne 2) { continue }
        $pluginName = $parts[0]
        $marketplace = $parts[1]
        if ($Marketplaces -notcontains $marketplace) { continue }

        foreach ($install in @($entry.Value))
        {
            if ([string]::IsNullOrWhiteSpace($install.installPath)) { continue }
            $skillsDir = Join-Path $install.installPath 'skills'
            if (-not (Test-Path -LiteralPath $skillsDir)) { continue }

            foreach ($dir in Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue)
            {
                $fm = Read-SkillFrontmatter (Join-Path $dir.FullName 'SKILL.md')
                if ($null -eq $fm) { continue }
                if ($seen.ContainsKey($fm.name)) { continue }
                $seen[$fm.name] = $true

                # What the developer types is the plugin-qualified form. The bare name is not
                # guaranteed to resolve, and telling somebody to run a command that does not exist
                # is worse than saying nothing. `id` and `suppressIfUsed` stay bare: ids are how
                # authored tips override discovered ones, and Test-AlreadyUsed matches either form.
                $qualified = "$pluginName`:$($fm.name)"

                $tip = [pscustomobject]@{
                    id             = $fm.name
                    kind           = 'skill'
                    title          = "/$qualified"
                    body           = ConvertTo-TipBody $fm.description
                    ref            = "/$qualified"
                    repos          = @('*')
                    maxShows       = 3
                    suppressIfUsed = $fm.name
                    source         = 'discovered'
                    install        = [pscustomobject]@{ plugin = $pluginName; marketplace = $marketplace }
                }

                if (Test-AlreadyUsed $tip $StateDir) { continue }
                $tips += $tip
            }
        }
    }

    return $tips
}
