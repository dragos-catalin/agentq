import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { describe, expect, it } from "vitest";
import type { Endpoint } from "../src/client.ts";
import { buildMcpServer, mcpArgv } from "../src/mcp.ts";
import { parseJsonLine, resolveScript, runPwsh } from "../src/pws.ts";

const EP: Endpoint = { url: "http://127.0.0.1:1", token: "test" };

/** Every registered tool name, read over an in-memory transport — no daemon and no socket needed. */
async function toolNames(): Promise<string[]> {
    const server = buildMcpServer(EP, "test-session");
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);
    const client = new Client({ name: "test", version: "0.0.0" });
    await client.connect(clientTransport);
    try {
        const { tools } = await client.listTools();
        return tools.map((t) => t.name).sort();
    } finally {
        await client.close();
    }
}

const EXPECTED = [
    "acp_acquire",
    "acp_journal",
    "acp_mark",
    "acp_note",
    "acp_release",
    "acp_status",
    "acp_wait",
    "agentq_break",
    "agentq_land",
    "agentq_lease",
    "agentq_note",
    "agentq_propose",
    "agentq_publish",
    "agentq_run",
    "agentq_since",
    "agentq_status",
    "agentq_sweep",
    "agentq_unlease",
    "agentq_workspace",
    "cloud_log",
    "cloud_reset",
    "cloud_result",
    "cloud_resume",
    "cloud_status",
    "cloud_submit",
    "cloud_suspend",
    "cloud_workspaces",
    "job_list",
    "job_start",
    "job_wait",
].sort();

describe("MCP tool registration", () => {
    it("registers the acp RPC tools plus every agentq/job/cloud spawn tool", async () => {
        const names = await toolNames();
        expect(names).toEqual(EXPECTED);
    });
});

describe("argument vectors", () => {
    it("keeps a value with a space as ONE element", () => {
        expect(mcpArgv.note({ message: "do not touch apps/x" })).toEqual(["note", "-Message", "do not touch apps/x"]);
    });

    it("builds `agentq run` with the command after --", () => {
        expect(mcpArgv.run({ purpose: "gate the web build", command: ["pnpm", "--filter", "web", "build"] })).toEqual([
            "run",
            "-Resource",
            "build",
            "-Purpose",
            "gate the web build",
            "--",
            "pnpm",
            "--filter",
            "web",
            "build",
        ]);
    });

    it("adds cloud placement flags to a run", () => {
        expect(mcpArgv.run({ purpose: "x", command: ["pnpm", "test"], where: "cloud", ws: "codai" })).toEqual([
            "run",
            "-Resource",
            "build",
            "-Purpose",
            "x",
            "-Where",
            "cloud",
            "-Ws",
            "codai",
            "--",
            "pnpm",
            "test",
        ]);
    });

    it("joins publish paths with commas and keeps the message intact", () => {
        expect(mcpArgv.publish({ paths: ["src/a.ts", "src/b.ts"], message: "fix(x): y", purpose: "ship" })).toEqual([
            "publish",
            "-Paths",
            "src/a.ts,src/b.ts",
            "-Message",
            "fix(x): y",
            "-Purpose",
            "ship",
        ]);
    });

    it("names branch and target for a land", () => {
        expect(mcpArgv.land({ branch: "feat/x", onto: "main", purpose: "ship" })).toEqual([
            "land",
            "-Branch",
            "feat/x",
            "-Onto",
            "main",
            "-Purpose",
            "ship",
        ]);
    });

    it("passes the slot directory and lease id to unlease", () => {
        expect(mcpArgv.unlease({ repo: "E:\\gh\\.wt\\brivio\\task-1", leaseId: "abc" })).toEqual([
            "unlease",
            "-Repo",
            "E:\\gh\\.wt\\brivio\\task-1",
            "-LeaseId",
            "abc",
        ]);
    });

    it("puts the cloud command after -- behind its typed flags", () => {
        expect(
            mcpArgv.cloudSubmit({ ws: "codai", purpose: "typecheck", command: ["pnpm", "typecheck"], lane: "gate" }),
        ).toEqual(["-Ws", "codai", "-Purpose", "typecheck", "-Lane", "gate", "--", "pnpm", "typecheck"]);
    });

    it("addresses the bucket object for a job log and the VM for a reset", () => {
        expect(mcpArgv.cloudObject("dragos-devcloud-devcloud-jobs", "id1", "log")).toEqual([
            "storage",
            "cat",
            "gs://dragos-devcloud-devcloud-jobs/jobs/id1/log",
        ]);
        expect(
            mcpArgv.cloudInstance("reset", { ws: "codai", project: "codai-training", zone: "europe-west4-a" }),
        ).toEqual([
            "compute",
            "instances",
            "reset",
            "ws-codai",
            "--project",
            "codai-training",
            "--zone",
            "europe-west4-a",
        ]);
    });

    it("passes job-start named parameters, never one joined string", () => {
        expect(mcpArgv.jobStart({ label: "web gate", command: "pnpm build", expectedMin: 12 })).toEqual([
            "-Label",
            "web gate",
            "-Command",
            "pnpm build",
            "-ExpectedMin",
            "12",
        ]);
    });
});

const has = (prog: string): boolean => spawnSync(prog, ["-NoProfile", "-Command", "exit 0"]).status === 0;
const pwsh = has("pwsh") ? "pwsh" : has("powershell") ? "powershell" : null;

describe("pws helpers", () => {
    it("resolves a shipped script to an existing file", () => {
        expect(existsSync(resolveScript("agentq.ps1"))).toBe(true);
    });

    it("reads the last JSON line and ignores the prose around it", () => {
        expect(parseJsonLine('starting\n{"id":"j1","state":"running"}\ndone')).toEqual({ id: "j1", state: "running" });
        expect(parseJsonLine("no json on any line")).toBeUndefined();
    });

    it.skipIf(!pwsh)("captures stdout, stderr and the exit code", async () => {
        const dir = mkdtempSync(join(tmpdir(), "agentq-pws-"));
        const script = join(dir, "probe.ps1");
        writeFileSync(script, "Write-Output 'the out line'\n[Console]::Error.WriteLine('the err line')\nexit 7\n");
        const r = await runPwsh(script, []);
        expect(r.code).toBe(7);
        expect(r.stdout).toContain("the out line");
        expect(r.stderr).toContain("the err line");
    });

    it.skipIf(!pwsh)("passes an argument containing a space as one argv element", async () => {
        const dir = mkdtempSync(join(tmpdir(), "agentq-pws-"));
        const script = join(dir, "echo.ps1");
        writeFileSync(script, "param([string]$Text)\nWrite-Output $Text\n");
        const r = await runPwsh(script, ["-Text", "hello world"]);
        expect(r.code).toBe(0);
        expect(r.stdout.trim()).toBe("hello world");
    });
});
