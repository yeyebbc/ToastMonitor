import Foundation
import SwiftCrossUI
import WinUI
import WinUIBackend
import UWP

private enum WindowsSettingsColors {
    static let error = Color.adaptive(
        light: Color(red: 196.0 / 255, green: 43.0 / 255, blue: 28.0 / 255),
        dark: Color(red: 1, green: 153.0 / 255, blue: 164.0 / 255))
}

struct WindowsSettingsView: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Text(model.settingsSection.rawValue).font(.title2).emphasized()
            WindowsSettingsTabs(selection: SwiftCrossUI.Binding(
                get: { WindowsSettingsSection.allCases.firstIndex(of: model.settingsSection) ?? 0 },
                set: { model.settingsSection = WindowsSettingsSection.allCases[$0] }))
                .frame(height: 76)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.message.isEmpty { Text(model.message).font(.caption).textSelectionEnabled() }
                    if let problem = model.databaseProblemDescription {
                        Text("\(problem). Open Data to restore a backup or recover the store.").foregroundColor(WindowsSettingsColors.error).font(.caption)
                    }
                    if model.settingsSection == .general { WindowsGeneralSettings() }
                    else if model.settingsSection == .appearance { WindowsAppearanceSettings() }
                    else if model.settingsSection == .sources { WindowsSourceSettings() }
                    else if model.settingsSection == .accounts {
                        WindowsAccountSettings()
                        WindowsSubscriptionSettings()
                    }
                    else if model.settingsSection == .data { WindowsDataSettings() }
                    else { WindowsAboutSettings() }
                }.frame(maxWidth: 620, alignment: .leading).padding(4)
            }
        }.padding(20).font(.system(size: 14))
    }
}

private struct WindowsGeneralSettings: View {
    @State private var model = WindowsModel.shared
    @State private var periods = UsagePeriodSettings.shared
    @State private var alerts = QuotaAlertManager.shared
    @State private var startup = WindowsStartup.isEnabled
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            WindowsSettingsGroup {
                WindowsSettingsToggle("Launch at sign-in", isOn: SwiftCrossUI.Binding(get: { startup }, set: { value in
                    do { try WindowsStartup.setEnabled(value); startup = WindowsStartup.isEnabled }
                    catch { model.message = "Startup setting failed: \(error.localizedDescription)" }
                }))
                Divider()
                WindowsSettingsToggle("Quota and renewal alerts", isOn: SwiftCrossUI.Binding(get: { alerts.enabled }, set: { alerts.setEnabled($0) }))
                Divider()
                WindowsSettingsRow("Alert when quota left is below") {
                    WindowsChoice(label: "Low quota alert threshold", options: QuotaAlertManager.thresholdChoices.map { "\(Int($0))%" },
                        selection: SwiftCrossUI.Binding(get: { QuotaAlertManager.thresholdChoices.firstIndex(of: alerts.threshold) ?? 0 },
                            set: { alerts.setThreshold(QuotaAlertManager.thresholdChoices[$0]) }))
                }.disabled(!alerts.enabled)
            }
            if !alerts.enabled { Text("Enable alerts to change the threshold.").font(.caption) }
            Text("Date Range").font(.headline)
            WindowsSettingsGroup {
                WindowsSettingsRow("Periods") {
                    WindowsChoice(label: "Usage period mode", options: UsagePeriodMode.allCases.map(\.title),
                        selection: SwiftCrossUI.Binding(get: { UsagePeriodMode.allCases.firstIndex(of: periods.mode) ?? 0 },
                            set: { periods.setMode(UsagePeriodMode.allCases[$0]); model.refresh() }))
                }
                if periods.mode == .calendar {
                    Divider()
                    WindowsSettingsRow("Week starts") {
                        WindowsChoice(label: "Week starts", options: UsageWeekStart.allCases.map(\.title),
                            selection: SwiftCrossUI.Binding(get: { UsageWeekStart.allCases.firstIndex(of: periods.weekStart) ?? 0 },
                                set: { periods.setWeekStart(UsageWeekStart.allCases[$0]); model.refresh() }))
                    }
                }
            }
            WindowsDisclosure("Window behavior") {
                Text("Taskbar text shows today's tokens. Click it to open Usage. With the taskbar readout available, Close or Escape hides a window while collection continues. If the taskbar host is unavailable, closing Usage quits and Escape does not hide it. Quit always ends collection.").font(.caption)
                Text("Windows uses native desktop alert dialogs, not Windows toast notifications. Appearance follows the system light/dark theme.").font(.caption)
            }
        }
    }
}

