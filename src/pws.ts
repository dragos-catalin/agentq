import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

/** Exit code and captured streams of one finished process. */
export interface PwshResult {
    code: number;
    stdout: string;
    stderr: string;
}

export interface RunOptions {
    cwd?: string;
    /** Extra environment for the child, merged over process.env. */
    env?: NodeJS.ProcessEnv;
    /** Kill the process after this many milliseconds; the result then carries code 124. 0/undefined = no limit. */
    timeoutMs?: number;
}

// pwsh first: every script here targets PowerShell 7. Windows always has the 5.1 fallback; off Windows the
// fallback binary is `powershell`, not `powershell.exe`.
const SHELLS = process.platform === "win32" ? ["pwsh", "powershell.exe"] : ["pwsh", "powershell"];

/**
 * Resolve a script shipped with agentq to an absolute path (an absolute path is returned untouched, so a
 * caller can point at any script). A bare name is looked for in $AGENTQ_SCRIPTS_DIR, the package's own
 * ps/bin (a checkout, or the bundled dist/ one and two levels down), then ~/.copilot/bin — where
 * ps/install.ps1 puts the live copy every hook uses — and ~/.codai/bin.
 */
export function resolveScript(name: string): string {
    if (isAbsolute(name)) return name;
    const here = import.meta.dirname;
    const dirs = [
        process.env["AGENTQ_SCRIPTS_DIR"],
        join(here, "..", "ps", "bin"),
        join(here, "..", "..", "ps", "bin"),
        join(homedir(), ".copilot", "bin"),
        join(homedir(), ".codai", "bin"),
    ].filter((d): d is string => Boolean(d));
    for (const d of dirs) {
        const p = join(d, name);
        if (existsSync(p)) return p;
    }
    return join(dirs[dirs.length - 1]!, name);
}

/** One spawn attempt. Returns "enoent" when the binary itself is missing, so a caller can fall back. */
function spawnOnce(bin: string, args: string[], opts: RunOptions): Promise<PwshResult | "enoent"> {
    return new Promise((done) => {
        // stdio is piped, never inherited: the MCP transport owns this process's stdio, so a child that
        // wrote to it would corrupt the protocol stream.
        const child = spawn(bin, args, {
            cwd: opts.cwd,
            env: opts.env ? { ...process.env, ...opts.env } : process.env,
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
        });
        let stdout = "";
        let stderr = "";
        let timer: NodeJS.Timeout | undefined;
        let settled = false;
        const finish = (r: PwshResult | "enoent"): void => {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            done(r);
        };
        child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
        child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
        child.on("error", (e: NodeJS.ErrnoException) => {
            if (e.code === "ENOENT") finish("enoent");
            else finish({ code: 127, stdout, stderr: stderr || `agentq: ${e.message}` });
        });
        // exit code, not signal: `c ?? (sig ? 1 : 0)` mirrors runCommand() in src/cli.ts
        child.on("close", (code, signal) => finish({ code: code ?? (signal ? 1 : 0), stdout, stderr }));
        if (opts.timeoutMs && opts.timeoutMs > 0) {
            const ms = opts.timeoutMs;
            timer = setTimeout(() => {
                stderr += `\nagentq: killed after ${ms} ms (timeout)`;
                child.kill(); // stops the shell; a grandchild may survive, which is acceptable on a timeout
                finish({ code: 124, stdout, stderr });
            }, ms);
            timer.unref();
        }
    });
}

/** Run an executable directly with an argv array (never a shell string) and captured output. */
export async function runProcess(file: string, args: string[], opts: RunOptions = {}): Promise<PwshResult> {
    const r = await spawnOnce(file, args, opts);
    return r === "enoent" ? { code: 127, stdout: "", stderr: `agentq: cannot find ${file}` } : r;
}

/**
 * Run one PowerShell script with an argv ARRAY — never a joined shell string, so an argument containing a
 * space stays one element. Prefers pwsh, falling back to Windows PowerShell when pwsh is absent.
 */
export async function runPwsh(script: string, args: string[], opts: RunOptions = {}): Promise<PwshResult> {
    const file = resolveScript(script);
    const argv = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file, ...args];
    for (const shell of SHELLS) {
        const r = await spawnOnce(shell, argv, opts);
        if (r !== "enoent") return r;
    }
    return { code: 127, stdout: "", stderr: `agentq: neither ${SHELLS.join(" nor ")} is available to run ${file}` };
}

/**
 * The last JSON object or array a script wrote on its own line — e.g. the compact payload a `-Json` call
 * prints after prose. Scanned from the end so a shell's incidental logging cannot shadow the real result.
 */
export function parseJsonLine<T = unknown>(stdout: string): T | undefined {
    const lines = stdout.split(/\r?\n/);
    for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i]!.trim();
        if (line.length === 0 || (line[0] !== "{" && line[0] !== "[")) continue;
        try {
            return JSON.parse(line) as T;
        } catch {
            /* not this line */
        }
    }
    return undefined;
}
