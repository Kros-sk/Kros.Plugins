# Catalog distribution — where tips come from

Design for stage 1 of `dev-tips`. Supersedes the catalog section of the MVP: `catalog/tips.json`
stops being the source of truth and becomes a fallback.

Status: design, not implemented. Current shipped version is 0.3.0.

The reasoning behind these choices, the alternatives rejected and the open questions are in
[catalog-distribution-analysis.md](catalog-distribution-analysis.md).

## The problem

A tip today lives in `catalog/tips.json`, which is packaged inside the plugin. Publishing one tip
therefore costs a full release cycle on every machine:

1. bump `version` in `.claude-plugin/plugin.json` and in `marketplace.json`
2. `claude plugin marketplace update kros-plugins`
3. `claude plugin update dev-tips@kros-plugins`
4. restart the application

Steps 2–4 are the developer's, not ours. A developer who never runs them reads an old catalog
forever, and nothing on either side reports the drift. That is backwards for a plugin whose whole job
is to announce things that have just appeared.

The plugin is also un-silenceable. If a tip turns out to be wrong or annoying, there is no way to
stop it reaching people except by asking each of them to update.

## Principle

**Code ships with the plugin. Content does not.**

The plugin version changes when hook logic changes — which is rare. Tip content arrives through
channels that need no action from the developer.

## Three channels

Which channel a tip uses is decided by one question: **does the developer already have the thing the
tip is about?**

| Case | Source | What makes a new tip arrive |
|---|---|---|
| Already installed (global plugin, skill, command, agent) | local inspection of the machine | nothing |
| Specific to the repository being worked in | `.dev-tips/` in that repository | `git pull` |
| Not installed | remote catalog, cached locally | nothing (background refresh) |

### A. Discovery — things the developer already has

No catalog entry required. Everything needed is on disk:

```
~/.claude/plugins/installed_plugins.json      -> installPath of each plugin
  <installPath>/skills/*/SKILL.md             -> frontmatter name + description
  <installPath>/commands/*.md
  <installPath>/agents/*.md
~/.claude/skills/*/SKILL.md                   -> user scope
<repo>/.claude/skills/*/SKILL.md              -> project scope
```

A skill's `description` is written to tell a model when the skill applies, which makes it directly
usable as tip copy. Intersected with `usage.json` — already collected by `Record-SkillUse.ps1` — this
yields *you have this and have never used it*, which is stronger than any hand-written tip because it
is verifiably true for that one developer.

This channel is why a new skill in `kros-shared` needs no `dev-tips` release. The developer updates
`kros-shared` because they want the skill; `dev-tips` sees it on the next session.

Discovery is limited to plugins from **our own marketplaces** — `kros-ai-dev-tools` and
`kros-plugins` by default, overridable through `discoverMarketplaces` in the fetched config. A
machine typically carries third-party tooling as well; we did not write its copy, we do not control
when it changes, and a tip for it spends the one notice per cooldown on something that is not ours
to recommend.

A skill's `description` is frequently a YAML block scalar (`description: >`), which half of ours are.
Reading only the first line yields a tip whose entire body is `>`, so the reader has to fold the
block: `>` joins its lines with spaces, `|` keeps the newlines.

`usage.json` on its own knows only what `Record-SkillUse.ps1` has recorded since the plugin was
installed, which leaves the newest developer worst served: they are told about the command they have
been using for two months. The past is on disk anyway — Claude Code writes every skill invocation to
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` — so the background refresh scans those
transcripts once a day and backfills `usage.json` from them. Same signal, read retrospectively. A
live record always wins over an inferred one, and the scan never runs inside a hook: that directory
runs to hundreds of megabytes.

### B. Repository-local tips

```
Invoicing/.dev-tips/adr-0018-companyid.json
```

Read live from the working directory, so each worktree gets the tips of whatever it has checked out.
These never enter the central catalog — doing so would need a cross-repo token in CI and a second
path for content that is already free to read off the disk.

### C. Remote source — things the developer does not have

A plugin that is not installed cannot be discovered, so this is the only case that genuinely needs a
push channel.

Nothing is generated and nothing is published. The client fetches `master` shallow into a bare mirror
and reads the authored files straight out of the tree:

```bash
git -C "$CLAUDE_PLUGIN_DATA/remote" fetch --depth 1 origin master
git -C "$CLAUDE_PLUGIN_DATA/remote" ls-tree -r --name-only FETCH_HEAD \
    | grep -E 'tip\.json$|dev-tips/(manual|config)\.json$'
