import assert from "node:assert/strict";
import test from "node:test";
import { activityRows, activityState, agentNames, describe, fixedFailures, focusedAgent, liveSubagents, program, resolve,
  steps, turnDigest, turnSummary, verbTable } from "./model.js";

// Labels as the reporter writes them: an index of headings, one label per turn.
function split(state) {
  if (!Array.isArray(state?.turns)) return { "bettr.activity": JSON.stringify(state) };
  const labels = {}, headings = [];
  state.turns.forEach((turn, index) => {
    if (!turn || typeof turn !== "object") return headings.push(turn);
    const { entries, dropped, reply, ...heading } = turn;
    const id = heading.id ?? index + 1;
    headings.push({ ...heading, id });
    labels[`bettr.activity.${id}`] = JSON.stringify({ entries, dropped, reply });
  });
  return { ...labels, "bettr.activity": JSON.stringify({ ...state, turns: headings }) };
}
const withLabel = (state, program = { key: "claude-code", agent: true }, extra = {}) => ({
  address: "t1", state: "live", program, labels: { ...split(state), ...extra },
});
const snapshot = (turns, provider = "claude") => ({ version: 4, provider, sessionId: "s1", turns });
const subagents = (agents, provider = "claude") => ({ "bettr.subagents": JSON.stringify(
  { version: 2, provider, sessionId: "s1", agents }) });
const run = (label, extra = {}) => ({ kind: "run", label, ...extra });

test("focus follows the displayed terminal; shells and ended terminals are not agents", () => {
  const all = [{ address: "t1", state: "live", program: { agent: true } },
    { address: "t2", state: "live", program: { agent: true } },
    { address: "t3", state: "live", program: { shell: true } },
    { address: "t4", state: "exited", program: { agent: true } }];
  assert.equal(focusedAgent({ terminal: "t1", shown: "t2" }, all, []).address, "t2");
  assert.equal(focusedAgent({ terminal: "t1", agent: "t2" }, all, []).address, "t1");
  assert.equal(focusedAgent({ terminal: "t3" }, all, []), null);
  assert.equal(focusedAgent({ terminal: "t4" }, all, []), null);
  assert.equal(focusedAgent(null, all, []), null);
});

test("turns stay oldest first and invalid data is dropped", () => {
  const state = activityState(withLabel(snapshot([
    { prompt: "old", startedAt: 1, endedAt: 2, outcome: "done", entries: [{ kind: "run" }, { kind: "bogus" }, null] },
    { prompt: "new", startedAt: 3, entries: [] },
    { prompt: "no start", entries: [] },
  ])));
  assert.deepEqual(state.turns.map(turn => turn.prompt), ["old", "new"]);
  assert.equal(state.turns[0].entries.length, 1);
  assert.equal(activityState(withLabel({ ...snapshot([]), version: 3 })), null);
  assert.equal(activityState({ labels: { "bettr.activity": "bad" } }), null);
});

test("a label from another agent in the same terminal is hidden; any provider works", () => {
  const parent = withLabel(snapshot([]), { key: "claude", agent: true }, subagents([{ id: "a1", status: "working" }]));
  assert.ok(activityState(parent));
  assert.equal(liveSubagents(parent).length, 1);
  // The same label text, now under Codex: still hidden although the label was parsed before.
  const codex = { ...parent, program: { key: "codex", agent: true } };
  assert.equal(activityState(codex), null);
  assert.deepEqual(liveSubagents(codex), []);
  assert.ok(activityState(withLabel(snapshot([], "pi"), { key: "pi", agent: true })));
});

