import Foundation
import SwiftCrossUI
import WinUIBackend

@main
@MainActor
enum ToastMonitorWindowsMain {
    static func main() {
        do {
            try WindowsTimeZone.initialize()
        } catch {
            fputs("The system timezone could not be initialized: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            ToastMonitor for Windows
            Usage: ToastMonitor.exe [--background | --show-dashboard | --show-settings]
                   ToastMonitor.exe --print-usage
                   ToastMonitor.exe --export-diagnostics PATH

            The readout embeds in the primary horizontal Explorer taskbar, not the tray.
            Data: %LOCALAPPDATA%\\ToastMonitor (TM_DATABASE_PATH overrides the database).
            --print-usage reads cached totals; it does not scan source logs.
            """)
            return
        }
        if arguments.contains("--print-usage") {
            Database.shared.open()
            guard Database.shared.openProblem == nil else {
                fputs("The usage database could not be opened.\n", stderr)
                Foundation.exit(1)
            }
            let range = UsagePeriodSettings.shared.configuration.range(for: .today, now: Date())
            let totals = Database.shared.totals(from: range.start, to: range.end)
            let value: [String: Any] = ["period": "today", "from": range.start, "to": range.end,
                "input": totals.input, "output": totals.output, "cacheRead": totals.cacheRead,
                "cacheWrite": totals.cacheWrite, "calls": totals.count, "cost": totals.cost]
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Could not encode usage: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            Database.shared.close()
            return
        }
        if let index = arguments.firstIndex(of: "--export-diagnostics") {
            guard arguments.indices.contains(index + 1) else {
                fputs("--export-diagnostics requires an output path.\n", stderr)
                Foundation.exit(2)
            }
            Database.shared.open()
            do {
                let data = try JSONSerialization.data(withJSONObject: Database.shared.diagnosticsSummary(), options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: [.atomic])
                print("Redacted diagnostics saved to \(arguments[index + 1]).")
            } catch {
                fputs("Diagnostics export failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
            Database.shared.close()
            return
        }
        let supported = Set(["--background", "--show-dashboard", "--show-settings"])
        guard arguments.allSatisfy(supported.contains) else {
            fputs("Unknown argument. Run ToastMonitor.exe --help.\n", stderr)
            Foundation.exit(2)
        }
        Database.shared.open()
        defer { WindowsWindowController.shared.shutdown() }
        WindowsApplication.main()
    }
}

@MainActor
private struct WindowsApplication: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = WindowsWindowController.shared.start { openWindow(id: $0) }
        Window("ToastMonitor", id: "usage") {
            WindowsUsageView()
                .inspectWindow { WindowsWindowController.shared.register($0, id: "usage") }
        }
        .defaultSize(width: 450, height: 680)
        .defaultLaunchBehavior(.suppressed)
        Window("ToastMonitor — Dashboard", id: "dashboard") {
            WindowsDashboardView()
                .inspectWindow { WindowsWindowController.shared.register($0, id: "dashboard") }
        }
        .defaultSize(width: 1040, height: 740)
        .defaultLaunchBehavior(.suppressed)
        Window("ToastMonitor — Settings", id: "settings") {
            WindowsSettingsView()
                .inspectWindow { WindowsWindowController.shared.register($0, id: "settings") }
        }
        .defaultSize(width: 880, height: 720)
        .defaultLaunchBehavior(.suppressed)
    }
}
