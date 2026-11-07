import SwiftUI

/// Settings › Sources › Collectors: one summary row, collapsed by default.
/// Testing, rescanning or the disclosure triangle expands a table with one
/// row per enabled source.
struct CollectorStatusSection: View {
    @ObservedObject private var health = SourceHealthHub.shared
    let sources: [ToolKind: UsageSources]

    @State private var expanded = false
    @State private var testing = false
    @State private var testResult: (text: String, ok: Bool)?
    /// Bumped per test start; a stale 10s timeout checks it before firing.
    @State private var testGeneration = 0

    enum Status: String {
        case synced = "Synced", stale = "Stale", error = "Error", idle = "Idle"

        var symbol: String {
            switch self {
            case .synced: return "checkmark.circle.fill"
            case .stale: return "clock.badge.exclamationmark"
            case .error: return "xmark.circle.fill"
            case .idle: return "circle.dashed"
            }
        }

        var color: Color {
            switch self {
            case .synced, .idle: return .secondary
            case .stale: return TMDesign.warning
            case .error: return TMDesign.danger
            }
        }
    }

    var body: some View {
        Section("Collectors") {
            DisclosureGroup(isExpanded: $expanded) {
                if let testResult {
                    Text(testResult.text)
                        .foregroundStyle(testResult.ok ? Color.secondary : TMDesign.danger)
                        .textSelection(.enabled)
                }
                table
                ForEach(rows.filter { $0.error != nil }) { row in
                    LabeledContent(row.displayName) {
                        Text(row.error ?? "")
                            .foregroundStyle(TMDesign.danger)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                LabeledContent {
                    HStack {
                        Button {
                            test()
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(testing)
                        Button("Rescan Now") { rescan() }
                    }
                } label: {
                    Text(summary)
                        .foregroundStyle(summaryColor)
                }
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        let rows = rows
        return Table(rows) {
            TableColumn("Source") { row in
                HStack(spacing: 6) {
                    let tool = ToolKind(rawValue: row.tool)
                    Image(systemName: row.mode == "remote" ? "externaldrive.badge.icloud" : (tool?.symbol ?? "tray"))
                        .foregroundStyle(tool?.color ?? TMDesign.accent)
                        .frame(width: 16)
                    Text(row.displayName)
                }
            }
            .width(min: 96, ideal: 128)
            TableColumn("Status") { row in
                let status = status(for: row)
                Label(status.rawValue, systemImage: status.symbol)
                    .foregroundStyle(status.color)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Last Scan") { row in
                Text(row.lastScan > 0 ? Format.dateTime(row.lastScan) : "—")
            }
            .width(min: 72, ideal: 78)
            TableColumn("Imported") { row in
                Text(row.lastScan > 0 ? "\(row.lastRows)" : "—").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 56)
            TableColumn("Failed") { row in
                Text(row.lastScan > 0 ? "\(row.failedRows)" : "—").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 42)
            TableColumn("Time") { row in
                Text(row.lastScan > 0 && row.mode == "local" ? String(format: "%.0f ms", row.durationMs) : "—").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 48)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .tmMonospacedDigit()
        .frame(height: CGFloat(rows.count) * 24 + 30)
        .accessibilityLabel("Collector status")
    }

    private var rows: [SourceHealth] {
        ToolKind.allCases.filter { $0 != .openrouter }.flatMap { tool -> [SourceHealth] in
            let enabled = sources[tool] ?? .local
            let modes = [(enabled.includesLocal, "local"), (enabled.includesRemote, "remote")]
            return modes.compactMap { included, mode in
                guard included else { return nil }
                return health.sources.first { $0.tool == tool.rawValue && $0.mode == mode }
                    ?? SourceHealth(tool: tool.rawValue, mode: mode)
            }
        }
    }

    private func status(for row: SourceHealth) -> Status {
        if row.error != nil { return .error }
        if row.isStale { return .stale }
        return row.lastScan > 0 ? .synced : .idle
    }

    private var summary: String {
        let rows = rows
        let errors = rows.filter { $0.error != nil }
        let stale = rows.filter { $0.error == nil && $0.isStale }
        if errors.count == 1 { return "\(errors[0].displayName) failed" }
        if errors.count > 1 { return "\(errors.count) sources failed" }
        if stale.count == 1 { return "\(stale[0].displayName) is stale" }
        if stale.count > 1 { return "\(stale.count) sources are stale" }
        let last = rows.map(\.lastScan).max() ?? 0
        return last > 0 ? "Up to date · \(Format.dateTime(last))" : "Not scanned yet"
    }

    private var summaryColor: Color {
        let rows = rows
        if rows.contains(where: { $0.error != nil }) { return TMDesign.danger }
        if rows.contains(where: { $0.error == nil && $0.isStale }) { return TMDesign.warning }
        return .secondary
    }

    // MARK: - Actions

    private func test() {
        expanded = true
        testing = true
        testResult = nil
        testGeneration += 1
        let gen = testGeneration
        CollectorEngine.shared.scheduleScan(force: true) { receipt in
            // The completion is the source of truth: a late success must be
            // able to replace the 10s timeout message.
            guard gen == testGeneration else { return }
            // Read the remote status in the poll's own completion; the local
            // scan usually finishes first and would report a stale value.
            HermesRemoteClient.shared.poll {
                guard gen == testGeneration else { return }
                testing = false
                let remoteErrors = rows.filter { $0.mode == "remote" && $0.error != nil }
                let failures = receipt.failedSources + remoteErrors.map { row in
                    "\(row.displayName): \(row.error ?? "")"
                }
                if failures.isEmpty {
                    testResult = ("Scan complete · \(receipt.turns) new", true)
                } else {
                    testResult = ("Failed: \(failures.joined(separator: ", "))", false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard gen == testGeneration, testing else { return }
            testing = false
            testResult = ("Scan not finished in 10 s", false)
        }
    }

    private func rescan() {
        expanded = true
        CollectorEngine.shared.scheduleScan()
        OpenRouterClient.shared.refresh()
        OpenCodeGoClient.shared.refresh()
    }
}
