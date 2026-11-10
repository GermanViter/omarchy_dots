import { test } from "node:test";
import assert from "node:assert/strict";
import { cacheView, contextState, contextView, logView } from "./model.js";

const terminal = value => ({ address: "t1", program: { key: "claude" }, labels: { "bettr.context": JSON.stringify(value) } });
const label = {
  version: 1, provider: "claude", sessionId: "s", used: 63800, exact: true, window: 1000000, reserved: 33000,
  rows: [{ key: "messages", label: "Messages", tokens: 28200, parts: [{ label: "Bash", tokens: 20000 }] },
    { key: "tools", label: "Tools", tokens: 14200 }, { key: "bad", label: "", tokens: 5 }],
};

test("the label becomes rows, reserve and free space; with no window, the total only", () => {
  const state = contextState(terminal(label));
  assert.equal(state.rows.length, 2);
  const view = contextView(state, new Set(["messages"]));
  assert.equal(view.reserved, 33000);
  assert.equal(view.free, 1000000 - 63800 - 33000);
  assert.ok(view.rows[0].expandable && view.rows[0].opened);
  assert.equal(view.rows[1].expandable, false);
  assert.deepEqual(view.segments.map(s => s.key), ["messages", "tools", "reserved"]);
  const unknown = contextView(contextState(terminal({ ...label, window: undefined, used: 1000 })));
  assert.deepEqual([unknown.total, unknown.free, unknown.reserved], ["", 0, 0]);
});

test("a label from another agent or version is not shown", () => {
  const claude = terminal(label);
  assert.ok(contextState(claude));
  // The same label text, now under Codex: hidden although the label was parsed before.
  assert.equal(contextState({ ...claude, program: { key: "codex" } }), null);
  assert.equal(contextState(terminal({ ...label, version: 2 })), null);
  assert.equal(contextState({ labels: {} }), null);
});

test("the cache field becomes a hit rate, totals and misses, newest first", () => {
  const at = 1_800_000_000;
  const value = { ...label, cache: { requests: 60, read: 5514465, written: 201256, rewritten: 139507, uncached: 134,
    since: at - 3600, misses: [{ at, lost: 77507, rewritten: 77507, idle: 8437, ttl: 3600 },
      { at: at + 1, lost: 440000, compaction: true }, { at: at + 2, lost: 31000, rewritten: 31000, models: ["a", "b"] },
      { at: 0, lost: 9 }] } };
  const view = cacheView(contextState(terminal(value)).cache, "claude", at + 60);
  assert.equal(view.hit, "96.4% hit");
  // Write is new content only: written minus rewritten.
  assert.deepEqual(view.totals.map(item => [item.key, item.value]),
    [["read", "5.5M"], ["write", "61.7k"], ["rewrite", "139.5k"], ["uncached", "134"]]);
  // The miss with no time is dropped; a compaction drops its cache rather than rewriting it.
  assert.deepEqual(view.misses.map(m => [m.lost, m.plain]), [["31k", false], ["440k", true], ["77.5k", false]]);
  assert.ok(view.misses[0].facts.includes("model change"));
  assert.ok(view.misses[1].facts.includes("compaction"));
  assert.ok(view.misses[2].facts.includes("idle"));
});

test("a miss shows only its main reason: compaction, else model change, else idle", () => {
  const at = 1_800_000_000;
  const both = { at, lost: 5000, compaction: true, idle: 8437, ttl: 3600 };
  const model = { at, lost: 5000, rewritten: 5000, models: ["a", "b"], idle: 8437, ttl: 3600 };
  const view = cacheView({ requests: 1, read: 0, written: 0, rewritten: 0, uncached: 0, since: 0, misses: [model, both] },
    "claude", at + 60);
  assert.deepEqual(view.misses.map(m => m.facts), ["Drop after compaction", "Rewrite after model change: a → b"]);
});

test("a hit rate never rounds up to 100%, and Codex shows no misses", () => {
  const near = cacheView({ requests: 2, read: 99999, written: 1, rewritten: 0, uncached: 0, since: 0, misses: [] }, "claude");
  assert.equal(near.hit, "99.9% hit");
  const codex = { ...label, provider: "codex", cache: { requests: 3, read: 150, uncached: 250 } };
  const view = cacheView(contextState({ ...terminal(codex), program: { key: "codex" } }).cache, "codex");
  assert.deepEqual(view.totals.map(item => item.value), ["150", "—", "—", "250"]);
  assert.equal(view.misses.length, 0);
  const empty = cacheView(null, "claude");
  assert.deepEqual([empty.hit, empty.misses.length, ...empty.totals.map(item => item.value)], ["", 0, "0", "0", "0", "0"]);
});

test("the compaction log keeps only recorded facts, oldest first", () => {
  const at = 1_800_000_000;
  const state = contextState(terminal({ version: 1, provider: "claude", used: 1, rows: [], log: [
    { at: at - 3600, before: 80000 },
    { at, trigger: "auto", before: 312725, after: 12735, took: 39.9 },
    { at, after: 5 }, // No size before: dropped.
  ] }));
  const rows = logView(state.log, 1000000, at);
  assert.deepEqual(rows.map(row => [row.before, row.after]), [["80k", "—"], ["312.7k", "12.7k"]]);
});
