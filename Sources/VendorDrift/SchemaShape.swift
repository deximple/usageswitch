import Foundation

/// Flattens one JSON Schema definition into `member → signature` strings. Prose (`description`,
/// `title`) is dropped, so two schemas compare equal unless their shape changed.
///
/// Written with explicit types throughout: this target must also build with the older compiler
/// CI uses, which gives up on long inferred expressions.
enum SchemaShape {
    /// The member key of a definition that is neither an object with properties nor an enum.
    static let wholeKey = "(shape)"
    /// The member key of an object's `additionalProperties` schema.
    static let additionalKey = "(any other key)"
    static let requiredSuffix = " (required)"
    /// The signature of each value of an enum.
    static let enumValue = "enum value"

    static func members(of definition: Any) -> [String: String] {
        guard let schema = definition as? [String: Any] else { return [wholeKey: signature(definition)] }
        if let values = schema["enum"] as? [Any] {
            return enumMembers(values)
        }
        if schema["properties"] != nil || schema["additionalProperties"] is [String: Any] {
            return properties(of: schema, prefix: "")
        }
        let alternatives: Any? = schema["oneOf"] ?? schema["anyOf"]
        if let variants = alternatives as? [[String: Any]], variants.contains(where: isStructured) {
            return unionMembers(variants)
        }
        return [wholeKey: signature(schema)]
    }

    /// The names of every `#/definitions/<name>` the schema points at, at any depth.
    static func references(in schema: Any) -> Set<String> {
        var names = Set<String>()
        if let object = schema as? [String: Any] {
            for (key, value) in object {
                if key == "$ref", let reference = value as? String {
                    names.insert(name(ofReference: reference))
                } else {
                    names.formUnion(references(in: value))
                }
            }
        } else if let list = schema as? [Any] {
            for item in list { names.formUnion(references(in: item)) }
        }
        return names
    }

    static func signature(_ schema: Any) -> String {
        if let flag = schema as? Bool { return flag ? "any" : "never" }
        guard let object = schema as? [String: Any] else { return "any" }
        if let reference = object["$ref"] as? String { return name(ofReference: reference) }
        if let all = object["allOf"] as? [Any], !all.isEmpty {
            let parts: [String] = all.map(signature)
            return parts.joined(separator: " & ")
        }
        let alternatives: Any? = object["anyOf"] ?? object["oneOf"]
        if let any = alternatives as? [Any], !any.isEmpty {
            let parts: [String] = any.map(signature)
            return union(parts)
        }
        if let values = object["enum"] as? [Any] {
            let names: [String] = values.map(text).sorted()
            return "enum(\(names.joined(separator: "|")))"
        }
        if let constant = object["const"] { return "const(\(text(constant)))" }
        let types: [String] = typeNames(of: object)
        guard !types.isEmpty else { return "any" }
        let parts: [String] = types.map { (type: String) -> String in signature(ofType: type, in: object) }
        return union(parts)
    }

    /// The schema's `type`, which is one name or a list of them.
    private static func typeNames(of object: [String: Any]) -> [String] {
        if let list = object["type"] as? [String] { return list }
        if let single = object["type"] as? String { return [single] }
        return []
    }

    private static func signature(ofType type: String, in object: [String: Any]) -> String {
        switch type {
        case "array":
            let items: Any = object["items"] ?? true
            return "[\(signature(items))]"
        case "object":
            let members: [String: String] = properties(of: object, prefix: "")
            guard !members.isEmpty else { return "object" }
            let names: [String] = members.keys.sorted()
            let lines: [String] = names.map { (name: String) -> String in "\(name): \(members[name] ?? "")" }
            return "{\(lines.joined(separator: ", "))}"
        case "null":
            return type
        default:
            guard let format = object["format"] as? String else { return type }
            return "\(type)<\(format)>"
        }
    }

    private static func enumMembers(_ values: [Any]) -> [String: String] {
        var out: [String: String] = [:]
        for value in values { out[text(value)] = enumValue }
        return out
    }

    private static func isStructured(_ variant: [String: Any]) -> Bool {
        variant["properties"] != nil || variant["enum"] != nil
    }

    /// The members of a union: enum values as themselves, object variants under their tag
    /// (or `#<index>` when they have none, or share it with another variant).
    private static func unionMembers(_ variants: [[String: Any]]) -> [String: String] {
        let tags: [String?] = variants.map(tag)
        var out: [String: String] = [:]
        for (index, variant) in variants.enumerated() {
            if let values = variant["enum"] as? [Any] {
                for value in values { out[text(value)] = enumValue }
            } else if variant["properties"] != nil {
                let name: String = uniqueTag(at: index, in: tags) ?? "#\(index)"
                let members: [String: String] = properties(of: variant, prefix: "\(name).")
                for (key, value) in members where out[key] == nil { out[key] = value }
            } else {
                out["#\(index)"] = signature(variant)
            }
        }
        return out
    }

    /// A tag names its variant only while no other variant carries the same one.
    private static func uniqueTag(at index: Int, in tags: [String?]) -> String? {
        guard let tag = tags[index] else { return nil }
        let sameTag: [String?] = tags.filter { (other: String?) -> Bool in other == tag }
        return sameTag.count == 1 ? tag : nil
    }

    private static func properties(of schema: [String: Any], prefix: String) -> [String: String] {
        let requiredNames: [String] = schema["required"] as? [String] ?? []
        let required: Set<String> = Set(requiredNames)
        let declared: [String: Any] = schema["properties"] as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for (name, property) in declared {
            let suffix: String = required.contains(name) ? requiredSuffix : ""
            out["\(prefix)\(name)"] = "\(signature(property))\(suffix)"
        }
        if let additional = schema["additionalProperties"] as? [String: Any] {
            out["\(prefix)\(additionalKey)"] = signature(additional)
        }
        return out
    }

    /// The single-valued enum property that names a tagged-union variant (`"type": {"enum": ["chatgpt"]}`).
    private static func tag(of variant: [String: Any]) -> String? {
        let properties: [String: Any] = variant["properties"] as? [String: Any] ?? [:]
        for key in properties.keys.sorted() {
            guard let property = properties[key] as? [String: Any],
                  let values = property["enum"] as? [Any], values.count == 1
            else { continue }
            return text(values[0])
        }
        return nil
    }

    /// Alternatives in a stable order, `null` last.
    private static func union(_ signatures: [String]) -> String {
        let unique: Set<String> = Set(signatures)
        var ordered: [String] = unique.filter { (signature: String) -> Bool in signature != "null" }.sorted()
        if unique.contains("null") { ordered.append("null") }
        return ordered.joined(separator: " | ")
    }

    private static func name(ofReference reference: String) -> String {
        guard let last = reference.split(separator: "/").last else { return reference }
        return String(last)
    }

    private static func text(_ value: Any) -> String {
        if let string = value as? String { return string }
        return String(describing: value)
    }
}
