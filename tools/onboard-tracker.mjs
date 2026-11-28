#!/usr/bin/env node
// onboard-tracker - turn "this repo has tracker CSVs" into one committed mapping.
//
// Why it exists: bringing a repo into the unified tracker index means
// hand-writing <repo>/.agentq/trackers.json - the file, the column map, the id
// shape and the status vocabulary - and that was done by hand four times in one
// session. This tool reads the repo's own CSVs, infers that mapping, and proves
// it by running the REAL linter (tools/tracker-lint.mjs) as a child process.
//
// It is a dry run by default: it prints the mapping it WOULD write and the lint
// result, and touches nothing anywhere. `--write` writes it to
// <root>/.agentq/trackers.json. It refuses to clobber an existing mapping unless
// --force, so a re-run never silently discards a hand-tuned file.
//
// The inference is deliberately conservative and never invents a fact:
//   * a column is mapped only when its HEADER names it (id/key/code/task,
//     title/item/name, status/state, ...); the ONE value-driven guess is the id
//     column, and only when no header names it;
//   * a status is mapped only when normalising it (case, surrounding spaces, and
//     space/underscore vs hyphen) lands it EXACTLY on a canonical status. Every
//     other raw token is printed as a warning and left OUT of the map, because
//     inventing a synonym is inventing a fact;
//   * idPattern (and groupPattern) are emitted only when every observed value
//     shares one shape; otherwise the distinct shapes are printed and the
//     pattern is omitted rather than guessed.
//
// Usage:
//   node onboard-tracker.mjs --root <repo> [--id <slug>] [--file <rel csv>]
//        [--narrative <rel md>]... [--write] [--force] [--json]
//
// Exit code: 0 when the mapping was inferred and the lint is clean; the lint's
// finding count when it is not (capped 255); 2 when it could not proceed (no
// candidate, an ambiguous candidate set without --file, a --file that is not a
// readable CSV under the root, or an existing mapping without --force).
//
// Zero dependencies, Node ESM, LF, and BOM-tolerant on every read (the CSV and
// any JSON), because a UTF-8 BOM makes the first header cell read as `\ufeffid`
// and silently hides the id column.

import {
    readFileSync,
    writeFileSync,
    existsSync,
    readdirSync,
    lstatSync,
    mkdirSync,
    mkdtempSync,
    copyFileSync,
    rmSync,
} from "node:fs";
import { join, dirname, resolve, basename, relative, sep } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LINTER = join(HERE, "tracker-lint.mjs");

// The one vocabulary, identical to spec/tracker.schema.json $defs.status.
const CANONICAL = ["todo", "in-progress", "blocked", "review", "done", "dropped", "deferred"];

// Directories that are never a tracker source. Node's own walk cannot read
// .gitignore, and codai alone has thousands of files under .copilot-tmp, so the
// scratch and build roots are named here and merged with whatever the repo's
// .ignore/.gitignore add (see ignoreDirs).
const NOISE = new Set([
    ".git",
    "node_modules",
    "target",
    "dist",
    "build",
    ".next",
    ".turbo",
    ".copilot-tmp",
    ".venv",
    "venv",
    "__pycache__",
    "coverage",
    ".cache",
    "out",
]);

// ---- small shared helpers ---------------------------------------------------

function stripBom(text) {
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function readText(file) {
    return stripBom(readFileSync(file, "utf8"));
}

// A repo path is written with forward slashes in the mapping (the examples do),
// whatever separator the platform's fs module uses.
function toPosix(p) {
    return p.split(sep).join("/");
}

function escapeRegex(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function slugify(s) {
    return String(s)
        .replace(/\.csv$/i, "")
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
}

// A real CSV reader, copied in spirit from tracker-lint.mjs so the two agree on
// what a row is: quotes and newlines inside a quoted field are honoured, and LF
// and CRLF are alike. A blank line is not a record.
function parseCsv(text) {
    const records = [];
    let fields = [];
    let sb = "";
    let inQuotes = false;
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
            if (fields.some((f) => f.trim() !== "")) records.push(fields);
            fields = [];
            continue;
        }
        sb += c;
    }
    if (sb.length > 0 || fields.length > 0) {
        fields.push(sb);
        if (fields.some((f) => f.trim() !== "")) records.push(fields);
    }
    return records;
}

