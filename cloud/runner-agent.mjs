#!/usr/bin/env node
// devcloud runner-agent (DC-036): runs on a warm workspace VM, claims jobs from GCS, runs them in a
// persistent checkout (warm node_modules / turbo / pnpm store), streams the log back, suspends the VM
// when idle. Zero dependencies: GCS + Compute + Secret Manager over REST with the metadata token.
// Contract: E:\gh\agentq\spec\job.md (v1). Client: ps/bin/agentq-cloud.ps1.
// DC-063: the same file runs on Windows workspaces (process.platform === 'win32'): work dir C:\work,
// the command runs as a pwsh script built from spec.argv (PowerShell quoting, not POSIX), process
// trees are killed with taskkill. Linux behaviour is unchanged.
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const MD = 'http://metadata.google.internal/computeMetadata/v1';
const isWin = process.platform === 'win32';
// Every request has a deadline (DC-063): on ws-vitals-win a request in flight across a suspend never settled
// (heartbeat frozen at the pre-suspend time, VM RUNNING, queue never claimed). Uploads get longer.
const T = (ms) => AbortSignal.timeout(ms);
const md = async (p) => (await fetch(`${MD}/${p}`, { headers: { 'Metadata-Flavor': 'Google' }, signal: T(15_000) })).text();
const attr = async (k, d = '') => { try { const r = await fetch(`${MD}/instance/attributes/${k}`, { headers: { 'Metadata-Flavor': 'Google' }, signal: T(15_000) }); return r.ok ? (await r.text()).trim() : d; } catch { return d; } };

let tok = { v: '', exp: 0 };
async function token() {
  if (Date.now() < tok.exp - 60_000) return tok.v;
  const j = JSON.parse(await md('instance/service-accounts/default/token'));
  tok = { v: j.access_token, exp: Date.now() + j.expires_in * 1000 };
  return tok.v;
}
async function api(url, init = {}) {
  const r = await fetch(url, { signal: T(init.body ? 600_000 : 60_000), ...init, headers: { Authorization: `Bearer ${await token()}`, ...(init.headers || {}) } });
  if (!r.ok && r.status !== 404) throw new Error(`${init.method || 'GET'} ${url.split('?')[0]} -> ${r.status} ${(await r.text()).slice(0, 300)}`);
  return r;
}
const enc = encodeURIComponent;
const gs = {
  list: async (b, prefix) => ((await (await api(`https://storage.googleapis.com/storage/v1/b/${b}/o?prefix=${enc(prefix)}&fields=items(name,generation)`)).json()).items || []),
  get: async (b, o) => { const r = await api(`https://storage.googleapis.com/storage/v1/b/${b}/o/${enc(o)}?alt=media`); return r.status === 404 ? null : Buffer.from(await r.arrayBuffer()); },
  put: async (b, o, body, type = 'application/octet-stream') => api(`https://storage.googleapis.com/upload/storage/v1/b/${b}/o?uploadType=media&name=${enc(o)}`, { method: 'POST', body, headers: { 'Content-Type': type } }),
  // claim = delete with ifGenerationMatch: only one agent wins a queued job.
  claim: async (b, o, gen) => { const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${b}/o/${enc(o)}?ifGenerationMatch=${gen}`, { method: 'DELETE', headers: { Authorization: `Bearer ${await token()}` }, signal: T(60_000) }); return r.status === 204; },
};

const cfg = {
  bucket: await attr('devcloud-bucket'),
  ws: await attr('devcloud-ws'),
  idleMin: Number(await attr('devcloud-idle-min', '15')),
  project: await md('project/project-id'),
  zone: (await md('instance/zone')).split('/').pop(),
  name: await md('instance/name'),
  // the control plane (bucket, secret, turbo cache) may live in another project than the VM
  secretProject: await attr('devcloud-secret-project', ''),
  turboSecret: await attr('devcloud-turbo-secret', 'devcloud-turbo-token'),
  turboApi: await attr('devcloud-turbo-api', ''),
  work: isWin ? await attr('devcloud-work', 'C:\\work') : '/work',
};
if (!cfg.secretProject) cfg.secretProject = cfg.project;
const log = (...a) => console.log(new Date().toISOString(), ...a);
let turboToken = '';
async function loadTurbo() {
  if (!cfg.turboApi) return;
  try {
    const r = await api(`https://secretmanager.googleapis.com/v1/projects/${cfg.secretProject}/secrets/${cfg.turboSecret}/versions/latest:access`);
    turboToken = Buffer.from((await r.json()).payload.data, 'base64').toString('utf8').trim();
  } catch (e) { log('turbo token unavailable:', e.message); }
}

