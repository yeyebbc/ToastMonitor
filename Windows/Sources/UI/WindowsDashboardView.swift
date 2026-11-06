import Foundation
import SwiftCrossUI

struct WindowsDashboardView: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Dashboard").font(.title).emphasized()
                Spacer()
                WindowsAction("Refresh") { model.refreshAll() }.disabled(model.refreshing)
                WindowsAction("Settings") { WindowsWindowController.shared.showSettings() }
            }
            WindowsTopTabs(labels: WindowsDashboardSection.allCases.map(\.rawValue),
                selection: SwiftCrossUI.Binding(get: { WindowsDashboardSection.allCases.firstIndex(of: model.dashboardSection) ?? 0 },
                    set: { model.dashboardSection = WindowsDashboardSection.allCases[$0] }), name: "Dashboard pages").frame(height: 48)
            WindowsStatusView()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.databaseProblem != nil {
                        Text("Usage is unavailable until the database is recovered in Settings → Data.")
                    } else if model.snapshot == nil {
                        Text("Loading dashboard from your local database…")
                    } else if model.dashboardSection == .overview {
                        WindowsPeriodSelector()
                        WindowsDashboardSummary()
                        HStack(alignment: .top, spacing: 28) {
                            WindowsToolBreakdown().frame(maxWidth: .infinity, alignment: .leading)
                            WindowsModelComparison().frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack {
                            WindowsAction("Explore analysis") { model.dashboardSection = .analysis }
                            WindowsAction("Review plans") { model.dashboardSection = .plans }
                            WindowsAction("Set up sources") { WindowsWindowController.shared.showSettings(section: .sources) }
                        }
                    } else if model.dashboardSection == .analysis {
                        WindowsAnalysisFilters(showsRange: false)
                        WindowsModelAnalysisView()
                        WindowsHistoryView()
                    } else if model.dashboardSection == .performance {
                        WindowsAnalysisFilters()
                        WindowsPerformanceView()
                    } else if model.dashboardSection == .plans {
                        WindowsPlansView()
                        WindowsQuotaView()
                    } else {
                        WindowsSessionsView()
                    }
                }.frame(maxWidth: 860, alignment: .leading)
            }
        }.padding(24).font(.system(size: 14))
    }
}

struct WindowsAnalysisFilters: View {
    var showsRange = true
    @State private var model = WindowsModel.shared
    var body: some View {
        HStack {
            Text(showsRange ? "Tool · performance" : "Tool · models and history")
            WindowsToolChoice(label: "Shared analysis tool", selection: $model.analysisTool).frame(width: 180)
            if showsRange {
                Text("Performance range")
                WindowsHistoryRange()
            }
        }
    }
}

struct WindowsHistoryView: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        let daily = model.filteredDaily
        let maximum = Double(daily.lazy.map { tokens($0) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily history · last \(model.analysisDays ?? "30") days").font(.headline)
                WindowsHistoryRange()
            }
            Text("Tool scope: \(WindowsUI.toolName(model.analysisTool ?? "All tools"))").font(.caption)
            if model.dailyLoading { Text("Loading history…") }
            if !model.dailyLoading && daily.isEmpty { Text("No collected usage in this history range.") }
            Text("One bar per tool and day. Token counts use each tool's original accounting rules.").font(.caption)
            ForEach(Array(daily.suffix(120).enumerated()), id: \.offset) { entry in
                WindowsDayRow(row: entry.element, maximum: maximum)
            }
            if daily.count > 120 { Text("Showing the latest 120 tool-day rows. Export the database in Settings for the complete history.") }
        }
    }
    private func tokens(_ row: Database.DayAgg) -> Int64 {
        ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? (row.input + row.output + row.cacheRead)
    }
}

private struct WindowsDayRow: View {
    let row: Database.DayAgg
    let maximum: Double
    private var tokens: Int64 { ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? (row.input + row.output + row.cacheRead) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WindowsValueRow(label: "\(WindowsUI.day(row.day)) · \(WindowsUI.toolName(row.tool))", value: "\(Format.compact(tokens)) tokens · \(Format.money(row.cost))")
            WindowsUI.copper.frame(width: 440 * Double(tokens) / max(maximum, 1), height: 7)
        }
    }
}

