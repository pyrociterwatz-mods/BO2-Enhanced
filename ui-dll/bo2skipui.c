/* bo2skipui.dll - Blood Omen 2 Cutscene Skip: a turning ring on the black screen of a long skip.
 *
 * Loaded once by the mod's exe (V42, from its frame hook, LoadLibraryA("bo2skipui.dll")). On load it waits for the game's
 * Direct3D 8 device ([0x00920230], created at 0x55F77C / 0x55F9BB) and replaces Present (vtable slot 15) in the device's
 * vtable. Each frame, before the real Present, it reads the mod's skip phase ([0x00AAFF10]: 1 fading out, 2 fast-forward,
 * 3 fading back). Once the screen has been black (phase 1 or 2) for RING_DELAY seconds and the skip is still in phase 2,
 * it fades in the game's own HUD texture ui/hud/metal_ring (read from the player's DATA\Code.big, so no game art ships with
 * the mod) in the lower right corner and turns it; it fades out when the skip ends.
 *
 * Drawing happens on the back buffer after the game's frame is complete: own BeginScene/EndScene, render target set to the
 * back buffer, all device state captured in a state block and restored afterwards. Any failure turns the ring off for the
 * session; the game's Present is always called. Messages go to OutputDebugString (the launcher's log shows them).
 *
 * Autosave (V43, user 2026-11-18: "At each checkpoint an auto save would be great. Use the ring to show a save happening"):
 * the exe calls the export BO2UiTick once per frame from its frame hook (main thread, inside the world update). While the
 * game is in play (top-level state 11) it finds Kain (0x4A5290), his behaviour object ([Kain+0x124], vtable 0x841D84, the
 * class whose debug display prints "Last checkpoint: %s:%s" from +0x214 level / +0x218 checkpoint, both string handles,
 * text at +6). When that checkpoint changes on the same behaviour object, an autosave is queued; it runs when no skip,
 * cinematic or scripted scene is active and at least AUTOSAVE_GAP seconds after the previous one. The save is the pause
 * menu's own call (as 0x55BAD0 does it): device = 0x6A5240(ecx=[0xA74C98], 0), slot name = wide string "Save 49"
 * (0x6AEB50), 0x51C370(ecx=[0x91EEE0] save manager, device, &name), then name freed (0x6AECA0) and device released.
 * Save 49 is the last slot the game's load list accepts (Save 00-49); the player's own saves are never touched.
 *
 * Enemy health bar across level loads (0.9.10, crash 2026-11-20 after the charm-vampire arena): the HUD's enemy bar reads
 * [GameUI+0x8C] (GameUI = [0x91EF00]), a pointer into the enemy creature's health {max, value}, set only by the script
 * call sethudenemy (0x54F710 -> 0x52CF90) and cleared by sethudenemy(null), by LimboBehavior (0x44D560 -> 0x52CF90(0)) and
 * by GameUI's menu/in-game state change (0x52CDB0). A level load (0x4B0860/0x4B08D0/0x4AD310/0x4AD670, all calling the
 * loader 0x4AF550) sets the HUD to kain mode but leaves +0x8C alone, so if it still points at a creature of the level
 * being unloaded, the next enemy-bar update (HUDEnemyHealthBar slot 64, 0x539540) reads freed memory. DllMain retargets
 * the four CALLs to 0x4AF550 to LoadHook, which clears +0x8C (as 0x52CDB0 does) and then runs the loader unchanged.
 *
 * 0.9.11 (user 2026-11-20: name the autosave slot "auto save"; keep the black over the moment Kain is seen after a chapter
 * change): the save lists show slot 49 as "Autosave: <place>" (HookSaveLabel), and after skipping a chapter's last scene the
 * picture stays black until the next level's loader starts (WatchChapterSkip, DrawBlack, released in ClearEnemyOnLoad).
 * BO2UiTick logs every change of the pointer, so a log shows when the game sets and clears it.
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <d3d8.h>
#include <math.h>
#include <string.h>
#include <stdio.h>

#define DEVICE_SLOT   ((IDirect3DDevice8 * volatile *)0x00920230)
#define MOD_PHASE     (*(volatile LONG *)0x00AAFF10)
#define PRESENT_INDEX 15

#define RING_DELAY    3.0    /* seconds of black before the ring shows */
#define RING_TURN     1.6    /* seconds per turn */
#define FADE_IN       0.35   /* seconds */
#define FADE_OUT      0.25
#define RING_SIZE     0.085  /* of the back buffer height */
#define RING_MARGIN   0.06   /* of the back buffer height, from the right and bottom edges */
#define RING_NAME     "ui/hud/metal_ring"

typedef HRESULT (WINAPI *Present_t)(IDirect3DDevice8 *, const RECT *, const RECT *, HWND, const RGNDATA *);

static Present_t g_realPresent;
static volatile LONG g_disabled;          /* 1: something failed, never draw again */

static BYTE *g_dxt;                        /* level 0 of the ring, as stored (DXT blocks) */
static UINT g_w, g_h, g_dxtLen, g_blockBytes;
static D3DFORMAT g_fmt;
static int g_loadTried;