function sh(cmd, args, opts = {}) { return execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 28, ...opts }).toString(); }
const repoKey = (r) => String(r).toLowerCase().replace(/[^\w.-]/g, '_');

// Windows: the client sends argv (spec.argv) besides the POSIX-quoted cmd. One element = a pwsh
// script line as-is (`-- 'pnpm typecheck; cargo test'`); several = a command invocation, each token
// single-quoted for PowerShell. The script ends with the native exit code: `pwsh -Command` alone
// maps any native failure to 1 (measured: `cmd /c exit 5` -> 1), which would hide real codes.
const psq = (s) => (/^[\w@./:=,+\\-]+$/.test(s) ? s : `'${String(s).replace(/'/g, "''")}'`);
function winScript(spec) {
  const argv = Array.isArray(spec.argv) && spec.argv.length ? spec.argv.map(String) : null;
  const body = !argv ? spec.cmd : argv.length === 1 ? argv[0] : `& ${argv.map(psq).join(' ')}`;
  return [
    "$ErrorActionPreference = 'Continue'",
    '$global:LASTEXITCODE = 0',
    body,
    '$devcloudOk = $?',
    'if ($LASTEXITCODE) { exit $LASTEXITCODE }',
    'if (-not $devcloudOk) { exit 1 }',
    'exit 0',
    '',
  ].join('\r\n');
}
function killTree(p) {
  if (isWin) { try { execFileSync('taskkill', ['/T', '/F', '/PID', String(p.pid)], { stdio: 'ignore' }); } catch { p.kill(); } return; }
  try { process.kill(-p.pid, 'SIGKILL'); } catch { p.kill('SIGKILL'); }
}

// Shas this workspace has (and therefore all their ancestors): the client picks its bundle base from
// these via merge-base, so only the commits the workspace lacks travel.
async function publishKnown(repo, dir, sha) {
  const f = path.join(cfg.work, `.known-${repo}.json`);
  let shas = [];
  try { shas = JSON.parse(fs.readFileSync(f, 'utf8')).shas || []; } catch {}
  shas = [sha, ...shas.filter((s) => s !== sha)].slice(0, 30);
  shas = shas.filter((s) => { try { sh('git', ['-C', dir, 'cat-file', '-e', `${s}^{commit}`]); return true; } catch { return false; } });
  const doc = JSON.stringify({ repo, shas, at: new Date().toISOString(), host: cfg.name });
  fs.writeFileSync(f, doc);
  await gs.put(cfg.bucket, `ws/${cfg.ws}/repos/${repo}.json`, doc, 'application/json').catch((e) => log('known', e.message));
}

