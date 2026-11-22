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

// One feature module per entry: the name, and what it needs besides NotchCore.
let modules: [(name: String, deps: [Target.Dependency])] = [
    ("ConvertModule", ["ImageEngine"]),
    ("ShelfModule", []),
    ("ClipboardModule", []),
    ("NowPlayingModule", []),
    ("CalendarModule", []),
    ("ClaudeAgentsModule", []),
    ("ScreenshotsModule", []),
    ("ColourModule", []),
    ("DevServersModule", []),
    ("BuildsModule", []),
]

// Built up in statements: one long chain of `+` is more than older compilers will type-check in a manifest.
var targets: [Target] = [
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
]

// The app: composition root
let appDependencies: [Target.Dependency] = ["NotchCore", "NotchUI", "ImageEngine"] + modules.map { Target.Dependency(stringLiteral: $0.name) }
targets.append(.executableTarget(name: "NicheApp", dependencies: appDependencies, swiftSettings: swift6))
for entry in modules {
    targets += module(entry.name, deps: entry.deps)
}

let package = Package(
    name: "Niche",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Niche", targets: ["NicheApp"]),
        .executable(name: "NotchPlayground", targets: ["NotchPlayground"]),
        .executable(name: "webpify", targets: ["webpify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", .upToNextMinor(from: "1.6.0")),
    ],
    targets: targets
)
