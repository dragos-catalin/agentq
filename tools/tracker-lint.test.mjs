// Coverage tests for tracker-lint.mjs - the per-tracker status-map report.
// Run with EITHER runner:
//   node --test tools/tracker-lint.test.mjs            (the tools/ convention)
//   pnpm exec vitest run tools/tracker-lint.test.mjs   (the project's test script)
//
// The suite is deliberately runner-agnostic. vitest does not pick up
// tools/*.test.mjs on its own - the project's `include` is `test/**/*.test.ts`
// and there is no --include flag - and the sibling tools tests are node:test
// files that vitest reports as "No test suite found". So the runner is chosen at
// runtime from `process.env.VITEST`, and the teardown is bound to whichever name
// that runner exports (`after` in node:test, `afterAll` in vitest) - a static `import { test } from "vitest"`
// would break `node --test`, and a static node:test import is invisible to
// vitest). Everything else mirrors the sibling tools tests: the CLI is driven as
// a CHILD PROCESS against a throwaway repo in a temp directory, so what is
// asserted is the real contract - the exit code, the --json payload and the human
// line - not an in-process shortcut. The suite is listed by name in
// vitest.config.ts so vitest can see it without dragging the node:test siblings in.
//
// Non-vacuous proof: force the report to claim every token is mapped - in
// readTrackerFile's coverage build, replace the byToken `mapped` value with a
// literal `true` (or hard-code `unmapped: 0`) - and these fail:
//   * "names the exact unmapped token ..." on assert.equal(cov.unmapped, 1)
//   * "collapses ..." on assert.equal(cov.byToken.active.mapped, false)
//   * and both on the exit code, because the per-token finding is emitted from
//     the same predicate. Restore it and all pass again. Observed in this repo.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";

const runner = process.env.VITEST ? await import("vitest") : await import("node:test");
const test = runner.test;
const after = runner.after ?? runner.afterAll;

const TOOL = join(dirname(import.meta.filename), "tracker-lint.mjs");
const dirs = [];

function makeRepo() {
    const d = mkdtempSync(join(tmpdir(), "tracker-lint-coverage-"));
    dirs.push(d);
    return d;
}

function run(...args) {
    const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: "utf8" });
    return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

// A minimal valid mapping: one tracker, the three required columns, an idPattern
// that matches every fixture id (so no unrelated finding is produced), and the
// status vocabulary the case needs.
function writeRepo(repo, csv, statusMap) {
    mkdirSync(join(repo, ".agentq"), { recursive: true });
    writeFileSync(join(repo, "t.csv"), csv, "utf8");
    writeFileSync(
        join(repo, ".agentq", "trackers.json"),
        JSON.stringify(
            {
                repo: "fixture",
                trackers: [
                    {
                        id: "fx",
                        file: "t.csv",
                        columns: { id: "id", title: "title", status: "status" },
                        idPattern: "^A-\\d+$",
                        status: { map: statusMap },
                    },
                ],
            },
            null,
            2,
        ),
        "utf8",
    );
    return repo;
}

