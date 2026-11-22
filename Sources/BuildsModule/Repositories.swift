import Foundation

/// A repository picked in Settings: the local folder, and where its runs live.
public struct BuildRepository: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// The folder that holds `.git`, as a plain path.
    public var folderPath: String
    /// Lowercased host name, without a port: `github.com`, or a GitHub Enterprise host.
    public var host: String
    public var owner: String
    public var name: String
    /// The host the user confirmed in Settings for this entry; only needed when `host` is not github.com. An entry
    /// whose confirmed host is missing or differs from `host` (a hand-edited preference, say) is never fetched.
    public var confirmedHost: String?

    public init(folderPath: String, host: String, owner: String, name: String, confirmedHost: String? = nil) {
        self.folderPath = folderPath; self.host = host; self.owner = owner; self.name = name
        self.confirmedHost = confirmedHost
    }

    /// One entry per folder: two worktrees of one repository are two entries, each on its own branch.
    public var id: String { folderPath }
    public var folder: URL { URL(filePath: folderPath, directoryHint: .isDirectory) }
    /// "owner/name".
    public var slug: String { "\(owner)/\(name)" }
    public var isGitHubDotCom: Bool { host == "github.com" }
    /// The value for gh's `--repo`: `[HOST/]OWNER/NAME`, the host only when it is not github.com.
    public var repoArgument: String { isGitHubDotCom ? slug : "\(host)/\(slug)" }
    /// github.com, or a host confirmed in Settings for this very entry.
    public var isHostConfirmed: Bool { isGitHubDotCom || confirmedHost == host }
    /// Host, owner and name pass the same checks as a freshly read remote, so a hand-edited entry cannot put
    /// anything odd into gh's arguments.
    public var isWellFormed: Bool {
        host == host.lowercased() && RemoteURL.isName(host, allowDots: true) && RemoteURL.isName(owner, allowDots: false)
            && RemoteURL.isName(name, allowDots: true)
    }
    /// Whether gh may be run for this entry at all.
    public var mayFetch: Bool { isWellFormed && isHostConfirmed }

    /// Reads the folder's Git metadata: the `origin` remote, else the first remote.
    public static func read(folder: URL, files: any RepositoryFileReading) throws(RepositoryError) -> BuildRepository {
        guard let location = GitFolder.locate(folder, files: files) else { throw .notARepository }
        let config = files.text(at: location.commonDir.appending(path: "config")) ?? ""
        let remotes = GitConfig.remotes(in: config)
        guard let remote = remotes.first(where: { $0.name == "origin" }) ?? remotes.first else { throw .noRemote }
        guard let parsed = RemoteURL.parse(remote.url) else { throw .unsupportedRemote }
        return BuildRepository(
            folderPath: folder.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlash,
            host: parsed.host, owner: parsed.owner, name: parsed.name
        )
    }
}

/// Why a folder could not be added. Each message names the next step.
public enum RepositoryError: Error, Sendable, Equatable {
    case notARepository, noRemote, unsupportedRemote, alreadyAdded

    public var message: String {
        switch self {
        case .notARepository: "Not a Git repository. Choose the folder that holds .git."
        case .noRemote: "No remote found. Add one with git remote add, then try again."
        case .unsupportedRemote: "The remote does not name a GitHub owner and repository."
        case .alreadyAdded: "This folder is already in the list."
        }
    }
}

/// File access for Git metadata. Injected so tests use temporary directories or fakes.
public protocol RepositoryFileReading: Sendable {
    /// The file's text, or `nil` when it is missing, unreadable or a directory.
    func text(at url: URL) -> String?
    func isDirectory(at url: URL) -> Bool
}

/// The real file system. Reads small text files only.
public struct DiskRepositoryFiles: RepositoryFileReading {
    /// Git metadata files are tiny; anything larger is not one.
    static let maxBytes = 1 << 20

    public init() {}

