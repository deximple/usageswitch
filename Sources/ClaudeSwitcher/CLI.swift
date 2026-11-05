import Foundation
import SwitcherCore

/// `<executable> --cli <command>`: JSON on stdout, progress on stderr. Never prints secrets.
enum CLI {
    static var usage: String { L10n.t(.cliUsage) }

    static func run(_ rawArgs: [String]) -> Int32 {
        // `--lang <code>` may appear anywhere, also before the command.
        let lang = value(after: "--lang", in: rawArgs)
        let args = removingOption("--lang", from: rawArgs)
        var options = SwitcherOptions()
        options.allowFaultInjection = ProcessInfo.processInfo.environment["CDSW_ALLOW_FAULT_INJECTION"] == "1"
        if let wait = value(after: "--veto-wait", in: args).flatMap(Double.init) { options.quitVetoWait = wait }
        let switcher = Switcher(options: options)
        // Language: --lang, else the saved setting, else the system language.
        let settings = SwitcherSettings.load(env: switcher.env)
        L10n.language = lang.flatMap(AppLanguage.matching) ?? settings.effectiveLanguage
        guard let command = args.first else { return fail("usage", usage, exit: 64) }
        let yes = args.contains("--yes")
        if ["switch", "capture", "enroll", "recover", "remove"].contains(command) {
            // An interrupted session would skip the relauncher restore and could leave files mid-swap.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            signal(SIGHUP, SIG_IGN)
        }
        let progress: (SwitchStep) -> Void = { step in
            FileHandle.standardError.write(Data("step: \(step.title)\n".utf8))
        }
        do {
            switch command {
            case "status", "list":
                switcher.recoverIfNeeded().forEach { FileHandle.standardError.write(Data("note: \($0)\n".utf8)) }
                return emit(switcher.status())
            case "usage":
                // The app's last read, from its file — no vendor tool, Keychain or network here.
                guard let snapshot = UsageSnapshot.load(env: switcher.env) else {
                    return fail("no_usage", L10n.t(.cliUsageNoData), exit: 1)
                }
                return emit(snapshot)
            case "switch":
                guard args.count >= 2, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64) }
                let fault = value(after: "--inject-fault", in: args).flatMap(InjectedFault.init(rawValue:))
                return emit(try switcher.switchTo(args[1], confirmed: yes, force: args.contains("--force"), fault: fault, progress: progress))
            case "capture":
                let snap = try switcher.captureCurrent(confirmed: yes, progress: progress)
                return emit(snap.manifest)
            case "enroll":
                try switcher.beginEnrollment(confirmed: yes, progress: progress)
                return emit(["result": L10n.t(.cliEnrollStarted)])
            case "remove":
                guard args.count >= 2, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64) }
                let label = switcher.account(matching: args[1])?.label ?? args[1]
                try switcher.removeSaved(args[1])
                return emit(["result": L10n.t(.uiRemoveSavedDone, label)])
            case "rename":
                // `rename <account> <name words…>` or `rename <account> --reset`; any other option is a mistake.
                guard args.count >= 3, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64) }
                let words = Array(args[2...])
                let reset = words == ["--reset"]
                guard reset || !words.contains(where: { $0.hasPrefix("--") }) else { return fail("usage", usage, exit: 64) }
                let renamed = try switcher.renameAccount(args[1], to: reset ? nil : words.joined(separator: " "))
                return emit(["result": L10n.t(renamed.customName == nil ? .cliRenameReset : .cliRenamed, renamed.label),
                             "id": renamed.id, "label": renamed.label])
            case "language":
                guard args.count >= 2 else { return fail("usage", usage, exit: 64) }
                let choice: AppLanguage?
                if args[1] == "system" {
                    choice = nil
                } else if let lang = AppLanguage.matching(args[1]) {
                    choice = lang
                } else {
                    return fail("usage", usage, exit: 64)
                }
                try SwitcherSettings.update(env: switcher.env, fs: switcher.fs) { $0.language = choice }
                let updated = SwitcherSettings.load(env: switcher.env)
                L10n.language = updated.effectiveLanguage
                return emit(["result": L10n.t(.cliLanguageSet, updated.effectiveLanguage.nativeName),
                             "language": updated.language?.rawValue ?? "system"])
            case "probe-code":
                guard let active = switcher.activeIdentity() else {
                    throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonNoSignInSignal))
                }
                let identity = AccountIdentity(accountUuid: active.account, orgUuid: active.org, email: nil, displayName: nil)
                let timeout = value(after: "--timeout", in: args).flatMap(Double.init) ?? 60
                let since = args.contains("--since-launch")
                    ? (switcher.processes.mainProcess()?.startTime ?? Date()) : Date.distantPast
                return emit(switcher.probeCodeSession(
                    expected: identity, since: since, trigger: args.contains("--trigger"), timeout: timeout))
            case "recover":
                let report = switcher.recover()
                _ = emit(["notes": report.notes])
                return report.needsAttention ? 1 : 0
            case "codex":
                return try runCodex(Array(args.dropFirst()))
            default:
                return fail("usage", usage, exit: 64)
            }
        } catch let e as SwitcherError {
            if case .needsConfirmation = e { return fail(e.code, e.description, exit: 3) }
            if case .swapInterrupted = e { return fail(e.code, e.description, exit: 4) }
            if case .verificationFailed(_, let rollback) = e {
                // 1 = safe (previous account restored and confirmed), 2 = restored but unconfirmed, 4 = needs recovery.
                let code: Int32 = rollback == .verified ? 1 : rollback == .unverified ? 2 : 4
                return fail(e.code, e.description, exit: code, extra: ["rollback": rollback.rawValue])
            }
            return fail(e.code, e.description, exit: 1)
        } catch {
            return fail("unexpected", String(describing: error), exit: 1)
        }
    }

    /// `codex status|open|add|reauth|remove|rename|unhide`: the Codex tab from the command line.
    static func runCodex(_ args: [String]) throws -> Int32 {
        let codex = CodexManager()
        guard let command = args.first else { return fail("usage", usage, exit: 64) }
        let target = args.count >= 2 && !args[1].hasPrefix("--") ? args[1] : nil
        switch command {
        case "status", "list":
            return emit(codex.status())
        case "open":
            guard let target else { return fail("usage", usage, exit: 64) }
            return emit(try codex.open(target))
        case "add", "reauth":
            if command == "reauth" && target == nil { return fail("usage", usage, exit: 64) }
            FileHandle.standardError.write(Data((L10n.t(.codexSigningIn) + "\n").utf8))
            let stop = InterruptFlag()   // Ctrl-C cancels the browser sign-in
            let onLink: @Sendable (URL) -> Void = { link in
                FileHandle.standardError.write(Data("\(L10n.t(.codexOpenLinkAgain)): \(link.absoluteString)\n".utf8))
            }
            defer { stop.restore() }
            if command == "reauth" { return emit(try codex.reauthenticate(target ?? "", shouldStop: { stop.isSet }, onLink: onLink)) }
            let account = try codex.addAccount(shouldStop: { stop.isSet }, onLink: onLink)
            do {
                try codex.open(account.id)
            } catch let error as SwitcherError {
                // The account is kept; it can be opened later.
                FileHandle.standardError.write(Data("warning: \(error.description)\n".utf8))
            }
            return emit(account)
        case "adopt":
            guard let target else { return fail("usage", usage, exit: 64) }
            if !args.contains("--yes"), let same = try codex.listedAccount(sameAs: target) {
                // The folder may be a backup copy of a listed home: ask for --yes, like the app asks first.
                let message = L10n.t(.codexConfirmAdoptSame, SwitcherModel.displayName(same.label))
                return fail("needs_confirmation", message, exit: 3)
            }
            return emit(try codex.adopt(target))
        case "remove":
            guard let target else { return fail("usage", usage, exit: 64) }
            return emit(try codex.remove(target))
        case "rename":
            guard let target, args.count >= 3 else { return fail("usage", usage, exit: 64) }
            let words = Array(args[2...])
            let reset = words == ["--reset"]
            guard reset || !words.contains(where: { $0.hasPrefix("--") }) else { return fail("usage", usage, exit: 64) }
            return emit(try codex.renameAccount(target, to: reset ? nil : words.joined(separator: " ")))
        case "unhide":
            try codex.unhideAll()
            return emit(codex.status())
        default:
            return fail("usage", usage, exit: 64)
        }
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func removingOption(_ flag: String, from args: [String]) -> [String] {
        guard let i = args.firstIndex(of: flag) else { return args }
        return Array(args[..<i]) + Array(args[min(i + 2, args.count)...])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func emit<T: Encodable>(_ value: T) -> Int32 {
        let data = (try? encoder.encode(Envelope(ok: true, result: value))) ?? Data("{\"ok\":true}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return 0
    }

    struct Envelope<V: Encodable>: Encodable { let ok: Bool; let result: V }

    static func fail(_ code: String, _ message: String, exit: Int32, extra: [String: String] = [:]) -> Int32 {
        struct Failure: Encodable { let ok = false; let error: [String: String] }
        let data = (try? encoder.encode(Failure(error: ["code": code, "message": message].merging(extra) { a, _ in a }))) ?? Data()
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return exit
    }
}

/// Set by Ctrl-C, SIGTERM or SIGHUP instead of ending the process, so a running sign-in (and its `codex login`)
/// stops cleanly; `restore` puts the default handling back afterwards.
final class InterruptFlag: @unchecked Sendable {
    static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private let lock = NSLock()
    private var set = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for number in Self.signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.raise() }
            source.resume()
            sources.append(source)
        }
    }

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }

    func restore() {
        sources.forEach { $0.cancel() }
        sources = []
        Self.signals.forEach { signal($0, SIG_DFL) }
    }

    private func raise() { lock.lock(); set = true; lock.unlock() }
}
