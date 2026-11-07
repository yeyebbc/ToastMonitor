import Foundation
import Combine

/// Per-source collection health, observable by the UI.
struct SourceHealth: Identifiable, Equatable {
    let tool: String
    let mode: String          // "local" | "remote"
    var lastScan: Int64 = 0
    var lastRows: Int = 0
    var failedRows: Int = 0
    var durationMs: Double = 0
    var error: String?

    var id: String { "\(tool)-\(mode)" }

    /// User-facing name used when an aggregate status needs to identify one
    /// failing source instead of reporting only a count.
    var displayName: String {
        let name = ToolKind(rawValue: tool)?.displayName ?? tool
        return mode == "remote" ? "\(name) (Remote)" : name
    }
    var isStale: Bool {
        lastScan > 0 && Date().timeIntervalSince1970 - TimeInterval(lastScan) > Self.staleThreshold
    }
}

extension SourceHealth {
    /// One staleness threshold for local sources and the remote feed alike.
    static let staleThreshold: TimeInterval = 120
}

@MainActor
final class SourceHealthHub: ObservableObject {
    static let shared = SourceHealthHub()

    @Published private(set) var sources: [SourceHealth] = []

    private init() {}

    func record(tool: String, mode: String = "local", rows: Int, failed: Int,
                durationMs: Double, error: String?) {
        if mode == "local", ToolKind(rawValue: tool)?.sources().includesLocal == false { return }
        let h = SourceHealth(tool: tool, mode: mode, lastScan: Int64(Date().timeIntervalSince1970),
                             lastRows: rows, failedRows: failed, durationMs: durationMs, error: error)
        if let idx = sources.firstIndex(where: { $0.id == h.id }) {
            sources[idx] = h
        } else {
            sources.append(h)
        }
    }

    func remove(tool: ToolKind, mode: String) {
        if let index = sources.firstIndex(where: { $0.tool == tool.rawValue && $0.mode == mode }) {
            sources.remove(at: index)
        }
    }

    /// An unchanged scan is still a successful parse. Clear an old error so a
    /// transient failure cannot remain visible forever after recovery.
    func recordIdle(tool: String, durationMs: Double) {
        if let existing = sources.first(where: { $0.tool == tool && $0.mode == "local" }),
           existing.error == nil, existing.failedRows == 0, existing.lastRows == 0,
           existing.lastScan > 0,
           Date().timeIntervalSince1970 - TimeInterval(existing.lastScan) < 30 {
            return
        }
        record(tool: tool, rows: 0, failed: 0, durationMs: durationMs, error: nil)
    }
}
