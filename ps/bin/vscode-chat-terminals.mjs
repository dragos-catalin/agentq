// Prints the shell PIDs VS Code has associated with a chat session (run_in_terminal), one per
// line as "<pid> fg|bg", read from every workspace's state.vscdb key `chat.terminalSessions`.
//
// Why (2026-10-18): reap-terminals killed 507 terminals in a day; 82 of them were terminals VS
// Code still tracked for an agent's chat. Killing one makes VS Code post "terminal exited" into
// that chat, which interrupts the agent mid-turn - the "agents freeze, I have to stop them and
// say continue" symptom. Those terminals are VS Code's to dispose (it does, when the command or
// the chat ends), so the reaper must know which they are.
//
// Each database is copied first: the live file is held open by VS Code. Exit 0 always; a
// workspace whose database cannot be read is skipped (fewer protected PIDs is the caller's
// cue to be conservative, see reap-terminals.ps1 -NoAssocMeansStop).
import { readdirSync, existsSync, copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

process.removeAllListeners('warning');
const { DatabaseSync } = await import('node:sqlite');
const root = process.argv[2] ?? join(process.env.APPDATA ?? '', 'Code - Insiders', 'User', 'workspaceStorage');
const tmp = mkdtempSync(join(tmpdir(), 'vct-'));
let read = 0;
try {
  for (const ws of existsSync(root) ? readdirSync(root) : []) {
    const db = join(root, ws, 'state.vscdb');
    if (!existsSync(db)) continue;
    const copy = join(tmp, `${ws}.vscdb`);
    try {
      copyFileSync(db, copy);
      const d = new DatabaseSync(copy, { readOnly: true });
      const row = d.prepare("SELECT value FROM ItemTable WHERE key = 'chat.terminalSessions'").get();
      d.close();
      read++;
      if (!row) continue;
      for (const [pid, a] of Object.entries(JSON.parse(String(row.value)))) {
        if (/^\d+$/.test(pid)) console.log(`${pid} ${a && a.isBackground ? 'bg' : 'fg'}`);
      }
    } catch { /* locked, not sqlite, or bad JSON: skip this workspace */ }
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
console.log(`#read ${read}`);
