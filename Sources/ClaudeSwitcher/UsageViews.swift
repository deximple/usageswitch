import AppKit
import SwiftUI
import SwitcherCore

/// Bar fill: the vendor's logo color while there is room; warning and used-up override it,
/// and a stale reading is always grey.
enum UsageColors {
    static func forWindow(_ window: UsageWindow, provider: UsageProvider, stale: Bool,
                          warnAt: Double = 80) -> Color {
        Theme.usageFill(UsageBarPalette.role(usedPercent: window.usedPercent, warnAt: warnAt,
                                             stale: stale), provider: provider)
    }
}

/// A status line that never rides on color alone: the marker carries the color, the text
/// stays at full reading contrast.
struct UsageNote: View {
    enum Tone { case neutral, warning, failure }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            switch tone {
            case .neutral: EmptyView()
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.usageWarn)
                    .accessibilityHidden(true)
            case .failure:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.usageExhausted)
                    .accessibilityHidden(true)
            }
            Text(text).foregroundStyle(tone == .neutral ? Theme.inkMuted : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.small)
    }
}

/// List title plus the Guide disclosure, kept OUT of the scrolling body in both hosts so the
/// control stays reachable no matter how long the account list grows.
struct UsageListHeader: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: SwitcherModel

    private var quietSignalVisible: Bool {
        SuggestionQuietSignal.shouldShow(enabled: settings.suggestionQuietSignal,
            guideExpanded: model.guideExpanded,
            topCandidateID: model.suggestionCandidateIdentity(),
            activeCandidateID: model.activeSuggestionCandidateIdentity())
    }

    var body: some View {
        HStack {
            Text(L10n.t(.usageListTitle))
                .font(Theme.title).foregroundStyle(Theme.ink)
            Spacer()
            Button {
                model.guideExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.t(.usageSegGuide))
                    if quietSignalVisible {
                        Circle().fill(Theme.active).frame(width: 5, height: 5)
                            .accessibilityLabel(Text(L10n.t(.suggestionAvailable)))
                    }
                    Image(systemName: model.guideExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.usages.isEmpty)
            .accessibilityLabel(quietSignalVisible
                ? L10n.t(.usageSegGuide) + ", " + L10n.t(.suggestionAvailable)
                : L10n.t(.usageSegGuide))
            .accessibilityValue(model.guideExpanded ? L10n.t(.usageGuideExpandedA11y)
                                                    : L10n.t(.usageGuideCollapsedA11y))
        }
    }
}

/// Last read / next refresh state plus the refresh control — fixed chrome, not scroll content.
struct UsageFooter: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                if model.isRefreshing {
                    Text(L10n.t(.usageRefreshing)).font(Theme.small).foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        if let lastRead = model.usages.map(\.readAt).max() {
                            Text(UsageText.updatedAgo(readAt: lastRead, now: context.date))
                                .font(Theme.small).foregroundStyle(Theme.inkMuted)
                        }
                        Text(model.nextRefresh.timeIntervalSince(context.date) < 60
                            ? L10n.t(.usageRefreshingSoon)
                            : L10n.t(.usageNextUpdate,
                                     UsageText.countdown(to: model.nextRefresh, from: context.date)))
                            .font(Theme.small).foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer()
                UsageRefreshButton(model: model)
            }
        }
    }
}

