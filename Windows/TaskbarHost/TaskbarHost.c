#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <objbase.h>
#include <oleauto.h>
#include <UIAutomationClient.h>
#include <stdlib.h>
#include <wchar.h>
#include "include/TaskbarHost.h"

#define TM_TIMER 1
#define TM_ACTION (WM_APP + 37)
#define TM_LAYOUT (WM_APP + 38)
#define TM_POLL_MS 2000
#define TM_MAX_TEXT 512
#define TM_MAX_RECTS 512

struct TMTaskbarHost {
    DWORD thread;
    HWND control, window, tooltip, taskbar, parent, tasklist;
    TMTaskbarAction action;
    void *context;
    UINT taskbarCreated;
    DWORD error;
    BOOL started, reserved, comOwned, light;
    BOOL layoutPending;
    HWINEVENTHOOK layoutHook;
    RECT original, owned;
    HFONT font;
    UINT dpi;
    wchar_t text[TM_MAX_TEXT], tip[TM_MAX_TEXT];
    IUIAutomation *automation;
};

static LRESULT CALLBACK tm_window_proc(HWND, UINT, WPARAM, LPARAM);
static int tm_refresh(TMTaskbarHost *host);
static const wchar_t tm_control_class[] = L"ToastMonitor.Taskbar.Control";
static const wchar_t tm_readout_class[] = L"ToastMonitor.Taskbar.Readout";

static BOOL CALLBACK tm_layout_window(HWND window, LPARAM changedWindow) {
    wchar_t className[64];
    TMTaskbarHost *host;
    HWND changed = (HWND)changedWindow;
    if (!GetClassNameW(window, className, 64) || wcscmp(className, tm_control_class)) return TRUE;
    host = (TMTaskbarHost *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (!host || !host->started || host->layoutPending) return TRUE;
    if (changed == host->taskbar || changed == host->tasklist || changed == host->parent ||
        (!host->tasklist && GetAncestor(changed, GA_ROOT) == host->taskbar)) {
        host->layoutPending = PostMessageW(window, TM_LAYOUT, 0, 0);
    }
    return TRUE;
}

static void CALLBACK tm_layout_event(HWINEVENTHOOK hook, DWORD event, HWND window,
                                     LONG object, LONG child, DWORD thread, DWORD time) {
    (void)hook; (void)event; (void)child; (void)thread; (void)time;
    if (window && object == OBJID_WINDOW)
        EnumThreadWindows(GetCurrentThreadId(), tm_layout_window, (LPARAM)window);
}

static DWORD tm_error(void) {
    DWORD error = GetLastError();
    return error ? error : ERROR_GEN_FAILURE;
}

static BOOL tm_thread(TMTaskbarHost *host) {
    if (!host) return FALSE;
    if (host->thread == GetCurrentThreadId()) return TRUE;
    SetLastError(ERROR_INVALID_THREAD_ID);
    return FALSE;
}

static void tm_copy(wchar_t *destination, const wchar_t *source) {
    if (!source) source = L"";
    wcsncpy_s(destination, TM_MAX_TEXT, source, _TRUNCATE);
}

static RECT tm_child_rect(HWND child, HWND parent) {
    RECT rect = {0};
    GetWindowRect(child, &rect);
    MapWindowPoints(NULL, parent, (POINT *)&rect, 2);
    return rect;
}

static void tm_restore(TMTaskbarHost *host) {
    /* Explorer may have relaid out this band independently. Never put an old
       rectangle back over an externally changed layout. */
    if (host->reserved && IsWindow(host->tasklist) && IsWindow(host->parent)) {
        RECT current = tm_child_rect(host->tasklist, host->parent);
        if (EqualRect(&current, &host->owned)) {
            SetWindowPos(host->tasklist, NULL, host->original.left, host->original.top,
                host->original.right - host->original.left,
                host->original.bottom - host->original.top,
                SWP_NOACTIVATE | SWP_NOZORDER);
        }
    }
    host->reserved = FALSE;
}

static void tm_detach(TMTaskbarHost *host) {
    if (host->tooltip) DestroyWindow(host->tooltip);
    host->tooltip = NULL;
    if (IsWindow(host->window)) DestroyWindow(host->window);
    host->window = NULL;
    tm_restore(host);
    host->taskbar = host->parent = host->tasklist = NULL;
}

static void tm_theme(TMTaskbarHost *host) {
    DWORD value = 0, bytes = sizeof(value);
    BOOL light = RegGetValueW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        L"SystemUsesLightTheme", RRF_RT_REG_DWORD, NULL, &value, &bytes) == ERROR_SUCCESS && value != 0;
    if (host->light != light) {
        host->light = light;
        if (host->window) InvalidateRect(host->window, NULL, FALSE);
    }
}

