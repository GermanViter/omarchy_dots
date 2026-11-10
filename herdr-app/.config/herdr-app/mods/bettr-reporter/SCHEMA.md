# Subagents label contract (version 2)

The Activity panel reads one terminal label, `bettr.subagents`, on the agent's
terminal: it lists the working subagents under the log, and names the sender of an
agent's message. The panel does not know which agent wrote the label. Any reporter that
writes this shape is supported: the included Python hook reporter, or a plugin
for another agent.

## Label value

The value is compact JSON:

```json
{
  "version": 2,
  "provider": "claude",
  "sessionId": "0f0e7374-…",
  "ended": false,
  "updatedAt": 1793749324.75,
  "agents": [
    {
      "id": "a0210e462984b6634",
      "type": "Explore",
      "status": "working",
      "startedAt": 1793749300.1,
      "updatedAt": 1793749324.75,
      "name": "Scout",
      "description": "Find endpoints",
      "model": "claude-opus-5-5",
      "modelLabel": "opus-5-5",
      "effort": "high"
    }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | `2`. |
| `provider` | yes | Non-empty. The panel hides the label when the terminal's agent app name does not contain it, for example `claude` in `claude-code`. |
| `sessionId` | yes | The parent conversation. A new conversation replaces the state. |
| `ended` | no | `true` after the session ends. |
| `agents[].id` | yes | Stable ID for one subagent. |
| `agents[].type` | yes | Agent type. The panel uses it when `name` is missing. |
| `agents[].status` | yes | `working`, `done`, `failed`, or `interrupted`. Rows with other values are not shown. |
| `agents[].startedAt` | yes | Start of the current run, in Unix seconds. A resumed agent starts a new run. |
| `agents[].endedAt` | when finished | End of the run, in Unix seconds. |
| `agents[].updatedAt` | yes | The last change to this row, in Unix seconds. |
| `name`, `description`, `effort` | no | Short display text. Leave out a value that is not known. Do not send a placeholder. |
| `model` | no | The full model ID, shown on hover. |
| `modelLabel` | no | A short model name for the row. The panel uses `model` when it is missing. |

The panel shows only working rows, newest start first. A reporter must not put
results, prompts, transcripts, or full hook payloads in the label.

## Included reporter

`report.py` is called by each agent's hooks with the provider name, for example
`report.py claude`. It loads `providers/<provider>.py`. That file has one
function, `normalize(event)`, which changes one raw hook payload into a list of
neutral events:

| Event | Extra keys | Effect |
| --- | --- | --- |
| `session.start` | `keepAgents` | New or resumed session. Unless `keepAgents` is true (compaction), working rows become `interrupted`. |
| `session.prompt` | `prompt`, `source`, `from` | A prompt arrived. This can start a new session. `prompt` is its first line, for the Activity log. `source: "notice"` marks a harness message (a task notification or an agent message), and `from` is the sending agent's ID. Use `common.prompt_fields`. |
| `session.end` | | Working rows become `interrupted`, and `ended` becomes true. |
| `agent.start` | `agent`, `fields` | Adds the agent, or starts a new run of a finished one. |
| `agent.stop` | `agent`, `outcome`, `fields` | Ends a working agent with `done`, `failed`, or `interrupted`. The first outcome stays. Unknown IDs are ignored. |
| `agent.meta` | `agent`, `fields`, `create` | Adds display fields. It never changes status. It adds a new row only when `create` is true, for example a spawn tool's launch response. |

Each event also has `type` and `session`. `fields` can hold any optional row
field above, plus `type`. Leave out fields that are not known.

An event whose `session` is different from the current session is ignored,
except for `session.start` and `session.prompt`. There is 1 exception: an agent
event whose `session` and `agent` are both the ID of a child already listed.
Codex reports some child requests this way.

The same `normalize(event)` also returns events for the Activity log
(`activity.py`, `mods/bettr-activity/SCHEMA.md`). The subagent reducer ignores them:

| Event | Extra keys | Effect |
| --- | --- | --- |
| `activity` | `entry`, `composite` | One step of the main agent's work. Build `entry` with `providers/classify.py` (`shell_entry` for shell commands). `composite` marks a step read from a script that calls other tools; it is used only when the session has no direct steps. |
| `turn.end` | `outcome`, `reply`, `at` | The agent finished its turn: `done`, `failed`, or `interrupted`. `reply` is its last message, when the hook gives it. `at` (epoch seconds) is when it ended, if not now. The agent sends no stop event when the user interrupts it, so on a prompt the adapter reads its transcript tail and, when the last turn was interrupted, sends `turn.end` with that time before `session.prompt`. Otherwise the prompt would steer the stopped turn. |

To add an agent:

1. Add `providers/<name>.py` with `normalize(event)`.
2. Add `hooks/<name>.json`, which calls `report.py <name>`, and add the name to
   `AGENTS` and `SETTINGS` in `setup.py`.
3. Add fixture payloads for it to `test_report.py`.
