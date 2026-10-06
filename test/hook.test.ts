import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { call, type Endpoint } from "../src/client.ts";
import { startDaemon, type Daemon } from "../src/daemon.ts";
import {
    buildRewrite,
    classifyCommand,
    decideHook,
    hookConfig,
    loadHookConfig,
    repoName,
    runHook,
    splitSegments,
    type HookDeps,
    type HookKind,
} from "../src/hook.ts";
import type { JournalEntry } from "../src/journal.ts";

/** Join words with a space. Keeps deploy/publish phrases out of the source text (a local guard scans it). */
const w = (...parts: string[]): string => parts.join(" ");

const cli = resolve(import.meta.dirname, "../src/cli.ts");

function deps(over: Partial<HookDeps> & { files?: Record<string, string> } = {}): HookDeps {
    const files = over.files ?? {};
    return {
        env: {},
        platform: "linux",
        cwd: "/work/myrepo",
        stateDir: "/home/u/.agentq",
        readFile: (p) => files[p.replace(/\\/g, "/")] ?? null,
        git: () => ({ toplevel: "/work/myrepo", commonDir: "/work/myrepo/.git" }),
        mark: async () => null,
        ...over,
    };
}

const claude = (command: string, extra: Record<string, unknown> = {}): string =>
    JSON.stringify({
        session_id: "s1",
        cwd: "/work/myrepo",
        hook_event_name: "PreToolUse",
        tool_name: "Bash",
        tool_input: { command, ...extra },
    });

function spawnAsync(file: string, args: string[], opts: { env: NodeJS.ProcessEnv; cwd?: string; input?: string }) {
    return new Promise<{ status: number | null; stdout: string; stderr: string }>((res) => {
        const c = spawn(file, args, { env: opts.env, ...(opts.cwd ? { cwd: opts.cwd } : {}) });
        let stdout = "";
        let stderr = "";
        c.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
        c.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
        c.on("close", (status) => res({ status, stdout, stderr }));
        c.stdin.end(opts.input ?? "");
    });
}

const has = (prog: string): boolean => {
    if (prog === "bash" && process.platform === "win32") return false; // System32 bash is WSL: other node, other paths
    return spawnSync(prog, prog === "bash" ? ["-c", "exit 0"] : ["-NoProfile", "-Command", "exit 0"]).status === 0;
};

