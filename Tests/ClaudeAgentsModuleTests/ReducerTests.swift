import Foundation
import NotchCore
import Testing
@testable import ClaudeAgentsModule

@Suite struct ReducerHookTransitionTests {
    let t0 = Fixture.t0
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A reducer that only knows hook events (no registry on this machine).
    func reduce(_ events: [HookEvent]) -> SessionReducer {
        var r = SessionReducer()
        r.applyRegistry(RegistrySnapshot(records: [], available: false))
        events.forEach { r.apply($0) }
        return r
    }

    func state(_ events: [HookEvent], now: TimeInterval) -> SessionState? {
        reduce(events).sessions(now: at(now)).first?.state
    }

    @Test func everyEventMovesTheStateAsDocumented() {
        typealias E = HookEvent.Kind
        #expect(state([Fixture.event(.sessionStart(source: "startup"), at: 0)], now: 1) == .idle(since: at(0)))
        #expect(state([Fixture.event(.userPromptSubmit, at: 0)], now: 1) == .working)
        #expect(state([Fixture.event(.permissionRequest(tool: "Bash"), at: 0)], now: 1) == .needsPermission(detail: "Bash"))
        #expect(state([Fixture.event(.notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 0)], now: 1) == .needsPermission(detail: nil))
        #expect(state([Fixture.event(.notification(type: "elicitation_dialog", message: "Pick one"), at: 0)], now: 1) == .needsInput(detail: "Pick one"))
        #expect(state([Fixture.event(.notification(type: "agent_needs_input", message: nil), at: 0)], now: 1) == .needsInput(detail: nil))
        #expect(state([Fixture.event(.permissionRequest(tool: "Bash"), at: 0), Fixture.event(.postToolUse(tool: "Bash"), at: 5)], now: 6) == .working)
        #expect(state([Fixture.event(.permissionRequest(tool: "Bash"), at: 0), Fixture.event(.postToolUseFailure(tool: "Bash"), at: 5)], now: 6) == .working)
        #expect(state([Fixture.event(.notification(type: "elicitation_dialog", message: nil), at: 0), Fixture.event(.notification(type: "elicitation_response", message: nil), at: 3)], now: 4) == .working)
        #expect(state([Fixture.event(.permissionRequest(tool: "Edit"), at: 0), Fixture.event(.userPromptSubmit, at: 5)], now: 6) == .working)
        #expect(state([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.stop, at: 10)], now: 11) == .finished(at: at(10)))
        #expect(state([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.stopFailure(error: "rate_limit"), at: 10)], now: 11) == .finished(at: at(10)))
        #expect(state([Fixture.event(.permissionRequest(tool: "Bash"), at: 0), Fixture.event(.stop, at: 5)], now: 6) == .finished(at: at(5)))
        #expect(state([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.notification(type: "auth_success", message: nil), at: 5)], now: 6) == .working, "unrelated notifications change nothing")
        #expect(state([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.other("SubagentStop"), at: 5)], now: 6) == .working)
    }

