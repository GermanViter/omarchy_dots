// WCAG 2.0 AA: text needs 4.5:1 against what it sits on. Theme colors like `dim` often fall short,
// so each text color is moved toward the theme's foreground until it passes on every background.
const rgb = (c) => {
  const m = /^#([0-9a-f]{6})/i.exec(c ?? "");
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const luminance = (c) => {
  const f = (v) => ((v /= 255) <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
};
const contrast = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};
const hex = (c) => `#${c.map((v) => Math.round(v).toString(16).padStart(2, "0")).join("")}`;
export function readable(color, toward, backgrounds, min = 4.5) {
  const from = rgb(color);
  const to = rgb(toward);
  const bgs = backgrounds.map(rgb);
  if (!from || !to || bgs.some((b) => !b)) return color;
  for (let step = 0; step <= 10; step++) {
    const c = from.map((v, i) => v + ((to[i] - v) * step) / 10);
    if (bgs.every((b) => contrast(c, b) >= min)) return hex(c);
  }
  return toward;
}

export function palette(t) {
  const on = [t.popover, t.selected, t.raised];
  const text = (c) => readable(c, t.foreground, on);
  return {
    bg: t.popover, card: t.raised, sel: t.selected, hover: t.hover, border: t.border, input: t.input, bar: t.accent,
    fg: t.foreground, muted: text(t.muted), dim: text(t.dim), accent: text(t.accent),
    ok: text(t.done), warn: text(t.blocked), busy: text(t.working),
    solid: t.solid, solidFg: readable(t.solid_foreground, t.background, [t.solid]),
  };
}
