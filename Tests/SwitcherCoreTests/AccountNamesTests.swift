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
        // Variation selectors and skin tones inside an emoji ZWJ sequence are part of the emoji.
        for name in ["\u{2764}\u{FE0F}\u{200D}\u{1F525} Fire", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308} Pride",
                     "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} Dev"] {
            #expect(throws: Never.self) { try AccountNames.validated(name) }
        }
        // A joiner after a lone variation selector is still refused.
        #expect(throws: SwitcherError.self) { try AccountNames.validated("a\u{FE0F}\u{200D}b") }
        // The length limit applies after NFKC: 20 × "ﬃ" becomes 60 characters.
        #expect(throws: SwitcherError.self) { try AccountNames.validated(String(repeating: "\u{FB03}", count: 20)) }
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
