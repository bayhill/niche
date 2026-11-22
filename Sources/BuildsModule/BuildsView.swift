import NotchCore
import SwiftUI

/// The Builds page: a header, then one row per repository with its newest run that matters. Four rows fit;
/// more scroll.
struct BuildsPage: View {
    let module: BuildsModule
    /// `false` lays the rows out without a scroll view; only for off-screen snapshots, which cannot draw one.
    var scrolls = true

    var body: some View {
        let status = module.status
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader("Builds", symbol: "hammer") {
                if status == .ready {
                    HStack(spacing: Tokens.Spacing.xs) {
                        UpdatedText(lastFetched: module.lastFetched, fetching: module.isFetching)
                        GlassIconButton("arrow.clockwise", label: "Refresh", kind: .plain, size: 20) { module.refreshNow() }
                            .disabled(module.isFetching)
                    }
                    .transition(.opacity)
                }
            }

            ZStack {
                switch status {
                case .noRepositories:
                    StatusMessage(
                        symbol: "folder.badge.plus", title: "Add a repository in Settings",
                        message: "CI runs for the checked-out branch show here, through the GitHub CLI."
                    ) {
                        if module.canOpenSettings {
                            GlassButton("Open Settings", symbol: "gear", prominence: .accent) { module.openSettings() }
                        }
                    }
                    .transition(.opacity)
                case .ghMissing:
                    StatusMessage(
                        symbol: "terminal", title: "Install the GitHub CLI to see builds",
                        message: "Homebrew installs it with brew install gh. Sign in with gh auth login, then try again."
                    ) {
                        GlassButton("Try again", symbol: "arrow.clockwise") { module.refreshNow() }
                    }
                    .transition(.opacity)
                case .signedOut:
                    StatusMessage(
                        symbol: "person.crop.circle.badge.questionmark", title: "Sign in to the GitHub CLI",
                        message: "Run gh auth login in Terminal, then try again."
                    ) {
                        GlassButton("Try again", symbol: "arrow.clockwise") { module.refreshNow() }
                    }
                    .transition(.opacity)
                case .ready:
                    RowList(module: module, scrolls: scrolls)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .motion(Motion.morph, value: status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { module.pageAppeared() }
    }
}

/// Explanation plus one action, centred.
private struct StatusMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            EmptyState(symbol: symbol, title: title, message: message).fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .motionAppear()
    }
}

/// "Updated 2m ago", kept fresh; "Checking" while a refresh runs.
private struct UpdatedText: View {
    let lastFetched: Date?
    let fetching: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(at: context.date))
                .notchStyle(.caption)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private func text(at date: Date) -> String {
        if fetching || lastFetched == nil { return "Checking" }
        let age = Format.age(seconds: date.timeIntervalSince(lastFetched ?? date))
        return age == "now" ? "Updated just now" : "Updated \(age) ago"
    }
}

private struct RowList: View {
    let module: BuildsModule
    let scrolls: Bool

    var body: some View {
        let rows = module.rows
        let hero = module.announcedRepositoryID ?? rows.first?.id
        let list = VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                BuildRowView(row: row, isHero: row.id == hero) { module.open(row) }
                    .motionAppear(min(index, 6))
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .motion(Motion.morph, value: rows.map(\.id))
        if scrolls {
            ScrollView(.vertical, showsIndicators: false) { list }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            Color.clear.overlay(alignment: .top) { list.fixedSize(horizontal: false, vertical: true) }.clipped()
        }
    }
}

/// One repository: status mark, owner and name, branch, workflow, and the state with how long ago.
/// A click opens the run in the browser.
struct BuildRowView: View {
    let row: BuildRow
    let isHero: Bool
    let open: () -> Void

    static let branchWidth: CGFloat = 144
    static let workflowWidth: CGFloat = 104
    static let outcomeWidth: CGFloat = 136

    var body: some View {
        Button(action: open) {
            HStack(spacing: Tokens.Spacing.m) {
                StatusMark(content: row.content)
                    .frame(width: 18, height: 18)
                    .modifier(HeroIf(active: isHero))
                name
                    .frame(maxWidth: .infinity, alignment: .leading)
                details
            }
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .disabled(row.run?.url == nil)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(row.run?.url == nil ? "" : "Opens the run in the browser")
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(row.repository.owner)/").notchStyle(.caption).lineLimit(1).layoutPriority(-1)
            Text(row.repository.name).notchStyle(.title).lineLimit(1).layoutPriority(1)
        }
    }

