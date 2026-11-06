import Foundation

/// Cross-surface notification names (foreground state, tab selection).
/// Defined at top level so non-main-actor code can reference them.
enum TMNotifications {
    static let popoverVisibility = Notification.Name("tmPopoverVisibility")
    static let dashboardVisibility = Notification.Name("tmDashboardVisibility")
    static let usagePeriodSettingsChanged = Notification.Name("tmUsagePeriodSettingsChanged")
}

/// Shared refresh cadence. Foreground values preserve the existing live UI
/// behavior; background values keep the menu-bar state current without
/// polling at the same cadence when no panel is visible.
enum TMRefreshPolicy {
    static let foregroundSnapshotInterval: TimeInterval = 5
    static let backgroundSnapshotInterval: TimeInterval = 30
    static let foregroundQuotaInterval: TimeInterval = 60
    static let backgroundQuotaInterval: TimeInterval = 5 * 60

    static func snapshotInterval(foreground: Bool) -> TimeInterval {
        foreground ? foregroundSnapshotInterval : backgroundSnapshotInterval
    }

    static func quotaInterval(foreground: Bool) -> TimeInterval {
        foreground ? foregroundQuotaInterval : backgroundQuotaInterval
    }
}
