BeforeAll {
    . (Join-Path $PSScriptRoot '../hooks/DevTips.Common.ps1')
}

Describe 'New-TipText' {
    It 'tells you how to run an installed tool' {
        $tip = [pscustomobject]@{ kind = 'command'; title = 'T'; body = 'b'; ref = '/git-diff' }

        New-TipText $tip 'installed' | Should -Match 'Spúšťa sa cez `/git-diff`'
    }

    It 'points at the document for a tip that is not a tool' {
        $tip = [pscustomobject]@{
            kind = 'rule'; title = 'T'; body = 'b'
            ref  = 'docs/architecture/rules/project-structure.md'
        }

        $text = New-TipText $tip 'n/a'

        $text | Should -Match 'docs/architecture/rules/project-structure\.md'
        $text | Should -Not -Match 'Spúšťa sa' -Because 'a document is read, not run'
    }

    It 'says nothing extra when such a tip carries no reference' {
        $tip = [pscustomobject]@{ kind = 'convention'; title = 'T'; body = 'b' }

        (New-TipText $tip 'n/a') -split "`n" | Should -HaveCount 1
    }
}
