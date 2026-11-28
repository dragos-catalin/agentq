#!/usr/bin/env node
// track — the portable live-state store for "tracking & resume".
//
// Why it exists: a chat's live state (its goal, what is next, the tasks it is
// carrying, who owns which claim) lived nowhere portable. The todo list died
// with the context window; a claim was a sentence in the transcript two agents
// could not arbitrate; the cross-repo picture was a file only one machine's
// scanner knew how to write. This is one Node CLI - no PowerShell, no compiler,
// no dependency - that works in any clone, any agentq slot, any cloud workspace
// on any OS, so a resume reads a file instead of re-deriving the plan from a log.
//
// Two stores, in the agentq state dir (same place tracker-lint writes its index):
//   $STATE/chats/<session>.plan.json   the session plan  (spec/plan.schema.json)
//   $STATE/tasks/<id>.json             a claimable task  (spec planTask)
// $STATE = $env:AGENTQ_HOME || ~/.codai/coord. Every write is atomic (temp file
// then rename, utf8 with no BOM), so a reader never sees half a record, and a
// claim is serialised with an exclusive lock file so two agents cannot both win.
//
// Exit codes are harness-readable: `status` = total drift (capped 255, 2 when the
// index is missing); `task claim` = 2 when the claim is already held; `task next`
// = 3 when nothing is ready. Read-only except the one file it is asked to write.
//
// Usage:
//   node track.mjs status [--json]
//   node track.mjs plan set  --session <id> --goal <s> [--next a,b] [--done a,b] [--roster a,b] [--handoff <path>]
//   node track.mjs plan show --session <id> [--json]
//   node track.mjs task add   --id <id> [--title s] [--group g] [--status todo] [--dep a,b]
//   node track.mjs task claim --id <id> [--by <agent>]
//   node track.mjs task next  [--by <agent>]
//   node track.mjs task block --id <id> --reason <s>
//   node track.mjs task done  --id <id> [--evidence s]
//   node track.mjs task show  --id <id> [--json]
//   node track.mjs task list  [--json]

import {
    readFileSync,
    writeFileSync,
    existsSync,
    readdirSync,
    mkdirSync,
    renameSync,
    openSync,
    closeSync,
    unlinkSync,
} from "node:fs";
import { join, dirname, resolve } from "node:path";
import { homedir } from "node:os";

const STATE = process.env.AGENTQ_HOME || join(homedir(), ".codai", "coord");
const CHATS = join(STATE, "chats");
const TASKS = join(STATE, "tasks");
const INDEX = join(STATE, "trackers", "index.json");

// The one vocabulary, identical to spec/tracker.schema.json $defs.status for the
// tracker side and planTask.status for the task side: a task that could be
// claimed and a tracker row that is "in-progress" must spell the state the same
// way, or the two halves of "where am I" disagree.
const TASK_STATUS = ["todo", "claimed", "in-progress", "blocked", "review", "done", "dropped"];
const CLAIMABLE = ["todo", "claimed", "in-progress"];
const CLOSED = ["done", "dropped"];

function iso() {
    return new Date().toISOString();
}