    @Test func finishedDecaysToIdleAndIdlePromptKeepsDone() {
        let events = [Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.stop, at: 10)]
        let decay = SessionReducer.Config().finishedDecay
        #expect(state(events, now: 10 + decay - 1) == .finished(at: at(10)))
        #expect(state(events, now: 10 + decay + 1) == .idle(since: at(10)))
        #expect(state(events + [Fixture.event(.notification(type: "idle_prompt", message: nil), at: 70)], now: 71) == .finished(at: at(10)))
    }

    @Test func permissionDetailAndStartSurviveTheFollowUpNotification() throws {
        let r = reduce([
            Fixture.event(.userPromptSubmit, at: 0),
            Fixture.event(.permissionRequest(tool: "Bash"), at: 10),
            Fixture.event(.notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 11),
        ])
        let s = try #require(r.sessions(now: at(20)).first)
        #expect(s.state == .needsPermission(detail: "Bash"))
        #expect(s.since == at(10))
    }

    @Test func workingKeepsItsStartAcrossToolUses() throws {
        let r = reduce([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.postToolUse(tool: "Read"), at: 30), Fixture.event(.postToolUse(tool: "Edit"), at: 60)])
        #expect(try #require(r.sessions(now: at(61)).first).since == at(0))
    }

    @Test func sessionEndRemovesAndBlocksStaleRegistryFile() {
        var r = reduce([Fixture.event(.userPromptSubmit, at: 0), Fixture.event(.sessionEnd(reason: "prompt_input_exit"), at: 20)])
        #expect(r.sessions(now: at(21)).isEmpty)
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "idle", at: 15)], available: true))
        #expect(r.sessions(now: at(22)).isEmpty, "a registry file older than the end is ignored")
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "busy", at: 30)], available: true))
        #expect(r.sessions(now: at(31)).first?.state == .working, "rewritten after the end: it is back (e.g. /resume)")
        r.apply(Fixture.event(.userPromptSubmit, at: 10))
        #expect(r.sessions(now: at(32)).first?.state == .working)
    }

    @Test func lateEventsDoNotRewindState() {
        var r = reduce([Fixture.event(.stop, at: 50)])
        r.apply(Fixture.event(.userPromptSubmit, at: 10))
        #expect(r.sessions(now: at(51)).first?.state == .finished(at: at(50)))
    }

    @Test func hookOnlySessionsExpire() {
        var noRegistry = reduce([Fixture.event(.userPromptSubmit, at: 0)])
        let cfg = SessionReducer.Config()
        #expect(noRegistry.sessions(now: at(cfg.hookOnlyTTL - 1)).count == 1)
        #expect(noRegistry.sessions(now: at(cfg.hookOnlyTTL + 1)).isEmpty)

        noRegistry.applyRegistry(RegistrySnapshot(records: [], available: true))
        #expect(noRegistry.sessions(now: at(cfg.hookOnlyGrace - 1)).count == 1, "registry exists but lags: short grace")
        #expect(noRegistry.sessions(now: at(cfg.hookOnlyGrace + 1)).isEmpty)

        var waiting = SessionReducer()
        waiting.applyRegistry(RegistrySnapshot(records: [], available: true))
        waiting.apply(Fixture.event(.permissionRequest(tool: "Bash"), at: 0))
        #expect(waiting.sessions(now: at(cfg.attentionGrace - 1)).count == 1, "a waiting session stays longer")
        #expect(waiting.sessions(now: at(cfg.attentionGrace + 1)).isEmpty)
    }

    @Test func titleAndCwdComeFromHooksWithoutRegistry() throws {
        var r = reduce([HookEvent(sessionID: "s9", kind: .sessionStart(source: "startup"), at: at(0), cwd: "/Users/dev/projects/webshop")])
        #expect(try #require(r.sessions(now: at(1)).first).title == "webshop")
        r.apply(HookEvent(sessionID: "s9", kind: .userPromptSubmit, at: at(2), cwd: nil, title: "Fix the cart"))
        let s = try #require(r.sessions(now: at(3)).first)
        #expect(s.title == "Fix the cart" && s.cwd == "/Users/dev/projects/webshop" && s.pid == nil)
    }
}

@Suite struct ReducerPruningTests {
    let t0 = Fixture.t0
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func mapsStayBounded() {
        var r = SessionReducer()
        r.applyRegistry(RegistrySnapshot(records: [], available: true), now: at(0))
        for i in 0..<500 {
            r.apply(Fixture.event(.userPromptSubmit, "hook-only-\(i)", at: Double(i)))
            r.apply(Fixture.event(.sessionEnd(reason: "other"), "ended-\(i)", at: Double(i)))
            r.applyRegistry(RegistrySnapshot(records: [Fixture.record("seen-\(i)", status: "busy", at: Double(i))], available: true), now: at(Double(i)))
        }
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record("live", status: "idle", at: 0)], available: true), now: at(500))
        r.apply(Fixture.event(.userPromptSubmit, "fresh", at: 600))
        r.prune(now: at(600))
        #expect(r.memoryFootprint.hooks == 501, "nothing is past its limit yet")
        let later = 500 + SessionReducer.memory + SessionReducer.Config().attentionGrace + 1
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record("live", status: "idle", at: 0)], available: true), now: at(later))
        r.prune(now: at(later))
        let f = r.memoryFootprint
        #expect(f.registry == 1 && f.seen == 1 && f.ended == 0 && f.hooks == 0)
        #expect(r.sessions(now: at(later)).map(\.id) == ["live"])
    }
}

@Suite struct ReducerMergeTests {
    let t0 = Fixture.t0
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func snap(_ records: RegistryRecord...) -> RegistrySnapshot { RegistrySnapshot(records: records, available: true) }