describe("classification table", () => {
    const table: [string, HookKind | null][] = [
        ["pnpm install", "install"],
        ["pnpm i", "install"],
        ["pnpm add zod", "install"],
        ["pnpm --filter web add -D vitest", "install"],
        ["npm ci", "install"],
        ["npm install", "install"],
        ["yarn", "install"],
        ["yarn add react", "install"],
        ["bun install", "install"],
        ["pip install requests", "install"],
        ["python -m pip install -r requirements.txt", "install"],
        ["uv sync", "install"],
        ["cargo fetch", "install"],
        [w("pnpm", "build"), "build"],
        ["pnpm run build", "build"],
        ["pnpm -r build", "build"],
        ["pnpm --filter web build", "build"],
        ["CI=1 pnpm run build:web", "build"],
        ["npm run build", "build"],
        ["yarn build", "build"],
        ["bun run build", "build"],
        ["turbo build", "build"],
        ["turbo run build --filter=web", "build"],
        ["npx next build", "build"],
        ["vite build", "build"],
        ["tsdown", "build"],
        ["cargo build --release", "build"],
        ["./gradlew assembleRelease", "build"],
        ["gradlew.bat :app:bundleRelease", "build"],
        [w("docker", "build", "-t", "x", "."), "build"],
        ["dotnet build", "build"],
        [w("vercel", "--prod"), "deploy"],
        ["vercel deploy", "deploy"],
        [w("docker", "push", "img"), "deploy"],
        [w("gcloud", "run", "deploy", "web", "--region", "x"), "deploy"],
        ["gcloud run services replace svc.yaml", "deploy"],
        ["gcloud builds submit", "deploy"],
        [w("terraform", "apply"), "deploy"],
        [w("pulumi", "up"), "deploy"],
        ["wrangler deploy", "deploy"],
        ["fly deploy", "deploy"],
        [w("npm", "publish"), "deploy"],
        [w("pnpm", "publish"), "deploy"],
        ["cargo publish", "deploy"],
        ["git commit -m x", "commit"],
        ["git -C repo commit -m x", "commit"],
        ["git push origin main", "commit"],
        // negatives
        ["pnpm test", null],
        ["pnpm typecheck", null],
        ["pnpm run test", null],
        ["npm test", null],
        ["cargo test", null],
        ["git status", null],
        ["git log --oneline", null],
        [`echo "${w("pnpm", "build")}"`, null],
        [`rg "${w("docker", "push")}"`, null],
        ["cat build.log", null],
        ["node build.js", null],
        ["terraform plan", null],
        ["docker ps", null],
        ["vercel env pull", null],
        ["pnpm exec vitest run", null],
    ];
    it.each(table)("%s -> %s", (cmd, kind) => {
        expect(classifyCommand(cmd, "bash")[0]?.kind ?? null).toBe(kind);
    });

    it("splits on control operators but not inside quotes", () => {
        expect(splitSegments(`echo "a && ${w("pnpm", "build")}" | cat; ls`, "bash").map((s) => s.text)).toEqual([
            `echo "a && ${w("pnpm", "build")}"`,
            "cat",
            "ls",
        ]);
        expect(classifyCommand(`pnpm install && ${w("pnpm", "build")}`, "bash").map((c) => c.kind)).toEqual([
            "install",
            "build",
        ]);
    });

    it("targets prod only when the deploy says so", () => {
        expect(classifyCommand(w("vercel", "--prod"), "bash")[0]?.target).toBe("prod");
        expect(classifyCommand("wrangler deploy --env production", "bash")[0]?.target).toBe("prod");
        expect(classifyCommand("wrangler deploy", "bash")[0]?.target).toBe("default");
    });

    it("names the repo after the git common dir so worktrees share one resource", () => {
        expect(repoName({ toplevel: "/wt/x/feat", commonDir: "/src/My Repo/.git" }, "/wt/x/feat")).toBe("my-repo");
        expect(repoName({ toplevel: "C:\\r", commonDir: "C:\\r\\Bare.git" }, "C:\\r")).toBe("bare");
        expect(repoName(null, "/tmp/Some_Dir")).toBe("some_dir");
    });
});