test("one verb table names tools and commands; null hides a step", () => {
  const table = verbTable({ tools: { Grep: "Searched", Glob: "Searched", "mcp__*": "Used", TodoWrite: null },
    commands: { git: "Git", "git commit": "Committed", "node --test": "Tested", pytest: "Tested", sleep: null,
      bad: 3, "": "x" } });
  assert.deepEqual(table.command("git commit -m x"), { key: "git commit", verb: "Committed" });
  assert.equal(table.command("gitk"), undefined);
  assert.equal(resolve({ kind: "tool", tool: "mcp__docs__read" }, table).verb, "Used");
  assert.equal(resolve({ kind: "tool", tool: "LSP" }, table).verb, "LSP");  // No row: the tool's name.
  assert.equal(resolve({ kind: "run", label: "make" }, table).verb, "Ran");
  assert.deepEqual(steps([run("pytest -q"), run("node --test a.js"), run("sleep 5"), run("git push"), run("ls")], table)
    .map(step => step.verb), ["Tested", "Git", "Ran"]);
  // A hidden step between two searches does not split them; Grep and Glob share a row.
  assert.equal(steps([{ kind: "search", tool: "Grep", items: ["a"] }, { kind: "tool", tool: "TodoWrite" },
    { kind: "search", tool: "Glob", items: ["*.js"] }], table).length, 1);
  assert.equal(verbTable({ sleep: null }).command("sleep 1").verb, null);  // A flat object is a commands table.
  // A wildcard tool row does not hide the agent's own text.
  assert.equal(resolve({ kind: "message", text: "hi" }, verbTable({ tools: { "*": null } })).hidden, false);
});

test("neighbouring commands share a row and count failures; other kinds split it", () => {
  const grouped = steps([run("grep -n a x", { repeat: 2 }), run("cd /tmp"), run("make", { result: "failed" }),
    { kind: "read", tool: "Read", items: ["a"] }, run("ls")]);
  assert.deepEqual(grouped.map(step => [step.verb, step.entries.length]), [["Ran", 3], ["Read", 1], ["Ran", 1]]);
  const line = describe(grouped[0].entries);
  assert.deepEqual(line.parts.map(part => part.name), ["grep", "cd", "make"]);
  assert.deepEqual([line.tail, line.tone], ["1 failed", "blocked"]);
  const table = verbTable({ tools: { Agent: "Spawned", SendMessage: "Messaged" } });
  assert.equal(steps([{ kind: "agent", tool: "Agent", label: "A" }, { kind: "agent", tool: "SendMessage", label: "A" }],
    table).length, 2);
});

test("a command's program is its first word", () => {
  assert.deepEqual(["/usr/bin/git status", "f() {", "ls; pwd", "(cd x && make)", "a|b", "'q' x", "~/x/tool"]
    .map(program), ["git", "f", "ls", "cd", "a", "q", "tool"]);
});

test("edits to one file add up, and a file deleted then written again is modified", () => {
  const edits = describe([{ kind: "edit", files: [["a.js", 1, 0, "modified"]] },
    { kind: "edit", files: [["a.js", 2, 1, "modified"]] }]);
  assert.equal(edits.text, "a.js +3 −1");
  assert.equal(edits.diff, true);
  const reborn = describe([{ kind: "edit", files: [["a", 0, 0, "deleted"]] }, { kind: "edit", files: [["a", 3, 0, "created"]] }]);
  assert.equal(reborn.text, "a +3 −0");
});

test("a turn's outcome sets its status; messages name the sending subagent", () => {
  const status = (turn, now) => turnSummary({ startedAt: 0, entries: [], ...turn }, now).status;
  assert.equal(status({}, 10), "Working");
  assert.equal(status({ endedAt: 5, outcome: "done" }, 10), "Done");
  assert.equal(status({ endedAt: 5, outcome: "failed" }, 10), "Failed");
  assert.equal(status({ endedAt: 5, outcome: "interrupted" }, 10), "Stopped");
  const names = agentNames(withLabel(snapshot([]), undefined, subagents([{ id: "a6f", name: "Scout" }])));
  assert.equal(names.get("a6f"), "Scout");
  assert.match(turnSummary({ source: "notice", from: "a6f", startedAt: 0, endedAt: 1, entries: [] }, 1, names).title,
    /Scout/);
});

test("a working turn without steps for 15 minutes is shown as stopped", () => {
  const turn = { prompt: "go", startedAt: 0, entries: [{ kind: "run", label: "ls", at: 60 }] };
  assert.equal(turnSummary(turn, 120).live, true);
  const stale = turnSummary(turn, 60 + 15 * 60);
  assert.deepEqual([stale.live, stale.status], [false, "Stopped"]);
});

