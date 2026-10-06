import type { Mark } from "./core.ts";

/**
 * Pre-tool hooks for coding agents (Claude Code, Codex, GitHub Copilot CLI, VS Code Copilot).
 *
 * The hook reads the agent's PreToolUse payload, classifies the shell command with a heuristic
 * rule table, and either rewrites it to run under `agentq run` or denies it with the command to
 * run instead. Everything here is pure: file, git and daemon access come in through `HookDeps`.
 */

export const HOOK_AGENTS = ["claude", "codex", "copilot", "vscode"] as const;
export type HookAgent = (typeof HOOK_AGENTS)[number];
export type HookShell = "bash" | "pwsh";
export type HookKind = "deploy" | "build" | "install" | "commit";
export type HookMode = "rewrite" | "deny" | "off";

/** Most significant first: one command holds one resource, the most important one it touches. */
export const KIND_RANK: readonly HookKind[] = ["deploy", "build", "install", "commit"];

export interface HookRule {
    match: string;
    kind: HookKind;
    target?: string;
}

export interface HookRulesFile {
    rules?: HookRule[];
    mode?: HookMode;
}

export interface GitInfo {
    /** Working tree root (`git rev-parse --show-toplevel`). */
    toplevel: string;
    /** Absolute `git rev-parse --git-common-dir`: shared by every worktree of one repository. */
    commonDir: string;
}

export interface HookDeps {
    env: Record<string, string | undefined>;
    platform: string;
    /** The hook process's working directory, used when the payload carries no cwd. */
    cwd: string;
    /** agentq state dir ($AGENTQ_HOME or ~/.agentq). */
    stateDir: string;
    readFile(path: string): string | null;
    git(cwd: string): GitInfo | null;
    /** Freeze mark of a resource from a running daemon (no autostart). null when none or unreachable. */
    mark(resource: string): Promise<Mark | null>;
}

/** Parsed hook payload, independent of the agent's wire format. */
export interface HookInput {
    agent: HookAgent;
    /** "flat" = Copilot CLI camelCase output; "envelope" = Claude-style hookSpecificOutput. */
    output: "flat" | "envelope";
    eventName: string;
    toolName: string;
    command: string;
    shell: HookShell;
    cwd: string | undefined;
    /** Every original tool argument, so a rewrite can replace only `command`. */
    args: Record<string, unknown>;
}

export interface Segment {
    /** Raw text of the simple command, trimmed. */
    text: string;
    /** Words with quotes and escapes removed. */
    words: string[];
}

export interface Classified {
    kind: HookKind;
    target: string;
    segment: string;
}

export type HookDecision =
    | { action: "none"; why: string }
    | { action: "rewrite"; resource: string; command: string; input: HookInput }
    | { action: "deny"; resource: string; reason: string; input: HookInput };

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

// ---------------------------------------------------------------- input

/** Parse a hook payload. Returns null for malformed JSON, non-shell tools and missing commands. */
export function parseHookInput(agent: HookAgent, raw: string, platform: string): HookInput | null {
    let j: unknown;
    try {
        j = JSON.parse(raw);
    } catch {
        return null;
    }
    if (!isObj(j)) return null;
    const winShell: HookShell = platform === "win32" ? "pwsh" : "bash";

    // Copilot CLI camelCase: { toolName, toolArgs (object or JSON string), cwd }
    if (agent === "copilot" && j["toolName"] !== undefined && j["tool_name"] === undefined) {
        const tool = (str(j["toolName"]) ?? "").toLowerCase();
        if (tool !== "bash" && tool !== "powershell") return null;
        let args: unknown = j["toolArgs"];
        if (typeof args === "string") {
            try {
                args = JSON.parse(args);
            } catch {
                return null;
            }
        }
        if (!isObj(args)) return null;
        const command = str(args["command"]);
        if (!command?.trim()) return null;
        return {
            agent,
            output: "flat",
            eventName: "preToolUse",
            toolName: str(j["toolName"])!,
            command,
            shell: tool === "powershell" ? "pwsh" : "bash",
            cwd: str(j["cwd"]),
            args,
        };
    }

    // Claude-style snake_case: Claude Code, Codex, VS Code, and Copilot's PascalCase variant.
    const toolName = str(j["tool_name"]);
    const args = j["tool_input"];
    if (!toolName || !isObj(args)) return null;
    const command = str(args["command"]);
    if (!command?.trim()) return null;
    let shell: HookShell;
    if (agent === "claude") {
        if (toolName === "Bash") shell = "bash";
        else if (toolName === "PowerShell") shell = "pwsh";
        else return null;
    } else if (agent === "codex") {
        if (toolName !== "Bash") return null;
        shell = "bash";
    } else if (agent === "vscode") {
        if (toolName !== "run_in_terminal") return null;
        shell = winShell;
    } else {
        const t = toolName.toLowerCase();
        if (t === "bash") shell = "bash";
        else if (t === "powershell") shell = "pwsh";
        else return null;
    }
    return {
        agent,
        output: "envelope",
        eventName: str(j["hook_event_name"]) ?? "PreToolUse",
        toolName,
        command,
        shell,
        cwd: str(j["cwd"]),
        args,
    };
}

