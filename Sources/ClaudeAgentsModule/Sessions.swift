import Foundation
import NotchCore

/// What a session is doing, from the user's point of view.
public enum SessionState: Sendable, Equatable {
    case working
    case idle(since: Date)
    /// A permission dialog is open. `detail` is the tool name when known.
    case needsPermission(detail: String?)
    /// Claude asked a question or opened a dialog (elicitation, plan approval, ...).
    case needsInput(detail: String?)
    /// The turn just ended. Decays to `idle` after `SessionReducer.Config.finishedDecay`.
    case finished(at: Date)

    public var needsUser: Bool {
        switch self {
        case .needsPermission, .needsInput: true
        default: false
        }
    }

    /// Sort bucket: needs the user, then working, then idle/finished.
    var rank: Int {
        switch self {
        case .needsPermission, .needsInput: 0
        case .working: 1
        case .idle, .finished: 2
        }
    }
}

/// Which app hosts the session (`entrypoint` in the registry).
public enum Entrypoint: Sendable, Equatable {
    case cli, vscode, desktop, unknown
    case other(String)

    public init(_ raw: String?) {
        switch raw {
        case nil, "": self = .unknown
        case "cli": self = .cli
        case "claude-vscode": self = .vscode
        case "claude-desktop": self = .desktop
        case let value?: self = .other(value)
        }
    }
}

public struct ClaudeSession: Sendable, Equatable, Identifiable {
    /// The Claude Code session id (shared by the registry and hook events).
    public var id: String
    /// Process id from the registry; `nil` for sessions known only from hook events.
    public var pid: Int32?
    public var cwd: String
    public var title: String
    public var entrypoint: Entrypoint
    public var state: SessionState
    /// When the session entered `state`.
    public var since: Date
    /// The most recent sign of life from either source.
    public var lastEvent: Date

    public init(
        id: String, pid: Int32?, cwd: String, title: String, entrypoint: Entrypoint, state: SessionState,
        since: Date, lastEvent: Date
    ) {
        self.id = id; self.pid = pid; self.cwd = cwd; self.title = title; self.entrypoint = entrypoint
        self.state = state; self.since = since; self.lastEvent = lastEvent
    }
}

/// Combines the registry (which sessions exist, busy/idle/waiting) and hook events (permission, input, stop)
/// into one list of sessions. Pure value type: feed it snapshots and events, ask for `sessions(now:)`.
///
/// Hook events:
/// - `SessionStart` → idle; `UserPromptSubmit`, `PostToolUse(Failure)`, `Notification(elicitation_complete|
///   elicitation_response)` → working.
/// - `PermissionRequest`, `Notification(permission_prompt)` → needsPermission (tool name from PermissionRequest).
/// - `Notification(elicitation_dialog|elicitation_url_dialog|agent_needs_input)` → needsInput(message).
/// - `Notification(idle_prompt)` → idle; other notifications only refresh `lastEvent`.
/// - `Stop`, `StopFailure` → finished, shown as idle after `finishedDecay`.
/// - `SessionEnd` → removed; a registry file for that id is ignored until it is rewritten after the end.
///
/// Registry `status`: busy → working; idle/shell → idle; waiting/blocked → needsPermission when `waitingFor`
/// mentions "permission", else needsInput; classifier `tempo: blocked` → needsInput(needs); anything else → no
/// opinion. A busy → idle change seen between two snapshots counts as finished (so "Done" works without hooks),
/// unless a hook reported an open prompt, which the idle then dismisses.
///
/// Merge, per session id: the newer observation wins (hook time = spool file mtime, registry time =
/// `statusUpdatedAt`), except that idle never overrides finished, and two "needs" observations of the same kind
/// combine (earliest start, the hook's detail first). A registry state that overrules the hook state consumes it. Sessions in the registry are shown while their process
/// lives; one that drops out of the registry is removed. Sessions known only from hooks are shown for
/// `hookOnlyGrace` after their last event (`attentionGrace` while they need the user) when a registry exists,
/// and for `hookOnlyTTL` when there is no registry at all.
public struct SessionReducer: Sendable {
    public struct Config: Sendable, Equatable {
        public var finishedDecay: TimeInterval = 300
        public var hookOnlyGrace: TimeInterval = 120
        public var attentionGrace: TimeInterval = 3600
        public var hookOnlyTTL: TimeInterval = 12 * 3600
        public init() {}
    }

