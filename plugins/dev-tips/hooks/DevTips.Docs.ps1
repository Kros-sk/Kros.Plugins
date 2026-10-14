#!/usr/bin/env pwsh
# Documents that are rules rather than tools: ADRs and guidelines.
#
# The text is the document's own. A skill carries a `description`; an ADR carries a title and a
# decision, a guideline a heading and a first paragraph. Nobody writes a second copy of either -
# see D18. An optional `tip:` line in the document's front matter is the one exception, and it
# lives in the document, which is the whole point.

function Read-DocFrontMatter([string]$Text)
{
    $fm = [ordered]@{}
    if ($Text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---') { return [pscustomobject]$fm }

    foreach ($line in ($Matches[1] -split '\r?\n'))
    {
        if ($line -match '^\s*([A-Za-z][\w-]*)\s*:\s*(.*)$')
        {
            $fm[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim()
        }
    }
    return [pscustomobject]$fm
}

# A document is written for a markdown renderer; the band has none and draws plain Text. Emphasis
# and code spans would reach the person as literal asterisks and backticks, so they come off here.
# Link text is kept and its target dropped: the band has nowhere to follow it to.
function Remove-DocMarkup([string]$Text)
{
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    # A leading list marker is the clearest case: the paragraph was a bullet, and the band is one
    # line of prose. The marker goes; the sentence after it stands on its own.
    $out = $Text -replace '^\s*[-*+]\s+', ''
    $out = $out -replace '\[([^\]]+)\]\([^)]*\)', '$1'
    $out = $out -replace '`+([^`]*)`+', '$1'
    $out = $out -replace '\*\*([^*]+)\*\*', '$1'
    $out = $out -replace '(?<![\w*])\*([^*]+)\*(?![\w*])', '$1'
    $out = $out -replace '(?<![\w_])_([^_]+)_(?![\w_])', '$1'

    return $out.Trim()
}

# The first paragraph under a heading, whatever that heading is called in this repository.
function Get-SectionParagraph([string]$Text, [string]$HeadingPattern)
{
    # Single-quoted and formatted, never interpolated: in a double-quoted string PowerShell reads
    # the regex's `$(` as a subexpression and runs `.*?` as a command.
    # `\r?` before the `$`: in multiline mode `$` matches before the `\n`, so on a CRLF document
    # the carriage return sits between the heading and the anchor. Every document in Kros.ADR is
    # CRLF, and without this the reader found every heading in the fixtures and none in the repo.
    $pattern = '(?ms)^##[ \t]*(?:{0})[ \t]*\r?$(.*?)(?=^##[ \t]|\z)' -f $HeadingPattern

    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) { return $null }

    foreach ($para in ($m.Groups[1].Value.Trim() -split '\r?\n\s*\r?\n'))
    {
        $prose = ConvertTo-Prose $para
        if (-not [string]::IsNullOrWhiteSpace($prose)) { return $prose }
    }
    return $null
}

# One block of a document as one line of prose, or nothing when it is not prose at all.
#
# A sub-heading and a table row are not sentences: ADR 0018 opens its decision with `### Definície
# pojmov` and a table, and announcing that heading tells the reader nothing. A list is prose once
# the markers are gone - joined with a semicolon, because seven of the twenty real bodies kept an
# interior `- ` when only the leading one was stripped.
function ConvertTo-Prose([string]$Block)
{
    $lines = @()
    foreach ($line in ($Block -split '\r?\n'))
    {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t.StartsWith('#')) { return $null }
        if ($t.StartsWith('|')) { return $null }
        if ($t -match '^<!--') { continue }

        # Numbered items lose their number for the same reason bullets lose their marker: flattened
        # into one line the numbers are markup, and the last one survives the trim as an orphan.
        $lines += ($t -replace '^(?:[-*+]|\d+[.)])\s+', '')
    }

    if ($lines.Count -eq 0) { return $null }

    # Each item ends in its own full stop or not at all; a semicolon between them keeps one line
    # readable without claiming the author wrote it as a sentence.
    $joined = ($lines -join '; ') -replace '\.\s*;', '.'
    return (($joined -replace '\s+', ' ').Trim())
}

function Get-AdrTips([string]$Root)
{
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return @() }

    $tips = @()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Filter '*.md' -File -ErrorAction SilentlyContinue)
    {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $fm = Read-DocFrontMatter $text
        # The decision first, because that is what the ADR is for. Where it opens with a table or a
        # sub-heading - 2 of the 22 real ones do - the context says the same thing in prose, and a
        # true sentence from the context beats a heading from the decision. With neither, say
        # nothing: the same treatment an ADR with no decision section already gets.
        $raw = $fm.tip
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = Get-SectionParagraph $text 'Rozhodnutie|Decision' }
        # Only when the decision is there but says nothing a person can read. An ADR with no
        # decision section at all is unfinished, and its context describes a problem, not a rule.
        if ([string]::IsNullOrWhiteSpace($raw) -and $text -match '(?m)^##[ 	]*(?:Rozhodnutie|Decision)[ 	]*
?$')
        {
            $raw = Get-SectionParagraph $text 'Kontext|Context'
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $title = if (-not [string]::IsNullOrWhiteSpace($fm.title)) { $fm.title } else { $file.BaseName }

        $tips += [pscustomobject]@{
            id       = $file.BaseName
            kind     = 'adr'
            title    = $title
            body     = ConvertTo-TipBody (Remove-DocMarkup $raw)
            # The path inside the mirror, not the bare name: the band composes an absolute path
            # from the state directory and this, so the model can actually open the document.
            ref      = "Adrs/$($file.Name)"
            repos    = @('*')
            maxShows = 1
            source   = 'docs'
        }
    }

    # No comma wrapper, for the reason spelled out in DevTips.RepoTips.ps1.
    return $tips
}

