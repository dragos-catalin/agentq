#!/usr/bin/env node
// devcloud runner-agent (DC-036): runs on a warm workspace VM, claims jobs from GCS, runs them in a
// persistent checkout (warm node_modules / turbo / pnpm store), streams the log back, suspends the VM
// when idle. Zero dependencies: GCS + Compute + Secret Manager over REST with the metadata token.
// Contract: E:\gh\agentq\spec\job.md (v1). Client: ps/bin/agentq-cloud.ps1.
// DC-063: the same file runs on Windows workspaces (process.platform === 'win32'): work dir C:\work,
// the command runs as a pwsh script built from spec.argv (PowerShell quoting, not POSIX), process
// trees are killed with taskkill. Linux behaviour is unchanged.
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const MD = "http://metadata.google.internal/computeMetadata/v1";
const isWin = process.platform === "win32";
// Every request has a deadline (DC-063): on ws-vitals-win a request in flight across a suspend never settled
// (heartbeat frozen at the pre-suspend time, VM RUNNING, queue never claimed). Uploads get longer.
const T = (ms) => AbortSignal.timeout(ms);
const md = async (p) =>
    (await fetch(`${MD}/${p}`, { headers: { "Metadata-Flavor": "Google" }, signal: T(15_000) })).text();
const attr = async (k, d = "") => {
    try {
        const r = await fetch(`${MD}/instance/attributes/${k}`, {
            headers: { "Metadata-Flavor": "Google" },
            signal: T(15_000),
        });
        return r.ok ? (await r.text()).trim() : d;
    } catch {
        return d;
    }
};

let tok = { v: "", exp: 0 };
async function token() {
    if (Date.now() < tok.exp - 60_000) return tok.v;
    const j = JSON.parse(await md("instance/service-accounts/default/token"));
    tok = { v: j.access_token, exp: Date.now() + j.expires_in * 1000 };
    return tok.v;
}
async function api(url, init = {}) {
    const r = await fetch(url, {
        signal: T(init.body ? 600_000 : 60_000),
        ...init,
        headers: { Authorization: `Bearer ${await token()}`, ...(init.headers || {}) },
    });
    if (!r.ok && r.status !== 404)
        throw new Error(
            `${init.method || "GET"} ${url.split("?")[0]} -> ${r.status} ${(await r.text()).slice(0, 300)}`,
        );
    return r;
}
const enc = encodeURIComponent;
const gs = {
    list: async (b, prefix) =>
        (
            await (
                await api(
                    `https://storage.googleapis.com/storage/v1/b/${b}/o?prefix=${enc(prefix)}&fields=items(name,generation)`,
                )
            ).json()
        ).items || [],
    get: async (b, o) => {
        const r = await api(`https://storage.googleapis.com/storage/v1/b/${b}/o/${enc(o)}?alt=media`);
        return r.status === 404 ? null : Buffer.from(await r.arrayBuffer());
    },
    put: async (b, o, body, type = "application/octet-stream") =>
        api(`https://storage.googleapis.com/upload/storage/v1/b/${b}/o?uploadType=media&name=${enc(o)}`, {
            method: "POST",
            body,
            headers: { "Content-Type": type },
        }),
    // plain delete (404 is fine - `api` tolerates it): used to clear ws/<ws>/busy when a job ends.
    del: async (b, o) => api(`https://storage.googleapis.com/storage/v1/b/${b}/o/${enc(o)}`, { method: "DELETE" }),
    // claim = delete with ifGenerationMatch: only one agent wins a queued job.
    claim: async (b, o, gen) => {
        const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${b}/o/${enc(o)}?ifGenerationMatch=${gen}`, {
            method: "DELETE",
            headers: { Authorization: `Bearer ${await token()}` },
            signal: T(60_000),
        });
        return r.status === 204;
    },
};

const cfg = {
    bucket: await attr("devcloud-bucket"),
    ws: await attr("devcloud-ws"),
    idleMin: Number(await attr("devcloud-idle-min", "15")),
    // devbox: interactive workspace (VS Code Remote / SSH / codaid). Never suspend while a session or load is present.
    interactive: (await attr("devcloud-interactive", "0")) === "1",
    busyLoad: Number(await attr("devcloud-busy-load", "1.0")),
    project: await md("project/project-id"),
    zone: (await md("instance/zone")).split("/").pop(),
    name: await md("instance/name"),
    // the control plane (bucket, secret, turbo cache) may live in another project than the VM
    secretProject: await attr("devcloud-secret-project", ""),
    turboSecret: await attr("devcloud-turbo-secret", "devcloud-turbo-token"),
    turboApi: await attr("devcloud-turbo-api", ""),
    work: isWin ? await attr("devcloud-work", "C:\\work") : "/work",
    // extra `git clean -e` patterns kept between jobs (comma list), e.g. ws-watch-faces keeps Gradle `build`
    // dirs + pinned tool jars so gates stay incremental. Default empty = only the warm caches below.
    cleanKeep: (await attr("devcloud-clean-keep", ""))
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
};
if (!cfg.secretProject) cfg.secretProject = cfg.project;
// Job checkouts (git checkout -f + clean -ffdx every job). On an interactive devbox /work/<repo> is the TEAM
// repo people edit (agentq ADR 0007), so jobs get their own tree: /work/.jobs/<repo>. Runners keep /work/<repo>.
cfg.jobs = await attr("devcloud-jobs-dir", cfg.interactive ? path.join(cfg.work, ".jobs") : cfg.work);
const log = (...a) => console.log(new Date().toISOString(), ...a);
let turboToken = "";
async function loadTurbo() {
    if (!cfg.turboApi) return;
    try {
        const r = await api(
            `https://secretmanager.googleapis.com/v1/projects/${cfg.secretProject}/secrets/${cfg.turboSecret}/versions/latest:access`,
        );
        turboToken = Buffer.from((await r.json()).payload.data, "base64")
            .toString("utf8")
            .trim();
    } catch (e) {
        log("turbo token unavailable:", e.message);
    }
}