static int tm_font(TMTaskbarHost *host, UINT dpi) {
    NONCLIENTMETRICSW metrics;
    HFONT font;
    if (host->font && host->dpi == dpi) return 1;
    ZeroMemory(&metrics, sizeof(metrics));
    metrics.cbSize = sizeof(metrics);
    if (!SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS, sizeof(metrics), &metrics, 0, dpi)) {
        host->error = tm_error();
        return 0;
    }
    font = CreateFontIndirectW(&metrics.lfMessageFont);
    if (!font) { host->error = tm_error(); return 0; }
    if (host->font) DeleteObject(host->font);
    host->font = font;
    host->dpi = dpi;
    if (host->window) InvalidateRect(host->window, NULL, FALSE);
    return 1;
}

static int tm_width(TMTaskbarHost *host) {
    HDC dc = GetDC(host->control);
    HGDIOBJ old;
    SIZE size = {0};
    if (!dc) { host->error = tm_error(); return 0; }
    old = SelectObject(dc, host->font);
    if (!GetTextExtentPoint32W(dc, host->text, (int)wcslen(host->text), &size)) {
        host->error = tm_error();
        SelectObject(dc, old);
        ReleaseDC(host->control, dc);
        return 0;
    }
    SelectObject(dc, old);
    ReleaseDC(host->control, dc);
    return max(MulDiv(112, host->dpi, 96), size.cx + MulDiv(24, host->dpi, 96));
}

static void tm_paint(TMTaskbarHost *host, HWND window) {
    PAINTSTRUCT paint;
    RECT rect;
    HDC dc = BeginPaint(window, &paint);
    HDC buffer = CreateCompatibleDC(dc);
    HBITMAP bitmap = NULL;
    HGDIOBJ oldBitmap = NULL, oldFont;
    HDC target = dc;
    BOOL highContrast = FALSE;
    HIGHCONTRASTW contrast = {sizeof(contrast), 0, NULL};
    COLORREF background, foreground;
    HBRUSH brush;
    GetClientRect(window, &rect);
    if (buffer && rect.right > 0 && rect.bottom > 0) {
        bitmap = CreateCompatibleBitmap(dc, rect.right, rect.bottom);
        if (bitmap) { oldBitmap = SelectObject(buffer, bitmap); target = buffer; }
    }
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0))
        highContrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
    background = highContrast ? GetSysColor(COLOR_WINDOW) : host->light ? RGB(243,243,243) : RGB(32,32,32);
    foreground = highContrast ? GetSysColor(COLOR_WINDOWTEXT) : host->light ? RGB(20,20,20) : RGB(245,245,245);
    brush = CreateSolidBrush(background);
    FillRect(target, &rect, brush);
    DeleteObject(brush);
    SetBkMode(target, TRANSPARENT);
    SetTextColor(target, foreground);
    oldFont = SelectObject(target, host->font);
    DrawTextW(target, host->text, -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    SelectObject(target, oldFont);
    if (GetFocus() == window) {
        InflateRect(&rect, -2, -2);
        DrawFocusRect(target, &rect);
    }
    if (bitmap) {
        GetClientRect(window, &rect);
        BitBlt(dc, 0, 0, rect.right, rect.bottom, buffer, 0, 0, SRCCOPY);
        SelectObject(buffer, oldBitmap);
        DeleteObject(bitmap);
    }
    if (buffer) DeleteDC(buffer);
    EndPaint(window, &paint);
}

