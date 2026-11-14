import Testing
@testable import VendorDrift

@Suite("Schema shape")
struct SchemaShapeTests {
    // Small typed builders: every schema below is a `[String: Any]` put together from these.
    private func reference(_ name: String) -> [String: Any] { ["$ref": "#/definitions/\(name)"] }
    private func type(_ name: String) -> [String: Any] { ["type": name] }
    private func nullable(_ name: String, format: String? = nil) -> [String: Any] {
        let names: [String] = [name, "null"]
        var schema: [String: Any] = ["type": names]
        if let format { schema["format"] = format }
        return schema
    }
    private func tagged(_ tag: String, _ members: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        let values: [String] = [tag]
        var properties: [String: Any] = members
        properties["type"] = ["enum": values, "type": "string"] as [String: Any]
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
    private func oneOf(_ variants: [[String: Any]]) -> [String: Any] { ["oneOf": variants] }
    private func anyOf(_ variants: [[String: Any]]) -> [String: Any] { ["anyOf": variants] }

    @Test("a signature names the type, its format and its alternatives, null last")
    func signatures() {
        #expect(SchemaShape.signature(type("string")) == "string")
        #expect(SchemaShape.signature(nullable("integer", format: "int64")) == "integer<int64> | null")
        #expect(SchemaShape.signature(reference("RateLimitWindow")) == "RateLimitWindow")
        #expect(SchemaShape.signature(anyOf([type("null"), reference("B"), reference("A")])) == "A | B | null")
        #expect(SchemaShape.signature(oneOf([reference("A"), reference("A")])) == "A")

        let wrapped: [String: Any] = ["allOf": [reference("A")] as [[String: Any]], "description": "prose"]
        #expect(SchemaShape.signature(wrapped) == "A")
        let strings: [String: Any] = ["type": "array", "items": type("string")]
        #expect(SchemaShape.signature(strings) == "[string]")
        #expect(SchemaShape.signature(type("array")) == "[any]")
        let choice: [String: Any] = ["enum": ["b", "a"] as [String], "type": "string"]
        #expect(SchemaShape.signature(choice) == "enum(a|b)")
        let constant: [String: Any] = ["const": "x"]
        #expect(SchemaShape.signature(constant) == "const(x)")
        #expect(SchemaShape.signature(true) == "any")
        #expect(SchemaShape.signature(false) == "never")
        let empty: [String: Any] = [:]
        #expect(SchemaShape.signature(empty) == "any")
        #expect(SchemaShape.signature("not a schema") == "any")
    }

    @Test("an inline object lists its members; a map shows its value type")
    func inlineObjects() {
        let members: [String: Any] = ["a": type("string"), "b": type("boolean")]
        let object: [String: Any] = ["type": "object", "required": ["a"] as [String], "properties": members]
        #expect(SchemaShape.signature(object) == "{a: string (required), b: boolean}")
        var map: [String: Any] = nullable("object")
        map["additionalProperties"] = reference("A")
        #expect(SchemaShape.signature(map) == "{(any other key): A} | null")
        #expect(SchemaShape.signature(type("object")) == "object")
    }

    @Test("an object's members carry their signature and whether they are required")
    func objectMembers() {
        let used: [String: Any] = ["type": "integer", "format": "int32", "description": "prose"]
        let members: [String: Any] = ["usedPercent": used, "resetsAt": nullable("integer", format: "int64")]
        let definition: [String: Any] = ["type": "object", "required": ["usedPercent"] as [String],
                                         "description": "prose", "properties": members]
        let expected: [String: String] = ["usedPercent": "integer<int32> (required)",
                                          "resetsAt": "integer<int64> | null"]
        #expect(SchemaShape.members(of: definition) == expected)
    }

    @Test("prose changes leave the shape alone")
    func proseIsIgnored() {
        func definition(_ prose: String) -> [String: Any] {
            let member: [String: Any] = ["type": "string", "description": prose]
            let members: [String: Any] = ["a": member]
            return ["type": "object", "title": prose, "description": prose, "properties": members]
        }
        #expect(SchemaShape.members(of: definition("old")) == SchemaShape.members(of: definition("new")))
    }

    @Test("an enum lists its values, so an added or removed value shows on its own")
    func enumMembers() {
        let plans: [String: Any] = ["enum": ["free", "plus"] as [String], "type": "string"]
        let expected: [String: String] = ["free": "enum value", "plus": "enum value"]
        #expect(SchemaShape.members(of: plans) == expected)
    }

    @Test("a tagged union lists each variant's members under its tag")
    func taggedUnion() {
        let none: [String: Any] = ["enum": ["none"] as [String], "type": "string"]
        let untaggedMembers: [String: Any] = ["untagged": type("string")]
        let untagged: [String: Any] = ["type": "object", "properties": untaggedMembers]
        let account: [String: Any] = oneOf([
            tagged("apiKey", required: ["type"]),
            tagged("chatgpt", ["email": nullable("string")], required: ["type"]),
            none, untagged, type("null"),
        ])
        let expected: [String: String] = [
            "apiKey.type": "enum(apiKey) (required)",
            "chatgpt.type": "enum(chatgpt) (required)", "chatgpt.email": "string | null",
            "none": "enum value", "#3.untagged": "string", "#4": "null",
        ]
        #expect(SchemaShape.members(of: account) == expected)
    }

    @Test("variants sharing a tag are kept apart instead of one hiding the other")
    func duplicateTags() {
        let union: [String: Any] = oneOf([
            tagged("same", ["first": type("string")]),
            tagged("same", ["second": type("string")]),
            tagged("other"),
        ])
        let expected: [String: String] = [
            "#0.type": "enum(same)", "#0.first": "string", "#1.type": "enum(same)", "#1.second": "string",
            "other.type": "enum(other)",
        ]
        #expect(SchemaShape.members(of: union) == expected)
    }

    @Test("anything else is one whole shape")
    func wholeShape() {
        let string: [String: String] = [SchemaShape.wholeKey: "string"]
        #expect(SchemaShape.members(of: type("string")) == string)
        let any: [String: String] = [SchemaShape.wholeKey: "any"]
        #expect(SchemaShape.members(of: true) == any)
        let optional: [String: String] = [SchemaShape.wholeKey: "A | null"]
        #expect(SchemaShape.members(of: anyOf([reference("A"), type("null")])) == optional)
    }

    @Test("a map-only object lists its value type as a member")
    func mapMembers() {
        let map: [String: Any] = ["type": "object", "additionalProperties": reference("A")]
        let expected: [String: String] = [SchemaShape.additionalKey: "A"]
        #expect(SchemaShape.members(of: map) == expected)
    }

    @Test("references are found at any depth")
    func references() {
        let list: [String: Any] = ["type": "array", "items": reference("C")]
        let members: [String: Any] = ["a": reference("A"), "b": anyOf([reference("B"), type("null")]), "c": list]
        let schema: [String: Any] = ["properties": members]
        let expected: Set<String> = ["A", "B", "C"]
        #expect(SchemaShape.references(in: schema) == expected)
        #expect(SchemaShape.references(in: "text").isEmpty)
    }
}