test("only working subagents are listed, newest first; bad labels list none", () => {
  const parent = agents => withLabel(snapshot([]), undefined, subagents(agents));
  const rows = liveSubagents(parent([
    { id: "a1", type: "Explore", status: "working", startedAt: 10, modelLabel: "opus-5-5" },
    { id: "a2", type: "Plan", name: "Planner", status: "working", startedAt: 20, effort: "high" },
    { id: "a3", type: "Explore", status: "done", startedAt: 30, endedAt: 40 },
  ]));
  assert.deepEqual(rows.map(row => [row.id, row.name, row.model, row.effort]),
    [["a2", "Planner", "", "high"], ["a1", "Explore", "opus-5-5", ""]]);
  assert.deepEqual(liveSubagents(withLabel(snapshot([]), undefined, { "bettr.subagents": "{bad" })), []);
  assert.deepEqual(liveSubagents(withLabel(snapshot([]))), []);
});

test("a notice is a step row with its own icon verb and nothing to open", () => {
  const state = activityState(withLabel(snapshot([{ prompt: "t", startedAt: 1, endedAt: 2, outcome: "done",
    entries: [{ kind: "notice", label: "Background command finished" }] }])));
  const row = activityRows(state, { now: 9 }).find(item => item.type === "entry");
  assert.equal(row.verb, "Notice");
  assert.equal(row.text, "Background command finished");
  assert.equal(row.expandable, false);
});

test("only an open step's last detail row is marked last", () => {
  const state = activityState(withLabel(snapshot([{ prompt: "t", startedAt: 1, endedAt: 2, outcome: "done",
    entries: [run("ls"), run("pwd")] }])));
  const details = activityRows(state, { now: 9, open: new Set(["s1#1:0"]) }).filter(row => row.type === "detail");
  assert.deepEqual(details.map(row => row.last), [false, true]);
});

test("finished turns are closed, the newest is open, and the person's choice wins", () => {
  const turn = (id, more = {}) => ({ prompt: `t${id}`, startedAt: id, endedAt: id + 1, outcome: "done",
    entries: [run("ls")], ...more });
  const state = activityState(withLabel(snapshot([turn(1), turn(2)])));
  const heads = rows => rows.filter(row => row.type === "prompt").map(row => [row.key, row.expanded]);
  assert.deepEqual(heads(activityRows(state, { now: 9 })), [["s1#1", false], ["s1#2", true]]);
  const chosen = activityRows(state, { now: 9, expanded: new Map([["s1#1", true], ["s1#2", false]]) });
  assert.deepEqual(heads(chosen), [["s1#1", true], ["s1#2", false]]);
  assert.deepEqual(chosen.filter(row => row.type === "entry").map(row => row.key), ["s1#1:0"]);
  // A turn with only hidden steps has nothing to open.
  const hidden = activityRows(activityState(withLabel(snapshot([turn(1, { entries: [{ kind: "tool", tool: "TodoWrite" }] })]))),
    { verbs: verbTable({ tools: { TodoWrite: null } }) });
  assert.deepEqual([hidden.length, hidden[0].expandable], [1, false]);
});

test("two or more finished turns before the newest fold into one row", () => {
  const turn = (id, more = {}) => ({ prompt: `t${id}`, startedAt: id, endedAt: id + 1, outcome: "done",
    entries: [run("ls")], ...more });
  const state = activityState(withLabel(snapshot([turn(1), turn(2), turn(3, { endedAt: undefined })])));
  const folded = activityRows(state, { now: 4 });
  assert.deepEqual(folded.map(row => row.key), ["s1#~older", "s1#3", "s1#3:0", "s1#3:end"]);
  assert.equal(folded[0].count, 2);
  const shown = activityRows(state, { now: 4, expanded: new Map([["s1#~older", true]]) });
  assert.deepEqual(shown.map(row => row.key).slice(0, 3), ["s1#~older", "s1#1", "s1#2"]);
  // One earlier turn is not folded.
  assert.equal(activityRows(activityState(withLabel(snapshot([turn(1), turn(2)]))), { now: 4 })[0].type, "prompt");
});

