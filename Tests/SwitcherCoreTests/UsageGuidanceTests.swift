import Foundation
import Testing
@testable import SwitcherCore

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func window(_ minutes: Int?, used: Double, scope: String? = nil,
                    resetsAt: Date? = nil) -> UsageWindow {
    UsageWindow(scope: scope, durationMinutes: minutes, usedPercent: used, resetsAt: resetsAt)
}

private func usage(_ windows: [UsageWindow], id: String = "codex:a",
                   provider: UsageProvider = .codex, state: UsageState = .ok,
                   auth: UsageAuthentication = .subscription,
                   plan: String? = nil, identityKey: String? = nil,
                   readAt: Date = epoch) -> AccountUsage {
    AccountUsage(id: id, provider: provider, accountRef: String(id.split(separator: ":").last ?? "a"),
                 label: "Account \(id)", plan: plan, windows: windows, state: state,
                 readAt: readAt, toolVersion: nil, authentication: auth, identityKey: identityKey)
}

@Suite("Usage pace")
struct UsagePaceTests {
    /// A fully matching context: same login, same reset in the future, same window length.
    private func reset(_ from: Date) -> Date { from.addingTimeInterval(3 * 86400) }
    private func prev(_ at: Date, _ used: Double, id: String? = "id1",
                      reset: Date? = nil, duration: Int? = 300) -> UsagePace.Sample {
        UsagePace.Sample(at: at, usedPercent: used, identityKey: id,
                         resetsAt: reset ?? epoch.addingTimeInterval(3 * 86400), durationMinutes: duration)
    }
    private func fresh(_ at: Date, _ used: Double, reset: Date? = nil,
                       duration: Int? = 300) -> UsageWindow {
        window(duration, used: used, resetsAt: reset ?? self.reset(at))
    }

    @Test("no sample or a sub-minute gap is unknown")
    func unknown() {
        #expect(UsagePace.reading(fresh(epoch, 50), previous: nil, now: epoch, identityKey: "id1") == .unknown)
        let recent = prev(epoch.addingTimeInterval(-30), 45)
        #expect(UsagePace.reading(fresh(epoch, 50), previous: recent, now: epoch, identityKey: "id1") == .unknown)
    }

    @Test("flat or falling use is steady")
    func steady() {
        let prev = prev(epoch.addingTimeInterval(-300), 50)
        #expect(UsagePace.reading(fresh(epoch, 50), previous: prev, now: epoch, identityKey: "id1") == .steady)
        #expect(UsagePace.reading(fresh(epoch, 30), previous: prev, now: epoch, identityKey: "id1") == .steady)
    }

    @Test("climbing use projects the exhaustion moment")
    func depleting() {
        // +5 points over 300 s → the 50 left drain in 3000 s.
        let prev = prev(epoch.addingTimeInterval(-300), 45)
        let reading = UsagePace.reading(fresh(epoch, 50), previous: prev, now: epoch, identityKey: "id1")
        #expect(reading == .depleting(at: epoch.addingTimeInterval(3000)))
    }