private struct WindowsSourceSettings: View {
    @State private var model = WindowsModel.shared
    @State private var health = SourceHealthHub.shared
    @State private var remote = HermesRemoteClient.shared
    @State private var feed = HermesRemoteClient.shared.feedURL
    @State private var feedValidation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data Sources").font(.headline)
            WindowsSettingsGroup {
                ForEach(ToolKind.allCases.filter { $0 != .openrouter }, id: \.rawValue) { tool in
                    WindowsSettingsRow(tool.displayName) {
                        if tool.supportsRemoteSource {
                            WindowsRadioChoice(label: "\(tool.displayName) source", options: ["Local", "Remote"],
                                selection: SwiftCrossUI.Binding(get: { tool.sourceIsRemote ? 1 : 0 },
                                    set: { model.setSource(tool, remote: $0 == 1) }))
                        } else { Text("Local only").font(.caption) }
                    }
                    if let error = health.sources.first(where: { $0.tool == tool.rawValue })?.error {
                        WindowsNotice(tool.displayName, detail: error, severity: .error)
                    }
                    if tool != .dsh { Divider() }
                }
            }
            Text("Remote Feed").font(.headline)
            WindowsSettingsGroup {
                HStack(spacing: 8) {
                    Text("Feed URL")
                    TextField("HTTPS feed URL", text: $feed)
                    WindowsAction("Save") {
                        feedValidation = model.saveFeed(feed) ? "" : "Feed URL was not saved. Use a supported HTTPS URL without embedded credentials, and check that the database is writable."
                    }
                    WindowsAction("Refresh feed") { remote.poll() }
                }
                if !feedValidation.isEmpty { Text(feedValidation).foregroundColor(WindowsSettingsColors.error).textSelectionEnabled() }
                if let error = remote.status.error { Text(error).foregroundColor(WindowsSettingsColors.error).textSelectionEnabled() }
            }
            Text("Collectors").font(.headline)
            WindowsSettingsGroup {
                WindowsSettingsRow("Collection health") { WindowsAction("Rescan now") { model.refreshAll() } }
                WindowsCollectorRow(values: ["Source", "Status", "Last Scan", "Imported", "Failed", "Time"])
                Divider()
                ForEach(health.sources, id: \.id) { source in
                    WindowsCollectorRow(values: [source.displayName,
                        source.error != nil ? "Failed" : (source.failedRows > 0 ? "Partial" : (source.lastScan == 0 ? "Not scanned" : (source.isStale ? "Stale" : "Synced"))),
                        source.lastScan > 0 ? WindowsUI.date(source.lastScan) : "—",
                        "\(source.lastRows)", "\(source.failedRows)", "\(Int(source.durationMs)) ms"])
                    if let error = source.error { Text(error).foregroundColor(WindowsSettingsColors.error).font(.caption) }
                }
            }
            WindowsDisclosure("Source help") {
                Text("Local sources read the original tool logs under your Windows user profile. Remote sources ingest the configured usage feed; selecting Remote does not run a local parser for that tool.").font(.caption)
                Text("Use a feed without embedded passwords or tokens. Credentials are never saved in a source URL. WSL distributions are not automatically discovered; configure a supported remote feed for WSL or another computer. macOS Cowork containers and macOS-only browser/Keychain imports are unavailable on Windows.").font(.caption)
            }
        }
    }
}

