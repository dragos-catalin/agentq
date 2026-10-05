import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Journal, type JournalEntry } from "./journal.ts";

/** ACP-Lock core: FIFO tickets per resource, capacity, leases, marks, journal. */

export interface Owner {
    session: string;
    purpose: string;
    /** Same-host liveness: a dead pid releases the ticket at once. */
    pid?: number;
    host?: string;
}

export interface Ticket {
    id: string;
    resource: string;
    seq: number;
    owner: Owner;
    created: number;
    /** Lease deadline (ms since epoch). Extended by heartbeat and by waiting. */
    expires: number;
    leaseMs: number;
}

export type MarkState = "frozen" | "blocked";

export interface Mark {
    resource: string;
    state: MarkState;
    reason: string;
    session: string;
    at: string;
}

export interface TicketView extends Ticket {
    held: boolean;
    position: number;
}

export interface ResourceStatus {
    resource: string;
    capacity: number;
    holders: TicketView[];
    waiters: TicketView[];
    mark?: Mark;
}

export class AcpError extends Error {
    readonly code: number;
    readonly data: unknown;
    constructor(code: number, message: string, data?: unknown) {
        super(message);
        this.code = code;
        this.data = data;
    }
}

export const ERR = {
    MARKED: -32001,
    UNKNOWN_TICKET: -32002,
    INVALID: -32602,
} as const;

export interface CoordinatorOptions {
    /** State directory; null keeps everything in memory (tests). */
    dir: string | null;
    now?: () => number;
    defaultLeaseMs?: number;
    capacities?: Record<string, number>;
    isAlive?: (pid: number) => boolean;
}

interface Persisted {
    seq: number;
    tickets: Ticket[];
    marks: Mark[];
    capacities: Record<string, number>;
}

export const RESOURCE_RE = /^[a-z0-9][a-z0-9._/-]*(:[a-z0-9._/-]+)*$/;

function defaultIsAlive(pid: number): boolean {
    try {
        process.kill(pid, 0);
        return true;
    } catch (e) {
        // EPERM: exists but owned by someone else.
        return (e as NodeJS.ErrnoException).code === "EPERM";
    }
}

export class Coordinator {
    readonly journal: Journal;
    private readonly now: () => number;
    private readonly defaultLeaseMs: number;
    private readonly isAlive: (pid: number) => boolean;
    private readonly stateFile: string | null;
    private seq = 0;
    private tickets = new Map<string, Ticket>();
    private marks = new Map<string, Mark>();
    private capacities: Record<string, number>;
    private listeners = new Set<() => void>();

    constructor(opts: CoordinatorOptions) {
        this.now = opts.now ?? Date.now;
        this.defaultLeaseMs = opts.defaultLeaseMs ?? 60_000;
        this.isAlive = opts.isAlive ?? defaultIsAlive;
        this.capacities = { ...(opts.capacities ?? {}) };
        if (opts.dir) mkdirSync(opts.dir, { recursive: true });
        this.stateFile = opts.dir ? join(opts.dir, "state.json") : null;
        this.journal = new Journal(opts.dir ? join(opts.dir, "journal.jsonl") : null, this.now);
        if (this.stateFile && existsSync(this.stateFile)) {
            const s = JSON.parse(readFileSync(this.stateFile, "utf8")) as Persisted;
            this.seq = s.seq;
            for (const t of s.tickets) this.tickets.set(t.id, t);
            for (const m of s.marks) this.marks.set(m.resource, m);
            this.capacities = { ...s.capacities, ...this.capacities };
        }
        this.reap();
    }

    onChange(fn: () => void): () => void {
        this.listeners.add(fn);
        return () => this.listeners.delete(fn);
    }

    private changed(): void {
        if (this.stateFile) {
            const s: Persisted = {
                seq: this.seq,
                tickets: [...this.tickets.values()],
                marks: [...this.marks.values()],
                capacities: this.capacities,
            };
            const tmp = `${this.stateFile}.tmp`;
            writeFileSync(tmp, JSON.stringify(s, null, 2));
            renameSync(tmp, this.stateFile);
        }
        for (const fn of this.listeners) fn();
    }

    capacity(resource: string): number {
        return this.capacities[resource] ?? 1;
    }

    private ordered(resource: string): Ticket[] {
        return [...this.tickets.values()].filter((t) => t.resource === resource).sort((a, b) => a.seq - b.seq);
    }

    view(t: Ticket): TicketView {
        const pos = this.ordered(t.resource).findIndex((x) => x.id === t.id);
        return { ...t, position: pos, held: pos < this.capacity(t.resource) };
    }

    /** Expire lapsed leases and dead same-host owners. Returns how many were removed. */
    reap(): number {
        const now = this.now();
        let n = 0;
        for (const t of [...this.tickets.values()]) {
            const dead = t.owner.pid !== undefined && !this.isAlive(t.owner.pid);
            if (t.expires <= now || dead) {
                this.tickets.delete(t.id);
                this.journal.append({
                    event: "expire",
                    session: t.owner.session,
                    resource: t.resource,
                    ticket: t.id,
                    purpose: t.owner.purpose,
                    reason: dead ? `owner pid ${t.owner.pid} is gone` : "lease expired",
                });
                n++;
            }
        }
        if (n) this.changed();
        return n;
    }