    @Test("anything that breaks the chain is unknown")
    func chainBreaks() {
        let prevAt = epoch.addingTimeInterval(-300)
        let w = fresh(epoch, 50)
        // missing or changed identity
        #expect(UsagePace.reading(w, previous: prev(prevAt, 45), now: epoch) == .unknown)
        #expect(UsagePace.reading(w, previous: prev(prevAt, 45, id: "other"), now: epoch, identityKey: "id1") == .unknown)
        // missing, changed, or already-passed reset
        let noResetPrev = UsagePace.Sample(at: prevAt, usedPercent: 45, identityKey: "id1", resetsAt: nil, durationMinutes: 300)
        #expect(UsagePace.reading(w, previous: noResetPrev, now: epoch, identityKey: "id1") == .unknown)
        let otherReset = UsagePace.Sample(at: prevAt, usedPercent: 45, identityKey: "id1", resetsAt: epoch.addingTimeInterval(86400), durationMinutes: 300)
        #expect(UsagePace.reading(w, previous: otherReset, now: epoch, identityKey: "id1") == .unknown)
        let pastReset = UsagePace.Sample(at: prevAt, usedPercent: 45, identityKey: "id1", resetsAt: epoch.addingTimeInterval(-1), durationMinutes: 300)
        #expect(UsagePace.reading(window(300, used: 50, resetsAt: epoch.addingTimeInterval(-1)),
                                previous: pastReset, now: epoch, identityKey: "id1") == .unknown)
        // changed window length
        #expect(UsagePace.reading(w, previous: prev(prevAt, 45, duration: 10080), now: epoch, identityKey: "id1") == .unknown)
        // gap below 60 s or above maximumSampleGap
        let tooOld = UsagePace.Sample(at: epoch.addingTimeInterval(-601), usedPercent: 45, identityKey: "id1", resetsAt: epoch.addingTimeInterval(86400), durationMinutes: 300)
        #expect(UsagePace.reading(fresh(epoch, 50, reset: epoch.addingTimeInterval(86400)),
                                previous: tooOld, now: epoch, identityKey: "id1") == .unknown)
        // the boundaries themselves are admitted (60 s and 600 s)
        let edge60 = UsagePace.Sample(at: epoch.addingTimeInterval(-60), usedPercent: 45, identityKey: "id1", resetsAt: epoch.addingTimeInterval(86400), durationMinutes: 300)
        #expect(UsagePace.reading(fresh(epoch, 50, reset: epoch.addingTimeInterval(86400)),
                                previous: edge60, now: epoch, identityKey: "id1") != .unknown)
        let edge600 = UsagePace.Sample(at: epoch.addingTimeInterval(-600), usedPercent: 45, identityKey: "id1", resetsAt: epoch.addingTimeInterval(86400), durationMinutes: 300)
        #expect(UsagePace.reading(fresh(epoch, 50, reset: epoch.addingTimeInterval(86400)),
                                previous: edge600, now: epoch, identityKey: "id1") != .unknown)
        // non-finite or out-of-range percents
        #expect(UsagePace.reading(fresh(epoch, .nan), previous: prev(prevAt, 45), now: epoch, identityKey: "id1") == .unknown)
        let highPrev = UsagePace.Sample(at: prevAt, usedPercent: 105, identityKey: "id1", resetsAt: epoch.addingTimeInterval(86400), durationMinutes: 300)
        #expect(UsagePace.reading(fresh(epoch, 50, reset: epoch.addingTimeInterval(86400)),
                                previous: highPrev, now: epoch, identityKey: "id1") == .unknown)
    }

    @Test("runsOutEarly only counts depletion landing before the reset")
    func runsOutEarly() {
        let resetSoon = epoch.addingTimeInterval(2 * 3600)
        let resetFar = epoch.addingTimeInterval(20 * 3600)
        let depleting = UsagePace.Reading.depleting(at: epoch.addingTimeInterval(5 * 3600))
        // Empty at 5h but the reset lands at 2h: on track, nothing to flag.
        #expect(UsagePace.runsOutEarly(depleting, window: window(300, used: 50, resetsAt: resetSoon)) == nil)
        // Empty at 5h while the reset is 20h away: it runs dry early.
        #expect(UsagePace.runsOutEarly(depleting, window: window(300, used: 50, resetsAt: resetFar))
            == epoch.addingTimeInterval(5 * 3600))
        #expect(UsagePace.runsOutEarly(.steady, window: window(300, used: 50, resetsAt: resetSoon)) == nil)
        // No reset to catch it: depletion still stands on its own.
        #expect(UsagePace.runsOutEarly(depleting, window: window(nil, used: 50)) != nil)
    }
}

@Suite("Usage guidance")
struct UsageGuidanceTests {
    let future = epoch.addingTimeInterval(3 * 86400)
    let soon = epoch.addingTimeInterval(3600)
    private func fresh(_ readAt: Date) -> UsageWindow {
        window(300, used: 10, resetsAt: soon)
    }

