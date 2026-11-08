import Foundation

public enum SuggestionLogRootPolicy {
    public static func includes(provider: UsageProvider, accountRef: String,
                                usages: [AccountUsage]) -> Bool {
        usages.filter { $0.provider == provider && $0.accountRef == accountRef }
            .max { $0.readAt < $1.readAt }?.state == .ok
    }
}
