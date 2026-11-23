/* Logging-only build: every FSOUND entry the game uses is wrapped, logged and passed to the original FMOD 3.
   Nothing about the audio changes. Purpose: record real traffic, threads, callback timing and stop/close races. */
#include <windows.h>
#include "log.h"
#include "hook.h"

/* ------------------------------------------------------------------ per-function stats */
enum {
    F_SetOutput, F_Init, F_Close, F_SetSFXMasterVolume, F_GetMaxChannels, F_GetOutput,
    F_DSP_Create, F_DSP_Free, F_DSP_SetActive, F_DSP_GetSFXUnit, F_DSP_GetBufferLength, F_DSP_MixBuffers,
    F_Lock, F_Unlock, F_PlaySoundEx, F_StopSound, F_SetFrequency, F_SetLevels, F_SetVolume, F_SetVolumeAbsolute,
    F_SetPaused, F_IsPlaying, F_Sample_Alloc, F_Sample_Free, F_Sample_Upload, F_Sample_SetMode, F_Sample_SetLoopPoints,
    F_Stream_Create, F_Stream_Play, F_Stream_Stop, F_Stream_Close, F_COUNT
};
typedef struct { const char *name; unsigned addr; int limit; volatile LONG calls; volatile LONG logged;
                 volatile LONG offmain; double maxms; } FnStat;
/* limit: how many calls are logged one by one (-1 = all). Counting never stops. */
static FnStat S[F_COUNT] = {
    {"SetOutput", 0x6d4070, -1}, {"Init", 0x6d4430, -1}, {"Close", 0x6d4990, -1},
    {"SetSFXMasterVolume", 0x6d4270, -1}, {"GetMaxChannels", 0x6d4d20, 50}, {"GetMixer", 0x6d4be0, 20},
    {"DSP_Create", 0x6dcb50, -1}, {"DSP_Free", 0x6dcbb0, -1}, {"DSP_SetActive", 0x6dcd10, -1},
    {"DSP_GetSFXUnit", 0x6dcd60, 20}, {"DSP_GetBufferLength", 0x6dcdc0, -1}, {"DSP_MixBuffers", 0x6dcde0, 30},
    {"Lock", 0x6e2310, 0}, {"Unlock", 0x6e2340, 0}, {"PlaySoundEx", 0x6e24e0, 400}, {"StopSound", 0x6e2860, 400},
    {"SetFrequency", 0x6e2c60, 200}, {"SetLevels", 0x6e2d50, 200}, {"SetVolume", 0x6e2e60, 200},
    {"SetPan", 0x6e3070, 200}, {"SetPaused", 0x6e3430, 400}, {"IsPlaying", 0x6e3890, 50},
    {"Sample_Alloc", 0x6e41d0, -1}, {"Sample_Free", 0x6e4340, -1}, {"Sample_Upload", 0x6e4720, -1},
    {"Sample_SetMode", 0x6e4890, -1}, {"Sample_SetLoopPoints", 0x6e4910, -1},
    {"Stream_Create", 0x6e6a70, -1}, {"Stream_Play", 0x6e70d0, -1}, {"Stream_Stop", 0x6e7250, -1},
    {"Stream_Close", 0x6e7350, -1},
};
static void *T[F_COUNT];          /* trampolines to the original code */
static DWORD g_main_tid;

static int want_log(int f)
{
    FnStat *s = &S[f];
    InterlockedIncrement(&s->calls);
    if (g_main_tid && GetCurrentThreadId() != g_main_tid) InterlockedIncrement(&s->offmain);
    if (s->limit < 0) return 1;
    if (s->logged >= s->limit) return 0;
    return InterlockedIncrement(&s->logged) <= s->limit;
}
static void note_ms(int f, double ms) { if (ms > S[f].maxms) S[f].maxms = ms; }
#define RET ((unsigned)__builtin_return_address(0))

/* ------------------------------------------------------------------ callback wrapping */
/* Each wrapped callback gets a 10-byte thunk (mov eax, slot; jmp common) so the original pointer is recovered
   without touching the arguments. Slots are reused per (callback, userdata) pair. */
#define MAXSLOTS 512
typedef struct Slot {
    void *orig, *user, *stream;           /* stream: FSOUND_STREAM* (streams only) */
    unsigned char *thunk;
    int kind;                             /* 1 dsp, 2 stream */
    volatile LONG calls, in_cb;
    volatile DWORD cb_tid;
    DWORD tids[4];
    double maxms;
    LONG slow;
} Slot;
static Slot g_slots[MAXSLOTS];
static volatile LONG g_nslots;
static CRITICAL_SECTION g_slot_cs;
static DWORD g_cb_threads[8];
static int g_ncb_threads;

