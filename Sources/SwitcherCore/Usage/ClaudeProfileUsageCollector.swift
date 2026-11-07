import Darwin
import Foundation

public struct ClaudeProfileUsageCollector: Sendable {
    private struct ProfileIdentity: Equatable {
        let accountUuid: String
        let orgUuid: String
    }

    private struct AuthStatus: Equatable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
        let analyticsDisabled: Bool
        let projectsDirectory: String?
        let configDirectory: String?
        let email: String?
        let orgId: String?
        let orgName: String?
        let subscriptionType: String?
    }

    private enum AuthResult {
        case status(AuthStatus)
        case problem(UsageState)
    }

    private enum AuthValidation {
        case valid
        case problem(UsageState)
    }

    private enum IdentityResult {
        case identity(ProfileIdentity)
        case noSignIn
        case invalid
    }

    private let binding: ClaudeProfileBinding
    private let runner: any UsageProcessRunner
    private let home: URL
    private let managed: ClaudeManagedSettings
    private let binaryPaths: [URL]
    private let excludedRoots: [URL]
    private let now: @Sendable () -> Date

    public init(binding: ClaudeProfileBinding, runner: any UsageProcessRunner,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                managed: ClaudeManagedSettings = .system,
                binaryPaths: [URL]? = nil,
                excludedRoots: [URL],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.binding = binding
        self.runner = runner
        self.home = home
        self.managed = managed
        self.binaryPaths = binaryPaths ?? ClaudeUsageCollector.defaultBinaryPaths(home: home)
        self.excludedRoots = excludedRoots
        self.now = now
    }

    public func collect() -> AccountUsage {
        func finish(_ state: UsageState, _ windows: [UsageWindow] = [],
                    toolVersion: String? = nil) -> AccountUsage {
            AccountUsage(id: "claude:app:\(binding.accountId)", provider: .claude,
                         accountRef: "app:\(binding.accountId)", label: "Claude profile",
                         plan: nil, windows: windows, state: state, readAt: now(),
                         toolVersion: toolVersion, authentication: .unknown, identityKey: nil)
        }

        guard let binary = binaryPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return finish(.unavailable(.cliMissing)) }
        guard let toolVersion = ClaudeUsageCollector.toolVersion(of: binary)
        else { return finish(.unavailable(.unsupportedVersion)) }
        guard let profile = ClaudeProfileDirectory.validate(
            path: binding.profilePath, home: home, excludedRoots: excludedRoots),
              profile.path == binding.profilePath,
              let initialFileIdentity = ClaudeProfileDirectory.identity(at: profile)
        else { return finish(.unavailable(.profileInvalid), toolVersion: toolVersion) }
        guard !managed.shuts(claudeFolder: profile)
        else { return finish(.unavailable(.managed), toolVersion: toolVersion) }

        let identityA: ProfileIdentity
        switch Self.readIdentity(profile: profile) {
        case .identity(let value): identityA = value
        case .noSignIn: return finish(.unavailable(.noSignIn), toolVersion: toolVersion)
        case .invalid: return finish(.failed(.schemaChanged), toolVersion: toolVersion)
        }
        guard identityA.accountUuid == binding.accountUuid && identityA.orgUuid == binding.orgUuid
        else { return finish(.failed(.accountMismatch), toolVersion: toolVersion) }

        var environment = ClaudeUsageCollector.environment()
        environment["CLAUDE_CONFIG_DIR"] = profile.path
        let authA: AuthStatus
        switch Self.authStatus(runner: runner, binary: binary, environment: environment) {
        case .status(let status): authA = status
        case .problem(let state): return finish(state, toolVersion: toolVersion)
        }
        switch Self.validate(auth: authA, binding: binding, profile: profile) {
        case .valid: break
        case .problem(let state): return finish(state, toolVersion: toolVersion)
        }

        let parsed = ClaudeUsageCollector.readUsage(runner: runner, binary: binary,
            environment: environment, timeout: 60, now: now)

        guard ClaudeProfileDirectory.validate(path: binding.profilePath, home: home,
                                             excludedRoots: excludedRoots) == profile,
              ClaudeProfileDirectory.identity(at: profile) == initialFileIdentity
        else { return finish(.failed(.accountMismatch), toolVersion: toolVersion) }
        guard case .identity(let identityB) = Self.readIdentity(profile: profile),
              identityB == identityA, identityB.accountUuid == binding.accountUuid,
              identityB.orgUuid == binding.orgUuid
        else { return finish(.failed(.accountMismatch), toolVersion: toolVersion) }
        let authB: AuthStatus
        switch Self.authStatus(runner: runner, binary: binary, environment: environment) {
        case .status(let status): authB = status
        case .problem(let state): return finish(state, toolVersion: toolVersion)
        }
        guard case .valid = Self.validate(auth: authB, binding: binding, profile: profile),
              authB == authA
        else { return finish(.failed(.accountMismatch), toolVersion: toolVersion) }

        return finish(parsed.state, parsed.windows, toolVersion: toolVersion)
    }

    private static func validate(auth: AuthStatus, binding: ClaudeProfileBinding,
                                 profile: URL) -> AuthValidation {
        guard auth.loggedIn else { return .problem(.unavailable(.noSignIn)) }
        guard auth.orgId == binding.orgUuid else { return .problem(.failed(.accountMismatch)) }
        guard let configDirectory = auth.configDirectory,
              ClaudeProfileDirectory.realpathValue(configDirectory) == profile.path
        else { return .problem(.unavailable(.profileInvalid)) }
        return .valid
    }

    private static func readIdentity(profile: URL) -> IdentityResult {
        let path = profile.appendingPathComponent(".claude.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return .invalid }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size >= 0, attributes.st_size <= 4 * 1_048_576
        else { return .invalid }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { return .invalid }
            if count == 0 { break }
            guard data.count <= 4 * 1_048_576 - count else { return .invalid }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .invalid }
        guard let account = object["oauthAccount"] as? [String: Any] else { return .noSignIn }
        guard let accountUuid = account["accountUuid"] as? String,
              let orgUuid = account["organizationUuid"] as? String,
              !accountUuid.isEmpty, !orgUuid.isEmpty
        else { return .invalid }
        return .identity(ProfileIdentity(accountUuid: accountUuid, orgUuid: orgUuid))
    }

    private static func authStatus(runner: any UsageProcessRunner, binary: URL,
                                   environment: [String: String]) -> AuthResult {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageswitch-claude-auth-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: workDir,
                withIntermediateDirectories: true)) != nil
        else { return .problem(.unavailable(.refused)) }
        defer { try? FileManager.default.removeItem(at: workDir) }
        let result = runner.run(UsageProcessRequest(executable: binary,
            arguments: ["auth", "status", "--json"], environment: environment,
            workingDirectory: workDir, timeout: 20))
        switch result.outcome {
        case .timedOut: return .problem(.failed(.timeout))
        case .failedToStart: return .problem(.unavailable(.cliMissing))
        case .outputLimit: return .problem(.unavailable(.refused))
        case .stopped, .exited: break
        }
        guard let value = try? JSONSerialization.jsonObject(
            with: Data(result.lines.joined(separator: "\n").utf8)) as? [String: Any],
              let status = parseAuthStatus(value)
        else { return .problem(.failed(.schemaChanged)) }
        return .status(status)
    }

    private static func parseAuthStatus(_ value: [String: Any]) -> AuthStatus? {
        func optionalString(_ key: String) -> String? {
            guard let value = value[key] else { return nil }
            if value is NSNull { return nil }
            return value as? String
        }
        func hasValidOptionalString(_ key: String) -> Bool {
            guard let value = value[key] else { return false }
            return value is NSNull || value is String
        }
        guard let loggedIn = value["loggedIn"] as? Bool,
              ["authMethod", "apiProvider", "projectsDirectory", "configDirectory",
               "email", "orgId", "orgName", "subscriptionType"].allSatisfy(hasValidOptionalString),
              let analyticsDisabled = value["analyticsDisabled"] as? Bool
        else { return nil }
        return AuthStatus(loggedIn: loggedIn,
            authMethod: optionalString("authMethod"), apiProvider: optionalString("apiProvider"),
            analyticsDisabled: analyticsDisabled,
            projectsDirectory: optionalString("projectsDirectory"),
            configDirectory: optionalString("configDirectory"), email: optionalString("email"),
            orgId: optionalString("orgId"), orgName: optionalString("orgName"),
            subscriptionType: optionalString("subscriptionType"))
    }
}
