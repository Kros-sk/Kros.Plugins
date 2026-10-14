function New-TempDir
{
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('devtips-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-FakePluginRoot([hashtable]$Tips, [hashtable]$Config)
{
    $root = New-TempDir
    New-Item -ItemType Directory -Path (Join-Path $root 'catalog') -Force | Out-Null
    $catalog = [pscustomobject]@{ version = 2; tips = @($Tips) }
    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'catalog/tips.json') -Encoding UTF8
    ([pscustomobject]$Config) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'catalog/config.json') -Encoding UTF8
    return $root
}

function New-FixtureOriginRepo
{
    # A stand-in for Kros.AiDevTools: a real git repo on disk, no network involved.
    $repo = New-TempDir
    $skillDir = Join-Path $repo 'plugins/kros-shared/skills/git-diff'
    New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo 'dev-tips') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo '.claude-plugin') -Force | Out-Null

    ([pscustomobject]@{ kind = 'command'; title = 'From the source'; body = 'authored'; repos = @('*'); maxShows = 2 }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $skillDir 'tip.json') -Encoding UTF8

    # The SKILL.md has to exist: a tip beside a tool that is not there is exactly what the validator
    # is for, so a fixture without it is not a well-formed repository.
    @('---', 'name: git-diff', 'description: Analyze git changes against master.', '---') |
        Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Encoding UTF8
    ([pscustomobject]@{ ttlHours = 24; cooldownDays = 2; enabled = $true }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo 'dev-tips/config.json') -Encoding UTF8
    ([pscustomobject]@{ name = 'kros-ai-dev-tools' }) |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $repo '.claude-plugin/marketplace.json') -Encoding UTF8

    & git -C $repo init --initial-branch=master --quiet
    & git -C $repo -c user.email=t@t -c user.name=t add -A
    & git -C $repo -c user.email=t@t -c user.name=t commit -q -m 'fixture'
    return $repo
}

function New-FakePluginsRoot
{
    # Builds ~/.claude/plugins with one installed plugin carrying one skill.
    $root = New-TempDir
    $installPath = Join-Path $root 'cache/kros-ai-dev-tools/kros-shared/abc123'
    New-Item -ItemType Directory -Path (Join-Path $installPath 'skills/git-diff') -Force | Out-Null

    @(
        '---'
        'name: git-diff'
        'description: Analyze git changes against master.'
        '---'
        ''
        'body text'
    ) | Set-Content -LiteralPath (Join-Path $installPath 'skills/git-diff/SKILL.md') -Encoding UTF8

    # A second plugin from somebody else's marketplace, to prove it is filtered out.
    $foreignPath = Join-Path $root 'cache/claude-plugins-official/superpowers/6.3.0'
    New-Item -ItemType Directory -Path (Join-Path $foreignPath 'skills/using-git-worktrees') -Force | Out-Null
    @(
        '---'
        'name: using-git-worktrees'
        'description: Use when starting feature work that needs isolation.'
        '---'
    ) | Set-Content -LiteralPath (Join-Path $foreignPath 'skills/using-git-worktrees/SKILL.md') -Encoding UTF8

    $installed = [pscustomobject]@{
        version = 2
        plugins = [pscustomobject]@{
            'kros-shared@kros-ai-dev-tools' = @(
                [pscustomobject]@{ scope = 'user'; installPath = $installPath; version = 'abc123' }
            )
            'superpowers@claude-plugins-official' = @(
                [pscustomobject]@{ scope = 'user'; installPath = $foreignPath; version = '6.3.0' }
            )
        }
    }
    $installed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'installed_plugins.json') -Encoding UTF8
    return $root
}

function New-FakeTranscripts
{
    # Two skill invocations and one line that is not one, in the layout Claude Code uses.
    $root = New-TempDir
    $project = Join-Path $root 'C--Users-someone-Projects-Invoicing'
    New-Item -ItemType Directory -Path $project -Force | Out-Null

    @(
        '{"type":"assistant","timestamp":"2026-09-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"kros-shared:git-diff"}}]}}'
        '{"type":"assistant","timestamp":"2026-09-02T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"kros-shared:git-diff"}}]}}'
        '{"type":"user","timestamp":"2026-09-02T10:01:00.000Z","message":{"content":"no skill here"}}'
    ) | Set-Content -LiteralPath (Join-Path $project 'session-1.jsonl') -Encoding UTF8

    return $root
}

function New-FixtureAdrRepo
{
    # A stand-in for Kros.ADR: a real git repo on disk, no network involved.
    $repo = New-TempDir
    $dir = Join-Path $repo 'Adrs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    @('---', 'title: Prvé rozhodnutie', '---', '', '## Rozhodnutie', '', 'Robíme to takto.') |
        Set-Content -LiteralPath (Join-Path $dir '0001-prve.md') -Encoding UTF8

    & git -C $repo init --initial-branch=master --quiet
    & git -C $repo -c user.email=t@t -c user.name=t add -A
    & git -C $repo -c user.email=t@t -c user.name=t commit -q -m 'adr fixture'
    return $repo
}
