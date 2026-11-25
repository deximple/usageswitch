import Foundation
import Testing
@testable import SwitcherCore

/// 2.5.1 switch-engine fixes: the settle wait is measured on the monotonic clock (audit A-2), and a
/// verified switch whose commit cleanup failed still restores Claude's relaunchers (audit A-4).
@Suite("Switcher settle clock and relaunchers after a failed commit")
struct SwitcherSettleClockTests {
    /// After the relaunch: the wall clock moves by `jump` at +3 s (the init line is logged at +2 s),
    /// and Claude logs a failure at +10 s — well inside the 20 s settle.
    static func armClockJump(_ rig: Rig, jump: TimeInterval, failureAt: TimeInterval? = 10) {
        let env = rig.env
        rig.world.update {
            $0.afterLaunch = { s in
                FakeWorld.schedule(&s, at: s.now.addingTimeInterval(3)) { st, _ in st.wallClockOffset += jump }
                if let failureAt {
                    FakeWorld.schedule(&s, at: s.now.addingTimeInterval(failureAt)) { st, t in
                        FakeWorld.appendLog(&st, env: env, at: t, "[auth] names a different account")
                    }
                }
            }
        }
    }

    @Test("a wall clock that jumps forward does not cut the settle short (audit A-2)")
    func forwardJumpKeepsTheSettle() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        Self.armClockJump(rig, jump: 3600)
        let err = switcherError { _ = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true) }
        guard case .verificationFailed(let reason, _) = err else {
            Issue.record("expected verificationFailed, got \(String(describing: err))"); return
        }
        #expect(reason == L10n.t(.reasonLogPattern, "names a different account"))
    }

    @Test("a wall clock that jumps back does not stretch the settle (audit A-2)")
    func backwardJumpKeepsTheBound() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        Self.armClockJump(rig, jump: -3600, failureAt: nil)
        let started = rig.world.uptime()
        let result = try rig.switcher.switchTo(FakeIdentity.b.key, confirmed: true)
        #expect(result.outcome == "switched")
        let options = rig.switcher.options
        // Quit, relaunch, init at +2 s and a 20 s settle: nowhere near the hour the wall clock lost.
        #expect(rig.world.uptime() - started < options.launchVerifyTimeout + options.settle + 30)
    }

    @Test("a verified switch whose commit fails still restores the relaunchers (audit A-4)")
    func failedCommitRestoresRelaunchers() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        let snap = try #require(rig.switcher.store.latest(for: FakeIdentity.b.identity))
        // keepPreviousAt under a path whose parent is a regular file: the move inside commit fails.
        let blocker = rig.env.displacedDir.appendingPathComponent("blocked")
        try rig.sandbox.write("x", to: blocker)
        var warnings: [String] = []
        try rig.switcher.withExclusiveSession(confirmed: true, progress: { _ in }) { _ in
            #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
            try rig.switcher.stageAndInstall(cookiesFrom: snap.dir, manifest: snap.manifest,
                                             mutation: .restore(accountUuid: FakeIdentity.b.account),
                                             stripAuthRows: false, keepPreviousAt: blocker.appendingPathComponent("keep"))
            try rig.switcher.launchAndVerify(target: FakeIdentity.b.identity, previous: FakeIdentity.a.identity,
                                             fault: nil, keepPreviousAt: blocker.appendingPathComponent("keep"),
                                             warnings: &warnings, progress: { _ in })
        }
        #expect(warnings.count == 1)
        // The journal stays for a later retry, but the live files are the verified account's whole set.
        #expect(rig.switcher.swapper.pendingJournal()?.state == "installed")
        #expect(rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().isEmpty)
    }

    @Test("a journal left mid-swap still keeps the relaunchers suspended")
    func partialJournalKeepsRelaunchersSuspended() throws {
        let rig = try Rig.make(); defer { rig.cleanup() }
        try rig.switcher.withExclusiveSession(confirmed: true, progress: { _ in }) { _ in
            // A journal that never reached "installed": the files may be mixed.
            let journal = SwapEngine.Journal(state: "installing", applied: [])
            try rig.switcher.fs.write(try JSONEncoder().encode(journal), to: rig.env.journalFile)
        }
        #expect(!rig.world.isAgentLoaded(AgentFixture.keepaliveLabel))
        #expect(rig.switcher.relaunchers.journal().map(\.label) == [AgentFixture.keepaliveLabel])
    }
}
