#!/usr/bin/env node
// agentq flake ledger (ADR 0003 W2-3). One JSON file per repo under <AGENTQ_HOME>/flakes/<repo>.json.
//
// Source of truth = the pre-push/gate OUTPUT (vitest/turbo text; no reporter changes in the repos).
// Per tree hash we keep which tests failed in which attempt and whether the tree was ever green.
// A test FLIPS when it failed on a tree that is (or later becomes) green, or failed in one attempt and
// not in the next attempt on the SAME tree. A flipped test is QUARANTINED for `days` (default 14):
// it still runs, but a land whose only failures are quarantined tests retries once and then lands.
//
// CLI (all print one JSON object on stdout):
//   record  --ledger F --tree T --log L [--attempt N]   parse failures from L, store them for T
//   pass    --ledger F --tree T                          T went green: tests that failed on T are flips
//   list    --ledger F                                   quarantined tests + recent trees
//   clear   --ledger F --test "<key>"                    lift a quarantine (key or substring)
// Options: --days N (quarantine length, default 14), --now ISO (tests).
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const TEST_FILE = String.raw`[\w@./\\-]+\.(?:test|spec)\.[cm]?[jt]sx?`;
// turbo prefixes every line with "<pkg>:<task>: "; vitest projects add "|name|".
const TURBO_PREFIX = /^([@\w./-]+):([\w:-]+): /;
const FAIL_LINE = new RegExp(String.raw`^\s*(?:FAIL|×|✗|├ù|Ôťľ)\s+(?:\|[^|]+\|\s+)?(` + TEST_FILE + String.raw`)\s+>\s+(.+?)(?:\s+\[[^\]]*\])?(?:\s+\d+(?:\.\d+)?\s?m?s)?\s*$`);
// Failures that are NOT a test: a quarantine can never excuse these.
const NON_TEST = [
  /error TS\d+/,
  /\bFailed:\s+[@\w./-]+#(?!test\b)[\w:-]+/,
  /ERR_PNPM_(?!RECURSIVE_(?:RUN|EXEC)_FIRST_FAIL)\w+/,
  /✖ \d+ problems?/,
  /\b(?:eslint|oxlint|knip)\b.*\berror/i,
  /Build failed|Failed to compile|Module not found/,
];
// Turbo "Failed:" list, used to require that every failed task is a test task.
const TURBO_FAILED = /\bFailed:\s+((?:[@\w./-]+#[\w:-]+[,\s]*)+)/g;

export function parseFailures(text) {
  const failed = new Set();
  let nonTest = false;
  for (let raw of String(text).split(/\r?\n/)) {
    let pkg = '';
    const m = raw.match(TURBO_PREFIX);
    if (m) { pkg = m[1]; raw = raw.slice(m[0].length); }
    if (NON_TEST.some((re) => re.test(raw))) nonTest = true;
    const f = raw.match(FAIL_LINE);
    if (f) {
      const file = f[1].replace(/\\/g, '/');
      const name = f[2].replace(/\s+/g, ' ').trim();
      failed.add(`${pkg ? pkg + '|' : ''}${file} > ${name}`);
    }
  }
  for (const m of String(text).matchAll(TURBO_FAILED)) {
    for (const task of m[1].split(/[,\s]+/).filter(Boolean)) if (!/#test(?::|$)/.test(task)) nonTest = true;
  }
  return { failed: [...failed].sort(), nonTest };
}

export function emptyLedger() { return { version: 1, quarantine: {}, trees: {} }; }
export function load(file) {
  try { const j = JSON.parse(fs.readFileSync(file, 'utf8')); if (j && j.version === 1) return j; } catch { /* missing or bad */ }
  return emptyLedger();
}
export function save(file, led) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(led, null, 1));
  fs.renameSync(tmp, file);
}

function prune(led, nowMs, days) {
  for (const [k, q] of Object.entries(led.quarantine)) if (Date.parse(q.until) <= nowMs) delete led.quarantine[k];
  const keep = Math.max(days, 14) * 864e5;
  for (const [t, v] of Object.entries(led.trees)) if (nowMs - Date.parse(v.ts) > keep) delete led.trees[t];
}
function quarantine(led, test, reason, nowMs, days, tree) {
  const until = new Date(nowMs + days * 864e5).toISOString();
  const prev = led.quarantine[test];
  led.quarantine[test] = { since: prev?.since ?? new Date(nowMs).toISOString(), until, reason, tree, flips: (prev?.flips ?? 0) + 1 };
}
function isQuarantined(led, key, nowMs) {
  const q = led.quarantine[key];
  return !!q && Date.parse(q.until) > nowMs;
}

// Store one failed attempt; returns the classification used by `land`.
export function record(led, { tree, text, attempt = 1, nowMs = Date.now(), days = 14 }) {
  prune(led, nowMs, days);
  const { failed, nonTest } = parseFailures(text);
  const ts = new Date(nowMs).toISOString();
  const t = led.trees[tree] ?? (led.trees[tree] = { ts, green: false, attempts: [] });
  t.ts = ts;
  const flipped = [];
  // Same tree, previous attempt failed tests that this attempt did not (and this attempt reached tests).
  const prev = t.attempts[t.attempts.length - 1];
  if (prev && failed.length && !nonTest) {
    for (const k of prev.failed) if (!failed.includes(k)) { quarantine(led, k, 'passed on retry of the same tree', nowMs, days, tree); flipped.push(k); }
  }
  // Failing on a tree that has been green before = a flip by definition.
  if (t.green) for (const k of failed) { quarantine(led, k, 'failed on a tree that passed before', nowMs, days, tree); flipped.push(k); }
  t.attempts.push({ attempt, ts, failed, nonTest });
  if (t.attempts.length > 6) t.attempts.splice(0, t.attempts.length - 6);
  const quarantined = failed.filter((k) => isQuarantined(led, k, nowMs));
  return {
    tree, failed, nonTest, quarantined, flipped: [...new Set(flipped)],
    allQuarantined: failed.length > 0 && !nonTest && quarantined.length === failed.length,
  };
}

// The tree passed: every test that failed on it in an earlier attempt flipped.
export function pass(led, { tree, nowMs = Date.now(), days = 14 }) {
  prune(led, nowMs, days);
  const t = led.trees[tree] ?? (led.trees[tree] = { ts: new Date(nowMs).toISOString(), green: false, attempts: [] });
  const flipped = new Set();
  for (const a of t.attempts) if (!a.nonTest) for (const k of a.failed) flipped.add(k);
  for (const k of flipped) quarantine(led, k, 'failed then passed on the same tree', nowMs, days, tree);
  t.green = true; t.ts = new Date(nowMs).toISOString();
  return { tree, flipped: [...flipped].sort() };
}

export function list(led, nowMs = Date.now()) {
  const q = Object.entries(led.quarantine).filter(([, v]) => Date.parse(v.until) > nowMs).map(([test, v]) => ({ test, ...v }))
    .sort((a, b) => b.flips - a.flips || a.test.localeCompare(b.test));
  const trees = Object.entries(led.trees).sort((a, b) => Date.parse(b[1].ts) - Date.parse(a[1].ts)).slice(0, 20)
    .map(([tree, v]) => ({ tree, green: v.green, ts: v.ts, attempts: v.attempts.length, lastFailed: v.attempts.at(-1)?.failed.length ?? 0 }));
  return { quarantined: q, trees };
}

export function clear(led, test) {
  const keys = Object.keys(led.quarantine).filter((k) => k === test || k.includes(test));
  for (const k of keys) delete led.quarantine[k];
  return { cleared: keys };
}

function args(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { const k = a.slice(2); const v = argv[i + 1]; if (v === undefined || v.startsWith('--')) o[k] = true; else { o[k] = v; i++; } } else o._.push(a);
  }
  return o;
}

