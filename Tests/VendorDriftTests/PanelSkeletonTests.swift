import Testing
@testable import VendorDrift

@Suite("Panel skeleton")
struct PanelSkeletonTests {
    @Test("window lines keep their shape and lose every value")
    func windowLines() {
        let shape = PanelSkeleton.shape(of: Sample.claudePanel)
        #expect(shape.windowLines == [
            "Current session: N% used · resets N:Npm (Zone)",
            "Current week (all models): N% used · resets Mon N at N:Npm (Zone)",
            "Current week (…): N% used · resets Mon N at N:Npm (Zone)",
        ])
        #expect(!shape.mentionsUsedOutsideWindows)
    }

    @Test("the known scopes stay; a UTC zone is a zone")
    func knownScopes() {
        #expect(PanelSkeleton.redacted("Current week (Sonnet only): 100% used · resets Jan 31 at 9am (UTC)")
            == "Current week (Sonnet only): N% used · resets Mon N at Nam (Zone)")
    }

    @Test("a line nobody has seen before shows its shape and none of its words")
    func unknownLine() {
        #expect(PanelSkeleton.redacted("Current plan: Acme Corp team (acme-internal) until 2027-01-31")
            == "Current …: … … … (…) … N-N-N")
        #expect(PanelSkeleton.redacted("Current week: 75% used, resets soon") == "Current week: N% used, resets …")
    }

    @Test("words and digits in any script are taken out, not only ASCII ones")
    func otherScripts() {
        #expect(PanelSkeleton.redacted("Current 프로젝트 plan: 홍길동 5% used · José Ünïcode ４２ x²")
            == "Current … …: … N% used · … … N …N")
        #expect(PanelSkeleton.redacted("Current week (홍길동의 팀): 5% used") == "Current week (…): N% used")
    }

    @Test("usage reported outside the window lines is noticed, without being shown")
    func usageOutsideWindows() {
        let shape = PanelSkeleton.shape(of: "Weekly limit: 40% used\nSession limit: 3% used\n\n")
        #expect(shape.windowLines.isEmpty)
        #expect(shape.mentionsUsedOutsideWindows)
        #expect(PanelSkeleton.shape(of: "") == PanelSkeleton.Shape(windowLines: [], mentionsUsedOutsideWindows: false))
    }
}