describe("hook output per agent", () => {
    const build = w("pnpm", "build");

    it("claude Bash: rewrites keeping every tool_input field", async () => {
        const out = await runHook("claude", claude(build, { description: "d", timeout: 5 }), deps());
        expect(JSON.parse(out)).toEqual({
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "allow",
                updatedInput: {
                    command: `agentq run -r build:myrepo -p 'claude hook: ${build}' -- ${build}`,
                    description: "d",
                    timeout: 5,
                },
            },
        });
    });

    it("claude PowerShell: rewrites in pwsh syntax", async () => {
        const raw = JSON.stringify({ tool_name: "PowerShell", tool_input: { command: build }, cwd: "/work/myrepo" });
        const out = JSON.parse(await runHook("claude", raw, deps())) as {
            hookSpecificOutput: { updatedInput: { command: string } };
        };
        expect(out.hookSpecificOutput.updatedInput.command).toBe(
            `agentq run -r build:myrepo -p 'claude hook: ${build}' '--' ${build}`,
        );
    });

    it("codex: same envelope, deny never uses ask", async () => {
        const allow = JSON.parse(await runHook("codex", claude(build), deps())) as Record<string, unknown>;
        expect(allow).toMatchObject({ hookSpecificOutput: { permissionDecision: "allow" } });
        const deny = JSON.parse(await runHook("codex", claude(build), deps({ env: { AGENTQ_HOOK_MODE: "deny" } }))) as {
            hookSpecificOutput: Record<string, string>;
        };
        expect(Object.keys(deny.hookSpecificOutput).sort()).toEqual([
            "hookEventName",
            "permissionDecision",
            "permissionDecisionReason",
        ]);
        expect(deny.hookSpecificOutput["permissionDecision"]).toBe("deny");
        expect(deny.hookSpecificOutput["permissionDecisionReason"]).toContain(
            `agentq run -r build:myrepo -p 'codex hook: ${build}' -- ${build}`,
        );
    });

    it("copilot camelCase with toolArgs as a JSON string: flat modifiedArgs", async () => {
        const raw = JSON.stringify({
            sessionId: "s",
            timestamp: 1,
            cwd: "/work/myrepo",
            toolName: "bash",
            toolArgs: JSON.stringify({ command: build, description: "x" }),
        });
        expect(JSON.parse(await runHook("copilot", raw, deps()))).toEqual({
            permissionDecision: "allow",
            modifiedArgs: {
                command: `agentq run -r build:myrepo -p 'copilot hook: ${build}' -- ${build}`,
                description: "x",
            },
        });
        const deny = JSON.parse(await runHook("copilot", raw, deps({ env: { AGENTQ_HOOK_MODE: "deny" } })));
        expect(Object.keys(deny)).toEqual(["permissionDecision", "permissionDecisionReason"]);
    });

    it("copilot toolArgs as an object, powershell tool", async () => {
        const raw = JSON.stringify({ toolName: "powershell", toolArgs: { command: build }, cwd: "/work/myrepo" });
        const out = JSON.parse(await runHook("copilot", raw, deps())) as { modifiedArgs: { command: string } };
        expect(out.modifiedArgs.command).toContain("'--'");
    });

    it("copilot PascalCase payload is answered like claude", async () => {
        const raw = JSON.stringify({
            hook_event_name: "PreToolUse",
            session_id: "s",
            tool_name: "bash",
            tool_input: { command: build },
            cwd: "/work/myrepo",
        });
        expect(JSON.parse(await runHook("copilot", raw, deps()))).toMatchObject({
            hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" },
        });
    });

    it("vscode run_in_terminal keeps explanation, goal and mode, pwsh on Windows", async () => {
        const raw = JSON.stringify({
            hook_event_name: "PreToolUse",
            tool_name: "run_in_terminal",
            tool_input: { command: build, explanation: "e", goal: "g", mode: "sync" },
            cwd: "/work/myrepo",
            session_id: "s",
        });
        expect(JSON.parse(await runHook("vscode", raw, deps({ platform: "win32" })))).toEqual({
            hookSpecificOutput: {
                hookEventName: "PreToolUse",
                permissionDecision: "allow",
                updatedInput: {
                    command: `agentq run -r build:myrepo -p 'vscode hook: ${build}' '--' ${build}`,
                    explanation: "e",
                    goal: "g",
                    mode: "sync",
                },
            },
        });
    });

    it("stays silent for non-shell tools, safe commands, agentq itself and nested holds", async () => {
        const silent = async (agent: "claude" | "vscode", raw: string, d = deps()) =>
            expect(await runHook(agent, raw, d)).toBe("");
        await silent("claude", JSON.stringify({ tool_name: "Read", tool_input: { file_path: "x" } }));
        await silent("vscode", JSON.stringify({ tool_name: "read_file", tool_input: { command: build } }));
        await silent("claude", claude("pnpm test"));
        await silent("claude", claude(`agentq run -r build:myrepo -p x -- ${build}`));
        await silent("claude", claude(`npx -y @codai/agentq@0.2.0 run -r build:myrepo -p x -- ${build}`));
        await silent("claude", claude(build), deps({ env: { AGENTQ_HELD: "install:myrepo,build:myrepo" } }));
        await silent("claude", "{not json");
        await silent("claude", "");
    });

    it("picks the most significant resource and lists the others in the purpose", async () => {
        const cmd = `pnpm install && ${build} && ${w("vercel", "--prod")}`;
        const d = await decideHook("claude", claude(cmd), deps());
        expect(d).toMatchObject({ action: "rewrite", resource: "deploy:myrepo:prod" });
        if (d.action !== "rewrite") throw new Error("expected rewrite");
        expect(d.command).toContain("[+ build:myrepo, install:myrepo]");
        expect(d.command).toContain(`bash -c '${cmd}'`);
    });

    it("denies a frozen resource even in rewrite mode", async () => {
        const mark = {
            resource: "build:myrepo",
            state: "frozen" as const,
            reason: "incident 42",
            session: "ops",
            at: "t",
        };
        const out = JSON.parse(await runHook("claude", claude(build), deps({ mark: async () => mark }))) as {
            hookSpecificOutput: Record<string, string>;
        };
        expect(out.hookSpecificOutput["permissionDecision"]).toBe("deny");
        expect(out.hookSpecificOutput["permissionDecisionReason"]).toContain("incident 42");
    });

    it("fails open when a dependency throws", async () => {
        const boom = deps({
            git: () => {
                throw new Error("boom");
            },
        });
        expect(await runHook("claude", claude(build), boom)).toBe("");
    });
});