// A UTF-8 BOM makes the first key read as `\ufeffid`, which is how a written
// file "breaks consumers": strip it once, at the read, never let a BOM reach
// JSON.parse. Node's writeFileSync("utf8") never emits one, so this only guards
// files other tools (PowerShell Add-Content, an editor) may have touched.
function stripBom(text) {
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readJson(file) {
    try {
        return JSON.parse(stripBom(readFileSync(file, "utf8")));
    } catch {
        return null;
    }
}

// Atomic write: a reader either sees the old file or the whole new one, never a
// half-written record. Temp name carries pid+ms so two writers cannot collide on
// it; rename over an existing target is one operation on both NTFS and POSIX.
function writeJsonAtomic(file, obj) {
    mkdirSync(dirname(file), { recursive: true });
    const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
    writeFileSync(tmp, JSON.stringify(obj, null, 2) + "\n", "utf8");
    renameSync(tmp, file);
}

// Synchronous sleep. There is no blocking sleep in Node's core, and a claim loop
// that yields to the event loop would not be a claim loop. Atomics.wait blocks
// the thread for exactly the timeout when the value is already as expected.
function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// The exclusive lock that makes claim atomic ACROSS processes. A test that only
// ran two claims in one process would prove nothing about two agents; the `wx`
// open is the OS-level "create or fail" primitive that both processes see, so
// the read-modify-write of the claim happens with nobody else inside. A crash
// leaves the lock file behind, so a bounded wait then a take-over keeps a dead
// holder from wedging the store forever.
function withLock(file, fn) {
    const lock = `${file}.lock`;
    mkdirSync(dirname(lock), { recursive: true });
    let fd = null;
    const deadline = Date.now() + 3000;
    for (;;) {
        try {
            fd = openSync(lock, "wx");
            break;
        } catch (e) {
            if (e.code !== "EEXIST") throw e;
            if (Date.now() > deadline) {
                try {
                    unlinkSync(lock);
                } catch {}
                try {
                    fd = openSync(lock, "wx");
                    break;
                } catch {
                    throw e;
                }
            }
            sleepSync(40);
        }
    }
    try {
        return fn();
    } finally {
        try {
            closeSync(fd);
        } catch {}
        try {
            unlinkSync(lock);
        } catch {}
    }
}

function parseArgs(argv) {
    const flags = {};
    const pos = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith("--")) {
            const eq = a.indexOf("=");
            if (eq >= 0) {
                flags[a.slice(2, eq)] = a.slice(eq + 1);
            } else {
                const key = a.slice(2);
                const next = argv[i + 1];
                if (next === undefined || next.startsWith("--")) flags[key] = true;
                else {
                    flags[key] = next;
                    i++;
                }
            }
        } else {
            pos.push(a);
        }
    }
    return { flags, pos };
}

// A comma list from the CLI: `--next a,b` -> ["a","b"]. Whitespace trimmed, an
// empty token dropped, so `--next "a, b,"` reads the way a human wrote it.
function list(value) {
    if (Array.isArray(value)) return value.map((s) => String(s).trim()).filter(Boolean);
    if (typeof value === "string")
        return value
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean);
    return [];
}

function agentId(flags) {
    return flags.by || process.env.AGENTQ_SESSION || process.env.AGENTQ_AGENT || "self";
}

// A task id becomes a filename, so a separator or a traversal is refused here
// rather than turned into a write somewhere else in the tree.
function taskFile(id) {
    if (!id || /[\\/]/.test(id) || id.includes("..")) return null;
    return join(TASKS, `${id}.json`);
}

function loadAllTasks() {
    if (!existsSync(TASKS)) return [];
    const out = [];
    for (const name of readdirSync(TASKS)) {
        if (!name.endsWith(".json")) continue;
        const t = readJson(join(TASKS, name));
        if (t && t.id) out.push(t);
    }
    return out;
}

function byCreatedThenId(a, b) {
    if (a.createdAt && b.createdAt && a.createdAt !== b.createdAt) return a.createdAt < b.createdAt ? -1 : 1;
    return String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0;
}

// A dependency is OPEN unless the task it names is done or dropped. A dep naming
// a task that does not exist is open too: fail-closed, because "I could not find
// the thing this waits on" must never read as "the thing is finished".
function hasOpenDep(task, all) {
    for (const dep of task.deps || []) {
        const d = all.find((t) => t.id === dep);
        if (!d || !CLOSED.includes(d.status)) return true;
    }
    return false;
}

// ---- status -----------------------------------------------------------------

