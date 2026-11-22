import Foundation

/// What counts as a dev server when the page does not list every listening process.
///
/// A dev server was started from a project folder: its working directory is inside the home folder (but is not
/// the home folder itself), and its executable is neither an app nor part of macOS. That leaves out apps
/// (music players, container tools, editors' helpers), launchd services (their working directory is `/`) and system tools.
public enum DevServerFilter {
    /// Folders whose executables are part of macOS or installed system-wide.
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/Library/"]
    /// Developer tools and interpreters under `/Library` (the Command Line Tools, python.org's Python), which do run
    /// dev servers.
    static let developerPrefixes = ["/Library/Developer/", "/Library/Frameworks/"]

    public static func isDevServer(_ server: DevServer, home: String) -> Bool {
        isProjectFolder(server.workingDirectory, home: home) && !isAppOrSystem(server.executablePath)
    }

    /// Inside `home`, not `home` itself. An unknown directory is not a project folder.
    public static func isProjectFolder(_ directory: String?, home: String) -> Bool {
        guard let directory else { return false }
        let dir = normalised(directory), root = normalised(home)
        guard !root.isEmpty, root != "/" else { return false }
        return dir.hasPrefix(root + "/") && dir.count > root.count + 1
    }

    /// Inside an `.app` bundle, or under `/System`, `/usr/libexec` or `/Library`. An unknown executable is not.
    ///
    /// Interpreters are an exception: Python's executable lives in a `Python.app` inside `Python.framework` (in
    /// Homebrew, python.org and the Command Line Tools alike), and Xcode's tools live in `Xcode.app/Contents/Developer`.
    public static func isAppOrSystem(_ executable: String?) -> Bool {
        guard let executable else { return false }
        let path = normalised(executable)
        if developerPrefixes.contains(where: path.hasPrefix) { return isInAppBundle(path) }
        if systemPrefixes.contains(where: path.hasPrefix) { return true }
        return isInAppBundle(path)
    }

    static func isInAppBundle(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let innermost = components.lastIndex(where: { $0.hasSuffix(".app") }) else { return false }
        // An app embedded in a framework is an interpreter's launcher (Python.app), not an app.
        if components[..<innermost].contains(where: { $0.hasSuffix(".framework") }) { return false }
        // Xcode's command-line tools.
        if components.count > innermost + 2, components[innermost + 1] == "Contents", components[innermost + 2] == "Developer" {
            return false
        }
        return true
    }

    /// Drops a trailing slash so `/Users/a/` and `/Users/a` compare equal.
    private static func normalised(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
