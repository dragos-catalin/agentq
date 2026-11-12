#!/usr/bin/env node
// agentq SLO report (ADR 0003 W4-4). Dependency-free; streams the journal line by line.
//
//   node agentq-slo.mjs [--days 7] [--json] [--journal <path> | --store <coord dir>] [--home <coord dir>] [--now <ISO>]
//
// Targets: ready-to-landed p90 < 45 min, flake-caused land failures < 2 %, zero lost-work incidents,
// >= 95 % of 5-minute start-probe buckets with a median under 500 ms, zero slots lost with a live chat.
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
//  * Queue time (rep.queueTime): ONLY 'acquired' events with a numeric waitSec (one per grant, so no
//    dedupe), credited to the FIRST resource of a comma list, keyed kind:repo ("deploy:alpha:web" ->
//    "deploy:alpha", "build:machine" stays). Different rule than queueWaitSec above on purpose: this
//    one is the week-over-week total, that one is the per-kind percentile table.
//  * Land ticket (rep.landTicket): an 'acquired' whose first resource is land:<repo> opens a hold keyed
//    by session; the next land / land-* failure of that repo closes it (same session if open, else the
//    most recently opened one: a batch journals one 'land' per topic with the topic's session).
//  * Slots lost with a live chat (rep.slots): lease-expire with numeric chatIdleMin <= 30, lease-break
//    with numeric chatIdleMin <= 30 and byChat !== true. Lines without those fields count as neither.
//  * Hook cost (<home>/hooks/cost-YYYYMMDD.jsonl) and start probe (<home>/load/probe-YYYYMMDD.jsonl)
//    are day files read from disk; they are never in the SQLite store. Cost of one call = ms + startMs.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

export const TARGETS = {
    readyToLandedP90Min: 45,
    flakeRatePct: 2,
    lostWork: 0,
    startProbeBucketMs: 500,
    startProbeBucketsPct: 95,
    slotsLostLiveChat: 0,
    liveChatIdleMin: 30,
};
const INTEGRATION = new Set(["main", "master", "dev"]);
const LAND_FAIL = {
    "land-conflict": "conflict",
    "land-push-failed": "pushRefused",
    "land-gate-failed": "gate",
    "land-oversized": "oversized",
    "land-finalize-failed": "finalize",
};
// A land-push-failed whose reason carries the hook's output = the repo pre-push gate failed (lint, tests,
// platform gates); only the rest is the remote refusing the push.
export const PRE_PUSH_RE = /pre-push|husky|FAIL |Tests? +\d+ failed|ELIFECYCLE|error TS\d|lint error/i;
const BENIGN_BREAK = /clean|landed|merged|done|finished|pushed/i;
const LONG_WAIT_SEC = 600; // "waits over 10 min"
const SHORT_HOLD_SEC = 60;
const PROBE_BUCKET_MS = 5 * 60 * 1000;
const LAND_END = new Set(["land", ...Object.keys(LAND_FAIL)]);
const LAND_STAGE0 = {
    "land-pregate-ok": "pregateOk",
    "land-pregate-failed": "pregateFailed",
    "land-pregate-conflict": "pregateConflict",
    "land-pregate-skipped": "pregateSkipped",
    "land-gate-skipped-green": "gateSkippedGreen",
};

export function parseArgs(argv) {
    const a = {
        days: 7,
        json: false,
        journal: path.join(os.homedir(), ".codai", "coord", "journal.jsonl"),
        now: null,
        home: null,
    };
    for (let i = 0; i < argv.length; i++) {
        const k = argv[i];
        if (k === "--days") a.days = Number(argv[++i]);
        else if (k === "--json") a.json = true;
        else if (k === "--journal") a.journal = argv[++i];
        else if (k === "--now") a.now = argv[++i];
        else if (k === "--store") a.store = argv[++i];
        else if (k === "--home") a.home = argv[++i];
        else if (k === "-h" || k === "--help") a.help = true;
        else throw new Error(`unknown argument ${k}`);
    }
    if (!(a.days > 0)) throw new Error("--days must be > 0");
    // Day files (hook cost, start probe) live next to the journal: --home, else the store dir, else the journal's dir.
    a.home ??= a.store ?? path.dirname(a.journal);
    return a;
}

export function pct(values, p) {
    if (!values.length) return null;
    const s = [...values].sort((x, y) => x - y);
    return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}

