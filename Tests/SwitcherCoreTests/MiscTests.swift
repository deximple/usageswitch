import Foundation
import Testing
@testable import SwitcherCore

@Suite("Errors, steps and small types")
struct MiscTests {
    static let allErrors: [SwitcherError] = [
        .forbiddenWrite("/p"), .unknownAccount("x"), .notEnrolled(label: "L"),
        .snapshotCorrupt("r"), .snapshotIncompatible("r"), .needsConfirmation(codeSessions: 2), .anotherSwitchInProgress,
        .insufficientDisk(freeGB: 1, requiredGB: 8), .updateInProgress, .updatePending, .cannotSaveCurrentLogin,
        .claudeNotInstalled, .quitVetoed(waitedSeconds: 3),
        .quitTimeout(waitedSeconds: 4), .claudeStartedDuringSwap, .swapFailed("r"), .verificationFailed("r", rollback: .verified),
        .verificationFailed("r", rollback: .unverified), .verificationFailed("r", rollback: .failed), .activeIdentityUnknown("r"),
        .enrollmentIdentityMismatch(expected: "e", got: "g"), .io("r"), .sqlite("r"), .launchFailed("r"),
        .cannotRemoveActive, .legacyRecoveryPending, .invalidAccountName(maxLength: 40), .duplicateAccountName("N"),
    ]

    @Test func everyErrorHasMessageAndStableCode() throws {
        let codes = Self.allErrors.map(\.code)
        #expect(Set(codes).count == 26) // one code per case (verificationFailed appears three times above)
        for e in Self.allErrors {
            #expect(!e.description.isEmpty)
            #expect(e.code.allSatisfy { $0.isLowercase || $0 == "_" })
        }
        #expect(SwitcherError.needsConfirmation(codeSessions: 2).description.contains("2"))
        #expect(SwitcherError.insufficientDisk(freeGB: 1, requiredGB: 8).description == L10n.t(.errInsufficientDisk, 1, 8))
        // Each rollback outcome is reported differently; the code stays the same.
        let outcomes: [RollbackOutcome] = [.verified, .unverified, .failed]
        let rollbackMessages = outcomes.map { SwitcherError.verificationFailed("r", rollback: $0).description }
        #expect(Set(rollbackMessages).count == 3)
        #expect(outcomes.allSatisfy { SwitcherError.verificationFailed("r", rollback: $0).code == "verification_failed" })
        #expect(outcomes.map(\.rawValue) == ["verified", "unverified", "failed"])
        #expect(try JSONDecoder().decode(RollbackOutcome.self, from: JSONEncoder().encode(RollbackOutcome.failed)) == .failed)
        #expect(SwitcherError.quitVetoed(waitedSeconds: 3).code == "quit_vetoed")
        #expect(SwitcherError.invalidAccountName(maxLength: 40).code == "invalid_name")
        #expect(SwitcherError.invalidAccountName(maxLength: 40).description.contains("40"))
        #expect(SwitcherError.duplicateAccountName("N").code == "duplicate_name")
        #expect(SwitcherError.updatePending.code == "update_pending")
        #expect(SwitcherError.cannotSaveCurrentLogin.code == "cannot_save_current_login")
        // Both refusals promise that nothing was changed / the sign-in is kept.
        #expect(SwitcherError.updatePending.description == L10n.t(.errUpdatePending))
        #expect(L10n.string(.errUpdatePending, language: .ko).contains("아무것도 바뀌지 않았습니다"))
        #expect(L10n.string(.errUpdatePending, language: .en).contains("Nothing was changed"))
        #expect(SwitcherError.cannotSaveCurrentLogin.description == L10n.t(.errCannotSaveCurrentLogin))
        #expect(L10n.string(.errCannotSaveCurrentLogin, language: .ko).contains("그대로"))
        #expect(L10n.string(.errCannotSaveCurrentLogin, language: .en).contains("unchanged"))
    }

    @Test func everyStepHasATitle() {
        let steps: [SwitchStep] = [
            .preflight, .suspendingRelaunchers, .quittingClaude, .waitingForClaudeDialog(seconds: 12),
            .capturingOutgoing, .backingUp, .swapping, .launching, .verifying, .rollingBack, .restoringRelaunchers, .done,
        ]
        let titles = steps.map(\.title)
        #expect(Set(titles).count == steps.count)
        #expect(SwitchStep.waitingForClaudeDialog(seconds: 12).title.contains("12"))
    }