    @ViewBuilder private var details: some View {
        switch row.content {
        case .run(let run):
            BranchLabel(branch: run.branch)
                .frame(width: Self.branchWidth, alignment: .leading)
            Text(run.workflow).notchStyle(.caption).lineLimit(1)
                .frame(width: Self.workflowWidth, alignment: .leading)
            HStack(spacing: Tokens.Spacing.s) {
                Text(run.state.label)
                    .font(NotchTextStyle.caption.font)
                    .foregroundStyle(Self.tint(run.state).color)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                AgeText(date: run.state.isActive ? run.createdAt : run.updatedAt).frame(width: 34, alignment: .trailing)
            }
            .frame(width: Self.outcomeWidth, alignment: .trailing)
            .motion(Motion.quick, value: run.state)
        case .loading:
            quiet("Loading runs")
        case .noRuns:
            quiet("No workflow runs yet")
        case .problem(let problem):
            quiet(problem.message(host: row.repository.host))
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .notchStyle(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: Self.branchWidth + Self.workflowWidth + Self.outcomeWidth + 2 * Tokens.Spacing.m, alignment: .leading)
    }

    static func tint(_ state: BuildState) -> TintRole {
        switch state {
        case .running: .accent
        case .passed: .success
        case .failed, .needsApproval, .waiting: .warning
        case .queued, .cancelled, .skipped, .finished: .secondary
        }
    }

    private var help: String {
        guard let run = row.run else { return row.repository.repoArgument }
        if let branch = row.checkedOutBranch, branch != run.branch {
            return "No runs on \(branch); showing the latest on \(run.branch)"
        }
        return run.title.isEmpty ? "Open the run in the browser" : run.title
    }

    private var accessibilityText: String {
        let repository = row.repository.slug
        switch row.content {
        case .run(let run): return "\(repository), \(run.branch), \(run.workflow), \(run.state.label)"
        case .loading: return "\(repository), loading"
        case .noRuns: return "\(repository), no workflow runs"
        case .problem(let problem): return "\(repository), \(problem.message(host: row.repository.host))"
        }
    }
}

/// The run's state at a glance: a spinner while running, a pulsing dot while waiting, a symbol once finished.
private struct StatusMark: View {
    let content: BuildRow.Content

    var body: some View {
        ZStack {
            switch content {
            case .run(let run):
                mark(for: run.state)
            case .loading:
                StatusDot(.secondary, pulsing: true)
            case .noRuns:
                symbol("circle.dashed", .secondary)
            case .problem:
                symbol("exclamationmark.circle", .secondary)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .motion(Motion.morph, value: content)
    }

    @ViewBuilder private func mark(for state: BuildState) -> some View {
        switch state {
        case .running: SpinnerRing(size: 14, lineWidth: 2, tint: .accent)
        case .queued: StatusDot(.secondary, pulsing: true)
        case .waiting: StatusDot(.warning, pulsing: true)
        case .passed: symbol("checkmark.circle.fill", .success)
        case .failed: symbol("xmark.circle.fill", .warning)
        case .needsApproval: symbol("exclamationmark.circle.fill", .warning)
        case .cancelled: symbol("slash.circle", .secondary)
        case .skipped, .finished: symbol("circle.dashed", .secondary)
        }
    }

    private func symbol(_ name: String, _ tint: TintRole) -> some View {
        Image(systemName: name)
            .font(NotchTextStyle.title.font)
            .foregroundStyle(tint.color)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

private struct BranchLabel: View {
    let branch: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(NotchTextStyle.label.font)
                .foregroundStyle(Tokens.Colors.textTertiary)
            Text(branch).notchStyle(.caption).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "now", "4m", "1h", kept fresh.
private struct AgeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Format.age(seconds: context.date.timeIntervalSince(date)))
                .font(NotchTextStyle.numeric.font)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .fixedSize()
        }
    }
}

/// `.notchHero(.builds)` on one status mark only.
private struct HeroIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.notchHero(.builds) } else { content }
    }
}

/// Settings pane: the repositories, and the note beside the notch.
struct BuildsSettings: View {
    let module: BuildsModule
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(module.repositories) { repository in
                    LabeledContent {
                        Button {
                            module.removeRepository(repository)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove \(repository.slug)")
                    } label: {
                        Text(repository.isGitHubDotCom ? repository.slug : repository.repoArgument)
                        Text((repository.folderPath as NSString).abbreviatingWithTildeInPath)
                    }
                }
                HStack {
                    Button("Add repository…") { Task { await module.chooseRepository() } }
                    if let error = module.addError {
                        Text(error.message).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text(
                    "Runs for the branch checked out in each folder, read with the GitHub CLI (gh) and its existing "
                        + "sign-in. No token is stored; only this list is kept."
                )
            }
            Section {
                Toggle("Show finished runs beside the notch", isOn: settings.binding(BuildsModule.showBesideNotchKey))
            } footer: {
                Text("For a few seconds when a run seen queued or in progress finishes.")
            }
        }
        .formStyle(.grouped)
    }
}