function cmdStatus(flags) {
    if (!existsSync(INDEX)) {
        console.error(`track: no tracker index at ${INDEX}`);
        console.error(`build it:  node tools/tracker-lint.mjs --scan <dir> [<dir> ...]`);
        console.error(`       or: node tools/tracker-lint.mjs --scan --all   (every child of ~/gh)`);
        return 2;
    }
    const index = readJson(INDEX);
    if (!index) {
        console.error(`track: index at ${INDEX} is unreadable (not JSON?)`);
        return 2;
    }
    const repos = Array.isArray(index.repos) ? index.repos : [];
    let totalItems = 0;
    let totalDrift = 0;
    for (const r of repos) {
        const items = (r.trackers || []).reduce((n, t) => n + ((t.items || []).length || 0), 0);
        const drift = (r.drift || []).length;
        totalItems += items;
        totalDrift += drift;
    }
    if (flags.json) {
        process.stdout.write(JSON.stringify(index, null, 2) + "\n");
        return Math.min(totalDrift, 255);
    }
    console.log(`trackers: ${repos.length} repo(s), ${totalItems} item(s)  (generated ${index.generatedAt || "?"})`);
    for (const r of repos) {
        const items = (r.trackers || []).reduce((n, t) => n + ((t.items || []).length || 0), 0);
        console.log(`  ${r.repo}: ${items} item(s), ${(r.drift || []).length} drift`);
    }
    console.log(`total drift: ${totalDrift}`);
    return Math.min(totalDrift, 255);
}

// ---- plan -------------------------------------------------------------------

function planFile(session) {
    return join(CHATS, `${session}.plan.json`);
}

function cmdPlan(sub, flags) {
    const session = flags.session;
    if (!session || session === true) {
        console.error(`track plan ${sub}: --session <id> is required`);
        return 2;
    }
    const file = planFile(session);

    if (sub === "show") {
        const plan = readJson(file);
        if (!plan) {
            console.error(`track: no plan for session '${session}' (${file})`);
            return 2;
        }
        if (flags.json) {
            process.stdout.write(JSON.stringify(plan, null, 2) + "\n");
            return 0;
        }
        const steps = (plan.next || []).map((s) => `${s.title}${s.status ? ` [${s.status}]` : ""}`).join(" | ");
        const roster = (plan.roster || []).map((r) => `${r.agentName}${r.status ? ` [${r.status}]` : ""}`).join(" | ");
        const jobs = (plan.jobs || []).map((j) => j.id).join(" | ");
        const todos = (plan.todos || []).map((t) => `${t.title}${t.status ? ` [${t.status}]` : ""}`).join(" | ");
        console.log(`plan ${session}  (updated ${plan.updatedAt || "?"})`);
        console.log(`  goal: ${plan.goal}`);
        console.log(`  doneMeans: ${(plan.doneMeans || []).join(" | ") || "(none)"}`);
        console.log(`  next: ${steps || "(none)"}`);
        console.log(`  roster: ${roster || "(none)"}`);
        console.log(`  jobs: ${jobs || "(none)"}`);
        console.log(`  todos: ${todos || "(none)"}`);
        if (plan.handoffPath) console.log(`  handoff: ${plan.handoffPath}`);
        return 0;
    }

    if (sub === "set") {
        // Merge onto any existing plan so a later `set --next ...` does not drop
        // the goal a previous call recorded - resume must never lose the one
        // field it exists to keep.
        const plan = readJson(file) || { version: 1, sessionId: session, goal: "", next: [] };
        if (flags.goal !== undefined) plan.goal = flags.goal === true ? "" : flags.goal;
        if (!plan.goal) {
            console.error(`track plan set: --goal <s> is required for a new plan`);
            return 2;
        }
        if (flags.next !== undefined) plan.next = list(flags.next).map((title) => ({ title, status: "todo" }));
        if (flags.done !== undefined) plan.doneMeans = list(flags.done);
        if (flags.roster !== undefined)
            plan.roster = list(flags.roster).map((agentName) => ({ agentName, purpose: "", status: "planned" }));
        if (flags.handoff !== undefined) plan.handoffPath = flags.handoff;
        plan.version = 1;
        plan.sessionId = session;
        plan.updatedAt = iso();
        writeJsonAtomic(file, plan);
        console.log(`plan ${session}: goal="${plan.goal}" next=${(plan.next || []).length} -> ${file}`);
        return 0;
    }

    console.error(`track plan: unknown subcommand '${sub}' (set | show)`);
    return 2;
}

