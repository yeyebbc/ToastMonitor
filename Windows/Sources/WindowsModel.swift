import Foundation
import SwiftCrossUI

enum WindowsSettingsSection: String, CaseIterable {
    case general = "General", appearance = "Appearance", sources = "Sources"
    case accounts = "Accounts", data = "Data", updates = "Updates"
}

enum WindowsDashboardSection: String, CaseIterable {
    case overview = "Overview", analysis = "Analysis", performance = "Performance", plans = "Plans", sessions = "Sessions"
}

/// Windows presentation state retains the original query snapshots and database rows.
@MainActor
final class WindowsModel: ObservableObject {
    static let shared = WindowsModel()
    @Published private(set) var snapshot: UsageQueryService.Snapshot?
    @Published private(set) var refreshing = false
    @Published var message = ""
    @Published var settingsSection: WindowsSettingsSection = .general
    @Published var dashboardSection: WindowsDashboardSection = .overview
    @Published var showSubscriptionEditor = false
    @Published var fullTokens = UserDefaults.standard.bool(forKey: "popoverFullTokens") {
        didSet { UserDefaults.standard.set(fullTokens, forKey: "popoverFullTokens") }
    }
    @Published var quotaShowsRemaining = UserDefaults.standard.bool(forKey: QuotaWindow.showsRemainingKey) {
        didSet { UserDefaults.standard.set(quotaShowsRemaining, forKey: QuotaWindow.showsRemainingKey) }
    }
    @Published var taskbarProblem: String?
    @Published private(set) var daily: [Database.DayAgg] = []
    @Published private(set) var performance: [PerfPoint] = []
    @Published private(set) var dailyLoading = false
    @Published private(set) var performanceLoading = false
    @Published private(set) var maintenanceBusy = false
    @Published private(set) var sessions: [Database.SessionRow] = []
    @Published private(set) var sessionCount = 0
    @Published private(set) var sessionPage = 0
    @Published private(set) var sessionsLoading = false
    @Published private(set) var selectedSession: Database.SessionRow?
    @Published private(set) var turns: [(ts: Int64, model: String?, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = []
    @Published private(set) var turnsLoading = false
    @Published var sessionTool: String? = "All tools"
    @Published var analysisTool: String? = "All tools"
    @Published var analysisDays: String? = "30"
    @Published var period: UsagePeriodSlot = .today
    @Published private(set) var backups: [URL] = []
    private var started = false
    private var observations: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var pendingRefresh = false
    private var analysisGeneration = 0
    private var sessionGeneration = 0
    private var detailGeneration = 0
    let pageSize = 50
    lazy var billingCoordinator = CodexBillingModeCoordinator(onCommitted: { [weak self] in self?.refresh() })
    var databaseProblemDescription: String? {
        switch Database.shared.openProblem {
        case .damaged(let detail): return "Database is damaged: \(detail)"
        case .readOnly(let detail): return "Database is not writable: \(detail)"
        case nil: return nil
        }
    }
    var configuration: UsagePeriodConfiguration { UsagePeriodSettings.shared.configuration }
    var todayTokens: Int64 { snapshot?.light.todayTokens ?? 0 }
    var databaseProblem: Database.OpenProblem? { Database.shared.openProblem }
    var toolOptions: [String] { ["All tools"] + ToolKind.allCases.map(\.rawValue) }
    var filteredDaily: [Database.DayAgg] {
        analysisTool == "All tools" ? daily : daily.filter { $0.tool == analysisTool }
    }
    var filteredPerformance: [PerfPoint] {
        analysisTool == "All tools" ? performance : performance.filter { $0.tool == analysisTool }
    }
    var periodModelRows: [Database.ModelAgg] {
        guard let snapshot else { return [] }
        let rows: [Database.ModelAgg]
        switch period {
        case .today: rows = snapshot.modelAggsToday
        case .week: rows = snapshot.modelAggs
        case .month: rows = snapshot.modelAggsMonth
        case .all: rows = snapshot.modelAggsAll
        }
        return rows
    }
    var modelRows: [Database.ModelAgg] {
        analysisTool == "All tools" ? periodModelRows : periodModelRows.filter { $0.tool == analysisTool }
    }
    func tokens(_ slot: UsagePeriodSlot) -> Int64 {
        guard let light = snapshot?.light else { return 0 }
        switch slot { case .today: return light.todayTokens; case .week: return light.weekTokens; case .month: return light.monthTokens; case .all: return light.allTokens }
    }
    func totals(_ slot: UsagePeriodSlot) -> Database.ToolTotals? {
        guard let light = snapshot?.light else { return nil }
        switch slot { case .today: return light.today; case .week: return light.week; case .month: return light.month; case .all: return light.all }
    }
    func apiValue(_ slot: UsagePeriodSlot) -> Double {
        guard let light = snapshot?.light else { return 0 }
        switch slot { case .today: return light.apiValueToday; case .week: return light.apiValueWeek; case .month: return light.apiValueMonth; case .all: return light.apiValueAll }
    }
    func rows(_ slot: UsagePeriodSlot) -> [Database.ToolTotals] {
        guard let light = snapshot?.light else { return [] }
        switch slot { case .today: return light.byToolToday; case .week: return light.byToolWeek; case .month: return light.byToolMonth; case .all: return light.byToolAll }
    }
    func quality(_ slot: UsagePeriodSlot) -> UsageQueryService.CostQuality? {
        guard let light = snapshot?.light else { return nil }
        switch slot { case .today: return light.costToday; case .week: return light.costWeek; case .month: return light.costMonth; case .all: return light.costAll }
    }
    func start() {
        guard !started else { return }
        started = true
        CollectorEngine.shared.start()
        HermesRemoteClient.shared.start()
        OpenCodeGoClient.shared.start()
        OpenRouterClient.shared.start()
        CommandCodeQuotaClient.shared.start()
        ClaudeQuotaClient.shared.start()
        CodexQuotaClient.shared.start()
        GrokQuotaClient.shared.start()
        DeepSeekBillingClient.shared.start()
        QuotaAlertManager.shared.start()
        for name in [CollectorEngine.didCollect, Database.subscriptionsDidChange, TMNotifications.usagePeriodSettingsChanged] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
        self.timer = timer
        timer.resume()
        reloadBackups()
        refresh()
        loadAnalysis()
        loadSessions(page: 0)
    }
    func refresh() {
        guard !refreshing else { pendingRefresh = true; return }
        refreshing = true
        UsageQueryService.shared.loadSnapshot(configuration: configuration) { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.refreshing = false
            if self.pendingRefresh { self.pendingRefresh = false; self.refresh() }
        }
    }
    func refreshAll() {
        CollectorEngine.shared.scheduleScan(force: true) { [weak self] _ in self?.refresh() }
        HermesRemoteClient.shared.poll()
        OpenCodeGoClient.shared.refresh()
        OpenRouterClient.shared.refresh()
        CommandCodeQuotaClient.shared.refresh()
        ClaudeQuotaClient.shared.refresh(force: true)
        CodexQuotaClient.shared.refresh()
        GrokQuotaClient.shared.refresh()
        DeepSeekBillingClient.shared.refresh(force: true)
        refresh()
        loadAnalysis()
        loadSessions(page: sessionPage)
    }
    func loadAnalysis() {
        let days = Int(analysisDays ?? "30") ?? 30
        analysisGeneration += 1
        let generation = analysisGeneration
        dailyLoading = true
        performanceLoading = true
        UsageQueryService.shared.loadDailyAggs(days: days) { [weak self] rows in
            guard let self, generation == self.analysisGeneration else { return }
            self.daily = rows
            self.dailyLoading = false
        }
        UsageQueryService.shared.loadPerfPoints(days: days) { [weak self] points in
            guard let self, generation == self.analysisGeneration else { return }
            self.performance = points
            self.performanceLoading = false
        }
    }
    func loadSessions(page: Int) {
        let page = max(0, page)
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionsLoading = true
        let tool = ToolKind(rawValue: sessionTool ?? "")
        UsageQueryService.shared.loadSessions(tool: tool, limit: pageSize, offset: page * pageSize) { [weak self] rows, total in
            guard let self, generation == self.sessionGeneration else { return }
            self.sessions = rows
            self.sessionCount = total
            self.sessionPage = page
            self.sessionsLoading = false
        }
    }
    func selectSession(_ session: Database.SessionRow) {
        selectedSession = session
        turns = []
        turnsLoading = true
        detailGeneration += 1
        let generation = detailGeneration
        UsageQueryService.shared.loadTurns(sessionTool: session.tool, sessionID: session.sessionID) { [weak self] turns in
            guard let self, generation == self.detailGeneration else { return }
            self.turns = turns
            self.turnsLoading = false
        }
    }
    func setSource(_ tool: ToolKind, remote: Bool) {
        message = tool.setSource(remote: remote) ? "Source saved. Scanning…" : "Source could not be saved."
        refreshAll()
    }
    func saveFeed(_ raw: String) -> Bool {
        guard HermesRemoteClient.shared.provision(url: raw) else { return false }
        message = "Remote feed saved."
        refreshAll()
        return true
    }
    func saveSubscription(_ subscription: Database.Subscription) -> Bool {
        guard Database.shared.upsertSubscription(subscription) else { return false }
        message = "Subscription saved."
        refresh()
        return true
    }
    func deleteSubscription(_ id: Int64) {
        message = Database.shared.deleteSubscription(id: id) ? "Subscription deleted." : "Subscription could not be deleted."
        refresh()
    }
    func reloadBackups() { backups = DataMaintenance.availableBackups() }
    func backup() {
        maintenance { DataMaintenance.createBackup().map { "Backup saved: \($0)" } ?? "Backup failed. Check available disk space and folder permissions." }
    }
    func exportDatabase(to path: String) {
        maintenance { DataMaintenance.exportDatabase(to: path) ? "Redacted database exported to \(path). Usage and project metadata remain sensitive." : "Export failed. Choose a writable destination outside the live database." }
    }
    func restore(_ url: URL) {
        maintenance { DataMaintenance.restoreWithReceipt(backupPath: url.path).map { "Restored backup. Pre-restore snapshot: \($0)" } ?? "Restore failed. Only valid managed backups can be restored." }
    }
    func recoverDatabase() {
        guard Database.shared.openProblem != nil else { return }
        maintenance { DataMaintenance.recover(from: nil) ? "A new database was opened. The unusable store was preserved beside it." : "Recovery failed. Check the database folder permissions and available disk space." }
    }
    func clearData() {
        maintenance {
            guard let backup = DataMaintenance.createBackup(label: "pre-clear") else { return "Clear cancelled: safety backup failed." }
            return Database.shared.clearAllData() ? "Data cleared. Safety backup: \(backup). Original tool logs can be collected again." : "Clear failed. Safety backup: \(backup)"
        }
    }
    private func maintenance(_ operation: @escaping @Sendable () -> String) {
        guard !maintenanceBusy else { return }
        maintenanceBusy = true
        message = "Working…"
        DispatchQueue.global(qos: .utility).async {
            let result = operation()
            Task { @MainActor in
                self.message = result
                self.maintenanceBusy = false
                self.reloadBackups()
                self.refresh()
                self.loadAnalysis()
                self.loadSessions(page: 0)
            }
        }
    }
    func exportAnalysis(to path: String) {
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard DataMaintenance.isSafeExportDestination(destination, databasePath: Database.shared.dbPath) else {
            message = "Choose an export path outside the live database."; return
        }
        var lines = ["tool,model,input_tokens,output_tokens,cache_read_tokens,calls,estimated_cost"]
        lines += modelRows.map { row in
            [AnalysisCSVRow.csvField(row.tool), AnalysisCSVRow.csvField(row.model), String(row.input), String(row.output),
             String(row.cacheRead), String(row.count), String(row.cost)].joined(separator: ",")
        }
        let csv = lines.joined(separator: "\r\n") + "\r\n"
        maintenance {
            do { try csv.write(to: destination, atomically: true, encoding: .utf8); return "Current model analysis exported to \(path)." }
            catch { return "CSV export failed: \(error.localizedDescription)" }
        }
    }
    func open(_ address: String) {
        guard let url = URL(string: address) else { message = "Invalid link."; return }
        do { try WindowsExternalBrowser.open(url) }
        catch { message = error.localizedDescription }
    }
}
