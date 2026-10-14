# dev-tips

Surfaces internal tooling developers do not know about — skills, commands, agents, ADRs and team
conventions — as one short tip at session start, with a question they can answer.

Design: `655507-dev-tips-plugin.md`. This is the **MVP (0.1.0)**: it delivers a tip and asks. The
generator, usage-based suppression and measurement are not implemented yet.

## What it does today

On `SessionStart` it picks at most one tip from `catalog/tips.json` and delivers it **differently per
client**, because the two clients do not render the same things.

| Client | Channel | Result |
|---|---|---|
| CLI | `systemMessage` + a quiet note in `additionalContext` | tip appears immediately, rendered by the harness; the model is told not to repeat it |
| Desktop app | the tip itself in `additionalContext` | tip appears in the model's first reply |

The client is detected from `CLAUDE_CODE_ENTRYPOINT` (`claude-desktop`) and
`CLAUDE_CODE_DESKTOP_APP_VERSION`.

**Why not `systemMessage` everywhere.** It is the better channel: it renders before the developer
types anything and the model cannot reword, skip or act on it. But the desktop app **accepts and
records `systemMessage` without displaying it** — verified in a session transcript, which contains
the delivered tip as a `hook_system_message` attachment that never reached the UI. Until that is
fixed in the app, desktop users only get the tip once the model replies. The CLI keeps the better
behaviour rather than being levelled down to match.

A tip is only offered when:

- its `repos` match the current repository (`*` matches everything, otherwise a substring match on
  the repository folder name),
- it has not already been shown `maxShows` times,
- no other tip has been shown in the last `cooldownDays` (default 2), globally across repositories.

The question depends on whether the developer actually has the tool, determined by reading
`~/.claude/plugins/installed_plugins.json` and `known_marketplaces.json`:

| State | Tip says | Question |
|---|---|---|
| Plugin installed | how to run it | "Chceš, aby som ti ukázal, ako sa to používa?" |
| Marketplace added, plugin missing | `/plugin install …` | "Mám ti ho pridať?" |
| Marketplace not added | `/plugin marketplace add …` first | "Mám ti pridať marketplace aj plugin?" |

State lives in `$CLAUDE_PLUGIN_DATA/shown.json`. Nothing leaves the machine.

## Retrospective notices: "you just did that by hand"

The stronger case is the one a keyword match cannot see — the developer spends a turn stepping
through something a skill they **already have** does in one command. Four hooks cooperate:

| Hook | Script | Does |
|---|---|---|
| `PostToolUse` (Bash) | `Record-TurnCommand.ps1` | appends the command to `turns/<session>.txt` |
| `PreToolUse` (Skill) | `Record-SkillUse.ps1` | records that a skill was actually used, into `usage.json` |
| `Stop` | `Test-TurnForSkills.ps1` | reads the ledger once, clears it, matches it against `when.did`, records a candidate |
| `UserPromptSubmit` | `Show-Candidate.ps1` | delivers the candidate on the very next prompt |

The ledger pattern — `PostToolUse` writes, `Stop` reads and clears — is deliberate. Claude Code runs
an event's hooks **in parallel as separate processes**, so read-and-clear has to live in one process
or a sibling hook will race it.

A candidate only survives if the developer can act on it right now: the plugin must be installed, and
`usage.json` must show they have never invoked the skill. Recommending `/commit` to someone who uses
`/commit` is the fastest way to get the plugin switched off.

The notice is never delivered by the hook that detected it. `Stop` records, the next prompt delivers —
so nothing interrupts the turn that produced it, and one set of brakes governs every notice however
many detectors get added later.

Wording matters here more than for a scheduled tip. A false positive on a scheduled tip is noise; a
false positive on this one tells somebody they did their job wrong. The copy says *next time you can
use X*, never *you should have used X*.

```json
"when": {
  "did": {
    "commands": ["^\\s*git\\s+status", "^\\s*git\\s+add\\b", "^\\s*git\\s+commit\\b"],
    "minMatches": 3
  }
}
```

`minMatches` counts **distinct patterns** matched anywhere in the turn, not a sequence — order is too
brittle to rely on.

## Trying it locally

