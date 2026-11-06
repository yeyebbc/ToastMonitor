import Foundation
import SwiftCrossUI

/// The pinned macOS composition, translated to native WinUI rather than macOS chrome.
struct WindowsUsageView: View {
    @State private var model = WindowsModel.shared
    @State private var health = SourceHealthHub.shared
    @State private var claude = ClaudeQuotaClient.shared
    @State private var codex = CodexQuotaClient.shared
    @State private var grok = GrokQuotaClient.shared
    @State private var go = OpenCodeGoClient.shared
    @State private var router = OpenRouterClient.shared
    @State private var command = CommandCodeQuotaClient.shared
    @State private var deepseek = DeepSeekBillingClient.shared
    var body: some View {
        WindowsPopupSurface(model: .live(model: model, sources: health.sources,
            claude: claude, codex: codex, grok: grok, go: go,
            router: router, command: command, deepseek: deepseek),
            actions: WindowsPopupActions(refresh: { model.refreshAll() }, selectPeriod: {
                model.period = $0
                deepseek.select($0, configuration: model.configuration)
            }, settings: { section in
                if let section { WindowsWindowController.shared.showSettings(section: section) }
                else { WindowsWindowController.shared.showSettings() }
            }, dashboard: { WindowsWindowController.shared.showDashboard() },
            quit: { WindowsWindowController.shared.quit() }))
    }
}

struct WindowsStatusView: View {
    @State private var model = WindowsModel.shared
    @State private var health = SourceHealthHub.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.taskbarProblem {
                WindowsNotice("Taskbar readout unavailable", detail: "\(problem). No tray icon is substituted. Closing Usage quits when the taskbar host is unavailable; Escape does not hide it.", severity: .warning)
            }
            if let problem = model.databaseProblemDescription {
                WindowsNotice("Database needs attention", detail: "\(problem). Open Settings → Data to restore a managed backup or preserve the unusable store and start fresh.", severity: .error)
            }
            if !model.message.isEmpty { Text(model.message).textSelectionEnabled() }
            if let fetched = model.snapshot?.light.fetchedAt {
                Text("Updated \(WindowsUI.date(fetched))").font(.caption)
            }
            ForEach(health.sources.filter { $0.error != nil || $0.failedRows > 0 || $0.isStale }, id: \.id) { source in
                WindowsNotice(source.displayName, detail: source.error ?? (source.isStale ? "Collection is stale; refresh to retry." : "\(source.failedRows) records failed to import."), severity: source.error != nil ? .error : .warning)
            }
        }
    }
}

struct WindowsPeriodSelector: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        WindowsRadioChoice(label: "Usage period", options: UsagePeriodSlot.allCases.map { model.configuration.label(for: $0) },
            selection: SwiftCrossUI.Binding(get: { UsagePeriodSlot.allCases.firstIndex(of: model.period) ?? 0 }, set: {
                model.period = UsagePeriodSlot.allCases[$0]
                DeepSeekBillingClient.shared.select(model.period, configuration: model.configuration)
            }))
    }
}

struct WindowsCostDetails: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WindowsValueRow(label: "API value", value: Format.money(model.apiValue(model.period)))
            if let quality = model.quality(model.period), let subscriptions = model.snapshot?.light.subscriptions {
                WindowsValueRow(label: "Estimated API cost", value: Format.money(quality.estimated))
                WindowsValueRow(label: "Actual API spend", value: Format.money(quality.actual))
                WindowsValueRow(label: "Subscription allocation", value: Format.money(SubscriptionMath.amortized(slot: model.period, configuration: model.configuration, subscriptions: subscriptions)))
                Text("Estimated API value and actual billed spend are different measures. Subscription allocation uses the recorded billing cycles.").font(.caption)
            }
        }
    }
}


