#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <powrprof.h>
#include <shellapi.h>
#include <stdlib.h>
#include <wchar.h>
#include "WindowsServicesNative.h"


static HPOWERNOTIFY power_registration;
static PVOID volatile lifecycle_callback;
static ULONG CALLBACK power_event(PVOID context, ULONG type, PVOID setting) {
    (void)context; (void)setting;
    TMLifecycleCallback callback = (TMLifecycleCallback)InterlockedCompareExchangePointer(&lifecycle_callback, NULL, NULL);
    if (callback && type == PBT_APMSUSPEND) callback(1);
    if (callback && (type == PBT_APMRESUMEAUTOMATIC || type == PBT_APMRESUMESUSPEND)) callback(0);
    return ERROR_SUCCESS;
}
int tm_lifecycle_start(TMLifecycleCallback callback) {
    if (power_registration) return 1;
    InterlockedExchangePointer(&lifecycle_callback, (PVOID)callback);
    DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS parameters = {power_event, NULL};
    DWORD error = PowerRegisterSuspendResumeNotification(DEVICE_NOTIFY_CALLBACK, &parameters, &power_registration);
    if (error != ERROR_SUCCESS) { InterlockedExchangePointer(&lifecycle_callback, NULL); power_registration = NULL; return 0; }
    return 1;
}
void tm_lifecycle_stop(void) {
    if (power_registration) PowerUnregisterSuspendResumeNotification(power_registration);
    power_registration = NULL; InterlockedExchangePointer(&lifecycle_callback, NULL);
}
int tm_low_power_mode(void) {
    SYSTEM_POWER_STATUS status;
    return GetSystemPowerStatus(&status) && status.SystemStatusFlag == 1;
}
int tm_open_url(const wchar_t *url) {
    return (INT_PTR)ShellExecuteW(NULL, L"open", url, NULL, NULL, SW_SHOWNORMAL) > 32;
}
void tm_notify(const wchar_t *title, const wchar_t *body) {
    MessageBoxW(NULL, body, title, MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
}

struct TMCLI {
    HANDLE process, thread, job, input, output;
    HPCON console;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes;
};
TMCLI *tm_cli_start(const wchar_t *binary, wchar_t *command_line, const wchar_t *directory, int terminal) {
    TMCLI *child = calloc(1, sizeof(TMCLI));
    if (!child) return NULL;
    HANDLE console_input = NULL, console_output = NULL, null_handle = INVALID_HANDLE_VALUE;
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    SECURITY_ATTRIBUTES security = {sizeof(security), NULL, TRUE};
    SIZE_T attribute_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    child->attributes = malloc(attribute_size);
    if (!child->attributes) goto fail;
    if (!InitializeProcThreadAttributeList(child->attributes, 1, 0, &attribute_size)) {
        free(child->attributes); child->attributes = NULL; goto fail;
    }
    startup.lpAttributeList = child->attributes;
    if (terminal) {
        /* Otherwise Windows duplicates a redirected parent's standard handles,
           bypassing ConPTY even with bInheritHandles=FALSE (terminal#11276). */
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        if (!CreatePipe(&console_input, &child->input, NULL, 0) ||
            !CreatePipe(&child->output, &console_output, NULL, 0)) goto fail;
        COORD size = {120, 40};
        if (FAILED(CreatePseudoConsole(size, console_input, console_output, 0, &child->console))) goto fail;
        CloseHandle(console_input); console_input = NULL;
        CloseHandle(console_output); console_output = NULL;
        if (!UpdateProcThreadAttribute(child->attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                       child->console, sizeof(child->console), NULL, NULL)) goto fail;
    } else {
        null_handle = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                                  FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
        if (null_handle == INVALID_HANDLE_VALUE) goto fail;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = null_handle;
        startup.StartupInfo.hStdOutput = null_handle;
        startup.StartupInfo.hStdError = null_handle;
        if (!UpdateProcThreadAttribute(child->attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                       &null_handle, sizeof(null_handle), NULL, NULL)) goto fail;
    }
    child->job = CreateJobObjectW(NULL, NULL);
    if (!child->job) goto fail;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(child->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) goto fail;
    PROCESS_INFORMATION info = {0};
    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED;
    if (!terminal) flags |= CREATE_NO_WINDOW;
    if (!CreateProcessW(binary, command_line, NULL, NULL, !terminal, flags,
                        NULL, directory, &startup.StartupInfo, &info)) goto fail;
    child->process = info.hProcess; child->thread = info.hThread;
    if (!AssignProcessToJobObject(child->job, child->process)) goto fail;
    if (ResumeThread(child->thread) == (DWORD)-1) goto fail;
    CloseHandle(child->thread); child->thread = NULL;
    if (null_handle != INVALID_HANDLE_VALUE) CloseHandle(null_handle);
    return child;
fail:
    if (console_input) CloseHandle(console_input);
    if (console_output) CloseHandle(console_output);
    if (null_handle != INVALID_HANDLE_VALUE) CloseHandle(null_handle);
    tm_cli_destroy(child);
    return NULL;
}
int tm_cli_read(TMCLI *child, unsigned char *data, uint32_t capacity) {
    if (!child->output) return 0;
    DWORD available = 0, received = 0;
    if (!PeekNamedPipe(child->output, NULL, 0, NULL, &available, NULL)) return -1;
    if (!available) return 0;
    if (!ReadFile(child->output, data, min(available, capacity), &received, NULL)) return -1;
    return (int)received;
}
int tm_cli_write(TMCLI *child, const unsigned char *data, uint32_t length) {
    DWORD sent = 0;
    return child->input && WriteFile(child->input, data, length, &sent, NULL) && sent == length;
}
int tm_cli_exited(TMCLI *child, uint32_t *exit_code) {
    if (WaitForSingleObject(child->process, 0) != WAIT_OBJECT_0) return 0;
    return GetExitCodeProcess(child->process, (LPDWORD)exit_code) != 0;
}
void tm_cli_destroy(TMCLI *child) {
    if (!child) return;
    if (child->process) TerminateProcess(child->process, ERROR_CANCELLED);
    if (child->job) { TerminateJobObject(child->job, ERROR_CANCELLED); CloseHandle(child->job); }
    if (child->process) { WaitForSingleObject(child->process, 2000); CloseHandle(child->process); }
    if (child->thread) CloseHandle(child->thread);
    if (child->input) CloseHandle(child->input);
    if (child->output) CloseHandle(child->output);
    if (child->console) ClosePseudoConsole(child->console);
    if (child->attributes) { DeleteProcThreadAttributeList(child->attributes); free(child->attributes); }
    free(child);
}

static const wchar_t startup_key[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
static wchar_t *startup_command(const wchar_t *executable) {
    if (!executable || wcschr(executable, L'"')) { SetLastError(ERROR_INVALID_PARAMETER); return NULL; }
    size_t length = wcslen(executable);
    if (length > 32760) { SetLastError(ERROR_BAD_LENGTH); return NULL; }
    wchar_t *command = calloc(length + 3, sizeof(wchar_t));
    if (!command) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    command[0] = L'"';
    memcpy(command + 1, executable, length * sizeof(wchar_t));
    command[length + 1] = L'"';
    return command;
}
int tm_startup_enabled(const wchar_t *executable) {
    wchar_t *expected = startup_command(executable);
    if (!expected) return 0;
    HKEY key;
    LSTATUS error = RegOpenKeyExW(HKEY_CURRENT_USER, startup_key, 0, KEY_QUERY_VALUE, &key);
    if (error != ERROR_SUCCESS) { free(expected); SetLastError(error); return 0; }
    DWORD type = 0, size = 0;
    error = RegQueryValueExW(key, L"ToastMonitor", NULL, &type, NULL, &size);
    int enabled = 0;
    if (error == ERROR_SUCCESS && type == REG_SZ && size >= sizeof(wchar_t) && size <= 65536) {
        wchar_t *actual = calloc(size / sizeof(wchar_t) + 1, sizeof(wchar_t));
        if (!actual) error = ERROR_NOT_ENOUGH_MEMORY;
        else {
            error = RegQueryValueExW(key, L"ToastMonitor", NULL, &type, (LPBYTE)actual, &size);
            if (error == ERROR_SUCCESS) enabled = type == REG_SZ && _wcsicmp(actual, expected) == 0;
            free(actual);
        }
    }
    RegCloseKey(key);
    free(expected);
    SetLastError(error);
    return enabled;
}
int tm_startup_set(const wchar_t *executable, int enabled) {
    wchar_t *command = startup_command(executable);
    if (!command) return 0;
    HKEY key;
    LSTATUS error = RegCreateKeyExW(HKEY_CURRENT_USER, startup_key, 0, NULL, 0,
                                  KEY_SET_VALUE, NULL, &key, NULL);
    if (error == ERROR_SUCCESS) {
        if (enabled) error = RegSetValueExW(key, L"ToastMonitor", 0, REG_SZ,
                                          (const BYTE *)command, (DWORD)((wcslen(command) + 1) * sizeof(wchar_t)));
        else {
            error = RegDeleteValueW(key, L"ToastMonitor");
            if (error == ERROR_FILE_NOT_FOUND) error = ERROR_SUCCESS;
        }
        RegCloseKey(key);
    }
    free(command);
    SetLastError(error);
    return error == ERROR_SUCCESS;
}