private struct WindowsAccountSettings: View {
    @State private var model = WindowsModel.shared
    @State private var claude = ClaudeQuotaClient.shared
    @State private var codex = CodexQuotaClient.shared
    @State private var grok = GrokQuotaClient.shared
    @State private var go = OpenCodeGoClient.shared
    @State private var router = OpenRouterClient.shared
    @State private var command = CommandCodeQuotaClient.shared
    @State private var deepseek = DeepSeekBillingClient.shared
    @State private var workspace = ""
    @State private var goCookie = ""
    @State private var routerKey = ""
    @State private var commandCookie = ""
    @State private var deepseekSecret = ""
    @State private var deepseekKind: String? = "Platform session"
    @State private var codexBilling = Database.shared.setting("codex_billing_mode") ?? "api"
    @State private var codexName = UserDefaults.standard.string(forKey: "codexDisplayName") ?? ""
    @State private var credentialFailure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts").font(.headline)
            if let credentialFailure { WindowsNotice("Account action failed", detail: credentialFailure, severity: .error) }
            WindowsSettingsGroup {
            WindowsProviderGroup("Claude", status: claude.enabled ? (claude.state.sevenDay != nil ? "Connected" : "Polling enabled") : "Polling off", error: claude.state.error) {
                WindowsSettingsToggle("Poll Claude quota using Claude Code login", isOn: SwiftCrossUI.Binding(get: { claude.enabled }, set: { claude.setEnabled($0) }))
                Text("Sign in with Claude Code for Windows. If renewal fails, sign in again in the CLI.").font(.caption)
            }
            WindowsProviderGroup("OpenCode Go", credentialState: WindowsCredentialState.accounts(["go-workspace-id", "go-auth-cookie"], legacyKeys: ["go_workspace_id", "go_auth_cookie"]), error: go.state.error) {
            Text("Workspace ID")
            TextField("Workspace ID", text: $workspace)
            Text("Session cookie")
            SecureField("OpenCode session cookie", text: $goCookie)
            HStack {
                WindowsAction("Save Go credentials") {
                    credentialFailure = nil
                    if go.provision(workspaceId: workspace, cookie: goCookie) { goCookie = ""; model.message = "OpenCode Go credentials saved securely." }
                    else { credentialFailure = "OpenCode Go: \(go.state.error ?? "Credentials could not be saved.")" }
                }.disabled(workspace.isEmpty || goCookie.isEmpty)
                WindowsAction("Disconnect Go") { go.clear(); goCookie = "" }
                WindowsAction("Open Go account") { model.open("https://opencode.ai/workspace") }
            }
            }
            WindowsProviderGroup("Codex", status: codex.enabled ? (codex.state.primaryPct != nil ? "Connected" : "Polling enabled") : "Polling off", error: codex.state.error) {
                WindowsSettingsToggle("Poll Codex quota using Codex login", isOn: SwiftCrossUI.Binding(get: { codex.enabled }, set: { codex.setEnabled($0) }))
                WindowsSettingsRow("Name") {
                    TextField("Codex display name", text: SwiftCrossUI.Binding(get: { codexName }, set: {
                        codexName = $0
                        UserDefaults.standard.set($0, forKey: "codexDisplayName")
                        model.refresh()
                    }))
                }
                Text("Cost accounting")
                WindowsRadioChoice(label: "Codex cost accounting", options: ["API usage", "Covered by subscription"],
                    selection: SwiftCrossUI.Binding(get: { codexBilling == "api" ? 0 : 1 }, set: {
                        let mode = $0 == 0 ? "api" : "subscription"
                        codexBilling = mode
                        model.billingCoordinator.set(mode, restoreSelection: { codexBilling = $0 })
                    }))
                Text("Subscription-covered usage retains tokens and calls but excludes estimated API cost from spend. Sign in with Codex for Windows.").font(.caption)
            }
            WindowsProviderGroup("Command Code", credentialState: WindowsCredentialState.accounts([CommandCodeQuotaClient.keychainAccount]), error: command.state.error) {
            Text("Session cookie")
            SecureField("Command Code session cookie", text: $commandCookie)
            HStack {
                WindowsAction("Save Command Code cookie") {
                    credentialFailure = nil
                    if command.provision(cookie: commandCookie) { commandCookie = ""; model.message = "Command Code credential saved securely." }
                    else { credentialFailure = "Command Code: \(command.state.error ?? "Credential could not be saved.")" }
                }.disabled(commandCookie.isEmpty)
                WindowsAction("Disconnect Command Code") { command.clear(); commandCookie = "" }
            }
            }
            WindowsProviderGroup("Grok", status: grok.enabled ? (grok.state.usedPercent != nil ? "Connected" : "Polling enabled") : "Polling off", error: grok.state.error) {
                WindowsSettingsToggle("Poll Grok quota using Grok CLI login", isOn: SwiftCrossUI.Binding(get: { grok.enabled }, set: { grok.setEnabled($0) }))
                Text("Sign in with Grok CLI for Windows. Quota polling is optional.").font(.caption)
            }
            WindowsProviderGroup("OpenRouter", credentialState: WindowsCredentialState.accounts(["or-keys", "openrouter-key"], legacyKeys: ["or_keys", "openrouter_key"]), error: router.state.error) {
            Text("API or management key")
            SecureField("OpenRouter API or management key", text: $routerKey)
            HStack {
                WindowsAction("Replace keys") {
                    credentialFailure = nil
                    if router.setKey(routerKey) { routerKey = ""; model.message = "OpenRouter key saved securely." }
                    else { credentialFailure = "OpenRouter: \(router.state.error ?? "Key could not be saved. Check the key format and try again.")" }
                }.disabled(routerKey.isEmpty)
                WindowsAction("Add key") {
                    credentialFailure = nil
                    if router.addKey(routerKey) { routerKey = ""; model.message = "OpenRouter key added securely." }
                    else { credentialFailure = "OpenRouter: \(router.state.error ?? "Key could not be added. Check the key format and try again.")" }
                }.disabled(routerKey.isEmpty)
                WindowsAction("Disconnect OpenRouter") {
                    credentialFailure = nil
                    if router.setKey(nil) { routerKey = "" }
                    else { credentialFailure = "OpenRouter: \(router.state.error ?? "Keys could not be removed.")" }
                }
                WindowsAction("Open API keys") { model.open("https://openrouter.ai/settings/keys") }
            }
            Text("\(router.state.keyCount) keys reported by provider. Management keys can report account-wide balances; ordinary keys may expose only their own limits.").font(.caption)
            }
            WindowsProviderGroup("DeepSeek", credentialState: WindowsCredentialState.accounts([DeepSeekBillingClient.keychainAccount], legacyKeys: [DeepSeekBillingClient.configuredKey], emptyIsDisconnected: true), error: deepseek.connectionError ?? deepseek.state.balanceError ?? deepseek.state.spendError, preserveMissingError: deepseek.connectionError != nil) {
            Text("Credential type")
            WindowsChoice(label: "DeepSeek credential type", options: ["Platform session", "API key"],
                selection: SwiftCrossUI.Binding(get: { deepseekKind == "API key" ? 1 : 0 }, set: { deepseekKind = $0 == 1 ? "API key" : "Platform session" })).frame(width: 230)
            Text("Session token or API key")
            SecureField("DeepSeek session token or API key", text: $deepseekSecret)
            HStack {
                WindowsAction(deepseek.connecting ? "Connecting…" : "Connect DeepSeek") { deepseek.connect(deepseekSecret, kind: deepseekKind == "API key" ? .apiKey : .platform)
                deepseekSecret = ""
                                 }.disabled(deepseekSecret.isEmpty || deepseek.connecting)
                WindowsAction("Disconnect DeepSeek") { deepseek.disconnect() }.disabled(deepseek.connecting)
                WindowsAction("Open DeepSeek platform") { model.open("https://platform.deepseek.com") }
            }
            Text("Windows opens the default browser. Automatic active-tab/Safari credential import is unsupported; paste your own platform session or API key. API keys expose balance only where the provider supports it; platform sessions enable experimental billed-spend queries.").font(.caption)
            }
            }
            WindowsDisclosure("Credential privacy") {
                Text("Secrets are protected by Windows Credential Manager. Saved secrets are not read back into fields. Connection failures remain visible.").font(.caption)
            }
        }
    }
}

