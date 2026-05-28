#!/usr/bin/env node
// backlog-agent-status.mjs — invoked by ~/dev/projects/active/backlog-infra/bin/backlog-agent
// after each `backlog-agent run` tick. Reads the transcript JSONL for the
// session that just finished, normalises token usage, writes
// .claude/backlog-status.json (overwrite, headline state) and appends one
// line to .claude/backlog-history.jsonl (full history), then commits both
// with a `Claude-Effort:` trailer and pushes. Cross-machine status: every
// machine commits its own ticks; `~/dev/projects/active/backlog-infra/bin/backlog-agents`
// aggregates by fetching.
//
// Usage:
//   node scripts/backlog-agent-status.mjs \
//     --item "<title>" \
//     --exit-code <n> \
//     --mode loop|watch|manual \
//     --pre-head <sha>
//
// Defaults: --item "" (idle), --exit-code 0, --mode loop,
// --pre-head = `git rev-parse HEAD` if not supplied.

import { execSync, spawnSync } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CLAUDE_DIR = join(REPO_ROOT, ".claude");
const STATUS_FILE = join(CLAUDE_DIR, "backlog-status.json");
const HOST_STATUS_FILE = join(CLAUDE_DIR, `backlog-status-${hostname()}.json`);
const HISTORY_LOG = join(CLAUDE_DIR, "backlog-history.jsonl");
const PLAN_LIMITS = join(homedir(), ".claude", "plan-limits.json");
const TRANSCRIPTS_ROOT = join(homedir(), ".claude", "projects");

// Backlog file location, polyglot during migration.
function findBacklogFile() {
  const docs = join(REPO_ROOT, "docs", "Backlog.md");
  if (existsSync(docs)) return docs;
  const root = join(REPO_ROOT, "Backlog.md");
  if (existsSync(root)) return root;
  const legacy = join(REPO_ROOT, "backlog.txt");
  if (existsSync(legacy)) return legacy;
  return null;
}

// ---------- arg parsing ----------
function parseArgs() {
  const argv = process.argv.slice(2);
  const opts = { item: "", exitCode: 0, mode: "loop", preHead: null, pulled: 0 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--item") opts.item = argv[++i] ?? "";
    else if (a === "--exit-code")
      opts.exitCode = Number.parseInt(argv[++i] ?? "0", 10);
    else if (a === "--mode") opts.mode = argv[++i] ?? "loop";
    else if (a === "--pre-head") opts.preHead = argv[++i] ?? null;
    else if (a === "--pulled")
      opts.pulled = Number.parseInt(argv[++i] ?? "0", 10);
  }
  if (!opts.preHead) {
    try {
      opts.preHead = execSync("git rev-parse HEAD", {
        cwd: REPO_ROOT,
        encoding: "utf8",
      }).trim();
    } catch {
      opts.preHead = null;
    }
  }
  return opts;
}

// ---------- shell helpers ----------
function git(args, { allowFail = false } = {}) {
  const r = spawnSync("git", args, { cwd: REPO_ROOT, encoding: "utf8" });
  if (r.status !== 0 && !allowFail) {
    const cmd = ["git", ...args].join(" ");
    throw new Error(`${cmd} exited ${r.status}: ${r.stderr || r.stdout}`);
  }
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

// ---------- transcript discovery + usage extraction ----------
function findNewestTranscript() {
  const encoded = REPO_ROOT.replaceAll("/", "-");
  const dir = join(TRANSCRIPTS_ROOT, encoded);
  if (!existsSync(dir)) return null;
  let newest = null;
  let newestMtime = 0;
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".jsonl")) continue;
    const full = join(dir, name);
    let m;
    try {
      m = statSync(full).mtimeMs;
    } catch {
      continue;
    }
    if (m > newestMtime) {
      newestMtime = m;
      newest = full;
    }
  }
  return newest;
}

function zeroUsage() {
  return {
    input: 0,
    output: 0,
    cache_creation: 0,
    cache_read: 0,
    num_turns: 0,
    session_id: null,
    duration_ms: 0,
  };
}

