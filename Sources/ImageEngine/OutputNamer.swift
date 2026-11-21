import Foundation

/// Picks `hero.webp`, then `hero-1.webp`, `hero-2.webp`… Never returns a name that exists or is reserved.
/// Comparison is case-insensitive, like the default APFS volume.
public enum OutputNamer {
    public static func destination(
        for source: URL, in directory: URL, reserved: Set<URL>, exists: (URL) -> Bool = defaultExists
    ) -> URL {
        destination(baseName: baseName(for: source.lastPathComponent), in: directory, reserved: reserved, exists: exists)
    }

    public static func destination(
        baseName: String, in directory: URL, reserved: Set<URL>, exists: (URL) -> Bool = defaultExists
    ) -> URL {
        let taken = Set(reserved.map(key))
        var n = 0
        while true {
            let name = n == 0 ? "\(baseName).webp" : "\(baseName)-\(n).webp"
            let candidate = directory.appending(path: name, directoryHint: .notDirectory)
            if !taken.contains(key(candidate)) && !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// File name without extension, made safe for a file name. Empty names become "image".
    public static func baseName(for name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? "image" : base
    }

    public static func defaultExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }
}
