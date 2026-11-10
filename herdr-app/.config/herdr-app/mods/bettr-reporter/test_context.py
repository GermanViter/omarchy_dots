from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import context  # noqa: E402
import report  # noqa: E402


def claude(kind, **fields):
    return {"type": kind, **fields}


def assistant(blocks, usage=None, model="claude-opus-5-5"):
    message = {"model": model, "content": blocks}
    if usage:
        message["usage"] = {"input_tokens": 2, "cache_read_input_tokens": usage, "cache_creation_input_tokens": 0,
                            "output_tokens": 0}
    return claude("assistant", message=message)


def user(blocks, **fields):
    return claude("user", message={"role": "user", "content": blocks}, **fields)


BOUNDARY = claude("system", subtype="compact_boundary")
SHAPE = claude("api-request-shape", shape={"system": [{"type": "text", "text": "s" * 700}],
                                           "tools": [{"name": "Bash", "description": "t" * 1400}]})


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = str(Path(self.folder.name) / "session.jsonl")

    def write(self, items, mode="w", tail=""):
        with open(self.path, mode) as output:
            output.writelines(json.dumps(item) + "\n" for item in items)
            output.write(tail)

    def run_event(self, state, provider="claude", session="s1", events=(), **extra):
        event = {"session_id": session, "transcript_path": self.path, **extra}
        return context.update(state, event, list(events), provider, report.adapter(provider))

    def test_claude_rows_start_at_the_newest_compaction(self):
        old = user([{"type": "text", "text": "x" * 70000}])
        self.write([SHAPE, old, BOUNDARY,
                    user([{"type": "text", "text": "summary " * 100}], isCompactSummary=True),
                    claude("attachment", attachment={"type": "skill_listing",
                                                     "content": "- one: " + "k" * 168 + "\n- two: x:y\n" + "k" * 163}),
                    assistant([{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]),
                    user([{"type": "tool_result", "tool_use_id": "t1", "content": "r" * 3500}]),
                    assistant([{"type": "text", "text": "done"}], usage=5000)])
        state = self.run_event(None)
        value = json.loads(state["label"])
        rows = {row["key"]: row for row in value["rows"]}
        self.assertEqual(value["used"], 5002)
        self.assertTrue(value["exact"])
        self.assertEqual((value["window"], value["reserved"], value["compactions"]), (1_000_000, 33_000, 1))
        # The pinned shape before the boundary counts; the old message does not.
        self.assertEqual(rows["system"]["tokens"], 200)
        self.assertEqual(rows["tools"]["tokens"], 410)
        self.assertEqual(rows["skills"]["tokens"], 100)
        self.assertEqual(rows["skills"]["parts"], [{"label": "one", "tokens": 50}, {"label": "two", "tokens": 50}])
        self.assertEqual(rows["tools"]["parts"][0]["label"], "Bash")
        parts = {part["label"]: part["tokens"] for part in rows["messages"]["parts"]}
        self.assertEqual(parts["Bash"], 1005)
        self.assertIn("Summary", parts)
        # What the rows cannot explain is Messages' Other part, so the rows add up to the total.
        self.assertEqual(sum(row["tokens"] for row in value["rows"]), 5002)
        self.assertNotIn("other", rows)
        self.assertEqual(rows["messages"]["parts"][-1]["label"], "Other")
        self.assertEqual(sum(parts.values()), rows["messages"]["tokens"])

    def test_rows_are_scaled_down_when_estimates_exceed_the_total(self):
        self.write([user([{"type": "text", "text": "x" * 35000}]), assistant([], usage=1000)])
        value = json.loads(self.run_event(None)["label"])
        self.assertEqual(value["rows"], [{"key": "messages", "label": "Messages", "tokens": 1002,
                                          "parts": [{"label": "User", "tokens": 1002}]}])

    def test_reads_only_new_whole_lines(self):
        self.write([assistant([{"type": "text", "text": "a" * 35}], usage=1000)], tail='{"type": "user", "mess')
        state = self.run_event(None)
        offset = state["offset"]
        self.assertIsNone(self.run_event(state))  # Nothing new: the label is the same.
        self.assertEqual(state["offset"], offset)
        with open(self.path, "a") as output:
            output.write('age": {"content": "' + "u" * 350 + '"}}\n')
        state = self.run_event(state)
        parts = {part["label"]: part["tokens"] for part in json.loads(state["label"])["rows"][0]["parts"]}
        self.assertEqual(parts["User"], 100)

    def test_a_compaction_resets_messages_and_the_total(self):
        self.write([assistant([{"type": "text", "text": "a" * 3500}], usage=2000)])
        state = self.run_event(None)
        self.write([BOUNDARY, user([{"type": "text", "text": "b" * 350}], isCompactSummary=True)], mode="a")
        value = json.loads(self.run_event(state)["label"])
        self.assertFalse(value["exact"])
        self.assertEqual(value["used"], 100)
        self.assertEqual(value["compactions"], 1)

    def test_tool_and_agent_figures(self):
        definition = {"name": "mcp__docs__read", "description": "d" * 300}
        delta = {"type": "deferred_tools_delta", "addedNames": ["A", "B"], "addedLines": ["A", "B"], "removedNames": [],
                 "surfacedDefinitions": [{"name": "mcp__docs__read", "definition": definition}]}
        agents = {"type": "agent_listing_delta", "addedTypes": ["Explore", "mine"], "builtInTypes": ["Explore"],
                  "addedLines": ["- Explore: " + "e" * 339, "- mine: " + "m" * 692]}
        self.write([claude("attachment", attachment=delta), claude("attachment", attachment=agents),
                    claude("attachment", attachment={**delta, "addedNames": [], "addedLines": [], "removedNames": ["A"]})])
        value = json.loads(self.run_event(None)["label"])
        self.assertNotIn("lists", value)
        tools = next(row for row in value["rows"] if row["key"] == "tools")
        self.assertEqual(tools["parts"][0]["label"], "docs: read")
        # Each agent's description line is a sub-row of Custom agents.
        agents = next(row for row in value["rows"] if row["key"] == "agents")
        self.assertEqual(agents["parts"], [{"label": "mine", "tokens": 200}, {"label": "Explore", "tokens": 100}])

    def test_codex_uses_its_token_count_and_replacement_history(self):
        def item(kind, **payload):
            return {"type": kind, "payload": payload}
        message = lambda role, text: {"type": "message", "role": role, "content": [{"type": "input_text", "text": text}]}
        self.write([item("response_item", **message("user", "old " * 5000)),
                    item("compacted", replacement_history=[
                        message("developer", "You are Codex" + "." * 337),
                        message("developer", "<skills_instructions>\n## Skills\n- a:b: " + "k" * 157
                                + "\n# Escalation\n" + "e" * 140),
                        message("user", "# AGENTS.md instructions" + "m" * 326),
                        {"type": "additional_tools", "tools": [{"name": "exec"}]}]),
                    item("turn_context", model="gpt-6"),
                    item("response_item", type="function_call", call_id="c1", name="exec", arguments="x" * 35),
                    item("response_item", type="function_call_output", call_id="c1", output="y" * 315),
                    item("event_msg", type="token_count",
                         info={"last_token_usage": {"input_tokens": 900, "output_tokens": 100},
                               "model_context_window": 258400})])
        value = json.loads(self.run_event(None, provider="codex")["label"])
        rows = {row["key"]: row["tokens"] for row in value["rows"]}
        self.assertEqual((value["used"], value["window"], value["model"]), (1000, 258400, "gpt-6"))
        self.assertNotIn("reserved", value)
        self.assertEqual((rows["system"], rows["skills"], rows["memory"]), (100, 100, 100))
        # The exec call and output are 100; the rest of the 1000 is Messages' Other part.
        self.assertEqual(rows["messages"], 1000 - sum(tokens for key, tokens in rows.items() if key != "messages"))
        parts = {part["label"]: part["tokens"] for part in value["rows"][0]["parts"]}
        self.assertEqual(parts["exec"], 100)
        self.assertEqual(value["compactions"], 1)
        skills = next(row for row in value["rows"] if row["key"] == "skills")
        self.assertEqual(skills["parts"], [{"label": "Instructions", "tokens": 53}, {"label": "a:b", "tokens": 47}])

    def test_subagent_events_and_old_sessions_are_ignored(self):
        self.write([assistant([], usage=100)])
        self.assertIsNone(self.run_event(None, agent_id="child"))
        state = self.run_event(None)
        self.assertIsNone(self.run_event(state, session="old"))
        started = self.run_event(state, session="new", events=[{"type": "session.prompt"}])
        self.assertEqual(json.loads(started["label"])["sessionId"], "new")

    def test_the_reporter_sends_the_label_once(self):
        self.write([assistant([{"type": "text", "text": "hi"}], usage=100)])
        sent = []
        stop = {"hook_event_name": "Stop", "session_id": "s1", "transcript_path": self.path}
        cache = Path(self.folder.name) / "cache"
        report.record(stop, "claude", "t1", cache, send=lambda terminal, pairs: sent.append(pairs))
        report.record(stop, "claude", "t1", cache, send=lambda terminal, pairs: sent.append(pairs))
        labels = [pairs[context.LABEL] for pairs in sent if context.LABEL in pairs]
        self.assertEqual(len(labels), 1)
        self.assertEqual(json.loads(labels[0])["used"], 102)

    def test_post_compact_sends_the_new_compaction(self):
        self.write([assistant([{"type": "text", "text": "hi"}], usage=100)])
        sent = []
        cache = Path(self.folder.name) / "cache"
        send = lambda terminal, pairs: sent.append(pairs)
        report.record({"hook_event_name": "Stop", "session_id": "s1", "transcript_path": self.path}, "claude", "t1",
                      cache, send=send)
        stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        self.write([claude("system", subtype="compact_boundary", timestamp=stamp,
                           compactMetadata={"trigger": "manual", "preTokens": 900, "postTokens": 50})], mode="a")
        report.record({"hook_event_name": "PostCompact", "session_id": "s1", "transcript_path": self.path,
                       "trigger": "manual"}, "claude", "t1", cache, send=send)
        log = json.loads(sent[-1][context.LABEL])["log"]
        self.assertEqual([(entry["trigger"], entry["before"], entry["after"]) for entry in log], [("manual", 900, 50)])

    def test_cache_totals_and_misses_keep_only_transcript_facts(self):
        def request(id, read, write, at, model="claude-opus-5-5", tier="ephemeral_1h_input_tokens"):
            sent = user([{"type": "text", "text": "go"}], timestamp=f"2026-11-05T{at}Z")
            usage = {"input_tokens": 2, "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
                     "output_tokens": 1, "cache_creation": {tier: write}}
            reply = claude("assistant", message={"id": id, "model": model, "content": [{"type": "text", "text": "a"}],
                                                 "usage": usage})
            return [sent, reply, reply]  # Claude writes the usage again for each content block.
        self.write([*request("m1", 0, 30000, "10:00:00"),
                    *request("m2", 30000, 2000, "10:00:30"),     # Read all the previous prompt: no miss.
                    *request("m3", 31500, 900, "10:01:00"),      # 500 short: below the smallest cache.
                    *request("m4", 27000, 6000, "11:30:00"),     # 90 min idle, TTL 1 h.
                    BOUNDARY,
                    *request("m5", 27000, 4000, "11:31:00"),     # After the compaction.
                    *request("m6", 0, 31000, "11:32:00", model="claude-sonnet-5"),
                    *request("m7", 0, 31000, "11:33:00", model="claude-sonnet-5", tier="ephemeral_5m_input_tokens")])
        cache = json.loads(self.run_event(None)["label"])["cache"]
        self.assertEqual((cache["requests"], cache["uncached"]), (7, 14))
        self.assertEqual(cache["read"], 30000 + 31500 + 27000 + 27000)
        self.assertEqual(cache["written"], 30000 + 2000 + 900 + 6000 + 4000 + 31000 + 31000)
        # A compaction rewrites nothing: its 32k cached prompt was dropped, not written again.
        self.assertEqual(cache["rewritten"], 5400 + 31000 + 31000)
        self.assertEqual(cache["misses"], [
            {"at": cache["since"] + 5400, "lost": 32400 - 27000, "rewritten": 5400, "idle": 5340, "ttl": 3600},
            {"at": cache["since"] + 5460, "lost": 33000 - 27000, "compaction": True},
            {"at": cache["since"] + 5520, "lost": 31000, "rewritten": 31000,
             "models": ["claude-opus-5-5", "claude-sonnet-5"]},
            {"at": cache["since"] + 5580, "lost": 31000, "rewritten": 31000}])

    def test_codex_cache_has_reads_but_no_misses(self):
        def count(total, sent, read):
            return {"type": "event_msg", "timestamp": "2026-11-05T10:00:00Z", "payload": {
                "type": "token_count", "info": {"last_token_usage": {"input_tokens": sent, "cached_input_tokens": read,
                                                                     "output_tokens": 5},
                                                "total_token_usage": {"total_tokens": total}}}}
        self.write([count(100, 100, 0), count(100, 100, 0), count(300, 200, 150), count(400, 100, 0)])
        cache = json.loads(self.run_event(None, provider="codex")["label"])["cache"]
        self.assertEqual(cache, {"requests": 3, "read": 150, "uncached": 250, "since": cache["since"]})

    def test_compaction_log_keeps_recorded_facts_only(self):
        def boundary(at, before, after, **meta):
            return claude("system", subtype="compact_boundary", timestamp=at,
                          compactMetadata={"trigger": "auto", "preTokens": before, "postTokens": after, **meta})
        # The older compaction is found on the first read; the newer one when read.
        self.write([boundary("2026-11-05T10:00:00Z", 300000, 12000, durationMs=40000),
                    assistant([{"type": "text", "text": "a"}], usage=50000),
                    claude("system", subtype="compact_boundary", timestamp="2026-11-05T11:00:00Z",
                           compactMetadata={"trigger": "manual", "preTokens": 80000}),
                    assistant([{"type": "text", "text": "b"}], usage=9000)])
        log = json.loads(self.run_event(None)["label"])["log"]
        self.assertEqual(log[0], {"at": 1793872800, "trigger": "auto", "before": 300000, "after": 12000, "took": 40.0})
        # No postTokens: the size after is the next request's; no duration is made up.
        self.assertEqual(log[1], {"at": 1793876400, "trigger": "manual", "before": 80000, "after": 9002})

    def test_codex_compaction_has_no_trigger_and_takes_the_next_size(self):
        def count(sent):
            return {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"input_tokens": sent, "cached_input_tokens": 0, "output_tokens": 0}}}}
        def compacted(at, before):
            return {"type": "compacted", "timestamp": at, "payload": {
                "latest_token_usage_record": {"usage": {"input_tokens": before}}, "replacement_history": []}}
        self.write([count(240000), compacted("2026-11-05T10:00:00Z", 245000), count(0), count(33000),
                    count(90000), compacted("2026-11-05T12:00:00Z", 246000), count(31000)])
        log = json.loads(self.run_event(None, provider="codex")["label"])["log"]
        self.assertEqual(log, [{"at": 1793872800, "before": 245000, "after": 33000},
                               {"at": 1793880000, "before": 246000, "after": 31000}])

    def test_a_missing_transcript_publishes_nothing(self):
        self.assertIsNone(context.update(None, {"session_id": "s1", "transcript_path": self.path + ".gone"}, [],
                                         "claude", report.adapter("claude")))

    def test_a_new_session_without_a_transcript_replaces_the_old_label(self):
        self.write([assistant([], usage=100)])
        old = self.run_event(None)
        later = self.path + ".later"
        start = [{"type": "session.start"}]
        state = context.update(old, {"session_id": "s2", "transcript_path": later}, start,
                               "claude", report.adapter("claude"))
        value = json.loads(state["label"])
        self.assertEqual((value["sessionId"], value["used"], value["rows"]), ("s2", 0, []))
        # The transcript comes after the start; a tool event of the new session reads it.
        self.path = later
        self.write([assistant([], usage=300)])
        self.assertEqual(json.loads(self.run_event(state, session="s2")["label"])["used"], 302)


if __name__ == "__main__":
    unittest.main()
