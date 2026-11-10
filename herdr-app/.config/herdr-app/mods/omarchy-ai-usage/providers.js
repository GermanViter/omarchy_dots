import { home, readTextFile, settings } from "herdr";
import { H, DAY } from "./time.js";

const json = async path => {
  try { return JSON.parse((await readTextFile(path.startsWith("/") ? path : `${home()}/${path}`)) ?? "null"); } catch { return null; }
};
const isoOf = ms => (ms ? new Date(ms).toISOString() : null);
const spanName = s => (s >= 7 * DAY ? "Weekly limit" : `${Math.round(s / H)}-hour limit`);
const spanShort = s => (s >= DAY ? `${Math.round(s / DAY)}d` : `${Math.round(s / H)}h`);
const win = (span, used, resetsAt, extra) => ({ short: spanShort(span), long: spanName(span), span, used: Math.round(used), resets_at: resetsAt, ...extra });

// Quota endpoints, each on the provider's own host. `creds` never leaves fetch time.
export const PROVIDERS = {
  claude: {
    name: "Claude",
    color: "#D97757",
    async usage(c) {
      const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
        headers: { Authorization: `Bearer ${c.token}`, "anthropic-beta": "oauth-2025-04-20", Accept: "application/json" },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const span = { session: 5 * H, weekly_all: 7 * DAY, weekly_scoped: 7 * DAY };
      if (Array.isArray(data.limits)) {
        return data.limits.filter(l => span[l.kind]).map(l => {
          const model = l.scope?.model?.display_name;
          const w = win(span[l.kind], l.percent, l.resets_at);
          return model ? { ...w, short: `7d ${model}`, long: `Weekly ${model} limit` } : w;
        });
      }
      return [["five_hour", 5 * H], ["seven_day", 7 * DAY]]
        .filter(([k]) => typeof data[k]?.utilization === "number")
        .map(([k, s]) => win(s, data[k].utilization, data[k].resets_at));
    },
  },
  codex: {
    name: "Codex",
    color: "#7A9DFF",
    async usage(c) {
      const res = await fetch("https://chatgpt.com/backend-api/wham/usage", {
        headers: { Authorization: `Bearer ${c.token}`, "ChatGPT-Account-Id": c.account ?? "", Accept: "application/json" },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const rl = (await res.json()).rate_limit ?? {};
      return [rl.primary_window, rl.secondary_window].filter(w => w && typeof w.used_percent === "number")
        .map(w => win(w.limit_window_seconds * 1e3, w.used_percent, isoOf(w.reset_at * 1e3)));
    },
  },
  copilot: {
    name: "Copilot",
    color: "#a371f7",
    async usage(c) {
      const res = await fetch("https://api.github.com/copilot_internal/user", {
        headers: { Authorization: `token ${c.token}`, Accept: "application/json" },
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const label = { premium_interactions: "premium", chat: "chat", completions: "completions" };
      return Object.entries(data.quota_snapshots ?? {}).filter(([k, q]) => label[k] && !q.unlimited)
        .map(([k, q]) => win(30 * DAY, 100 - q.percent_remaining, data.quota_reset_date_utc,
          { short: k === "premium_interactions" ? "mo" : label[k], long: `Monthly ${label[k]} requests`, monthly: true }));
    },
  },
};

// Multi-provider harnesses: which provider they use, and where their logins live.
const HARNESS = {
  pi: { auth: ".pi/agent/auth.json", pick: async () => (await json(".pi/agent/settings.json"))?.defaultProvider },
  opencode: { auth: ".local/share/opencode/auth.json", pick: async () => (await json(".config/opencode/opencode.json"))?.model?.split("/")[0] },
};
const UNDER = { anthropic: "claude", "openai-codex": "codex", openai: "codex", "github-copilot": "copilot" };

// Rebuilt from the plain source record each fetch, so the popup copy can refresh too.
async function creds(src) {
  const f = src.from;
  if (f.claude) {
    const o = (await json(`${f.claude}/.credentials.json`))?.claudeAiOauth;
    if (!o?.accessToken) throw new Error(`no Claude Code login in ${f.claude.replace(home(), "~")}`);
    return { token: o.accessToken, expires: o.expiresAt };
  }
  if (f.codex) {
    const t = (await json(".codex/auth.json"))?.tokens;
    if (!t?.access_token) throw new Error("no Codex ChatGPT login in ~/.codex");
    return { token: t.access_token, account: t.account_id };
  }
  if (f.copilot) {
    const gh = (await json(".config/github-copilot/oauth.json"))?.["https://github.com/login/oauth"]?.[0]?.accessToken;
    const apps = Object.values({ ...(await json(".config/github-copilot/hosts.json")), ...(await json(".config/github-copilot/apps.json")) });
    const token = gh ?? apps.find(a => a?.oauth_token)?.oauth_token;
    if (!token) throw new Error("no GitHub Copilot login in ~/.config/github-copilot");
    return { token };
  }
  const e = (await json(HARNESS[f.harness].auth))?.[f.entry];
  if (e?.type !== "oauth") throw new Error(`no ${f.entry} login in ${f.harness}`);
  return { token: src.provider === "copilot" ? e.refresh : e.access, account: e.accountId, expires: e.expires };
}

const claudeDirs = [".claude", ".claude-personal"];
const claudeLabel = dir => (dir.split("/").pop().replace(/^\.claude-?/, "") || "claude");

const capital = s => s[0].toUpperCase() + s.slice(1);

// settings.json's "claude_labels" ({ "~/.claude": "Work" }) names a profile outright. Otherwise its
// organization ("Flexspring"), or "Personal" for the "<email>'s Organization" a personal account
// gets, else the folder's name. ~/.claude keeps its state in ~/.claude.json, other folders inside.
async function claudeName(dir) {
  const own = settings()?.claude_labels?.[dir.replace(home(), "~")];
  if (typeof own === "string" && own) return own;
  const file = dir === `${home()}/.claude` ? `${home()}/.claude.json` : `${dir}/.claude.json`;
  const text = await readTextFile(file).catch(() => null);
  let org;
  try { org = JSON.parse(text ?? "{}")?.oauthAccount?.organizationName; } catch { /* mid-write or broken: the folder's name */ }
  if (!org) return capital(claudeLabel(dir));
  return /'s Organization$/.test(org) ? "Personal" : org;
}

function labelled(v, why) {
  return { id: `none.${v.program.key}`, agent: v.program.name, label: v.program.name, icon: v.program.icon, tint: v.program.tint, note: why ?? "no usage API" };
}

export async function sourcesFor(v, claudeDirOf) {
  const key = v.program.key, agent = v.program.name;
  const icon = v.program.icon, tint = v.program.tint;
  if (key === "claude" || key === "claude-code") {
    const dir = await claudeDirOf(v.terminal);
    const dirs = dir ? [dir] : claudeDirs.map(d => `${home()}/${d}`);
    return Promise.all(dirs.map(async d => ({ id: `claude.${claudeLabel(d)}`, provider: "claude", agent, label: await claudeName(d), sub: d.replace(home(), "~"), icon, tint, from: { claude: d } })));
  }
  if (key === "codex") return [{ id: "codex", provider: "codex", agent, label: "codex", sub: "ChatGPT plan", icon, tint, from: { codex: true } }];
  if (key === "copilot") return [{ id: "copilot", provider: "copilot", agent, label: "copilot", sub: "GitHub Copilot", icon, tint, from: { copilot: true } }];
  const h = HARNESS[key];
  if (!h) return [labelled(v)];
  const entry = await h.pick();
  const auth = (await json(h.auth))?.[entry];
  const provider = UNDER[entry];
  if (!provider || auth?.type !== "oauth") return [labelled(v, `${entry ?? "its provider"}: no usage API`)];
  // Same ChatGPT account as Codex's own login: share its numbers and its fresher token.
  if (provider === "codex" && auth.accountId && auth.accountId === (await json(".codex/auth.json"))?.tokens?.account_id) {
    return [{ id: "codex", provider, agent, label: key, sub: `via ${entry} (Codex login)`, icon, tint, from: { codex: true } }];
  }
  return [{ id: `${key}.${provider}`, provider, agent, label: key, sub: `via ${entry}`, icon, tint, from: { harness: key, entry } }];
}

export async function fetchUsage(src) {
  const c = await creds(src);
  if (c.expires && c.expires < Date.now()) throw new Error(`token expired, use ${src.agent} to refresh it`);
  return PROVIDERS[src.provider].usage(c);
}