    private assertResource(resource: string): void {
        if (!RESOURCE_RE.test(resource)) throw new AcpError(ERR.INVALID, `invalid resource name "${resource}"`);
    }

    private assertNotMarked(resource: string): void {
        const m = this.marks.get(resource);
        if (m) throw new AcpError(ERR.MARKED, `${resource} is ${m.state}: ${m.reason}`, m);
    }

    acquire(req: { resource: string; owner: Owner; leaseMs?: number; capacity?: number }): TicketView {
        this.assertResource(req.resource);
        if (!req.owner.purpose.trim()) throw new AcpError(ERR.INVALID, "purpose is required (other agents read it)");
        this.reap();
        this.assertNotMarked(req.resource);
        if (req.capacity !== undefined) {
            if (!Number.isInteger(req.capacity) || req.capacity < 1)
                throw new AcpError(ERR.INVALID, "capacity must be >= 1");
            this.capacities[req.resource] = req.capacity;
        }
        const leaseMs = req.leaseMs ?? this.defaultLeaseMs;
        const t: Ticket = {
            id: randomBytes(6).toString("hex"),
            resource: req.resource,
            seq: ++this.seq,
            owner: req.owner,
            created: this.now(),
            expires: this.now() + leaseMs,
            leaseMs,
        };
        this.tickets.set(t.id, t);
        const v = this.view(t);
        this.journal.append({
            event: v.held ? "acquire" : "queue",
            session: t.owner.session,
            resource: t.resource,
            ticket: t.id,
            purpose: t.owner.purpose,
        });
        this.changed();
        return v;
    }

    get(id: string): Ticket {
        const t = this.tickets.get(id);
        if (!t)
            throw new AcpError(
                ERR.UNKNOWN_TICKET,
                `unknown ticket ${id} (expired, released or broken; see the journal)`,
            );
        return t;
    }

    /** Extend the lease. A frozen resource does not revoke held tickets; it only refuses new ones. */
    heartbeat(id: string): TicketView {
        this.reap();
        const t = this.get(id);
        const wasHeld = this.view(t).held;
        t.expires = this.now() + t.leaseMs;
        const v = this.view(t);
        if (v.held && !wasHeld) {
            this.journal.append({
                event: "acquire",
                session: t.owner.session,
                resource: t.resource,
                ticket: t.id,
                purpose: t.owner.purpose,
            });
        }
        this.changed();
        return v;
    }

    release(id: string, exit?: number): void {
        const t = this.get(id);
        this.tickets.delete(id);
        this.journal.append({
            event: "release",
            session: t.owner.session,
            resource: t.resource,
            ticket: t.id,
            purpose: t.owner.purpose,
            ...(exit !== undefined ? { exit } : {}),
        });
        this.changed();
    }

    break(id: string, reason: string, session: string): Ticket {
        if (!reason.trim()) throw new AcpError(ERR.INVALID, "break needs a reason");
        const t = this.get(id);
        this.tickets.delete(id);
        this.journal.append({
            event: "break",
            session,
            resource: t.resource,
            ticket: t.id,
            purpose: t.owner.purpose,
            reason,
        });
        this.changed();
        return t;
    }

    mark(resource: string, state: MarkState | "clear", reason: string, session: string): Mark | null {
        this.assertResource(resource);
        if (!reason.trim()) throw new AcpError(ERR.INVALID, "mark needs a reason");
        if (state === "clear") {
            this.marks.delete(resource);
            this.journal.append({ event: "unmark", session, resource, reason });
            this.changed();
            return null;
        }
        const m: Mark = { resource, state, reason, session, at: new Date(this.now()).toISOString() };
        this.marks.set(resource, m);
        this.journal.append({ event: "mark", session, resource, state, reason });
        this.changed();
        return m;
    }

    note(message: string, session: string, resource?: string): JournalEntry {
        const e = this.journal.append({ event: "note", session, message, ...(resource ? { resource } : {}) });
        this.changed();
        return e;
    }

    status(filter?: string): ResourceStatus[] {
        this.reap();
        const names = new Set<string>([...[...this.tickets.values()].map((t) => t.resource), ...this.marks.keys()]);
        const out: ResourceStatus[] = [];
        for (const r of [...names].sort()) {
            if (
                filter &&
                r !== filter &&
                !r.startsWith(`${filter}:`) &&
                !r.endsWith(`:${filter}`) &&
                !r.includes(`:${filter}:`)
            )
                continue;
            const views = this.ordered(r).map((t) => this.view(t));
            const m = this.marks.get(r);
            out.push({
                resource: r,
                capacity: this.capacity(r),
                holders: views.filter((v) => v.held),
                waiters: views.filter((v) => !v.held),
                ...(m ? { mark: m } : {}),
            });
        }
        return out;
    }
}