// ---- task -------------------------------------------------------------------

// The claim, factored so `claim` and `next` share one definition of "atomic".
// The whole read-check-write runs inside the exclusive lock, so two agents race
// for the lock, not for the field.
function claimTask(id, by) {
    const file = taskFile(id);
    if (!file) return { rc: 2, task: null, reason: `bad task id '${id}'` };
    return withLock(file, () => {
        const t = readJson(file);
        if (!t) return { rc: 2, task: null, reason: `no task '${id}'` };
        if (t.owner && t.owner !== by) return { rc: 2, task: t, reason: `already claimed by ${t.owner}` };
        if (!CLAIMABLE.includes(t.status)) return { rc: 2, task: t, reason: `status is '${t.status}'` };
        t.owner = by;
        t.status = "claimed";
        t.claimedAt = iso();
        t.updatedAt = iso();
        writeJsonAtomic(file, t);
        return { rc: 0, task: t };
    });
}

function cmdTask(sub, flags) {
    const id = flags.id;

    if (sub === "add") {
        if (!id || id === true) {
            console.error(`track task add: --id <id> is required`);
            return 2;
        }
        const file = taskFile(id);
        if (!file) {
            console.error(`track task add: id '${id}' must not contain a path separator`);
            return 2;
        }
        if (existsSync(file)) {
            console.error(`track: task '${id}' already exists (${file})`);
            return 2;
        }
        const status = flags.status === undefined || flags.status === true ? "todo" : flags.status;
        if (!TASK_STATUS.includes(status)) {
            console.error(`track: status '${status}' is not one of ${TASK_STATUS.join(", ")}`);
            return 2;
        }
        const now = iso();
        const task = {
            version: 1,
            id,
            title: flags.title && flags.title !== true ? flags.title : id,
            status,
            createdAt: now,
            updatedAt: now,
        };
        if (flags.group && flags.group !== true) task.group = flags.group;
        if (flags.dep !== undefined) task.deps = list(flags.dep);
        writeJsonAtomic(file, task);
        console.log(`task ${id} added (status ${status}) -> ${file}`);
        return 0;
    }

    if (sub === "claim") {
        if (!id || id === true) {
            console.error(`track task claim: --id <id> is required`);
            return 2;
        }
        const by = agentId(flags);
        const r = claimTask(id, by);
        if (r.rc !== 0) {
            console.error(`track: cannot claim '${id}': ${r.reason}`);
            return 2;
        }
        console.log(`task ${id}: claimed by ${by}`);
        return 0;
    }

    if (sub === "next") {
        const by = agentId(flags);
        const all = loadAllTasks().sort(byCreatedThenId);
        const ready = all.filter((t) => t.status === "todo" && (!t.owner || t.owner === by) && !hasOpenDep(t, all));
        for (const cand of ready) {
            const r = claimTask(cand.id, by);
            if (r.rc === 0) {
                console.log(`task ${cand.id}: assigned to ${by}`);
                console.log(`  ${cand.title}`);
                return 0;
            }
            // Someone took it between the scan and the lock, or it is not
            // claimable after all: try the next candidate rather than fail.
        }
        console.error(
            `track: no ready task (${by}) - every todo task is claimed by another agent or has an open dependency`,
        );
        return 3;
    }

    if (sub === "block") {
        if (!id || id === true) {
            console.error(`track task block: --id <id> is required`);
            return 2;
        }
        if (flags.reason === undefined || flags.reason === true) {
            console.error(`track task block: --reason <s> is required`);
            return 2;
        }
        const file = taskFile(id);
        if (!file) {
            console.error(`track: bad task id '${id}'`);
            return 2;
        }
        return withLock(file, () => {
            const t = readJson(file);
            if (!t) {
                console.error(`track: no task '${id}'`);
                return 2;
            }
            t.status = "blocked";
            t.blockReason = flags.reason;
            t.updatedAt = iso();
            writeJsonAtomic(file, t);
            console.log(`task ${id}: blocked - ${flags.reason}`);
            return 0;
        });
    }

    if (sub === "done") {
        if (!id || id === true) {
            console.error(`track task done: --id <id> is required`);
            return 2;
        }
        const file = taskFile(id);
        if (!file) {
            console.error(`track: bad task id '${id}'`);
            return 2;
        }
        return withLock(file, () => {
            const t = readJson(file);
            if (!t) {
                console.error(`track: no task '${id}'`);
                return 2;
            }
            t.status = "done";
            if (flags.evidence !== undefined && flags.evidence !== true) t.evidence = flags.evidence;
            t.doneAt = iso();
            t.updatedAt = iso();
            writeJsonAtomic(file, t);
            console.log(`task ${id}: done${t.evidence ? ` (${t.evidence})` : ""}`);
            return 0;
        });
    }

    if (sub === "show") {
        if (!id || id === true) {
            console.error(`track task show: --id <id> is required`);
            return 2;
        }
        const file = taskFile(id);
        const t = file ? readJson(file) : null;
        if (!t) {
            console.error(`track: no task '${id}'`);
            return 2;
        }
        if (flags.json) {
            process.stdout.write(JSON.stringify(t, null, 2) + "\n");
            return 0;
        }
        console.log(`${t.id}  [${t.status}]  ${t.title}`);
        if (t.owner) console.log(`  owner: ${t.owner}${t.claimedAt ? ` (${t.claimedAt})` : ""}`);
        if (t.group) console.log(`  group: ${t.group}`);
        if (t.deps && t.deps.length) console.log(`  deps: ${t.deps.join(", ")}`);
        if (t.blockReason) console.log(`  blocked: ${t.blockReason}`);
        if (t.evidence) console.log(`  evidence: ${t.evidence}`);
        console.log(`  updated: ${t.updatedAt || "?"}`);
        return 0;
    }

    if (sub === "list") {
        const all = loadAllTasks().sort(byCreatedThenId);
        if (flags.json) {
            process.stdout.write(JSON.stringify(all, null, 2) + "\n");
            return 0;
        }
        if (all.length === 0) {
            console.log(`tasks: none (${TASKS})`);
            return 0;
        }
        for (const t of all) {
            const who = t.owner ? ` @${t.owner}` : "";
            const deps = t.deps && t.deps.length ? ` deps=[${t.deps.join(",")}]` : "";
            console.log(`  ${t.status.padEnd(11)} ${t.id}${who}${deps}  ${t.title}`);
        }
        console.log(`tasks: ${all.length} (${TASKS})`);
        return 0;
    }

    console.error(`track task: unknown subcommand '${sub}' (add | claim | next | block | done | show | list)`);
    return 2;
}