// ---------------------------------------------------------------- tokenizer

/**
 * Split a command line into simple commands on `&&`, `||`, `;`, `|`, `&` and newlines, respecting
 * single and double quotes and the shell's escape character (`\` in bash, backtick in pwsh).
 * A heuristic: it does not expand variables, aliases, functions, `$(...)` or here-docs.
 */
export function splitSegments(cmd: string, shell: HookShell): Segment[] {
    const esc = shell === "pwsh" ? "`" : "\\";
    const segs: Segment[] = [];
    let text = "";
    let word = "";
    let inWord = false;
    let words: string[] = [];
    let quote: string | null = null;
    const endWord = (): void => {
        if (inWord) words.push(word);
        word = "";
        inWord = false;
    };
    const endSeg = (): void => {
        endWord();
        if (words.length) segs.push({ text: text.trim(), words });
        text = "";
        words = [];
    };
    for (let i = 0; i < cmd.length; i++) {
        const c = cmd[i]!;
        const next = cmd[i + 1];
        if (quote) {
            if (c === quote) quote = null;
            else if (quote === '"' && c === esc && next !== undefined) {
                word += next;
                text += c;
                i++;
                text += next;
                continue;
            } else word += c;
            text += c;
            continue;
        }
        if (c === "'" || c === '"') {
            quote = c;
            inWord = true;
            text += c;
            continue;
        }
        if (c === esc && next !== undefined) {
            i++;
            if (next === "\n" || next === "\r") {
                if (next === "\r" && cmd[i + 1] === "\n") i++;
                endWord();
                text += " ";
                continue;
            }
            word += next;
            inWord = true;
            text += c + next;
            continue;
        }
        if (c === "\n" || c === "\r" || c === ";" || c === "|" || c === "&") {
            endSeg();
            continue;
        }
        if (/\s/.test(c)) {
            endWord();
            text += c;
            continue;
        }
        word += c;
        inWord = true;
        text += c;
    }
    endSeg();
    return segs;
}

// ---------------------------------------------------------------- classification

const progName = (w: string): string =>
    (w.split(/[\\/]/).pop() ?? w).toLowerCase().replace(/\.(cmd|exe|bat|ps1|sh)$/, "");

const ENV_ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;
const WRAPPERS = new Set(["sudo", "time", "nice", "env", "command", "exec", "nohup"]);

/** Drop env assignments, wrappers (`sudo`, `env`) and package runners (`npx`, `pnpm exec`, `bunx`). */
export function stripPrefixes(words: string[]): string[] {
    let w = [...words];
    for (let guard = 0; guard < 8 && w.length; guard++) {
        const p = progName(w[0]!);
        if (ENV_ASSIGN.test(w[0]!) || WRAPPERS.has(p)) {
            w = w.slice(1);
            continue;
        }
        if (p === "npx" || p === "bunx" || p === "pnpx") {
            w = w.slice(1);
            while (w.length && w[0]!.startsWith("-")) w = w.slice(1);
            continue;
        }
        if ((p === "pnpm" || p === "yarn" || p === "npm") && (w[1] === "exec" || w[1] === "dlx")) {
            w = w.slice(2);
            while (w.length && w[0]!.startsWith("-")) w = w.slice(1);
            continue;
        }
        break;
    }
    return w;
}

