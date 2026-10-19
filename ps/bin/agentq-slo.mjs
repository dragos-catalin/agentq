#!/usr/bin/env node
// agentq SLO report (ADR 0003 W4-4). Dependency-free; streams the journal line by line.
//
//   node agentq-slo.mjs [--days 7] [--json] [--journal <path>] [--now <ISO>]
//
// Targets: ready-to-landed p90 < 45 min, flake-caused land failures < 2 %, zero lost-work incidents.
//
// Approximations (the journal does not carry every link, so these are best effort):
//  * Queue waits: acquired/start/done/fail all repeat the same waitSec for one grant. A grant is
//    deduplicated on (session, resource-list, waitSec) within 24 h; a comma resource list
//    ("build:codai,build:machine") credits the wait to every resource in it.
//  * Ready-to-landed: "ready" = the session's first 'queued land:<repo>' (or 'queued commit:<repo>'
//    for publish) not yet consumed by an earlier land of that session. The land event carries no
//    ticket, so pairing is by session+repo, FIFO. Work time before the agent asks to land is invisible.
//  * Bypass: a 'push' event to an integration branch (main/master/dev) is an agentq commit pushed
//    straight from a clone (shared clone or slot), not via land/publish. Pushes by plain `git push`
//    (temp-index plumbing under `agentq run -Resource commit`) are NOT journaled as 'push', so the
//    real bypass share is HIGHER than reported. share = directPush / (directPush + land + publish).
//  * Flake rate: 'flake' events (agentq retried a pre-push infra failure) / land attempts
//    (land + land failures). Share of push failures = flake / (flake + land-push-failed).
//  * Lost work: an incident is a slot loss where the work was NOT safely preserved:
//    lease-expire-failed (backup could not be proven, lease kept) and backup with pushError (only a
//    local bundle). Expiry/unlease/break ALWAYS back up first and fail closed, so a missing ref means
//    the slot was clean: counted as cleanExpire / benignBreak. With a ref = "recovered" (restore needed).
//    publish-refused = prevented incidents (reported separately).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

export const TARGETS = { readyToLandedP90Min: 45, flakeRatePct: 2, lostWork: 0 };
const INTEGRATION = new Set(['main', 'master', 'dev']);
const LAND_FAIL = {
  'land-conflict': 'conflict',
  'land-push-failed': 'pushRefused',
  'land-gate-failed': 'gate',
  'land-oversized': 'oversized',
  'land-finalize-failed': 'finalize',
};
// A land-push-failed whose reason carries the hook's output = the repo pre-push gate failed (lint, tests,
// platform gates); only the rest is the remote refusing the push.
export const PRE_PUSH_RE = /pre-push|husky|FAIL |Tests? +\d+ failed|ELIFECYCLE|error TS\d|lint error/i;
const BENIGN_BREAK = /clean|landed|merged|done|finished|pushed/i;

export function parseArgs(argv) {
  const a = { days: 7, json: false, journal: path.join(os.homedir(), '.codai', 'coord', 'journal.jsonl'), now: null };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--days') a.days = Number(argv[++i]);
    else if (k === '--json') a.json = true;
    else if (k === '--journal') a.journal = argv[++i];
    else if (k === '--now') a.now = argv[++i];
    else if (k === '-h' || k === '--help') a.help = true;
    else throw new Error(`unknown argument ${k}`);
  }
  if (!(a.days > 0)) throw new Error('--days must be > 0');
  return a;
}

export function pct(values, p) {
  if (!values.length) return null;
  const s = [...values].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}

const repoOf = (o) => o.repo || String(o.resource ?? '').split(',')[0].split(':')[1] || '?';

function newRepo() {
  return {
    lands: 0, landFail: { conflict: 0, prePush: 0, pushRefused: 0, gate: 0, oversized: 0, finalize: 0 }, publish: 0, publishRefused: 0,
    waits: { build: [], commit: [], land: [] },
    commitAcquired: 0, commits: 0, commitFailed: 0, pushFailed: 0, pushDeferred: 0,
    directPush: 0, branchPush: 0, flake: 0, quarantinedLands: 0,
    lost: { incidents: 0, cleanExpire: 0, recoveredExpire: 0, recoveredBreak: 0, foreignBreakBenign: 0, prevented: 0, details: [] },
    readyToLandedMin: [], unpairedLands: 0,
  };
}

