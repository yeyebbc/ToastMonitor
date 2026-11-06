#if os(macOS)
import Combine
import UserNotifications
#else
import SwiftCrossUI
#endif
import Foundation

enum QuotaAlertPolicy {
    struct BadgeState: Codable, Equatable {
        var resetAt: Int64?
        var triggered = false
        var unread = false

        mutating func update(remaining: Double, threshold: Double, resetAt nextReset: Int64?,
                             viewed: Bool = false) {
            guard remaining.isFinite else { return }
            // Relative reset countdowns can drift slightly between fetches.
            if let old = resetAt, let nextReset, Double(nextReset) - Double(old) > 300 {
                triggered = false
                unread = false
                resetAt = nextReset
            } else if resetAt == nil {
                resetAt = nextReset
            }
            if remaining > threshold {
                unread = false
                if resetAt == nil { triggered = false }
            } else if !triggered {
                triggered = true
                unread = true
            }
            if viewed { unread = false }
        }
    }

    enum Event: Equatable {
        case low
        case recovered
    }

    static func transition(previous: String?, remaining: Double,
                           threshold: Double) -> Event? {
        let isLow = remaining <= threshold
        if isLow, previous != "low" { return .low }
        if !isLow, previous == "low" { return .recovered }
        return nil
    }
}

@MainActor
final class QuotaAlertManager: ObservableObject {
    struct Reading {
        let id: String
        let name: String
        let remaining: Double
        var resetAt: Int64? = nil
    }

    static let shared = QuotaAlertManager()
    static let enabledKey = "quota_alerts_enabled"
    static let thresholdKey = "quota_alerts_threshold"

    @Published private(set) var enabled: Bool
    @Published private(set) var unreadCount = 0
    /// Remaining percent at or below which a quota alerts.
    @Published private(set) var threshold: Double
    static let thresholdChoices: [Double] = [10, 20, 30, 50]

    private var started = false
    private var panelVisible = false
    private let readingProvider: (() -> [Reading])?
    private var badgeStates: [String: QuotaAlertPolicy.BadgeState] = [:]
    private static let badgeStateKey = "quota_alert_badge_states"
    #if os(macOS)
    private var cancellables: Set<AnyCancellable> = []
    /// Direct SwiftPM/headless render binaries have no application bundle
    /// proxy, and UserNotifications throws an Objective-C exception if its
    /// center is created there. Resolve it only when normal app startup or an
    /// explicit settings action actually needs notification delivery.
    private lazy var center = UNUserNotificationCenter.current()
    #else
    private var windowsObservations: [SwiftCrossUI.Cancellable] = []
    private var windowsPublishers: [SwiftCrossUI.Publisher] = []
    private var windowsNotificationObservers: [NSObjectProtocol] = []
    #endif