    @Test func registryAloneGivesStatesAndTitles() throws {
        var r = SessionReducer()
        r.applyRegistry(snap(
            Fixture.record("a", pid: 1, status: "busy", at: 0, name: "build-demo-app", nameSource: "auto"),
            Fixture.record("b", pid: 2, status: "idle", at: -60, name: "garden-web-85", nameSource: "derived", cwd: "/Users/dev/projects/Garden.Web"),
            Fixture.record("c", pid: 3, status: "shell", at: -30, name: nil, nameSource: nil, cwd: "/Users/dev/projects/gui"),
            Fixture.record("d", pid: 4, status: "waiting", at: -5, waitingFor: "permission prompt")
        ))
        let s = r.sessions(now: at(1))
        #expect(s.map(\.id) == ["d", "a", "c", "b"], "needs the user first, then working, then idle (newest first)")
        #expect(s.map(\.title) == ["demo-task", "build-demo-app", "gui", "Garden.Web"], "derived names fall back to the folder")
        #expect(s[0].state == .needsPermission(detail: nil) && s[0].pid == 4)
        #expect(s[1].state == .working)
        #expect(s[2].state == .idle(since: at(-30)))
    }

    @Test func busyToIdleBetweenSnapshotsIsDone() {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "idle", at: -100)))
        #expect(r.sessions(now: at(0)).first?.state == .idle(since: at(-100)), "first sight of an idle session is not 'done'")
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 0)))
        r.applyRegistry(snap(Fixture.record(status: "idle", at: 40)))
        #expect(r.sessions(now: at(41)).first?.state == .finished(at: at(40)))
        r.applyRegistry(snap(Fixture.record(status: "idle", at: 40)))
        #expect(r.sessions(now: at(50)).first?.state == .finished(at: at(40)), "stays done across polls")
        #expect(r.sessions(now: at(40 + SessionReducer.Config().finishedDecay + 1)).first?.state == .idle(since: at(40)))
    }

    @Test func newerObservationWins() {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 0)))
        r.apply(Fixture.event(.permissionRequest(tool: "Bash"), at: 10))
        #expect(r.sessions(now: at(11)).first?.state == .needsPermission(detail: "Bash"), "registry did not flip to waiting (older CLI)")
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 20)))
        #expect(r.sessions(now: at(21)).first?.state == .working, "approved: the registry saw busy after the prompt")

        r.apply(Fixture.event(.permissionRequest(tool: "Edit"), at: 30))
        r.applyRegistry(snap(Fixture.record(status: "idle", at: 35)))
        #expect(r.sessions(now: at(36)).first?.state == .idle(since: at(35)), "denied / escaped: idle after the prompt")

        r.apply(Fixture.event(.userPromptSubmit, at: 40))
        #expect(r.sessions(now: at(41)).first?.state == .working, "hook ahead of a registry that has not caught up")
    }

    @Test func agreeingNeedsCombine() throws {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "waiting", at: 12, waitingFor: "permission prompt")))
        r.apply(Fixture.event(.permissionRequest(tool: "Bash"), at: 10))
        let s = try #require(r.sessions(now: at(13)).first)
        #expect(s.state == .needsPermission(detail: "Bash"), "hook detail with registry agreement")
        #expect(s.since == at(10), "earliest start")

        var input = SessionReducer()
        input.applyRegistry(snap(Fixture.record(status: "waiting", at: 5, waitingFor: "input needed")))
        #expect(input.sessions(now: at(6)).first?.state == .needsInput(detail: "input needed"))
    }

    @Test func registryIdleNeverHidesHookDone() {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "idle", at: -500)))
        r.apply(Fixture.event(.userPromptSubmit, at: 0))
        r.apply(Fixture.event(.stop, at: 30))
        r.applyRegistry(snap(Fixture.record(status: "idle", at: 30.2)))
        #expect(r.sessions(now: at(31)).first?.state == .finished(at: at(30)))
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 60)))
        #expect(r.sessions(now: at(61)).first?.state == .working, "a newer busy does override done")
    }

    @Test func leavingTheRegistryRemovesTheSession() {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 0)))
        r.apply(Fixture.event(.userPromptSubmit, at: 1))
        #expect(r.sessions(now: at(2)).count == 1)
        r.applyRegistry(snap())
        #expect(r.sessions(now: at(3)).isEmpty, "process gone: no hook-only ghost")
    }

    @Test func registryAndHookShareOneRow() throws {
        var r = SessionReducer()
        r.applyRegistry(snap(Fixture.record(status: "busy", at: 0, name: "demo-task")))
        r.apply(HookEvent(sessionID: "s1", kind: .userPromptSubmit, at: at(1), cwd: "/Users/dev/projects/demo", title: "Custom title"))
        let all = r.sessions(now: at(2))
        #expect(all.count == 1)
        #expect(try #require(all.first).title == "demo-task", "a real registry name beats the hook title")
        #expect(all.first?.lastEvent == at(1))
    }
}

