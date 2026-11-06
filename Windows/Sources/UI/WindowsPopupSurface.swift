import Foundation
import SwiftCrossUI
import WinUI
import WinUIBackend
import UWP
import WindowsFoundation

/// SwiftCrossUI 0.10 retains the first representable value. Keep its native
/// instance stable while the enclosing View supplies the latest immutable facts.
@MainActor
private final class WindowsPopupStorage: SwiftCrossUI.ObservableObject {
    var model: WindowsPopupPresentation?
    var actions: WindowsPopupActions?
}

struct WindowsPopupSurface: View {
    let model: WindowsPopupPresentation
    let actions: WindowsPopupActions
    @State private var storage = WindowsPopupStorage()
    var body: some View {
        let _ = storage.model = model
        let _ = storage.actions = actions
        WindowsPopupElement(storage: storage)
    }
}

/// Native controls own focus, tooltips, selection and progress accessibility.
private struct WindowsPopupElement: WinUIElementRepresentable {
    let storage: WindowsPopupStorage
    private var model: WindowsPopupPresentation { storage.model! }
    private var actions: WindowsPopupActions { storage.actions! }
    struct ToolKey: Equatable { let tool: String; let tokens: Int64 }
    struct ToolsKey: Equatable { let rows: [ToolKey]; let exact: Bool; let dark: Bool; let loading: Bool; let unavailable: Bool }
    struct AccountsKey: Equatable {
        let quotas: [WindowsPopupPresentation.Quota]
        let balances: [WindowsPopupPresentation.Balance]
        let notices: [String]
        let remaining: Bool
        let dark: Bool
        let staleQuotas: [Bool]
        let staleBalances: [Bool]
    }
    struct ActivityKey: Equatable {
        let values: [Int64: Int64]
        let mode: String
        let day: Date
        let firstWeekday: Int
        let dark: Bool
        let available: Bool
    }

