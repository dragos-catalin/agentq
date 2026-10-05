import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { call, hold, readEndpoint, RpcError, type Endpoint } from "../src/client.ts";
import type { TicketView } from "../src/core.ts";
import { startDaemon, type Daemon } from "../src/daemon.ts";

/** spawnSync would block this worker's event loop, and with it the in-process daemon. */
function spawnAsync(file: string, args: string[], opts: { env: NodeJS.ProcessEnv; encoding: "utf8" }) {
    return new Promise<{ status: number | null; stdout: string; stderr: string }>((res) => {
        const c = spawn(file, args, { env: opts.env });
        let stdout = "";
        let stderr = "";
        c.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
        c.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
        c.on("close", (status) => res({ status, stdout, stderr }));
    });
}

let d: Daemon;let ep: Endpoint;
let dir: string;

beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), "agentq-d-"));
    d = await startDaemon({ dir, defaultLeaseMs: 5_000, reapIntervalMs: 200 });
    ep = { url: d.url, token: d.token };
});
afterAll(() => d.close());

describe("daemon over JSON-RPC", () => {
    it("writes a private discovery file and answers hello", async () => {
        expect(readEndpoint(dir)).toMatchObject({ url: d.url, token: d.token });
        expect(await call(ep, "acp.hello")).toMatchObject({ protocol: "acp-lock/0.1" });
    });

    it("rejects a wrong token, a browser origin and unknown methods", async () => {
        const bad = await fetch(d.url, { method: "POST", headers: { authorization: "Bearer nope" }, body: "{}" });
        expect(bad.status).toBe(401);
        const browser = await fetch(d.url, {
            method: "POST",
            headers: { authorization: `Bearer ${d.token}`, origin: "https://evil.example" },
            body: "{}",
        });
        expect(browser.status).toBe(404);
        await expect(call(ep, "acp.nope")).rejects.toMatchObject({ code: -32601 });
        await expect(call(ep, "acp.acquire", { resource: "x" })).rejects.toBeInstanceOf(RpcError);
    });

    it("acp.wait returns as soon as the holder releases", async () => {
        const a = await call<TicketView>(ep, "acp.acquire", {
            resource: "build:w",
            owner: { session: "a", purpose: "x" },
        });
        const b = await call<TicketView>(ep, "acp.acquire", {
            resource: "build:w",
            owner: { session: "b", purpose: "y" },
        });
        expect([a.held, b.held]).toEqual([true, false]);
        const started = Date.now();
        const waiting = call<TicketView>(ep, "acp.wait", { ticket: b.id, timeoutMs: 10_000 });
        setTimeout(() => void call(ep, "acp.release", { ticket: a.id, exit: 0 }), 300);
        const got = await waiting;
        expect(got.held).toBe(true);
        expect(Date.now() - started).toBeLessThan(5_000);
        await call(ep, "acp.release", { ticket: b.id });
    });

    it("hold() serialises two concurrent critical sections", async () => {
        const order: string[] = [];
        const job = async (name: string) => {
            const h = await hold(ep, {
                resource: "commit:r",
                owner: { session: name, purpose: "commit" },
                leaseMs: 5_000,
            });
            order.push(`${name}+`);
            await new Promise((r) => setTimeout(r, 200));
            order.push(`${name}-`);
            await h.release(0);
        };
        await Promise.all([job("a"), job("b")]);
        expect(order).toEqual(["a+", "a-", "b+", "b-"]);
    });

    it("refuses acquire on a frozen resource with the reason, and journals everything", async () => {
        await call(ep, "acp.mark", { resource: "deploy:r:prod", state: "frozen", reason: "incident", session: "ops" });
        await expect(
            call(ep, "acp.acquire", { resource: "deploy:r:prod", owner: { session: "a", purpose: "ship" } }),
        ).rejects.toMatchObject({ code: -32001, message: expect.stringContaining("incident") });
        await call(ep, "acp.mark", { resource: "deploy:r:prod", state: "clear", reason: "resolved", session: "ops" });
        const v = await call<{ ok: boolean; entries: number }>(ep, "acp.verifyJournal");
        expect(v.ok).toBe(true);
        expect(v.entries).toBeGreaterThan(5);
        const lines = readFileSync(join(dir, "journal.jsonl"), "utf8").trim().split("\n");
        expect(lines.length).toBe(v.entries);
    });
});

describe("cli against a real daemon", () => {
    const cli = resolve(import.meta.dirname, "../src/cli.ts");
    it("run holds the resource for the command and returns its exit code", async () => {
        const env = { ...process.env, AGENTQ_HOME: dir, AGENTQ_SESSION: "cli-test", AGENTQ_NO_AUTOSTART: "1" };
        const r = await spawnAsync(
            process.execPath,
            [cli, "run", "-r", "build:cli", "-p", "test", "--", process.execPath, "-e", "process.exit(7)"],
            {
                env,
                encoding: "utf8",
            },
        );
        expect(r.status, r.stderr).toBe(7);
        const shim = await spawnAsync(
            process.execPath,
            [cli, "run", "-r", "build:cli", "-p", "shim", "--", "pnpm", "--version"],
            {
                env,
                encoding: "utf8",
            },
        );
        expect(shim.status, shim.stderr).toBe(0);
        expect(shim.stdout).toMatch(/^\d+\.\d+/);
        const log = await spawnAsync(process.execPath, [cli, "log", "--json", "-r", "build:cli"], { env, encoding: "utf8" });
        const events = (JSON.parse(log.stdout) as { event: string; exit?: number }[]).map(
            (e) => `${e.event}${e.exit ?? ""}`,
        );
        expect(events).toEqual(["acquire", "release7", "acquire", "release0"]);
        const frozen = await spawnAsync(
            process.execPath,
            [cli, "mark", "-r", "build:cli", "--state", "frozen", "--reason", "x"],
            { env, encoding: "utf8" },
        );
        expect(frozen.status).toBe(0);
        const refused = await spawnAsync(
            process.execPath,
            [cli, "run", "-r", "build:cli", "-p", "t", "--", process.execPath, "-e", "0"],
            {
                env,
                encoding: "utf8",
            },
        );
        expect(refused.status).toBe(3);
        expect(refused.stderr).toContain("frozen");
    });
});
