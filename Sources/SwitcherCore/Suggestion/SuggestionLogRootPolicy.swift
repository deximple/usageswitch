import Foundation

public enum SuggestionLogRootPolicy {
    public static func includes(provider: UsageProvider, accountRef: String,
                                usages: [AccountUsage]) -> Bool {
        guard let latest = usages.filter({ $0.provider == provider && $0.accountRef == accountRef })
            .max(by: { $0.readAt < $1.readAt }) else { return true }
        return latest.state != .failed(.accountMismatch)
    }
}