    @MainActor final class Coordinator {
        let body = WinUI.StackPanel()
        let summary = WinUI.StackPanel()
        let quota = WinUI.StackPanel()
        let balance = WinUI.StackPanel()
        let activity = WinUI.StackPanel()
        let notices = WinUI.StackPanel()
        let legend = WinUI.StackPanel()
        let proportions = WinUI.Grid()
        let count = WinUI.TextBlock()
        let money = WinUI.TextBlock()
        let unit = WinUI.TextBlock()
        let activeDays = WinUI.TextBlock()
        let chart = WinUI.Grid()
        let periods = WinUI.Grid()
        var periodButtons: [WinUI.ToggleButton] = []
        var modeButtons: [WinUI.ToggleButton] = []
        var handlers: [() -> Void] = []
        var dynamicHandlers: [() -> Void] = []
        var chartHandlers: [() -> Void] = []
        var surface: WindowsPopupElement?
        var updating = false
        var mode = UserDefaults.standard.string(forKey: "popoverHistoryMode") ?? "heatmap"
        var heatmap: [Int64: Int64] = [:]
        var dark = false
        var toolsKey: ToolsKey?
        var accountsKey: AccountsKey?
        var activityKey: ActivityKey?
        var plotWidth = 406.0
        var plotHeight = 20 + 7 * 406.0 / 24 - 34
        var trendPlot: WinUI.Grid?
        var trendPath: WinUI.Path?
        var trendTransform: WinUI.CompositeTransform?
        let refresh = WinUI.Button()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func inset(_ value: Double) -> WinUI.Thickness {
        .init(left: value, top: value, right: value, bottom: value)
    }
    private static func brush(_ hex: UInt32, alpha: UInt8 = 255) -> WinUI.SolidColorBrush {
        WinUI.SolidColorBrush(UWP.Color(a: alpha, r: UInt8((hex >> 16) & 255), g: UInt8((hex >> 8) & 255), b: UInt8(hex & 255)))
    }
    private static func toolColor(_ tool: String, dark: Bool) -> UInt32 {
        switch ToolKind(rawValue: tool) {
        case .claude: return 0xD97757
        case .codex: return 0x7A9DFF
        case .dsh: return dark ? 0x3D5AEA : 0x2F49D1
        case .openrouter: return dark ? 0xC8FF00 : 0x7624F4
        case .opencode: return dark ? 0x30D158 : 0x248A3D
        case .hermes: return dark ? 0xBF5AF2 : 0x8944AB
        case .omp: return dark ? 0x40C8E0 : 0x00889C
        case nil: return dark ? 0xEB824D : 0xC75229
        }
    }
    private static func label(_ text: String, size: Double = 14) -> WinUI.TextBlock {
        let block = WinUI.TextBlock(); block.text = text; block.fontSize = size
        block.textWrapping = .wrap
        return block
    }
    private static func row(_ left: WinUI.FrameworkElement, _ right: WinUI.FrameworkElement) -> WinUI.Grid {
        let grid = WinUI.Grid()
        let first = WinUI.ColumnDefinition(); first.width = .init(value: 1, gridUnitType: .star)
        let second = WinUI.ColumnDefinition(); second.width = .init(value: 1, gridUnitType: .auto)
        grid.columnDefinitions.append(first); grid.columnDefinitions.append(second)
        left.verticalAlignment = .center; right.verticalAlignment = .center
        grid.children.append(left); grid.children.append(right); WinUI.Grid.setColumn(right, 1)
        return grid
    }
    private static func command(_ button: WinUI.Button, name: String, glyph: String? = nil, action: @escaping () -> Void, retain: Coordinator) {
        if let glyph {
            let icon = label(glyph, size: 17)
            icon.fontFamily = WinUI.FontFamily("Segoe MDL2 Assets")
            icon.textWrapping = .noWrap; icon.horizontalAlignment = .center; icon.verticalAlignment = .center
            button.padding = inset(0); button.horizontalContentAlignment = .center; button.verticalContentAlignment = .center
            button.content = icon; button.width = 34; button.height = 32
        } else { button.content = name }
        button.minWidth = 0
        WinUI.AutomationProperties.setName(button, name)
        WinUI.ToolTipService.setToolTip(button, name)
        let handler = button.click.addHandler { _, _ in action() }
        retain.handlers.append { handler.dispose() }
    }
    private static func card(_ content: WinUI.StackPanel, dark: Bool) -> WinUI.Border {
        content.spacing = 4
        let border = WinUI.Border(); border.child = content
        border.padding = inset(10)
        border.cornerRadius = .init(topLeft: 9, topRight: 9, bottomRight: 9, bottomLeft: 9)
        border.background = brush(dark ? 0xFFFFFF : 0x000000, alpha: dark ? 13 : 9)
        return border
    }
    func makeWinUIElement(context: Context) -> WinUI.Grid {
        let c = context.coordinator; c.surface = self
        let root = WinUI.Grid(); root.padding = Self.inset(12)
        for unit in [WinUI.GridUnitType.auto, .star, .auto] {
            let row = WinUI.RowDefinition(); row.height = .init(value: 1, gridUnitType: unit); root.rowDefinitions.append(row)
        }
        let title = Self.label("ToastMonitor", size: 18)
        title.fontWeight = UWP.FontWeights.semiBold
        Self.command(c.refresh, name: "Refresh", glyph: "\u{E72C}", action: { [weak c] in c?.surface?.actions.refresh() }, retain: c)
        let header = Self.row(title, c.refresh); header.margin = .init(left: 2, top: 0, right: 2, bottom: 10)
        root.children.append(header)
        c.body.spacing = 8
        let scroll = WinUI.ScrollViewer(); scroll.content = c.body
        scroll.horizontalScrollBarVisibility = .disabled; scroll.verticalScrollBarVisibility = .auto
        root.children.append(scroll); WinUI.Grid.setRow(scroll, 1)
        let footerLeft = WinUI.StackPanel(); footerLeft.orientation = .horizontal; footerLeft.spacing = 6
        let settings = WinUI.Button(); let quit = WinUI.Button(); let dashboard = WinUI.Button()
        Self.command(settings, name: "Settings", glyph: "\u{E713}", action: { [weak c] in c?.surface?.actions.settings(nil) }, retain: c)
        Self.command(quit, name: "Quit", glyph: "\u{E7E8}", action: { [weak c] in c?.surface?.actions.quit() }, retain: c)
        Self.command(dashboard, name: "Open Dashboard", action: { [weak c] in c?.surface?.actions.dashboard() }, retain: c)
        footerLeft.children.append(settings); footerLeft.children.append(quit)
        let footer = Self.row(footerLeft, dashboard); footer.margin = .init(left: 0, top: 10, right: 0, bottom: 0)
        root.children.append(footer); WinUI.Grid.setRow(footer, 2)
        for index in 0..<4 {
            let column = WinUI.ColumnDefinition(); column.width = .init(value: 1, gridUnitType: .star); c.periods.columnDefinitions.append(column)
            let button = WinUI.ToggleButton(); button.minWidth = 0; button.padding = .init(left: 3, top: 5, right: 3, bottom: 5)
            button.horizontalAlignment = .stretch; button.horizontalContentAlignment = .center
            WinUI.Grid.setColumn(button, Int32(index)); c.periods.children.append(button); c.periodButtons.append(button)
            let event = button.click.addHandler { [weak c] _, _ in
                guard let c, !c.updating, let surface = c.surface else { return }
                let slot = UsagePeriodSlot.allCases[index]
                surface.actions.selectPeriod(slot)
                surface.updateSelection(c)
            }
            c.handlers.append { event.dispose() }
        }
        c.summary.children.append(c.periods)
        let countRow = WinUI.StackPanel(); countRow.orientation = .horizontal; countRow.spacing = 8
        c.count.fontSize = 36; c.count.isTextSelectionEnabled = true
        c.count.fontWeight = UWP.FontWeights.semiBold
        let unit = c.unit; unit.text = "tokens"; unit.fontSize = 16
        unit.verticalAlignment = .bottom; unit.margin = .init(left: 0, top: 0, right: 0, bottom: 7)
        countRow.children.append(c.count); countRow.children.append(unit); c.summary.children.append(countRow)
        c.money.fontSize = 14; c.money.isTextSelectionEnabled = true; c.summary.children.append(c.money)
        c.proportions.height = 5; c.proportions.margin = .init(left: 0, top: 6, right: 0, bottom: 0)
        c.summary.children.append(c.proportions); c.legend.spacing = 4; c.summary.children.append(c.legend)
        c.activity.children.append(Self.row(c.activeDays, makeModeSelector(c)))
        c.chart.height = 20 + 7 * c.plotWidth / 24; c.activity.children.append(c.chart)
        rebuildCards(c)
        return root
    }
    private func makeModeSelector(_ c: Coordinator) -> WinUI.StackPanel {
        let stack = WinUI.StackPanel(); stack.orientation = .horizontal
        for (index, name) in ["Activity calendar", "Activity line chart"].enumerated() {
            let button = WinUI.ToggleButton(); button.minWidth = 0; button.width = 30; button.height = 28
            button.padding = Self.inset(0); button.horizontalContentAlignment = .center; button.verticalContentAlignment = .center
            let icon = Self.label(index == 0 ? "\u{E80A}" : "\u{E9D2}", size: 15); icon.fontFamily = WinUI.FontFamily("Segoe MDL2 Assets"); button.content = icon
            WinUI.AutomationProperties.setName(button, name); WinUI.ToolTipService.setToolTip(button, name)
            let event = button.click.addHandler { [weak c] _, _ in
                guard let c, let surface = c.surface else { return }
                c.mode = index == 0 ? "heatmap" : "trend"
                UserDefaults.standard.set(c.mode, forKey: "popoverHistoryMode")
                surface.drawActivity(c); surface.updateSelection(c)
            }
            c.handlers.append { event.dispose() }; c.modeButtons.append(button); stack.children.append(button)
        }
        return stack
    }
    private func rebuildCards(_ c: Coordinator) {
        c.body.children.clear()
        for panel in [c.summary, c.quota, c.balance, c.activity] { c.body.children.append(Self.card(panel, dark: c.dark)) }
        c.body.children.append(c.notices)
    }
    private func updateSelection(_ c: Coordinator) {
        c.updating = true
        for (index, button) in c.periodButtons.enumerated() {
            let slot = UsagePeriodSlot.allCases[index]
            let text = model.configuration.label(for: slot); button.content = text
            WinUI.AutomationProperties.setName(button, text); button.isChecked = slot == model.period
        }
        for (index, button) in c.modeButtons.enumerated() { button.isChecked = (c.mode == "heatmap") == (index == 0) }
        c.updating = false
    }
    func sizeThatFits(_ proposal: ProposedViewSize, winUIElement: WinUI.Grid, context: Context) -> ViewSize {
        let width = proposal.width ?? 450
        let c = context.coordinator
        c.plotWidth = max(1, width - 44)
        c.chart.height = 20 + 7 * c.plotWidth / 24
        c.plotHeight = max(1, c.chart.height - 34)
        c.trendPlot?.height = c.plotHeight
        c.trendPath?.height = c.plotHeight
        c.trendTransform?.scaleY = max(1, c.plotHeight - 2)
        c.trendPath?.width = c.plotWidth
        c.trendTransform?.scaleX = max(1, c.plotWidth - 2)
        c.count.fontSize = 36
        try! c.count.measure(WindowsFoundation.Size(width: .infinity, height: 52))
        try! c.unit.measure(WindowsFoundation.Size(width: .infinity, height: 52))
        let available = max(1, width - 48 - 8 - Double(c.unit.desiredSize.width))
        c.count.fontSize = min(36, 36 * available / max(1, Double(c.count.desiredSize.width)))
        return ViewSize(width, proposal.height ?? 680)
    }
    func updateWinUIElement(_ root: WinUI.Grid, context: Context) {
        let c = context.coordinator; c.surface = self
        let dark = context.environment.colorScheme == .dark
        root.requestedTheme = dark ? .dark : .light
        if c.dark != dark { c.dark = dark; rebuildCards(c) }
        c.refresh.isEnabled = !model.refreshing
        updateSelection(c)
        c.count.text = model.databaseProblem != nil || model.snapshot == nil ? "—" : (model.fullTokens ? Format.full(model.tokens(model.period)) : Format.compact(model.tokens(model.period)))
        c.money.text = "\(model.spendLabel)  \(model.databaseProblem == nil ? model.spent : "—")     Value  \(model.valueText)"
        WinUI.ToolTipService.setToolTip(c.money, model.spendNote)
        let toolKey = ToolsKey(rows: model.rows(model.period).map { ToolKey(tool: $0.tool, tokens: WindowsUI.tokens($0)) },
            exact: model.fullTokens, dark: dark, loading: model.snapshot == nil, unavailable: model.databaseProblem != nil)
        if c.toolsKey != toolKey { c.toolsKey = toolKey; drawTools(c) }
        let accountsKey = AccountsKey(quotas: model.quotas, balances: model.balances, notices: model.accountNotices,
            remaining: model.quotaShowsRemaining, dark: dark,
            staleQuotas: model.quotas.map { $0.lastSync > 0 && model.now.timeIntervalSince1970 - Double($0.lastSync) > 900 },
            staleBalances: model.balances.map { $0.updated.map { model.now.timeIntervalSince($0) > 900 } ?? false })
        if c.accountsKey != accountsKey { c.accountsKey = accountsKey; drawAccounts(c) }
        c.heatmap = model.snapshot?.heatmap ?? [:]
        drawActivity(c)
        drawNotices(c)
    }
    private func drawTools(_ c: Coordinator) {
        c.legend.children.clear(); c.proportions.children.clear(); c.proportions.columnDefinitions.clear()
        let rows = model.databaseProblem == nil ? model.rows(model.period).filter { WindowsUI.tokens($0) > 0 } : []
        let total = rows.reduce(Int64(0)) { $0 + WindowsUI.tokens($1) }
        if rows.isEmpty {
            c.proportions.background = Self.brush(c.dark ? 0xFFFFFF : 0x000000, alpha: 18)
            let empty = Self.label(model.databaseProblem != nil ? "Usage unavailable" : (model.snapshot == nil ? "Loading local usage…" : "No usage in this period"), size: 12); c.legend.children.append(empty)
            return
        }
        for (index, row) in rows.enumerated() {
            let tokens = WindowsUI.tokens(row); let fraction = Double(tokens) / Double(max(total, 1))
            let color = Self.brush(Self.toolColor(row.tool, dark: c.dark))
            let column = WinUI.ColumnDefinition(); column.width = .init(value: Double(tokens), gridUnitType: .star); c.proportions.columnDefinitions.append(column)
            let segment = WinUI.Border(); segment.background = color; c.proportions.children.append(segment); WinUI.Grid.setColumn(segment, Int32(index))
            let dot = WinUI.Ellipse(); dot.width = 7; dot.height = 7; dot.fill = color; dot.verticalAlignment = .center
            let name = Self.label("\(WindowsUI.toolName(row.tool))  (\(String(format: "%.1f", fraction * 100))%)", size: 13)
            let left = WinUI.StackPanel(); left.orientation = .horizontal; left.spacing = 7; left.children.append(dot); left.children.append(name)
            c.legend.children.append(Self.row(left, Self.label(model.fullTokens ? Format.full(tokens) : Format.compact(tokens), size: 13)))
        }
    }
    private func drawAccounts(_ c: Coordinator) {
        for remove in c.dynamicHandlers { remove() }; c.dynamicHandlers.removeAll()
        c.quota.children.clear(); c.balance.children.clear()
        let quotaTitle = Self.label("Quota", size: 15); quotaTitle.fontWeight = UWP.FontWeights.semiBold
        let balanceTitle = Self.label("Balance", size: 15); balanceTitle.fontWeight = UWP.FontWeights.semiBold
        c.quota.children.append(quotaTitle); c.balance.children.append(balanceTitle)
        var quotaCount = 0
        func quota(_ name: String, _ window: String, _ percent: Double?, _ reset: Int64?, _ error: String?) {
            quotaCount += 1
            let stack = WinUI.StackPanel(); stack.spacing = 3
            stack.children.append(Self.label(name, size: 14))
            let value = percent.map { String(format: "%.0f%% %@", model.quotaShowsRemaining ? 100 - $0 : $0, model.quotaShowsRemaining ? "remaining" : "used") } ?? "—"
            let resetText = reset.map { " · resets \(Self.resetText($0))" } ?? ""
            stack.children.append(Self.row(Self.label(window + resetText, size: 12), Self.label(value, size: 12)))
            if let percent {
                let progress = WinUI.ProgressBar(); progress.minimum = 0; progress.maximum = 100
                progress.value = max(0, min(100, model.quotaShowsRemaining ? 100 - percent : percent)); progress.height = 5
                WinUI.AutomationProperties.setName(progress, "\(name) \(window) \(model.quotaShowsRemaining ? "remaining" : "used")")
                stack.children.append(progress)
            }
            if let error { stack.children.append(Self.label(error, size: 12)) }
            c.quota.children.append(stack)
        }
        for row in model.quotas {
            quota(row.account, row.window, row.percent, row.reset, row.error)
            if row.lastSync > 0, model.now.timeIntervalSince1970 - Double(row.lastSync) > 900 {
                c.quota.children.append(Self.label("Updated \(WindowsUI.date(row.lastSync)) · may be stale", size: 11))
            }
        }
        for notice in model.accountNotices { c.quota.children.append(Self.label(notice, size: 12)) }
        if quotaCount == 0 { setup("No quota account connected", provider: "Quota accounts", panel: c.quota, c: c) }
        for row in model.balances {
            if row.credential == .missing, row.value == nil, row.error == nil {
                continue
            } else {
                c.balance.children.append(Self.row(Self.label(row.provider, size: 13), Self.label(row.value ?? "—", size: 13)))
                if case .failure(let status) = row.credential {
                    c.balance.children.append(Self.label("Credential Manager error \(status). Reconnect in Accounts.", size: 12))
                }
                if let updated = row.updated, model.now.timeIntervalSince(updated) > 900 {
                    c.balance.children.append(Self.label("Updated \(updated.formatted(date: .abbreviated, time: .shortened)) · may be stale", size: 11))
                }
            }
            if let error = row.error { c.balance.children.append(Self.label("\(row.provider): \(error)", size: 12)) }
        }
        let disconnected = model.balances.filter { $0.credential == .missing && $0.value == nil && $0.error == nil }
        if !disconnected.isEmpty {
            setup("Not connected", provider: disconnected.map(\.provider).joined(separator: ", "), panel: c.balance, c: c)
        }
    }
    private func setup(_ title: String, provider: String, panel: WinUI.StackPanel, c: Coordinator) {
        let left = WinUI.StackPanel(); left.spacing = 1
        left.children.append(Self.label(title, size: 13)); left.children.append(Self.label(provider, size: 12))
        let button = WinUI.Button(); button.content = "Set Up…"; button.minWidth = 0
        WinUI.AutomationProperties.setName(button, "Set up \(provider)")
        let event = button.click.addHandler { [weak c] _, _ in c?.surface?.actions.settings(.accounts) }
        c.dynamicHandlers.append { event.dispose() }; panel.children.append(Self.row(left, button))
    }
    private static func resetText(_ stamp: Int64) -> String {
        let seconds = Double(stamp) - Date().timeIntervalSince1970
        if seconds > 86400 { return "in \(String(format: "%.1f", seconds / 86400))d" }
        if seconds > 3600 { return "in \(Int(ceil(seconds / 3600)))h" }
        if seconds > 0 { return "in \(Int(ceil(seconds / 60)))m" }
        return WindowsUI.date(stamp)
    }
    private func drawNotices(_ c: Coordinator) {
        c.notices.children.clear(); c.notices.spacing = 4
        if let problem = model.databaseProblemDescription { c.notices.children.append(Self.label("Database needs attention: \(problem). Open Settings → Data.", size: 12)) }
        if let problem = model.taskbarProblem { c.notices.children.append(Self.label("Taskbar unavailable: \(problem). Closing Usage quits; Escape does not hide this fallback window.", size: 11)) }
        if !model.message.isEmpty { c.notices.children.append(Self.label(model.message, size: 12)) }
        for source in model.sources where source.error != nil || source.failedRows > 0 || source.isStale {
            c.notices.children.append(Self.label("\(source.displayName): \(source.error ?? (source.isStale ? "Collection is stale; refresh to retry." : "\(source.failedRows) records failed to import."))", size: 12))
        }
    }
    private func drawActivity(_ c: Coordinator) {
        let calendar = model.configuration.configuredCalendar()
        let today = calendar.startOfDay(for: model.now)
        let available = model.snapshot != nil && model.databaseProblem == nil
        let change = ActivityKey(values: c.heatmap, mode: c.mode, day: today, firstWeekday: calendar.firstWeekday, dark: c.dark, available: available)
        guard c.activityKey != change else { return }
        c.activityKey = change
        for remove in c.chartHandlers { remove() }; c.chartHandlers.removeAll()
        c.chart.children.clear()
        c.trendPath = nil
        c.trendTransform = nil
        c.trendPlot = nil
        guard available else {
            c.activeDays.text = "Activity  — active days"
            c.chart.children.append(Self.label(model.databaseProblem == nil ? "Loading activity…" : "Activity unavailable", size: 12))
            return
        }
        let thisWeek = model.configuration.startOfConfiguredWeek(today, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -23 * 7, to: thisWeek)!
        func key(_ date: Date) -> Int64 {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return Int64(parts.year! * 10000 + parts.month! * 100 + parts.day!)
        }
        let visible = (0..<168).compactMap { offset -> (Date, Int64)? in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return date <= today ? (date, c.heatmap[key(date)] ?? 0) : nil
        }
        c.activeDays.text = "Activity  \(visible.filter { $0.1 > 0 }.count) active days"; c.activeDays.fontSize = 14
        if c.mode == "heatmap" {
            let grid = WinUI.Grid()
            for _ in 0..<24 { let column = WinUI.ColumnDefinition(); column.width = .init(value: 1, gridUnitType: .star); grid.columnDefinitions.append(column) }
            let heading = WinUI.RowDefinition(); heading.height = .init(value: 20, gridUnitType: .pixel); grid.rowDefinitions.append(heading)
            for _ in 0..<7 { let row = WinUI.RowDefinition(); row.height = .init(value: 1, gridUnitType: .star); grid.rowDefinitions.append(row) }
            // Match PopoverHeatmap: quartiles of positive *visible* values.
            let positive = visible.map(\.1).filter { $0 > 0 }.sorted()
            let cuts = positive.isEmpty ? [] : [1, 2, 3].map { positive[min(positive.count - 1, positive.count * $0 / 4)] }
            let opacity: [UInt8] = [71, 128, 191, 255]
            var months: [(column: Int, date: Date)] = []
            for column in 0..<24 {
                let date = calendar.date(byAdding: .day, value: column * 7, to: start)!
                if date <= today, months.last.map({ calendar.component(.month, from: $0.date) }) != calendar.component(.month, from: date) {
                    months.append((column, date))
                }
            }
            if months.count > 1, months[1].column - months[0].column < 3 { months.removeFirst() }
            let formatter = DateFormatter(); formatter.dateFormat = "MMM"
            for month in months {
                let label = Self.label(formatter.string(from: month.date), size: 10); label.textWrapping = .noWrap
                grid.children.append(label); WinUI.Grid.setColumn(label, Int32(month.column))
                WinUI.Grid.setColumnSpan(label, Int32(min(3, 24 - month.column)))
            }
            for (index, entry) in visible.enumerated() {
                let (date, tokens) = entry
                let cell = WinUI.Border(); cell.margin = Self.inset(1)
                cell.cornerRadius = .init(topLeft: 2, topRight: 2, bottomRight: 2, bottomLeft: 2)
                let level = tokens > 0 ? cuts.filter { tokens >= $0 }.count : 0
                cell.background = tokens > 0 ? Self.brush(0xC75229, alpha: opacity[level]) : Self.brush(c.dark ? 0xFFFFFF : 0x000000, alpha: 14)
                let description = "\(date.formatted(date: .abbreviated, time: .omitted)): \(Format.full(tokens)) tokens"
                WinUI.AutomationProperties.setName(cell, description); WinUI.ToolTipService.setToolTip(cell, description)
                grid.children.append(cell); WinUI.Grid.setColumn(cell, Int32(index / 7)); WinUI.Grid.setRow(cell, Int32(index % 7 + 1))
            }
            c.chart.children.append(grid)
        } else {
            drawTrend(c, calendar: calendar)
        }
    }
    private func drawTrend(_ c: Coordinator, calendar: Calendar) {
        let series = c.heatmap.keys.sorted().suffix(60).compactMap { key -> (date: Date, tokens: Int64)? in
            var parts = DateComponents(); parts.year = Int(key / 10000); parts.month = Int(key / 100 % 100); parts.day = Int(key % 100)
            return calendar.date(from: parts).map { ($0, c.heatmap[key] ?? 0) }
        }
        let stack = WinUI.StackPanel(); stack.spacing = 3
        let readout = Self.label("", size: 11); readout.height = 16
        stack.children.append(readout)
        guard let first = series.first, let last = series.last else {
            stack.children.append(Self.label("No collected activity yet", size: 12)); c.chart.children.append(stack); return
        }
        func description(_ point: (date: Date, tokens: Int64)) -> String {
            "\(point.date.formatted(.dateTime.month(.abbreviated).day())) · \(Format.compact(point.tokens)) tokens"
        }
        readout.text = description(last)
        let duration = max(last.date.timeIntervalSince(first.date), 86400)
        let peak = max(series.map(\.tokens).max() ?? 0, 1)
        let plot = WinUI.Grid(); plot.height = c.plotHeight; plot.background = Self.brush(0x000000, alpha: 0)
        c.trendPlot = plot
        let path = WinUI.Path(); let geometry = WinUI.PathGeometry(); let figure = WinUI.PathFigure()
        for (index, value) in series.enumerated() {
            // Calendar-time x preserves real gaps. Only recorded samples become vertices.
            let point = WindowsFoundation.Point(x: Float(value.date.timeIntervalSince(first.date) / duration), y: Float(1 - Double(value.tokens) / Double(peak)))
            if index == 0 { figure.startPoint = point }
            else { let segment = WinUI.LineSegment(); segment.point = point; figure.segments.append(segment) }
        }
        figure.isFilled = false; geometry.figures.append(figure); path.data = geometry
        let transform = WinUI.CompositeTransform()
        transform.scaleX = max(1, c.plotWidth - 2); transform.scaleY = max(1, c.plotHeight - 2)
        transform.translateX = 1; transform.translateY = 1
        geometry.transform = transform; c.trendTransform = transform
        path.stroke = Self.brush(0xC75229); path.strokeThickness = 1.6; path.stretch = .none
        path.width = c.plotWidth; path.height = c.plotHeight
        path.horizontalAlignment = .stretch; path.verticalAlignment = .stretch
        c.trendPath = path
        WinUI.AutomationProperties.setName(path, "Activity line chart, \(series.count) recorded days")
        WinUI.AutomationProperties.setHelpText(path, series.map { description($0) }.joined(separator: "; "))
        plot.children.append(path); stack.children.append(plot)
        let moved = plot.pointerMoved.addHandler { [weak plot, weak readout] _, arguments in
            guard let plot, let readout, let arguments, plot.actualWidth > 0,
                  let position = try? arguments.getCurrentPoint(plot)?.position else { return }
            let fraction = max(0, min(1, Double(position.x) / plot.actualWidth))
            let day = calendar.startOfDay(for: first.date.addingTimeInterval(fraction * duration))
            readout.text = series.first(where: { calendar.isDate($0.date, inSameDayAs: day) }).map(description) ?? ""
        }
        let exited = plot.pointerExited.addHandler { [weak readout] _, _ in readout?.text = description(last) }
        c.chartHandlers.append { moved.dispose() }; c.chartHandlers.append { exited.dispose() }
        let axis = WinUI.Grid()
        for _ in 0..<3 { let column = WinUI.ColumnDefinition(); column.width = .init(value: 1, gridUnitType: .star); axis.columnDefinitions.append(column) }
        let dates = [first.date, first.date.addingTimeInterval(duration / 2), last.date]
        for (index, date) in dates.enumerated() {
            let text = Self.label(date.formatted(.dateTime.month(.defaultDigits).day()), size: 10)
            text.horizontalAlignment = index == 0 ? .left : (index == 1 ? .center : .right)
            axis.children.append(text); WinUI.Grid.setColumn(text, Int32(index))
        }
        stack.children.append(axis); c.chart.children.append(stack)
    }
    static func dismantleWinUIElement(_ root: WinUI.Grid, coordinator: Coordinator) {
        for remove in coordinator.handlers + coordinator.dynamicHandlers + coordinator.chartHandlers { remove() }
        coordinator.surface = nil
    }
}