const VALUE_FLAGS: Record<string, string[]> = {
    pnpm: ["--filter", "-F", "-C", "--dir", "--reporter", "--loglevel", "--workspace-root"],
    npm: ["--prefix", "-w", "--workspace", "--loglevel"],
    yarn: ["--cwd"],
    bun: ["--cwd", "--filter"],
    git: ["-C", "-c", "--git-dir", "--work-tree", "--namespace"],
    gcloud: ["--project", "--region", "--account", "--configuration", "--format", "--impersonate-service-account"],
    docker: ["--context", "-c", "-H", "--host", "--config", "-l", "--log-level"],
    terraform: ["-chdir"],
    turbo: ["--filter", "-F", "--cwd"],
};

/** Positional arguments of a command, skipping flags and the values of known value-taking flags. */
function positionals(prog: string, args: string[]): string[] {
    const takes = new Set(VALUE_FLAGS[prog] ?? []);
    const out: string[] = [];
    for (let i = 0; i < args.length; i++) {
        const a = args[i]!;
        if (a === "--") {
            out.push(...args.slice(i + 1));
            break;
        }
        if (a.startsWith("-") || a.startsWith("+")) {
            if (takes.has(a)) i++;
            continue;
        }
        out.push(a);
    }
    return out;
}

const isBuildScript = (s: string | undefined): boolean => !!s && /^build(?:[:-][\w:.-]*)?$/.test(s);
const PM_INSTALL: Record<string, string[]> = {
    pnpm: ["install", "i", "add", "remove", "rm", "uninstall", "un", "update", "up"],
    npm: ["install", "i", "ci", "add"],
    yarn: ["install", "add"],
    bun: ["install", "i", "add"],
};
const DEPLOY_ONE: Record<string, string> = {
    terraform: "apply",
    tofu: "apply",
    pulumi: "up",
    wrangler: "deploy",
    fly: "deploy",
    flyctl: "deploy",
};

/** Built-in rule table. Returns the kind of a simple command, or null when it needs no resource. */
export function builtinKind(words: string[]): HookKind | null {
    const w = stripPrefixes(words);
    if (!w.length) return null;
    const prog = progName(w[0]!);
    const pos = positionals(prog, w.slice(1));
    const [a, b] = pos;

    if (prog in PM_INSTALL) {
        if (prog === "yarn" && pos.length === 0) return "install";
        if (PM_INSTALL[prog]!.includes(a ?? "")) return "install";
        if (a === "publish" || (prog === "yarn" && a === "npm" && b === "publish")) return "deploy";
        if ((a === "run" || a === "run-script") && isBuildScript(b)) return "build";
        if (prog !== "npm" && isBuildScript(a)) return "build";
        return null;
    }
    switch (prog) {
        case "pip":
        case "pip3":
            return a === "install" ? "install" : null;
        case "python":
        case "python3":
        case "py": {
            const m = w.indexOf("-m");
            return m >= 0 && progName(w[m + 1] ?? "") === "pip" && w[m + 2] === "install" ? "install" : null;
        }
        case "uv":
            return a === "sync" || (a === "pip" && b === "install") ? "install" : null;
        case "cargo":
            if (a === "fetch") return "install";
            if (a === "build" || a === "b") return "build";
            if (a === "publish") return "deploy";
            return null;
        case "turbo": {
            const tasks = a === "run" ? pos.slice(1) : pos;
            return tasks.some(isBuildScript) ? "build" : null;
        }
        case "next":
        case "vite":
            return a === "build" ? "build" : null;
        case "tsdown":
            return "build";
        case "gradle":
        case "gradlew":
            return pos.some((t) => /(^|:)(assemble\w*|build|bundle\w*)$/.test(t)) ? "build" : null;
        case "docker":
        case "podman":
            if (a === "build" || ((a === "buildx" || a === "image") && b === "build")) return "build";
            if (a === "push" || (a === "image" && b === "push")) return "deploy";
            return null;
        case "dotnet":
            return a === "build" ? "build" : null;
        case "vercel":
            return w.includes("--prod") || a === "deploy" ? "deploy" : null;
        case "gcloud": {
            const g = pos.filter((x) => x !== "alpha" && x !== "beta");
            const [g0, g1, g2] = g;
            if (g0 === "run" && (g1 === "deploy" || (g1 === "jobs" && g2 === "deploy"))) return "deploy";
            if (g0 === "run" && g1 === "services" && (g2 === "replace" || g2 === "update")) return "deploy";
            if (g0 === "builds" && g1 === "submit") return "deploy";
            if ((g0 === "app" || g0 === "functions") && g1 === "deploy") return "deploy";
            return null;
        }
        case "git":
            if (a === "commit") return "commit";
            if (a === "push") return "commit";
            return null;
    }
    if (prog in DEPLOY_ONE) return a === DEPLOY_ONE[prog] ? "deploy" : null;
    return null;
}