    @Test func optionsDefaultsMatchDesign() {
        let o = SwitcherOptions()
        #expect(o.minFreeDiskGB == 8)
        #expect(o.shipItQuietWindow == 3)
        #expect(o.quitVetoWait == 600)
        #expect(o.settle == 20)
        #expect(!o.allowFaultInjection && !o.allowUIGroup)
        #expect(InjectedFault(rawValue: "post-swap-verify") == .postSwapVerify)
        #expect(InjectedFault(rawValue: "other") == nil)
    }

    @Test func accountTypesRoundTrip() throws {
        let account = SwitcherAccount(identity: FakeIdentity.a.identity, customName: "Work")
        let decoded = try JSONDecoder().decode(SwitcherAccount.self, from: JSONEncoder().encode(account))
        #expect(decoded == account)
        #expect(account.id == FakeIdentity.a.key && account.label == "Work")
        #expect(FakeIdentity.a.identity.key.count == 74)
    }

    @Test func defaultNamesFallBackFromEmailToDisplayNameToIdPrefix() {
        let a = FakeIdentity.a
        #expect(SwitcherAccount(identity: a.identity).label == a.email)
        let noEmail = AccountIdentity(accountUuid: a.account, orgUuid: a.org, email: nil, displayName: "Fake Twenty")
        #expect(SwitcherAccount(identity: noEmail).label == "Fake Twenty")
        let bare = AccountIdentity(accountUuid: a.account, orgUuid: a.org, email: nil, displayName: nil)
        #expect(SwitcherAccount(identity: bare).label == String(a.account.prefix(8)))
        #expect(SwitcherAccount(identity: bare, customName: "Mine").label == "Mine")
    }

    @Test func switchResultCarriesTheDisplacedPreviousPath() throws {
        var result = SwitchResult(outcome: "switched", from: FakeIdentity.a.identity, to: FakeIdentity.b.identity,
                                  recapturedOutgoing: false, durationSeconds: 1)
        #expect(result.displacedPrevious == nil)
        result.displacedPrevious = "/fake/displaced/x"
        let decoded = try JSONDecoder().decode(SwitchResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(decoded.displacedPrevious == "/fake/displaced/x")
    }

    @Test func errorBoxStoresLastError() {
        let box = ErrorBox()
        #expect(box.get() == nil)
        box.set(SwitcherError.io("x"))
        #expect(box.get() as? SwitcherError == .io("x"))
        box.set(nil)
        #expect(box.get() == nil)
    }

    @Test func rigRemovesItsSandboxWhenAFixtureStepThrows() throws {
        var root: URL?
        do {
            _ = try Rig.make(afterSetup: { rig in
                root = rig.sandbox.root
                #expect(exists(rig.env.claudeCookies)) // the world was fully built before the failing step
                throw SwitcherError.io("fixture step failed")
            })
            Issue.record("expected the fixture to throw")
        } catch {
            #expect(error as? SwitcherError == .io("fixture step failed"))
        }
        #expect(!exists(try #require(root)))
    }

    @Test func systemClockIsMonotonicEnough() {
        let clock = SystemClock()
        let a = clock.now()
        clock.sleep(0)
        #expect(clock.now() >= a)
    }

    @Test func appsAreFoundInApplicationsThenInTheUsersApplications() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let system = sb.root.appendingPathComponent("system", isDirectory: true)
        let user = sb.root.appendingPathComponent("user", isDirectory: true)
        let folders = [system, user]
        #expect(SwitcherEnvironment.installedApp(named: "Codex.app", in: folders) == nil)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Codex.app"), withIntermediateDirectories: true)
        #expect(SwitcherEnvironment.installedApp(named: "Codex.app", in: folders)?.path == user.appendingPathComponent("Codex.app").path)
        try FileManager.default.createDirectory(at: system.appendingPathComponent("Codex.app"), withIntermediateDirectories: true)
        #expect(SwitcherEnvironment.installedApp(named: "Codex.app", in: folders)?.path == system.appendingPathComponent("Codex.app").path)
    }

    @Test func releasesPageIsAnHTTPSAddress() {
        #expect(ProductInfo.releasesURL.scheme == "https")
        #expect(ProductInfo.releasesURL.host == "github.com")
    }
}