// ---- dispatch ---------------------------------------------------------------

function usage() {
    console.error(
        [
            `track — the portable live-state store (state: ${STATE})`,
            `  track status [--json]`,
            `  track plan set  --session <id> --goal <s> [--next a,b] [--done a,b] [--roster a,b] [--handoff <path>]`,
            `  track plan show --session <id> [--json]`,
            `  track task add   --id <id> [--title s] [--group g] [--status todo] [--dep a,b]`,
            `  track task claim --id <id> [--by <agent>]`,
            `  track task next  [--by <agent>]`,
            `  track task block --id <id> --reason <s>`,
            `  track task done  --id <id> [--evidence s]`,
            `  track task show  --id <id> [--json]`,
            `  track task list  [--json]`,
        ].join("\n"),
    );
}

export function run(argv) {
    const { flags, pos } = parseArgs(argv);
    const cmd = pos[0];
    if (!cmd) {
        usage();
        return 2;
    }
    if (cmd === "status") return cmdStatus(flags);
    if (cmd === "plan") return cmdPlan(pos[1], flags);
    if (cmd === "task") return cmdTask(pos[1], flags);
    usage();
    return 2;
}

// Run only when invoked as the entry point, so a test can import `run`/helpers
// without the module reading the test runner's own argv. import.meta.filename is
// the script's real path (Node 20.11+), no node:url needed.
if (import.meta.filename && process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
    process.exit(run(process.argv.slice(2)));
}
