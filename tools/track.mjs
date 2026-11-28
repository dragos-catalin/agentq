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
// Exit codes are harness-readable: `status` = total drift + root issues (capped
// 255, 2 when the index is missing); `task claim` = 2 when the claim is already
// held; `task next` = 3 when nothing is ready. Read-only except the one file it
// is asked to write.
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
//   node track.mjs roster [--session <id>] [--json]
//   node track.mjs export [--out <.agentq/state.json>]
//   node track.mjs import [--in  <.agentq/state.json>] [--json]
//   node track.mjs drift  [--repo <dir>] [--json]

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
import { spawnSync } from "node:child_process";
// The drift computation lives in tracker-lint and is NOT re-implemented here:
// `track drift` imports the very same scanRepo that wrote the index, so the two
// can never disagree about what a drift finding is.
import { scanRepo } from "./tracker-lint.mjs";

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

// ---- shared helpers (roster / export / import / drift) ----------------------

// A claim's session, for a record written before `session` existed: the owner is
// the best stand-in, so an old task still shows up in the roster of whoever holds
// it. Never invents a session - falls back to the owner, then to "self".
function taskSession(t) {
    return t.session || t.owner || "self";
}

// The session this process acts for, unless the caller names one. `--session`
// wins, then the environment, then "self" - the same precedence a claim uses.
function currentSession(flags) {
    if (flags.session && flags.session !== true) return flags.session;
    return process.env.AGENTQ_SESSION || process.env.AGENTQ_AGENT || "self";
}

// The claim context: who owns it (`by`), which session claimed it (`session`) and,
// for a subagent, the session it ran under (`parent`). Kept in one place so claim
// and next cannot stamp a task differently.
function claimContext(flags) {
    const by = agentId(flags);
    const session =
        flags.session && flags.session !== true
            ? flags.session
            : process.env.AGENTQ_SESSION || process.env.AGENTQ_AGENT || by;
    const parent = flags.parent && flags.parent !== true ? flags.parent : undefined;
    return { by, session, parent };
}

// ISO timestamps compare correctly as strings; a missing one sorts oldest, so a
// record with no updatedAt never wins a merge against one that has it.
function compareTs(a, b) {
    const x = a || "";
    const y = b || "";
    return x < y ? -1 : x > y ? 1 : 0;
}

// A canonical form for equality and for deterministic export: keys sorted at
// every depth, arrays left as the caller ordered them (the caller applies a
// stable sort). Two records are "the same" iff their canonical forms match, so a
// merge compares content, not key order.
function sortKeysDeep(v) {
    if (Array.isArray(v)) return v.map(sortKeysDeep);
    if (v && typeof v === "object") {
        const out = {};
        for (const k of Object.keys(v).sort()) out[k] = sortKeysDeep(v[k]);
        return out;
    }
    return v;
}

function canonical(v) {
    return JSON.stringify(sortKeysDeep(v));
}

// ---- status -----------------------------------------------------------------

// Does the root this repo was indexed under still carry the mapping that made
// it a repo at all? The index is keyed by a root that may be a worktree slot
// while the shared clone is the copy a reader actually opens; a root that has
// quietly lost its `.agentq/trackers.json` is the "missing card with no
// explanation" this records. Only when the file is absent do we ask git - an
// exit-0 `cat-file -e` proves the mapping still lives on origin/main - and a
// missing git, or a root that is not a repository, is never an error: it just
// means the mapping is simply gone. This is the ONE definition of root health;
// tracker-lint imports it so the scan and the status report cannot disagree
// (the mirror of how track imports scanRepo from tracker-lint).
export function rootIssueFor(root) {
    if (!root) return null;
    if (existsSync(join(root, ".agentq", "trackers.json"))) return null;
    try {
        const r = spawnSync("git", ["-C", root, "cat-file", "-e", "origin/main:.agentq/trackers.json"], {
            stdio: "ignore",
        });
        if (r && r.status === 0) return "mapping-on-origin-main-only";
    } catch {
        // git is not installed, or the root is not a repository: not a reason to
        // fail the command, only to report the mapping as simply missing.
    }
    return "mapping-missing-at-root";
}

