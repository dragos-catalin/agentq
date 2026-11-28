// Ratchet for OQ-004's SECOND red: the probe-bucket share (startProbeBucketsPct) and the lost live
// chats (slotsLostLiveChat) that agentq-slo.mjs prints in the SAME verdict block as its first red.
//
// Why this file exists: the second red was written into the OQ-004 row as prose - "named here, not
// investigated" - and a red that lives only in prose is a red nothing enforces. The first red was
// fixed in the emitter (agentq-slo.mjs now excludes a break the owner is provably gone for), but the
// goal itself - >= 95 % of 5-minute buckets under 500 ms, and 0 live chats lost - was never met, and
// there was nothing that would notice if the row quietly stopped quoting the numbers. This freezes the
// measured state and fails the moment the row reports anything worse than it.
//
// Offline and deterministic: it reads exactly two committed files - the frozen baseline and
// docs/TRACKER.csv. It never runs agentq, never reads the journal, never touches the network.
//
// Reporting mirrors ps/tests/test-flakes.mjs (`ok(name, fn)` -> "PASS <name>", closing
// "ALL PASS <suite> (n)"). One addition: a failing check is recorded and the run continues, so a
// report names EVERY window that moved rather than only the first, and the raw FAIL lines are the
// whole story.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");

// Parameterisable ONLY so a mutation test can run against a TEMP COPY and leave the committed files
// byte-identical (sha256-checked). Nothing in the product ever sets these.
const baselinePath = process.env.AGENTQ_SLO_BASELINE
    ? path.resolve(process.env.AGENTQ_SLO_BASELINE)
    : path.join(here, "slo-second-red-baseline.json");
const csvPath = process.env.AGENTQ_TRACKER_CSV
    ? path.resolve(process.env.AGENTQ_TRACKER_CSV)
    : path.join(repoRoot, "docs", "TRACKER.csv");

let checks = 0;
const failures = [];
const ok = (name, fn) => {
    checks++;
    try {
        fn();
        console.log(`PASS ${name}`);
    } catch (e) {
        failures.push(`${name}: ${e.message}`);
        console.log(`FAIL ${name}: ${e.message}`);
    }
};

// RFC4180: quoted fields, doubled quotes inside them, LF or CRLF, a leading BOM.
function parseCsv(text) {
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
    const rows = [];
    let field = "";
    let row = [];
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (quoted) {
            if (c === '"') {
                if (text[i + 1] === '"') {
                    field += '"';
                    i++;
                } else {
                    quoted = false;
                }
            } else {
                field += c;
            }
        } else if (c === '"') {
            quoted = true;
        } else if (c === ",") {
            row.push(field);
            field = "";
        } else if (c === "\n") {
            row.push(field);
            rows.push(row);
            row = [];
            field = "";
        } else if (c !== "\r") {
            field += c;
        }
    }
    if (field !== "" || row.length) {
        row.push(field);
        rows.push(row);
    }
    return rows;
}

// The notes column is quoted but carries UNESCAPED inner quotes (the tracker writes
// `appends " - N not counted (...)"`), so a strict parse splits it into more fields than the header
// has. Join the tail back: the comma the split consumed is re-inserted, and every number these
// checks need sits in the head of the column, so nothing is lost. `NOTES_COL` is the 1-based index of
// `notes` in `id,stage,title,status,acceptance,notes`.
const NOTES_COL = 5;
const notesOf = (row) => row.slice(NOTES_COL).join(",");

// The canonical, labelled shape the row must keep stating. Deliberately anchored on the row's own
// phrases (not on "any number"): these are the numbers a reader and this ratchet both rely on, and a
// re-wording that drops them is exactly the silent-forgetting this suite exists to catch.
const PCT_RE = /1-day startProbeBucketsPct\s+([0-9]+(?:\.[0-9]+)?)[\s\S]*?7-day\s+([0-9]+(?:\.[0-9]+)?)[\s\S]*?14-day\s+([0-9]+(?:\.[0-9]+)?)/;
const LOST_RE = /slotsLostLiveChat\s+([0-9]+)\s*\(1-day\)\s*\/\s*([0-9]+)\s*\(7-day\)\s*\/\s*([0-9]+)\s*\(14-day\)/;