static IDirect3DDevice8 *g_texDev;
static IDirect3DTexture8 *g_tex;

static LARGE_INTEGER g_freq, g_last;
static double g_blackT, g_alpha, g_angle;
static int g_shownLogged;
static volatile LONG g_saveRingUntil;      /* GetTickCount value until which the ring shows for an autosave */
static volatile LONG g_saveRingOn;         /* 1 once an autosave has set g_saveRingUntil */
static volatile LONG g_holdOn;             /* chapter change: screen held black until the next level loads */
static volatile LONG g_holdStart;          /* GetTickCount when the hold began */
static double g_holdAlpha;                 /* black overlay opacity (1 while held, fading after the time-out) */

static void Msg(const char *fmt, ...)
{
    char b[300];
    va_list a;
    va_start(a, fmt);
    lstrcpyA(b, "bo2skipui: ");
    vsnprintf(b + 11, sizeof b - 13, fmt, a);
    va_end(a);
    lstrcatA(b, "\n");
    OutputDebugStringA(b);
}

/* ---- the ring texture from DATA\Code.big (goefile: symlist of names, then chunks tag[8] size u32 ...) ---- */
static int LoadRing(void)
{
    char path[MAX_PATH];
    HANDLE f;
    DWORD size, got;
    BYTE *d;
    UINT ssz, count, i, off;
    const char **names = NULL;
    int ok = 0;

    GetModuleFileNameA(NULL, path, MAX_PATH);
    { char *s = strrchr(path, '\\'); if (s) s[1] = 0; else path[0] = 0; }
    lstrcatA(path, "DATA\\Code.big");
    f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) { Msg("cannot open DATA\\Code.big"); return 0; }
    size = GetFileSize(f, NULL);
    if (size < 0x40 || size > 64u << 20) { CloseHandle(f); Msg("Code.big has an unexpected size"); return 0; }
    d = (BYTE *)HeapAlloc(GetProcessHeap(), 0, size);
    if (!d) { CloseHandle(f); return 0; }
    if (!ReadFile(f, d, size, &got, NULL) || got != size) { CloseHandle(f); HeapFree(GetProcessHeap(), 0, d); Msg("cannot read Code.big"); return 0; }
    CloseHandle(f);

    if (memcmp(d, "goefile\0", 8) || memcmp(d + 0x10, "symlist\0", 8)) { Msg("Code.big is not a goefile"); goto done; }
    ssz = *(UINT *)(d + 0x18);
    if (ssz < 0x14 || 0x10 + ssz > size) goto done;
    count = *(UINT *)(d + 0x20);
    if (count > 1000000) goto done;
    names = (const char **)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, (count + 1) * sizeof *names);
    if (!names) goto done;
    {
        UINT p = 0x24, end = 0x10 + ssz;
        for (i = 0; i < count && p < end; i++) {
            names[i] = (const char *)d + p;
            while (p < end && d[p]) p++;
            p++;
        }
        if (i < count || p > end) { Msg("Code.big name table is damaged"); goto done; }
    }
    for (off = 0x10 + ssz; off + 12 <= size; ) {
        UINT csize = *(UINT *)(d + off + 8);
        if (csize < 12 || off + csize > size) break;
        if (!memcmp(d + off, "texture\0", 8) && csize > 20) {
            UINT idx = *(UINT *)(d + off + 16);
            if ((idx >> 16) == 0 && (idx & 0xFFFF) < count && !strcmp(names[idx & 0xFFFF], RING_NAME)) {
                UINT p, w, h, bw, bh;
                for (p = off + 20; p + 128 <= off + csize; p++)
                    if (!memcmp(d + p, "DDS |", 5)) break;
                if (p + 128 > off + csize) { Msg("%s has no DDS header", RING_NAME); goto done; }
                h = *(UINT *)(d + p + 12);
                w = *(UINT *)(d + p + 16);
                if (!(*(UINT *)(d + p + 80) & 4)) { Msg("%s is not compressed", RING_NAME); goto done; }
                if (!memcmp(d + p + 84, "DXT1", 4)) { g_fmt = D3DFMT_DXT1; g_blockBytes = 8; }
                else if (!memcmp(d + p + 84, "DXT3", 4)) { g_fmt = D3DFMT_DXT3; g_blockBytes = 16; }
                else if (!memcmp(d + p + 84, "DXT5", 4)) { g_fmt = D3DFMT_DXT5; g_blockBytes = 16; }
                else { Msg("%s has an unknown format", RING_NAME); goto done; }
                if (w < 4 || h < 4 || w > 4096 || h > 4096) goto done;
                bw = (w + 3) / 4; bh = (h + 3) / 4;
                g_dxtLen = bw * bh * g_blockBytes;
                if (p + 128 + g_dxtLen > off + csize) { Msg("%s is truncated", RING_NAME); goto done; }
                g_dxt = (BYTE *)HeapAlloc(GetProcessHeap(), 0, g_dxtLen);
                if (!g_dxt) goto done;
                memcpy(g_dxt, d + p + 128, g_dxtLen);
                g_w = w; g_h = h;
                ok = 1;
                Msg("ring texture %ux%u read from Code.big", w, h);
                goto done;
            }
        }
        off += csize;
    }
    Msg("%s not found in Code.big", RING_NAME);
