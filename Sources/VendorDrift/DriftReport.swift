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

    public var hasDrift: Bool { count(of: .drift) > 0 }

    private func count(of status: DriftStatus) -> Int {
        findings.filter { (finding: DriftFinding) -> Bool in finding.status == status }.count
    }

    public func markdown(timeZone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        lines.append("# Vendor drift report — \(stamp.string(from: generatedAt))")
        lines.append("")
        lines.append(headline)
        lines.append("")
        lines.append("| Check | Result | What was found |")
        lines.append("|---|---|---|")
        for finding in findings {
            lines.append("| \(cell(finding.check)) | \(finding.status.label) | \(cell(finding.summary)) |")
        }
        lines.append("")
        lines.append("## Installed tools")
        lines.append("")
        if tools.isEmpty { lines.append("None of the tools UsageSwitch reads is installed.") }
        for tool in tools {
            var line = "- \(tool.name): `\(tool.path)`"
            if let version = tool.version { line += " — \(version)" }
            lines.append(line)
        }
        for section in DriftFinding.Section.allCases {
            let own: [DriftFinding] = findings.filter { (finding: DriftFinding) -> Bool in finding.section == section }
            guard !own.isEmpty else { continue }
            lines.append("")
            lines.append("## \(section.rawValue)")
            for finding in own {
                lines.append("")
                lines.append("### \(finding.check) — \(finding.status.label)")
                lines.append("")
                lines.append(finding.summary)
                if !finding.details.isEmpty { lines.append("") }
                for detail in finding.details { lines.append("- \(detail)") }
            }
        }
        lines.append("")
        lines.append("## Running this regularly")
        lines.append("")
        lines.append(Self.scheduleNote)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private var headline: String {
        let drift: Int = count(of: .drift)
        let look: Int = count(of: .attention)
        var text = "**No drift found.**"
        if drift == 1 { text = "**Drift found: 1 check needs a fix.**" }
        if drift > 1 { text = "**Drift found: \(drift) checks need a fix.**" }
        if look > 0 { text += " \(look) more worth a look." }
        return text
    }

    private func cell(_ text: String) -> String {
        let escaped: String = text.replacingOccurrences(of: "|", with: "\\|")
        return escaped.replacingOccurrences(of: "\n", with: " ")
    }

    static let scheduleNote = """
        Nothing was scheduled by this run. Vendor CLIs update themselves, so a weekly run (and one \
        right after a CLI update) catches most changes before a user does. Options, all left to you: \
        a launchd agent or cron line that runs `scripts/vendor-drift.sh` and keeps the report, or a \
        scheduled Claude Code task that runs it and reads `latest.md`. See `docs/vendor-drift.md`.
        """
}
