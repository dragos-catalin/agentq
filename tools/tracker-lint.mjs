#!/usr/bin/env node
// tracker-lint — one linter for every plan/tracker on this machine.
//
// A repo keeps its native tracker file (CSV or Markdown narrative) and declares
// how to read it in `.agentq/trackers.json` (see ../spec/tracker.schema.json).
// This tool turns that declaration into facts: it reads each tracker, maps the
// columns and the status vocabulary onto the unified schema, checks the shape
// that has actually drifted before (arity, duplicate ids, a status nobody
// mapped, a narrative id that points at nothing), and - in --scan mode - writes
// ONE merged cross-repo index that `agentq tracker` and the Vitals Tracking page
// read. There is no second source of truth: the per-repo file is written by
// hand, the mapping says how it is read, and the index is a rebuildable view.
//
// Usage:
//   node tracker-lint.mjs [--root <dir>] [--json]        validate one repo
//   node tracker-lint.mjs --scan <dir> [<dir> ...]       scan repos, write index
//   node tracker-lint.mjs --scan --all [--json]          scan every child of $HOME/gh
//
// Exit code = number of drift findings (capped at 255); 0 means the conventions
// hold. Read-only except the index file in --scan mode.

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync, mkdirSync } from "node:fs";
import { join, dirname, resolve, basename } from "node:path";
import { homedir } from "node:os";
// The single definition of root health lives in track.mjs (this file imports it
// so the scan and `track status` cannot disagree). track.mjs imports scanRepo
// from here in turn - an intentional, benign cycle: both are function
// declarations, so each binding is initialised before either module body runs.
import { rootIssueFor } from "./track.mjs";

const CANONICAL = ["todo", "in-progress", "blocked", "review", "done", "dropped", "deferred"];
const REQUIRED = ["id", "title", "status"];

function parseArgs(argv) {
    const out = { root: process.cwd(), json: false, scan: false, all: false, dirs: [] };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--root") out.root = resolve(argv[++i]);
        else if (a === "--json") out.json = true;
        else if (a === "--scan") out.scan = true;
        else if (a === "--all") out.all = true;
        else if (!a.startsWith("--")) out.dirs.push(resolve(a));
    }
    if (out.scan && out.dirs.length === 0 && !out.all) out.dirs.push(resolve(out.root));
    return out;
}

// A real CSV reader. Import-Csv / `-split ','` both pad a short row to the
// header width, which hides the exact defect this exists for (a field pasted
// twice or dropped). This honours quotes and newlines inside a quoted field,
// takes LF and CRLF alike, and remembers the physical line of each record.
function parseCsv(text) {
    const records = [];
    let fields = [];
    let sb = "";
    let inQuotes = false;
    let line = 1;
    let recordLine = 1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (inQuotes) {
            if (c === '"') {
                if (text[i + 1] === '"') {
                    sb += '"';
                    i++;
                } else {
                    inQuotes = false;
                }
            } else {
                if (c === "\n") line++;
                sb += c;
            }
            continue;
        }
        if (c === '"') {
            inQuotes = true;
            continue;
        }
        if (c === ",") {
            fields.push(sb);
            sb = "";
            continue;
        }
        if (c === "\r") continue;
        if (c === "\n") {
            fields.push(sb);
            sb = "";
            // A blank line is not a record (RFC 4180), and the canonical
            // generators emit separator lines inside generated files, so
            // counting one as a 1-column record reports phantom arity drift.
            if (fields.some((f) => f.trim() !== "")) records.push({ line: recordLine, fields });
            fields = [];
            line++;
            recordLine = line;
            continue;
        }
        sb += c;
    }
    if (sb.length > 0 || fields.length > 0) {
        fields.push(sb);
        if (fields.some((f) => f.trim() !== "")) records.push({ line: recordLine, fields });
    }
    return records;
}