done:
    if (names) HeapFree(GetProcessHeap(), 0, names);
    HeapFree(GetProcessHeap(), 0, d);
    return ok;
}

static int MakeTexture(IDirect3DDevice8 *dev)
{
    D3DLOCKED_RECT lr;
    UINT row, rowBytes = ((g_w + 3) / 4) * g_blockBytes, rows = (g_h + 3) / 4;
    IDirect3DTexture8 *t = NULL;
    if (FAILED(IDirect3DDevice8_CreateTexture(dev, g_w, g_h, 1, 0, g_fmt, D3DPOOL_MANAGED, &t)) || !t) {
        Msg("CreateTexture failed");
        return 0;
    }
    if (FAILED(IDirect3DTexture8_LockRect(t, 0, &lr, NULL, 0))) {
        IDirect3DTexture8_Release(t);
        Msg("LockRect failed");
        return 0;
    }
    for (row = 0; row < rows; row++)
        memcpy((BYTE *)lr.pBits + row * lr.Pitch, g_dxt + row * rowBytes, rowBytes);
    IDirect3DTexture8_UnlockRect(t, 0);
    g_tex = t;
    g_texDev = dev;
    return 1;
}

typedef struct { float x, y, z, rhw; DWORD color; float u, v; } Vtx;
#define VTX_FVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1)

static void DrawRing(IDirect3DDevice8 *dev)
{
    IDirect3DSurface8 *bb = NULL, *oldRT = NULL, *oldZ = NULL;
    D3DSURFACE_DESC sd;
    DWORD sb = 0;
    Vtx v[4];
    float cx, cy, r, c, s;
    DWORD col;
    int i;
    static const float cu[4] = { 0, 1, 1, 0 }, cv[4] = { 0, 0, 1, 1 };
    static const float px[4] = { -1, 1, 1, -1 }, py[4] = { -1, -1, 1, 1 };

    if (IDirect3DDevice8_TestCooperativeLevel(dev) != D3D_OK) return;
    if (FAILED(IDirect3DDevice8_GetBackBuffer(dev, 0, D3DBACKBUFFER_TYPE_MONO, &bb)) || !bb) return;
    if (FAILED(IDirect3DSurface8_GetDesc(bb, &sd))) { IDirect3DSurface8_Release(bb); return; }
    if (FAILED(IDirect3DDevice8_CreateStateBlock(dev, D3DSBT_ALL, &sb))) { IDirect3DSurface8_Release(bb); return; }
    IDirect3DDevice8_GetRenderTarget(dev, &oldRT);
    if (FAILED(IDirect3DDevice8_GetDepthStencilSurface(dev, &oldZ))) oldZ = NULL;

    if (SUCCEEDED(IDirect3DDevice8_SetRenderTarget(dev, bb, NULL)) &&
        SUCCEEDED(IDirect3DDevice8_BeginScene(dev))) {
        D3DVIEWPORT8 vp = { 0, 0, sd.Width, sd.Height, 0.0f, 1.0f };
        IDirect3DDevice8_SetViewport(dev, &vp);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ZENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ZWRITEENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ALPHATESTENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ALPHABLENDENABLE, TRUE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_FOGENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_STENCILENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_FILLMODE, D3DFILL_SOLID);
        IDirect3DDevice8_SetTexture(dev, 0, (IDirect3DBaseTexture8 *)g_tex);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLOROP, D3DTOP_MODULATE2X);   /* the ring is dark metal */
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_MINFILTER, D3DTEXF_LINEAR);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_MAGFILTER, D3DTEXF_LINEAR);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_MIPFILTER, D3DTEXF_NONE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ADDRESSU, D3DTADDRESS_CLAMP);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ADDRESSV, D3DTADDRESS_CLAMP);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_TEXCOORDINDEX, 0);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_TEXTURETRANSFORMFLAGS, D3DTTFF_DISABLE);
        IDirect3DDevice8_SetTextureStageState(dev, 1, D3DTSS_COLOROP, D3DTOP_DISABLE);
        IDirect3DDevice8_SetTextureStageState(dev, 1, D3DTSS_ALPHAOP, D3DTOP_DISABLE);
        IDirect3DDevice8_SetVertexShader(dev, VTX_FVF);

        r = (float)sd.Height * (float)RING_SIZE * 0.5f;
        cx = (float)sd.Width - (float)sd.Height * (float)RING_MARGIN - r;
        cy = (float)sd.Height - (float)sd.Height * (float)RING_MARGIN - r;
        c = (float)cos(g_angle) * r;
        s = (float)sin(g_angle) * r;
        col = ((DWORD)(g_alpha * 255.0 + 0.5) << 24) | 0x00FFFFFF;
        for (i = 0; i < 4; i++) {
            v[i].x = cx + px[i] * c - py[i] * s - 0.5f;
            v[i].y = cy + px[i] * s + py[i] * c - 0.5f;
            v[i].z = 0.0f; v[i].rhw = 1.0f;
            v[i].color = col;
            v[i].u = cu[i]; v[i].v = cv[i];
        }
        IDirect3DDevice8_DrawPrimitiveUP(dev, D3DPT_TRIANGLEFAN, 2, v, sizeof(Vtx));
        IDirect3DDevice8_EndScene(dev);
    }
    if (oldRT) IDirect3DDevice8_SetRenderTarget(dev, oldRT, oldZ);
    IDirect3DDevice8_ApplyStateBlock(dev, sb);
    IDirect3DDevice8_DeleteStateBlock(dev, sb);
    if (oldZ) IDirect3DSurface8_Release(oldZ);
    if (oldRT) IDirect3DSurface8_Release(oldRT);
    IDirect3DSurface8_Release(bb);
}

