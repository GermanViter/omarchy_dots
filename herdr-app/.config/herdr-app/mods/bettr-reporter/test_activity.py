import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import activity  # noqa: E402
from providers import classify, common  # noqa: E402
import report  # noqa: E402


def hook(kind, session="s1", **extra):
    return {"hook_event_name": kind, "session_id": session, "cwd": "/repo", **extra}


def tool(name, tool_input, tool_response=None, kind="PostToolUse", **extra):
    return hook(kind, tool_name=name, tool_input=tool_input, tool_response=tool_response or {}, **extra)


def apply(state, payload, now, provider="claude"):
    """The activity state after one hook payload, or None when it did not change."""
    events = report.adapter(provider).normalize(payload)
    return report.apply({activity.LABEL: state}, events, provider, now).get(activity.LABEL)


def run(events, provider="claude", state=None):
    now = 100
    for payload in events:
        now += 1
        state = apply(state, payload, now, provider) or state
    return state


def labels(state):
    """Every label of a state, as its first publication sends them."""
    return report.changes(report.published({}), {activity.LABEL: state})


def entries(state, turn=-1):
    return state["turns"][turn]["entries"]


class CodexHome(unittest.TestCase):
    """Never read the real Codex thread table from a test."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        patcher = patch.dict(os.environ, {"CODEX_HOME": folder.name})
        patcher.start()
        self.addCleanup(patcher.stop)


class ClassifierTests(unittest.TestCase):
    def test_commands_are_recorded_without_interpretation(self):
        cases = {
            "cd /x && node --test mods/a.test.js 2>&1 | tail -8": "node --test mods/a.test.js 2>&1 | tail -8",
            'A=1 B="x y" timeout 30 pytest -q': "pytest -q",
            "export X=1; git push": "git push",
            'cd ~/x && f=$(ls -t *.json | head -1); python3 - "$f"': 'python3 - "$f"',
            'A=$(date +%s) make test': "make test",
            'cd "/a b" && ls': "ls",
            "cd /tmp": "cd /tmp",
            "/usr/bin/git status --short": "git status --short",
            "/opt/homebrew/bin/rg x": "rg x",
            "~/bin/tool run": "~/bin/tool run",
            "python3 - <<'EOF'\nprint(1)\nEOF": "python3 - <<'EOF'",
            "ugly \"unbalanced": 'ugly "unbalanced',
        }
        for command, label in cases.items():
            self.assertEqual(classify.shell_entry(command, "ok")["label"], label, command)
        heredoc = classify.shell_entry("python3 - <<'EOF'\nprint(1)\nEOF")
        self.assertEqual((heredoc["kind"], heredoc["detail"]), ("run", "python3 - <<'EOF'\nprint(1)\nEOF"))
        self.assertNotIn("detail", classify.shell_entry("git status"))
        self.assertIsNone(classify.shell_entry("  "))

    def test_patches_and_code_mode_calls(self):
        patch_text = ("*** Begin Patch\n*** Update File: /repo/a.py\n@@\n-old\n+new\n+more\n"
                      "*** Add File: b.md\n+x\n*** Delete File: c.txt\n*** End Patch")
        self.assertEqual(classify.patch_files(patch_text, "/repo"),
                         [["a.py", 2, 1, "modified"], ["b.md", 1, 0, "created"], ["c.txt", 0, 0, "deleted"]])
        code = ('await tools.exec_command({cmd:"cat \\"AGENTS.md\\"","workdir":"/x"}); '
                "await tools.apply_patch(`*** Begin Patch\n*** Update File: a.js\n+x\n*** End Patch`); "
                "await tools.web__run({q: 'x'})")
        self.assertEqual(classify.code_mode_calls(code), [
            ("exec_command", 'cat "AGENTS.md"'),
            ("apply_patch", "*** Begin Patch\n*** Update File: a.js\n+x\n*** End Patch"),
            ("web__run", "")])

    def test_credentials_are_redacted(self):
        for command, secret in (('curl -H "Authorization: Bearer abc123" https://x', "abc123"),
                                ('curl -H "Authorization: token abc123" https://x', "abc123"),
                                ("GITHUB_TOKEN=ghp_xx gh pr create", "ghp_xx"),
                                ("AWS_SECRET_ACCESS_KEY=abc123 aws s3 ls", "abc123"),
                                ("GITHUB_PAT=abc123 gh repo list", "abc123"),
                                ("mysql --password=hunter2 -u root", "hunter2"),
                                ("gh pr create --token abc123", "abc123"),
                                ("psql postgres://ann:hunter2@db/prod", "hunter2"),
                                ("curl -u ann:hunter2 https://x", "hunter2"),
                                ("echo sk-ant-api03-abcdefgh | pbcopy", "abcdefgh"),
                                ('curl -H "Cookie: session=abc123" https://x', "abc123")):
            entry = classify.shell_entry(command)
            self.assertNotIn(secret, json.dumps(entry), command)
        # Prompts, fetched URLs and replies are published too.
        state = run([hook("UserPromptSubmit", prompt="use TOKEN=abc123"),
                     tool("WebFetch", {"url": "https://ann:hunter2@x.com/?api_key=abc123"}),
                     hook("Stop", last_assistant_message="I set API_KEY=abc123")])
        self.assertNotIn("abc123", json.dumps(state))
        self.assertNotIn("hunter2", json.dumps(state))
        # A long command is redacted only as far as it can be shown.
        started = time.perf_counter()
        classify.shell_entry("echo " + "ab-" * 17000)
        self.assertLess(time.perf_counter() - started, 0.5)

    def test_paths_are_relative_to_the_session_folder(self):
        self.assertEqual(classify.relative("/repo/mods/a.js", "/repo"), "mods/a.js")
        self.assertEqual(classify.relative(os.path.expanduser("~/notes.md"), "/repo"), "~/notes.md")


class ReducerTests(unittest.TestCase):
    def test_turns_follow_prompts_and_stops(self):
        state = run([hook("UserPromptSubmit", prompt="\n  fix the panel\nmore detail"),
                     tool("Read", {"file_path": "/repo/a.js"}),
                     hook("Stop"),
                     hook("UserPromptSubmit", prompt="commit"),
                     hook("UserPromptSubmit", prompt="again")])
        first, second = state["turns"]
        self.assertEqual((first["prompt"], first["outcome"], first["endedAt"]), ("fix the panel", "done", 103))
        self.assertEqual(second["entries"][0]["kind"], "steer")  # A prompt while working.
        self.assertNotIn("endedAt", second)
        later = apply(state, hook("UserPromptSubmit", prompt="much later"), 106 + activity.STALE_TURN)
        self.assertEqual(later["turns"][-2]["outcome"], "interrupted")

    def test_consecutive_work_is_merged(self):
        state = run([hook("UserPromptSubmit", prompt="go"),
                     tool("Read", {"file_path": "/repo/a.js"}),
                     tool("Read", {"file_path": "/repo/b.js"}),
                     tool("Grep", {"pattern": "x", "path": "/repo/mods"}),
                     tool("Glob", {"pattern": "**/*.js"}),
                     tool("Grep", {"pattern": "x"}),
                     tool("Read", {"file_path": "/repo/a.js"}),
                     tool("Bash", {"command": "ls"}, {"stdout": ""}),
                     tool("Edit", {"file_path": "/repo/a.js"}, {"structuredPatch": [{"lines": ["-a", "+b", "+c"]}]}),
                     tool("Edit", {"file_path": "/repo/a.js"}, {"structuredPatch": [{"lines": ["+d"]}]}),
                     tool("Write", {"file_path": "/repo/n.md", "content": "1\n2\n"}, {"type": "create"}),
                     tool("Bash", {"command": "node --test a.js"}, kind="PostToolUseFailure", error="Exit code 1"),
                     tool("Bash", {"command": "cd /repo && node --test a.js"}, {"stdout": "ℹ pass 4"})])
        read, search, again, listed, edit, test = entries(state)
        self.assertEqual((read["items"], again["items"]), (["a.js", "b.js"], ["a.js"]))  # Order is kept.
        self.assertEqual((search["items"], search["repeat"]), (["x", "**/*.js"], 3))
        self.assertEqual((listed["kind"], listed["label"]), ("run", "ls"))
        self.assertEqual(edit["files"], [["a.js", 3, 1, "modified"], ["n.md", 2, 0, "created"]])
        self.assertEqual((test["label"], test["result"], test["repeat"]), ("node --test a.js", "ok", 2))

    def test_messages_sent_while_working_steer_the_open_turn(self):
        state = run([hook("UserPromptSubmit", prompt="fix it"),
                     tool("Bash", {"command": "make"}),
                     hook("UserPromptSubmit", prompt="also the docs\nplease"),
                     hook("UserPromptSubmit", prompt="<task-notification><summary>Agent \"A\" finished</summary>"
                                                     "</task-notification>"),
                     hook("Stop", last_assistant_message="  Fixed it.\n\n- make passes  "),
                     hook("UserPromptSubmit", prompt="next")])
        first, second = state["turns"]
        self.assertEqual([(entry["kind"], entry.get("label")) for entry in first["entries"]],
                         [("run", "make"), ("steer", "also the docs"), ("notice", 'Agent "A" finished')])
        self.assertEqual((first["reply"], first["outcome"], second["prompt"]),
                         ("Fixed it.\n\n- make passes", "done", "next"))

    def test_harness_messages_become_notices(self):
        notification = ("<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n"
                        '<summary>Agent "Scout" finished</summary>\n<result>long text</result>\n</task-notification>')
        state = run([hook("UserPromptSubmit", prompt=notification), hook("Stop"),
                     hook("UserPromptSubmit", prompt='<agent-message from="a6f">\nFF-48 landed\n</agent-message>'),
                     hook("Stop"),
                     hook("UserPromptSubmit", prompt="<system-reminder>x</system-reminder>\nreal question"),
                     hook("Stop"),
                     hook("UserPromptSubmit", prompt="<system-reminder>only</system-reminder>"),
                     hook("UserPromptSubmit", prompt="<command-name>/review</command-name>\n"
                                                     "<command-args>42</command-args>")])
        notice, message, user, command = state["turns"]
        self.assertEqual(command["prompt"], "/review 42")
        self.assertEqual((notice["prompt"], notice["source"]), ('Agent "Scout" finished', "notice"))
        self.assertEqual((message["prompt"], message["source"], message["from"]), ("", "notice", "a6f"))
        self.assertEqual((user["prompt"], "source" in user), ("real question", False))
        # Messages from different agents during a turn stay separate.
        steered = run([hook("UserPromptSubmit", prompt="go"),
                       hook("UserPromptSubmit", prompt='<agent-message from="a">x</agent-message>'),
                       hook("UserPromptSubmit", prompt='<agent-message from="b">y</agent-message>')])
        self.assertEqual([entry.get("from") for entry in entries(steered)], ["a", "b"])

    def test_failures_and_interrupts_are_kept(self):
        state = run([hook("UserPromptSubmit", prompt="go"),
                     tool("Bash", {"command": "cargo build"}, kind="PostToolUseFailure", error="Exit code 101"),
                     tool("Bash", {"command": "pytest"}, kind="PostToolUseFailure", error="x", is_interrupt=True),
                     tool("Edit", {"file_path": "/repo/a.js"}, kind="PostToolUseFailure", error="no match"),
                     hook("StopFailure")])
        build, test = entries(state)
        self.assertEqual((build["label"], build["result"]), ("cargo build", "failed"))
        self.assertEqual((test["label"], test["result"]), ("pytest", "interrupted"))
        self.assertEqual(state["turns"][-1]["outcome"], "interrupted")  # The interrupt ended it.

    def test_subagent_work_is_ignored_and_bookkeeping_tools_are_named(self):
        state = run([hook("UserPromptSubmit", prompt="go"),
                     tool("Read", {"file_path": "/repo/a.js"}, agent_id="child"),
                     tool("ToolSearch", {"query": "x"})])
        # Bookkeeping tools are recorded with their name; the panel's verb table hides them.
        self.assertEqual(entries(state), [{"kind": "tool", "tool": "ToolSearch", "at": 103}])
        state = run([hook("Stop")], state=state)
        self.assertIsNone(apply(state, hook("Stop"), 200))

    def test_new_session_replaces_the_log_and_late_events_are_ignored(self):
        state = run([hook("UserPromptSubmit", prompt="old"), tool("Bash", {"command": "make"})])
        state = run([hook("SessionStart", session="s2", source="startup")], state=state)
        self.assertEqual((state["sessionId"], state["turns"]), ("s2", []))
        self.assertIsNone(apply(state, tool("Bash", {"command": "make"}), 300))

    def test_each_turn_is_its_own_label_and_only_changes_are_sent(self):
        state = run([hook("UserPromptSubmit", prompt="one"), tool("Bash", {"command": "make"}), hook("Stop"),
                     hook("UserPromptSubmit", prompt="two")])
        values = labels(state)
        self.assertEqual(sorted(values), ["bettr.activity", "bettr.activity.1", "bettr.activity.2"])
        index = json.loads(values["bettr.activity"])
        self.assertEqual([(turn["id"], turn["prompt"]) for turn in index["turns"]], [(1, "one"), (2, "two")])
        self.assertNotIn("entries", index["turns"][0])
        self.assertNotIn("direct", values["bettr.activity"])
        self.assertEqual(json.loads(values["bettr.activity.1"])["entries"][0]["label"], "make")
        before = report.published({activity.LABEL: state})
        later = apply(state, tool("Bash", {"command": "ls"}), 300)
        self.assertEqual(sorted(report.changes(before, {activity.LABEL: later})), ["bettr.activity.2"])
        # A new session reuses turn IDs: its turn 1 is sent again, and old turn 2 is removed.
        before = report.published({activity.LABEL: later})
        fresh = apply(later, hook("UserPromptSubmit", session="s2", prompt="new"), 400)
        sent = report.changes(before, {activity.LABEL: fresh})
        self.assertEqual((json.loads(sent["bettr.activity.1"]), sent["bettr.activity.2"]), ({}, ""))

    def test_an_older_cache_is_replaced_by_the_split_labels(self):
        old = {"version": 3, "provider": "claude", "sessionId": "s1", "turns": [{"prompt": "x", "startedAt": 1,
                                                                                  "entries": []}]}
        before = report.published({activity.LABEL: old})
        sent = report.changes(before, {activity.LABEL: apply(old, tool("Bash", {"command": "ls"}), 5)})
        self.assertEqual(json.loads(sent["bettr.activity"])["version"], activity.VERSION)
        self.assertIn("bettr.activity.1", sent)

    def test_steps_keep_event_order_and_late_steps_join_the_ended_turn(self):
        state = run([hook("UserPromptSubmit", prompt="go"), tool("Bash", {"command": "make"})])
        turn = state["turns"][-1]
        activity.add(turn, {"kind": "run", "label": "early"}, turn["entries"][0]["at"] - 0.5)
        self.assertEqual([entry["label"] for entry in turn["entries"]], ["early", "make"])
        state = run([hook("Stop")], state=state)
        ended = state["turns"][-1]["endedAt"]
        late = apply(state, tool("Bash", {"command": "ls"}), ended + 2)
        self.assertEqual(len(late["turns"]), 1)
        self.assertEqual(late["turns"][0]["entries"][-1]["label"], "ls")
        # Later work without a prompt opens a new, unprompted turn.
        later = apply(state, tool("Bash", {"command": "pwd"}), ended + 60)
        self.assertEqual((later["turns"][-1]["prompt"], entries(later)[0]["label"]), ("", "pwd"))

    def test_labels_are_bounded_in_bytes_for_any_text(self):
        events = []
        for index in range(40):
            events.append(hook("UserPromptSubmit", prompt=f"turn {index} " + "日本語のテキスト" * 15))
            events += [tool("Bash", {"command": f"tool{n} " + "漢字" * 140}) for n in range(30)]
            events.append(hook("Stop", last_assistant_message="z" * 3000))
        state = run(events)
        self.assertEqual([len(turn["entries"]) for turn in state["turns"]], [30] * 40)  # Every turn is kept.
        values = labels(state)
        self.assertTrue(all(len(value.encode()) <= activity.MAX_BYTES for value in values.values()))
        self.assertIn("日本語", values["bettr.activity"])  # Not escaped.


class MessageTests(CodexHome):
    def transcript(self, items):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = Path(folder.name) / "t.jsonl"
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def test_claude_text_before_a_tool_call_is_logged_in_order(self):
        said = lambda *blocks: {"type": "assistant", "message": {"content": list(blocks)}}
        path = self.transcript([
            {"type": "user", "message": {"content": "go"}},
            said({"type": "text", "text": "Checking the **tests** first."}),
            said({"type": "tool_use", "id": "t1", "name": "Bash"}),
            said({"type": "tool_use", "id": "t2", "name": "Bash"}),
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1"}]}},
            {"type": "attachment"},
            said({"type": "text", "text": "Now"}, {"type": "text", "text": "the fix."},
                 {"type": "tool_use", "id": "t3", "name": "Edit"})])
        events = [hook("UserPromptSubmit", prompt="go")]
        for tool_id in ("t1", "t2", "t3"):
            events.append(tool("Bash", {"command": f"echo {tool_id}"}, {"stdout": ""}, tool_use_id=tool_id,
                               transcript_path=path))
        kinds = [(entry["kind"], entry.get("text") or entry.get("label")) for entry in entries(run(events))]
        self.assertEqual(kinds, [("message", "Checking the **tests** first."), ("run", "echo t1"),
                                 ("run", "echo t2"), ("message", "Now\n\nthe fix."), ("run", "echo t3")])
        missing = run([hook("UserPromptSubmit", prompt="go"),
                       tool("Bash", {"command": "ls"}, tool_use_id="t9", transcript_path=path + ".gone")])
        self.assertEqual([entry["kind"] for entry in entries(missing)], ["run"])
        # A call not in the transcript yet is waited for, on a clock that does not really sleep.
        clock = [0.0]
        with patch.object(common.time, "monotonic", lambda: clock[0]), \
                patch.object(common.time, "sleep", lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            self.assertEqual(common.message_before(path, "t-late", lambda item: True, lambda item: [],
                                                   lambda item: True), "")

    def test_codex_commentary_before_a_call_is_logged(self):
        item = lambda **payload: {"type": "response_item", "payload": payload}
        path = self.transcript([
            item(type="message", role="user", content=[{"type": "input_text", "text": "go"}]),
            {"type": "event_msg", "payload": {"type": "token_count"}},
            item(type="message", role="assistant", phase="commentary",
                 content=[{"type": "output_text", "text": "I’ll start two tasks."}]),
            item(type="function_call", name="exec_command", call_id="c1"),
            item(type="function_call_output", call_id="c1"),
            item(type="function_call", name="exec_command", call_id="c2")])
        state = run([hook("UserPromptSubmit", prompt="go"),
                     tool("exec_command", {"cmd": "make"}, "Exit code: 0", tool_use_id="c1", transcript_path=path),
                     tool("exec_command", {"cmd": "ls"}, "Exit code: 0", tool_use_id="c2", transcript_path=path)],
                    provider="codex")
        self.assertEqual([entry["kind"] for entry in entries(state)], ["message", "run", "run"])
        self.assertEqual(entries(state)[0]["text"], "I’ll start two tasks.")

    def test_a_prompt_after_an_interrupt_starts_a_new_turn(self):
        said = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash"}]}}
        stopped = {"type": "user", "timestamp": "1970-01-01T00:01:42Z",
                   "message": {"content": [{"type": "text", "text": "[Request interrupted by user for tool use]"}]}}
        prompt = {"type": "user", "message": {"content": "next"}}
        working = self.transcript([said, {"type": "attachment"}])
        ended = self.transcript([said, stopped, {"type": "system", "subtype": "turn_duration",
                                                 "timestamp": "1970-01-01T00:01:42.500Z"}, prompt])
        first = [hook("UserPromptSubmit", prompt="go"), tool("Bash", {"command": "ls"}, transcript_path=working)]
        steered = run(first + [hook("UserPromptSubmit", prompt="also", transcript_path=working)])
        self.assertEqual([len(steered["turns"]), entries(steered)[-1]["kind"]], [1, "steer"])
        state = run(first + [hook("UserPromptSubmit", prompt="next", transcript_path=ended)])
        self.assertEqual([(turn["prompt"], turn.get("outcome")) for turn in state["turns"]],
                         [("go", "interrupted"), ("next", None)])
        self.assertEqual(state["turns"][0]["endedAt"], 102.5)  # The interrupt's time, not the prompt's.
        item = lambda kind, **payload: {"type": kind, "payload": payload}
        aborted = self.transcript([item("response_item", type="function_call", call_id="c1"),
                                   item("event_msg", type="turn_aborted", completed_at=102),
                                   item("response_item", type="message", role="user", content=[])])
        codex = run([hook("UserPromptSubmit", prompt="go"),
                     tool("exec_command", {"cmd": "ls"}, "Exit code: 0", transcript_path=working),
                     hook("UserPromptSubmit", prompt="next", transcript_path=aborted)], provider="codex")
        self.assertEqual([turn.get("outcome") for turn in codex["turns"]], ["interrupted", None])


class CodexTests(CodexHome):
    def test_shell_patch_and_agent_tools(self):
        state = run([hook("UserPromptSubmit", prompt="go"),
                     tool("exec_command", {"cmd": "timeout 60 npm test"}, "Process exited with code 1\n2 failed, 5 passed"),
                     tool("apply_patch", "*** Begin Patch\n*** Add File: /repo/x.md\n+a\n*** End Patch"),
                     tool("collaboration.spawn_agent", {"task_name": "fix_auth_bug"}, '{"task_name":"/root/fix_auth_bug"}'),
                     tool("collaboration.wait_agent", {"timeout_ms": 1}),
                     tool("request_user_input_async", {"questions": [{"title": "Which tracker?"}]}),
                     hook("Stop")], provider="codex")
        test, edit, spawned, waited, asked = entries(state)
        self.assertEqual((waited["kind"], waited["tool"]), ("tool", "wait_agent"))
        self.assertEqual((test["label"], test["result"]), ("npm test", "failed"))
        self.assertEqual(edit["files"], [["x.md", 1, 0, "created"]])
        self.assertEqual((spawned["label"], spawned["result"], spawned["tool"]), ("fix auth bug", "started", "spawn_agent"))
        self.assertEqual(asked["label"], "Which tracker?")
        self.assertEqual(state["turns"][-1]["outcome"], "done")

    def test_code_mode_is_a_fallback_when_nested_calls_are_not_reported(self):
        code = 'text(await tools.exec_command({cmd:"cd /x && cat AGENTS.md"}))'
        alone = run([hook("UserPromptSubmit", prompt="go"), tool("exec", code, "done")], provider="codex")
        self.assertEqual(entries(alone)[0]["label"], "cat AGENTS.md")
        both = run([hook("UserPromptSubmit", prompt="go"),
                    tool("exec_command", {"cmd": "cd /x && cat AGENTS.md"}, "Exit code: 0"),
                    tool("exec", code, "done")], provider="codex")
        self.assertEqual(entries(both), [{"kind": "run", "label": "cat AGENTS.md", "result": "ok",
                                          "detail": "cd /x && cat AGENTS.md", "at": 102}])

    def test_child_threads_do_not_reset_or_fill_the_parent_log(self):
        state = run([hook("UserPromptSubmit", prompt="parent"),
                     hook("UserPromptSubmit", session="child", prompt="child task", agent_id="child"),
                     tool("exec_command", {"cmd": "make"}, "Exit code: 0", agent_id="child")], provider="codex")
        self.assertEqual([turn["prompt"] for turn in state["turns"]], ["parent"])
        self.assertEqual(entries(state), [])


if __name__ == "__main__":
    unittest.main()
