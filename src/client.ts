import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Owner, TicketView } from "./core.ts";

export function stateDir(): string {
    return process.env["AGENTQ_HOME"] ?? join(homedir(), ".agentq");
}

export class RpcError extends Error {
    readonly code: number;
    readonly data: unknown;
    constructor(code: number, message: string, data?: unknown) {
        super(message);
        this.code = code;
        this.data = data;
    }
}

export interface Endpoint {
    url: string;
    token: string;
}

export function readEndpoint(dir = stateDir()): Endpoint | null {
    const f = join(dir, "daemon.json");
    if (!existsSync(f)) return null;
    try {
        const j = JSON.parse(readFileSync(f, "utf8")) as Endpoint;
        return j.url && j.token ? j : null;
    } catch {
        return null;
    }
}

let nextId = 1;

export async function call<T>(ep: Endpoint, method: string, params: object = {}, timeoutMs = 40_000): Promise<T> {
    const res = await fetch(ep.url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${ep.token}` },
        body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
        signal: AbortSignal.timeout(timeoutMs),
    });
    if (res.status === 401) throw new RpcError(401, "daemon refused the token (restarted? re-read daemon.json)");
    const j = (await res.json()) as { result?: T; error?: { code: number; message: string; data?: unknown } };
    if (j.error) throw new RpcError(j.error.code, j.error.message, j.error.data);
    return j.result as T;
}

/** Endpoint of a running daemon, starting one detached when none answers. */
export async function connect(opts: { dir?: string; autostart?: boolean; cli?: string } = {}): Promise<Endpoint> {
    const dir = opts.dir ?? stateDir();
    const ping = async (): Promise<Endpoint | null> => {
        const ep = readEndpoint(dir);
        if (!ep) return null;
        try {
            await call(ep, "acp.hello", {}, 2_000);
            return ep;
        } catch {
            return null;
        }
    };
    const ep = await ping();
    if (ep) return ep;
    if (opts.autostart === false || process.env["AGENTQ_NO_AUTOSTART"] === "1") {
        throw new Error(`no agentq daemon in ${dir} (run "agentq daemon")`);
    }
    const cli = opts.cli ?? process.argv[1]!;
    const child = spawn(process.execPath, [cli, "daemon"], {
        detached: true,
        stdio: "ignore",
        env: { ...process.env, AGENTQ_HOME: dir },
        windowsHide: true,
    });
    child.unref();
    for (let i = 0; i < 50; i++) {
        await new Promise((r) => setTimeout(r, 100));
        const up = await ping();
        if (up) return up;
    }
    throw new Error(`agentq daemon did not start in ${dir}`);
}

/** Queue, wait until held (keeping the lease alive), and return a handle that heartbeats until released. */
export async function hold(
    ep: Endpoint,
    req: { resource: string; owner: Owner; leaseMs?: number; capacity?: number; timeoutMs?: number },
    onWait?: (t: TicketView) => void,
): Promise<{ ticket: TicketView; release: (exit?: number) => Promise<void> }> {
    let t = await call<TicketView>(ep, "acp.acquire", req);
    const deadline = Date.now() + (req.timeoutMs ?? 60 * 60_000);
    while (!t.held) {
        onWait?.(t);
        if (Date.now() > deadline) {
            await call(ep, "acp.release", { ticket: t.id }).catch(() => undefined);
            throw new RpcError(3, `gave up waiting for ${req.resource}`);
        }
        t = await call<TicketView>(ep, "acp.wait", { ticket: t.id, timeoutMs: 25_000 });
    }
    const lease = req.leaseMs ?? 60_000;
    const beat = setInterval(
        () => void call(ep, "acp.heartbeat", { ticket: t.id }).catch(() => undefined),
        Math.max(1_000, lease / 3),
    );
    beat.unref();
    return {
        ticket: t,
        release: async (exit?: number) => {
            clearInterval(beat);
            await call(ep, "acp.release", { ticket: t.id, ...(exit !== undefined ? { exit } : {}) });
        },
    };
}
