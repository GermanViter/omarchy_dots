# Activity label contract (version 4)

The Activity panel reads the `bettr.activity` labels on the agent's terminal.
The panel does not know which agent wrote them. The included reporter
(`mods/bettr-reporter/report.py` with `activity.py`) writes them from agent hooks.
Everything is local: no network or model requests.

## Labels

The log is split so that each event sends only what changed:

| Label | Value | Changes when |
| --- | --- | --- |
| `bettr.activity` | The index: session and turn headings. | A turn starts or ends. |
| `bettr.activity.<id>` | One turn's `entries`, `dropped`, and `reply`. | That turn changes. |

A finished turn's label is written once. Each event compares only the index,
the newest turn, and removed turns. When the session ID or provider changes,
the reporter removes the old turn labels (`hc label <terminal> key=`). Each
label is one command-line argument to `hc`, and Linux allows 128 KiB for one:
the reporter keeps the index and each turn under 100,000 UTF-8 bytes. Text is
not escaped, so a non-ASCII character costs its UTF-8 size.

```json
bettr.activity = {
  "version": 4,
  "provider": "claude",
  "sessionId": "0f0e7374-…",
  "turns": [
    {"id": 1, "prompt": "fix the subagents token display", "startedAt": 1793749300.1,
     "endedAt": 1793749434.2, "outcome": "done"},
    {"id": 2, "prompt": "Agent \"Scout\" finished", "source": "notice", "startedAt": 1793749500.0}
  ]
}

bettr.activity.1 = {
  "entries": [
    {"kind": "read", "items": ["mods/bettr-reporter/model.js"], "at": 1793749302.0},
    {"kind": "search", "items": ["tokens", "usage"], "repeat": 3, "detail": "rg usage mods", "at": 1793749303.0},
    {"kind": "message", "text": "Removing the token row now.", "at": 1793749305.0},
    {"kind": "edit", "files": [["mods/bettr-reporter/model.js", 12, 4, "modified"]], "at": 1793749310.0},
    {"kind": "run", "label": "node --test mods/bettr-reporter/model.test.js", "result": "ok",
     "detail": "cd /repo && node --test mods/bettr-reporter/model.test.js", "repeat": 2, "at": 1793749320.0},
    {"kind": "steer", "label": "also update the docs", "at": 1793749325.0},
    {"kind": "run", "label": "git commit -m 'Remove tokens'", "result": "ok", "at": 1793749330.0}
  ],
  "reply": "Removed the token display.\n\n- Tests pass"
}
```

| Field | Meaning |
| --- | --- |
| `version`, `provider`, `sessionId` | As in the Subagents label. The panel hides the label when the terminal's agent app name does not contain `provider`. The panel reads only version 4. |
| `turns[]` | Headings, oldest first. `id` is unique in the session and names the turn's label. A turn starts at a prompt. Work with no prompt (for example after a background agent reports) starts a turn with an empty `prompt`. |
| `turns[].prompt` | The first non-empty line of the prompt, up to 120 characters. For a notice, a short summary or empty. |
| `turns[].source` | `notice` when the harness, not the user, sent the prompt: a background-task notification or a message from another agent. Absent for user prompts. |
| `turns[].from` | For a message from an agent: the sender's agent ID. The panel names it from the `bettr.subagents` label on the same terminal. |
| `turns[].endedAt`, `outcome` | Set when the turn ends: `done`, `failed`, or `interrupted`. A turn with no `endedAt` is in progress; the panel shows it as stopped after 15 minutes with no step. |
| `reply` (turn label) | The agent's last message in the turn, from the stop event, up to 2000 characters, with `…` when cut. Markdown: closed, the panel shows one plain line; opened, the Markdown. |
| `dropped` (turn label) | The number of older entries removed from this turn to limit its size. |
| `entries[].kind` | `run` (a shell command), `edit`, `read`, `search`, `web`, `agent`, `ask`, `tool`, `steer` (a message the user sent while the agent worked), `message` (the agent's text before a tool call, in `text`, up to 800 characters), or `notice` (a harness message that arrived while the agent worked; `label` is its summary, `from` the sender's agent ID). |
| `entries[].tool` | For kinds other than `run`: the agent's tool name, without a namespace (`Read`, `Grep`, `apply_patch`, `spawn_agent`, `mcp__docs__search`). The panel's verb table names it. Every tool call is recorded, bookkeeping too; the table hides those. |
| `entries[].label` | Short text. For `run`: the command's first line without leading `cd …&&`, `export …;`, `VAR=value`, or `timeout N`. Shell commands are not interpreted. |
| `entries[].items` | For `read`: file paths. For `search`: patterns. |
| `entries[].files` | For `edit`: `[path, added, removed, op]`. `op` is `created`, `modified`, or `deleted`. Counts are `null` when not known. |
| `entries[].result` | `ok`, `failed`, `interrupted`, or `started` (still running in the background). Absent when not known. |
| `entries[].detail` | Shown when the step is selected: the full command, up to 300 characters, when it says more than `label`. Values that look like credentials are replaced by `…`. |
| `entries[].repeat` | The number of steps merged into this one: searches, or the same command again. The other fields are from the last one. |
| `entries[].at` | Unix seconds. |

A prompt that arrives while a turn is open is a `steer` or `notice` entry in
that turn, not a new turn. An open turn whose last step is 15 minutes old is
taken as interrupted at that step, and the prompt starts a new turn. A user
interrupt during a tool call ends the turn as `interrupted`.

Each entry's `at` is when its hook started. Hooks can finish out of order, so
an older entry is put in its place. A step whose hook finishes up to 5 seconds
after the stop event belongs to the turn that just ended.

The reporter keeps every turn of the session (up to 300), each with up to 60
entries; `dropped` counts older entries removed from a long turn. The reporter
merges a step only with the newest step, so the list keeps the order the work
happened in: reads with reads and searches with searches (any tool), edits with
edits (counts added per file), and the same kind, tool, and label again.
`steer`, `notice`, and `message` entries never merge.

## Verb table

The panel names every step with one table, the `verbs` prop of its layout
block. The reporter never chooses a verb.

```json
{"mod": "bettr-activity", "props": {"verbs": {
  "tools": {"Grep": "Searched", "Glob": "Searched", "mcp__*": "Used", "TodoWrite": null},
  "commands": {"git commit": "Committed", "pytest": "Tested", "sleep": null}
}}}
```

- `tools` keys are tool names, or a prefix ending in `*`. A tool with no row
  shows its own name.
- `commands` keys match a `run` label that starts with them as whole words
  (`git` matches `git push`, not `gitk`). A command with no row shows as `Ran`.
- The longest key wins. `null` hides the step.
- A flat object, with neither `tools` nor `commands`, is a `commands` table.
- `steer` rows always say `Steered`. Notices and messages have no verb and
  are not in the table.

Hidden steps are dropped before neighbours merge, so a hidden tool between two
reads does not split them.

The panel shows a command by its program name (`grep`), or by the matched key.
Neighbouring steps of the same kind and verb share one row:
`Ran grep ×3, cd ×2, make`, with the counts muted. Selecting the row lists each
full command. Edit the table in this package's `layouts/bettr.json`, then
install it (`scripts/install.py --update`): the installer replaces the
installed copy. No hook or reporter change is needed.

## Adapters

`mods/bettr-reporter/providers/classify.py` has the provider-neutral helpers:
command cleanup, patch line counts, and credential redaction. Each provider
adapter maps its own tool names to entry kinds. Only the main agent's work is
logged; subagents' own tool calls are not.