    @Test("a drained common window blocks the account even when another has room")
    func commonExhaustedBlocks() {
        // session 100 used → excluded entirely, weekly 10 doesn't rescue it.
        let blocked = usage([window(300, used: 100, resetsAt: soon),
                             window(10080, used: 10, resetsAt: future)], id: "codex:a")
        let ok = usage([window(300, used: 20, resetsAt: soon),
                        window(10080, used: 20, resetsAt: future)], id: "codex:b")
        let proposals = UsageGuidance.proposals([blocked, ok], now: epoch)
        #expect(proposals.map(\.usageID) == ["codex:b"])
        #expect(proposals[0].comparedCount == 1 && !proposals[0].isRecommendation)
    }

    /// Every exclusion reason, asserted one account at a time against a known-good peer:
    /// the bad account must never appear, the good one is the lone neutral reading.
    @Test("every exclusion reason drops exactly that account", arguments: [
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], state: .failed(.timeout)),
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], state: .unavailable(.cliMissing)),
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], state: .notReporting),
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(-60))]),   // stale reset
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))],
              readAt: epoch.addingTimeInterval(-601)),                            // too old
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))],
              readAt: epoch.addingTimeInterval(60)),                              // future read
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], auth: .apiKey),
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], auth: .unknown),
        usage([window(300, used: 10, scope: "Fable", resetsAt: epoch.addingTimeInterval(3600))]),
        usage([window(300, used: .nan, resetsAt: epoch.addingTimeInterval(3600))]),
        usage([window(300, used: .infinity, resetsAt: epoch.addingTimeInterval(3600))]),
        usage([window(300, used: -1, resetsAt: epoch.addingTimeInterval(3600))]),  // below range
        usage([window(300, used: 101, resetsAt: epoch.addingTimeInterval(3600))]), // above range
        usage([window(nil, used: 10, resetsAt: epoch.addingTimeInterval(3600))]),  // no duration
        usage([window(0, used: 10, resetsAt: epoch.addingTimeInterval(3600))]),    // zero duration
        usage([window(-300, used: 10, resetsAt: epoch.addingTimeInterval(3600))]), // negative duration
        usage([window(600, used: 10, resetsAt: epoch.addingTimeInterval(3600))]),  // kind .other
        usage([window(300, used: 80, resetsAt: epoch.addingTimeInterval(3600))]),  // at warn bar
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600)),
               window(300, used: 20, resetsAt: epoch.addingTimeInterval(3600))]),  // duplicate signature
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], provider: .claude),
        usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], provider: .cursor),
    ])
    func exclusions(bad: AccountUsage) {
        let good = usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))],
                         id: "codex:good")
        let proposals = UsageGuidance.proposals([bad, good], now: epoch)
        #expect(proposals.count == 1)
        #expect(proposals[0].usageID == "codex:good")
        #expect(proposals[0].comparedCount == 1 && !proposals[0].isRecommendation)
    }

    @Test("boundary values that stay admitted")
    func boundaries() {
        // 79.9% used is just under the warn bar; exactly 600 s old still counts.
        let a = usage([window(300, used: 79.9, resetsAt: epoch.addingTimeInterval(3600))],
                      id: "codex:a", readAt: epoch.addingTimeInterval(-600))
        let b = usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], id: "codex:b")
        let proposals = UsageGuidance.proposals([a, b], now: epoch)
        #expect(proposals[0].usageID == "codex:b" && proposals[0].comparedCount == 2)
        // A monthly window is a positive healthy common window, not a rejection.
        let monthly = usage([window(43200, used: 10, resetsAt: epoch.addingTimeInterval(3600))],
                            id: "codex:m")
        let monthly2 = usage([window(43200, used: 20, resetsAt: epoch.addingTimeInterval(3600))],
                             id: "codex:n")
        #expect(UsageGuidance.proposals([monthly, monthly2], now: epoch)[0].comparedCount == 2)
    }

    @Test("equal-size groups tie-break on the lexically smallest signature")
    func groupTie() {
        // Two size-2 groups: [session] vs [weekly] — "session:300" sorts before "weekly:10080".
        let s1 = usage([window(300, used: 10, resetsAt: epoch.addingTimeInterval(3600))], id: "codex:a")
        let s2 = usage([window(300, used: 20, resetsAt: epoch.addingTimeInterval(3600))], id: "codex:b")
        let w1 = usage([window(10080, used: 30, resetsAt: epoch.addingTimeInterval(86400))], id: "codex:c")
        let w2 = usage([window(10080, used: 40, resetsAt: epoch.addingTimeInterval(86400))], id: "codex:d")
        let proposals = UsageGuidance.proposals([w1, s1, w2, s2], now: epoch)
        #expect(proposals[0].comparedCount == 2)
        #expect(proposals[0].usageID == "codex:a") // session group won the lexical tie-break
    }

    @Test("comparison uses the minimum remaining share across common windows")
    func minimumLeft() {
        // A: min(70, 40) = 40; B: min(50, 80) = 50 → B wins on its session.
        let a = usage([window(300, used: 30, resetsAt: soon),
                       window(10080, used: 60, resetsAt: future)], id: "codex:a")
        let b = usage([window(300, used: 50, resetsAt: soon),
                       window(10080, used: 20, resetsAt: future)], id: "codex:b")
        let proposals = UsageGuidance.proposals([a, b], now: epoch)
        #expect(proposals.count == 1)
        #expect(proposals[0].usageID == "codex:b")
        #expect(proposals[0].comparedCount == 2 && proposals[0].isRecommendation)
        #expect(proposals[0].window == window(300, used: 50, resetsAt: soon)) // limiting = min left
        #expect(proposals[0].windows.count == 2)
        #expect(proposals[0].windows[0].durationMinutes == 300) // duration sort
    }

    @Test("equal scores keep the earlier stable account id")
    func tieStable() {
        let b = usage([fresh(epoch)], id: "codex:b")
        let a = usage([fresh(epoch)], id: "codex:a")
        #expect(UsageGuidance.proposals([b, a], now: epoch)[0].usageID == "codex:a")
        // input order invariant
        #expect(UsageGuidance.proposals([a, b], now: epoch)[0].usageID == "codex:a")
    }

    @Test("same provider different plans still compare and flag it")
    func plansDiffer() {
        let a = usage([fresh(epoch)], id: "codex:a", plan: "pro")
        let b = usage([fresh(epoch)], id: "codex:b", plan: "team")
        let proposals = UsageGuidance.proposals([a, b], now: epoch)
        #expect(proposals[0].plansDiffer)
        let samePlan = usage([fresh(epoch)], id: "codex:c", plan: "pro")
        #expect(!UsageGuidance.proposals([a, samePlan], now: epoch)[0].plansDiffer)
    }

    @Test("different window structures are never compared")
    func structures() {
        // a has [session], b has [session,weekly]: no common signature → no comparison.
        let a = usage([fresh(epoch)], id: "codex:a")
        let b = usage([fresh(epoch), window(10080, used: 20, resetsAt: future)], id: "codex:b")
        #expect(UsageGuidance.proposals([a, b], now: epoch).isEmpty)
    }

    @Test("the largest comparable group supplies the candidate")
    func largestGroup() {
        let pair1 = usage([fresh(epoch)], id: "codex:a")
        let pair2 = usage([fresh(epoch)], id: "codex:b")
        let trioA = usage([fresh(epoch), window(10080, used: 10, resetsAt: future)], id: "codex:c")
        let trioB = usage([fresh(epoch), window(10080, used: 30, resetsAt: future)], id: "codex:d")
        let trioC = usage([fresh(epoch), window(10080, used: 50, resetsAt: future)], id: "codex:e")
        let proposals = UsageGuidance.proposals([pair1, pair2, trioA, trioB, trioC], now: epoch)
        #expect(proposals[0].comparedCount == 3)
        // min remaining: c=min(90,90)=90, d=min(90,70)=70, e=min(90,50)=50 → c wins.
        #expect(proposals[0].usageID == "codex:c")
    }

    @Test("warnAt outside the admitted range fails closed")
    func warnAtGuard() {
        let a = usage([window(300, used: 92, resetsAt: soon)], id: "codex:a")
        let b = usage([fresh(epoch)], id: "codex:b")
        // 92 used ≥ 80 warn → a excluded, b alone → neutral single.
        #expect(UsageGuidance.proposals([a, b], now: epoch)[0].usageID == "codex:b")
        #expect(UsageGuidance.proposals([a, b], now: epoch, warnAt: .nan).isEmpty)
        #expect(UsageGuidance.proposals([a, b], now: epoch, warnAt: 30).isEmpty)
        #expect(UsageGuidance.proposals([a, b], now: epoch, warnAt: 120).isEmpty)
    }
}