/* A full-screen black quad at the given opacity, drawn like the ring (own scene on the back buffer, state block). */
static void DrawBlack(IDirect3DDevice8 *dev, double alpha)
{
    IDirect3DSurface8 *bb = NULL, *oldRT = NULL, *oldZ = NULL;
    D3DSURFACE_DESC sd;
    DWORD sb = 0, col;
    Vtx v[4];
    int i;
    if (IDirect3DDevice8_TestCooperativeLevel(dev) != D3D_OK) return;
    if (FAILED(IDirect3DDevice8_GetBackBuffer(dev, 0, D3DBACKBUFFER_TYPE_MONO, &bb)) || !bb) return;
    if (FAILED(IDirect3DSurface8_GetDesc(bb, &sd))) { IDirect3DSurface8_Release(bb); return; }
    if (FAILED(IDirect3DDevice8_CreateStateBlock(dev, D3DSBT_ALL, &sb))) { IDirect3DSurface8_Release(bb); return; }
    IDirect3DDevice8_GetRenderTarget(dev, &oldRT);
    if (FAILED(IDirect3DDevice8_GetDepthStencilSurface(dev, &oldZ))) oldZ = NULL;
    if (SUCCEEDED(IDirect3DDevice8_SetRenderTarget(dev, bb, NULL)) &&
        SUCCEEDED(IDirect3DDevice8_BeginScene(dev))) {
        D3DVIEWPORT8 vp = { 0, 0, sd.Width, sd.Height, 0.0f, 1.0f };
        IDirect3DDevice8_SetViewport(dev, &vp);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ZENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ZWRITEENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ALPHATESTENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_ALPHABLENDENABLE, TRUE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_SRCBLEND, D3DBLEND_SRCALPHA);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_FOGENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_STENCILENABLE, FALSE);
        IDirect3DDevice8_SetRenderState(dev, D3DRS_FILLMODE, D3DFILL_SOLID);
        IDirect3DDevice8_SetTexture(dev, 0, NULL);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLOROP, D3DTOP_SELECTARG1);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_COLORARG1, D3DTA_DIFFUSE);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ALPHAOP, D3DTOP_SELECTARG1);
        IDirect3DDevice8_SetTextureStageState(dev, 0, D3DTSS_ALPHAARG1, D3DTA_DIFFUSE);
        IDirect3DDevice8_SetTextureStageState(dev, 1, D3DTSS_COLOROP, D3DTOP_DISABLE);
        IDirect3DDevice8_SetTextureStageState(dev, 1, D3DTSS_ALPHAOP, D3DTOP_DISABLE);
        IDirect3DDevice8_SetVertexShader(dev, VTX_FVF);
        col = (DWORD)(alpha * 255.0 + 0.5) << 24;           /* black */
        for (i = 0; i < 4; i++) {
            v[i].x = (i == 1 || i == 2) ? (float)sd.Width - 0.5f : -0.5f;
            v[i].y = (i >= 2) ? (float)sd.Height - 0.5f : -0.5f;
            v[i].z = 0.0f; v[i].rhw = 1.0f; v[i].color = col; v[i].u = 0; v[i].v = 0;
        }
        IDirect3DDevice8_DrawPrimitiveUP(dev, D3DPT_TRIANGLEFAN, 2, v, sizeof(Vtx));
        IDirect3DDevice8_EndScene(dev);
    }
    if (oldRT) IDirect3DDevice8_SetRenderTarget(dev, oldRT, oldZ);
    IDirect3DDevice8_ApplyStateBlock(dev, sb);
    IDirect3DDevice8_DeleteStateBlock(dev, sb);
    if (oldZ) IDirect3DSurface8_Release(oldZ);
    if (oldRT) IDirect3DSurface8_Release(oldRT);
    IDirect3DSurface8_Release(bb);
}

#define HOLD_MAX_MS   3000    /* chapter change: longest black hold waiting for the level load */
#define HOLD_FADE     0.3     /* seconds to fade the hold out if no load came */

