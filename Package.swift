// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeSwitcher",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeSwitcher", targets: ["ClaudeSwitcher"]),
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "SwitcherCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ClaudeSwitcher",
            dependencies: [
                "SwitcherCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"],
            exclude: ["Fixtures"]
        ),
        // Developer tool, not shipped in the app: checks installed vendor CLIs against what
        // SwitcherCore reads (scripts/vendor-drift.sh, docs/vendor-drift.md).
        .target(name: "VendorDrift", dependencies: ["SwitcherCore"]),
        .executableTarget(name: "usageswitch-drift", dependencies: ["VendorDrift"]),
        .testTarget(name: "VendorDriftTests", dependencies: ["VendorDrift", "SwitcherCore"]),
    ],
    swiftLanguageModes: [.v6]
)
