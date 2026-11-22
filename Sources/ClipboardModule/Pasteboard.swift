import AppKit
import NotchCore

/// What macOS lets Niche do with the general pasteboard (`NSPasteboard.AccessBehavior`, macOS 15.4+).
public enum PasteboardAccess: Sendable, Equatable {
    /// Never asked yet: the first programmatic read shows the system's paste alert.
    case notDetermined
    /// The system asks before each programmatic read.
    case ask
    /// Reads go through silently.
    case allowed
    /// Reads are refused without asking. The user can change this in System Settings.
    case denied
}

/// One thing copied: text or encoded image bytes.
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    /// `type` is the pasteboard type identifier the bytes came from, e.g. `public.png`.
    case image(Data, type: String)
}

/// The pasteboard as the clipboard history sees it. The app uses `SystemPasteboard(.general)`; tests and fixtures
/// use `InMemoryPasteboard` (or `SystemPasteboard` over a uniquely named pasteboard), so the user's clipboard is
/// never read or changed.
@MainActor
public protocol PasteboardAccessing: AnyObject {
    /// Increments whenever the contents change. Reading it does not read the contents.
    var changeCount: Int { get }
    var access: PasteboardAccess { get }
    /// Type identifiers of the current contents.
    func types() -> [String]
    func string() -> String?
    func data(forType type: String) -> Data?
    /// File URLs on the pasteboard (files copied in Finder).
    func fileURLs() -> [URL]
    /// Replaces the contents and returns the change count afterwards.
    @discardableResult func write(_ content: ClipboardContent) -> Int
}

public enum PasteboardTypes {
    public static let plainText = NSPasteboard.PasteboardType.string.rawValue
    public static let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
    /// Image types we keep, most preferred first.
    public static let images = ["public.png", "public.jpeg", "public.heic", "org.webmproject.webp", "com.compuserve.gif", "public.tiff"]
}

/// `NSPasteboard`-backed implementation.
@MainActor
public final class SystemPasteboard: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    /// The user's clipboard. Only the app uses this.
    public static func general() -> SystemPasteboard { SystemPasteboard(.general) }

    public var changeCount: Int { pasteboard.changeCount }

    public var access: PasteboardAccess {
        switch pasteboard.accessBehavior {
        case .default: .notDetermined
        case .ask: .ask
        case .alwaysAllow: .allowed
        case .alwaysDeny: .denied
        @unknown default: .ask
        }
    }

    public func types() -> [String] { pasteboard.types?.map(\.rawValue) ?? [] }
    public func string() -> String? { pasteboard.string(forType: .string) }
    public func data(forType type: String) -> Data? { pasteboard.data(forType: NSPasteboard.PasteboardType(type)) }

    public func fileURLs() -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    @discardableResult
    public func write(_ content: ClipboardContent) -> Int {
        pasteboard.clearContents()
        switch content {
        case .text(let text): pasteboard.setString(text, forType: .string)
        case .image(let data, let type): pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        return pasteboard.changeCount
    }
}

/// A pasteboard that lives in memory: for tests, fixtures and the playground. Counts every access.
@MainActor
public final class InMemoryPasteboard: PasteboardAccessing {
    private var storedChangeCount = 0
    private var storedAccess: PasteboardAccess
    private var contents: [(type: String, data: Data)] = []

    /// Every read of `changeCount`, `access`, `types()`, `string()` or `data(forType:)`.
    public private(set) var reads = 0
    /// Reads of the contents only (`types()`, `string()`, `data(forType:)`).
    public private(set) var contentReads = 0
    public private(set) var writes: [ClipboardContent] = []

    public init(access: PasteboardAccess = .allowed) { storedAccess = access }

    public var changeCount: Int { reads += 1; return storedChangeCount }
    public var access: PasteboardAccess { reads += 1; return storedAccess }

    public func types() -> [String] { reads += 1; contentReads += 1; return contents.map(\.type) }

    public func string() -> String? {
        reads += 1; contentReads += 1
        return contents.first { $0.type == PasteboardTypes.plainText }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    public func data(forType type: String) -> Data? {
        reads += 1; contentReads += 1
        return contents.first { $0.type == type }?.data
    }

    public func fileURLs() -> [URL] {
        reads += 1; contentReads += 1
        return contents.filter { $0.type == PasteboardTypes.fileURL }
            .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
            .filter(\.isFileURL)
    }

    @discardableResult
    public func write(_ content: ClipboardContent) -> Int {
        writes.append(content)
        switch content {
        case .text(let text): setContents([(PasteboardTypes.plainText, Data(text.utf8))])
        case .image(let data, let type): setContents([(type, data)])
        }
        return storedChangeCount
    }

    // MARK: Simulating other apps

    /// Another app copied these representations (type identifier, bytes).
    public func setContents(_ representations: [(String, Data)]) {
        contents = representations.map { (type: $0.0, data: $0.1) }
        storedChangeCount += 1
    }

    /// Another app copied text, optionally with marker types such as `org.nspasteboard.ConcealedType`.
    public func copy(text: String, markers: [String] = []) {
        setContents([(PasteboardTypes.plainText, Data(text.utf8))] + markers.map { ($0, Data()) })
    }

    /// Finder copied these files (the file names come along as text, as in Finder).
    public func copy(files: [URL], markers: [String] = []) {
        setContents(
            files.map { (PasteboardTypes.fileURL, Data($0.absoluteString.utf8)) }
                + [(PasteboardTypes.plainText, Data(files.map(\.lastPathComponent).joined(separator: "\r").utf8))]
                + markers.map { ($0, Data()) }
        )
    }

    /// Another app copied an image.
    public func copy(image: Data, type: String = "public.png", markers: [String] = []) {
        setContents([(type, image)] + markers.map { ($0, Data()) })
    }

    public func setAccess(_ access: PasteboardAccess) { storedAccess = access }
}