// The ONE place a repo's live index entry is reduced to (items, drift). `track
// status` and `track drift` both read the index through this, so the number a
// drift check compares against is the same number status prints.
function summarizeRepo(r) {
    const items = (r.trackers || []).reduce((n, t) => n + ((t.items || []).length || 0), 0);
    const drift = (r.drift || []).length;
    return { items, drift };
}

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
    let totalIssues = 0;
    for (const r of repos) {
        const { items, drift } = summarizeRepo(r);
        totalItems += items;
        totalDrift += drift;
        if (r.rootIssue) totalIssues++;
    }
    // A root issue is a finding too: a harness that reads the exit code must see
    // a broken root even when the trackers under it happen to be drift-free.
    const rc = Math.min(totalDrift + totalIssues, 255);
    if (flags.json) {
        process.stdout.write(JSON.stringify(index, null, 2) + "\n");
        return rc;
    }
    console.log(`trackers: ${repos.length} repo(s), ${totalItems} item(s)  (generated ${index.generatedAt || "?"})`);
    for (const r of repos) {
        const { items, drift } = summarizeRepo(r);
        console.log(`  ${r.repo}: ${items} item(s), ${drift} drift`);
    }
    // A root that lost its mapping "has no card": name the repo, the root and
    // the issue, so a consumer can tell a broken root from a repo that was never
    // tracked at all.
    for (const r of repos) {
        if (r.rootIssue) console.log(`  root [${r.repo}] ${r.root} - ${r.rootIssue}`);
    }
    console.log(`total drift: ${totalDrift}${totalIssues ? `, ${totalIssues} root issue(s)` : ""}`);
    return rc;
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
function claimTask(id, ctx) {
    const { by, session, parent } = ctx;
    const file = taskFile(id);
    if (!file) return { rc: 2, task: null, reason: `bad task id '${id}'` };
    return withLock(file, () => {
        const t = readJson(file);
        if (!t) return { rc: 2, task: null, reason: `no task '${id}'` };
        if (t.owner && t.owner !== by) return { rc: 2, task: t, reason: `already claimed by ${t.owner}` };
        if (!CLAIMABLE.includes(t.status)) return { rc: 2, task: t, reason: `status is '${t.status}'` };
        t.owner = by;
        // The claiming session is recorded so `roster` can group claims by the
        // session (and its children) that holds them - an agent name alone cannot
        // tell a parent from its subagents.
        t.session = session;
        // A subagent records the session it ran under, so the parent's roster
        // finds it without the parent tracking each child by hand.
        if (parent) t.parent = parent;
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
        const ctx = claimContext(flags);
        const r = claimTask(id, ctx);
        if (r.rc !== 0) {
            console.error(`track: cannot claim '${id}': ${r.reason}`);
            return 2;
        }
        console.log(
            `task ${id}: claimed by ${ctx.by}${ctx.parent ? ` (session ${ctx.session}, under ${ctx.parent})` : ` (session ${ctx.session})`}`,
        );
        return 0;
    }

    if (sub === "next") {
        const ctx = claimContext(flags);
        const by = ctx.by;
        const all = loadAllTasks().sort(byCreatedThenId);
        const ready = all.filter((t) => t.status === "todo" && (!t.owner || t.owner === by) && !hasOpenDep(t, all));
        for (const cand of ready) {
            const r = claimTask(cand.id, ctx);
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

// ---- roster -----------------------------------------------------------------

// Every claim held by a session AND by its descendants, so a parent agent sees
// what its subagents claimed without asking each one. The link is `parent` on a
// claim; the walk is transitive because a child may itself dispatch a child.
function cmdRoster(flags) {
    const root = currentSession(flags);
    const all = loadAllTasks();
    const sessions = new Set([root]);
    let changed = true;
    while (changed) {
        changed = false;
        for (const t of all) {
            const s = taskSession(t);
            if (t.parent && sessions.has(t.parent) && !sessions.has(s)) {
                sessions.add(s);
                changed = true;
            }
        }
    }
    const tasks = all.filter((t) => sessions.has(taskSession(t))).sort(byCreatedThenId);
    if (flags.json) {
        process.stdout.write(JSON.stringify({ session: root, sessions: [...sessions].sort(), tasks }, null, 2) + "\n");
        return 0;
    }
    console.log(`roster for '${root}': ${tasks.length} claim(s) across ${sessions.size} session(s)`);
    for (const t of tasks) {
        console.log(`  ${String(t.status).padEnd(11)} ${t.id} @${taskSession(t)}  ${t.title}`);
    }
    return 0;
}

// ---- export / import --------------------------------------------------------

function byId(a, b) {
    return String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0;
}

function bySessionId(a, b) {
    return String(a.sessionId) < String(b.sessionId) ? -1 : String(a.sessionId) > String(b.sessionId) ? 1 : 0;
}

function loadAllPlans() {
    if (!existsSync(CHATS)) return [];
    const out = [];
    for (const name of readdirSync(CHATS)) {
        if (!name.endsWith(".plan.json")) continue;
        const p = readJson(join(CHATS, name));
        if (p && p.sessionId) out.push(p);
    }
    return out;
}

// Default to a path a commit carries: inside the repo, beside the tracker
// definition, so `git add .agentq/state.json` publishes this machine's live state.
function defaultStatePath() {
    return join(process.cwd(), ".agentq", "state.json");
}

// Export ONE deterministic JSON: keys sorted at every depth, arrays stably
// ordered by id/sessionId, the only time-varying field the explicit exportedAt.
// Two exports of the same state differ in exactly that one line, so a diff in git
// is a real state change and nothing else.
function cmdExport(flags) {
    const out = flags.out && flags.out !== true ? resolve(flags.out) : defaultStatePath();
    const tasks = loadAllTasks().sort(byId);
    const plans = loadAllPlans().sort(bySessionId);
    const payload = { version: 1, exportedAt: iso(), tasks, plans };
    writeJsonAtomic(out, sortKeysDeep(payload));
    console.log(`export: ${tasks.length} task(s), ${plans.length} plan(s) -> ${out}`);
    return 0;
}

// Merge ONE incoming record into the local store, conservatively. The rule is
// never to lose a local claim and never to overwrite a newer local record; when
// neither side can be chosen safely it is a CONFLICT, reported, and the local
// record is left untouched. Runs under the same exclusive lock a claim uses, so
// an import cannot race a concurrent claim.
function mergeRecord(file, incoming, key) {
    return withLock(file, () => {
        const local = readJson(file);
        if (!local) {
            writeJsonAtomic(file, incoming);
            return { action: "added" };
        }
        if (canonical(local) === canonical(incoming)) return { action: "unchanged" };
        // A local claim that the incoming record would drop or change is a
        // conflict: another machine's state must never release a claim held here.
        if (local.owner && local.owner !== incoming.owner) {
            return {
                action: "conflict",
                conflict: {
                    kind: "owner-divergence",
                    id: key,
                    local: local.owner,
                    incoming: incoming.owner || "(none)",
                },
            };
        }
        const cmp = compareTs(local.updatedAt, incoming.updatedAt);
        if (cmp > 0) {
            return {
                action: "conflict",
                conflict: {
                    kind: "newer-local",
                    id: key,
                    local: local.updatedAt,
                    incoming: incoming.updatedAt || "(none)",
                },
            };
        }
        if (cmp < 0) {
            writeJsonAtomic(file, incoming);
            return { action: "updated" };
        }
        // Same timestamp, different content, no claim at stake: still ambiguous.
        return { action: "conflict", conflict: { kind: "divergence", id: key } };
    });
}

function cmdImport(flags) {
    const inPath = flags.in && flags.in !== true ? resolve(flags.in) : defaultStatePath();
    const data = readJson(inPath);
    if (!data) {
        console.error(`track import: cannot read ${inPath}`);
        return 2;
    }
    const report = {
        path: inPath,
        source: data.exportedAt || null,
        added: [],
        updated: [],
        unchanged: [],
        conflicts: [],
    };
    for (const t of data.tasks || []) {
        if (!t || !t.id) continue;
        const file = taskFile(t.id);
        if (!file) {
            report.conflicts.push({ kind: "bad-id", id: t.id });
            continue;
        }
        const r = mergeRecord(file, t, t.id);
        if (r.action === "conflict") report.conflicts.push(r.conflict);
        else report[r.action].push(t.id);
    }
    for (const p of data.plans || []) {
        if (!p || !p.sessionId) continue;
        const r = mergeRecord(planFile(p.sessionId), p, p.sessionId);
        if (r.action === "conflict") report.conflicts.push(r.conflict);
        else report[r.action].push(p.sessionId);
    }
    if (flags.json) {
        process.stdout.write(JSON.stringify(report, null, 2) + "\n");
    } else {
        console.log(
            `import ${report.path}: +${report.added.length} added, ~${report.updated.length} updated, ` +
                `=${report.unchanged.length} unchanged, !${report.conflicts.length} conflict(s)`,
        );
        for (const c of report.conflicts) {
            const extra = c.local !== undefined ? ` (local ${c.local}, incoming ${c.incoming})` : "";
            console.log(`  conflict [${c.kind}] ${c.id}${extra}`);
        }
    }
    // A conflict is unresolved by definition: exit non-zero so a script cannot
    // mistake "merged with doubts" for "merged".
    return report.conflicts.length > 0 ? 1 : 0;
}

// ---- drift ------------------------------------------------------------------

// Does a repo's live definition still agree with the index that was built from
// it? Recomputed with scanRepo - the very function that wrote the index - so the
// two sides are compared against one definition of a drift finding, never a fork.
function cmdDrift(flags) {
    const root = flags.repo && flags.repo !== true ? resolve(flags.repo) : process.cwd();
    let live;
    try {
        live = scanRepo(root);
    } catch (e) {
        console.error(`track drift: scan of ${root} failed: ${e.message}`);
        return 2;
    }
    if (!live) {
        console.error(`track drift: no .agentq/trackers.json under ${root}`);
        return 2;
    }
    const index = existsSync(INDEX) ? readJson(INDEX) : null;
    const repos = index && Array.isArray(index.repos) ? index.repos : [];
    const norm = (p) => (p ? resolve(String(p)) : "");
    const recorded = repos.find((r) => norm(r.root) === norm(live.root) || r.repo === live.repo) || null;
    const findings = [];
    if (!recorded) {
        findings.push({
            kind: "repo-not-indexed",
            ref: live.repo,
            detail: `no index entry for ${live.root}; rebuild with tracker-lint --scan`,
        });
    } else {
        const liveT = new Map((live.trackers || []).map((t) => [t.id, t]));
        const recT = new Map((recorded.trackers || []).map((t) => [t.id, t]));
        for (const [id, t] of liveT) {
            const r = recT.get(id);
            if (!r) {
                findings.push({
                    kind: "tracker-not-indexed",
                    ref: id,
                    detail: "tracker in the definition, not in the index",
                });
                continue;
            }
            const li = (t.items || []).length;
            const ri = (r.items || []).length;
            if (li !== ri) findings.push({ kind: "row-count", ref: id, detail: `index ${ri}, definition ${li}` });
            const lc = t.countsByStatus || {};
            const rc = r.countsByStatus || {};
            for (const s of new Set([...Object.keys(lc), ...Object.keys(rc)])) {
                if ((lc[s] || 0) !== (rc[s] || 0))
                    findings.push({
                        kind: "status-count",
                        ref: `${id}:${s}`,
                        detail: `index ${rc[s] || 0}, definition ${lc[s] || 0}`,
                    });
            }
        }
        for (const id of recT.keys()) {
            if (!liveT.has(id))
                findings.push({ kind: "tracker-removed", ref: id, detail: "index tracker gone from the definition" });
        }
        const key = (d) => `${d.kind}|${d.tracker}|${d.ref}`;
        const recKeys = new Set((recorded.drift || []).map(key));
        for (const d of live.drift || []) {
            if (!recKeys.has(key(d)))
                findings.push({
                    kind: "drift-not-indexed",
                    ref: d.ref,
                    detail: `${d.kind} (${d.tracker}) - live, absent from the index`,
                });
        }
        const liveKeys = new Set((live.drift || []).map(key));
        for (const d of recorded.drift || []) {
            if (!liveKeys.has(key(d)))
                findings.push({
                    kind: "stale-drift",
                    ref: d.ref,
                    detail: `${d.kind} (${d.tracker}) - in the index, not in the definition`,
                });
        }
    }
    if (flags.json) {
        process.stdout.write(
            JSON.stringify({ repo: live.repo, root: live.root, indexed: !!recorded, findings }, null, 2) + "\n",
        );
    } else if (findings.length === 0) {
        console.log(`drift ${live.repo}: clean (definition agrees with the index)`);
    } else {
        console.log(`drift ${live.repo}: ${findings.length} disagreement(s) with the index`);
        for (const f of findings) console.log(`  [${f.kind}] ${f.ref} - ${f.detail}`);
    }
    return findings.length === 0 ? 0 : 1;
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
            `  track roster [--session <id>] [--json]`,
            `  track export [--out <path>]      (default .agentq/state.json in the repo)`,
            `  track import [--in  <path>] [--json]`,
            `  track drift  [--repo <dir>] [--json]`,
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
    if (cmd === "roster") return cmdRoster(flags);
    if (cmd === "export") return cmdExport(flags);
    if (cmd === "import") return cmdImport(flags);
    if (cmd === "drift") return cmdDrift(flags);
    usage();
    return 2;
}

// Run only when invoked as the entry point, so a test can import `run`/helpers
// without the module reading the test runner's own argv. import.meta.filename is
// the script's real path (Node 20.11+), no node:url needed.
if (import.meta.filename && process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
    process.exit(run(process.argv.slice(2)));
}