function sh(cmd, args, opts = {}) {
    return execFileSync(cmd, args, { stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28, ...opts }).toString();
}
const repoKey = (r) =>
    String(r)
        .toLowerCase()
        .replace(/[^\w.-]/g, "_");

// Windows: the client sends argv (spec.argv) besides the POSIX-quoted cmd. One element = a pwsh
// script line as-is (`-- 'pnpm typecheck; cargo test'`); several = a command invocation, each token
// single-quoted for PowerShell. The script ends with the native exit code: `pwsh -Command` alone
// maps any native failure to 1 (measured: `cmd /c exit 5` -> 1), which would hide real codes.
const psq = (s) => (/^[\w@./:=,+\\-]+$/.test(s) ? s : `'${String(s).replace(/'/g, "''")}'`);
function winScript(spec) {
    const argv = Array.isArray(spec.argv) && spec.argv.length ? spec.argv.map(String) : null;
    const body = !argv ? spec.cmd : argv.length === 1 ? argv[0] : `& ${argv.map(psq).join(" ")}`;
    return [
        "$ErrorActionPreference = 'Continue'",
        "$global:LASTEXITCODE = 0",
        body,
        "$devcloudOk = $?",
        "if ($LASTEXITCODE) { exit $LASTEXITCODE }",
        "if (-not $devcloudOk) { exit 1 }",
        "exit 0",
        "",
    ].join("\r\n");
}
function killTree(p) {
    if (isWin) {
        try {
            execFileSync("taskkill", ["/T", "/F", "/PID", String(p.pid)], { stdio: "ignore" });
        } catch {
            p.kill();
        }
        return;
    }
    try {
        process.kill(-p.pid, "SIGKILL");
    } catch {
        p.kill("SIGKILL");
    }
}

