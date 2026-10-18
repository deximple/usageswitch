import Foundation
import Testing
@testable import SwitcherCore

/// Where an `install(names:)` run can be killed while applying one item (write-ahead journal windows).
enum CrashPoint: String, Sendable {
    /// Journal entry saved (done=false), nothing touched yet.
    case afterSave
    /// `swapped` only: staged and live exchanged, the old live content still sits in staging.
    case afterSwap
    /// Every filesystem step finished, but the entry was not yet marked done.
    case afterMove
}

struct CrashCase: Sendable, CustomStringConvertible {
    let name: String
    let point: CrashPoint
    var description: String { "\(name) \(point.rawValue)" }
}

enum CrashFixture {
    /// Leaves the disk exactly as an `install(names:)` killed at `point` while applying `name` would: every earlier
    /// name applied by the real engine, then the write-ahead entry for `name`, then the filesystem steps up to `point`.
    /// Staging must already hold the incoming items. `legacy` writes every entry the way journals did before
    /// `originalDigest` existed (so recovery must fall back to `stagedDigest`).
    static func interruptInstall(fs: SafeFS, env: SwitcherEnvironment, engine: SwapEngine, names: [String],
                                 at name: String, _ point: CrashPoint, legacy: Bool = false) throws {
        let idx = try #require(names.firstIndex(of: name))
        try engine.install(names: Array(names[..<idx]))
        var journal = try #require(engine.pendingJournal())
        journal.state = "installing"
        let live = env.claudeUserData.appendingPathComponent(name)
        let staged = env.stagingDir.appendingPathComponent(name)
        let prev = env.previousDir.appendingPathComponent(name)
        let kind: SwapEngine.Journal.Kind = SwapEngine.exists(staged) ? (SwapEngine.exists(live) ? .swapped : .created) : .removed
        journal.applied.append(.init(name: name, kind: kind, done: false,
                                     stagedDigest: kind == .removed ? nil : try SwapEngine.digest(staged),
                                     originalDigest: kind == .created ? nil : try SwapEngine.digest(live)))
        if legacy { journal = stripOriginalDigests(journal) }
        try fs.write(try JSONEncoder().encode(journal), to: env.journalFile)
        switch (kind, point) {
        case (_, .afterSave): break
        case (.swapped, .afterSwap): try fs.swap(staged, live)
        case (.swapped, .afterMove):
            try fs.swap(staged, live)
            try fs.move(staged, to: prev)
        case (.created, .afterMove): try fs.move(staged, to: live)
        case (.removed, .afterMove): try fs.move(live, to: prev)
        default: Issue.record("\(kind) has no \(point) window")
        }
    }

    /// Marks a finished install as interrupted before its final "installed" save.
    static func markInstalling(fs: SafeFS, env: SwitcherEnvironment, engine: SwapEngine, legacy: Bool = false) throws {
        var journal = try #require(engine.pendingJournal())
        journal.state = "installing"
        if legacy { journal = stripOriginalDigests(journal) }
        try fs.write(try JSONEncoder().encode(journal), to: env.journalFile)
    }

    /// The same journal as written by an engine that predates `originalDigest`.
    static func stripOriginalDigests(_ journal: SwapEngine.Journal) -> SwapEngine.Journal {
        SwapEngine.Journal(state: journal.state, applied: journal.applied.map {
            .init(name: $0.name, kind: $0.kind, done: $0.done, stagedDigest: $0.stagedDigest)
        })
    }
}
