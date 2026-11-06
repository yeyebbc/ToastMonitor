import Foundation

/// A value-only boundary: the native popup never starts collection, reads credentials,
/// or reaches into provider singletons. The application supplies facts and actions.
struct WindowsPopupPresentation {
    struct Quota: Equatable {
        let account: String
        let window: String
        let percent: Double?
        let reset: Int64?
        let error: String?
        let lastSync: Int64
    }
    struct Balance: Equatable {
        let provider: String
        let value: String?
        let credential: WindowsCredentialState
        let error: String?
        let updated: Date?
    }
    let snapshot: UsageQueryService.Snapshot?
    let configuration: UsagePeriodConfiguration
    let period: UsagePeriodSlot
    let fullTokens: Bool
    let quotaShowsRemaining: Bool
    let refreshing: Bool
    let databaseProblemDescription: String?
    let taskbarProblem: String?
    let message: String
    let sources: [SourceHealth]
    let quotas: [Quota]
    let balances: [Balance]
    let accountNotices: [String]
    let spent: String
    let spendLabel: String
    let spendNote: String
    let now: Date
    var databaseProblem: String? { databaseProblemDescription }
    func tokens(_ slot: UsagePeriodSlot) -> Int64 {
        guard let light = snapshot?.light else { return 0 }
        switch slot { case .today: return light.todayTokens; case .week: return light.weekTokens; case .month: return light.monthTokens; case .all: return light.allTokens }
    }
    func apiValue(_ slot: UsagePeriodSlot) -> Double {
        guard let light = snapshot?.light else { return 0 }
        switch slot { case .today: return light.apiValueToday; case .week: return light.apiValueWeek; case .month: return light.apiValueMonth; case .all: return light.apiValueAll }
    }
    var valueText: String {
        guard let snapshot, databaseProblem == nil else { return "—" }
        let models: [Database.ModelAgg]
        switch period {
        case .today: models = snapshot.modelAggsToday
        case .week: models = snapshot.modelAggs
        case .month: models = snapshot.modelAggsMonth
        case .all: models = snapshot.modelAggsAll
        }
        let known = models.reduce(0) { $0 + (Pricing.price(for: $1.model) != nil ? 1 : 0) }
        if !models.isEmpty && known == 0 { return "—" }
        return Format.money(apiValue(period)) + (known < models.count ? " · partial" : "")
    }
    func rows(_ slot: UsagePeriodSlot) -> [Database.ToolTotals] {
        guard let light = snapshot?.light else { return [] }
        switch slot { case .today: return light.byToolToday; case .week: return light.byToolWeek; case .month: return light.byToolMonth; case .all: return light.byToolAll }
    }
}

struct WindowsPopupActions {
    let refresh: () -> Void
    let selectPeriod: (UsagePeriodSlot) -> Void
    let settings: (WindowsSettingsSection?) -> Void
    let dashboard: () -> Void
    let quit: () -> Void
}

