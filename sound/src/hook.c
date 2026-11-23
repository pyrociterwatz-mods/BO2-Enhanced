/* Inline jmp hooks on the FMOD 3 entry points listed in hook_table.h (generated from the vanilla exe). */
#include "hook.h"
#include "log.h"
#include "hook_table.h"

static unsigned char *g_pool;
static int g_pool_used;
#define POOL_SIZE (64 * 1024)

unsigned char *exec_alloc(int size)
{
    unsigned char *p;
    if (!g_pool) {
        g_pool = VirtualAlloc(NULL, POOL_SIZE, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (!g_pool) return NULL;
    }
    size = (size + 15) & ~15;
    if (g_pool_used + size > POOL_SIZE) return NULL;
    p = g_pool + g_pool_used;
    g_pool_used += size;
    return p;
}

static const HookSite *find_site(unsigned addr)
{
    int i;
    for (i = 0; i < NSITES; i++)
        if (g_sites[i].addr == addr) return &g_sites[i];
    return NULL;
}

int hook_verify(void)
{
    int i, bad = 0;
    for (i = 0; i < NSITES; i++) {
        const HookSite *s = &g_sites[i];
        if (IsBadReadPtr((void *)s->addr, s->len) || memcmp((void *)s->addr, s->bytes, s->len) != 0) {
            LOG("verify: bytes at %06X do not match the vanilla exe", s->addr);
            bad++;
        }
    }
    return bad;
}

static void put_jmp(unsigned char *at, const void *to)
{
    at[0] = 0xE9;
    *(int *)(at + 1) = (int)((const unsigned char *)to - (at + 5));
}

void *hook_install(unsigned addr, void *target)
{
    const HookSite *s = find_site(addr);
    unsigned char *tr, *site = (unsigned char *)addr;
    DWORD old;
    int i;
    if (!s) { LOG("hook: %06X not in table", addr); return NULL; }
    tr = exec_alloc(s->len + 5);
    if (!tr) return NULL;
    memcpy(tr, s->bytes, s->len);
    for (i = 0; i < s->nrel; i++) {           /* re-aim relative call/jmp operands */
        int off = s->rel[i];
        int rel = *(int *)(s->bytes + off);
        unsigned dest = addr + off + 4 + rel;
        *(int *)(tr + off) = (int)(dest - ((unsigned)tr + off + 4));
    }
    put_jmp(tr + s->len, site + s->len);
    if (!VirtualProtect(site, s->len, PAGE_EXECUTE_READWRITE, &old)) return NULL;
    put_jmp(site, target);
    for (i = 5; i < s->len; i++) site[i] = 0x90;
    VirtualProtect(site, s->len, old, &old);
    FlushInstructionCache(GetCurrentProcess(), site, s->len);
    return tr;
}

/* ---- counting hooks for FMOD functions the game is not expected to call directly ---- */
#define MAXCALLERS 12
typedef struct { unsigned addr; volatile LONG calls; volatile LONG callers[MAXCALLERS]; volatile LONG ncalls[MAXCALLERS]; } Counter;
static Counter g_counters[NSITES];

static void __cdecl record_call(int idx, unsigned ret)
{
    Counter *c = &g_counters[idx];
    int i;
    InterlockedIncrement(&c->calls);
    for (i = 0; i < MAXCALLERS; i++) {
        LONG cur = c->callers[i];
        if (cur == (LONG)ret) { InterlockedIncrement(&c->ncalls[i]); return; }
        if (cur == 0 && InterlockedCompareExchange(&c->callers[i], (LONG)ret, 0) == 0) {
            InterlockedIncrement(&c->ncalls[i]);
            return;
        }
        if (c->callers[i] == (LONG)ret) { InterlockedIncrement(&c->ncalls[i]); return; }
    }
}

void hook_install_counters(void)
{
    int i;
    for (i = 0; i < NSITES; i++) {
        unsigned char *stub, *p, *tr;
        if (g_sites[i].typed) continue;
        g_counters[i].addr = g_sites[i].addr;
        stub = exec_alloc(32);
        if (!stub) return;
        p = stub;
        *p++ = 0x9C;                                   /* pushfd */
        *p++ = 0x60;                                   /* pushad */
        *p++ = 0xFF; *p++ = 0x74; *p++ = 0x24; *p++ = 0x24; /* push [esp+24h] = return address */
        *p++ = 0x68; *(int *)p = i; p += 4;            /* push idx */
        *p = 0xE8; *(int *)(p + 1) = (int)((unsigned char *)record_call - (p + 5)); p += 5;
        *p++ = 0x83; *p++ = 0xC4; *p++ = 0x08;         /* add esp, 8 */
        *p++ = 0x61;                                   /* popad */
        *p++ = 0x9D;                                   /* popfd */
        tr = hook_install(g_sites[i].addr, stub);
        if (!tr) { LOG("counter hook failed at %06X", g_sites[i].addr); continue; }
        put_jmp(p, tr);
    }
}

void hook_report_counters(void)
{
    int i, j;
    for (i = 0; i < NSITES; i++) {
        Counter *c = &g_counters[i];
        if (g_sites[i].typed || !c->calls) continue;
        LOG("  other FMOD fn %06X: %ld calls", c->addr, c->calls);
        for (j = 0; j < MAXCALLERS && c->callers[j]; j++)
            LOG("      from %08lX x%ld", c->callers[j], c->ncalls[j]);
    }
}
