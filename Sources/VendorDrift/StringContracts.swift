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
        let passed = "ClaudeUsageCollector passes it to keep the run quiet and local"
        var contracts: [StringContract] = [
            StringContract("Current session", reason: panel),
            StringContract("Current week (all models)", reason: panel),
            StringContract(label: "% used · resets ", reason: panel, bytes: panelSeparator),
            StringContract("<synthetic>", reason: stream),
            StringContract("num_turns", reason: stream),
            StringContract("total_cost_usd", reason: stream),
            StringContract("is_error", reason: stream),
        ]
        for word in invocation(ClaudeUsageCollector.arguments) {
            contracts.append(StringContract(word, reason: passed))
        }
        return contracts
    }

    /// `% used · resets ` the three ways a binary may store its middle dot.
    private static var panelSeparator: [[UInt8]] {
        let before: [UInt8] = Array("% used ".utf8)
        let after: [UInt8] = Array(" resets ".utf8)
        let escaped: [UInt8] = Array(#"% used \xB7 resets "#.utf8)   // as written in the bundled script
        let utf8: [UInt8] = Array("% used · resets ".utf8)
        var latin1: [UInt8] = before                                 // a Latin-1 string table
        latin1.append(0xB7)
        latin1.append(contentsOf: after)
        return [escaped, utf8, latin1]
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
        var words: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--") {
                words.append(argument)
            } else if index > 0, arguments[index - 1] == "--output-format" {
                words.append(argument)
            } else if argument.hasPrefix("{"),
                      let object = try? JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String: Any] {
                words.append(contentsOf: object.keys.sorted())
            }
        }
        return words
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
        let missing: [StringContract] = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [StringContract] in
            contracts.filter { (contract: StringContract) -> Bool in !contains(contract, in: buffer) }
        }
        return .scanned(missing: missing)
    }

    private static func contains(_ contract: StringContract, in buffer: UnsafeRawBufferPointer) -> Bool {
        for needle in contract.alternatives {
            guard !needle.isEmpty, buffer.count >= needle.count else { continue }
            if memmem(buffer.baseAddress, buffer.count, needle, needle.count) != nil { return true }
        }
        return false
    }
}
