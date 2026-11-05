import AppKit
import SwiftUI
import SwitcherCore

/// Gauge colors: room to run, nearly out, empty; stale is always grey.
enum UsageColors {
    static func forWindow(_ window: UsageWindow, stale: Bool, warnAt: Double = 80) -> Color {
        if stale { return Theme.missing }
        if window.usedPercent >= 100 { return Theme.danger }
        return window.usedPercent >= warnAt ? Theme.usageLow : Theme.usageNormal
    }
}

/// The native Guide / All Usage switch, kept OUT of the scrolling body in both hosts so it
/// stays reachable no matter how long the account list grows.
struct UsageSegmentPicker: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Picker(L10n.t(.usageSegPicker), selection: $model.segment) {
            Text(L10n.t(.usageSegGuide)).tag(UsageModel.Segment.guide)
            Text(L10n.t(.usageSegAll)).tag(UsageModel.Segment.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(L10n.t(.usageSegPicker))
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
/// conservative next-account candidate with its comparison folded away; All lists every
/// account plainly by provider. The picker and footer live outside this scrollable body.
struct UsageContent: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: SwitcherModel
    @ObservedObject var codex: CodexModel
    @ObservedObject var tabs: TabSelection
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            switch model.segment {
            case .guide: guide(now: context.date)
            case .all: allUsage(now: context.date)
            }
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
        case .cursor: return nil
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
                if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                    items.append(("\(usage.id)/state", "\(label) — \(reason)", true))
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
                        HStack {
                            Text(UsageText.name(of: window)).font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Text(UsageText.left(window)).font(.system(size: 12))
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                } else if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                }
                HStack {
                    Spacer()
                    Button(L10n.t(.usageViewAll)) { model.segment = .all }
                        .buttonStyle(ActionButtonStyle(tint: Theme.inkMuted, prominent: false))
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
                if !usage.windows.isEmpty {
                    Text(L10n.t(.usageRemaining)).font(.system(size: 10))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            billing(of: usage)
            ForEach(usage.windows, id: \.self) { window in
                UsageBarRow(usage: usage, window: window, settings: settings, now: now,
                            compact: compact, fresh: fresh(usage, now: now),
                            pinned: model.pins.contains(UsagePriority.key(usage, window)),
                            pace: model.pace[UsagePriority.key(usage, window)])
            }
            if usage.authentication == .apiKey {
                Link(L10n.t(.usageBillingConsole), destination: Self.billingURL(for: usage.provider))
                    .font(.system(size: 11)).foregroundStyle(Theme.active)
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
    static func billingURL(for provider: UsageProvider) -> URL {
        switch provider {
        case .codex: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
        case .claude: return URL(string: "https://platform.claude.com/settings/billing")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        }
    }

    private func isFailure(_ state: UsageState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// One window under an account: pin column, name, a remaining-share bar, the remaining %,
/// reset or freshness, and the pin affordance. The bar and its number both show what is
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
    var pinned = false
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

    private var trailingText: String {
        if stale { return UsageText.updatedAgo(readAt: usage.readAt, now: now) }
        if let earlyRunOut {
            return L10n.t(.usageRunsOut, UsageText.countdown(to: earlyRunOut, from: now))
        }
        return window.resetsAt.map { UsageText.countdown(to: $0, from: now) } ?? "—"
    }

    /// Fixed-width columns so every bar starts at the same x — the pin column is reserved
    /// on every row so a pin never shifts alignment.
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.inkMuted)
                }
            }
            .frame(width: 10)
            Text(UsageText.name(of: window))
                .font(.system(size: 12)).foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: compact ? 104 : 128, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.25))
                Capsule().fill(color)
                    .frame(width: 70 * CGFloat(left ?? 0) / 100)
            }
            .frame(width: 70, height: 6)
            Text(left.map { "\($0)%" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                .frame(width: 40, alignment: .trailing)
            Spacer(minLength: 4)
            Text(trailingText).font(.system(size: 11))
                .foregroundStyle(earlyRunOut != nil ? Theme.usageLow : Theme.inkMuted)
        }
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
