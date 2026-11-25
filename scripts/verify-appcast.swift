#!/usr/bin/env swift
// Verifies a Sparkle appcast.xml before (or after) it is published.
//
// Usage:
//   swift scripts/verify-appcast.swift <appcast.xml> [--archives DIR] [--key BASE64]
//
// Checks, failing closed:
//   - the feed is signed: it carries Sparkle's signing block and the block's
//     edSignature verifies over the bytes before it. Builds from 2.5.1 on set
//     SURequireSignedFeed and accept no other feed, so the published feed must
//     stay signed.
//   - the signed bytes parse as XML and hold at least one <item>; the whole file
//     parses too, because builds without SURequireSignedFeed read all of it
//   - every item carries sparkle:version, sparkle:shortVersionString and exactly
//     one enclosure, whose URL is https under the fixed "appcast" release prefix
//     and whose edSignature is 64 bytes; versions are unique
//   - no item lists a delta update: appcast.sh uploads none
//   - with --archives, each enclosure's file exists in DIR and its ed25519
//     signature verifies
// The public key is --key, else the SUPublicEDKey value in Resources/Info.plist.
import CryptoKit
import Foundation

let expectedPrefix = "https://github.com/deximple/usageswitch/releases/download/appcast/"

struct Enclosure {
    var url = ""
    var signature = ""
    var isDelta = false
}

struct FeedItem {
    var version = ""
    var shortVersion = ""
    var enclosures: [Enclosure] = []
}

final class FeedParser: NSObject, XMLParserDelegate {
    private(set) var items: [FeedItem] = []
    private var current: FeedItem?
    private var insideDeltas = false
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = FeedItem() }
        if name == "sparkle:deltas" { insideDeltas = true }
        if name == "enclosure", current != nil {
            current?.enclosures.append(Enclosure(
                url: attributes["url"] ?? "",
                signature: attributes["sparkle:edSignature"] ?? "",
                isDelta: insideDeltas))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item": if let item = current { items.append(item) }; current = nil
        case "sparkle:deltas": insideDeltas = false
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

/// The part of a feed that its signature covers, and that signature. Split exactly as Sparkle
/// 2.10.1 does (SPUExtractAppcastContent in Sparkle/SPUExtractSignedFeed.m, then SUSignatures):
/// the signing block starts at the last "<!-- sparkle-signatures:\n" and runs to the next "-->",
/// and the signature covers every byte before the block. Re-check this against Sparkle's source
/// when the pinned version changes.
func signedPart(of feed: Data) -> (content: Data, signature: Data) {
    guard let blockStart = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let blockEnd = feed.range(of: Data("-->".utf8), in: blockStart.upperBound..<feed.endIndex),
          let block = String(data: feed[blockStart.upperBound..<blockEnd.lowerBound], encoding: .utf8)
    else {
        fail("the feed is not signed (no sparkle-signatures block): a build that requires a signed "
            + "feed would reject it. Sign it with Sparkle's sign_update.")
    }
    func value(_ key: String) -> String? {
        var found: String?
        (block as NSString).enumerateLines { line, _ in
            guard line.hasPrefix(key) else { return }
            found = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return found
    }
    guard let encoded = value("edSignature:"), let signature = Data(base64Encoded: encoded), signature.count == 64
    else { fail("the feed's signing block has no 64-byte edSignature") }
    let content = Data(feed[..<blockStart.lowerBound])
    // Sparkle's signing tool always records how many bytes it signed. A different count means
    // the file was edited after signing.
    guard let length = value("length:").flatMap({ Int($0) }), length == content.count
    else { fail("the feed's signing block does not give the length of the \(content.count) signed bytes") }
    return (content, signature)
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

let (content, feedSignature) = signedPart(of: data)
guard key.isValidSignature(feedSignature, for: content)
else { fail("the feed's edSignature does not verify: it was changed after signing, or signed with another key") }
print("feed signature verifies over \(content.count) of \(data.count) bytes")

// A build with SURequireSignedFeed parses only the signed bytes; builds without it parse the whole file.
let delegate = FeedParser()
let xml = XMLParser(data: content)
xml.delegate = delegate
guard xml.parse() else { fail("XML did not parse: \(xml.parserError?.localizedDescription ?? "?")") }
let whole = XMLParser(data: data)
guard whole.parse() else {
    fail("the file with its signing block did not parse as XML: \(whole.parserError?.localizedDescription ?? "?")")
}
let items = delegate.items
guard !items.isEmpty else { fail("no <item> entries") }

var seen = Set<String>()
for (index, item) in items.enumerated() {
    let label = item.shortVersion.isEmpty ? "item \(index)" : item.shortVersion
    if let delta = item.enclosures.first(where: \.isDelta) {
        fail("\(label): lists a delta update (\(delta.url)), which appcast.sh never uploads")
    }
    guard item.enclosures.count == 1
    else { fail("\(label): expected one enclosure, found \(item.enclosures.count)") }
    let enclosure = item.enclosures[0]
    guard enclosure.url.hasPrefix(expectedPrefix) else { fail("\(label): enclosure URL not under \(expectedPrefix)") }
    guard !item.version.isEmpty, !item.shortVersion.isEmpty else { fail("\(label): missing sparkle version") }
    guard let sig = Data(base64Encoded: enclosure.signature), sig.count == 64
    else { fail("\(label): missing or malformed edSignature") }
    guard seen.insert(item.version).inserted else { fail("\(label): duplicate sparkle:version \(item.version)") }
}
print("\(items.count) item(s): URLs, versions and signatures well-formed")

if let archivesDir {
    for item in items {
        let enclosure = item.enclosures[0]
        guard let name = URL(string: enclosure.url)?.lastPathComponent
        else { fail("\(item.shortVersion): the enclosure URL is not a URL") }
        let path = (archivesDir as NSString).appendingPathComponent(name)
        guard let file = FileManager.default.contents(atPath: path)
        else { fail("\(item.shortVersion): archive missing in \(archivesDir): \(name)") }
        let sig = Data(base64Encoded: enclosure.signature)!
        guard key.isValidSignature(sig, for: file)
        else { fail("\(item.shortVersion): edSignature does not verify against \(name)") }
    }
    print("all \(items.count) signature(s) verify against \(archivesDir)")
}
print("appcast OK")
