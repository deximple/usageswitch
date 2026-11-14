import Foundation

/// The command line of `usageswitch-drift`.
public struct DriftArguments: Equatable, Sendable {
    public static let usage =
        "usage: usageswitch-drift --work <empty folder> [--snapshot <file>] [--update-snapshot [--codex <cli>]]"

    /// An existing empty folder for the vendor CLIs to start in and write their schema to.
    public let work: String
    /// The frozen Codex protocol snapshot to compare with.
    public let snapshot: String?
    /// Print a fresh snapshot instead of a report.
    public let updateSnapshot: Bool
    /// The Codex CLI to take that snapshot from, instead of the one the app runs.
    public let codex: String?

    public enum Failure: Error, Equatable {
        case missingValue(String)
        case unknown(String)
        case workRequired
    }

    public static func parse(_ arguments: [String]) -> Result<DriftArguments, Failure> {
        var values: [String: String] = [:]
        var update = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--update-snapshot":
                update = true
            case "--work", "--snapshot", "--codex":
                guard index + 1 < arguments.count else { return .failure(.missingValue(argument)) }
                values[argument] = arguments[index + 1]
                index += 1
            default:
                return .failure(.unknown(argument))
            }
            index += 1
        }
        guard let work = values["--work"] else { return .failure(.workRequired) }
        return .success(DriftArguments(work: work, snapshot: values["--snapshot"],
                                       updateSnapshot: update, codex: values["--codex"]))
    }
}