struct WindowsToolBreakdown: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By tool").font(.headline)
            if model.rows(model.period).isEmpty {
                Text(model.snapshot?.light.byToolAll.isEmpty == true
                    ? "No usage collected yet. Configure Sources in Settings, then refresh."
                    : "No usage in this period. Choose another period to see collected usage.")
                WindowsAction("Set up sources") { WindowsWindowController.shared.showSettings(section: .sources) }
            }
            ForEach(model.rows(model.period), id: \.tool) { row in
                WindowsValueRow(label: ToolKind(rawValue: row.tool)?.displayName ?? row.tool,
                    value: "\(Format.compact(WindowsUI.tokens(row))) tokens · \(Format.money(row.cost))")
            }
        }
    }
}

struct WindowsQuotaView: View {
    @State private var claude = ClaudeQuotaClient.shared
    @State private var codex = CodexQuotaClient.shared
    @State private var grok = GrokQuotaClient.shared
    @State private var go = OpenCodeGoClient.shared
    @State private var router = OpenRouterClient.shared
    @State private var command = CommandCodeQuotaClient.shared
    @State private var deepseek = DeepSeekBillingClient.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quotas & balances").font(.headline)
            if claude.enabled {
                WindowsQuotaRow(name: "Claude · \(claude.state.planType ?? "account")", percent: claude.state.sevenDay.map { Double($0.usedPercent) }, reset: claude.state.sevenDay?.resetAt, error: claude.state.error)
                if let window = claude.state.fiveHour { WindowsQuotaRow(name: "Claude \(window.label)", percent: Double(window.usedPercent), reset: window.resetAt, error: nil) }
                if let window = claude.state.sevenDayOpus { WindowsQuotaRow(name: "Claude \(window.label)", percent: Double(window.usedPercent), reset: window.resetAt, error: nil) }
            }
            if codex.enabled { WindowsQuotaRow(name: "Codex · \(codex.state.planType ?? "account")", percent: codex.state.primaryPct.map(Double.init), reset: codex.state.resetAt, error: codex.state.error) }
            if grok.enabled { WindowsQuotaRow(name: "Grok · \(grok.state.planName ?? "account")", percent: grok.state.usedPercent, reset: grok.state.resetAt, error: grok.state.error) }
            if go.configured {
                WindowsQuotaRow(name: "OpenCode Go · 5 hours", percent: go.state.rollingPct, reset: go.state.rollingReset, error: go.state.error)
                WindowsQuotaRow(name: "OpenCode Go · weekly", percent: go.state.weeklyPct, reset: go.state.weeklyReset, error: nil)
                WindowsQuotaRow(name: "OpenCode Go · monthly", percent: go.state.monthlyPct, reset: go.state.monthlyReset, error: nil)
            }
            if !go.configured {
                WindowsCredentialIssue(name: "OpenCode Go", state: WindowsCredentialState.accounts(["go-workspace-id", "go-auth-cookie"], legacyKeys: ["go_workspace_id", "go_auth_cookie"]), error: go.state.error)
            }
            WindowsProviderBalance()
            if command.state.configured { WindowsQuotaRow(name: "Command Code · \(command.state.planName ?? "plan")", percent: command.state.monthlyUsedPercent, reset: command.state.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) }, error: command.state.error) }
            if !command.state.configured {
                WindowsCredentialIssue(name: "Command Code", state: WindowsCredentialState.accounts([CommandCodeQuotaClient.keychainAccount]), error: command.state.error)
            }
            if let balance = deepseek.state.balance { Text("DeepSeek: \(balance.formatted)").textSelectionEnabled() }
            if let spend = deepseek.state.spend { Text("DeepSeek billed spend: \(spend.formatted)").textSelectionEnabled() }
            if let error = deepseek.state.balanceError ?? deepseek.state.spendError { WindowsNotice("DeepSeek", detail: error, severity: .error) }
            WindowsAction("Manage accounts") { WindowsWindowController.shared.showSettings(section: .accounts) }
        }
    }
}
struct WindowsProviderBalance: View {
    @State private var router = OpenRouterClient.shared
    var body: some View {
        let configuration = WindowsCredentialState.accounts(["or-keys", "openrouter-key"], legacyKeys: ["or_keys", "openrouter_key"])
        VStack(alignment: .leading, spacing: 6) {
            if configuration == .missing {
                Text("OpenRouter · Not connected").font(.caption)
            } else {
                WindowsValueRow(label: "OpenRouter account balance", value: router.state.accountBalance.map(Format.money) ?? "Not available")
                if case .failure(let status) = configuration {
                    WindowsNotice("OpenRouter credential unavailable", detail: "Windows Credential Manager returned error \(status). Reconnect in Accounts.", severity: .error)
                }
                if let error = router.state.error { WindowsNotice("OpenRouter", detail: error, severity: .error) }
            }
        }
    }
}

