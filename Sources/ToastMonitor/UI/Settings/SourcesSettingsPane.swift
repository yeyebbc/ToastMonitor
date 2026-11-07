import SwiftUI

struct AccountsSettingsPane: View {
    var body: some View {
        AccountsSettingsSection()
        SubscriptionSettingsSection()
    }
}

/// Settings › Sources: each tool's usage inputs and collector status.
struct SourcesSettingsPane: View {
    @State private var sources: [ToolKind: UsageSources] = [:]
    @State private var sourceSaves: [ToolKind: (id: UUID, saved: Bool?)] = [:]

    private let tools = ToolKind.allCases.filter { $0 != .openrouter }

    var body: some View {
        Section("Data Sources") {
            ForEach(tools) { tool in
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        if tool.supportsRemoteSource {
                            HStack(spacing: 12) {
                                Toggle("Local", isOn: sourceBinding(for: tool, remote: false))
                                    .accessibilityLabel("\(tool.displayName) Local")
                                Toggle("Remote", isOn: sourceBinding(for: tool, remote: true))
                                    .accessibilityLabel("\(tool.displayName) Remote")
                            }
                            .toggleStyle(.checkbox)
                            .disabled(sourceSaves[tool] != nil && sourceSaves[tool]?.saved == nil)
                        } else {
                            Text("Local only")
                        }
                    } label: {
                        sourceLabel(tool)
                    }
                    if sources[tool]?.includesRemote == true {
                        RemoteFeedSettingsRow(tool: tool)
                    }
                }
            }
        }
        .onAppear {
            sources = Dictionary(uniqueKeysWithValues: tools.map { ($0, $0.sources()) })
        }

        CollectorStatusSection(sources: sources)
    }

    private func sourceLabel(_ tool: ToolKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tool.symbol)
                .foregroundStyle(tool.color)
                .frame(width: 18)
            Text(tool.displayName)
            if let saved = sourceSaves[tool]?.saved {
                Image(systemName: saved ? "checkmark" : "exclamationmark.triangle")
                    .foregroundStyle(saved ? TMDesign.accent : TMDesign.danger)
                    .accessibilityLabel(saved ? "Saved" : "Save failed")
            }
        }
    }

    private func sourceBinding(for tool: ToolKind, remote: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let current = sources[tool] ?? .local
                return remote ? current.includesRemote : current.includesLocal
            },
            set: { enabled in
                if let save = sourceSaves[tool], save.saved == nil { return }
                let current = sources[tool] ?? .local
                let updated = UsageSources(local: remote ? current.includesLocal : enabled,
                                           remote: remote ? enabled : current.includesRemote)
                let id = UUID()
                sourceSaves[tool] = (id, nil)
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = tool.setSources(updated)
                    DispatchQueue.main.async {
                        sourceSaves[tool] = (id, ok)
                        if ok {
                            sources[tool] = updated
                            if !updated.includesLocal {
                                SourceHealthHub.shared.remove(tool: tool, mode: "local")
                            }
                            if !updated.includesRemote {
                                SourceHealthHub.shared.remove(tool: tool, mode: "remote")
                            }
                            if updated.includesLocal && !current.includesLocal {
                                CollectorEngine.shared.scheduleScan()
                            }
                            if updated.includesRemote && !current.includesRemote,
                               !HermesRemoteClient.shared.feedURL(for: tool).isEmpty {
                                HermesRemoteClient.shared.poll(tool: tool)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if sourceSaves[tool]?.id == id { sourceSaves[tool] = nil }
                        }
                    }
                }
            }
        )
    }
}

private struct RemoteFeedSettingsRow: View {
    let tool: ToolKind

    @ObservedObject private var health = SourceHealthHub.shared
    @State private var feedURL = ""
    @State private var saving = false
    @State private var savedMessage: String?
    @State private var feedError: String?

