import concurrent.futures
from contextlib import closing
import json
import os
from pathlib import Path
import subprocess
import sys
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report  # noqa: E402


def event(kind, session="s1", agent="a1", **extra):
    return {**dict(hook_event_name=kind, session_id=session, agent_id=agent, agent_type="Explore"), **extra}


def update(state, payload, provider, now):
    """The subagent state after one hook payload, or None when it did not change."""
    module = report.adapter(provider)
    if module is None or not isinstance(payload, dict):
        return None
    return report.reduce(state, module.normalize(payload), provider, now)


class ReporterTests(unittest.TestCase):
    def setUp(self):
        # Never read the real Codex thread table from a test.
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.codex_home = Path(folder.name)
        patcher = patch.dict(os.environ, {"CODEX_HOME": folder.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def codex_thread(self, agent_id, nickname, path, effort, version=5):
        with closing(sqlite3.connect(self.codex_home / f"state_{version}.sqlite")) as db:
            db.execute("CREATE TABLE IF NOT EXISTS threads (id TEXT PRIMARY KEY, agent_nickname TEXT, "
                       "agent_path TEXT, reasoning_effort TEXT, first_user_message TEXT)")
            db.execute("INSERT INTO threads VALUES (?, ?, ?, ?, 'private task')", (agent_id, nickname, path, effort))
            db.commit()

    def test_start_stop_and_resume(self):
        state = update(None, event("SubagentStart"), "claude", 1)
        self.assertEqual(state["agents"][0]["status"], "working")
        state = update(state, event("SubagentStop", last_assistant_message="Result"), "claude", 2)
        self.assertNotIn("Result", json.dumps(state))
        self.assertEqual(state["agents"][0]["status"], "done")
        state = update(state, event("SubagentStart"), "claude", 3)
        self.assertEqual(len(state["agents"]), 1)
        self.assertNotIn("result", state["agents"][0])

    def test_session_switch_rejects_late_events(self):
        state = update(None, event("SubagentStart"), "codex", 1)
        state = update(state, event("UserPromptSubmit", session="s2", agent=None), "codex", 2)
        self.assertEqual(state["agents"], [])
        self.assertIsNone(update(state, event("SubagentStop"), "codex", 3))
        self.assertIsNone(update(state, event("SessionEnd", agent=None), "codex", 4))

    def test_session_end_and_resume_do_not_leave_agents_working(self):
        for kind in ("SessionEnd", "SessionStart"):
            state = update(None, event("SubagentStart"), "claude", 1)
            state = update(state, event(kind, source="resume"), "claude", 2)
            self.assertEqual(state["agents"][0]["status"], "interrupted")

    def test_compaction_keeps_active_agents(self):
        state = update(None, event("SubagentStart"), "claude", 1)
        # Compaction changes nothing, so nothing is sent; the agent stays working.
        self.assertIsNone(update(state, event("SessionStart", source="compact"), "claude", 2))
        self.assertEqual(state["agents"][0]["status"], "working")
        self.assertIsNone(update(state, event("UserPromptSubmit"), "claude", 3))

    def test_payload_size_and_history_are_bounded(self):
        state = None
        for index in range(30):
            state = update(state, event("SubagentStart", agent=str(index)), "codex", index)
            state = update(state, event("SubagentStop", agent=str(index),
                                              last_assistant_message="x" * 5000), "codex", index + 0.5)
        self.assertEqual(len(state["agents"]), 16)
        self.assertNotIn("last_assistant_message", json.dumps(state))
        # Fields that are not published, for example from an older cache, are dropped.
        state["agents"][0]["result"] = "private result"
        state = update(state, event("SubagentStart", agent="new"), "codex", 99)
        self.assertNotIn("private result", json.dumps(state))

    def test_parallel_agents_publish_without_lost_updates(self):
        with tempfile.TemporaryDirectory() as folder:
            published = []
            def send(terminal, pairs):
                published.append((terminal, len(json.loads(pairs[report.LABEL])["agents"])))
            def start(index):
                report.record(event("SubagentStart", agent=str(index)), "claude", "t1", Path(folder), send)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(start, range(12)))
            self.assertEqual([count for _, count in published], list(range(1, 13)))
            self.assertEqual(len(json.loads(next(Path(folder).glob("*.json")).read_text())["agents"]), 12)

    def test_no_terminal_does_not_write_or_publish(self):
        with tempfile.TemporaryDirectory() as folder:
            report.record(event("SubagentStart"), "claude", None, Path(folder),
                          lambda *args: self.fail("must not publish"))
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_unknown_or_missing_event_fields_are_ignored(self):
        for payload, provider in (({}, "claude"), (event("PreToolUse"), "claude"),
                                  (event("SubagentStart", agent=None), "claude"),
                                  (event("PostToolUse", agent=None, tool_name="Read", tool_response="private"), "codex"),
                                  (event("PostToolUse", agent=None, tool_name="Agent", tool_response={}), "codex"),
                                  (event("PostModelRequest", agent=None, token_usage={"total_tokens": 100}), "codex"),
                                  (None, "codex")):
            self.assertIsNone(update(None, payload, provider, 1))
        # Token counts are not published: they are not reliable for every provider.
        state = update(None, event("PostToolUse", agent=None, tool_name="Agent",
                                   tool_response={"agentId": "a1", "totalTokens": 900}), "claude", 1)
        self.assertNotIn("900", json.dumps(state))

    def test_claude_tool_response_enriches_the_returned_agent_not_the_caller(self):
        state = update(None, event("SubagentStart", agent="caller"), "claude", 0)
        state = update(state, event("SubagentStart", agent="child"), "claude", 1)
        payload = event("PostToolUse", agent="caller", effort={"level": "high"}, tool_name="Agent",
                        tool_input={"name": "Scout", "description": "Find endpoints", "model": "haiku",
                                    "subagent_type": "Explore", "prompt": "private prompt"},
                        tool_response={"agentId": "child", "status": "completed", "totalTokens": 12450,
                                       "resolvedModel": "claude-sonnet-4-5", "content": "private result"})
        state = update(state, payload, "claude", 2)
        rows = {row["id"]: row for row in state["agents"]}
        self.assertEqual(rows["child"]["name"], "Scout")
        self.assertEqual(rows["child"]["description"], "Find endpoints")
        self.assertEqual(rows["child"]["model"], "claude-sonnet-4-5")
        self.assertEqual(rows["child"]["modelLabel"], "sonnet-4-5")
        self.assertEqual(rows["child"]["endedAt"], 2)
        self.assertEqual(rows["child"]["status"], "done")
        self.assertNotIn("effort", rows["child"])
        self.assertEqual(rows["caller"]["effort"], "high")
        self.assertNotIn("private", json.dumps(state))

    def test_live_effort_and_late_background_metadata_preserve_stopped_status(self):
        state = update(None, event("SubagentStart"), "claude", 1)
        payload = event("PostToolUse", tool_name="Read", effort={"level": "high"})
        state = update(state, payload, "claude", 2)
        self.assertEqual(state["agents"][0]["effort"], "high")
        self.assertIsNone(update(state, payload, "claude", 3))
        state = update(state, event("SubagentStop", effort={"level": "medium"}), "claude", 4)
        state = update(state, event("PostToolUse", agent=None, tool_name="Agent",
                            tool_input={}, tool_response={"agentId": "a1", "status": "async_launched",
                            "resolvedModel": "claude-opus-4-6", "description": "Inspect files"}), "claude", 5)
        row = state["agents"][0]
        self.assertEqual(row["status"], "done")
        self.assertEqual(row["effort"], "medium")
        self.assertEqual(row["description"], "Inspect files")

    def test_codex_spawn_and_request_metadata_keep_child_identity(self):
        state = update(None, event("SubagentStart", model="child-model"), "codex", 1)
        state = update(state, event("PostToolUse", agent=None, tool_name="spawn_agent", model="parent-model",
                              tool_input={"message": "Inspect files " * 100, "reasoning_effort": "high"},
                              tool_response=json.dumps({"agent_id": "a1", "nickname": "Scout"})), "codex", 2)
        row = state["agents"][0]
        self.assertEqual(row["name"], "Scout")
        self.assertEqual(row["model"], "child-model")
        self.assertEqual(row["effort"], "high")
        self.assertEqual(len(row["description"]), 300)
        # A child request under the child's own session updates the parent's row.
        state = update(state, event("PostModelRequest", session="a1", model="child-model-2",
                              status="completed", token_usage={"total_tokens": 12000}), "codex", 3)
        self.assertEqual(state["sessionId"], "s1")
        self.assertEqual(state["agents"][0]["model"], "child-model-2")
        self.assertNotIn("12000", json.dumps(state))
        # The same model again changes nothing, so nothing is published.
        self.assertIsNone(update(state, event("PostModelRequest", session="a1", model="child-model-2",
                                                     token_usage={"total_tokens": 14000}), "codex", 4))
        self.assertIsNone(update(state, event("PostModelRequest", session="old", agent="old"), "codex", 5))
        # Multi-agent v1: an encrypted task message is not a description.
        state = update(state, event("PostToolUse", agent=None, tool_name="spawn_agent",
                                    tool_input={"message": "gAAAAAB" + "x" * 80},
                                    tool_response={"agent_id": "a2", "nickname": "Scout"}), "codex", 6)
        row = report.find(state, "a2")
        self.assertEqual(row["name"], "Scout")
        self.assertNotIn("description", row)

    def test_repeated_tool_metadata_does_not_publish_again(self):
        payload = event("PostToolUse", agent=None, tool_name="Agent",
                        tool_input={"description": "Inspect files"},
                        tool_response={"agentId": "a1", "status": "async_launched"})
        with tempfile.TemporaryDirectory() as folder:
            published = []
            for _ in range(2):
                report.record(payload, "claude", "t1", Path(folder), lambda *args: published.append(args))
            # The activity log counts the repeat; the subagent label is not sent again.
            self.assertEqual(sum(report.LABEL in pairs for _, pairs in published), 1)


    def test_stop_or_metadata_for_unknown_agents_adds_no_row(self):
        # Claude's internal helpers send SubagentStop without a start or a type.
        state = update(None, event("SubagentStart"), "claude", 1)
        self.assertIsNone(update(state, event("SubagentStop", agent="helper", agent_type=None,
                                                      effort={"level": "xhigh"}), "claude", 2))
        self.assertIsNone(update(state, event("PostToolUse", agent="helper", tool_name="Read",
                                                      effort={"level": "xhigh"}), "claude", 3))
        self.assertIsNone(update(state, event("PostModelRequest", agent="helper"), "codex", 4))
        self.assertEqual([row["id"] for row in state["agents"]], ["a1"])

    def test_task_stop_interrupts_the_agent_and_ignores_shells(self):
        state = update(None, event("SubagentStart"), "claude", 1)
        shell = event("PostToolUse", agent=None, tool_name="TaskStop", tool_input={"task_id": "b1"},
                      tool_response={"task_id": "b1", "task_type": "local_bash"})
        self.assertIsNone(update(state, shell, "claude", 2))
        stop = event("PostToolUse", agent=None, tool_name="TaskStop", tool_input={"task_id": "a1"},
                     tool_response={"task_id": "a1", "task_type": "local_agent"})
        state = update(state, stop, "claude", 3)
        self.assertEqual(state["agents"][0]["status"], "interrupted")
        self.assertEqual(state["agents"][0]["endedAt"], 3)
        # A later stop changes nothing: the first outcome stays.
        self.assertIsNone(update(state, event("SubagentStop"), "claude", 4))

    def test_restart_begins_a_new_run_and_late_metadata_keeps_order(self):
        state = update(None, event("SubagentStart", agent="old"), "claude", 1)
        state = update(state, event("SubagentStop", agent="old"), "claude", 2)
        state = update(state, event("SubagentStart", agent="new"), "claude", 3)
        state = update(state, event("SubagentStop", agent="new"), "claude", 4)
        late = event("PostToolUse", agent=None, tool_name="Agent", tool_input={"description": "Late"},
                     tool_response={"agentId": "old", "status": "completed"})
        state = update(state, late, "claude", 5)
        self.assertEqual([row["id"] for row in state["agents"]], ["new", "old"])
        self.assertEqual(state["agents"][1]["endedAt"], 2)
        state = update(state, event("SubagentStart", agent="old"), "claude", 6)
        row = state["agents"][0]
        self.assertEqual((row["id"], row["status"], row["startedAt"]), ("old", "working", 6))
        self.assertNotIn("endedAt", row)

    def test_unknown_providers_and_adapter_paths_are_rejected(self):
        for provider in ("gemini", "common", "../claude", "Claude", "", None):
            self.assertIsNone(report.adapter(provider))
            self.assertIsNone(update(None, event("SubagentStart"), provider, 1))

    def test_isolated_hook_run_loads_adapters_and_publishes(self):
        package = Path(report.__file__).parent
        files = sorted(package.rglob("*"))
        start = json.dumps(event("SubagentStart"))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "bin").mkdir()
            hc = root / "bin/hc"
            hc.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$HOME/published"\n')
            hc.chmod(0o755)
            env = {"HOME": folder, "PATH": f"{root / 'bin'}:/usr/bin:/bin", "HC_TERMINAL_ID": "t1"}

            def hook(stdin, *args, **extra):
                return subprocess.run([sys.executable, "-I", str(package / "report.py"), *args], input=stdin,
                                      text=True, env={**env, **extra}, capture_output=True, check=True)
            # A bad payload, no agent, or no Herdr terminal: `{}`, exit 0, and nothing published.
            for stdin, args, extra in (("not json", ["claude"], {}), (start, [], {}),
                                       (start, ["claude"], {"HC_TERMINAL_ID": ""})):
                self.assertEqual(hook(stdin, *args, **extra).stdout, "{}\n")
            self.assertFalse((root / "published").exists())
            run = hook(start, "claude")
            self.assertEqual((run.stdout, run.stderr), ("{}\n", ""))
            terminal, label = (root / "published").read_text().splitlines()[1:3]
            self.assertEqual(terminal, "t1")
            state = json.loads(label.split("=", 1)[1])
            self.assertEqual((state["version"], state["agents"][0]["type"]), (2, "Explore"))
            # Bytecode goes to the cache, so the next hook does not compile again.
            self.assertTrue(any((root / ".cache/bettr/pycache").rglob("*.pyc")))
        self.assertEqual(sorted(package.rglob("*")), files)  # No bytecode or other files next to the reporter.


    def test_codex_v2_names_come_from_the_local_thread_table(self):
        self.codex_thread("old", "Old", "/root/old", "low", version=4)
        self.codex_thread("c1", "Hume", "/root/panel_test_one", "high")
        state = update(None, event("SubagentStart", agent="c1", agent_type="default", model="gpt-x"), "codex", 1)
        row = state["agents"][0]
        self.assertEqual((row["name"], row["description"], row["effort"], row["model"]),
                         ("Hume", "panel test one", "high", "gpt-x"))
        self.assertNotIn("private task", json.dumps(state))
        # v2 spawn responses carry only the task path, and an encrypted message.
        spawn = event("PostToolUse", agent=None, tool_name="spawn_agent",
                      tool_input={"task_name": "panel_test_one", "message": "gAAAAABq6nV7QQ42rXtwkWJqzq3nka-N9k1Nz"},
                      tool_response=json.dumps({"task_name": "/root/panel_test_one"}))
        self.assertIsNone(update(state, spawn, "codex", 2))

    def test_codex_without_thread_table_still_reports_the_agent(self):
        (self.codex_home / "state_5.sqlite").write_text("not a database")
        state = update(None, event("SubagentStart", agent="c1", agent_type="default"), "codex", 1)
        self.assertEqual(state["agents"][0]["type"], "default")
        self.assertNotIn("name", state["agents"][0])


if __name__ == "__main__":
    unittest.main()