// ---- discovery --------------------------------------------------------------

// Directory names to skip: the fixed set, plus the last path segment of each
// line of .ignore/.gitignore that names a directory (no wildcard). git ignores
// are layout, not search, but for a discovery walk they play the same role.
function ignoreDirs(root) {
    const dirs = new Set(NOISE);
    for (const name of [".ignore", ".gitignore"]) {
        const file = join(root, name);
        if (!existsSync(file)) continue;
        for (let line of readText(file).split(/\r?\n/)) {
            line = line.trim();
            if (!line || line.startsWith("#") || line.startsWith("!")) continue;
            const seg = line.replace(/^\//, "").replace(/\/+$/, "").split("/").filter(Boolean).pop();
            if (seg && !seg.includes("*") && !seg.includes("?")) dirs.add(seg);
        }
    }
    return dirs;
}

// Every *.csv under <root>, as forward-slash paths relative to it, skipping the
// noise directories and never following a symlink (a junction back to an
// ancestor would otherwise loop forever).
function discoverCsv(root) {
    const skip = ignoreDirs(root);
    const out = [];
    const walk = (dir) => {
        let entries;
        try {
            entries = readdirSync(dir, { withFileTypes: true });
        } catch {
            return;
        }
        for (const e of entries) {
            const full = join(dir, e.name);
            if (e.isSymbolicLink()) continue;
            if (e.isDirectory()) {
                if (skip.has(e.name)) continue;
                // A directory named in NOISE is skipped wherever it sits; hidden
                // directories other than the two we read are skipped too.
                if (e.name.startsWith(".") && e.name !== ".agentq") continue;
                walk(full);
            } else if (e.isFile() && e.name.toLowerCase().endsWith(".csv")) {
                out.push(toPosix(relative(root, full)));
            }
        }
    };
    walk(root);
    return out.sort();
}

function headerOf(text) {
    const records = parseCsv(text);
    return records.length ? records[0].map((s) => s.trim()) : [];
}

function normHeader(s) {
    return String(s).trim().toLowerCase();
}

function hasIdLikeHeader(header) {
    return header.some((h) => /\b(id|key|code|task)\b/.test(normHeader(h)));
}

// A candidate is a CSV whose header names an id-like column and that has at
// least one data row. This is the rule the brief fixes; value-only id columns
// are not candidates (the id would then be inferred from an unnamed column,
// which is exactly the guess we refuse).
function isCandidate(root, rel) {
    try {
        const text = readText(join(root, rel));
        const records = parseCsv(text);
        if (records.length < 2) return false;
        return hasIdLikeHeader(records[0].map((s) => s.trim()));
    } catch {
        return false;
    }
}

// ---- column inference -------------------------------------------------------

function pickColumn(header, names, used) {
    for (const want of names) {
        for (let i = 0; i < header.length; i++) {
            if (used.has(i)) continue;
            if (normHeader(header[i]) === want) return i;
        }
    }
    for (const want of names) {
        const re = new RegExp(`\\b${escapeRegex(want)}\\b`);
        for (let i = 0; i < header.length; i++) {
            if (used.has(i)) continue;
            if (re.test(normHeader(header[i]))) return i;
        }
    }
    return -1;
}

// A value that reads as an identifier rather than prose or a number: short,
// no spaces, and carrying a digit (the shape every id vocabulary in the fleet
// uses - M1, W0-01, AL-001, VQ-001).
function looksLikeId(v) {
    const t = String(v).trim();
    if (!t || t.length > 24) return false;
    if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(t)) return false;
    if (!/[0-9]/.test(t)) return false;
    return true;
}