struct WindowsModelAnalysisView: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models · \(model.configuration.title(for: model.period))").font(.headline)
                Spacer()
                WindowsAction("Export models…") { WindowsSaveDialog.exportModels() }.disabled(model.modelRows.isEmpty || model.maintenanceBusy)
            }
            WindowsPeriodSelector()
            Text("\(WindowsUI.periodRange(model.configuration, model.period)). Only model results use this period; Daily history has its own range below.").font(.caption)
            if model.modelRows.isEmpty { Text("No model usage matches these filters.") }
            ForEach(model.modelRows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    WindowsValueRow(label: "\(row.model) · \(WindowsUI.toolName(row.tool))", value: "\(row.count) calls · \(Format.money(row.cost))")
                    Text("Input \(Format.full(row.input)) · Output \(Format.full(row.output)) · Cache read \(Format.full(row.cacheRead))").font(.caption).textSelectionEnabled()
                }
                Divider()
            }
        }
    }
}

struct WindowsPerformanceView: View {
    @State private var model = WindowsModel.shared
    private var groups: [String: [PerfPoint]] { Dictionary(grouping: model.filteredPerformance, by: \.model) }
    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 12) {
            Text("Measured performance · last \(model.analysisDays ?? "30") days").font(.headline)
            Text("Time to first token and generation throughput come from recorded request timings. Only calls with sufficient recorded timing data contribute to these measurements.")
            if model.performanceLoading { Text("Loading measured performance…") }
            if !model.performanceLoading && groups.isEmpty {
                Text("No measured calls match these filters.")
                Text("Timing is available only for sources whose logs record request timing.").font(.caption)
            }
            ForEach(groups.keys.sorted(), id: \.self) { name in
                WindowsPerformanceRow(name: name, points: groups[name] ?? [])
            }
        }
    }
}

private struct WindowsPerformanceRow: View {
    let name: String
    let points: [PerfPoint]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).emphasized()
            WindowsValueRow(label: "Measured calls", value: "\(points.count)")
            WindowsValueRow(label: "Median first token", value: PerfStats.median(points.compactMap(\.ttftMs)).map { String(format: "%.0f ms", $0) } ?? "Not recorded")
            WindowsValueRow(label: "Median generation speed", value: PerfStats.median(points.compactMap(\.tokensPerSecond)).map { String(format: "%.1f tokens/s", $0) } ?? "Not recorded")
            Divider()
        }
    }
}

struct WindowsPlansView: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Subscriptions").font(.headline)
                Spacer()
                WindowsAction("Edit subscriptions") { WindowsWindowController.shared.showSettings(section: .accounts, subscriptions: true) }
            }
            if model.snapshot?.light.subscriptions.isEmpty != false { Text("No subscriptions recorded. Add your billing plan in Settings.") }
            ForEach(model.snapshot?.light.subscriptions ?? [], id: \.id) { subscription in
                VStack(alignment: .leading, spacing: 4) {
                    WindowsValueRow(label: subscription.name, value: "\(subscription.currency) \(String(format: "%.2f", subscription.price)) / \(subscription.cycle)")
                    if let cycle = SubscriptionMath.cycleInfo(start: subscription.startDate, end: subscription.endDate, cycle: subscription.cycle) {
                        Text("Day \(cycle.dayOfCycle) of \(cycle.totalDays) · next renewal \(SubscriptionMath.dateStr(cycle.end))")
                        WindowsUI.copper.frame(width: 360 * cycle.progress, height: 5)
                    } else { Text("Inactive or not yet in a supported billing cycle") }
                    Divider()
                }
            }
        }
    }
}