static void tm_menu(TMTaskbarHost *host, HWND window, LPARAM location) {
    HMENU menu = CreatePopupMenu();
    POINT point = {GET_X_LPARAM(location), GET_Y_LPARAM(location)};
    UINT selected;
    if (!menu) { host->error = tm_error(); return; }
    if (point.x == -1 && point.y == -1) {
        RECT rect;
        GetWindowRect(window, &rect);
        point.x = rect.left;
        point.y = rect.top;
    }
    AppendMenuW(menu, MF_STRING, TM_TASKBAR_USAGE, L"Usage");
    AppendMenuW(menu, MF_STRING, TM_TASKBAR_DASHBOARD, L"Dashboard");
    AppendMenuW(menu, MF_STRING, TM_TASKBAR_SETTINGS, L"Settings");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, TM_TASKBAR_QUIT, L"Quit ToastMonitor");
    SetForegroundWindow(host->control);
    selected = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
        point.x, point.y, host->control, NULL);
    DestroyMenu(menu);
    if (selected) PostMessageW(host->control, TM_ACTION, selected, 0);
}

static BOOL tm_register_classes(void) {
    WNDCLASSEXW cls;
    ZeroMemory(&cls, sizeof(cls));
    cls.cbSize = sizeof(cls);
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpfnWndProc = tm_window_proc;
    cls.hCursor = LoadCursorW(NULL, IDC_ARROW);
    cls.lpszClassName = tm_control_class;
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return FALSE;
    cls.lpszClassName = tm_readout_class;
    cls.style = CS_DBLCLKS;
    return RegisterClassExW(&cls) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

static int tm_attach(TMTaskbarHost *host, HWND parent) {
    HWND window;
    TOOLINFOW tool;
    LONG_PTR style;
    /* Create top-level first; change WS_POPUP/WS_CHILD explicitly because
       SetParent does not change styles and NULL is a valid successful result. */
    window = CreateWindowExW(WS_EX_TOOLWINDOW, tm_readout_class, host->text,
        WS_POPUP | WS_TABSTOP, 0, 0, 1, 1, NULL, NULL, GetModuleHandleW(NULL), host);
    if (!window) { host->error = tm_error(); return 0; }
    SetLastError(ERROR_SUCCESS);
    style = SetWindowLongPtrW(window, GWL_STYLE, WS_CHILD | WS_TABSTOP | WS_CLIPSIBLINGS);
    if (!style && GetLastError()) {
        host->error = tm_error(); DestroyWindow(window); return 0;
    }
    SetLastError(ERROR_SUCCESS);
    if (!SetParent(window, parent) && GetLastError() != ERROR_SUCCESS) {
        host->error = tm_error(); DestroyWindow(window); return 0;
    }
    host->window = window;
    host->tooltip = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, TOOLTIPS_CLASSW, NULL,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT,
        CW_USEDEFAULT, CW_USEDEFAULT, window, NULL, GetModuleHandleW(NULL), NULL);
    if (host->tooltip) {
        ZeroMemory(&tool, sizeof(tool));
        tool.cbSize = sizeof(tool);
        tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
        tool.hwnd = window;
        tool.uId = (UINT_PTR)window;
        tool.lpszText = host->tip;
        SendMessageW(host->tooltip, TTM_ADDTOOLW, 0, (LPARAM)&tool);
    }
    return 1;
}

/* Windows 11's XAML taskbar has no supported reservation API. Measure actual
   accessibility elements, not guessed icon counts or centered-icon offsets.
   The conservative failure mode is no readout, never covering shell buttons. */