static HRESULT WINAPI HookPresent(IDirect3DDevice8 *dev, const RECT *src, const RECT *dst, HWND wnd, const RGNDATA *dirty)
{
    if (g_holdOn) {                                         /* chapter change after a skip: keep the picture black */
        DWORD el = GetTickCount() - (DWORD)g_holdStart;
        if (MOD_PHASE == 1 || MOD_PHASE == 2) g_holdOn = 0; /* a new skip took over */
        else if (el < HOLD_MAX_MS) g_holdAlpha = 1.0;
        else {
            g_holdAlpha = 1.0 - (double)(el - HOLD_MAX_MS) / (HOLD_FADE * 1000.0);
            if (g_holdAlpha <= 0) { g_holdOn = 0; Msg("black hold timed out (no level load)"); }
        }
        if (g_holdOn) DrawBlack(dev, g_holdAlpha);
    }
    if (!g_disabled) {
        LARGE_INTEGER now;
        double dt;
        LONG phase = MOD_PHASE;
        double target;
        QueryPerformanceCounter(&now);
        dt = g_last.QuadPart ? (double)(now.QuadPart - g_last.QuadPart) / (double)g_freq.QuadPart : 0.0;
        if (dt < 0 || dt > 0.25) dt = 0.25;
        g_last = now;
        if (phase == 1 || phase == 2) g_blackT += dt; else g_blackT = 0;
        target = (phase == 2 && g_blackT >= RING_DELAY) ? 1.0 : 0.0;
        if (g_saveRingOn && (LONG)(GetTickCount() - (DWORD)g_saveRingUntil) < 0) target = 1.0;   /* an autosave just ran */
        if (target > g_alpha) { g_alpha += dt / FADE_IN; if (g_alpha > 1) g_alpha = 1; }
        else if (target < g_alpha) { g_alpha -= dt / FADE_OUT; if (g_alpha < 0) g_alpha = 0; }
        if (g_alpha > 0) {
            g_angle += dt * 6.283185307 / RING_TURN;
            if (g_angle > 6.283185307) g_angle -= 6.283185307;
            if (!g_loadTried) {
                g_loadTried = 1;
                if (!LoadRing()) { InterlockedExchange(&g_disabled, 1); }
            }
            if (!g_disabled && g_texDev != dev) {
                g_tex = NULL;                     /* a texture of an earlier device is not released: that device may be gone */
                if (!MakeTexture(dev)) InterlockedExchange(&g_disabled, 1);
            }
            if (!g_disabled && g_tex) {
                if (!g_shownLogged) { g_shownLogged = 1; Msg("ring shown"); }
                DrawRing(dev);
            }
        } else {
            g_shownLogged = 0;
        }
    }
    return g_realPresent(dev, src, dst, wnd, dirty);
}

/* The exe this DLL was written for: the mod's patched bo2_actual.exe (frame hook jump at 0x72EDE9, the device pointer
 * pushed at 0x55F74B for CreateDevice). Anything else: do nothing. */
static int RightExe(void)
{
    static const BYTE createDev[5] = { 0x68, 0x30, 0x02, 0x92, 0x00 };
    BYTE *base = (BYTE *)GetModuleHandleA(NULL);
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    IMAGE_NT_HEADERS32 *nt;
    if (base != (BYTE *)0x00400000 || dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS32 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.SizeOfImage < 0x6B0000) return 0;
    if (*(BYTE *)0x0072EDE9 != 0xE9) return 0;
    if (memcmp((void *)0x0055F74B, createDev, 5)) return 0;
    return 1;
}

static DWORD WINAPI HookThread(LPVOID p)
{
    int i;
    (void)p;
    for (i = 0; i < 1200; i++) {                  /* up to 2 minutes for the device */
        IDirect3DDevice8 *dev = *DEVICE_SLOT;
        if (dev) {
            void **vt = *(void ***)dev;
            DWORD old;
            if (vt[PRESENT_INDEX] == (void *)HookPresent) return 0;
            if (!VirtualProtect(&vt[PRESENT_INDEX], sizeof(void *), PAGE_EXECUTE_READWRITE, &old)) {
                Msg("cannot unprotect the device vtable");
                return 0;
            }
            g_realPresent = (Present_t)vt[PRESENT_INDEX];
            InterlockedExchange((volatile LONG *)&vt[PRESENT_INDEX], (LONG)(LONG_PTR)HookPresent);
            VirtualProtect(&vt[PRESENT_INDEX], sizeof(void *), old, &old);
            Msg("ready (Present hooked)");
            return 0;
        }
        Sleep(100);
    }
    Msg("no Direct3D device found");
    return 0;
}

/* ---- autosave at checkpoints ---- */
#define APP_SLOT        (*(BYTE * volatile *)0x00A83664)   /* top-level app object; state at +0x18 (11 = in game) */
#define MOD_PROMPTTICK  (*(volatile LONG *)0x00AAFF28)     /* > 0 while a cinematic ticks */
#define MOD_CINESEEN    (*(volatile LONG *)0x00AAFF90)     /* > 0 for a few frames after a cinematic ticked */
#define MOD_SCRIPTON    (*(volatile LONG *)0x00AAFF9C)     /* 1 during a scripted (non-cinematic) scene */
#define SAVE_MANAGER    (*(void * volatile *)0x0091EEE0)
#define DEVICE_OWNER    (*(void * volatile *)0x00A74C98)
#define KAIN_BEH_VTABLE 0x00841D84
#define AUTOSAVE_SLOT   "Save 49"
#define AUTOSAVE_GAP    2000        /* ms between autosaves at least (0.9.9: was 10 s, which held a save past its checkpoint) */
#define SAVE_RING_MS    1800        /* how long the ring shows for an autosave */

