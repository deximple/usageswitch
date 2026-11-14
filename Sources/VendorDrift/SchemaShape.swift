import Foundation

/// Flattens one JSON Schema definition into `member → signature` strings. Prose (`description`,
/// `title`) is dropped, so two schemas compare equal unless their shape changed.
enum SchemaShape {
    /// The member key of a definition that is neither an object with properties nor an enum.
    static let wholeKey = "(shape)"
    /// The member key of an object's `additionalProperties` schema.
    static let additionalKey = "(any other key)"
    static let requiredSuffix = " (required)"
    private static let enumValue = "enum value"

    static func members(of definition: Any) -> [String: String] {
        guard let schema = definition as? [String: Any] else { return [wholeKey: signature(definition)] }
        if let values = schema["enum"] as? [Any] {
            return Dictionary(values.map { (text($0), enumValue) }, uniquingKeysWith: { first, _ in first })
        }
        if schema["properties"] != nil || schema["additionalProperties"] is [String: Any] {
            return properties(of: schema, prefix: "")
        }
        if let variants = (schema["oneOf"] ?? schema["anyOf"]) as? [[String: Any]],
           variants.contains(where: { $0["properties"] != nil || $0["enum"] != nil }) {
            let tags = variants.map(tag)
            return variants.enumerated().reduce(into: [:]) { out, entry in
                let (index, variant) = entry
                if let values = variant["enum"] as? [Any] {
                    for value in values { out[text(value)] = enumValue }
                } else if variant["properties"] != nil {
                    // A tag names its variant only while no other variant carries the same one.
                    let name = tags[index].flatMap { tag in tags.filter { $0 == tag }.count == 1 ? tag : nil }
                    out.merge(properties(of: variant, prefix: "\(name ?? "#\(index)")."),
                              uniquingKeysWith: { first, _ in first })
                } else {
                    out["#\(index)"] = signature(variant)
                }
            }
        }
        return [wholeKey: signature(schema)]
    }

    /// The names of every `#/definitions/<name>` the schema points at, at any depth.
    static func references(in schema: Any) -> Set<String> {
        if let object = schema as? [String: Any] {
            var names = Set<String>()
            if let reference = object["$ref"] as? String { names.insert(name(ofReference: reference)) }
            for (key, value) in object where key != "$ref" { names.formUnion(references(in: value)) }
            return names
        }
        if let list = schema as? [Any] { return list.reduce(into: []) { $0.formUnion(references(in: $1)) } }
        return []
    }

    static func signature(_ schema: Any) -> String {
        if let flag = schema as? Bool { return flag ? "any" : "never" }
        guard let object = schema as? [String: Any] else { return "any" }
        if let reference = object["$ref"] as? String { return name(ofReference: reference) }
        if let all = object["allOf"] as? [Any], !all.isEmpty {
            return all.map(signature).joined(separator: " & ")
        }
        if let any = (object["anyOf"] ?? object["oneOf"]) as? [Any], !any.isEmpty {
            return union(any.map(signature))
        }
        if let values = object["enum"] as? [Any] {
            return "enum(" + values.map(text).sorted().joined(separator: "|") + ")"
        }
        if let constant = object["const"] { return "const(\(text(constant)))" }
        let types = (object["type"] as? [String]) ?? (object["type"] as? String).map { [$0] } ?? []
        guard !types.isEmpty else { return "any" }
        return union(types.map { type in
            switch type {
            case "array":
                return "[" + signature(object["items"] ?? true) + "]"
            case "object":
                let members = properties(of: object, prefix: "")
                guard !members.isEmpty else { return "object" }
                return "{" + members.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
            case "null":
                return type
            default:
                return (object["format"] as? String).map { "\(type)<\($0)>" } ?? type
            }
        })
    }

    private static func properties(of schema: [String: Any], prefix: String) -> [String: String] {
        let required = Set(schema["required"] as? [String] ?? [])
        var out: [String: String] = [:]
        for (name, property) in schema["properties"] as? [String: Any] ?? [:] {
            out[prefix + name] = signature(property) + (required.contains(name) ? requiredSuffix : "")
        }
        if let additional = schema["additionalProperties"] as? [String: Any] {
            out[prefix + additionalKey] = signature(additional)
        }
        return out
    }

    /// The single-valued enum property that names a tagged-union variant (`"type": {"enum": ["chatgpt"]}`).
    private static func tag(of variant: [String: Any]) -> String? {
        let properties = variant["properties"] as? [String: Any] ?? [:]
        return properties.keys.sorted().lazy.compactMap { key -> String? in
            guard let values = (properties[key] as? [String: Any])?["enum"] as? [Any], values.count == 1
            else { return nil }
            return text(values[0])
        }.first
    }

    /// Alternatives in a stable order, `null` last.
    private static func union(_ signatures: [String]) -> String {
        let unique = Set(signatures)
        return (unique.subtracting(["null"]).sorted() + (unique.contains("null") ? ["null"] : []))
            .joined(separator: " | ")
    }

    private static func name(ofReference reference: String) -> String {
        reference.split(separator: "/").last.map(String.init) ?? reference
    }

    private static func text(_ value: Any) -> String {
        (value as? String) ?? String(describing: value)
    }
}
