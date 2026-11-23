/* Replacement for the FMOD 3 functions bo2.exe calls, on miniaudio. See notes/design.md.

   Threads:
     audio   miniaudio's device thread. Mixes the voices under g_mix. Never calls game code.
     tick    once per 708 frames of output: takes the game's SND lock (0x6E2310), then runs the game's DSP
             callbacks (the sound-sequencer clock 0x6CCEB0) with no lock of ours held.
     feeder  tops up the stream rings: enters the game's stream lock (0x6DD390) first, checks the stream is
             still alive, calls the game's stream callback, leaves the lock.
   Lock order everywhere: game locks -> g_mix. g_mix is only held for short, game-free sections.
   Nothing waits by spinning. DSP_Free / Stream_Stop / Stream_Close take the same game lock the callback
   thread holds, so they return only when no callback for that object is running, and they never deadlock
   with the callback because the game already owns that lock when it calls them (recursive enter). */
#include <windows.h>
#include <string.h>
#include <stdlib.h>
#include "log.h"
#include "hook.h"
#include "ma_cfg.h"

#define OUT_RATE   44100
#define BLOCK      708          /* FMOD's block at 44100 Hz (logger run 1); the game's tick dt is based on it */
#define MAXVOICES  64
#define MAXUNITS   256

/* game functions we call (same addresses in the vanilla and cutscene-mod exe; verified via the hook table) */
typedef void (__cdecl *voidfn)(void);
#define GAME_SND_LOCK     ((voidfn)0x6E2310)   /* CS 0xA7C1BC */
#define GAME_SND_UNLOCK   ((voidfn)0x6E2340)
#define GAME_STREAM_LOCK  ((voidfn)0x6DD390)   /* CS 0xA7C178 */
#define GAME_STREAM_UNLOCK ((voidfn)0x6DD3C0)

typedef void *(__cdecl *DspCb)(void *orig, void *buf, int len, void *user);
typedef signed char (__cdecl *StreamCb)(void *stream, void *buf, int len, void *user);

/* FSOUND mode bits */
#define M_LOOP_OFF    0x01
#define M_LOOP_NORMAL 0x02
#define M_LOOP_BIDI   0x04
#define M_8BITS       0x08
#define M_16BITS      0x10
#define M_MONO        0x20
#define M_STEREO      0x40
#define M_UNSIGNED    0x80
#define M_SIGNED      0x100

/* ------------------------------------------------------------------ objects */
typedef struct Sample {
    int frames, chans;
    short *pcm;                     /* interleaved int16 */
    int loopmode, ls, le;           /* le inclusive */
    int deffreq, defvol, defpan;
    int mode;
} Sample;

typedef struct Stream {
    struct Stream *next;
    StreamCb cb;
    void *user;
    int chunk;                      /* bytes per callback request */
    int chans, bits, bpf_src;       /* source format */
    int rate;
    short *ring; int cap, rd, fill; /* frames */
    unsigned char *tmp;
    int state;                      /* 0 created, 1 playing, 2 stopped */
    int ended, dead, channel;
    LONG cbs;
} Stream;

typedef struct Voice {
    int active, paused, fresh;
    Sample *smp;
    Stream *st;
    double pos;
    int freq;
    int vol, v20, pan, left, right;
    float gl, gr;
} Voice;

typedef struct Unit { DspCb cb; int prio; void *user; int active, dead, used; } Unit;

static CRITICAL_SECTION g_mix;
static Voice g_v[MAXVOICES];
static int g_nch = 48;
static int g_master = 255;
static int g_inited;                /* between Init and Close */
static Unit g_units[MAXUNITS];
static Unit g_sfx_unit;             /* returned by DSP_GetSFXUnit; never runs */
static Stream *g_streams;

/* device / threads */
static ma_context g_ctx;
static ma_device g_dev;
static volatile LONG g_have_device;
static volatile LONG g_started;
static HANDLE g_tick_ev, g_feed_ev, g_ctl_done;
static volatile LONGLONG g_clock;   /* output frames played (or synthesised when no device) */
static volatile LONGLONG g_last_cb_qpc;
static LONGLONG g_qpf;

/* stats */
static volatile LONG st_underrun, st_dropped_ticks, st_ticks, st_cb_frames_max, st_streams, st_samples, st_stream_cbs;
static volatile LONG st_maxvoices, st_unknown_mode;
static double st_mix_ms_max, st_tick_ms_max, st_feed_ms_max, st_feed_lock_ms_max;

