import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// Finds screenshots and tells the module when the set changes. Injected so tests and fixtures never read a real folder.
@MainActor
public protocol ScreenshotSource: AnyObject {
    /// Begins watching. `deliver` receives the full current set every time it changes; the first call is
    /// marked `isInitial`. Idempotent. Reads the folder, so macOS may ask for access to it.
    func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void)
    /// Ends the watch. No delivery happens after it returns. Idempotent.
    func stop()
    /// Reads the folder new screenshots are saved in, so that macOS asks for access there and then, while the user
    /// is looking at the button they just clicked. Called only on that click (or with `mayPrompt`).
    func requestFolderAccess() async -> FolderAccess
}

/// Watches the folder macOS saves screenshots in and lists the images in it.
///
/// Spotlight is deliberately not used: its index can be switched off, excluded or rebuilding, and other screenshot
/// tools do not set its screen-capture flag. The folder is read directly instead: its listing, each file's
/// attributes, and the header of the newest images for their pixel size.
@MainActor
public final class FolderScreenshotSource: ScreenshotSource {
    private let folder: @Sendable () -> URL
    private let now: @MainActor () -> Date
    private let lookback: TimeInterval
    private let settle: Duration
    private let followUp: Duration
    private var deliver: (@MainActor (ScreenshotBatch) -> Void)?
    private var watched: URL?
    private var watcher: (any DispatchSourceFileSystemObject)?
    private var scanTask: Task<Void, Never>?
    private var gathered = false

    /// - Parameters:
    ///   - folder: where screenshots are saved; asked once per `start`.
    ///   - lookback: how far back a scan reaches. Older screenshots are never listed anyway.
    ///   - settle: how long after the folder changes it is read, so a file being written is finished first.
    ///   - followUp: how long after that it is read once more, for a tool that writes its file in two steps.
    public init(
        folder: @escaping @Sendable () -> URL = FolderScreenshotSource.screenshotFolder,
        now: @escaping @MainActor () -> Date = { Date() },
        lookback: TimeInterval = ScreenshotList.window,
        settle: Duration = .milliseconds(400),
        followUp: Duration = .seconds(2)
    ) {
        self.folder = folder
        self.now = now
        self.lookback = lookback
        self.settle = settle
        self.followUp = followUp
    }

    public func start(_ deliver: @escaping @MainActor (ScreenshotBatch) -> Void) {
        guard self.deliver == nil else { return }
        self.deliver = deliver
        gathered = false
        let folder = folder()
        watched = folder
        watch(folder)
        scan(after: [.zero])
    }

    public func stop() {
        scanTask?.cancel(); scanTask = nil
        watcher?.cancel(); watcher = nil
        watched = nil
        deliver = nil
        gathered = false
    }

    public func requestFolderAccess() async -> FolderAccess {
        let folder = folder()
        return await Task.detached(priority: .userInitiated) { Self.probe(folder) }.value
    }

    /// Asks the kernel to say when entries in the folder change. A folder that cannot be opened is simply not
    /// watched: the first scan then reports nothing, and `start` after `stop` tries again.
    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func folderChanged() {
        guard let watched, let watcher else { return }
        // The folder itself was renamed or removed: follow the path, not the old folder.
        if !watcher.data.isDisjoint(with: [.rename, .delete]) {
            watcher.cancel()
            self.watcher = nil
            watch(watched)
        }
        scan(after: [settle, followUp])
    }

    /// Reads the folder after each delay in turn, off the main actor. A change that arrives meanwhile starts over.
    private func scan(after delays: [Duration]) {
        scanTask?.cancel()
        guard let folder = watched else { return }
        scanTask = Task { [weak self] in
            for delay in delays {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self else { return }
                let since = self.now().addingTimeInterval(-self.lookback)
                let shots = await Task.detached(priority: .utility) { Self.scan(folder, since: since) }.value
                guard !Task.isCancelled, let deliver = self.deliver else { return }
                let initial = !self.gathered
                self.gathered = true
                deliver(ScreenshotBatch(screenshots: shots, isInitial: initial))
            }
        }
    }

