// Self-test for agentq-slo.mjs: synthetic journal, asserts every computed number.
import assert from 'node:assert/strict';
import { compute, render, pct, parseArgs } from '../bin/agentq-slo.mjs';

const T = (hm) => `2026-10-18T${hm}:00.000Z`;
const j = (o) => JSON.stringify(o);
const lines = [
  j({ ts: '2026-09-01T00:00:00Z', event: 'land', repo: 'r', resource: 'land:r', session: 'OLD' }), // outside window
  j({ ts: T('00:00'), event: 'queued', repo: 'r', resource: 'land:r', session: 'A', ticket: 't1' }),
  j({ ts: T('00:01'), event: 'acquired', resource: 'land:r', session: 'A', tickets: ['t1'], waitSec: 60 }),
  j({ ts: T('00:30'), event: 'land', repo: 'r', resource: 'land:r', session: 'A', branch: 'main' }),
  j({ ts: T('01:00'), event: 'queued', repo: 'r', resource: 'land:r', session: 'B', ticket: 't2' }),
  j({ ts: T('01:05'), event: 'land-conflict', repo: 'r', resource: 'land:r', session: 'B' }),
  j({ ts: T('01:10'), event: 'queued', repo: 'r', resource: 'land:r', session: 'B', ticket: 't3' }),
  j({ ts: T('01:50'), event: 'flake', repo: 'r', resource: 'land:r', session: 'B', exit: 7 }),
  j({ ts: T('02:00'), event: 'land', repo: 'r', resource: 'land:r', session: 'B', branch: 'main' }),
  j({ ts: T('02:10'), event: 'land-push-failed', repo: 'r', resource: 'land:r', session: 'C', exit: 7 }),
  j({ ts: T('02:20'), event: 'acquired', resource: 'commit:r', session: 'C', tickets: ['t4'], waitSec: 10 }),
  j({ ts: T('02:21'), event: 'commit', repo: 'r', resource: 'commit:r', session: 'C', sha: 'abc' }),
  j({ ts: T('02:22'), event: 'commit-failed', repo: 'r', resource: 'commit:r', session: 'C' }),
  j({ ts: T('02:23'), event: 'push', repo: 'r', resource: 'commit:r', session: 'C', branch: 'main' }),
  j({ ts: T('02:24'), event: 'push', repo: 'r', resource: 'commit:r', session: 'C', branch: 'feat/x' }),
  j({ ts: T('03:00'), event: 'lease-expire', repo: 'r', resource: 'slot:r:task-1', holderSession: 'X', session: 'S', ref: 'refs/backup/wt/r/task-1/1' }),
  j({ ts: T('03:01'), event: 'lease-expire', repo: 'r', resource: 'slot:r:task-2', holderSession: 'X', session: 'S', ref: '' }),
  j({ ts: T('03:02'), event: 'lease-break', repo: 'r', resource: 'slot:r:task-3', holderSession: 'X', session: 'Y', ref: '', reason: 'stuck' }),
  j({ ts: T('03:03'), event: 'lease-expire-failed', repo: 'r', resource: 'slot:r:task-4', reason: 'backup could not be proven' }),
  j({ ts: T('03:04'), event: 'backup', repo: 'r', resource: 'slot:r:task-5', ref: 'refs/backup/wt/r/task-5/1', pushError: 'network' }),
  j({ ts: T('03:03'), event: 'publish-refused', repo: 'r', resource: 'commit:r', session: 'Y' }),
  j({ ts: T('04:00'), event: 'done', repo: 's', resource: 'build:s,build:machine', session: 'D', waitSec: 120, exit: 0 }),
  j({ ts: T('04:00'), event: 'fail', repo: 's', resource: 'build:s,build:machine', session: 'D', waitSec: 120, exit: 1 }), // same grant -> deduped
  '{not json',
];
async function* gen() { for (const l of lines) yield l; }

const rep = await compute(gen(), { days: 7, now: T('12:00') });
const r = rep.byRepo.r, s = rep.byRepo.s, o = rep.overall;

assert.equal(rep.journal.lines, 24);
assert.equal(rep.journal.badLines, 1);
assert.equal(rep.journal.eventsInWindow, 22);
// landing
assert.equal(r.landing.lands, 2);
assert.deepEqual(r.landing.failByCause, { conflict: 1, pushRefused: 1, gate: 0, oversized: 0 });
assert.equal(r.landing.failureRate, 0.5);
assert.equal(r.landing.publishRefused, 1);
// queue
assert.deepEqual(r.queueWaitSec.land, { n: 1, p50: 60, p90: 60 });
assert.deepEqual(r.queueWaitSec.commit, { n: 1, p50: 10, p90: 10 });
assert.deepEqual(s.queueWaitSec.build, { n: 1, p50: 120, p90: 120 });
assert.equal(rep.byRepo.machine, undefined);
// commit path + bypass
assert.deepEqual(r.commitPath, { acquired: 1, commits: 1, commitFailed: 1, pushFailed: 0, pushDeferred: 0 });
assert.equal(r.bypass.directPushIntegration, 1);
assert.equal(r.bypass.pushTopicBranch, 1);
assert.equal(r.bypass.share, 1 / 3);
// flake
assert.equal(r.flake.flakes, 1);
assert.equal(r.flake.rate, 0.25);
assert.equal(r.flake.shareOfPushFailures, 0.5);
// lost work
// clean expiry / clean foreign break (no ref = nothing unique) are NOT incidents; a failed backup is.
assert.equal(r.lostWork.incidents, 2);
assert.equal(r.lostWork.cleanExpire ?? 1, 1);
assert.equal(r.lostWork.foreignBreakBenign, 1);
assert.equal(r.lostWork.recoveredExpire, 1);
assert.equal(r.lostWork.prevented, 1);
// ready-to-landed: A 30 min; B first unconsumed queue 01:00 -> 02:00 = 60 min
assert.deepEqual(r.readyToLandedMin, { n: 2, p50: 30, p90: 60, unpaired: 0 });
// overall + SLO verdicts
assert.equal(o.landing.lands, 2);
assert.equal(rep.slo.readyToLandedP90Min.value, 60);
assert.equal(rep.slo.readyToLandedP90Min.verdict, 'FAIL');
assert.equal(rep.slo.flakeRatePct.value, 25);
assert.equal(rep.slo.flakeRatePct.verdict, 'FAIL');
assert.equal(rep.slo.lostWorkIncidents.verdict, 'FAIL');
// helpers
assert.equal(pct([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
assert.equal(pct([], 50), null);
assert.deepEqual(parseArgs(['--days', '3', '--json']).days, 3);
assert.throws(() => parseArgs(['--bogus']));
// a clean window passes
async function* ok() {
  yield j({ ts: T('01:00'), event: 'queued', repo: 'q', resource: 'land:q', session: 'Z' });
  yield j({ ts: T('01:10'), event: 'land', repo: 'q', resource: 'land:q', session: 'Z' });
}
const good = await compute(ok(), { days: 1, now: T('12:00') });
assert.deepEqual(Object.values(good.slo).map((x) => x.verdict), ['PASS', 'PASS', 'PASS']);

const txt = render(rep);
assert.match(txt, /LANDING/);
assert.match(txt, /readyToLandedP90Min\s+60\s+< 45\s+FAIL/);
console.log(txt);
console.log('\nSELFTEST OK (all assertions passed)');
