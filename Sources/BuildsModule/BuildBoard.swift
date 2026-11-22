import Foundation

/// One repository on the page: its newest run that matters, or why there is none.
public struct BuildRow: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// Not fetched yet this session.
        case loading
        /// The run that speaks for the repository (`BuildSummary.decidingRun`).
        case run(BuildRun)
        /// gh answered, but there are no runs on any branch.
        case noRuns
        case problem(RepositoryProblem)
    }

    public var repository: BuildRepository
    public var content: Content
    /// The branch checked out in the folder at the last fetch; `nil` when detached or not fetched.
    public var checkedOutBranch: String?

    public var id: String { repository.id }

    public var run: BuildRun? {
        if case .run(let run) = content { return run }
        return nil
    }

    public var state: BuildState? { run?.state }
}

/// Builds the page's rows from the repositories and what the last refresh found. Pure.
enum BuildBoard {
    /// Work in flight first, then failures, then by how recently the run changed. Repositories without a run
    /// come last, in the order they were added.
    static func rows(repositories: [BuildRepository], outcomes: [String: FetchOutcome]) -> [BuildRow] {
        let rows = repositories.map { repository -> BuildRow in
            switch outcomes[repository.id] {
            case nil:
                return BuildRow(repository: repository, content: .loading)
            case .problem(let problem):
                return BuildRow(repository: repository, content: .problem(problem))
            case .runs(let runs, let branch):
                let content: BuildRow.Content = BuildSummary.decidingRun(runs).map(BuildRow.Content.run) ?? .noRuns
                return BuildRow(repository: repository, content: content, checkedOutBranch: branch)
            }
        }
        return rows.enumerated()
            .sorted { a, b in
                let (ga, gb) = (group(a.element), group(b.element))
                if ga != gb { return ga < gb }
                if let ra = a.element.run, let rb = b.element.run, ra.updatedAt != rb.updatedAt { return ra.updatedAt > rb.updatedAt }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private static func group(_ row: BuildRow) -> Int {
        guard let state = row.state else { return 3 }
        if state.isActive { return 0 }
        if state.needsLook { return 1 }
        return 2
    }

    /// Any fetched run still queued, waiting or running: the refresh loop checks again sooner.
    static func hasActiveRuns(_ outcomes: some Sequence<FetchOutcome>) -> Bool {
        outcomes.contains { outcome in
            if case .runs(let runs, _) = outcome { return runs.contains { $0.state.isActive } }
            return false
        }
    }
}