    public func text(at url: URL) -> String? {
        guard !isDirectory(at: url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}

/// Where a working folder keeps its Git metadata. No `git` binary is involved.
enum GitFolder {
    struct Location: Equatable {
        /// Per-worktree state: `HEAD`.
        var gitDir: URL
        /// Shared state: `config`. The same as `gitDir` except in a linked worktree.
        var commonDir: URL
    }

    /// `<folder>/.git` as a directory, or a `.git` file whose `gitdir:` line points at one (worktrees, submodules).
    static func locate(_ folder: URL, files: any RepositoryFileReading) -> Location? {
        let dotGit = folder.appending(path: ".git")
        let gitDir: URL
        if files.isDirectory(at: dotGit) {
            gitDir = dotGit
        } else if let text = files.text(at: dotGit), let target = pointer(in: text, prefix: "gitdir:") {
            gitDir = resolve(target, against: folder)
            guard files.isDirectory(at: gitDir) else { return nil }
        } else {
            return nil
        }
        var commonDir = gitDir
        if let text = files.text(at: gitDir.appending(path: "commondir")), let target = firstLine(text) {
            commonDir = resolve(target, against: gitDir)
        }
        return Location(gitDir: gitDir, commonDir: commonDir)
    }

    /// The checked-out branch, read from `HEAD`; `nil` for a detached HEAD or an unreadable folder.
    static func branch(of folder: URL, files: any RepositoryFileReading) -> String? {
        guard let location = locate(folder, files: files),
              let head = files.text(at: location.gitDir.appending(path: "HEAD")),
              let ref = pointer(in: head, prefix: "ref:")
        else { return nil }
        let prefix = "refs/heads/"
        guard ref.hasPrefix(prefix) else { return nil }
        let branch = String(ref.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }

    private static func pointer(in text: String, prefix: String) -> String? {
        guard let line = firstLine(text), line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }

    private static func resolve(_ path: String, against base: URL) -> URL {
        let url = path.hasPrefix("/")
            ? URL(filePath: path, directoryHint: .isDirectory)
            : base.appending(path: path, directoryHint: .isDirectory)
        return url.standardizedFileURL
    }
}

/// The parts of `.git/config` that name remotes.
enum GitConfig {
    struct Remote: Equatable {
        var name: String
        var url: String
    }

    /// Remotes with a `url`, in the order they first appear. Section and key names are case-insensitive;
    /// remote names are not.
    static func remotes(in config: String) -> [Remote] {
        var found: [Remote] = []
        var current: String?
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                current = remoteName(inHeader: line)
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url", !found.contains(where: { $0.name == current }) else { continue }
            let value = unquote(String(line[line.index(after: equals)...]))
            if !value.isEmpty { found.append(Remote(name: current, url: value)) }
        }
        return found
    }

    /// `[remote "origin"]`, or the old `[remote.origin]`.
    private static func remoteName(inHeader line: String) -> String? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        if let quote = inner.firstIndex(of: "\"") {
            guard inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased() == "remote" else { return nil }
            let rest = inner[inner.index(after: quote)...]
            guard let end = rest.lastIndex(of: "\"") else { return nil }
            let name = String(rest[..<end])
            return name.isEmpty ? nil : name
        }
        let parts = inner.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "remote" else { return nil }
        return String(parts[1])
    }

    /// Strips a trailing comment outside quotes, then the quotes themselves.
    private static func unquote(_ raw: String) -> String {
        var out = ""
        var quoted = false
        var escaped = false
        for ch in raw {
            if escaped { out.append(ch); escaped = false; continue }
            switch ch {
            case "\\": escaped = true
            case "\"": quoted.toggle()
            case "#" where !quoted, ";" where !quoted: return out.trimmingCharacters(in: .whitespaces)
            default: out.append(ch)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Host, owner and name from a remote URL.
enum RemoteURL {
    struct Parts: Equatable {
        var host: String
        var owner: String
        var name: String
    }

    /// Handles `git@host:owner/name.git`, `https://host/owner/name(.git)` and `ssh://git@host[:port]/owner/name.git`.
    /// Credentials and ports are dropped; nothing but host, owner and name is kept.
    static func parse(_ raw: String) -> Parts? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let path: String
        if text.contains("://") {
            guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let h = components.host, !h.isEmpty
            else { return nil }
            host = h
            path = components.path
        } else {
            // scp-like: [user@]host:path, where the colon comes before any slash.
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let authority = text[..<colon]
            guard !authority.contains("/") else { return nil }
            host = String(authority.split(separator: "@").last ?? "")
            path = String(text[text.index(after: colon)...])
        }
        var segments = path.split(separator: "/").map(String.init)
        guard segments.count == 2 else { return nil }
        if segments[1].lowercased().hasSuffix(".git") { segments[1] = String(segments[1].dropLast(4)) }
        let owner = segments[0], name = segments[1]
        guard isName(host, allowDots: true), isName(owner, allowDots: false), isName(name, allowDots: true) else { return nil }
        return Parts(host: host.lowercased(), owner: owner, name: name)
    }

    /// Letters, digits, `-`, `_` (and `.` where GitHub allows it). Keeps anything odd out of gh's arguments.
    static func isName(_ text: String, allowDots: Bool) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-"), !text.hasPrefix("."), text != ".." else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || (allowDots && scalar == "."))
        }
    }
}

extension String {
    var trimmingTrailingSlash: String {
        var text = self
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
