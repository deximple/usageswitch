import Foundation
import Testing
@testable import SwitcherCore

/// What the usage screens decide per row, outside the views (2.5.0 audit U-04, U-05, U-06, U-08,
/// U-09, U-10). Assertions compose their expectations in the current language, so they hold in any.
@Suite("Usage screen states")
struct ScreenStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(_ id: String, provider: UsageProvider = .codex, label: String = "Personal",
                       state: UsageState = .ok, readAt: Date? = nil, windows: [UsageWindow] = [],
                       resetCredits: UsageResetCredits? = nil) -> AccountUsage {
        AccountUsage(id: id, provider: provider, accountRef: String(id.split(separator: ":").last ?? ""),
                     label: label, plan: nil, windows: windows, state: state, readAt: readAt ?? now,
                     toolVersion: nil, authentication: .subscription, identityKey: "k",
                     resetCredits: resetCredits)
    }

    // MARK: - U-08 the Guide's attention lines name the provider

    @Test("two accounts with one name stay apart in the Guide's attention lines")
    func attentionLinesNameTheProvider() {
        let claude = usage("claude:app:p", provider: .claude, state: .failed(.network))
        let codex = usage("codex:p", provider: .codex, state: .failed(.network))
        let lines = UsageAttention.lines([claude, codex], label: \.label, warnAt: 80, now: now)
        #expect(lines.count == 2)
        #expect(Set(lines.map(\.text)).count == 2, "\(lines.map(\.text))")
        #expect(lines[0].text.hasPrefix("\(UsageText.providerName(.claude)) · Personal"))
        #expect(lines[1].text.hasPrefix("\(UsageText.providerName(.codex)) · Personal"))
    }

    @Test("a window over the warning level names the provider too")
    func warningLineNamesTheProvider() {
        let window = UsageWindow(durationMinutes: 10080, usedPercent: 85, resetsAt: now.addingTimeInterval(86_400))
        let lines = UsageAttention.lines([usage("codex:p", windows: [window])], label: \.label,
                                         warnAt: 80, now: now)
        #expect(lines.map(\.text) == [L10n.t(.usageAttnWindow, "\(UsageText.providerName(.codex)) · Personal",
                                             UsageText.name(of: window), 15)])
        #expect(lines.first?.warn == true)
    }

    // MARK: - U-04 a registered row waiting for its first read

    private func presentation(_ row: AccountUsage, owner: UsageAccountPresentation.Owner?) -> UsageAccountPresentation {
        UsageAccountPresentation(usage: row, name: row.label, email: nil, environment: .cli, login: .saved,
                                 badgeActive: false, owner: owner)
    }

    @Test("a registered Codex row with no reading yet is being checked while a refresh runs")
    func codexRowAwaitsItsFirstRead() {
        let placeholder = usage("codex:work", state: .notReporting)
        let row = presentation(placeholder, owner: .codex("work"))
        #expect(UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: true, boundClaudeAccountIDs: [],
                                                   codexInstalled: true))
        // Once the refresh is over, or once it has its own reading, the reason stands.
        #expect(!UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: false, boundClaudeAccountIDs: [],
                                                    codexInstalled: true))
        #expect(!UsagePresentations.awaitsFirstRead(row, readings: [placeholder], refreshing: true,
                                                    boundClaudeAccountIDs: [], codexInstalled: true))
        // Without Codex installed no collector reads it: the reason must not flicker on every refresh.
        #expect(!UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: true, boundClaudeAccountIDs: [],
                                                    codexInstalled: false))
    }

    @Test("a saved Claude account is checked only when a profile is linked: nothing else reads it")
    func claudeRowAwaitsOnlyWithAProfile() {
        let row = presentation(usage("claude:app:acc", provider: .claude, state: .notReporting),
                               owner: .claude("acc"))
        #expect(UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: true,
                                                   boundClaudeAccountIDs: ["acc"], codexInstalled: true))
        #expect(!UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: true,
                                                    boundClaudeAccountIDs: [], codexInstalled: true))
    }

    @Test("a row with no owner is never shown as being checked")
    func unownedRowNeverAwaits() {
        let row = presentation(usage("cursor:cursor", provider: .cursor, state: .notReporting), owner: nil)
        #expect(!UsagePresentations.awaitsFirstRead(row, readings: [], refreshing: true, boundClaudeAccountIDs: [],
                                                    codexInstalled: true))
    }

    // MARK: - U-06 the lock glyph tells verified from saved without color

    @Test func everyLoginStateThatShowsALockHasItsOwnGlyph() {
        let shown = [UsageAccountPresentation.Login.verified, .saved, .requiresSignIn].compactMap(\.symbol)
        #expect(shown.count == 3)
        #expect(Set(shown).count == 3, "\(shown)")
        #expect(UsageAccountPresentation.Login.unknown.symbol == nil)
    }

    // MARK: - U-09 reset tickets from a failed read are the last known value

    private let credits = UsageResetCredits(available: 2)

    @Test("a current read shows its reset tickets as they are")
    func currentTickets() {
        let line = UsageText.resetCreditsLine(usage("codex:p", resetCredits: credits), now: now)
        #expect(line == UsageText.ResetCreditsLine(text: L10n.t(.usageResetCredits, 2), lastKnown: false))
    }

    @Test("a failed read keeps the last count but says when it was read")
    func failedReadTickets() {
        let readAt = now.addingTimeInterval(-25 * 60)
        let row = usage("codex:p", state: .failed(.network), readAt: readAt, resetCredits: credits)
        let line = UsageText.resetCreditsLine(row, now: now)
        #expect(line?.lastKnown == true)
        #expect(line?.text == L10n.t(.usageResetCredits, 2) + " · "
                + UsageText.updatedAgo(readAt: readAt, now: now))
    }

    @Test("an aged read is last known even when it succeeded")
    func agedReadTickets() {
        let readAt = now.addingTimeInterval(-(UsagePresentations.verifiedAgeLimit + 60))
        let line = UsageText.resetCreditsLine(usage("codex:p", readAt: readAt, resetCredits: credits), now: now)
        #expect(line?.lastKnown == true)
    }

    @Test func noTicketsNoLine() {
        #expect(UsageText.resetCreditsLine(usage("codex:p", state: .failed(.network)), now: now) == nil)
    }

    // MARK: - U-05 a slider moved without a drag is saved

    @Test("a change that comes without a drag (arrow keys, VoiceOver) is saved at once")
    func keyboardChangeIsSaved() {
        var draft = SliderDraft()
        let saved = draft.set(0.6)
        #expect(saved == 0.6)
        #expect(draft.value == nil)
    }

    @Test("a drag is held until it ends, then saved once")
    func dragIsSavedWhenItEnds() {
        var draft = SliderDraft()
        let steps = [draft.editingChanged(true), draft.set(0.3), draft.set(0.4)]
        #expect(steps == [nil, nil, nil])
        #expect(draft.value == 0.4)
        let ended = draft.editingChanged(false)
        #expect(ended == 0.4)
        #expect(draft.value == nil)
        // A drag that moved nothing saves nothing.
        let empty = [draft.editingChanged(true), draft.editingChanged(false)]
        #expect(empty == [nil, nil])
    }

    // MARK: - U-10 a result banner is announced once

    @Test("a banner shown in the menu and the window at once is announced once")
    func announcedOnce() {
        var gate = AnnouncementGate()
        let answers = [
            gate.shouldAnnounce("Switched to Work", at: now),
            gate.shouldAnnounce("Switched to Work", at: now.addingTimeInterval(1)),
            gate.shouldAnnounce("Switched to Personal", at: now.addingTimeInterval(1)),
            // The same result later is a new event.
            gate.shouldAnnounce("Switched to Work", at: now.addingTimeInterval(30)),
            gate.shouldAnnounce("", at: now.addingTimeInterval(60)),
        ]
        #expect(answers == [true, false, true, true, false])
    }

    @Test("a banner is not read again when another one was announced in between")
    func announcedOnceAcrossOthers() {
        var gate = AnnouncementGate()
        let answers = [
            gate.shouldAnnounce("Warning A", at: now),
            gate.shouldAnnounce("Warning B", at: now),
            gate.shouldAnnounce("Warning A", at: now.addingTimeInterval(1)),
            gate.shouldAnnounce("Warning B", at: now.addingTimeInterval(1)),
        ]
        #expect(answers == [true, true, false, false])
    }
}