private struct WindowsCredentialIssue: View {
    let name: String
    let state: WindowsCredentialState
    let error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .failure(let status) = state {
                WindowsNotice("\(name) credential unavailable", detail: "Windows Credential Manager returned error \(status). Reconnect in Accounts.", severity: .error)
            } else if state == .stored {
                if let error { WindowsNotice(name, detail: error, severity: .error) }
                else { Text("\(name) · Loading saved account…").font(.caption) }
            }
        }
    }
}

enum WindowsCredentialState: Equatable {
    case missing, stored, failure(UInt32)
    static func accounts(_ names: [String], legacyKeys: [String] = [], emptyIsDisconnected: Bool = false) -> Self {
        var stored = false
        for name in names {
            switch KeychainStore.readResult(account: name) {
            case .value(let value): if !emptyIsDisconnected || !value.isEmpty { stored = true }
            case .missing: break
            case .failure(let status): return .failure(status)
            }
        }
        if legacyKeys.contains(where: { !(Database.shared.setting($0) ?? "").isEmpty }) { stored = true }
        return stored ? .stored : .missing
    }
}

struct WindowsNotice: View {
    enum Severity { case warning, error }
    let title: String
    let detail: String
    let severity: Severity
    init(_ title: String, detail: String, severity: Severity) {
        self.title = title; self.detail = detail; self.severity = severity
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(severity == .error ? "Error" : "Attention"): \(title)").emphasized()
            WindowsDisclosure("Details") { Text(detail).textSelectionEnabled() }
        }
    }
}


struct WindowsQuotaRow: View {
    @State private var model = WindowsModel.shared
    var name: String
    var percent: Double?
    var reset: Int64?
    var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WindowsValueRow(label: name, value: percent.map { String(format: "%.0f%% %@", model.quotaShowsRemaining ? 100 - $0 : $0, model.quotaShowsRemaining ? "remaining" : "used") } ?? "Waiting for provider")
            if let percent {
                WindowsUI.copper.frame(width: max(0, min(model.quotaShowsRemaining ? 100 - percent : percent, 100)) * 2.4, height: 4)
            }
            if let reset { Text("Resets \(WindowsUI.date(reset))").font(.caption) }
            if let error { Text(error).foregroundColor(.red) }
        }
    }
}

struct WindowsValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).fixedSize(horizontal: true, vertical: false).textSelectionEnabled()
        }
    }
}

enum WindowsUI {
    static let datePickerRange = Date(timeIntervalSince1970: -11_644_473_600)...Date(timeIntervalSince1970: 253_402_214_400)
    static let copper = Color.adaptive(light: Color(red: 0.62, green: 0.29, blue: 0.18), dark: Color(red: 0.9, green: 0.58, blue: 0.42))
    static func date(_ timestamp: Int64) -> String { Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .shortened) }
    static func periodRange(_ configuration: UsagePeriodConfiguration, _ slot: UsagePeriodSlot) -> String {
        let now = Date()
        let range = configuration.range(for: slot, now: now)
        if slot == .all { return "All collected history" }
        let start = Date(timeIntervalSince1970: Double(range.start)).formatted(date: .abbreviated, time: .omitted)
        return "\(start) – \(now.formatted(date: .abbreviated, time: .omitted))"
    }
    static func toolName(_ raw: String) -> String { ToolKind(rawValue: raw)?.displayName ?? raw }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        formatter.isLenient = false
        return formatter
    }()
    static func day(_ value: Int64) -> String {
        let raw = String(value)
        guard let date = dayFormatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    static func tokens(_ row: Database.ToolTotals) -> Int64 {
        ToolKind(rawValue: row.tool)?.totalTokens(row) ?? (row.input + row.output + row.cacheRead)
    }
}
