import Foundation

/// The limits already warned about, kept across restarts so signing in to the Mac does not repeat
/// every warning. Keys are the opaque pinned-row keys (`codex:m-1a2b3c4d/weekly/`): no label, no email.
public struct UsageAlertState: Codable, Equatable, Sendable {
    public var threshold: Double
    public var keys: Set<String>

    public init(threshold: Double, keys: Set<String>) {
        self.threshold = threshold
        self.keys = keys
    }

    /// The remembered keys, or none when the warning level has changed since they were recorded.
    public func keys(for threshold: Double) -> Set<String> {
        self.threshold == threshold ? keys : []
    }

    private enum CodingKeys: String, CodingKey { case threshold, keys }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try container.decode(Double.self, forKey: .threshold)
        keys = Set(try container.decode([String].self, forKey: .keys))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threshold, forKey: .threshold)
        try container.encode(keys.sorted(), forKey: .keys)
    }
}

public struct UsageAlertStore: Sendable {
    static let maximumBytes = 262_144
    private let env: SwitcherEnvironment
    private let fs: SafeFS

    public init(env: SwitcherEnvironment, fs: SafeFS) {
        self.env = env
        self.fs = fs
    }

    /// nil when there is no file or it cannot be read: warnings then start from nothing.
    public func load() -> UsageAlertState? {
        guard let data = BoundedReader.readBounded(env.usageAlertsFile.path, limit: Self.maximumBytes, allowBinary: true)
        else { return nil }
        return try? JSONDecoder().decode(UsageAlertState.self, from: data)
    }

    public func save(_ state: UsageAlertState) throws {
        try fs.createDirectory(env.storeDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try fs.write(try encoder.encode(state), to: env.usageAlertsFile)
    }
}