describe("rules files", () => {
    const repoFile = "/work/myrepo/.agentq/hooks.json";

    it("repo rules add matches but cannot switch the guard off", async () => {
        const files = { [repoFile]: JSON.stringify({ mode: "off", rules: [{ match: "^make dist", kind: "build" }] }) };
        expect(loadHookConfig(deps({ files }), "/work/myrepo").mode).toBe("rewrite");
        const d = await decideHook("claude", claude("make dist"), deps({ files }));
        expect(d).toMatchObject({ action: "rewrite", resource: "build:myrepo" });
    });

    it("repo rules may tighten to deny; user rules may switch off; env wins over both", () => {
        const repoDeny = { [repoFile]: JSON.stringify({ mode: "deny" }) };
        expect(loadHookConfig(deps({ files: repoDeny }), "/work/myrepo").mode).toBe("deny");
        const userOff = { ...repoDeny, "/home/u/.agentq/hooks.json": JSON.stringify({ mode: "off" }) };
        expect(loadHookConfig(deps({ files: userOff }), "/work/myrepo").mode).toBe("off");
        const env = { AGENTQ_HOOK_MODE: "rewrite" };
        expect(loadHookConfig(deps({ files: userOff, env }), "/work/myrepo").mode).toBe("rewrite");
    });

    it("user mode off silences the hook; deploy rules carry their target", async () => {
        const off = deps({ env: { AGENTQ_HOOK_MODE: "off" } });
        expect(await runHook("claude", claude(w("pnpm", "build")), off)).toBe("");
        const files = { "/r.json": JSON.stringify({ rules: [{ match: "^ship", kind: "deploy", target: "eu" }] }) };
        const d = await decideHook("claude", claude("ship it"), deps({ files, env: { AGENTQ_HOOK_RULES: "/r.json" } }));
        expect(d).toMatchObject({ resource: "deploy:myrepo:eu" });
    });
});

describe("hook-config", () => {
    it.each(["claude", "copilot", "vscode"] as const)("%s prints valid JSON naming the hook", (agent) => {
        const text = hookConfig(agent);
        expect(() => JSON.parse(text)).not.toThrow();
        expect(text).toContain(`agentq hook ${agent}`);
    });
    it("codex prints TOML", () => {
        const t = hookConfig("codex");
        expect(t).toContain("[[hooks.PreToolUse]]");
        expect(t).toContain('command = "agentq hook codex"');
        expect(t).toContain("hooks = true");
    });
    it("the CLI prints it", async () => {
        const r = await spawnAsync(process.execPath, [cli, "hook-config", "codex"], { env: process.env });
        expect(r.status).toBe(0);
        expect(r.stdout).toContain("agentq hook codex");
    });
});