@Suite("Usage alerts")
struct UsageAlertTests {
    let future = epoch.addingTimeInterval(3 * 86400)

    @Test("a window crossing the threshold alerts once")
    func crossOnce() {
        let usages = [usage([window(10080, used: 85, resetsAt: future)])]
        let first = UsageAlerts.update(usages: usages, threshold: 80, alerted: [], now: epoch)
        #expect(first.alerts.count == 1)
        #expect(first.alerts[0].key == "codex:a/weekly/")
        #expect(first.alerts[0].emptied == false)
        #expect(first.alerted == ["codex:a/weekly/"])
        // Same reading again: kept in the set, nothing new.
        let again = UsageAlerts.update(usages: usages, threshold: 80, alerted: first.alerted,
                                       now: epoch)
        #expect(again.alerts.isEmpty)
        #expect(again.alerted == first.alerted)
    }

    @Test("100%+ is emptied; a window already at 100 on first sight alerts as emptied")
    func emptied() {
        let usages = [usage([window(300, used: 104, resetsAt: future)])]
        let result = UsageAlerts.update(usages: usages, threshold: 80, alerted: [], now: epoch)
        #expect(result.alerts.map(\.emptied) == [true])
    }

    @Test("recovering below the hysteresis re-arms; hovering just under keeps it spent")
    func hysteresis() {
        let alerted: Set<String> = ["codex:a/weekly/"]
        let hovering = [usage([window(10080, used: 76, resetsAt: future)])] // 80-5=75 boundary
        let keep = UsageAlerts.update(usages: hovering, threshold: 80, alerted: alerted, now: epoch)
        #expect(keep.alerted == alerted)
        #expect(keep.alerts.isEmpty)
        let recovered = [usage([window(10080, used: 70, resetsAt: future)])]
        let rearmed = UsageAlerts.update(usages: recovered, threshold: 80, alerted: alerted, now: epoch)
        #expect(rearmed.alerted.isEmpty)
        let again = UsageAlerts.update(usages: [usage([window(10080, used: 82, resetsAt: future)])],
                                       threshold: 80, alerted: rearmed.alerted, now: epoch)
        #expect(again.alerts.count == 1)
    }