@Suite struct ActivityTests {
    let now = Fixture.t0
    func session(_ id: String, _ title: String, _ state: SessionState, since: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, cwd: "/Users/dev/\(title)", title: title, entrypoint: .cli, state: state,
                      since: now.addingTimeInterval(since), lastEvent: now.addingTimeInterval(since))
    }

    @Test func attentionWhenAnyoneWaits() throws {
        let one = try #require(ClaudeActivity.make(for: [session("a", "notcher", .needsPermission(detail: "Bash"), since: -20), session("b", "x", .working, since: -5)], now: now, showNames: false))
        #expect(one.priority == .attention)
        #expect(one.leading == .symbol("hand.raised.fill", tint: .warning, pulse: true))
        #expect(one.trailing == .text("notch\u{2026}"))
        #expect(one.accessibilityLabel == "notcher: Needs permission")
        #expect(one.module == .claudeAgents)

        let two = try #require(ClaudeActivity.make(for: [session("a", "lanternfly", .needsPermission(detail: nil), since: -20), session("b", "y", .needsInput(detail: nil), since: -5)], now: now, showNames: false))
        #expect(two.trailing == .text("2"))
        #expect(two.accessibilityLabel == "2 Claude sessions need attention")
        #expect(two.leading == .symbol("questionmark.bubble.fill", tint: .warning, pulse: true))
        #expect(ClaudeActivity.make(for: [session("a", "lanternfly", .needsInput(detail: nil), since: -1)], now: now, showNames: false)?.trailing == .text("lante\u{2026}"))
    }

    @Test func namesOffIsExactlyThePreviousActivity() throws {
        let waiting = [session("a", "notcher", .needsPermission(detail: "Bash"), since: -20)]
        let off = try #require(ClaudeActivity.make(for: waiting, now: now, showNames: false))
        #expect(off == LiveActivity(
            id: "claudeAgents.attention", module: .claudeAgents, priority: .attention,
            leading: .symbol("hand.raised.fill", tint: .warning, pulse: true), trailing: .text("notch\u{2026}"),
            updatedAt: now.addingTimeInterval(-20), accessibilityLabel: "notcher: Needs permission"
        ))
        let done = [session("a", "demo", .finished(at: now.addingTimeInterval(-2)), since: -2)]
        #expect(try #require(ClaudeActivity.make(for: done, now: now, showNames: false)) == LiveActivity(
            id: "claudeAgents.done", module: .claudeAgents, priority: .passive,
            leading: .symbol("checkmark.circle.fill", tint: .success), trailing: .text("demo"),
            expiresAt: now.addingTimeInterval(-2 + ClaudeActivity.doneDuration), updatedAt: now.addingTimeInterval(-2),
            accessibilityLabel: "demo: done"
        ))
    }

    @Test func oneWaitingWithTool() throws {
        let a = try #require(ClaudeActivity.make(for: [session("a", "notcher", .needsPermission(detail: "Bash"), since: -20), session("b", "x", .working, since: -5)], now: now))
        #expect(a.leadingText == "notcher" && a.trailingText == "Allow Bash")
        #expect(a.leading == .symbol("hand.raised.fill", tint: .warning, pulse: true) && a.trailing == nil)
        #expect(a.accessibilityLabel == "notcher is waiting: Allow Bash")
        #expect(a.id == "claudeAgents.attention" && a.priority == .attention && a.updatedAt == now.addingTimeInterval(-20))
    }

    @Test func oneWaitingWithoutToolOrForInput() throws {
        let perm = try #require(ClaudeActivity.make(for: [session("a", "notcher", .needsPermission(detail: nil), since: -1)], now: now))
        #expect(perm.trailingText == "Needs permission" && perm.accessibilityLabel == "notcher is waiting: Needs permission")
        let input = try #require(ClaudeActivity.make(for: [session("a", "webshop", .needsInput(detail: "Pick a database"), since: -1)], now: now))
        #expect(input.leadingText == "webshop" && input.trailingText == "Needs input")
        #expect(input.leading == .symbol("questionmark.bubble.fill", tint: .warning, pulse: true))
    }

    @Test func severalWaitingNameTheLongestWaiting() throws {
        let sessions = [
            session("a", "newest", .needsPermission(detail: "Edit"), since: -5),
            session("b", "oldest", .needsPermission(detail: "Bash"), since: -300),
            session("c", "middle", .needsInput(detail: nil), since: -60),
            session("d", "busy", .working, since: -1),
        ]
        let a = try #require(ClaudeActivity.make(for: sessions, now: now))
        #expect(a.leadingText == "oldest" && a.trailingText == "3 sessions")
        #expect(a.trailing == nil, "the count is not repeated as a glyph")
        #expect(SessionCardContent.make(sessions: sessions, alerts: .on).rows.first?.title == "oldest", "the card lists the same session first")
        #expect(a.accessibilityLabel == "3 Claude sessions are waiting; oldest has waited longest: Allow Bash")
        #expect(a.id == "claudeAgents.attention")
    }

    @Test func doneNamesTheSession() throws {
        let a = try #require(ClaudeActivity.make(for: [session("a", "garden-clock", .finished(at: now.addingTimeInterval(-2)), since: -2)], now: now))
        #expect(a.leadingText == "garden-clock" && a.trailingText == "Done" && a.trailing == nil)
        #expect(a.priority == .passive && a.id == "claudeAgents.done" && a.accessibilityLabel == "garden-clock is done")
    }

    @Test func textHygiene() throws {
        let messy = session("a", "  fix\n the   cart\t ", .needsPermission(detail: "  mcp__server__\n" + String(repeating: "x", count: 500)), since: -1)
        let a = try #require(ClaudeActivity.make(for: [messy], now: now))
        #expect(a.leadingText == "fix the cart")
        let tool = try #require(a.trailingText)
        #expect(!tool.contains("\n") && tool.hasPrefix("Allow mcp__server__ x"))
        #expect(tool.count == "Allow ".count + ClaudeActivity.maxToolLength && tool.hasSuffix("\u{2026}"))
        #expect(ClaudeActivity.request(for: .needsPermission(detail: " \n ")) == "Needs permission")
        let long = try #require(ClaudeActivity.make(for: [session("b", String(repeating: "t", count: 300), .needsInput(detail: nil), since: -1)], now: now))
        #expect(long.leadingText?.count == ClaudeActivity.maxTitleLength)
        for text in [a.leadingText, a.trailingText, a.accessibilityLabel, long.trailingText].compactMap({ $0 }) {
            #expect(!text.contains("!") && !text.lowercased().contains("you"))
        }
    }

    @Test func registryOnlyNeverYieldsAToolName() throws {
        var r = SessionReducer()
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "waiting", at: 0, waitingFor: "permission prompt")], available: true))
        let s = r.sessions(now: Fixture.t0.addingTimeInterval(1))
        #expect(s.first?.state == .needsPermission(detail: nil))
        let a = try #require(ClaudeActivity.make(for: s, now: Fixture.t0.addingTimeInterval(1)))
        #expect(a.trailingText == "Needs permission")
        var input = SessionReducer()
        input.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "waiting", at: 0, waitingFor: "dialog open")], available: true))
        #expect(ClaudeActivity.make(for: input.sessions(now: Fixture.t0.addingTimeInterval(1)), now: Fixture.t0)?.trailingText == "Needs input")
    }

    @Test func toolNameIsCarriedFromTheHookAndUpdatedForANewPrompt() throws {
        var r = SessionReducer()
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "busy", at: 0)], available: true))
        r.apply(Fixture.event(.permissionRequest(tool: "Bash"), at: 10))
        r.apply(Fixture.event(.notification(type: "permission_prompt", message: "Claude needs permission"), at: 10.5))
        r.applyRegistry(RegistrySnapshot(records: [Fixture.record(status: "waiting", at: 11, waitingFor: "permission prompt")], available: true))
        let first = try #require(r.sessions(now: Fixture.t0.addingTimeInterval(12)).first)
        #expect(ClaudeActivity.request(for: first.state) == "Allow Bash", "hook tool survives the registry's own waiting status")
        r.apply(Fixture.event(.permissionRequest(tool: "Edit"), at: 20))
        let second = try #require(r.sessions(now: Fixture.t0.addingTimeInterval(21)).first)
        #expect(ClaudeActivity.request(for: second.state) == "Allow Edit", "a new prompt for another tool is not shown as the old one")
    }

    @Test func shortDoneThenNothing() throws {
        let done = [session("a", "demo", .finished(at: now.addingTimeInterval(-2)), since: -2), session("b", "x", .idle(since: now), since: 0)]
        let activity = try #require(ClaudeActivity.make(for: done, now: now, showNames: false))
        #expect(activity.priority == .passive)
        #expect(activity.accessibilityLabel == "demo: done" && activity.trailing == .text("demo"))
        #expect(activity.expiresAt == now.addingTimeInterval(-2 + ClaudeActivity.doneDuration))
        #expect(ClaudeActivity.make(for: done, now: now.addingTimeInterval(ClaudeActivity.doneDuration)) == nil)
        #expect(ClaudeActivity.make(for: [session("a", "demo", .working, since: -60), session("b", "x", .idle(since: now), since: 0)], now: now) == nil,
                "sessions merely existing show nothing")
    }

    @Test func presentationLines() {
        #expect(SessionPresentation.stateLine(for: .needsPermission(detail: "Bash")) == "Needs permission")
        #expect(SessionPresentation.detailLine(for: .needsPermission(detail: "Bash")) == "Asking permission to use Bash")
        #expect(SessionPresentation.stateLine(for: .needsInput(detail: "x")) == "Needs input")
        #expect(SessionPresentation.detailLine(for: .needsInput(detail: "pick a database")) == "Needs input: pick a database")
        #expect(SessionPresentation.stateLine(for: .idle(since: now)) == "Idle")
        #expect(SessionPresentation.stateLine(for: .working) == "Working")
        #expect(SessionPresentation.stateLine(for: .finished(at: now)) == "Done")
        #expect(SessionPresentation.elapsed(since: now.addingTimeInterval(-125), now: now) == "2m")
        #expect(SessionPresentation.elapsed(since: now.addingTimeInterval(-45), now: now) == "now")
        #expect(SessionPresentation.elapsed(since: now.addingTimeInterval(-7300), now: now) == "2h")
        #expect(SessionPresentation.wingTitle("notcher") == "notch\u{2026}" && SessionPresentation.wingTitle("demo") == "demo")
        #expect(SessionPresentation.tint(for: .needsInput(detail: nil)) == .warning)
    }
}