function extractUsage(path) {
  if (!path || !existsSync(path)) return zeroUsage();
  const text = readFileSync(path, "utf8");
  const lines = text.split("\n");
  let lastResult = null;
  let firstTs = null;
  let lastTs = null;
  let sessionId = null;
  let turns = 0;
  const seenMsgIds = new Set();
  const summed = { input: 0, output: 0, cache_creation: 0, cache_read: 0 };

  for (const line of lines) {
    if (!line) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (!sessionId && obj.sessionId) sessionId = obj.sessionId;
    if (obj.timestamp) {
      const t = Date.parse(obj.timestamp);
      if (!Number.isNaN(t)) {
        if (firstTs === null || t < firstTs) firstTs = t;
        if (lastTs === null || t > lastTs) lastTs = t;
      }
    }
    if (obj.type === "result" && (obj.usage || obj.num_turns != null)) {
      lastResult = obj;
    } else if (obj.type === "assistant" && obj.message?.usage) {
      const id = obj.message.id;
      if (id) {
        if (seenMsgIds.has(id)) continue;
        seenMsgIds.add(id);
      }
      const u = obj.message.usage;
      summed.input += u.input_tokens ?? 0;
      summed.output += u.output_tokens ?? 0;
      summed.cache_creation += u.cache_creation_input_tokens ?? 0;
      summed.cache_read += u.cache_read_input_tokens ?? 0;
      if (obj.message.stop_reason) turns++;
    }
  }

  if (!sessionId) {
    const base = path.split("/").pop().replace(/\.jsonl$/, "");
    sessionId = base || null;
  }
  const computedDuration =
    firstTs !== null && lastTs !== null ? lastTs - firstTs : 0;

  if (lastResult?.usage) {
    const u = lastResult.usage;
    return {
      input: u.input_tokens ?? 0,
      output: u.output_tokens ?? 0,
      cache_creation: u.cache_creation_input_tokens ?? 0,
      cache_read: u.cache_read_input_tokens ?? 0,
      num_turns: lastResult.num_turns ?? turns,
      session_id: sessionId,
      duration_ms: lastResult.duration_ms ?? computedDuration,
    };
  }
  return {
    ...summed,
    num_turns: turns,
    session_id: sessionId,
    duration_ms: computedDuration,
  };
}

