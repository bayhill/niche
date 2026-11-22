import Foundation

/// One GitHub Actions workflow run, as `gh run list --json` reports it.
public struct BuildRun: Sendable, Equatable, Identifiable {
    /// `databaseId`: stable across attempts, so a re-run is the same run going back to `queued`.
    public var id: Int
    public var title: String
    public var workflow: String
    public var branch: String
    /// `headSha`; empty when gh did not report it.
    public var commit: String
    public var status: String
    /// Empty until the run has completed.
    public var conclusion: String
    public var event: String
    public var createdAt: Date
    public var updatedAt: Date
    public var url: URL?

    public init(
        id: Int, title: String = "", workflow: String, branch: String, commit: String = "", status: String,
        conclusion: String = "", event: String = "push", createdAt: Date, updatedAt: Date? = nil, url: URL? = nil
    ) {
        self.id = id; self.title = title; self.workflow = workflow; self.branch = branch; self.commit = commit
        self.status = status; self.conclusion = conclusion; self.event = event
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.url = url
    }

    public var state: BuildState { BuildState(status: status, conclusion: conclusion) }
}

/// What a run's status and conclusion mean on the page.
public enum BuildState: Sendable, Equatable, CaseIterable {
    case queued, running, waiting, passed, failed, needsApproval, cancelled, skipped, finished

    /// GitHub's `status` (queued, in_progress, waiting, requested, pending, completed) and `conclusion`
    /// (success, failure, cancelled, skipped, timed_out, action_required, neutral, stale, startup_failure).
    public init(status: String, conclusion: String) {
        switch status {
        case "completed":
            switch conclusion {
            case "success": self = .passed
            case "failure", "timed_out", "startup_failure": self = .failed
            case "action_required": self = .needsApproval
            case "cancelled": self = .cancelled
            case "skipped", "stale": self = .skipped
            default: self = .finished
            }
        case "in_progress": self = .running
        case "waiting": self = .waiting
        case "action_required": self = .needsApproval
        default: self = .queued  // queued, requested, pending and anything newer
        }
    }

    /// Queued, waiting or running: worth checking again soon.
    public var isActive: Bool { self == .queued || self == .running || self == .waiting }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .passed: "Passed"
        case .failed: "Failed"
        case .needsApproval: "Needs approval"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .finished: "Finished"
        }
    }

    /// Which run speaks for a commit when several workflows ran for it: work in flight first, then what needs
    /// a look, then the rest. Skipped and neutral runs never hide a real result.
    var weight: Int {
        switch self {
        case .running: 9
        case .waiting: 8
        case .queued: 7
        case .failed: 6
        case .needsApproval: 5
        case .cancelled: 4
        case .passed: 3
        case .finished: 2
        case .skipped: 1
        }
    }

    /// Failed or held for approval: sorts right after work in flight.
    var needsLook: Bool { self == .failed || self == .needsApproval }
}

/// Reads `gh run list --json …` output. Pure, so it is tested with invented JSON.
public enum RunListDecoder {
    public struct Failure: Error, Equatable {}

    /// Runs with no `databaseId` are left out; missing text fields read as empty, unreadable dates as the other date.
    public static func decode(_ data: Data) throws -> [BuildRun] {
        let raw: [RawRun]
        do { raw = try JSONDecoder().decode([RawRun].self, from: data) } catch { throw Failure() }
        return raw.compactMap { item in
            guard let id = item.databaseId else { return nil }
            let created = item.createdAt.flatMap(parseDate)
            let updated = item.updatedAt.flatMap(parseDate)
            let start = created ?? updated ?? .distantPast
            return BuildRun(
                id: id, title: item.displayTitle ?? "", workflow: item.workflowName ?? "", branch: item.headBranch ?? "",
                commit: item.headSha ?? "", status: item.status ?? "", conclusion: item.conclusion ?? "",
                event: item.event ?? "", createdAt: start, updatedAt: max(updated ?? start, start),
                url: item.url.flatMap(webURL)
            )
        }
    }

    private struct RawRun: Decodable {
        var databaseId: Int?
        var displayTitle: String?
        var workflowName: String?
        var headBranch: String?
        var headSha: String?
        var status: String?
        var conclusion: String?
        var event: String?
        var createdAt: String?
        var updatedAt: String?
        var url: String?
    }

    /// ISO 8601, with or without fractional seconds. GitHub's "zero" date (year 1) reads as unknown.
    static func parseDate(_ text: String) -> Date? {
        let date = (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        guard let date, date > Date(timeIntervalSince1970: 0) else { return nil }
        return date
    }

    /// Only web addresses are ever opened.
    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return nil }
        return url
    }
}

/// The run that speaks for a repository: among the runs for the newest run's commit, the one with the most weight.
public enum BuildSummary {
    public static func decidingRun(_ runs: [BuildRun]) -> BuildRun? {
        guard let newest = runs.max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) else { return nil }
        let batch = newest.commit.isEmpty ? [newest] : runs.filter { $0.commit == newest.commit }
        return batch.max { a, b in
            if a.state.weight != b.state.weight { return a.state.weight < b.state.weight }
            return (a.createdAt, a.id) < (b.createdAt, b.id)
        }
    }
}

/// Remembers runs seen queued or in progress this session, and reports the ones that have since finished.
public struct CompletionTracker: Sendable, Equatable {
    private(set) var watching: Set<Int> = []

    public init() {}

    /// - Returns: runs that were seen in flight before and are finished now. A run first seen finished is never reported.
    public mutating func observe(_ runs: [BuildRun]) -> [BuildRun] {
        var finished: [BuildRun] = []
        for run in runs {
            if run.state.isActive {
                watching.insert(run.id)
            } else if watching.remove(run.id) != nil {
                finished.append(run)
            }
        }
        return finished
    }
}
