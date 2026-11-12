import Foundation
import SwitcherCore
import Testing

@Suite("EnrollmentGuide")
struct EnrollmentGuideTests {
    private func account(id: String, uuid: String, org: String = "org") -> AccountStatus {
        AccountStatus(id: id, label: id, customName: nil, defaultName: id, email: nil,
                      accountUuid: uuid, orgUuid: org, isActive: false, snapshot: .ready,
                      capturedAt: nil, sessionExpiresAt: nil)
    }

    private func status(uuid: String?, org: String? = "org",
                        accounts: [AccountStatus] = []) -> SwitcherStatus {
        SwitcherStatus(claude: ClaudeStatus(installed: true, running: true, pid: 1,
                                            version: nil, activeAccountUuid: uuid,
                                            activeOrgUuid: uuid == nil ? nil : org,
                                            activeEmail: nil, codeSessions: 0),
                       accounts: accounts, relaunchers: [], suspendedRelaunchers: [],
                       originalBackup: nil, pendingJournal: false,
                       nativeMultiAccount: false, warnings: [])
    }

    @Test func signedOutIsWaiting() {
        let s = status(uuid: nil, accounts: [account(id: "a__org", uuid: "a")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .waiting)
    }

    @Test func uuidWithoutOrgIsWaiting() {
        let s = status(uuid: "a", org: nil, accounts: [account(id: "a__org", uuid: "a")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .waiting)
    }

    @Test func sameUuidAndOrgReturnsSameAccount() {
        let s = status(uuid: "a", accounts: [account(id: "a__org", uuid: "a")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .sameAccountReturned)
    }

    @Test func sameUuidDifferentOrgIsNewUnsaved() {
        // A same-name login in another org is a different account — never folds into the old row.
        let s = status(uuid: "a", org: "org2", accounts: [account(id: "a__org", uuid: "a", org: "org")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .newUnsaved)
    }

    @Test func differentSavedAccountIsKnown() {
        let s = status(uuid: "b", accounts: [account(id: "a__org", uuid: "a"),
                                             account(id: "b__org", uuid: "b")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .knownAccount("b__org"))
    }

    @Test func unknownLoginIsNewUnsaved() {
        let s = status(uuid: "z", accounts: [account(id: "a__org", uuid: "a")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: "a__org") == .newUnsaved)
    }

    @Test func nilPreviousStillDistinguishesKnownAndNew() {
        let s = status(uuid: "b", accounts: [account(id: "b__org", uuid: "b")])
        #expect(EnrollmentGuide.state(status: s, previousAccountID: nil) == .knownAccount("b__org"))
        let s2 = status(uuid: "z", accounts: [])
        #expect(EnrollmentGuide.state(status: s2, previousAccountID: nil) == .newUnsaved)
    }
}