/** Deploy target: `prod` when the command says so, else `default`. */
export function deployTarget(words: string[]): string {
    return words.some((x) => x === "--prod" || /production/i.test(x)) ? "prod" : "default";
}

/** Classify every simple command; extra rules (regex on the segment text) win over the built-ins. */
export function classifyCommand(command: string, shell: HookShell, extra: HookRule[] = []): Classified[] {
    const compiled = extra.flatMap((r) => {
        if (!KIND_RANK.includes(r.kind)) return [];
        try {
            return [{ re: new RegExp(r.match), rule: r }];
        } catch {
            return [];
        }
    });
    const out: Classified[] = [];
    for (const seg of splitSegments(command, shell)) {
        const user = compiled.find((x) => x.re.test(seg.text));
        const kind = user ? user.rule.kind : builtinKind(seg.words);
        if (!kind) continue;
        const target = user?.rule.target ?? deployTarget(seg.words);
        out.push({ kind, target: kind === "deploy" ? target : "", segment: seg.text });
    }
    return out;
}

/** Lowercase and keep only characters valid in an ACP-Lock resource segment. */
export function sanitizeSegment(s: string): string {
    const v = s
        .toLowerCase()
        .replace(/[^a-z0-9._-]+/g, "-")
        .replace(/^[^a-z0-9]+/, "")
        .replace(/-+$/, "");
    return v || "repo";
}

const baseName = (p: string): string =>
    p
        .replace(/[\\/]+$/, "")
        .split(/[\\/]/)
        .pop() ?? p;
const dirName = (p: string): string => p.replace(/[\\/]+$/, "").replace(/[\\/][^\\/]*$/, "");

/** Repository name shared by all worktrees: the folder owning the git common dir, else the cwd's name. */
export function repoName(git: GitInfo | null, cwd: string): string {
    if (git) {
        const common = git.commonDir;
        const b = baseName(common);
        return sanitizeSegment(b.toLowerCase() === ".git" ? baseName(dirName(common)) : b.replace(/\.git$/i, ""));
    }
    return sanitizeSegment(baseName(cwd));
}

export function resourceFor(c: Pick<Classified, "kind" | "target">, repo: string): string {
    return c.kind === "deploy" ? `deploy:${repo}:${sanitizeSegment(c.target || "default")}` : `${c.kind}:${repo}`;
}

// ---------------------------------------------------------------- rules + mode

const MODES: readonly HookMode[] = ["rewrite", "deny", "off"];

function parseRules(text: string | null): HookRulesFile | null {
    if (!text) return null;
    try {
        const j: unknown = JSON.parse(text);
        if (!isObj(j)) return null;
        const rules = Array.isArray(j["rules"])
            ? j["rules"].flatMap((r): HookRule[] => {
                  if (!isObj(r) || typeof r["match"] !== "string" || !KIND_RANK.includes(r["kind"] as HookKind))
                      return [];
                  return [
                      {
                          match: r["match"],
                          kind: r["kind"] as HookKind,
                          ...(typeof r["target"] === "string" ? { target: r["target"] } : {}),
                      },
                  ];
              })
            : [];
        const mode = MODES.includes(j["mode"] as HookMode) ? (j["mode"] as HookMode) : undefined;
        return { rules, ...(mode ? { mode } : {}) };
    } catch {
        return null;
    }
}

const joinPath = (a: string, b: string): string => `${a.replace(/[\\/]+$/, "")}/${b}`;

/**
 * Load rules: user-level files ($AGENTQ_HOOK_RULES, $AGENTQ_HOME/hooks.json) may set any mode;
 * the repo file (<root>/.agentq/hooks.json) can only add rules or tighten the mode to `deny`.
 * Mode precedence: $AGENTQ_HOOK_MODE > user files > repo `deny` > `rewrite`.
 */