private struct WindowsProviderGroup<Content: View>: View {
    let name: String
    let status: String
    let error: String?
    let content: Content
    @State private var expanded = false
    init(_ name: String, status: String, error: String?, @ViewBuilder content: () -> Content) {
        self.name = name; self.status = status; self.error = error; self.content = content()
    }
    init(_ name: String, credentialState: WindowsCredentialState, error: String?, preserveMissingError: Bool = false, @ViewBuilder content: () -> Content) {
        self.name = name
        switch credentialState {
        case .missing: self.status = preserveMissingError ? "Needs attention" : "Not connected"; self.error = preserveMissingError ? error : nil
        case .stored: self.status = error == nil ? "Credentials saved" : "Needs attention"; self.error = error
        case .failure(let code): self.status = "Credential unavailable"; self.error = "Windows Credential Manager error \(code). \(error ?? "Reconnect to retry.")"
        }
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                WindowsProviderDisclosure(name: name, expanded: $expanded).frame(width: 28, height: 32)
                WindowsSettingsToolIcon(name: name).frame(width: 20, height: 22)
                Text(name)
                Spacer()
                Text(status).font(.caption)
            }
            if let error { WindowsNotice(name, detail: error, severity: .error) }
            if expanded { content }
            if name != "DeepSeek" { Divider() }
        }
    }
}

private struct WindowsAppearanceSettings: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Popover / Usage").font(.headline)
            WindowsSettingsGroup {
                WindowsSettingsRow("Token count") {
                    WindowsChoice(label: "Token count display", options: ["Compact · 3.7M", "Exact · 3,712,456"],
                        selection: SwiftCrossUI.Binding(get: { model.fullTokens ? 1 : 0 }, set: { model.fullTokens = $0 == 1 }))
                }
                Divider()
                WindowsSettingsRow("Quota") {
                    WindowsChoice(label: "Quota display", options: ["Used", "Remaining"],
                        selection: SwiftCrossUI.Binding(get: { model.quotaShowsRemaining ? 1 : 0 }, set: { model.quotaShowsRemaining = $0 == 1 }))
                }
            }
            Text("Changes apply immediately. Windows typography and colors follow the system theme.").font(.caption)
        }
    }
}

