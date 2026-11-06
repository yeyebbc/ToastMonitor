import Foundation

@MainActor
final class CodexBillingModeCoordinator {
    private let database: Database
    private let queries: UsageQueryService
    private let queue: DispatchQueue
    private let onCommitted: @MainActor () -> Void
    private var generation: UInt64 = 0
    private var latestSelection: String?

    init(database: Database = .shared, queries: UsageQueryService = .shared,
         queue: DispatchQueue = DispatchQueue(label: "toastmonitor.codex-billing-setting", qos: .userInitiated),
         onCommitted: @escaping @MainActor () -> Void) {
        self.database = database
        self.queries = queries
        self.queue = queue
        self.onCommitted = onCommitted
    }

    @discardableResult
    func set(_ value: String, restoreSelection: @escaping @MainActor (String) -> Void,
             completion: @escaping @MainActor () -> Void = {}) -> Bool {
        let previousSelection = latestSelection ?? (database.setting("codex_billing_mode") ?? "api")
        guard value != previousSelection else { return false }
        latestSelection = value
        generation &+= 1
        let requestGeneration = generation
        let database = self.database
        queue.async { [weak self] in
            let saved = database.setSetting("codex_billing_mode", value)
            DispatchQueue.main.async {
                guard let self else { return }
                guard saved else {
                    if self.generation == requestGeneration {
                        let persisted = database.setting("codex_billing_mode") ?? "api"
                        self.latestSelection = persisted
                        restoreSelection(persisted)
                    }
                    completion()
                    return
                }
                self.queries.invalidateBillingModeCaches {
                    self.onCommitted()
                    completion()
                }
            }
        }
        return true
    }
}
