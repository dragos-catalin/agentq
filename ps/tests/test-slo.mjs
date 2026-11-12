// Self-test for agentq-slo.mjs: synthetic journal, asserts every computed number.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { compute, render, pct, median, queueKey, parseArgs, TARGETS } from "../bin/agentq-slo.mjs";

const T = (hm) => `2026-10-18T${hm}:00.000Z`;
const TS = (hms) => `2026-10-18T${hms}.000Z`;
const j = (o) => JSON.stringify(o);
const lines = [
    j({ ts: "2026-09-01T00:00:00Z", event: "land", repo: "r", resource: "land:r", session: "OLD" }), // outside window
    j({ ts: T("00:00"), event: "queued", repo: "r", resource: "land:r", session: "A", ticket: "t1" }),
    j({ ts: T("00:01"), event: "acquired", resource: "land:r", session: "A", tickets: ["t1"], waitSec: 60 }),
    j({ ts: T("00:30"), event: "land", repo: "r", resource: "land:r", session: "A", branch: "main" }),
    j({ ts: T("01:00"), event: "queued", repo: "r", resource: "land:r", session: "B", ticket: "t2" }),
    j({ ts: T("01:05"), event: "land-conflict", repo: "r", resource: "land:r", session: "B" }),
    j({ ts: T("01:10"), event: "queued", repo: "r", resource: "land:r", session: "B", ticket: "t3" }),
    j({ ts: T("01:50"), event: "flake", repo: "r", resource: "land:r", session: "B", exit: 7 }),
    j({ ts: T("02:00"), event: "land", repo: "r", resource: "land:r", session: "B", branch: "main" }),
    j({ ts: T("02:10"), event: "land-push-failed", repo: "r", resource: "land:r", session: "C", exit: 7 }),
    j({
        ts: T("02:11"),
        event: "land-push-failed",
        repo: "r",
        resource: "land:r",
        session: "C",
        exit: 7,
        reason: "FAIL src/x.test.ts | husky - pre-push script failed",
    }),
    j({
        ts: T("02:12"),
        event: "land-finalize-failed",
        repo: "r",
        resource: "land:r",
        session: "C",
        exit: 2,
        reason: "fragment invalid",
    }),
    j({ ts: T("02:20"), event: "acquired", resource: "commit:r", session: "C", tickets: ["t4"], waitSec: 10 }),
    j({ ts: T("02:21"), event: "commit", repo: "r", resource: "commit:r", session: "C", sha: "abc" }),
    j({ ts: T("02:22"), event: "commit-failed", repo: "r", resource: "commit:r", session: "C" }),
    j({ ts: T("02:23"), event: "push", repo: "r", resource: "commit:r", session: "C", branch: "main" }),
    j({ ts: T("02:24"), event: "push", repo: "r", resource: "commit:r", session: "C", branch: "feat/x" }),
    j({
        ts: T("03:00"),
        event: "lease-expire",
        repo: "r",
        resource: "slot:r:task-1",
        holderSession: "X",
        session: "S",
        ref: "refs/backup/wt/r/task-1/1",
    }),
    j({
        ts: T("03:01"),
        event: "lease-expire",
        repo: "r",
        resource: "slot:r:task-2",
        holderSession: "X",
        session: "S",
        ref: "",
    }),
    j({
        ts: T("03:02"),
        event: "lease-break",
        repo: "r",
        resource: "slot:r:task-3",
        holderSession: "X",
        session: "Y",
        ref: "",
        reason: "stuck",
    }),
    j({
        ts: T("03:03"),
        event: "lease-expire-failed",
        repo: "r",
        resource: "slot:r:task-4",
        reason: "backup could not be proven",
    }),
    j({
        ts: T("03:04"),
        event: "backup",
        repo: "r",
        resource: "slot:r:task-5",
        ref: "refs/backup/wt/r/task-5/1",
        pushError: "network",
    }),
    j({ ts: T("03:03"), event: "publish-refused", repo: "r", resource: "commit:r", session: "Y" }),
    j({
        ts: T("04:00"),
        event: "done",
        repo: "s",
        resource: "build:s,build:machine",
        session: "D",
        waitSec: 120,
        exit: 0,
    }),
    j({
        ts: T("04:00"),
        event: "fail",
        repo: "s",
        resource: "build:s,build:machine",
        session: "D",
        waitSec: 120,
        exit: 1,
    }), // same grant -> deduped
    "{not json",
];
async function* gen() {
    for (const l of lines) yield l;
}

