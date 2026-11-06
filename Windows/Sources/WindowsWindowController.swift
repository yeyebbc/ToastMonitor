import Foundation
import SwiftCrossUI
import TaskbarHost
import WinAppSDK
import WinSDK
import UWP
import WinUI
import WinUIBackend

/// The only owner of native window handles and the Explorer integration.
@MainActor
final class WindowsWindowController {
    static let shared = WindowsWindowController()
    private var windows: [String: WinUI.Window] = [:]
    private var handles: [String: HWND] = [:]
    // Generated event accessors capture their Swift projection weakly.
    private var appWindows: [String: WinAppSDK.AppWindow] = [:]
    private var roots: [String: WinUI.UIElement] = [:]
    private var openWindow: ((String) -> Void)?
    private var host: OpaquePointer?
    private var observation: SwiftCrossUI.Cancellable?
    private var statusTimer: DispatchSourceTimer?
    private var lastLabel = ""
    private var activationInstance: AppInstance?
    private var initialized = false
    private var quitting = false
    private var lastHostError: UInt32 = .max

    func start(openWindow action: @escaping (String) -> Void) {
        let firstLaunch = openWindow == nil
        openWindow = action
        guard firstLaunch else { return }
        // Let the public scene graph register its openWindow actions before starting the native host.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.initialize()
            if CommandLine.arguments.contains("--show-dashboard") { self.showDashboard() }
            else if CommandLine.arguments.contains("--show-settings") { self.showSettings() }
            else if !CommandLine.arguments.contains("--background") {
                self.showUsage()
            }
        }
    }

    func register(_ window: WinUI.Window, id: String) {
        guard windows[id] == nil, let handle = window.getHWND() else { return }
        windows[id] = window
        handles[id] = handle
        let appWindow = window.appWindow
        let root = window.content
        appWindows[id] = appWindow
        roots[id] = root
        if id == "usage" { updateUsageStyle(handle) }
        appWindow?.closing.addHandler { [weak self] _, arguments in
            MainActor.assumeIsolated {
                guard let self, !self.quitting else { return }
                arguments?.cancel = true
                if id == "usage", self.host == nil || WindowsModel.shared.taskbarProblem != nil { self.quit() }
                else { self.hide(id) }
            }
        }
        root?.keyDown.addHandler { [weak self] _, arguments in
            MainActor.assumeIsolated {
                if arguments?.key == .escape {
                    arguments?.handled = true
                    self?.hide(id)
                }
            }
        }
        window.activated.addHandler { [weak self] _, arguments in
            MainActor.assumeIsolated {
                guard let self, id == "usage", arguments?.windowActivationState == .deactivated,
                      Database.shared.setting("popover_dismiss_on_resign") == "1" else { return }
                var cursor = POINT()
                if GetCursorPos(&cursor), let rect = self.readoutRect(),
                   cursor.x >= rect.left, cursor.x < rect.right,
                   cursor.y >= rect.top, cursor.y < rect.bottom { return }
                self.hide(id)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.show(id)
            if id == "settings", WindowsModel.shared.showSubscriptionEditor { self.focusSubscriptionEditor() }
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        activationInstance = AppInstance.getCurrent()
        activationInstance?.activated.addHandler { [weak self] _, arguments in
            guard arguments?.kind == .launch,
                  let launch = arguments?.data as? UWP.ILaunchActivatedEventArgs,
                  let id = Self.requestedWindow(launch.arguments) else { return }
            DispatchQueue.main.async { self?.show(id) }
        }
        let model = WindowsModel.shared
        model.start()
        observation = model.didChange.observe { [weak self] in
            DispatchQueue.main.async { self?.updateReadout() }
        }
        host = tm_taskbar_create({ context, action in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<WindowsWindowController>.fromOpaque(context).takeUnretainedValue()
                switch action {
                case Int32(TM_TASKBAR_USAGE): controller.toggleUsage()
                case Int32(TM_TASKBAR_DASHBOARD): controller.showDashboard()
                case Int32(TM_TASKBAR_SETTINGS): controller.showSettings()
                case Int32(TM_TASKBAR_QUIT): controller.quit()
                default: break
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        if let host { _ = tm_taskbar_start(host) }
        updateReadout()
        checkHost()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkHost() } }
        timer.resume()
        statusTimer = timer
    }

    private func updateReadout() {
        guard let host else { return }
        let tokens = WindowsModel.shared.todayTokens
        let label = "Today " + Format.compact(tokens)
        guard label != lastLabel else { return }
        lastLabel = label
        let tooltip = "Today: \(Format.full(tokens)) tokens\nClick for usage and quotas. Right-click for Dashboard, Settings or Quit."
        label.withCString(encodedAs: UTF16.self) { text in
            tooltip.withCString(encodedAs: UTF16.self) { tm_taskbar_set_text(host, text, $0) }
        }
    }

    private func checkHost() {
        let error = host.map { UInt32(tm_taskbar_last_error($0)) } ?? UInt32(ERROR_NOT_ENOUGH_MEMORY)
        guard error != lastHostError else { return }
        lastHostError = error
        let model = WindowsModel.shared
        switch error {
        case 0: model.taskbarProblem = nil
        case UInt32(ERROR_NOT_SUPPORTED): model.taskbarProblem = "A horizontal primary Explorer taskbar is required"
        case UInt32(ERROR_INSUFFICIENT_BUFFER): model.taskbarProblem = "There is not enough free taskbar space; close or combine taskbar buttons"
        default: model.taskbarProblem = "Explorer integration failed (Windows error \(error)); automatic recovery is active"
        }
        if let handle = handles["usage"] { updateUsageStyle(handle) }
        if let problem = model.taskbarProblem {
            fputs("Taskbar readout unavailable (Windows error \(error)): \(problem). Automatic recovery remains active.\n", stderr)
        }
    }

    private func updateUsageStyle(_ handle: HWND) {
        let previous = GetWindowLongPtrW(handle, GWL_EXSTYLE)
        let style: LONG_PTR
        if WindowsModel.shared.taskbarProblem == nil {
            style = (previous | LONG_PTR(WS_EX_TOOLWINDOW)) & ~LONG_PTR(WS_EX_APPWINDOW)
        } else {
            style = (previous | LONG_PTR(WS_EX_APPWINDOW)) & ~LONG_PTR(WS_EX_TOOLWINDOW)
        }
        _ = SetWindowLongPtrW(handle, GWL_EXSTYLE, style)
        _ = SetWindowPos(handle, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED))
    }

    nonisolated private static func requestedWindow(_ commandLine: String) -> String? {
        var count: Int32 = 0
        guard let arguments = commandLine.withCString(encodedAs: UTF16.self, {
            CommandLineToArgvW($0, &count)
        }) else { return nil }
        defer { _ = LocalFree(arguments) }
        var dashboard = false
        var settings = false
        var background = false
        for index in 0..<Int(count) {
            guard let argument = arguments[index] else { continue }
            switch String(decodingCString: argument, as: UTF16.self) {
            case "--background": background = true
            case "--show-dashboard": dashboard = true
            case "--show-settings": settings = true
            default: break
            }
        }
        return dashboard ? "dashboard" : settings ? "settings" : background ? nil : "usage"
    }

    func showUsage() { show("usage") }
    func showDashboard(section: WindowsDashboardSection? = nil) {
        if let section { WindowsModel.shared.dashboardSection = section }
        show("dashboard")
    }
    func showSettings(section: WindowsSettingsSection? = nil, subscriptions: Bool = false) {
        if let section { WindowsModel.shared.settingsSection = section }
        WindowsModel.shared.showSubscriptionEditor = subscriptions
        show("settings")
        if subscriptions { focusSubscriptionEditor() }
    }

    func window(for id: String) -> WinUI.Window? { windows[id] }

    private func focusSubscriptionEditor() {
        guard let root = roots["settings"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            func findField(_ node: WinUI.DependencyObject) -> WinUI.TextBox? {
                if let field = node as? WinUI.TextBox, field.placeholderText == "Subscription name" { return field }
                for index in 0..<WinUI.VisualTreeHelper.getChildrenCount(node) {
                    if let child = WinUI.VisualTreeHelper.getChild(node, index), let field = findField(child) { return field }
                }
                return nil
            }
            if let field = findField(root) {
                try? field.startBringIntoView()
                _ = try? field.focus(.programmatic)
            }
        }
    }

    func toggleUsage() {
        if let handle = handles["usage"], IsWindowVisible(handle) { hide("usage") }
        else { showUsage() }
    }

    private func show(_ id: String) {
        guard let window = windows[id], let handle = handles[id] else {
            openWindow?(id)
            return
        }
        _ = ShowWindow(handle, IsIconic(handle) ? SW_RESTORE : SW_SHOW)
        positionWindow(handle, nearReadout: id == "usage")
        do { try window.activate() }
        catch { WindowsModel.shared.message = "The window could not be activated: \(error.localizedDescription)" }
        _ = SetForegroundWindow(handle)
        publishVisibility(id, true)
    }

    private func hide(_ id: String) {
        guard id != "usage" || WindowsModel.shared.taskbarProblem == nil else { return }
        guard let handle = handles[id] else { return }
        _ = ShowWindow(handle, SW_HIDE)
        publishVisibility(id, false)
    }

    private func publishVisibility(_ id: String, _ visible: Bool) {
        let name: Notification.Name
        switch id {
        case "usage": name = TMNotifications.popoverVisibility
        case "dashboard": name = TMNotifications.dashboardVisibility
        default: return
        }
        NotificationCenter.default.post(name: name, object: visible)
    }

    private func readoutRect() -> RECT? {
        guard let host else { return nil }
        var x: Int32 = 0, y: Int32 = 0, width: Int32 = 0, height: Int32 = 0
        guard tm_taskbar_bounds(host, &x, &y, &width, &height) != 0 else { return nil }
        return RECT(left: x, top: y, right: x + width, bottom: y + height)
    }

    private func positionWindow(_ handle: HWND, nearReadout: Bool) {
        var frame = RECT()
        guard GetWindowRect(handle, &frame) else { return }
        var anchor = nearReadout ? (readoutRect() ?? frame) : frame
        guard let monitor = MonitorFromRect(&anchor, DWORD(MONITOR_DEFAULTTONEAREST)) else { return }
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        guard GetMonitorInfoW(monitor, &info) else { return }
        let work = info.rcWork
        let width = min(frame.right - frame.left, work.right - work.left)
        let height = min(frame.bottom - frame.top, work.bottom - work.top)
        let x = max(work.left, min(nearReadout ? anchor.right - width : frame.left, work.right - width))
        let y: LONG
        if nearReadout {
            let gap = LONG(max(6, GetDpiForWindow(handle) / 12))
            let above = anchor.top - height - gap
            y = above >= work.top ? above : max(work.top, min(anchor.bottom + gap, work.bottom - height))
        } else {
            y = max(work.top, min(frame.top, work.bottom - height))
        }
        _ = SetWindowPos(handle, nil, x, y, width, height, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    func shutdown() {
        guard !quitting else { return }
        quitting = true
        statusTimer?.cancel()
        statusTimer = nil
        observation?.cancel()
        observation = nil
        if let host { tm_taskbar_destroy(host); self.host = nil }
        WindowsLifecycle.stop()
        Database.shared.close()
    }

    func quit() {
        shutdown()
        Foundation.exit(0)
    }
}
