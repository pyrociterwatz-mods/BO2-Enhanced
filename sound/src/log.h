#pragma once
#include <windows.h>

void log_open(void);
void log_close(void);
void log_flush(void);
void logf_(const char *fmt, ...);
double log_now(void);          /* seconds since log_open */
#define LOG(...) logf_(__VA_ARGS__)