    private let remote = HermesRemoteClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Feed URL", text: $feedURL, prompt: Text("HTTPS or private range"))
                    .accessibilityLabel("\(tool.displayName) Feed URL")
                    .disabled(saving)
                Button("Save", action: save)
                    .disabled(saving)
                Button {
                    remote.poll(tool: tool)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Pull now")
                .accessibilityLabel("Pull \(tool.displayName) now")
                .disabled(saving || remote.feedURL(for: tool).isEmpty)
            }
            if let status = health.sources.first(where: { $0.tool == tool.rawValue && $0.mode == "remote" }) {
                if let error = status.error {
                    Text(error).foregroundStyle(TMDesign.danger)
                } else {
                    Text(status.lastRows > 0
                         ? "Synced \(Format.dateTime(status.lastScan)) · \(status.lastRows) new"
                         : "Synced \(Format.dateTime(status.lastScan)) · up to date")
                        .foregroundStyle(.secondary)
                }
            }
            if let savedMessage { Text(savedMessage).foregroundStyle(TMDesign.accent) }
            if let feedError { Text(feedError).foregroundStyle(TMDesign.danger) }
        }
        .onAppear { feedURL = remote.feedURL(for: tool) }
        .onChange(of: feedURL) { _ in
            savedMessage = nil
            feedError = nil
        }
    }

    private func save() {
        let address = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        savedMessage = nil
        feedError = HermesRemoteClient.feedURLProblem(address)
        guard feedError == nil else { return }
        saving = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = HermesRemoteClient.shared.provision(url: address, for: tool)
            DispatchQueue.main.async {
                saving = false
                guard ok else {
                    feedError = "Save failed (database unavailable)"
                    return
                }
                savedMessage = address.isEmpty ? "Feed URL cleared" : "Saved"
                SourceHealthHub.shared.remove(tool: tool, mode: "remote")
                if !address.isEmpty { remote.poll(tool: tool) }
            }
        }
    }
}

/// Settings › Data: export, local rebuild, and the automatic backups.
struct DataSettingsPane: View {
    @ObservedObject private var app = AppState.shared
    @State private var preview: Database.LocalRebuildPreview?
    @State private var receipt: DataRepairReceipt?
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirmsRepair = false
    @State private var confirmsRestore = false
    /// Every managed snapshot (weekly automatic + pre-rebuild + pre-clear +
    /// manual export leftovers do NOT show here — export goes to a
    /// user-chosen path outside the managed directory). Newest first, same
    /// ordering DataMaintenance.pruneBackups uses to decide what survives.
    @State private var backups: [URL] = []
    @State private var pendingRestoreBackup: URL?

    var body: some View {
        Section {
            LabeledContent("Export database") {
                Button("Export…") { exportDatabase() }
                    .disabled(isWorking)
            }
        } header: {
            Text("Backup")
        }
        .onAppear { loadBackups() }

        Section {
            LabeledContent("Rebuild local usage data") {
                Button("Preview") { loadPreview() }
                    .disabled(isWorking)
            }
            if let preview {
                LabeledContent("Rebuilt from logs") {
                    Text(Self.scope(preview.turns, preview.sessions, preview.tokens))
                        .tmMonospacedDigit()
                }
                if preview.keptSessions > 0 {
                    LabeledContent("Kept, log no longer exists") {
                        Text(Self.scope(preview.keptTurns, preview.keptSessions, preview.keptTokens))
                            .tmMonospacedDigit()
                    }
                }
                HStack {
                    Spacer()
                    if receipt != nil {
                        Button("Restore Pre-Rebuild Backup…") { confirmsRestore = true }
                            .disabled(isWorking)
                    }
                    Button("Back Up and Rebuild…", role: .destructive) { confirmsRepair = true }
                        .disabled(isWorking || preview.turns == 0)
                }
            }
            if isWorking || message != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isWorking { ProgressView().controlSize(.small) }
                    if let message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Rebuild Claude Code and Codex")
        }
        .confirmationDialog("Rebuild Claude Code and Codex usage?", isPresented: $confirmsRepair) {
            Button("Back Up and Rebuild", role: .destructive) { repair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is created first. Sessions with a log on this Mac are read again; history whose log is gone is kept as it is.")
        }
        .confirmationDialog("Restore pre-rebuild backup?", isPresented: $confirmsRestore) {
            Button("Restore Backup", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
        }

        backupsSection
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { pendingRestoreBackup != nil },
                set: { if !$0 { pendingRestoreBackup = nil } })) {
                    Button("Restore Backup", role: .destructive) { restoreManaged() }
                    Button("Cancel", role: .cancel) { pendingRestoreBackup = nil }
                } message: {
                    Text("This replaces all current usage data, subscriptions and settings with the snapshot's contents.")
                }
    }

