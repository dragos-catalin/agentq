// Tests for agentq-store.mjs (ADR 0006 / ADR 0003 W4-3): incremental ingest, rotation, bad lines, jobs
// upsert by mtime + removal, query filters, rebuild == incremental, slo from store == slo from file.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { sync, status, query, windowLines, rebuild } from '../bin/agentq-store.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const bin = path.join(here, '..', 'bin');
let n = 0;
const ok = (name, fn) => { fn(); n++; console.log(`PASS ${name}`); };
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'aqstore-'));
const J = path.join(home, 'journal.jsonl');
const ev = (min, event, extra = {}) => JSON.stringify({ ts: new Date(Date.parse('2026-10-19T00:00:00Z') + min * 6e4).toISOString(), event, session: 'S', ...extra });

try {
  fs.writeFileSync(J, [ev(1, 'queued', { resource: 'land:codai' }), ev(2, 'land', { repo: 'codai', resource: 'land:codai' }), 'not json', ''].join('\n'));
  ok('first sync ingests valid lines, skips bad ones', () => {
    const r = sync(home);
    assert.equal(r.journal.added, 2); assert.equal(r.journal.bad, 1);
  });
  ok('second sync adds only new lines', () => {
    fs.appendFileSync(J, ev(3, 'flake', { repo: 'brivio' }) + '\n');
    assert.equal(sync(home).journal.added, 1);
    assert.equal(sync(home).journal.added, 0);
  });
  ok('a half-written last line waits for its newline', () => {
    fs.appendFileSync(J, ev(4, 'commit', { repo: 'codai' }).slice(0, 20));
    assert.equal(sync(home).journal.added, 0);
    fs.appendFileSync(J, ev(4, 'commit', { repo: 'codai' }).slice(20) + '\n');
    assert.equal(sync(home).journal.added, 1);
  });
  ok('rotation: renamed file is not re-read, new journal starts from 0', () => {
    fs.appendFileSync(J, ev(5, 'push', { repo: 'codai' }) + '\n');  // not yet synced when rotated
    fs.renameSync(J, path.join(home, 'journal-20261019-000600.jsonl'));
    fs.writeFileSync(J, ev(7, 'land', { repo: 'brivio', resource: 'land:brivio' }) + '\n');
    const r = sync(home);
    assert.equal(r.journal.added, 2, 'one tail line of the rotated file + one in the new file');
    assert.equal(status(home).journalRows, 6);
    assert.equal(status(home).lagBytes, 0);
  });
  ok('query filters by event, repo (from resource too) and window', () => {
    assert.equal(query(home, { event: 'land' }).length, 2);
    assert.equal(query(home, { repo: 'codai' }).length, 4);
    assert.equal(query(home, { hours: 2 / 60, now: '2026-10-19T00:06:30Z' }).length, 2, 'ts >= 00:04:30 (no upper bound): 00:05 + 00:07');
    assert.equal(windowLines(home, 2 / 1440, '2026-10-19T00:06:30Z').length, 2);
  });
  ok('jobs: upsert by mtime, removal mirrored', () => {
    const jd = path.join(home, 'jobs'); fs.mkdirSync(jd);
    fs.writeFileSync(path.join(jd, 'j1.json'), JSON.stringify({ label: 'gate', state: 'running', cwd: 'E:/x' }));
    fs.writeFileSync(path.join(jd, 'j2.json'), JSON.stringify({ label: 'b', state: 'done', exit: 0 }));
    assert.equal(sync(home).jobs.upserted, 2);
    assert.equal(sync(home).jobs.upserted, 0);
    const t = new Date(Date.now() + 5000);
    fs.writeFileSync(path.join(jd, 'j1.json'), JSON.stringify({ label: 'gate', state: 'done', exit: 1 })); fs.utimesSync(path.join(jd, 'j1.json'), t, t);
    fs.rmSync(path.join(jd, 'j2.json'));
    const r = sync(home);
    assert.equal(r.jobs.upserted, 1); assert.equal(r.jobs.removed, 1);
    assert.equal(status(home).jobs, 1);
  });
  ok('rebuild equals incremental', () => {
    const before = query(home, {});
    rebuild(home);
    assert.deepEqual(query(home, {}), before);
  });
  ok('CLI status/query', () => {
    const cli = path.join(bin, 'agentq-store.mjs');
    const s = JSON.parse(execFileSync(process.execPath, [cli, 'status', '--home', home], { encoding: 'utf8' }));
    assert.equal(s.journalRows, 6);
    const q = execFileSync(process.execPath, [cli, 'query', '--home', home, '--event', 'flake'], { encoding: 'utf8' }).trim().split('\n');
    assert.equal(q.length, 1); assert.equal(JSON.parse(q[0]).repo, 'brivio');
  });
  ok('slo from store equals slo from file', () => {
    const slo = path.join(bin, 'agentq-slo.mjs');
    const all = path.join(home, 'all.jsonl');
    fs.writeFileSync(all, [fs.readFileSync(path.join(home, 'journal-20261019-000600.jsonl'), 'utf8'), fs.readFileSync(J, 'utf8')].join(''));
    const strip = (o) => { delete o.generatedAt; delete o.journal; return o; };
    // agentq-slo exits 1 when an SLO verdict is FAIL; the JSON on stdout is what matters here.
    const run = (...a) => { try { return execFileSync(process.execPath, [slo, ...a], { encoding: 'utf8' }); } catch (e) { if (e.status === 1 && e.stdout) return e.stdout; throw e; } };
    const a = strip(JSON.parse(run('--journal', all, '--days', '1', '--now', '2026-10-19T01:00:00Z', '--json')));
    const b = strip(JSON.parse(run('--store', home, '--days', '1', '--now', '2026-10-19T01:00:00Z', '--json')));
    assert.ok(a.overall.landing.lands >= 1);
    assert.deepEqual(b, a);
  });
} finally { fs.rmSync(home, { recursive: true, force: true }); }
console.log(`ALL PASS store (${n})`);
