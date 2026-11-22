import Foundation

/// Invented repositories and runs for `sample()`: every name, path and address is made up.
enum BuildsSamples {
    static func make(now: Date) -> ([BuildRepository], [String: FetchOutcome]) {
        func repository(_ name: String) -> BuildRepository {
            BuildRepository(folderPath: "/Users/example/Developer/\(name)", host: "github.com", owner: "acme", name: name)
        }
        func run(
            _ id: Int, _ repo: String, workflow: String, branch: String, status: String, conclusion: String = "",
            minutesAgo: Double, updatedMinutesAgo: Double? = nil, title: String
        ) -> BuildRun {
            BuildRun(
                id: id, title: title, workflow: workflow, branch: branch, commit: "sample-\(id)", status: status,
                conclusion: conclusion, createdAt: now.addingTimeInterval(-minutesAgo * 60),
                updatedAt: now.addingTimeInterval(-(updatedMinutesAgo ?? minutesAgo) * 60),
                url: URL(string: "https://github.com/acme/\(repo)/actions/runs/\(id)")
            )
        }

        let storefront = repository("storefront")
        let api = repository("api")
        let docs = repository("docs")
        let mobile = repository("mobile")
        let outcomes: [String: FetchOutcome] = [
            storefront.id: .runs([
                run(1001, "storefront", workflow: "CI", branch: "main", status: "completed", conclusion: "success",
                    minutesAgo: 26, updatedMinutesAgo: 18, title: "Show delivery dates in the basket"),
            ], branch: "main"),
            api.id: .runs([
                run(2002, "api", workflow: "Test", branch: "feature/checkout", status: "in_progress",
                    minutesAgo: 3, title: "Validate gift card codes"),
            ], branch: "feature/checkout"),
            docs.id: .runs([
                run(3003, "docs", workflow: "Deploy", branch: "main", status: "completed", conclusion: "failure",
                    minutesAgo: 52, updatedMinutesAgo: 47, title: "Rewrite the getting started guide"),
            ], branch: "main"),
            mobile.id: .runs([
                run(4004, "mobile", workflow: "Release", branch: "release/2.4", status: "completed", conclusion: "cancelled",
                    minutesAgo: 190, updatedMinutesAgo: 185, title: "Bump version to 2.4.1"),
            ], branch: "release/2.4"),
        ]
        return ([storefront, api, docs, mobile], outcomes)
    }
}
