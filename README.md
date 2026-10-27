# Kros Plugins

Internal Claude Code plugin marketplace for building and packaging plugins for the **KROS plugin store** (the business app marketplace).

## Plugins

| Plugin | Stack | Description |
|--------|-------|-------------|
| **plugin-builder** | Any | Interactive workflow that builds a valid, upload-ready plugin package (`manifest.json` + `.zip`) for the KROS plugin store — validates every field against the Framework contract and can validate/deploy against a running app. |
| **dev-tips** | Any | Shows one short, rate-limited tip at session start about internal tooling you may not know exists — skills, commands, agents, ADRs, team conventions — and asks whether you want it. |

## Installation

From within Claude Code (interactive mode):

```
# 1. Add Kros marketplace (one-time)
/plugin marketplace add Kros-sk/Kros.Plugins

# 2. Install the plugin
/plugin install plugin-builder@kros-plugins
```

Or from the terminal (CLI):

```bash
# 1. Add Kros marketplace (one-time)
claude plugin marketplace add Kros-sk/Kros.Plugins

# 2. Install the plugin
claude plugin install plugin-builder@kros-plugins
```

You can also browse available plugins interactively with `/plugin` → **Discover** tab.

To pick up new versions after a plugin is updated here: `/plugin marketplace update kros-plugins`.

## Structure

```
.claude-plugin/marketplace.json     # Marketplace index
plugins/
  plugin-builder/                   # KROS plugin store package builder
    skills/    plugin-builder       (SKILL.md + manifest/package rules reference + New-PluginPackage.ps1)
```

## Adding another plugin

1. Create `plugins/<my-plugin>/.claude-plugin/plugin.json` (`name`, `description`, `author`).
2. Put the plugin's content next to it — a skill in `plugins/<my-plugin>/skills/<skill-name>/SKILL.md`, commands in `commands/`, agents in `agents/`.
3. Add an entry to the `plugins` array in `.claude-plugin/marketplace.json` with `source` pointing at `./plugins/<my-plugin>`.
4. Commit and push. Users refresh with `/plugin marketplace update kros-plugins`.