function Get-GuidelineTips([string]$RepoRoot)
{
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return @() }
    $dir = Join-Path $RepoRoot 'docs/guidelines'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }

    $tips = @()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $fm = Read-DocFrontMatter $text
        # `\s*$` rather than `[ \t]*$`: \s takes the carriage return, which every real document has.
        $heading = [regex]::Match($text, '(?m)^#[ \t]+(.+?)\s*$')
        $title = if (-not [string]::IsNullOrWhiteSpace($fm.title)) { $fm.title }
                 elseif ($heading.Success) { $heading.Groups[1].Value } else { $file.BaseName }

        $raw = $fm.tip
        if ([string]::IsNullOrWhiteSpace($raw) -and $heading.Success)
        {
            $after = $text.Substring($heading.Index + $heading.Length)
            foreach ($para in ($after.Trim() -split '\r?\n\s*\r?\n'))
            {
                $flat = ($para -replace '\s+', ' ').Trim()
                if ([string]::IsNullOrWhiteSpace($flat)) { continue }

                # A heading straight after a heading means the document opens with no prose of its
                # own. Announcing the next section's title would misrepresent it, so say nothing.
                if ($flat.StartsWith('#')) { break }
                $raw = $flat
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $tips += [pscustomobject]@{
            id       = "guideline-$($file.BaseName)"
            kind     = 'guideline'
            title    = $title
            body     = ConvertTo-TipBody (Remove-DocMarkup $raw)
            ref      = "docs/guidelines/$($file.Name)"
            repos    = @('*')
            maxShows = 1
            source   = 'docs'
        }
    }

    return $tips
}

# Everything that exists the first time this runs is history, not news. Without it, switching the
# channel on would queue every document on the machine and the skills would not get a turn for
# months.
#
# Once only, and for the same reason the state merge is once only: a second pass would silence
# every document written since the first, and those are exactly the ones worth announcing.
function Initialize-DocsBaseline([string]$StateDir, $Tips, [string[]]$AnnounceAnyway, [string]$Source = 'docs')
{
    # Per source, because the sources do not arrive together. Guidelines are read live from the
    # repository; the ADR mirror is fetched by the Stop hook, so the first session on a fresh
    # install sees guidelines and no ADRs at all. One shared marker would close the baseline on
    # that partial set, and every ADR written before the install would then be announced as news -
    # the backlog this function exists to prevent.
    $marker = Join-Path $StateDir ".docs-baseline-$Source"
    $spare = @($AnnounceAnyway | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if (Test-Path -LiteralPath $marker)
    {
        Clear-BaselinedEntries -StateDir $StateDir -Ids $spare
        return
    }

    $keep = @{}
    $shown = Read-JsonFile (Join-Path $StateDir 'shown.json')
    if ($null -ne $shown -and $null -ne $shown.entries)
    {
        foreach ($p in $shown.entries.PSObject.Properties) { $keep[$p.Name] = $p.Value }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($tip in @($Tips))
    {
        if ($spare -contains $tip.id) { continue }
        if ($keep.ContainsKey($tip.id)) { continue }

        $max = if ($null -ne $tip.maxShows) { [int]$tip.maxShows } else { 1 }
        # Marked as the baseline's own doing, so naming the id in announceAnyway later can undo it.
        # Without the mark there is no way to tell this apart from a tip the person was really shown.
        $keep[$tip.id] = [pscustomobject]@{ count = $max; last = $now; firstSeen = $now; baselined = $true }
    }

    # The cooldown is carried through untouched: a baseline is bookkeeping, not a showing, and
    # moving lastShownAt here would cost the person their next real tip.
    Write-JsonFile (Join-Path $StateDir 'shown.json') ([pscustomobject]@{
        lastShownAt     = if ($null -ne $shown) { $shown.lastShownAt } else { $null }
        lastCandidateAt = if ($null -ne $shown) { $shown.lastCandidateAt } else { $null }
        entries         = [pscustomobject]$keep
    })

    $now | Set-Content -LiteralPath $marker -Encoding UTF8
}

# Releases documents the baseline silenced, when somebody names them in `announceAnyway` later.
#
# Without this the one operational lever the feature has works on the first run and is inert for
# ever after, with no error and no log line to say so. Only entries the baseline itself wrote are
# touched: a document the person was really shown stays shown.
function Clear-BaselinedEntries([string]$StateDir, [string[]]$Ids)
{
    if ($null -eq $Ids -or $Ids.Count -eq 0) { return }

    $shown = Read-JsonFile (Join-Path $StateDir 'shown.json')
    if ($null -eq $shown -or $null -eq $shown.entries) { return }

    $keep = @{}
    $released = $false
    foreach ($p in $shown.entries.PSObject.Properties)
    {
        if (($Ids -contains $p.Name) -and $p.Value.baselined) { $released = $true; continue }
        $keep[$p.Name] = $p.Value
    }
    if (-not $released) { return }

    Write-JsonFile (Join-Path $StateDir 'shown.json') ([pscustomobject]@{
        lastShownAt     = $shown.lastShownAt
        lastCandidateAt = $shown.lastCandidateAt
        entries         = [pscustomobject]$keep
    })
}