// Both child streams are piped (stdio: ["ignore", "pipe", "pipe"]) and appended to the SAME
// jobs/<id>/log, so a suite's stderr used to be indistinguishable from its stdout - a failure whose
// only evidence was on stderr read as "the process printed nothing". Tag every stderr LINE with a
// prefix so the two streams can be told apart in the log. Chunk boundaries are unrelated to line
// boundaries, so a line split across two chunks can carry the tag twice; that is cosmetic, never
// lossy. The per-chunk append+flush below is unchanged.
const tagStderr = (s) => s.replace(/^(?=[^\r\n])/gm, "[devcloud:stderr] ");

// Shas this workspace has (and therefore all their ancestors): the client picks its bundle base from
// these via merge-base, so only the commits the workspace lacks travel.
async function publishKnown(repo, dir, sha) {
    const f = path.join(cfg.jobs, `.known-${repo}.json`);
    let shas = [];
    try {
        shas = JSON.parse(fs.readFileSync(f, "utf8")).shas || [];
    } catch {}
    shas = [sha, ...shas.filter((s) => s !== sha)].slice(0, 30);
    shas = shas.filter((s) => {
        try {
            sh("git", ["-C", dir, "cat-file", "-e", `${s}^{commit}`]);
            return true;
        } catch {
            return false;
        }
    });
    const doc = JSON.stringify({ repo, shas, at: new Date().toISOString(), host: cfg.name });
    fs.writeFileSync(f, doc);
    await gs
        .put(cfg.bucket, `ws/${cfg.ws}/repos/${repo}.json`, doc, "application/json")
        .catch((e) => log("known", e.message));
}

// The bundle-base claim the client reads (ws/<ws>/repos/<repo>.json) is a CACHE of what this disk
// already has, never data. A VM that was recreated, rebaked or reset keeps a job checkout with fewer
// commits than the claim still names, so the client picks an unusable base and dies with "Repository
// lacks these prerequisite commits" -- and re-sends the same thin bundle on every retry. workspace.ps1
// clears the claim only on the instance-create path, so every other way a disk is lost leaves it stale.
// Drop the shas this disk cannot prove, in place, keeping the newest-first order. A shorter or empty
// claim can only ever make the client ship a BIGGER bundle, so this repair can never turn a working job
// into a failing one; a healthy workspace changes nothing and writes nothing.
async function healKnownClaims() {
    let items;
    try {
        items = await gs.list(cfg.bucket, `ws/${cfg.ws}/repos/`);
    } catch (e) {
        log("heal list", e.message);
        return;
    }
    for (const it of items) {
        if (!it.name.endsWith(".json")) continue;
        const repo = it.name.slice(it.name.lastIndexOf("/") + 1).replace(/\.json$/, "");
        try {
            const raw = await gs.get(cfg.bucket, it.name);
            if (!raw) continue;
            const doc = JSON.parse(raw.toString());
            const shas = Array.isArray(doc.shas) ? doc.shas : [];
            const dir = path.join(cfg.jobs, repo);
            // A missing checkout dir, or one that is not a git repository, proves no sha: cat-file
            // throws for each and the list collapses to [] (an empty claim = a full bundle).
            const present = shas.filter((s) => {
                try {
                    sh("git", ["-C", dir, "cat-file", "-e", `${s}^{commit}`]);
                    return true;
                } catch {
                    return false;
                }
            });
            if (present.length === shas.length) continue; // healthy: zero writes
            await gs.put(
                cfg.bucket,
                it.name,
                JSON.stringify({ repo, shas: present, at: new Date().toISOString(), host: cfg.name }),
                "application/json",
            );
            log("heal", repo, `${shas.length} -> ${present.length} shas`);
        } catch (e) {
            log("heal", repo, e.message);
        }
    }
}

