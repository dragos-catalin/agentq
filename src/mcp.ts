import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { call, type Endpoint } from "./client.ts";
import type { TicketView } from "./core.ts";

/**
 * MCP face of the daemon, so any MCP-capable agent can coordinate without a shell.
 * Tickets acquired here are owned by this server process (pid) and heartbeated by it,
 * so they are released when the agent session ends.
 */
export async function runMcp(ep: Endpoint, session: string): Promise<void> {
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

    await server.connect(new StdioServerTransport());
}
