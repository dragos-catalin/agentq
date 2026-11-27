import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { z } from "zod";
import { call, type Endpoint } from "./client.ts";
import type { TicketView } from "./core.ts";
import { resolveScript, runProcess, runPwsh, type PwshResult } from "./pws.ts";

// --- argument vectors (pure, exported for the tests) ---------------------------------------------
// Every vector is asserted by test/mcp.test.ts. A value is never folded into a joined shell string, so
// an argument that contains a space stays ONE element of the array.
export const mcpArgv = {
    since: (a: { hours?: number | undefined; repo?: string | undefined }): string[] => [
        "since",
        "-Hours",
        String(a.hours ?? 12),
        ...(a.repo ? ["-Repo", a.repo] : []),
    ],
    status: (a: { all?: boolean | undefined; json?: boolean | undefined }): string[] => [
        "status",
        ...(a.all ? ["-All"] : []),
        ...(a.json ? ["-Json"] : []),
    ],
    run: (a: {
        resource?: string | undefined;
        purpose: string;
        command: string[];
        lane?: string | undefined;
        where?: string | undefined;
        ws?: string | undefined;
    }): string[] => [
        "run",
        "-Resource",
        a.resource ?? "build",
        "-Purpose",
        a.purpose,
        ...(a.lane ? ["-Lane", a.lane] : []),
        ...(a.where ? ["-Where", a.where] : []),
        ...(a.ws ? ["-Ws", a.ws] : []),
        "--",
        ...a.command,
    ],
    note: (a: { message: string; repo?: string | undefined }): string[] => [
        "note",
        "-Message",
        a.message,
        ...(a.repo ? ["-Repo", a.repo] : []),
    ],
    lesson: (a: { message: string; repo?: string | undefined; kind?: string | undefined }): string[] => [
        "lesson",
        "-Message",
        a.message,
        ...(a.repo ? ["-Repo", a.repo] : []),
        ...(a.kind ? ["-Kind", a.kind] : []),
    ],
    lessons: (a: { repo?: string | undefined; limit?: number | undefined }): string[] => [
        "lessons",
        ...(a.repo ? ["-Repo", a.repo] : []),
        ...(a.limit ? ["-Limit", String(a.limit)] : []),
    ],
    break: (a: { resource: string; reason: string; id?: string | undefined }): string[] => [
        "break",
        "-Resource",
        a.resource,
        "-Reason",
        a.reason,
        ...(a.id ? ["-Id", a.id] : []),
    ],
    propose: (a: { reason?: string | undefined }): string[] => ["propose", ...(a.reason ? ["-Reason", a.reason] : [])],
    workspace: (a: {
        sub: string;
        name?: string | undefined;
        purpose?: string | undefined;
        force?: boolean | undefined;
        reason?: string | undefined;
    }): string[] => [
        "workspace",
        a.sub,
        ...(a.name ? ["-Name", a.name] : []),
        ...(a.purpose ? ["-Purpose", a.purpose] : []),
        ...(a.force ? ["-Force"] : []),
        ...(a.reason ? ["-Reason", a.reason] : []),
    ],
    lease: (a: {
        purpose: string;
        slot?: string | undefined;
        branch?: string | undefined;
        ref?: string | undefined;
        wait?: boolean | undefined;
        maxMin?: number | undefined;
    }): string[] => [
        "lease",
        "-Purpose",
        a.purpose,
        ...(a.slot ? ["-Slot", a.slot] : []),
        ...(a.branch ? ["-Branch", a.branch] : []),
        ...(a.ref ? ["-Ref", a.ref] : []),
        ...(a.wait ? ["-Wait"] : []),
        ...(a.maxMin !== undefined ? ["-MaxMin", String(a.maxMin)] : []),
    ],
    unlease: (a: {
        repo: string;
        leaseId: string;
        slot?: string | undefined;
        reason?: string | undefined;
        force?: boolean | undefined;
    }): string[] => [
        "unlease",
        "-Repo",
        a.repo,
        "-LeaseId",
        a.leaseId,
        ...(a.slot ? ["-Slot", a.slot] : []),
        ...(a.reason ? ["-Reason", a.reason] : []),
        ...(a.force ? ["-Force"] : []),
    ],
    land: (a: {
        branch: string;
        onto: string;
        purpose: string;
        gate?: string | undefined;
        also?: string[] | undefined;
        rebaseOnConflict?: boolean | undefined;
        force?: boolean | undefined;
    }): string[] => [
        "land",
        "-Branch",
        a.branch,
        "-Onto",
        a.onto,
        "-Purpose",
        a.purpose,
        ...(a.gate ? ["-Gate", a.gate] : []),
        ...(a.also && a.also.length ? ["-Also", a.also.join(",")] : []),
        ...(a.rebaseOnConflict ? ["-RebaseOnConflict"] : []),
        ...(a.force ? ["-Force"] : []),
    ],
    publish: (a: {
        paths: string[];
        message: string;
        purpose: string;
        onto?: string | undefined;
        base?: string | undefined;
        land?: boolean | undefined;
        noPush?: boolean | undefined;
    }): string[] => [
        "publish",
        "-Paths",
        a.paths.join(","),
        "-Message",
        a.message,
        "-Purpose",
        a.purpose,
        ...(a.onto ? ["-Onto", a.onto] : []),
        ...(a.base ? ["-Base", a.base] : []),
        ...(a.land ? ["-Land"] : []),
        ...(a.noPush ? ["-NoPush"] : []),
    ],
    sweep: (a: { whatIf?: boolean | undefined; json?: boolean | undefined }): string[] => [
        "sweep",
        ...(a.whatIf ? ["-WhatIf"] : []),
        ...(a.json ? ["-Json"] : []),
    ],
    jobStart: (a: {
        label: string;
        command: string;
        cwd?: string | undefined;
        expectedMin?: number | undefined;
        repo?: string | undefined;
        priority?: string | undefined;
    }): string[] => [
        "-Label",
        a.label,
        "-Command",
        a.command,
        ...(a.cwd ? ["-Cwd", a.cwd] : []),
        ...(a.expectedMin !== undefined ? ["-ExpectedMin", String(a.expectedMin)] : []),
        ...(a.repo ? ["-Repo", a.repo] : []),
        ...(a.priority ? ["-Priority", a.priority] : []),
    ],
    jobWait: (a: { jobId: string; maxMin?: number | undefined; stallMin?: number | undefined }): string[] => [
        "-JobId",
        a.jobId,
        ...(a.maxMin !== undefined ? ["-MaxMin", String(a.maxMin)] : []),
        ...(a.stallMin !== undefined ? ["-StallMin", String(a.stallMin)] : []),
    ],
    jobList: (a: { all?: boolean | undefined; json?: boolean | undefined }): string[] => [
        "list",
        ...(a.all ? ["-All"] : []),
        ...(a.json ? ["-Json"] : []),
    ],
    cloudSubmit: (a: {
        ws: string;
        purpose: string;
        command: string[];
        lane?: string | undefined;
        timeoutMin?: number | undefined;
        repo?: string | undefined;
        noPatch?: boolean | undefined;
        noInstall?: boolean | undefined;
        staleClaimMin?: number | undefined;
        wakeFirstHealMin?: number | undefined;
        noHeal?: boolean | undefined;
    }): string[] => [
        "-Ws",
        a.ws,
        "-Purpose",
        a.purpose,
        ...(a.lane ? ["-Lane", a.lane] : []),
        ...(a.timeoutMin !== undefined ? ["-TimeoutMin", String(a.timeoutMin)] : []),
        ...(a.repo ? ["-Repo", a.repo] : []),
        ...(a.noPatch ? ["-NoPatch"] : []),
        ...(a.noInstall ? ["-NoInstall"] : []),
        ...(a.staleClaimMin !== undefined ? ["-StaleClaimMin", String(a.staleClaimMin)] : []),
        ...(a.wakeFirstHealMin !== undefined ? ["-WakeFirstHealMin", String(a.wakeFirstHealMin)] : []),
        ...(a.noHeal ? ["-NoHeal"] : []),
        "--",
        ...a.command,
    ],
    // One read-only verb, two shapes: the table for one workspace, or the whole registry as one
    // document. `-Status -Json` ignores `-Ws` by design - the document lists every workspace - so the
    // flag is never sent with it, and a call that names neither is refused rather than guessed at.
    cloudStatus: (a: { ws?: string | undefined; json?: boolean | undefined }): string[] => {
        if (a.json === true) {
            return ["-Status", "-Json"];
        }
        if (a.ws === undefined) {
            throw new Error(
                "cloud_status needs `ws` for the workspace table, or `json: true` for the registry document",
            );
        }
        return ["-Ws", a.ws, "-Status"];
    },
    cloudSuspend: (a: { ws: string }): string[] => ["-Ws", a.ws, "-Suspend"],
    cloudInstance: (verb: "resume" | "reset", a: { ws: string; project: string; zone: string }): string[] => [
        "compute",
        "instances",
        verb,
        `ws-${a.ws}`,
        "--project",
        a.project,
        "--zone",
        a.zone,
    ],
    cloudObject: (bucket: string, id: string, object: string): string[] => [
        "storage",
        "cat",
        `gs://${bucket}/jobs/${id}/${object}`,
    ],
};