static int tm_gap(TMTaskbarHost *host, RECT taskbar, int width, RECT *placement) {
    IUIAutomationElement *root = NULL;
    IUIAutomationElementArray *elements = NULL;
    IUIAutomationCondition *condition = NULL;
    RECT occupied[TM_MAX_RECTS];
    int count = 0, length = 0, i, candidate, limit;
    BOOL sawControl = FALSE;
    HWND bridge = FindWindowExW(host->taskbar, NULL,
        L"Windows.UI.Composition.DesktopWindowContentBridge", NULL);
    HRESULT hr;
    if (!host->automation || !bridge) { host->error = ERROR_NOT_SUPPORTED; return 0; }
    /* Only traverse Explorer's XAML subtree. Traversing our sibling HWND
       through UI Automation on its owning UI thread can deadlock. */
    hr = IUIAutomation_ElementFromHandle(host->automation, bridge, &root);
    if (FAILED(hr)) goto unavailable;
    hr = IUIAutomation_get_ControlViewCondition(host->automation, &condition);
    if (FAILED(hr)) goto unavailable;
    hr = IUIAutomationElement_FindAll(root, TreeScope_Descendants, condition, &elements);
    if (FAILED(hr)) goto unavailable;
    hr = IUIAutomationElementArray_get_Length(elements, &length);
    if (FAILED(hr) || length > 2048) goto unavailable;
    for (i = 0; i < length; ++i) {
        IUIAutomationElement *element = NULL;
        CONTROLTYPEID type = 0;
        int process = 0;
        BOOL offscreen = FALSE;
        RECT rect, clipped;
        if (FAILED(IUIAutomationElementArray_GetElement(elements, i, &element))) goto unavailable;
        hr = IUIAutomationElement_get_CurrentProcessId(element, &process);
        if (SUCCEEDED(hr)) hr = IUIAutomationElement_get_CurrentControlType(element, &type);
        if (SUCCEEDED(hr)) hr = IUIAutomationElement_get_CurrentIsOffscreen(element, &offscreen);
        if (SUCCEEDED(hr)) hr = IUIAutomationElement_get_CurrentBoundingRectangle(element, &rect);
        IUIAutomationElement_Release(element);
        if (FAILED(hr)) goto unavailable;
        if (process == (int)GetCurrentProcessId() || offscreen) continue;
        if (type == UIA_PaneControlTypeId || type == UIA_GroupControlTypeId ||
            type == UIA_ToolBarControlTypeId || type == UIA_WindowControlTypeId ||
            type == UIA_ListControlTypeId || type == UIA_MenuBarControlTypeId) continue;
        if (!IntersectRect(&clipped, &rect, &taskbar)) continue;
        sawControl = TRUE;
        if (count == TM_MAX_RECTS) goto unavailable;
        occupied[count++] = clipped;
    }
    if (!sawControl) goto unavailable;
    /* Native notification and auxiliary windows remain occupied even when
       their automation provider exposes only part of the visible contents. */
    {
        HWND tray = FindWindowExW(host->taskbar, NULL, L"TrayNotifyWnd", NULL);
        RECT rect;
        if (tray && GetWindowRect(tray, &rect) && count < TM_MAX_RECTS) occupied[count++] = rect;
        else goto unavailable;
        {
            HWND child = GetWindow(host->taskbar, GW_CHILD);
            while (child) {
                DWORD process = 0;
                GetWindowThreadProcessId(child, &process);
                if (child != bridge && child != tray && process != GetCurrentProcessId() &&
                    IsWindowVisible(child) && GetWindowRect(child, &rect) &&
                    rect.right > rect.left && rect.bottom > rect.top) {
                    if (count == TM_MAX_RECTS) goto unavailable;
                    occupied[count++] = rect;
                }
                child = GetWindow(child, GW_HWNDNEXT);
            }
        }
    }
    candidate = taskbar.left + MulDiv(8, host->dpi, 96);
    limit = taskbar.right - MulDiv(8, host->dpi, 96);
    while (candidate + width <= limit) {
        int next = candidate;
        for (i = 0; i < count; ++i) {
            if (occupied[i].left < candidate + width && occupied[i].right > candidate)
                next = max(next, occupied[i].right + MulDiv(4, host->dpi, 96));
        }
        if (next == candidate) {
            *placement = taskbar;
            placement->left = candidate;
            placement->right = candidate + width;
            IUIAutomationElementArray_Release(elements);
            IUIAutomationCondition_Release(condition);
            IUIAutomationElement_Release(root);
            return 1;
        }
        candidate = next;
    }
    host->error = ERROR_INSUFFICIENT_BUFFER;
    goto cleanup;
unavailable:
    host->error = ERROR_NOT_SUPPORTED;
cleanup:
    if (elements) IUIAutomationElementArray_Release(elements);
    if (condition) IUIAutomationCondition_Release(condition);
    if (root) IUIAutomationElement_Release(root);
    return 0;
}