export async function compute(lines, { days = 7, now = null } = {}) {
  const repos = new Map();
  const R = (name) => { if (!repos.has(name)) repos.set(name, newRepo()); return repos.get(name); };
  const stats = { lines: 0, bad: 0, inWindow: 0, firstTs: null, lastTs: null };
  const all = [];
  for await (const line of lines) {
    stats.lines++;
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { stats.bad++; continue; }
    const t = Date.parse(o?.ts);
    if (!o || typeof o.event !== 'string' || Number.isNaN(t)) { stats.bad++; continue; }
    all.push([t, o]);
  }
  const end = now ? Date.parse(now) : Math.max(Date.now(), ...all.map((x) => x[0]).slice(-1));
  const start = end - days * 864e5;
  all.sort((a, b) => a[0] - b[0]);

  const seenWait = new Map(); // dedupe key -> ts
  const readyQueue = new Map(); // `${session}|${repo}|land|commit` -> [ts...]
  for (const [t, o] of all) {
    if (t < start || t > end) continue;
    stats.inWindow++;
    if (stats.firstTs === null) stats.firstTs = t;
    stats.lastTs = t;
    const ev = o.event;
    const repo = repoOf(o);
    const res = String(o.resource ?? '');

    // queue waits
    if ((ev === 'acquired' || ev === 'start' || ev === 'done' || ev === 'fail') && typeof o.waitSec === 'number' && res) {
      const key = `${o.session}|${res}|${o.waitSec}`;
      const prev = seenWait.get(key);
      if (prev === undefined || t - prev > 864e5) {
        seenWait.set(key, t);
        for (const r of res.split(',')) {
          const [kind, rname] = r.trim().split(':');
          if (rname && rname !== 'machine' && R(rname).waits[kind]) R(rname).waits[kind].push(o.waitSec);
        }
      }
    }
    if (ev === 'acquired' && res.split(',').some((r) => r.startsWith('commit:'))) R(repo).commitAcquired++;
    if (ev === 'queued') {
      const kind = res.split(':')[0];
      if (kind === 'land' || kind === 'commit') {
        const k = `${o.session}|${repo}|${kind}`;
        if (!readyQueue.has(k)) readyQueue.set(k, []);
        readyQueue.get(k).push(t);
      }
    }
    const r = R(repo);
    switch (ev) {
      case 'land':
      case 'publish': {
        if (ev === 'land') r.lands++; else r.publish++;
        const q = readyQueue.get(`${o.session}|${repo}|${ev === 'land' ? 'land' : 'commit'}`);
        if (q && q.length) { r.readyToLandedMin.push((t - q[0]) / 6e4); q.length = 0; } else r.unpairedLands++;
        break;
      }
      case 'land-push-failed':
        if (PRE_PUSH_RE.test(String(o.reason ?? ''))) r.landFail.prePush++; else r.landFail.pushRefused++;
        break;
      case 'land-conflict': case 'land-gate-failed': case 'land-oversized': case 'land-finalize-failed':
        r.landFail[LAND_FAIL[ev]]++; break;
      case 'publish-refused': r.publishRefused++; r.lost.prevented++; break;
      case 'commit': r.commits++; break;
      case 'commit-failed': r.commitFailed++; break;
      case 'push-failed': r.pushFailed++; break;
      case 'push-deferred': r.pushDeferred++; break;
      case 'push': if (INTEGRATION.has(String(o.branch))) r.directPush++; else r.branchPush++; break;
      case 'flake': r.flake++; break;
      case 'flake-quarantined': r.quarantinedLands++; break;
      case 'lease-expire':
        // Backup-Slot runs first and fails closed (lease-expire-failed); ref '' = nothing unique (clean).
        if (o.ref) r.lost.recoveredExpire++; else r.lost.cleanExpire++;
        break;
      case 'lease-expire-failed':
        r.lost.incidents++; r.lost.details.push(`${o.ts} lease-expire-failed ${res}`); break;
      case 'backup':
        if (o.pushError) { r.lost.incidents++; r.lost.details.push(`${o.ts} backup push failed ${res}`); }
        break;
      case 'lease-break':
        if (o.holderSession && o.holderSession !== o.session) {
          // unlease -Reason also backs up first and refuses on a failed backup: no ref = clean slot.
          if (o.ref) r.lost.recoveredBreak++;
          else r.lost.foreignBreakBenign++;
        }
        break;
      default: break;
    }
  }
  return summarize(repos, stats, { start, end, days });
}