// The id column: the one its header names, else the one whose values look most
// like identifiers. Never the first column on faith alone.
function inferIdColumn(header, rows, used) {
    const byName = pickColumn(header, ["id", "key", "code", "task"], used);
    if (byName >= 0) return { idx: byName, how: `header '${header[byName]}'` };
    let best = -1;
    let bestFrac = 0;
    for (let i = 0; i < header.length; i++) {
        if (used.has(i)) continue;
        const vals = rows.map((r) => (i < r.length ? r[i] : "")).filter((v) => v.trim() !== "");
        if (vals.length === 0) continue;
        const frac = vals.filter(looksLikeId).length / vals.length;
        if (frac > bestFrac + 1e-9 || (Math.abs(frac - bestFrac) < 1e-9 && best >= 0 && i < best)) {
            best = i;
            bestFrac = frac;
        }
    }
    if (best >= 0 && bestFrac >= 0.8)
        return { idx: best, how: `values of '${header[best]}' look like ids (${Math.round(bestFrac * 100)}%)` };
    return { idx: -1, how: "no id-like header and no column whose values look like ids" };
}

// ---- shape inference (idPattern / groupPattern) -----------------------------

function shapeOf(v) {
    return String(v)
        .replace(/[A-Za-z]+/g, "L")
        .replace(/[0-9]+/g, "D");
}

// The regex a shape describes: L -> a letter run, D -> a digit run, everything
// else kept literally. Derived from the OBSERVED runs, so it always matches every
// value it was built from - it is a shape, not a guess at the intended one.
function regexFromShape(shape) {
    let out = "^";
    for (const ch of shape) {
        if (ch === "L") out += "[A-Za-z]+";
        else if (ch === "D") out += "\\d+";
        else out += escapeRegex(ch);
    }
    return out + "$";
}

// Returns { pattern } when every non-empty value shares one shape, else
// { shapes } so the caller can print them and omit the pattern.
function inferPattern(values) {
    const nonEmpty = values.map((v) => String(v).trim()).filter((v) => v !== "");
    if (nonEmpty.length === 0) return { shapes: [] };
    const shapes = [...new Set(nonEmpty.map(shapeOf))];
    if (shapes.length === 1) return { pattern: regexFromShape(shapes[0]), shape: shapes[0], count: nonEmpty.length };
    return { shapes };
}

// ---- status vocabulary ------------------------------------------------------

// The ONLY normalisation allowed: trim, lower-case, collapse internal whitespace
// and unify space/underscore/hyphen. A token that lands exactly on a canonical
// value is mapped; everything else is a warning, never a synonym.
function normaliseStatus(raw) {
    return String(raw)
        .trim()
        .toLowerCase()
        .replace(/[\s_]+/g, "-")
        .replace(/-+/g, "-");
}

function inferStatusMap(rawValues) {
    const map = {};
    const warnings = [];
    const distinct = [...new Set(rawValues)];
    for (const raw of distinct) {
        if (raw.trim() === "") {
            warnings.push(`a row has an empty status cell - the linter will flag it; fill it in or map it`);
            continue;
        }
        const n = normaliseStatus(raw);
        if (CANONICAL.includes(n)) map[raw] = n;
        else warnings.push(`status '${raw}' (normalised '${n}') has no canonical mapping - map it by hand`);
    }
    return { map, warnings };
}

// ---- narrative --------------------------------------------------------------

// docs/TRACKER.md, docs/*MASTER*.md, docs/ROADMAP*.md, when they exist.
function inferNarrative(root) {
    const out = [];
    const trackerMd = "docs/TRACKER.md";
    if (existsSync(join(root, trackerMd))) out.push(trackerMd);
    let entries = [];
    try {
        entries = readdirSync(join(root, "docs"), { withFileTypes: true });
    } catch {
        return out;
    }
    for (const e of entries) {
        if (!e.isFile() || !e.name.toLowerCase().endsWith(".md")) continue;
        if (/MASTER/i.test(e.name) || /^ROADMAP/i.test(e.name)) out.push(`docs/${e.name}`);
    }
    return [...new Set(out)].sort();
}

