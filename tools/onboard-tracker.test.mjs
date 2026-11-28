// Tests for onboard-tracker.mjs - run with: node --test tools/onboard-tracker.test.mjs
//
// Every case drives the CLI as a CHILD PROCESS against a throwaway repo built in
// a temp directory, so what is asserted is the real contract: the mapping it
// infers, the file it does or does not write, and the linter's exit code. The
// tool's whole job is to run the real linter (tools/tracker-lint.mjs) as a child
// and then map what it found, so an in-process call would prove nothing about
// that boundary.
//
// Non-vacuous proof for "never invents a status": add `"active": "in-progress"`
// to the inferred map (or a synonym table) in onboard-tracker.mjs and
// "mapping is conservative about status" fails, because the inferred map would
// then contain 'active' - a mapping nobody asked for and the file never spelled.
//
// Non-vacuous proof for "writes nothing on a dry run": make the dry-run branch
// write the mapping (drop the `if (write)` guard) and "dry run writes nothing"
// fails on `assert.equal(existsSync(mapping), false)`.

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";

const TOOL = join(dirname(import.meta.filename), "onboard-tracker.mjs");
const dirs = [];

function makeRepo() {
    const d = mkdtempSync(join(tmpdir(), "onboard-tracker-"));
    dirs.push(d);
    return d;
}

function run(...args) {
    const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: "utf8" });
    return { code: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
}

function writeCsv(repo, rel, text) {
    const full = join(repo, rel);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, text, "utf8");
    return full;
}

