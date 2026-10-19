// Unit tests for agentq-flakes.mjs (ADR 0003 W2-3): parser, flip detection, quarantine expiry, CLI.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseFailures, emptyLedger, record, pass, list, clear } from '../bin/agentq-flakes.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
let n = 0;
const ok = (name, fn) => { fn(); n++; console.log(`PASS ${name}`); };

const vitestOut = [
  ' FAIL  src/jobs/gdpr-storage.test.ts > deleteUserObjects > skips unconfigured buckets and reports them',
  '@codai/sdk:test:  FAIL  |unit| test/vault.test.ts > vault > lists files 12ms',
  '@codai/sdk:test: Error: Test timed out in 5000ms.',
  ' Failed:    @codai/sdk#test',
  'Error: ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL',
].join('\n');

ok('parser: plain + turbo-prefixed vitest lines', () => {
  const r = parseFailures(vitestOut);
  assert.deepEqual(r.failed, ['@codai/sdk|test/vault.test.ts > vault > lists files', 'src/jobs/gdpr-storage.test.ts > deleteUserObjects > skips unconfigured buckets and reports them']);
  assert.equal(r.nonTest, false);
});
ok('parser: a typecheck/build task failure is nonTest', () => {
  assert.equal(parseFailures('x:typecheck: src/a.ts(1,2): error TS2322: nope').nonTest, true);
  assert.equal(parseFailures(' Failed:    @codai/web#build, @codai/sdk#test').nonTest, true);
  assert.equal(parseFailures(' Failed:    @codai/sdk#test').nonTest, false);
});

const T0 = Date.parse('2026-10-19T00:00:00Z');
const A = 'a.test.ts > s > flaky';
const B = 'b.test.ts > s > real';
const out = (...ks) => ks.map((k) => ` FAIL  ${k}`).join('\n');

ok('first failure on a new tree: not quarantined', () => {
  const led = emptyLedger();
  const r = record(led, { tree: 't1', text: out(A), nowMs: T0 });
  assert.deepEqual(r.failed, [A]); assert.equal(r.allQuarantined, false); assert.deepEqual(r.flipped, []);
});
ok('fail then pass on the same tree -> quarantined; next tree failure is excused', () => {
  const led = emptyLedger();
  record(led, { tree: 't1', text: out(A), nowMs: T0 });
  const p = pass(led, { tree: 't1', nowMs: T0 + 1000 });
  assert.deepEqual(p.flipped, [A]);
  const r = record(led, { tree: 't2', text: out(A), nowMs: T0 + 2000 });
  assert.equal(r.allQuarantined, true);
  const r2 = record(led, { tree: 't3', text: out(A, B), nowMs: T0 + 3000 });
  assert.equal(r2.allQuarantined, false, 'a non-quarantined failure still blocks');
  assert.deepEqual(r2.quarantined, [A]);
});
ok('attempt 2 on the same tree drops a failure -> that test flips', () => {
  const led = emptyLedger();
  record(led, { tree: 't1', text: out(A, B), nowMs: T0, attempt: 1 });
  const r = record(led, { tree: 't1', text: out(B), nowMs: T0 + 1, attempt: 2 });
  assert.deepEqual(r.flipped, [A]);
  assert.equal(r.allQuarantined, false);
});
ok('failure on a tree that was green -> flip', () => {
  const led = emptyLedger();
  pass(led, { tree: 't1', nowMs: T0 });
  const r = record(led, { tree: 't1', text: out(B), nowMs: T0 + 1 });
  assert.deepEqual(r.flipped, [B]); assert.equal(r.allQuarantined, true);
});
ok('nonTest failures are never excused', () => {
  const led = emptyLedger();
  record(led, { tree: 't1', text: out(A), nowMs: T0 }); pass(led, { tree: 't1', nowMs: T0 + 1 });
  const r = record(led, { tree: 't2', text: out(A) + '\nsrc/x.ts(1,1): error TS2304: x', nowMs: T0 + 2 });
  assert.equal(r.nonTest, true); assert.equal(r.allQuarantined, false);
});
ok('quarantine expires after --days; clear lifts it', () => {
  const led = emptyLedger();
  record(led, { tree: 't1', text: out(A), nowMs: T0, days: 1 }); pass(led, { tree: 't1', nowMs: T0, days: 1 });
  assert.equal(list(led, T0 + 1000).quarantined.length, 1);
  assert.equal(list(led, T0 + 2 * 864e5).quarantined.length, 0);
  const r = record(led, { tree: 't9', text: out(A), nowMs: T0 + 2 * 864e5, days: 1 });
  assert.equal(r.allQuarantined, false);
  record(led, { tree: 't1', text: out(A), nowMs: T0, days: 1 }); pass(led, { tree: 't1', nowMs: T0, days: 1 });
  assert.deepEqual(clear(led, 'flaky').cleared, [A]);
});
ok('CLI record/pass/list round-trip', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aqflk-'));
  const L = path.join(dir, 'r.json'); const log = path.join(dir, 'o.log');
  fs.writeFileSync(log, out(A));
  const cli = path.join(here, '..', 'bin', 'agentq-flakes.mjs');
  const run = (...a) => JSON.parse(execFileSync(process.execPath, [cli, ...a, '--ledger', L], { encoding: 'utf8' }));
  assert.deepEqual(run('record', '--tree', 't1', '--log', log).failed, [A]);
  assert.deepEqual(run('pass', '--tree', 't1').flipped, [A]);
  assert.equal(run('list').quarantined[0].test, A);
  assert.equal(run('record', '--tree', 't2', '--log', log).allQuarantined, true);
  fs.rmSync(dir, { recursive: true, force: true });
});
console.log(`ALL PASS flakes (${n})`);