// The workspace advertises WHICH job it is running, for the WHOLE duration of that job, on
// ws/<ws>/busy. A client that is about to reset a wedged workspace reads it first, so it never reboots
// the VM out from under a peer's run - the old client only asked whether ITS OWN job had been claimed,
// so a reset killed a peer build (ws-codai, 2026-11-26). A marker that has outlived its deadline is a
// wedge, not a live peer, and a client may then reset it - so the deadline is BOUNDED and REFRESHED
// while the job really runs (2026-11-28). It used to be `at + the job's own timeoutSec` (up to 90 min):
// a job killed together with its VM then left a marker that made every peer-aware heal answer
// `skip-peer` for that whole window, and the land that resumed ws-agentq sat unclaimed 105 min behind
// it (pre-gate job 20261128-133944-8f1895). The bound must stay well above the refresh interval.
const BUSY_TTL_SEC = 300;
async function markBusy(spec) {
    const timeoutSec = Number(spec.timeoutSec) || 3600;
    const ttlSec = Math.min(timeoutSec, BUSY_TTL_SEC);
    await gs
        .put(
            cfg.bucket,
            `ws/${cfg.ws}/busy`,
            JSON.stringify({
                job: spec.id,
                host: cfg.name,
                at: new Date().toISOString(),
                timeoutSec,
                ttlSec,
                until: new Date(Date.now() + ttlSec * 1000).toISOString(),
            }),
            "application/json",
        )
        .catch((e) => log("busy marker", e.message));
}
async function clearBusy(jobId) {
    // Only clear the marker if it is OURS: never erase a peer's claim to this workspace.
    try {
        const raw = await gs.get(cfg.bucket, `ws/${cfg.ws}/busy`);
        if (!raw) return;
        if (JSON.parse(raw.toString()).job !== jobId) return;
        await gs.del(cfg.bucket, `ws/${cfg.ws}/busy`);
    } catch (e) {
        log("busy clear", e.message);
    }
}

// A marker whose host is THIS workspace is ours by construction (one workspace = one VM) and at startup
// this process holds no job, so whatever is there is a leftover from a killed or restarted agent. Left
// alone it makes every peer-aware heal answer `skip-peer` until its TTL expires, which is exactly how a
// frozen runner kept a land waiting (2026-11-28). Cheap: one GET, and only a DEL when it is ours.
async function clearStaleBusyOnStart() {
    try {
        const raw = await gs.get(cfg.bucket, `ws/${cfg.ws}/busy`);
        if (!raw) return;
        const m = JSON.parse(raw.toString());
        if (m.host !== cfg.name) return;
        await gs.del(cfg.bucket, `ws/${cfg.ws}/busy`);
        log("cleared the previous agent's busy marker", m.job);
    } catch (e) {
        log("busy clear on start", e.message);
    }
}

