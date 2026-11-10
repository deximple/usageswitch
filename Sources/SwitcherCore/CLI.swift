import Foundation

/// `<executable> --cli <command>`: JSON on stdout, progress on stderr. Never prints secrets.
public enum CLI {
    static var usage: String { L10n.t(.cliUsage) }

    /// The real entry point: default collaborators and the process's own stdout/stderr.
    public static func run(_ rawArgs: [String]) -> Int32 {
        var options = SwitcherOptions()
        options.allowFaultInjection = ProcessInfo.processInfo.environment["CDSW_ALLOW_FAULT_INJECTION"] == "1"
        return run(args: rawArgs, switcher: Switcher(options: options), codex: CodexManager(),
                   out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                   err: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    /// Testable core: inject the switcher, the codex manager and the output sinks (audit B-13).
    static func run(args rawArgs: [String], switcher: Switcher, codex: CodexManager,
                    out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) -> Int32 {
        // `--lang <code>` may appear anywhere, also before the command.
        let lang = value(after: "--lang", in: rawArgs)
        let args = removingOption("--lang", from: rawArgs)
        if let wait = value(after: "--veto-wait", in: args).flatMap(Double.init) {
            switcher.options.quitVetoWait = wait
        }
        // Language: --lang, else the saved setting, else the system language.
        let settings = SwitcherSettings.load(env: switcher.env)
        L10n.language = lang.flatMap(AppLanguage.matching) ?? settings.effectiveLanguage
        guard let command = args.first else { return fail("usage", usage, exit: 64, out: out) }
        let yes = args.contains("--yes")
        // status/list run pending-switch recovery; codex remove/reauth move folders and sign out.
        let signalSensitive = ["switch", "capture", "enroll", "recover", "remove", "status", "list"].contains(command)
            || (command == "codex" && args.count >= 2 && ["remove", "reauth"].contains(args[1]))
        if signalSensitive {
            // An interrupted session would skip the relauncher restore and could leave files mid-swap.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            signal(SIGHUP, SIG_IGN)
        }
        let progress: (SwitchStep) -> Void = { step in err("step: \(step.title)\n") }
        do {
            switch command {
            case "status", "list":
                switcher.recoverIfNeeded().forEach { err("note: \($0)\n") }
                return emit(switcher.status(), out: out)
            case "usage":
                // The app's last read, from its file — no vendor tool, Keychain or network here.
                guard let snapshot = UsageSnapshot.load(env: switcher.env) else {
                    return fail("no_usage", L10n.t(.cliUsageNoData), exit: 1, out: out)
                }
                return emit(snapshot, out: out)
            case "switch":
                guard args.count >= 2, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64, out: out) }
                let fault = value(after: "--inject-fault", in: args).flatMap(InjectedFault.init(rawValue:))
                return emit(try switcher.switchTo(args[1], confirmed: yes, force: args.contains("--force"), fault: fault, progress: progress), out: out)
            case "capture":
                let snap = try switcher.captureCurrent(confirmed: yes, progress: progress)
                return emit(snap.manifest, out: out)
            case "enroll":
                try switcher.beginEnrollment(confirmed: yes, progress: progress)
                return emit(["result": L10n.t(.cliEnrollStarted)], out: out)
            case "remove":
                guard args.count >= 2, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64, out: out) }
                let label = switcher.account(matching: args[1])?.label ?? args[1]
                guard yes else {
                    return fail("needs_confirmation", L10n.t(.uiRemoveSavedConfirm, label), exit: 3, out: out)
                }
                try switcher.removeSaved(args[1])
                return emit(["result": L10n.t(.uiRemoveSavedDone, label)], out: out)
            case "rename":
                // `rename <account> <name words…>` or `rename <account> --reset`; any other option is a mistake.
                guard args.count >= 3, !args[1].hasPrefix("--") else { return fail("usage", usage, exit: 64, out: out) }
                let words = Array(args[2...])
                let reset = words == ["--reset"]
                guard reset || !words.contains(where: { $0.hasPrefix("--") }) else { return fail("usage", usage, exit: 64, out: out) }
                let renamed = try switcher.renameAccount(args[1], to: reset ? nil : words.joined(separator: " "))
                return emit(["result": L10n.t(renamed.customName == nil ? .cliRenameReset : .cliRenamed, renamed.label),
                             "id": renamed.id, "label": renamed.label], out: out)
            case "language":
                guard args.count >= 2 else { return fail("usage", usage, exit: 64, out: out) }
                let choice: AppLanguage?
                if args[1] == "system" {
                    choice = nil
                } else if let lang = AppLanguage.matching(args[1]) {
                    choice = lang
                } else {
                    return fail("usage", usage, exit: 64, out: out)
                }
                try SwitcherSettings.update(env: switcher.env, fs: switcher.fs) { $0.language = choice }
                let updated = SwitcherSettings.load(env: switcher.env)
                L10n.language = updated.effectiveLanguage
                return emit(["result": L10n.t(.cliLanguageSet, updated.effectiveLanguage.nativeName),
                             "language": updated.language?.rawValue ?? "system"], out: out)
            case "probe-code":
                guard let active = switcher.activeIdentity() else {
                    throw SwitcherError.activeIdentityUnknown(L10n.t(.reasonNoSignInSignal))
                }
                let identity = AccountIdentity(accountUuid: active.account, orgUuid: active.org, email: nil, displayName: nil)
                let timeout = value(after: "--timeout", in: args).flatMap(Double.init) ?? 60
                let since = args.contains("--since-launch")
                    ? (switcher.processes.mainProcess()?.startTime ?? Date()) : Date.distantPast
                return emit(switcher.probeCodeSession(
                    expected: identity, since: since, trigger: args.contains("--trigger"), timeout: timeout), out: out)
            case "recover":
                if args.contains("--set-aside") {
                    guard args.contains("--yes") else {
                        return fail("needs_confirmation", L10n.t(.uiSetAsideJournalBody), exit: 3, out: out)
                    }
                    let result = try switcher.setAsidePendingJournal()
                    result.restoreNotes.forEach { err("note: \($0)\n") }
                    _ = emit(["setAside": result.destination.path], out: out)
                    return result.needsAttention ? 1 : 0
                }
                let report = switcher.recover()
                _ = emit(["notes": report.notes], out: out)
                return report.needsAttention ? 1 : 0
            case "codex":
                return try runCodex(Array(args.dropFirst()), codex: codex, out: out, err: err)
            default:
                return fail("usage", usage, exit: 64, out: out)
            }
        } catch let e as SwitcherError {
            if case .needsConfirmation = e { return fail(e.code, e.description, exit: 3, out: out) }
            if case .swapInterrupted = e { return fail(e.code, e.description, exit: 4, out: out) }
            if case .verificationFailed(_, let rollback) = e {
                // 1 = safe (previous account restored and confirmed), 2 = restored but unconfirmed, 4 = needs recovery.
                let code: Int32 = rollback == .verified ? 1 : rollback == .unverified ? 2 : 4
                return fail(e.code, e.description, exit: code, extra: ["rollback": rollback.rawValue], out: out)
            }
            return fail(e.code, e.description, exit: 1, out: out)
        } catch {
            return fail("unexpected", String(describing: error), exit: 1, out: out)
        }
    }

    /// `codex status|open|add|reauth|remove|rename|unhide`: the Codex tab from the command line.
    static func runCodex(_ args: [String], codex: CodexManager,
                         out: @escaping @Sendable (String) -> Void,
                         err: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let command = args.first else { return fail("usage", usage, exit: 64, out: out) }
        let target = args.count >= 2 && !args[1].hasPrefix("--") ? args[1] : nil
        switch command {
        case "status", "list":
            let status = codex.status().withoutPhantomDefault
            // An unreadable registry is an error, not an empty list (audit B-10).
            if status.registryUnreadable {
                return fail("registry_unreadable", "could not read codex-accounts.json", exit: 1, out: out)
            }
            return emit(status, out: out)
        case "open":
            guard let target else { return fail("usage", usage, exit: 64, out: out) }
            return emit(try codex.open(target), out: out)
        case "add", "reauth":
            if command == "reauth" && target == nil { return fail("usage", usage, exit: 64, out: out) }
            err(L10n.t(.codexSigningIn) + "\n")
            let stop = InterruptFlag()   // Ctrl-C cancels the browser sign-in
            let onLink: @Sendable (URL) -> Void = { link in
                err("\(L10n.t(.codexOpenLinkAgain)): \(link.absoluteString)\n")
            }
            defer { stop.restore() }
            if command == "reauth" { return emit(try codex.reauthenticate(target ?? "", shouldStop: { stop.isSet }, onLink: onLink), out: out) }
            let account = try codex.addAccount(shouldStop: { stop.isSet }, onLink: onLink)
            do {
                try codex.open(account.id)
            } catch let error as SwitcherError {
                // The account is kept; it can be opened later.
                FileHandle.standardError.write(Data("warning: \(error.description)\n".utf8))
            }
            return emit(account, out: out)
        case "adopt":
            guard let target else { return fail("usage", usage, exit: 64, out: out) }
            if !args.contains("--yes"), let same = try codex.listedAccount(sameAs: target) {
                // The folder may be a backup copy of a listed home: ask for --yes, like the app asks first.
                let message = L10n.t(.codexConfirmAdoptSame, Privacy.maskEmails(in: same.label))
                return fail("needs_confirmation", message, exit: 3, out: out)
            }
            return emit(try codex.adopt(target), out: out)
        case "remove":
            guard let target else { return fail("usage", usage, exit: 64, out: out) }
            guard args.contains("--yes") else {
                return fail("needs_confirmation", L10n.t(.codexConfirmRemove, target), exit: 3, out: out)
            }
            return emit(try codex.remove(target), out: out)
        case "rename":
            guard let target, args.count >= 3 else { return fail("usage", usage, exit: 64, out: out) }
            let words = Array(args[2...])
            let reset = words == ["--reset"]
            guard reset || !words.contains(where: { $0.hasPrefix("--") }) else { return fail("usage", usage, exit: 64, out: out) }
            return emit(try codex.renameAccount(target, to: reset ? nil : words.joined(separator: " ")), out: out)
        case "unhide":
            try codex.unhideAll()
            return emit(codex.status(), out: out)
        default:
            return fail("usage", usage, exit: 64, out: out)
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

    static func emit<T: Encodable>(_ value: T, out: @Sendable (String) -> Void) -> Int32 {
        guard let data = try? encoder.encode(Envelope(ok: true, result: value)) else {
            return fail("encode_failed", "could not encode the result as JSON", exit: 1, out: out)
        }
        out(String(decoding: data, as: UTF8.self) + "\n")
        return 0
    }

    struct Envelope<V: Encodable>: Encodable { let ok: Bool; let result: V }

    static func fail(_ code: String, _ message: String, exit: Int32, extra: [String: String] = [:],
                     out: @Sendable (String) -> Void) -> Int32 {
        struct Failure: Encodable { let ok = false; let error: [String: String] }
        let data = (try? encoder.encode(Failure(error: ["code": code, "message": message].merging(extra) { a, _ in a }))) ?? Data()
        out(String(decoding: data, as: UTF8.self) + "\n")
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
