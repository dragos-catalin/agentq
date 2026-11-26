/*
  hookc4.c - resident hook client, v4 (2026-11-25, codai PoC). Supersedes hookc3.c.

  v3's deadline used overlapped I/O. That is the wrong mode here: server4.ps1 creates its pipe with
  PipeOptions::None (a blocking instance), and against a blocking server the overlapped client produced
  `reply body incomplete` on the client and `write failed: Pipe is broken.` on the server - while the
  request itself had already run in 294 ms (server.log, 2026-11-25). So v4 goes back to the plain
  synchronous handle that v2 used, and keeps the deadline with a WATCHDOG THREAD: after the budget it
  closes the handle, which aborts whatever synchronous read/write is blocked, and the main path then
  falls back. Same guarantee ("a hook never hangs"), one mechanism PC users actually document.

  Fallback on ANY failure to get a complete reply - no server, handle not openable, write/read aborted
  or short, deadline hit - because a hook that cannot reach its server must never become a skipped
  guard. The fallback is byte-for-byte what runs today:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File <guard.ps1> < <same payload>
  If the server ran the request and only the reply was lost, the guard runs a second time; it reads
  stdin and decides, so the second run is idempotent and the harness still gets the verdict.

  Usage: hookc4.exe [guard.ps1] [pipeName]      (both optional; pipe may be bare or \\.\pipe\<name>)

  The guard is OPTIONAL because the installed entry is a bare "command": "<...>\hookc.exe" (a plain
  path, no arguments), and a client that refuses to run without one would make EVERY hook invocation
  produce nothing - both guards skipped, which is the exact failure this whole design exists to
  prevent. Defaulting here also means the install does not depend on whether the harness forwards
  arguments into the command string, which is not a thing to bet the guards on.
*/
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static HANDLE          g_pipe = INVALID_HANDLE_VALUE;
static HANDLE          g_stop = NULL;
static HANDLE          g_main = NULL;
static DWORD           g_budget = 6000;
static volatile LONG   g_aborted = 0;

static int  fallback(const wchar_t* guard, const unsigned char* payload, size_t len, const char* why);
static void note_err(const char* what, DWORD err) {
    fprintf(stderr, "hookc: %s (win32 %lu) - falling back\n", what, (unsigned long)err); fflush(stderr);
}
static void note(const char* what) {
    if (what) { fprintf(stderr, "hookc: %s - falling back\n", what); fflush(stderr); }
}

static DWORD pipe_timeout_ms(void) {
    char v[32];
    DWORD n = GetEnvironmentVariableA("HOOKC_TIMEOUT_MS", v, sizeof v);
    if (n > 0 && n < sizeof v) { long t = strtol(v, NULL, 10); if (t > 0) return (DWORD)t; }
    return 6000;
}

static void full_pipe_name(const wchar_t* in, wchar_t* out, size_t cch) {
    if (_wcsnicmp(in, L"\\\\", 2) == 0) { _snwprintf(out, cch, L"%ls", in); return; }
    while (*in == L'\\' || *in == L'/') in++;
    _snwprintf(out, cch, L"\\\\.\\pipe\\%ls", in);
}

/* watchdog: after the budget, cancels the transfer the main thread is blocked in and closes the pipe.
   Closing the handle alone is NOT enough for a synchronous ReadFile/WriteFile on a pipe - the call
   stays blocked until the peer acts (measured 2026-11-25: against a server that never answered the
   client waited the PEER's 30 s, not its own 6 s budget). CancelSynchronousIo is the documented way
   to abort a blocked synchronous I/O in another thread. */
static DWORD WINAPI watchdog(LPVOID) {
    if (WaitForSingleObject(g_stop, g_budget) == WAIT_TIMEOUT) {
        InterlockedExchange(&g_aborted, 1);
        if (g_main) CancelSynchronousIo(g_main);
        HANDLE h = g_pipe;
        if (h != INVALID_HANDLE_VALUE) CloseHandle(h);   /* aborts the pending read/write */
    }
    return 0;
}

/* synchronous transfer with a retry on short reads; FALSE means "did not get the bytes" */
static BOOL read_all(HANDLE h, void* dst, DWORD total) {
    DWORD have = 0;
    while (have < total) {
        DWORD got = 0;
        if (!ReadFile(h, (char*)dst + have, total - have, &got, NULL) || got == 0) return FALSE;
        have += got;
    }
    return TRUE;
}
static BOOL write_all(HANDLE h, const void* src, DWORD total) {
    DWORD have = 0;
    while (have < total) {
        DWORD put = 0;
        if (!WriteFile(h, (const char*)src + have, total - have, &put, NULL) || put == 0) return FALSE;
        have += put;
    }
    return TRUE;
}

