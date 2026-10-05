import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { AcpError, Coordinator, ERR, type CoordinatorOptions, type MarkState, type Owner } from "./core.ts";
import { verifyChain } from "./journal.ts";

/**
 * ACP-Lock daemon: JSON-RPC 2.0 over HTTP on 127.0.0.1 with a bearer token.
 * Discovery file `<dir>/daemon.json` (mode 0600) holds { url, token, pid }.
 */
export const PROTOCOL = "acp-lock/0.1";
const MAX_BODY = 64 * 1024;
const MAX_WAIT_MS = 30_000;

export interface Daemon {
    url: string;
    token: string;
    coordinator: Coordinator;
    close(): Promise<void>;
}

type Params = Record<string, unknown>;

const str = (p: Params, k: string, required = true): string => {
    const v = p[k];
    if (typeof v === "string") return v;
    if (!required && v === undefined) return "";
    throw new AcpError(ERR.INVALID, `param "${k}" must be a string`);
};
const num = (p: Params, k: string): number | undefined => {
    const v = p[k];
    if (v === undefined) return undefined;
    if (typeof v === "number" && Number.isFinite(v)) return v;
    throw new AcpError(ERR.INVALID, `param "${k}" must be a number`);
};

function owner(p: Params): Owner {
    const o = (p["owner"] ?? {}) as Params;
    const pid = num(o, "pid");
    return {
        session: str(o, "session"),
        purpose: str(o, "purpose"),
        ...(pid !== undefined ? { pid } : {}),
        ...(typeof o["host"] === "string" ? { host: o["host"] } : {}),
    };
}