export function loadHookConfig(
    deps: Pick<HookDeps, "env" | "readFile" | "stateDir">,
    repoRoot: string | null,
): { rules: HookRule[]; mode: HookMode } {
    const userFiles = [deps.env["AGENTQ_HOOK_RULES"], joinPath(deps.stateDir, "hooks.json")].filter(
        (p): p is string => !!p,
    );
    const user = userFiles.map((p) => parseRules(deps.readFile(p))).filter((x) => x !== null);
    const repo = repoRoot ? parseRules(deps.readFile(joinPath(repoRoot, ".agentq/hooks.json"))) : null;
    const rules = [...user.flatMap((u) => u.rules ?? []), ...(repo?.rules ?? [])];
    const envMode = deps.env["AGENTQ_HOOK_MODE"]?.toLowerCase() as HookMode | undefined;
    const mode =
        (envMode && MODES.includes(envMode) ? envMode : undefined) ??
        user.find((u) => u.mode)?.mode ??
        (repo?.mode === "deny" ? "deny" : undefined) ??
        "rewrite";
    return { rules, mode };
}

// ---------------------------------------------------------------- rewrite

export const quoteBash = (s: string): string => `'${s.replace(/'/g, `'\\''`)}'`;
/** PowerShell single-quoted literal; typographic single quotes also close a pwsh string, so double them too. */
export const quotePwsh = (s: string): string => `'${s.replace(/['\u2018\u2019\u201a\u201b]/g, "$&$&")}'`;

const SIMPLE: Record<HookShell, RegExp> = {
    bash: /^[\w\s./:=@+,%-]+$/,
    pwsh: /^[\w\s./:=+\\-]+$/,
};

/** True when the command is one simple command that `agentq run` can spawn directly, with no shell. */
export function isSimpleCommand(command: string, shell: HookShell): boolean {
    return !command.includes("\n") && SIMPLE[shell].test(command.trim());
}

/**
 * `pwsh -Command` exits 1 or 0 from `$?`, not with the native exit code. Re-raise it on failure;
 * on a new line only when a `#` could comment it out (a newline in a terminal line invites `>>`).
 */
const PWSH_EXIT = "if (-not $?) { if ($LASTEXITCODE) { exit $LASTEXITCODE } else { exit 1 } }";
const pwshScript = (command: string): string => `${command}${/[#\n]/.test(command) ? "\n" : "; "}${PWSH_EXIT}`;

/** `agentq run -r <resource> -p <purpose> -- <command>`, valid in the same shell the agent uses. */
export function buildRewrite(opts: {
    command: string;
    shell: HookShell;
    resource: string;
    purpose: string;
    bin: string;
}): string {
    const { command, shell, resource, purpose, bin } = opts;
    const q = shell === "pwsh" ? quotePwsh : quoteBash;
    const simple = isSimpleCommand(command, shell);
    const inner = simple
        ? command.trim()
        : shell === "pwsh"
          ? `pwsh -NoProfile -Command ${quotePwsh(pwshScript(command))}`
          : `bash -c ${quoteBash(command)}`;
    // A bare -- is PowerShell's end-of-parameters token and a .ps1 shim would swallow it; quoted it is a plain string.
    const dd = shell === "pwsh" ? "'--'" : "--";
    return `${bin} run -r ${resource} -p ${q(purpose)} ${dd} ${inner}`;
}

/** True when the command already goes through agentq (`agentq ...`, `npx @codai/agentq ...`, $AGENTQ_HOOK_BIN). */
export function alreadyQueued(command: string, shell: HookShell, bin: string): boolean {
    const t = command.trimStart();
    if (bin && t.startsWith(bin)) return true;
    const first = splitSegments(command, shell)[0];
    if (!first) return false;
    const w = stripPrefixes(first.words);
    return /(^|[\\/])agentq(@[\w.-]+)?(\.(cmd|exe|ps1|mjs|js))?$/i.test(w[0] ?? "");
}

// ---------------------------------------------------------------- decision

const oneLine = (s: string): string => s.replace(/\s+/g, " ").trim();