@MainActor
extension WindowsPopupPresentation {
    static func live(model: WindowsModel, sources: [SourceHealth], claude: ClaudeQuotaClient,
                     codex: CodexQuotaClient, grok: GrokQuotaClient, go: OpenCodeGoClient,
                     router: OpenRouterClient, command: CommandCodeQuotaClient,
                     deepseek: DeepSeekBillingClient) -> Self {
        let now = Date()
        var quotas: [Quota] = []
        var notices: [String] = []
        func append(_ account: String, _ window: String, _ percent: Double?, _ reset: Int64?, _ error: String?, _ sync: Int64) {
            quotas.append(Quota(account: account, window: window, percent: percent, reset: reset, error: error, lastSync: sync))
        }
        if claude.enabled {
            append("Claude \(claude.state.planType ?? "account")", "Weekly", claude.state.sevenDay.map { Double($0.usedPercent) }, claude.state.sevenDay?.resetAt, claude.state.error, claude.state.lastSync)
            if let window = claude.state.fiveHour { append("Claude", window.label, Double(window.usedPercent), window.resetAt, nil, claude.state.lastSync) }
            if let window = claude.state.sevenDayOpus { append("Claude", window.label, Double(window.usedPercent), window.resetAt, nil, claude.state.lastSync) }
        }
        if codex.enabled {
            let custom = UserDefaults.standard.string(forKey: "codexDisplayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = custom.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex \(codex.state.planType ?? "account")"
            let window = codex.state.windowSeconds.map { $0 >= 604800 ? "Weekly" : ($0 >= 86400 ? "Daily" : "\(max(1, $0 / 3600)) hours") } ?? "Quota"
            append(name, window, codex.state.primaryPct.map(Double.init), codex.state.resetAt, codex.state.error, codex.state.lastSync)
        }
        if grok.enabled { append("Grok \(grok.state.planName ?? "account")", "Quota", grok.state.usedPercent, grok.state.resetAt, grok.state.error, grok.state.lastSync) }
        if go.configured {
            func reset(_ seconds: Int64?) -> Int64? { seconds.map { go.state.lastSync + $0 } }
            append("OpenCode Go", "5 hours", go.state.rollingPct, reset(go.state.rollingReset), go.state.error, go.state.lastSync)
            append("OpenCode Go", "Weekly", go.state.weeklyPct, reset(go.state.weeklyReset), nil, go.state.lastSync)
            append("OpenCode Go", "Monthly", go.state.monthlyPct, reset(go.state.monthlyReset), nil, go.state.lastSync)
        } else {
            credentialNotice("OpenCode Go", WindowsCredentialState.accounts(["go-workspace-id", "go-auth-cookie"], legacyKeys: ["go_workspace_id", "go_auth_cookie"]), go.state.error, into: &notices)
        }
        if command.state.configured {
            append("Command Code \(command.state.planName ?? "plan")", "Monthly", command.state.monthlyUsedPercent, command.state.billingPeriodEnd.map { Int64($0.timeIntervalSince1970) }, command.state.error, command.state.lastSync)
        } else { credentialNotice("Command Code", WindowsCredentialState.accounts([CommandCodeQuotaClient.keychainAccount]), command.state.error, into: &notices) }
        let routerCredential = WindowsCredentialState.accounts(["or-keys", "openrouter-key"], legacyKeys: ["or_keys", "openrouter_key"])
        let deepseekCredential = WindowsCredentialState.accounts([DeepSeekBillingClient.keychainAccount], emptyIsDisconnected: true)
        let balances = [
            Balance(provider: "OpenRouter", value: router.state.accountBalance.map(Format.money), credential: routerCredential, error: router.state.error, updated: nil),
            Balance(provider: "DeepSeek", value: deepseek.state.balance?.formatted, credential: deepseekCredential, error: deepseek.state.balanceError ?? deepseek.state.spendError, updated: deepseek.state.balanceUpdated)
        ]
        let providerUsage: Double
        switch model.period {
        case .today: providerUsage = router.state.usageDaily
        case .week: providerUsage = router.state.usageWeekly
        case .month, .all: providerUsage = router.state.usageMonthly
        }
        let quality = model.quality(model.period)
        let spend = deepseek.spend(for: model.period, configuration: model.configuration, now: now)
        let rate = UserDefaults.standard.object(forKey: DeepSeekBilling.exchangeRateKey) as? Double ?? DeepSeekBilling.defaultCNYPerUSD
        let spent = DeepSeekBilling.combinedSpend(localUSD: (quality?.actual ?? 0) + providerUsage,
            coveredLocalUSD: quality?.deepseekActual ?? 0, spend: spend, cnyPerUSD: rate)
        return Self(snapshot: model.snapshot, configuration: model.configuration, period: model.period,
            fullTokens: model.fullTokens, quotaShowsRemaining: model.quotaShowsRemaining, refreshing: model.refreshing,
            databaseProblemDescription: model.databaseProblemDescription, taskbarProblem: model.taskbarProblem,
            message: model.message, sources: sources, quotas: quotas, balances: balances, accountNotices: notices,
            spent: spent, spendLabel: (model.period == .all && routerCredential == .stored ? "Spent · OR recent month" : "Spent")
                + (deepseek.state.kind == .platform && spend == nil ? " · partial" : ""),
            spendNote: "Spent combines recorded actual API spend and available provider billing, deduplicating covered DeepSeek usage. Value is estimated API-equivalent value. Subscription allocations and estimated costs are not spend.", now: now)
    }
    private static func credentialNotice(_ name: String, _ credential: WindowsCredentialState, _ error: String?, into notices: inout [String]) {
        switch credential {
        case .missing: break
        case .stored: notices.append(error.map { "\(name): \($0)" } ?? "\(name) · Loading saved account…")
        case .failure(let status): notices.append("\(name): Credential Manager error \(status). Reconnect in Accounts.")
        }
    }
}