    @Test("stale and non-ok windows never alert")
    func neverStale() {
        let stale = usage([window(300, used: 95, resetsAt: epoch.addingTimeInterval(-60))])
        #expect(UsageAlerts.update(usages: [stale], threshold: 80, alerted: [], now: epoch).alerts.isEmpty)
        let failed = usage([window(300, used: 95, resetsAt: future)], state: .failed(.network))
        #expect(UsageAlerts.update(usages: [failed], threshold: 80, alerted: [], now: epoch).alerts.isEmpty)
    }

    // MARK: - Audit A-07

    @Test func aFailedReadBetweenTwoReadingsDoesNotRearm() {
        let ok = [usage([window(10080, used: 90, resetsAt: future)])]
        let first = UsageAlerts.update(usages: ok, threshold: 80, alerted: [], now: epoch)
        #expect(first.alerts.count == 1)
        // A transient failure: the row keeps its windows but its state is failed.
        let failed = [usage([window(10080, used: 90, resetsAt: future)], state: .failed(.timeout))]
        let during = UsageAlerts.update(usages: failed, threshold: 80, alerted: first.alerted, now: epoch)
        #expect(during.alerts.isEmpty)
        #expect(during.alerted == first.alerted)
        let after = UsageAlerts.update(usages: ok, threshold: 80, alerted: during.alerted, now: epoch)
        #expect(after.alerts.isEmpty)
    }