async function runJob(spec) {
    const t0 = Date.now();
    const phases = {};
    const repo = repoKey(spec.repo);
    const dir = path.join(cfg.jobs, repo);
    const out = [];
    let dirty = true;
    let lastFlush = 0;
    const append = (s) => {
        out.push(s);
        dirty = true;
    };
    const flush = async (force = false) => {
        if (!dirty || (!force && Date.now() - lastFlush < 2000)) return;
        dirty = false;
        lastFlush = Date.now();
        await gs
            .put(cfg.bucket, `jobs/${spec.id}/log`, out.join(""), "text/plain; charset=utf-8")
            .catch((e) => log("log flush", e.message));
    };
    const step = (cmd, args, o = {}) =>
        new Promise((res) => {
            append(`$ ${cmd} ${args.join(" ")}\n`);
            const p = spawn(cmd, args, {
                cwd: o.cwd || dir,
                env: o.env || process.env,
                stdio: ["ignore", "pipe", "pipe"],
                detached: !isWin,
                windowsHide: true,
            });
            let killed = false;
            const timer = o.timeoutSec
                ? setTimeout(() => {
                      killed = true;
                      append(`\n[devcloud] timeout after ${o.timeoutSec}s, killing\n`);
                      killTree(p);
                  }, o.timeoutSec * 1000)
                : null;
            p.stdout.on("data", (d) => {
                append(d.toString());
                void flush();
            });
            p.stderr.on("data", (d) => {
                append(tagStderr(d.toString()));
                void flush();
            });
            // The step ends when the process ends, not when its streams close. A tool that
            // starts a daemon hands that daemon the handles it inherited from us: Gradle's
            // daemon outlives its client by hours, so `close` - process exit AND both streams
            // closed - never fires, and the job never publishes an exit code. Measured
            // 2026-11-25: the log ended with `assemble exit=0`, every process we started had
            // exited, and result.json was still absent ten minutes later; three android jobs
            // were abandoned and the instance was reset twice. The daemon holding a pipe to a
            // reader that has stopped caring is the toolchain's business, and killing the
            // daemon to make a bookkeeping event fire would trade a hang for a rebuilt JVM.
            let settled = false;
            const settle = (code) => {
                if (settled) return;
                settled = true;
                if (timer) clearTimeout(timer);
                res(killed ? 124 : (code ?? 1));
            };
            p.on("error", (e) => {
                append(`[devcloud] spawn ${cmd}: ${e.message}\n`);
                settle(1);
            });
            // `close` normally arrives first and stays the fast path; the exit handler is what
            // makes a step whose pipes are still held by a daemon (or by a grandchild that
            // outlives its parent) finish at all. Half a second after exit covers the output
            // still sitting in the pipe, which `close` would otherwise have delivered.
            p.on("close", (code) => settle(code));
            p.on("exit", (code) => setTimeout(() => settle(code), 500));
        });
    await gs
        .put(
            cfg.bucket,
            `jobs/${spec.id}/claimed`,
            JSON.stringify({ at: new Date().toISOString(), host: cfg.name }),
            "application/json",
        )
        .catch(() => {});
    let exit = 0;
    try {
        // --- sync: fetch new commits from the bundle, checkout sha, clean (keep warm caches), apply patch
        let s = Date.now();
        fs.mkdirSync(cfg.jobs, { recursive: true });
        const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "job-"));
        if (!fs.existsSync(path.join(dir, ".git"))) {
            exit = await step("git", ["init", "-q", dir], { cwd: cfg.jobs });
            if (exit) throw new Error("git init failed");
        }
        sh("git", ["-C", dir, "config", "core.autocrlf", "false"]);
        sh("git", ["-C", dir, "config", "gc.auto", "0"]);
        if (spec.bundle) {
            const b = await gs.get(cfg.bucket, `jobs/${spec.id}/bundle`);
            if (!b) throw new Error("bundle missing in GCS");
            fs.writeFileSync(path.join(tmp, "b.bundle"), b);
            append(`[devcloud] bundle ${(b.length / 1048576).toFixed(1)} MB\n`);
            exit = await step("git", [
                "fetch",
                "-q",
                "--no-tags",
                path.join(tmp, "b.bundle"),
                `HEAD:refs/devcloud/in/${spec.id}`,
            ]);
            if (exit)
                throw new Error(
                    "bundle fetch failed (prerequisite missing? the client re-sends a full bundle on retry)",
                );
        }
        exit = await step("git", ["checkout", "-q", "-f", "--detach", spec.sha]);
        if (exit) throw new Error(`sha ${spec.sha} not in workspace (stale known list?)`);
        exit = await step("git", [
            "clean",
            "-q",
            "-ffdx",
            "-e",
            "node_modules",
            "-e",
            ".turbo",
            "-e",
            "target",
            "-e",
            ".gradle",
            "-e",
            ".pnpm-store",
            ...cfg.cleanKeep.flatMap((k) => ["-e", k]),
        ]);
        if (spec.patch) {
            const p = await gs.get(cfg.bucket, `jobs/${spec.id}/patch`);
            if (p && p.length) {
                fs.writeFileSync(path.join(tmp, "w.patch"), p);
                append(`[devcloud] patch ${(p.length / 1024).toFixed(1)} KB\n`);
                exit = await step("git", ["apply", "--binary", "--whitespace=nowarn", path.join(tmp, "w.patch")]);
                if (exit) throw new Error("patch did not apply");
            }
        }
        fs.rmSync(tmp, { recursive: true, force: true });
        phases.sync = Math.round((Date.now() - s) / 100) / 10;
        await publishKnown(repo, dir, spec.sha);
        // --- install only when the lockfile changed since the last install in this checkout
        s = Date.now();
        const lock = path.join(dir, "pnpm-lock.yaml");
        if (fs.existsSync(lock) && !spec.noInstall) {
            const h = crypto.createHash("sha256").update(fs.readFileSync(lock)).digest("hex");
            const mark = path.join(dir, "node_modules", ".devcloud-lock");
            if (!fs.existsSync(mark) || fs.readFileSync(mark, "utf8") !== h) {
                exit = await step(
                    "pnpm",
                    ["install", "--frozen-lockfile", "--prefer-offline", "--reporter=append-only"],
                    { env: { ...process.env, CI: "1" }, timeoutSec: 1800 },
                );
                if (exit) throw new Error("pnpm install failed");
                fs.writeFileSync(mark, h);
            } else append("[devcloud] node_modules up to date (lockfile unchanged)\n");
        }
        phases.install = Math.round((Date.now() - s) / 100) / 10;
        // --- run
        s = Date.now();
        // DEVCLOUD_JOB_ID / DEVCLOUD_BUCKET: a job script may upload artefacts to jobs/<id>/ (watch-faces cloud-job.ps1).
        const env = {
            ...process.env,
            CI: "1",
            FORCE_COLOR: "0",
            NODE_OPTIONS: process.env.NODE_OPTIONS || "--max-old-space-size=16384",
            DEVCLOUD_JOB_ID: spec.id,
            DEVCLOUD_BUCKET: cfg.bucket,
            ...(spec.env || {}),
        };
        if (turboToken && !env.TURBO_TOKEN)
            Object.assign(env, { TURBO_API: cfg.turboApi, TURBO_TEAM: "dragos", TURBO_TOKEN: turboToken });
        append(`\n[devcloud] run on ${cfg.name} (${os.cpus().length} vCPU): ${spec.cmd}\n`);
        if (isWin) {
            const js = path.join(os.tmpdir(), `devcloud-job-${spec.id}.ps1`);
            fs.writeFileSync(js, winScript(spec));
            try {
                exit = await step(
                    "pwsh",
                    ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", js],
                    { env, timeoutSec: spec.timeoutSec || 3600 },
                );
            } finally {
                fs.rmSync(js, { force: true });
            }
        } else {
            exit = await step("bash", ["-lc", spec.cmd], { env, timeoutSec: spec.timeoutSec || 3600 });
        }
        phases.run = Math.round((Date.now() - s) / 100) / 10;
    } catch (e) {
        append(`\n[devcloud] ERROR: ${e.message}\n`);
        if (!exit) exit = 1;
    }
    append(`\n[devcloud] exit ${exit}\n`);
    await flush(true);
    const result = {
        v: 1,
        id: spec.id,
        exit,
        durSec: Math.round((Date.now() - t0) / 100) / 10,
        phases,
        host: cfg.name,
        vcpu: os.cpus().length,
        finishedAt: new Date().toISOString(),
    };
    await gs.put(cfg.bucket, `jobs/${spec.id}/result.json`, JSON.stringify(result), "application/json");
    log("job", spec.id, "exit", exit, JSON.stringify(phases));
}

