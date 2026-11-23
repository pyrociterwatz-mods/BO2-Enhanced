/* Buffered, thread-safe text log in Documents\BO2 Audio logs. */
#include "log.h"
#include <shlobj.h>
#include <stdio.h>
#include <stdarg.h>

static CRITICAL_SECTION g_cs;
static HANDLE g_file = INVALID_HANDLE_VALUE;
static char g_buf[256 * 1024];
static int g_len;
static LARGE_INTEGER g_t0, g_freq;
static int g_ready;

double log_now(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)(t.QuadPart - g_t0.QuadPart) / (double)g_freq.QuadPart;
}

void log_open(void)
{
    char dir[MAX_PATH], path[MAX_PATH];
    SYSTEMTIME st;
    if (g_ready) return;
    InitializeCriticalSection(&g_cs);
    QueryPerformanceFrequency(&g_freq);
    QueryPerformanceCounter(&g_t0);
    if (GetEnvironmentVariableA("BO2AUDIO_LOGDIR", dir, MAX_PATH) == 0) {   /* override used by the test harness */
        if (SHGetFolderPathA(NULL, CSIDL_PERSONAL, NULL, 0, dir) != S_OK)
            GetTempPathA(MAX_PATH, dir);
        lstrcatA(dir, "\\BO2 Audio logs");
    }
    CreateDirectoryA(dir, NULL);
    GetLocalTime(&st);
    wsprintfA(path, "%s\\bo2audio-%04d%02d%02d-%02d%02d%02d.txt", dir, st.wYear, st.wMonth, st.wDay,
              st.wHour, st.wMinute, st.wSecond);
    g_file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    g_ready = 1;
}

static void flush_locked(void)
{
    DWORD w;
    if (g_len && g_file != INVALID_HANDLE_VALUE) WriteFile(g_file, g_buf, g_len, &w, NULL);
    g_len = 0;
}

void log_flush(void)
{
    if (!g_ready) return;
    EnterCriticalSection(&g_cs);
    flush_locked();
    LeaveCriticalSection(&g_cs);
}

void log_close(void)
{
    if (!g_ready) return;
    log_flush();
    if (g_file != INVALID_HANDLE_VALUE) CloseHandle(g_file);
    g_file = INVALID_HANDLE_VALUE;
}

void logf_(const char *fmt, ...)
{
    char line[1024];
    int n;
    va_list ap;
    if (!g_ready) return;
    n = snprintf(line, sizeof line, "%10.4f %5lu ", log_now(), GetCurrentThreadId());
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof line - n - 2, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof line - 2) n = sizeof line - 2;
    line[n++] = '\r';
    line[n++] = '\n';
    EnterCriticalSection(&g_cs);
    if (g_len + n > (int)sizeof g_buf) flush_locked();
    memcpy(g_buf + g_len, line, n);
    g_len += n;
    LeaveCriticalSection(&g_cs);
}