```

One bare repository, initialised once, fetched shallow. No repeated clones.

The refresh does the reading, deriving and merging **once** and writes the result to
`remote-tips.json`. `SessionStart` still opens exactly one file and never touches the mirror.

Transport is `git`, not an HTTP GET. `Kros.AiDevTools` is private; a raw URL would need a token
distributed inside the plugin. `git` reuses the credential manager the developer must already have
configured, or `plugin marketplace add` would not have worked for them either.

## Merge rules

Sources are merged by `id`, with fixed precedence:

| Field group | Winner | Why |
|---|---|---|
| copy — `title`, `body`, `maxShows`, `repos`, `when` | derived from the thing itself; see "Where the words come from" | nobody keeps a second copy in step with the first |
| install state — installed / marketplace-only / missing | always local inspection | the remote source cannot know what this machine has |

## Where the words come from

Nobody writes a tip. The authored `tip.json` channel is retired (`authoredTips: false`, D18) and
the text is taken from the thing it describes:

| What | Title | Body |
|---|---|---|
| skill, command, agent | its `name` | `description:` in its `SKILL.md` |
| ADR | `title:` in its front matter | first prose block of `## Rozhodnutie`, else of `## Kontext` |
| guideline | its `# H1` | the first prose paragraph under it |

A block that is a heading or a table row is not prose and is passed over; a document with no prose
anywhere is not announced at all. Where the prose will not trim into one line, the document may
carry a single `tip:` line in its own front matter, and that wins. It lives in the document, never
in a file of its own.

ADRs are fetched shallow from `Kros-sk/Kros.ADR` by the detached refresh and written out under the
state directory, because the mirror git keeps is bare. Guidelines are read live from
`docs/guidelines` in the repository being worked in.

A document is announced **once** (`maxShows: 1`) and carries no usage suppression: a rule is not
run and nobody already uses one. Everything that exists when a source is first seen is recorded as
already announced, per source, so only what lands afterwards is news; the ids in `announceAnyway`
are the exception and can be named later to release a document the baseline silenced.

## Authoring and validation

### Source files — `Kros.AiDevTools`, branch `master`

One small JSON per tool, next to the tool, written by the tool's author in the same pull request:

```
plugins/kros-shared/skills/git-diff/SKILL.md    <- its description is the tip
plugins/kros-shared/commands/commit.md          <- its description is the tip
dev-tips/config.json                            <- policy only; no tips are authored
```

A separate file rather than a `tip:` block in the `SKILL.md` frontmatter: that frontmatter is parsed
by Claude Code's skill loader, and an unknown key there is a risk taken for no gain. Scanning is
equally easy either way.

Authors write copy and conditions only:

```json
{
  "kind": "command",
  "title": "/git-diff porovná branch oproti masteru",
  "body": "Nemusíš skladať refspec ručne — zoberie commit, branch alebo nič a porovná to správne.",
  "repos": ["*"],
  "maxShows": 2,
  "when": { "did": { "commands": ["^\\s*git\\s+diff\\s+.*\\bmaster\\b"], "minMatches": 2 } }
}
```

### Derived fields

The client derives what an author does not write, from the same tree the tips come from:

| Field | Derived from |
|---|---|
| `id` | the skill's or command's directory / file name |
| `ref` | `/<name>` |
| `install` | `.claude-plugin/marketplace.json` — which plugin and marketplace the file sits in |

There is no `published`. A shallow fetch carries no history to derive it from, and what the field was
for — knowing how new an item is — is better answered locally: the hook records `firstSeen` in
`shown.json` the first time an `id` appears. To somebody who joined last week a two-year-old tip *is*
new, which is the behaviour wanted. `expires` stays an explicit field the author writes; it says when
content goes stale, which has nothing to do with when it was committed.

### There is no published artifact

The pipeline has no publishing step. Nothing builds a catalog, no bot commits one and no branch holds
one. CI in `Kros.AiDevTools` (which has no `.github` today) exists only to validate pull requests.