typedef struct { int len; void *buf; } GameWStr;
typedef void *(__attribute__((cdecl)) *GetKain_t)(void);
typedef void *(__attribute__((thiscall)) *GetDevice_t)(void *owner, int index);
typedef void (__attribute__((thiscall)) *WStrFromA_t)(GameWStr *self, const char *src, int len);
typedef void (__attribute__((thiscall)) *WStrFree_t)(GameWStr *self);
typedef int (__attribute__((thiscall)) *SaveGame_t)(void *mgr, void *device, GameWStr *slot);
typedef void (__attribute__((thiscall)) *Release_t)(void *self);

static void *g_lastBeh, *g_lastLvl, *g_lastCp;
static int g_pending, g_behWarned, g_saves;
static DWORD g_lastSaveTick;
static int g_haveSaved;
static int g_rightExe;                     /* set by DllMain: this is the mod's game exe */
static int g_hookMsg;
static int g_enemyHooks;
static void WatchEnemy(void);

static void HandleText(void *h, char *out, int n)
{
    int i;
    const char *s = h ? (const char *)h + 6 : NULL;
    out[0] = 0;
    if (!s || IsBadReadPtr(s, 1)) return;
    for (i = 0; i < n - 1 && !IsBadReadPtr(s + i, 1) && s[i]; i++) out[i] = s[i];
    out[i] = 0;
}

static void DoAutosave(void)
{
    void *mgr = SAVE_MANAGER, *owner = DEVICE_OWNER, *dev;
    GameWStr name = { 0, NULL };
    int ok;
    if (!mgr || !owner) { Msg("autosave skipped: no save manager"); return; }
    dev = ((GetDevice_t)0x006A5240)(owner, 0);
    if (!dev) { Msg("autosave skipped: no save device"); return; }
    ((LONG *)dev)[1]++;                                    /* hold a reference, as the menu does */
    ((WStrFromA_t)0x006AEB50)(&name, AUTOSAVE_SLOT, 7);
    ok = ((SaveGame_t)0x0051C370)(mgr, dev, &name);
    ((WStrFree_t)0x006AECA0)(&name);
    if (--((LONG *)dev)[1] == 0) ((Release_t)(*(void ***)dev)[1])(dev);
    g_saves++;
    Msg("autosave %d to %s: %s", g_saves, AUTOSAVE_SLOT, ok ? "saved" : "FAILED");
    if (ok) {
        g_saveRingUntil = (LONG)(GetTickCount() + SAVE_RING_MS);
        g_saveRingOn = 1;
    }
}

/* ---- chapter changes after a skip: keep the screen black until the next level loads ----
 * Logs 2026-11-17..20: after skipping a chapter's last scene the fade back ends 0.7-1.3 s before the next level's load
 * screen, so Kain is seen standing for about a second. For the scenes below (and every chapter-scene abort, DevSkip), the
 * picture is held black from the end of the fast-forward until the level loader starts (LoadHook), at most HOLD_MAX_MS.
 * A scene is told by its cinematic object name and the level of Kain's current checkpoint (names are reused across areas). */
#define MOD_LATCH    (*(BYTE * volatile *)0x00AAFF00)
#define MOD_DEVSKIP  (*(volatile LONG *)0x00AAFF70)
static const struct { const char *level, *cine; } g_chapterEnds[] = {
    { "slums/sl08",                          "bo2cinematic004" },   /* -> Smuggler's Den */
    { "bossrooms/charmvampirearena/cvarena", "bo2cinematic003" },   /* -> the Keep */
    { "wharves/regionfiles/wh13",            "bo2cinematic002" },   /* -> Hylden City (confirmed 0.9.12, log 20261121-061418) */
    { "canyons/cy07",                        "bo2cinematic002" },   /* -> Eternal Prison (0.9.12, log 20261120-152751) */
    { "bossrooms/madvampirearena/mvarena",   "m_cin_end" },         /* -> the Device (0.9.13, log 20261121-061418) */
    { "device/dv09",                         "bo2cinematic001" },   /* -> the Wharves (0.9.13, same log) */
};
static LONG g_prevPhase;
static int g_holdArmed;

static void CinematicName(BYTE *cin, char *out, int n)
{
    BYTE *obj, *str;
    out[0] = 0;
    if (!cin || IsBadReadPtr(cin + 0x2C, 4)) return;
    obj = *(BYTE **)(cin + 0x2C);
    if (!obj || IsBadReadPtr(obj + 0xB0, 4)) return;
    str = *(BYTE **)(obj + 0xB0);
    if (!str) return;
    HandleText(str, out, n);
}