static int tm_refresh(TMTaskbarHost *host) {
    HWND taskbar = FindWindowW(L"Shell_TrayWnd", NULL);
    HWND rebar, tasklist, parent;
    RECT bar, position;
    MONITORINFO monitor = {sizeof(monitor)};
    DPI_AWARENESS_CONTEXT previous;
    int width, result = 0;
    BOOL modern;
    if (!taskbar) { tm_detach(host); host->error = ERROR_NOT_FOUND; return 0; }
    /* Match Explorer's DPI context for cross-process parenting. Physical
       bounds are obtained separately under per-monitor V2 awareness. */
    previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(taskbar));
    GetWindowRect(taskbar, &bar);
    if (!GetMonitorInfoW(MonitorFromWindow(taskbar, MONITOR_DEFAULTTOPRIMARY), &monitor) ||
        !(monitor.dwFlags & MONITORINFOF_PRIMARY) || bar.bottom - bar.top >= bar.right - bar.left) {
        host->error = ERROR_NOT_SUPPORTED;
        tm_detach(host);
        goto done;
    }
    rebar = FindWindowExW(taskbar, NULL, L"ReBarWindow32", NULL);
    tasklist = rebar ? FindWindowExW(rebar, NULL, L"MSTaskSwWClass", NULL) : NULL;
    modern = FindWindowExW(taskbar, NULL, L"Windows.UI.Composition.DesktopWindowContentBridge", NULL) != NULL || !tasklist;
    parent = modern ? taskbar : rebar;
    if (host->taskbar != taskbar || host->parent != parent || !IsWindow(host->window)) {
        tm_detach(host);
        host->taskbar = taskbar;
        host->parent = parent;
        host->tasklist = modern ? NULL : tasklist;
    }
    if (!tm_font(host, GetDpiForWindow(taskbar))) goto failed;
    tm_theme(host);
    width = tm_width(host);
    if (!width) goto failed;
    if (modern) {
        /* UI Automation bounding rectangles are always physical pixels. */
        DPI_AWARENESS_CONTEXT physical = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        RECT physicalBar;
        GetWindowRect(taskbar, &physicalBar);
        result = tm_gap(host, physicalBar, width, &position);
        if (result) MapWindowPoints(NULL, parent, (POINT *)&position, 2);
        SetThreadDpiAwarenessContext(physical);
        if (!result) goto failed;
    } else {
        RECT current = tm_child_rect(tasklist, parent), available, desired;
        if (host->reserved && !EqualRect(&current, &host->owned)) host->reserved = FALSE;
        available = host->reserved ? host->original : current;
        /* Leave the task switcher meaningful space. It, not our child,
           relays the new available width to Explorer's button layout. */
        if (available.right - available.left < width + MulDiv(160, host->dpi, 96)) {
            host->error = ERROR_INSUFFICIENT_BUFFER;
            goto failed;
        }
        position = available;
        position.left = available.right - width;
        if (!host->reserved) host->original = available;
        desired = available;
        desired.right = position.left;
        if (!EqualRect(&current, &desired) &&
            !SetWindowPos(tasklist, NULL, desired.left, desired.top,
                desired.right - desired.left, desired.bottom - desired.top,
                SWP_NOACTIVATE | SWP_NOZORDER)) {
            host->error = tm_error(); goto failed;
        }
        current = tm_child_rect(tasklist, parent);
        if (!EqualRect(&current, &desired)) {
            host->reserved = FALSE;
            host->error = ERROR_INVALID_STATE;
            goto failed;
        }
        host->owned = desired;
        host->reserved = TRUE;
    }
    if (!host->window && !tm_attach(host, parent)) goto failed;
    {
        RECT current = tm_child_rect(host->window, parent);
        if (!EqualRect(&current, &position) || !IsWindowVisible(host->window)) {
            if (!SetWindowPos(host->window, HWND_TOP, position.left, position.top,
                position.right - position.left, position.bottom - position.top,
                SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED)) {
                host->error = tm_error(); goto failed;
            }
        }
    }
    host->error = ERROR_SUCCESS;
    result = 1;
    goto done;
