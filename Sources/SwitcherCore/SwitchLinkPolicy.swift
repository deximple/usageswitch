/// What to do with a `usageswitch://switch?id=…` link (audit B-04). A pure function so the app
/// target only polls the state; the table is the spec's: a link that arrives while the app is
/// still coming up waits, one that arrives mid-action reports busy, anything unknown stays silent.
public enum SwitchLinkPolicy {
    public enum Decision: Sendable, Equatable {
        case ignore, wait, busy
        case confirm(id: String, force: Bool)
    }

    public static func decide(isDemo: Bool, recovering: Bool, hasStatus: Bool, working: Bool,
                              hasPending: Bool, renaming: Bool, knownIDs: Set<String>,
                              id: String, force: Bool) -> Decision {
        if isDemo { return .ignore }
        if recovering || !hasStatus { return .wait }
        if working || hasPending || renaming { return .busy }
        if !force && !knownIDs.contains(id) { return .ignore }
        return .confirm(id: id, force: force)
    }
}
