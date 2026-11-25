import Foundation
import Testing
import SwitcherCore

@Suite("Product info")
struct ProductInfoTests {
    @Test("the fallback version is the version the app ships as")
    func fallbackVersionMatchesTheBundle() throws {
        // Used when the running build has no Info.plist (`swift run`): it is sent to Codex and
        // Devin as this app's version, so a release that bumps the bundle must bump it too.
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let shipped = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(ProductInfo.fallbackVersion == shipped)
    }
}
