import Darwin
import Foundation
import SwitcherCore

/// One piece of text a parser in SwitcherCore depends on, as it should appear inside a vendor
/// binary. Any one of `alternatives` being present satisfies it.
public struct StringContract: Equatable, Sendable {
    /// What is looked for, as shown in the report.
    public let label: String
    /// What breaks without it.
    public let reason: String
    public let alternatives: [[UInt8]]

    public init(_ label: String, reason: String) {
        self.label = label; self.reason = reason; self.alternatives = [Array(label.utf8)]
    }

    init(label: String, reason: String, bytes alternatives: [[UInt8]]) {
        self.label = label; self.reason = reason; self.alternatives = alternatives
    }
}

public enum StringContracts {
    /// The `claude -p /usage` panel lines `ClaudeUsageText` reads, the stream-json fields
    /// `ClaudeUsageOutput` reads, and every flag and setting `ClaudeUsageCollector` passes.
    public static var claude: [StringContract] {
        let panel = "ClaudeUsageText reads the usage windows from this panel line"
        let stream = "ClaudeUsageOutput decides from it whether the answer is clean"
        let separator: [[UInt8]] = [
            Array(#"% used \xB7 resets "#.utf8),         // as written in the bundled script
            Array("% used · resets ".utf8),              // UTF-8
            Array("% used ".utf8) + [0xB7] + Array(" resets ".utf8),  // Latin-1 string table
        ]
        return [
            StringContract("Current session", reason: panel),
            StringContract("Current week (all models)", reason: panel),
            StringContract(label: "% used · resets ", reason: panel, bytes: separator),
            StringContract("<synthetic>", reason: stream),
            StringContract("num_turns", reason: stream),
            StringContract("total_cost_usd", reason: stream),
            StringContract("is_error", reason: stream),
        ] + invocation(ClaudeUsageCollector.arguments).map {
            StringContract($0, reason: "ClaudeUsageCollector passes it to keep the run quiet and local")
        }
    }

    /// The `/usage` screen title `AntigravityUsageScreen` looks for. The screen's footer is
    /// put together at run time, so it can't be found in the binary and isn't listed.
    public static let antigravity: [StringContract] = [
        StringContract("Models & Quota", reason: "AntigravityUsageScreen finds the quota screen by this title"),
    ]

    /// The error wording `CodexRateLimitsParser.failure(for:)` maps to a reason, and the request it sends.
    public static let codex: [StringContract] = [
        StringContract("account/rateLimits/read", reason: "CodexUsageCollector sends this request"),
        StringContract("excludeResetCreditDetails", reason: "CodexUsageCollector sends this parameter"),
        StringContract("chatgpt authentication required",
                       reason: "CodexRateLimitsParser reads an API-key sign-in from this error"),
        StringContract("authentication required",
                       reason: "CodexRateLimitsParser reads a signed-out home from this error"),
    ]

    /// The long options and settings keys in a command line: `--flag` words, the value after
    /// `--output-format`, and the keys of a JSON object argument.
    static func invocation(_ arguments: [String]) -> [String] {
        arguments.enumerated().flatMap { index, argument -> [String] in
            if argument.hasPrefix("--") { return [argument] }
            if index > 0, arguments[index - 1] == "--output-format" { return [argument] }
            guard argument.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any]
            else { return [] }
            return object.keys.sorted()
        }
    }
}

public enum BinaryStrings {
    public enum Scan: Equatable, Sendable {
        /// Missing, unreadable or empty.
        case unreadable
        /// A `#!` launcher: the text lives in whatever it starts, which is not searched.
        case script
        /// The contracts with no alternative anywhere in the file.
        case scanned(missing: [StringContract])
    }

    /// Searches `file` for each contract. The file is memory-mapped and only searched —
    /// nothing from it is kept.
    public static func scan(_ contracts: [StringContract], in file: URL) -> Scan {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), !data.isEmpty
        else { return .unreadable }
        guard !data.starts(with: Array("#!".utf8)) else { return .script }
        return data.withUnsafeBytes { buffer in
            .scanned(missing: contracts.filter { contract in
                !contract.alternatives.contains { needle in
                    guard !needle.isEmpty, buffer.count >= needle.count else { return false }
                    return memmem(buffer.baseAddress, buffer.count, needle, needle.count) != nil
                }
            })
        }
    }
}