// Exit-code legends, so a failed tool call tells the agent what the code means instead of a bare number.
const AGENTQ_EXIT =
    "agentq exit codes: 0 ok, 2 usage, 3 frozen/blocked or timed out, 4 release superseded, 5 land conflict, 6 land pre-gate, 7 lease -Wait bound expired; `run` returns the wrapped command's own code.";
const CLOUD_EXIT =
    "agentq-cloud exit codes: the remote command's own exit; 3 timed out waiting after submit; 4 workspace unavailable and NOTHING submitted; 2 usage.";
const JOBS_EXIT = "job script exit codes: 0 ok, 2 usage, 3 the job is still running (wait-job bound reached).";

// Read-only verbs cannot hang; a generous ceiling only catches a wedged PowerShell.
const FAST_MS = 180_000;

interface CloudTarget {
    project: string;
    zone: string;
}

/** The registry the cloud script itself reads: its agentq-config.json (or $AGENTQ_CONFIG), key `cloudRegistry`. */
function cloudRegistry(): Record<string, CloudTarget> {
    const cfg = process.env["AGENTQ_CONFIG"] ?? join(dirname(resolveScript("agentq-cloud.ps1")), "agentq-config.json");
    try {
        const parsed = JSON.parse(readFileSync(cfg, "utf8")) as { cloudRegistry?: Record<string, CloudTarget> };
        return parsed.cloudRegistry ?? {};
    } catch {
        return {};
    }
}