const rep = await compute(gen(), { days: 7, now: T("12:00") });
const r = rep.byRepo.r,
    s = rep.byRepo.s,
    o = rep.overall;

assert.equal(rep.journal.lines, 26);
assert.equal(rep.journal.badLines, 1);
assert.equal(rep.journal.eventsInWindow, 24);
// landing
assert.equal(r.landing.lands, 2);
assert.deepEqual(r.landing.failByCause, {
    conflict: 1,
    prePush: 1,
    pushRefused: 1,
    gate: 0,
    oversized: 0,
    finalize: 1,
});
assert.equal(r.landing.failureRate, 4 / 6);
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
assert.equal(r.flake.rate, 1 / 6);
assert.equal(r.flake.shareOfPushFailures, 1 / 3);
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
assert.equal(rep.slo.readyToLandedP90Min.verdict, "FAIL");
assert.ok(Math.abs(rep.slo.flakeRatePct.value - 100 / 6) < 1e-9);
assert.equal(rep.slo.flakeRatePct.verdict, "FAIL");
assert.equal(rep.slo.lostWorkIncidents.verdict, "FAIL");
// new sections on the same journal: only the two 'acquired' lines count as queue time (done/fail do not)
assert.deepEqual(rep.queueTime.byResource, [
    { resource: "land:r", n: 1, p50: 60, p90: 60, max: 60, totalSec: 60, over10min: 0 },
    { resource: "commit:r", n: 1, p50: 10, p90: 10, max: 10, totalSec: 10, over10min: 0 },
]);
assert.equal(rep.queueTime.totalHours, 70 / 3600);
assert.equal(rep.queueTime.over10min, 0);
// land ticket: one hold (A: 00:01 -> 00:30 = 1740 s); the other lands / failures had no open hold
assert.deepEqual(rep.landTicket.byRepo.r, {
    lands: 2,
    failures: 4,
    holds: 1,
    holdTotalSec: 1740,
    holdP50: 1740,
    holdP90: 1740,
    under60s: 0,
    holdFailedSec: 0,
    pregateOk: 0,
    pregateFailed: 0,
    pregateConflict: 0,
    pregateSkipped: 0,
    gateSkippedGreen: 0,
});
// older journal lines (no chat fields) are neither lost-with-live-chat nor own-chat breaks
assert.deepEqual(rep.slots.byRepo.r, {
    lostLiveChat: 0,
    expireLiveChat: 0,
    breakLiveChat: 0,
    breakByOwnChat: 0,
    leaseBreaks: 1,
    leaseExpires: 2,
});
assert.deepEqual(rep.slo.slotsLostLiveChat, { verdict: "PASS", value: 0, target: "= 0" });
// no --home: no day files
assert.equal(rep.hookCost, null);
assert.equal(rep.startProbe, null);
assert.deepEqual(rep.slo.startProbeBucketsPct, { verdict: "NO DATA", value: null, target: ">= 95" });
assert.equal(rep.baseline.hookCostHoursPerDay, null);
assert.deepEqual(Object.keys(rep.slo), [
    "readyToLandedP90Min",
    "flakeRatePct",
    "lostWorkIncidents",
    "startProbeBucketsPct",
    "slotsLostLiveChat",
]);
assert.equal(TARGETS.startProbeBucketMs, 500);
assert.equal(TARGETS.startProbeBucketsPct, 95);
assert.equal(TARGETS.slotsLostLiveChat, 0);
// helpers
assert.equal(pct([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), 9);
assert.equal(pct([], 50), null);
assert.equal(median([3, 1, 2]), 2);
assert.equal(median([400, 600]), 500);
assert.equal(median([]), null);
assert.equal(queueKey("build:alpha,build:machine"), "build:alpha");
assert.equal(queueKey("deploy:alpha:web"), "deploy:alpha");
assert.equal(queueKey("build:machine"), "build:machine");
assert.equal(queueKey(""), null);
assert.deepEqual(parseArgs(["--days", "3", "--json"]).days, 3);
assert.throws(() => parseArgs(["--bogus"]));
const jp = path.join("x", "y", "journal.jsonl");
assert.equal(parseArgs(["--journal", jp]).home, path.join("x", "y"));
assert.equal(parseArgs(["--store", "st"]).home, "st");
assert.equal(parseArgs(["--store", "st", "--home", "hh"]).home, "hh");
assert.equal(parseArgs(["--home", "hh", "--journal", jp]).home, "hh");
// a clean window passes
async function* ok() {
    yield j({ ts: T("01:00"), event: "queued", repo: "q", resource: "land:q", session: "Z" });
    yield j({ ts: T("01:10"), event: "land", repo: "q", resource: "land:q", session: "Z" });
}
const good = await compute(ok(), { days: 1, now: T("12:00") });
// two new SLO rows: no probe data without a home dir, and zero slots lost
assert.deepEqual(
    Object.values(good.slo).map((x) => x.verdict),
    ["PASS", "PASS", "PASS", "NO DATA", "PASS"],
);

const txt = render(rep);
assert.match(txt, /LANDING/);
assert.match(txt, /readyToLandedP90Min\s+60\s+< 45\s+FAIL/);
assert.match(txt, /startProbeBucketsPct\s+-\s+>= 95\s+NO DATA/);
assert.match(txt, /slotsLostLiveChat\s+0\s+= 0\s+PASS/);
assert.match(txt, /no hook cost data \(the hook does not log yet\)/);
assert.match(txt, /no start probe data/);
assert.match(txt, /hook cost\s+-\n/);
console.log(txt);

// ---------- second journal: queue time, land ticket, slots lost with a live chat ----------
const lines2 = [
    // queue time: only 'acquired' with a numeric waitSec, credited to the first resource, key kind:repo
    j({ ts: "2026-10-01T00:00:00Z", event: "acquired", resource: "build:alpha", session: "Q0", waitSec: 5000 }), // outside window
    j({ ts: TS("00:00:00"), event: "acquired", resource: "build:alpha,build:machine", session: "Q1", waitSec: 700 }),
    j({ ts: TS("00:01:00"), event: "acquired", resource: "build:alpha,build:machine", session: "Q2", waitSec: 100 }),
    j({ ts: TS("00:02:00"), event: "acquired", resource: "build:alpha", session: "Q3", waitSec: 601 }),
    j({ ts: TS("00:03:00"), event: "acquired", resource: "build:machine", session: "Q4", waitSec: 600 }), // exactly 10 min: not "over"
    j({ ts: TS("00:04:00"), event: "acquired", resource: "deploy:alpha:web", session: "Q5", waitSec: 3600 }),
    j({ ts: TS("00:05:00"), event: "acquired", resource: "commit:beta", session: "Q6", waitSec: 5 }),
    j({ ts: TS("00:06:00"), event: "acquired", resource: "commit:beta", session: "Q7" }), // no waitSec
    j({ ts: TS("00:07:00"), event: "acquired", resource: "commit:beta", session: "Q8", waitSec: "30" }), // not numeric
    j({ ts: TS("00:08:00"), event: "start", resource: "build:alpha", session: "Q9", waitSec: 9999 }), // not 'acquired'
    // land ticket alpha
    j({ ts: TS("00:59:00"), event: "land-pregate-ok", repo: "alpha", resource: "land:alpha", session: "L1" }),
    j({ ts: TS("00:59:10"), event: "land-pregate-ok", repo: "alpha", session: "L2" }), // no resource: falls back to repo
    j({ ts: TS("00:59:20"), event: "land-pregate-failed", repo: "alpha", resource: "land:alpha", session: "L9" }),
    j({ ts: TS("00:59:30"), event: "land-pregate-conflict", repo: "alpha", resource: "land:alpha", session: "L9" }),
    j({ ts: TS("00:59:40"), event: "land-pregate-skipped", repo: "alpha", resource: "land:alpha", session: "L9" }),
    j({ ts: TS("01:00:00"), event: "acquired", resource: "land:alpha", session: "L1", waitSec: 1200 }),
    j({ ts: TS("01:00:20"), event: "land-gate-skipped-green", repo: "alpha", resource: "land:alpha", session: "L1" }),
    j({ ts: TS("01:00:50"), event: "land", repo: "alpha", resource: "land:alpha", session: "L1" }), // hold 50 s
    j({ ts: TS("01:10:00"), event: "acquired", resource: "land:alpha", session: "L2", waitSec: 61 }),
    j({ ts: TS("01:20:00"), event: "land-gate-failed", repo: "alpha", resource: "land:alpha", session: "L2" }), // hold 600 s, failed
    j({ ts: TS("01:30:00"), event: "acquired", resource: "land:alpha", session: "BATCH", waitSec: 0 }),
    j({
        ts: TS("01:30:10"),
        event: "land-gate-skipped-green",
        repo: "alpha",
        resource: "land:alpha",
        session: "BATCH",
    }),
    j({ ts: TS("01:35:00"), event: "land", repo: "alpha", resource: "land:alpha", session: "T1" }), // topic session: closes BATCH, 300 s
    j({ ts: TS("01:36:00"), event: "land", repo: "alpha", resource: "land:alpha", session: "T2" }), // nothing open: a land, no hold
    j({ ts: TS("01:40:00"), event: "acquired", resource: "land:alpha", session: "L3", waitSec: 10 }),
    j({ ts: TS("01:41:00"), event: "acquired", resource: "land:alpha", session: "L4", waitSec: 20 }),
    j({ ts: TS("01:50:00"), event: "land-conflict", repo: "alpha", resource: "land:alpha", session: "ZZ" }), // closes the most recently opened (L4): 540 s
    j({ ts: TS("01:55:00"), event: "land-gate-skipped-green", repo: "alpha", resource: "land:alpha", session: "L3" }),
    j({ ts: TS("02:00:00"), event: "land", repo: "alpha", resource: "land:alpha", session: "L3" }), // 1200 s
    // land ticket beta
    j({ ts: TS("03:00:00"), event: "acquired", resource: "land:beta", session: "B1", waitSec: 30 }),
    j({ ts: TS("03:00:10"), event: "land-push-failed", repo: "beta", resource: "land:beta", session: "B1" }), // hold 10 s, failed
    // two holds open at once: each end closes its OWN session's hold, not the most recent one
    j({ ts: TS("03:10:00"), event: "acquired", resource: "land:beta", session: "B2" }), // no waitSec: still opens a hold
    j({ ts: TS("03:11:00"), event: "acquired", resource: "land:beta", session: "B3" }),
    j({ ts: TS("03:12:00"), event: "land", repo: "beta", resource: "land:beta", session: "B2" }), // 120 s (most recent would give 60 s)
    j({ ts: TS("03:13:00"), event: "land", repo: "beta", resource: "land:beta", session: "B3" }), // 120 s (most recent would give 180 s)
    // slots: lost with a live chat = expire with chatIdleMin <= 30; break with chatIdleMin <= 30 and not byChat
    j({
        ts: TS("04:00:00"),
        event: "lease-expire",
        repo: "alpha",
        resource: "slot:alpha:task-1",
        chats: 1,
        chatIdleMin: 5,
        byChat: false,
    }), // lost
    j({
        ts: TS("04:01:00"),
        event: "lease-expire",
        repo: "alpha",
        resource: "slot:alpha:task-2",
        chats: 1,
        chatIdleMin: 30,
        byChat: false,
    }), // lost (boundary)
    j({
        ts: TS("04:02:00"),
        event: "lease-expire",
        repo: "alpha",
        resource: "slot:alpha:task-3",
        chats: 1,
        chatIdleMin: 31,
        byChat: false,
    }),
    j({
        ts: TS("04:03:00"),
        event: "lease-expire",
        repo: "alpha",
        resource: "slot:alpha:task-1",
        chats: 0,
        chatIdleMin: null,
        byChat: false,
    }),
    j({ ts: TS("04:04:00"), event: "lease-expire", repo: "beta", resource: "slot:beta:task-1" }), // older line, no fields
    j({
        ts: TS("04:10:00"),
        event: "lease-break",
        repo: "alpha",
        resource: "slot:alpha:task-1",
        chats: 1,
        chatIdleMin: 2,
        byChat: false,
    }), // lost
    j({
        ts: TS("04:11:00"),
        event: "lease-break",
        repo: "alpha",
        resource: "slot:alpha:task-2",
        chats: 1,
        chatIdleMin: 2,
        byChat: true,
    }), // own chat
    j({
        ts: TS("04:12:00"),
        event: "lease-break",
        repo: "alpha",
        resource: "slot:alpha:task-3",
        chats: 1,
        chatIdleMin: 45,
        byChat: false,
    }),
    j({ ts: TS("04:13:00"), event: "lease-break", resource: "slot:beta:task-1", chats: 2, chatIdleMin: 10 }), // lost (byChat absent), repo from the resource
    j({ ts: TS("04:14:00"), event: "lease-break", repo: "beta", resource: "slot:beta:task-2" }), // older line, no fields
    j({ ts: TS("04:15:00"), event: "lease-break", repo: "beta", resource: "slot:beta:task-3", byChat: true }), // own chat
    // shared clone writes
    j({ ts: TS("05:00:00"), event: "shared-write", repo: "alpha", mode: "warn", paths: "src/a.ts" }),
    j({ ts: TS("05:01:00"), event: "shared-write", repo: "alpha", mode: "refuse", override: true, paths: "src/b.ts" }),
];
async function* gen2() {
    for (const l of lines2) yield l;
}

// ---------- temp home with hook cost + start probe day files ----------
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "agentq-slo-test-"));
const write = (home, rel, rows) => {
    const p = path.join(home, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, rows.map((x) => (typeof x === "string" ? x : j(x))).join("\n") + "\n");
};
try {
    const homeFail = path.join(tmp, "fail");
    write(homeFail, "hooks/cost-20261017.jsonl", [
        { ts: "2026-10-17T10:00:00.000Z", ms: 100, startMs: 400, tool: "run", deny: false, session: "s1" }, // 500
        { ts: "2026-10-17T10:01:00.000Z", ms: 200, startMs: 800, tool: "run", deny: true, session: "s1" }, // 1000
        { ts: "2026-10-17T10:02:00.000Z", ms: 300, startMs: 1200, tool: "edit", deny: false, session: "s2" }, // 1500
        { ts: "2026-10-17T10:03:00.000Z", ms: 1000, startMs: 2600, tool: "edit", deny: true, session: "s2" }, // 3600
        "{oops",
        { ts: "2026-10-17T10:04:00.000Z", startMs: 5, tool: "run", deny: false, session: "s2" }, // no ms: bad
        { ts: "2026-10-11T11:00:00.000Z", ms: 999999, startMs: 1, tool: "run", deny: true, session: "s0" }, // before the window
        "",
    ]);
    write(homeFail, "hooks/cost-20261018.jsonl", [
        { ts: "2026-10-17T23:59:59.000Z", ms: 400, startMs: 400, tool: "run", deny: false, session: "s3" }, // 800, UTC day = the 17th
        { ts: "2026-10-18T01:00:00.000Z", ms: 50, startMs: 150, tool: "run", deny: false, session: "s3" }, // 200
        { ts: "2026-10-18T01:01:00.000Z", ms: 100, tool: "run", deny: false, session: "s3" }, // no startMs: 100
        { ts: "2026-10-18T13:00:00.000Z", ms: 777777, startMs: 1, tool: "run", deny: true, session: "s3" }, // after the window
    ]);
    write(homeFail, "hooks/cost-20260901.jsonl", [
        { ts: "2026-09-01T00:00:00.000Z", ms: 123456, startMs: 1, tool: "run", deny: true, session: "s0" },
    ]);
    write(homeFail, "hooks/notes.txt", ["not a day file"]);
    write(homeFail, "load/probe-20261018.jsonl", [
        { ts: "2026-10-18T02:00:10.000Z", ms: 100, cpu: 20, src: "agentq" },
        { ts: "2026-10-18T02:02:00.000Z", ms: 900, cpu: 95.5, src: "agentq" },
        { ts: "2026-10-18T02:04:59.000Z", ms: 200, cpu: null, src: "agentq" }, // bucket 02:00 median 200: good
        { ts: "2026-10-18T02:05:00.000Z", ms: 400, cpu: 50, src: "agentq" },
        { ts: "2026-10-18T02:09:00.000Z", ms: 600, cpu: 50, src: "agentq" }, // bucket 02:05 median 500: NOT under 500
        { ts: "2026-10-18T02:10:00.000Z", ms: 450, cpu: 50, src: "agentq" }, // bucket 02:10 median 450: good
        { ts: "2026-10-18T02:15:00.000Z", ms: 2000, cpu: 100, src: "agentq" },
        { ts: "2026-10-18T02:16:00.000Z", ms: 3000, cpu: 100, src: "agentq" },
        { ts: "2026-10-18T02:17:00.000Z", ms: 100, cpu: 100, src: "agentq" }, // bucket 02:15 median 2000: worst
        "garbage",
        { ts: "2026-10-18T12:30:00.000Z", ms: 60000, cpu: 100, src: "agentq" }, // after the window
    ]);

    const rep2 = await compute(gen2(), { days: 7, now: T("12:00"), home: homeFail });

    // queue time
    assert.deepEqual(rep2.queueTime.byResource, [
        { resource: "deploy:alpha", n: 1, p50: 3600, p90: 3600, max: 3600, totalSec: 3600, over10min: 1 },
        { resource: "build:alpha", n: 3, p50: 601, p90: 700, max: 700, totalSec: 1401, over10min: 2 },
        { resource: "land:alpha", n: 5, p50: 20, p90: 1200, max: 1200, totalSec: 1291, over10min: 1 },
        { resource: "build:machine", n: 1, p50: 600, p90: 600, max: 600, totalSec: 600, over10min: 0 },
        { resource: "land:beta", n: 1, p50: 30, p90: 30, max: 30, totalSec: 30, over10min: 0 },
        { resource: "commit:beta", n: 1, p50: 5, p90: 5, max: 5, totalSec: 5, over10min: 0 },
    ]);
    assert.equal(rep2.queueTime.totalHours, 6927 / 3600);
    assert.equal(rep2.queueTime.hoursPerDay, 6927 / 3600 / 7);
    assert.equal(rep2.queueTime.over10min, 4);
    assert.equal(rep2.queueTime.waits, 12);
    // the older per-kind table keeps its own rule (start/done/fail count, machine is skipped)
    assert.equal(rep2.byRepo.alpha.queueWaitSec.build.n, 4);

    // land ticket
    assert.deepEqual(rep2.landTicket.byRepo.alpha, {
        lands: 4,
        failures: 2,
        holds: 5,
        holdTotalSec: 2690,
        holdP50: 540,
        holdP90: 1200,
        under60s: 1,
        holdFailedSec: 1140,
        pregateOk: 2,
        pregateFailed: 1,
        pregateConflict: 1,
        pregateSkipped: 1,
        gateSkippedGreen: 3,
    });
    assert.deepEqual(rep2.landTicket.byRepo.beta, {
        lands: 2,
        failures: 1,
        holds: 3,
        holdTotalSec: 250,
        holdP50: 120,
        holdP90: 120,
        under60s: 1,
        holdFailedSec: 10,
        pregateOk: 0,
        pregateFailed: 0,
        pregateConflict: 0,
        pregateSkipped: 0,
        gateSkippedGreen: 0,
    });
    assert.deepEqual(Object.keys(rep2.landTicket.byRepo), ["alpha", "beta"]);

    // slots lost with a live chat
    assert.deepEqual(rep2.slots.byRepo.alpha, {
        lostLiveChat: 3,
        expireLiveChat: 2,
        breakLiveChat: 1,
        breakByOwnChat: 1,
        leaseBreaks: 3,
        leaseExpires: 4,
    });
    assert.deepEqual(rep2.slots.byRepo.beta, {
        lostLiveChat: 1,
        expireLiveChat: 0,
        breakLiveChat: 1,
        breakByOwnChat: 1,
        leaseBreaks: 3,
        leaseExpires: 1,
    });
    assert.equal(rep2.slots.lostLiveChat, 4);
    assert.equal(rep2.slots.breakByOwnChat, 2);
    assert.equal(rep2.slots.leaseBreaks, 6);
    assert.equal(rep2.slots.leaseExpires, 5);
    assert.deepEqual(rep2.slo.slotsLostLiveChat, { verdict: "FAIL", value: 4, target: "= 0" });

    // hook cost: cost per call = ms + startMs, day = UTC date of ts (not of the file name)
    const hc = rep2.hookCost;
    assert.deepEqual(hc.days, [
        { day: "2026-10-17", calls: 5, totalHours: 7400 / 3.6e6, p50Ms: 1000, p90Ms: 3600, startP50Ms: 800, denies: 2 },
        { day: "2026-10-18", calls: 2, totalHours: 300 / 3.6e6, p50Ms: 100, p90Ms: 200, startP50Ms: 150, denies: 0 },
    ]);
    assert.equal(hc.calls, 7);
    assert.equal(hc.totalHours, 7700 / 3.6e6);
    assert.equal(hc.hoursPerDay, 7700 / 3.6e6 / 2);
    assert.equal(hc.p50Ms, 800);
    assert.equal(hc.p90Ms, 3600);
    assert.equal(hc.startP50Ms, 400);
    assert.equal(hc.denies, 2);
    assert.equal(hc.badLines, 2);

    // start probe: 4 buckets, 2 with a median under 500 ms -> 50 % -> FAIL
    assert.deepEqual(rep2.startProbe, {
        samples: 9,
        buckets: 4,
        bucketsUnder500: 2,
        underPct: 50,
        p50Ms: 450,
        p90Ms: 3000,
        worstBucket: { at: "2026-10-18T02:15:00.000Z", medianMs: 2000, n: 3 },
        badLines: 1,
    });
    assert.deepEqual(rep2.slo.startProbeBucketsPct, { verdict: "FAIL", value: 50, target: ">= 95" });

    // baseline block
    assert.deepEqual(rep2.baseline, {
        queueWaitHours: 6927 / 3600,
        waitsOver10min: 4,
        busiestQueue: { resource: "deploy:alpha", hours: 1 },
        landFailureRate: 3 / 9,
        leaseBreaks: 6,
        leaseExpires: 5,
        sharedCloneWrites: 1,
        sharedCloneOverrides: 1,
        hookCostHoursPerDay: 7700 / 3.6e6 / 2,
    });
    // existing fields keep their meaning
    assert.equal(rep2.overall.bypass.sharedCloneWrites, 1);
    assert.equal(rep2.overall.landing.failureRate, 3 / 9);

    const txt2 = render(rep2);
    assert.ok(
        txt2.indexOf("BASELINE NUMBERS") > 0 && txt2.indexOf("BASELINE NUMBERS") < txt2.indexOf("\nSLO\n"),
        "baseline block comes first",
    );
    assert.match(txt2, /queue wait total\s+1\.9 h \(0\.3 h\/day\)/);
    assert.match(txt2, /waits over 10 min\s+4\n/);
    assert.match(txt2, /busiest queue\s+deploy:alpha 1\.0 h/);
    assert.match(txt2, /land failure rate\s+33\.3% \(3 of 9\)/);
    assert.match(txt2, /lease-break \/ lease-expire\s+6 \/ 5/);
    assert.match(txt2, /shared clone writes\s+1 \(\+1 overrides\)/);
    assert.match(txt2, /hook cost\s+0\.00 h\/day/);
    assert.match(txt2, /startProbeBucketsPct\s+50\s+>= 95\s+FAIL/);
    assert.match(txt2, /slotsLostLiveChat\s+4\s+= 0\s+FAIL/);
    assert.match(txt2, /QUEUE TIME/);
    assert.match(txt2, /total 1\.9 h in 7 d = 0\.3 h\/day; 12 waits, 4 over 10 min/);
    assert.match(txt2, /build:alpha\s+3\s+10\.0m\s+11\.7m\s+11\.7m\s+23\.4m\s+2\n/);
    assert.match(txt2, /LAND TICKET/);
    assert.match(txt2, /alpha\s+4\s+2\s+5\s+44\.8m\s+9\.0m\s+20\.0m\s+1\s+19\.0m\s+2\s+1\s+1\s+1\s+3\n/);
    assert.match(txt2, /SLOTS LOST WITH A LIVE CHAT \(chat idle <= 30 min; lease-break 6, lease-expire 5 in window\)/);
    assert.match(txt2, /ALL\s+4\s+2\s+2\s+2\s+6\s+5/);
    assert.match(txt2, /HOOK COST/);
    assert.match(txt2, /2026-10-17\s+5\s+0\.00\s+1000\s+3600\s+800\s+2\n/);
    assert.match(txt2, /START PROBE/);
    assert.match(txt2, /4 buckets, 2 under 500 ms = 50%; 9 samples p50 450 ms p90 3000 ms; 1 bad lines/);
    assert.match(txt2, /worst bucket 2026-10-18T02:15Z median 2000 ms \(n 3\)/);
    console.log(`\n${txt2}`);

    // more than 8 queues: the table shows the top 8 by total wait
    async function* many() {
        for (let i = 1; i <= 10; i++)
            yield j({
                ts: TS("06:00:00"),
                event: "acquired",
                resource: `build:q${String(i).padStart(2, "0")}`,
                session: `M${i}`,
                waitSec: i * 10,
            });
    }
    const repMany = await compute(many(), { days: 1, now: T("12:00") });
    assert.equal(repMany.queueTime.byResource.length, 10);
    assert.equal(repMany.queueTime.byResource[0].resource, "build:q10");
    const txtMany = render(repMany);
    assert.match(txtMany, /build:q03\s+1\s/);
    assert.doesNotMatch(txtMany, /build:q02\s+1\s/);
    assert.match(txtMany, /\(\+2 more resources in --json\)/);

    // PASS: 20 buckets, 19 under 500 ms = exactly 95 %; no slot lost; every row green
    const homePass = path.join(tmp, "pass");
    write(
        homePass,
        "load/probe-20261018.jsonl",
        Array.from({ length: 20 }, (_, i) => ({
            ts: new Date(Date.parse(TS("03:00:00")) + i * 5 * 60 * 1000).toISOString(),
            ms: i === 7 ? 800 : 100,
            cpu: 10,
            src: "agentq",
        })),
    );
    const pass = await compute(ok(), { days: 1, now: T("12:00"), home: homePass });
    assert.equal(pass.startProbe.buckets, 20);
    assert.equal(pass.startProbe.bucketsUnder500, 19);
    assert.deepEqual(pass.slo.startProbeBucketsPct, { verdict: "PASS", value: 95, target: ">= 95" });
    assert.deepEqual(pass.slo.slotsLostLiveChat, { verdict: "PASS", value: 0, target: "= 0" });
    assert.deepEqual(
        Object.values(pass.slo).map((x) => x.verdict),
        ["PASS", "PASS", "PASS", "PASS", "PASS"],
    );
    assert.equal(pass.hookCost, null); // no hooks dir in this home
    assert.match(render(pass), /no hook cost data \(the hook does not log yet\)/);

    // 18 of 20 = 90 % -> FAIL (just under the target)
    const homeNinety = path.join(tmp, "ninety");
    write(
        homeNinety,
        "load/probe-20261018.jsonl",
        Array.from({ length: 20 }, (_, i) => ({
            ts: new Date(Date.parse(TS("03:00:00")) + i * 5 * 60 * 1000).toISOString(),
            ms: i < 2 ? 800 : 100,
            cpu: 10,
            src: "agentq",
        })),
    );
    assert.deepEqual((await compute(ok(), { days: 1, now: T("12:00"), home: homeNinety })).slo.startProbeBucketsPct, {
        verdict: "FAIL",
        value: 90,
        target: ">= 95",
    });

    // NO DATA: day files exist but nothing falls in the window; empty home = nulls
    const homeOld = path.join(tmp, "old");
    write(homeOld, "hooks/cost-20260901.jsonl", [
        { ts: "2026-09-01T00:00:00.000Z", ms: 5, startMs: 5, tool: "run", deny: false, session: "s" },
    ]);
    write(homeOld, "load/probe-20260901.jsonl", [{ ts: "2026-09-01T00:00:00.000Z", ms: 5, cpu: 1, src: "agentq" }]);
    const old = await compute(ok(), { days: 1, now: T("12:00"), home: homeOld });
    assert.equal(old.hookCost.calls, 0);
    assert.deepEqual(old.hookCost.days, []);
    assert.equal(old.hookCost.hoursPerDay, null);
    assert.equal(old.baseline.hookCostHoursPerDay, null);
    assert.equal(old.startProbe.buckets, 0);
    assert.equal(old.slo.startProbeBucketsPct.verdict, "NO DATA");
    assert.match(render(old), /no hook cost samples in the window/);
    assert.match(render(old), /no start probe samples in the window/);
    const homeEmpty = path.join(tmp, "empty");
    fs.mkdirSync(homeEmpty);
    const empty = await compute(ok(), { days: 1, now: T("12:00"), home: homeEmpty });
    assert.equal(empty.hookCost, null);
    assert.equal(empty.startProbe, null);
    assert.equal(empty.slo.startProbeBucketsPct.verdict, "NO DATA");

    // CLI: --home defaults to the journal's directory; exit 1 on a FAIL row, 0 when nothing fails
    const cli = fileURLToPath(new URL("../bin/agentq-slo.mjs", import.meta.url));
    const run = (args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
    fs.writeFileSync(path.join(homeFail, "journal.jsonl"), lines2.join("\n") + "\n");
    const c1 = run(["--journal", path.join(homeFail, "journal.jsonl"), "--now", T("12:00"), "--json"]);
    assert.equal(c1.status, 1, c1.stderr);
    const j1 = JSON.parse(c1.stdout);
    assert.equal(j1.hookCost.calls, 7);
    assert.equal(j1.startProbe.buckets, 4);
    assert.equal(j1.queueTime.over10min, 4);
    const okJournal = path.join(tmp, "ok-journal.jsonl");
    const okLines = [];
    for await (const l of ok()) okLines.push(l);
    fs.writeFileSync(okJournal, okLines.join("\n") + "\n");
    const c2 = run(["--journal", okJournal, "--home", homePass, "--days", "1", "--now", T("12:00")]);
    assert.equal(c2.status, 0, c2.stderr);
    assert.match(c2.stdout, /startProbeBucketsPct\s+95\s+>= 95\s+PASS/);
    const c3 = run(["--journal", okJournal, "--days", "1", "--now", T("12:00"), "--json"]); // home = tmp: no day files
    assert.equal(c3.status, 0, c3.stderr);
    assert.equal(JSON.parse(c3.stdout).hookCost, null);
    const c4 = run(["--help"]);
    assert.equal(c4.status, 0);
    assert.match(c4.stdout, /--home <coord dir>/);
    const c5 = run(["--bogus"]);
    assert.equal(c5.status, 2);
    assert.match(c5.stderr, /unknown argument --bogus/);
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}
assert.equal(fs.existsSync(tmp), false);

console.log("\nSELFTEST OK (all assertions passed)");