async function runJob(spec) {
  const t0 = Date.now(); const phases = {};
  const repo = repoKey(spec.repo);
  const dir = path.join(cfg.work, repo);
  const out = []; let dirty = true; let lastFlush = 0;
  const append = (s) => { out.push(s); dirty = true; };
  const flush = async (force = false) => {
    if (!dirty || (!force && Date.now() - lastFlush < 2000)) return;
    dirty = false; lastFlush = Date.now();
    await gs.put(cfg.bucket, `jobs/${spec.id}/log`, out.join(''), 'text/plain; charset=utf-8').catch((e) => log('log flush', e.message));
  };
  const step = (cmd, args, o = {}) => new Promise((res) => {
    append(`$ ${cmd} ${args.join(' ')}\n`);
    const p = spawn(cmd, args, { cwd: o.cwd || dir, env: o.env || process.env, stdio: ['ignore', 'pipe', 'pipe'], detached: !isWin, windowsHide: true });
    let killed = false;
    const timer = o.timeoutSec ? setTimeout(() => { killed = true; append(`\n[devcloud] timeout after ${o.timeoutSec}s, killing\n`); killTree(p); }, o.timeoutSec * 1000) : null;
    p.stdout.on('data', (d) => { append(d.toString()); void flush(); });
    p.stderr.on('data', (d) => { append(d.toString()); void flush(); });
    p.on('error', (e) => { append(`[devcloud] spawn ${cmd}: ${e.message}\n`); });
    p.on('close', (code) => { if (timer) clearTimeout(timer); res(killed ? 124 : (code ?? 1)); });
  });
  await gs.put(cfg.bucket, `jobs/${spec.id}/claimed`, JSON.stringify({ at: new Date().toISOString(), host: cfg.name }), 'application/json').catch(() => {});
  let exit = 0;
  try {
    // --- sync: fetch new commits from the bundle, checkout sha, clean (keep warm caches), apply patch
    let s = Date.now();
    fs.mkdirSync(cfg.work, { recursive: true });
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'job-'));
    if (!fs.existsSync(path.join(dir, '.git'))) {
      exit = await step('git', ['init', '-q', dir], { cwd: cfg.work }); if (exit) throw new Error('git init failed');
    }
    sh('git', ['-C', dir, 'config', 'core.autocrlf', 'false']);
    sh('git', ['-C', dir, 'config', 'gc.auto', '0']);
    if (spec.bundle) {
      const b = await gs.get(cfg.bucket, `jobs/${spec.id}/bundle`);
      if (!b) throw new Error('bundle missing in GCS');
      fs.writeFileSync(path.join(tmp, 'b.bundle'), b);
      append(`[devcloud] bundle ${(b.length / 1048576).toFixed(1)} MB\n`);
      exit = await step('git', ['fetch', '-q', '--no-tags', path.join(tmp, 'b.bundle'), `HEAD:refs/devcloud/in/${spec.id}`]);
      if (exit) throw new Error('bundle fetch failed (prerequisite missing? the client re-sends a full bundle on retry)');
    }
    exit = await step('git', ['checkout', '-q', '-f', '--detach', spec.sha]); if (exit) throw new Error(`sha ${spec.sha} not in workspace (stale known list?)`);
    exit = await step('git', ['clean', '-q', '-ffdx', '-e', 'node_modules', '-e', '.turbo', '-e', 'target', '-e', '.gradle', '-e', '.pnpm-store']);
    if (spec.patch) {
      const p = await gs.get(cfg.bucket, `jobs/${spec.id}/patch`);
      if (p && p.length) {
        fs.writeFileSync(path.join(tmp, 'w.patch'), p);
        append(`[devcloud] patch ${(p.length / 1024).toFixed(1)} KB\n`);
        exit = await step('git', ['apply', '--binary', '--whitespace=nowarn', path.join(tmp, 'w.patch')]);
        if (exit) throw new Error('patch did not apply');
      }
    }
    fs.rmSync(tmp, { recursive: true, force: true });
    phases.sync = Math.round((Date.now() - s) / 100) / 10;
    await publishKnown(repo, dir, spec.sha);
    // --- install only when the lockfile changed since the last install in this checkout
    s = Date.now();
    const lock = path.join(dir, 'pnpm-lock.yaml');
    if (fs.existsSync(lock) && !spec.noInstall) {
      const h = crypto.createHash('sha256').update(fs.readFileSync(lock)).digest('hex');
      const mark = path.join(dir, 'node_modules', '.devcloud-lock');
      if (!fs.existsSync(mark) || fs.readFileSync(mark, 'utf8') !== h) {
        exit = await step('pnpm', ['install', '--frozen-lockfile', '--prefer-offline', '--reporter=append-only'], { env: { ...process.env, CI: '1' }, timeoutSec: 1800 });
        if (exit) throw new Error('pnpm install failed');
        fs.writeFileSync(mark, h);
      } else append('[devcloud] node_modules up to date (lockfile unchanged)\n');
    }
    phases.install = Math.round((Date.now() - s) / 100) / 10;
    // --- run
    s = Date.now();
    const env = { ...process.env, CI: '1', FORCE_COLOR: '0', NODE_OPTIONS: process.env.NODE_OPTIONS || '--max-old-space-size=16384', ...(spec.env || {}) };
    if (turboToken && !env.TURBO_TOKEN) Object.assign(env, { TURBO_API: cfg.turboApi, TURBO_TEAM: 'dragos', TURBO_TOKEN: turboToken });
    append(`\n[devcloud] run on ${cfg.name} (${os.cpus().length} vCPU): ${spec.cmd}\n`);
    if (isWin) {
      const js = path.join(os.tmpdir(), `devcloud-job-${spec.id}.ps1`);
      fs.writeFileSync(js, winScript(spec));
      try { exit = await step('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', js], { env, timeoutSec: spec.timeoutSec || 3600 }); }
      finally { fs.rmSync(js, { force: true }); }
    } else {
      exit = await step('bash', ['-lc', spec.cmd], { env, timeoutSec: spec.timeoutSec || 3600 });
    }
    phases.run = Math.round((Date.now() - s) / 100) / 10;
  } catch (e) {
    append(`\n[devcloud] ERROR: ${e.message}\n`); if (!exit) exit = 1;
  }
  append(`\n[devcloud] exit ${exit}\n`);
  await flush(true);
  const result = { v: 1, id: spec.id, exit, durSec: Math.round((Date.now() - t0) / 100) / 10, phases, host: cfg.name, vcpu: os.cpus().length, finishedAt: new Date().toISOString() };
  await gs.put(cfg.bucket, `jobs/${spec.id}/result.json`, JSON.stringify(result), 'application/json');
  log('job', spec.id, 'exit', exit, JSON.stringify(phases));
}