static LONGLONG qpc(void) { LARGE_INTEGER t; QueryPerformanceCounter(&t); return t.QuadPart; }
static double ms_between(LONGLONG a, LONGLONG b) { return (b - a) * 1000.0 / g_qpf; }
static int clamp(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

/* ------------------------------------------------------------------ voices (call with g_mix held) */
static void v_pan_levels(Voice *v)
{
    if (v->pan < 0) { v->left = v->right = v->v20; return; }
    v->right = v->v20 * v->pan / 255;
    v->left = v->v20 * (255 - v->pan) / 255;
}

static void v_stop(Voice *v)
{
    if (v->st) { v->st->state = 2; v->st->channel = -1; }
    v->active = 0; v->smp = NULL; v->st = NULL;
}

static void v_start(Voice *v, int vol, int pan, int freq, int paused)
{
    v->active = 1; v->paused = paused; v->fresh = 1;
    v->pos = 0; v->freq = freq;
    v->vol = vol; v->v20 = vol * g_master / 255; v->pan = pan;
    v_pan_levels(v);
}

/* Runs the statement on one channel or on all of them (-3). Sets ok = 0 for a bad channel. */
#define FOR_CH(ch, ...) do { int c_, lo_ = (ch), hi_ = (ch) + 1; \
    if ((ch) == -3) { lo_ = 0; hi_ = g_nch; } else if ((ch) < 0 || (ch) >= g_nch) { ok = 0; break; } \
    for (c_ = lo_; c_ < hi_; c_++) { Voice *v = &g_v[c_]; __VA_ARGS__; } } while (0)

/* ------------------------------------------------------------------ stream ring (g_mix held) */
static int ring_free(Stream *s) { return s->cap - s->fill; }
static void ring_write(Stream *s, const unsigned char *src, int bytes)
{
    int frames = bytes / s->bpf_src, i, c;
    if (frames > ring_free(s)) frames = ring_free(s);
    for (i = 0; i < frames; i++) {
        int w = (s->rd + s->fill) % s->cap;
        for (c = 0; c < s->chans; c++) {
            short x;
            if (s->bits == 16) x = ((const short *)src)[i * s->chans + c];
            else x = (short)(((int)src[i * s->chans + c] - 128) << 8);
            s->ring[w * s->chans + c] = x;
        }
        s->fill++;
    }
}

/* ------------------------------------------------------------------ mixer */
static void mix_voice(Voice *v, float *out, int n)
{
    double step = v->freq / (double)OUT_RATE;
    float tl = v->left / 255.0f, tr = v->right / 255.0f;
    int i;
    if (v->fresh) { v->gl = tl; v->gr = tr; v->fresh = 0; }
    if (step <= 0) return;
    for (i = 0; i < n; i++) {
        float l0, r0, l1, r1, fr, a, b;
        int idx;
        v->gl += (tl - v->gl) * 0.02f;          /* ~1 ms ramp: no clicks on volume jumps */
        v->gr += (tr - v->gr) * 0.02f;
        if (v->smp) {
            Sample *s = v->smp;
            int j, loop = (s->loopmode & (M_LOOP_NORMAL | M_LOOP_BIDI)) && s->le > s->ls;
            idx = (int)v->pos;
            if (idx >= s->frames) { v_stop(v); return; }
            fr = (float)(v->pos - idx);
            j = idx + 1;
            if (loop && idx >= s->le) j = s->ls;
            if (s->chans == 2) {
                l0 = s->pcm[idx * 2]; r0 = s->pcm[idx * 2 + 1];
                if (j < s->frames) { l1 = s->pcm[j * 2]; r1 = s->pcm[j * 2 + 1]; } else l1 = r1 = 0;
            } else {
                l0 = r0 = s->pcm[idx];
                l1 = r1 = j < s->frames ? s->pcm[j] : 0;
            }
            v->pos += step;
            if (loop) { double len = s->le - s->ls + 1; while (v->pos >= s->le + 1) v->pos -= len; }
        } else {
            Stream *s = v->st;
            int adv;
            if (s->fill == 0) {
                if (s->ended) { v_stop(v); return; }
                InterlockedIncrement(&st_underrun);
                return;                                     /* silent until the feeder catches up */
            }
            fr = (float)v->pos;
            idx = s->rd;
            if (s->chans == 2) { l0 = s->ring[idx * 2]; r0 = s->ring[idx * 2 + 1]; }
            else l0 = r0 = s->ring[idx];
            if (s->fill >= 2) {
                int j = (idx + 1) % s->cap;
                if (s->chans == 2) { l1 = s->ring[j * 2]; r1 = s->ring[j * 2 + 1]; } else l1 = r1 = s->ring[j];
            } else { l1 = l0; r1 = r0; }
            v->pos += step;
            adv = (int)v->pos;
            if (adv > s->fill) adv = s->fill;
            v->pos -= adv;
            s->rd = (s->rd + adv) % s->cap;
            s->fill -= adv;
        }
        a = l0 + (l1 - l0) * fr;
        b = r0 + (r1 - r0) * fr;
        out[i * 2] += a * (1.0f / 32768.0f) * v->gl;
        out[i * 2 + 1] += b * (1.0f / 32768.0f) * v->gr;
    }
}