// ---- build the mapping ------------------------------------------------------

function buildMapping(root, relFile, trackerId) {
    const text = readText(join(root, relFile));
    const records = parseCsv(text);
    const header = records[0].map((s) => s.trim());
    const rows = records.slice(1);

    const used = new Set();
    const evidence = [];

    const idPick = inferIdColumn(header, rows, used);
    const idIdx = idPick.idx;
    if (idIdx >= 0) used.add(idIdx);
    evidence.push({ field: "id", column: idIdx >= 0 ? header[idIdx] : null, how: idPick.how });

    const specs = [
        {
            field: "group",
            names: [
                "group",
                "workstream",
                "wave",
                "phase",
                "stage",
                "slice",
                "area",
                "epic",
                "stream",
                "category",
                "module",
            ],
        },
        { field: "title", names: ["title", "item", "name", "summary", "subject", "task", "description", "desc"] },
        { field: "status", names: ["status", "state"] },
        {
            field: "evidence",
            names: [
                "evidence",
                "verification",
                "acceptance",
                "verify",
                "verified_how",
                "verification_how",
                "verified",
                "proof",
                "gate",
            ],
        },
        { field: "notes", names: ["notes", "note", "detail", "details", "comment", "comments", "remark", "remarks"] },
    ];
    const picked = { id: idIdx };
    for (const spec of specs) {
        const idx = pickColumn(header, spec.names, used);
        if (idx >= 0) used.add(idx);
        picked[spec.field] = idx;
        evidence.push({
            field: spec.field,
            column: idx >= 0 ? header[idx] : null,
            how: idx >= 0 ? `header '${header[idx]}'` : "no matching header",
        });
    }

    const columns = {};
    for (const field of ["id", "group", "title", "status", "evidence", "notes"]) {
        if (picked[field] >= 0) columns[field] = header[picked[field]];
    }

    const cell = (row, field) => {
        const idx = picked[field];
        return idx >= 0 && idx < row.length ? row[idx] : "";
    };

    const warnings = [];
    const idShapes = idIdx >= 0 ? inferPattern(rows.map((r) => cell(r, "id"))) : { shapes: [] };
    if (idIdx >= 0 && idShapes.shapes && idShapes.shapes.length) {
        warnings.push(`ids do not share one shape - omitting idPattern. shapes: ${idShapes.shapes.join(", ")}`);
    }
    const groupShapes = picked.group >= 0 ? inferPattern(rows.map((r) => cell(r, "group"))) : null;

    const status = inferStatusMap(rows.map((r) => cell(r, "status")));
    warnings.push(...status.warnings);

    for (const field of ["id", "title", "status"]) {
        if (picked[field] < 0)
            warnings.push(
                `required column '${field}' could not be inferred - the mapping will not lint until it is added`,
            );
    }

    const tracker = { id: trackerId, file: relFile, format: "csv", columns };
    if (idShapes.pattern) tracker.idPattern = idShapes.pattern;
    if (groupShapes && groupShapes.pattern) tracker.groupPattern = groupShapes.pattern;
    tracker.status = { map: status.map };
    tracker.index = { kind: "plan", order: 0 };

    const mapping = {
        $schema: "https://codwen.com/schemas/tracker.schema.json#/$defs/trackerRegistry",
        version: 1,
        repo: basename(root),
        trackers: [tracker],
    };
    const narrative = inferNarrative(root);
    if (narrative.length) mapping.narrative = narrative;

    return { mapping, evidence, warnings, idShapes, groupShapes, header, rowCount: rows.length };
}

// ---- lint (the real linter, as a child process) -----------------------------