function cloudTarget(ws: string, project?: string, zone?: string): CloudTarget {
    if (project && zone) return { project, zone };
    const entry = cloudRegistry()[ws];
    if (!entry) {
        const known = Object.keys(cloudRegistry()).join(", ") || "none";
        throw new Error(
            `unknown workspace '${ws}' — not in the cloudRegistry of agentq-config.json (known: ${known}); pass project and zone explicitly`,
        );
    }
    return { project: project ?? entry.project, zone: zone ?? entry.zone };
}

/** The control-plane bucket the cloud script writes logs and results into: gs://<ctlProject>-devcloud-jobs. */
function cloudBucket(ctlProject = "dragos-devcloud"): string {
    return `${ctlProject}-devcloud-jobs`;
}

/**
 * MCP face of the daemon, so any MCP-capable agent can coordinate without a shell.
 * Tickets acquired here are owned by this server process (pid) and heartbeated by it,
 * so they are released when the agent session ends.
 *
 * `acp_*` tools talk to the daemon over JSON-RPC. `agentq_*`, `job_*` and `cloud_*` tools spawn the
 * PowerShell scripts the hooks and a terminal user already call, so the whole tool — not just the
 * daemon's RPC surface — is reachable from an agent.
 */
export function buildMcpServer(ep: Endpoint, session: string): McpServer {
    const server = new McpServer({ name: "agentq", version: "0.1.0" });
    const beats = new Map<string, NodeJS.Timeout>();
    const text = (v: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(v, null, 2) }] });
    const guard = async (fn: () => Promise<unknown>) => {
        try {
            return text(await fn());
        } catch (e) {
            return { ...text({ error: (e as Error).message }), isError: true };
        }
    };
    /** Run a spawn and turn it into a text result; a non-zero code that is not expected becomes isError. */
    const scripted = async (legend: string, fn: () => Promise<PwshResult>, okCodes: number[] = [0]) => {
        let r: PwshResult;
        try {
            r = await fn();
        } catch (e) {
            return { content: [{ type: "text" as const, text: `agentq: ${(e as Error).message}` }], isError: true };
        }
        const body = [r.stdout.replace(/\s+$/, ""), r.stderr.replace(/\s+$/, "")].filter(Boolean).join("\n").trim();
        if (okCodes.includes(r.code))
            return { content: [{ type: "text" as const, text: body || `(no output; exit ${r.code})` }] };
        return {
            content: [{ type: "text" as const, text: `${body || "(no output)"}\n\n${legend} (exit ${r.code})` }],
            isError: true,
        };
    };

    server.registerTool(
        "acp_acquire",
        {
            description:
                "Queue for a shared resource (e.g. build:<repo>, deploy:<repo>:prod) and wait up to waitSeconds for your turn. Returns held=true when it is yours; call acp_release when done. Refused while the resource is frozen.",
            inputSchema: {
                resource: z.string(),
                purpose: z.string().describe("Why you need it; other agents read this"),
                waitSeconds: z.number().int().min(0).max(25).default(25),
                capacity: z.number().int().min(1).optional(),
            },
        },
        ({ resource, purpose, waitSeconds, capacity }) =>
            guard(async () => {
                let t = await call<TicketView>(ep, "acp.acquire", {
                    resource,
                    owner: { session, purpose, pid: process.pid },
                    leaseMs: 60_000,
                    ...(capacity ? { capacity } : {}),
                });
                const timer = setInterval(
                    () => void call(ep, "acp.heartbeat", { ticket: t.id }).catch(() => undefined),
                    20_000,
                );
                timer.unref();
                beats.set(t.id, timer);
                if (!t.held && waitSeconds > 0)
                    t = await call<TicketView>(ep, "acp.wait", { ticket: t.id, timeoutMs: waitSeconds * 1000 });
                return t;
            }),
    );
    server.registerTool(
        "acp_wait",
        {
            description: "Wait up to waitSeconds more for a queued ticket to become held.",
            inputSchema: { ticket: z.string(), waitSeconds: z.number().int().min(1).max(25).default(25) },
        },
        ({ ticket, waitSeconds }) => guard(() => call(ep, "acp.wait", { ticket, timeoutMs: waitSeconds * 1000 })),
    );
    server.registerTool(
        "acp_release",
        {
            description: "Release a ticket you hold or are queued with.",
            inputSchema: { ticket: z.string(), exit: z.number().int().optional() },
        },
        ({ ticket, exit }) =>
            guard(async () => {
                clearInterval(beats.get(ticket));
                beats.delete(ticket);
                return call(ep, "acp.release", { ticket, ...(exit !== undefined ? { exit } : {}) });
            }),
    );
    server.registerTool(
        "acp_status",
        {
            description: "Holders, waiters and freeze marks, optionally for one resource or repo name.",
            inputSchema: { resource: z.string().optional() },
            annotations: { readOnlyHint: true },
        },
        ({ resource }) => guard(() => call(ep, "acp.status", resource ? { resource } : {})),
    );
    server.registerTool(
        "acp_mark",
        {
            description: "Freeze or block a resource with a reason (e.g. during an incident), or clear it.",
            inputSchema: { resource: z.string(), state: z.enum(["frozen", "blocked", "clear"]), reason: z.string() },
        },
        ({ resource, state, reason }) => guard(() => call(ep, "acp.mark", { resource, state, reason, session })),
    );
    server.registerTool(
        "acp_note",
        {
            description: "Leave a handoff note in the shared journal.",
            inputSchema: { message: z.string(), resource: z.string().optional() },
        },
        ({ message, resource }) =>
            guard(() => call(ep, "acp.note", { message, session, ...(resource ? { resource } : {}) })),
    );
    server.registerTool(
        "acp_journal",
        {
            description: "Recent journal entries: who acquired, released, froze or noted what.",
            inputSchema: { limit: z.number().int().min(1).max(200).default(30), resource: z.string().optional() },
            annotations: { readOnlyHint: true },
        },
        ({ limit, resource }) => guard(() => call(ep, "acp.journal", { limit, ...(resource ? { resource } : {}) })),
    );

    // --- coordination: the queue/land verbs a terminal user runs as `agentq <verb>` -----------------

    server.registerTool(
        "agentq_since",
        {
            description:
                "Use before starting work in a repo: what other agents changed here — this repo's journal plus recent git log. Read-only.",
            inputSchema: { hours: z.number().min(1).max(72).default(12), repo: z.string().optional() },
            annotations: { readOnlyHint: true },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.since(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_status",
        {
            description:
                "Holders, waiters, stale tickets, slots, releases and freeze marks. Use to find out why you are queued or who holds a resource. Read-only.",
            inputSchema: { all: z.boolean().default(false), json: z.boolean().default(false) },
            annotations: { readOnlyHint: true },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.status(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_run",
        {
            description:
                "Queue, hold, run and release a build/install/test/deploy command, so it never races another agent's. The command is a token array (never one string); the result is the command's own output and exit code.",
            inputSchema: {
                resource: z
                    .string()
                    .default("build")
                    .describe("Short kind: build|install|deploy:<target>|commit, or a full resource"),
                purpose: z.string().describe("Why you need it; other agents read this"),
                command: z.array(z.string()).min(1).describe("The command as argv tokens, e.g. ['pnpm','build']"),
                lane: z.enum(["interactive", "quick", "gate", "heavy", "batch"]).optional(),
                where: z
                    .enum(["local", "cloud", "auto"])
                    .optional()
                    .describe("Placement; auto uses a warm workspace when it fits"),
                ws: z.string().optional().describe("Cloud workspace name, with where=cloud"),
                timeoutSec: z
                    .number()
                    .int()
                    .min(1)
                    .optional()
                    .describe("Tool-level cap; the queue's own wait is set by agentq"),
            },
        },
        (a) =>
            scripted(AGENTQ_EXIT, () =>
                runPwsh("agentq.ps1", mcpArgv.run(a), a.timeoutSec ? { timeoutMs: a.timeoutSec * 1000 } : {}),
            ),
    );
    server.registerTool(
        "agentq_note",
        {
            description:
                "Leave a free-form handoff note in the shared journal (e.g. 'do not touch apps/x until the migration lands').",
            inputSchema: { message: z.string(), repo: z.string().optional() },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.note(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_lesson",
        {
            description:
                "Record a durable, reusable lesson (symptom -> what you believed -> what proved it -> the fix) so future agents in this repo do not relearn it. One concrete sentence, no secrets.",
            inputSchema: {
                message: z.string().describe("The lesson, one concrete sentence, no secrets"),
                repo: z.string().optional().describe("Repo the lesson applies to, e.g. codai"),
                kind: z.string().optional().describe("Optional short class, e.g. build|git|env|verify"),
            },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.lesson(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_lessons",
        {
            description:
                "List recorded lessons, newest first: read what earlier agents learned in this repo before you start. Read-only.",
            inputSchema: {
                repo: z.string().optional().describe("Only this repo's lessons"),
                limit: z.number().int().min(1).max(200).optional().describe("How many, newest first (default 30)"),
            },
            annotations: { readOnlyHint: true },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.lessons(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_break",
        {
            description:
                "DESTRUCTIVE: removes a stuck ticket from a resource, abandoning whatever holds it. Only pass it when the holder's process is dead or its heartbeat is STALE — never to jump the queue. Needs the resource and a reason.",
            inputSchema: {
                resource: z.string(),
                reason: z.string().describe("Why it is safe to remove; recorded in the journal"),
                id: z.string().optional().describe("Ticket id; required when the resource has more than one ticket"),
            },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.break(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_propose",
        {
            description:
                "Diagnose why you are waiting and APPLY safe remedies (break dead/stale holders, bump a long wait, a short burst when RAM allows). Use when a queue looks stuck. Overrides need a reason of 8+ characters.",
            inputSchema: { reason: z.string().optional() },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.propose(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_workspace",
        {
            description:
                "Register or look up a warm cloud workspace (ADR 0007): take marks it active at you, release frees it, list shows who holds what. take/release need a name; a foreign take needs force and a reason.",
            inputSchema: {
                sub: z.enum(["take", "release", "list"]),
                name: z.string().optional().describe("Lowercase workspace name; required except for list"),
                purpose: z.string().optional(),
                force: z.boolean().default(false).describe("take/release a workspace another holder has"),
                reason: z.string().optional().describe("Required with force"),
            },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.workspace(a), { timeoutMs: FAST_MS })),
    );

    // --- leases and landing --------------------------------------------------------------------------

    server.registerTool(
        "agentq_lease",
        {
            description:
                "Take a worktree slot lease (ADR 0001) and print its path. Use it when you need an isolated checkout. With wait=true it polls up to maxMin for a free slot (exit 7 if the bound expires).",
            inputSchema: {
                purpose: z.string(),
                slot: z.string().optional().describe("e.g. task-2, scratch-1, release"),
                branch: z.string().optional(),
                ref: z.string().optional(),
                wait: z.boolean().default(false),
                maxMin: z.number().min(0).optional().describe("With wait; default 5"),
                timeoutSec: z
                    .number()
                    .int()
                    .min(1)
                    .optional()
                    .describe("Tool-level cap (the lease -Wait bound is separate)"),
            },
        },
        (a) =>
            scripted(AGENTQ_EXIT, () =>
                runPwsh(
                    "agentq.ps1",
                    mcpArgv.lease(a),
                    a.timeoutSec ? { timeoutMs: a.timeoutSec * 1000 } : { timeoutMs: FAST_MS },
                ),
            ),
    );
    server.registerTool(
        "agentq_unlease",
        {
            description:
                "Give back a slot lease; anything unpushed is backed up first. Needs the slot directory (repo) and the lease id `agentq status` printed. Releasing a lease another agent is using needs force.",
            inputSchema: {
                repo: z.string().describe("The slot directory the lease named"),
                leaseId: z.string(),
                slot: z.string().optional(),
                reason: z.string().optional(),
                force: z.boolean().default(false),
            },
        },
        (a) => scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.unlease(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "agentq_land",
        {
            description:
                "DESTRUCTIVE: merges your branch into onto (dev|main) and pushes. Pre-gates the rebased result, then serialised merge+push. Landing is the release train — the branch really moves. Needs branch, onto and a reason.",
            inputSchema: {
                branch: z.string().describe("Topic branch to land"),
                onto: z.string().describe("Target branch, e.g. dev or main"),
                purpose: z.string().describe("Why; shown to other agents on the train"),
                gate: z.string().optional().describe("Pre-gate command run before the merge"),
                also: z.array(z.string()).optional().describe("Extra branches to land in the same batch"),
                rebaseOnConflict: z.boolean().default(false),
                force: z.boolean().default(false),
                timeoutSec: z.number().int().min(1).optional(),
            },
        },
        (a) =>
            scripted(AGENTQ_EXIT, () =>
                runPwsh("agentq.ps1", mcpArgv.land(a), a.timeoutSec ? { timeoutMs: a.timeoutSec * 1000 } : {}),
            ),
    );
    server.registerTool(
        "agentq_publish",
        {
            description:
                "Commit exactly the paths you name (with trailers) and push — the shared-clone-safe commit. With land=true it lands them in one step. Never stages anything you did not list.",
            inputSchema: {
                paths: z.array(z.string()).min(1).describe("Explicit paths; nothing else is staged"),
                message: z.string().describe("Conventional commit message"),
                purpose: z.string(),
                onto: z.string().optional(),
                base: z.string().optional(),
                land: z.boolean().default(false),
                noPush: z.boolean().default(false),
            },
        },
        (a) =>
            scripted(AGENTQ_EXIT, () =>
                runPwsh("agentq.ps1", mcpArgv.publish(a), a.noPush ? { timeoutMs: FAST_MS } : {}),
            ),
    );
    server.registerTool(
        "agentq_sweep",
        {
            description:
                "DESTRUCTIVE housekeeping: reaps dead/stale tickets and leases, rotates the journal and prunes state across the machine. It acts on everything, so pass confirm=true deliberately; whatIf=true only reports. Never run it while another agent is mid-work.",
            inputSchema: {
                confirm: z.boolean().describe("Must be true to sweep; the tool refuses otherwise"),
                whatIf: z.boolean().default(false).describe("Report the changes without writing"),
                json: z.boolean().default(false),
            },
        },
        (a) =>
            a.confirm
                ? scripted(AGENTQ_EXIT, () => runPwsh("agentq.ps1", mcpArgv.sweep(a), { timeoutMs: FAST_MS }))
                : {
                      content: [
                          {
                              type: "text" as const,
                              text: "agentq_sweep refused: pass confirm=true — it acts on every resource on the machine.",
                          },
                      ],
                      isError: true,
                  },
    );

    // --- background jobs -----------------------------------------------------------------------------

    server.registerTool(
        "job_start",
        {
            description:
                "Launch a long command as a registered background job in its own hidden console (never inherit a shared terminal's Ctrl+C), then keep working. Wait only when blocked, with job_wait. Returns the job id and log path.",
            inputSchema: {
                label: z.string().describe("Human label shown in the job list"),
                command: z.string().describe("The PowerShell command line the job runs"),
                cwd: z.string().optional().describe("Working directory; default = this process's cwd"),
                expectedMin: z.number().min(0).default(10).describe("Expected duration; drives the 'suspect' state"),
                repo: z.string().optional(),
                priority: z
                    .enum(["Idle", "BelowNormal", "Normal"])
                    .optional()
                    .describe("Runner priority; default BelowNormal"),
            },
        },
        (a) => scripted(JOBS_EXIT, () => runPwsh("job-start.ps1", mcpArgv.jobStart(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "job_wait",
        {
            description:
                "BOUNDED wait on a background job with stall detection (hard cap 10 min). Use only when every remaining task depends on the job. Exit 0 done, 1 failed, 2 stalled, 3 timed out while still progressing.",
            inputSchema: {
                jobId: z.string(),
                maxMin: z.number().min(0.05).default(10).describe("Hard cap is 10"),
                stallMin: z.number().min(0.05).default(5),
            },
        },
        (a) => scripted(JOBS_EXIT, () => runPwsh("wait-job.ps1", mcpArgv.jobWait(a), { timeoutMs: 660_000 })),
    );
    server.registerTool(
        "job_list",
        {
            description: "List registered background jobs (id, label, state, runtime, log). Read-only.",
            inputSchema: {
                all: z.boolean().default(false).describe("Include finished jobs older than 24 h"),
                json: z.boolean().default(false),
            },
            annotations: { readOnlyHint: true },
        },
        (a) => scripted(JOBS_EXIT, () => runPwsh("jobs.ps1", mcpArgv.jobList(a), { timeoutMs: FAST_MS })),
    );

    // --- cloud workspaces (devcloud) -----------------------------------------------------------------

    server.registerTool(
        "cloud_submit",
        {
            description:
                "Run a command on a devcloud warm workspace: ships the git delta, streams the log and returns the REMOTE exit code. Use it to offload a heavy gate (build/typecheck/test) from this machine. The command is a token array.",
            inputSchema: {
                ws: z.string().describe("Workspace name, e.g. codai or vitals-win"),
                purpose: z.string().min(3).describe("Why; recorded in the cloud journal and the repo's run journal"),
                command: z
                    .array(z.string())
                    .min(1)
                    .describe("Command as argv tokens, e.g. ['pnpm','--filter','web','build']"),
                lane: z.enum(["interactive", "quick", "gate", "heavy", "batch"]).optional().describe("Default gate"),
                timeoutMin: z.number().int().min(1).optional().describe("Remote command budget in minutes; default 60"),
                repo: z.string().optional().describe("Repo directory to ship; default = cwd"),
                noPatch: z
                    .boolean()
                    .default(false)
                    .describe("Ship committed HEAD only, without the working-tree patch"),
                noInstall: z.boolean().default(false),
                staleClaimMin: z
                    .number()
                    .int()
                    .min(0)
                    .optional()
                    .describe("Minutes before the heal reclaims a wedged workspace; default 3"),
                wakeFirstHealMin: z
                    .number()
                    .min(0)
                    .optional()
                    .describe("Minutes before the FIRST heal when THIS run performed the wake; default 0.5"),
                noHeal: z.boolean().default(false),
                timeoutSec: z.number().int().min(1).optional(),
            },
        },
        (a) =>
            scripted(CLOUD_EXIT, () =>
                runPwsh(
                    "agentq-cloud.ps1",
                    mcpArgv.cloudSubmit(a),
                    a.timeoutSec ? { timeoutMs: a.timeoutSec * 1000 } : {},
                ),
            ),
    );
    server.registerTool(
        "cloud_status",
        {
            description:
                "A devcloud workspace's VM state, heartbeat and queued jobs, with a one-line verdict on whether its agent is wedged - or, with json, the whole cloud registry as one JSON document: state, heartbeat age, idle seconds and queue depth per workspace, plus the names of any it could not reach and why. A value that could not be measured is null, never 0. Read-only.",
            inputSchema: {
                ws: z.string().optional().describe("The workspace to report on. Required unless json is true."),
                json: z
                    .boolean()
                    .default(false)
                    .describe(
                        "Return every workspace in the cloud registry as one JSON document instead of one workspace's table.",
                    ),
            },
            annotations: { readOnlyHint: true },
        },
        (a) => scripted(CLOUD_EXIT, () => runPwsh("agentq-cloud.ps1", mcpArgv.cloudStatus(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "cloud_workspaces",
        {
            description: "List the devcloud workspaces this machine knows (their GCP project and zone). Read-only.",
            inputSchema: {},
            annotations: { readOnlyHint: true },
        },
        () => {
            const registry = cloudRegistry();
            const names = Object.keys(registry);
            if (!names.length) return text({ error: "no cloudRegistry in agentq-config.json (or $AGENTQ_CONFIG)" });
            return text(Object.fromEntries(names.map((n) => [n, registry[n]])));
        },
    );
    server.registerTool(
        "cloud_suspend",
        {
            description:
                "DESTRUCTIVE: suspends a devcloud workspace's VM now (its queue stops being read until it is resumed). Name the workspace explicitly.",
            inputSchema: { ws: z.string().describe("Workspace to suspend; required") },
        },
        (a) => scripted(CLOUD_EXIT, () => runPwsh("agentq-cloud.ps1", mcpArgv.cloudSuspend(a), { timeoutMs: FAST_MS })),
    );
    server.registerTool(
        "cloud_resume",
        {
            description:
                "Resume a SUSPENDED devcloud workspace VM. GCE distinguishes resume (suspended) from start (terminated); this does resume. Project and zone come from the cloudRegistry unless given.",
            inputSchema: {
                ws: z.string().describe("Workspace name; required"),
                project: z.string().optional(),
                zone: z.string().optional(),
            },
        },
        (a) =>
            scripted(CLOUD_EXIT, () => {
                const { project, zone } = cloudTarget(a.ws, a.project, a.zone);
                return runProcess("gcloud", mcpArgv.cloudInstance("resume", { ws: a.ws, project, zone }), {
                    timeoutMs: FAST_MS,
                });
            }),
    );
    server.registerTool(
        "cloud_reset",
        {
            description:
                "DESTRUCTIVE: hard-resets a devcloud workspace VM, killing whatever runs on it and re-running the boot script (the same action the cloud submit heal takes when a workspace is wedged). Project and zone come from the cloudRegistry unless given.",
            inputSchema: {
                ws: z.string().describe("Workspace name; required"),
                project: z.string().optional(),
                zone: z.string().optional(),
            },
        },
        (a) =>
            scripted(CLOUD_EXIT, () => {
                const { project, zone } = cloudTarget(a.ws, a.project, a.zone);
                return runProcess("gcloud", mcpArgv.cloudInstance("reset", { ws: a.ws, project, zone }), {
                    timeoutMs: FAST_MS,
                });
            }),
    );
    server.registerTool(
        "cloud_log",
        {
            description:
                "Print a cloud job's log object from the bucket (gs://<ctl>-devcloud-jobs/jobs/<id>/log). Use the job id a cloud_submit printed. Read-only.",
            inputSchema: {
                id: z.string().describe("Job id"),
                ctlProject: z
                    .string()
                    .default("dragos-devcloud")
                    .describe("Control-plane project that owns the bucket"),
            },
            annotations: { readOnlyHint: true },
        },
        (a) =>
            scripted(CLOUD_EXIT, () =>
                runProcess("gcloud", mcpArgv.cloudObject(cloudBucket(a.ctlProject), a.id, "log"), {
                    timeoutMs: FAST_MS,
                }),
            ),
    );
    server.registerTool(
        "cloud_result",
        {
            description:
                "Print a cloud job's result.json from the bucket (the exit code and phase timings). Read-only; complements cloud_log.",
            inputSchema: {
                id: z.string().describe("Job id"),
                ctlProject: z.string().default("dragos-devcloud"),
            },
            annotations: { readOnlyHint: true },
        },
        (a) =>
            scripted(CLOUD_EXIT, () =>
                runProcess("gcloud", mcpArgv.cloudObject(cloudBucket(a.ctlProject), a.id, "result.json"), {
                    timeoutMs: FAST_MS,
                }),
            ),
    );

    return server;
}

export async function runMcp(ep: Endpoint, session: string): Promise<void> {
    const server = buildMcpServer(ep, session);
    await server.connect(new StdioServerTransport());
}