static void data_cb(ma_device *d, void *pout, const void *pin, ma_uint32 n)
{
    float *out = (float *)pout;
    LONGLONG t0 = qpc();
    int i, nact = 0;
    (void)d; (void)pin;
    memset(out, 0, n * 2 * sizeof(float));
    EnterCriticalSection(&g_mix);
    for (i = 0; i < g_nch; i++) {
        Voice *v = &g_v[i];
        if (!v->active || v->paused) continue;
        nact++;
        mix_voice(v, out, (int)n);
    }
    LeaveCriticalSection(&g_mix);
    for (i = 0; i < (int)n * 2; i++) {
        float x = out[i];
        out[i] = x > 1.0f ? 1.0f : x < -1.0f ? -1.0f : x;
    }
    {
        double ms = ms_between(t0, qpc());
        if (ms > st_mix_ms_max) st_mix_ms_max = ms;
        if (nact > st_maxvoices) st_maxvoices = nact;
        if ((LONG)n > st_cb_frames_max) st_cb_frames_max = n;
    }
    InterlockedExchangeAdd64(&g_clock, n);
    InterlockedExchange64(&g_last_cb_qpc, qpc());
    SetEvent(g_tick_ev);
    SetEvent(g_feed_ev);
}

/* ------------------------------------------------------------------ tick thread */
static short g_scratch[BLOCK * 2 * 2];

static void run_tick(void)
{
    Unit *list[MAXUNITS];
    int n = 0, i, j;
    LONGLONG t0 = qpc();
    GAME_SND_LOCK();
    EnterCriticalSection(&g_mix);
    if (g_inited)
        for (i = 0; i < MAXUNITS; i++)
            if (g_units[i].used && g_units[i].active && !g_units[i].dead && g_units[i].cb) list[n++] = &g_units[i];
    LeaveCriticalSection(&g_mix);
    for (i = 1; i < n; i++)                                  /* by priority, as FMOD's DSP chain */
        for (j = i; j > 0 && list[j - 1]->prio > list[j]->prio; j--) { Unit *t = list[j]; list[j] = list[j - 1]; list[j - 1] = t; }
    for (i = 0; i < n; i++) {
        int ok;
        EnterCriticalSection(&g_mix);
        ok = list[i]->active && !list[i]->dead;             /* a callback may have freed another unit */
        LeaveCriticalSection(&g_mix);
        if (!ok) continue;
        memset(g_scratch, 0, sizeof g_scratch);
        list[i]->cb(g_scratch, g_scratch, BLOCK, list[i]->user);
    }
    GAME_SND_UNLOCK();
    {
        double ms = ms_between(t0, qpc());
        if (ms > st_tick_ms_max) st_tick_ms_max = ms;
    }
    InterlockedIncrement(&st_ticks);
}

static DWORD WINAPI tick_thread(LPVOID p)
{
    LONGLONG done = 0, last = qpc();
    (void)p;
    for (;;) {
        LONGLONG now, target;
        WaitForSingleObject(g_tick_ev, 5);
        now = qpc();
        /* No device, or the device stopped calling back (lost, unplugged): keep the game's clock running. */
        if (!g_have_device || ms_between(InterlockedCompareExchange64(&g_last_cb_qpc, 0, 0), now) > 200.0) {
            LONGLONG frames = (now - last) * OUT_RATE / g_qpf;
            if (frames > 0) { InterlockedExchangeAdd64(&g_clock, frames); last += frames * g_qpf / OUT_RATE; }
        } else last = now;
        target = InterlockedCompareExchange64(&g_clock, 0, 0) / BLOCK;
        if (done == 0 && target > 1) done = target - 1;     /* start-up: don't replay history */
        if (target - done > 16) { InterlockedExchangeAdd(&st_dropped_ticks, (LONG)(target - done - 16)); done = target - 16; }
        while (done < target) { run_tick(); done++; }
    }
    return 0;
}

/* ------------------------------------------------------------------ feeder thread */
static void summary(const char *why);