/// The Usage tab body, shared by the main window and the menu (`compact`). Guide shows one
/// conservative next-account candidate with its comparison folded away, shown only while the
/// header's Guide disclosure is open; the list of every account by provider is always shown.
/// The header and footer live outside this scrollable body.
struct UsageContent: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var tabs: TabSelection
    @State private var confirmingUrgentMode = false
    @State private var taskDraft: Double? = nil
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: Theme.gapGroup) {
                if presentations.isEmpty {
                    emptyState
                } else {
                    if model.guideExpanded {
                        // The guide is an aside folded into the list: one hairline closes it.
                        VStack(alignment: .leading, spacing: Theme.gapRow) {
                            guide(now: context.date)
                            Divider()
                        }
                    }
                    allUsage(now: context.date)
                }
            }
        }
        .onAppear { model.recordSuggestionShownIfNeeded() }
        .onChange(of: model.guideExpanded) { _, expanded in
            if expanded { model.recordSuggestionShownIfNeeded() }
        }
        // Data-driven keys only: a Date()-computed key ran the suggestion engine on every body pass.
        .onChange(of: model.usages) { _, _ in model.recordSuggestionShownIfNeeded() }
        .onChange(of: model.pace) { _, _ in model.recordSuggestionShownIfNeeded() }
        .onChange(of: settings.suggestionMode) { _, _ in model.recordSuggestionShownIfNeeded() }
        .onChange(of: settings.suggestionTask) { _, _ in model.recordSuggestionShownIfNeeded() }
        .onChange(of: settings.suggestionUrgentUntil) { _, _ in model.recordSuggestionShownIfNeeded() }
        .onChange(of: settings.usageWarnPercent) { _, _ in model.recordSuggestionShownIfNeeded() }
        .alert(L10n.t(.suggestionUrgentTitle), isPresented: $confirmingUrgentMode) {
            Button(L10n.t(.uiCancel), role: .cancel) {}
            Button(L10n.t(.suggestionUrgentConfirm)) {
                settings.setSuggestionMode(
                    .urgent,
                    urgentUntil: SuggestionMode.urgentExpiry(usages: model.usages, now: Date()),
                    snapshot: model.suggestionUsageSnapshot())
            }
        } message: {
            Text(L10n.t(.suggestionUrgentMessage))
        }
    }

    /// No readings yet: show the refreshing state while a read runs, else the plain empty copy —
    /// never a healthy-looking list. Independent of the Guide disclosure.
    @ViewBuilder
    private var emptyState: some View {
        if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(L10n.t(.usageRefreshing)).font(Theme.body).foregroundStyle(Theme.inkMuted)
            }
        } else {
            Text(L10n.t(.usageGuideNone)).font(Theme.body).foregroundStyle(Theme.inkMuted)
        }
    }

    /// A fresh reading is one whose timestamp sits inside the admitted window — older
    /// samples and future timestamps are both treated as stale.
    private func fresh(_ usage: AccountUsage, now: Date) -> Bool {
        (0...UsageGuidance.maximumAge).contains(now.timeIntervalSince(usage.readAt))
    }

    /// Confirmed execution environment, shown small next to the account — never guessed:
    /// the Claude collector only sees the current CLI sign-in; registered Codex homes are the
    /// ones the App can open. Neither implies the other environment doesn't exist.
    private func environment(of usage: AccountUsage) -> String? {
        environmentBadge(presentations.first { $0.id == usage.id })
    }

    /// One billing line per account: subscription name+plan, API key billed elsewhere, or a
    /// bare plan that doesn't guess the auth class. Unknown with no plan shows nothing.
    @ViewBuilder
    private func billing(of usage: AccountUsage) -> some View {
        switch usage.authentication {
        case .subscription:
            if let plan = UsageText.planName(usage.plan) {
                Text(plan).font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
        case .apiKey:
            Text("API").font(Theme.caption).foregroundStyle(Theme.inkMuted)
        case .unknown:
            if let plan = UsageText.planName(usage.plan) {
                Text(plan)
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    // MARK: - Guide

    /// What needs attention before any suggestion, keyed by stable account/window ids so two
    /// identical lines never collide in ForEach. Expected API non-reporting stays a neutral
    /// note — only real failures and aged or thresholded readings get the warn color.
    private func attention(now: Date) -> [(id: String, text: String, warn: Bool)] {
        let warnAt = Double(settings.usageWarnPercent)
        var items: [(String, String, Bool)] = []
        for usage in model.usages {
            let label = currentLabel(usage)
            switch usage.state {
            case .failed, .unavailable:
                // connectionRequired is per-row neutral only — never a global notice.
                // A permanent reason like notEligible (e.g. a retired plan) can't be
                // fixed, so it stays on the row but never warns globally.
                if case .unavailable(.connectionRequired) = usage.state { continue }
                if case .unavailable(.notEligible) = usage.state { continue }
                if let reason = UsageText.reason(for: usage) {
                    items.append(("\(usage.id)/state", "\(label) — \(reason)", true))
                }
            case .notReporting:
                if let reason = UsageText.reason(for: usage) {
                    items.append(("\(usage.id)/state", "\(label) — \(reason)", false))
                }
            case .ok:
                if !fresh(usage, now: now) {
                    items.append(("\(usage.id)/aged",
                                  "\(label) — \(UsageText.updatedAgo(readAt: usage.readAt, now: now))",
                                  true))
                }
            }
            guard usage.state == .ok, fresh(usage, now: now) else { continue }
            for window in usage.windows where window.scope == nil {
                if window.isStale(now: now) {
                    items.append((UsagePriority.key(usage, window),
                                  "\(label) — \(L10n.t(.usageRefreshNeeded))", true))
                } else if window.usedPercent >= warnAt,
                          let left = UsageText.percentLeft(window.usedPercent) {
                    items.append((UsagePriority.key(usage, window),
                                  L10n.t(.usageAttnWindow, label,
                                         UsageText.name(of: window), left), true))
                }
            }
        }
        return items
    }

    @ViewBuilder
    private func guide(now: Date) -> some View {
        let suggestion = model.suggestionResult(now: now)
        let explanation = model.suggestionExplanation(now: now, label: currentLabel)
        let proposals = UsageGuidance.proposals(model.suggestionUsages(now: now), now: now,
                                                warnAt: Double(settings.usageWarnPercent))
        let items = attention(now: now)
        VStack(alignment: .leading, spacing: Theme.gapRow) {
            suggestionControls
            if model.usages.isEmpty && model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(L10n.t(.usageRefreshing)).font(Theme.body).foregroundStyle(Theme.inkMuted)
                }
            } else {
                ForEach(items, id: \.id) { item in
                    UsageNote(text: item.text, tone: item.warn ? .warning : .neutral)
                }
                GuideOutlookView(lines: model.suggestionOutlookLines(now: now, label: currentLabel))
                if let headline = explanation?.headline {
                    Text(headline).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let situation = explanation?.situation {
                        Text(situation).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let budget = model.suggestionBudgetLine(now: now) {
                        Text(budget).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let target = model.suggestionSwitchTarget(now: now) {
                        Button(L10n.t(.uiActionSwitchTo, SwitcherModel.displayLabel(target))) {
                            settings.requestConfirmedSwitch(target)
                        }
                        .buttonStyle(ActionButtonStyle(tint: Theme.active))
                    }
                } else if SuggestionGuideFallback.shouldShowLegacyProposal(for: suggestion),
                          let proposal = proposals.first,
                          let usage = model.usages.first(where: { $0.id == proposal.usageID }) {
                    proposalBlock(proposal, usage: usage, now: now)
                }
                if let explanation {
                    GuideBasisView(explanation: explanation, expanded: $model.guideBasisExpanded)
                }
                claudeRow(now: now)
                if explanation?.headline == nil && explanation?.empty.isEmpty != false
                    && proposals.isEmpty && items.isEmpty && claudeUsage == nil {
                    Text(L10n.t(.usageGuideNone)).font(Theme.body).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    private var suggestionControls: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Picker(L10n.t(.suggestionModeLabel), selection: Binding(
                get: { settings.effectiveSuggestionMode(now: Date()) },
                set: { mode in
                    if mode == .urgent {
                        confirmingUrgentMode = true
                    } else {
                        settings.setSuggestionMode(mode, snapshot: model.suggestionUsageSnapshot())
                    }
                })) {
                    ForEach(SuggestionMode.allCases, id: \.self) { mode in
                        Text(modeName(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text(L10n.t(.suggestionModeLabel)))
            // End labels sit under the track: beside it, a long label wrapped and squeezed it.
            VStack(spacing: 0) {
                Slider(value: Binding(
                    get: { taskDraft ?? settings.suggestionTask },
                    set: { taskDraft = $0 }), in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let draft = taskDraft {
                            settings.setSuggestionTask(draft, snapshot: model.suggestionUsageSnapshot())
                            taskDraft = nil
                        }
                    })
                    .accessibilityLabel(Text(L10n.t(.suggestionTaskLabel)))
                HStack {
                    Text(L10n.t(.suggestionTaskSimple))
                    Spacer(minLength: 8)
                    Text(L10n.t(.suggestionTaskReasoning))
                }
                .font(Theme.small).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
        }
    }

    private func modeName(_ mode: SuggestionMode) -> String {
        switch mode {
        case .saver: L10n.t(.suggestionModeSaver)
        case .balanced: L10n.t(.suggestionModeBalanced)
        case .focus: L10n.t(.suggestionModeFocus)
        case .urgent: L10n.t(.suggestionModeUrgent)
        }
    }

    /// Small header → account name → billing → limiting window + remaining + reset → action.
    /// No boxes, no badges: the comparison folds away and every percent shown is REMAINING.
    private func proposalBlock(_ proposal: UsageGuidance.Proposal, usage: AccountUsage,
                               now: Date) -> some View {
        let accessibilityContext =
            "\(UsageText.providerName(usage.provider)), \(currentLabel(usage))"
        return VStack(alignment: .leading, spacing: Theme.gapTight) {
            Text(proposal.isRecommendation ? L10n.t(.usageGuideCandidate)
                                           : L10n.t(.usageGuideReading))
                .font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
            HStack(spacing: 6) {
                ProviderIcon(provider: usage.provider)
                Text(UsageText.providerName(usage.provider))
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                if let env = environment(of: usage) {
                    Text("· \(env)").font(Theme.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            Text(currentLabel(usage))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(2)
            billing(of: usage)
            HStack {
                Text(UsageText.name(of: proposal.window))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
                Spacer()
                Text(UsageText.left(proposal.window))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Group {
                if let resetsAt = proposal.window.resetsAt {
                    if resetsAt > now {
                        Text(resetsAt.timeIntervalSince(now) < 60
                            ? L10n.t(.usageRefreshingSoon)
                            : L10n.t(.usageResetsIn, UsageText.countdown(to: resetsAt, from: now)))
                    } else {
                        UsageNote(text: L10n.t(.usageRefreshNeeded), tone: .warning)
                    }
                }
            }
            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            HStack {
                Spacer()
                Button(L10n.t(.uiDetails)) {
                    AppDelegate.shared?.showUsageDetail(id: usage.id)
                }
                .buttonStyle(ActionButtonStyle(tint: Theme.active))
                .accessibilityLabel(Text("\(accessibilityContext), \(L10n.t(.uiDetails))"))
            }
            DisclosureGroup(L10n.t(.usageGuideBasis)) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(proposal.windows, id: \.self) { window in
                        HStack {
                            Text(UsageText.name(of: window)).font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Text(UsageText.left(window)).font(.system(size: 12))
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                    Text(L10n.t(.usageGuideCompared, proposal.comparedCount,
                                model.usages.filter {
                                    $0.provider == proposal.provider
                                    && $0.authentication == .subscription }.count))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    Text(L10n.t(.usageGuideRatioNote))
                        .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    if proposal.plansDiffer {
                        Text(L10n.t(.usageGuidePlansDiffer))
                            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .padding(.top, 4)
            }
            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityContext))
    }

    /// The one Claude reading the collector sees: the current Code CLI sign-in only. Never
    /// linked to a Claude App account, never a switch suggestion — just its limits, and a
    /// shortcut to the full list.
    private var claudeUsage: AccountUsage? {
        model.usages.first { $0.provider == .claude }
    }

    @ViewBuilder
    private func claudeRow(now: Date) -> some View {
        if let usage = claudeUsage {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                Text(L10n.t(.usageClaudeSource)).font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
                if usage.state == .ok || !usage.windows.isEmpty {
                    ForEach(usage.windows.filter { $0.scope == nil }, id: \.self) { window in
                        UsageBarRow(usage: usage, window: window, settings: settings, now: now,
                                    compact: compact,
                                    pace: model.pace[UsagePriority.key(usage, window)])
                    }
                    if let reason = UsageText.reason(for: usage) { UsageNote(text: reason) }
                } else if let reason = UsageText.reason(for: usage) {
                    UsageNote(text: reason)
                }
            }
        }
    }

    // MARK: - All Usage

    /// Accounts in collector order (Claude, then Codex, then Cursor), grouped by provider.
    private var presentations: [UsageAccountPresentation] {
        model.presentations(claude: settings.status, codex: codex.status, now: Date())
    }

    private func currentLabel(_ usage: AccountUsage) -> String {
        guard let presentation = presentations.first(where: { $0.id == usage.id }) else {
            return model.label(of: usage)
        }
        return displayedName(presentation, fallback: usage)
    }

    private var providerGroups: [(UsageProvider, [AccountUsage])] {
        let rows = presentations
        return UsageProvider.allCases.compactMap { provider in
            let usages = rows.filter { $0.usage.provider == provider }.map(\.usage)
            return usages.isEmpty ? nil : (provider, usages)
        }
    }

    @ViewBuilder
    private func allUsage(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapGroup) {
            ForEach(providerGroups, id: \.0) { provider, usages in
                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    HStack(spacing: 8) {
                        ProviderIcon(provider: provider)
                            .frame(width: 18, height: 18)
                        Text(UsageText.providerName(provider))
                            .font(Theme.title).foregroundStyle(Theme.ink)
                    }
                    .padding(.bottom, Theme.gapTight)
                    ForEach(usages) { usage in
                        accountBlock(usage, now: now,
                                     presentation: presentations.first { $0.id == usage.id })
                        if usage.id != usages.last?.id { Divider().padding(.vertical, Theme.gapTight) }
                    }
                }
            }
        }
    }

    /// One account: label + billing + confirmed environment + plan, then its windows —
    /// remaining share on a plain bar. Non-reporting accounts stay listed; nothing disappears.
    private func accountBlock(_ usage: AccountUsage, now: Date,
                              presentation p: UsageAccountPresentation? = nil) -> some View {
        let p = p ?? presentations.first { $0.id == usage.id }
        let accessibilityContext =
            "\(UsageText.providerName(usage.provider)), \(displayedName(p, fallback: usage))"
        // The second identity line exists only for an email that isn't already the name.
        let email = p?.email.flatMap { $0 == p?.name ? nil : $0 }
        let details = Button(L10n.t(.uiDetails)) { AppDelegate.shared?.showUsageDetail(id: usage.id) }
            .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false, small: true))
            .fixedSize()
            .accessibilityLabel(Text("\(accessibilityContext), \(L10n.t(.uiDetails))"))
        // line 1: masked name + lock + env badge + plan — all from current registry
        let nameLine = HStack(spacing: 4) {
            Text(displayedName(p, fallback: usage))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            lockIcon(p)
            if let env = environmentBadge(p) {
                Text(env).font(Theme.small)
                    .foregroundStyle(p?.badgeActive == true ? Theme.environmentActive : Theme.inkMuted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((p?.badgeActive == true ? Theme.environmentActive : Theme.inkMuted).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
                    .help(p?.badgeActive == true ? L10n.t(.usageActiveEnvironment) : env)
                    .accessibilityValue(p?.badgeActive == true ? L10n.t(.usageActiveEnvironment) : "")
            }
            if let plan = shortPlan(usage) {
                Text(plan).font(Theme.small).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).fixedSize()
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                if let email {
                    HStack(spacing: 0) { nameLine; Spacer(minLength: 8) }
                    // line 2: masked email + Details — every row opens the read-only detail
                    HStack {
                        Text(settings.showEmails ? email : Privacy.maskEmails(in: email))
                            .font(Theme.small).foregroundStyle(Theme.inkMuted)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        details
                    }
                } else {
                    // No email to sit next to: Details joins the name line instead of leaving a
                    // row that holds nothing but the button — unless that would cut the name.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) { nameLine; Spacer(minLength: 8); details }
                        VStack(alignment: .leading, spacing: Theme.gapTight) {
                            HStack(spacing: 0) { nameLine; Spacer(minLength: 8) }
                            HStack { Spacer(); details }
                        }
                    }
                }
            }
            if p?.environment == .app,
               UsagePresentations.claudeAppUnlinked(
                   usage: usage, boundAccountIDs: Set(model.claudeBindings.map(\.accountId))) {
                UsageNote(text: L10n.t(.usageNotLinked))
            }
            let shown = compact ? UsagePresentations.compactWindows(usage, now: now) : usage.windows
            ForEach(shown, id: \.self) { window in
                UsageBarRow(usage: usage, window: window, settings: settings, now: now,
                            compact: compact,
                            pace: model.pace[UsagePriority.key(usage, window)])
            }
            if let balance = model.apiUsageBalanceHint(for: usage, shownWindows: usage.windows, now: now) {
                Text(L10n.t(.apiBalance, String(format: "$%.2f", balance)))
                    .font(Theme.small).foregroundStyle(Theme.inkMuted)
            }
            if let resets = UsageText.resetCredits(usage.resetCredits, now: now) {
                Label(resets, systemImage: "ticket")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .accessibilityLabel(Text("\(accessibilityContext), \(resets)"))
            }
            if compact, usage.windows.count > shown.count {
                Button(L10n.t(.usageMoreLimits, usage.windows.count - shown.count)) {
                    AppDelegate.shared?.showUsageDetail(id: usage.id)
                }
                .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false, small: true))
                .accessibilityLabel(Text("\(accessibilityContext), \(L10n.t(.usageMoreLimits, usage.windows.count - shown.count))"))
            }
            if usage.accountRef.hasPrefix("app:"), usage.provider == .claude {
                if let reason = UsageText.reason(for: usage) {
                    UsageNote(text: reason, tone: isFailure(usage.state) ? .failure : .neutral)
                }
            } else if UsageCollection.canConnect(usage, enabledProviders: settings.enabledUsageProviders) {
                HStack(spacing: 8) {
                    Button(L10n.t(.uiConnectUsage)) {
                        SettingsMenu.enableUsageConnection(usage.provider, model: settings, usage: model)
                    }
                    .buttonStyle(ActionButtonStyle(tint: Theme.active, prominent: false, small: true))
                    .accessibilityLabel(Text("\(accessibilityContext), \(L10n.t(.uiConnectUsage))"))
                    // A tool the user doesn't use leaves the list; ⚙︎ › Usage Connections brings it back.
                    Button(L10n.t(.uiConnectUsageHide)) {
                        settings.hideUsageConnection(usage.provider)
                        model.applyConsent(settings.enabledUsageProviders,
                                           hidden: settings.hiddenUsageProviders)
                    }
                    .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false, small: true))
                    .accessibilityLabel(Text("\(accessibilityContext), \(L10n.t(.uiConnectUsageHide))"))
                }
            } else if let reason = UsageText.reason(for: usage) {
                UsageNote(text: reason, tone: isFailure(usage.state) ? .failure : .neutral)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityContext))
    }

    private func displayedName(_ p: UsageAccountPresentation?, fallback: AccountUsage) -> String {
        let raw = p?.name ?? model.label(of: fallback)
        return !settings.showEmails && raw.contains("@") ? Privacy.maskEmails(in: raw) : raw
    }

    @ViewBuilder private func lockIcon(_ p: UsageAccountPresentation?) -> some View {
        switch p?.login {
        case .verified: Image(systemName: "lock.open.fill").font(.system(size: 10))
                .foregroundStyle(Theme.active)
                .help(L10n.t(.usageLockVerified))
                .accessibilityLabel(L10n.t(.usageLockVerified))
        case .saved: Image(systemName: "lock.open.fill").font(.system(size: 10))
                .foregroundStyle(Theme.inkMuted)
                .help(L10n.t(.usageLockSaved))
                .accessibilityLabel(L10n.t(.usageLockSaved))
        case .requiresSignIn: Image(systemName: "lock.fill").font(.system(size: 10))
                .foregroundStyle(Theme.inkMuted)
                .help(L10n.t(.usageLockRequiredHelp, L10n.t(.uiRelogin)))
                .accessibilityLabel(L10n.t(.usageLockRequired))
        default: EmptyView() // unknown login makes no claim
        }
    }

    private func environmentBadge(_ p: UsageAccountPresentation?) -> String? {
        switch p?.environment {
        case .cli: return L10n.t(.usageEnvCLI)
        case .app: return L10n.t(.usageEnvApp)
        case nil: return nil
        }
    }

    private func shortPlan(_ usage: AccountUsage) -> String? {
        if usage.authentication == .apiKey { return "API" }
        return UsageText.planName(usage.plan)
    }

    private func isFailure(_ state: UsageState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// One window under an account: name, a remaining-share bar, the remaining %, reset or
/// freshness; pinning stays on the context menu. The bar and its number both show what is
/// LEFT (invalid readings render a dash, never a fake hundred); `usedPercent` stays the
/// JSON/storage meaning everywhere else.
struct UsageBarRow: View {
    let usage: AccountUsage
    let window: UsageWindow
    @ObservedObject var settings: SwitcherModel
    let now: Date
    var compact = false
    /// The detail's own layout: name and remaining share on one line, a full-width bar, then
    /// the full reset sentence — the list's column widths don't apply there.
    var stacked = false
    /// Drain speed for this window, when two readings line up.
    var pace: UsagePace.Reading?

    /// Remaining 0…100, nil for a reading that isn't a real non-negative number.
    private var left: Int? { UsageText.percentLeft(window.usedPercent) }
    /// How this window renders: current, greyed last-known, or reset-since-read (no number).
    private var display: UsagePresentations.UsageWindowDisplay {
        UsagePresentations.windowDisplay(usage, window, now: now)
    }
    /// Anything that isn't a live current reading renders greyed.
    private var stale: Bool { display != .current }
    private var color: Color {
        UsageColors.forWindow(window, provider: usage.provider, stale: stale,
                              warnAt: Double(settings.usageWarnPercent))
    }
    private var earlyRunOut: Date? {
        guard !stale, let pace else { return nil }
        return UsagePace.runsOutEarly(pace, window: window)
    }

    /// The compact row shows no remaining share for a stale reading — a dash, never a gauge
    /// number; a reset-passed window drops its number in every mode.
    private var shownLeft: Int? {
        display == .resetSinceRead || (compact && stale) ? nil : left
    }
    /// Estimated run-out in the full localized form, for help and accessibility.
    private var runOutText: String? {
        earlyRunOut.map {
            $0.timeIntervalSince(now) < 60 ? L10n.t(.usageRunsOutSoon)
                : L10n.t(.usageRunsOut, UsageText.countdown(to: $0, from: now))
        }
    }

    /// Reset column text: ALWAYS the real reset time (compact form in the menu, the readable one
    /// in the main window), so the column keeps one width and the bars line up. A stale row
    /// never shows a countdown — a dash here, its age in `note`.
    private var trailingText: String {
        guard !stale, let resetsAt = window.resetsAt else { return "—" }
        return compact ? UsageText.compactCountdown(to: resetsAt, from: now)
                       : UsageText.countdown(to: resetsAt, from: now)
    }

    /// What doesn't fit a fixed column, shown on its own line outside the menu: why a stale
    /// number is stale, or the estimated run-out (the menu keeps that on the marker alone).
    private var note: String? {
        if display == .resetSinceRead { return L10n.t(.usageResetSinceRead) }
        if stale { return UsageText.updatedAgo(readAt: usage.readAt, now: now) }
        return runOutText
    }

    /// The detail's reset line: the full sentence, then the note.
    private var stackedCaption: String? {
        let reset = stale ? nil : window.resetsAt.map {
            $0.timeIntervalSince(now) < 60 ? L10n.t(.usageRefreshingSoon)
                : L10n.t(.usageResetsIn, UsageText.countdown(to: $0, from: now))
        }
        let parts = [reset, note].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Warning/exhausted marker so the state never rides on color alone; nil when fine or stale.
    private var statusIcon: (name: String, label: String)? {
        guard !stale else { return nil }
        if window.usedPercent >= 100 { return ("xmark.octagon.fill", L10n.t(.usageExhaustedA11y)) }
        if window.usedPercent >= Double(settings.usageWarnPercent) {
            return ("exclamationmark.triangle.fill", L10n.t(.usageWarnA11y))
        }
        return nil
    }

    /// Marker before the percentage: the compact stale clock, else exhausted/warning, else the
    /// early run-out warning — a state is never told by the bar's color or the note's text alone.
    private var marker: (name: String, tint: Color)? {
        if stale { return compact ? ("clock", Theme.inkMuted) : nil }
        if let statusIcon { return (statusIcon.name, color) }
        if earlyRunOut != nil { return ("exclamationmark.triangle.fill", Theme.usageWarn) }
        return nil
    }

    /// Full-length reading for help and VoiceOver: full window name (kind + scope), remaining
    /// share, then either the stale state with its age, or status, the FULL localized reset and
    /// the separately labeled early run-out estimate.
    private var accessibilitySummary: String {
        let value = shownLeft.map { L10n.t(.usageLeft, $0) } ?? "—"
        var parts: [String?] = [UsageText.name(of: window), value]
        switch display {
        case .resetSinceRead:
            parts += [L10n.t(.usageResetSinceRead),
                      UsageText.updatedAgo(readAt: usage.readAt, now: now)]
        case .lastKnown where usage.state != .ok:
            parts += [L10n.t(.usageLastKnownA11y),
                      UsageText.updatedAgo(readAt: usage.readAt, now: now),
                      UsageText.reason(for: usage)]
        case .current:
            let reset = window.resetsAt.map { UsageText.countdown(to: $0, from: now) }
            parts += [statusIcon?.label,
                      reset.flatMap { $0 == "—" ? nil : L10n.t(.usageResetsIn, $0) },
                      runOutText,]
            return parts.compactMap { $0 }.joined(separator: ", ")
        default:
            parts += [L10n.t(.usageStaleA11y), UsageText.updatedAgo(readAt: usage.readAt, now: now)]
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// Gemini metric scopes like `gemini-2.5-pro [input]` are unreadably long —
    /// label them `IN <model>`/`OUT <model>` by stripping the exact bracketed
    /// metric suffix and only the leading `gemini-` vendor prefix, preserving all
    /// remaining model/version text. Any other provider/shape uses the full name.
    private var windowLabel: String {
        let fallback = compact
            ? (window.scope ?? UsageText.name(of: window, scoped: false))
            : UsageText.name(of: window)
        guard usage.provider == .gemini, let scope = window.scope else { return fallback }
        for (suffix, tag) in [(" [input]", "IN"), (" [output]", "OUT")] where scope.hasSuffix(suffix) {
            var stem = String(scope.dropLast(suffix.count))
            if stem.hasPrefix("gemini-") { stem.removeFirst("gemini-".count) }
            let trimmed = stem.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? fallback : "\(tag) \(trimmed)"
        }
        return fallback
    }

    /// Reading order is the same in every layout: name, bar, marker + remaining share, reset.
    var body: some View {
        Group {
            if stacked { stackedRow } else { listRow }
        }
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .contextMenu {
            let key = UsagePriority.key(usage, window)
            let isPinned = settings.usagePins.contains(key)
            Button(isPinned ? L10n.t(.usageUnpin) : L10n.t(.usagePin)) { AppModel.usage.togglePin(key) }
        }
    }

    /// Width of the name column outside the menu; the note below the row lines up with the bar.
    private static let wideNameWidth: CGFloat = 168
    /// Fits the longest localized countdown ("11日 23時間") without scaling.
    private static let wideResetWidth: CGFloat = 88

    /// One line: name 84 (compact: scope only, else the unscoped kind) · bar ≤88 (flexible in
    /// the main window) · marker + percent 58 · reset 52 (88 in the main window), 8pt gaps; the
    /// compact cells flex so percent and reset sit on the row's right edge. Every column is a
    /// fixed width, so bars and numbers align down the list.
    private var listRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                nameLabel.frame(width: compact ? 84 : Self.wideNameWidth, alignment: .leading)
                bar.frame(maxWidth: compact ? 88 : .infinity)
                if compact { Spacer(minLength: 0) }
                percent.frame(width: 58, alignment: .trailing)
                Text(trailingText).font(Theme.small.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: compact ? 52 : Self.wideResetWidth, alignment: .trailing)
            }
            if !compact, let note {
                Text(note).font(Theme.small).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.wideNameWidth + 8)
            }
        }
    }

    /// The detail's two-line limit: name and remaining share, a full-width bar, the reset sentence.
    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nameLabel
                Spacer(minLength: 8)
                percent
            }
            bar
            if let stackedCaption {
                Text(stackedCaption).font(Theme.small).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameLabel: some View {
        Text(windowLabel)
            .font(.system(size: 12)).foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
            .lineLimit(1).truncationMode(.tail)
            .minimumScaleFactor(usage.provider == .gemini ? 0.8 : (compact ? 0.85 : 1))
    }

    /// The track is always neutral, so an empty bar reads as empty — never as a pale full one.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.usageTrack)
                Capsule().fill(color)
                    .frame(width: proxy.size.width * CGFloat(shownLeft ?? 0) / 100)
            }
        }
        .frame(height: 6)
    }

    private var percent: some View {
        HStack(spacing: 3) {
            if let marker {
                Image(systemName: marker.name).font(.system(size: 10))
                    .foregroundStyle(marker.tint)
            }
            Text(shownLeft.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
        }
    }
}

/// Refresh button: a system progress indicator while a read is in flight, disabled meanwhile.
private struct UsageRefreshButton: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Button { model.refresh() } label: {
            // A ProgressView instead of a repeatForever rotation: endless value animations
            // are not reliably cancelled by assigning the model value back.
            Group {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshing)
        .help(L10n.t(.usageRefreshHelp))
        .accessibilityLabel(L10n.t(.uiRefresh))
    }
}