function runLint(lintRoot) {
    const r = spawnSync(process.execPath, [LINTER, "--root", lintRoot, "--json"], { encoding: "utf8" });
    let findings = null;
    try {
        findings = JSON.parse(r.stdout).drift || [];
    } catch {
        findings = null;
    }
    return {
        code: typeof r.status === "number" ? r.status : 1,
        stdout: r.stdout || "",
        stderr: r.stderr || "",
        findings,
    };
}

// A dry run must write nothing anywhere, so the mapping is linted against a
// throwaway mirror of the repo (the mapping plus the CSV and narrative files at
// their same relative paths), never against the real tree.
function lintMirror(root, mapping) {
    const tmp = mkdtempSync(join(tmpdir(), "onboard-tracker-"));
    try {
        mkdirSync(join(tmp, ".agentq"), { recursive: true });
        writeFileSync(join(tmp, ".agentq", "trackers.json"), JSON.stringify(mapping, null, 2) + "\n", "utf8");
        const files = mapping.trackers.map((t) => t.file).concat(mapping.narrative || []);
        for (const rel of files) {
            const src = join(root, rel);
            if (!existsSync(src)) continue;
            const dst = join(tmp, rel);
            mkdirSync(dirname(dst), { recursive: true });
            copyFileSync(src, dst);
        }
        return { ...runLint(tmp), lintRoot: tmp };
    } finally {
        rmSync(tmp, { recursive: true, force: true });
    }
}

// ---- CLI --------------------------------------------------------------------

function parseArgs(argv) {
    const flags = { narrative: [] };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (!a.startsWith("--")) continue;
        const eq = a.indexOf("=");
        let key;
        let val;
        if (eq >= 0) {
            key = a.slice(2, eq);
            val = a.slice(eq + 1);
        } else {
            key = a.slice(2);
            const next = argv[i + 1];
            if (next === undefined || next.startsWith("--")) val = true;
            else {
                val = next;
                i++;
            }
        }
        if (key === "narrative" && typeof val === "string") {
            flags.narrative.push(
                ...val
                    .split(",")
                    .map((s) => s.trim())
                    .filter(Boolean),
            );
        } else {
            flags[key] = val;
        }
    }
    return flags;
}

