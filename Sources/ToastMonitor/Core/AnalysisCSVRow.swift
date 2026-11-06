import Foundation

/// One CSV line of the Analysis export.
struct AnalysisCSVRow: Equatable {
    let name: String
    let tokens: Int64
    let calls: Int64
    let cost: Double
    let ratio: Double

    /// One row per raw model id (never merged by display name), most-used
    /// first, so an export can be matched back to the logs and price table.
    static func perModelID(
        _ aggs: [(day: Int64, model: String, input: Int64, output: Int64, cacheRead: Int64, cost: Double, count: Int64, totalTokens: Int64)]
    ) -> [AnalysisCSVRow] {
        var tokens: [String: Int64] = [:], calls: [String: Int64] = [:], cost: [String: Double] = [:]
        for m in aggs {
            tokens[m.model, default: 0] += m.totalTokens
            calls[m.model, default: 0] += max(m.count, 0)
            cost[m.model, default: 0] += max(m.cost, 0)
        }
        let total = tokens.values.reduce(0, +)
        return tokens.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { id, t in
                AnalysisCSVRow(name: id, tokens: t, calls: calls[id] ?? 0, cost: cost[id] ?? 0,
                               ratio: total > 0 ? Double(t) / Double(total) : 0)
            }
    }
    static func csvField(_ value: String, text: Bool = true) -> String {
        var escaped = value
        if text {
            let leading = value.prefix(while: { $0.isWhitespace })
            let first = value.dropFirst(leading.count).first
            let formula = first.map { "=+-@".contains($0) } ?? false
            let control = leading.unicodeScalars.contains { $0.value == 9 || $0.value == 13 }
            if formula || control { escaped = "'" + value }
        }
        guard escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r") else { return escaped }
        return "\"\(escaped.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