static DWORD WINAPI feeder_thread(LPVOID p)
{
    LONGLONG last_flush = qpc(), last_sum = last_flush;
    (void)p;
    for (;;) {
        Stream *list[64];
        int n = 0, i;
        Stream **pp;
        LONGLONG now;
        WaitForSingleObject(g_feed_ev, 5);
        now = qpc();
        if (ms_between(last_flush, now) > 1000) { log_flush(); last_flush = now; }
        if (ms_between(last_sum, now) > 60000) { summary("periodic"); last_sum = now; }

        EnterCriticalSection(&g_mix);
        for (pp = &g_streams; *pp;) {                        /* only this thread frees streams */
            Stream *s = *pp;
            if (s->dead) { *pp = s->next; free(s->ring); free(s->tmp); free(s); continue; }
            if (s->state == 1 && !s->ended && ring_free(s) * s->bpf_src >= s->chunk && n < 64) list[n++] = s;
            pp = &s->next;
        }
        LeaveCriticalSection(&g_mix);

        for (i = 0; i < n; i++) {
            Stream *s = list[i];
            int ok;
            LONGLONG t0 = qpc(), t1;
            GAME_STREAM_LOCK();
            t1 = qpc();
            EnterCriticalSection(&g_mix);
            ok = s->state == 1 && !s->ended && !s->dead && ring_free(s) * s->bpf_src >= s->chunk;
            LeaveCriticalSection(&g_mix);
            if (ok) {
                signed char r = s->cb(s, s->tmp, s->chunk, s->user);
                InterlockedIncrement(&st_stream_cbs);
                EnterCriticalSection(&g_mix);
                if (s->state == 1 && !s->dead) { ring_write(s, s->tmp, s->chunk); if (!r) s->ended = 1; }
                s->cbs++;
                LeaveCriticalSection(&g_mix);
            }
            GAME_STREAM_UNLOCK();
            {
                double lw = ms_between(t0, t1), all = ms_between(t0, qpc());
                if (lw > st_feed_lock_ms_max) st_feed_lock_ms_max = lw;
                if (all > st_feed_ms_max) st_feed_ms_max = all;
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ device control thread */
/* The device is created on a thread of our own, so miniaudio's COM set-up never meets the game's apartment. */
static DWORD WINAPI ctl_thread(LPVOID p)
{
    ma_device_config cfg;
    ma_result r;
    (void)p;
#ifdef SELFTEST
    if (GetEnvironmentVariableA("BO2AUDIO_NODEVICE", NULL, 0)) { LOG("audio: test mode, no device"); goto out; }
#endif
    r = ma_context_init(NULL, 0, NULL, &g_ctx);
    if (r != MA_SUCCESS) { LOG("audio: ma_context_init failed (%d); running without output", r); goto out; }
    cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = OUT_RATE;
    cfg.dataCallback = data_cb;
    cfg.periodSizeInMilliseconds = 10;
    cfg.periods = 3;
    cfg.performanceProfile = ma_performance_profile_low_latency;
    cfg.noClip = MA_TRUE;
    r = ma_device_init(&g_ctx, &cfg, &g_dev);
    if (r != MA_SUCCESS) { LOG("audio: ma_device_init failed (%d); running without output", r); goto out; }
    LOG("audio: backend %s, device \"%s\", internal %u Hz %u ch fmt %d, period %u frames x %u",
        ma_get_backend_name(g_ctx.backend), g_dev.playback.name, g_dev.playback.internalSampleRate,
        g_dev.playback.internalChannels, g_dev.playback.internalFormat,
        g_dev.playback.internalPeriodSizeInFrames, g_dev.playback.internalPeriods);
    r = ma_device_start(&g_dev);
    if (r != MA_SUCCESS) { LOG("audio: ma_device_start failed (%d)", r); ma_device_uninit(&g_dev); goto out; }
    InterlockedExchange64(&g_last_cb_qpc, qpc());
    InterlockedExchange(&g_have_device, 1);
out:
    log_flush();
    SetEvent(g_ctl_done);
    Sleep(INFINITE);           /* keep the thread (and its COM apartment) alive for the device */
    return 0;
}

static void start_once(void)
{
    if (InterlockedExchange(&g_started, 1)) return;
    g_tick_ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    g_feed_ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    g_ctl_done = CreateEventA(NULL, TRUE, FALSE, NULL);
    CloseHandle(CreateThread(NULL, 0, ctl_thread, NULL, 0, NULL));
    if (WaitForSingleObject(g_ctl_done, 5000) != WAIT_OBJECT_0) LOG("audio: device start is taking over 5 s; continuing");
    {
        HANDLE h = CreateThread(NULL, 0, feeder_thread, NULL, 0, NULL);
        SetThreadPriority(h, THREAD_PRIORITY_ABOVE_NORMAL);
        CloseHandle(h);
        h = CreateThread(NULL, 0, tick_thread, NULL, 0, NULL);
        SetThreadPriority(h, THREAD_PRIORITY_ABOVE_NORMAL);
        CloseHandle(h);
    }
}

/* ------------------------------------------------------------------ FSOUND shims (all __stdcall) */
static volatile LONG c_play, c_stop, c_streamplay, c_streamstop, c_streamclose, c_dspfree;

static int __stdcall s_SetOutput(int o) { LOG("SetOutput(%d)", o); return 1; }

static int __stdcall s_Init(int rate, int ch, int flags)
{
    int i;
    start_once();
    EnterCriticalSection(&g_mix);
    for (i = 0; i < MAXVOICES; i++) v_stop(&g_v[i]);
    g_nch = clamp(ch, 1, MAXVOICES);
    g_inited = 1;
    LeaveCriticalSection(&g_mix);
    LOG("Init(%d, %d, 0x%X): %d channels, output %s", rate, ch, flags, g_nch, g_have_device ? "on" : "none (silent, clock only)");
    log_flush();
    return 1;
}

static int __stdcall s_Close(void)
{
    int i;
    Stream *s;
    GAME_SND_LOCK();                             /* waits out a running tick */
    EnterCriticalSection(&g_mix);
    for (i = 0; i < MAXUNITS; i++) if (g_units[i].used) g_units[i].dead = 1;
    g_inited = 0;
    LeaveCriticalSection(&g_mix);
    GAME_SND_UNLOCK();
    GAME_STREAM_LOCK();                          /* waits out a running stream callback */
    EnterCriticalSection(&g_mix);
    for (i = 0; i < MAXVOICES; i++) v_stop(&g_v[i]);
    for (s = g_streams; s; s = s->next) { s->state = 2; s->dead = 1; }
    LeaveCriticalSection(&g_mix);
    GAME_STREAM_UNLOCK();
    LOG("Close()");
    log_flush();
    return 0;
}

static int __stdcall s_SetSFXMasterVolume(int v) { EnterCriticalSection(&g_mix); g_master = clamp(v, 0, 255); LeaveCriticalSection(&g_mix); return 0; }
static int __stdcall s_GetMaxChannels(void) { return g_nch; }
static int __stdcall s_GetMixer(void) { return 7; }               /* FSOUND_MIXER_QUALITY_MMXP6, as logged */

static int __stdcall s_DSP_Create(int cb, int prio, int user)
{
    Unit *u = NULL;
    int i;
    EnterCriticalSection(&g_mix);
    for (i = 0; i < MAXUNITS && !u; i++) if (!g_units[i].used) u = &g_units[i];
    for (i = 0; i < MAXUNITS && !u; i++) if (g_units[i].dead) u = &g_units[i];   /* pool full: reuse */
    if (u) { u->cb = (DspCb)cb; u->prio = prio; u->user = (void *)user; u->active = 0; u->dead = 0; u->used = 1; }
    LeaveCriticalSection(&g_mix);
    LOG("DSP_Create(cb %08X, prio %d, user %08X) = %p", cb, prio, user, (void *)u);
    return (int)u;
}
static int __stdcall s_DSP_Free(int unit)
{
    Unit *u = (Unit *)unit;
    if (!u) return 0;
    GAME_SND_LOCK();                             /* the tick thread runs callbacks only while holding this */
    EnterCriticalSection(&g_mix);
    u->dead = 1; u->active = 0;
    LeaveCriticalSection(&g_mix);
    GAME_SND_UNLOCK();
    InterlockedIncrement(&c_dspfree);
    LOG("DSP_Free(%p)", (void *)u);
    return 0;
}
static int __stdcall s_DSP_SetActive(int unit, int a)
{
    Unit *u = (Unit *)unit;
    if (!u || u == &g_sfx_unit) return 0;
    EnterCriticalSection(&g_mix);
    u->active = (a & 0xff) != 0;
    LeaveCriticalSection(&g_mix);
    LOG("DSP_SetActive(%p, %d)", (void *)u, a & 0xff);
    return 0;
}
static int __stdcall s_DSP_GetSFXUnit(void) { return (int)&g_sfx_unit; }
static int __stdcall s_DSP_GetBufferLength(void) { return BLOCK; }

/* Only the game's reverb callback uses this, and it never runs in the PC game. Basic 16-bit stereo add. */
static int __stdcall s_DSP_MixBuffers(int dst, int src, int len, int freq, int vol, int pan, int mode)
{
    short *d = (short *)dst, *s = (short *)src;
    int i, l, r;
    (void)freq; (void)mode;
    if (!d || !s || len <= 0) return 0;
    vol = clamp(vol, 0, 255); pan = clamp(pan, 0, 255);
    l = vol * (255 - pan) / 255; r = vol * pan / 255;
    for (i = 0; i < len; i++) {
        d[i * 2] = (short)clamp(d[i * 2] + s[i * 2] * l / 255, -32768, 32767);
        d[i * 2 + 1] = (short)clamp(d[i * 2 + 1] + s[i * 2 + 1] * r / 255, -32768, 32767);
    }
    return 1;
}

static int __stdcall s_PlaySoundEx(int ch, int smp, int dsp, int paused)
{
    Sample *s = (Sample *)smp;
    int r = -1;
    (void)dsp;                                   /* SFX unit or dry unit: same output while reverb is off */
    if (!s) return -1;
    EnterCriticalSection(&g_mix);
    if (ch == -1) { int i; for (i = 0; i < g_nch; i++) if (!g_v[i].active) { ch = i; break; } }
    if (ch >= 0 && ch < g_nch) {
        Voice *v = &g_v[ch];
        v_stop(v);
        v->smp = s;
        v_start(v, s->defvol, s->defpan, s->deffreq, (paused & 0xff) != 0);
        r = ch;
    }
    LeaveCriticalSection(&g_mix);
    InterlockedIncrement(&c_play);
    return r;
}
static int __stdcall s_StopSound(int ch)
{
    int ok = 1;
    EnterCriticalSection(&g_mix);
    FOR_CH(ch, v_stop(v));
    LeaveCriticalSection(&g_mix);
    InterlockedIncrement(&c_stop);
    return ok;
}
static int __stdcall s_SetFrequency(int ch, int f)
{
    int ok = 1;
    EnterCriticalSection(&g_mix);
    FOR_CH(ch, v->freq = clamp(f, 0, 705600));
    LeaveCriticalSection(&g_mix);
    return ok;
}
static int __stdcall s_SetLevels(int ch, int l, int r)
{
    int ok = 1;
    l = clamp(l, 0, 255); r = clamp(r, 0, 255);
    EnterCriticalSection(&g_mix);
    if (ch == -3) ok = 0;                        /* FMOD returns without doing anything for -3 */
    else FOR_CH(ch, { v->vol = l; v->v20 = l * g_master / 255; v->pan = 128;
                      v->left = v->v20; v->right = r * g_master / 255; });
    LeaveCriticalSection(&g_mix);
    return ok;
}
static int __stdcall s_SetVolume(int ch, int vol)
{
    int ok = 1;
    vol = clamp(vol, 0, 255);
    EnterCriticalSection(&g_mix);
    FOR_CH(ch, { v->vol = vol; v->v20 = vol * g_master / 255; v_pan_levels(v); });
    LeaveCriticalSection(&g_mix);
    return ok;
}
static int __stdcall s_SetPan(int ch, int pan)
{
    int ok = 1;
    pan = clamp(pan, 0, 255);
    EnterCriticalSection(&g_mix);
    FOR_CH(ch, { v->pan = pan; v_pan_levels(v); });
    LeaveCriticalSection(&g_mix);
    return ok;
}
static int __stdcall s_SetPaused(int ch, int p)
{
    int ok = 1;
    EnterCriticalSection(&g_mix);
    FOR_CH(ch, v->paused = (p & 0xff) != 0);
    LeaveCriticalSection(&g_mix);
    return ok;
}
static int __stdcall s_IsPlaying(int ch)
{
    int r = 0;
    EnterCriticalSection(&g_mix);
    if (ch >= 0 && ch < g_nch) r = g_v[ch].active;
    LeaveCriticalSection(&g_mix);
    return r;
}

static int __stdcall s_Sample_Alloc(int idx, int len, int mode, int freq, int vol, int pan, int pri)
{
    Sample *s;
    int chans = (mode & M_STEREO) ? 2 : 1;
    (void)idx; (void)pri;
    if (len <= 0) return 0;
    s = calloc(1, sizeof *s);
    if (!s) return 0;
    s->pcm = calloc((size_t)len * chans, sizeof(short));
    if (!s->pcm) { free(s); return 0; }
    s->frames = len; s->chans = chans; s->mode = mode;
    s->loopmode = mode & 7; s->ls = 0; s->le = len - 1;
    s->deffreq = freq > 0 ? freq : OUT_RATE;
    s->defvol = vol < 0 ? 255 : clamp(vol, 0, 255);
    s->defpan = pan < 0 ? 128 : clamp(pan, 0, 255);
    InterlockedIncrement(&st_samples);
    if ((mode & M_8BITS) && InterlockedIncrement(&st_unknown_mode) <= 10) LOG("Sample_Alloc: 8-bit sample (mode 0x%X)", mode);
    return (int)s;
}
static int __stdcall s_Sample_Free(int smp)
{
    Sample *s = (Sample *)smp;
    int i;
    if (!s) return 0;
    EnterCriticalSection(&g_mix);
    for (i = 0; i < MAXVOICES; i++) if (g_v[i].smp == s) v_stop(&g_v[i]);
    LeaveCriticalSection(&g_mix);
    free(s->pcm);
    free(s);
    InterlockedDecrement(&st_samples);
    return 0;
}
static int __stdcall s_Sample_Upload(int smp, int data, int mode)
{
    Sample *s = (Sample *)smp;
    int n, i, schans = (mode & M_STEREO) ? 2 : 1;
    short *tmp;
    if (!s || !data) return 0;
    n = s->frames;
    tmp = malloc((size_t)n * s->chans * sizeof(short));
    if (!tmp) return 0;
    for (i = 0; i < n * s->chans; i++) {
        int si = schans == s->chans ? i : (schans == 2 ? i * 2 : i / 2), x;   /* mono<->stereo if they differ */
        if (mode & M_8BITS) {
            unsigned char b = ((unsigned char *)data)[si];
            x = (mode & M_SIGNED) ? ((signed char)b) << 8 : ((int)b - 128) << 8;
        } else x = ((short *)data)[si];
        tmp[i] = (short)x;
    }
    EnterCriticalSection(&g_mix);                /* a voice may be playing it */
    memcpy(s->pcm, tmp, (size_t)n * s->chans * sizeof(short));
    LeaveCriticalSection(&g_mix);
    free(tmp);
    return 1;
}
static int __stdcall s_Sample_SetMode(int smp, int mode)
{
    Sample *s = (Sample *)smp;
    if (!s) return 0;
    EnterCriticalSection(&g_mix);
    s->loopmode = mode & 7;
    LeaveCriticalSection(&g_mix);
    return 1;
}
static int __stdcall s_Sample_SetLoopPoints(int smp, int a, int b)
{
    Sample *s = (Sample *)smp;
    if (!s) return 0;
    EnterCriticalSection(&g_mix);
    s->ls = clamp(a, 0, s->frames - 1);
    s->le = clamp(b, 0, s->frames - 1);
    LeaveCriticalSection(&g_mix);
    return 1;
}

static int __stdcall s_Stream_Create(int cb, int bytes, int mode, int rate, int user)
{
    Stream *s;
    if (!cb || bytes <= 0) return 0;
    s = calloc(1, sizeof *s);
    if (!s) return 0;
    s->cb = (StreamCb)cb; s->user = (void *)user;
    s->chans = (mode & M_STEREO) ? 2 : 1;
    s->bits = (mode & M_8BITS) ? 8 : 16;
    s->bpf_src = s->chans * s->bits / 8;
    s->chunk = bytes / s->bpf_src * s->bpf_src;
    if (s->chunk <= 0) s->chunk = s->bpf_src;
    s->rate = rate > 0 ? rate : OUT_RATE;
    s->cap = 2 * s->chunk / s->bpf_src;
    s->ring = calloc((size_t)s->cap * s->chans, sizeof(short));
    s->tmp = calloc(1, (size_t)s->chunk);
    s->channel = -1;
    if (!s->ring || !s->tmp) { free(s->ring); free(s->tmp); free(s); return 0; }
    EnterCriticalSection(&g_mix);
    s->next = g_streams; g_streams = s;
    LeaveCriticalSection(&g_mix);
    InterlockedIncrement(&st_streams);
    LOG("Stream_Create(cb %08X, %d bytes, mode 0x%X, %d Hz, user %08X) = %p", cb, bytes, mode, rate, user, (void *)s);
    return (int)s;
}
static int __stdcall s_Stream_Play(int ch, int stream, int dsp, int paused)
{
    Stream *s = (Stream *)stream;
    signed char r;
    int ret = -1;
    (void)dsp;
    if (!s) return -1;
    GAME_STREAM_LOCK();                          /* the game already holds it here (0x6DE0E0); recursive */
    EnterCriticalSection(&g_mix);
    if (s->dead) { LeaveCriticalSection(&g_mix); GAME_STREAM_UNLOCK(); return -1; }
    if (s->channel >= 0 && g_v[s->channel].st == s) v_stop(&g_v[s->channel]);
    s->state = 0; s->rd = 0; s->fill = 0; s->ended = 0;
    LeaveCriticalSection(&g_mix);
    r = s->cb(s, s->tmp, s->chunk, s->user);     /* prebuffer on the caller's thread, as FMOD did */
    InterlockedIncrement(&st_stream_cbs);
    EnterCriticalSection(&g_mix);
    ring_write(s, s->tmp, s->chunk);
    s->ended = !r;
    if (ch == -1) { int i; for (i = 0; i < g_nch; i++) if (!g_v[i].active) { ch = i; break; } }
    if (ch >= 0 && ch < g_nch) {
        Voice *v = &g_v[ch];
        v_stop(v);
        v->st = s;
        v_start(v, 255, 128, s->rate, (paused & 0xff) != 0);
        s->channel = ch;
        s->state = 1;
        ret = ch;
    }
    LeaveCriticalSection(&g_mix);
    GAME_STREAM_UNLOCK();
    InterlockedIncrement(&c_streamplay);
    SetEvent(g_feed_ev);
    return ret;
}
static int __stdcall s_Stream_Stop(int stream)
{
    Stream *s = (Stream *)stream;
    if (!s) return 0;
    GAME_STREAM_LOCK();                          /* no callback for it can be running once we hold this */
    EnterCriticalSection(&g_mix);
    if (s->channel >= 0 && g_v[s->channel].st == s) v_stop(&g_v[s->channel]);
    s->state = 2; s->channel = -1; s->rd = s->fill = 0;
    LeaveCriticalSection(&g_mix);
    GAME_STREAM_UNLOCK();
    InterlockedIncrement(&c_streamstop);
    return 1;
}
static int __stdcall s_Stream_Close(int stream)
{
    Stream *s = (Stream *)stream;
    if (!s) return 0;
    GAME_STREAM_LOCK();
    EnterCriticalSection(&g_mix);
    if (s->channel >= 0 && g_v[s->channel].st == s) v_stop(&g_v[s->channel]);
    s->state = 2; s->channel = -1; s->dead = 1;  /* the feeder thread frees it */
    LeaveCriticalSection(&g_mix);
    GAME_STREAM_UNLOCK();
    InterlockedIncrement(&c_streamclose);
    SetEvent(g_feed_ev);
    return 1;
}

/* ------------------------------------------------------------------ hook list */
static const struct { const char *name; unsigned addr; void *fn; } HK[] = {
    {"SetOutput", 0x6d4070, s_SetOutput}, {"Init", 0x6d4430, s_Init}, {"Close", 0x6d4990, s_Close},
    {"SetSFXMasterVolume", 0x6d4270, s_SetSFXMasterVolume}, {"GetMaxChannels", 0x6d4d20, s_GetMaxChannels},
    {"GetMixer", 0x6d4be0, s_GetMixer},
    {"DSP_Create", 0x6dcb50, s_DSP_Create}, {"DSP_Free", 0x6dcbb0, s_DSP_Free}, {"DSP_SetActive", 0x6dcd10, s_DSP_SetActive},
    {"DSP_GetSFXUnit", 0x6dcd60, s_DSP_GetSFXUnit}, {"DSP_GetBufferLength", 0x6dcdc0, s_DSP_GetBufferLength},
    {"DSP_MixBuffers", 0x6dcde0, s_DSP_MixBuffers},
    {"PlaySoundEx", 0x6e24e0, s_PlaySoundEx}, {"StopSound", 0x6e2860, s_StopSound}, {"SetFrequency", 0x6e2c60, s_SetFrequency},
    {"SetLevels", 0x6e2d50, s_SetLevels}, {"SetVolume", 0x6e2e60, s_SetVolume}, {"SetPan", 0x6e3070, s_SetPan},
    {"SetPaused", 0x6e3430, s_SetPaused}, {"IsPlaying", 0x6e3890, s_IsPlaying},
    {"Sample_Alloc", 0x6e41d0, s_Sample_Alloc}, {"Sample_Free", 0x6e4340, s_Sample_Free}, {"Sample_Upload", 0x6e4720, s_Sample_Upload},
    {"Sample_SetMode", 0x6e4890, s_Sample_SetMode}, {"Sample_SetLoopPoints", 0x6e4910, s_Sample_SetLoopPoints},
    {"Stream_Create", 0x6e6a70, s_Stream_Create}, {"Stream_Play", 0x6e70d0, s_Stream_Play},
    {"Stream_Stop", 0x6e7250, s_Stream_Stop}, {"Stream_Close", 0x6e7350, s_Stream_Close},
};
#define NHK ((int)(sizeof HK / sizeof HK[0]))

static void summary(const char *why)
{
    LOG("---- summary (%s) ----", why);
    LOG("  device %s, ticks %ld (dropped %ld), worst tick %.2f ms, worst mix %.3f ms, biggest callback %ld frames",
        g_have_device ? "on" : "none", st_ticks, st_dropped_ticks, st_tick_ms_max, st_mix_ms_max, st_cb_frames_max);
    LOG("  voices: most at once %ld, PlaySoundEx %ld, StopSound %ld, samples alive %ld",
        st_maxvoices, c_play, c_stop, st_samples);
    LOG("  streams: created %ld, played %ld, stopped %ld, closed %ld, callbacks %ld, underrun blocks %ld, "
        "worst feeder wait for stream lock %.2f ms, worst fill %.2f ms",
        st_streams, c_streamplay, c_streamstop, c_streamclose, st_stream_cbs, st_underrun, st_feed_lock_ms_max, st_feed_ms_max);
    LOG("  DSP_Free %ld", c_dspfree);
    hook_report_counters();
    log_flush();
}

static int enabled_by_ini(void)
{
    char path[MAX_PATH], *p;
    GetModuleFileNameA(NULL, path, MAX_PATH);
    p = strrchr(path, '\\');
    if (p) strcpy(p + 1, "bo2audio.ini"); else strcpy(path, "bo2audio.ini");
    return GetPrivateProfileIntA("bo2audio", "enable", 1, path) != 0;
}

void backend_start(void)
{
    int i, bad;
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    g_qpf = f.QuadPart;
    log_open();
    InitializeCriticalSectionAndSpinCount(&g_mix, 1000);
    LOG("bo2audio backend (FMOD 3 replaced by miniaudio %s). exe %s", MA_VERSION_STRING, GetCommandLineA());
    if (!enabled_by_ini()) { LOG("disabled by bo2audio.ini: FMOD runs untouched"); log_flush(); return; }
    bad = hook_verify();
    if (bad) { LOG("%d hook sites differ from the vanilla exe: not hooking anything, FMOD runs untouched", bad); log_flush(); return; }
    for (i = 0; i < NHK; i++)
        if (!hook_install(HK[i].addr, HK[i].fn)) LOG("hook failed at %06X (%s)", HK[i].addr, HK[i].name);
    hook_install_counters();     /* flags any call into FMOD code we did not replace */
    LOG("hooks installed: %d FSOUND functions replaced", NHK);
    log_flush();
}

void backend_stop(void)
{
    summary("exit");
    log_close();
}

#ifdef SELFTEST
/* Test-only hooks for tests/harness_backend.c */
__declspec(dllexport) int __cdecl bo2audio_have_device(void) { return g_have_device; }
__declspec(dllexport) long __cdecl bo2audio_ticks(void) { return st_ticks; }
__declspec(dllexport) long __cdecl bo2audio_underruns(void) { return st_underrun; }
__declspec(dllexport) void __cdecl bo2audio_summary(void) { summary("test"); }
__declspec(dllexport) void __cdecl bo2audio_render(float *out, int frames) { data_cb(NULL, out, NULL, (ma_uint32)frames); }
#endif