after(() => {
    for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

test("coverage counts distinct tokens and proves every one is mapped", () => {
    const repo = writeRepo(makeRepo(), "id,title,status\nA-1,one,done\nA-2,two,review\nA-3,three,done\n", {
        done: "done",
        review: "review",
    });
    const r = run("--root", repo, "--json");
    assert.equal(r.code, 0, r.stderr + r.stdout);
    const entry = JSON.parse(r.stdout);
    const cov = entry.trackers[0].coverage;
    assert.equal(cov.rows, 3);
    assert.equal(cov.tokens, 2);
    assert.equal(cov.mapped, 2);
    assert.equal(cov.unmapped, 0);
    assert.deepEqual(cov.byToken, { done: { rows: 2, mapped: true }, review: { rows: 1, mapped: true } });
    assert.equal(entry.drift.length, 0, JSON.stringify(entry.drift));

    const human = run("--root", repo);
    assert.equal(human.code, 0, human.stderr + human.stdout);
    assert.match(human.stdout, /tracker fx: 3 row\(s\), 2 token\(s\), 2 mapped, 0 unmapped \(done=2, review=1\)/);
});

test("names the exact unmapped token and counts it in the exit code", () => {
    const repo = writeRepo(makeRepo(), "id,title,status\nA-1,one,active\n", { done: "done" });
    const r = run("--root", repo, "--json");
    assert.equal(r.code, 1, r.stderr + r.stdout);
    const entry = JSON.parse(r.stdout);
    const cov = entry.trackers[0].coverage;
    assert.equal(cov.rows, 1);
    assert.equal(cov.tokens, 1);
    assert.equal(cov.mapped, 0);
    assert.equal(cov.unmapped, 1);
    assert.equal(cov.byToken.active.mapped, false);
    assert.equal(cov.byToken.active.rows, 1);

    const unmapped = entry.drift.filter((d) => d.kind === "unmapped-status");
    assert.equal(unmapped.length, 1);
    assert.equal(unmapped[0].ref, "A-1");
    assert.match(unmapped[0].detail, /status 'active' has no mapping; map it to one of/);

    const human = run("--root", repo);
    assert.equal(human.code, 1, human.stderr + human.stdout);
    assert.match(human.stdout, /tracker fx: 1 row\(s\), 1 token\(s\), 0 mapped, 1 unmapped \(active=1\)/);
    assert.match(human.stdout, /drift: \[unmapped-status\] fx A-1 - status 'active' has no mapping/);
});

test("collapses a token repeated across rows into ONE finding with its row count", () => {
    const repo = writeRepo(
        makeRepo(),
        "id,title,status\nA-1,one,active\nA-2,two,active\nA-3,three,active\nA-4,four,done\n",
        { done: "done" },
    );
    const r = run("--root", repo, "--json");
    // One finding, not three: the exit code is the number of DISTINCT problems.
    assert.equal(r.code, 1, r.stderr + r.stdout);
    const entry = JSON.parse(r.stdout);
    const cov = entry.trackers[0].coverage;
    assert.equal(cov.rows, 4);
    assert.equal(cov.tokens, 2);
    assert.equal(cov.mapped, 1);
    assert.equal(cov.unmapped, 1);
    assert.deepEqual(cov.byToken.active, { rows: 3, mapped: false });
    assert.deepEqual(cov.byToken.done, { rows: 1, mapped: true });

    const unmapped = entry.drift.filter((d) => d.kind === "unmapped-status");
    assert.equal(unmapped.length, 1, "a repeated token must collapse to one finding");
    assert.equal(unmapped[0].ref, "A-1", "the finding points at the first row that carried the token");
    assert.match(unmapped[0].detail, /status 'active' has no mapping in 3 rows; map it to one of/);

    const human = run("--root", repo);
    assert.match(human.stdout, /tracker fx: 4 row\(s\), 2 token\(s\), 1 mapped, 1 unmapped \(active=3, done=1\)/);
});

test("--no-coverage quiets only the human lines; findings and exit code are unchanged", () => {
    const repo = writeRepo(makeRepo(), "id,title,status\nA-1,one,active\n", { done: "done" });
    const human = run("--root", repo, "--no-coverage");
    assert.equal(human.code, 1, human.stderr + human.stdout);
    assert.doesNotMatch(human.stdout, /tracker fx:/);
    assert.match(human.stdout, /drift: \[unmapped-status\] fx A-1/);

    const js = run("--root", repo, "--no-coverage", "--json");
    assert.equal(js.code, 1);
    assert.equal(JSON.parse(js.stdout).trackers[0].coverage.unmapped, 1);
});

test("a declared tracker that does not exist reports empty coverage, not a missing field", () => {
    const repo = makeRepo();
    mkdirSync(join(repo, ".agentq"), { recursive: true });
    writeFileSync(
        join(repo, ".agentq", "trackers.json"),
        JSON.stringify({
            repo: "fixture",
            trackers: [
                {
                    id: "fx",
                    file: "gone.csv",
                    columns: { id: "id", title: "title", status: "status" },
                    status: { map: {} },
                },
            ],
        }),
        "utf8",
    );
    const r = run("--root", repo, "--json");
    assert.equal(r.code, 1, r.stderr + r.stdout);
    assert.deepEqual(JSON.parse(r.stdout).trackers[0].coverage, {
        rows: 0,
        tokens: 0,
        mapped: 0,
        unmapped: 0,
        byToken: {},
    });
    const human = run("--root", repo);
    assert.match(human.stdout, /tracker fx: 0 row\(s\), 0 token\(s\), 0 mapped, 0 unmapped$/m);
});
