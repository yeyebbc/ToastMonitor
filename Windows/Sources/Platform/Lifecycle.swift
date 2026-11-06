import Foundation
import WindowsServicesNative

enum WindowsLifecycle {
    static let willSleep = Notification.Name("ToastMonitor.Windows.willSleep")
    static let didWake = Notification.Name("ToastMonitor.Windows.didWake")
    private static let lock = NSLock()
    private static var started = false
    static var isLowPowerModeEnabled: Bool { tm_low_power_mode() != 0 }

    /// Power notifications use Windows callbacks, not a second application message loop.
    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = tm_lifecycle_start { sleeping in
            NotificationCenter.default.post(name: sleeping != 0 ? WindowsLifecycle.willSleep : WindowsLifecycle.didWake,
                                            object: nil)
        } != 0
        if !started {
            NSLog("[ToastMonitor] Windows suspend/resume notification registration failed")
        }
    }
    static func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        tm_lifecycle_stop()
        started = false
    }
}
