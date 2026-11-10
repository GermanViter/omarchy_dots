# Context label contract (version 1)

The Context panel reads the `bettr.context` label on the agent's terminal. It
does not know which agent wrote it. The included reporter
(`mods/bettr-reporter/report.py` with `context.py`) writes it from agent hooks: on
each event it reads the new lines of the agent's local transcript, from the
newest compaction. Everything is local: no network or model requests.

```json
bettr.context = {
  "version": 1,
  "provider": "claude",
  "sessionId": "0f0e7374-…",
  "used": 63800,
  "exact": true,
  "window": 1000000,
  "reserved": 33000,
  "model": "claude-opus-5-5",
  "compactions": 6,
  "log": [{"at": 1793267585, "trigger": "auto", "before": 312725, "after": 12735, "took": 39.9}],
  "rows": [
    {"key": "messages", "label": "Messages", "tokens": 28200,
     "parts": [{"label": "Bash", "tokens": 12000}, {"label": "Other", "tokens": 4100}]},
    {"key": "tools", "label": "Tools", "tokens": 14200}
  ],
  "cache": {
    "requests": 60, "read": 5514465, "written": 201256, "rewritten": 77507, "uncached": 134,
    "since": 1793839616, "misses": [{"at": 1793848541, "lost": 77507, "rewritten": 77507, "idle": 8437, "ttl": 3600}]
  }
}
```

| Field | Meaning |
| --- | --- |
| `provider`, `sessionId` | As in the Activity label. The panel hides the label when the terminal's agent app name does not contain `provider`. |
| `used` | Tokens in context after the last request: the agent's own count when `exact`, else the sum of the rows (no count since the last compaction). |
| `window` | The model's context window, when known. Codex gives it; for Claude it comes from a model table in `providers/claude.py`. |
| `reserved` | Tokens the agent keeps free for automatic compaction, when it has such a reserve. Approximate. |
| `compactions` | Compactions found in the transcript. |
| `log[]` | The newest 20 compactions found, oldest first; absent when none. `at` (epoch seconds) and `before` (context tokens before it) always; then only what the agent recorded: `trigger` (`auto` or `manual`), `after` (context tokens after it; for Codex, the first request's after it), and `took` (seconds). Claude records all; Codex no `trigger` or `took`. |
| `rows[]` | In display order. `key` is one of `messages`, `tools`, `skills`, `memory`, `agents`, `system`, `mcp`; the panel gives each a rainbow colour. `tokens` is an estimate from character counts (3.5 characters a token), scaled down when the estimates add up to more than `used`. What the rows cannot explain (reminders, hook output) is added to `messages` as its `Other` part, as Claude counts it. |
| `rows[].parts` | Sub-rows, the 40 largest, then `Other`. For `messages`: by kind (`User`, `Assistant`, `Thinking`, `Summary`, `Files`, `Images`) and by tool; its `Other` also holds what no row explains. For `tools`: one per tool (`server: tool` for MCP tools), plus `Deferred tool names`. For `skills`: one per skill, plus `Instructions` (the list's other text). For `agents`: one per agent type. |

| `cache` | The main agent's prompt cache, from the requests read so far (see `since`). Absent before the first request. |
| `cache.requests`, `.read`, `.written`, `.uncached` | API requests, and their input tokens: read from cache, written to cache, and not cached. `written` is absent when the agent does not report cache writes (Codex). |
| `cache.rewritten` | The part of `written` that the previous prompt had cached: the sum of all misses' `rewritten`, not only the 20 kept. With `written`. |
| `cache.since` | Epoch seconds of the first counted request. |
| `cache.misses[]` | The newest 20 requests that read 1,024 tokens or more less than the previous request read plus wrote. Absent with `written`. `at`: when its request was sent; `lost`: cached tokens the request did not read; `rewritten`: up to `lost` of what it wrote, absent after a compaction (the new prompt is a summary). Then only facts found before it: `compaction: true`, `models: [old, new]`, and `idle` (seconds since the previous request was sent) with `ttl` (of the newest write) when `idle` is longer. No field names a cause. |

The reporter reads internal transcript formats. When an agent changes them, a
row can drop to zero and its size moves to Messages' `Other` part; the total stays exact.
