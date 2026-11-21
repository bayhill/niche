// swift-tools-version: 6.2
// FROZEN after contracts-v1. Only the orchestrator edits this file.
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
        // Contracts (orchestrator)
        .target(name: "NotchCore", swiftSettings: swift6),
        .target(name: "NotchCoreTesting", dependencies: ["NotchCore"], swiftSettings: swift6),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "NotchCoreTesting"], swiftSettings: swift6),

        // Agent A
        .target(name: "NotchUI", dependencies: ["NotchCore"], swiftSettings: swift6),
        .testTarget(name: "NotchUITests", dependencies: ["NotchUI", "NotchCore", "NotchCoreTesting"], swiftSettings: swift6),
        .executableTarget(name: "NotchPlayground", dependencies: ["NotchUI", "NotchCore", "NotchCoreTesting"], swiftSettings: swift6),

        // Agent B
        .target(name: "ImageEngine", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")], swiftSettings: swift6),
        .testTarget(name: "ImageEngineTests", dependencies: ["ImageEngine"], swiftSettings: swift6),
        .executableTarget(name: "webpify", dependencies: ["ImageEngine", .product(name: "libwebp", package: "libwebp-Xcode")], swiftSettings: swift6),

        // Composition root (orchestrator)
        .executableTarget(
            name: "NotcherApp",
            dependencies: [
                "NotchCore", "NotchUI", "ImageEngine", "ConvertModule", "ShelfModule", "ClipboardModule",
                "NowPlayingModule", "CalendarModule", "ClaudeAgentsModule",
            ],
            swiftSettings: swift6
        ),
    ]
    + module("ConvertModule", deps: ["ImageEngine"])   // Agent B
    + module("ShelfModule")                            // Agent C
    + module("ClipboardModule")                        // Agent C
    + module("NowPlayingModule")                       // Agent D
    + module("CalendarModule")                         // Agent D
    + module("ClaudeAgentsModule")                     // Agent E
)
