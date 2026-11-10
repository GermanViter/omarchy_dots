import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { GENERATED, blocksDiffer, panelMod, withBlocks } from "./panel-mods.js";

const tree = (...extra) => ({ id: "root", type: "row", children: [
  { id: "panel-body", type: "row", children: [{ id: "files", type: "block", content: { mod: "files" } }, ...extra] },
] });
const body = t => t.children[0].children.map(node => node.id);
const tracker = panelMod("tracker", '{"title":"Tracker","panel":{"width":900}}');

test("only a mod that asks gets a panel", () => {
  assert.deepEqual(tracker, { name: "tracker", id: `${GENERATED}tracker`, title: "Tracker", width: 900 });
  assert.deepEqual(panelMod("x", '{"panel":true}'), { name: "x", id: `${GENERATED}x`, title: "x", width: null });
  for (const text of ['{"place":"none"}', '{"panel":false}', "{not json", null]) assert.equal(panelMod("x", text), null);
});

test("a missing block is added hidden, after the person's own", () => {
  const t = tree();
  assert.equal(blocksDiffer(t, [tracker]), true);
  withBlocks(t, [tracker]);
  assert.deepEqual(body(t), ["files", tracker.id]);
  assert.deepEqual(t.children[0].children[1],
    { id: tracker.id, type: "block", content: { mod: "tracker" }, size: { weight: 1 }, hidden: true });
  assert.equal(blocksDiffer(t, [tracker]), false);
});

test("a removed mod's block goes, and the person's own blocks and a kept block's fields stay", () => {
  const kept = { id: tracker.id, type: "block", content: { mod: "tracker" }, size: { px: 500 } };
  const gone = { id: `${GENERATED}gone`, type: "block", content: { mod: "gone" } };
  const mine = { id: "my-panel", type: "block", content: { mod: "mine" } };
  const t = tree(kept, mine, gone);
  assert.equal(blocksDiffer(t, [tracker]), true);
  withBlocks(t, [tracker]);
  assert.deepEqual(body(t), ["files", tracker.id, "my-panel"]);
  assert.deepEqual(t.children[0].children[1], kept);
});

test("a layout with no panel-body is left alone", () => {
  assert.equal(blocksDiffer({ id: "root", children: [] }, [tracker]), false);
});

test("the installer ignores the same prefix", () => {
  const script = readFileSync(new URL("../../scripts/install.py", import.meta.url), "utf8");
  assert.ok(script.includes(`GENERATED_PANEL = "${GENERATED}"`));
});
