import CoreGraphics
import Foundation
import Synchronization
import ImageIO
import NotchCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A scriptable module for tests and the playground.
@MainActor
@Observable
public final class FakeModule: NotchModule {
    public let id: ModuleID
    public var title: String
    public var symbol: String
    public var placement: PanelPlacement
    public var liveActivity: LiveActivity?
    public var nudge: Nudge?
    public var requirements: [PermissionRequirement] = []
    public var acceptance: @MainActor (DropItem) -> DropAcceptance = { _ in .reject }
    public var hint: DropHint?
    public var view: AnyView
    public private(set) var started = false
    public private(set) var startCount = 0
    public private(set) var drops: [DropPayload] = []
    /// Nudge ids the user acted on / dismissed, in order. Either one clears `nudge`, as a real module would.
    public private(set) var nudgeActions: [Nudge.ID] = []
    public private(set) var nudgeDismissals: [Nudge.ID] = []

    public init(
        _ id: ModuleID, title: String? = nil, symbol: String = "square.dashed", placement: PanelPlacement = .hidden,
        liveActivity: LiveActivity? = nil, view: AnyView? = nil
    ) {
        self.id = id; self.title = title ?? id.rawValue.capitalized; self.symbol = symbol
        self.placement = placement; self.liveActivity = liveActivity
        self.view = view ?? AnyView(GlassCard { SectionHeader(title ?? id.rawValue.capitalized, symbol: symbol) })
    }

    public func start(_ context: ModuleContext) async { started = true; startCount += 1 }
    public func stop() { started = false }
    public func panelView() -> AnyView { view }
    public func dropAcceptance(for item: DropItem) -> DropAcceptance { acceptance(item) }
    public func dropHint(for items: [DropItem]) -> DropHint? { hint }
    public func handleDrop(_ payload: DropPayload) async { drops.append(payload) }
    public func performNudgeAction(_ id: Nudge.ID) { nudgeActions.append(id); if nudge?.id == id { nudge = nil } }
    public func dismissNudge(_ id: Nudge.ID) { nudgeDismissals.append(id); if nudge?.id == id { nudge = nil } }
}

@MainActor
public final class RecordingConverter: ImageConverting {
    public private(set) var requests: [[ConversionSource]] = []
    public init() {}
    public func convert(_ sources: [ConversionSource]) { requests.append(sources) }
}

@MainActor
public final class RecordingShelf: ShelfAccepting {
    public private(set) var added: [(urls: [URL], origin: ShelfOrigin)] = []
    public init() {}
    public func add(_ urls: [URL], origin: ShelfOrigin) { added.append((urls, origin)) }
}

@MainActor
public final class RecordingPlayback: PlaybackControlling {
    public private(set) var pauses = 0
    public init() {}
    public func pauseIfPlaying() { pauses += 1 }
}

@MainActor
public final class RecordingNotchController: NotchControlling {
    public enum Call: Equatable { case expand(ModuleID?), collapse, toggle }
    public private(set) var calls: [Call] = []
    public init() {}
    public func expand(page: ModuleID?) { calls.append(.expand(page)) }
    public func collapse() { calls.append(.collapse) }
    public func toggle() { calls.append(.toggle) }
}

/// A self-contained environment rooted in a fresh temporary directory. Nothing touches the user's real files.
@MainActor
public struct TestEnvironment {
    public let root: URL
    public let directories: AppDirectories
    public let settings: SettingsStore
    public let services: AppServices
    public let converter = RecordingConverter()
    public let shelf = RecordingShelf()
    public let notch = RecordingNotchController()
    public let playback = RecordingPlayback()

    public init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "niche-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        directories = .rooted(at: root)
        for dir in [directories.appSupport, directories.caches, directories.downloads, directories.home] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        settings = .ephemeral()
        services = AppServices()
        services.converter = converter
        services.shelf = shelf
        services.notch = notch
        services.playback = playback
    }

    public func context(for module: ModuleID, mayPrompt: Bool = false) -> ModuleContext {
        ModuleContext(services: services, settings: settings, directories: directories, mayPrompt: mayPrompt, log: Log.logger(for: module))
    }

    public func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

public extension ScreenMetrics {
    /// The development machine: 14" MacBook Pro at the "More Space" scaling (1800×1169), notch 220×38.
    static let mbp14MoreSpace = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: 0, y: 73, width: 1800, height: 1057),
        safeTop: 38, auxLeft: CGRect(x: 0, y: 1131, width: 790, height: 38), auxRight: CGRect(x: 1010, y: 1131, width: 790, height: 38)
    )
    /// 14" MacBook Pro at default scaling (1512×982), notch 185×32.
    static let mbp14Default = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeTop: 32, auxLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), auxRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
    )
    /// External 1080p display to the right of a 1512-wide primary: no notch, 25 pt menu bar.
    static let external1080p = ScreenMetrics(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
        safeTop: 0, auxLeft: nil, auxRight: nil, scale: 1, maximumFramesPerSecond: 60
    )
    /// Notchless display with an auto-hiding menu bar.
    static let externalHiddenMenuBar = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeTop: 0, auxLeft: nil, auxRight: nil, scale: 2, maximumFramesPerSecond: 60
    )
}

/// Tiny generated images for tests and fixtures.
public enum TestImage {
    /// A solid-colour sRGB image. Components are 0...1.
    public static func solid(width: Int = 8, height: Int = 8, red: Double = 1, green: Double = 0, blue: Double = 0, alpha: Double = 1) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Encodes with ImageIO (PNG by default).
    public static func data(_ image: CGImage, type: UTType = .png) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Writes an encoded image to disk and returns the URL.
    @discardableResult
    public static func write(_ image: CGImage, to url: URL, type: UTType = .png) throws -> URL {
        try data(image, type: type).write(to: url)
        return url
    }
}

/// Runs nothing: records each command and answers from `respond`.
public final class ScriptedCommandRunner: CommandRunning {
    public struct Call: Sendable, Equatable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]?
    }

    private let state = Mutex<[Call]>([])
    private let respond: @Sendable (Call) -> CommandResult

    /// - Parameter respond: the result for each command; called on whatever thread the command was run from.
    public init(_ respond: @escaping @Sendable (Call) -> CommandResult = { _ in CommandResult(status: 0) }) {
        self.respond = respond
    }

    public var calls: [Call] { state.withLock { $0 } }

    public func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment)
        state.withLock { $0.append(call) }
        return respond(call)
    }
}