    // MARK: Reading the folder

    /// The most screenshots one scan describes: well above what the page lists.
    nonisolated static let scanLimit = 48
    nonisolated static let screenCaptureFlag = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Where the screenshot tool saves (`defaults read com.apple.screencapture location`), else the Desktop.
    public nonisolated static func screenshotFolder() -> URL {
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

    /// The screenshots in `folder` taken since `since`, newest first.
    /// - Parameter dedicated: whether every image in the folder counts; worked out from the path when `nil`.
    nonisolated static func scan(_ folder: URL, since: Date, dedicated: Bool? = nil, limit: Int = scanLimit) -> [Screenshot] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let listing = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )
        guard let listing else { return [] }
        let dedicated = dedicated ?? isDedicated(folder)
        var found: [Screenshot] = []
        for url in listing {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let type = values.contentType, let created = values.creationDate ?? values.contentModificationDate,
                  isScreenshot(type: type, created: created, since: since, inDedicatedFolder: dedicated, isFlagged: hasScreenCaptureFlag(url))
            else { continue }
            found.append(Screenshot(
                url: url, createdAt: created, modifiedAt: values.contentModificationDate,
                bytes: values.fileSize.map(Int64.init)
            ))
        }
        let newest = withoutConversions(found)
            .sorted { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.dedupeKey < b.dedupeKey }
            .prefix(max(0, limit))
        return newest.map { shot in
            var shot = shot
            shot.pixelSize = pixelSize(of: shot.url)
            return shot
        }
    }

    /// Whether a file in the screenshot folder is listed: a still image (screen recordings are saved there too),
    /// recent, and either carrying the flag macOS puts on its own screenshots or in a folder that holds nothing else.
    nonisolated static func isScreenshot(
        type: UTType, created: Date, since: Date, inDedicatedFolder: Bool, isFlagged: @autoclosure () -> Bool
    ) -> Bool {
        type.conforms(to: .image) && created >= since && (inDedicatedFolder || isFlagged())
    }

    /// A folder of its own for screenshots, where another tool's captures count as well. The Desktop and the other
    /// shared folders hold unrelated pictures, so there only files flagged by macOS are listed.
    nonisolated static func isDedicated(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let shared = [home] + ["Desktop", "Documents", "Downloads", "Pictures"].map { home.appending(path: $0, directoryHint: .isDirectory) }
        return !shared.map(path).contains(path(folder))
    }

    /// Leaves out a WebP that sits beside a picture of the same name: that is a conversion of the screenshot
    /// (Convert writes it next to the original), not another screenshot.
    nonisolated static func withoutConversions(_ shots: [Screenshot]) -> [Screenshot] {
        func stem(_ shot: Screenshot) -> String { shot.url.deletingPathExtension().lastPathComponent }
        func isWebP(_ shot: Screenshot) -> Bool { shot.url.pathExtension.lowercased() == "webp" }
        let originals = Set(shots.filter { !isWebP($0) }.map(stem))
        return shots.filter { !(isWebP($0) && originals.contains(stem($0))) }
    }

    /// Reads the flag macOS writes on a screenshot it takes: an extended attribute, so no Spotlight and no file contents.
    nonisolated static func hasScreenCaptureFlag(_ url: URL) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 128)
        let length = getxattr(url.path, screenCaptureFlag, &buffer, buffer.count, 0, 0)
        guard length > 0 else { return false }
        let value = try? PropertyListSerialization.propertyList(from: Data(buffer[0..<length]), format: nil)
        return value as? Bool ?? false
    }

    /// The picture's size from its header; the pixels are not decoded.
    nonisolated static func pixelSize(of url: URL) -> PixelSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        return PixelSize(width: width, height: height)
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
