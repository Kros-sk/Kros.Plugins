BeforeAll {
    $script:ConfigPath = Join-Path $PSScriptRoot '../catalog/config.json'
}

Describe 'Shipped config.json' {
    It 'does not ship test cooldowns' {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.cooldownDays | Should -BeGreaterOrEqual 1
        $config.candidateCooldownHours | Should -BeGreaterOrEqual 1
    }
}
