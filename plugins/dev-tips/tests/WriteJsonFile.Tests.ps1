BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
}

Describe 'Write-JsonFile while somebody else is reading' {
    # shown.json holds every count, every firstSeen and the cooldown, and it has more than one
    # writer and more than one reader: D17 measured four SessionStart runs in nineteen seconds.
    #
    # A write that truncates the file and fills it in afterwards leaves a window where the file on
    # disk is empty. A session that reads in that window sees no history at all and offers tips the
    # person has already answered; a process that dies in it loses the history for good.
    #
    # The window cannot be seen from inside the process doing the writing, so the writing happens
    # in a child and this test plays the other session: it reads, over and over, and asks whether
    # what it got back was ever unreadable.
    It 'is never caught with the file half written' {
        $state = New-TempDir
        $target = Join-Path $state 'shown.json'
        $ready = Join-Path $state 'ready'
        $child = Join-Path $state 'writer.ps1'
        $common = (Resolve-Path (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')).Path

        $q = { param($p) $p -replace "'", "''" }

        @"
. '$(& $q $common)'

`$entries = [ordered]@{}
foreach (`$i in 1..1500)
{
    `$entries["tip-`$i"] = [pscustomobject]@{ count = 1; last = '2026-10-14T06:00:00Z'; firstSeen = '2026-10-14T06:00:00Z' }
}
`$value = [pscustomobject]@{ lastShownAt = '2026-10-14T06:00:00Z'; entries = [pscustomobject]`$entries }

# Serialised once: the cost of ConvertTo-Json is not what this test is about, and leaving it in
# the loop would hide the write behind it.
`$json = `$value | ConvertTo-Json -Depth 8

Set-Content -LiteralPath '$(& $q $ready)' -Value 'go'

while (`$true) { Write-JsonFile '$(& $q $target)' `$value }
"@ | Set-Content -LiteralPath $child -Encoding UTF8

        $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $child -PassThru -WindowStyle Hidden
        try
        {
            $waited = 0
            while (-not (Test-Path -LiteralPath $ready) -and $waited -lt 200)
            {
                Start-Sleep -Milliseconds 50
                $waited++
            }
            Test-Path -LiteralPath $ready | Should -BeTrue -Because 'the writer has to be running for this to prove anything'

            # Wait for the first complete file, so a read before any write ever happened is not
            # counted as damage.
            $waited = 0
            while ($waited -lt 100)
            {
                $first = Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($first)) { break }
                Start-Sleep -Milliseconds 20
                $waited++
            }

            $reads = 0
            $halfWritten = 0
            $deadline = (Get-Date).AddSeconds(4)
            while ((Get-Date) -lt $deadline)
            {
                $raw = $null
                # A sharing violation means the reader could not look at all, which is a different
                # thing from looking and seeing rubbish. Only what was actually read is judged.
                try { $raw = [IO.File]::ReadAllText($target) } catch { continue }

                $reads++
                if ([string]::IsNullOrWhiteSpace($raw)) { $halfWritten++; continue }
                try { $null = $raw | ConvertFrom-Json } catch { $halfWritten++ }
            }

            $reads | Should -BeGreaterThan 50 -Because 'a handful of reads would not have looked hard enough'
            $halfWritten | Should -Be 0 -Because 'a reader that catches shown.json empty loses every count it holds'
        }
        finally
        {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