async function main() {
  const a = args(process.argv.slice(2));
  const cmd = a._[0];
  if (!a.ledger) throw new Error('--ledger <file> is required');
  const nowMs = a.now ? Date.parse(a.now) : Date.now();
  const days = a.days ? Number(a.days) : 14;
  const led = load(a.ledger);
  let out;
  switch (cmd) {
    case 'record': {
      if (!a.tree || !a.log) throw new Error('record --tree T --log L');
      const text = fs.readFileSync(a.log, 'utf8');
      out = record(led, { tree: a.tree, text, attempt: Number(a.attempt ?? 1), nowMs, days });
      save(a.ledger, led); break;
    }
    case 'pass': if (!a.tree) throw new Error('pass --tree T'); out = pass(led, { tree: a.tree, nowMs, days }); save(a.ledger, led); break;
    case 'list': out = list(led, nowMs); break;
    case 'clear': if (!a.test) throw new Error('clear --test KEY'); out = clear(led, String(a.test)); save(a.ledger, led); break;
    default: throw new Error('usage: agentq-flakes.mjs record|pass|list|clear --ledger F ...');
  }
  process.stdout.write(JSON.stringify(out) + '\n');
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((e) => { process.stderr.write(`agentq-flakes: ${e.message}\n`); process.exit(2); });
}
