#!/usr/bin/env swift
// Verifies a Sparkle appcast.xml before (or after) it is published.
//
// Usage:
//   swift scripts/verify-appcast.swift <appcast.xml> [--archives DIR] [--key BASE64]
//
// Checks, failing closed:
//   - XML parses and holds at least one <item>
//   - every enclosure URL is https and matches the fixed "appcast" release prefix
//   - every item carries sparkle:version, sparkle:shortVersionString and a
//     64-byte edSignature; versions are unique
//   - with --archives, each enclosure's file exists in DIR and its ed25519
//     signature verifies against the public key — from --key, else the
//     SUPublicEDKey value in Resources/Info.plist (skipped if it is still the
//     shipping placeholder)
import CryptoKit
import Foundation

let expectedPrefix = "https://github.com/deximple/usageswitch/releases/download/appcast/"

struct FeedItem {
    var version = ""
    var shortVersion = ""
    var url = ""
    var signature = ""
}

final class FeedParser: NSObject, XMLParserDelegate {
    private(set) var items: [FeedItem] = []
    private var current: FeedItem?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = FeedItem() }
        if name == "enclosure", current != nil {
            current?.url = attributes["url"] ?? ""
            current?.signature = attributes["sparkle:edSignature"] ?? ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let item = current { items.append(item) }; current = nil
        case "sparkle:version": current?.version = value
        case "sparkle:shortVersionString": current?.shortVersion = value
        default: break
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("verify-appcast: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var archivesDir: String?
var keyOverride: String?
var xmlPath: String?
var index = 0
while index < args.count {
    switch args[index] {
    case "--archives": index += 1; archivesDir = index < args.count ? args[index] : nil
    case "--key": index += 1; keyOverride = index < args.count ? args[index] : nil
    default: xmlPath = args[index]
    }
    index += 1
}
guard let xmlPath else { fail("usage: verify-appcast.swift <appcast.xml> [--archives DIR] [--key BASE64]") }
guard let data = FileManager.default.contents(atPath: xmlPath) else { fail("cannot read \(xmlPath)") }

let delegate = FeedParser()
let xml = XMLParser(data: data)
xml.delegate = delegate
guard xml.parse() else { fail("XML did not parse: \(xml.parserError?.localizedDescription ?? "?")") }
let items = delegate.items
guard !items.isEmpty else { fail("no <item> entries") }

var seen = Set<String>()
for (index, item) in items.enumerated() {
    let label = item.shortVersion.isEmpty ? "item \(index)" : item.shortVersion
    guard item.url.hasPrefix(expectedPrefix) else { fail("\(label): enclosure URL not under \(expectedPrefix)") }
    guard !item.version.isEmpty, !item.shortVersion.isEmpty else { fail("\(label): missing sparkle version") }
    guard let sig = Data(base64Encoded: item.signature), sig.count == 64
    else { fail("\(label): missing or malformed edSignature") }
    guard seen.insert(item.version).inserted else { fail("\(label): duplicate sparkle:version \(item.version)") }
}
print("\(items.count) item(s): URLs, versions and signatures well-formed")

if let archivesDir {
    var publicKey: Data?
    if let keyOverride {
        publicKey = Data(base64Encoded: keyOverride)
    } else if let plist = FileManager.default.contents(atPath: "Resources/Info.plist"),
              let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let key = dict["SUPublicEDKey"] as? String {
        publicKey = Data(base64Encoded: key)
    }
    guard let keyBytes = publicKey, keyBytes.count == 32 else {
        fail("no usable EdDSA public key — pass --key or ship SUPublicEDKey in Info.plist")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    for item in items {
        let name = URL(string: item.url)!.lastPathComponent
        let path = (archivesDir as NSString).appendingPathComponent(name)
        guard let file = FileManager.default.contents(atPath: path)
        else { fail("\(item.shortVersion): archive missing in \(archivesDir): \(name)") }
        let sig = Data(base64Encoded: item.signature)!
        guard key.isValidSignature(sig, for: file)
        else { fail("\(item.shortVersion): edSignature does not verify against \(name)") }
    }
    print("all \(items.count) signature(s) verify against \(archivesDir)")
}
print("appcast OK")