failed:
    if (host->window) ShowWindow(host->window, SW_HIDE);
    tm_restore(host);
    result = 0;
done:
    if (previous) SetThreadDpiAwarenessContext(previous);
    return result;
}

static LRESULT CALLBACK tm_window_proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    TMTaskbarHost *host = (TMTaskbarHost *)GetWindowLongPtrW(window, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        host = (TMTaskbarHost *)((CREATESTRUCTW *)lParam)->lpCreateParams;
        SetWindowLongPtrW(window, GWLP_USERDATA, (LONG_PTR)host);
    }
    if (!host) return DefWindowProcW(window, message, wParam, lParam);
    if (message == host->taskbarCreated && window == host->control) {
        tm_detach(host);
        if (host->started) tm_refresh(host);
        return 0;
    }
    switch (message) {
    case TM_LAYOUT:
        host->layoutPending = FALSE;
        if (host->started) tm_refresh(host);
        return 0;
    case WM_TIMER:
        if (window == host->control && wParam == TM_TIMER && host->started) tm_refresh(host);
        return 0;
    case TM_ACTION:
        if (window == host->control && host->action) host->action(host->context, (int)wParam);
        return 0;
    case WM_LBUTTONUP:
        SetFocus(window);
        PostMessageW(host->control, TM_ACTION, TM_TASKBAR_USAGE, 0);
        return 0;
    case WM_KEYUP:
        if (wParam == VK_SPACE || wParam == VK_RETURN) {
            PostMessageW(host->control, TM_ACTION, TM_TASKBAR_USAGE, 0);
            return 0;
        }
        break;
    case WM_GETDLGCODE: return DLGC_WANTCHARS;
    case WM_CONTEXTMENU:
        tm_menu(host, window, lParam);
        return 0;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
        InvalidateRect(window, NULL, FALSE);
        return 0;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT:
        if (window != host->control) { tm_paint(host, window); return 0; }
        break;
    case WM_DPICHANGED:
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
    case WM_DISPLAYCHANGE:
        if (host->font) { DeleteObject(host->font); host->font = NULL; }
        if (host->window) InvalidateRect(host->window, NULL, FALSE);
        if (host->started) PostMessageW(host->control, WM_TIMER, TM_TIMER, 0);
        break;
    case WM_NCDESTROY:
        if (window == host->window) {
            host->window = NULL;
            host->tooltip = NULL;
        }
        SetWindowLongPtrW(window, GWLP_USERDATA, 0);
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

TMTaskbarHost *tm_taskbar_create(TMTaskbarAction action, void *context) {
    TMTaskbarHost *host;
    HRESULT hr;
    INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_WIN95_CLASSES};
    if (!tm_register_classes() || !InitCommonControlsEx(&controls)) return NULL;
    host = (TMTaskbarHost *)calloc(1, sizeof(*host));
    if (!host) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    host->thread = GetCurrentThreadId();
    host->action = action;
    host->context = context;
    tm_copy(host->text, L"Today: 0 tokens");
    tm_copy(host->tip, L"ToastMonitor — today's tokens. Click for usage.");
    host->taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    if (!host->taskbarCreated) { DWORD error = tm_error(); free(host); SetLastError(error); return NULL; }
    /* A hidden top-level window (not HWND_MESSAGE) receives shell broadcasts
       even while our Explorer-owned child does not exist. */
    host->control = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, tm_control_class,
        L"ToastMonitor taskbar controller", WS_POPUP, 0, 0, 0, 0, NULL, NULL,
        GetModuleHandleW(NULL), host);
    if (!host->control) { DWORD error = tm_error(); free(host); SetLastError(error); return NULL; }
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    host->comOwned = SUCCEEDED(hr);
    if (SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE)
        CoCreateInstance(&CLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER,
            &IID_IUIAutomation, (void **)&host->automation);
    return host;
}