    @Test func aKeyIsKeptWhileItsAccountHasNoOkReading() {
        let alerted: Set<String> = ["codex:a/weekly/", "codex:a/session/"]
        for state in [UsageState.failed(.network), .unavailable(.noSignIn), .notReporting] {
            let result = UsageAlerts.update(usages: [usage([], state: state)], threshold: 80, alerted: alerted, now: epoch)
            #expect(result.alerted == alerted, "\(state)")
            #expect(result.alerts.isEmpty)
        }
    }

    @Test func aKeyIsDroppedWhenItsAccountDisappears() {
        let alerted: Set<String> = ["codex:a/weekly/", "codex:gone/weekly/"]
        let result = UsageAlerts.update(usages: [usage([], state: .failed(.network))], threshold: 80,
                                        alerted: alerted, now: epoch)
        #expect(result.alerted == ["codex:a/weekly/"])
        // An id that merely starts with another id is a different account.
        let other = UsageAlerts.update(usages: [usage([], id: "codex:ab", state: .failed(.network))], threshold: 80,
                                       alerted: ["codex:a/weekly/"], now: epoch)
        #expect(other.alerted.isEmpty)
    }

    @Test func aNewWindowAfterTheResetAlertsAgain() {
        let first = UsageAlerts.update(usages: [usage([window(10080, used: 90, resetsAt: future)])],
                                       threshold: 80, alerted: [], now: epoch)
        // The reset passed: the old number says nothing, so the key is released.
        let afterReset = future.addingTimeInterval(60)
        let stale = UsageAlerts.update(usages: [usage([window(10080, used: 90, resetsAt: future)])],
                                       threshold: 80, alerted: first.alerted, now: afterReset)
        #expect(stale.alerted.isEmpty && stale.alerts.isEmpty)
        let next = UsageAlerts.update(
            usages: [usage([window(10080, used: 85, resetsAt: afterReset.addingTimeInterval(7 * 86400))])],
            threshold: 80, alerted: stale.alerted, now: afterReset)
        #expect(next.alerts.count == 1)
    }

    @Test func changingTheThresholdStartsOver() {
        let state = UsageAlertState(threshold: 80, keys: ["codex:a/weekly/"])
        #expect(state.keys(for: 80) == ["codex:a/weekly/"])
        #expect(state.keys(for: 90).isEmpty)
        let usages = [usage([window(10080, used: 85, resetsAt: future)])]
        // Raised to 90: 85% is no longer over the line, and nothing is remembered.
        let raised = UsageAlerts.update(usages: usages, threshold: 90, alerted: state.keys(for: 90), now: epoch)
        #expect(raised.alerts.isEmpty && raised.alerted.isEmpty)
        // Lowered to 70: it counts as a fresh crossing.
        let lowered = UsageAlerts.update(usages: usages, threshold: 70, alerted: state.keys(for: 70), now: epoch)
        #expect(lowered.alerts.count == 1)
    }
}

@Suite("Usage alert store")
struct UsageAlertStoreTests {
    @Test func roundTrips() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let store = UsageAlertStore(env: sb.env, fs: sb.fs)
        #expect(store.load() == nil)
        let state = UsageAlertState(threshold: 80, keys: ["codex:m-1a2b3c4d/weekly/", "claude:cli/session/"])
        try store.save(state)
        #expect(store.load() == state)
        #expect(UsageAlertStore(env: sb.env, fs: sb.fs).load()?.keys(for: 80) == state.keys)
        let mode = try FileManager.default.attributesOfItem(atPath: sb.env.usageAlertsFile.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func aBrokenFileIsAnEmptyState() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        try sb.fs.createDirectory(sb.env.storeDir)
        try sb.fs.write(Data("{not json".utf8), to: sb.env.usageAlertsFile)
        #expect(UsageAlertStore(env: sb.env, fs: sb.fs).load() == nil)
        try sb.fs.write(Data(repeating: 0x20, count: UsageAlertStore.maximumBytes + 1), to: sb.env.usageAlertsFile)
        #expect(UsageAlertStore(env: sb.env, fs: sb.fs).load() == nil)
    }

