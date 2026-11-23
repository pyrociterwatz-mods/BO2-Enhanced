/* dinput.dll proxy: forwards DirectInputCreateEx to the system DLL and starts the audio code
   (the FMOD replacement, or with -DLOGGER the logging-only build). */
#include <windows.h>

#ifdef LOGGER
void fsound_log_start(void);
void fsound_log_stop(void);
#define AUDIO_START fsound_log_start
#define AUDIO_STOP fsound_log_stop
#else
void backend_start(void);
void backend_stop(void);
#define AUDIO_START backend_start
#define AUDIO_STOP backend_stop
#endif

typedef HRESULT (WINAPI *PFN_DICreateEx)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
static PFN_DICreateEx g_real;

HRESULT WINAPI proxy_DirectInputCreateEx(HINSTANCE h, DWORD ver, REFIID riid, LPVOID *out, LPUNKNOWN outer)
{
    if (!g_real) {
        char path[MAX_PATH];
        HMODULE m;
        GetSystemDirectoryA(path, MAX_PATH);   /* SysWOW64 for this 32-bit process */
        lstrcatA(path, "\\dinput.dll");
        m = LoadLibraryA(path);
        if (m) g_real = (PFN_DICreateEx)GetProcAddress(m, "DirectInputCreateEx");
        if (!g_real) return E_FAIL;
    }
    return g_real(h, ver, riid, out, outer);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        AUDIO_START();
    } else if (reason == DLL_PROCESS_DETACH) {
        AUDIO_STOP();
    }
    (void)reserved;
    return TRUE;
}