static void WatchChapterSkip(void)
{
    LONG phase = MOD_PHASE;
    if (phase != g_prevPhase) {
        if (g_prevPhase == 0 && phase == 1) {                 /* a skip starts: is it a chapter's last scene? */
            char name[64], lvl[96];
            size_t i;
            g_holdArmed = 0;
            CinematicName(MOD_LATCH, name, sizeof name);
            HandleText(g_lastLvl, lvl, sizeof lvl);
            for (i = 0; i < sizeof g_chapterEnds / sizeof g_chapterEnds[0]; i++)
                if (!strcmp(name, g_chapterEnds[i].cine) && !strcmp(lvl, g_chapterEnds[i].level)) g_holdArmed = 1;
            if (g_holdArmed) Msg("skip of %s in %s: chapter end, the screen stays black into the next area", name, lvl);
        }
        if (phase == 2 && MOD_DEVSKIP && !g_holdArmed) {     /* the game's own abort: only the three chapter scenes */
            g_holdArmed = 1;
            Msg("chapter scene abort: the screen stays black into the next area");
        }
        if (g_prevPhase == 2 && phase == 3 && g_holdArmed) {  /* the fast-forward is over: hold instead of fading back */
            g_holdStart = (LONG)GetTickCount();
            g_holdAlpha = 1.0;
            g_holdOn = 1;
        }
        if (phase == 0 || phase == 1) { if (phase == 0) g_holdArmed = 0; }
        g_prevPhase = phase;
    }
}

__declspec(dllexport) void __cdecl BO2UiTick(void)
{
    BYTE *app = APP_SLOT, *kain, *beh;
    void *lvl, *cp;
    if (!g_rightExe) return;
    if (!g_hookMsg) { g_hookMsg = 1; Msg("level loads clear the HUD enemy bar (%d of 4 calls hooked)", g_enemyHooks); }
    if (!app || *(LONG *)(app + 0x18) != 11) { g_lastBeh = NULL; g_pending = 0; g_prevPhase = 0; return; }
    WatchChapterSkip();
    WatchEnemy();
    kain = (BYTE *)((GetKain_t)0x004A5290)();
    if (!kain) return;
    beh = *(BYTE **)(kain + 0x124);
    if (!beh || *(DWORD *)beh != KAIN_BEH_VTABLE) {
        if (!g_behWarned) {
            int i;
            g_behWarned = 1;
            Msg("checkpoint object not at Kain+0x124 (vtable %08lX); looking further", beh ? *(DWORD *)beh : 0UL);
            for (i = 0; i < 0x800; i += 4) {
                BYTE *p = *(BYTE **)(kain + i);
                if (p && !IsBadReadPtr(p, 4) && *(DWORD *)p == KAIN_BEH_VTABLE) { Msg("  found at Kain+0x%X", i); break; }
            }
        }
        return;
    }
    lvl = *(void **)(beh + 0x214);
    cp = *(void **)(beh + 0x218);
    if (beh != g_lastBeh) {                               /* new level or a loaded game: start from here, no save */
        char a[64], b[64];
        HandleText(lvl, a, sizeof a); HandleText(cp, b, sizeof b);
        Msg("checkpoint at start: %s:%s", a, b);
        g_lastBeh = beh; g_lastLvl = lvl; g_lastCp = cp; g_pending = 0;
        return;
    }
    if (lvl != g_lastLvl || cp != g_lastCp) {
        char a[64], b[64];
        HandleText(lvl, a, sizeof a); HandleText(cp, b, sizeof b);
        Msg("checkpoint reached: %s:%s", a, b);
        g_lastLvl = lvl; g_lastCp = cp; g_pending = 1;
    }
    if (g_pending && MOD_PHASE == 0 && MOD_PROMPTTICK <= 0 && MOD_CINESEEN <= 0 && MOD_SCRIPTON == 0 &&
        (!g_haveSaved || GetTickCount() - g_lastSaveTick >= AUTOSAVE_GAP)) {
        g_pending = 0;
        g_haveSaved = 1;
        g_lastSaveTick = GetTickCount();
        DoAutosave();
    }
}

/* ---- enemy health bar cleared on every level load (see the header) ---- */
#define GAMEUI_SLOT   (*(BYTE * volatile *)0x0091EF00)
#define HUD_VTABLE    0x00869000                      /* [GameUI+0x58] is the HUD; same check as the exe's HudRead */
#define LEVEL_LOADER  0x004AF550
static const DWORD g_loaderCalls[4] = { 0x004B08B5, 0x004B095B, 0x004AD52E, 0x004AD81B };
static void *g_lastEnemy;                  /* last [GameUI+0x8C] seen by BO2UiTick */

static BYTE *GameUI(void)
{
    BYTE *ui = GAMEUI_SLOT, *hud;
    if (!ui) return NULL;
    hud = *(BYTE **)(ui + 0x58);
    if (!hud || *(DWORD *)hud != HUD_VTABLE) return NULL;
    return ui;
}