static void note_cb_thread(Slot *s)
{
    DWORD t = GetCurrentThreadId();
    int i;
    for (i = 0; i < 4 && s->tids[i]; i++) if (s->tids[i] == t) goto global;
    if (i < 4) {
        s->tids[i] = t;
        if (i > 0) LOG("NOTE: %s callback %p (user %p) now also runs on thread %lu (was %lu)",
                       s->kind == 1 ? "DSP" : "stream", s->orig, s->user, t, s->tids[0]);
    }
global:
    EnterCriticalSection(&g_slot_cs);
    for (i = 0; i < g_ncb_threads; i++) if (g_cb_threads[i] == t) break;
    if (i == g_ncb_threads && i < 8) {
        g_cb_threads[g_ncb_threads++] = t;
        LOG("callback thread #%d: tid %lu (%s callback)%s", g_ncb_threads, t, s->kind == 1 ? "DSP" : "stream",
            g_ncb_threads > 1 ? "  <-- more than one thread runs FMOD callbacks" : "");
    }
    LeaveCriticalSection(&g_slot_cs);
}

typedef void *(__cdecl *DspCb)(void *orig, void *buf, int len, void *user);
typedef signed char (__cdecl *StreamCb)(void *stream, void *buf, int len, void *user);

static void *__cdecl dsp_wrap(Slot *s, void *orig, void *buf, int len, void *user)
{
    LARGE_INTEGER a, b, f;
    void *r;
    LONG n = InterlockedIncrement(&s->calls);
    if (n <= 2 || (n & 0xFFF) == 0) note_cb_thread(s);
    if (n == 1) LOG("DSP cb %p first run: orig %p buf %p len %d user %p mixshift [AACFBC]=%lu blocklen [AACFAC]=%lu",
                    s->orig, orig, buf, len, user, *(DWORD *)0xAACFBC, *(DWORD *)0xAACFAC);
    QueryPerformanceCounter(&a);
    r = ((DspCb)s->orig)(orig, buf, len, user);
    QueryPerformanceCounter(&b);
    QueryPerformanceFrequency(&f);
    { double ms = (b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart; if (ms > s->maxms) s->maxms = ms; }
    return r;
}

static signed char __cdecl stream_wrap(Slot *s, void *stream, void *buf, int len, void *user)
{
    LARGE_INTEGER a, b, f;
    signed char r;
    double ms;
    LONG n = InterlockedIncrement(&s->calls);
    if (n <= 2 || (n & 0xFF) == 0) note_cb_thread(s);
    if (s->in_cb) LOG("RACE: stream cb for %p re-entered (thread %lu already inside)", stream, s->cb_tid);
    s->cb_tid = GetCurrentThreadId();
    InterlockedExchange(&s->in_cb, 1);
    QueryPerformanceCounter(&a);
    r = ((StreamCb)s->orig)(stream, buf, len, user);
    QueryPerformanceCounter(&b);
    InterlockedExchange(&s->in_cb, 0);
    QueryPerformanceFrequency(&f);
    ms = (b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart;
    if (ms > s->maxms) s->maxms = ms;
    if (ms > 4.0) {
        s->slow++;
        LOG("stream cb %p (user %p) took %.2f ms for %d bytes (waiting on the game stream lock 0xA7C178?)", stream, user, ms, len);
    }
    return r;
}

__attribute__((naked)) static void dsp_common(void)
{
    __asm__ volatile(
        "mov %%eax, %%ecx\n\t"
        "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t"
        "pushl %%ecx\n\t"
        "call %P0\n\t"
        "addl $20, %%esp\n\t"
        "ret\n\t" :: "i"(dsp_wrap));
}
__attribute__((naked)) static void stream_common(void)
{
    __asm__ volatile(
        "mov %%eax, %%ecx\n\t"
        "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t" "pushl 16(%%esp)\n\t"
        "pushl %%ecx\n\t"
        "call %P0\n\t"
        "addl $20, %%esp\n\t"
        "ret\n\t" :: "i"(stream_wrap));
}

static Slot *get_slot(int kind, void *orig, void *user)
{
    Slot *s = NULL;
    int i;
    EnterCriticalSection(&g_slot_cs);
    for (i = 0; i < g_nslots; i++)
        if (g_slots[i].kind == kind && g_slots[i].orig == orig && g_slots[i].user == user) { s = &g_slots[i]; break; }
    if (!s && g_nslots < MAXSLOTS) {
        unsigned char *t = exec_alloc(10);
        if (t) {
            s = &g_slots[g_nslots];
            s->kind = kind; s->orig = orig; s->user = user; s->thunk = t;
            t[0] = 0xB8; *(Slot **)(t + 1) = s;
            t[5] = 0xE9; *(int *)(t + 6) = (int)((unsigned char *)(kind == 1 ? (void *)dsp_common : (void *)stream_common) - (t + 10));
            FlushInstructionCache(GetCurrentProcess(), t, 10);
            g_nslots++;
        }
    }
    LeaveCriticalSection(&g_slot_cs);
    return s;
}

static Slot *slot_for_stream(void *stream)
{
    int i;
    for (i = 0; i < g_nslots; i++) if (g_slots[i].kind == 2 && g_slots[i].stream == stream) return &g_slots[i];
    return NULL;
}

/* ------------------------------------------------------------------ hooks */
typedef int (__stdcall *fn0)(void);
typedef int (__stdcall *fn1)(int);
typedef int (__stdcall *fn2)(int, int);
typedef int (__stdcall *fn3)(int, int, int);
typedef int (__stdcall *fn4)(int, int, int, int);
typedef int (__stdcall *fn5)(int, int, int, int, int);
typedef int (__stdcall *fn7)(int, int, int, int, int, int, int);

static double ms_since(LARGE_INTEGER a)
{
    LARGE_INTEGER b, f;
    QueryPerformanceCounter(&b);
    QueryPerformanceFrequency(&f);
    return (b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart;
}
#define TSTART LARGE_INTEGER t0_; QueryPerformanceCounter(&t0_)
#define TMS ms_since(t0_)

static DWORD WINAPI summary_thread(LPVOID p);
static volatile LONG g_summary_started;

static int __stdcall h_SetOutput(int o) { int r = ((fn1)T[F_SetOutput])(o); if (want_log(F_SetOutput)) LOG("SetOutput(%d) = %d  [from %08X]", o, r & 0xff, RET); return r; }

static int __stdcall h_Init(int rate, int ch, int flags)
{
    int r;
    TSTART;
    if (!g_main_tid) g_main_tid = GetCurrentThreadId();
    if (InterlockedExchange(&g_summary_started, 1) == 0) CloseHandle(CreateThread(NULL, 0, summary_thread, NULL, 0, NULL));
    r = ((fn3)T[F_Init])(rate, ch, flags);
    want_log(F_Init);
    LOG("Init(%d, %d, 0x%X) = %d in %.1f ms. output=%lu mixer=%lu mixshift=%lu (bytes/frame %lu) blocklen=%lu mixbuf=%08lX clearfn=%08lX "
        "channels=%lu hw2d=%lu hw3d=%lu",
        rate, ch, flags, r & 0xff, TMS, *(DWORD *)(*(DWORD *)0x90B9BC + 4), *(DWORD *)(*(DWORD *)0x90B9BC + 8), *(DWORD *)0xAACFBC, 4ul << *(DWORD *)0xAACFBC,
        *(DWORD *)0xAACFAC, *(DWORD *)0xAACFA8, *(DWORD *)0xA9567C, *(DWORD *)(*(DWORD *)0x90B9BC + 0x470),
        *(DWORD *)(*(DWORD *)0x90B9BC + 0x478), *(DWORD *)(*(DWORD *)0x90B9BC + 0x47C));
    log_flush();
    return r;
}
static int __stdcall h_Close(void) { TSTART; int r = ((fn0)T[F_Close])(); want_log(F_Close); LOG("Close() in %.1f ms (mixer exited flag [90C840]=%d)", TMS, *(BYTE *)0x90C840); log_flush(); return r; }
static int __stdcall h_SetSFXMasterVolume(int v) { int r = ((fn1)T[F_SetSFXMasterVolume])(v); if (want_log(F_SetSFXMasterVolume)) LOG("SetSFXMasterVolume(%d)", v); return r; }
static int __stdcall h_GetMaxChannels(void) { int r = ((fn0)T[F_GetMaxChannels])(); if (want_log(F_GetMaxChannels)) LOG("GetMaxChannels() = %d", r); return r; }
static int __stdcall h_GetOutput(void) { int r = ((fn0)T[F_GetOutput])(); if (want_log(F_GetOutput)) LOG("GetMixer() = %d", r); return r; }

static int __stdcall h_DSP_Create(int cb, int prio, int user)
{
    Slot *s = cb ? get_slot(1, (void *)cb, (void *)user) : NULL;
    int r = ((fn3)T[F_DSP_Create])(s ? (int)s->thunk : cb, prio, user);
    want_log(F_DSP_Create);
    LOG("DSP_Create(cb %08X, prio %d, user %08X) = %08X%s  [from %08X]", cb, prio, user, r, s ? " (wrapped)" : "", RET);
    return r;
}
static int __stdcall h_DSP_Free(int u) { TSTART; int r = ((fn1)T[F_DSP_Free])(u); double ms = TMS; note_ms(F_DSP_Free, ms); want_log(F_DSP_Free); LOG("DSP_Free(%08X) in %.2f ms", u, ms); return r; }
static int __stdcall h_DSP_SetActive(int u, int a) { int r = ((fn2)T[F_DSP_SetActive])(u, a); if (want_log(F_DSP_SetActive)) LOG("DSP_SetActive(%08X, %d)", u, a & 0xff); return r; }
static int __stdcall h_DSP_GetSFXUnit(void) { int r = ((fn0)T[F_DSP_GetSFXUnit])(); if (want_log(F_DSP_GetSFXUnit)) LOG("DSP_GetSFXUnit() = %08X", r); return r; }
static int __stdcall h_DSP_GetBufferLength(void) { int r = ((fn0)T[F_DSP_GetBufferLength])(); if (want_log(F_DSP_GetBufferLength)) LOG("DSP_GetBufferLength() = %d", r); return r; }
static int __stdcall h_DSP_MixBuffers(int d, int s, int len, int fr, int vol, int pan, int mode)
{
    int r = ((fn7)T[F_DSP_MixBuffers])(d, s, len, fr, vol, pan, mode);
    if (want_log(F_DSP_MixBuffers)) LOG("DSP_MixBuffers(dst %08X, src %08X, len %d, freq %d, vol %d, pan %d, mode 0x%X)", d, s, len, fr, vol, pan, mode);
    return r;
}

static volatile LONG g_lock_slow;
static int __stdcall h_Lock(void)
{
    TSTART;
    int r = ((fn0)T[F_Lock])();
    double ms = TMS;
    want_log(F_Lock);
    note_ms(F_Lock, ms);
    if (ms > 4.0 && InterlockedIncrement(&g_lock_slow) <= 200) LOG("Lock (CS 0xA7C1BC) waited %.2f ms  [from %08X]", ms, RET);
    return r;
}
static int __stdcall h_Unlock(void) { want_log(F_Unlock); return ((fn0)T[F_Unlock])(); }

static int __stdcall h_PlaySoundEx(int ch, int smp, int dsp, int paused) { int r = ((fn4)T[F_PlaySoundEx])(ch, smp, dsp, paused); if (want_log(F_PlaySoundEx)) LOG("PlaySoundEx(ch %d, sample %08X, dsp %08X, paused %d) = %d", ch, smp, dsp, paused & 0xff, r); return r; }
static int __stdcall h_StopSound(int ch) { int r = ((fn1)T[F_StopSound])(ch); if (want_log(F_StopSound)) LOG("StopSound(%d) = %d", ch, r & 0xff); return r; }
static int __stdcall h_SetFrequency(int ch, int f) { int r = ((fn2)T[F_SetFrequency])(ch, f); if (want_log(F_SetFrequency)) LOG("SetFrequency(%d, %d)", ch, f); return r; }
static int __stdcall h_SetLevels(int ch, int l, int rr) { int r = ((fn3)T[F_SetLevels])(ch, l, rr); if (want_log(F_SetLevels)) LOG("SetLevels(%d, L %d, R %d)", ch, l, rr); return r; }
static int __stdcall h_SetVolume(int ch, int v) { int r = ((fn2)T[F_SetVolume])(ch, v); if (want_log(F_SetVolume)) LOG("SetVolume(%d, %d)", ch, v); return r; }
static int __stdcall h_SetVolumeAbsolute(int ch, int v) { int r = ((fn2)T[F_SetVolumeAbsolute])(ch, v); if (want_log(F_SetVolumeAbsolute)) LOG("SetPan(%d, %d)", ch, v); return r; }
static int __stdcall h_SetPaused(int ch, int p) { int r = ((fn2)T[F_SetPaused])(ch, p); if (want_log(F_SetPaused)) LOG("SetPaused(%d, %d)", ch, p & 0xff); return r; }
static int __stdcall h_IsPlaying(int ch) { int r = ((fn1)T[F_IsPlaying])(ch); if (want_log(F_IsPlaying)) LOG("IsPlaying(%d) = %d", ch, r & 0xff); return r; }

static int __stdcall h_Sample_Alloc(int idx, int len, int mode, int fr, int vol, int pan, int pri)
{
    int r = ((fn7)T[F_Sample_Alloc])(idx, len, mode, fr, vol, pan, pri);
    if (want_log(F_Sample_Alloc)) LOG("Sample_Alloc(idx %d, len %d, mode 0x%X, freq %d, vol %d, pan %d, pri %d) = %08X  [from %08X]", idx, len, mode, fr, vol, pan, pri, r, RET);
    return r;
}
static int __stdcall h_Sample_Free(int s) { int r = ((fn1)T[F_Sample_Free])(s); if (want_log(F_Sample_Free)) LOG("Sample_Free(%08X)  [from %08X]", s, RET); return r; }
static int __stdcall h_Sample_Upload(int s, int data, int mode) { TSTART; int r = ((fn3)T[F_Sample_Upload])(s, data, mode); if (want_log(F_Sample_Upload)) LOG("Sample_Upload(%08X, data %08X, mode 0x%X) = %d in %.2f ms", s, data, mode, r & 0xff, TMS); return r; }
static int __stdcall h_Sample_SetMode(int s, int m) { int r = ((fn2)T[F_Sample_SetMode])(s, m); if (want_log(F_Sample_SetMode)) LOG("Sample_SetMode(%08X, 0x%X)", s, m); return r; }
static int __stdcall h_Sample_SetLoopPoints(int s, int a, int b) { int r = ((fn3)T[F_Sample_SetLoopPoints])(s, a, b); if (want_log(F_Sample_SetLoopPoints)) LOG("Sample_SetLoopPoints(%08X, %d, %d)", s, a, b); return r; }

static int __stdcall h_Stream_Create(int cb, int len, int mode, int rate, int user)
{
    Slot *s = cb ? get_slot(2, (void *)cb, (void *)user) : NULL;
    int r = ((fn5)T[F_Stream_Create])(s ? (int)s->thunk : cb, len, mode, rate, user);
    if (s) s->stream = (void *)r;
    want_log(F_Stream_Create);
    LOG("Stream_Create(cb %08X, bytes %d, mode 0x%X, rate %d, user %08X) = %08X  [from %08X]", cb, len, mode, rate, user, r, RET);
    return r;
}
static int __stdcall h_Stream_Play(int ch, int st, int dsp, int paused) { int r = ((fn4)T[F_Stream_Play])(ch, st, dsp, paused); want_log(F_Stream_Play); LOG("Stream_Play(ch %d, stream %08X, dsp %08X, paused %d) = %d", ch, st, dsp, paused & 0xff, r); return r; }

static void check_race(const char *what, int st)
{
    Slot *s = slot_for_stream((void *)st);
    if (s && s->in_cb && s->cb_tid != GetCurrentThreadId())
        LOG("RACE: %s(%08X) called while thread %lu is inside its stream callback", what, st, s->cb_tid);
}
static int __stdcall h_Stream_Stop(int st)
{
    TSTART;
    int r;
    check_race("Stream_Stop", st);
    r = ((fn1)T[F_Stream_Stop])(st);
    { double ms = TMS; note_ms(F_Stream_Stop, ms); want_log(F_Stream_Stop); LOG("Stream_Stop(%08X) = %d in %.2f ms  [from %08X]", st, r & 0xff, ms, RET); }
    return r;
}
static int __stdcall h_Stream_Close(int st)
{
    TSTART;
    int r;
    Slot *s;
    check_race("Stream_Close", st);
    r = ((fn1)T[F_Stream_Close])(st);
    { double ms = TMS; note_ms(F_Stream_Close, ms); want_log(F_Stream_Close); LOG("Stream_Close(%08X) = %d in %.2f ms", st, r & 0xff, ms); }
    s = slot_for_stream((void *)st);
    if (s) s->stream = NULL;
    return r;
}

static void *const H[F_COUNT] = {
    h_SetOutput, h_Init, h_Close, h_SetSFXMasterVolume, h_GetMaxChannels, h_GetOutput,
    h_DSP_Create, h_DSP_Free, h_DSP_SetActive, h_DSP_GetSFXUnit, h_DSP_GetBufferLength, h_DSP_MixBuffers,
    h_Lock, h_Unlock, h_PlaySoundEx, h_StopSound, h_SetFrequency, h_SetLevels, h_SetVolume, h_SetVolumeAbsolute,
    h_SetPaused, h_IsPlaying, h_Sample_Alloc, h_Sample_Free, h_Sample_Upload, h_Sample_SetMode, h_Sample_SetLoopPoints,
    h_Stream_Create, h_Stream_Play, h_Stream_Stop, h_Stream_Close,
};

/* ------------------------------------------------------------------ summary */
static void summary(const char *why)
{
    int i;
    LOG("---- summary (%s) ----", why);
    for (i = 0; i < F_COUNT; i++)
        if (S[i].calls)
            LOG("  %-22s %9ld calls, %ld off the main thread%s", S[i].name, S[i].calls, S[i].offmain,
                S[i].maxms > 0 ? "" : "");
    LOG("  worst waits: Lock %.2f ms, Stream_Stop %.2f ms, Stream_Close %.2f ms, DSP_Free %.2f ms",
        S[F_Lock].maxms, S[F_Stream_Stop].maxms, S[F_Stream_Close].maxms, S[F_DSP_Free].maxms);
    for (i = 0; i < g_nslots; i++) {
        Slot *s = &g_slots[i];
        if (s->kind == 1) LOG("  DSP cb %p user %p: %ld runs, worst %.2f ms, thread %lu", s->orig, s->user, s->calls, s->maxms, s->tids[0]);
    }
    {
        LONG calls = 0, slow = 0; double worst = 0;
        for (i = 0; i < g_nslots; i++) if (g_slots[i].kind == 2) { calls += g_slots[i].calls; slow += g_slots[i].slow; if (g_slots[i].maxms > worst) worst = g_slots[i].maxms; }
        LOG("  stream callbacks: %ld runs, %ld slower than 4 ms, worst %.2f ms", calls, slow, worst);
    }
    LOG("  callback threads seen: %d", g_ncb_threads);
    hook_report_counters();
    log_flush();
}

static DWORD WINAPI summary_thread(LPVOID p)
{
    int n = 0;
    (void)p;
    for (;;) {
        Sleep(1000);
        log_flush();
        if (++n % 60 == 0) summary("periodic");
    }
    return 0;
}

/* ------------------------------------------------------------------ setup */
void fsound_log_start(void)
{
    int i, bad;
    log_open();
    InitializeCriticalSection(&g_slot_cs);
    LOG("bo2audio logger (no audio changes). exe %s", GetCommandLineA());
    bad = hook_verify();
    if (bad) {
        LOG("%d hook sites differ from the vanilla exe: not hooking anything, FMOD runs untouched", bad);
        log_flush();
        return;
    }
    for (i = 0; i < F_COUNT; i++) {
        T[i] = hook_install(S[i].addr, H[i]);
        if (!T[i]) { LOG("hook failed at %06X (%s)", S[i].addr, S[i].name); }
    }
    hook_install_counters();
    LOG("hooks installed: %d typed + counters", F_COUNT);
    log_flush();
}

#ifdef SELFTEST
/* Test-only: runs a dummy cdecl callback through a DSP thunk and a stream thunk. Returns 0 when both pass. */
static void *__cdecl test_dsp(void *o, void *b, int len, void *u) { return (char *)b + len + (int)u + (o ? 1 : 0); }
static signed char __cdecl test_stream(void *st, void *b, int len, void *u) { return (signed char)(len + (int)u + (st ? 1 : 0) + (b ? 1 : 0)); }
__declspec(dllexport) int __cdecl bo2audio_selftest(void)
{
    Slot *d = get_slot(1, (void *)test_dsp, (void *)7), *s = get_slot(2, (void *)test_stream, (void *)3);
    void *r1 = ((DspCb)d->thunk)((void *)1, (void *)0x1000, 0x20, (void *)7);
    signed char r2 = ((StreamCb)s->thunk)((void *)1, (void *)1, 10, (void *)3);
    LOG("selftest: dsp thunk -> %p (want 00001028), stream thunk -> %d (want 15), calls %ld/%ld", r1, r2, d->calls, s->calls);
    return (r1 == (void *)0x1028 && r2 == 15 && d->calls == 1 && s->calls == 1) ? 0 : 1;
}
#endif

void fsound_log_stop(void)
{
    summary("exit");
    log_close();
}
