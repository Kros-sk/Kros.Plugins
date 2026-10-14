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
        $flat = ($para -replace '\s+', ' ').Trim()
        if (-not [string]::IsNullOrWhiteSpace($flat)) { return $flat }
    }
    return $null
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
        $raw = if (-not [string]::IsNullOrWhiteSpace($fm.tip)) { $fm.tip }
               else { Get-SectionParagraph $text 'Rozhodnutie|Decision' }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $title = if (-not [string]::IsNullOrWhiteSpace($fm.title)) { $fm.title } else { $file.BaseName }

        $tips += [pscustomobject]@{
            id       = $file.BaseName
            kind     = 'adr'
            title    = $title
            body     = ConvertTo-TipBody $raw
            ref      = $file.Name
            repos    = @('*')
            maxShows = 1
            source   = 'docs'
        }
    }

    # No comma wrapper, for the reason spelled out in DevTips.RepoTips.ps1.
    return $tips
}
