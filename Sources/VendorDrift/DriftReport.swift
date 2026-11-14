import Foundation

public enum DriftStatus: String, Sendable {
    /// Checked; it is what the app expects.
    case ok
    /// The vendor changed something the app sends or reads.
    case drift
    /// Checked, but the answer settles nothing — worth a look, doesn't fail the run.
    case attention
    /// Something changed or is new, but nothing the app reads.
    case info
    /// Nothing to check: not installed, not signed in.
    case skipped
    /// Left out on purpose.
    case notChecked

    var label: String {
        switch self {
        case .ok: "ok"
        case .drift: "DRIFT"
        case .attention: "look"
        case .info: "info"
        case .skipped: "skipped"
        case .notChecked: "not checked"
        }
    }
}

public struct DriftFinding: Equatable, Sendable {
    public enum Section: String, Sendable, CaseIterable {
        case codexProtocol = "Codex app-server protocol"
        case strings = "Text the parsers depend on"
        case live = "Live reads"
        case notChecked = "Not checked"
    }

    public let section: Section
    public let check: String
    public let status: DriftStatus
    public let summary: String
    public let details: [String]

    public init(_ section: Section, _ check: String, _ status: DriftStatus, _ summary: String,
                details: [String] = []) {
        self.section = section; self.check = check; self.status = status
        self.summary = summary; self.details = details
    }
}

public struct DriftReport: Equatable, Sendable {
    public struct Tool: Equatable, Sendable {
        public let name: String
        /// Home shown as `~`.
        public let path: String
        public let version: String?
    }

    public let generatedAt: Date
    public let tools: [Tool]
    public let findings: [DriftFinding]

    public var hasDrift: Bool { findings.contains { $0.status == .drift } }

    public func markdown(timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let drift = findings.filter { $0.status == .drift }.count
        let look = findings.filter { $0.status == .attention }.count
        let headline = drift > 0
            ? "**Drift found: \(drift) check\(drift == 1 ? " needs" : "s need") a fix.**"
            : "**No drift found.**"
        var lines = ["# Vendor drift report — \(stamp.string(from: generatedAt))", "",
                     headline + (look > 0 ? " \(look) more worth a look." : ""), "",
                     "| Check | Result | What was found |", "|---|---|---|"]
        lines += findings.map { "| \(cell($0.check)) | \($0.status.label) | \(cell($0.summary)) |" }
        lines += ["", "## Installed tools", ""]
        lines += tools.isEmpty ? ["None of the tools UsageSwitch reads is installed."]
            : tools.map { "- \($0.name): `\($0.path)`" + ($0.version.map { " — \($0)" } ?? "") }
        for section in DriftFinding.Section.allCases {
            let own = findings.filter { $0.section == section }
            guard !own.isEmpty else { continue }
            lines += ["", "## \(section.rawValue)"]
            for finding in own {
                lines += ["", "### \(finding.check) — \(finding.status.label)", "", finding.summary]
                if !finding.details.isEmpty { lines += [""] + finding.details.map { "- \($0)" } }
            }
        }
        lines += ["", "## Running this regularly", "", Self.scheduleNote, ""]
        return lines.joined(separator: "\n")
    }

    private func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static let scheduleNote = """
        Nothing was scheduled by this run. Vendor CLIs update themselves, so a weekly run (and one \
        right after a CLI update) catches most changes before a user does. Options, all left to you: \
        a launchd agent or cron line that runs `scripts/vendor-drift.sh` and keeps the report, or a \
        scheduled Claude Code task that runs it and reads `latest.md`. See `docs/vendor-drift.md`.
        """
}
