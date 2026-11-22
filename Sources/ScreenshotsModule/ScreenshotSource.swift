import Foundation

/// One delivery from a `ScreenshotSource`: every screenshot it currently knows about.
public struct ScreenshotBatch: Sendable, Equatable {
    public var screenshots: [Screenshot]
    /// True for the first delivery after `start` (what was already there); false for live updates after it.
    public var isInitial: Bool

    public init(screenshots: [Screenshot], isInitial: Bool) {
        self.screenshots = screenshots; self.isInitial = isInitial
    }
}

/// What touching the screenshot folder found out.
public enum FolderAccess: Sendable, Equatable {
    case granted
    /// macOS refused (Privacy & Security › Files and Folders).
    case denied
    /// Anything else: the folder is missing, or the check could not tell.
    case unknown
}

/// Finds screenshots and tells the module when the set changes. Injected so tests and fixtures never query Spotlight.
@MainActor
public protocol ScreenshotSource: AnyObject {
    /// Begins a live search. `deliver` receives the full current set every time it changes; the first call is
    /// marked `isInitial`. Idempotent. Must not open or read any file: the results come from the Spotlight index.
    func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void)
    /// Ends the search. No delivery happens after it returns. Idempotent.
    func stop()
    /// Reads the folder new screenshots are saved in, so that macOS asks for access there and then, while the user
    /// is looking at the button they just clicked. Called only on that click (or with `mayPrompt`).
    func requestFolderAccess() async -> FolderAccess
}

/// A live Spotlight query for `kMDItemIsScreenCapture == 1`, so it finds screenshots wherever they are saved and
/// whatever the file names say (they are localised). Results come from the index: nothing here opens a screenshot.
@MainActor
public final class SpotlightScreenshotSource: ScreenshotSource {
    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    private var deliver: (@MainActor (ScreenshotBatch) -> Void)?
    private var gathered = false
    private let now: @MainActor () -> Date
    private let lookback: TimeInterval

    /// - Parameter lookback: how far back the query reaches at start. Older screenshots are never listed anyway.
    public init(now: @escaping @MainActor () -> Date = { Date() }, lookback: TimeInterval = ScreenshotList.window) {
        self.now = now
        self.lookback = lookback
    }

    public func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void) {
        guard query == nil else { return }
        self.deliver = deliver
        gathered = false
        let query = NSMetadataQuery()
        let since = now().addingTimeInterval(-lookback)
        query.predicate = NSPredicate(
            format: "%K == 1 AND %K >= %@", Attribute.isScreenCapture, Attribute.contentCreated, since as NSDate
        )
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.5
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish(initial: true) }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish(initial: false) }
            },
        ]
        self.query = query
        query.start()
    }

    public func stop() {
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        deliver = nil
        gathered = false
    }

    public func requestFolderAccess() async -> FolderAccess {
        let folder = Self.screenshotFolder()
        return await Task.detached(priority: .userInitiated) { Self.probe(folder) }.value
    }

    private func publish(initial: Bool) {
        guard let query, let deliver else { return }
        if initial { gathered = true } else if !gathered { return }
        query.disableUpdates()
        var shots: [Screenshot] = []
        shots.reserveCapacity(query.resultCount)
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            let shot = Screenshot.fromSpotlight(
                path: item.value(forAttribute: Attribute.path) as? String,
                contentType: item.value(forAttribute: Attribute.contentType) as? String,
                contentCreated: item.value(forAttribute: Attribute.contentCreated) as? Date,
                fileCreated: item.value(forAttribute: Attribute.fileCreated) as? Date,
                modified: item.value(forAttribute: Attribute.contentModified) as? Date,
                pixelWidth: (item.value(forAttribute: Attribute.pixelWidth) as? NSNumber)?.intValue,
                pixelHeight: (item.value(forAttribute: Attribute.pixelHeight) as? NSNumber)?.intValue,
                bytes: (item.value(forAttribute: Attribute.size) as? NSNumber)?.int64Value
            )
            if let shot { shots.append(shot) }
        }
        query.enableUpdates()
        deliver(ScreenshotBatch(screenshots: shots, isInitial: initial))
    }

    private enum Attribute {
        static let isScreenCapture = "kMDItemIsScreenCapture"
        static let path = "kMDItemPath"
        static let contentType = "kMDItemContentType"
        static let contentCreated = "kMDItemContentCreationDate"
        static let contentModified = "kMDItemContentModificationDate"
        static let fileCreated = "kMDItemFSCreationDate"
        static let pixelWidth = "kMDItemPixelWidth"
        static let pixelHeight = "kMDItemPixelHeight"
        static let size = "kMDItemFSSize"
    }

    /// Where the screenshot tool saves (`defaults read com.apple.screencapture location`), else the Desktop.
    nonisolated static func screenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }

    /// Lists the folder (and throws the listing away), which is what makes macOS ask for Desktop or Documents access.
    nonisolated static func probe(_ folder: URL) -> FolderAccess {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return .granted
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .denied
        } catch {
            return .unknown
        }
    }
}

/// Finds nothing. For fixtures.
@MainActor
public final class NoScreenshotSource: ScreenshotSource {
    public init() {}
    public func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void) {}
    public func stop() {}
    public func requestFolderAccess() async -> FolderAccess { .unknown }
}