    private func exportDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ToastMonitor-backup-\(Int64(Date().timeIntervalSince1970)).db"
        panel.canCreateDirectories = true
        panel.message = "The export includes session titles and project names."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DataMaintenance.exportDatabase(to: url.path)
            DispatchQueue.main.async {
                message = ok ? "Database exported: \(url.path)" : "Database export failed"
                isWorking = false
            }
        }
    }

    /// A backup is created automatically once a week (idle weeks included)
    /// plus before any repair/clear operation; DataMaintenance.retained
    /// decides which are kept, and any of them can be restored from here.
    private var backupsSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backups, id: \.self) { url in
                    LabeledContent {
                        Button("Restore…") { pendingRestoreBackup = url }
                            .disabled(isWorking)
                    } label: {
                        Text(DataMaintenance.managedBackupLabel(for: url).capitalized)
                        Text(Self.dateAndSize(for: url))
                            .tmMonospacedDigit()
                    }
                }
            }
        } header: {
            Text("Automatic Backups")
        }
    }


    private static func scope(_ turns: Int, _ sessions: Int, _ tokens: Int64) -> String {
        "\(Format.count(Int64(turns))) \(turns == 1 ? "record" : "records") · \(sessions) \(sessions == 1 ? "session" : "sessions") · \(Format.count(tokens)) tokens"
    }

    private static func dateAndSize(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate
            .map { Format.dateTime(Int64($0.timeIntervalSince1970)) } ?? "—"
        let size = values?.fileSize.map { Format.bytes(Int64($0)) } ?? "—"
        return "\(date) · \(size)"
    }

    private func loadBackups() {
        DispatchQueue.global(qos: .utility).async {
            let urls = DataMaintenance.availableBackups()
            DispatchQueue.main.async { backups = urls }
        }
    }

    private func restoreManaged() {
        guard let target = pendingRestoreBackup else { return }
        pendingRestoreBackup = nil
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = DataMaintenance.restoreWithReceipt(backupPath: target.path)
            let ok = snapshot != nil
            DispatchQueue.main.async {
                message = snapshot.map { "Restored · \(($0 as NSString).lastPathComponent)" }
                    ?? "Restore failed; original data retained"
                isWorking = false
                if ok {
                    app.refresh()
                    refreshPreviewQuietly()
                    loadBackups()
                }
            }
        }
    }

    private func loadPreview() {
        isWorking = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let value = DataMaintenance.preview()
            DispatchQueue.main.async {
                preview = value
                isWorking = false
            }
        }
    }

    private func repair() {
        isWorking = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try DataMaintenance.repair()
                DispatchQueue.main.async {
                    receipt = value
                    message = "Backup: \(value.backupPath)"
                    // Reset here rather than relying on loadPreview()'s side
                    // effect: loadPreview() sets isWorking = true then wipes
                    // `message` to nil before its own async read completes,
                    // which cleared this success message before it could be
                    // seen and left the spinner stuck if the scan callback
                    // below never fired.
                    isWorking = false
                    loadBackups()
                    CollectorEngine.shared.scheduleScan(force: true) { _ in
                        app.refresh()
                        refreshPreviewQuietly()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    message = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }

    /// Reloads the preview counts without touching `message` or `isWorking`
    /// — used after repair/restore so the outcome message just set by the
    /// caller stays visible instead of being cleared by loadPreview()'s reset.
    private func refreshPreviewQuietly() {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = DataMaintenance.preview()
            DispatchQueue.main.async { preview = value }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DataMaintenance.restore(backupPath: receipt.backupPath)
            DispatchQueue.main.async {
                message = ok ? "Restored: \(receipt.backupPath)" : "Restore failed; backup retained"
                isWorking = false
                if ok {
                    app.refresh()
                    refreshPreviewQuietly()
                }
            }
        }
    }
}