    init(readingProvider: (() -> [Reading])? = nil) {
        self.readingProvider = readingProvider
        enabled = Database.shared.setting(Self.enabledKey) == "1"
        let saved = Double(Database.shared.setting(Self.thresholdKey) ?? "") ?? 20
        threshold = Self.thresholdChoices.contains(saved) ? saved : 20
        if let raw = Database.shared.setting(Self.badgeStateKey), let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String: QuotaAlertPolicy.BadgeState].self, from: data) {
            badgeStates = saved
        }
    }

    func start() {
        guard !started else { return }
        started = true
        #if os(macOS)
        NotificationCenter.default.publisher(for: PanelController.visibilityNotification)
            .sink { [weak self] notification in
                guard let self, let visible = notification.object as? Bool else { return }
                self.panelVisible = visible
                if visible { self.evaluate() }
            }.store(in: &cancellables)
        let publishers: [AnyPublisher<Void, Never>] = [
            ClaudeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            CodexQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            OpenCodeGoClient.shared.objectWillChange.eraseToAnyPublisher(),
            CommandCodeQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            GrokQuotaClient.shared.objectWillChange.eraseToAnyPublisher(),
            OpenRouterClient.shared.objectWillChange.eraseToAnyPublisher(),
            AppState.shared.objectWillChange.eraseToAnyPublisher(),
        ]
        for publisher in publishers {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.scheduleEvaluation()
            }.store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: Database.subscriptionsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRenewalReminders() }
            .store(in: &cancellables)
        #else
        windowsNotificationObservers.append(NotificationCenter.default.addObserver(
            forName: TMNotifications.popoverVisibility, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let visible = note.object as? Bool else { return }
            MainActor.assumeIsolated {
                self.panelVisible = visible
                if visible { self.evaluate() }
            }
        })
        windowsPublishers = [
            ClaudeQuotaClient.shared.didChange,
            CodexQuotaClient.shared.didChange,
            OpenCodeGoClient.shared.didChange,
            CommandCodeQuotaClient.shared.didChange,
            GrokQuotaClient.shared.didChange,
            OpenRouterClient.shared.didChange,
        ]
        windowsObservations = windowsPublishers.map { publisher in
            publisher.observe { [weak self] in self?.scheduleEvaluation() }
        }
        windowsNotificationObservers.append(NotificationCenter.default.addObserver(
            forName: Database.subscriptionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRenewalReminders() }
        })
        #endif
        evaluate()
        scheduleRenewalReminders()
    }

    func setThreshold(_ newValue: Double) {
        guard newValue != threshold, Self.thresholdChoices.contains(newValue) else { return }
        threshold = newValue
        _ = Database.shared.setSetting(Self.thresholdKey, "\(Int(newValue))")
        evaluate()
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        if !newValue {
            enabled = false
            _ = Database.shared.setSetting(Self.enabledKey, nil)
            #if os(macOS)
            center.removePendingNotificationRequests(withIdentifiers: renewalIdentifiers())
            #else
            WindowsAlertDelivery.cancel(identifiers: renewalIdentifiers())
            #endif
            return
        }
        #if os(macOS)
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enabled = granted
                _ = Database.shared.setSetting(Self.enabledKey, granted ? "1" : nil)
                if granted {
                    self.evaluate()
                    self.scheduleRenewalReminders()
                }
            }
        }
        #else
        enabled = true
        _ = Database.shared.setSetting(Self.enabledKey, "1")
        evaluate()
        scheduleRenewalReminders()
        #endif
    }

    func evaluate() {
        let readings = currentReadings()
        let previousBadges = badgeStates
        if panelVisible {
            for id in Array(badgeStates.keys) { badgeStates[id]?.unread = false }
        }
        for reading in readings {
            var state = badgeStates[reading.id] ?? QuotaAlertPolicy.BadgeState()
            state.update(remaining: reading.remaining, threshold: threshold,
                         resetAt: reading.resetAt, viewed: panelVisible)
            badgeStates[reading.id] = state
        }
        let count = readings.filter { badgeStates[$0.id]?.unread == true }.count
        if unreadCount != count { unreadCount = count }
        if badgeStates != previousBadges,
           let data = try? JSONEncoder().encode(badgeStates),
           let raw = String(data: data, encoding: .utf8) {
            _ = Database.shared.setSetting(Self.badgeStateKey, raw)
        }
        guard enabled else { return }
        for reading in readings {
            let key = "quota_alert_state_\(reading.id)"
            let previous = Database.shared.setting(key)
            guard let event = QuotaAlertPolicy.transition(previous: previous,
                                                          remaining: reading.remaining,
                                                          threshold: threshold) else { continue }
            switch event {
            case .low:
                post(identifier: "quota-low-\(reading.id)",
                     title: "\(reading.name) quota is low",
                     body: "\(Int(reading.remaining.rounded()))% remaining")
                _ = Database.shared.setSetting(key, "low")
            case .recovered:
                post(identifier: "quota-reset-\(reading.id)",
                     title: "\(reading.name) quota reset",
                     body: "Capacity is back to \(Int(reading.remaining.rounded()))% remaining")
                _ = Database.shared.setSetting(key, "ok")
            }
        }
    }

    private func scheduleEvaluation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.evaluate()
        }
    }

    private func currentReadings() -> [Reading] {
        if let readingProvider { return readingProvider() }
        var readings: [Reading] = []
        if let used = ClaudeQuotaClient.shared.state.sevenDay?.usedPercent {
            readings.append(.init(id: "claude-weekly", name: "Claude weekly",
                                  remaining: Double(100 - used),
                                  resetAt: ClaudeQuotaClient.shared.state.sevenDay?.resetAt))
        }
        if let used = CodexQuotaClient.shared.state.primaryPct {
            readings.append(.init(id: "codex", name: "Codex",
                                  remaining: Double(100 - used), resetAt: CodexQuotaClient.shared.state.resetAt))
        }
        if let used = OpenCodeGoClient.shared.state.monthlyPct {
            readings.append(.init(id: "opencode-go", name: "OpenCode Go",
                                  remaining: 100 - used,
                                  resetAt: OpenCodeGoClient.shared.state.monthlyReset.map {
                                      OpenCodeGoClient.shared.state.lastSync + $0
                                  }))
        }
        if let used = CommandCodeQuotaClient.shared.state.monthlyUsedPercent {
            readings.append(.init(id: "command-code", name: "Command Code",
                                  remaining: 100 - used,
                                  resetAt: CommandCodeQuotaClient.shared.state.billingPeriodEnd.map {
                                      Int64($0.timeIntervalSince1970)
                                  }))
        }
        if let used = GrokQuotaClient.shared.state.usedPercent {
            readings.append(.init(id: "supergrok-weekly", name: "Grok weekly",
                                  remaining: 100 - used, resetAt: GrokQuotaClient.shared.state.resetAt))
        }
        let router = OpenRouterClient.shared.state
        if let limit = router.limit, limit > 0, let remaining = router.limitRemaining {
            readings.append(.init(id: "openrouter", name: "OpenRouter",
                                  remaining: min(max(remaining / limit * 100, 0), 100)))
        }
        return readings
    }

    private func scheduleRenewalReminders() {
        guard enabled else { return }
        let subscriptions = Database.shared.subscriptions()
        #if os(macOS)
        center.removePendingNotificationRequests(withIdentifiers: renewalIdentifiers())
        #else
        WindowsAlertDelivery.cancel(identifiers: renewalIdentifiers())
        #endif
        let now = Date()
        for subscription in subscriptions {
            guard let cycle = SubscriptionMath.cycleInfo(start: subscription.startDate,
                                                         end: subscription.endDate,
                                                         cycle: subscription.cycle,
                                                         now: now) else { continue }
            let fireDate = cycle.end.addingTimeInterval(-86400)
            guard fireDate > now else { continue }
            #if os(macOS)
            let content = UNMutableNotificationContent()
            content.title = "Subscription renews tomorrow"
            content.body = "\(subscription.name) renews for \(Format.money(subscription.price))"
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                              from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: "renewal-\(subscription.id)",
                                             content: content, trigger: trigger))
            #else
            WindowsAlertDelivery.schedule(identifier: "renewal-\(subscription.id)",
                                         title: "Subscription renews tomorrow",
                                         body: "\(subscription.name) renews for \(Format.money(subscription.price))",
                                         at: fireDate)
            #endif
        }
    }

    private func renewalIdentifiers() -> [String] {
        Database.shared.subscriptions().map { "renewal-\($0.id)" }
    }

    private func post(identifier: String, title: String, body: String) {
        #if os(macOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier,
                                         content: content, trigger: nil))
        #else
        WindowsAlertDelivery.post(title: title, body: body)
        #endif
    }
}