@Suite struct CardContentTests {
    let now = Fixture.t0
    func session(_ id: String, _ state: SessionState, since: TimeInterval) -> ClaudeSession {
        ClaudeSession(id: id, pid: 1, cwd: "/Users/dev/\(id)", title: id, entrypoint: .cli, state: state,
                      since: now.addingTimeInterval(since), lastEvent: now.addingTimeInterval(since))
    }

    @Test func topTwoAreTheMostImportant() {
        let all = [
            session("idle", .idle(since: now), since: -10),
            session("done", .finished(at: now.addingTimeInterval(-5)), since: -5),
            session("work", .working, since: -300),
            session("ask", .needsInput(detail: nil), since: -60),
            session("perm", .needsPermission(detail: "Bash"), since: -20),
        ]
        let c = SessionCardContent.make(sessions: all, alerts: .on)
        #expect(c.rows.map(\.id) == ["ask", "perm"], "needs the user first, longest waiting first")
        #expect(c.hiddenCount == 3)
        let calm = SessionCardContent.make(sessions: Array(all.prefix(3)), alerts: .on)
        #expect(calm.rows.map(\.id) == ["work", "done"], "then working, then done/idle")
        #expect(calm.hiddenCount == 1)
        let two = SessionCardContent.make(sessions: Array(all.prefix(2)), alerts: .on)
        #expect(two.hiddenCount == 0 && two.rows.count == 2)
    }

    @Test func enableAlertsOnlyWhenOffAndSomethingRuns() {
        let one = [session("work", .working, since: 0)]
        #expect(SessionCardContent.make(sessions: one, alerts: .off).showsEnableAlerts)
        #expect(SessionCardContent.make(sessions: one, alerts: .unavailable).showsEnableAlerts && SessionCardContent.make(sessions: one, alerts: .offStillRegistered).showsEnableAlerts)
        #expect(!SessionCardContent.make(sessions: one, alerts: .on).showsEnableAlerts)
        #expect(!SessionCardContent.make(sessions: [], alerts: .off).showsEnableAlerts)
        #expect(SessionCardContent.make(sessions: [], alerts: .off).rows.isEmpty)
    }
}
