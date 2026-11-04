import SwiftUI
import SwitcherCore

/// Gauge colors: room to run, nearly out, empty; stale is always grey.
enum UsageColors {
    static func forWindow(_ window: UsageWindow, stale: Bool) -> Color {
        if stale { return Theme.missing }
        if window.usedPercent >= 100 { return Theme.danger }
        return window.usedPercent >= 80 ? Theme.usageLow : Theme.usageNormal
    }
}

/// The Usage tab, shared by the main window and the menu (`compact`). Countdowns and the footer's
/// "next update" line re-render every 30 s via the TimelineView.
struct UsageContent: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: SwitcherModel
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: compact ? Theme.gapRow : Theme.gapGroup) {
                // macOS's NSSegmentedControl won't stretch, so the full-width pill is drawn by hand.
                UsageSegmentPicker(segment: $model.segment)
                switch model.segment {
                case .priority: priority(now: context.date)
                case .all: allUsage(now: context.date)
                }
                footer(now: context.date)
            }
        }
    }

    // MARK: - Priority

    @ViewBuilder
    private func priority(now: Date) -> some View {
        let sections = UsagePriority.sections(model.usages, pins: model.pins, now: now)
        if sections.pinned.isEmpty && sections.runningOut.isEmpty && sections.usedUp.isEmpty {
            VStack(alignment: .leading, spacing: Theme.gapTight) {
                Text(L10n.t(.usageEmptyRoom)).font(Theme.body).foregroundStyle(Theme.inkMuted)
                Text(L10n.t(.usageEmptyHint)).font(Theme.caption).foregroundStyle(Theme.inkMuted.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: Theme.gapRow) {
                if !sections.pinned.isEmpty { section(L10n.t(.usageSecPinned), rows: sections.pinned, now: now) }
                if !sections.runningOut.isEmpty { section(L10n.t(.usageSecRunningOut), rows: sections.runningOut, now: now) }
                if !sections.usedUp.isEmpty { section(L10n.t(.usageSecUsedUp), rows: sections.usedUp, now: now, usedUp: true) }
            }
        }
    }

    private func section(_ title: String, rows: [UsagePriority.Row], now: Date, usedUp: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            Text(title).font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
            ForEach(rows, id: \.key) { row in
                PriorityRow(row: row, settings: settings, now: now, usedUp: usedUp)
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
                    HStack {
                        Text(UsageText.providerName(provider))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: UsageText.providerGlyph(provider))
                            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    }
                    VStack(alignment: .leading, spacing: Theme.gapRow) {
                        ForEach(usages) { usage in allUsageCard(usage, now: now) }
                    }
                }
            }
        }
    }

    private func allUsageCard(_ usage: AccountUsage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.label(of: usage)).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let plan = UsageText.planName(usage.plan) {
                    Chip(text: plan, color: Theme.inkMuted)
                }
            }
            ForEach(usage.windows, id: \.self) { window in
                UsageBarRow(usage: usage, window: window, settings: settings, now: now, compact: compact)
            }
            if let reason = UsageText.reason(usage.state, provider: usage.provider) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(usage.state == .ok ? Theme.inkMuted
                        : isFailure(usage.state) ? Theme.danger : Theme.inkMuted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func isFailure(_ state: UsageState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Footer

    private func footer(now: Date) -> some View {
        HStack {
            Text(L10n.t(.usageNextUpdate, UsageText.countdown(to: model.nextRefresh, from: now)))
                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
            Spacer()
            UsageRefreshButton(model: model)
        }
    }
}

/// Full-width Priority | All Usage pill: two equal halves, the selected one raised.
private struct UsageSegmentPicker: View {
    @Binding var segment: UsageModel.Segment

    var body: some View {
        HStack(spacing: 2) {
            button(.priority, L10n.t(.usageSegPriority))
            button(.all, L10n.t(.usageSegAll))
        }
        .padding(2)
        .background(Capsule().fill(Theme.inkMuted.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func button(_ value: UsageModel.Segment, _ label: String) -> some View {
        Button { segment = value } label: {
            Text(label)
                .font(.system(size: 12, weight: segment == value ? .semibold : .regular))
                .foregroundStyle(segment == value ? Theme.ink : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(segment == value ? Theme.surface : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(segment == value ? .isSelected : [])
    }
}

/// The ring: track circle plus an arc showing the share LEFT, provider glyph inside.
struct RingGauge: View {
    let percentUsed: Double
    let color: Color
    let glyph: String

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(1, (100 - percentUsed) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: glyph).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

/// One Priority row: ring gauge, window name + account label, "% left" and the reset countdown.
struct PriorityRow: View {
    let row: UsagePriority.Row
    @ObservedObject var settings: SwitcherModel
    let now: Date
    var usedUp = false

    private var window: UsageWindow { row.window }
    /// Kept windows from a failed re-read render stale, like ones whose reset passed.
    private var stale: Bool { window.isStale(now: now) || row.usage.state != .ok }
    private var color: Color { UsageColors.forWindow(window, stale: stale) }

    private var countdown: some View {
        Text(trailingText)
            .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
    }

    private var trailingText: String {
        if stale { return UsageText.updatedAgo(readAt: row.usage.readAt, now: now) }
        return window.resetsAt.map { UsageText.countdown(to: $0, from: now) } ?? "—"
    }

    @ViewBuilder
    private var pinMenu: some View {
        let pinned = settings.usagePins.contains(row.key)
        Button(pinned ? L10n.t(.usageUnpin) : L10n.t(.usagePin)) { AppModel.usage.togglePin(row.key) }
    }

    var body: some View {
        if usedUp {
            // Used Up is one dimmed line: no ring, no percent.
            HStack(spacing: 10) {
                Image(systemName: UsageText.providerGlyph(row.usage.provider))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 30)
                Text(UsageText.name(of: window))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                Text(UsageText.accountLabel(row.usage, showEmails: settings.showEmails))
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                countdown
            }
            .contextMenu { pinMenu }
        } else {
            HStack(spacing: 10) {
                RingGauge(percentUsed: window.usedPercent, color: color,
                          glyph: UsageText.providerGlyph(row.usage.provider))
                VStack(alignment: .leading, spacing: 2) {
                    Text(UsageText.name(of: window))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                    Text(UsageText.accountLabel(row.usage, showEmails: settings.showEmails))
                        .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageText.left(window))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                    countdown
                }
            }
            .contextMenu { pinMenu }
        }
    }
}

/// One window inside an All Usage card: name, capsule bar (% USED), percent and countdown.
struct UsageBarRow: View {
    let usage: AccountUsage
    let window: UsageWindow
    @ObservedObject var settings: SwitcherModel
    let now: Date
    var compact = false

    /// Kept windows from a failed re-read render stale, like ones whose reset passed.
    private var stale: Bool { window.isStale(now: now) || usage.state != .ok }
    private var color: Color { UsageColors.forWindow(window, stale: stale) }

    private var trailingText: String {
        if stale { return UsageText.updatedAgo(readAt: usage.readAt, now: now) }
        return window.resetsAt.map { UsageText.countdown(to: $0, from: now) } ?? "—"
    }

    /// Fixed-width columns so every bar starts at the same x, across rows and cards.
    var body: some View {
        HStack(spacing: 8) {
            Text(UsageText.name(of: window))
                .font(.system(size: 12)).foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: compact ? 104 : 128, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.25))
                Capsule().fill(color)
                    .frame(width: 70 * max(0, min(1, window.usedPercent / 100)))
            }
            .frame(width: 70, height: 6)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(stale ? Theme.inkMuted : Theme.ink)
                .frame(width: 40, alignment: .trailing)
            Spacer(minLength: 4)
            Text(trailingText).font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        }
        .contextMenu {
            let key = UsagePriority.key(usage, window)
            let pinned = settings.usagePins.contains(key)
            Button(pinned ? L10n.t(.usageUnpin) : L10n.t(.usagePin)) { AppModel.usage.togglePin(key) }
        }
    }
}

/// Refresh button: spins while a read is in flight, disabled meanwhile.
private struct UsageRefreshButton: View {
    @ObservedObject var model: UsageModel
    @State private var turns = 0.0

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
            if refreshing {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turns += 360 }
            } else {
                turns = turns.truncatingRemainder(dividingBy: 360)
            }
        }
    }
}
