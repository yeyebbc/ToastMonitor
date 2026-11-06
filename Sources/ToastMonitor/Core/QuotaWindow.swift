struct QuotaWindow {
    /// Settings key: true shows how much of each window is left instead of
    /// how much is used.
    static let showsRemainingKey = "popoverQuotaShowsRemaining"

    let label: String
    /// 0…100, how much of the window is used.
    let usedPercent: Double
    /// Compact countdown ("3.9d", "2.1h"), nil once passed / unknown.
    let resetIn: String?
    /// 0…1, how much of the window's time has passed; nil if unknown.
    var elapsed: Double?

    /// What a number or bar shows, 0…100, in the selected used or remaining mode.
    static func shownPercent(used: Double, showsRemaining: Bool) -> Double {
        showsRemaining ? 100 - used : used
    }

    /// The time the bar compares against. Pace is a reading of usage, so the
    /// remaining mode is a plain gauge without it.
    func barElapsed(showsRemaining: Bool) -> Double? {
        showsRemaining ? nil : elapsed
    }
}