/* Called by LoadHook on the game's main thread just before the level loader runs. */
void ClearEnemyOnLoad(void) __asm__("bo2_clear_enemy_on_load") __attribute__((used));
void ClearEnemyOnLoad(void)
{
    if (g_holdOn) { g_holdOn = 0; Msg("level load: black hold ends, the load screen takes over"); }
    {
    BYTE *ui = GameUI();
    void *e;
    if (!ui) return;
    e = *(void **)(ui + 0x8C);
    if (!e) return;
    *(void **)(ui + 0x8C) = NULL;
    g_lastEnemy = NULL;
    Msg("level load: HUD enemy bar cleared (was 0x%08lX, HUD mode %ld)", (unsigned long)(DWORD_PTR)e,
        *(LONG *)(*(BYTE **)(ui + 0x58) + 0x104));
    }
}

/* Entered by the retargeted CALL with the loader's cdecl arguments and return address on the stack: keep every register
 * and flag, clear the bar, then continue into the loader as if called directly (it returns to the original caller). */
__attribute__((naked)) static void LoadHook(void)
{
    __asm__ volatile(
        "pushal\n\t"
        "pushfl\n\t"
        "call bo2_clear_enemy_on_load\n\t"
        "popfl\n\t"
        "popal\n\t"
        "pushl $0x004AF550\n\t"
        "ret\n\t");
}

static void HookLevelLoads(void)
{
    int i;
    for (i = 0; i < 4; i++) {
        BYTE *site = (BYTE *)g_loaderCalls[i];
        DWORD old, rel;
        if (site[0] != 0xE8 || (DWORD)(site + 5) + *(DWORD *)(site + 1) != LEVEL_LOADER) {
            Msg("level-load call at %08lX not as expected; left alone", (unsigned long)g_loaderCalls[i]);
            continue;
        }
        if (!VirtualProtect(site + 1, 4, PAGE_EXECUTE_READWRITE, &old)) continue;
        rel = (DWORD)(DWORD_PTR)LoadHook - (DWORD)(site + 5);
        *(DWORD *)(site + 1) = rel;
        VirtualProtect(site + 1, 4, old, &old);
        g_enemyHooks++;
    }
    FlushInstructionCache(GetCurrentProcess(), (void *)0x004AD000, 0x4000);
}

/* ---- the autosave's name in the load / save lists ----
 * The list label of a save is built in 0x51AF60 with sprintf(buf, 0x50, "@c%s %d: %s@n%s %s", "Game", slot + 1, place,
 * date, time) (format 0x8FB78C pushed at 0x51B1CC; esi = the list entry, slot number at +0x10). For slot 49 (the
 * autosave) the push is replaced by a format that drops "Game" and the number: "@cautosave%.0s: %.*s@n%s %s" (%.0s eats
 * "Game"; %.*s takes slot + 1 = 50 as the place's maximum length). */
#define LABEL_PUSH   0x0051B1CC
#define LABEL_FORMAT 0x008FB78C
const char g_autoFmt[] __asm__("bo2_auto_fmt") __attribute__((used)) = "@cautosave%.0s: %.*s@n%s %s";

__attribute__((naked)) static void LabelFormat(void)
{
    __asm__ volatile(
        "pushl (%esp)\n\t"                  /* return address copied down; its old slot becomes the pushed format */
        "movl $0x008FB78C, 4(%esp)\n\t"
        "cmpl $49, 0x10(%esi)\n\t"
        "jne 1f\n\t"
        "movl $bo2_auto_fmt, 4(%esp)\n\t"
        "1:\n\t"
        "ret\n\t");
}

static void HookSaveLabel(void)
{
    static const BYTE want[5] = { 0x68, 0x8C, 0xB7, 0x8F, 0x00 };   /* push 0x8FB78C */
    BYTE *site = (BYTE *)LABEL_PUSH;
    DWORD old, rel;
    if (memcmp(site, want, 5)) { Msg("save label code not as expected; autosave keeps its number"); return; }
    if (!VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &old)) return;
    rel = (DWORD)(DWORD_PTR)LabelFormat - (DWORD)(site + 5);
    *(DWORD *)(site + 1) = rel;
    site[0] = 0xE8;                                           /* call LabelFormat (same 5 bytes) */
    VirtualProtect(site, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, 5);
}

static void WatchEnemy(void)
{
    BYTE *ui = GameUI();
    void *e;
    if (!ui) return;
    e = *(void **)(ui + 0x8C);
    if (e != g_lastEnemy) {
        Msg("HUD enemy bar 0x%08lX (was 0x%08lX)", (unsigned long)(DWORD_PTR)e, (unsigned long)(DWORD_PTR)g_lastEnemy);
        g_lastEnemy = e;
    }
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r)
{
    (void)r;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE t;
        DisableThreadLibraryCalls(h);
        if (!RightExe()) { OutputDebugStringA("bo2skipui: not the mod's game exe, doing nothing\n"); return TRUE; }
        g_rightExe = 1;
        HookLevelLoads();
        HookSaveLabel();
        QueryPerformanceFrequency(&g_freq);
        t = CreateThread(NULL, 0, HookThread, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
