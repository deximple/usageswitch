import Testing
@testable import VendorDrift

@Suite("Schema shape")
struct SchemaShapeTests {
    private func reference(_ name: String) -> [String: Any] { ["$ref": "#/definitions/\(name)"] }

    @Test("a signature names the type, its format and its alternatives, null last")
    func signatures() {
        #expect(SchemaShape.signature(["type": "string"]) == "string")
        #expect(SchemaShape.signature(["type": ["integer", "null"], "format": "int64"]) == "integer<int64> | null")
        #expect(SchemaShape.signature(reference("RateLimitWindow")) == "RateLimitWindow")
        #expect(SchemaShape.signature(["anyOf": [["type": "null"], reference("B"), reference("A")]]) == "A | B | null")
        #expect(SchemaShape.signature(["oneOf": [reference("A"), reference("A")]]) == "A")
        #expect(SchemaShape.signature(["allOf": [reference("A")], "description": "prose"]) == "A")
        #expect(SchemaShape.signature(["type": "array", "items": ["type": "string"]]) == "[string]")
        #expect(SchemaShape.signature(["type": "array"]) == "[any]")
        #expect(SchemaShape.signature(["enum": ["b", "a"], "type": "string"]) == "enum(a|b)")
        #expect(SchemaShape.signature(["const": "x"]) == "const(x)")
        #expect(SchemaShape.signature(true) == "any")
        #expect(SchemaShape.signature(false) == "never")
        #expect(SchemaShape.signature([String: Any]()) == "any")
        #expect(SchemaShape.signature("not a schema") == "any")
    }

    @Test("an inline object lists its members; a map shows its value type")
    func inlineObjects() {
        let object: [String: Any] = ["type": "object", "required": ["a"],
                                     "properties": ["a": ["type": "string"], "b": ["type": "boolean"]]]
        #expect(SchemaShape.signature(object) == "{a: string (required), b: boolean}")
        #expect(SchemaShape.signature(["type": ["object", "null"], "additionalProperties": reference("A")])
            == "{(any other key): A} | null")
        #expect(SchemaShape.signature(["type": "object"]) == "object")
    }

    @Test("an object's members carry their signature and whether they are required")
    func objectMembers() {
        let definition: [String: Any] = [
            "type": "object", "required": ["usedPercent"], "description": "prose",
            "properties": ["usedPercent": ["type": "integer", "format": "int32", "description": "prose"],
                           "resetsAt": ["type": ["integer", "null"], "format": "int64"]],
        ]
        #expect(SchemaShape.members(of: definition) == [
            "usedPercent": "integer<int32> (required)", "resetsAt": "integer<int64> | null",
        ])
    }

    @Test("prose changes leave the shape alone")
    func proseIsIgnored() {
        let before: [String: Any] = ["type": "object", "title": "A", "description": "old",
                                     "properties": ["a": ["type": "string", "description": "old"]]]
        let after: [String: Any] = ["type": "object", "title": "B", "description": "new",
                                    "properties": ["a": ["type": "string", "description": "new"]]]
        #expect(SchemaShape.members(of: before) == SchemaShape.members(of: after))
    }

    @Test("an enum lists its values, so an added or removed value shows on its own")
    func enumMembers() {
        #expect(SchemaShape.members(of: ["enum": ["free", "plus"], "type": "string"])
            == ["free": "enum value", "plus": "enum value"])
    }

    @Test("a tagged union lists each variant's members under its tag")
    func taggedUnion() {
        let account: [String: Any] = ["oneOf": [
            ["type": "object", "required": ["type"], "properties": ["type": ["enum": ["apiKey"], "type": "string"]]],
            ["type": "object", "required": ["type"],
             "properties": ["type": ["enum": ["chatgpt"], "type": "string"], "email": ["type": ["string", "null"]]]],
            ["enum": ["none"], "type": "string"],
            ["type": "object", "properties": ["untagged": ["type": "string"]]],
            ["type": "null"],
        ]]
        #expect(SchemaShape.members(of: account) == [
            "apiKey.type": "enum(apiKey) (required)",
            "chatgpt.type": "enum(chatgpt) (required)", "chatgpt.email": "string | null",
            "none": "enum value", "#3.untagged": "string", "#4": "null",
        ])
    }

    @Test("variants sharing a tag are kept apart instead of one hiding the other")
    func duplicateTags() {
        let union: [String: Any] = ["oneOf": [
            ["type": "object", "properties": ["type": ["enum": ["same"]], "first": ["type": "string"]]],
            ["type": "object", "properties": ["type": ["enum": ["same"]], "second": ["type": "string"]]],
            ["type": "object", "properties": ["type": ["enum": ["other"]]]],
        ]]
        #expect(SchemaShape.members(of: union) == [
            "#0.type": "enum(same)", "#0.first": "string", "#1.type": "enum(same)", "#1.second": "string",
            "other.type": "enum(other)",
        ])
    }

    @Test("anything else is one whole shape")
    func wholeShape() {
        #expect(SchemaShape.members(of: ["type": "string"]) == [SchemaShape.wholeKey: "string"])
        #expect(SchemaShape.members(of: true) == [SchemaShape.wholeKey: "any"])
        #expect(SchemaShape.members(of: ["anyOf": [reference("A"), ["type": "null"]]])
            == [SchemaShape.wholeKey: "A | null"])
    }

    @Test("a map-only object lists its value type as a member")
    func mapMembers() {
        #expect(SchemaShape.members(of: ["type": "object", "additionalProperties": reference("A")])
            == [SchemaShape.additionalKey: "A"])
    }

    @Test("references are found at any depth")
    func references() {
        let schema: [String: Any] = [
            "properties": ["a": reference("A"), "b": ["anyOf": [reference("B"), ["type": "null"]]],
                           "c": ["type": "array", "items": reference("C")]],
        ]
        #expect(SchemaShape.references(in: schema) == ["A", "B", "C"])
        #expect(SchemaShape.references(in: "text").isEmpty)
    }
}