export async function startDaemon(
    opts: CoordinatorOptions & { port?: number; reapIntervalMs?: number },
): Promise<Daemon> {
    const c = new Coordinator(opts);
    const token = randomBytes(32).toString("hex");
    const waiters = new Set<() => void>();
    c.onChange(() => {
        for (const w of [...waiters]) w();
    });

    /** Long-poll until the ticket is held, it disappears, or timeout. Waiting keeps the lease alive. */
    const wait = (id: string, timeoutMs: number): Promise<unknown> =>
        new Promise((resolve, reject) => {
            const check = (): boolean => {
                try {
                    const v = c.heartbeat(id);
                    if (v.held) {
                        done();
                        resolve(v);
                        return true;
                    }
                } catch (e) {
                    done();
                    reject(e);
                    return true;
                }
                return false;
            };
            const done = (): void => {
                waiters.delete(onChange);
                clearTimeout(timer);
            };
            let busy = false;
            const onChange = (): void => {
                if (busy) return;
                busy = true;
                queueMicrotask(() => {
                    busy = false;
                    check();
                });
            };
            const timer = setTimeout(
                () => {
                    done();
                    try {
                        resolve(c.view(c.get(id)));
                    } catch (e) {
                        reject(e);
                    }
                },
                Math.min(timeoutMs, MAX_WAIT_MS),
            );
            if (!check()) waiters.add(onChange);
        });

    const methods: Record<string, (p: Params) => unknown> = {
        "acp.hello": () => ({ protocol: PROTOCOL, pid: process.pid }),
        "acp.acquire": (p) => {
            const leaseMs = num(p, "leaseMs");
            const capacity = num(p, "capacity");
            return c.acquire({
                resource: str(p, "resource"),
                owner: owner(p),
                ...(leaseMs !== undefined ? { leaseMs } : {}),
                ...(capacity !== undefined ? { capacity } : {}),
            });
        },
        "acp.wait": (p) => wait(str(p, "ticket"), num(p, "timeoutMs") ?? MAX_WAIT_MS),
        "acp.heartbeat": (p) => c.heartbeat(str(p, "ticket")),
        "acp.release": (p) => {
            const exit = num(p, "exit");
            c.release(str(p, "ticket"), exit);
            return { ok: true };
        },
        "acp.break": (p) => c.break(str(p, "ticket"), str(p, "reason"), str(p, "session")),
        "acp.mark": (p) => {
            const state = str(p, "state");
            if (!["frozen", "blocked", "clear"].includes(state))
                throw new AcpError(ERR.INVALID, "state must be frozen, blocked or clear");
            return c.mark(str(p, "resource"), state as MarkState | "clear", str(p, "reason"), str(p, "session"));
        },
        "acp.note": (p) => c.note(str(p, "message"), str(p, "session"), str(p, "resource", false) || undefined),
        "acp.status": (p) => c.status(str(p, "resource", false) || undefined),
        "acp.journal": (p) => {
            const after = num(p, "after");
            const limit = num(p, "limit");
            const resource = str(p, "resource", false);
            return c.journal.read({
                ...(after !== undefined ? { after } : {}),
                ...(limit !== undefined ? { limit } : {}),
                ...(resource ? { resource } : {}),
            });
        },
        "acp.verifyJournal": () => {
            const all = c.journal.read();
            const broken = verifyChain(all);
            return { entries: all.length, ok: broken < 0, ...(broken >= 0 ? { brokenAt: all[broken]!.seq } : {}) };
        },
    };

    const authOk = (req: IncomingMessage): boolean => {
        const h = req.headers.authorization ?? "";
        const got = Buffer.from(h.replace(/^Bearer\s+/i, ""));
        const want = Buffer.from(token);
        return got.length === want.length && timingSafeEqual(got, want);
    };

    const server: Server = createServer((req, res) => {
        const send = (status: number, body: unknown): void => {
            res.writeHead(status, { "content-type": "application/json" });
            res.end(JSON.stringify(body));
        };
        // Browsers send Origin; a local page must not drive the daemon even with a stolen token.
        if (req.method !== "POST" || req.url !== "/rpc" || req.headers.origin) return send(404, { error: "not found" });
        if (!authOk(req)) return send(401, { error: "unauthorized" });
        let size = 0;
        const chunks: Buffer[] = [];
        req.on("data", (d: Buffer) => {
            size += d.length;
            if (size > MAX_BODY) req.destroy();
            else chunks.push(d);
        });
        req.on("end", () => {
            let id: unknown = null;
            Promise.resolve()
                .then(() => {
                    const msg = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
                        id?: unknown;
                        method?: unknown;
                        params?: unknown;
                    };
                    id = msg.id ?? null;
                    const fn = typeof msg.method === "string" ? methods[msg.method] : undefined;
                    if (!fn) throw new AcpError(-32601, `method not found: ${String(msg.method)}`);
                    return fn((msg.params ?? {}) as Params);
                })
                .then(
                    (result) => send(200, { jsonrpc: "2.0", id, result: result ?? null }),
                    (e: unknown) => {
                        const err =
                            e instanceof AcpError
                                ? e
                                : new AcpError(e instanceof SyntaxError ? -32700 : -32603, (e as Error).message);
                        send(200, {
                            jsonrpc: "2.0",
                            id,
                            error: { code: err.code, message: err.message, ...(err.data ? { data: err.data } : {}) },
                        });
                    },
                );
        });
    });

    await new Promise<void>((resolve) => server.listen(opts.port ?? 0, "127.0.0.1", resolve));
    const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/rpc`;
    const reaper = setInterval(() => c.reap(), opts.reapIntervalMs ?? 5_000);
    reaper.unref();
    let discovery: string | null = null;
    if (opts.dir) {
        mkdirSync(opts.dir, { recursive: true });
        discovery = join(opts.dir, "daemon.json");
        writeFileSync(discovery, JSON.stringify({ url, token, pid: process.pid, protocol: PROTOCOL }), { mode: 0o600 });
    }
    return {
        url,
        token,
        coordinator: c,
        close: () =>
            new Promise((resolve) => {
                clearInterval(reaper);
                if (discovery) rmSync(discovery, { force: true });
                server.closeAllConnections();
                server.close(() => resolve());
            }),
    };
}