    enum Signal: Sendable, Equatable {
        case working, idle, finished
        case needsPermission(String?)
        case needsInput(String?)

        var needsUser: Bool {
            switch self {
            case .needsPermission, .needsInput: true
            default: false
            }
        }
    }

    struct Observation: Sendable, Equatable {
        var signal: Signal
        var at: Date
    }

    struct RegistryTrack: Sendable {
        var record: RegistryRecord
        var observation: Observation?
    }

    struct HookTrack: Sendable {
        var observation: Observation?
        var cwd: String?
        var title: String?
        var lastEvent: Date
    }

    public var config: Config
    public private(set) var registryAvailable = false
    private var registry: [String: RegistryTrack] = [:]
    private var hooks: [String: HookTrack] = [:]
    private var seenInRegistry: Set<String> = []
    private var ended: [String: Date] = [:]

    public init(config: Config = Config()) { self.config = config }

    // MARK: Input

    public mutating func applyRegistry(_ snapshot: RegistrySnapshot) {
        registryAvailable = snapshot.available
        var next: [String: RegistryTrack] = [:]
        for record in snapshot.records {
            let id = record.sessionID
            let at = record.observedAt ?? .distantPast
            if let endedAt = ended[id] {
                if at <= endedAt { continue }
                ended[id] = nil
            }
            var observation = Self.signal(for: record).map { Observation(signal: $0, at: at) }
            if let previous = registry[id]?.observation, observation?.signal == .idle {
                // busy → idle ends a turn, unless a prompt was open: then it was dismissed or denied, not finished.
                let promptOpen = hooks[id]?.observation?.signal.needsUser ?? false
                if previous.signal == .working, !promptOpen { observation?.signal = .finished }
                if previous.signal == .finished { observation = previous }
            }
            // A newer registry state that overrules the hook state consumes it, so the next hook event starts afresh
            // (e.g. a second permission prompt after the first was approved is not merged with the first).
            if let observation, let hook = hooks[id]?.observation, observation.at > hook.at,
               Self.merge(observation, hook) == observation {
                hooks[id]?.observation = nil
            }
            next[id] = RegistryTrack(record: record, observation: observation)
            seenInRegistry.insert(id)
        }
        for id in registry.keys where next[id] == nil { hooks[id] = nil }
        registry = next
    }

    public mutating func apply(_ event: HookEvent) {
        let id = event.sessionID
        if case .sessionEnd = event.kind {
            ended[id] = event.at
            hooks[id] = nil
            registry[id] = nil
            return
        }
        if let endedAt = ended[id] {
            if event.at <= endedAt { return }
            ended[id] = nil
        }
        var track = hooks[id] ?? HookTrack(observation: nil, cwd: nil, title: nil, lastEvent: event.at)
        track.lastEvent = max(track.lastEvent, event.at)
        if let cwd = event.cwd, !cwd.isEmpty { track.cwd = cwd }
        if let title = event.title { track.title = title }
        if let signal = Self.signal(for: event.kind) {
            let incoming = Observation(signal: signal, at: event.at)
            if let current = track.observation {
                if incoming.at >= current.at { track.observation = Self.combine(current, incoming) ?? incoming }
            } else {
                track.observation = incoming
            }
        }
        hooks[id] = track
    }

    // MARK: Output