Ways of publishing a generated catalog, and why none of them is used:

- **An orphan branch.** It works, but it is a build artifact to keep in step with its source,
  produced by a bot, carrying content the client can read from that source just as cheaply.
- **A generated file committed to `master`.** Either a bot pushes it — retriggering the workflow and
  colliding with branch protection — or every contributor regenerates it by hand, which puts friction
  exactly on the people writing tips voluntarily.
- **A release asset.** Downloading one from a private repository needs an API token, which is the
  problem `git` was chosen to avoid.

### Validation runs on the pull request

There is no tip validator any more: with nothing authored there is no schema to break. What a pull
request can still get wrong is a `description` that reads as a paragraph, and that is caught by the
240-character trim rather than by a gate.

The retired validator failed a pull request when:

- a `tip.json` did not match the schema, or an `id` collided,
- `title` or `body` exceeds its length limit — the notice is two lines, and without a limit someone
  will write a paragraph,
- `ref` points at a skill or command that does not exist in the repository.

The last check is the one that pays for the workflow. A tip pointing at a renamed command is worse
than no tip, and nobody would catch it in review: the only people who see the tip are the ones who do
not know the tool.

## Timing

Reading and fetching are separate events and must stay separate.

`Stop` fires whenever the model finishes responding — the end of every turn, dozens of times per
session. It is not a session-end event: clearing a conversation is `SessionStart` with the `clear`
source, which the plugin already matches.

| Event | Action | Network | Blocks the session |
|---|---|---|---|
| `SessionStart` | read `remote-tips.json` from disk | no | one file read |
| `Stop`, every turn | compare cache `mtime` against `ttlHours`, exit if fresh | no | no |
| `Stop`, once per TTL | spawn a detached refresh process and exit | yes, off the critical path | no |

`SessionStart` never checks whether the cache is current — it reads whatever is there, falling back
to the packaged `catalog/tips.json` when the cache does not exist yet (fresh install, no fetch has
run). Session start time is therefore constant and independent of the network, the VPN, and whether
the developer is at home.

The refresh belongs in `Stop`, where `Test-TurnForSkills.ps1` already runs: nothing waits on it once
the model has finished. Even there nothing waits on `git`:

```powershell
Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-File',"$PSScriptRoot/Update-DevTipsData.ps1")
```

**A freshly fetched catalog is not used by the session that fetched it.** It is for the next one, so a
tip is always one session behind. That is a consequence of delivering tips at session start, not a
hard constraint: the refresh finishes long after the moment of delivery has passed, and the only ways
to use it sooner are to wait for the network in `SessionStart` — refused above — or to deliver the
tip mid-session from `UserPromptSubmit`, the way `Show-Candidate.ps1` already delivers retrospective
notices.

Mid-session delivery is deliberately not done. A scheduled tip interrupting work is more intrusive
than one at startup, and a retrospective notice earns that intrusion by reacting to what the
developer just did, where a scheduled tip does not. Nothing is gained either: content on a 24-hour
TTL has no reason to arrive ninety seconds earlier.

### Three constraints on the refresh

**The TTL check must be the first operation in `Stop`.** That hook runs after every turn, dozens of
times a day. Comparing a file's `mtime` to `ttlHours` costs microseconds; anything more expensive
placed ahead of it is multiplied by the turn count.

**Concurrent sessions will collide.** Claude Code runs hooks as separate parallel processes, and
developers keep several windows open — each with its own `Stop`. The refresh needs a lock file with a
stale timeout (for the process that died holding it), and the cache must be written to a temporary
file and moved into place. A direct write lets a `SessionStart` in another window read half a file.
This is the same hazard the turn ledger already works around.

**Offline is a normal state, not an error.** The fetch fails, the old cache stays, one line goes to
`debug.log`. No retry loop and no shortened TTL — it tries again after the TTL.

### What the detached process needs

Three things, and each has a silent failure mode.