export async function decideHook(agent: HookAgent, raw: string, deps: HookDeps): Promise<HookDecision> {
    const input = parseHookInput(agent, raw, deps.platform);
    if (!input) return { action: "none", why: "not a shell tool call" };
    const bin = deps.env["AGENTQ_HOOK_BIN"] || "agentq";
    if (alreadyQueued(input.command, input.shell, bin)) return { action: "none", why: "already runs under agentq" };

    const cwd = input.cwd && input.cwd !== "." ? input.cwd : deps.cwd;
    const git = deps.git(cwd);
    const { rules, mode } = loadHookConfig(deps, git?.toplevel ?? null);
    if (mode === "off") return { action: "none", why: "mode off" };

    const found = classifyCommand(input.command, input.shell, rules);
    if (!found.length) return { action: "none", why: "no queued resource" };
    found.sort((x, y) => KIND_RANK.indexOf(x.kind) - KIND_RANK.indexOf(y.kind));
    const repo = repoName(git, cwd);
    const resource = resourceFor(found[0]!, repo);
    const held = (deps.env["AGENTQ_HELD"] ?? "").split(",").map((s) => s.trim());
    if (held.includes(resource)) return { action: "none", why: "resource already held (nested)" };

    const others = [...new Set(found.slice(1).map((f) => resourceFor(f, repo)))].filter((r) => r !== resource);
    const purpose = `${agent} hook: ${oneLine(input.command).slice(0, 80)}${others.length ? ` [+ ${others.join(", ")}]` : ""}`;

    const mark = await deps.mark(resource).catch(() => null);
    if (mark) {
        return {
            action: "deny",
            resource,
            input,
            reason: `agentq: ${resource} is ${mark.state}: ${mark.reason} (by ${mark.session} at ${mark.at}). Do not run it until someone clears the mark (agentq mark -r ${resource} --state clear --reason <why>).`,
        };
    }
    const rewritten = buildRewrite({ command: input.command, shell: input.shell, resource, purpose, bin });
    if (mode === "deny") {
        return {
            action: "deny",
            resource,
            input,
            reason: `agentq: this command needs ${resource}; other agents may be using it. Run it through the queue instead: ${rewritten}`,
        };
    }
    return { action: "rewrite", resource, command: rewritten, input };
}

/** The exact JSON the agent expects on stdout, or "" for no opinion. */
export function renderHookOutput(d: HookDecision): string {
    if (d.action === "none") return "";
    const i = d.input;
    if (i.output === "flat") {
        return JSON.stringify(
            d.action === "rewrite"
                ? { permissionDecision: "allow", modifiedArgs: { ...i.args, command: d.command } }
                : { permissionDecision: "deny", permissionDecisionReason: d.reason },
        );
    }
    return JSON.stringify({
        hookSpecificOutput:
            d.action === "rewrite"
                ? {
                      hookEventName: i.eventName,
                      permissionDecision: "allow",
                      updatedInput: { ...i.args, command: d.command },
                  }
                : { hookEventName: i.eventName, permissionDecision: "deny", permissionDecisionReason: d.reason },
    });
}

/** Run one hook invocation end to end. Never throws: any internal error means no output (fail open). */
export async function runHook(agent: HookAgent, raw: string, deps: HookDeps): Promise<string> {
    try {
        return renderHookOutput(await decideHook(agent, raw, deps));
    } catch {
        return "";
    }
}

// ---------------------------------------------------------------- config snippets

/** Config snippet that registers the hook for an agent (printed, never written). */
export function hookConfig(agent: HookAgent): string {
    const command = `agentq hook ${agent}`;
    switch (agent) {
        case "claude":
            return JSON.stringify(
                {
                    hooks: {
                        PreToolUse: [
                            { matcher: "Bash|PowerShell", hooks: [{ type: "command", command, timeout: 30 }] },
                        ],
                    },
                },
                null,
                2,
            );
        case "codex":
            return [
                "# ~/.codex/config.toml, then trust the hook with /hooks",
                "[features]",
                "hooks = true",
                "",
                "[[hooks.PreToolUse]]",
                'matcher = "^Bash$"',
                "",
                "[[hooks.PreToolUse.hooks]]",
                'type = "command"',
                `command = "${command}"`,
                "timeout = 30",
            ].join("\n");
        case "copilot":
            return JSON.stringify(
                {
                    version: 1,
                    hooks: {
                        preToolUse: [
                            {
                                type: "command",
                                matcher: "bash|powershell",
                                bash: command,
                                powershell: command,
                                timeoutSec: 30,
                            },
                        ],
                    },
                },
                null,
                2,
            );
        case "vscode":
            return JSON.stringify({ hooks: { PreToolUse: [{ type: "command", command, timeout: 15 }] } }, null, 2);
    }
}