export function main(argv) {
    const flags = parseArgs(argv);
    const root = resolve(flags.root && flags.root !== true ? flags.root : process.cwd());
    if (!existsSync(root)) {
        console.error(`onboard-tracker: --root '${root}' does not exist`);
        return 2;
    }
    const jsonOut = flags.json === true;
    const write = flags.write === true;
    const force = flags.force === true;
    const mappingPath = join(root, ".agentq", "trackers.json");

    // Refuse to clobber an existing mapping: a hand-tuned file is worth more than
    // a fresh inference, and --force is the one word that says "I know".
    if (existsSync(mappingPath) && !force) {
        console.error(
            `onboard-tracker: ${mappingPath} already exists - refusing to overwrite (pass --force to replace it)`,
        );
        return 2;
    }

    // Choose the tracker file.
    let relFile;
    let candidates = null;
    if (typeof flags.file === "string" && flags.file) {
        const abs = resolve(root, flags.file);
        const inside = relative(root, abs);
        if (inside.startsWith("..") || !existsSync(abs) || !abs.toLowerCase().endsWith(".csv")) {
            console.error(`onboard-tracker: --file '${flags.file}' is not a readable .csv under ${root}`);
            return 2;
        }
        relFile = toPosix(inside);
    } else {
        const all = discoverCsv(root);
        candidates = all.filter((rel) => isCandidate(root, rel));
        if (candidates.length === 0) {
            console.error(`onboard-tracker: no tracker CSV found under ${root} (scanned ${all.length} .csv file(s))`);
            console.error(`a candidate is a CSV whose header names an id-like column and that has at least one row`);
            return 2;
        }
        if (candidates.length > 1) {
            console.error(`onboard-tracker: ${candidates.length} candidate tracker CSVs - choose one with --file:`);
            for (const c of candidates) console.error(`  ${c}`);
            return 2;
        }
        relFile = candidates[0];
    }

    const trackerId = typeof flags.id === "string" && flags.id ? flags.id : slugify(relFile) || "tracker";
    const built = buildMapping(root, relFile, trackerId);
    const mapping = built.mapping;

    if (flags.narrative && flags.narrative.length) {
        mapping.narrative = [...new Set(flags.narrative.map((n) => toPosix(n)))];
    }

    const missingRequired = ["id", "title", "status"].filter((f) => !(f in mapping.trackers[0].columns));

    // Write, then lint the real artifact; or dry-run, then lint a mirror.
    let wrote = false;
    if (write) {
        if (missingRequired.length) {
            console.error(
                `onboard-tracker: refusing to write - required column(s) ${missingRequired.join(", ")} could not be inferred; add them by hand`,
            );
            return 2;
        }
        mkdirSync(dirname(mappingPath), { recursive: true });
        writeFileSync(mappingPath, JSON.stringify(mapping, null, 2) + "\n", "utf8");
        wrote = true;
    }
    const lint = write ? { ...runLint(root), lintRoot: root } : lintMirror(root, mapping);

    if (jsonOut) {
        console.log(
            JSON.stringify(
                {
                    root,
                    mappingPath,
                    file: relFile,
                    trackerId,
                    wrote,
                    dryRun: !write,
                    mapping,
                    inference: {
                        columns: built.evidence,
                        idShapes: built.idShapes,
                        groupShapes: built.groupShapes,
                        rowCount: built.rowCount,
                    },
                    warnings: built.warnings,
                    missingRequired,
                    lint: {
                        exitCode: lint.code,
                        lintRoot: lint.lintRoot,
                        findings: lint.findings,
                        raw: lint.findings === null ? lint.stdout : undefined,
                    },
                },
                null,
                2,
            ) + "\n",
        );
        return lint.code === 0 ? 0 : Math.min(lint.code, 255);
    }

    // Human output.
    console.log(`root:       ${root}`);
    console.log(`tracker:    ${trackerId}  ->  ${relFile}  (${built.rowCount} row(s))`);
    console.log(
        `columns:    ${
            Object.entries(mapping.trackers[0].columns)
                .map(([f, c]) => `${f}=${c}`)
                .join("  ") || "(none)"
        }`,
    );
    console.log(
        `idPattern:  ${mapping.trackers[0].idPattern || "(omitted)"}${built.idShapes.shape ? `  (all ${built.idShapes.count} ids share shape ${built.idShapes.shape})` : ""}`,
    );
    if (mapping.trackers[0].groupPattern) console.log(`groupPattern: ${mapping.trackers[0].groupPattern}`);
    const mapEntries = Object.entries(mapping.trackers[0].status.map);
    console.log(`status.map: ${mapEntries.length ? mapEntries.map(([k, v]) => `'${k}'->${v}`).join("  ") : "(empty)"}`);
    if (mapping.narrative) console.log(`narrative:  ${mapping.narrative.join(", ")}`);
    for (const w of built.warnings) console.log(`warning:    ${w}`);
    console.log(write ? `wrote:      ${mappingPath}` : `dry run:    would write ${mappingPath} (nothing written)`);
    console.log("mapping:");
    console.log(JSON.stringify(mapping, null, 2));
    console.log(
        `lint:       node tracker-lint.mjs --root ${lint.lintRoot === root ? root : "<mirror of " + root + ">"}  ->  exit ${lint.code}`,
    );
    if (lint.findings) {
        for (const d of lint.findings) console.log(`  drift: [${d.kind}] ${d.tracker} ${d.ref} - ${d.detail}`);
    } else if (lint.findings === null) {
        console.log(`  (linter output not JSON; raw:)`);
        for (const line of lint.stdout.trim().split(/\r?\n/)) console.log(`  ${line}`);
    }
    return lint.code === 0 ? 0 : Math.min(lint.code, 255);
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
    process.exit(main(process.argv.slice(2)));
}