let baseline;
try {
    baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
} catch (e) {
    console.log(`FAIL baseline: cannot read/parse ${baselinePath}: ${e.message}`);
    process.exit(1);
}
let csvText;
try {
    csvText = fs.readFileSync(csvPath, "utf8");
} catch (e) {
    console.log(`FAIL csv: cannot read ${csvPath}: ${e.message}`);
    process.exit(1);
}

const windows = Array.isArray(baseline.windows) ? baseline.windows : [];
const targetPct = baseline.targets ? baseline.targets.startProbeBucketsPct : undefined;
const targetLost = baseline.targets ? baseline.targets.slotsLostLiveChat : undefined;

const rows = parseCsv(csvText);
const oq004 = rows.filter((r) => r[0] === "OQ-004");
const row = oq004.length === 1 ? oq004[0] : undefined;
const rowText = row ? notesOf(row) : "";

const pctMatch = rowText.match(PCT_RE);
const lostMatch = rowText.match(LOST_RE);
const current = { startProbeBucketsPct: {}, slotsLostLiveChat: {} };
windows.forEach((w, i) => {
    if (pctMatch) current.startProbeBucketsPct[w] = Number(pctMatch[i + 1]);
    if (lostMatch) current.slotsLostLiveChat[w] = Number(lostMatch[i + 1]);
});

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? String(v) : "?");
const gap = (v) => (typeof v === "number" && Number.isFinite(v) ? String(Math.round(v * 100) / 100) : "?");

// Always printed, green or red, so the report is actionable without opening the CSV.
console.log(`OQ-004 second red - distance to target (${csvPath})`);
for (const w of windows) {
    const p = current.startProbeBucketsPct[w];
    const l = current.slotsLostLiveChat[w];
    console.log(
        `  ${w.padEnd(6)}startProbeBucketsPct ${num(p).padEnd(7)}(target >= ${num(targetPct)}, gap ${gap(p - targetPct)})` +
            `   slotsLostLiveChat ${num(l).padEnd(5)}(target = ${num(targetLost)}, gap ${gap(l - targetLost)})`
    );
}
console.log(
    `  frozen floor (${baseline.frozen}): startProbeBucketsPct ${windows.map((w) => num(baseline.startProbeBucketsPct?.[w])).join(" / ")},` +
        ` slotsLostLiveChat ${windows.map((w) => num(baseline.slotsLostLiveChat?.[w])).join(" / ")}`
);

ok("baseline: pins the three windows for both metrics and their two targets", () => {
    assert.deepEqual(
        windows,
        ["24h", "168h", "336h"],
        `the baseline must pin 24h/168h/336h, got ${JSON.stringify(windows)} - fix ${baselinePath}`
    );
    for (const w of windows) {
        assert.equal(
            typeof baseline.startProbeBucketsPct?.[w],
            "number",
            `baseline.startProbeBucketsPct.${w} is not a number - fix ${baselinePath}`
        );
        assert.equal(
            typeof baseline.slotsLostLiveChat?.[w],
            "number",
            `baseline.slotsLostLiveChat.${w} is not a number - fix ${baselinePath}`
        );
    }
    assert.equal(targetPct, 95, `baseline target for startProbeBucketsPct must be 95 - fix ${baselinePath}`);
    assert.equal(targetLost, 0, `baseline target for slotsLostLiveChat must be 0 - fix ${baselinePath}`);
});

