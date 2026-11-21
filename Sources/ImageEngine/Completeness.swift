import Darwin
import Foundation
import UniformTypeIdentifiers

/// Structural checks that catch files cut off mid-download, which ImageIO happily decodes with a blank remainder.
/// Formats without a check here pass.
enum ImageCompleteness {
    static func isComplete(_ data: Data, type: UTType?) -> Bool {
        guard let type else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            if type.conforms(to: .jpeg) { return jpeg(b) }
            if type.conforms(to: .png) { return png(b) }
            if type.conforms(to: .gif) { return gif(b) }
            if type.conforms(to: .heic) || type.conforms(to: .heif) || type.identifier == "public.avif" { return isoBMFF(b) }
            return true
        }
    }

    /// An end-of-image marker after the first start-of-scan. Inside entropy-coded data 0xFF is always stuffed
    /// (FF 00) or a restart marker, so FF D9 there can only be the real EOI. Data appended after it (MPF gain
    /// maps, depth) does not matter: the primary image is whole.
    static func jpeg(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return false }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return false }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }  // fill byte
            if marker == 0xD9 { return false }       // EOI before any scan
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return false }
            if marker == 0xDA {
                // Search backwards: a whole file has its EOI at (or near) the end.
                let scan = i + 2 + length
                var j = b.count - 2
                while j >= scan {
                    if b[j] == 0xFF && b[j + 1] == 0xD9 { return true }
                    j -= 1
                }
                return false
            }
            i += 2 + length
        }
        return false
    }

    /// Every chunk fits, up to and including IEND.
    static func png(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard b.count >= 8 else { return false }
        var i = 8
        while i + 12 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let isEnd = b[i + 4] == 0x49 && b[i + 5] == 0x45 && b[i + 6] == 0x4E && b[i + 7] == 0x44  // "IEND"
            let next = i + 12 + length
            guard length >= 0, next <= b.count else { return false }
            if isEnd { return true }
            i = next
        }
        return false
    }

    /// The trailer byte, allowing trailing padding.
    static func gif(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        var end = b.count - 1
        while end > 0 && b[end] == 0 { end -= 1 }
        return end > 6 && b[end] == 0x3B
    }

    /// Top-level boxes tile the file exactly (a cut file ends inside its last box).
    static func isoBMFF(_ b: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        while i < b.count {
            guard i + 8 <= b.count else { return false }
            var size = UInt64(b[i]) << 24 | UInt64(b[i + 1]) << 16 | UInt64(b[i + 2]) << 8 | UInt64(b[i + 3])
            if size == 1 {
                guard i + 16 <= b.count else { return false }
                size = (8..<16).reduce(UInt64(0)) { $0 << 8 | UInt64(b[i + $1]) }
            } else if size == 0 {
                return true  // box runs to the end of the file
            }
            guard size >= 8, size <= UInt64(b.count - i) else { return false }
            i += Int(size)
        }
        return true
    }
}

/// Whether a file's content is actually on this Mac.
enum FileAvailability {
    static func problem(at url: URL) -> ConversionError? {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        var info = stat()
        let flags = stat(url.path, &info) == 0 ? info.st_flags : nil
        return problem(isUbiquitous: values?.isUbiquitousItem, status: values?.ubiquitousItemDownloadingStatus, flags: flags)
    }

    /// - Parameter flags: `st_flags`, or `nil` when the file does not exist.
    static func problem(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?, flags: UInt32?) -> ConversionError? {
        guard let flags else { return .decodeFailed }
        if isUbiquitous == true, let status, status != .current { return .notDownloaded }
        if flags & UInt32(SF_DATALESS) != 0 { return .notDownloaded }
        return nil
    }
}