test("a failed command that a later run of the same command passes is fixed", () => {
  const table = verbTable({ "node --test": "Tested" });
  const entries = [run("node --test a.js", { result: "failed" }), run("make", { result: "failed" }),
    run("node --test", { result: "ok" }), run("make -j4", { result: "ok" }), run("ls", { result: "failed" })];
  const fixed = fixedFailures(entries, table);
  // The table key joins the two test runs; `make` and `make -j4` are different commands.
  assert.deepEqual(entries.map(entry => fixed.has(entry)), [true, false, false, false, false]);
  const tested = describe([entries[0], entries[2]], table, undefined, fixed);
  assert.deepEqual([tested.tail, tested.tone], ["fixed", "dim"]);
  assert.match(tested.details[0], /fixed later/);
  assert.deepEqual(describe([entries[1]], table, undefined, fixed).tail, "failed");
  // A failure after the passing run is not fixed.
  const later = [run("pytest", { result: "ok" }), run("pytest", { result: "failed" })];
  assert.equal(fixedFailures(later).size, 0);
});

test("a finished turn folds its exploration; a working turn does not", () => {
  const entries = [{ kind: "read", tool: "Read", items: ["src/a.js", "b.js"] },
    { kind: "search", tool: "Grep", items: ["foo"], repeat: 2 }, { kind: "web", tool: "WebFetch", label: "x.dev" },
    { kind: "read", tool: "Read", items: ["src/a.js"] }, run("ls"), { kind: "read", tool: "Read", items: ["c.js"] }];
  const table = verbTable({ tools: { Read: "Read", Grep: "Searched", WebFetch: "Fetched" } });
  const rows = turn => activityRows(activityState(withLabel(snapshot([{ prompt: "t", startedAt: 1, entries, ...turn }]))),
    { now: 9, verbs: table }).filter(row => row.type === "entry");
  const done = rows({ endedAt: 2, outcome: "done" });
  assert.deepEqual(done.map(row => row.verb), ["Explored", "Ran", "Read"]);
  assert.equal(done[0].text, "2 files, 2 searches, 1 web lookup");
  assert.deepEqual(done[0].details, ["src/a.js", "b.js", "“foo”", "x.dev"]);
  assert.equal(done[0].key, "s1#1:0");
  assert.deepEqual(rows({}).map(row => row.verb), ["Read", "Searched", "Fetched", "Read", "Ran", "Read"]);
});

test("a closed turn's digest has edits, open failures and milestones, else the reply", () => {
  const table = verbTable({ "git commit": "Committed", "git push": "Pushed", "npm test": "Tested" });
  const digest = (entries, reply = "") => {
    const turn = { entries, reply };
    return turnDigest(turn, steps(entries, table), fixedFailures(entries, table));
  };
  const edits = [{ kind: "edit", files: [["src/a.js", 3, 1, "modified"], ["b.js", 2, 0, "created"]] },
    { kind: "edit", files: [["src/a.js", 1, 1, "modified"]] }];
  assert.deepEqual(digest([...edits, run("npm test", { result: "failed" }), run("npm test", { result: "ok" }),
    run("make", { result: "failed" }), run("git commit -m x", { result: "ok" }), run("git push", { result: "failed" })]),
  [{ text: "2 files +6 −2", diff: true }, { text: "2 failed", tone: "blocked" }, { text: "committed" }]);
  assert.deepEqual(digest([edits[1]]), [{ text: "a.js +1 −1", diff: true }]);
  assert.deepEqual(digest([{ kind: "edit", files: [["a", null, null, "modified"]] }]), [{ text: "a", diff: true }]);
  assert.deepEqual(digest([run("ls")], "## Answer\n\nIt is **fine**."), [{ text: "Answer" }]);
  assert.deepEqual(digest([]), []);
  // Shown only on closed, finished turns.
  const turn = more => activityRows(activityState(withLabel(snapshot([
    { prompt: "a", startedAt: 1, endedAt: 2, outcome: "done", entries: edits, ...more },
    { prompt: "b", startedAt: 3, endedAt: 4, outcome: "done", entries: [] }]))), { now: 9 })[0];
  assert.equal(turn().digest.length, 1);
  assert.deepEqual(turn().digest, [{ text: "2 files +6 −2", diff: true }]);
  assert.deepEqual(activityRows(activityState(withLabel(snapshot([{ prompt: "a", startedAt: 1, endedAt: 2,
    outcome: "done", entries: edits }]))), { now: 9 })[0].digest, []);
});