private struct WindowsSubscriptionSettings: View {
    @State private var model = WindowsModel.shared
    @State private var editingID: Int64 = 0
    @State private var name = ""
    @State private var plan: String? = ""
    @State private var cycle: String? = "monthly"
    @State private var price = ""
    @State private var currency = "USD"
    @State private var start = Calendar.current.startOfDay(for: Date())
    @State private var end = Calendar.current.startOfDay(for: Date())
    @State private var noEndDate = true
    @State private var validation = ""
    @State private var showingForm = false
    @State private var deleteConfirmation: Int64?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscriptions").font(.headline)
            WindowsSettingsGroup {
            if model.snapshot == nil { Text("Loading recorded subscriptions…") }
            ForEach(model.snapshot?.light.subscriptions ?? [], id: \.id) { sub in
                HStack {
                    Text("\(sub.name) · \(sub.currency) \(String(format: "%.2f", sub.price)) / \(sub.cycle)")
                    Spacer()
                    WindowsAction("Edit") { [id = sub.id] in
                        if let current = model.snapshot?.light.subscriptions.first(where: { $0.id == id }) { load(current) }
                    }
                    WindowsAction("Delete") { deleteConfirmation = sub.id }
                }
                if deleteConfirmation == sub.id {
                    HStack {
                        Text("Delete this subscription record?")
                        WindowsAction("Delete record") { model.deleteSubscription(sub.id); deleteConfirmation = nil }
                        WindowsAction("Cancel") { deleteConfirmation = nil }
                    }
                }
            }
            Divider()
            WindowsAction("Add subscription…") { showingForm = true; editingID = 0; name = ""; price = ""; noEndDate = true; start = Calendar.current.startOfDay(for: Date()); validation = "" }
                .fixedSize(horizontal: true, vertical: false)
            if showingForm || model.showSubscriptionEditor {
            Text(editingID == 0 ? "Add subscription" : "Edit subscription").font(.headline)
            Text("Subscription name")
            TextField("Subscription name", text: $name)
            HStack {
                Text("Provider plan").frame(width: 180, alignment: .leading)
                WindowsChoice(label: "Subscription provider plan", options: ["Not linked", "OpenCode Go", "OpenRouter", "Claude", "OpenAI", "Grok"],
                    selection: SwiftCrossUI.Binding(get: { ["", "go", "openrouter", "claude", "openai", "grok"].firstIndex(of: plan ?? "") ?? 0 },
                        set: { plan = ["", "go", "openrouter", "claude", "openai", "grok"][$0] })).frame(width: 240)
            }
            HStack {
                Text("Billing cycle").frame(width: 180, alignment: .leading)
                WindowsChoice(label: "Subscription billing cycle", options: ["Weekly", "Monthly", "Yearly"],
                    selection: SwiftCrossUI.Binding(get: { ["weekly", "monthly", "yearly"].firstIndex(of: cycle ?? "monthly") ?? 1 },
                        set: { cycle = ["weekly", "monthly", "yearly"][$0] })).frame(width: 240)
            }
            Text("Price · nonnegative amount")
            WindowsPriceField(text: $price).frame(width: 240)
            Text("Currency · three-letter code")
            TextField("Currency code", text: $currency).frame(width: 240)
            DatePicker("Start date", selection: $start, in: WindowsUI.datePickerRange, displayedComponents: .date)
            WindowsSettingsToggle("No end date", isOn: $noEndDate)
            if !noEndDate { DatePicker("End date", selection: $end, in: WindowsUI.datePickerRange, displayedComponents: .date) }
            if !validation.isEmpty { Text(validation).foregroundColor(WindowsSettingsColors.error).textSelectionEnabled() }
            HStack {
                WindowsAction("Save subscription") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                WindowsAction("Cancel editing") { showingForm = false; model.showSubscriptionEditor = false; validation = "" }
            }
            }
            }
            Text("Record the price actually paid. Each cycle is allocated over its real dates.").font(.caption)
        }
    }
    private func load(_ sub: Database.Subscription) {
        editingID = sub.id; name = sub.name; plan = sub.plan; cycle = sub.cycle
        price = String(sub.price); currency = sub.currency
        start = Date(timeIntervalSince1970: Double(sub.startDate))
        end = sub.endDate == 0 ? start : Date(timeIntervalSince1970: Double(sub.endDate))
        noEndDate = sub.endDate == 0; showingForm = true; validation = ""
    }
    private func save() {
        validation = ""
        guard let amount = Double(price), amount.isFinite, amount >= 0 else {
            validation = "Enter a nonnegative numeric price."; return
        }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.utf8.count == 3, code.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {
            validation = "Enter a three-letter currency code, such as USD or CNY."; return
        }
        let startDate = Calendar.current.startOfDay(for: start)
        let endDate = Calendar.current.startOfDay(for: end)
        guard noEndDate || endDate > startDate else {
            validation = "End date must be after the start date, or choose No end date."; return
        }
        if !model.saveSubscription(Database.Subscription(id: editingID, name: name, plan: plan ?? "", startDate: Int64(startDate.timeIntervalSince1970), endDate: noEndDate ? 0 : Int64(endDate.timeIntervalSince1970), cycle: cycle ?? "monthly", price: amount, currency: code)) {
            validation = "Subscription was not saved. Check the fields and that the database is writable."
        }
    }
}

