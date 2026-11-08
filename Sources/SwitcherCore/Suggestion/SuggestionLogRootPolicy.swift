import Foundation

public enum SuggestionLogRootPolicy {
    public static func includes(provider: UsageProvider, accountRef: String,
                                usages: [AccountUsage]) -> Bool {
        let latest = usages.filter { $0.provider == provider && $0.accountRef == accountRef }
            .max { $0.readAt < $1.readAt }
        switch provider {
        case .claude where accountRef.hasPrefix("app:"):
            return latest?.state == .ok
        case .codex:
            return latest?.state != .failed(.accountMismatch)
        default:
            return true
        }
    }
}