function summarizeRepo(r) {
  const failures = Object.values(r.landFail).reduce((a, b) => a + b, 0);
  const attempts = r.lands + failures;
  const q = (arr) => ({ n: arr.length, p50: pct(arr, 50), p90: pct(arr, 90) });
  const integ = r.directPush + r.lands + r.publish;
  return {
    landing: { lands: r.lands, failures, failByCause: r.landFail, failureRate: attempts ? failures / attempts : null, publish: r.publish, publishRefused: r.publishRefused },
    queueWaitSec: { build: q(r.waits.build), commit: q(r.waits.commit), land: q(r.waits.land) },
    commitPath: { acquired: r.commitAcquired, commits: r.commits, commitFailed: r.commitFailed, pushFailed: r.pushFailed, pushDeferred: r.pushDeferred },
    bypass: { directPushIntegration: r.directPush, pushTopicBranch: r.branchPush, share: integ ? r.directPush / integ : null },
    flake: { flakes: r.flake, quarantinedLands: r.quarantinedLands, shareOfPushFailures: r.flake + r.landFail.prePush + r.landFail.pushRefused ? r.flake / (r.flake + r.landFail.prePush + r.landFail.pushRefused) : null, rate: attempts ? r.flake / attempts : null },
    lostWork: { incidents: r.lost.incidents, recoveredExpire: r.lost.recoveredExpire, recoveredBreak: r.lost.recoveredBreak, foreignBreakBenign: r.lost.foreignBreakBenign, prevented: r.lost.prevented, details: r.lost.details.slice(0, 20) },
    readyToLandedMin: { n: r.readyToLandedMin.length, p50: pct(r.readyToLandedMin, 50), p90: pct(r.readyToLandedMin, 90), unpaired: r.unpairedLands },
    _raw: r,
  };
}

function summarize(repos, stats, win) {
  const tot = newRepo();
  for (const r of repos.values()) {
    tot.lands += r.lands; tot.publish += r.publish; tot.publishRefused += r.publishRefused;
    for (const k of Object.keys(tot.landFail)) tot.landFail[k] += r.landFail[k];
    for (const k of Object.keys(tot.waits)) tot.waits[k].push(...r.waits[k]);
    for (const k of ['commitAcquired', 'commits', 'commitFailed', 'pushFailed', 'pushDeferred', 'directPush', 'branchPush', 'flake', 'quarantinedLands', 'unpairedLands']) tot[k] += r[k];
    for (const k of ['incidents', 'recoveredExpire', 'recoveredBreak', 'foreignBreakBenign', 'prevented']) tot.lost[k] += r.lost[k];
    tot.lost.details.push(...r.lost.details);
    tot.readyToLandedMin.push(...r.readyToLandedMin);
  }
  const byRepo = {};
  for (const [name, r] of [...repos].sort()) {
    const s = summarizeRepo(r);
    const active = s.landing.lands + s.landing.failures + s.landing.publish + s.commitPath.commits + s.commitPath.acquired + s.queueWaitSec.build.n + s.lostWork.incidents + s.lostWork.recoveredExpire + s.lostWork.recoveredBreak;
    if (active) { delete s._raw; byRepo[name] = s; }
  }
  const overall = summarizeRepo(tot); delete overall._raw;
  const v = (ok, value, target) => ({ verdict: value === null ? 'NO DATA' : ok ? 'PASS' : 'FAIL', value, target });
  const rtl = overall.readyToLandedMin.p90;
  const fr = overall.flake.rate === null ? null : overall.flake.rate * 100;
  const slo = {
    readyToLandedP90Min: v(rtl !== null && rtl < TARGETS.readyToLandedP90Min, rtl, `< ${TARGETS.readyToLandedP90Min}`),
    flakeRatePct: v(fr !== null && fr < TARGETS.flakeRatePct, fr, `< ${TARGETS.flakeRatePct}`),
    lostWorkIncidents: v(overall.lostWork.incidents === TARGETS.lostWork, overall.lostWork.incidents, `= ${TARGETS.lostWork}`),
  };
  return {
    generatedAt: new Date().toISOString(),
    window: { days: win.days, from: new Date(win.start).toISOString(), to: new Date(win.end).toISOString() },
    journal: { lines: stats.lines, badLines: stats.bad, eventsInWindow: stats.inWindow },
    slo, overall, byRepo,
  };
}

