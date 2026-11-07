import Foundation
import CryptoKit

/// Remote usage collector: pulls the usage feed exported by the VPS
/// (cron exporter over a user-configured HTTPS or private-network feed)
/// and imports turns for tools that have enabled that feed.
///
/// Row semantics per tool (produced by tm-export.py):
///  - hermes:   aggregate per (session, model) — delta-tracked locally
///  - opencode: cumulative per session — delta via session_totals
///  - claude:   per-turn events (real ts) — direct insert
///  - codex:    per-turn events (real ts) — direct insert
///
/// Event IDs provide idempotency; timestamp watermarks are retained only for
/// diagnostics and never exclude a valid per-turn event.
final class HermesRemoteClient {
    nonisolated(unsafe) static let shared = HermesRemoteClient()
    static let maxFeedURLLength = 2_048
    static let maxFeedBytes = 10_000_000
    static let maxFeedRows = 50_000
    static let maxFieldLength = 512
    static let maxProviderLength = 256

    private static let legacyFeedKey = "remote_feed_url"

    private let queue = DispatchQueue(label: "toastmonitor.remote", qos: .utility)
    private let session: URLSession
    /// Retained: URLSession keeps its delegate weakly.
    private let redirectBlocker = NoRedirectDelegate()
    private var lastPoll: [String: Int64] = [:]
    private var timer: Timer?
    private var inFlight: [String: [DispatchGroup]] = [:]
    private var started = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration,
                             delegate: redirectBlocker, delegateQueue: nil)
        observeForeground()
    }

    private var popoverVisible = false
    private var dashboardVisible = false
    private var foreground = false

    private func updateForeground() {
        let fg = popoverVisible || dashboardVisible
        guard fg != foreground else { return }
        foreground = fg
        if fg {
            startTimer()
            poll()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func observeForeground() {
        for name in [TMNotifications.popoverVisibility, TMNotifications.dashboardVisibility] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let visible = (note.object as? Bool) ?? false
                if name == TMNotifications.popoverVisibility {
                    self.popoverVisible = visible
                } else {
                    self.dashboardVisible = visible
                }
                self.updateForeground()
            }
        }
    }

    private static func feedKey(for tool: ToolKind) -> String {
        "\(legacyFeedKey)_\(tool.rawValue)"
    }

    func feedURL(for tool: ToolKind, in database: any ParserStateStore = Database.shared) -> String {
        // Existing configurations keep their feed until a tool saves its own.
        // An explicitly empty value also overrides the old shared URL.
        database.setting(Self.feedKey(for: tool)) ?? database.setting(Self.legacyFeedKey) ?? ""
    }

    @discardableResult
    func provision(url: String, for tool: ToolKind, in database: Database = .shared) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tool.supportsRemoteSource, Self.feedURLProblem(trimmed) == nil else { return false }
        let address = trimmed.isEmpty ? "" : URL(string: trimmed)?.absoluteString
        return database.setSetting(Self.feedKey(for: tool), address)
    }

    static func feedURLProblem(_ address: String) -> String? {
        if address.isEmpty { return nil }
        if address.count > maxFeedURLLength { return "URL too long (max \(maxFeedURLLength) chars)" }
        if address.rangeOfCharacter(from: .controlCharacters) != nil {
            return "URL contains control characters"
        }
        guard let url = URL(string: address) else { return "Not a valid URL" }
        guard isAllowedFeedURL(url) else { return "URL rejected. Use HTTPS or a private range." }
        return nil
    }

    func start() {
        guard !started else { return }
        started = true
        updateForeground()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Called from the collector loop; rate-limited internally (60s).
    func maybePoll() {
        // Keep the rate-limit check on the serial queue: lastPoll is only
        // mutated inside pollEnqueued, which always runs there.
        queue.async { [weak self] in
            self?.pollEnqueued(tool: nil, rateLimited: true, completion: nil)
        }
    }

    static func isAllowedFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              url.user == nil,
              url.password == nil else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host else { return false }
        // HTTP is limited to the Tailscale CGNAT range 100.64.0.0/10 and loopback.
        if let ip = IPv4Address(host) {
            if ip.isTailscale || ip.isLoopback { return true }
            return false
        }
        return host == "localhost"
    }

    private static func validField(_ value: Any?, maxLength: Int,
                                   allowEmpty: Bool = true) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let string = value as? String,
              (allowEmpty || !string.isEmpty),
              string.count <= maxLength,
              string.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return true
    }

    private struct IPv4Address {
        let a: UInt8, b: UInt8, c: UInt8, d: UInt8
        init?(_ s: String) {
            let parts = s.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { return nil }
            (a, b, c, d) = (parts[0], parts[1], parts[2], parts[3])
        }
        var isTailscale: Bool { a == 100 && b >= 64 && b <= 127 }
        var isLoopback: Bool { a == 127 }
    }

    // MARK: - Poll

    /// Enqueues one poll on the serial queue. Safe to call from any thread,
    /// including the main thread (Settings' "Test Connection").
    /// `completion` is invoked on the main actor once this poll finishes —
    /// success or failure, including the skip paths where no network request
    /// is made.
    func poll(tool: ToolKind? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            self?.pollEnqueued(tool: tool, rateLimited: false, completion: completion)
        }
    }

    private func remoteTools(in database: any ParserStateStore, address: String? = nil) -> [ToolKind] {
        ToolKind.allCases.filter { tool in
            tool.sources(in: database).includesRemote
                && (address == nil || feedURL(for: tool, in: database) == address)
        }
    }

    /// Runs on the serial queue. A feed shared by several tools is fetched once.
    private func pollEnqueued(tool: ToolKind?, rateLimited: Bool,
                              completion: (@MainActor @Sendable () -> Void)?) {
        let feeds = Dictionary(grouping: remoteTools(in: Database.shared)) { feedURL(for: $0) }
        lastPoll = lastPoll.filter { feeds[$0.key] != nil }
        let now = Int64(Date().timeIntervalSince1970)
        let group = DispatchGroup()
        for (address, tools) in feeds {
            if let tool, !tools.contains(tool) { continue }
            guard !rateLimited || now - (lastPoll[address] ?? 0) > 60 else { continue }
            lastPoll[address] = now
            if let problem = address.isEmpty ? "Enter a feed URL" : Self.feedURLProblem(address) {
                publishHealth(for: tools, address: address, error: problem)
                continue
            }
            guard let url = URL(string: address) else { continue }
            group.enter()
            fetch(url, address: address, group: group)
        }
        if let completion {
            group.notify(queue: .main) {
                Task { @MainActor in completion() }
            }
        }
    }

    private func fetch(_ url: URL, address: String, group: DispatchGroup) {
        if inFlight[address] != nil {
            inFlight[address]?.append(group)
            return
        }
        inFlight[address] = [group]
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        redirectBlocker.boundedDataTask(in: session, request: req,
                                        maxBytes: Self.maxFeedBytes) { [weak self] data, resp, err in
            guard let self else { return }
            // The session completion arrives on a URLSession delegate queue;
            // hop back onto the serial queue for all state mutation. This is
            // not a nested queue.async inside pollEnqueued's own closure (it
            // runs later, off the queue), so there is no deadlock.
            self.queue.async {
                defer { self.inFlight.removeValue(forKey: address)?.forEach { $0.leave() } }
                let tools = self.remoteTools(in: Database.shared, address: address)
                guard !tools.isEmpty else { return }
                func fail(_ message: String) {
                    self.publishHealth(for: tools, address: address, error: message)
                }
                if let err {
                    fail(err.localizedDescription)
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    fail("No HTTP response")
                    return
                }
                // Redirects are cancelled by the delegate; retain this
                // final-URL check for custom URL loading implementations.
                if !Self.isAllowedFeedURL(http.url ?? url) {
                    fail("Redirect to a disallowed address rejected")
                    return
                }
                // Reject oversized responses from the Content-Length header
                // before the body finishes buffering.
                if http.expectedContentLength > Int64(Self.maxFeedBytes) {
                    fail("Response too large (>10MB)")
                    return
                }
                guard http.statusCode == 200 else {
                    fail("HTTP \(http.statusCode)")
                    return
                }
                guard let data, data.count <= Self.maxFeedBytes else {
                    fail("Response too large (>10MB)")
                    return
                }
                if let mime = http.mimeType, !mime.contains("json") {
                    fail("Non-JSON response (\(mime))")
                    return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    fail("Failed to parse response")
                    return
                }
                self.importFeed(obj, from: address)
            }
        }.resume()
    }

    private func publishHealth(for tools: [ToolKind], address: String, error: String?,
                               imported: [ToolKind: Int] = [:], failed: Int = 0) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tool in tools where tool.sources().includesRemote && self.feedURL(for: tool) == address {
                SourceHealthHub.shared.record(tool: tool.rawValue, mode: "remote",
                                              rows: imported[tool] ?? 0, failed: failed,
                                              durationMs: 0, error: error)
            }
        }
    }

    func importFeed(_ result: [String: Any], from address: String? = nil, database: Database = .shared) {
        let state = StagedParserStateStore(database: database, sourcePaths: [])
        let tools = remoteTools(in: state, address: address)
        guard !tools.isEmpty else { return }
        func report(_ error: String) {
            if let address { publishHealth(for: tools, address: address, error: error) }
        }
        guard let rows = result["rows"] as? [[String: Any]],
              rows.count <= Self.maxFeedRows else {
            report("Feed format invalid or too many rows")
            return
        }
        if let schema = result["schema"] as? Int, schema > 1 {
            report("Unsupported feed schema v\(schema)")
            return
        }
        let sourceDigest = SHA256.hash(data: Data((address ?? state.setting(Self.legacyFeedKey) ?? "").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let sourceInstance = "remote:\(sourceDigest)"

        // Retain a monotonic watermark for diagnostics and migration
        // visibility, but never use it to decide whether a per-turn event is
        // eligible: event_id is the durable deduplication boundary. The
        // Cursor keeps the eventID only for same-second tie-break ordering;
        // only the timestamp is persisted (see the write below).
        struct Cursor {
            var ts: Int64
            var eventID: String
        }

        var turns: [TurnRecord] = []
        var sessions: [String: SessionInfo] = [:]
        var pendingWatermarks: [ToolKind: Cursor] = [:]
        var unknownTools = 0
        var malformedRows = 0
        let totals = state.sessionTotals()
        let toolRemoteSources = Set(tools)
        // Track updated OpenCode totals without rebuilding the totals
        // snapshot for every row. Hermes reads its staged settings directly.
        var runningOpenCode: [String: (tool: String, input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)] = [:]
        let nowTs = Int64(Date().timeIntervalSince1970)
        // Feed rows outside this window are rejected (a future-dated row
        // would poison the monotonic watermark and blind per-turn tools).
        let tsLower = nowTs - 10 * 366 * 86400
        let tsUpper = nowTs + 24 * 3600

        for row in rows {
            // Unknown tools are rejected, never silently treated as Hermes.
            guard let tool = ToolKind(rawValue: row["tool"] as? String ?? "") else {
                unknownTools += 1
                continue
            }
            guard toolRemoteSources.contains(tool) else { continue }
            guard let rawSession = row["session_id"] as? String,
                  !rawSession.isEmpty, rawSession.count <= Self.maxFieldLength,
                  rawSession.rangeOfCharacter(from: .controlCharacters) == nil else {
                malformedRows += 1
                continue
            }
            guard Self.validField(row["model"], maxLength: Self.maxFieldLength),
                  Self.validField(row["title"], maxLength: Self.maxFieldLength),
                  Self.validField(row["project"], maxLength: Self.maxFieldLength),
                  Self.validField(row["billing_provider"], maxLength: Self.maxProviderLength),
                  Self.validField(row["provider"], maxLength: Self.maxProviderLength),
                  Self.validField(row["billing_base_url"], maxLength: Self.maxFieldLength),
                  Self.validField(row["event_id"], maxLength: Self.maxFieldLength) else {
                malformedRows += 1
                continue
            }
            let sessionID = rawSession
            guard let rawLast = (row["last_seen"] as? NSNumber)?.doubleValue,
                  rawLast.isFinite, rawLast >= 0, rawLast <= 4_000_000_000_000 else {
                malformedRows += 1
                continue
            }
            let lastSeenS = Int64(rawLast > 1_000_000_000_000 ? rawLast / 1000 : rawLast)
            guard lastSeenS >= tsLower && lastSeenS <= tsUpper else {
                malformedRows += 1
                continue
            }
            let rawFirst = (row["first_seen"] as? NSNumber)?.doubleValue ?? Double(lastSeenS)
            guard rawFirst.isFinite, rawFirst >= 0, rawFirst <= 4_000_000_000_000 else {
                malformedRows += 1
                continue
            }
            let normalizedFirst = Int64(rawFirst > 1_000_000_000_000 ? rawFirst / 1000 : rawFirst)
            let firstSeenS = min(max(normalizedFirst, tsLower), min(lastSeenS, nowTs))
            let model = row["model"] as? String
            // All token values are non-negative and capped before arithmetic;
            // malformed numbers become zero instead of overflowing Int64 sums.
            func count(_ key: String) -> Int64 {
                guard let n = row[key] as? NSNumber else { return 0 }
                let d = n.doubleValue
                guard d.isFinite else { return 0 }
                return Int64(min(max(d, 0), Double(TurnRecord.maxTokens)))
            }
            let input = count("input_tokens")
            let output = count("output_tokens")
            let reasoning = count("reasoning_tokens")
            let cacheRead = count("cache_read_tokens")
            let cacheWrite = count("cache_write_tokens")
            let rawCost = (row["cost_usd"] as? NSNumber)?.doubleValue ?? 0
            let cost = rawCost.isFinite ? min(max(rawCost, 0), 1_000_000_000) : 0
            let title = row["title"] as? String
            let project = row["project"] as? String

            var dInput = input
            var dReasoning = reasoning
            var dOutput = output
            var dCacheRead = cacheRead
            var dCacheWrite = cacheWrite
            var dCost = cost
            let hasReportedCost = (row["cost_usd"] as? NSNumber).map { $0.doubleValue.isFinite } ?? false
            var costQuality = hasReportedCost ? "estimated" : "unknown"
            let rawEventID = row["event_id"] as? String ?? ""
            let eventID = rawEventID.isEmpty
                ? Self.fallbackEventID(row: row, tool: tool, sessionID: sessionID,
                                       lastSeen: lastSeenS, firstSeen: firstSeenS)
                : rawEventID
            // Event identity, not a timestamp watermark, is the idempotency
            // boundary for per-turn rows. A producer can append a valid event
            // older than the current cursor; re-reading it is cheap and
            // INSERT ... ON CONFLICT DO NOTHING keeps the import exact.
            // Cumulative Hermes/OpenCode rows remain idempotent via their
            // persisted baselines below.
            var isFirstRow = false // first row = the session's cumulative baseline, dated firstSeen

            switch tool {
            case .hermes:
                // Hermes traffic bills through the underlying plans
                // (OpenCode Go plan / OpenRouter balance / Codex subscription) — tokens
                // only, never cost here.
                // Delta key is per (session, model, billing route): one
                // cumulative row per (provider, base_url) combo — sharing a
                // key lets later small rows clobber the baseline. base_url is
                // normalized (trailing slash) because Hermes flips the slash
                // on route changes, which would otherwise open a fresh row
                // carrying the FULL cumulative value (double counting).
                let key = HermesUsageBaseline.key(session: sessionID, model: model,
                                                  provider: row["billing_provider"] as? String,
                                                  baseURL: row["billing_base_url"] as? String)
                // hm_d| baselines grow one settings entry per distinct
                // (session, model, billing route) and are never pruned.
                // Retention is deliberately absent: deleting a baseline would
                // replay that session's cumulative totals as fresh deltas
                // (double counting). Growth is bounded by distinct sessions
                // seen via the feed and is the accepted tradeoff. A session
                // the local parser already counted continues from its
                // baseline instead of starting over.
                let current = HermesUsageBaseline.Counters(input: input, output: output, reasoning: reasoning,
                                                            cacheRead: cacheRead, cacheWrite: cacheWrite)
                let local: [Int64] = totals[HermesUsageBaseline.localTotalsKey(key)]
                    .map { [$0.input, $0.output, $0.reasoning, $0.cacheRead, $0.cacheWrite, 0] } ?? []
                let prev = HermesUsageBaseline.merge(current: current, baselines: [local,
                    HermesUsageBaseline.parse(state.setting(key))])
                let step = HermesUsageBaseline.advance(
                    current: .init(input: input, output: output, reasoning: reasoning,
                                   cacheRead: cacheRead, cacheWrite: cacheWrite),
                    prev: prev)
                isFirstRow = step.isFirst
                dInput = step.delta.input
                dOutput = step.delta.output
                dReasoning = step.delta.reasoning
                dCacheRead = step.delta.cacheRead
                dCacheWrite = step.delta.cacheWrite
                let base = step.base
                state.setSetting(key, HermesUsageBaseline.encode(base))
                state.setSessionTotals(HermesUsageBaseline.localTotalsKey(key), tool: "hermes",
                                       input: base.input, output: base.output, reasoning: base.reasoning,
                                       cacheRead: base.cacheRead, cacheWrite: base.cacheWrite, cost: 0, updated: nowTs)
                dCost = 0
                costQuality = "unknown"
            case .opencode:
                let totalsKey = "opencode|\(sessionID)"
                let prev = runningOpenCode[totalsKey] ?? totals[totalsKey]
                isFirstRow = prev == nil
                var legacyCombinedInput = false
                if let prev {
                    legacyCombinedInput = prev.reasoning == 0
                        && reasoning > 0 && prev.input == input + reasoning
                    dInput = max((legacyCombinedInput ? input + reasoning : input) - prev.input, 0)
                    dOutput = max(output - prev.output, 0)
                    dReasoning = legacyCombinedInput ? 0 : max(reasoning - prev.reasoning, 0)
                    dCacheRead = max(cacheRead - prev.cacheRead, 0)
                    dCacheWrite = max(cacheWrite - prev.cacheWrite, 0)
                    dCost = max(cost - prev.cost, 0)
                }
                let safeInput = legacyCombinedInput ? input : (prev.map { max(input, $0.input) } ?? input)
                let safeOutput = prev.map { max(output, $0.output) } ?? output
                let safeReasoning = legacyCombinedInput ? reasoning : (prev.map { max(reasoning, $0.reasoning) } ?? reasoning)
                let safeRead = prev.map { max(cacheRead, $0.cacheRead) } ?? cacheRead
                let safeWrite = prev.map { max(cacheWrite, $0.cacheWrite) } ?? cacheWrite
                let safeCost = prev.map { max(cost, $0.cost) } ?? cost
                runningOpenCode[totalsKey] = ("opencode", safeInput, safeOutput, safeReasoning,
                                              safeRead, safeWrite, safeCost)
                state.setSessionTotals(totalsKey, tool: "opencode", input: safeInput, output: safeOutput,
                                       reasoning: safeReasoning, cacheRead: safeRead, cacheWrite: safeWrite,
                                       cost: safeCost, updated: lastSeenS)
                costQuality = hasReportedCost ? "actual" : "unknown"
            default:
                break // per-turn events: insert as-is
            }

            if dInput > 0 || dOutput > 0 || dReasoning > 0 || dCacheRead > 0 || dCacheWrite > 0 {
                // First-seen rows are cumulative baselines: attribute them to
                // the session's start date, not "now".
                let ts = (isFirstRow && firstSeenS > 0) ? firstSeenS : lastSeenS
                let provider = (row["billing_provider"] as? String)
                    ?? (row["provider"] as? String)
                turns.append(TurnRecord(tool: tool, sessionID: sessionID, project: project,
                                        model: model, ts: ts,
                                        inputTokens: dInput, outputTokens: dOutput,
                                        reasoningTokens: dReasoning,
                                        cacheRead: dCacheRead, cacheWrite: dCacheWrite, cost: dCost,
                                        provider: provider, sourceInstance: sourceInstance,
                                        eventID: eventID, costQuality: costQuality))
            }
            sessions["\(tool.rawValue)|\(sessionID)"] = SessionInfo(tool: tool, sessionID: sessionID, title: title,
                                                                    project: project, model: model,
                                                                    created: firstSeenS,
                                                                    updated: lastSeenS)
            // Clamp the cursor to now: a future-dated row (within the +24h
            // acceptance window) must not advance the watermark past the
            // present, or it would blind per-turn import until the feed
            // catches up.
            let candidate = Cursor(ts: min(lastSeenS, nowTs), eventID: eventID)
            if let previous = pendingWatermarks[tool] {
                if candidate.ts > previous.ts || (candidate.ts == previous.ts && candidate.eventID > previous.eventID) {
                    pendingWatermarks[tool] = candidate
                }
            } else {
                pendingWatermarks[tool] = candidate
            }
        }

        for (tool, value) in pendingWatermarks {
            state.setSetting("remote_watermark_\(tool.rawValue)", "\(value.ts)")
        }
        // A concurrent local scan can advance a shared baseline while this
        // feed is being parsed. Revalidate before committing either delta.
        let ok = database.inTransaction {
            state.validateForCommit()
                && database.insertTurns(turns)
                && database.upsertSessions(Array(sessions.values))
                && state.apply()
        }
        guard ok else {
            report("Source changed or write failed. Retrying on the next pull.")
            return
        }
        let ignoredRows = unknownTools + malformedRows
        let errorText = ignoredRows > 0 ? "\(ignoredRows) invalid/unknown rows ignored" : nil
        let importedTurnCount = turns.count
        if let address {
            let importedByTool = turns.reduce(into: [ToolKind: Int]()) { counts, turn in
                counts[turn.tool, default: 0] += 1
            }
            publishHealth(for: tools, address: address, error: errorText,
                          imported: importedByTool, failed: ignoredRows)
        }
        Task { @MainActor in
            // Remote import completes after the collector's local scan
            // notification. Publish the same refresh signal so the menu bar
            // and dashboard do not wait for the next snapshot poll.
            NotificationCenter.default.post(name: CollectorEngine.didCollect, object: nil)
        }
        if importedTurnCount > 0 || ignoredRows > 0 {
            NSLog("[ToastMonitor] remote feed: %d rows received, %d turns imported, %d invalid",
                  rows.count, importedTurnCount, ignoredRows)
        }
    }

    /// Feed rows without an upstream event_id still need a stable identity.
    /// Hashing the canonical JSON preserves distinct same-second rows while
    /// keeping the SQLite event_id compact and free of raw prompt content.
    private static func fallbackEventID(row: [String: Any], tool: ToolKind,
                                        sessionID: String, lastSeen: Int64,
                                        firstSeen: Int64) -> String {
        let digest: String
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            digest = "\(firstSeen):\(lastSeen)"
        }
        let full = "remote:\(tool.rawValue):\(sessionID):\(digest)"
        guard full.count <= Self.maxFieldLength else {
            let sessionDigest = SHA256.hash(data: Data(sessionID.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "remote:\(tool.rawValue):\(sessionDigest):\(digest)"
        }
        return full
    }
}
