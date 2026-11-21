import AppKit
import NotchCore
import Synchronization
import UniformTypeIdentifiers

public extension DropHint {
    /// Shown when no module offers a hint.
    static let fallback = DropHint(title: "Drop", symbol: "tray.and.arrow.down")
}

/// Turning drag pasteboard contents into `DropItem`s. The pure parts are separated from pasteboard access for tests.
public enum DropItems {
    /// Final items, by precedence: files (dropped or delivered from promises), else raw image data, else text.
    public static func resolve(fileURLs: [URL], imageData: Data?, text: String?) -> [DropItem] {
        if !fileURLs.isEmpty { return fileURLs.map(DropItem.file) }
        if let imageData, !imageData.isEmpty { return [.imageData(imageData, suggestedName: nil)] }
        if let text, !text.isEmpty { return [.text(text)] }
        return []
    }

    /// Cheap stand-ins used to ask modules for a hint while the drag is still in flight.
    /// Promised files are represented by a placeholder URL with the promised type's extension.
    public static func preview(fileURLs: [URL], promisedTypes: [String], hasImage: Bool, hasText: Bool) -> [DropItem] {
        if !fileURLs.isEmpty { return fileURLs.map(DropItem.file) }
        if !promisedTypes.isEmpty {
            return promisedTypes.enumerated().map { index, identifier in
                let ext = UTType(identifier)?.preferredFilenameExtension ?? "data"
                return .file(URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "promised-\(index).\(ext)"))
            }
        }
        if hasImage { return [.imageData(Data(), suggestedName: nil)] }
        if hasText { return [.text("")] }
        return []
    }
}

/// Reads a drag pasteboard.
@MainActor
enum DragPasteboard {
    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    struct Contents {
        var fileURLs: [URL]
        var promises: [NSFilePromiseReceiver]
        var imageData: Data?
        var text: String?
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func promises(_ pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }

    static func preview(_ pb: NSPasteboard) -> [DropItem] {
        let urls = fileURLs(pb)
        return DropItems.preview(
            fileURLs: urls,
            promisedTypes: urls.isEmpty ? promises(pb).flatMap(\.fileTypes) : [],
            hasImage: pb.availableType(from: [.png, .tiff]) != nil,
            hasText: pb.availableType(from: [.string]) != nil
        )
    }

    static func read(_ pb: NSPasteboard) -> Contents {
        let urls = fileURLs(pb)
        let promised = urls.isEmpty ? promises(pb) : []
        let needsData = urls.isEmpty && promised.isEmpty
        return Contents(
            fileURLs: urls, promises: promised,
            imageData: needsData ? (pb.data(forType: .png) ?? pb.data(forType: .tiff)) : nil,
            text: needsData ? pb.string(forType: .string) : nil
        )
    }
}

/// Receives promised files (Mail attachments, Photos, browser images) into a folder.
@MainActor
enum FilePromises {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "notcher.file-promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    static func receive(_ receivers: [NSFilePromiseReceiver], into directory: URL, timeout: Duration = .seconds(60)) async -> [URL] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for receiver in receivers {
            let collector = PromiseCollector()
            urls += await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
                collector.begin(continuation)
                receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                    collector.add(error == nil ? url : nil)
                }
                collector.expect(max(1, receiver.fileNames.count))
                Task { try? await Task.sleep(for: timeout); collector.finish() }
            }
        }
        return urls
    }
}

/// Collects reader callbacks from any queue and resumes once with every delivered URL.
private final class PromiseCollector: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[URL], Never>?
        var expected: Int?
        var callbacks = 0
        var urls: [URL] = []
    }
    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<[URL], Never>) { state.withLock { $0.continuation = continuation } }

    func expect(_ count: Int) {
        state.withLock { $0.expected = count }
        resumeIfDone()
    }

    func add(_ url: URL?) {
        state.withLock { s in
            s.callbacks += 1
            if let url { s.urls.append(url) }
        }
        resumeIfDone()
    }

    func finish() {
        let pending = state.withLock { s -> (CheckedContinuation<[URL], Never>, [URL])? in
            guard let c = s.continuation else { return nil }
            s.continuation = nil
            return (c, s.urls)
        }
        pending.map { $0.0.resume(returning: $0.1) }
    }

    private func resumeIfDone() {
        let done = state.withLock { s in s.expected.map { s.callbacks >= $0 } ?? false }
        if done { finish() }
    }
}