private struct WindowsDataSettings: View {
    @State private var model = WindowsModel.shared
    @State private var restoreCandidate: URL?
    @State private var clearPhrase = ""
    @State private var rebuildPreview: Database.LocalRebuildPreview?
    @State private var rebuildBusy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup").font(.headline)
            WindowsSettingsGroup {
                WindowsSettingsRow("Export database") {
                    WindowsAction("Export…") { WindowsSaveDialog.exportDatabase() }
                }
                Divider()
                WindowsSettingsRow("Managed recovery copy") {
                    WindowsAction("Create backup") { model.backup() }
                    WindowsAction("Refresh list") { model.reloadBackups() }
                }
            }
            Text("Backups preserve recovery state. Exports remove known legacy credential keys; usage and project metadata remain sensitive.").font(.caption)
            Text("Database: \(Database.shared.dbPath)").font(.caption).textSelectionEnabled()
            Text("Rebuild Claude Code and Codex").font(.headline)
            WindowsSettingsGroup {
                WindowsSettingsRow("Rebuild local usage data") {
                    WindowsAction(rebuildBusy ? "Working…" : "Preview") { previewRebuild() }.disabled(model.databaseProblem != nil)
                }
                if let preview = rebuildPreview {
                    Text("Rebuildable: \(preview.sessions) sessions · \(preview.turns) records · \(Format.full(preview.tokens)) tokens.").font(.caption)
                    Text("Preserved history: \(preview.keptSessions) sessions · \(preview.keptTurns) records · \(Format.full(preview.keptTokens)) tokens whose logs are unavailable. This preview does not change data.").font(.caption)
                    WindowsAction("Close preview") { rebuildPreview = nil }
                }
            }
            if model.databaseProblem != nil {
                WindowsSettingsGroup {
                Text("If no usable backup exists, type RECOVER below to preserve the unusable store and create a new one.")
                TextField("Type RECOVER", text: $clearPhrase)
                WindowsAction("Preserve unusable store and start fresh") { model.recoverDatabase(); clearPhrase = "" }.disabled(clearPhrase != "RECOVER")
                }
            }
            Text("Managed backups").font(.headline)
            WindowsSettingsGroup {
            if model.backups.isEmpty { Text("No managed backups. Create one before changing or moving your data.") }
            ForEach(model.backups, id: \.path) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backup.lastPathComponent).textSelectionEnabled()
                        Text(backupDetail(backup)).font(.caption)
                    }
                    Spacer()
                    WindowsAction("Restore…") { restoreCandidate = backup }
                }
            }
            if let backup = restoreCandidate {
                Text("Replace current data with \(backup.lastPathComponent)? A pre-restore backup is mandatory before replacement.")
                HStack {
                    WindowsAction("Restore selected backup") {
                        guard let selected = restoreCandidate else { return }
                        model.restore(selected); restoreCandidate = nil
                    }
                    WindowsAction("Cancel restore") { restoreCandidate = nil }
                }
            }
            }
            Text("Clear collected data").font(.headline)
            WindowsSettingsGroup {
            Text("This removes database usage and collection state, not your original tool logs. Collection can import the logs again. A safety backup must succeed first. Type CLEAR to confirm.")
            TextField("Type CLEAR", text: $clearPhrase)
            WindowsAction("Back up and clear data") { model.clearData(); clearPhrase = "" }.disabled(clearPhrase != "CLEAR")
            }
        }.disabled(model.maintenanceBusy || rebuildBusy)
    }
    private func previewRebuild() {
        guard model.databaseProblem == nil else { return }
        rebuildBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = DataMaintenance.preview()
            DispatchQueue.main.async { rebuildPreview = preview; rebuildBusy = false }
        }
    }
    private func backupDetail(_ backup: URL) -> String {
        guard let values = try? backup.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "Details unavailable" }
        let date = values.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
        let size = values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unknown size"
        return "\(date) · \(size)"
    }
}

private struct WindowsAboutSettings: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WindowsSettingsGroup {
                WindowsBuildInformation()
            }
            WindowsSettingsGroup {
                WindowsSettingsRow("Windows updates") {
                    WindowsAction("Open Windows builds") { model.open("https://github.com/yeyebbc/ToastMonitor/actions/workflows/windows.yml") }
                }
            }
            Text("Install Windows updates manually. Upstream macOS packages are not Windows installers.").font(.caption)
            WindowsDisclosure("About and help") {
                Text("ToastMonitor uses the shared local parsers, SQLite queries and pricing calculations.").font(.caption)
                WindowsAction("Windows setup help") { model.open("https://github.com/yeyebbc/ToastMonitor/blob/main/docs/windows-port.md") }
                WindowsAction("Report an issue") { model.open("https://github.com/yeyebbc/ToastMonitor/issues") }
                WindowsAction("Source repository") { model.open("https://github.com/yeyebbc/ToastMonitor") }
                Text("Explorer taskbar embedding is a native Windows integration. Unsupported taskbar layouts and Explorer errors are reported rather than replaced by a tray icon.").font(.caption)
            }
        }
    }
}

private struct WindowsSettingsToggle: View {
    let label: String
    let isOn: SwiftCrossUI.Binding<Bool>

    init(_ label: String, isOn: SwiftCrossUI.Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            WindowsSettingsSwitch(label: label, isOn: isOn)
        }
    }
}

