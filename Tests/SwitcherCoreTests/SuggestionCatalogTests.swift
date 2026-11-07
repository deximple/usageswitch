import Foundation
import Testing
@testable import SwitcherCore

@Suite("Suggestion catalog contract")
struct SuggestionCatalogTests {
    private let date = "2026-11-07"

    private func facts(version: Int = 1, efforts: String = #"["low","high"]"#,
                       source: String = "https://vendor.example.invalid/models",
                       checkedAt: String = "2026-11-07",
                       extraValues: String = "", duplicate: Bool = false) -> Data {
        let model = """
        {"vendorId":"openai","model":"test-model","name":"Test Model","efforts":\(efforts),"values":[
          {"id":"openai/test-model/inputPricePerMTok","code":"inputPricePerMTok",
           "number":4,"text":null,"source":"\(source)","checkedAt":"\(checkedAt)"}\(extraValues)]}
        """
        return Data("""
        {"version":\(version),"date":"\(date)","models":[\(model)\(duplicate ? ",\(model)" : "")]}
        """.utf8)
    }

    private func tiers(version: Int = 1, factsDate: String = "2026-11-07",
                       key: String = "openai/test-model", effort: String = "high",
                       rank: String = #"{"simpleCoding":4,"reasoning":1}"#,
                       evidence: String? = nil, duplicate: Bool = false) -> Data {
        let evidence = evidence ?? """
        [{"kind":"benchmark","source":"https://benchmark.example.invalid/models","checkedAt":"\(date)"}]
        """
        let entry = """
        {"key":"\(key)","effort":"\(effort)","tier":"frontier","rank":\(rank),"evidence":\(evidence)}
        """
        return Data("""
        {"version":\(version),"date":"\(date)","factsDate":"\(factsDate)",
         "axis":["simpleCoding","reasoning"],"entries":[\(entry)\(duplicate ? ",\(entry)" : "")]}
        """.utf8)
    }

    @Test("maker, fact, effort, evidence and ranks are preserved without scoring")
    func valid() throws {
        let catalog = try SuggestionCatalog(facts: facts(), tiers: tiers())
        #expect(catalog.factsDate == date && catalog.tiersDate == date)
        #expect(catalog.axes == ["simpleCoding", "reasoning"])
        let model = try #require(catalog.models.first)
        #expect(model.key == "openai/test-model")
        #expect(model.vendorId == "openai")
        #expect(model.efforts == ["low", "high"])
        #expect(model.values.first?.number == 4)
        let entry = try #require(catalog.entries.first)
        #expect(entry.key == model.key && entry.effort == "high")
        #expect(entry.tier.rawValue == "frontier")
        #expect(entry.rank == ["simpleCoding": 4, "reasoning": 1])
        #expect(entry.evidence.first?.kind.rawValue == "benchmark")
        #expect(entry.evidence.first?.checkedAt == date)
    }

