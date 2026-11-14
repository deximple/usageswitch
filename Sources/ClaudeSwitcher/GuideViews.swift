import SwiftUI
import SwitcherCore

/// Limits on course to empty before they reset, one line each. A measured pace carries the
/// warning tint the bar rows use for it; a window's own average stays neutral — it is an
/// estimate from one reading, not a slope.
struct GuideOutlookView: View {
    let lines: [SuggestionText.OutlookLine]

    var body: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.text).font(.system(size: 12))
                .foregroundStyle(line.basis == .recentPace ? Theme.usageLow : Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Guide's "why": the lines for a missing pick, then the folded comparison — every weighed
/// account in rank order and every account left out with the limit in its way. Text only;
/// nothing here switches, opens or signs in.
struct GuideBasisView: View {
    let explanation: SuggestionText.Explanation
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapTight) {
            ForEach(Array(explanation.empty.enumerated()), id: \.offset) { index, line in
                Text(line).font(.system(size: index == 0 ? 13 : 12))
                    .foregroundStyle(index == 0 ? Theme.ink : Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !explanation.compared.isEmpty || !explanation.leftOut.isEmpty {
                // With no pick there is no suggestion to explain — the fold is just the left-out list.
                DisclosureGroup(L10n.t(explanation.compared.isEmpty ? .suggestionBasisLeftOut
                                                                    : .suggestionBasisTitle),
                                isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: Theme.gapTight) {
                        ForEach(Array(explanation.compared.enumerated()), id: \.offset) { index, line in
                            row(Text("\(index + 1). ").monospacedDigit() + Text(line),
                                tint: index == 0 ? Theme.ink : Theme.inkMuted)
                        }
                        if !explanation.leftOut.isEmpty {
                            if !explanation.compared.isEmpty {
                                Text(L10n.t(.suggestionBasisLeftOut))
                                    .font(Theme.eyebrow).foregroundStyle(Theme.inkMuted)
                                    .padding(.top, Theme.gapTight)
                            }
                            ForEach(Array(explanation.leftOut.enumerated()), id: \.offset) { _, text in
                                row(Text(text), tint: Theme.inkMuted)
                            }
                        }
                        if !explanation.compared.isEmpty {
                            row(Text(L10n.t(.suggestionBasisNote)), tint: Theme.inkMuted)
                                .padding(.top, Theme.gapTight)
                        }
                    }
                    .padding(.top, Theme.gapTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.caption).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func row(_ text: Text, tint: Color) -> some View {
        text.font(Theme.caption).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
