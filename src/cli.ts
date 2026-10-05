#!/usr/bin/env node
import { spawn } from "node:child_process";
import { hostname } from "node:os";
import { parseArgs } from "node:util";
import { call, connect, hold, readEndpoint, RpcError, stateDir } from "./client.ts";
import type { ResourceStatus } from "./core.ts";
import { startDaemon } from "./daemon.ts";
import type { JournalEntry } from "./journal.ts";
import { runMcp } from "./mcp.ts";

export const VERSION = "0.1.0";

const HELP = `agentq ${VERSION} — coordinate builds, installs, commits and deploys between agents

Usage:
  agentq daemon                                    run the coordinator (auto-started by other commands)
  agentq run -r <resource> -p <purpose> -- <cmd>   queue, hold, run, release (exit = command's exit)
  agentq status [resource]                         holders, waiters, freeze marks
  agentq mark -r <resource> --state frozen|blocked|clear --reason <why>
  agentq break <ticket> --reason <why>             remove a stuck ticket
  agentq note <message> [-r <resource>]            leave a handoff in the journal
  agentq log [--limit N] [-r <resource>]           recent journal entries
  agentq verify-journal                            check the hash chain
  agentq mcp                                       MCP server (stdio) for agents

Options:
  -r, --resource   e.g. build:myrepo, install:myrepo, deploy:myrepo:prod (lowercase, ':'-separated)
  -p, --purpose    why you need it; other agents read it
  --capacity       holders allowed at once (set on first use, e.g. build:machine = 2)
  --timeout        minutes to wait for a turn (default 60)
  --json           machine-readable output

State: $AGENTQ_HOME (default ~/.agentq). Session id: $AGENTQ_SESSION, else <host>-<ppid>.
Exit codes: 0 ok, 2 usage, 3 refused (frozen/blocked) or timed out; run returns the command's code.`;

function session(): string {
    return (
        process.env["AGENTQ_SESSION"] ??
        process.env["CLAUDE_SESSION_ID"] ??
        process.env["COPILOT_SESSION_ID"] ??
        `${hostname()}-${process.ppid}`
    );
}

/** Run argv without a shell. On Windows, `pnpm`/`npx` are .cmd shims: retry through cmd.exe with every arg quoted. */
function runCommand(argv: string[], env: NodeJS.ProcessEnv): Promise<number> {
    const once = (file: string, args: string[], verbatim: boolean): Promise<number | "enoent"> =>
        new Promise((resolve) => {
            const child = spawn(file, args, { stdio: "inherit", env, windowsVerbatimArguments: verbatim });
            child.on("exit", (c, sig) => resolve(c ?? (sig ? 1 : 0)));
            child.on("error", (e: NodeJS.ErrnoException) => {
                if (e.code === "ENOENT") resolve("enoent");
                else {
                    console.error(`agentq: ${e.message}`);
                    resolve(127);
                }
            });
        });
    const quote = (a: string): string =>
        /^[\w./:\\=@+-]+$/.test(a) ? a : `"${a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, "$1$1")}"`;
    return once(argv[0]!, argv.slice(1), false).then((r) => {
        if (r !== "enoent") return r;
        if (process.platform !== "win32") {
            console.error(`agentq: command not found: ${argv[0]}`);
            return 127;
        }
        const line = `"${argv.map(quote).join(" ")}"`;
        return once(process.env["ComSpec"] ?? "cmd.exe", ["/d", "/s", "/c", line], true).then((x) =>
            x === "enoent" ? 127 : x,
        );
    });
}

function formatStatus(rows: ResourceStatus[]): string {
    if (rows.length === 0) return "idle";
    const lines: string[] = [];
    for (const r of rows) {
        const m = r.mark ? `  [${r.mark.state.toUpperCase()}: ${r.mark.reason}]` : "";
        lines.push(`${r.resource} (capacity ${r.capacity})${m}`);
        for (const t of [...r.holders, ...r.waiters]) {
            const age = Math.round((Date.now() - t.created) / 6000) / 10;
            lines.push(
                `  ${t.held ? "HOLD " : `wait#${t.position - r.capacity + 1}`} ${t.id} ${t.owner.session} "${t.owner.purpose}" ${age}m`,
            );
        }
    }
    return lines.join("\n");
}

const formatEntry = (e: JournalEntry): string =>
    `${e.ts.slice(0, 19).replace("T", " ")} #${e.seq} ${e.event.padEnd(8)} ${(e.resource ?? "").padEnd(28)} ${e.session} ${e.purpose ?? e.message ?? ""}${e.reason ? ` (${e.reason})` : ""}${e.exit !== undefined ? ` exit=${e.exit}` : ""}`;

