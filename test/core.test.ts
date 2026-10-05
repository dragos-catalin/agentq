import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AcpError, Coordinator, ERR } from "../src/core.ts";
import { verifyChain, type JournalEntry } from "../src/journal.ts";

function clock(start = 1_000_000) {
    let t = start;
    return { now: () => t, advance: (ms: number) => (t += ms) };
}

const owner = (session: string, purpose = "build") => ({ session, purpose });

describe("coordinator", () => {
    it("grants in FIFO order up to capacity", () => {
        const c = new Coordinator({ dir: null, capacities: { "build:machine": 2 } });
        const a = c.acquire({ resource: "build:machine", owner: owner("a") });
        const b = c.acquire({ resource: "build:machine", owner: owner("b") });
        const d = c.acquire({ resource: "build:machine", owner: owner("d") });
        expect([a.held, b.held, d.held]).toEqual([true, true, false]);
        c.release(a.id);
        expect(c.view(c.get(d.id)).held).toBe(true);
        const s = c.status("build:machine")[0]!;
        expect(s.holders.map((t) => t.owner.session)).toEqual(["b", "d"]);
    });

    it("expires a lapsed lease and promotes the next waiter", () => {
        const k = clock();
        const c = new Coordinator({ dir: null, now: k.now, defaultLeaseMs: 10_000 });
        const a = c.acquire({ resource: "deploy:web:prod", owner: owner("a") });
        const b = c.acquire({ resource: "deploy:web:prod", owner: owner("b") });
        k.advance(5_000);
        c.heartbeat(b.id); // waiting keeps b alive
        k.advance(6_000); // a lapsed at 10 s
        expect(c.heartbeat(b.id).held).toBe(true);
        expect(() => c.get(a.id)).toThrow(/unknown ticket/);
        const exp = c.journal.read().find((e) => e.event === "expire");
        expect(exp).toMatchObject({ ticket: a.id, reason: "lease expired" });
    });

    it("releases at once when the owner pid is dead", () => {
        let alive = true;
        const c = new Coordinator({ dir: null, isAlive: () => alive });
        const a = c.acquire({ resource: "install:x", owner: { ...owner("a"), pid: 4242 } });
        const b = c.acquire({ resource: "install:x", owner: owner("b") });
        expect(c.view(c.get(b.id)).held).toBe(false);
        alive = false;
        expect(c.reap()).toBe(1);
        expect(c.view(c.get(b.id)).held).toBe(true);
        expect(() => c.get(a.id)).toThrow();
    });

    it("refuses new tickets on a frozen resource but keeps current holders", () => {
        const c = new Coordinator({ dir: null });
        const a = c.acquire({ resource: "deploy:api:prod", owner: owner("a") });
        c.mark("deploy:api:prod", "frozen", "incident: 500s since 08:12Z", "oncall");
        try {
            c.acquire({ resource: "deploy:api:prod", owner: owner("b") });
            expect.unreachable();
        } catch (e) {
            expect(e).toBeInstanceOf(AcpError);
            expect((e as AcpError).code).toBe(ERR.MARKED);
            expect((e as AcpError).message).toContain("incident");
        }
        expect(c.heartbeat(a.id).held).toBe(true);
        c.mark("deploy:api:prod", "clear", "rolled back", "oncall");
        expect(c.acquire({ resource: "deploy:api:prod", owner: owner("b") }).held).toBe(false);
    });

    it("validates names, purpose and reasons", () => {
        const c = new Coordinator({ dir: null });
        expect(() => c.acquire({ resource: "Build Repo", owner: owner("a") })).toThrow(/invalid resource/);
        expect(() => c.acquire({ resource: "build:x", owner: owner("a", " ") })).toThrow(/purpose/);
        const t = c.acquire({ resource: "build:x", owner: owner("a") });
        expect(() => c.break(t.id, "", "me")).toThrow(/reason/);
        expect(() => c.mark("build:x", "frozen", "", "me")).toThrow(/reason/);
    });

    it("break removes a ticket and records who and why", () => {
        const c = new Coordinator({ dir: null });
        const t = c.acquire({ resource: "build:x", owner: owner("a", "stuck build") });
        c.break(t.id, "holder wedged 54 min", "b");
        const e = c.journal.read().at(-1)!;
        expect(e).toMatchObject({
            event: "break",
            session: "b",
            ticket: t.id,
            purpose: "stuck build",
            reason: "holder wedged 54 min",
        });
    });

    it("persists state and journal across restarts", () => {
        const dir = mkdtempSync(join(tmpdir(), "agentq-"));
        const c1 = new Coordinator({ dir, defaultLeaseMs: 3_600_000 });
        const t = c1.acquire({ resource: "build:x", owner: owner("a") });
        c1.mark("deploy:x:prod", "blocked", "waiting for migration", "a");
        const c2 = new Coordinator({ dir });
        expect(c2.view(c2.get(t.id)).held).toBe(true);
        expect(c2.status("deploy:x:prod")[0]!.mark?.state).toBe("blocked");
        expect(c2.acquire({ resource: "build:x", owner: owner("b") }).seq).toBe(t.seq + 1);
        expect(verifyChain(c2.journal.read())).toBe(-1);
    });

    it("status filters by repo name inside resource names", () => {
        const c = new Coordinator({ dir: null });
        c.acquire({ resource: "build:web", owner: owner("a") });
        c.acquire({ resource: "deploy:web:prod", owner: owner("a") });
        c.acquire({ resource: "build:api", owner: owner("a") });
        expect(c.status("web").map((s) => s.resource)).toEqual(["build:web", "deploy:web:prod"]);
    });
});

describe("journal chain", () => {
    it("detects an edited or deleted line", () => {
        const dir = mkdtempSync(join(tmpdir(), "agentq-"));
        const c = new Coordinator({ dir });
        for (let i = 0; i < 4; i++) c.note(`n${i}`, "a");
        const file = join(dir, "journal.jsonl");
        const lines = readFileSync(file, "utf8").trim().split("\n");
        const parsed = lines.map((l) => JSON.parse(l) as JournalEntry);
        expect(verifyChain(parsed)).toBe(-1);

        const edited = parsed.map((e, i) => (i === 1 ? { ...e, message: "forged" } : e));
        expect(verifyChain(edited)).toBe(1);
        const deleted = parsed.filter((_, i) => i !== 2);
        expect(verifyChain(deleted)).toBe(2);
        writeFileSync(file, lines.join("\n") + "\n");
    });
});