```bash
claude plugin marketplace add C:/Users/<you>/Documents/Projects/Kros.Plugins
claude plugin install dev-tips@kros-plugins
```

Then start a new session.

## Running it by hand

```bash
pwsh -NoProfile -File plugins/dev-tips/hooks/Show-DevTip.ps1 -DryRun
```

`-DryRun` prints the selection and the injected text without writing state. `-Force` ignores the
cooldown, which is how you step through several tips in a row while testing.

## Debug log

The hook swallows every error and always exits 0, because a broken tip must never block a session.
That makes silence ambiguous, so every run appends a line to `$CLAUDE_PLUGIN_DATA/debug.log`:

```
… run start | pid=19400 | dryRun=False | force=False | CLAUDE_PLUGIN_DATA=set | pluginRoot=… | cwd=…
… picked=teapie | repo=Invoicing | candidates=5 | shownBefore=0 | install=marketplace-only
… emitted systemMessage + additionalContext | shownNow=1 | state written
```

The other outcomes are equally explicit: `exit: cooldown, 0,43d elapsed of 2d`, `exit: no candidates`,
`exit: catalog missing or empty`, `exit: dry run, state not written`, and on a failure
`ERROR: <message> | at <file>:<line>`.

**No line at all means the hook never ran** — which is a different problem from a tip not being
selected, and the distinction is the whole point of the log. The file is trimmed to its last 200
lines once it passes 64 KB.

## Updating after a change

The installed plugin is a **copy** under `~/.claude/plugins/cache/`, and `plugin update` compares
versions — so an edit without a version bump updates nothing, silently.

1. Bump `version` in `plugins/dev-tips/.claude-plugin/plugin.json` **and** in the matching
   `.claude-plugin/marketplace.json` entry.
2. `claude plugin marketplace update kros-plugins`
3. `claude plugin update dev-tips@kros-plugins`
4. **Restart the application**, not just open a new chat — a running process keeps the old version.

## Catalog

`catalog/tips.json` is hand-written for the MVP. From stage 1 of the design onwards it is generated
by CI from the source repositories and must not be edited by hand.

Where those tips come from once that happens — authoring, CI, the remote catalog and when it gets
read — is designed in [docs/catalog-distribution.md](docs/catalog-distribution.md).
The reasoning and the rejected alternatives are in
[docs/catalog-distribution-analysis.md](docs/catalog-distribution-analysis.md).

| Field | Meaning |
|---|---|
| `id` | stable; `shown.json` keys off it |
| `kind` | `skill`, `command`, `agent`, `adr`, `convention`, `recommendation` |
| `title`, `body` | what the developer reads |
| `ref` | what they type to run it, or `null` |
| `repos` | `["*"]`, or substrings matched against the repository folder name |
| `published` | when the item appeared; set by CI later, never rewritten |
| `expires` | optional; the tip stops being offered after this date |
| `maxShows` | how many times one developer may see it |
| `install` | `marketplace`, `repo`, `plugin` — drives the install variants above; `null` for ADRs and conventions |

## Where the words come from

Nobody writes a tip. The text is taken from the thing it describes, and there is no second copy to
keep in step with the first:

| What | Title | Body |
|---|---|---|
| skill, command, agent | its `name` | `description:` in its `SKILL.md` |
| ADR | `title:` in its front matter | first paragraph of `## Rozhodnutie` |
| guideline | its `# H1` | the first paragraph under it |

Where that prose does not trim into one readable line, the document may carry a single `tip:` line
in its own front matter, and that is used instead. It lives in the document, never in a file of its
own: `authoredTips` is `false` and the `*.tip.json` channel is retired. See D18 in
`docs/catalog-distribution-analysis.md`.

ADRs are fetched shallow from `Kros-sk/Kros.ADR` by the detached refresh and written out under the
state directory; guidelines are read live from `docs/guidelines` in the repository being worked in.
A document is announced **once** (`maxShows: 1`), and everything that already existed when the
channel was switched on is recorded as announced, apart from the ids in `announceAnyway`.

## Tests

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path plugins/dev-tips/tests -Output Detailed"
```

Pester 5 is required. No test reaches the network or the real profile: transcripts, plugin
installations and the remote origin are all built as fixtures in a temp directory.
