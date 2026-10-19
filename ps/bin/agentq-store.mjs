#!/usr/bin/env node
// agentq SQLite store, phase 1 (ADR 0006 / ADR 0003 W4-3): a rebuildable index of journal.jsonl (+ rotated
// journal-*.jsonl) and of the job registry (<coord>/jobs/*.json). The JSONL files stay the source of truth.
//   sync     [--home H]                          ingest new journal bytes + changed job files
//   status   [--home H]                          counts, last ts, lag, size (JSON)
//   query    [--home H] [--event E] [--repo R] [--hours N] [--limit N]   journal lines, one per row
//   window   [--home H] --days N [--now ISO]     raw journal lines in the window (for agentq-slo)
//   rebuild  [--home H]                          drop the db and ingest everything again
// Env: AGENTQ_HOME (default ~/.codai/coord).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

export const homeDir = (h) => h || process.env.AGENTQ_HOME || path.join(os.homedir(), '.codai', 'coord');
export const dbPath = (home) => path.join(home, 'agentq.db');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS journal(id INTEGER PRIMARY KEY, ts TEXT NOT NULL, event TEXT NOT NULL, repo TEXT, resource TEXT, session TEXT, line TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS journal_ts ON journal(ts);
CREATE INDEX IF NOT EXISTS journal_repo_ts ON journal(repo, ts);
CREATE INDEX IF NOT EXISTS journal_event_ts ON journal(event, ts);
CREATE TABLE IF NOT EXISTS ingest(file TEXT PRIMARY KEY, offset INTEGER NOT NULL, ident TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, label TEXT, state TEXT, started TEXT, ended TEXT, exit INTEGER, cwd TEXT, json TEXT NOT NULL, mtime REAL NOT NULL);
CREATE INDEX IF NOT EXISTS jobs_started ON jobs(started);
`;

export function open(home) {
  fs.mkdirSync(home, { recursive: true });
  const db = new DatabaseSync(dbPath(home));
  db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;');
  db.exec(SCHEMA);
  return db;
}

const repoOf = (o) => o.repo || String(o.resource ?? '').split(',')[0].split(':')[1] || null;

// Journal files oldest first: rotated journal-*.jsonl (name sorts by timestamp), then journal.jsonl.
export function journalFiles(home) {
  let names = [];
  try { names = fs.readdirSync(home); } catch { return []; }
  const rotated = names.filter((n) => /^journal-.+\.jsonl$/.test(n)).sort();
  const out = rotated.map((n) => path.join(home, n));
  if (names.includes('journal.jsonl')) out.push(path.join(home, 'journal.jsonl'));
  return out;
}

// The first complete line (max 4 KB) identifies a file across renames (rotation moves journal.jsonl ->
// journal-<ts>.jsonl); it never changes once written, unlike a fixed-size prefix of a growing file.
function ident(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const b = Buffer.alloc(4096); const n = fs.readSync(fd, b, 0, 4096, 0);
    const nl = b.subarray(0, n).indexOf(0x0a);
    return nl < 0 ? null : b.subarray(0, nl).toString('base64');
  } finally { fs.closeSync(fd); }
}

function tx(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try { const r = fn(); db.exec('COMMIT'); return r; } catch (e) { try { db.exec('ROLLBACK'); } catch { /* ignore */ } throw e; }
}

export function ingestJournal(db, home) {
  const ins = db.prepare('INSERT INTO journal(ts, event, repo, resource, session, line) VALUES (?, ?, ?, ?, ?, ?)');
  const get = db.prepare('SELECT file, offset, ident FROM ingest WHERE ident = ? OR file = ?');
  const put = db.prepare('INSERT INTO ingest(file, offset, ident) VALUES (?, ?, ?) ON CONFLICT(file) DO UPDATE SET offset = excluded.offset, ident = excluded.ident');
  const delByIdent = db.prepare('DELETE FROM ingest WHERE ident = ? AND file <> ?');
  let added = 0; let bad = 0;
  for (const file of journalFiles(home)) {
    const size = fs.statSync(file).size;
    if (!size) continue;
    const id = ident(file);
    if (!id) continue;   // first line not complete yet
    const rows = get.all(id, file);
    // Same content prefix seen before (possibly under the pre-rotation name) -> resume at its offset.
    const known = rows.find((r) => r.ident === id) ?? null;
    let offset = known ? Number(known.offset) : 0;
    if (offset > size) offset = 0;
    if (offset === size) { if (known && known.file !== file) tx(db, () => { delByIdent.run(id, file); put.run(file, offset, id); }); continue; }
    const fd = fs.openSync(file, 'r');
    let buf;
    try { buf = Buffer.alloc(size - offset); fs.readSync(fd, buf, 0, buf.length, offset); } finally { fs.closeSync(fd); }
    // Only complete lines: a writer may be mid-append.
    const lastNl = buf.lastIndexOf(0x0a);
    if (lastNl < 0) continue;
    const text = buf.subarray(0, lastNl + 1).toString('utf8');
    const consumed = offset + lastNl + 1;
    tx(db, () => {
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        let o;
        try { o = JSON.parse(line); } catch { bad++; continue; }
        if (!o || typeof o.event !== 'string' || typeof o.ts !== 'string' || Number.isNaN(Date.parse(o.ts))) { bad++; continue; }
        ins.run(new Date(Date.parse(o.ts)).toISOString(), o.event, repoOf(o), o.resource == null ? null : String(o.resource), o.session == null ? null : String(o.session), line);
        added++;
      }
      delByIdent.run(id, file);
      put.run(file, consumed, id);
    });
  }
  return { added, bad };
}

export function ingestJobs(db, home) {
  const dir = path.join(home, 'jobs');
  let names = [];
  try { names = fs.readdirSync(dir).filter((n) => n.endsWith('.json')); } catch { return { upserted: 0, removed: 0 }; }
  const known = new Map(db.prepare('SELECT id, mtime FROM jobs').all().map((r) => [r.id, Number(r.mtime)]));
  const up = db.prepare(`INSERT INTO jobs(id, label, state, started, ended, exit, cwd, json, mtime) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET label = excluded.label, state = excluded.state, started = excluded.started, ended = excluded.ended, exit = excluded.exit, cwd = excluded.cwd, json = excluded.json, mtime = excluded.mtime`);
  const del = db.prepare('DELETE FROM jobs WHERE id = ?');
  let upserted = 0; let removed = 0;
  const seen = new Set();
  tx(db, () => {
    for (const n of names) {
      const id = n.slice(0, -5);
      seen.add(id);
      const f = path.join(dir, n);
      let st; try { st = fs.statSync(f); } catch { continue; }
      if (known.get(id) === st.mtimeMs) continue;
      let j; try { j = JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '')); } catch { continue; }
      const s = (v) => (v == null ? null : String(v));
      up.run(id, s(j.label), s(j.state ?? j.status), s(j.started ?? j.startedAt), s(j.ended ?? j.endedAt), Number.isInteger(j.exit) ? j.exit : (Number.isInteger(j.exitCode) ? j.exitCode : null), s(j.cwd), JSON.stringify(j), st.mtimeMs);
      upserted++;
    }
    for (const id of known.keys()) if (!seen.has(id)) { del.run(id); removed++; }
  });
  return { upserted, removed };
}

export function sync(home) {
  const db = open(home);
  try { return { journal: ingestJournal(db, home), jobs: ingestJobs(db, home) }; } finally { db.close(); }
}

export function status(home) {
  const db = open(home);
  try {
    const one = (q) => db.prepare(q).get();
    let lag = 0;
    const offs = new Map(db.prepare('SELECT file, offset FROM ingest').all().map((r) => [r.file, Number(r.offset)]));
    for (const f of journalFiles(home)) lag += Math.max(0, fs.statSync(f).size - (offs.get(f) ?? 0));
    return {
      db: dbPath(home), sizeBytes: fs.statSync(dbPath(home)).size,
      journalRows: Number(one('SELECT count(*) n FROM journal').n), lastTs: one('SELECT max(ts) t FROM journal').t,
      jobs: Number(one('SELECT count(*) n FROM jobs').n), lagBytes: lag,
    };
  } finally { db.close(); }
}

export function query(home, { event, repo, hours, limit = 1000, now } = {}) {
  const db = open(home);
  try {
    const where = []; const args = [];
    if (event) { where.push('event = ?'); args.push(event); }
    if (repo) { where.push('repo = ?'); args.push(repo); }
    if (hours) { where.push('ts >= ?'); args.push(new Date((now ? Date.parse(now) : Date.now()) - hours * 36e5).toISOString()); }
    const sql = `SELECT line FROM (SELECT id, line FROM journal ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY id DESC LIMIT ?) ORDER BY id`;
    return db.prepare(sql).all(...args, Number(limit)).map((r) => r.line);
  } finally { db.close(); }
}

// Lines in [now - days, now]; caller (agentq-slo) applies the exact window again.
export function windowLines(home, days, now) {
  const db = open(home);
  try {
    const from = new Date((now ? Date.parse(now) : Date.now()) - days * 864e5).toISOString();
    return db.prepare('SELECT line FROM journal WHERE ts >= ? ORDER BY ts, id').all(from).map((r) => r.line);
  } finally { db.close(); }
}

export function rebuild(home) {
  for (const s of ['', '-wal', '-shm']) { try { fs.rmSync(dbPath(home) + s, { force: true }); } catch { /* ignore */ } }
  return sync(home);
}

function args(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) { const k = a.slice(2); const v = argv[i + 1]; if (v === undefined || v.startsWith('--')) o[k] = true; else { o[k] = v; i++; } } else o._.push(a);
  }
  return o;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  try {
    const a = args(process.argv.slice(2));
    const home = homeDir(a.home);
    switch (a._[0]) {
      case 'sync': console.log(JSON.stringify(sync(home))); break;
      case 'status': sync(home); console.log(JSON.stringify(status(home))); break;
      case 'query': sync(home); for (const l of query(home, { event: a.event, repo: a.repo, hours: a.hours ? Number(a.hours) : undefined, limit: a.limit ?? 1000, now: a.now })) process.stdout.write(l + '\n'); break;
      case 'window': sync(home); for (const l of windowLines(home, Number(a.days ?? 7), a.now)) process.stdout.write(l + '\n'); break;
      case 'rebuild': console.log(JSON.stringify(rebuild(home))); break;
      default: throw new Error('usage: agentq-store.mjs sync|status|query|window|rebuild [--home H]');
    }
  } catch (e) { process.stderr.write(`agentq-store: ${e.message}\n`); process.exit(2); }
}
