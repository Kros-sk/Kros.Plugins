# Desktop app never renders a SessionStart hook's `systemMessage`

Report prepared for `anthropics/claude-code`. Written 2026-09-17 while building the `dev-tips` plugin,
whose entire purpose is to show a short notice to the developer when a session starts.

## Summary

A `SessionStart` hook returns `systemMessage`. The Claude Code **desktop app** accepts it, records it
in the session transcript as a `hook_system_message` attachment, and **never displays it**. The same
hook, same plugin version, same machine, renders correctly in the **CLI**.

The failure is silent in both directions: the hook exits 0, the model still receives
`hookSpecificOutput.additionalContext`, and nothing in the session indicates that the user-facing half
of the output was dropped. A hook author cannot detect the degradation at runtime.

## Environment

| | |
|---|---|
| `CLAUDE_CODE_ENTRYPOINT` | `claude-desktop` |
| `CLAUDE_CODE_DESKTOP_APP_VERSION` | `2.110.1` |
| `CLAUDE_AGENT_SDK_VERSION` | `0.3.271` |
| OS | Windows 11 Pro 26200 |
| Hook runtime | `pwsh -NoProfile -File …` |
| Plugin | `dev-tips@kros-plugins` 0.1.4, user scope |

## Reproduction

`hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|resume",
        "hooks": [
          { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/Show-DevTip.ps1\"", "timeout": 10 }
        ]
      }
    ]
  }
}
```

The script writes exactly this to stdout and exits 0:

```json
{
  "systemMessage": "TIP: /teapie scaffolds a TeaPie test for you. Want it installed?",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "A tip was shown to the user — do not repeat it."
  }
}
```

1. Install the plugin at user scope, restart the desktop app.
2. Open a new chat in any project and send any message.

**Expected:** the `systemMessage` text appears to the user, as it does in the CLI.
**Actual:** nothing appears. The model receives `additionalContext` and behaves accordingly, so from
inside the session everything looks healthy.

## Evidence that the app received it

The session transcript
(`~/.claude/projects/<project>/<session>.jsonl`) contains three attachments for this hook invocation.
Two of them are the relevant ones — the raw stdout, and a parsed `hook_system_message`:

```json
{"attachment": {"type": "hook_success", "hookName": "SessionStart:startup",
  "toolUseID": "b8422fd7-a306-43f9-a51d-6958ce0657b7", "hookEvent": "SessionStart",
  "content": "", "stdout": "{\"systemMessage\":\"💡 **TeaPie …** … Mám ti ho pridať?\", …}"}}
```

```json
{"attachment": {"type": "hook_system_message", "hookName": "SessionStart:startup",
  "toolUseID": "b8422fd7-a306-43f9-a51d-6958ce0657b7", "hookEvent": "SessionStart",
  "content": "💡 **TeaPie ti vygeneruje kostru testu** — … Mám ti ho pridať?"}}
```

So the message is parsed out of stdout into its own typed attachment and persisted. This is a
**rendering** gap in the desktop UI, not a parsing or transport failure — which narrows the fix
considerably compared with the existing reports.

For contrast, the sibling `hook_additional_context` attachment from the same invocation *does* reach
the user indirectly, because the model can be told to echo it.

## Scope

| Surface | `systemMessage` | `additionalContext` |
|---|---|---|
| CLI (`CLAUDE_CODE_ENTRYPOINT=cli`) | rendered immediately | reaches the model |
| Desktop app (`claude-desktop`) | **silently dropped** | reaches the model |

## Prior art

This is a known class of bug with several reports, none of which covers exactly desktop +
`SessionStart`:

| Issue | Covers | State |
|---|---|---|
| [#77518](https://github.com/anthropics/claude-code/issues/77518) | Desktop app and remote-control mirror never render hook `systemMessage` — `PreToolUse` / `PostToolUse` | closed as duplicate (target not shown) |
| [#76736](https://github.com/anthropics/claude-code/issues/76736) | VS Code renders no `SessionStart` hook output at all — `systemMessage`, `statusMessage`, `additionalContext` | closed **not planned**, stale |
| [#15344](https://github.com/anthropics/claude-code/issues/15344) | Feature request: display `SessionStart` `systemMessage` in VS Code | open |
| [#16289](https://github.com/anthropics/claude-code/issues/16289) | `SubagentStop` `systemMessage` not displayed | — |
| [#50542](https://github.com/anthropics/claude-code/issues/50542) | `Stop` hook `systemMessage` not rendered, plugin-scope dispatch | — |
| [#40380](https://github.com/anthropics/claude-code/issues/40380) | `PreToolUse`/`PostToolUse` `systemMessage` dropped without `hookSpecificOutput` | — |
| [#9090](https://github.com/anthropics/claude-code/issues/9090) | `SessionEnd` system message not shown in terminal | — |
| [#47692](https://github.com/anthropics/claude-code/issues/47692) | canonical report, auto-closed as stale | closed |
| [#62557](https://github.com/anthropics/claude-code/issues/62557) | `permissionDecisionReason` not rendered — same root cause | duplicate |

#76736 names the only available workaround and is blunt about it: instruct the model to echo
`additionalContext` verbatim, accepting that it can silently omit it.

## Workaround in use

`dev-tips` 0.2.0 branches on the client:

- `CLAUDE_CODE_ENTRYPOINT=claude-desktop` (or `CLAUDE_CODE_DESKTOP_APP_VERSION` set) → the notice goes
  into `additionalContext` with an instruction to print it verbatim.
- otherwise → `systemMessage`, plus a note to the model not to repeat it.

Two costs. The notice arrives one turn late on desktop, so it cannot precede the work it is meant to
influence. And it is now advisory: the model may reword it, drop it, or act on it instead of relaying
it — which also corrupts any measurement of whether the notice worked.

## Why it matters

Any hook-driven notice at session start — onboarding banners, environment warnings, policy notices,
deprecation notices — has no deterministic user-visible channel on the desktop app. Since plugins
cannot contribute a `statusLine` (per the plugins reference), and every other documented channel is
model-mediated, `systemMessage` is the only mechanism available, and on the surface where most people
now work it does nothing.