struct WindowsSessionsView: View {
    @State private var model = WindowsModel.shared
    @State private var search = ""
    @State private var detailPage = 0
    private var visibleSessions: [Database.SessionRow] {
        model.sessions.filter { search.isEmpty || [$0.title, $0.project, $0.model, $0.sessionID].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions").font(.headline)
            HStack {
                Text("Tool")
                WindowsToolChoice(label: "Session tool", selection: $model.sessionTool).frame(width: 170)
                    .onChange(of: model.sessionTool) { model.loadSessions(page: 0) }
                TextField("Find in this page", text: $search)
            }
            Text("\(model.sessionCount) sessions · page \(model.sessionPage + 1). Search filters the current page.").font(.caption)
            if model.sessionsLoading { Text("Loading sessions…") }
            if !model.sessionsLoading && visibleSessions.isEmpty { Text("No sessions on this page match the filter.") }
            ForEach(visibleSessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: 4) {
                    WindowsAction(session.title ?? session.sessionID) { detailPage = 0; model.selectSession(session) }
                    Text("\(WindowsUI.toolName(session.tool)) · \(session.model ?? "Unknown model") · \(session.count) calls · \(Format.money(session.cost))")
                    if let project = session.project { Text(project).font(.caption).textSelectionEnabled() }
                }
                Divider()
            }
            HStack {
                WindowsAction("Previous page") { model.loadSessions(page: model.sessionPage - 1) }.disabled(model.sessionPage == 0 || model.sessionsLoading)
                WindowsAction("Next page") { model.loadSessions(page: model.sessionPage + 1) }.disabled((model.sessionPage + 1) * model.pageSize >= model.sessionCount || model.sessionsLoading)
            }
            if let session = model.selectedSession {
                Divider()
                Text(session.title ?? session.sessionID).font(.headline)
                Text("\(WindowsUI.toolName(session.tool)) · \(WindowsUI.date(session.created)) → \(WindowsUI.date(session.updated))")
                if model.turnsLoading { Text("Loading session calls…") }
                if !model.turnsLoading && model.turns.isEmpty { Text("No individual calls are available for this session.") }
                ForEach(Array(model.turns.enumerated().dropFirst(detailPage * 50).prefix(50)), id: \.offset) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(WindowsUI.date(entry.element.ts)) · \(entry.element.model ?? "Unknown model")")
                        Text("Input \(entry.element.input) · Output \(entry.element.output) · Cache read \(entry.element.cacheRead) · Cache write \(entry.element.cacheWrite) · \(Format.money(entry.element.cost))").textSelectionEnabled()
                    }
                }
                HStack {
                    WindowsAction("Earlier calls") { detailPage -= 1 }.disabled(detailPage == 0)
                    Text("\(model.turns.count) calls · page \(detailPage + 1)")
                    WindowsAction("Later calls") { detailPage += 1 }.disabled((detailPage + 1) * 50 >= model.turns.count)
                }
            }
        }
    }
}

struct WindowsHistoryRange: View {
    @State private var model = WindowsModel.shared
    private let days = ["7", "30", "90", "365"]
    var body: some View {
        WindowsChoice(label: "History and performance range", options: days.map { "\($0) days" },
            selection: SwiftCrossUI.Binding(get: { days.firstIndex(of: model.analysisDays ?? "30") ?? 1 },
                set: { model.analysisDays = days[$0]; model.loadAnalysis() })).frame(width: 140)
    }
}

struct WindowsToolChoice: View {
    let label: String
    let selection: SwiftCrossUI.Binding<String?>
    private var options: [String] { ["All tools"] + ToolKind.allCases.map(\.rawValue) }
    var body: some View {
        WindowsChoice(label: label, options: options.map(WindowsUI.toolName), selection: SwiftCrossUI.Binding(
            get: { options.firstIndex(of: selection.wrappedValue ?? "All tools") ?? 0 },
            set: { selection.wrappedValue = options[$0] }))
    }
}

private struct WindowsModelComparison: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models").font(.headline)
            if model.periodModelRows.isEmpty { Text("No model usage in this period.") }
            ForEach(Array(model.periodModelRows.prefix(6)), id: \.id) { row in
                WindowsValueRow(label: row.model, value: "\(Format.compact(ToolKind(rawValue: row.tool)?.totalTokens(input: row.input, output: row.output, cacheRead: row.cacheRead) ?? (row.input + row.output + row.cacheRead))) tokens")
            }
            WindowsAction("All model results") { model.dashboardSection = .analysis }
        }
    }
}

private struct WindowsDashboardSummary: View {
    @State private var model = WindowsModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                metric("Tokens", Format.compact(model.tokens(model.period)))
                metric("Calls", model.totals(model.period).map { Format.full($0.count) } ?? "Not available")
                metric("Actual API spend", model.quality(model.period).map { Format.money($0.actual) } ?? "Not available")
                metric("API value", Format.money(model.apiValue(model.period)))
            }
            WindowsDisclosure("Cost details") { WindowsCostDetails() }
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption)
            Text(value).font(.title2).emphasized().textSelectionEnabled()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
