import Foundation
import NotchCore

/// Why one repository's runs could not be loaded. The repository stays listed and is tried again at the next refresh.
public enum RepositoryProblem: Error, Sendable, Equatable {
    /// gh has no sign-in for this repository's host (exit code 4).
    case signedOut
    /// The repository does not exist, or the signed-in account cannot see it.
    case notFound
    case timedOut
    /// gh answered with something that is not a run list.
    case unreadable
    case failed
    /// The entry names a host other than github.com that was never confirmed in Settings; gh is not run for it.
    case hostNotConfirmed
    /// The stored entry does not name a valid host, owner and repository; gh is not run for it.
    case invalidEntry

    /// One quiet line for the repository's row.
    public func message(host: String) -> String {
        switch self {
        case .signedOut: "Not signed in to \(host). Run gh auth login in Terminal, then refresh."
        case .notFound: "Not found, or not visible to this gh sign-in. Tries again at the next refresh."
        case .timedOut: "GitHub did not answer in time. Tries again at the next refresh."
        case .unreadable: "The gh output was not understood. Updating gh may help."
        case .failed: "Could not load runs. Tries again at the next refresh."
        case .hostNotConfirmed: "Not checked: \(host) is not confirmed. Confirm it in Settings to load runs."
        case .invalidEntry: "This entry is not valid. Remove it in Settings and add the folder again."
        }
    }
}

/// What one refresh found for one repository.
enum FetchOutcome: Sendable, Equatable {
    /// Up to five runs, newest first as gh lists them; `branch` is the branch that was checked out.
    case runs([BuildRun], branch: String?)
    case problem(RepositoryProblem)
}

/// How the module talks to the user's own GitHub CLI. It never installs gh, never signs in and never asks for a token.
enum GitHubCLI {
    /// Where Homebrew (Apple silicon, Intel) and a system install put gh. Nothing is looked up on `PATH`.
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    static let jsonFields = [
        "databaseId", "displayTitle", "workflowName", "headBranch", "headSha", "status", "conclusion", "event",
        "createdAt", "updatedAt", "url",
    ]
    static let limit = 5
    static let timeout: Duration = .seconds(20)
    /// gh's exit code for "authentication required".
    static let signedOutStatus: Int32 = 4

    /// The first candidate that exists and is executable.
    static func locate(isExecutable: (String) -> Bool) -> URL? {
        candidates.first(where: isExecutable).map { URL(filePath: $0) }
    }

    /// `gh run list --repo=[HOST/]OWNER/NAME [--branch=<branch>] --limit=5 --json=<fields>`.
    /// Values are joined to their flags so a branch name can never read as a flag.
    static func arguments(for repository: BuildRepository, branch: String?) -> [String] {
        var arguments = ["run", "list", "--repo=\(repository.repoArgument)"]
        if let branch { arguments.append("--branch=\(branch)") }
        arguments += ["--limit=\(limit)", "--json=\(jsonFields.joined(separator: ","))"]
        return arguments
    }

    /// Variables never handed to gh. An enterprise token would go to whichever enterprise host a repository names,
    /// and `GH_HOST` would pick a host without the user choosing it.
    static let withheldVariables = ["GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST"]

    /// The app's environment without `withheldVariables`, with gh told never to prompt, colour or check for updates.
    static func environment(base: [String: String]) -> [String: String] {
        var environment = base
        for name in withheldVariables { environment[name] = nil }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        return environment
    }

    static func interpret(_ result: CommandResult) -> Result<[BuildRun], RepositoryProblem> {
        if result.timedOut { return .failure(.timedOut) }
        if result.status == signedOutStatus { return .failure(.signedOut) }
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if message.contains("gh auth login") { return .failure(.signedOut) }
            if message.contains("could not resolve to a repository") || message.contains("http 404") {
                return .failure(.notFound)
            }
            return .failure(.failed)
        }
        do { return .success(try RunListDecoder.decode(result.stdout)) } catch { return .failure(.unreadable) }
    }
}

/// Fetches one repository's runs: on the checked-out branch, else on any branch when that shows nothing.
struct RunFetcher: Sendable {
    let executable: URL
    let runner: any CommandRunning
    let files: any RepositoryFileReading
    let environment: [String: String]

    func fetch(_ repository: BuildRepository) async -> FetchOutcome {
        if let problem = RunFetcher.refusal(for: repository) { return .problem(problem) }
        let branch = GitFolder.branch(of: repository.folder, files: files)
        if let branch {
            switch await list(repository, branch: branch) {
            case .success(let runs) where !runs.isEmpty: return .runs(runs, branch: branch)
            case .success: break
            case .failure(let problem): return .problem(problem)
            }
        }
        switch await list(repository, branch: nil) {
        case .success(let runs): return .runs(runs, branch: branch)
        case .failure(let problem): return .problem(problem)
        }
    }

    /// Why gh must not be run for an entry, or `nil` when it may.
    static func refusal(for repository: BuildRepository) -> RepositoryProblem? {
        if !repository.isWellFormed { return .invalidEntry }
        if !repository.isHostConfirmed { return .hostNotConfirmed }
        return nil
    }

    private func list(_ repository: BuildRepository, branch: String?) async -> Result<[BuildRun], RepositoryProblem> {
        let result = await runner.run(
            executable, arguments: GitHubCLI.arguments(for: repository, branch: branch),
            environment: environment, timeout: GitHubCLI.timeout
        )
        return GitHubCLI.interpret(result)
    }
}