/* the classic path, verbatim; the buffered payload is handed over through a temp file */
static int fallback(const wchar_t* guard, const unsigned char* payload, size_t len, const char* why) {
    note(why);
    /* A missing guard must be LOUD: "no decision" and "allow" look the same to the harness, so
       failing silently here would quietly disable every guard. */
    if (GetFileAttributesW(guard) == INVALID_FILE_ATTRIBUTES) {
        fwprintf(stderr, L"hookc: guard not found: %ls\n", guard); fflush(stderr); return 3;
    }
    wchar_t tmpPath[MAX_PATH], tmpFile[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, tmpPath);
    if (n == 0 || n > MAX_PATH) { fputs("hookc: no temp path\n", stderr); return 3; }
    if (GetTempFileNameW(tmpPath, L"hkc", 0, tmpFile) == 0) { fputs("hookc: no temp file\n", stderr); return 3; }
    HANDLE h = CreateFileW(tmpFile, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, NULL);
    if (h == INVALID_HANDLE_VALUE) { fputs("hookc: temp file not writable\n", stderr); return 3; }
    DWORD put = 0;
    WriteFile(h, payload, (DWORD)len, &put, NULL);
    CloseHandle(h);

    wchar_t cmd[32768];
    _snwprintf(cmd, 32768, L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%ls\" < \"%ls\"", guard, tmpFile);
    int rc = _wsystem(cmd);
    DeleteFileW(tmpFile);
    return rc;
}

int wmain(int argc, wchar_t** argv) {
    static wchar_t guardBuf[MAX_PATH * 2];
    const wchar_t* guard;
    if (argc > 1 && argv[1][0]) {
        guard = argv[1];                                  /* explicit override (rigs, tests) */
    } else {
        wchar_t prof[MAX_PATH];
        DWORD n = GetEnvironmentVariableW(L"USERPROFILE", prof, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) { fputs("hookc: USERPROFILE not set\n", stderr); return 3; }
        _snwprintf(guardBuf, MAX_PATH * 2, L"%ls\\.copilot\\hooks\\hook-pre.ps1", prof);
        guard = guardBuf;
    }
    wchar_t pipeBuf[512];
    full_pipe_name((argc > 2) ? argv[2] : L"codai-hookc", pipeBuf, 512);
    g_budget = pipe_timeout_ms();

    /* 1. read ALL of stdin first: the fallback needs the payload verbatim. */
    size_t cap = 65536, len = 0;
    unsigned char* buf = (unsigned char*)malloc(cap);
    if (!buf) { fputs("hookc: out of memory\n", stderr); return 3; }
    for (;;) {
        if (len == cap) { cap *= 2; unsigned char* nb = (unsigned char*)realloc(buf, cap); if (!nb) { free(buf); return 3; } buf = nb; }
        DWORD got = 0;
        if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), buf + len, (DWORD)(cap - len), &got, NULL)) break;
        if (got == 0) break;
        len += got;
    }

    /* 2. connect; a short wait only - a hook must not stall the harness when the server is down. */
    if (!WaitNamedPipeW(pipeBuf, 250)) { DWORD e = GetLastError(); note_err("no server", e); int rc = fallback(guard, buf, len, NULL); free(buf); return rc; }
    HANDLE p = CreateFileW(pipeBuf, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (p == INVALID_HANDLE_VALUE) { DWORD e = GetLastError(); note_err("pipe not openable", e); int rc = fallback(guard, buf, len, NULL); free(buf); return rc; }
    g_pipe = p;
    g_stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &g_main,
                    THREAD_TERMINATE, FALSE, 0);   /* CancelSynchronousIo needs THREAD_TERMINATE */
    HANDLE th = g_stop ? CreateThread(NULL, 0, watchdog, NULL, 0, NULL) : NULL;

    /* 3. framed request: negative header asks for the binary reply. */
    int32_t hdr = -(int32_t)(len + 1);
    int rc = 0; char* body = NULL;
    if (!write_all(p, &hdr, 4)) {
        note("request header refused"); rc = fallback(guard, buf, len, NULL);
    } else if (len && !write_all(p, buf, (DWORD)len)) {
        note("payload not fully written"); rc = fallback(guard, buf, len, NULL);
    } else {
        /* NOTE: the payload stays alive until the very end - every fallback below must hand the classic
           path the SAME bytes, otherwise a lost reply would make the guard decide on empty stdin. */
        int32_t rh[3] = { 0, 0, 0 };
        if (!read_all(p, rh, 12)) {
            note(InterlockedCompareExchange(&g_aborted, 0, 0) ? "deadline hit waiting for the reply" : "no reply head");
            rc = fallback(guard, buf, len, NULL);
        } else {
            size_t total = (size_t)(rh[1] > 0 ? rh[1] : 0) + (size_t)(rh[2] > 0 ? rh[2] : 0);
            body = (char*)malloc(total ? total : 1);
            if (!body) { note("out of memory for the reply"); rc = fallback(guard, buf, len, NULL); }
            else if (total && !read_all(p, body, (DWORD)total)) {
                note(InterlockedCompareExchange(&g_aborted, 0, 0) ? "deadline hit reading the reply" : "reply body incomplete");
                rc = fallback(guard, buf, len, NULL);
            } else {
                if (rh[1] > 0) { fwrite(body, 1, (size_t)rh[1], stdout); fflush(stdout); }
                if (rh[2] > 0) { fwrite(body + rh[1], 1, (size_t)rh[2], stderr); fflush(stderr); }
                rc = (int)rh[0];
            }
        }
    }

    if (g_stop) SetEvent(g_stop);
    if (th) { WaitForSingleObject(th, 2000); CloseHandle(th); }
    if (!InterlockedCompareExchange(&g_aborted, 0, 0)) CloseHandle(p);   /* the watchdog owns it when it fired */
    if (g_stop) CloseHandle(g_stop);
    if (g_main) CloseHandle(g_main);
    free(body); free(buf);
    return rc;
}
