#ifndef TM_WINDOWS_SERVICES_H
#define TM_WINDOWS_SERVICES_H
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>
#ifdef __cplusplus
extern "C" {
#endif
uint32_t tm_credential_read(const wchar_t *account, unsigned char **data, uint32_t *length, int *missing);
uint32_t tm_credential_write(const wchar_t *account, const unsigned char *data, uint32_t length);
uint32_t tm_credential_delete(const wchar_t *account);
void tm_credential_free(unsigned char *data, uint32_t length);
typedef void (*TMLifecycleCallback)(int sleeping);
int tm_lifecycle_start(TMLifecycleCallback callback);
void tm_lifecycle_stop(void);
int tm_low_power_mode(void);
int tm_open_url(const wchar_t *url);
void tm_notify(const wchar_t *title, const wchar_t *body);
int tm_startup_enabled(const wchar_t *executable);
int tm_startup_set(const wchar_t *executable, int enabled);
typedef struct TMCLI TMCLI;
TMCLI *tm_cli_start(const wchar_t *binary, wchar_t *command_line, const wchar_t *directory, int terminal);
int tm_cli_read(TMCLI *process, unsigned char *data, uint32_t capacity);
int tm_cli_write(TMCLI *process, const unsigned char *data, uint32_t length);
int tm_cli_exited(TMCLI *process, uint32_t *exit_code);
void tm_cli_destroy(TMCLI *process);
#ifdef __cplusplus
}
#endif
#endif