// ---------- human output ----------
const f1 = (x) => (x === null || x === undefined ? '-' : Number.isInteger(x) ? String(x) : x.toFixed(1));
const fp = (x) => (x === null || x === undefined ? '-' : `${(x * 100).toFixed(1)}%`);
const fm = (s) => (s === null || s === undefined ? '-' : s < 60 ? `${s.toFixed(0)}s` : `${(s / 60).toFixed(1)}m`);
function table(head, rows) {
  const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
  const line = (r) => r.map((c, i) => (i === 0 ? String(c).padEnd(w[i]) : String(c).padStart(w[i]))).join('  ');
  return [line(head), w.map((n) => '-'.repeat(n)).join('  '), ...rows.map(line)].join('\n');
}
export function render(rep) {
  const rows = (fn) => [...Object.entries(rep.byRepo).map(([n, s]) => fn(n, s)), fn('ALL', rep.overall)];
  const out = [];
  out.push(`agentq SLO — ${rep.window.days} d window ${rep.window.from.slice(0, 16)}Z .. ${rep.window.to.slice(0, 16)}Z`);
  out.push(`journal: ${rep.journal.lines} lines, ${rep.journal.badLines} bad, ${rep.journal.eventsInWindow} in window\n`);
  out.push('SLO');
  out.push(table(['target', 'value', 'goal', 'verdict'], Object.entries(rep.slo).map(([k, s]) => [k, f1(s.value), s.target, s.verdict])));
  out.push('\nLANDING');
  out.push(table(['repo', 'lands', 'fail', 'conflict', 'prePush', 'pushRef', 'gate', 'oversz', 'final', 'failRate', 'publish', 'pubRef'],
    rows((n, s) => [n, s.landing.lands, s.landing.failures, s.landing.failByCause.conflict, s.landing.failByCause.prePush, s.landing.failByCause.pushRefused, s.landing.failByCause.gate, s.landing.failByCause.oversized, s.landing.failByCause.finalize, fp(s.landing.failureRate), s.landing.publish, s.landing.publishRefused])));
  out.push('\nQUEUE WAIT (p50 / p90, n)');
  out.push(table(['repo', 'build', 'commit', 'land'],
    rows((n, s) => [n, ...['build', 'commit', 'land'].map((k) => { const q = s.queueWaitSec[k]; return q.n ? `${fm(q.p50)}/${fm(q.p90)} n${q.n}` : '-'; })])));
  out.push('\nCOMMIT PATH / BYPASS / FLAKE / READY->LANDED');
  out.push(table(['repo', 'acq', 'commit', 'cFail', 'pFail', 'pDefer', 'direct', 'topic', 'bypass', 'flake', 'flkRate', 'r2l p50', 'r2l p90', 'r2l n'],
    rows((n, s) => [n, s.commitPath.acquired, s.commitPath.commits, s.commitPath.commitFailed, s.commitPath.pushFailed, s.commitPath.pushDeferred, s.bypass.directPushIntegration, s.bypass.pushTopicBranch, fp(s.bypass.share), s.flake.flakes, fp(s.flake.rate), f1(s.readyToLandedMin.p50), f1(s.readyToLandedMin.p90), s.readyToLandedMin.n])));
  out.push('\nLOST WORK');
  out.push(table(['repo', 'incidents', 'recovExpire', 'recovBreak', 'benignBreak', 'prevented'],
    rows((n, s) => [n, s.lostWork.incidents, s.lostWork.recoveredExpire, s.lostWork.recoveredBreak, s.lostWork.foreignBreakBenign, s.lostWork.prevented])));
  for (const d of rep.overall.lostWork.details.slice(0, 10)) out.push(`  ! ${d}`);
  return out.join('\n');
}

export async function* fileLines(p) {
  const rl = readline.createInterface({ input: fs.createReadStream(p, { encoding: 'utf8' }), crlfDelay: Infinity });
  for await (const l of rl) yield l;
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.help) { console.log('node agentq-slo.mjs [--days 7] [--json] [--journal <path>] [--now <ISO>]'); return; }
  if (!fs.existsSync(a.journal)) { console.error(`journal not found: ${a.journal}`); process.exit(2); }
  const rep = await compute(fileLines(a.journal), { days: a.days, now: a.now });
  console.log(a.json ? JSON.stringify(rep, null, 2) : render(rep));
  process.exitCode = Object.values(rep.slo).some((s) => s.verdict === 'FAIL') ? 1 : 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) main().catch((e) => { console.error(e.message); process.exit(2); });