function loadRegistry(root) {
    const p = join(root, ".agentq", "trackers.json");
    if (!existsSync(p)) return { path: p, registry: null };
    return { path: p, registry: JSON.parse(stripBom(readFileSync(p, "utf8"))) };
}

// A UTF-8 BOM in the first cell makes the header read as `\ufeffid`, so the
// `id` column is never found and every row looks empty. Strip it once, at the
// read, not in every consumer.
function stripBom(text) {
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

// `idPattern` may be one string or a list. A mapping with several id families (a
// `D-nnn` tracker beside an `F-nnn` one) declares them all, and an id is valid if
// it matches ANY of them. Normalised once, here, so the row check, the unused
// check and the narrative scan all read the same set.
function idPatternList(def) {
    const p = def && def.idPattern;
    if (!p) return [];
    return (Array.isArray(p) ? p : [p]).map(String).filter(Boolean);
}

function readTrackerFile(root, def) {
    const full = join(root, def.file);
    if (!existsSync(full)) {
        return {
            items: [],
            drift: [
                {
                    kind: "missing-file",
                    tracker: def.id,
                    ref: def.file,
                    detail: "declared tracker file does not exist",
                },
            ],
        };
    }
    const text = stripBom(readFileSync(full, "utf8"));
    const records = parseCsv(text);
    const drift = [];
    if (records.length === 0)
        return { items: [], drift: [{ kind: "arity", tracker: def.id, ref: def.file, detail: "empty file" }] };

    const header = records[0].fields.map((s) => s.trim());
    const col = {};
    header.forEach((name, idx) => {
        if (!(name in col)) col[name] = idx;
    });
    const width = header.length;

    const cols = def.columns || {};
    for (const f of REQUIRED) {
        const physical = cols[f];
        if (!physical || !(physical in col)) {
            drift.push({
                kind: "missing-column",
                tracker: def.id,
                ref: f,
                detail: `field '${f}' maps to column '${physical ?? "(none)"}' which is not in the header [${header.join(", ")}]`,
            });
        }
    }

    const statusMap = (def.status && def.status.map) || {};
    const idSrcs = idPatternList(def);
    const idRes = idSrcs.map((s) => new RegExp(s));
    const groupRe = def.groupPattern ? new RegExp(def.groupPattern) : null;
    const seen = new Map();
    const items = [];

    for (let r = 1; r < records.length; r++) {
        const rec = records[r];
        const f = rec.fields;
        const get = (field) => {
            const name = cols[field];
            const idx = name !== undefined ? col[name] : undefined;
            return idx !== undefined && idx < f.length ? f[idx] : "";
        };
        if (f.length !== width) {
            drift.push({
                kind: "arity",
                tracker: def.id,
                ref: `line ${rec.line}`,
                detail: `row has ${f.length} columns, expected ${width} - a field is missing, quoted or pasted twice`,
            });
        }
        const id = get("id");
        const rawStatus = get("status");
        if (!id) {
            drift.push({ kind: "duplicate-id", tracker: def.id, ref: `line ${rec.line}`, detail: "empty id" });
            continue;
        }
        if (seen.has(id))
            drift.push({
                kind: "duplicate-id",
                tracker: def.id,
                ref: id,
                detail: `first seen at line ${seen.get(id)}`,
            });
        else seen.set(id, rec.line);
        if (idRes.length && !idRes.some((re) => re.test(id)))
            drift.push({
                kind: "bad-id-shape",
                tracker: def.id,
                ref: id,
                detail: `does not match ${idSrcs.join(" | ")}`,
            });
        const group = get("group");
        if (groupRe && group && !groupRe.test(group))
            drift.push({
                kind: "bad-id-shape",
                tracker: def.id,
                ref: id,
                detail: `group '${group}' does not match ${def.groupPattern}`,
            });
        const status = statusMap[rawStatus];
        if (status === undefined)
            drift.push({
                kind: "unmapped-status",
                tracker: def.id,
                ref: id,
                detail: `status '${rawStatus}' has no mapping; map it to one of ${CANONICAL.join(", ")}`,
            });

        const item = { id, title: get("title"), status: status ?? rawStatus };
        if (group) item.group = group;
        const evidence = get("evidence");
        if (evidence) item.evidence = evidence;
        const notes = get("notes");
        if (notes) item.notes = notes;
        items.push(item);
    }

    if (def.status && def.status.map) {
        for (const [native, canonical] of Object.entries(def.status.map)) {
            if (!CANONICAL.includes(canonical))
                drift.push({
                    kind: "unmapped-status",
                    tracker: def.id,
                    ref: native,
                    detail: `maps to '${canonical}', not a canonical status`,
                });
        }
    }

    // A declared idPattern that matches no row at all is a silent lie: the
    // mapping claims a shape the file does not use, so every consumer that
    // trusts it reads the wrong ids (or none). Only meaningful when the tracker
    // has rows; an empty file is a different, already-reported problem.
    if (items.length > 0) {
        for (let i = 0; i < idRes.length; i++) {
            if (!items.some((it) => idRes[i].test(it.id)))
                drift.push({
                    kind: "id-pattern-unused",
                    tracker: def.id,
                    ref: idSrcs[i],
                    detail: `idPattern '${idSrcs[i]}' matches none of the ${items.length} id row(s) in ${def.file}`,
                });
        }
    }

    return { items, drift };
}

function narrativeDrift(root, registry, ids) {
    const drift = [];
    // Only a token shaped exactly like some tracker's id vocabulary can be a
    // dangling reference; free-form prose tokens (D1, F30, Stage-0) are not ids
    // and flagging them would drown the real finding.
    const shapes = (registry.trackers || []).flatMap((t) => idPatternList(t)).map((p) => new RegExp(p));
    if (shapes.length === 0) return drift;
    for (const rel of registry.narrative || []) {
        const full = join(root, rel);
        if (!existsSync(full)) continue;
        const text = stripBom(readFileSync(full, "utf8"));
        for (const m of text.matchAll(/\b([A-Z]{1,4}-\d{1,4})\b/g)) {
            const ref = m[1];
            if (!ids.has(ref) && shapes.some((re) => re.test(ref))) {
                drift.push({
                    kind: "dangling-narrative-ref",
                    tracker: rel,
                    ref,
                    detail: "referenced id has no row in any tracker",
                });
            }
        }
    }
    return drift;
}

function gitInfo(root) {
    try {
        const head = readFileSync(join(root, ".git", "HEAD"), "utf8").trim();
        if (head.startsWith("ref: ")) {
            const branch = head.slice(5).trim();
            const refPath = join(root, ".git", ...branch.split("/"));
            const sha = existsSync(refPath) ? readFileSync(refPath, "utf8").trim() : "";
            return { branch, head: sha.slice(0, 12) };
        }
        return { branch: "(detached)", head: head.slice(0, 12) };
    } catch {
        return null;
    }
}

// Exported so track.mjs can reuse the EXACT drift computation (not a fork of it)
// to tell whether a repo's definition agrees with the index it wrote.
export function scanRepo(root) {
    const { registry } = loadRegistry(root);
    const repo = registry?.repo || basename(root);
    if (!registry) return null;
    const allIds = new Set();
    const trackers = [];
    const drift = [];
    for (const def of registry.trackers) {
        const { items, drift: d } = readTrackerFile(root, def);
        items.forEach((it) => allIds.add(it.id));
        drift.push(...d);
        const countsByStatus = {};
        for (const it of items) countsByStatus[it.status] = (countsByStatus[it.status] || 0) + 1;
        trackers.push({ id: def.id, file: def.file, countsByStatus, items });
    }
    drift.push(...narrativeDrift(root, registry, allIds));
    // rootIssue is written here too, so every indexed entry carries the same
    // health evidence a `track status` reads (always null here: a repo without a
    // mapping never reaches this function).
    return { repo, root, git: gitInfo(root), rootIssue: rootIssueFor(root), trackers, drift };
}

// The CLI entrypoint, callable from a test or from another tool. It RETURNS the
// exit code instead of calling process.exit, so importing this module (track.mjs
// reuses scanRepo for `track drift`) never terminates the importing process.
export function main(argv) {
    const args = parseArgs(argv);

    if (!args.scan) {
        const entry = scanRepo(args.root);
        if (!entry) {
            console.error(`no .agentq/trackers.json under ${args.root}`);
            return 2;
        }
        if (args.json) {
            console.log(JSON.stringify(entry, null, 2));
        } else {
            const total = entry.trackers.reduce((n, t) => n + t.items.length, 0);
            const byStatus = {};
            for (const t of entry.trackers)
                for (const [s, n] of Object.entries(t.countsByStatus)) byStatus[s] = (byStatus[s] || 0) + n;
            console.log(
                `${entry.repo}: ${total} item(s) in ${entry.trackers.length} tracker(s) - ${Object.entries(byStatus)
                    .map(([s, n]) => `${s} ${n}`)
                    .join(", ")}`,
            );
            for (const d of entry.drift) console.log(`drift: [${d.kind}] ${d.tracker} ${d.ref} - ${d.detail}`);
        }
        return Math.min(entry.drift.length, 255);
    }

    // --scan: find repos and write one merged index.
    let dirs = args.dirs;
    if (args.all) {
        const gh = join(homedir(), "gh");
        const base = existsSync(gh) ? gh : homedir();
        dirs = readdirSync(base)
            .map((n) => join(base, n))
            .filter((p) => {
                try {
                    return statSync(p).isDirectory();
                } catch {
                    return false;
                }
            });
    }
    const repos = [];
    let findings = 0;
    for (const d of dirs) {
        const entry = scanRepo(d);
        if (entry) {
            repos.push(entry);
            findings += entry.drift.length;
            continue;
        }
        // A root with no mapping is not silently dropped: record WHY, so a
        // consumer sees an explained card ("the mapping is on origin/main only")
        // instead of no card at all. Only a directory that is actually a git
        // repository is recorded - a scratch folder is not a repo - so this
        // cannot turn ~/gh's working directories into phantom entries.
        const issue = rootIssueFor(d);
        if (issue && existsSync(join(d, ".git")))
            repos.push({ repo: basename(d), root: d, git: gitInfo(d), rootIssue: issue, trackers: [], drift: [] });
    }
    const index = { version: 1, generatedAt: new Date().toISOString(), repos };
    const stateDir = process.env.AGENTQ_HOME || join(homedir(), ".codai", "coord");
    const outPath = join(stateDir, "trackers", "index.json");
    try {
        // First scan on a machine has no index directory yet; the tool owns it.
        mkdirSync(dirname(outPath), { recursive: true });
        writeFileSync(outPath, JSON.stringify(index, null, 2));
    } catch (e) {
        console.error(`could not write ${outPath}: ${e.message}`);
    }
    if (args.json) {
        console.log(JSON.stringify(index, null, 2));
    } else {
        console.log(`scanned ${repos.length} repo(s) -> ${outPath}`);
        for (const r of repos) {
            const total = r.trackers.reduce((n, t) => n + t.items.length, 0);
            const issue = r.rootIssue ? `  [${r.rootIssue}]` : "";
            console.log(`  ${r.repo}: ${total} item(s), ${r.drift.length} drift finding(s)${issue}`);
        }
        console.log(findings === 0 ? "tracker-lint: clean" : `tracker-lint: ${findings} finding(s)`);
    }
    return Math.min(findings, 255);
}

if (import.meta.filename && process.argv[1] && resolve(process.argv[1]) === resolve(import.meta.filename)) {
    process.exit(main(process.argv.slice(2)));
}