    /// Every session to show, ordered: needs the user, then working, then idle/finished; newest change first.
    public func sessions(now: Date) -> [ClaudeSession] {
        var out: [ClaudeSession] = []
        for id in Set(registry.keys).union(hooks.keys) {
            let reg = registry[id]
            let hook = hooks[id]
            if reg == nil {
                guard let hook, !seenInRegistry.contains(id) else { continue }
                let needs = hook.observation?.signal.needsUser ?? false
                let limit = registryAvailable ? (needs ? config.attentionGrace : config.hookOnlyGrace) : config.hookOnlyTTL
                guard now.timeIntervalSince(hook.lastEvent) <= limit else { continue }
            }
            let merged = Self.merge(reg?.observation, hook?.observation)
            let lastEvent = max(reg?.record.updatedAt ?? .distantPast, reg?.record.observedAt ?? .distantPast, hook?.lastEvent ?? .distantPast)
            let state: SessionState
            let since: Date
            switch merged?.signal {
            case .working?: state = .working; since = merged!.at
            case .idle?: state = .idle(since: merged!.at); since = merged!.at
            case .finished?:
                let at = merged!.at
                state = now.timeIntervalSince(at) > config.finishedDecay ? .idle(since: at) : .finished(at: at)
                since = at
            case .needsPermission(let d)?: state = .needsPermission(detail: d); since = merged!.at
            case .needsInput(let d)?: state = .needsInput(detail: d); since = merged!.at
            case nil:
                let start = reg?.record.startedAt ?? lastEvent
                state = .idle(since: start); since = start
            }
            let cwd = reg?.record.cwd ?? hook?.cwd ?? ""
            out.append(ClaudeSession(
                id: id, pid: reg?.record.pid, cwd: cwd, title: Self.title(reg?.record, hookTitle: hook?.title, cwd: cwd),
                entrypoint: Entrypoint(reg?.record.entrypoint), state: state, since: since, lastEvent: lastEvent
            ))
        }
        return Self.ordered(out)
    }

    public static func ordered(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            if a.since != b.since { return a.since > b.since }
            return a.id < b.id
        }
    }

    // MARK: Rules

    static func signal(for record: RegistryRecord) -> Signal? {
        if record.tempo?.lowercased() == "blocked" { return .needsInput(record.needs) }
        switch record.status?.lowercased() {
        case "busy", "working", "running": return .working
        case "idle", "shell": return .idle
        case "waiting", "blocked":
            if let w = record.waitingFor, w.lowercased().contains("permission") { return .needsPermission(nil) }
            return .needsInput(record.waitingFor)
        default: return nil
        }
    }

    static func signal(for kind: HookEvent.Kind) -> Signal? {
        switch kind {
        case .sessionStart: return .idle
        case .userPromptSubmit, .postToolUse, .postToolUseFailure: return .working
        case .permissionRequest(let tool): return .needsPermission(tool)
        case .notification(let type, let message):
            switch type {
            case "permission_prompt": return .needsPermission(nil)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsInput(message)
            case "elicitation_complete", "elicitation_response": return .working
            case "idle_prompt": return .idle
            default: return nil
            }
        case .stop, .stopFailure: return .finished
        case .sessionEnd, .other: return nil
        }
    }

    /// Two observations that agree on the kind of state: keep the earlier start and the first known detail.
    /// Idle after finished keeps finished. `nil` when they disagree.
    static func combine(_ older: Observation, _ newer: Observation) -> Observation? {
        switch (older.signal, newer.signal) {
        case (.needsPermission(let a), .needsPermission(let b)):
            return Observation(signal: .needsPermission(a ?? b), at: min(older.at, newer.at))
        case (.needsInput(let a), .needsInput(let b)):
            return Observation(signal: .needsInput(a ?? b), at: min(older.at, newer.at))
        case (.finished, .idle), (.finished, .finished), (.working, .working), (.idle, .idle):
            return older
        default:
            return nil
        }
    }

    static func merge(_ registry: Observation?, _ hook: Observation?) -> Observation? {
        guard let registry else { return hook }
        guard let hook else { return registry }
        switch (registry.signal, hook.signal) {
        case (.needsPermission(let r), .needsPermission(let h)):
            return Observation(signal: .needsPermission(h ?? r), at: min(registry.at, hook.at))
        case (.needsInput(let r), .needsInput(let h)):
            return Observation(signal: .needsInput(h ?? r), at: min(registry.at, hook.at))
        case (.idle, .finished): return hook
        case (.finished, .idle): return registry
        default: return hook.at >= registry.at ? hook : registry
        }
    }

    /// The registry's name unless it is only a cwd slug, then the hook's custom title, then the folder name.
    static func title(_ record: RegistryRecord?, hookTitle: String?, cwd: String) -> String {
        let name = record?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, record?.nameSource != "derived" { return name }
        if let hookTitle, !hookTitle.isEmpty { return hookTitle }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        if !cwd.isEmpty, !folder.isEmpty, folder != "/" { return folder }
        return name.isEmpty ? "Claude" : name
    }
}
