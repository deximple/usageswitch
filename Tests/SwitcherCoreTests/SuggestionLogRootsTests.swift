import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion log roots")
struct SuggestionLogRootsTests {
    private let home = URL(fileURLWithPath: "/tmp/fake-home", isDirectory: true)

    private func codex(_ id: String, path: String) -> CodexAccount {
        CodexAccount(id: id, kind: .managed, label: id, customName: nil, defaultName: id,
                     home: path, homePath: path, identity: nil, state: .signedIn, pids: [])
    }

    @Test("a found-only home is not a log root (audit B-10, D-6)")
    func aFoundHomeIsNotARoot() {
        // `codex.found` homes never reach `make` — only listed accounts do — and no root
        // exists for a home that is merely discovered.
        let roots = SuggestionLogRoots.make(home: home, claudeBindings: [],
                                            registeredClaudeIDs: [],
                                            codexAccounts: [codex("m-1", path: "/x/added")],
                                            usages: [])
        #expect(roots.contains { $0.provider == .codex && $0.accountRef == "m-1" })
        #expect(!roots.contains { $0.directory.path.contains("found-only") })
        #expect(roots.filter { $0.provider == .codex }.count == 2) // standard + m-1
    }

    @Test("an added codex home is a root")
    func anAddedHomeIsARoot() {
        let roots = SuggestionLogRoots.make(home: home, claudeBindings: [],
                                            registeredClaudeIDs: [],
                                            codexAccounts: [codex("m-2", path: "/x/added-two")],
                                            usages: [])
        let codexRoots = roots.filter { $0.provider == .codex }
        #expect(codexRoots.contains { $0.directory.path == "/x/added-two" })
    }
}
