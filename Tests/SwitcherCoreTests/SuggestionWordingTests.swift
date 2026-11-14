import Testing
@testable import SwitcherCore

@Suite("Suggestion wording")
struct SuggestionWordingTests {
    private let suggestionKeys: [L10nKey] = [
        .suggestionAvailable, .suggestionModeLabel, .suggestionModeSaver,
        .suggestionModeBalanced, .suggestionModeFocus, .suggestionModeUrgent,
        .suggestionTaskLabel, .suggestionTaskSimple, .suggestionTaskReasoning,
        .suggestionUrgentTitle, .suggestionUrgentMessage, .suggestionUrgentConfirm,
        .suggestionSituationHeadroom, .suggestionSituationRemaining, .suggestionHeadline,
        .suggestionEffortNone, .suggestionEffortMinimal, .suggestionEffortLow,
        .suggestionEffortMedium, .suggestionEffortHigh, .suggestionEffortXHigh,
        .suggestionEffortMax, .suggestionEffortUnspecified,
        .suggestionHeadlineNeutral, .suggestionBasisTitle, .suggestionBasisOption,
        .suggestionBasisLeftOut, .suggestionBasisNote, .suggestionLeftOutWarn,
        .suggestionLeftOutPace, .suggestionLeftOutStale, .suggestionNoneExcluded,
        .suggestionFreesFirst, .suggestionNoneNoFit,
        .suggestionSituationExpiring, .suggestionBudget, .suggestionOutlookRecent,
        .suggestionOutlookAverage, .suggestionLighter, .suggestionOtherTool,
    ]

    @Test(arguments: AppLanguage.allCases)
    func suggestionCopyAvoidsJudgment(language: AppLanguage) {
        let banned = ["틀렸", "과하게", "wrong", "too much"]
        let table = L10n.table(for: language)
        for key in suggestionKeys {
            guard let text = table[key] else {
                Issue.record("\(language.rawValue): missing \(key.rawValue)")
                continue
            }
            let normalized = text.lowercased()
            for phrase in banned {
                #expect(!normalized.contains(phrase),
                        "\(language.rawValue) \(key.rawValue) contains \(phrase)")
            }
        }
    }
}
