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
    /// - Parameter promisedTypes: per file-promise receiver, the type identifiers it promises.
    public static func preview(fileURLs: [URL], promisedTypes: [[String]], hasImage: Bool, hasText: Bool) -> [DropItem] {
        if !fileURLs.isEmpty { return fileURLs.map(DropItem.file) }
        let promised = promisedTypes.enumerated().flatMap { receiver, types in
            types.enumerated().map { file, type in DropItem.file(promisePlaceholder(receiver: receiver, file: file, type: type)) }
        }
        if !promised.isEmpty { return promised }
        if hasImage { return [.imageData(Data(), suggestedName: nil)] }
        if hasText { return [.text("")] }
        return []
    }

    /// A stand-in URL for a promised file that has not been written yet; only its extension is meaningful.
    static func promisePlaceholder(receiver: Int, file: Int, type identifier: String) -> URL {
        let ext = UTType(identifier)?.preferredFilenameExtension ?? "data"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "niche-promised-\(receiver)-\(file).\(ext)")
    }
}

/// Whether anything would take a drag, decided before the drop target opens and again at drop time, so drags nobody
/// wants (selected text, links, browser tabs) pass by untouched and are never swallowed.
@MainActor
public enum DropDecision {
    /// True when at least one enabled module would receive at least one of the items.
    public static func accepts(_ items: [DropItem], optionKey: Bool, among modules: [any NotchModule]) -> Bool {
        !items.isEmpty && !DropRouter.route(DropPayload(items: items, optionKey: optionKey), among: modules).isEmpty
    }

    /// Which file-promise receivers (given each one's promised type identifiers) hold something a module accepts.
    /// Only those are received, so nothing is written to disk for content no module will take.
    public static func acceptedPromises(_ promisedTypes: [[String]], optionKey: Bool, among modules: [any NotchModule]) -> [Int] {
        var owner: [URL: Int] = [:]
        var items: [DropItem] = []
        for (receiver, types) in promisedTypes.enumerated() {
            for (file, type) in types.enumerated() {
                let url = DropItems.promisePlaceholder(receiver: receiver, file: file, type: type)
                owner[url] = receiver
                items.append(.file(url))
            }
        }
        let routed = DropRouter.route(DropPayload(items: items, optionKey: optionKey), among: modules)
            .flatMap(\.payload.items).compactMap { $0.fileURL.flatMap { owner[$0] } }
        return Array(Set(routed)).sorted()
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
            promisedTypes: urls.isEmpty ? promises(pb).map(\.fileTypes) : [],
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
        q.name = "niche.file-promises"
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Files a receiver will deliver. `fileNames` can be empty until the receiver is primed, so the promised types
    /// count too; at least one.
    static func expectedFileCount(fileNames: Int, fileTypes: Int) -> Int { max(1, fileNames, fileTypes) }

    /// Receives every receiver concurrently and returns what arrived, waiting at most `timeout` overall.
    static func receive(_ receivers: [NSFilePromiseReceiver], into directory: URL, timeout: Duration = .seconds(60)) async -> [URL] {
        guard !receivers.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let collector = PromiseCollector()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            collector.begin(continuation)
            var expected = 0
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                    collector.add(error == nil ? url : nil)
                }
                expected += expectedFileCount(fileNames: receiver.fileNames.count, fileTypes: receiver.fileTypes.count)
            }
            collector.expect(expected)
            Task { try? await Task.sleep(for: timeout); collector.finish() }
        }
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