export function median(values) {
    if (!values.length) return null;
    const s = [...values].sort((x, y) => x - y);
    const m = s.length >> 1;
    return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const sum = (a) => a.reduce((x, y) => x + y, 0);
const maxOf = (a) => a.reduce((x, y) => (y > x ? y : x), -Infinity);

const repoOf = (o) =>
    o.repo ||
    String(o.resource ?? "")
        .split(",")[0]
        .split(":")[1] ||
    "?";

// 'build:alpha,build:machine' -> 'build:alpha'; 'deploy:alpha:web' -> 'deploy:alpha'; 'build:machine' stays.
export function queueKey(resource) {
    const first = String(resource ?? "")
        .split(",")[0]
        .trim();
    if (!first) return null;
    const p = first.split(":");
    return p.length >= 2 ? `${p[0]}:${p[1]}` : first;
}

function newRepo() {
    return {
        lands: 0,
        landFail: { conflict: 0, prePush: 0, pushRefused: 0, gate: 0, oversized: 0, finalize: 0 },
        publish: 0,
        publishRefused: 0,
        waits: { build: [], commit: [], land: [] },
        commitAcquired: 0,
        commits: 0,
        commitFailed: 0,
        pushFailed: 0,
        pushDeferred: 0,
        directPush: 0,
        branchPush: 0,
        flake: 0,
        quarantinedLands: 0,
        sharedWrites: 0,
        sharedWritesOverride: 0,
        lost: {
            incidents: 0,
            cleanExpire: 0,
            recoveredExpire: 0,
            recoveredBreak: 0,
            foreignBreakBenign: 0,
            prevented: 0,
            details: [],
        },
        readyToLandedMin: [],
        unpairedLands: 0,
    };
}

const newLandTicket = () => ({
    lands: 0,
    failures: 0,
    holds: [],
    holdFailedSec: 0,
    open: new Map(),
    pregateOk: 0,
    pregateFailed: 0,
    pregateConflict: 0,
    pregateSkipped: 0,
    gateSkippedGreen: 0,
});
const newSlots = () => ({
    lostLiveChat: 0,
    expireLiveChat: 0,
    breakLiveChat: 0,
    breakByOwnChat: 0,
    leaseBreaks: 0,
    leaseExpires: 0,
});

export async function compute(lines, { days = 7, now = null, home = null } = {}) {
    const repos = new Map();
    const R = (name) => {
        if (!repos.has(name)) repos.set(name, newRepo());
        return repos.get(name);
    };
    const queue = new Map(); // kind:repo -> [waitSec] ('acquired' only)
    const landT = new Map(); // repo -> land ticket holds + stage-0 counters
    const LT = (name) => {
        if (!landT.has(name)) landT.set(name, newLandTicket());
        return landT.get(name);
    };
    const slots = new Map(); // repo -> lease-expire / lease-break counters
    const SL = (name) => {
        if (!slots.has(name)) slots.set(name, newSlots());
        return slots.get(name);
    };
    const stats = { lines: 0, bad: 0, inWindow: 0, firstTs: null, lastTs: null };
    const all = [];
    for await (const line of lines) {
        stats.lines++;
        if (!line.trim()) continue;
        let o;
        try {
            o = JSON.parse(line);
        } catch {
            stats.bad++;
            continue;
        }
        const t = Date.parse(o?.ts);
        if (!o || typeof o.event !== "string" || Number.isNaN(t)) {
            stats.bad++;
            continue;
        }
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
        const res = String(o.resource ?? "");

        // queue waits
        if (
            (ev === "acquired" || ev === "start" || ev === "done" || ev === "fail") &&
            typeof o.waitSec === "number" &&
            res
        ) {
            const key = `${o.session}|${res}|${o.waitSec}`;
            const prev = seenWait.get(key);
            if (prev === undefined || t - prev > 864e5) {
                seenWait.set(key, t);
                for (const r of res.split(",")) {
                    const [kind, rname] = r.trim().split(":");
                    if (rname && rname !== "machine" && R(rname).waits[kind]) R(rname).waits[kind].push(o.waitSec);
                }
            }
        }
        // queue time: one 'acquired' per grant, credited to the first resource
        if (ev === "acquired" && Number.isFinite(o.waitSec) && res) {
            const key = queueKey(res);
            if (key) {
                if (!queue.has(key)) queue.set(key, []);
                queue.get(key).push(o.waitSec);
            }
        }
        // land ticket holds + stage-0 counters
        const landRes = /^land:(.+)$/.exec(res.split(",")[0].trim());
        if (ev === "acquired" && landRes) {
            const lt = LT(landRes[1]);
            const sk = String(o.session ?? "");
            lt.open.delete(sk);
            lt.open.set(sk, t); // re-insert so Map order = order of opening
        } else if (LAND_END.has(ev)) {
            const lt = LT(landRes ? landRes[1] : repo);
            if (ev === "land") lt.lands++;
            else lt.failures++;
            if (lt.open.size) {
                const sk = String(o.session ?? "");
                const key = lt.open.has(sk) ? sk : [...lt.open.keys()].pop();
                const hold = (t - lt.open.get(key)) / 1000;
                lt.holds.push(hold);
                if (ev !== "land") lt.holdFailedSec += hold;
                lt.open.delete(key);
            }
        } else if (LAND_STAGE0[ev]) LT(landRes ? landRes[1] : repo)[LAND_STAGE0[ev]]++;
        // slots lost while a chat was still alive (new optional fields: chats, chatIdleMin, byChat)
        if (ev === "lease-expire" || ev === "lease-break") {
            const sl = SL(repo);
            const live = Number.isFinite(o.chatIdleMin) && o.chatIdleMin <= TARGETS.liveChatIdleMin;
            if (ev === "lease-expire") {
                sl.leaseExpires++;
                if (live) {
                    sl.expireLiveChat++;
                    sl.lostLiveChat++;
                }
            } else {
                sl.leaseBreaks++;
                if (o.byChat === true) sl.breakByOwnChat++;
                else if (live) {
                    sl.breakLiveChat++;
                    sl.lostLiveChat++;
                }
            }
        }
        if (ev === "acquired" && res.split(",").some((r) => r.startsWith("commit:"))) R(repo).commitAcquired++;
        if (ev === "queued") {
            const kind = res.split(":")[0];
            if (kind === "land" || kind === "commit") {
                const k = `${o.session}|${repo}|${kind}`;
                if (!readyQueue.has(k)) readyQueue.set(k, []);
                readyQueue.get(k).push(t);
            }
        }
        const r = R(repo);
        switch (ev) {
            case "land":
            case "publish": {
                if (ev === "land") r.lands++;
                else r.publish++;
                const q = readyQueue.get(`${o.session}|${repo}|${ev === "land" ? "land" : "commit"}`);
                if (q && q.length) {
                    r.readyToLandedMin.push((t - q[0]) / 6e4);
                    q.length = 0;
                } else r.unpairedLands++;
                break;
            }
            case "land-push-failed":
                if (PRE_PUSH_RE.test(String(o.reason ?? ""))) r.landFail.prePush++;
                else r.landFail.pushRefused++;
                break;
            case "land-conflict":
            case "land-gate-failed":
            case "land-oversized":
            case "land-finalize-failed":
                r.landFail[LAND_FAIL[ev]]++;
                break;
            case "publish-refused":
                r.publishRefused++;
                r.lost.prevented++;
                break;
            case "commit":
                r.commits++;
                break;
            case "commit-failed":
                r.commitFailed++;
                break;
            case "push-failed":
                r.pushFailed++;
                break;
            case "push-deferred":
                r.pushDeferred++;
                break;
            case "push":
                if (INTEGRATION.has(String(o.branch))) r.directPush++;
                else r.branchPush++;
                break;
            case "flake":
                r.flake++;
                break;
            case "flake-quarantined":
                r.quarantinedLands++;
                break;
            case "shared-write":
                if (o.override) r.sharedWritesOverride++;
                else r.sharedWrites++;
                break;
            case "lease-expire":
                // Backup-Slot runs first and fails closed (lease-expire-failed); ref '' = nothing unique (clean).
                if (o.ref) r.lost.recoveredExpire++;
                else r.lost.cleanExpire++;
                break;
            case "lease-expire-failed":
                r.lost.incidents++;
                r.lost.details.push(`${o.ts} lease-expire-failed ${res}`);
                break;
            case "backup":
                if (o.pushError) {
                    r.lost.incidents++;
                    r.lost.details.push(`${o.ts} backup push failed ${res}`);
                }
                break;
            case "lease-break":
                if (o.holderSession && o.holderSession !== o.session) {
                    // unlease -Reason also backs up first and refuses on a failed backup: no ref = clean slot.
                    if (o.ref) r.lost.recoveredBreak++;
                    else r.lost.foreignBreakBenign++;
                }
                break;
            default:
                break;
        }
    }
    const win = { start, end, days };
    const hookCost = home ? await readHookCost(home, win) : null;
    const startProbe = home ? await readStartProbe(home, win) : null;
    return summarize(repos, stats, win, { queue, landT, slots, hookCost, startProbe });
}

// ---------- day files (<home>/hooks/cost-YYYYMMDD.jsonl, <home>/load/probe-YYYYMMDD.jsonl) ----------
const ymd = (t) => new Date(t).toISOString().slice(0, 10).replaceAll("-", "");

// any = at least one day file exists at all; files = those whose name is within the window (+- 1 day).
export function dayFiles(dir, prefix, { start, end }) {
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch {
        return { any: false, files: [] };
    }
    const re = new RegExp(`^${prefix}-(\\d{8})\\.jsonl$`);
    const all = names
        .map((n) => re.exec(n))
        .filter(Boolean)
        .map((m) => ({ day: m[1], file: path.join(dir, m[0]) }));
    all.sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
    const lo = ymd(start - 864e5),
        hi = ymd(end + 864e5);
    return { any: all.length > 0, files: all.filter((x) => x.day >= lo && x.day <= hi).map((x) => x.file) };
}

async function* chainFiles(files) {
    for (const f of files) yield* fileLines(f);
}

function parseDayLine(line) {
    const s = line.replace(/^\uFEFF/, "");
    if (!s.trim()) return null;
    let o;
    try {
        o = JSON.parse(s);
    } catch {
        return { bad: true };
    }
    const t = Date.parse(o?.ts);
    if (!o || typeof o !== "object" || Number.isNaN(t) || !Number.isFinite(o.ms) || o.ms < 0) return { bad: true };
    return { t, o };
}

export async function computeHookCost(lines, { start, end }) {
    const byDay = new Map(); // YYYY-MM-DD (UTC) -> { cost: [], startMs: [], denies }
    let badLines = 0;
    for await (const line of lines) {
        const p = parseDayLine(line);
        if (!p) continue;
        if (p.bad) {
            badLines++;
            continue;
        }
        if (p.t < start || p.t > end) continue;
        const day = new Date(p.t).toISOString().slice(0, 10);
        if (!byDay.has(day)) byDay.set(day, { cost: [], startMs: [], denies: 0 });
        const d = byDay.get(day);
        const hasStart = Number.isFinite(p.o.startMs) && p.o.startMs >= 0;
        d.cost.push(p.o.ms + (hasStart ? p.o.startMs : 0));
        if (hasStart) d.startMs.push(p.o.startMs);
        if (p.o.deny === true) d.denies++;
    }
    const row = (cost, startMs, denies) => ({
        calls: cost.length,
        totalHours: sum(cost) / 3.6e6,
        p50Ms: pct(cost, 50),
        p90Ms: pct(cost, 90),
        startP50Ms: pct(startMs, 50),
        denies,
    });
    const days = [...byDay]
        .sort((a, b) => (a[0] < b[0] ? -1 : 1))
        .map(([day, d]) => ({ day, ...row(d.cost, d.startMs, d.denies) }));
    const all = row(
        [...byDay.values()].flatMap((d) => d.cost),
        [...byDay.values()].flatMap((d) => d.startMs),
        sum([...byDay.values()].map((d) => d.denies)),
    );
    return {
        days,
        calls: all.calls,
        totalHours: all.totalHours,
        hoursPerDay: days.length ? all.totalHours / days.length : null,
        p50Ms: all.p50Ms,
        p90Ms: all.p90Ms,
        startP50Ms: all.startP50Ms,
        denies: all.denies,
        badLines,
    };
}

export async function computeStartProbe(lines, { start, end }) {
    const buckets = new Map(); // floor(t / 5 min) -> [ms]
    const samples = [];
    let badLines = 0;
    for await (const line of lines) {
        const p = parseDayLine(line);
        if (!p) continue;
        if (p.bad) {
            badLines++;
            continue;
        }
        if (p.t < start || p.t > end) continue;
        const b = Math.floor(p.t / PROBE_BUCKET_MS);
        if (!buckets.has(b)) buckets.set(b, []);
        buckets.get(b).push(p.o.ms);
        samples.push(p.o.ms);
    }
    let under = 0,
        worst = null;
    for (const [b, ms] of [...buckets].sort((x, y) => x[0] - y[0])) {
        const med = median(ms);
        if (med < TARGETS.startProbeBucketMs) under++;
        if (!worst || med > worst.medianMs)
            worst = { at: new Date(b * PROBE_BUCKET_MS).toISOString(), medianMs: med, n: ms.length };
    }
    return {
        samples: samples.length,
        buckets: buckets.size,
        bucketsUnder500: under,
        underPct: buckets.size ? (100 * under) / buckets.size : null,
        p50Ms: pct(samples, 50),
        p90Ms: pct(samples, 90),
        worstBucket: worst,
        badLines,
    };
}

// null = the hook does not log yet (no cost-*.jsonl at all).
export async function readHookCost(home, win) {
    const { any, files } = dayFiles(path.join(home, "hooks"), "cost", win);
    return any ? computeHookCost(chainFiles(files), win) : null;
}

export async function readStartProbe(home, win) {
    const { any, files } = dayFiles(path.join(home, "load"), "probe", win);
    return any ? computeStartProbe(chainFiles(files), win) : null;
}

function summarizeRepo(r) {
    const failures = Object.values(r.landFail).reduce((a, b) => a + b, 0);
    const attempts = r.lands + failures;
    const q = (arr) => ({ n: arr.length, p50: pct(arr, 50), p90: pct(arr, 90) });
    const integ = r.directPush + r.lands + r.publish;
    return {
        landing: {
            lands: r.lands,
            failures,
            failByCause: r.landFail,
            failureRate: attempts ? failures / attempts : null,
            publish: r.publish,
            publishRefused: r.publishRefused,
        },
        queueWaitSec: { build: q(r.waits.build), commit: q(r.waits.commit), land: q(r.waits.land) },
        commitPath: {
            acquired: r.commitAcquired,
            commits: r.commits,
            commitFailed: r.commitFailed,
            pushFailed: r.pushFailed,
            pushDeferred: r.pushDeferred,
        },
        bypass: {
            directPushIntegration: r.directPush,
            pushTopicBranch: r.branchPush,
            share: integ ? r.directPush / integ : null,
            sharedCloneWrites: r.sharedWrites,
            sharedCloneOverrides: r.sharedWritesOverride,
        },
        flake: {
            flakes: r.flake,
            quarantinedLands: r.quarantinedLands,
            shareOfPushFailures:
                r.flake + r.landFail.prePush + r.landFail.pushRefused
                    ? r.flake / (r.flake + r.landFail.prePush + r.landFail.pushRefused)
                    : null,
            rate: attempts ? r.flake / attempts : null,
        },
        lostWork: {
            incidents: r.lost.incidents,
            recoveredExpire: r.lost.recoveredExpire,
            recoveredBreak: r.lost.recoveredBreak,
            foreignBreakBenign: r.lost.foreignBreakBenign,
            prevented: r.lost.prevented,
            details: r.lost.details.slice(0, 20),
        },
        readyToLandedMin: {
            n: r.readyToLandedMin.length,
            p50: pct(r.readyToLandedMin, 50),
            p90: pct(r.readyToLandedMin, 90),
            unpaired: r.unpairedLands,
        },
        _raw: r,
    };
}

function summarizeQueue(queue, days) {
    const byResource = [...queue]
        .map(([resource, w]) => ({
            resource,
            n: w.length,
            p50: pct(w, 50),
            p90: pct(w, 90),
            max: maxOf(w),
            totalSec: sum(w),
            over10min: w.filter((x) => x > LONG_WAIT_SEC).length,
        }))
        .sort((a, b) => b.totalSec - a.totalSec || (a.resource < b.resource ? -1 : 1));
    const totalHours = sum(byResource.map((x) => x.totalSec)) / 3600;
    return {
        totalHours,
        hoursPerDay: totalHours / days,
        over10min: sum(byResource.map((x) => x.over10min)),
        waits: sum(byResource.map((x) => x.n)),
        byResource,
    };
}

function summarizeLandTicket(landT) {
    const byRepo = {};
    for (const [name, lt] of [...landT].sort()) {
        byRepo[name] = {
            lands: lt.lands,
            failures: lt.failures,
            holds: lt.holds.length,
            holdTotalSec: sum(lt.holds),
            holdP50: pct(lt.holds, 50),
            holdP90: pct(lt.holds, 90),
            under60s: lt.holds.filter((x) => x < SHORT_HOLD_SEC).length,
            holdFailedSec: lt.holdFailedSec,
            pregateOk: lt.pregateOk,
            pregateFailed: lt.pregateFailed,
            pregateConflict: lt.pregateConflict,
            pregateSkipped: lt.pregateSkipped,
            gateSkippedGreen: lt.gateSkippedGreen,
        };
    }
    return { byRepo };
}

function summarizeSlots(slots) {
    const tot = newSlots();
    const byRepo = {};
    for (const [name, s] of [...slots].sort()) {
        byRepo[name] = { ...s };
        for (const k of Object.keys(tot)) tot[k] += s[k];
    }
    return { ...tot, byRepo };
}

function summarize(repos, stats, win, extra) {
    const tot = newRepo();
    for (const r of repos.values()) {
        tot.lands += r.lands;
        tot.publish += r.publish;
        tot.publishRefused += r.publishRefused;
        for (const k of Object.keys(tot.landFail)) tot.landFail[k] += r.landFail[k];
        for (const k of Object.keys(tot.waits)) tot.waits[k].push(...r.waits[k]);
        for (const k of [
            "commitAcquired",
            "commits",
            "commitFailed",
            "pushFailed",
            "pushDeferred",
            "directPush",
            "branchPush",
            "flake",
            "quarantinedLands",
            "sharedWrites",
            "sharedWritesOverride",
            "unpairedLands",
        ])
            tot[k] += r[k];
        for (const k of ["incidents", "recoveredExpire", "recoveredBreak", "foreignBreakBenign", "prevented"])
            tot.lost[k] += r.lost[k];
        tot.lost.details.push(...r.lost.details);
        tot.readyToLandedMin.push(...r.readyToLandedMin);
    }
    const byRepo = {};
    for (const [name, r] of [...repos].sort()) {
        const s = summarizeRepo(r);
        const active =
            s.landing.lands +
            s.landing.failures +
            s.landing.publish +
            s.commitPath.commits +
            s.commitPath.acquired +
            s.queueWaitSec.build.n +
            s.lostWork.incidents +
            s.lostWork.recoveredExpire +
            s.lostWork.recoveredBreak +
            s.bypass.sharedCloneWrites +
            s.bypass.sharedCloneOverrides;
        if (active) {
            delete s._raw;
            byRepo[name] = s;
        }
    }
    const overall = summarizeRepo(tot);
    delete overall._raw;
    const v = (ok, value, target) => ({ verdict: value === null ? "NO DATA" : ok ? "PASS" : "FAIL", value, target });
    const rtl = overall.readyToLandedMin.p90;
    const fr = overall.flake.rate === null ? null : overall.flake.rate * 100;
    const queueTime = summarizeQueue(extra.queue, win.days);
    const landTicket = summarizeLandTicket(extra.landT);
    const slots = summarizeSlots(extra.slots);
    const { hookCost, startProbe } = extra;
    const probePct = startProbe && startProbe.buckets ? startProbe.underPct : null;
    const slo = {
        readyToLandedP90Min: v(
            rtl !== null && rtl < TARGETS.readyToLandedP90Min,
            rtl,
            `< ${TARGETS.readyToLandedP90Min}`,
        ),
        flakeRatePct: v(fr !== null && fr < TARGETS.flakeRatePct, fr, `< ${TARGETS.flakeRatePct}`),
        lostWorkIncidents: v(
            overall.lostWork.incidents === TARGETS.lostWork,
            overall.lostWork.incidents,
            `= ${TARGETS.lostWork}`,
        ),
        startProbeBucketsPct: v(
            probePct !== null && probePct >= TARGETS.startProbeBucketsPct,
            probePct,
            `>= ${TARGETS.startProbeBucketsPct}`,
        ),
        slotsLostLiveChat: v(
            slots.lostLiveChat === TARGETS.slotsLostLiveChat,
            slots.lostLiveChat,
            `= ${TARGETS.slotsLostLiveChat}`,
        ),
    };
    const busiest = queueTime.byResource[0];
    // The block the owner compares week over week.
    const baseline = {
        queueWaitHours: queueTime.totalHours,
        waitsOver10min: queueTime.over10min,
        busiestQueue: busiest ? { resource: busiest.resource, hours: busiest.totalSec / 3600 } : null,
        landFailureRate: overall.landing.failureRate,
        leaseBreaks: slots.leaseBreaks,
        leaseExpires: slots.leaseExpires,
        sharedCloneWrites: overall.bypass.sharedCloneWrites,
        sharedCloneOverrides: overall.bypass.sharedCloneOverrides,
        hookCostHoursPerDay: hookCost ? hookCost.hoursPerDay : null,
    };
    return {
        generatedAt: new Date().toISOString(),
        window: { days: win.days, from: new Date(win.start).toISOString(), to: new Date(win.end).toISOString() },
        journal: { lines: stats.lines, badLines: stats.bad, eventsInWindow: stats.inWindow },
        slo,
        overall,
        byRepo,
        baseline,
        queueTime,
        landTicket,
        slots,
        hookCost,
        startProbe,
    };
}

// ---------- human output ----------
const f1 = (x) => (x === null || x === undefined ? "-" : Number.isInteger(x) ? String(x) : x.toFixed(1));
const fp = (x) => (x === null || x === undefined ? "-" : `${(x * 100).toFixed(1)}%`);
const fm = (s) => (s === null || s === undefined ? "-" : s < 60 ? `${s.toFixed(0)}s` : `${(s / 60).toFixed(1)}m`);
const fd = (s) => (s === null || s === undefined ? "-" : s < 3600 ? fm(s) : `${(s / 3600).toFixed(1)}h`);
const fh = (h, digits = 1) => (h === null || h === undefined ? "-" : h.toFixed(digits));
const f0 = (x) => (x === null || x === undefined ? "-" : String(Math.round(x)));
const TOP_QUEUES = 8;
function table(head, rows) {
    const w = head.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
    const line = (r) => r.map((c, i) => (i === 0 ? String(c).padEnd(w[i]) : String(c).padStart(w[i]))).join("  ");
    return [line(head), w.map((n) => "-".repeat(n)).join("  "), ...rows.map(line)].join("\n");
}
export function render(rep) {
    const rows = (fn) => [...Object.entries(rep.byRepo).map(([n, s]) => fn(n, s)), fn("ALL", rep.overall)];
    const out = [];
    out.push(
        `agentq SLO — ${rep.window.days} d window ${rep.window.from.slice(0, 16)}Z .. ${rep.window.to.slice(0, 16)}Z`,
    );
    out.push(
        `journal: ${rep.journal.lines} lines, ${rep.journal.badLines} bad, ${rep.journal.eventsInWindow} in window\n`,
    );
    const b = rep.baseline,
        qt = rep.queueTime,
        hc = rep.hookCost,
        sp = rep.startProbe,
        sl = rep.slots;
    out.push("BASELINE NUMBERS (compare week over week)");
    const base = [
        ["queue wait total", `${fh(b.queueWaitHours)} h (${fh(qt.hoursPerDay)} h/day)`],
        ["waits over 10 min", b.waitsOver10min],
        ["busiest queue", b.busiestQueue ? `${b.busiestQueue.resource} ${fh(b.busiestQueue.hours)} h` : "-"],
        [
            "land failure rate",
            `${fp(b.landFailureRate)} (${rep.overall.landing.failures} of ${rep.overall.landing.lands + rep.overall.landing.failures})`,
        ],
        ["lease-break / lease-expire", `${b.leaseBreaks} / ${b.leaseExpires}`],
        ["shared clone writes", `${b.sharedCloneWrites} (+${b.sharedCloneOverrides} overrides)`],
        ["hook cost", b.hookCostHoursPerDay === null ? "-" : `${fh(b.hookCostHoursPerDay, 2)} h/day`],
    ];
    for (const [k, val] of base) out.push(`  ${k.padEnd(28)}${val}`);
    out.push("");
    out.push("SLO");
    out.push(
        table(
            ["target", "value", "goal", "verdict"],
            Object.entries(rep.slo).map(([k, s]) => [k, f1(s.value), s.target, s.verdict]),
        ),
    );
    out.push("\nLANDING");
    out.push(
        table(
            [
                "repo",
                "lands",
                "fail",
                "conflict",
                "prePush",
                "pushRef",
                "gate",
                "oversz",
                "final",
                "failRate",
                "publish",
                "pubRef",
            ],
            rows((n, s) => [
                n,
                s.landing.lands,
                s.landing.failures,
                s.landing.failByCause.conflict,
                s.landing.failByCause.prePush,
                s.landing.failByCause.pushRefused,
                s.landing.failByCause.gate,
                s.landing.failByCause.oversized,
                s.landing.failByCause.finalize,
                fp(s.landing.failureRate),
                s.landing.publish,
                s.landing.publishRefused,
            ]),
        ),
    );
    out.push("\nQUEUE WAIT (p50 / p90, n)");
    out.push(
        table(
            ["repo", "build", "commit", "land"],
            rows((n, s) => [
                n,
                ...["build", "commit", "land"].map((k) => {
                    const q = s.queueWaitSec[k];
                    return q.n ? `${fm(q.p50)}/${fm(q.p90)} n${q.n}` : "-";
                }),
            ]),
        ),
    );
    out.push("\nQUEUE TIME (acquired events only, wait credited to the first resource)");
    out.push(
        `total ${fh(qt.totalHours)} h in ${rep.window.days} d = ${fh(qt.hoursPerDay)} h/day; ${qt.waits} waits, ${qt.over10min} over 10 min`,
    );
    if (qt.byResource.length) {
        out.push(
            table(
                ["resource", "n", "p50", "p90", "max", "total", ">10min"],
                qt.byResource
                    .slice(0, TOP_QUEUES)
                    .map((q) => [q.resource, q.n, fd(q.p50), fd(q.p90), fd(q.max), fd(q.totalSec), q.over10min]),
            ),
        );
        if (qt.byResource.length > TOP_QUEUES)
            out.push(`  (+${qt.byResource.length - TOP_QUEUES} more resources in --json)`);
    }
    out.push("\nLAND TICKET (hold = acquired land:<repo> .. land or land failure)");
    const lt = Object.entries(rep.landTicket.byRepo);
    if (lt.length) {
        out.push(
            table(
                [
                    "repo",
                    "lands",
                    "fail",
                    "holds",
                    "holdSum",
                    "p50",
                    "p90",
                    "<60s",
                    "failHold",
                    "preOk",
                    "preFail",
                    "preConf",
                    "preSkip",
                    "skipGreen",
                ],
                lt.map(([n, s]) => [
                    n,
                    s.lands,
                    s.failures,
                    s.holds,
                    fd(s.holdTotalSec),
                    fd(s.holdP50),
                    fd(s.holdP90),
                    s.under60s,
                    fd(s.holdFailedSec),
                    s.pregateOk,
                    s.pregateFailed,
                    s.pregateConflict,
                    s.pregateSkipped,
                    s.gateSkippedGreen,
                ]),
            ),
        );
    } else out.push("no land events");
    out.push("\nCOMMIT PATH / BYPASS / FLAKE / READY->LANDED");
    out.push(
        table(
            [
                "repo",
                "acq",
                "commit",
                "cFail",
                "pFail",
                "pDefer",
                "direct",
                "topic",
                "bypass",
                "flake",
                "flkRate",
                "r2l p50",
                "r2l p90",
                "r2l n",
            ],
            rows((n, s) => [
                n,
                s.commitPath.acquired,
                s.commitPath.commits,
                s.commitPath.commitFailed,
                s.commitPath.pushFailed,
                s.commitPath.pushDeferred,
                s.bypass.directPushIntegration,
                s.bypass.pushTopicBranch,
                fp(s.bypass.share),
                s.flake.flakes,
                fp(s.flake.rate),
                f1(s.readyToLandedMin.p50),
                f1(s.readyToLandedMin.p90),
                s.readyToLandedMin.n,
            ]),
        ),
    );
    out.push("\nSHARED CLONE WRITES (ADR 0004: refuse after 7 days of warn)");
    out.push(
        table(
            ["repo", "writes", "overrides"],
            rows((n, s) => [n, s.bypass.sharedCloneWrites, s.bypass.sharedCloneOverrides]),
        ),
    );
    out.push("\nLOST WORK");
    out.push(
        table(
            ["repo", "incidents", "recovExpire", "recovBreak", "benignBreak", "prevented"],
            rows((n, s) => [
                n,
                s.lostWork.incidents,
                s.lostWork.recoveredExpire,
                s.lostWork.recoveredBreak,
                s.lostWork.foreignBreakBenign,
                s.lostWork.prevented,
            ]),
        ),
    );
    for (const d of rep.overall.lostWork.details.slice(0, 10)) out.push(`  ! ${d}`);
    out.push(
        `\nSLOTS LOST WITH A LIVE CHAT (chat idle <= ${TARGETS.liveChatIdleMin} min; lease-break ${sl.leaseBreaks}, lease-expire ${sl.leaseExpires} in window)`,
    );
    out.push(
        table(
            ["repo", "lost", "expireLive", "breakLive", "ownChatBreak", "breaks", "expires"],
            [...Object.entries(sl.byRepo), ["ALL", sl]].map(([n, s]) => [
                n,
                s.lostLiveChat,
                s.expireLiveChat,
                s.breakLiveChat,
                s.breakByOwnChat,
                s.leaseBreaks,
                s.leaseExpires,
            ]),
        ),
    );
    out.push("\nHOOK COST (per call: script ms + process start ms)");
    if (!hc) out.push("no hook cost data (the hook does not log yet)");
    else if (!hc.calls) out.push(`no hook cost samples in the window (${hc.badLines} bad lines)`);
    else {
        out.push(
            table(
                ["day", "calls", "hours", "p50 ms", "p90 ms", "start p50", "denies"],
                [...hc.days.map((d) => [d.day, d]), ["ALL", hc]].map(([n, d]) => [
                    n,
                    d.calls,
                    fh(d.totalHours, 2),
                    f0(d.p50Ms),
                    f0(d.p90Ms),
                    f0(d.startP50Ms),
                    d.denies,
                ]),
            ),
        );
        out.push(`${fh(hc.hoursPerDay, 2)} h/day over ${hc.days.length} day(s) with data; ${hc.badLines} bad lines`);
    }
    out.push(
        `\nSTART PROBE (5-minute buckets, bucket = median start latency, good < ${TARGETS.startProbeBucketMs} ms)`,
    );
    if (!sp || !sp.buckets)
        out.push(sp ? `no start probe samples in the window (${sp.badLines} bad lines)` : "no start probe data");
    else {
        out.push(
            `${sp.buckets} buckets, ${sp.bucketsUnder500} under ${TARGETS.startProbeBucketMs} ms = ${f1(sp.underPct)}%; ${sp.samples} samples p50 ${f0(sp.p50Ms)} ms p90 ${f0(sp.p90Ms)} ms; ${sp.badLines} bad lines`,
        );
        out.push(
            `worst bucket ${sp.worstBucket.at.slice(0, 16)}Z median ${f0(sp.worstBucket.medianMs)} ms (n ${sp.worstBucket.n})`,
        );
    }
    return out.join("\n");
}

export async function* fileLines(p) {
    const rl = readline.createInterface({ input: fs.createReadStream(p, { encoding: "utf8" }), crlfDelay: Infinity });
    for await (const l of rl) yield l;
}

async function main() {
    const a = parseArgs(process.argv.slice(2));
    if (a.help) {
        console.log(
            [
                "node agentq-slo.mjs [--days 7] [--json] [--journal <path> | --store <coord dir>] [--home <coord dir>] [--now <ISO>]",
                "  --journal <path>   journal file (default ~/.codai/coord/journal.jsonl)",
                "  --store <dir>      read the window from the SQLite store in <dir> (falls back to --journal)",
                "  --home <dir>       coord dir holding the day files hooks/cost-YYYYMMDD.jsonl and load/probe-YYYYMMDD.jsonl",
                "                     (default: --store dir when given, else the directory of --journal)",
                "  exit 1 when any SLO row is FAIL",
            ].join("\n"),
        );
        return;
    }
    let lines = null;
    // ADR 0006: read the window from the SQLite store (covers rotated journals too); fall back to the file.
    if (a.store) {
        try {
            const st = await import("./agentq-store.mjs");
            st.sync(a.store);
            lines = st.windowLines(a.store, a.days + 1, a.now);
        } catch (e) {
            console.error(`agentq-slo: store unavailable (${e.message}), reading the journal file`);
            lines = null;
        }
    }
    if (!lines && !fs.existsSync(a.journal)) {
        console.error(`journal not found: ${a.journal}`);
        process.exit(2);
    }
    const rep = await compute(lines ?? fileLines(a.journal), { days: a.days, now: a.now, home: a.home });
    console.log(a.json ? JSON.stringify(rep, null, 2) : render(rep));
    process.exitCode = Object.values(rep.slo).some((s) => s.verdict === "FAIL") ? 1 : 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href)
    main().catch((e) => {
        console.error(e.message);
        process.exit(2);
    });
