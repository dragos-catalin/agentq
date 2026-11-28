import { defineConfig } from "vitest/config";

export default defineConfig({
    // `tools/*.test.mjs` are node:test files (run with `node --test tools/...`); a
    // `tools/**` glob here would pull them in and vitest would fail each with "No
    // test suite found". tracker-lint's suite is written to run under BOTH
    // runners, so it is listed by name.
    test: { include: ["test/**/*.test.ts", "tools/tracker-lint.test.mjs"], testTimeout: 30_000 },
});
