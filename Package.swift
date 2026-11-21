// swift-tools-version: 6.2
// One package, one target per layer or module. Modules depend on NotchCore only and never on each other.
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

func module(_ name: String, deps: [Target.Dependency] = []) -> [Target] {
    [
        .target(name: name, dependencies: ["NotchCore"] + deps, swiftSettings: swift6),
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name), "NotchCore", "NotchCoreTesting"], swiftSettings: swift6),
    ]
}

let package = Package(
    name: "Notcher",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Notcher", targets: ["NotcherApp"]),
        .executable(name: "NotchPlayground", targets: ["NotchPlayground"]),
        .executable(name: "webpify", targets: ["webpify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", .upToNextMinor(from: "1.6.0")),
    ],
    targets: [
        // Shared contract and design kit
        .target(name: "NotchCore", swiftSettings: swift6),
        .target(name: "NotchCoreTesting", dependencies: ["NotchCore"], swiftSettings: swift6),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "NotchCoreTesting"], swiftSettings: swift6),

        // The notch window layer
        .target(name: "NotchUI", dependencies: ["NotchCore"], swiftSettings: swift6),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI", "NotchCore", "NotchCoreTesting"], swiftSettings: swift6),
        .executableTarget(name: "NotchPlayground", dependencies: ["NotchUI", "NotchCore", "NotchCoreTesting"], swiftSettings: swift6),

        // WebP engine and its command-line tool
        .target(name: "ImageEngine", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")], swiftSettings: swift6),
        .testTarget(name: "ImageEngineTests", dependencies: ["ImageEngine"], swiftSettings: swift6),
        .executableTarget(name: "webpify", dependencies: ["ImageEngine", .product(name: "libwebp", package: "libwebp-Xcode")], swiftSettings: swift6),

        // The app: composition root
        .executableTarget(
            name: "NotcherApp",
            dependencies: [
                "NotchCore", "NotchUI", "ImageEngine", "ConvertModule", "ShelfModule", "ClipboardModule",
                "NowPlayingModule", "CalendarModule", "ClaudeAgentsModule",
            ],
            swiftSettings: swift6
        ),
    ]
    + module("ConvertModule", deps: ["ImageEngine"])
    + module("ShelfModule")
    + module("ClipboardModule")
    + module("NowPlayingModule")
    + module("CalendarModule")
    + module("ClaudeAgentsModule")
)
