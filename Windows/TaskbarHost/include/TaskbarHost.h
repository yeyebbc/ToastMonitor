#ifndef TM_TASKBAR_HOST_H
#define TM_TASKBAR_HOST_H

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TMTaskbarHost TMTaskbarHost;
typedef void (*TMTaskbarAction)(void *context, int action);

enum {
    TM_TASKBAR_USAGE = 1,
    TM_TASKBAR_DASHBOARD = 2,
    TM_TASKBAR_SETTINGS = 3,
    TM_TASKBAR_QUIT = 4
};

/* Call all functions on the creating WinUI UI thread. No private message loop
   is started. Keep context alive until destroy; callbacks run on this thread.
   Only the primary, horizontal Explorer taskbar is supported. */
TMTaskbarHost *tm_taskbar_create(TMTaskbarAction action, void *context);
/* A failed start retains the host and retries after Explorer/layout changes.
   last_error is a Win32 code (ERROR_NOT_SUPPORTED for unsupported layout,
   ERROR_INSUFFICIENT_BUFFER when no non-overlapping placement is available). */
int tm_taskbar_start(TMTaskbarHost *host);
void tm_taskbar_set_text(TMTaskbarHost *host, const wchar_t *text, const wchar_t *tooltip);
/* Visible readout bounds in screen physical pixels, including negative origins.
   Returns zero when detached, hidden (including auto-hide), or placement failed. */
int tm_taskbar_bounds(TMTaskbarHost *host, int *x, int *y, int *width, int *height);
int tm_taskbar_last_error(TMTaskbarHost *host);
void tm_taskbar_destroy(TMTaskbarHost *host);

#ifdef __cplusplus
}
#endif
#endif