**The state directory, passed explicitly.** `Get-StateDir` falls back to
`~/.claude/plugins/data/dev-tips-local` when `CLAUDE_PLUGIN_DATA` is not set. A detached child does
inherit its parent's environment, but if that ever fails the refresh writes its cache to a
*different* directory than the one `SessionStart` reads — the fetch runs, the log reports success and
the tip never changes. That split already exists on disk today, across three `dev-tips-*` data
directories left behind by different install methods. So the path travels as an argument, and
`Update-DevTipsData.ps1` carries no fallback: without `-StateDir` it logs and exits.

```powershell
Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-File',"$PSScriptRoot/Update-DevTipsData.ps1",
    '-StateDir',$stateDir)
```

**Credentials it does not manage.** There is no login step. `git` calls Git Credential Manager, which
reads the token from Windows Credential Manager, where it landed when the developer first
authenticated — which they must have, or `plugin marketplace add Kros-sk/Kros.AiDevTools` would not
have worked for them. This is the argument for `git` over HTTP with a token shipped inside the
plugin.

**A guarantee that it can never prompt.** When the token is missing or expired, GCM opens a window or
a browser by default. A hidden process with no console then hangs forever holding the lock: the cache
stops updating permanently, and `debug.log` gets no line because the script never reached one.
Disabling prompts turns an auth failure into an ordinary non-zero exit that is logged and retried
after the TTL:

```powershell
$env:GIT_TERMINAL_PROMPT = '0'
git -c credential.interactive=false -c core.askPass= `
    -C $remote fetch --depth 1 origin master
```

A hard timeout on the fetch covers the same hazard arriving from the network rather than from GCM.

One more, for whoever debugs this later: spawn with `-WindowStyle Hidden`, never `-NoNewWindow`. The
latter shares the `Stop` hook's stdout, which Claude Code parses as JSON — a single `Write-Host` in
the refresh script would corrupt the hook's output.

## Remote configuration

Policy is authored rather than generated, so it is an ordinary file in the same tree the tips come
from — `dev-tips/config.json`:

```json
{
  "ttlHours": 24,
  "cooldownDays": 2,
  "enabled": true,
  "discoverMarketplaces": ["kros-ai-dev-tools", "kros-plugins"]
}
```

The plugin's own values only bootstrap the first fetch. After that, what this file says is what the
hook does: the values are used as given, not clamped to bounds guessed in advance.

`"enabled": false` silences every notice for everyone within one TTL. A plugin that irritates people
and cannot be centrally stopped gets switched off locally and permanently, so this switch is not a
nice-to-have.

What stays outside our control in every design: the machine must be on the network, and a session
must start. Somebody who does not open Claude Code for a week receives nothing, which is correct.

## File map

```
Kros.AiDevTools @ master                        the only place tips are written
  plugins/<plugin>/skills/<skill>/SKILL.md      its own description is the tip
  dev-tips/config.json                          policy only

Kros.ADR @ master                               the rules, fetched the same way
  Adrs/*.md                                     title + decision are the announcement

<any product repo>
  .dev-tips/*.json                              authored by hand, read live

Kros.Plugins/plugins/dev-tips
  catalog/tips.json                             fallback for a first offline install
  hooks/DevTips.History.ps1                     new
  hooks/Update-DevTipsData.ps1                  new

~/.claude/plugins/data/dev-tips-kros-plugins
  remote/                                       bare mirror of Kros.AiDevTools @ master
  remote-tips.json                              merged snapshot written by the refresh
  *.stamp                                       one per refresh job, for its own TTL
  shown.json                                    carries firstSeen per id
  usage.json
```

## Migration from 0.3.0

1. Channel A first. It needs no CI and no network, and it already covers most of what the packaged
   catalog contains today.
2. Channel B next — a directory read, and it unblocks ADRs and conventions per repository.
3. Channel C last. It is the only part that reaches into another repository — a background fetch of
   `Kros.AiDevTools`, and a validation workflow there — and until it exists the packaged catalog
   keeps working exactly as it does now.

`catalog/config.json` currently ships `cooldownDays: 0` and `candidateCooldownHours: 0`. These are
test values and must be corrected before any of the above, independently of it.

## Out of scope

- Telemetry on whether a tip changed anyone's behaviour. Nothing leaves the machine today and that
  stays true here.
- Pushing repository-local tips into the shared source.
- Any mechanism for reaching a developer who is not starting sessions.