ok("csv: exactly one OQ-004 row", () => {
    assert.ok(rows.length > 10, `docs/TRACKER.csv at ${csvPath} parsed to only ${rows.length} rows - wrong file?`);
    assert.equal(
        oq004.length,
        1,
        `${csvPath} must carry exactly one OQ-004 row, found ${oq004.length} - without it the second red is unguarded`
    );
});

ok("csv: the OQ-004 row still states all three startProbeBucketsPct values", () => {
    assert.ok(row, `no OQ-004 row in ${csvPath}`);
    assert.ok(
        pctMatch,
        `the OQ-004 row no longer states its three window percentages in the form ` +
            `"1-day startProbeBucketsPct <v> ... 7-day <v> ... 14-day <v>" - the second red cannot be ` +
            `checked. Re-add them to the row, or update the pattern in ps/tests/slo-second-red.test.mjs (${csvPath})`
    );
});

ok("csv: the OQ-004 row still states all three slotsLostLiveChat values", () => {
    assert.ok(row, `no OQ-004 row in ${csvPath}`);
    assert.ok(
        lostMatch,
        `the OQ-004 row no longer states its three lost-chat counts in the form ` +
            `"slotsLostLiveChat <v> (1-day) / <v> (7-day) / <v> (14-day)" - the second red cannot be ` +
            `checked. Re-add them to the row, or update the pattern in ps/tests/slo-second-red.test.mjs (${csvPath})`
    );
});

for (const w of windows) {
    const base = baseline.startProbeBucketsPct?.[w];
    ok(`ratchet: ${w} startProbeBucketsPct is not below the frozen baseline`, () => {
        const now = current.startProbeBucketsPct[w];
        assert.ok(
            typeof now === "number",
            `the OQ-004 row no longer states ${w} startProbeBucketsPct, so it cannot be checked (${csvPath})`
        );
        assert.ok(
            now >= base,
            `ratchet: ${w} startProbeBucketsPct is ${now}, BELOW the frozen baseline ${base} - the probe-bucket ` +
                `share regressed (OQ-004, ${csvPath}). Fix the cause, or re-freeze ${baselinePath} deliberately if ` +
                `the drop is understood`
        );
    });
}

for (const w of windows) {
    const base = baseline.slotsLostLiveChat?.[w];
    ok(`ratchet: ${w} slotsLostLiveChat is not above the frozen baseline`, () => {
        const now = current.slotsLostLiveChat[w];
        assert.ok(
            typeof now === "number",
            `the OQ-004 row no longer states ${w} slotsLostLiveChat, so it cannot be checked (${csvPath})`
        );
        assert.ok(
            now <= base,
            `ratchet: ${w} slotsLostLiveChat is ${now}, ABOVE the frozen baseline ${base} - chats are being lost ` +
                `more often than when the red was frozen (OQ-004, ${csvPath}). Fix the cause, or re-freeze ` +
                `${baselinePath} deliberately if the rise is understood`
        );
    });
}

// Advisory only - an improvement is never a failure. It only means the frozen floor is looser than
// reality and should be tightened on the next deliberate re-freeze.
const beatingPct = windows.filter(
    (w) => typeof current.startProbeBucketsPct[w] === "number" && current.startProbeBucketsPct[w] > baseline.startProbeBucketsPct?.[w]
);
const beatingLost = windows.filter(
    (w) => typeof current.slotsLostLiveChat[w] === "number" && current.slotsLostLiveChat[w] < baseline.slotsLostLiveChat?.[w]
);
if (beatingPct.length || beatingLost.length) {
    console.log(
        `note: the row beats the frozen floor (startProbeBucketsPct ${beatingPct.join(", ") || "none"};` +
            ` slotsLostLiveChat ${beatingLost.join(", ") || "none"}) - safe to tighten ${baselinePath} on the next re-freeze`
    );
}

if (failures.length) {
    console.log(`\nFAIL slo-second-red (${checks - failures.length}/${checks} checks passed)`);
    process.exit(1);
}
console.log(`\nALL PASS slo-second-red (${checks})`);