    @Test func theFileHoldsOnlyOpaqueKeys() throws {
        let sb = try Sandbox(); defer { sb.remove() }
        let store = UsageAlertStore(env: sb.env, fs: sb.fs)
        try store.save(UsageAlertState(threshold: 85, keys: ["codex:m-1a2b3c4d/weekly/"]))
        let text = String(decoding: try Data(contentsOf: sb.env.usageAlertsFile), as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["threshold", "keys"])
        #expect(!text.contains("@"))
        #expect(!text.contains("label"))
    }
}

@Suite("Usage snapshot")
struct UsageSnapshotTests {
    @Test("round-trips with masked labels and problem names")
    func roundTrip() throws {
        L10n.language = .en
        let usages = [
            usage([window(300, used: 55, resetsAt: epoch.addingTimeInterval(3600))],
                  id: "codex:work@x.com", readAt: epoch),
            usage([], id: "claude:cli", provider: .claude, state: .unavailable(.schemaChanged),
                  readAt: epoch),
        ]
        let snapshot = UsageSnapshot(usages: usages, generatedAt: epoch, showEmails: false)
        #expect(snapshot.accounts[0].label == "Account codex:••••@x.com")
        #expect(snapshot.accounts[0].windows[0].leftPercent == 45)
        #expect(snapshot.accounts[1].state == "unavailable")
        #expect(snapshot.accounts[1].problem == "schemaChanged")
        #expect(snapshot.accounts[1].label == "CLI sign-in")

        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.fs.createDirectory(sandbox.env.storeDir)
        try snapshot.write(env: sandbox.env, fs: sandbox.fs)
        let loaded = UsageSnapshot.load(env: sandbox.env)
        #expect(loaded == snapshot)

        // A store that never wrote one loads nothing.
        let fresh = try Sandbox()
        defer { fresh.remove() }
        #expect(UsageSnapshot.load(env: fresh.env) == nil)
    }
}

@Suite("Warn threshold")
struct WarnThresholdTests {
    let future = epoch.addingTimeInterval(3 * 86400)

    @Test("the Running Out cutoff follows the configured percent")
    func customCutoff() {
        let usages = [usage([window(300, used: 75, resetsAt: future)])]
        #expect(UsagePriority.sections(usages, pins: [], now: epoch, runningOutAt: 80).runningOut.isEmpty)
        #expect(UsagePriority.sections(usages, pins: [], now: epoch, runningOutAt: 70).runningOut.count == 1)
    }

    @Test("settings clamp a hand-edited percent and default to 80 / alerts on")
    func settingsClamp() throws {
        #expect(SwitcherSettings().effectiveUsageWarnPercent == 80)
        #expect(SwitcherSettings().effectiveUsageAlertsEnabled == true)
        #expect(SwitcherSettings(usageWarnPercent: 95).effectiveUsageWarnPercent == 95)
        #expect(SwitcherSettings(usageWarnPercent: 40).effectiveUsageWarnPercent == 80)
        #expect(SwitcherSettings(usageWarnPercent: 100).effectiveUsageWarnPercent == 80)
        #expect(SwitcherSettings(usageAlertsEnabled: false).effectiveUsageAlertsEnabled == false)
        let old = Data(#"{"language":"en"}"#.utf8)
        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: old)
        #expect(decoded.usageWarnPercent == nil)
        #expect(decoded.effectiveUsageWarnPercent == 80)
    }
}
