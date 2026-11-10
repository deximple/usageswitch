import Testing
@testable import SwitcherCore

@Suite("Account name validation")
struct AccountNamesTests {
    @Test("invisible and tag characters are rejected")
    func forbiddenCharacters() {
        for scalar: String in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
                               "\u{2060}", "\u{FEFF}", "\u{061C}", "\u{E0001}", "\u{E007F}"] {
            #expect(throws: SwitcherError.self) { try AccountNames.validated("a\(scalar)b") }
        }
        #expect(throws: Never.self) { try AccountNames.validated("plain name") }
        #expect(throws: Never.self) { try AccountNames.validated("👩‍💻 Work") }
        #expect(throws: SwitcherError.self) { try AccountNames.validated("a\u{200D}b") }
        #expect(throws: SwitcherError.self) { try AccountNames.validated("#\u{200D}1") }
        #expect(throws: SwitcherError.self) { try AccountNames.validated("x\u{200D}") }
    }

    @Test("NFKC runs before folding: lookalike encodings collide")
    func nfkcBeforeUniqueness() throws {
        // Full-width 'A' normalizes to 'A'; a decomposed é folds with precomposed.
        #expect(SwitcherAccount.fold("\u{FF21}b") == SwitcherAccount.fold("Ab"))
        #expect(SwitcherAccount.fold("cafe\u{0301}") == SwitcherAccount.fold("café"))
        let stored = try AccountNames.validated("\u{FF21}b")
        #expect(stored == "Ab")
    }
}
