import AppKit
import SwiftUI
import SwitcherCore

/// Gauge colors: room to run, nearly out, empty; stale is always grey.
enum UsageColors {
    static func forWindow(_ window: UsageWindow, stale: Bool, warnAt: Double = 80) -> Color {
        if stale { return Theme.missing }
        if window.usedPercent >= 100 { return Theme.danger }
        return window.usedPercent >= warnAt ? Theme.usageLow : Theme.inkMuted
    }
}

/// List title plus the Guide disclosure, kept OUT of the scrolling body in both hosts so the
/// control stays reachable no matter how long the account list grows.
struct UsageListHeader: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        HStack {
            Text(L10n.t(.usageListTitle))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button {
                model.guideExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.t(.usageSegGuide))
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
            .accessibilityLabel(L10n.t(.usageSegGuide))
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
                    Text(L10n.t(.usageRefreshing)).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        if let lastRead = model.usages.map(\.readAt).max() {
                            Text(UsageText.updatedAgo(readAt: lastRead, now: context.date))
                                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        }
                        Text(L10n.t(.usageNextUpdate,
                                    UsageText.countdown(to: model.nextRefresh, from: context.date)))
                            .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
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
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: Theme.gapGroup) {
                if model.usages.isEmpty {
                    emptyState
                } else {
                    if model.guideExpanded { guide(now: context.date) }
                    allUsage(now: context.date)
                }
            }
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
        switch usage.provider {
        case .claude: return L10n.t(.usageEnvCLI)
        case .codex: return L10n.t(.usageEnvApp)
        case .cursor, .grok, .gemini, .devin, .opencode: return nil
        }
    }

    /// One billing line per account: subscription name+plan, API key billed elsewhere, or a
    /// bare plan that doesn't guess the auth class. Unknown with no plan shows nothing.
    @ViewBuilder
    private func billing(of usage: AccountUsage) -> some View {
        switch usage.authentication {
        case .subscription:
            Text(UsageText.planName(usage.plan).map { "\(L10n.t(.usageAuthSubscription)) · \($0)" }
                ?? L10n.t(.usageAuthSubscription))
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
        case .apiKey:
            Text(L10n.t(.usageAuthApi)).font(Theme.caption).foregroundStyle(Theme.inkMuted)
        case .unknown:
            if let plan = UsageText.planName(usage.plan) {
                Text("\(L10n.t(.usagePlanLabel)) · \(plan)")
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
            let label = model.label(of: usage)
            switch usage.state {
            case .failed, .unavailable:
                // connectionRequired is a neutral consent prompt, never an orange failure
                let warn: Bool = { if case .unavailable(.connectionRequired) = usage.state { return false }; return true }()
                if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                    items.append(("\(usage.id)/state", "\(label) — \(reason)", warn))
                }
            case .notReporting:
                if let reason = UsageText.reason(usage.state, provider: usage.provider) {
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
        let proposals = UsageGuidance.proposals(model.usages, now: now,
                                                warnAt: Double(settings.usageWarnPercent))
        let items = attention(now: now)
        VStack(alignment: .leading, spacing: Theme.gapRow) {
            if model.usages.isEmpty && model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(L10n.t(.usageRefreshing)).font(Theme.body).foregroundStyle(Theme.inkMuted)
                }
            } else {
                ForEach(items, id: \.id) { item in
                    Text(item.text).font(.system(size: 12))
                        .foregroundStyle(item.warn ? Theme.usageLow : Theme.inkMuted)
                }
                if let proposal = proposals.first,
                   let usage = model.usages.first(where: { $0.id == proposal.usageID }) {
                    proposalBlock(proposal, usage: usage, now: now)
                }
                claudeRow(now: now)
                if proposals.isEmpty && items.isEmpty && claudeUsage == nil {
                    Text(L10n.t(.usageGuideNone)).font(Theme.body).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    /// Small header → account name → billing → limiting window + remaining + reset → action.
    /// No boxes, no badges: the comparison folds away and every percent shown is REMAINING.
    private func proposalBlock(_ proposal: UsageGuidance.Proposal, usage: AccountUsage,
                               now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
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
            Text(model.label(of: usage))
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
                        Text(L10n.t(.usageResetsIn, UsageText.countdown(to: resetsAt, from: now)))
                    } else {
                        Text(L10n.t(.usageRefreshNeeded)).foregroundStyle(Theme.usageLow)
                    }
                }
            }
            .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            HStack {
                Spacer()
                Button(L10n.t(.usageViewAccount)) {
                    tabs.tab = .codex
                    codex.focusedAccountID = usage.accountRef
                }
                .buttonStyle(ActionButtonStyle(tint: Theme.active))
                .disabled(codex.isBusy
                          || !(codex.status?.accounts.contains { $0.id == usage.accountRef } ?? false))
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
                if usage.state == .ok {
                    ForEach(usage.windows.filter { $0.scope == nil }, id: \.self) { window in
                        UsageBarRow(usage: usage, window: window, settings: settings, now: now,
                                    compact: compact, fresh: fresh(usage, now: now),
                                    pace: model.pace[UsagePriority.key(usage, window)])
                    }
                } else if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }

    // MARK: - All Usage

    /// Accounts in collector order (Claude, then Codex, then Cursor), grouped by provider.
    private var providerGroups: [(UsageProvider, [AccountUsage])] {
        var groups: [(UsageProvider, [AccountUsage])] = []
        for usage in model.usages {
            if groups.last?.0 == usage.provider { groups[groups.count - 1].1.append(usage) }
            else { groups.append((usage.provider, [usage])) }
        }
        return groups
    }

    @ViewBuilder
    private func allUsage(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapGroup) {
            ForEach(providerGroups, id: \.0) { provider, usages in
                VStack(alignment: .leading, spacing: Theme.gapTight) {
                    HStack(spacing: 8) {
                        ProviderIcon(provider: provider)
                        Text(UsageText.providerName(provider))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    ForEach(usages) { usage in
                        accountBlock(usage, now: now)
                        if usage.id != usages.last?.id { Divider().overlay(Theme.hairline) }
                    }
                }
            }
        }
    }

    /// One account: label + billing + confirmed environment + plan, then its windows —
    /// remaining share on a plain bar. Non-reporting accounts stay listed; nothing disappears.
    private func accountBlock(_ usage: AccountUsage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.label(of: usage))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let env = environment(of: usage) {
                    Text(env).font(.system(size: 10)).foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 8)
            }
            billing(of: usage)
            ForEach(usage.windows, id: \.self) { window in
                UsageBarRow(usage: usage, window: window, settings: settings, now: now,
                            compact: compact, fresh: fresh(usage, now: now),
                            pace: model.pace[UsagePriority.key(usage, window)])
            }
            if usage.authentication == .apiKey {
                if let url = Self.billingURL(for: usage.provider) {
                    Link(L10n.t(.usageBillingConsole), destination: url)
                        .font(.system(size: 11)).foregroundStyle(Theme.active)
                }
            }
            if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                Text(reason).font(.system(size: 11))
                    .foregroundStyle(usage.state == .ok || usage.state == .notReporting
                        ? Theme.inkMuted
                        : isFailure(usage.state) ? Theme.danger : Theme.inkMuted)
            }
        }
    }

    /// The provider's own billing console — the only place a balance claim can be verified.
    /// nil for providers that have no self-serve billing page.
    static func billingURL(for provider: UsageProvider) -> URL? {
        switch provider {
        case .codex: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
        case .claude: return URL(string: "https://platform.claude.com/settings/billing")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .grok, .gemini, .devin, .opencode:
            return nil
        }
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
    /// Whether the account's own read is fresh; an old or future timestamp greys the row
    /// just like an elapsed reset does.
    var fresh = true
    /// Drain speed for this window, when two readings line up.
    var pace: UsagePace.Reading?

    /// Remaining 0…100, nil for a reading that isn't a real non-negative number.
    private var left: Int? { UsageText.percentLeft(window.usedPercent) }
    /// Kept windows from a failed re-read render stale, like ones whose reset passed —
    /// and so does a percent that can't be a real share.
    private var stale: Bool {
        !fresh || window.isStale(now: now) || usage.state != .ok || left == nil
    }
    private var color: Color {
        UsageColors.forWindow(window, stale: stale, warnAt: Double(settings.usageWarnPercent))
    }
    private var earlyRunOut: Date? {
        guard !stale, let pace else { return nil }
        return UsagePace.runsOutEarly(pace, window: window)
    }

    /// The compact row shows no remaining share for a stale reading — a dash, never a gauge number.
    private var shownLeft: Int? { compact && stale ? nil : left }
    /// Estimated run-out in the full localized form, for help and accessibility.
    private var runOutText: String? {
        earlyRunOut.map { L10n.t(.usageRunsOut, UsageText.countdown(to: $0, from: now)) }
    }

    /// Reset column text. The menu gets the compact form and ALWAYS the real reset time — the
    /// estimated run-out lives on the marker icon; the main window keeps the full readable
    /// one. A stale row never shows a countdown — its age is the label (compact: a dash).
    private var trailingText: String {
        if stale { return compact ? "—" : UsageText.updatedAgo(readAt: usage.readAt, now: now) }
        if compact {
            return window.resetsAt.map { UsageText.compactCountdown(to: $0, from: now) } ?? "—"
        }
        if let runOutText { return runOutText }
        guard let resetsAt = window.resetsAt else { return "—" }
        return UsageText.countdown(to: resetsAt, from: now)
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

    /// Marker before the percentage: the compact stale clock, else exhausted/warning, else (compact
    /// only) the early run-out warning — the estimate never rides in the reset column.
    private var marker: (name: String, tint: Color)? {
        if stale { return compact ? ("clock", Theme.inkMuted) : nil }
        if let statusIcon { return (statusIcon.name, color) }
        if compact, earlyRunOut != nil { return ("exclamationmark.triangle.fill", Theme.usageLow) }
        return nil
    }

    /// Full-length reading for help and VoiceOver: full window name (kind + scope), remaining
    /// share, then either the stale state with its age, or status, the FULL localized reset and
    /// the separately labeled early run-out estimate.
    private var accessibilitySummary: String {
        let value = shownLeft.map { L10n.t(.usageLeft, $0) } ?? "—"
        var parts: [String?] = [UsageText.name(of: window), value]
        if stale {
            parts += [L10n.t(.usageStaleA11y), UsageText.updatedAgo(readAt: usage.readAt, now: now)]
        } else {
            let reset = window.resetsAt.map { UsageText.countdown(to: $0, from: now) }
            parts += [statusIcon?.label,
                      reset.flatMap { $0 == "—" ? nil : L10n.t(.usageResetsIn, $0) },
                      runOutText,]
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// One line: name 60 (compact: scope only, else the unscoped kind) · bar ≤88 (flexible in
    /// the main window) · marker + percent 58 · reset 52 (full text in the main window), 8pt
    /// gaps; the compact cells flex so percent and reset sit on the row's right edge.
    var body: some View {
        HStack(spacing: 8) {
            Text(compact ? (window.scope ?? UsageText.name(of: window, scoped: false))
                         : UsageText.name(of: window))
                .font(.system(size: 12)).foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: compact ? 60 : 96, alignment: .leading)
            ZStack(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(color.opacity(0.25))
                    Capsule().fill(color)
                        .frame(width: proxy.size.width * CGFloat(shownLeft ?? 0) / 100)
                }
            }
            .frame(maxWidth: compact ? 88 : .infinity)
            .frame(height: 6)
            if compact { Spacer(minLength: 0) }
            HStack(spacing: 3) {
                if let marker {
                    Image(systemName: marker.name).font(.system(size: 10))
                        .foregroundStyle(marker.tint)
                }
                Text(shownLeft.map { "\($0)%" } ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
            }
            .frame(width: 58, alignment: .trailing)
            Text(trailingText).font(.system(size: 11).monospacedDigit())
                .foregroundStyle(!compact && earlyRunOut != nil ? Theme.usageLow : Theme.inkMuted)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: compact ? 52 : nil, alignment: .trailing)
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
}

/// Refresh button: spins while a read is in flight, disabled meanwhile; honors Reduce Motion.
private struct UsageRefreshButton: View {
    @ObservedObject var model: UsageModel
    @State private var turns = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { model.refresh() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .rotationEffect(.degrees(turns))
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshing)
        .help(L10n.t(.usageRefreshHelp))
        .accessibilityLabel(L10n.t(.uiRefresh))
        .onChange(of: model.isRefreshing) { _, refreshing in
            if refreshing, !reduceMotion {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turns += 360 }
            } else {
                turns = turns.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}