// Busy = any login session (`who`, or an sshd session process: covers notty sessions such as VS Code Remote-SSH and `gcloud compute ssh --command`) or 1-min load above devcloud-busy-load.
function interactiveBusy() {
    if (!cfg.interactive || isWin) return false;
    try {
        if (execFileSync("who", { encoding: "utf8", timeout: 5000 }).trim()) return true;
        const ps = execFileSync("ps", ["-eo", "args="], { encoding: "utf8", timeout: 5000 });
        if (/^sshd(-session)?: [^ ]+@(notty|pts)/m.test(ps)) return true;
        return Number(fs.readFileSync("/proc/loadavg", "utf8").split(" ")[0]) > cfg.busyLoad;
    } catch {
        return false;
    }
}

async function suspendSelf() {
    if (interactiveBusy()) {
        log("idle timer hit, interactive session or load present -> stay up");
        return false;
    }
    log(`idle ${cfg.idleMin} min -> suspend`);
    await gs
        .put(
            cfg.bucket,
            `ws/${cfg.ws}/heartbeat`,
            JSON.stringify({ at: new Date().toISOString(), host: cfg.name, state: "suspending" }),
            "application/json",
        )
        .catch(() => {});
    await api(
        `https://compute.googleapis.com/compute/v1/projects/${cfg.project}/zones/${cfg.zone}/instances/${cfg.name}/suspend`,
        { method: "POST" },
    ).catch((e) => log("suspend failed", e.message));
}