int tm_taskbar_start(TMTaskbarHost *host) {
    if (!tm_thread(host)) return 0;
    if (!host->started) {
        if (!SetTimer(host->control, TM_TIMER, TM_POLL_MS, NULL)) { host->error = tm_error(); return 0; }
        host->started = TRUE;
        host->layoutHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
            NULL, tm_layout_event, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    return tm_refresh(host);
}

void tm_taskbar_set_text(TMTaskbarHost *host, const wchar_t *text, const wchar_t *tooltip) {
    TOOLINFOW tool;
    wchar_t next[TM_MAX_TEXT];
    if (!tm_thread(host)) return;
    tm_copy(next, text);
    if (wcscmp(next, host->text) != 0) {
        tm_copy(host->text, next);
        if (host->window) {
            SetWindowTextW(host->window, host->text);
            InvalidateRect(host->window, NULL, FALSE);
        }
        if (host->started) tm_refresh(host);
    }
    tm_copy(host->tip, tooltip);
    if (host->tooltip) {
        ZeroMemory(&tool, sizeof(tool));
        tool.cbSize = sizeof(tool);
        tool.hwnd = host->window;
        tool.uId = (UINT_PTR)host->window;
        tool.lpszText = host->tip;
        SendMessageW(host->tooltip, TTM_UPDATETIPTEXTW, 0, (LPARAM)&tool);
    }
}

int tm_taskbar_bounds(TMTaskbarHost *host, int *x, int *y, int *width, int *height) {
    RECT rect, visible;
    MONITORINFO monitor = {sizeof(monitor)};
    DPI_AWARENESS_CONTEXT previous;
    BOOL valid;
    if (!tm_thread(host) || !host->window || !IsWindowVisible(host->window) || host->error) return 0;
    previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    valid = GetWindowRect(host->window, &rect) &&
        GetMonitorInfoW(MonitorFromWindow(host->taskbar, MONITOR_DEFAULTTOPRIMARY), &monitor) &&
        IntersectRect(&visible, &rect, &monitor.rcMonitor) &&
        visible.bottom - visible.top >= (rect.bottom - rect.top) / 2 &&
        visible.right - visible.left >= (rect.right - rect.left) / 2;
    if (previous) SetThreadDpiAwarenessContext(previous);
    if (!valid) return 0;
    if (x) *x = rect.left;
    if (y) *y = rect.top;
    if (width) *width = rect.right - rect.left;
    if (height) *height = rect.bottom - rect.top;
    return 1;
}

int tm_taskbar_last_error(TMTaskbarHost *host) {
    if (!tm_thread(host)) return host ? ERROR_INVALID_THREAD_ID : ERROR_INVALID_PARAMETER;
    return (int)host->error;
}

void tm_taskbar_destroy(TMTaskbarHost *host) {
    DPI_AWARENESS_CONTEXT previous = NULL;
    if (!tm_thread(host)) return;
    host->started = FALSE;
    KillTimer(host->control, TM_TIMER);
    if (host->layoutHook) UnhookWinEvent(host->layoutHook);
    if (IsWindow(host->taskbar)) previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(host->taskbar));
    tm_detach(host);
    if (previous) SetThreadDpiAwarenessContext(previous);
    DestroyWindow(host->control);
    if (host->font) DeleteObject(host->font);
    if (host->automation) IUIAutomation_Release(host->automation);
    if (host->comOwned) CoUninitialize();
    free(host);
}
