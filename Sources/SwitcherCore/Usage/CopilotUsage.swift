import CryptoKit
import Foundation

/// GitHub Copilot usage adapter. The token comes out of `gh auth token` (gh's own
/// keychain lookup — the token never touches this app's credential readers or any
/// file we control); the quota read itself is a plain GET to the FIXED
/// api.github.com /copilot_internal/user endpoint through the hardened transport —
/// allowlist, 1 MiB cap, no redirects. `gh` is never used to make the API call.
/// Read-only: a token ask is free, the quota GET is a billing-metadata read, and
/// nothing here writes, signs in, or refreshes credentials.
public struct CopilotUsageCollector: Sendable {
    public static let rowID = "copilot:current"
    public static let rowAccountRef = "current"
    private static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let quotaScopes = ["chat", "completions", "premium_interactions"]

    private let enabled: Bool
    private let http: any UsageHTTPTransport
    private let runner: any UsageProcessRunner
    private let cli: URL?
    private let home: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    public init(enabled: Bool, http: any UsageHTTPTransport,
                runner: any UsageProcessRunner, cli: URL?,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = [:],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.enabled = enabled; self.http = http; self.runner = runner; self.cli = cli
        self.home = home; self.environment = environment; self.now = now
    }

    /// `gh auth token` prints the OAuth token gh already holds (keychain on macOS,
    /// hosts.yml elsewhere). One line, nothing else — anything more is treated as a
    /// schema change, never as a partial token.
    private func authToken() -> String? {
        guard let cli else { return nil }
        let result = runner.run(UsageProcessRequest(
            executable: cli,
            arguments: ["auth", "token"],
            environment: UsageChildEnvironment.make(for: cli, home: home),
            workingDirectory: home, stdinLines: nil,
            maxOutputBytes: 4096, timeout: 10))
        guard case .exited(0) = result.outcome, result.lines.count == 1,
              let token = UsageJSON.token(result.lines.first) else { return nil }
        return token
    }

    public func collect() -> [AccountUsage] {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = []) -> AccountUsage {
            AccountUsage(id: Self.rowID, provider: .copilot, accountRef: Self.rowAccountRef,
                         label: "GitHub Copilot", plan: nil, windows: windows,
                         state: state, readAt: now(), toolVersion: nil)
        }
        guard enabled else { return [] }
        guard cli != nil else { return [finish(.unavailable(.cliMissing))] }
        guard let token = authToken() else { return [finish(.unavailable(.noSignIn))] }

        let request = UsageHTTPRequest(url: Self.endpoint, method: .get,
            headers: ["Authorization": "token \(token)",
                      "Accept": "application/vnd.github+json",
                      "X-GitHub-Api-Version": "2022-11-28"],
            timeout: 10)
        guard let r = http.send(request) else { return [finish(.failed(.network))] }
        switch r.status {
        case 200: break
        case 401: return [finish(.failed(.signInRejected))]
        // Copilot not on this account/plan — a statement about eligibility, not a bad sign-in.
        case 403: return [finish(.unavailable(.notEligible))]
        case 429: return [finish(.failed(.rateLimited))]
        default: return [finish(.failed(.network))]
        }

        guard let root = UsageJSON.object(r.body) else {
            return [finish(.unavailable(.schemaChanged))]
        }
        return [read(root, finish: finish)]
    }

    private func read(_ root: [String: Any],
                      finish: (UsageState, [UsageWindow]) -> AccountUsage) -> AccountUsage {
        let reset = UsageJSON.resetDateISO(root["quota_reset_date_utc"])
        guard let snapshots = root["quota_snapshots"] as? [String: Any],
              !snapshots.isEmpty else {
            return finish(.unavailable(.schemaChanged), [])
        }
        var windows: [UsageWindow] = []
        for scope in Self.quotaScopes {
            guard let raw = snapshots[scope] else { continue }
            guard let w = raw as? [String: Any] else {
                return finish(.unavailable(.schemaChanged), [])
            }
            // Unlimited pools carry no percentage; pools without quota aren't windows.
            if (w["unlimited"] as? Bool) == true { continue }
            if (w["has_quota"] as? Bool) == false { continue }
            guard let remaining = UsageJSON.percent(w["percent_remaining"]) else {
                return finish(.unavailable(.schemaChanged), [])
            }
            windows.append(UsageWindow(scope: scope, durationMinutes: 43200,
                                       usedPercent: 100 - remaining, resetsAt: reset))
        }
        // Opaque login fingerprint — same treatment as Codex's identityKey: SHA256 of the
        // login, memory only, never persisted. Lets retention/pace tell two sign-ins apart.
        let identityKey = UsageJSON.string(root["login"]).map { login in
            SHA256.hash(data: Data("copilot|\(login.lowercased())".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        let plan = UsageJSON.string(root["copilot_plan"])
        if windows.isEmpty { return finish(.notReporting, []) }
        var row = finish(.ok, windows)
        return AccountUsage(id: row.id, provider: row.provider, accountRef: row.accountRef,
                            label: row.label, plan: plan, windows: windows, state: .ok,
                            readAt: row.readAt, toolVersion: nil,
                            authentication: .subscription, identityKey: identityKey)
    }
}