    @Test("unsupported versions and mismatched source dates fail closed")
    func versionsAndDates() {
        #expect(throws: SuggestionCatalog.LoadError.unsupportedVersion) {
            try SuggestionCatalog(facts: facts(version: 2), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.unsupportedVersion) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(version: 2))
        }
        #expect(throws: SuggestionCatalog.LoadError.factsDateMismatch) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(factsDate: "2026-11-06"))
        }
    }

    @Test("duplicate identities, efforts and model-effort entries are rejected")
    func duplicates() {
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: facts(duplicate: true), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: facts(efforts: #"["low","low"]"#), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: facts(efforts: #"["high","low"]"#), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(duplicate: true))
        }
    }

    @Test("unknown model evaluations are ignored, never mapped to a harness")
    func unknownModel() throws {
        let catalog = try SuggestionCatalog(facts: facts(), tiers: tiers(key: "codex/test-model"))
        #expect(catalog.models.count == 1)
        #expect(catalog.entries.isEmpty)
    }

    @Test("a no-effort model accepts default only; declared efforts are not guessed")
    func effortMembership() throws {
        let catalog = try SuggestionCatalog(facts: facts(efforts: "[]"), tiers: tiers(effort: "default"))
        #expect(catalog.entries.first?.effort == "default")
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(efforts: "[]"), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(effort: "default"))
        }
    }

    @Test("community-only, insecure sources, invalid dates and invalid ranks are rejected")
    func invalidEvidence() {
        let community = """
        [{"kind":"community","source":"https://community.example.invalid","checkedAt":"\(date)"}]
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: community))
        }
        let insecure = """
        [{"kind":"benchmark","source":"http://benchmark.example.invalid","checkedAt":"\(date)"}]
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: insecure))
        }
        let invalidDate = """
        [{"kind":"benchmark","source":"https://benchmark.example.invalid","checkedAt":"2026-02-30"}]
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: invalidDate))
        }
        for rank in [#"{"reasoning":0}"#, #"{"reasoning":-1}"#,
                     #"{"reasoning":1.5}"#, #"{"undeclared":1}"#, "{}"] {
            #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
                try SuggestionCatalog(facts: facts(), tiers: tiers(rank: rank))
            }
        }
    }

    @Test("invalid fact provenance and dates are rejected")
    func invalidFacts() {
        for source in ["http://vendor.example.invalid", "https://user:pass@vendor.example.invalid"] {
            #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
                try SuggestionCatalog(facts: facts(source: source), tiers: tiers())
            }
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: facts(checkedAt: "2026-02-30"), tiers: tiers())
        }
    }

    @Test("unknown fact codes are ignored and qualified numeric/text facts are retained")
    func factCodes() throws {
        let extra = """
        ,{"id":"openai/test-model/futureCode","code":"futureCode","number":1,"text":null,
          "source":"https://vendor.example.invalid","checkedAt":"\(date)"}
        ,{"id":"openai/test-model/monthlyLimitUSD/go","code":"monthlyLimitUSD","number":60,"text":"go",
          "source":"https://vendor.example.invalid","checkedAt":"\(date)"}
        """
        let catalog = try SuggestionCatalog(facts: facts(extraValues: extra), tiers: tiers())
        #expect(catalog.models.first?.values.map(\.code) == ["inputPricePerMTok", "monthlyLimitUSD"])
        #expect(catalog.models.first?.values.last?.number == 60)
        #expect(catalog.models.first?.values.last?.text == "go")
    }

    @Test("malformed and oversized data fail before becoming a catalog")
    func malformed() {
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: Data("not json".utf8), tiers: tiers())
        }
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: Data("not json".utf8))
        }
        #expect(throws: SuggestionCatalog.LoadError.oversized) {
            try SuggestionCatalog(facts: Data(repeating: 32, count: 1_048_577), tiers: tiers())
        }
    }

    // MARK: - Edge cases beyond the contract draft

    private func tiersCustom(axis: String = #"["simpleCoding","reasoning"]"#,
                             date: String = "2026-11-07",
                             entry: String? = nil) -> Data {
        let entry = entry ?? """
        {"key":"openai/test-model","effort":"high","tier":"frontier",
         "rank":{"simpleCoding":4,"reasoning":1},
         "evidence":[{"kind":"benchmark","source":"https://b.example.invalid",
                      "checkedAt":"\(date)"}]}
        """
        return Data("""
        {"version":1,"date":"\(date)","factsDate":"\(self.date)","axis":\(axis),"entries":[\(entry)]}
        """.utf8)
    }

    private func factsCustom(_ model: String) -> Data {
        Data(#"{"version":1,"date":"2026-11-07","models":[\#(model)]}"#.utf8)
    }

    @Test("duplicate fact ids and wrong owner/prefix ids are rejected")
    func factIds() {
        let dup = """
        ,{"id":"openai/test-model/inputPricePerMTok","code":"inputPricePerMTok",
          "number":1,"text":null,"source":"https://v.example.invalid","checkedAt":"\(date)"}
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: facts(extraValues: dup), tiers: tiers())
        }
        for badId in ["other/x/inputPricePerMTok",
                      "openai/test-model/inputPricePerMTok/",
                      "openai/test-model/inputPricePerMTok/a b",
                      "openai/test-model/otherCode"] {
            let bad = """
            ,{"id":"\(badId)","code":"inputPricePerMTok","number":1,"text":null,
              "source":"https://v.example.invalid","checkedAt":"\(date)"}
            """
            #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
                try SuggestionCatalog(facts: facts(extraValues: bad), tiers: tiers())
            }
        }
    }

    @Test("facts need a finite number or a nonempty whitespace-free text")
    func factValues() {
        for extra in [
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":null,"text":null,"source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":null,"text":"","source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":null,"text":" ","source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
            // Every PROVIDED field must be independently valid — a finite number
            // does not rescue a bad text value.
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":4,"text":"","source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":4,"text":" ","source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
            #"{"id":"openai/test-model/maxOutputTokens","code":"maxOutputTokens","number":4,"text":"bad value","source":"https://v.example.invalid","checkedAt":"2026-11-07"}"#,
        ] {
            #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
                try SuggestionCatalog(facts: facts(extraValues: ",\(extra)"), tiers: tiers())
            }
        }
    }

    @Test("structurally decodable unknown codes skip every semantic check")
    func unknownCodesSkipped() throws {
        // Wrong owner id, invalid date and insecure source — all ignored because
        // the code is unknown; the retained known fact keeps the catalog usable.
        let bad = """
        ,{"id":"other/x/futureCode","code":"futureCode","number":null,"text":null,
          "source":"http://insecure.example.invalid","checkedAt":"2026-02-30"}
        """
        let catalog = try SuggestionCatalog(facts: facts(extraValues: bad), tiers: tiers())
        #expect(catalog.models.first?.values.map(\.code) == ["inputPricePerMTok"])
        #expect(catalog.entries.count == 1)
    }

    @Test("maker and model identifiers follow the upstream schema")
    func makerIds() {
        for (vendor, model) in [("OpenAI", "test-model"), ("open ai", "test-model"),
                                ("", "test-model"), ("openai", "Bad Model"),
                                ("openai", "-x"), ("openai", "")] {
            let m = """
            {"vendorId":"\(vendor)","model":"\(model)","name":"T","efforts":["high"],
             "values":[{"id":"\(vendor)/\(model)/inputPricePerMTok","code":"inputPricePerMTok",
                        "number":1,"text":null,"source":"https://v.example.invalid",
                        "checkedAt":"\(date)"}]}
            """
            #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
                try SuggestionCatalog(facts: factsCustom(m), tiers: tiers())
            }
        }
    }

    @Test("axes must be nonempty, unique tokens; dates are strict Gregorian")
    func axesAndDates() throws {
        for axis in ["[]", #"["a","a"]"#, #"["a b"]"#, #"["",""]"#] {
            #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
                try SuggestionCatalog(facts: facts(), tiers: tiersCustom(axis: axis))
            }
        }
        for bad in ["2026-02-30", "2025-02-29", "26-11-07", "2026-13-01",
                    "0000-01-01", "1900-02-29"] {
            #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
                try SuggestionCatalog(facts: facts(), tiers: tiersCustom(date: bad))
            }
        }
        // Escaped newline inside structurally valid JSON: the decoder accepts the
        // document, then catalog semantics reject the polluted date string.
        let newline = tiersCustom(date: "2026-11-07\\n")
        #expect((try? JSONSerialization.jsonObject(with: newline)) != nil)
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: newline)
        }
        // Same for a polluted checkedAt on an otherwise valid evidence record.
        let badChecked = """
        {"key":"openai/test-model","effort":"high","tier":"mid",
         "rank":{"reasoning":1},
         "evidence":[{"kind":"vendor","source":"https://v.example.invalid",
                      "checkedAt":"2026-11-07\\n"}]}
        """
        let checkedData = tiersCustom(entry: badChecked)
        #expect((try? JSONSerialization.jsonObject(with: checkedData)) != nil)
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: checkedData)
        }
        // Leap centuries: 1900 is not a leap year, 2000 is.
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiersCustom(date: "1900-02-29"))
        }
        // Valid leap day and a partial rank are accepted unchanged.
        let leap = """
        {"key":"openai/test-model","effort":"high","tier":"mid",
         "rank":{"reasoning":1},
         "evidence":[{"kind":"vendor","source":"https://v.example.invalid","checkedAt":"2024-02-29"}]}
        """
        let catalog = try SuggestionCatalog(facts: facts(), tiers: tiersCustom(date: "2024-02-29", entry: leap))
        #expect(catalog.tiersDate == "2024-02-29")
        #expect(catalog.entries.first?.rank == ["reasoning": 1])
        let y2k = """
        {"key":"openai/test-model","effort":"high","tier":"mid",
         "rank":{"reasoning":1},
         "evidence":[{"kind":"vendor","source":"https://v.example.invalid","checkedAt":"2000-02-29"}]}
        """
        let leapCentury = try SuggestionCatalog(facts: facts(),
                                                tiers: tiersCustom(date: "2000-02-29", entry: y2k))
        #expect(leapCentury.tiersDate == "2000-02-29")
    }

    @Test("source URLs must be HTTPS with a real host and no raw whitespace/control")
    func sourceBoundaries() {
        for bad in ["https:///path-only", "https://v.example.invalid/ a"] {
            #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
                try SuggestionCatalog(facts: facts(source: bad), tiers: tiers())
            }
        }
        // Escaped control character: the JSON decodes, then the source boundary
        // rejects the control character in the URL string.
        let control = facts(source: #"https://v.example.invalid/\u0001"#)
        #expect((try? JSONSerialization.jsonObject(with: control)) != nil)
        #expect(throws: SuggestionCatalog.LoadError.invalidFacts) {
            try SuggestionCatalog(facts: control, tiers: tiers())
        }
        let badEvidence = """
        [{"kind":"benchmark","source":"https:///path-only","checkedAt":"\(date)"}]
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: badEvidence))
        }
    }

    @Test("empty evidence, unknown evidence kinds and tiers fail closed")
    func evidenceAndTier() {
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: "[]"))
        }
        let badKind = """
        [{"kind":"crowd","source":"https://x.example.invalid","checkedAt":"\(date)"}]
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiers(evidence: badKind))
        }
        let badTier = """
        {"key":"openai/test-model","effort":"high","tier":"top","rank":{"reasoning":1},
         "evidence":[{"kind":"benchmark","source":"https://b.example.invalid",
                      "checkedAt":"\(date)"}]}
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiersCustom(entry: badTier))
        }
        let boolRank = """
        {"key":"openai/test-model","effort":"high","tier":"mid","rank":{"reasoning":true},
         "evidence":[{"kind":"benchmark","source":"https://b.example.invalid",
                      "checkedAt":"\(date)"}]}
        """
        #expect(throws: SuggestionCatalog.LoadError.invalidEvaluations) {
            try SuggestionCatalog(facts: facts(), tiers: tiersCustom(entry: boolRank))
        }
    }

    @Test("oversize applies to both inputs; exactly-limit data is accepted")
    func sizeLimits() throws {
        #expect(throws: SuggestionCatalog.LoadError.oversized) {
            try SuggestionCatalog(facts: facts(), tiers: Data(repeating: 32, count: 1_048_577))
        }
        #expect(throws: SuggestionCatalog.LoadError.oversized) {
            try SuggestionCatalog(facts: Data(repeating: 32, count: 1_048_577),
                                  tiers: Data(repeating: 32, count: 1_048_577))
        }
        var padded = facts()
        padded.append(Data(repeating: 32, count: 1_048_576 - padded.count))
        let catalog = try SuggestionCatalog(facts: padded, tiers: tiers())
        #expect(catalog.models.count == 1)
    }

    @Test("semantically invalid unknown-model evaluations are skipped entirely")
    func unknownModelSkipped() throws {
        let entry = """
        {"key":"other/x","effort":"bogus","tier":"frontier","rank":{"undeclared":0},
         "evidence":[]}
        """
        let catalog = try SuggestionCatalog(facts: facts(), tiers: tiersCustom(entry: entry))
        #expect(catalog.entries.isEmpty)
    }

    @Test("frozen upstream fixtures load with the settled shape")
    func frozenFixtures() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ModelTF", isDirectory: true)
        let facts = try Data(contentsOf: dir.appendingPathComponent("model-facts.json"))
        let tiers = try Data(contentsOf: dir.appendingPathComponent("model-tiers.json"))
        #expect(facts.count == 74_669 && tiers.count == 36_347)
        let catalog = try SuggestionCatalog(facts: facts, tiers: tiers)
        #expect(catalog.factsDate == "2026-11-07" && catalog.tiersDate == "2026-11-07")
        #expect(catalog.axes == ["simpleCoding", "reasoning"])
        #expect(catalog.models.count == 49)
        #expect(Set(catalog.models.map(\.key)).count == 49)
        #expect(catalog.models.allSatisfy { $0.key == "\($0.vendorId)/\($0.model)" })
        #expect(catalog.entries.count == 71)
        #expect(Set(catalog.entries.map { "\($0.key)\u{0}\($0.effort)" }).count == 71)
        let efforts = Dictionary(uniqueKeysWithValues: catalog.models.map { ($0.key, $0.efforts) })
        for e in catalog.entries {
            let declared = try #require(efforts[e.key])
            #expect(declared.contains(e.effort) || (declared.isEmpty && e.effort == "default"))
        }
    }
}
