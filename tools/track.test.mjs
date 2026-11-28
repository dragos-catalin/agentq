// Tests for track.mjs - run with: node --test tools/track.test.mjs
//
// Every case drives the CLI as a CHILD PROCESS against a throwaway state dir, so
// what is asserted is the real contract: the exit code and the file on disk. An
// in-process call would prove nothing about `claim` - the whole point is that two
// separate runs cannot both win - and about a resume, which is a different
// process reading a file another process wrote.
//
// Non-vacuous proof for the atomic-claim test: delete the line in track.mjs
//   if (t.owner && t.owner !== by) return { rc: 2, ... };
// and the second claim overwrites the first, returns exit 0, and
// "task claim is atomic" fails on `assert.equal(c2.code, 2)`. The exclusive
// lock, not that line alone, is what makes it true under a real race; the line
// is what the test pins.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";

const TOOL = join(dirname(import.meta.filename), "track.mjs");

function makeState() {
    return mkdtempSync(join(tmpdir(), "track-test-"));
}

function run(state, ...args) {
    const r = spawnSync(process.execPath, [TOOL, ...args], {
        env: { ...process.env, AGENTQ_HOME: state },
        encoding: "utf8",
    });
    return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

test("a plan round-trips through set then show", () => {
    const s = makeState();
    try {
        const a = run(
            s,
            "plan",
            "set",
            "--session",
            "demo",
            "--goal",
            "ship it",
            "--next",
            "a,b",
            "--done",
            "d1,d2",
            "--roster",
            "Researcher,Deep Build",
        );
        assert.equal(a.code, 0, a.stderr);
        const b = run(s, "plan", "show", "--session", "demo", "--json");
        assert.equal(b.code, 0, b.stderr);
        const plan = JSON.parse(b.stdout);
        assert.equal(plan.goal, "ship it");
        assert.deepEqual(
            plan.next.map((x) => x.title),
            ["a", "b"],
        );
        assert.deepEqual(plan.doneMeans, ["d1", "d2"]);
        assert.deepEqual(
            plan.roster.map((x) => x.agentName),
            ["Researcher", "Deep Build"],
        );
        assert.ok(plan.updatedAt, "updatedAt is set");
        // a later set must not drop the goal (resume safety)
        const c = run(s, "plan", "set", "--session", "demo", "--next", "z");
        assert.equal(c.code, 0, c.stderr);
        const plan2 = JSON.parse(run(s, "plan", "show", "--session", "demo", "--json").stdout);
        assert.equal(plan2.goal, "ship it");
        assert.deepEqual(
            plan2.next.map((x) => x.title),
            ["z"],
        );
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("task claim is atomic: the second claim by another agent exits 2", () => {
    const s = makeState();
    try {
        assert.equal(run(s, "task", "add", "--id", "t1", "--title", "one").code, 0);
        const c1 = run(s, "task", "claim", "--id", "t1", "--by", "agent-1");
        assert.equal(c1.code, 0, c1.stderr);
        const c2 = run(s, "task", "claim", "--id", "t1", "--by", "agent-2");
        assert.equal(c2.code, 2, `second claim must be refused; got code ${c2.code} - ${c2.stdout}`);
        const t = JSON.parse(readFileSync(join(s, "tasks", "t1.json"), "utf8"));
        assert.equal(t.owner, "agent-1", "the first owner is not overwritten");
        // the same agent may re-claim idempotently
        assert.equal(run(s, "task", "claim", "--id", "t1", "--by", "agent-1").code, 0);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("next skips a task whose dependency is open and returns it once the dep is done", () => {
    const s = makeState();
    try {
        assert.equal(run(s, "task", "add", "--id", "a", "--title", "A").code, 0);
        assert.equal(run(s, "task", "add", "--id", "b", "--title", "B", "--dep", "a").code, 0);
        // first next -> a (no deps), claimed
        const n1 = run(s, "task", "next", "--by", "w");
        assert.equal(n1.code, 0, n1.stderr);
        assert.match(n1.stdout, /\ba\b/);
        // a is now claimed (open) -> b is not ready -> none
        const n2 = run(s, "task", "next", "--by", "w");
        assert.equal(n2.code, 3, `b must be blocked while a is open; got ${n2.code} - ${n2.stdout}`);
        // finish a -> b becomes ready
        assert.equal(run(s, "task", "done", "--id", "a", "--evidence", "ok").code, 0);
        const n3 = run(s, "task", "next", "--by", "w");
        assert.equal(n3.code, 0, n3.stderr);
        assert.match(n3.stdout, /\bb\b/);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("next exits 3 when there is no task at all", () => {
    const s = makeState();
    try {
        const n = run(s, "task", "next", "--by", "w");
        assert.equal(n.code, 3, n.stdout);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("status counts repos and drift and exits with the total drift", () => {
    const s = makeState();
    try {
        mkdirSync(join(s, "trackers"), { recursive: true });
        const index = {
            version: 1,
            generatedAt: "2026-01-01T00:00:00Z",
            repos: [
                {
                    repo: "vitals",
                    root: "E:/gh/vitals",
                    trackers: [{ id: "t", file: "x.csv", countsByStatus: {}, items: [1, 2, 3] }],
                    drift: [],
                },
                {
                    repo: "agentq",
                    root: "E:/gh/agentq",
                    trackers: [{ id: "t", file: "y.csv", countsByStatus: {}, items: [1] }],
                    drift: [{ kind: "arity", tracker: "t", ref: "l1", detail: "x" }],
                },
            ],
        };
        writeFileSync(join(s, "trackers", "index.json"), JSON.stringify(index), "utf8");
        const r = run(s, "status");
        assert.equal(r.code, 1, `one drift finding -> exit 1; got ${r.code}`);
        assert.match(r.stdout, /vitals: 3 item\(s\), 0 drift/);
        assert.match(r.stdout, /agentq: 1 item\(s\), 1 drift/);
        assert.match(r.stdout, /total drift: 1/);
        const j = run(s, "status", "--json");
        assert.equal(j.code, 1);
        assert.equal(JSON.parse(j.stdout).repos.length, 2);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("status with no index prints how to build it and exits 2", () => {
    const s = makeState();
    try {
        const r = run(s, "status");
        assert.equal(r.code, 2, r.stdout);
        assert.match(r.stderr, /tracker-lint\.mjs --scan/);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

test("status with an empty index reports zero and exits 0", () => {
    const s = makeState();
    try {
        mkdirSync(join(s, "trackers"), { recursive: true });
        writeFileSync(
            join(s, "trackers", "index.json"),
            JSON.stringify({ version: 1, generatedAt: "x", repos: [] }),
            "utf8",
        );
        const r = run(s, "status");
        assert.equal(r.code, 0, r.stderr);
        assert.match(r.stdout, /0 repo\(s\), 0 item\(s\)/);
        assert.match(r.stdout, /total drift: 0/);
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});
