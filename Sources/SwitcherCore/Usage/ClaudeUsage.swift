import Foundation

/// Whether this Mac has managed Claude Code settings. Managed hooks can't be turned off by the values
/// a usage run passes, so their presence refuses the run. Existence only — contents are never read,
/// and an unreadable location counts as absent (Claude Code itself couldn't read it either).
public struct ClaudeManagedSettings: Sendable, Equatable {
    /// The folder holding `managed-settings.json` and `managed-settings.d/`.
    public let folder: URL
    /// The folder holding `com.anthropic.claudecode.plist`, possibly per-user in subfolders.
    public let preferences: URL

    public init(folder: URL, preferences: URL) {
        self.folder = folder
        self.preferences = preferences
    }

    public static let system = ClaudeManagedSettings(
        folder: URL(fileURLWithPath: "/Library/Application Support/ClaudeCode", isDirectory: true),
        preferences: URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true))

    private static let preferenceFile = "com.anthropic.claudecode.plist"
    /// An org's server-managed settings land as a copy in the account's own folder.
    private static let serverCopy = "remote-settings.json"

    /// Whether managed settings would bind a usage run under `claudeFolder` (~/.claude).
    func shuts(claudeFolder: URL) -> Bool {
        isPresent || FileManager.default.fileExists(atPath: claudeFolder.appendingPathComponent(Self.serverCopy).path)
    }

    public var isPresent: Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.appendingPathComponent("managed-settings.json").path) { return true }
        let dropIns = (try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent("managed-settings.d").path)) ?? []
        if !dropIns.isEmpty { return true }
        if manager.fileExists(atPath: preferences.appendingPathComponent(Self.preferenceFile).path) { return true }
        let users = (try? manager.contentsOfDirectory(atPath: preferences.path)) ?? []
        return users.contains { user in
            manager.fileExists(atPath: preferences.appendingPathComponent(user).appendingPathComponent(Self.preferenceFile).path)
        }
    }
}

/// The stream-json output of `claude -p /usage` (`--output-format stream-json --verbose`). Only the
/// answer's text and the stop markers are read; the init line's account fields are never looked at.
public enum ClaudeUsageOutput {
    public enum Failure: Error, Equatable {
        /// A hook event, a model turn, turns or cost was seen; the output is discarded.
        case stopped
        /// No usable result line.
        case unreadable
    }

    /// `/usage` answers through this placeholder model name; a real model turn means the session did work.
    private static let localModel = "<synthetic>"
    private static let hookEvents: Set<String> = ["hook_started", "hook_response", "hook_progress"]

    /// Whether a stdout line ends the run's usefulness: a hook event or a non-synthetic assistant turn.
    public static func stops(_ line: String) -> Bool {
        object(line).flatMap(reason) != nil
    }

    /// Whether a stdout line is the final result.
    public static func answers(_ line: String) -> Bool {
        object(line)?["type"] as? String == "result"
    }

    /// The answer's text. Fails when a stop line was seen, when the run did turns or cost anything,
    /// or when no clean result line exists.
    public static func text(in lines: [String]) -> Result<String, Failure> {
        let objects = lines.compactMap(object)
        if objects.lazy.compactMap(reason).first != nil { return .failure(.stopped) }
        guard let result = objects.last(where: { $0["type"] as? String == "result" }) else {
            return .failure(.unreadable)
        }
        if (result["num_turns"] as? NSNumber)?.intValue ?? 0 != 0
            || (result["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0 != 0 {
            return .failure(.stopped)
        }
        guard result["is_error"] as? Bool != true, let text = result["result"] as? String else {
            return .failure(.unreadable)
        }
        return .success(text)
    }

    private static func reason(_ object: [String: Any]) -> Failure? {
        switch object["type"] as? String {
        case "system":
            return (object["subtype"] as? String).flatMap { hookEvents.contains($0) ? .stopped : nil }
        case "assistant":
            return (object["message"] as? [String: Any])?["model"] as? String != localModel ? .stopped : nil
        default:
            return nil
        }
    }

    static func object(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}

/// Reads windows out of the `/usage` panel text. Lines starting with `Current ` are the windows; the
/// percentages in the "What's contributing" block are not. A `Current ` line that doesn't parse means
/// the panel changed shape — it reports unreadable rather than risk missing a capped window.
public enum ClaudeUsageText {
    public enum Failure: Error, Equatable {
        /// No `Current ` line at all: not signed in with a subscription.
        case notReporting
        /// A `Current ` line this build doesn't understand.
        case unreadable
    }

    private static let line = try! NSRegularExpression(
        pattern: #"^Current (week|session)(?: \(([^)]+)\))?: (\d{1,3})% used · resets (.+) \(([^)]+)\)$"#)
    /// "Nov 6 at 12:59pm" or "7:40pm".
    private static let reset = try! NSRegularExpression(
        pattern: #"^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?(am|pm)$"#)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let allModels = "all models"

    public static func windows(_ text: String, readAt: Date) -> Result<[UsageWindow], Failure> {
        let current = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Current ") }
        guard !current.isEmpty else { return .failure(.notReporting) }
        let windows = current.compactMap { window($0, readAt: readAt) }
        return windows.count == current.count ? .success(windows) : .failure(.unreadable)
    }

    private static func window(_ text: String, readAt: Date) -> UsageWindow? {
        guard let parts = groups(line, text), let label = parts[0], let used = parts[2].flatMap(Double.init),
              used <= 100, let resetText = parts[3], let zoneName = parts[4],
              let zone = TimeZone(identifier: zoneName),
              let resets = resetDate(resetText, zone: zone, readAt: readAt)
        else { return nil }
        let scope = parts[1].flatMap { $0 == allModels ? nil : $0 }
        return UsageWindow(scope: scope, durationMinutes: label == "week" ? 10080 : 300,
                           usedPercent: used, resetsAt: resets)
    }

    /// "Nov 6 at 12:59pm" or "7:40pm" in the named zone. A bare time means the next time it occurs
    /// (tonight, or tomorrow once it has passed); a past date rolls to next year.
    private static func resetDate(_ text: String, zone: TimeZone, readAt: Date) -> Date? {
        guard let parts = groups(reset, text), let hourText = parts[2], let twelve = Int(hourText),
              (1...12).contains(twelve), let meridiem = parts[4]
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var when = calendar.dateComponents([.year, .month, .day], from: readAt)
        when.hour = twelve % 12 + (meridiem == "pm" ? 12 : 0)
        when.minute = parts[3].flatMap(Int.init) ?? 0
        guard let month = parts[0] else {
            guard let today = calendar.date(from: when) else { return nil }
            return today > readAt ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        guard let index = months.firstIndex(of: month), let day = parts[1].flatMap(Int.init) else { return nil }
        when.month = index + 1
        when.day = day
        guard let date = calendar.date(from: when) else { return nil }
        return date.addingTimeInterval(86_400) < readAt ? calendar.date(byAdding: .year, value: 1, to: date) : date
    }

    private static func groups(_ expression: NSRegularExpression, _ text: String) -> [String?]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
