import { createHash } from "node:crypto";
import { appendFileSync, existsSync, readFileSync } from "node:fs";

/**
 * Append-only, hash-chained journal (ACP-Lock §6). Each entry carries the hash of
 * the previous one, so deleting or editing a line breaks every later hash.
 */
export interface JournalEntry {
    seq: number;
    ts: string;
    event: string;
    session: string;
    resource?: string;
    ticket?: string;
    purpose?: string;
    reason?: string;
    message?: string;
    state?: string;
    exit?: number;
    prev: string;
    hash: string;
}

export type JournalInput = Omit<JournalEntry, "seq" | "ts" | "prev" | "hash">;

export const GENESIS = "0".repeat(64);

export function canonical(v: unknown): string {
    if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
    if (v && typeof v === "object") {
        const o = v as Record<string, unknown>;
        return `{${Object.keys(o)
            .filter((k) => o[k] !== undefined)
            .sort()
            .map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`)
            .join(",")}}`;
    }
    return JSON.stringify(v);
}

export function entryHash(e: Omit<JournalEntry, "hash">): string {
    return createHash("sha256").update(canonical(e)).digest("hex");
}

export class Journal {
    private entries: JournalEntry[] = [];
    private readonly file: string | null;
    private readonly now: () => number;

    constructor(file: string | null, now: () => number) {
        this.file = file;
        this.now = now;
        if (file && existsSync(file)) {
            for (const line of readFileSync(file, "utf8").split("\n")) {
                if (line.trim()) this.entries.push(JSON.parse(line) as JournalEntry);
            }
        }
    }

    get last(): JournalEntry | undefined {
        return this.entries[this.entries.length - 1];
    }

    append(input: JournalInput): JournalEntry {
        const body: Omit<JournalEntry, "hash"> = {
            ...input,
            seq: (this.last?.seq ?? 0) + 1,
            ts: new Date(this.now()).toISOString(),
            prev: this.last?.hash ?? GENESIS,
        };
        const e: JournalEntry = { ...body, hash: entryHash(body) };
        this.entries.push(e);
        if (this.file) appendFileSync(this.file, `${JSON.stringify(e)}\n`);
        return e;
    }

    read(opts: { after?: number; limit?: number; resource?: string } = {}): JournalEntry[] {
        let out = this.entries.filter((e) => e.seq > (opts.after ?? 0));
        if (opts.resource) {
            const r = opts.resource;
            out = out.filter(
                (e) => e.resource === r || e.resource?.startsWith(`${r}:`) || e.resource?.endsWith(`:${r}`),
            );
        }
        return opts.limit ? out.slice(-opts.limit) : out;
    }
}

/** Index of the first broken entry, or -1 when the whole chain verifies. */
export function verifyChain(entries: JournalEntry[]): number {
    let prev = GENESIS;
    for (let i = 0; i < entries.length; i++) {
        const { hash, ...body } = entries[i]!;
        if (body.prev !== prev || entryHash(body) !== hash) return i;
        prev = hash;
    }
    return -1;
}
