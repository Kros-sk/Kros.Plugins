TITLE:
[BUG] Desktop app never renders a SessionStart hook's systemMessage — it is parsed and stored as a `hook_system_message` attachment, then dropped

BODY (everything below this line):
---

## Summary

A `SessionStart` hook returns `systemMessage`. The **desktop app** accepts it, records it in the
session transcript as a `hook_system_message` attachment, and never displays it. The same hook, same
plugin version, same machine, renders correctly in the **CLI**.

The failure is silent in both directions: the hook exits 0, the model still receives
`hookSpecificOutput.additionalContext`, and nothing in the session indicates the user-facing half of
the output was dropped. A hook author cannot detect the degradation at runtime.

**Why this is a new report and not a comment on an existing one.** Every prior report of this class is
closed — #77518 as a duplicate, #76736, #15344, #50542 and #16289 as *not planned* or auto-closed
stale, #47692 as stale — and none of them received a response. The specific intersection here,
desktop app + `SessionStart`, is not among them. I am also adding evidence none of those reports
carried: the message is parsed and persisted before it is dropped, so the gap is in rendering alone.

#50542 independently points at the same mechanism from the other direction, suspecting that
`AttachmentMessage.tsx` stopped emitting the `hook_system_message` `<Line>`. That matches exactly what
the transcript below shows arriving and then going nowhere.

## Environment

| | |
|---|---|
| `CLAUDE_CODE_ENTRYPOINT` | `claude-desktop` |
| `CLAUDE_CODE_DESKTOP_APP_VERSION` | `2.110.1` |
| `CLAUDE_AGENT_SDK_VERSION` | `0.3.271` |
| OS | Windows 11 Pro 26200 |
| Hook runtime | `pwsh -NoProfile -File …` |
| Plugin scope | user |

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
    "additionalContext": "A tip was shown to the user - do not repeat it."
  }
}
```

1. Install the plugin at user scope, restart the desktop app.
2. Open a new chat in any project and send any message.

**Expected:** the `systemMessage` text appears to the user, as it does in the CLI.

**Actual:** nothing appears. The model receives `additionalContext` and behaves accordingly, so from
inside the session everything looks healthy.

## Evidence the app received and parsed it

`~/.claude/projects/<project>/<session>.jsonl` contains, for this one hook invocation, both the raw
stdout and a **parsed, typed** attachment:

```json
{"attachment": {"type": "hook_success", "hookName": "SessionStart:startup",
  "toolUseID": "b8422fd7-a306-43f9-a51d-6958ce0657b7", "hookEvent": "SessionStart",
  "content": "", "stdout": "{\"systemMessage\":\"TIP: /teapie …\", …}"}}
```

```json
{"attachment": {"type": "hook_system_message", "hookName": "SessionStart:startup",
  "toolUseID": "b8422fd7-a306-43f9-a51d-6958ce0657b7", "hookEvent": "SessionStart",
  "content": "TIP: /teapie scaffolds a TeaPie test for you. Want it installed?"}}
```

The message is lifted out of stdout into its own `hook_system_message` attachment and persisted, so
transport and parsing both work. Only the desktop UI never renders that attachment type.

## Scope

| Surface | `systemMessage` | `additionalContext` |
|---|---|---|
| CLI (`CLAUDE_CODE_ENTRYPOINT=cli`) | rendered immediately | reaches the model |
| Desktop app (`claude-desktop`) | **silently dropped** | reaches the model |

## Workaround, and what it costs

Branch on the client: on desktop, put the notice into `additionalContext` with an instruction to
print it verbatim; elsewhere use `systemMessage`. #76736 describes the same workaround and is blunt
that it is brittle.

Two costs. The notice arrives one turn late on desktop, so it cannot precede the work it is meant to
influence. And it becomes advisory — the model may reword it, drop it, or act on it instead of
relaying it, which also corrupts any measurement of whether the notice worked.

## Why it matters

Any hook-driven notice at session start — onboarding banners, environment warnings, policy notices,
deprecation notices — has no deterministic user-visible channel on the desktop app. Plugins cannot
contribute a `statusLine` (per the plugins reference), and every other documented channel is
model-mediated. `systemMessage` is the only mechanism available, and on the surface where most people
now work it does nothing.

## Related

All closed, none answered:

| | Scope | Closed as |
|---|---|---|
| #77518 | desktop + remote-control mirror, `PreToolUse`/`PostToolUse` | duplicate |
| #76736 | VS Code, `SessionStart`, all three fields | not planned, stale |
| #15344 | VS Code, `SessionStart` `systemMessage` | not planned, autoclose |
| #50542 | `Stop` hook from a plugin; suspects `AttachmentMessage.tsx` | not planned, stale |
| #16289 | `SubagentStop` | not planned, autoclose |
| #47692 | canonical report | stale |
| #62557 | `permissionDecisionReason`, same root cause | duplicate |
| #40380, #9090, #19643 | same class, other hook events | — |