async function suspendSelf() {
  log(`idle ${cfg.idleMin} min -> suspend`);
  await gs.put(cfg.bucket, `ws/${cfg.ws}/heartbeat`, JSON.stringify({ at: new Date().toISOString(), host: cfg.name, state: 'suspending' }), 'application/json').catch(() => {});
  await api(`https://compute.googleapis.com/compute/v1/projects/${cfg.project}/zones/${cfg.zone}/instances/${cfg.name}/suspend`, { method: 'POST' }).catch((e) => log('suspend failed', e.message));
}

async function main() {
  if (!cfg.bucket || !cfg.ws) throw new Error('metadata devcloud-bucket / devcloud-ws missing');
  // Windows has no ssh path: publish the tail of the previous run's log (agent-loop.ps1 appends to it), so a
  // hang or crash is diagnosable from gs://<bucket>/ws/<ws>/agent-log-tail.
  if (isWin) {
    try { const t = fs.readFileSync('C:\\devcloud\\agent.log'); await gs.put(cfg.bucket, `ws/${cfg.ws}/agent-log-tail`, t.subarray(Math.max(0, t.length - 65536)), 'text/plain; charset=utf-8'); } catch (e) { log('log tail', e.message); }
  }
  await loadTurbo();
  log('agent up', JSON.stringify({ ws: cfg.ws, bucket: cfg.bucket, zone: cfg.zone, idleMin: cfg.idleMin, vcpu: os.cpus().length, secretProject: cfg.secretProject, turbo: !!turboToken }));
  let lastWork = Date.now(); let lastHb = 0; let lastTick = Date.now(); let lastSelfCheck = Date.now();
  // Watchdog: timers still fire while the loop awaits. No loop pass for 5 min outside a job = something
  // hung -> exit; systemd (Restart=always) / agent-loop.ps1 start a fresh agent.
  let inJob = false; let loopAt = Date.now();
  setInterval(() => { if (!inJob && Date.now() - loopAt > 300_000) { log('watchdog: loop stalled', Math.round((Date.now() - loopAt) / 1000), 's, exiting'); process.exit(3); } }, 30_000).unref();
  const hb = (state) => gs.put(cfg.bucket, `ws/${cfg.ws}/heartbeat`, JSON.stringify({ at: new Date().toISOString(), host: cfg.name, state, idleSec: Math.round((Date.now() - lastWork) / 1000) }), 'application/json').catch(() => {});
  for (;;) {
    loopAt = Date.now();
    // a jump in wall time = we were suspended; restart the idle clock and refresh the token
    if (Date.now() - lastTick > 30_000) { log('resumed after', Math.round((Date.now() - lastTick) / 1000), 's'); lastWork = Date.now(); tok.exp = 0; lastHb = 0; }
    lastTick = Date.now();
    let items = [];
    try { items = (await gs.list(cfg.bucket, `ws/${cfg.ws}/queue/`)).sort((a, b) => a.name.localeCompare(b.name)); } catch (e) { log('list', e.message); }
    if (items.length) {
      const it = items[0];
      const raw = await gs.get(cfg.bucket, it.name).catch(() => null);
      if (raw && await gs.claim(cfg.bucket, it.name, it.generation)) {
        const spec = JSON.parse(raw.toString());
        log('claimed', spec.id, spec.cmd);
        await hb('busy');
        if (!turboToken) await loadTurbo();
        inJob = true;
        try { await runJob(spec); } finally { inJob = false; loopAt = Date.now(); }
        lastWork = Date.now(); lastTick = Date.now();
        continue;
      }
    }
    if (Date.now() - lastHb > 30_000) { lastHb = Date.now(); await hb('idle'); }
    // Windows has no `gcloud compute ssh` restart path: while idle, adopt a newer agent pushed to metadata by
    // workspace.ps1 -UpdateAgent and exit; the agent-loop.ps1 wrapper starts the new file.
    if (isWin && Date.now() - lastSelfCheck > 60_000) {
      lastSelfCheck = Date.now();
      const fresh = await attr('runner-agent', '');
      const self = process.argv[1];
      if (fresh.length > 1000 && fresh !== fs.readFileSync(self, 'utf8').trim()) { fs.writeFileSync(self, fresh); log('agent updated from metadata, restarting'); process.exit(0); }
    }
    if (cfg.idleMin > 0 && Date.now() - lastWork > cfg.idleMin * 60_000) { await suspendSelf(); lastWork = Date.now(); await new Promise((r) => setTimeout(r, 20_000)); continue; }
    await new Promise((r) => setTimeout(r, 1000));
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