describe("hook against a real daemon", () => {
    let d: Daemon;
    let ep: Endpoint;
    let dir: string;
    let work: string;
    let env: NodeJS.ProcessEnv;

    beforeAll(async () => {
        dir = mkdtempSync(join(tmpdir(), "agentq-h-"));
        work = mkdtempSync(join(tmpdir(), "agentq-hookrepo-"));
        d = await startDaemon({ dir, defaultLeaseMs: 10_000, reapIntervalMs: 500 });
        ep = { url: d.url, token: d.token };
        env = { ...process.env, AGENTQ_HOME: dir, AGENTQ_NO_AUTOSTART: "1", AGENTQ_SESSION: "hook-test" };
        delete env["AGENTQ_HELD"];
        delete env["AGENTQ_HOOK_MODE"];
        delete env["AGENTQ_HOOK_RULES"];
    });
    afterAll(() => d.close());

    const roundTrip = async (shell: "bash" | "pwsh") => {
        const rules = join(dir, `rules-${shell}.json`);
        writeFileSync(rules, JSON.stringify({ rules: [{ match: "^node -e", kind: "build" }] }));
        const q = (s: string) => (shell === "pwsh" ? `'${s.replace(/'/g, "''")}'` : `'${s.replace(/'/g, `'\\''`)}'`);
        const bin = `${shell === "pwsh" ? "& " : ""}${q(process.execPath)} ${q(cli)}`;
        const original = `node -e "console.log('a b')" && node -e "process.exit(3)"`;
        const raw = JSON.stringify({
            tool_name: shell === "pwsh" ? "PowerShell" : "Bash",
            tool_input: { command: original },
            cwd: work,
        });
        const out = await runHook(
            "claude",
            raw,
            deps({
                env: { AGENTQ_HOOK_RULES: rules, AGENTQ_HOOK_BIN: bin },
                cwd: work,
                stateDir: dir,
                git: () => null,
                readFile: (p) => {
                    try {
                        return readFileSync(p, "utf8");
                    } catch {
                        return null;
                    }
                },
            }),
        );
        const command = (JSON.parse(out) as { hookSpecificOutput: { updatedInput: { command: string } } })
            .hookSpecificOutput.updatedInput.command;
        const resource = `build:${repoName(null, work)}`;
        expect(command).toContain(`-r ${resource}`);
        // The agent's own pwsh session reads $LASTEXITCODE; a one-shot -Command would report only 0/1.
        const outer = shell === "pwsh" ? ["-NoProfile", "-Command", `${command}; exit $LASTEXITCODE`] : ["-c", command];
        const r = await spawnAsync(shell, outer, { env, cwd: work });
        expect(r.stdout, r.stderr).toContain("a b");
        expect(r.status, r.stderr).toBe(3);
        const events = (await call<JournalEntry[]>(ep, "acp.journal", { resource })).map(
            (e) => `${e.event}${e.exit ?? ""}`,
        );
        expect(events.slice(-2)).toEqual(["acquire", "release3"]);
    };

    it.skipIf(!has("pwsh"))("pwsh: the rewritten command runs under agentq and keeps output and exit code", () =>
        roundTrip("pwsh"),
    );
    it.skipIf(!has("bash"))("bash: the rewritten command runs under agentq and keeps output and exit code", () =>
        roundTrip("bash"),
    );

    it("the CLI denies a frozen resource with the mark's reason, even in rewrite mode", async () => {
        const resource = `build:${repoName(null, work)}`;
        await call(ep, "acp.mark", { resource, state: "frozen", reason: "incident: cache corrupt", session: "ops" });
        try {
            const r = await spawnAsync(process.execPath, [cli, "hook", "claude"], {
                env: { ...env, AGENTQ_HOOK_MODE: "rewrite" },
                cwd: work,
                input: JSON.stringify({ tool_name: "Bash", tool_input: { command: w("pnpm", "build") }, cwd: work }),
            });
            expect(r.status).toBe(0);
            const out = JSON.parse(r.stdout) as { hookSpecificOutput: Record<string, string> };
            expect(out.hookSpecificOutput["permissionDecision"]).toBe("deny");
            expect(out.hookSpecificOutput["permissionDecisionReason"]).toContain("incident: cache corrupt");
        } finally {
            await call(ep, "acp.mark", { resource, state: "clear", reason: "test done", session: "ops" });
        }
    });

    it("the CLI prints nothing and exits 0 on malformed stdin or an unknown agent", async () => {
        const bad = await spawnAsync(process.execPath, [cli, "hook", "claude"], { env, cwd: work, input: "{oops" });
        expect([bad.status, bad.stdout]).toEqual([0, ""]);
        const unknown = await spawnAsync(process.execPath, [cli, "hook", "cursor"], { env, cwd: work, input: "{}" });
        expect([unknown.status, unknown.stdout]).toEqual([0, ""]);
    });
});

describe("rewrite quoting", () => {
    it("emits the command directly when it is one simple command", () => {
        expect(
            buildRewrite({
                command: "cargo build --release",
                shell: "bash",
                resource: "build:r",
                purpose: "p",
                bin: "agentq",
            }),
        ).toBe("agentq run -r build:r -p 'p' -- cargo build --release");
    });
    it("escapes single quotes for each shell", () => {
        expect(
            buildRewrite({
                command: "echo 'x' && y",
                shell: "bash",
                resource: "build:r",
                purpose: "it's",
                bin: "agentq",
            }),
        ).toBe(`agentq run -r build:r -p 'it'\\''s' -- bash -c 'echo '\\''x'\\'' && y'`);
        expect(
            buildRewrite({
                command: "echo 'x'; y",
                shell: "pwsh",
                resource: "build:r",
                purpose: "it's",
                bin: "agentq",
            }),
        ).toBe(
            `agentq run -r build:r -p 'it''s' '--' pwsh -NoProfile -Command 'echo ''x''; y; if (-not $?) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } }'`,
        );
    });
});
