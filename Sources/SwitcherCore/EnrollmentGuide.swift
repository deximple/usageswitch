import Foundation

/// What a live sign-in means while an enrollment is pending (`beginEnrollment`
/// already saved the previous account and left Claude at its login screen).
/// Pure decision — the app decides which surface each state lands on.
public enum EnrollmentGuide {
    public enum State: Equatable, Sendable {
        /// Still no live sign-in — Claude is on its login screen (or the
        /// sign-in hasn't propagated yet).
        case waiting
        /// The user signed back into the same account that was signed out.
        case sameAccountReturned
        /// Signed into a different, already-saved account — carries its id.
        case knownAccount(String)
        /// Signed into an account that isn't saved yet — needs an explicit
        /// save; nothing is written on detection alone.
        case newUnsaved
    }

    public static func state(status: SwitcherStatus, previousAccountID: String?) -> State {
        guard let uuid = status.claude.activeAccountUuid,
              let org = status.claude.activeOrgUuid else { return .waiting }
        guard let active = status.accounts.first(where: {
            $0.accountUuid == uuid && $0.orgUuid == org
        }) else { return .newUnsaved }
        return active.id == previousAccountID ? .sameAccountReturned : .knownAccount(active.id)
    }
}
