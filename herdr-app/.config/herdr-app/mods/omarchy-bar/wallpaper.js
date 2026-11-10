import { exec, appHome, layout } from "herdr";

// A theme's wallpapers: backgrounds/omarchy/<theme>/, in name order. None: [].
export async function wallpapers(name) {
  const dir = `backgrounds/omarchy/${name}`;
  const r = await exec("ls", ["-1", `${appHome()}/${dir}`]).catch(() => null);
  if (r?.code !== 0) return [];
  return r.stdout.split("\n").filter((f) => /\.(webp|jpe?g|png)$/i.test(f)).map((f) => `${dir}/${f}`);
}

// Through the CLI: run() refuses an argument nested deeper than 16 levels, and this layout's tree is deeper.
export async function setWallpaper(image) {
  const l = layout();
  if (!l) return;
  await exec("herdr-app", ["do", "layout.set", JSON.stringify({ layout: { ...l, background: { ...l.background, image } } })]);
}

function withNode(node, id, edit) {
  if (node?.id === id) return edit(node);
  if (!node?.children) return node;
  return { ...node, children: node.children.map((c) => withNode(c, id, edit)) };
}

// A zoomed pane gets a thicker frame, so a zoomed tab looks different.
export const ZOOM_BORDER = 4;

export async function setZoomBorder(zoomed) {
  const l = layout();
  if (!l) return;
  const width = zoomed ? ZOOM_BORDER : 2;
  const look = (b) => ({ ...b, width });
  const next = withNode(l, "main", (main) => {
    const pane = main.content.pane;
    return { ...main, content: { ...main.content, pane: { ...pane, border: look(pane.border), focus: look(pane.focus) } } };
  });
  await exec("herdr-app", ["do", "layout.set", JSON.stringify({ layout: next })]);
}