/// SwiftCrossUI's switch style separates the text from the native automation peer.
private struct WindowsSettingsSwitch: WinUIElementRepresentable {
    let label: String
    let isOn: SwiftCrossUI.Binding<Bool>

    @MainActor
    final class Coordinator {
        var binding: SwiftCrossUI.Binding<Bool>
        var label: String?
        var updating = false
        var removeHandler: (() -> Void)?

        init(binding: SwiftCrossUI.Binding<Bool>) { self.binding = binding }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: isOn) }

    func makeWinUIElement(context: Context) -> WinUI.ToggleSwitch {
        let control = WinUI.ToggleSwitch()
        control.offContent = ""
        control.onContent = ""
        control.minWidth = 0
        control.padding = WinUI.Thickness(left: 0, top: 0, right: 0, bottom: 0)
        WinUI.AutomationProperties.setName(control, label)
        context.coordinator.label = label
        let subscription = control.toggled.addHandler { [weak coordinator = context.coordinator, weak control] _, _ in
            guard let coordinator, let control, !coordinator.updating else { return }
            coordinator.binding.wrappedValue = control.isOn
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }

    func updateWinUIElement(_ control: WinUI.ToggleSwitch, context: Context) {
        context.coordinator.binding = isOn
        if context.coordinator.label != label {
            WinUI.AutomationProperties.setName(control, label)
            context.coordinator.label = label
        }
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        if control.isOn != isOn.wrappedValue {
            context.coordinator.updating = true
            control.isOn = isOn.wrappedValue
            context.coordinator.updating = false
        }
    }

    static func dismantleWinUIElement(_ control: WinUI.ToggleSwitch, coordinator: Coordinator) {
        coordinator.removeHandler?()
        coordinator.removeHandler = nil
    }
}

private struct WindowsSettingsRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack(spacing: 12) {
            if WindowsSettingsToolIcon.symbols[label] != nil {
                WindowsSettingsToolIcon(name: label).frame(width: 20, height: 22)
            }
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            content
        }
    }
}

private struct WindowsSettingsGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(WindowsSettingsGroupSurface())
    }
}

