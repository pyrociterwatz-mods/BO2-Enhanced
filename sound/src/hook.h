#pragma once
#include <windows.h>

/* Verifies every site in hook_table.h against the running exe. Returns the number of mismatches (0 = all good). */
int hook_verify(void);
/* Installs a jmp at site `addr` to `target`. Returns the trampoline that runs the original function, or NULL. */
void *hook_install(unsigned addr, void *target);
/* Installs counting hooks on every untyped site in the table (records call counts and caller addresses). */
void hook_install_counters(void);
void hook_report_counters(void);
/* Executable scratch memory for small generated thunks. */
unsigned char *exec_alloc(int size);