after(() => {
    for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

test("a dry run infers the mapping, lints it, and writes nothing", () => {
    const repo = makeRepo();
    writeCsv(
        repo,
        "docs/tracker.csv",
        "id,slice,title,status,verification,detail\nS01-01,S01,First thing,done,ran it,x\nS01-02,S01,Second thing,in-progress,tbd,y\n",
    );
    const r = run("--root", repo);
    assert.equal(r.code, 0, r.stderr + r.stdout);
    assert.match(r.stdout, /would write .*trackers\.json/);
    assert.equal(existsSync(join(repo, ".agentq", "trackers.json")), false, "a dry run must not write the mapping");
    assert.equal(existsSync(join(repo, ".agentq")), false, "a dry run must not even create the .agentq directory");
    assert.match(r.stdout, /lint:/); // the real linter ran
});

test("columns, idPattern and status.map are inferred from the headers and values", () => {
    const repo = makeRepo();
    writeCsv(
        repo,
        "plan/t.csv",
        "id,area,item,status,acceptance,notes\nM1,strategy,Do the thing,done,yes,a note\nM2,strategy,Do another,in progress,no,b note\n",
    );
    const r = run("--root", repo, "--json");
    // 'in progress' normalises to in-progress -> mapped; 'active' is absent here so the lint is clean
    assert.equal(r.code, 0, r.stderr + r.stdout);
    const out = JSON.parse(r.stdout);
    const t = out.mapping.trackers[0];
    assert.deepEqual(t.columns, {
        id: "id",
        group: "area",
        title: "item",
        status: "status",
        evidence: "acceptance",
        notes: "notes",
    });
    assert.equal(t.idPattern, "^[A-Za-z]+\\d+$", "M1/M2 share shape LD");
    assert.deepEqual(t.status.map, { done: "done", "in progress": "in-progress" });
    assert.equal(out.wrote, false);
    assert.equal(out.lint.exitCode, 0);
});

test("a status with no canonical spelling is warned and left out of the map, and the lint is non-zero", () => {
    const repo = makeRepo();
    writeCsv(repo, "t.csv", "id,title,status\nA-1,one,active\nA-2,two,done\n");
    const r = run("--root", repo, "--json");
    const out = JSON.parse(r.stdout);
    const t = out.mapping.trackers[0];
    assert.deepEqual(t.status.map, { done: "done" }, "only the canonical-looking token is mapped");
    assert.ok(
        out.warnings.some((w) => w.includes("'active'") && w.includes("no canonical mapping")),
        "an unmappable status is a printed warning",
    );
    assert.ok(out.lint.findings.some((f) => f.kind === "unmapped-status" && f.ref === "A-1"));
    assert.equal(r.code, out.lint.exitCode);
    assert.notEqual(r.code, 0, "an unmapped status must not report success");
});

test("idPattern is omitted and the shapes are printed when ids disagree", () => {
    const repo = makeRepo();
    writeCsv(repo, "t.csv", "id,title,status\nAB-1,one,done\nABC12-3,two,done\n");
    const r = run("--root", repo);
    assert.match(r.stdout, /idPattern:\s+\(omitted\)/);
    assert.match(r.stdout, /do not share one shape/);
    assert.match(r.stdout, /L-D/);
    assert.match(r.stdout, /LD-D/);
});

test("a leading BOM does not hide the id column", () => {
    const repo = makeRepo();
    writeCsv(repo, "t.csv", "\uFEFFid,title,status\nX-1,one,done\n");
    const r = run("--root", repo, "--json");
    const out = JSON.parse(r.stdout);
    assert.equal(out.mapping.trackers[0].columns.id, "id");
    assert.equal(out.mapping.trackers[0].idPattern, "^[A-Za-z]+-\\d+$");
});

test("several candidate CSVs without --file list them and refuse", () => {
    const repo = makeRepo();
    writeCsv(repo, "a.csv", "id,title,status\nA-1,one,done\n");
    writeCsv(repo, "b.csv", "id,title,status\nB-1,two,done\n");
    const r = run("--root", repo);
    assert.equal(r.code, 2, r.stdout);
    assert.match(r.stderr, /2 candidate tracker CSVs/);
    assert.match(r.stderr, /a\.csv/);
    assert.match(r.stderr, /b\.csv/);
    // and --file resolves the ambiguity
    const r2 = run("--root", repo, "--file", "a.csv", "--json");
    assert.equal(r2.code, 0, r2.stderr + r2.stdout);
    assert.equal(JSON.parse(r2.stdout).file, "a.csv");
});

test("a repo with no candidate CSV refuses with exit 2", () => {
    const repo = makeRepo();
    writeCsv(repo, "notes.csv", "hello,world\n1,2\n"); // no id-like header
    const r = run("--root", repo);
    assert.equal(r.code, 2, r.stdout);
    assert.match(r.stderr, /no tracker CSV found/);
});

test("an existing mapping is refused unless --force, and --write writes it", () => {
    const repo = makeRepo();
    writeCsv(repo, "t.csv", "id,title,status\nT-1,one,done\nT-2,two,todo\n");
    mkdirSync(join(repo, ".agentq"), { recursive: true });
    writeFileSync(join(repo, ".agentq", "trackers.json"), "{}\n", "utf8");
    const refused = run("--root", repo);
    assert.equal(refused.code, 2, refused.stdout);
    assert.match(refused.stderr, /already exists/);
    // the hand-written file is untouched
    assert.equal(readFileSync(join(repo, ".agentq", "trackers.json"), "utf8"), "{}\n");
    // --force overwrites it with an inferred, lint-clean mapping
    const forced = run("--root", repo, "--force", "--write");
    assert.equal(forced.code, 0, forced.stderr + forced.stdout);
    const written = JSON.parse(readFileSync(join(repo, ".agentq", "trackers.json"), "utf8"));
    assert.equal(written.repo, join(repo).split(/[\\/]/).pop());
    assert.equal(written.trackers[0].file, "t.csv");
    assert.deepEqual(written.trackers[0].columns, { id: "id", title: "title", status: "status" });
});

test("--write refuses to write a mapping whose required columns are missing", () => {
    const repo = makeRepo();
    // a header that has an id but no title and no status
    writeCsv(repo, "t.csv", "id,note\nT-1,x\nT-2,y\n");
    const r = run("--root", repo, "--file", "t.csv", "--write");
    assert.equal(r.code, 2, r.stdout);
    assert.match(r.stderr, /required column\(s\) title, status could not be inferred/);
    assert.equal(
        existsSync(join(repo, ".agentq", "trackers.json")),
        false,
        "nothing is written when the mapping cannot lint",
    );
});

test("narrative is picked from docs/TRACKER.md when it exists", () => {
    const repo = makeRepo();
    writeCsv(repo, "docs/tracker.csv", "id,title,status\nN-1,one,done\n");
    mkdirSync(join(repo, "docs"), { recursive: true });
    writeFileSync(join(repo, "docs", "TRACKER.md"), "# tracker\nN-1 done\n", "utf8");
    const r = run("--root", repo, "--json");
    const out = JSON.parse(r.stdout);
    assert.deepEqual(out.mapping.narrative, ["docs/TRACKER.md"]);
});