private struct WindowsSettingsGroupSurface: WinUIElementRepresentable {
    func makeWinUIElement(context: Context) -> WinUI.Border { WinUI.Border() }
    func updateWinUIElement(_ control: WinUI.Border, context: Context) {
        let dark = context.environment.colorScheme == .dark
        control.background = WinUI.SolidColorBrush(UWP.Color(a: 10, r: dark ? 255 : 0, g: dark ? 255 : 0, b: dark ? 255 : 0))
        control.borderBrush = WinUI.SolidColorBrush(UWP.Color(a: 22, r: dark ? 255 : 0, g: dark ? 255 : 0, b: dark ? 255 : 0))
        control.borderThickness = .init(left: 1, top: 1, right: 1, bottom: 1)
        control.cornerRadius = .init(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Border, context: Context) -> ViewSize {
        ViewSize(proposal.width ?? 0, proposal.height ?? 0)
    }
}

/// Settings-only vertical item content; Dashboard retains its text-only top tabs.
private struct WindowsSettingsTabs: WinUIElementRepresentable {
    let selection: SwiftCrossUI.Binding<Int>
    typealias Coordinator = WindowsTopTabs.Coordinator
    func makeCoordinator() -> Coordinator { Coordinator(selection) }
    func makeWinUIElement(context: Context) -> WinUI.NavigationView {
        let control = WinUI.NavigationView()
        control.paneDisplayMode = .top
        control.isPaneToggleButtonVisible = false
        control.isBackButtonVisible = .collapsed
        control.isSettingsVisible = false
        control.isTitleBarAutoPaddingEnabled = false
        let glyphs = ["\u{E713}", "\u{E790}", "\u{E896}", "\u{E77B}", "\u{E74E}", "\u{E895}"]
        for (index, section) in WindowsSettingsSection.allCases.enumerated() {
            let content = WinUI.StackPanel(); content.spacing = 3
            content.horizontalAlignment = .center
            content.margin = .init(left: 0, top: 0, right: 0, bottom: 8)
            let icon = WinUI.TextBlock(); icon.text = glyphs[index]
            icon.fontFamily = WinUI.FontFamily("Segoe MDL2 Assets"); icon.fontSize = 20
            icon.horizontalAlignment = .center
            WinUI.AutomationProperties.setAccessibilityView(icon, .raw)
            let label = WinUI.TextBlock(); label.text = section.rawValue; label.fontSize = 12
            label.horizontalAlignment = .center
            content.children.append(icon); content.children.append(label)
            let item = WinUI.NavigationViewItem(); item.content = content
            WinUI.AutomationProperties.setName(item, section.rawValue)
            context.coordinator.items.append(item); control.menuItems.append(item)
        }
        WinUI.AutomationProperties.setName(control, "Settings pages")
        let subscription = control.selectionChanged.addHandler { [weak coordinator = context.coordinator] _, arguments in
            guard let coordinator, !coordinator.updating, let item = arguments?.selectedItemContainer,
                  let index = coordinator.items.firstIndex(where: { $0 == item }),
                  coordinator.selection.wrappedValue != index else { return }
            coordinator.selection.wrappedValue = index
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.NavigationView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = selection
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        let index = selection.wrappedValue
        if coordinator.items.indices.contains(index), !coordinator.items[index].isSelected {
            coordinator.updating = true; control.selectedItem = coordinator.items[index]; coordinator.updating = false
        }
    }
    static func dismantleWinUIElement(_ control: WinUI.NavigationView, coordinator: Coordinator) { coordinator.removeHandler?() }
}

private struct WindowsCollectorRow: View {
    let values: [String]
    var body: some View {
        HStack(spacing: 8) {
            Text(values[0]).frame(width: 106, alignment: .leading)
            Text(values[1]).frame(width: 62, alignment: .leading)
            Text(values[2]).frame(maxWidth: .infinity, alignment: .leading)
            Text(values[3]).frame(width: 48, alignment: .trailing)
            Text(values[4]).frame(width: 34, alignment: .trailing)
            Text(values[5]).frame(width: 44, alignment: .trailing)
        }.font(.caption)
    }
}

private struct WindowsSettingsToolIcon: WinUIElementRepresentable {
    let name: String
    static let symbols: [String: (String, UInt32)] = [
        "Claude": ("\u{E734}", 0xC66343), "Claude Code": ("\u{E734}", 0xC66343),
        "Codex": ("\u{E943}", 0x577BD8), "OpenCode": ("\u{E756}", 0x248A3D),
        "Hermes": ("\u{E7C1}", 0x8944AB), "Oh My Pi": ("\u{E950}", 0x00889C),
        "DeepSeek Harness": ("\u{E7C3}", 0x2F49D1), "DeepSeek": ("\u{E7C3}", 0x2F49D1),
        "OpenCode Go": ("\u{E756}", 0x248A3D), "Command Code": ("\u{E756}", 0x8F7346),
        "Grok": ("\u{E943}", 0x555555), "OpenRouter": ("\u{E895}", 0x7624F4)
    ]
    func makeWinUIElement(context: Context) -> WinUI.TextBlock {
        let control = WinUI.TextBlock()
        control.fontFamily = WinUI.FontFamily("Segoe MDL2 Assets"); control.fontSize = 18
        control.verticalAlignment = .center
        WinUI.AutomationProperties.setAccessibilityView(control, .raw)
        return control
    }
    func updateWinUIElement(_ control: WinUI.TextBlock, context: Context) {
        guard let (glyph, color) = Self.symbols[name] else { return }
        control.text = glyph
        control.foreground = WinUI.SolidColorBrush(UWP.Color(a: 255,
            r: UInt8((color >> 16) & 255), g: UInt8((color >> 8) & 255), b: UInt8(color & 255)))
    }
}

private struct WindowsProviderDisclosure: WinUIElementRepresentable {
    let name: String
    let expanded: SwiftCrossUI.Binding<Bool>
    typealias Coordinator = WindowsDisclosureToggle.Coordinator
    func makeCoordinator() -> Coordinator { Coordinator(expanded) }
    func makeWinUIElement(context: Context) -> WinUI.ToggleButton {
        let control = WinUI.ToggleButton()
        let icon = context.coordinator.text
        icon.fontFamily = WinUI.FontFamily("Segoe MDL2 Assets"); icon.fontSize = 12
        WinUI.AutomationProperties.setAccessibilityView(icon, .raw)
        control.content = icon
        control.padding = .init(left: 0, top: 0, right: 0, bottom: 0)
        control.minWidth = 0
        let subscription = control.click.addHandler { [weak coordinator = context.coordinator, weak control] _, _ in
            guard let coordinator, let control else { return }
            coordinator.binding.wrappedValue = control.isChecked == true
        }
        context.coordinator.removeHandler = { subscription.dispose() }
        return control
    }
    func updateWinUIElement(_ control: WinUI.ToggleButton, context: Context) {
        context.coordinator.binding = expanded
        context.coordinator.text.text = expanded.wrappedValue ? "\u{E70D}" : "\u{E76C}"
        control.isChecked = expanded.wrappedValue
        control.isEnabled = context.environment.isEnabled
        control.requestedTheme = context.environment.colorScheme == .dark ? .dark : .light
        WinUI.AutomationProperties.setName(control, "\(name) settings, \(expanded.wrappedValue ? "expanded" : "collapsed")")
    }
    static func dismantleWinUIElement(_ control: WinUI.ToggleButton, coordinator: Coordinator) { coordinator.removeHandler?() }
}
