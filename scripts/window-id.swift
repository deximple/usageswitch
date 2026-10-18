// Prints the CGWindowID of the first on-screen window owned by the given app name (for `screencapture -l`).
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.dropFirst().first ?? "UsageSwitch"
let title = CommandLine.arguments.dropFirst(2).first
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    if let title, (w[kCGWindowName as String] as? String) != title { continue }
    print(w[kCGWindowNumber as String] as? Int ?? 0); exit(0)
}
exit(1)
