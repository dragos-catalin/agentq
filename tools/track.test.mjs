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

// Non-vacuous proof for the roster test: remove the `t.parent && sessions.has(...)`
// branch in cmdRoster and the child's claim (t2) drops out of its parent's roster,
// so `assert.deepEqual(roster.tasks.map(...), ["t1","t2"])` fails.
test("roster lists a session's claims and its children's, but not an unrelated one", () => {
    const s = makeState();
    try {
        assert.equal(run(s, "task", "add", "--id", "t1", "--title", "one").code, 0);
        assert.equal(run(s, "task", "add", "--id", "t2", "--title", "two").code, 0);
        assert.equal(run(s, "task", "add", "--id", "t3", "--title", "three").code, 0);
        assert.equal(run(s, "task", "claim", "--id", "t1", "--by", "A", "--session", "s-parent").code, 0);
        assert.equal(
            run(s, "task", "claim", "--id", "t2", "--by", "B", "--session", "s-child", "--parent", "s-parent").code,
            0,
        );
        assert.equal(run(s, "task", "claim", "--id", "t3", "--by", "C", "--session", "s-other").code, 0);
        const r = run(s, "roster", "--session", "s-parent", "--json");
        assert.equal(r.code, 0, r.stderr);
        const roster = JSON.parse(r.stdout);
        assert.deepEqual(roster.sessions, ["s-child", "s-parent"]);
        assert.deepEqual(roster.tasks.map((t) => t.id).sort(), ["t1", "t2"]);
        // a claim written before `session` existed falls back to its owner
        writeFileSync(
            join(s, "tasks", "t5.json"),
            JSON.stringify({
                version: 1,
                id: "t5",
                title: "five",
                status: "claimed",
                owner: "legacy",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
            }),
            "utf8",
        );
        const legacy = JSON.parse(run(s, "roster", "--session", "legacy", "--json").stdout);
        assert.deepEqual(
            legacy.tasks.map((t) => t.id),
            ["t5"],
        );
    } finally {
        rmSync(s, { recursive: true, force: true });
    }
});

// Non-vacuous proof: drop the `plans`/`tasks` arrays from the export payload and
// the import has nothing to add, so `t.owner === "A"` fails on the fresh state.
test("export then import carries tasks and plans to a fresh state without loss", () => {
    const s1 = makeState();
    const s2 = makeState();
    const file = join(s1, "state.json");
    try {
        assert.equal(run(s1, "task", "add", "--id", "t1", "--title", "one").code, 0);
        assert.equal(run(s1, "task", "claim", "--id", "t1", "--by", "A", "--session", "s1").code, 0);
        assert.equal(run(s1, "plan", "set", "--session", "p1", "--goal", "g").code, 0);
        const e = run(s1, "export", "--out", file);
        assert.equal(e.code, 0, e.stderr);
        // deterministic: two exports of one state differ only in exportedAt
        const file2 = join(s1, "state2.json");
        assert.equal(run(s1, "export", "--out", file2).code, 0);
        const strip = (p) => readFileSync(p, "utf8").replace(/"exportedAt":\s*"[^"]*"/, '"exportedAt":"X"');
        assert.equal(strip(file), strip(file2), "two exports of one state differ only in exportedAt");
        // import into a fresh state
        const i = run(s2, "import", "--in", file);
        assert.equal(i.code, 0, i.stderr);
        const t = JSON.parse(run(s2, "task", "show", "--id", "t1", "--json").stdout);
        assert.equal(t.owner, "A");
        assert.equal(t.session, "s1");
        const plan = JSON.parse(run(s2, "plan", "show", "--session", "p1", "--json").stdout);
        assert.equal(plan.goal, "g");
    } finally {
        rmSync(s1, { recursive: true, force: true });
        rmSync(s2, { recursive: true, force: true });
    }
});

// Non-vacuous proof: delete the `if (local.owner && local.owner !== incoming.owner)`
// line in mergeRecord and the import overwrites the local claim (exit 0), so both
// `assert.equal(i.code, 1)` and `assert.equal(t.owner, "B")` fail.
test("import refuses to overwrite a local claim and exits non-zero", () => {
    const s1 = makeState();
    const s2 = makeState();
    const file = join(s1, "state.json");
    try {
        assert.equal(run(s1, "task", "add", "--id", "t1", "--title", "one").code, 0);
        assert.equal(run(s1, "task", "claim", "--id", "t1", "--by", "A", "--session", "src").code, 0);
        assert.equal(run(s1, "export", "--out", file).code, 0);
        assert.equal(run(s2, "task", "add", "--id", "t1", "--title", "one").code, 0);
        assert.equal(run(s2, "task", "claim", "--id", "t1", "--by", "B", "--session", "dst").code, 0);
        const i = run(s2, "import", "--in", file);
        assert.equal(i.code, 1, `a conflict must exit non-zero; got ${i.code} - ${i.stdout}`);
        assert.match(i.stdout, /owner-divergence/);
        const t = JSON.parse(readFileSync(join(s2, "tasks", "t1.json"), "utf8"));
        assert.equal(t.owner, "B", "the local claim is not overwritten");
    } finally {
        rmSync(s1, { recursive: true, force: true });
        rmSync(s2, { recursive: true, force: true });
    }
});

// Non-vacuous proof: remove the `row-count` comparison in cmdDrift and the stale
// index passes as clean, so `assert.equal(d.code, 1)` fails.
test("drift exits non-zero on a stale index and 0 when the definition agrees", () => {
    const s = makeState();
    const repo = makeState();
    try {
        mkdirSync(join(repo, ".agentq"), { recursive: true });
        writeFileSync(
            join(repo, ".agentq", "trackers.json"),
            JSON.stringify({
                version: 1,
                repo: "vt",
                trackers: [
                    {
                        id: "t",
                        file: "t.csv",
                        format: "csv",
                        columns: { id: "id", title: "title", status: "status" },
                        status: { map: { todo: "todo", done: "done" } },
                    },
                ],
            }),
            "utf8",
        );
        writeFileSync(join(repo, "t.csv"), "id,title,status\nT-1,one,todo\nT-2,two,done\n", "utf8");
        mkdirSync(join(s, "trackers"), { recursive: true });
        const idx = (items, counts) => ({
            version: 1,
            generatedAt: "x",
            repos: [
                {
                    repo: "vt",
                    root: repo,
                    trackers: [{ id: "t", file: "t.csv", countsByStatus: counts, items }],
                    drift: [],
                },
            ],
        });
        // an index that matches the live definition -> clean
        writeFileSync(
            join(s, "trackers", "index.json"),
            JSON.stringify(idx([{ id: "T-1" }, { id: "T-2" }], { todo: 1, done: 1 })),
            "utf8",
        );
        assert.equal(run(s, "drift", "--repo", repo).code, 0);
        // a stale index (one row short) -> non-zero, row-count reported
        writeFileSync(join(s, "trackers", "index.json"), JSON.stringify(idx([{ id: "T-1" }], { todo: 2 })), "utf8");
        const d = run(s, "drift", "--repo", repo);
        assert.equal(d.code, 1, `a stale index must exit non-zero; got ${d.code} - ${d.stdout}`);
        assert.match(d.stdout, /row-count/);
    } finally {
        rmSync(s, { recursive: true, force: true });
        rmSync(repo, { recursive: true, force: true });
    }
});
