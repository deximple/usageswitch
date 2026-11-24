import Foundation

/// The limits `claude -p /usage` sends in structured form beside its panel text:
/// `usage_report.rate_limits.limits[]` on the answer's own assistant line (CLI 2.1.325 and later).
/// Their numbers are used ahead of the panel's, which prints each reset cut to the minute —
/// "10:59pm" on one run and "11pm" on the next for the same reset. Only a limit's kind, percent,
/// reset and scope name are looked at; the session totals beside them never are.
public enum ClaudeUsageLimits {
    public enum Reading: Equatable, Sendable {
        /// Nothing to read: an older CLI, no report on the line, or no limit listed.
        case absent
        /// Rows are there and none can be used: a row of a known kind is malformed (one spoils the
        /// report, so a limit that is used up is never dropped while the others are shown), or
        /// every row is of a kind this build doesn't know.
        case unreadable
        /// The rows of the kinds this build knows. `complete` is false when a row of another kind
        /// was left out — the vendor adds kinds without a CLI release — so these are not every
        /// limit the account has.
        case windows([UsageWindow], complete: Bool)
    }

    private static let report = "usage_report"
    /// The window length a row's `kind` stands for; the vendor classifies its rows by kind.
    private static let minutesByKind = ["session": 300, "weekly_all": 10080, "weekly_scoped": 10080]
    /// A kind that is always for one model or surface: without a name it can't be told from the
    /// plan-wide limit.
    private static let scopedKind = "weekly_scoped"
    /// The vendor's own bound on a display name.
    private static let maximumNameLength = 128
    /// The panel calls the Sonnet limit "Sonnet only"; a row names the model alone.
    private static let panelSuffix = " only"

    public static func reading(in lines: [String]) -> Reading {
        let answers: [[String: Any]] = lines.compactMap(ClaudeUsageOutput.object).filter(ClaudeUsageOutput.isLocalAnswer)
        let reports: [[String: Any]] = answers.compactMap { $0[report] as? [String: Any] }
        guard let found = reports.first, let rateLimits = present(found["rate_limits"]) else { return .absent }
        guard let rateLimits = rateLimits as? [String: Any] else { return .unreadable }
        guard let limits = present(rateLimits["limits"]) else { return .absent }
        guard let rows = limits as? [Any] else { return .unreadable }
        guard !rows.isEmpty else { return .absent }
        var windows: [UsageWindow] = []
        var complete = true
        for row in rows {
            guard let row = row as? [String: Any], let kind = row["kind"] as? String else { return .unreadable }
            guard let minutes = minutesByKind[kind] else { complete = false; continue }
            guard let window = window(row, kind: kind, minutes: minutes) else { return .unreadable }
            windows.append(window)
        }
        // Two rows for one window would share a pin and a pace sample, and nothing says which counts.
        let keys = Set(windows.map { WindowKey(kind: $0.kind, scope: $0.scope?.lowercased()) })
        guard !windows.isEmpty, keys.count == windows.count else { return .unreadable }
        return .windows(windows, complete: complete)
    }

    /// The panel's windows, each with the numbers of its structured row where it has one. The
    /// panel still says which limits there are and what they are called: the vendor's CLI builds
    /// its plan-wide lines from other fields and leaves out per-model rows it doesn't show, so a
    /// row list can both lack a line the panel prints and hold one it hides.
    public static func refining(_ panel: [UsageWindow], with rows: [UsageWindow]) -> [UsageWindow] {
        panel.map { window in
            guard let row = row(for: window, in: rows) else { return window }
            return UsageWindow(scope: window.scope, durationMinutes: window.durationMinutes,
                               usedPercent: row.usedPercent, resetsAt: row.resetsAt ?? window.resetsAt)
        }
    }

    /// The structured row for the same limit as a panel window: same length, same scope name.
    public static func row(for window: UsageWindow, in rows: [UsageWindow]) -> UsageWindow? {
        let name = window.scope.map(rowName)
        return rows.first { $0.kind == window.kind && $0.scope?.lowercased() == name }
    }

    /// A panel scope as a row would name it.
    private static func rowName(_ panelScope: String) -> String {
        let name = panelScope.lowercased()
        return name.hasSuffix(panelSuffix) ? String(name.dropLast(panelSuffix.count)) : name
    }

    private struct WindowKey: Hashable {
        let kind: UsageWindow.Kind
        let scope: String?
    }

    private enum Field<Value> {
        case none, value(Value), malformed
    }

    /// nil when a row of a known kind doesn't have the shape this build reads.
    private static func window(_ row: [String: Any], kind: String, minutes: Int) -> UsageWindow? {
        guard let percent = row["percent"] as? NSNumber, let used = UsageJSON.percent(percent) else { return nil }
        let scope: String?
        switch scopeName(row["scope"]) {
        case .malformed: return nil
        case .none: scope = nil
        case .value(let name): scope = name
        }
        if kind == scopedKind, scope == nil { return nil }
        guard let raw = present(row["resets_at"]) else {
            return UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used, resetsAt: nil)
        }
        guard let resets = UsageJSON.resetDateISO(raw) else { return nil }
        return UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used, resetsAt: wholeMinute(resets))
    }

    /// The server's reset moments differ by a fraction of a second from answer to answer
    /// (22:59:59.6, then 23:00:00.1), and `UsagePace` joins two reads only when their resets are
    /// equal. The nearest whole minute is the same moment for both.
    static func wholeMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// The model the row is for, else the surface.
    private static func scopeName(_ value: Any?) -> Field<String> {
        guard let value = present(value) else { return .none }
        guard let scope = value as? [String: Any] else { return .malformed }
        for key in ["model", "surface"] {
            switch displayName(scope[key]) {
            case .malformed: return .malformed
            case .value(let name): return .value(name)
            case .none: continue
            }
        }
        return .none
    }

    private static func displayName(_ value: Any?) -> Field<String> {
        guard let value = present(value) else { return .none }
        guard let name = (value as? [String: Any])?["display_name"] as? String,
              !name.isEmpty, name.count <= maximumNameLength
        else { return .malformed }
        return .value(name)
    }

    /// nil for a key that is missing or JSON null — the vendor sends either for "nothing here".
    private static func present(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }
}