async function main(argv: string[]): Promise<number> {
    const dd = argv.indexOf("--");
    const command = dd >= 0 ? argv.slice(dd + 1) : [];
    const { values, positionals } = parseArgs({
        args: dd >= 0 ? argv.slice(0, dd) : argv,
        allowPositionals: true,
        options: {
            resource: { type: "string", short: "r" },
            purpose: { type: "string", short: "p" },
            state: { type: "string" },
            reason: { type: "string" },
            capacity: { type: "string" },
            timeout: { type: "string", default: "60" },
            limit: { type: "string", default: "30" },
            port: { type: "string" },
            json: { type: "boolean", default: false },
            help: { type: "boolean", short: "h", default: false },
            version: { type: "boolean", short: "v", default: false },
        },
    });
    if (values.version) {
        console.log(VERSION);
        return 0;
    }
    const [cmd, ...rest] = positionals;
    const known = ["daemon", "run", "status", "mark", "break", "note", "log", "verify-journal", "mcp"];
    if (values.help || !cmd || !known.includes(cmd)) {
        console.log(HELP);
        return values.help ? 0 : 2;
    }
    const dir = stateDir();
    const out = (v: unknown, text: string): void => console.log(values.json ? JSON.stringify(v, null, 2) : text);

    if (cmd === "daemon") {
        const running = readEndpoint(dir);
        if (running) {
            try {
                await call(running, "acp.hello", {}, 2_000);
                console.error(`agentq: a daemon already answers at ${running.url}`);
                return 2;
            } catch {
                /* stale discovery file: take over */
            }
        }
        const d = await startDaemon({
            dir,
            ...(values.port ? { port: Number(values.port) } : {}),
            capacities: { "build:machine": 2 },
        });
        console.error(`agentq daemon on ${d.url} (state ${dir})`);
        const stop = (): void => void d.close().then(() => process.exit(0));
        process.on("SIGINT", stop);
        process.on("SIGTERM", stop);
        return await new Promise<number>(() => undefined);
    }

    const ep = await connect({ dir });

    switch (cmd) {
        case "run": {
            if (!values.resource || !values.purpose || command.length === 0) {
                console.error("agentq run: needs -r <resource> -p <purpose> -- <command>");
                return 2;
            }
            const h = await hold(
                ep,
                {
                    resource: values.resource,
                    owner: { session: session(), purpose: values.purpose, pid: process.pid, host: hostname() },
                    timeoutMs: Number(values.timeout) * 60_000,
                    ...(values.capacity ? { capacity: Number(values.capacity) } : {}),
                },
                (t) => console.error(`agentq: waiting for ${t.resource}, position ${t.position + 1}`),
            );
            const code = await runCommand(command, {
                ...process.env,
                AGENTQ_HELD: [process.env["AGENTQ_HELD"], values.resource].filter(Boolean).join(","),
            });
            await h.release(code);
            return code;
        }
        case "status": {
            const rows = await call<ResourceStatus[]>(ep, "acp.status", rest[0] ? { resource: rest[0] } : {});
            out(rows, formatStatus(rows));
            return 0;
        }
        case "mark": {
            if (!values.resource || !values.state || !values.reason) {
                console.error("agentq mark: needs -r <resource> --state frozen|blocked|clear --reason <why>");
                return 2;
            }
            const m = await call(ep, "acp.mark", {
                resource: values.resource,
                state: values.state,
                reason: values.reason,
                session: session(),
            });
            out(
                m,
                values.state === "clear" ? `cleared ${values.resource}` : `${values.resource} marked ${values.state}`,
            );
            return 0;
        }
        case "break": {
            if (!rest[0] || !values.reason) {
                console.error("agentq break: needs <ticket> --reason <why>");
                return 2;
            }
            const t = await call(ep, "acp.break", { ticket: rest[0], reason: values.reason, session: session() });
            out(t, `broke ${rest[0]}`);
            return 0;
        }
        case "note": {
            if (!rest.length) {
                console.error("agentq note: needs a message");
                return 2;
            }
            const e = await call<JournalEntry>(ep, "acp.note", {
                message: rest.join(" "),
                session: session(),
                ...(values.resource ? { resource: values.resource } : {}),
            });
            out(e, `noted #${e.seq}`);
            return 0;
        }
        case "log": {
            const es = await call<JournalEntry[]>(ep, "acp.journal", {
                limit: Number(values.limit),
                ...(values.resource ? { resource: values.resource } : {}),
            });
            out(es, es.map(formatEntry).join("\n") || "(empty)");
            return 0;
        }
        case "verify-journal": {
            const r = await call<{ entries: number; ok: boolean; brokenAt?: number }>(ep, "acp.verifyJournal");
            out(r, r.ok ? `ok: ${r.entries} entries chain` : `BROKEN at entry #${r.brokenAt}`);
            return r.ok ? 0 : 1;
        }
        case "mcp":
            await runMcp(ep, session());
            return await new Promise<number>(() => undefined);
    }
    return 2;
}

// Set exitCode and let the loop drain: process.exit() while undici still has a
// socket open aborted with 0xC0000409 on Windows. The unref'd timer is a backstop.
const finish = (code: number): void => {
    process.exitCode = code;
    setTimeout(() => process.exit(code), 2_000).unref();
};
main(process.argv.slice(2)).then(finish, (e: unknown) => {
    const refused = e instanceof RpcError && (e.code === -32001 || e.code === 3);
    console.error(`agentq: ${(e as Error).message}`);
    finish(refused ? 3 : 2);
});