async function main() {
    if (!cfg.bucket || !cfg.ws) throw new Error("metadata devcloud-bucket / devcloud-ws missing");
    // Windows has no ssh path: publish the tail of the previous run's log (agent-loop.ps1 appends to it), so a
    // hang or crash is diagnosable from gs://<bucket>/ws/<ws>/agent-log-tail.
    if (isWin) {
        try {
            const t = fs.readFileSync("C:\\devcloud\\agent.log");
            await gs.put(
                cfg.bucket,
                `ws/${cfg.ws}/agent-log-tail`,
                t.subarray(Math.max(0, t.length - 65536)),
                "text/plain; charset=utf-8",
            );
        } catch (e) {
            log("log tail", e.message);
        }
    }
    await loadTurbo();
    // Startup: a VM that just came up may already hold a claim from its previous disk. Never fatal.
    await healKnownClaims().catch((e) => log("heal", e.message));
    // Same reason, for the busy marker: a process that starts clean must not leave a peer looking busy.
    await clearStaleBusyOnStart();
    log(
        "agent up",
        JSON.stringify({
            interactive: cfg.interactive,
            ws: cfg.ws,
            bucket: cfg.bucket,
            zone: cfg.zone,
            idleMin: cfg.idleMin,
            vcpu: os.cpus().length,
            secretProject: cfg.secretProject,
            turbo: !!turboToken,
        }),
    );
    let lastWork = Date.now();
    let lastBusyCheck = 0;
    let lastHb = 0;
    let lastHeal = 0;
    let lastTick = Date.now();
    let lastSelfCheck = Date.now();
    // Watchdog: timers still fire while the loop awaits. No loop pass for 5 min outside a job = something
    // hung -> exit; systemd (Restart=always) / agent-loop.ps1 start a fresh agent.
    let inJob = false;
    let loopAt = Date.now();
    setInterval(() => {
        if (!inJob && Date.now() - loopAt > 300_000) {
            log("watchdog: loop stalled", Math.round((Date.now() - loopAt) / 1000), "s, exiting");
            process.exit(3);
        }
    }, 30_000).unref();
    const hb = (state) =>
        gs
            .put(
                cfg.bucket,
                `ws/${cfg.ws}/heartbeat`,
                JSON.stringify({
                    at: new Date().toISOString(),
                    host: cfg.name,
                    state,
                    idleSec: Math.round((Date.now() - lastWork) / 1000),
                }),
                "application/json",
            )
            .catch(() => {});
    for (;;) {
        loopAt = Date.now();
        // a jump in wall time = we were suspended; restart the idle clock and refresh the token
        if (Date.now() - lastTick > 30_000) {
            const gapSec = Math.round((Date.now() - lastTick) / 1000);
            log("resumed after", gapSec, "s");
            lastWork = Date.now();
            tok.exp = 0;
            lastHb = 0;
            // A long freeze (suspend/resume, a reset, a wedged event loop) leaves this process with a
            // stale in-memory view of the world; exit so the supervisor (systemd Restart=always on
            // Linux, agent-loop.ps1 on Windows) starts a clean one. 5 min is far above the 1 s loop
            // tick, so only a real freeze qualifies, and never while a job is running.
            if (gapSec > 300 && !inJob) {
                log("long wake, exiting so the supervisor starts a fresh agent");
                process.exit(0);
            }
        }
        lastTick = Date.now();
        let items = [];
        try {
            items = (await gs.list(cfg.bucket, `ws/${cfg.ws}/queue/`)).sort((a, b) => a.name.localeCompare(b.name));
        } catch (e) {
            log("list", e.message);
        }
        if (items.length) {
            const it = items[0];
            const raw = await gs.get(cfg.bucket, it.name).catch(() => null);
            if (raw && (await gs.claim(cfg.bucket, it.name, it.generation))) {
                const spec = JSON.parse(raw.toString());
                log("claimed", spec.id, spec.cmd);
                await markBusy(spec);
                await hb("busy");
                if (!turboToken) await loadTurbo();
                inJob = true;
                // The marker's TTL is short (BUSY_TTL_SEC) so a killed agent cannot wedge a peer's heal;
                // refresh it while the job really runs, or a long job would look like a dead one.
                const busyTimer = setInterval(() => void markBusy(spec), 60_000);
                busyTimer.unref();
                try {
                    await runJob(spec);
                } finally {
                    clearInterval(busyTimer);
                    inJob = false;
                    loopAt = Date.now();
                    await clearBusy(spec.id);
                }
                lastWork = Date.now();
                lastTick = Date.now();
                continue;
            }
        }
        if (Date.now() - lastHb > 30_000) {
            lastHb = Date.now();
            await hb("idle");
        }
        // Same cadence as the idle heartbeat: re-check the claims against the disk we actually have.
        if (Date.now() - lastHeal > 30_000) {
            lastHeal = Date.now();
            await healKnownClaims().catch((e) => log("heal", e.message));
        }
        // interactive devbox: every 30 s, a login session or load counts as work (idle clock restarts)
        if (cfg.interactive && Date.now() - lastBusyCheck > 30_000) {
            lastBusyCheck = Date.now();
            if (interactiveBusy()) lastWork = Date.now();
        }
        // Windows has no `gcloud compute ssh` restart path: while idle, adopt a newer agent pushed to metadata by
        // workspace.ps1 -UpdateAgent and exit; the agent-loop.ps1 wrapper starts the new file.
        if (isWin && Date.now() - lastSelfCheck > 60_000) {
            lastSelfCheck = Date.now();
            const fresh = await attr("runner-agent", "");
            const self = process.argv[1];
            // Compared trimmed on both sides: the metadata value is what gcloud read from a
            // file, so whether it carries the file's final newline is gcloud's business, and a
            // mismatch that is only a newline restarts the agent every minute forever.
            if (fresh.length > 1000 && fresh.trim() !== fs.readFileSync(self, "utf8").trim()) {
                fs.writeFileSync(self, fresh);
                log("agent updated from metadata, restarting");
                process.exit(0);
            }
        }
        if (cfg.idleMin > 0 && Date.now() - lastWork > cfg.idleMin * 60_000) {
            const did = await suspendSelf();
            lastWork = Date.now();
            if (did) await new Promise((r) => setTimeout(r, 20_000));
            continue;
        }
        await new Promise((r) => setTimeout(r, 1000));
    }
}
main().catch((e) => {
    console.error(e);
    process.exit(1);
});
