import Foundation

/// Whether a usage row names an account the user could actually act on.
/// A suggestion for an account whose sign-in can't be used isn't advice — it's noise.
/// The engine stays untouched; callers filter `usages` before they hand them over.
public enum SuggestionEligibility {
    /// Claude App accounts need a ready, unexpired snapshot — the current account is kept
    /// regardless (it's already in use; nothing to switch to). Codex accounts must not be
    /// signed out. Everything else passes: providers without an app-level account switch
    /// can't be suggested to something impossible.
    public static func usable(_ usage: AccountUsage,
                              claudeAccounts: [AccountStatus],
                              codexSignedOutIDs: Set<String>,
                              now: Date) -> Bool {
        switch usage.provider {
        case .claude where usage.accountRef.hasPrefix("app:"):
            let id = String(usage.accountRef.dropFirst("app:".count))
            guard let account = claudeAccounts.first(where: { $0.id == id }),
                  !account.isActive else { return true }
            let expired = account.sessionExpiresAt.map { $0 <= now } ?? false
            return account.snapshot == .ready && !expired
        case .codex:
            return !codexSignedOutIDs.contains(usage.accountRef)
        default:
            return true
        }
    }
}