// ---------- backlog markers ----------
function countBacklogMarkers() {
  const f = findBacklogFile();
  const counts = { thinking: 0, open: 0, in_progress: 0, blocked: 0, done: 0 };
  if (!f) return counts;
  let section = null;
  for (const line of readFileSync(f, "utf8").split("\n")) {
    if (/^## Thinking/i.test(line))   { section = "thinking"; continue; }
    if (/^## Open/i.test(line))       { section = "open"; continue; }
    if (/^## In progress/i.test(line)) { section = "in_progress"; continue; }
    if (/^## Blocked/i.test(line))    { section = "blocked"; continue; }
    if (/^## Done/i.test(line))       { section = "done"; continue; }
    if (/^## /i.test(line))           { section = null; continue; }
    if (!section) continue;
    if (/^(- )?\[ \] /.test(line)) {
      if (section === "thinking") counts.thinking++;
      else if (section === "open") counts.open++;
    } else if (/^(- )?\[~\] /.test(line)) { counts.in_progress++; }
    else if (/^(- )?\[\?\] /.test(line))  { counts.blocked++; }
    else if (/^(- )?\[x\] /.test(line))   { counts.done++; }
  }
  return counts;
}

// ---------- plan limits ----------
function loadPlanLimits() {
  if (!existsSync(PLAN_LIMITS)) return null;
  try {
    return JSON.parse(readFileSync(PLAN_LIMITS, "utf8"));
  } catch {
    return null;
  }
}

// ---------- formatters ----------
function formatDuration(ms) {
  const safe = Math.max(0, Math.round((ms ?? 0) / 1000));
  if (safe < 60) return `${safe}s`;
  const m = Math.floor(safe / 60);
  const rs = safe % 60;
  if (m < 60) return rs === 0 ? `${m}m` : `${m}m${rs}s`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return rm === 0 ? `${h}h` : `${h}h${rm}m`;
}

function formatTokens(n) {
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

// ---------- main ----------
async function main() {
  const opts = parseArgs();
  const ts = new Date().toISOString();
  const host = hostname();

  const transcript = findNewestTranscript();
  const usage = extractUsage(transcript);
  const headline = usage.input + usage.output + usage.cache_creation;
  const backlog = countBacklogMarkers();
  const limits = loadPlanLimits();

  // Current HEAD and branch
  let currentHead = null;
  try {
    currentHead = execSync("git rev-parse HEAD", {
      cwd: REPO_ROOT,
      encoding: "utf8",
    }).trim();
  } catch {}
  let branch = "main";
  try {
    branch = execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: REPO_ROOT,
      encoding: "utf8",
    }).trim() || "main";
  } catch {}

  const workCommit =
    currentHead && opts.preHead && currentHead !== opts.preHead
      ? currentHead.slice(0, 7)
      : null;

  // Pull --rebase BEFORE writing local artefacts so a clean working tree
  // lets rebase proceed without --autostash heroics. If origin/<branch>
  // doesn't exist (no upstream), skip.
  const upstreamExists =
    spawnSync(
      "git",
      ["show-ref", "--verify", "--quiet", `refs/remotes/origin/${branch}`],
      { cwd: REPO_ROOT },
    ).status === 0;
  if (upstreamExists) {
    const r = git(["pull", "--rebase", "origin", branch], { allowFail: true });
    if (r.status !== 0) {
      console.error(
        `[backlog-agent-status] git pull --rebase failed (continuing):\n${r.stderr}`,
      );
      git(["rebase", "--abort"], { allowFail: true });
    }
  }

  // Compute rolling-7d token total from the history JSONL so the web
  // dashboard and CLI can read it without parsing the full history file.
  let rolling7d = 0;
  if (existsSync(HISTORY_LOG)) {
    const cutoff = Date.now() - 7 * 86400 * 1000;
    const histText = readFileSync(HISTORY_LOG, "utf8");
    for (const line of histText.split("\n")) {
      if (!line) continue;
      try {
        const rec = JSON.parse(line);
        if (rec.ts && new Date(rec.ts).getTime() >= cutoff) {
          rolling7d += rec.tokens ?? 0;
        }
      } catch {}
    }
  }

  // Write artefacts
  mkdirSync(dirname(STATUS_FILE), { recursive: true });

  // On idle ticks (no tokens spent), preserve previous host/item/tokens so the
  // fleet dashboard and machines tab reflect the last machine that did real work.
  let statusHost = host;
  let statusItem = opts.item;
  let statusTokens = headline;
  let statusWorkCommit = workCommit;
  if (headline === 0 && existsSync(STATUS_FILE)) {
    try {
      const prev = JSON.parse(readFileSync(STATUS_FILE, "utf8"));
      statusHost = prev.last_host || host;
      statusItem = prev.last_item || opts.item;
      statusTokens = prev.last_tokens ?? headline;
      statusWorkCommit = prev.last_work_commit || workCommit;
    } catch {}
  }

  const statusObj = {
    last_tick_at: ts,
    last_host: statusHost,
    last_mode: opts.mode,
    last_item: statusItem,
    last_exit_code: opts.exitCode,
    last_tokens: statusTokens,
    last_work_commit: statusWorkCommit,
    last_pull_count: opts.pulled,
    rolling_7d_tokens: rolling7d + headline,
    backlog,
  };
  writeFileSync(STATUS_FILE, `${JSON.stringify(statusObj, null, 2)}\n`);
  // Per-host file always records the local machine's hostname — never
  // inherit the shared file's preserved last_host (that's for the fleet
  // "LAST BY" column, not for per-machine attribution).
  writeFileSync(
    HOST_STATUS_FILE,
    `${JSON.stringify({ ...statusObj, last_host: host }, null, 2)}\n`,
  );

  const effort = {
    ts,
    host,
    mode: opts.mode,
    item: opts.item,
    exit_code: opts.exitCode,
    duration_ms: usage.duration_ms,
    tokens: headline,
    tokens_breakdown: {
      input: usage.input,
      output: usage.output,
      cache_creation: usage.cache_creation,
      cache_read: usage.cache_read,
    },
    num_turns: usage.num_turns,
    session_id: usage.session_id,
    work_commit: workCommit,
    pulled: opts.pulled,
  };
  appendFileSync(HISTORY_LOG, `${JSON.stringify(effort)}\n`);

  // Gracefully no-op the commit/push when `.claude/` (or these specific
  // files) is wholesale-gitignored — the local fleet view (`backlog-agents`
  // reads .claude/*.json directly) still works, and the user can opt
  // into cross-machine visibility later by tuning .gitignore to match
  // the convention used by other projects (ignore logs+locks, track
  // status+history).
  const ignored = spawnSync("git", ["check-ignore", STATUS_FILE, HOST_STATUS_FILE, HISTORY_LOG], {
    cwd: REPO_ROOT,
  });
  if (ignored.status === 0) {
    console.log(
      "[backlog-agent-status] status files are gitignored; wrote locally, skipping commit/push",
    );
    return;
  }

  // Stage explicit paths (per CLAUDE.md — never `git add -A`)
  git(["add", STATUS_FILE, HOST_STATUS_FILE, HISTORY_LOG]);

  // Skip commit if nothing was staged (defensive — appended JSONL line
  // means the diff is always non-empty in practice).
  const diffCached = spawnSync("git", ["diff", "--cached", "--quiet"], {
    cwd: REPO_ROOT,
  });
  if (diffCached.status === 0) {
    console.log("[backlog-agent-status] no staged changes; skipping commit");
    return;
  }

  // Build commit message
  const subject = opts.item ? `backlog-agent-status: "${opts.item}"` : "backlog-agent-status: idle";
  const durStr = formatDuration(usage.duration_ms);
  const tokStr = formatTokens(headline);
  let tokSegment = `${tokStr} tok`;
  const cap = limits?.limits?.session_5h_tokens;
  if (cap && cap > 0) {
    const pct = (headline / cap) * 100;
    tokSegment += ` (${pct.toFixed(1)}% of 5h)`;
  }
  const trailer = `Claude-Effort: ${durStr}, ${tokSegment}, ${usage.num_turns} turns, exit=${opts.exitCode}`;

  const commit = spawnSync("git", ["commit", "-m", subject, "-m", trailer], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  if (commit.status !== 0) {
    console.error(`[backlog-agent-status] git commit failed:\n${commit.stderr}`);
    process.exit(1);
  }

  // Push with exponential backoff. Skip entirely if no upstream.
  if (!upstreamExists) {
    console.log(`[backlog-agent-status] no origin/${branch}; commit is local only`);
    return;
  }
  const delays = [0, 2000, 4000, 8000, 16000];
  for (let i = 0; i < delays.length; i++) {
    if (delays[i] > 0) await sleep(delays[i]);
    const r = spawnSync("git", ["push", "origin", branch], {
      cwd: REPO_ROOT,
      encoding: "utf8",
    });
    if (r.status === 0) {
      console.log("[backlog-agent-status] ok");
      return;
    }
    console.error(
      `[backlog-agent-status] push attempt ${i + 1} failed (delay=${delays[i]}ms):\n${r.stderr}`,
    );
  }
  console.error("[backlog-agent-status] push failed after retries; commit is local");
  process.exit(2);
}

main().catch((err) => {
  console.error(`[backlog-agent-status] fatal: ${err.message}`);
  process.exit(1);
});
